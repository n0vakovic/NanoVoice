import UIKit
import UserNotifications
import UniversalMediaPlayer
import AudioToolbox
import Postbox
import TelegramCore
import SwiftSignalKit
import AccountContext
import PeerMessagesMediaPlaylist

/// One explicit voice session owns capture, playback and the background connection.
final class WalkChatControls: NSObject {
    private weak var controller: ChatControllerImpl?
    private let context: AccountContext
    private let peerId: EnginePeer.Id
    private let button = UIButton(type: .system)
    private let gate = WalkReplyGate()
    private var enabled = false
    private var starting = false
    private var voiceSession: WalkVoiceSession?
    private var replyPlayer: MediaPlayer?
    private var replyStatus: Disposable?
    private var pending: [Message] = []
    private var current: EngineMessage.Id?
    private var lastPlayerStatus = ""
    private var incomingDisposable: Disposable?
    private let fetchDisposable = MetaDisposable()
    private let dataDisposable = MetaDisposable()
    private var downloadTimeout: DispatchWorkItem?
    private var delayedReply: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private let diagnosticId = UUID().uuidString
    private let draftStore: WalkDraftStore
    private var currentMessage: Message?
    private var attemptId = UUID()
    private var failedReplies: [Message] = []
    private var failureCounts: [EngineMessage.Id: Int] = [:]
    private var retryWork: [EngineMessage.Id: DispatchWorkItem] = [:]
    private var watchdog: Foundation.Timer?
    private var progress = WalkPlaybackProgress()
    private var pausedPosition: Double?
    private var latestPlayerState: MediaPlayerStatus?
    private var playerWantsPlayback = false
    private var pauseRequestedAt: Double = 0
    private var rewindCheckpoint: Double = 0
    private var playbackAdvanced = false
    private var preparingRecording = false
    private var pauseCompletion: (() -> Void)?
    private var pauseTimeout: DispatchWorkItem?
    private var nextId = Int32(Date().timeIntervalSince1970)

    init(controller: ChatControllerImpl, context: AccountContext, peerId: EnginePeer.Id) {
        self.controller = controller
        self.context = context
        self.peerId = peerId
        self.draftStore = WalkDraftStore(account: context.account.peerId.toInt64(), peer: peerId.toInt64())
        super.init()
        updateTitle()
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 16
        button.layer.shadowOpacity = 0.12
        button.layer.shadowRadius = 4
        button.accessibilityIdentifier = "walk.chat.controls"
        button.addTarget(self, action: #selector(menu), for: .touchUpInside)
        controller.view.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            button.widthAnchor.constraint(equalToConstant: 96),
            button.heightAnchor.constraint(equalToConstant: 36)
        ])
        for (name, label) in [(UIApplication.didEnterBackgroundNotification, "background"), (UIApplication.willEnterForegroundNotification, "foreground")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let self, self.enabled { self.log("Application entered \(label)") }
            })
        }
        if walkChatFixtureEnabled && (CommandLine.arguments.contains("--walk-chat-self-test") || CommandLine.arguments.contains("--walk-lock-self-test")) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.start()
            }
        }
    }

    deinit {
        voiceSession?.stop()
        watchdog?.invalidate()
        pauseTimeout?.cancel()
        for work in retryWork.values { work.cancel() }
        replyStatus?.dispose()
        incomingDisposable?.dispose()
        fetchDisposable.dispose()
        dataDisposable.dispose()
        downloadTimeout?.cancel()
        delayedReply?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func start() {
        guard !enabled, !starting else { return }
        starting = true
        updateTitle()
        context.sharedContext.mediaManager.setPlaylist(nil, type: .voice, control: .playback(.pause))
        context.sharedContext.mediaManager.setPlaylist(nil, type: .music, control: .playback(.pause))
        let session = WalkVoiceSession(context: context)
        voiceSession = session
        session.onLog = { [weak self] text in self?.log(text) }
        session.onError = { [weak self] text in
            guard let self else { return }
            self.log(text)
            Self.notifyIfAllowed("Walk mode stopped", body: "Open NanoVoice to review the interruption and any saved recording.")
            self.stop()
            if UIApplication.shared.applicationState == .active {
                let alert = UIAlertController(title: "Walk mode stopped", message: text, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.controller?.present(alert, animated: true)
            }
        }
        session.beforeRecording = { [weak self] completion in
            guard let self else { return }
            self.prepareRecording(completion)
        }
        let store = draftStore
        session.onInterruptedRecording = { [weak self] data, duration in
            do {
                try store.save(data: data, duration: duration)
                self?.log("Interrupted recording saved as draft")
                Self.notifyIfAllowed("Recording saved", body: "An interrupted Walk recording is ready to recover in its chat.")
                self?.updateTitle()
            } catch {
                // Keep a live copy and surface the failure; never claim persistence succeeded.
                store.retainUnsaved(data: data, duration: duration)
                self?.showError("Could not save the interrupted recording. Keep NanoVoice open and use Recover recordings to retry saving.")
                Self.notifyIfAllowed("Recording not saved to disk", body: "Keep NanoVoice open and use Recover recordings to retry saving.")
                WalkDiagnostics.log("Draft persistence failed")
            }
        }
        session.onRecording = { [weak self] recording in
            guard let self else { return }
            self.preparingRecording = false
            self.pauseTimeout?.cancel(); self.pauseTimeout = nil
            self.pauseCompletion = nil
            if recording { self.replyPlayer?.pause() }
            else if let player = self.replyPlayer {
                self.playerWantsPlayback = true
                if let position = self.pausedPosition {
                    player.seek(timestamp: position, play: true)
                    self.progress.reset(now: CACurrentMediaTime(), position: position)
                    self.rewindCheckpoint = position
                    self.playbackAdvanced = false
                    self.pausedPosition = nil
                } else { player.play() }
            } else if self.current == nil { self.playNext() }
            self.updateTitle()
        }
        session.onMessage = { [weak self] data, duration in self?.sendVoice(data: data, duration: duration) }
        session.onReady = { [weak self] in self?.ready() }
        session.start()
    }

    private func ready() {
        guard starting else { return }
        starting = false
        enabled = true
        gate.start(peer: peerId.toInt64(), timestamp: Int32(context.account.network.globalTime))
        incomingDisposable = (context.account.stateManager.incomingAudioSessionMessages |> deliverOnMainQueue).start(next: { [weak self] messages in
            guard let self, self.enabled else { return }
            for message in messages.sorted(by: { $0.index < $1.index }) {
                let audio = message.media.contains { media in
                    guard let file = media as? TelegramMediaFile else { return false }
                    return file.isVoice || file.isMusic || file.mimeType.hasPrefix("audio/")
                }
                if self.gate.accept(peer: message.id.peerId.toInt64(), id: "\(message.id.namespace):\(message.id.id)", timestamp: message.timestamp, now: Int32(self.context.account.network.globalTime), incoming: message.flags.contains(.Incoming), audio: audio) {
                    self.log("Received new audio")
                    self.pending.append(message)
                }
            }
            self.playNext()
        })
        log("Walk session started")
        if walkChatFixtureEnabled && CommandLine.arguments.contains("--walk-chat-self-test") {
            inject(count: 2)
        }
        if walkChatFixtureEnabled && CommandLine.arguments.contains("--walk-lock-self-test") {
            let work = DispatchWorkItem { [weak self] in self?.inject(count: 2) }
            delayedReply = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
            log("Locked-screen fixture scheduled in 90 seconds")
        }
        updateTitle()
    }

    func stop() {
        if enabled || starting { log("Walk session stopped") }
        enabled = false
        starting = false
        preparingRecording = false
        pauseCompletion = nil
        pauseTimeout?.cancel(); pauseTimeout = nil
        watchdog?.invalidate(); watchdog = nil
        for work in retryWork.values { work.cancel() }
        retryWork.removeAll()
        attemptId = UUID()
        pausedPosition = nil
        replyStatus?.dispose(); replyStatus = nil
        replyPlayer?.pause(); replyPlayer = nil
        voiceSession?.stop(); voiceSession = nil
        gate.stop()
        incomingDisposable?.dispose()
        incomingDisposable = nil
        delayedReply?.cancel()
        delayedReply = nil
        cancelDownload()
        for message in pending + (currentMessage.map { [$0] } ?? []) {
            if !failedReplies.contains(where: { $0.id == message.id }) { failedReplies.append(message) }
        }
        pending.removeAll()
        current = nil
        currentMessage = nil
        updateTitle()
    }

    @objc private func menu() {
        let sheet = UIAlertController(title: "Walk mode", message: walkChatFixtureEnabled ? "Local voice replies in the regular chat." : "Keeps a microphone session active while locked. Press your AirPod to unmute and record; press again to mute and send. Only recorded segments are sent. End Walk mode when finished.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: starting ? "Cancel starting" : (enabled ? "End Walk mode" : "Start Walk mode"), style: .default, handler: { [weak self] _ in
            guard let self else { return }
            if self.enabled || self.starting { self.stop() } else { self.start() }
        }))
        if enabled {
            sheet.addAction(UIAlertAction(title: voiceSession?.recording == true ? "Send voice reply" : "Record voice reply", style: .default, handler: { [weak self] _ in
                self?.voiceSession?.toggleRecording()
            }))
        }
        if enabled && !failedReplies.isEmpty {
            sheet.addAction(UIAlertAction(title: "Retry \(failedReplies.count) failed replies", style: .default, handler: { [weak self] _ in
                self?.retryFailedReplies()
            }))
        }
        if ((try? draftStore.hasDrafts()) ?? true) || !draftStore.unsaved.isEmpty {
            sheet.addAction(UIAlertAction(title: "Recover recordings", style: .default, handler: { [weak self] _ in self?.recoverDrafts() }))
        }
        sheet.addAction(UIAlertAction(title: "Share diagnostics", style: .default, handler: { [weak self] _ in
            guard let self else { return }
            let urls = WalkDiagnostics.exportURLs()
            guard !urls.isEmpty else { self.showError("Could not export diagnostics."); return }
            let share = UIActivityViewController(activityItems: urls, applicationActivities: nil)
            share.popoverPresentationController?.sourceView = self.button
            share.popoverPresentationController?.sourceRect = self.button.bounds
            self.controller?.present(share, animated: true)
        }))
        if walkChatFixtureEnabled {
            sheet.addAction(UIAlertAction(title: "Receive voice reply", style: .default, handler: { [weak self] _ in self?.inject(count: 1) }))
            sheet.addAction(UIAlertAction(title: "Receive two replies", style: .default, handler: { [weak self] _ in self?.inject(count: 2) }))
            sheet.addAction(UIAlertAction(title: "Receive reply in 10 seconds", style: .default, handler: { [weak self] _ in
                guard let self else { return }
                self.delayedReply?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.inject(count: 1) }
                self.delayedReply = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
            }))
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = button
        sheet.popoverPresentationController?.sourceRect = button.bounds
        controller?.present(sheet, animated: true)
    }

    private func updateTitle() {
        let needsRecovery = !draftStore.unsaved.isEmpty || ((try? draftStore.hasDrafts()) ?? true)
        let title = starting ? "Starting…" : (voiceSession?.recording == true ? "Recording" : (needsRecovery ? "Walk · Draft" : (enabled ? (failedReplies.isEmpty ? "Walk On" : "Walk · Retry") : "Walk Off")))
        button.setTitle(title, for: .normal)
    }

    private func inject(count: Int) {
        guard walkChatFixtureEnabled else { return }
        let name = peerId == walkChatEmmaId ? "emma-reply" : "russ-reply"
        guard let url = Bundle.main.url(forResource: name, withExtension: "ogg") else { log("Missing audio fixture"); return }
        for _ in 0 ..< count {
            nextId += 1
            let _ = (insertWalkChatVoice(account: context.account, peerId: peerId, fileURL: url, id: nextId)
            |> mapToSignal { [context] id in context.account.postbox.messageAtId(id) |> take(1) }
            |> deliverOnMainQueue).start(next: { [weak self] message in
                guard let self, let message else { return }
                self.log("Inserted native voice message")
                if self.enabled { self.pending.append(message); self.playNext() }
            })
        }
    }

    private func cancelDownload() {
        fetchDisposable.set(nil)
        dataDisposable.set(nil)
        downloadTimeout?.cancel()
        downloadTimeout = nil
    }
    private func playNext() {
        guard enabled, !preparingRecording, voiceSession?.recording != true, current == nil, !pending.isEmpty else { return }
        let message = pending.removeFirst()
        guard let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first(where: { $0.isVoice || $0.isMusic || $0.mimeType.hasPrefix("audio/") }) else { playNext(); return }
        let id = message.id
        current = id
        currentMessage = message
        attemptId = UUID()
        let token = attemptId
        lastPlayerStatus = ""
        let failed: () -> Void = { [weak self] in
            guard let self, self.attemptId == token else { return }
            self.failCurrent(reason: "Audio download failed or timed out")
        }
        let timeout = DispatchWorkItem(block: failed)
        downloadTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        fetchDisposable.set((fetchedMediaResource(mediaBox: context.account.postbox.mediaBox, userLocation: .peer(peerId), userContentType: MediaResourceUserContentType(file: file), reference: FileMediaReference.message(message: MessageReference(message), media: file).resourceReference(file.resource), continueInBackground: true)
        |> deliverOnMainQueue).start(error: { _ in failed() }))
        dataDisposable.set((context.account.postbox.mediaBox.resourceData(file.resource)
        |> filter { $0.complete } |> take(1) |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let self, self.enabled, self.attemptId == token, self.current == id else { return }
            self.cancelDownload()
            self.log("Audio downloaded")
            let player = MediaPlayer(audioSessionManager: self.context.sharedContext.mediaManager.audioSession, externalAudioSession: .custom { control in
                control.activate()
                return EmptyDisposable
            }, postbox: self.context.account.postbox, userLocation: .peer(self.peerId), userContentType: .audio, resourceReference: FileMediaReference.message(message: MessageReference(message), media: file).resourceReference(file.resource), streamable: .none, video: false, preferSoftwareDecoding: false, enableSound: true, fetchAutomatically: false, playAndRecord: true)
            self.replyPlayer = player
            self.latestPlayerState = nil
            self.playerWantsPlayback = false
            self.progress.reset(now: CACurrentMediaTime())
            self.rewindCheckpoint = 0
            self.playbackAdvanced = false
            self.watchdog?.invalidate()
            self.watchdog = Foundation.Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.attemptId == token else { return }
                if self.progress.stalled(now: CACurrentMediaTime(), suspended: self.preparingRecording || self.voiceSession?.recording == true) {
                    self.failCurrent(reason: "Reply decoder made no progress for 30 seconds")
                }
            }
            player.actionAtEnd = .action { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.attemptId == token, self.current == id else { return }
                    self.log("Native player ended")
                    self.watchdog?.invalidate(); self.watchdog = nil
                    self.failureCounts.removeValue(forKey: id)
                    self.currentMessage = nil
                    self.pausedPosition = nil
                    self.replyStatus?.dispose(); self.replyStatus = nil
                    self.replyPlayer = nil
                    self.current = nil
                    self.playNext()
                }
            }
            self.replyStatus = (player.status |> deliverOnMainQueue).start(next: { [weak self] state in
                guard let self, self.attemptId == token, self.current == id else { return }
                self.progress.observe(position: state.timestamp, now: CACurrentMediaTime())
                if state.timestamp > self.rewindCheckpoint + 0.01 { self.playbackAdvanced = true }
                self.latestPlayerState = state
                if self.preparingRecording, state.generationTimestamp >= self.pauseRequestedAt, Self.isPaused(state) {
                    self.pausedPosition = self.playbackAdvanced ? WalkPlaybackProgress.resumePosition(state.timestamp) : nil
                    self.finishPreparingRecording()
                }
                let status: String
                switch state.status {
                case .playing: status = "playing"
                case .paused: status = "paused"
                case .buffering: status = "buffering"
                }
                if status != self.lastPlayerStatus {
                    self.lastPlayerStatus = status
                    self.log("Native player: \(status), time=\(state.timestamp), duration=\(state.duration)")
                    self.voiceSession?.logAudioState("reply \(status)")
                }
            })
            if !self.preparingRecording && self.voiceSession?.recording != true { self.playerWantsPlayback = true; player.play() }
        }))
    }

    private static func isPaused(_ state: MediaPlayerStatus) -> Bool {
        switch state.status {
        case .paused: return true
        case let .buffering(_, whilePlaying, _, _): return !whilePlaying
        case .playing: return false
        }
    }

    private func prepareRecording(_ completion: @escaping () -> Void) {
        preparingRecording = true
        pauseCompletion = completion
        guard let player = replyPlayer else { finishPreparingRecording(); return }
        if !playerWantsPlayback, let state = latestPlayerState, Self.isPaused(state) {
            pausedPosition = playbackAdvanced ? WalkPlaybackProgress.resumePosition(state.timestamp) : nil
            finishPreparingRecording()
            return
        }
        playerWantsPlayback = false
        pauseRequestedAt = CACurrentMediaTime()
        player.pause()
        // MediaPlayer pauses on its own queue. Wait for acknowledgement before capturing.
        // If it cannot acknowledge, dispose that player instead of recording over playback.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.preparingRecording else { return }
            self.failCurrent(reason: "Reply did not acknowledge pause")
            self.finishPreparingRecording()
        }
        pauseTimeout?.cancel()
        pauseTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timeout)
    }

    private func finishPreparingRecording() {
        pauseTimeout?.cancel(); pauseTimeout = nil
        let completion = pauseCompletion
        pauseCompletion = nil
        completion?()
    }

    private func failCurrent(reason: String) {
        guard let message = currentMessage else { return }
        log(reason)
        voiceSession?.logAudioState("reply failed")
        attemptId = UUID()
        cancelDownload()
        watchdog?.invalidate(); watchdog = nil
        replyStatus?.dispose(); replyStatus = nil
        replyPlayer?.pause(); replyPlayer = nil
        current = nil
        currentMessage = nil
        pausedPosition = nil
        if !failedReplies.contains(where: { $0.id == message.id }) { failedReplies.append(message) }
        let failures = (failureCounts[message.id] ?? 0) + 1
        failureCounts[message.id] = failures
        if let delay = WalkPlaybackProgress.retryDelay(failureCount: failures) {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.enabled else { return }
                self.retryWork.removeValue(forKey: message.id)
                guard let index = self.failedReplies.firstIndex(where: { $0.id == message.id }) else { return }
                self.pending.append(self.failedReplies.remove(at: index))
                self.updateTitle()
                self.playNext()
            }
            retryWork[message.id]?.cancel()
            retryWork[message.id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        updateTitle()
        playNext()
    }

    private func retryFailedReplies() {
        for work in retryWork.values { work.cancel() }
        retryWork.removeAll()
        for message in failedReplies { failureCounts.removeValue(forKey: message.id) }
        pending.append(contentsOf: failedReplies)
        failedReplies.removeAll()
        updateTitle()
        playNext()
    }

    private static func notifyIfAllowed(_ title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "nanovoice-walk-\(UUID().uuidString)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if error != nil { WalkDiagnostics.log("Walk interruption notification failed") }
            }
        }
    }

    private func showError(_ message: String) {
        log(message)
        guard UIApplication.shared.applicationState == .active else { return }
        let alert = UIAlertController(title: "Walk mode", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller?.present(alert, animated: true)
    }

    private func recoverDrafts() {
        // Retry persistence first. Retain the in-memory copy if disk storage still fails.
        while let draft = draftStore.unsaved.first {
            do { try draftStore.save(data: draft.0, duration: draft.1); draftStore.removeFirstUnsaved() }
            catch { showError("Recording storage is unavailable. Keep NanoVoice open and free some space before trying again."); return }
        }
        let listing: WalkDraftStore.Listing
        do { listing = try draftStore.listing() }
        catch { showError("Could not read saved recordings. They have not been deleted."); return }
        let drafts = listing.drafts.filter { !draftStore.isSending($0.id) }
        let unreadableNotice = listing.unreadableCount > 0 ? " \(listing.unreadableCount) unreadable recording(s) remain stored and have not been deleted." : ""
        guard let draft = drafts.first else {
            updateTitle()
            showError(listing.drafts.isEmpty ? "No readable saved recordings." + unreadableNotice : "Saved recordings are being queued." + unreadableNotice)
            return
        }
        let date = DateFormatter.localizedString(from: draft.createdAt, dateStyle: .short, timeStyle: .short)
        let sheet = UIAlertController(title: "Saved recording (\(drafts.count))", message: "\(date) · \(Int(draft.duration)) seconds. Send this interrupted recording to this chat, or discard it?" + unreadableNotice, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Send saved recording", style: .default, handler: { [weak self] _ in
            guard let self else { return }
            let store = self.draftStore
            guard store.beginSending(draft.id) else { return }
            self.sendVoice(data: draft.audio, duration: draft.duration, recovered: true) { [weak self] success in
                defer { store.finishSending(draft.id) }
                if success {
                    do { try store.remove(draft.id) }
                    catch {
                        WalkDiagnostics.log("Queued draft could not be deleted")
                        self?.showError("Recording was queued, but its saved copy could not be deleted. Do not send that copy again.")
                    }
                }
                self?.updateTitle()
            }
        }))
        sheet.addAction(UIAlertAction(title: "Discard saved recording", style: .destructive, handler: { [weak self] _ in
            guard let self else { return }
            guard !self.draftStore.isSending(draft.id) else { return }
            do { try self.draftStore.remove(draft.id) }
            catch { self.showError("Could not delete the saved recording.") }
            self.updateTitle()
        }))
        sheet.addAction(UIAlertAction(title: "Keep for later", style: .cancel))
        sheet.popoverPresentationController?.sourceView = button
        sheet.popoverPresentationController?.sourceRect = button.bounds
        controller?.present(sheet, animated: true)
    }

    private func sendVoice(data: Data, duration: Double, recovered: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard (enabled || recovered), !walkChatFixtureEnabled else { log("Fixture voice capture completed; nothing sent"); completion?(false); return }
        let randomId = Int64.random(in: Int64.min ... Int64.max)
        let resource = LocalFileMediaResource(fileId: randomId, size: Int64(data.count))
        context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data)
        let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: randomId), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "audio/ogg", size: Int64(data.count), attributes: [.Audio(isVoice: true, duration: max(1, Int(duration)), title: nil, performer: nil, waveform: nil)], alternativeRepresentations: [])
        let message = EnqueueMessage.message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        // An explicit send must outlive this controller: media preparation happens before
        // the Postbox transaction, and cancelling there can lose an already finished capture.
        let store = draftStore
        let failed: () -> Void = { [weak self] in
            if !recovered {
                do { try store.save(data: data, duration: duration) }
                catch {
                    store.retainUnsaved(data: data, duration: duration)
                    WalkDiagnostics.log("Failed send could not be saved to disk; retained in memory")
                }
                Self.notifyIfAllowed("Voice message not queued", body: "Open NanoVoice and use Recover recordings. Keep the app open until recovery is complete.")
            }
            self?.showError("Could not queue the voice message. Use Recover recordings to try again; keep NanoVoice open.")
            self?.updateTitle()
        }
        var receivedResult = false
        let signal = enqueueMessages(account: context.account, peerId: peerId, messages: [message]) |> deliverOnMainQueue
        let next: ([EngineMessage.Id?]) -> Void = { [weak self] ids in
            guard !receivedResult else { return }
            receivedResult = true
            let success = ids.contains(where: { $0 != nil })
            if success { self?.log("Voice reply queued for selected chat") }
            else { failed() }
            completion?(success)
        }
        let completed: () -> Void = {
            if !receivedResult { receivedResult = true; failed(); completion?(false) }
        }
        let _ = signal.startStandalone(next: next, completed: completed)
    }

    private func log(_ text: String) {
        WalkDiagnostics.log("Walk[\(diagnosticId)] \(text)")
    }
}

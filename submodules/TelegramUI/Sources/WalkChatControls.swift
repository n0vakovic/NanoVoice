import UIKit
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
    private let sendDisposable = DisposableSet()
    private var pending: [Message] = []
    private var current: EngineMessage.Id?
    private var lastPlayerStatus = ""
    private var incomingDisposable: Disposable?
    private let fetchDisposable = MetaDisposable()
    private let dataDisposable = MetaDisposable()
    private var downloadTimeout: DispatchWorkItem?
    private var delayedReply: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var events: [String] = []
    private var nextId = Int32(Date().timeIntervalSince1970)

    init(controller: ChatControllerImpl, context: AccountContext, peerId: EnginePeer.Id) {
        self.controller = controller
        self.context = context
        self.peerId = peerId
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
        replyStatus?.dispose()
        sendDisposable.dispose()
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
            self.stop()
            if UIApplication.shared.applicationState == .active {
                let alert = UIAlertController(title: "Walk mode stopped", message: text, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.controller?.present(alert, animated: true)
            }
        }
        session.onRecording = { [weak self] recording in
            guard let self else { return }
            if recording { self.replyPlayer?.pause() }
            else if self.current != nil { self.replyPlayer?.play() }
            else { self.playNext() }
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
                    self.log("Received new audio \(message.id.id)")
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
        replyStatus?.dispose(); replyStatus = nil
        replyPlayer?.pause(); replyPlayer = nil
        voiceSession?.stop(); voiceSession = nil
        gate.stop()
        incomingDisposable?.dispose()
        incomingDisposable = nil
        delayedReply?.cancel()
        delayedReply = nil
        cancelDownload()
        pending.removeAll()
        current = nil
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

    private func updateTitle() { button.setTitle(starting ? "Starting…" : (voiceSession?.recording == true ? "Recording" : (enabled ? "Walk On" : "Walk Off")), for: .normal) }

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
                self.log("Inserted native voice message \(message.id.id)")
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
        guard enabled, voiceSession?.recording != true, current == nil, !pending.isEmpty else { return }
        let message = pending.removeFirst()
        guard let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first(where: { $0.isVoice || $0.isMusic || $0.mimeType.hasPrefix("audio/") }) else { playNext(); return }
        let id = message.id
        current = id
        lastPlayerStatus = ""
        let failed: () -> Void = { [weak self] in
            guard let self, self.current == id else { return }
            self.log("Audio download failed or timed out \(id.id)")
            self.cancelDownload()
            self.current = nil
            self.playNext()
        }
        let timeout = DispatchWorkItem(block: failed)
        downloadTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        fetchDisposable.set((fetchedMediaResource(mediaBox: context.account.postbox.mediaBox, userLocation: .peer(peerId), userContentType: MediaResourceUserContentType(file: file), reference: FileMediaReference.message(message: MessageReference(message), media: file).resourceReference(file.resource), continueInBackground: true)
        |> deliverOnMainQueue).start(error: { _ in failed() }))
        dataDisposable.set((context.account.postbox.mediaBox.resourceData(file.resource)
        |> filter { $0.complete } |> take(1) |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let self, self.enabled, self.current == id else { return }
            self.cancelDownload()
            self.log("Audio downloaded \(id.id)")
            let player = MediaPlayer(audioSessionManager: self.context.sharedContext.mediaManager.audioSession, externalAudioSession: .custom { control in
                control.activate()
                return EmptyDisposable
            }, postbox: self.context.account.postbox, userLocation: .peer(self.peerId), userContentType: .audio, resourceReference: FileMediaReference.message(message: MessageReference(message), media: file).resourceReference(file.resource), streamable: .none, video: false, preferSoftwareDecoding: false, enableSound: true, fetchAutomatically: false, playAndRecord: true)
            self.replyPlayer = player
            player.actionAtEnd = .action { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.current == id else { return }
                    self.log("Native player ended \(id.id)")
                    self.replyStatus?.dispose(); self.replyStatus = nil
                    self.replyPlayer = nil
                    self.current = nil
                    self.playNext()
                }
            }
            self.replyStatus = (player.status |> deliverOnMainQueue).start(next: { [weak self] state in
                guard let self, self.current == id else { return }
                let status: String
                switch state.status {
                case .playing: status = "playing"
                case .paused: status = "paused"
                case .buffering: status = "buffering"
                }
                if status != self.lastPlayerStatus {
                    self.lastPlayerStatus = status
                    self.log("Native player \(id.id): \(status), time=\(state.timestamp), duration=\(state.duration)")
                }
            })
            if self.voiceSession?.recording != true { player.play() }
        }))
    }

    private func sendVoice(data: Data, duration: Double) {
        guard enabled, !walkChatFixtureEnabled else { log("Fixture voice capture completed; nothing sent"); return }
        let randomId = Int64.random(in: Int64.min ... Int64.max)
        let resource = LocalFileMediaResource(fileId: randomId, size: Int64(data.count))
        context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data)
        let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: randomId), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "audio/ogg", size: Int64(data.count), attributes: [.Audio(isVoice: true, duration: max(1, Int(duration)), title: nil, performer: nil, waveform: nil)], alternativeRepresentations: [])
        let message = EnqueueMessage.message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        sendDisposable.add((enqueueMessages(account: context.account, peerId: peerId, messages: [message]) |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.log("Voice reply queued for selected chat")
        }))
    }

    private func log(_ text: String) {
        events.append("\(ISO8601DateFormatter().string(from: Date())) \(text)")
        if events.count > 300 { events.removeFirst(events.count - 300) }
        NSLog("WalkChat: %@", text)
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? events.joined(separator: "\n").write(to: dir.appendingPathComponent("walk-chat-events.txt"), atomically: true, encoding: .utf8)
        }
    }
}

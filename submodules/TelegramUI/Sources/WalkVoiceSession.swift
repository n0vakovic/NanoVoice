import Foundation
import UIKit
import AVFoundation
import TelegramAudio
import TelegramCore
import SwiftSignalKit
import Postbox
import AccountContext
import OpusBinding

/// A user-started, muted communication session. The input device stays running while
/// waiting; only explicitly unmuted segments are encoded. Teardown retains unfinished recordings.
final class WalkVoiceSession {
    static let activeAccount = ValuePromise<AccountRecordId?>(nil, ignoreRepeated: true)
    private let context: AccountContext
    private var lease: Disposable?
    private var callObserver: Disposable?
    private var heartbeat: Foundation.Timer?
    private var engine: AVAudioEngine?
    private var volumeObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private let capture = WalkVoiceCapture()
    private var active = false
    private var installedTap = false
    private(set) var recording = false
    private var recordingStartPending = false
    private var recordingStartGeneration = 0
    // Set before start for controlled comparison with the system default.
    var minimizeReplyDucking = true
    var beforeRecording: ((@escaping () -> Void) -> Void)?
    var onInterruptedRecording: ((Data, Double) -> Void)?
    var onReady: (() -> Void)?
    var onRecording: ((Bool) -> Void)?
    var onMessage: ((Data, Double) -> Void)?
    var onError: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    init(context: AccountContext) { self.context = context }
    deinit { stop() }

    func start() {
        guard #available(iOS 17.0, *) else { onError?("Walk voice sessions require iOS 17 or later."); return }
        guard !context.sharedContext.immediateHasOngoingCall else { onError?("End the current call before starting Walk mode."); return }
        active = true
        callObserver = (context.sharedContext.hasOngoingCall.get() |> deliverOnMainQueue).start(next: { [weak self] ongoing in
            if ongoing { self?.fail("A call started; Walk mode stopped.") }
        })
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                guard granted else { self.fail("Microphone access is required. Enable it in iPhone Settings."); return }
                self.acquire()
            }
        }
    }

    private func acquire() {
        lease = context.sharedContext.mediaManager.audioSession.push(audioSessionType: .voiceCall, outputMode: .speakerIfNoHeadphones, manualActivate: { [weak self] control in
            control.setupAndActivate { state in
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    self.onLog?("Audio session acquired: headset=\(state.isHeadsetConnected)")
                    self.runEngine()
                }
            }
        }, deactivate: { [weak self] _ in
            DispatchQueue.main.async { self?.fail("Voice session interrupted. Start Walk mode again when ready.") }
            return .single(())
        })
    }

    private func runEngine() {
        guard #available(iOS 17.0, *), engine == nil else { return }
        do {
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            // Replies use a separate renderer, so minimize their attenuation by voice processing.
            // This is a mitigation to validate on device, not proof of the reported volume cause.
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: minimizeReplyDucking ? .min : .default)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw WalkVoiceError.inputUnavailable }
            try capture.configure(format: format)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [capture] buffer, _ in capture.append(buffer) }
            installedTap = true
            try AVAudioApplication.shared.setInputMuted(true)
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.active else { return }
                self.applyMuted(AVAudioApplication.shared.isInputMuted)
            })
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                self?.logAudioState("interruption type=\(note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0)")
                if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                    self?.fail("Voice session interrupted; check saved Walk drafts.")
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                self?.logAudioState("route change reason=\(note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0)")
                if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.fail("Headphones disconnected; Walk mode stopped.")
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.logAudioState("engine configuration changed")
                self?.fail("Audio route changed; restart Walk mode.")
            })
            volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    self.logAudioState("system volume changed")
                }
            }
            for (name, event) in [(UIApplication.didEnterBackgroundNotification, "entered background"), (UIApplication.willEnterForegroundNotification, "entered foreground")] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.logAudioState(event) })
            }
            engine.prepare()
            try engine.start()
            Self.activeAccount.set(context.account.id)
            heartbeat = Foundation.Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                guard let self, self.active else { return }
                self.logAudioState("heartbeat")
                if self.recording && self.capture.hasFailed { self.fail("Recording failed; the captured portion was kept as a Walk draft where possible.") }
            }
            logAudioState("ready")
            onReady?()
        } catch { fail("Unable to start voice session: \(error.localizedDescription)") }
    }

    func toggleRecording() {
        guard #available(iOS 17.0, *), active, engine?.isRunning == true else { return }
        do {
            let muted = recording || recordingStartPending
            try AVAudioApplication.shared.setInputMuted(muted)
            applyMuted(muted)
        } catch { fail("Unable to change microphone state.") }
    }

    private func applyMuted(_ muted: Bool) {
        guard active, engine?.isRunning == true else { return }
        if muted {
            let cancelledStart = recordingStartPending
            recordingStartPending = false
            recordingStartGeneration += 1
            guard recording else {
                if cancelledStart { onRecording?(false) }
                return
            }
            recording = false
            let message = capture.finish()
            let captureFailed = capture.hasFailed
            if captureFailed {
                if let (data, duration) = message, duration >= 0.5 { onInterruptedRecording?(data, duration) }
                fail("Recording failed; check saved Walk drafts for the captured portion.")
                return
            }
            onRecording?(false)
            if let (data, duration) = message, duration >= 0.5 {
                onLog?("Voice message captured: \(duration)s")
                onMessage?(data, duration)
            } else if message == nil {
                fail("Unable to finish the recording. Check saved Walk drafts.")
                return
            } else { onLog?("Short recording discarded") }
            logAudioState("recording ended")
        } else {
            guard !recording, !recordingStartPending else { return }
            recordingStartPending = true
            recordingStartGeneration += 1
            let generation = recordingStartGeneration
            let begin: () -> Void = { [weak self] in
                guard let self, self.active, self.recordingStartPending, self.recordingStartGeneration == generation, self.engine?.isRunning == true else { return }
                self.recordingStartPending = false
                guard self.capture.begin() else { self.fail("Unable to create voice message."); return }
                self.recording = true
                self.onRecording?(true)
                self.logAudioState("recording started")
            }
            if let beforeRecording { beforeRecording(begin) } else { begin() }
        }
    }

    func logAudioState(_ event: String) {
        let session = AVAudioSession.sharedInstance()
        var processing = "unavailable"
        if #available(iOS 17.0, *), let input = engine?.inputNode {
            let ducking = input.voiceProcessingOtherAudioDuckingConfiguration
            processing = "voiceProcessing=\(input.isVoiceProcessingEnabled) ducking=\(ducking.duckingLevel.rawValue) advancedDucking=\(ducking.enableAdvancedDucking) muted=\(AVAudioApplication.shared.isInputMuted)"
        }
        onLog?("Audio \(event): category=\(session.category.rawValue) mode=\(session.mode.rawValue) options=\(session.categoryOptions.rawValue) input=\(session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")) output=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")) volume=\(session.outputVolume) engine=\(engine?.isRunning == true) recording=\(recording) recordingStartPending=\(recordingStartPending) background=\(UIApplication.shared.applicationState != .active) \(processing)")
    }

    func stop() {
        guard active || lease != nil || engine != nil else { return }
        logAudioState("stopping")
        active = false
        recordingStartPending = false
        recordingStartGeneration += 1
        callObserver?.dispose(); callObserver = nil
        heartbeat?.invalidate(); heartbeat = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        volumeObservation = nil
        let wasRecording = recording
        recording = false
        if wasRecording {
            if let (data, duration) = capture.finish(), duration >= 0.5 {
                onInterruptedRecording?(data, duration)
                onLog?("Unfinished recording handed to draft recovery: \(duration)s")
            } else { onLog?("Unable to retain recording: no recoverable audio") }
        } else { capture.discard() }
        if installedTap { engine?.inputNode.removeTap(onBus: 0) }
        installedTap = false
        engine?.stop(); engine = nil
        if #available(iOS 17.0, *) { try? AVAudioApplication.shared.setInputMuted(false) }
        Self.activeAccount.set(nil)
        lease?.dispose(); lease = nil
    }

    private func fail(_ message: String) {
        guard active else { return }
        stop()
        onError?(message)
    }
}

private enum WalkVoiceError: Error { case inputUnavailable }

private final class WalkVoiceCapture {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false)!
    private var writer: TGOggOpusWriter?
    private var item: TGDataItem?
    private var pending = Data()
    private var failed = false

    var hasFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return failed
    }

    func configure(format input: AVAudioFormat) throws {
        lock.lock(); defer { lock.unlock() }
        guard let converter = AVAudioConverter(from: input, to: format) else { throw WalkVoiceError.inputUnavailable }
        self.converter = converter
    }
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let item = TGDataItem()
        let writer = TGOggOpusWriter()
        guard writer.begin(with: item) else { return false }
        self.item = item; self.writer = writer
        pending.removeAll(); failed = false
        converter?.reset()
        return true
    }
    func append(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let writer, let converter, !failed else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48000 / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { failed = true; return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard error == nil, status != .error, let samples = output.int16ChannelData else { failed = true; return }
        pending.append(Data(bytes: samples[0], count: Int(output.frameLength) * 2))
        while pending.count >= 1920 {
            var packet = Data(pending.prefix(1920))
            let ok = packet.withUnsafeMutableBytes { writer.writeFrame($0.baseAddress!.assumingMemoryBound(to: UInt8.self), frameByteCount: 1920) }
            if !ok { failed = true; return }
            pending.removeFirst(1920)
        }
    }
    func finish() -> (Data, Double)? {
        lock.lock(); defer { lock.unlock() }
        defer { writer = nil; item = nil; pending.removeAll() }
        guard let writer else { return nil }
        // A converter failure need not destroy already encoded audio. Finalize its prefix.
        if !pending.isEmpty && pending.count < 1920 {
            pending.append(Data(count: 1920 - pending.count))
            let ok = pending.withUnsafeMutableBytes { writer.writeFrame($0.baseAddress!.assumingMemoryBound(to: UInt8.self), frameByteCount: 1920) }
            if !ok { failed = true }
        }
        if !writer.writeFrame(nil, frameByteCount: 0) { failed = true }
        // Preserve encoded bytes even if finalization failed; callers must offer these
        // as a recovery draft, never automatically send a potentially truncated file.
        guard let data = item?.data(), !data.isEmpty else { return nil }
        return (data, writer.encodedDuration())
    }
    func discard() {
        lock.lock(); defer { lock.unlock() }
        writer = nil; item = nil; pending.removeAll()
    }
}

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
/// waiting; only explicitly unmuted segments are encoded, and teardown discards drafts.
final class WalkVoiceSession {
    static let activeAccount = ValuePromise<AccountRecordId?>(nil, ignoreRepeated: true)
    private let context: AccountContext
    private var lease: Disposable?
    private var callObserver: Disposable?
    private var heartbeat: Foundation.Timer?
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private let capture = WalkVoiceCapture()
    private var active = false
    private var installedTap = false
    private(set) var recording = false
    private var limit: DispatchWorkItem?
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
            control.setupAndActivate { _ in
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
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
                if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                    self?.fail("Voice session interrupted; unfinished recording discarded.")
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.fail("Headphones disconnected; Walk mode stopped.")
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.fail("Audio route changed; restart Walk mode.")
            })
            engine.prepare()
            try engine.start()
            Self.activeAccount.set(context.account.id)
            heartbeat = Foundation.Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                guard let self, self.active else { return }
                self.onLog?("Session heartbeat: engine=\(self.engine?.isRunning == true), background=\(UIApplication.shared.applicationState != .active), recording=\(self.recording)")
            }
            onLog?("Voice session active; input=\(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName).joined(separator: ",")); muted")
            onReady?()
        } catch { fail("Unable to start voice session: \(error.localizedDescription)") }
    }

    func toggleRecording() {
        guard #available(iOS 17.0, *), active, engine?.isRunning == true else { return }
        do {
            let muted = recording
            try AVAudioApplication.shared.setInputMuted(muted)
            applyMuted(muted)
        } catch { fail("Unable to change microphone state.") }
    }

    private func applyMuted(_ muted: Bool) {
        guard active, engine?.isRunning == true, recording == muted else { return }
        if muted {
            recording = false
            limit?.cancel(); limit = nil
            let message = capture.finish()
            onRecording?(false)
            if let (data, duration) = message, duration >= 0.5 {
                onLog?("Voice message captured: \(duration)s")
                onMessage?(data, duration)
            } else { onLog?("Short recording discarded") }
        } else {
            guard capture.begin() else { fail("Unable to create voice message."); return }
            recording = true
            onRecording?(true)
            onLog?("Voice recording started")
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.recording else { return }
                self.toggleRecording()
            }
            limit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
        }
    }

    func stop() {
        guard active || lease != nil || engine != nil else { return }
        active = false
        callObserver?.dispose(); callObserver = nil
        heartbeat?.invalidate(); heartbeat = nil
        limit?.cancel(); limit = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        capture.discard()
        recording = false
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
        guard let writer, !failed else { return nil }
        if !pending.isEmpty {
            pending.append(Data(count: 1920 - pending.count))
            let ok = pending.withUnsafeMutableBytes { writer.writeFrame($0.baseAddress!.assumingMemoryBound(to: UInt8.self), frameByteCount: 1920) }
            guard ok else { return nil }
        }
        guard writer.writeFrame(nil, frameByteCount: 0), let data = item?.data() else { return nil }
        return (data, writer.encodedDuration())
    }
    func discard() {
        lock.lock(); defer { lock.unlock() }
        writer = nil; item = nil; pending.removeAll()
    }
}

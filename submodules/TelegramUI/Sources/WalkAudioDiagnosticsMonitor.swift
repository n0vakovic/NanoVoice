import Foundation
import UIKit
import AVFoundation
import TelegramAudio

/// Does not own or activate an audio session. Continues observing ordinary playback
/// for ten minutes after Walk ends so the same-file comparison is captured.
final class WalkAudioDiagnosticsMonitor {
    static let shared = WalkAudioDiagnosticsMonitor()
    private var sessions = Set<UUID>()
    private var deadline: TimeInterval = 0
    private var timer: Foundation.Timer?
    private var volume: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private let processId = UUID().uuidString

    func begin(_ id: UUID) {
        guard NanoVoiceChats.enabled else { return }
        sessions.insert(id)
        deadline = 0
        NanoVoiceAudioDiagnostics.setExpiration(.infinity)
        if timer == nil {
            NanoVoiceAudioDiagnostics.setSink { [processId] event in
                WalkDiagnostics.log("AudioTrace[\(processId)] \(event)")
            }
            let session = AVAudioSession.sharedInstance()
            volume = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
                let old = change.oldValue ?? -1
                let new = change.newValue ?? -1
                DispatchQueue.main.async { self?.snapshot("volume old=\(old) new=\(new)") }
            }
            for (name, label) in [
                (AVAudioSession.routeChangeNotification, "route"),
                (AVAudioSession.interruptionNotification, "interruption"),
                (AVAudioSession.mediaServicesWereResetNotification, "media-services-reset"),
                (AVAudioSession.mediaServicesWereLostNotification, "media-services-lost"),
                (UIApplication.didEnterBackgroundNotification, "background"),
                (UIApplication.didBecomeActiveNotification, "foreground")
            ] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                    let interruption = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
                    let previous = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?.outputs.map { $0.portType.rawValue }.joined(separator: ",") ?? "none"
                    self?.snapshot("\(label) reason=\(reason) interruption=\(interruption) previousOutput=\(previous)")
                })
            }
            timer = Foundation.Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.snapshot("heartbeat")
            }
            WalkDiagnostics.log("AudioTrace schema=2 process=\(processId) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") os=\(UIDevice.current.systemVersion)")
        }
        snapshot("walk begin id=\(id)")
    }

    func end(_ id: UUID) {
        guard sessions.remove(id) != nil else { return }
        if sessions.isEmpty {
            deadline = ProcessInfo.processInfo.systemUptime + 600
            NanoVoiceAudioDiagnostics.setExpiration(deadline)
        }
        snapshot("walk ended id=\(id); comparison window=600s")
        for delay in [0.25, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.snapshot("post-stop +\(delay)s")
            }
        }
    }

    func markQuiet() {
        WalkDiagnostics.log("USER MARKED AUDIO TOO QUIET traceActive=\(NanoVoiceAudioDiagnostics.enabled)")
        snapshot("USER MARKED AUDIO TOO QUIET")
    }

    private func snapshot(_ event: String) {
        guard timer != nil else { return }
        if sessions.isEmpty && ProcessInfo.processInfo.systemUptime >= deadline {
            WalkDiagnostics.log("AudioTrace comparison window ended")
            timer?.invalidate(); timer = nil
            volume = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            NanoVoiceAudioDiagnostics.setSink(nil)
            return
        }
        let s = AVAudioSession.sharedInstance()
        NanoVoiceAudioDiagnostics.emit("Session \(event) uptime=\(ProcessInfo.processInfo.systemUptime) activeWalks=\(sessions.count) category=\(s.category.rawValue) mode=\(s.mode.rawValue) options=\(s.categoryOptions.rawValue) input=\(s.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")) output=\(s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")) preferredInput=\(s.preferredInput?.portType.rawValue ?? "none") volume=\(s.outputVolume) sampleRate=\(s.sampleRate) buffer=\(s.ioBufferDuration) inputLatency=\(s.inputLatency) outputLatency=\(s.outputLatency) inputChannels=\(s.inputNumberOfChannels) outputChannels=\(s.outputNumberOfChannels) otherAudio=\(s.isOtherAudioPlaying) secondarySilenced=\(s.secondaryAudioShouldBeSilencedHint) background=\(UIApplication.shared.applicationState != .active)")
    }
}

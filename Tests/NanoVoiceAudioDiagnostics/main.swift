import Foundation
var events: [String] = []
NanoVoiceAudioDiagnostics.setExpiration(.infinity)
NanoVoiceAudioDiagnostics.setSink { value in
    // Reading the gate from a sink must not deadlock.
    assert(NanoVoiceAudioDiagnostics.enabled)
    events.append(value)
}
NanoVoiceAudioDiagnostics.emit("active")
NanoVoiceAudioDiagnostics.setExpiration(ProcessInfo.processInfo.systemUptime - 1)
assert(!NanoVoiceAudioDiagnostics.enabled)
NanoVoiceAudioDiagnostics.emit("expired")
assert(events == ["active"])
NanoVoiceAudioDiagnostics.setExpiration(.infinity)
NanoVoiceAudioDiagnostics.emit("restarted")
NanoVoiceAudioDiagnostics.setSink(nil)
NanoVoiceAudioDiagnostics.emit("disabled")
assert(events == ["active", "restarted"])
let empty = nanoVoicePCMLevels(Data())
assert(empty.samples == 0 && empty.rmsDBFS == -120)
let silence = nanoVoicePCMLevels(Data(repeating: 0, count: 100))
assert(silence.samples == 50 && silence.peakDBFS == -120)
// +0.5 and -0.5 full scale must have identical magnitude. Ignore trailing byte.
let half = nanoVoicePCMLevels(Data([0, 64, 0, 192, 255]))
assert(half.samples == 2 && abs(half.rmsDBFS + 6.0206) < 0.001)
assert(abs(half.peakDBFS + 6.0206) < 0.001)
let negativeFullScale = nanoVoicePCMLevels(Data([0, 128]))
assert(negativeFullScale.peakDBFS == 0)
assert(nanoVoicePCMLevels(Data(repeating: 0, count: 20000)).samples == 4096)
print("PASS: diagnostic gate expiration/restart/reentrancy and bounded signed PCM measurements")

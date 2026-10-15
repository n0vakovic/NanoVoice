for rate in [16000.0, 24000.0, 44100.0, 48000.0] {
    for channels: AVAudioChannelCount in [1, 2] {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let capture = WalkVoiceCapture()
        try capture.configure(format: inputFormat)
        assert(capture.finish() == nil)
        assert(capture.begin())
        let frames = Int(rate / 50)
        for chunk in 0..<150 {
            let b = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))!
            b.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<Int(channels) {
                for i in 0..<frames { b.floatChannelData![channel][i] = Float(sin(Double(chunk * frames + i) * 440 * 2 * .pi / rate)) * 0.2 }
            }
            capture.append(b)
        }
        guard let (data, duration) = capture.finish() else { fatalError("No encoded audio") }
        assert(abs(duration - 3.0) < 0.08, "Sample-rate conversion changed duration")
        assert(data.prefix(4) == Data("OggS".utf8))
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        assert(capture.finish() == nil)
        assert(capture.begin())
        capture.discard()
        assert(capture.finish() == nil)
        print("PASS: \(rate) Hz, \(channels) channels → \(duration)s Opus; idle/discard produce no message")
    }
}

// Exercise the production encoder beyond the former five-minute session cutoff.
do {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    let capture = WalkVoiceCapture()
    try capture.configure(format: format)
    assert(capture.begin())
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
    buffer.frameLength = 960
    for i in 0..<960 { buffer.floatChannelData![0][i] = 0.1 * Float(sin(Double(i) * 440 * 2 * .pi / 48000)) }
    for _ in 0..<15100 { capture.append(buffer) }
    guard let (data, duration) = capture.finish() else { fatalError("Long capture lost") }
    assert(!capture.hasFailed)
    assert(abs(duration - 302.0) < 0.08, "Long recording was truncated")
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("PASS: 302-second production capture is retained in full")
}

// A failed converter must not destroy the valid encoded prefix. The test lives
// in the capture source's file so fault injection does not require a shipping API.
private extension WalkVoiceCapture {
    func simulateConversionFailure() {
        lock.lock(); defer { lock.unlock() }
        failed = true
    }
}
do {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    let capture = WalkVoiceCapture()
    try capture.configure(format: format)
    assert(capture.begin())
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
    buffer.frameLength = 960
    for i in 0..<960 { buffer.floatChannelData![0][i] = 0 }
    for _ in 0..<100 { capture.append(buffer) }
    capture.simulateConversionFailure()
    capture.append(buffer)
    guard let (data, duration) = capture.finish() else { fatalError("Encoded prefix lost after conversion failure") }
    assert(capture.hasFailed, "Caller needs failure state to save a draft instead of auto sending")
    assert(abs(duration - 2.0) < 0.08)
    assert(data.prefix(4) == Data("OggS".utf8))
    assert(capture.finish() == nil)
    assert(capture.begin())
    assert(!capture.hasFailed)
    capture.discard()
    print("PASS: converter failure preserves encoded prefix and remains flagged until next recording")
}

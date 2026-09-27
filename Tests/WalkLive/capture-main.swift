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

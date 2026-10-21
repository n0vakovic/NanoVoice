import Foundation

/// Opt-in bridge into NanoVoice's bounded diagnostics store. No file/audio data or
/// peer/device identifiers may be passed here. Never call from an audio render callback.
public enum NanoVoiceAudioDiagnostics {
    private static let lock = NSLock()
    private static var expiration = TimeInterval.infinity
    private static var sink: ((String) -> Void)?

    public static var enabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sink != nil && ProcessInfo.processInfo.systemUptime < expiration
    }

    public static func setSink(_ value: ((String) -> Void)?) {
        lock.lock()
        sink = value
        lock.unlock()
    }

    public static func setExpiration(_ value: TimeInterval) {
        lock.lock()
        expiration = value
        lock.unlock()
    }

    public static func emit(_ event: @autoclosure () -> String) {
        lock.lock()
        let target = ProcessInfo.processInfo.systemUptime < expiration ? sink : nil
        lock.unlock()
        target?(event())
    }
}

/// Sparse decoded-PCM measurements, before mixer/EQ/system processing. Input is
/// the renderer's fixed little-endian signed 16-bit interleaved format.
public func nanoVoicePCMLevels(_ data: Data) -> (samples: Int, rmsDBFS: Double, peakDBFS: Double) {
    var sum = 0.0
    var peak = 0.0
    var count = 0
    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        for offset in stride(from: 0, to: min(data.count - data.count % 2, 8192), by: 2) {
            let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let sample = Double(Int16(bitPattern: bits)) / 32768.0
            sum += sample * sample
            peak = max(peak, abs(sample))
            count += 1
        }
    }
    let rms = count == 0 ? 0 : sqrt(sum / Double(count))
    return (count, 20 * log10(max(rms, 0.000001)), 20 * log10(max(peak, 0.000001)))
}

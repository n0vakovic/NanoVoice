import Foundation

/// Session-scoped delivery filtering, separate from history rendering and download/playback.
final class WalkReplyGate {
    private var selectedPeer: Int64?
    private var startedAt: Int32 = 0
    private var seen = Set<String>()
    func start(peer: Int64, timestamp: Int32) {
        selectedPeer = peer
        startedAt = timestamp
        seen.removeAll()
    }
    func stop() { selectedPeer = nil; seen.removeAll() }
    func accept(peer: Int64, id: String, timestamp: Int32, now: Int32, incoming: Bool, audio: Bool) -> Bool {
        guard selectedPeer == peer, incoming, audio, timestamp >= startedAt,
              !seen.contains(id) else { return false }
        seen.insert(id)
        return true
    }
}

/// Uses observed decoder progress, never a total-duration cap; suspend while recording.
struct WalkPlaybackProgress {
    private(set) var position: Double = 0
    private var lastProgress: Double = 0
    mutating func reset(now: Double, position: Double = 0) {
        self.position = position
        lastProgress = now
    }
    mutating func observe(position: Double, now: Double) {
        if position > self.position + 0.01 { lastProgress = now }
        self.position = position
    }
    mutating func stalled(now: Double, suspended: Bool) -> Bool {
        if suspended { lastProgress = now; return false }
        return now - lastProgress >= 30
    }
    static func resumePosition(_ position: Double) -> Double? {
        return position > 0 ? max(0, position - 5) : nil
    }
    static func retryDelay(failureCount: Int) -> Double? {
        switch failureCount {
        case 1: return 5
        case 2: return 15
        default: return nil
        }
    }
}

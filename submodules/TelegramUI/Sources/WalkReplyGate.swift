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
              Int64(now) - Int64(timestamp) <= 90, !seen.contains(id) else { return false }
        seen.insert(id)
        return true
    }
}

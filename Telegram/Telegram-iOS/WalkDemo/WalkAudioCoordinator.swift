import Foundation

struct WalkAudioMessage: Equatable {
    let id: String
    let chatID: String
    let fileURL: URL
}

/// The transport adapter supplies newly received, downloaded audio here.
/// History loading must use isNew: false. All calls belong on the main thread.
final class WalkAudioCoordinator {
    enum State: String { case off, waiting, playing, paused }
    private(set) var state: State = .off
    private(set) var chatID: String?
    private(set) var current: WalkAudioMessage?
    private(set) var queue: [WalkAudioMessage] = []
    private var seen: Set<String> = []
    var onChange: (() -> Void)?
    var onPlay: ((WalkAudioMessage) -> Void)?
    var onStop: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?

    func start(chatID: String) {
        end()
        self.chatID = chatID
        state = .waiting
        onChange?()
    }

    func receive(_ message: WalkAudioMessage, isNew: Bool) {
        let key = message.chatID + ":" + message.id
        guard seen.insert(key).inserted else { return }
        guard isNew, state != .off, message.chatID == chatID else { return }
        queue.append(message)
        if state == .waiting { playNext() } else { onChange?() }
    }

    func pauseOrResume() {
        if state == .playing {
            state = .paused
            onPause?()
        } else if state == .paused {
            state = .playing
            onResume?()
        }
        onChange?()
    }

    func finished(messageID: String) {
        guard current?.id == messageID, state == .playing else { return }
        current = nil
        playNext()
    }

    func failed(messageID: String) {
        guard current?.id == messageID else { return }
        current = nil
        playNext()
    }

    func end() {
        state = .off
        chatID = nil
        queue.removeAll()
        current = nil
        onStop?()
        onChange?()
    }

    private func playNext() {
        if queue.isEmpty {
            state = .waiting
            onChange?()
            return
        }
        current = queue.removeFirst()
        state = .playing
        onChange?()
        if let current { onPlay?(current) }
    }
}

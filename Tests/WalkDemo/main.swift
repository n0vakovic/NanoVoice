import Foundation

let coordinator = WalkAudioCoordinator()
let url = URL(fileURLWithPath: "/fixture.aiff")
func message(_ id: String, _ chat: String = "russ") -> WalkAudioMessage {
    WalkAudioMessage(id: id, chatID: chat, fileURL: url)
}
var played: [String] = []
var stopped = 0
var pauses = 0
var resumes = 0
coordinator.onPlay = { played.append($0.id) }
coordinator.onStop = { stopped += 1 }
coordinator.onPause = { pauses += 1 }
coordinator.onResume = { resumes += 1 }

coordinator.receive(message("before-session"), isNew: true)
coordinator.start(chatID: "russ")
coordinator.receive(message("before-session"), isNew: true)
coordinator.receive(message("history"), isNew: false)
coordinator.receive(message("history"), isNew: true)
coordinator.receive(message("other", "emma"), isNew: true)
assert(played.isEmpty, "Old, duplicate and wrong-chat events must stay silent")

coordinator.receive(message("a"), isNew: true)
coordinator.receive(message("a"), isNew: true)
coordinator.receive(message("b"), isNew: true)
assert(played == ["a"] && coordinator.queue.map(\.id) == ["b"])
coordinator.pauseOrResume()
coordinator.receive(message("c"), isNew: true)
coordinator.finished(messageID: "a")
assert(coordinator.state == .paused && played == ["a"] && pauses == 1)
coordinator.pauseOrResume()
assert(resumes == 1)
coordinator.finished(messageID: "stale-callback")
assert(played == ["a"])
coordinator.finished(messageID: "a")
assert(played == ["a", "b"])
coordinator.failed(messageID: "b")
assert(played == ["a", "b", "c"], "Failure must not wedge the queue")
coordinator.finished(messageID: "c")
assert(coordinator.state == .waiting && coordinator.current == nil)

coordinator.receive(message("d"), isNew: true)
coordinator.receive(message("e"), isNew: true)
coordinator.end()
coordinator.finished(messageID: "d")
assert(coordinator.state == .off && coordinator.queue.isEmpty && coordinator.current == nil)
assert(!played.contains("e"), "Ending a session must discard queued audio")
coordinator.start(chatID: "emma")
coordinator.receive(message("other", "emma"), isNew: true)
assert(coordinator.state == .waiting, "Switching chats must not replay previously observed messages")
coordinator.receive(message("a", "emma"), isNew: true)
assert(coordinator.current?.chatID == "emma", "Message IDs are scoped by chat")
assert(stopped >= 3)
print("PASS: history, disabled mode, chat scoping, duplicate suppression, FIFO, pause/resume, stale callbacks, playback failure, session cancellation")

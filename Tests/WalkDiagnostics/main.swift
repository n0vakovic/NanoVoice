import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("walk-diagnostics-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let first = WalkDiagnosticStore(directory: root, maximumBytes: 1024)
first.append("session-A recording started")
first.append("session-A route changed")
let initial = try String(contentsOf: first.export(), encoding: .utf8)
assert(initial.contains("recording started") && initial.contains("route changed"))

// A new instance represents another launch: existing history must survive.
let restarted = WalkDiagnosticStore(directory: root, maximumBytes: 1024)
restarted.append("session-B playing")
let restored = try String(contentsOf: restarted.export(), encoding: .utf8)
assert(restored.contains("session-A") && restored.contains("session-B"))

for index in 0..<80 { restarted.append("event-\(index) " + String(repeating: "x", count: 100)) }
let rotated = try String(contentsOf: restarted.export(), encoding: .utf8)
assert(rotated.contains("event-79"))
assert(!rotated.contains("event-0 "))
let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
assert(files.count == 4, "Three log segments plus one bounded export")
for file in files where file.lastPathComponent.hasPrefix("events-") {
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    assert(size <= 1024)
}
restarted.append(String(repeating: "🐕", count: 10000))
_ = try restarted.export()
let size = try root.appendingPathComponent("events-0.txt").resourceValues(forKeys: [.fileSizeKey]).fileSize!
assert(size <= 1024)
// One grapheme can contain thousands of scalars; bounds must count bytes.
restarted.append("a" + String(repeating: "\u{0301}", count: 10000))
_ = try restarted.export()
let combiningSize = try root.appendingPathComponent("events-0.txt").resourceValues(forKeys: [.fileSizeKey]).fileSize!
assert(combiningSize <= 1024)
// An unwritable destination is handled without crashing or silently exporting success.
let blocked = root.appendingPathComponent("not-a-directory")
try Data().write(to: blocked)
let broken = WalkDiagnosticStore(directory: blocked)
broken.append("must not crash")
do { _ = try broken.export(); assertionFailure("Export must surface an I/O error") } catch {}
print("PASS: diagnostics persist across instances, flush for export, rotate, and bound Unicode event/storage size")

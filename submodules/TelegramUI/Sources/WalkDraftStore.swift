import Foundation

/// One atomic file per unsent recording. Never evicts an unsent draft automatically.
final class WalkDraftStore {
    struct Draft: Codable {
        let id: UUID
        let createdAt: Date
        let duration: Double
        let audio: Data
    }
    // Emergency process-lifetime fallback only; explicitly not durable storage.
    private static var sending: Set<UUID> = []
    func beginSending(_ id: UUID) -> Bool { Self.sending.insert(id).inserted }
    func finishSending(_ id: UUID) { Self.sending.remove(id) }
    func isSending(_ id: UUID) -> Bool { Self.sending.contains(id) }
    private static var emergency: [String: [(Data, Double)]] = [:]
    private let directory: URL
    var unsaved: [(Data, Double)] { Self.emergency[directory.path] ?? [] }
    func retainUnsaved(data: Data, duration: Double) {
        Self.emergency[directory.path, default: []].append((data, duration))
    }
    func removeFirstUnsaved() {
        Self.emergency[directory.path]?.removeFirst()
        if Self.emergency[directory.path]?.isEmpty == true { Self.emergency.removeValue(forKey: directory.path) }
    }
    init(account: Int64, peer: Int64, root: URL? = nil) {
        let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = root.appendingPathComponent("WalkDrafts", isDirectory: true)
            .appendingPathComponent("\(account)", isDirectory: true)
            .appendingPathComponent("\(peer)", isDirectory: true)
    }
    @discardableResult func save(data: Data, duration: Double) throws -> Draft {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
        let draft = Draft(id: UUID(), createdAt: Date(), duration: duration, audio: data)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(draft)
        #if os(iOS)
        try encoded.write(to: url(draft.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try encoded.write(to: url(draft.id), options: .atomic)
        #endif
        return draft
    }
    func hasDrafts() throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).contains { $0.pathExtension == "plist" }
    }
    struct Listing {
        let drafts: [Draft]
        let unreadableCount: Int
    }
    func listing() throws -> Listing {
        guard FileManager.default.fileExists(atPath: directory.path) else { return Listing(drafts: [], unreadableCount: 0) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "plist" }
        var drafts: [Draft] = []
        var unreadableCount = 0
        for file in files {
            do { drafts.append(try PropertyListDecoder().decode(Draft.self, from: Data(contentsOf: file))) }
            catch { unreadableCount += 1 }
        }
        return Listing(drafts: drafts.sorted { $0.createdAt < $1.createdAt }, unreadableCount: unreadableCount)
    }
    func drafts() throws -> [Draft] { try listing().drafts }
    func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: url(id)) }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("plist") }
}

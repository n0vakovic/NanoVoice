import Foundation

/// Versioned, account-scoped favorites. Legacy bindings remain intact for rollback.
struct NanoVoiceAgent: Codable, Equatable {
    var id: String
    var peerId: Int64?
    var name: String?
}

enum NanoVoiceAgentStore {
    static func key(_ account: Int64) -> String { "nanovoice.agents.v1.\(account)" }
    static func load(account: Int64, defaults: UserDefaults = .standard) -> [NanoVoiceAgent] {
        if let data = defaults.data(forKey: key(account)), let entries = try? JSONDecoder().decode([NanoVoiceAgent].self, from: data) {
            return entries
        }
        let titles = ["Dam Rass", "Eating, Moving, Alivening"]
        let entries = titles.enumerated().map { index, title in
            NanoVoiceAgent(id: UUID().uuidString, peerId: defaults.string(forKey: "nanovoice.chat.\(account).\(index)").flatMap(Int64.init), name: title)
        }
        save(entries, account: account, defaults: defaults)
        return entries
    }
    static func save(_ entries: [NanoVoiceAgent], account: Int64, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key(account))
    }
}

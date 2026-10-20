import Foundation
let suite = "NanoVoiceAgentTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
defaults.set("123", forKey: "nanovoice.chat.42.0")
defaults.set("456", forKey: "nanovoice.chat.42.1")
var agents = NanoVoiceAgentStore.load(account: 42, defaults: defaults)
assert(agents.map(\.peerId) == [123, 456])
let original = agents
assert(NanoVoiceAgentStore.load(account: 42, defaults: defaults) == agents)
agents.reverse()
agents[0].name = "EMA"
agents.append(NanoVoiceAgent(id: "third", peerId: 789, name: nil))
NanoVoiceAgentStore.save(agents, account: 42, defaults: defaults)
assert(NanoVoiceAgentStore.load(account: 42, defaults: defaults) == agents)
assert(NanoVoiceAgentStore.load(account: 99, defaults: defaults).allSatisfy { $0.peerId == nil })
NanoVoiceAgentStore.save([], account: 42, defaults: defaults)
assert(NanoVoiceAgentStore.load(account: 42, defaults: defaults).isEmpty)
assert(defaults.string(forKey: "nanovoice.chat.42.0") == "123")
assert(original[0].name == "Dam Rass")
print("PASS: legacy migration, stable IDs, names/order, account isolation, intentional empty list, rollback bindings")

import UIKit
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import PresentationDataUtils
import AccountContext

import AvatarNode
import TelegramStringFormatting

enum NanoVoiceChats {
    static var enabled: Bool { Bundle.main.bundleIdentifier == "local.milan.NanoVoice" && !walkChatFixtureEnabled }
    /// Stable IDs survive title changes. Only writable cloud conversations can be agent slots.
    static func isEligible(_ peer: Peer, account: PeerId) -> Bool {
        guard peer.id != account, !peer.isDeleted, canSendMessagesToPeer(EnginePeer(peer)) else { return false }
        if let user = peer as? TelegramUser { return user.botInfo != nil }
        if let group = peer as? TelegramGroup { return group.membership == .Member && group.migrationReference == nil }
        if let channel = peer as? TelegramChannel, case .group = channel.info {
            return channel.participationStatus == .member
        }
        return false
    }
    static func contains(_ peer: PeerId, account: PeerId) -> Bool {
        NanoVoiceAgentStore.load(account: account.toInt64()).contains { $0.peerId == peer.toInt64() }
    }
}

private final class NanoVoiceAgentCell: UITableViewCell {
    let avatar = AvatarNode(font: avatarPlaceholderFont(size: 20.0))
    let nameLabel = UILabel()
    let previewLabel = UILabel()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(avatar.view)
        contentView.addSubview(nameLabel)
        contentView.addSubview(previewLabel)
        nameLabel.font = .preferredFont(forTextStyle: .headline)
        previewLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewLabel.textColor = .secondaryLabel
        nameLabel.adjustsFontForContentSizeCategory = true
        previewLabel.adjustsFontForContentSizeCategory = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        avatar.frame = CGRect(x: 16, y: (contentView.bounds.height - 48) / 2, width: 48, height: 48)
        let width = max(0, contentView.bounds.width - 92)
        nameLabel.frame = CGRect(x: 76, y: 16, width: width, height: 25)
        previewLabel.frame = CGRect(x: 76, y: 43, width: width, height: 23)
    }
}

/// Local favorites, independent of Telegram's server-side folders and chat names.
final class NanoVoiceHomeController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let openChat: (PeerId) -> Void
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var agents: [NanoVoiceAgent]
    private var peers: [Int64: Peer] = [:]
    private var previews: [Int64: String] = [:]
    private var subscriptions: [Disposable] = []

    init(context: AccountContext, openChat: @escaping (PeerId) -> Void) {
        self.context = context
        self.openChat = openChat
        self.agents = NanoVoiceAgentStore.load(account: context.account.peerId.toInt64())
        let data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationTheme: data.theme, presentationStrings: data.strings))
        self.title = "My Agents"
        self.statusBar.statusBarStyle = data.theme.rootController.statusBarStyle.style
        updateButtons()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { subscriptions.forEach { $0.dispose() } }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = .systemGroupedBackground
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 82
        table.allowsSelectionDuringEditing = true
        table.register(NanoVoiceAgentCell.self, forCellReuseIdentifier: "agent")
        self.displayNode.view.addSubview(table)
        observeChats()
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        table.frame = CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top)
    }
    private func updateButtons() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: table.isEditing ? "Done" : "Edit", style: .plain, target: self, action: #selector(toggleEditing))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Add", style: .plain, target: self, action: #selector(addAgent))
    }
    @objc private func toggleEditing() {
        table.setEditing(!table.isEditing, animated: true)
        updateButtons()
        table.reloadData()
    }
    @objc private func addAgent() { selectChat(replacing: nil) }
    private func save(reobserve: Bool = false) {
        NanoVoiceAgentStore.save(agents, account: context.account.peerId.toInt64())
        if reobserve { observeChats() }
        table.reloadData()
    }
    private func observeChats() {
        subscriptions.forEach { $0.dispose() }
        subscriptions.removeAll()
        for id in Set(agents.compactMap(\.peerId)) {
            let peerId = PeerId(id)
            subscriptions.append((context.account.postbox.peerView(id: peerId) |> deliverOnMainQueue).start(next: { [weak self] view in
                guard let self else { return }
                self.peers[id] = view.peers[peerId]
                if !self.table.isEditing { self.table.reloadData() }
            }))
            // Postbox requires count >= 2 (HistoryViewLoadedState halfLimit = count + 1 >= 3).
            // Observe a small valid window, then display only its newest message.
            let history = context.account.postbox.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: nil), anchor: .upperBound, ignoreMessagesInTimestampRange: nil, ignoreMessageIds: Set(), count: 10, fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: Set(), tag: nil, appendMessagesFromTheSameGroup: false, namespaces: .not(Namespaces.Message.allNonRegular), orderStatistics: [])
            subscriptions.append((history |> deliverOnMainQueue).start(next: { [weak self] view, _, _ in
                guard let self else { return }
                let data = self.context.sharedContext.currentPresentationData.with { $0 }
                self.previews[id] = view.entries.last.map {
                    descriptionStringForMessage(contentSettings: self.context.currentContentSettings.with { $0 }, message: EngineMessage($0.message), strings: data.strings, nameDisplayOrder: data.nameDisplayOrder, dateTimeFormat: data.dateTimeFormat, accountPeerId: self.context.account.peerId).0.string
                }
                if !self.table.isEditing { self.table.reloadData() }
            }))
        }
    }
    private func name(_ agent: NanoVoiceAgent) -> String {
        agent.name ?? agent.peerId.flatMap { peers[$0]?.debugDisplayTitle } ?? "Agent"
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { agents.count }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if agents.isEmpty { return "Tap + to add an existing bot or group conversation." }
        return table.isEditing ? "Drag to reorder. Tap an agent to rename it. Removing an agent keeps its Telegram conversation." : nil
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let agent = agents[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "agent", for: indexPath) as! NanoVoiceAgentCell
        let peer = agent.peerId.flatMap { peers[$0] }
        cell.nameLabel.text = name(agent)
        if let peer, NanoVoiceChats.isEligible(peer, account: context.account.peerId) {
            cell.previewLabel.text = agent.peerId.flatMap { previews[$0] } ?? "Open conversation"
        } else {
            cell.previewLabel.text = "Chat unavailable — tap to choose"
        }
        cell.avatar.setPeer(context: context, theme: context.sharedContext.currentPresentationData.with { $0.theme }, peer: peer.map(EnginePeer.init), displayDimensions: CGSize(width: 48, height: 48))
        if peer == nil { cell.avatar.setCustomLetters([String(name(agent).prefix(1))]) }
        cell.accessibilityLabel = "\(name(agent)), \(cell.previewLabel.text ?? "")"
        cell.accessoryType = .disclosureIndicator
        cell.showsReorderControl = true
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let agent = agents[indexPath.row]
        if table.isEditing { editName(agent.id) }
        else if let id = agent.peerId, let peer = peers[id], NanoVoiceChats.isEligible(peer, account: context.account.peerId) { openChat(PeerId(id)) }
        else { selectChat(replacing: agent.id) }
    }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }
    func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let agent = agents.remove(at: source.row)
        agents.insert(agent, at: destination.row)
        NanoVoiceAgentStore.save(agents, account: context.account.peerId.toInt64())
    }
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let agent = agents[indexPath.row]
        let active = agent.peerId.map { WalkChatControls.isActive(account: context.account.peerId, peer: PeerId($0)) } ?? false
        let alert = UIAlertController(title: "Remove \(name(agent))?", message: "The Telegram conversation and messages will remain." + (active ? " This will end its Walk mode session." : ""), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: active ? "End Walk mode and remove" : "Remove", style: .destructive, handler: { [weak self] _ in
            guard let self else { return }
            if let id = agent.peerId { WalkChatControls.stopActive(account: self.context.account.peerId, peer: PeerId(id)) }
            self.agents.removeAll { $0.id == agent.id }
            self.save(reobserve: true)
        }))
        show(alert)
    }
    private func show(_ alert: UIAlertController, from window: UIWindow? = nil) {
        var presenter = (window ?? view.window)?.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }
        presenter?.present(alert, animated: true)
    }
    private func editName(_ id: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }
        let alert = UIAlertController(title: "Agent name", message: "Only changes the name in NanoVoice. Leave blank to use the Telegram name.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = agent.name
            field.placeholder = agent.peerId.flatMap { self.peers[$0]?.debugDisplayTitle } ?? "Telegram name"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let index = self.agents.firstIndex(where: { $0.id == id }) else { return }
            let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.agents[index].name = value.isEmpty ? nil : value
            self.save()
        }))
        show(alert)
    }
    private func selectChat(replacing: String?) {
        let excluded = Set(agents.filter { $0.id != replacing }.compactMap { $0.peerId.map(PeerId.init) })
        let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(
            context: context,
            filter: [.onlyWriteable, .excludeDisabled, .excludeSecretChats, .excludeChannels, .excludeSavedMessages, .excludeRecent, .doNotSearchMessages],
            hasContactSelector: false, hasGlobalSearch: false, title: "Add agent conversation", excludedPeerIds: excluded
        ))
        controller.peerSelected = { [weak self, weak controller] peer, _ in
            guard let self else { return }
            guard NanoVoiceChats.isEligible(peer._asPeer(), account: self.context.account.peerId), !self.agents.contains(where: { $0.id != replacing && $0.peerId == peer.id.toInt64() }) else {
                controller?.present(textAlertController(context: self.context, title: "Choose an agent conversation", text: "Select a bot or a group you can write to. Already-added chats cannot be added again.", actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]), in: .window(.root))
                return
            }
            let alert = UIAlertController(title: replacing == nil ? "Add agent" : "Choose conversation", message: "Give this agent an optional name in NanoVoice.", preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = peer._asPeer().debugDisplayTitle
                field.text = self.agents.first(where: { $0.id == replacing })?.name
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: replacing == nil ? "Add" : "Save", style: .default, handler: { [weak self, weak controller, weak alert] _ in
                guard let self else { return }
                let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = value.isEmpty ? nil : value
                if let replacing, let index = self.agents.firstIndex(where: { $0.id == replacing }) {
                    self.agents[index].peerId = peer.id.toInt64()
                    self.agents[index].name = name
                } else {
                    guard !self.agents.contains(where: { $0.peerId == peer.id.toInt64() }) else { return }
                    self.agents.append(NanoVoiceAgent(id: UUID().uuidString, peerId: peer.id.toInt64(), name: name))
                }
                self.peers[peer.id.toInt64()] = peer._asPeer()
                self.save(reobserve: true)
                controller?.dismiss()
            }))
            self.show(alert, from: controller?.view.window)
        }
        push(controller)
    }
}

import UIKit
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import PresentationDataUtils
import AccountContext

enum NanoVoiceChats {
    static var enabled: Bool { Bundle.main.bundleIdentifier == "local.milan.NanoVoice" && !walkChatFixtureEnabled }
    static let titles = ["Dam Rass", "Eating, Moving, Alivening"]
    static func key(_ account: PeerId, _ index: Int) -> String { "nanovoice.chat.\(account.toInt64()).\(index)" }
    static func peer(_ account: PeerId, _ index: Int) -> PeerId? {
        guard let value = UserDefaults.standard.string(forKey: key(account, index)), let id = Int64(value) else { return nil }
        return PeerId(id)
    }
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
        return titles.indices.contains { self.peer(account, $0) == peer }
    }
    static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// A local, two-chat launcher. It does not change Telegram's server-side folders.
final class NanoVoiceHomeController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let openChat: (PeerId) -> Void
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var peers: [PeerId?] = [nil, nil]
    private var statuses = ["Finding chat…", "Finding chat…"]
    private var lookup: Disposable?

    init(context: AccountContext, openChat: @escaping (PeerId) -> Void) {
        self.context = context
        self.openChat = openChat
        let data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationTheme: data.theme, presentationStrings: data.strings))
        self.title = "NanoVoice"
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(refresh))
        self.statusBar.statusBarStyle = data.theme.rootController.statusBarStyle.style
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { lookup?.dispose() }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = .systemGroupedBackground
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 82
        self.displayNode.view.addSubview(table)
        refresh()
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        table.frame = CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top)
    }
    @objc private func refresh() {
        let saved = NanoVoiceChats.titles.indices.map { NanoVoiceChats.peer(context.account.peerId, $0) }
        peers = [nil, nil]
        statuses = ["Checking chat…", "Checking chat…"]
        table.reloadData()
        let signals = NanoVoiceChats.titles.map { title in
            context.account.postbox.searchPeers(query: NanoVoiceChats.normalized(title).components(separatedBy: " ").first ?? title)
        }
        let cached = context.account.postbox.transaction { transaction -> [PeerId: Peer] in
            var result: [PeerId: Peer] = [:]
            for id in saved.compactMap({ $0 }) {
                if let peer = transaction.getPeer(id) { result[id] = peer }
            }
            return result
        }
        lookup?.dispose()
        lookup = (combineLatest(cached, combineLatest(signals)) |> take(1) |> deliverOnMainQueue).start(next: { [weak self] cached, results in
            guard let self else { return }
            for index in NanoVoiceChats.titles.indices {
                if let id = saved[index] {
                    // Never silently replace an explicit binding because the peer is absent from
                    // a local snapshot (e.g. during sync), renamed, deleted, or inaccessible.
                    if let peer = cached[id], NanoVoiceChats.isEligible(peer, account: self.context.account.peerId),
                       !self.peers.enumerated().contains(where: { $0.offset != index && $0.element == id }) {
                        self.peers[index] = id
                        self.statuses[index] = "Open conversation · ⓘ to change"
                    } else {
                        self.peers[index] = nil
                        self.statuses[index] = "Saved chat unavailable — tap to select"
                    }
                    continue
                }
                let expected = NanoVoiceChats.normalized(NanoVoiceChats.titles[index])
                let reserved = Set(saved.compactMap { $0 } + self.peers.compactMap { $0 })
                let matches = results[index].compactMap(\.peer).filter {
                    NanoVoiceChats.normalized($0.debugDisplayTitle) == expected &&
                    NanoVoiceChats.isEligible($0, account: self.context.account.peerId) && !reserved.contains($0.id)
                }
                if matches.count == 1 {
                    self.peers[index] = matches[0].id
                    UserDefaults.standard.set(String(matches[0].id.toInt64()), forKey: NanoVoiceChats.key(self.context.account.peerId, index))
                    self.statuses[index] = "Open conversation · ⓘ to change"
                } else {
                    self.statuses[index] = matches.isEmpty ? "Not found — tap to select" : "Multiple matches — tap to select"
                }
            }
            self.table.reloadData()
            let names = NanoVoiceChats.titles.indices.map { "\(NanoVoiceChats.titles[$0]): \(self.peers[$0] == nil ? "unresolved" : "resolved")" }.joined(separator: "\n")
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? names.write(to: dir.appendingPathComponent("nanovoice-chats.txt"), atomically: true, encoding: .utf8)
            }
        })
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { "Your agents" }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = NanoVoiceChats.titles[indexPath.row]
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.text = statuses[indexPath.row]
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.imageView?.image = UIImage(systemName: indexPath.row == 0 ? "waveform.circle.fill" : "leaf.circle.fill")
        cell.imageView?.tintColor = .systemPurple
        cell.accessoryType = .detailButton
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let peer = peers[indexPath.row] { openChat(peer) } else { selectChat(indexPath.row) }
    }
    func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        selectChat(indexPath.row)
    }

    private func selectChat(_ index: Int) {
        let otherIds = Set(NanoVoiceChats.titles.indices.filter { $0 != index }.compactMap {
            NanoVoiceChats.peer(context.account.peerId, $0)
        })
        let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(
            context: context,
            filter: [.onlyWriteable, .excludeDisabled, .excludeSecretChats, .excludeChannels, .excludeSavedMessages, .excludeRecent, .doNotSearchMessages],
            hasContactSelector: false,
            hasGlobalSearch: false,
            title: "Choose chat for \(NanoVoiceChats.titles[index])",
            excludedPeerIds: otherIds
        ))
        controller.peerSelected = { [weak self, weak controller] peer, _ in
            guard let self else { return }
            guard NanoVoiceChats.isEligible(peer._asPeer(), account: self.context.account.peerId), !otherIds.contains(peer.id) else {
                controller?.present(textAlertController(context: self.context, title: "Choose an agent conversation", text: "Select a bot or a group you can write to. Each agent needs a different chat.", actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]), in: .window(.root))
                return
            }
            self.lookup?.dispose()
            UserDefaults.standard.set(String(peer.id.toInt64()), forKey: NanoVoiceChats.key(self.context.account.peerId, index))
            controller?.dismiss()
            self.refresh()
        }
        push(controller)
    }
}

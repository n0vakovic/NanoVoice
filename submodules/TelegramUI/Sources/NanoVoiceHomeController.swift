import UIKit
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import AccountContext

enum NanoVoiceChats {
    static var enabled: Bool { Bundle.main.bundleIdentifier == "local.milan.NanoVoice" && !walkChatFixtureEnabled }
    static let titles = ["Dam Rass", "Eating, Moving, Alivening"]
    static func key(_ account: PeerId, _ index: Int) -> String { "nanovoice.chat.\(account.toInt64()).\(index)" }
    static func peer(_ account: PeerId, _ index: Int) -> PeerId? {
        guard let value = UserDefaults.standard.string(forKey: key(account, index)), let id = Int64(value) else { return nil }
        return PeerId(id)
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
        peers = NanoVoiceChats.titles.indices.map { NanoVoiceChats.peer(context.account.peerId, $0) }
        statuses = peers.map { $0 == nil ? "Finding chat…" : "Open conversation" }
        table.reloadData()
        let signals = NanoVoiceChats.titles.map { title in
            context.account.postbox.searchPeers(query: NanoVoiceChats.normalized(title).components(separatedBy: " ").first ?? title)
        }
        lookup?.dispose()
        lookup = (combineLatest(signals) |> deliverOnMainQueue).start(next: { [weak self] results in
            guard let self else { return }
            for index in NanoVoiceChats.titles.indices {
                if self.peers[index] != nil { continue }
                let expected = NanoVoiceChats.normalized(NanoVoiceChats.titles[index])
                let matches = results[index].compactMap(\.peer).filter { NanoVoiceChats.normalized($0.debugDisplayTitle) == expected }
                if matches.count == 1 {
                    self.peers[index] = matches[0].id
                    UserDefaults.standard.set(String(matches[0].id.toInt64()), forKey: NanoVoiceChats.key(self.context.account.peerId, index))
                    self.statuses[index] = "Open conversation"
                } else {
                    self.statuses[index] = matches.isEmpty ? "Not found yet — tap Refresh" : "Multiple matches — needs selection"
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
        cell.accessoryType = peers[indexPath.row] == nil ? .none : .disclosureIndicator
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let peer = peers[indexPath.row] { openChat(peer) }
    }
}

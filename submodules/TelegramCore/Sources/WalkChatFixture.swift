import Foundation
import Postbox
import SwiftSignalKit

/// Local-only fixture. AppDelegate selects an isolated database for this flag.
public let walkChatFixtureEnabled = CommandLine.arguments.contains("--walk-demo")
public let walkChatRussId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(900001))
public let walkChatEmmaId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(900002))

public func prepareWalkChatFixture(account: UnauthorizedAccount, accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<Void, NoError> {
    guard walkChatFixtureEnabled else { return .complete() }
    return account.postbox.transaction { transaction -> Void in
        let me = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(900000))
        let peers = [(me, "Milan"), (walkChatRussId, "Russ"), (walkChatEmmaId, "Emma")].map { id, name in
            TelegramUser(id: id, accessHash: nil, firstName: name, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        }
        updatePeersCustom(transaction: transaction, peers: peers, update: { _, updated in updated })
        transaction.setState(AuthorizedAccountState(isTestingEnvironment: true, masterDatacenterId: 2, peerId: me, state: nil, invalidatedChannels: []))
        for peer in [walkChatRussId, walkChatEmmaId] {
            transaction.updatePeerChatListInclusion(peer, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
            transaction.removeHole(peerId: peer, threadId: nil, namespace: Namespaces.Message.Cloud, space: .everywhere, range: 1 ... Int32.max - 1)
            let message = StoreMessage(id: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1), customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: Int32(Date().timeIntervalSince1970) - 60, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: peer, text: "Local demo conversation. Tap Walk mode to simulate voice replies in this chat. No messages are sent to Telegram.", attributes: [], media: [])
            let _ = transaction.addMessages([message], location: .Random)
        }
    }
    |> mapToSignal { _ in
        return accountManager.transaction { transaction -> Void in
            switchToAuthorizedAccount(transaction: transaction, account: account, isSupportUser: false)
        }
    }
}

public func insertWalkChatVoice(account: Account, peerId: PeerId, fileURL: URL, id: Int32) -> Signal<MessageId, NoError> {
    guard walkChatFixtureEnabled, let data = try? Data(contentsOf: fileURL) else { return .complete() }
    let resource = LocalFileMediaResource(fileId: Int64.random(in: 1 ... Int64.max))
    account.postbox.mediaBox.storeResourceData(resource.id, data: data)
    return account.postbox.transaction { transaction -> MessageId in
        let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: id)
        let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: resource.fileId), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "audio/ogg", size: Int64(data.count), attributes: [.Audio(isVoice: true, duration: 6, title: nil, performer: nil, waveform: nil)], alternativeRepresentations: [])
        let message = StoreMessage(id: messageId, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: Int32(Date().timeIntervalSince1970), flags: [.Incoming], tags: [.voiceOrInstantVideo], globalTags: [], localTags: [], forwardInfo: nil, authorId: peerId, text: "", attributes: [], media: [file])
        let _ = transaction.addMessages([message], location: .Random)
        transaction.removeHole(peerId: peerId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .everywhere, range: 1 ... Int32.max - 1)
        transaction.removeHole(peerId: peerId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .tag(.voiceOrInstantVideo), range: 1 ... Int32.max - 1)
        return messageId
    }
}

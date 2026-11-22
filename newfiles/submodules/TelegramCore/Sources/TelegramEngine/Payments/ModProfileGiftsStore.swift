import Foundation
import Postbox
import SwiftSignalKit
import GiftNetworkTransfer

/// Persistence for mod-to-mod gifts shown in a profile.
///
/// A transfer names a REAL collectible gift by its slug (`t.me/nft/<slug>`). The gift's full data
/// is the server's own record, resolved via `payments.getUniqueStarGift(slug:)` and cached per
/// slug — identical to what a stock client shows when it opens that link. What the mod adds is
/// the *grant*: who sent it to whom, and the recipient's display choices.
///
/// Gifts are ingested when the server delivers the carrying message (both directions) via
/// `ingest`, called from the state replay's `applyAddMessages` — the single choke point that has
/// a Postbox transaction and sees every peer's messages. The owner of a received gift is the
/// account (incoming message); the owner of a sent gift is the chat peer (outgoing message), so
/// viewing that peer's profile shows the gifts we granted them.
///
/// Each grant is stored keyed by the sender-chosen `transferId` (dedup across re-delivery),
/// carrying the resolved `StarGift.UniqueGift`. The recipient's choices — hide from profile, pin
/// to top — are persisted alongside and applied when the profile gifts list is assembled. By
/// default every received mod gift IS displayed (the mod's contract: all granted gifts show).
public enum ModProfileGiftsStore {
    private struct StoredModGifts: Codable {
        var gifts: [ProfileGiftsContext.State.StarGift]
        /// transferId -> slug, so hide/pin can be keyed by the stable grant id.
        var slugByTransferId: [Int64: String]
        var hidden: Set<Int64>
        var pinned: Set<Int64>

        init() {
            self.gifts = []
            self.slugByTransferId = [:]
            self.hidden = []
            self.pinned = []
        }
    }

    // 16 is the first free app-specific collection id (PostboxKeys.swift uses 0-7, 10-15).
    private static let collectionId: Int8 = applicationSpecificItemCacheCollectionId(16)

    private static func entryId(peerId: EnginePeer.Id) -> ItemCacheEntryId {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: peerId.toInt64())
        return ItemCacheEntryId(collectionId: collectionId, key: key)
    }

    private static func read(transaction: Transaction, peerId: EnginePeer.Id) -> StoredModGifts {
        return transaction.retrieveItemCacheEntry(id: entryId(peerId: peerId))?.get(StoredModGifts.self) ?? StoredModGifts()
    }

    private static func write(transaction: Transaction, peerId: EnginePeer.Id, value: StoredModGifts) {
        if let entry = CodableEntry(value) {
            transaction.putItemCacheEntry(id: entryId(peerId: peerId), entry: entry)
        }
    }

    /// A mod gift's profile reference is the collectible slug (the real identifier), so the stock
    /// GiftViewScreen and profile grid treat it like any other unique gift. `isModGiftReference`
    /// tells the save/pin interception that this reference belongs to a mod grant.
    public static func isModGiftReference(_ reference: StarGiftReference, transaction: Transaction, peerId: EnginePeer.Id) -> Bool {
        guard case let .slug(slug) = reference else {
            return false
        }
        let stored = read(transaction: transaction, peerId: peerId)
        return stored.slugByTransferId.values.contains(slug)
    }

    /// All stored gifts across the given owners (the account plus peers it has chatted with).
    public static func allStoredGifts(transaction: Transaction, ownerPeerIds: [EnginePeer.Id]) -> [ProfileGiftsContext.State.StarGift] {
        var result: [ProfileGiftsContext.State.StarGift] = []
        for owner in ownerPeerIds {
            result.append(contentsOf: read(transaction: transaction, peerId: owner).gifts)
        }
        return result
    }

    /// Ingest delivered messages: for every text message carrying a transfer marker, resolve its
    /// collectible slug (from the per-slug cache or the server), rewrite the message into the
    /// stock gift form, and upsert the grant into its owner's store. Called from the state replay
    /// with the active transaction; the slug resolution + message rewrite happen in a follow-up
    /// transaction so this call never blocks sync.
    public static func ingest(transaction: Transaction, accountPeerId: EnginePeer.Id, messages: [StoreMessage]) {
        // Collect markers needing resolution. The gift data may already be cached (rendered at
        // StoreMessage time); if not, resolve and rewrite.
        var pending: [(messageId: MessageId, owner: EnginePeer.Id, payload: GiftTransferCodec.Payload, senderId: EnginePeer.Id?, timestamp: Int32)] = []
        var ready: [(messageId: MessageId, owner: EnginePeer.Id, gift: StarGift.UniqueGift, payload: GiftTransferCodec.Payload, senderId: EnginePeer.Id?, timestamp: Int32)] = []

        for message in messages {
            guard case let .Id(messageId) = message.id else {
                continue
            }
            // Already a gift action (rendered at StoreMessage time, or a prior ingest rewrite).
            if let action = message.media.compactMap({ $0 as? TelegramMediaAction }).first,
               case let .starGiftUnique(gift, _, _, _, _, _, _, _, _, senderId, _, _, _, _, _, _, _, _, _, text, _, nameHidden) = action.action,
               case let .unique(uniqueGift) = gift {
                // Only treat as a mod grant if the message text still carries a marker OR the
                // store already knows this slug as a mod grant (rewritten messages lose the
                // marker text but keep the action).
                let payload = GiftTransferCodec.decode(message.text)
                let knownMod = isKnownModSlug(transaction: transaction, accountPeerId: accountPeerId, slug: uniqueGift.slug)
                if payload != nil || knownMod {
                    let incoming = message.flags.contains(.Incoming)
                    let owner = incoming ? accountPeerId : messageId.peerId
                    let effectivePayload = payload ?? GiftTransferCodec.Payload(slug: uniqueGift.slug, text: text, nameHidden: nameHidden, transferId: syntheticTransferId(messageId: messageId, slug: uniqueGift.slug))
                    ready.append((messageId, owner, uniqueGift, effectivePayload, senderId ?? message.authorId, message.timestamp))
                }
                continue
            }
            // Plain text carrying a marker: needs resolution + rewrite.
            if let payload = GiftTransferCodec.decode(message.text) {
                let incoming = message.flags.contains(.Incoming)
                let owner = incoming ? accountPeerId : messageId.peerId
                if let cached = GiftTransferResolver.resolvedGift(accountPeerId: accountPeerId, slug: payload.slug) {
                    ready.append((messageId, owner, cached, payload, message.authorId, message.timestamp))
                } else {
                    pending.append((messageId, owner, payload, message.authorId, message.timestamp))
                }
            }
        }

        // Upsert ready grants now (transaction available).
        upsert(transaction: transaction, accountPeerId: accountPeerId, grants: ready.map { (owner: $0.owner, gift: $0.gift, payload: $0.payload, senderId: $0.senderId, timestamp: $0.timestamp) })

        // Resolve pending slugs asynchronously, then rewrite + upsert in a follow-up transaction.
        if !pending.isEmpty {
            // The account is needed for network resolution; recover it from the transaction's
            // postbox is not possible, so resolution is driven by the caller via a separate
            // account-bound entry point. Here we only record the pending set for the account
            // task manager to pick up.
            recordPending(accountPeerId: accountPeerId, pending: pending.map { (messageId: $0.messageId, slug: $0.payload.slug, transferId: $0.payload.transferId) })
        }
    }

    /// A stable transfer id for a gift action whose message lost its marker text (e.g. a server
    /// re-delivery of an already-rewritten message). Derived from the message id + slug so it is
    /// deterministic across re-deliveries.
    private static func syntheticTransferId(messageId: MessageId, slug: String) -> Int64 {
        var hasher = Hasher()
        hasher.combine(messageId.peerId.toInt64())
        hasher.combine(messageId.id)
        hasher.combine(slug)
        let value = hasher.finalize()
        // Keep it non-zero and stable; Int64 bit pattern of the hash.
        return Int64(bitPattern: UInt64(bitPattern: Int64(value))) | 1
    }

    private static func isKnownModSlug(transaction: Transaction, accountPeerId: EnginePeer.Id, slug: String) -> Bool {
        let stored = read(transaction: transaction, peerId: accountPeerId)
        if stored.slugByTransferId.values.contains(slug) {
            return true
        }
        return false
    }

    private static func upsert(transaction: Transaction, accountPeerId: EnginePeer.Id, grants: [(owner: EnginePeer.Id, gift: StarGift.UniqueGift, payload: GiftTransferCodec.Payload, senderId: EnginePeer.Id?, timestamp: Int32)]) {
        var byOwner: [EnginePeer.Id: [(gift: StarGift.UniqueGift, payload: GiftTransferCodec.Payload, senderId: EnginePeer.Id?, timestamp: Int32)]] = [:]
        for grant in grants {
            byOwner[grant.owner, default: []].append((grant.gift, grant.payload, grant.senderId, grant.timestamp))
        }
        for (owner, entries) in byOwner {
            var stored = read(transaction: transaction, peerId: owner)
            for entry in entries {
                let transferId = entry.payload.transferId
                let fromPeer: EnginePeer?
                if let senderId = entry.senderId, let peer = transaction.getPeer(senderId) {
                    fromPeer = EnginePeer(peer)
                } else {
                    fromPeer = nil
                }
                let displayed = !stored.hidden.contains(transferId)
                let pinned = stored.pinned.contains(transferId)
                let starGift = ProfileGiftsContext.State.StarGift(
                    gift: .unique(entry.gift),
                    reference: .slug(slug: entry.gift.slug),
                    fromPeer: fromPeer,
                    date: entry.timestamp,
                    text: entry.payload.text,
                    entities: nil,
                    nameHidden: entry.payload.nameHidden,
                    savedToProfile: displayed,
                    pinnedToTop: pinned,
                    convertStars: nil,
                    canUpgrade: false,
                    canExportDate: nil,
                    upgradeStars: nil,
                    transferStars: nil,
                    canTransferDate: nil,
                    canResaleDate: nil,
                    collectionIds: nil,
                    prepaidUpgradeHash: nil,
                    upgradeSeparate: false,
                    dropOriginalDetailsStars: nil,
                    number: entry.gift.number,
                    isRefunded: false,
                    canCraftAt: nil
                )
                stored.slugByTransferId[transferId] = entry.gift.slug
                if let index = stored.gifts.firstIndex(where: { gift in
                    if case let .unique(existing) = gift.gift {
                        return existing.slug == entry.gift.slug
                    }
                    return false
                }) {
                    stored.gifts[index] = starGift
                } else {
                    stored.gifts.append(starGift)
                }
            }
            write(transaction: transaction, peerId: owner, value: stored)
        }
    }

    /// Pending resolutions recorded by ingest for the account task manager to resolve + rewrite.
    private static var pendingByAccount: [EnginePeer.Id: [(messageId: MessageId, slug: String, transferId: Int64)]] = [:]
    private static let pendingQueue = Queue()

    private static func recordPending(accountPeerId: EnginePeer.Id, pending: [(messageId: MessageId, slug: String, transferId: Int64)]) {
        pendingQueue.async {
            var current = pendingByAccount[accountPeerId] ?? []
            for item in pending {
                if !current.contains(where: { $0.messageId == item.messageId }) {
                    current.append(item)
                }
            }
            pendingByAccount[accountPeerId] = current
        }
    }

    /// Drain pending resolutions for an account, as a long-running task: for each pending item,
    /// resolve the slug (server + per-slug cache), rewrite the message into the gift form, and
    /// upsert the grant. Unresolved items re-queue and the task restarts after a delay, so an
    /// offline first sighting becomes a gift bubble as soon as connectivity allows.
    public static func drainPendingTask(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<Never, NoError> {
        let queue = Queue.concurrentDefaultQueue()
        return Signal { subscriber in
            let disposableSet = DisposableSet()
            let drainOnce: () -> Void = {
                var items: [(messageId: MessageId, slug: String, transferId: Int64)] = []
                pendingQueue.sync {
                    items = pendingByAccount[accountPeerId] ?? []
                    pendingByAccount[accountPeerId] = []
                }
                guard !items.isEmpty else {
                    return
                }
                for item in items {
                    disposableSet.add((resolveGiftTransferSlug(postbox: postbox, network: network, accountPeerId: accountPeerId, slug: item.slug)
                    |> deliverOn(queue)).start(next: { resolved in
                        guard let uniqueGift = resolved else {
                            // Could not resolve (unknown slug / offline): re-queue for a later pass.
                            recordPending(accountPeerId: accountPeerId, pending: [item])
                            return
                        }
                        let _ = (postbox.transaction { transaction -> Void in
                            guard let message = transaction.getMessage(item.messageId) else {
                                return
                            }
                            let action = GiftTransferResolver.makeAction(uniqueGift: uniqueGift, senderId: message.author?.id, text: nil, nameHidden: false)
                            let displayText = "t.me/nft/\(item.slug)"
                            let payload = GiftTransferCodec.Payload(slug: item.slug, text: nil, nameHidden: false, transferId: item.transferId)
                            let updated = StoreMessage(
                                id: message.id,
                                customStableId: nil,
                                globallyUniqueId: message.globallyUniqueId,
                                groupingKey: message.groupingKey,
                                threadId: message.threadId,
                                timestamp: message.timestamp,
                                flags: StoreMessageFlags(message.flags),
                                tags: message.tags,
                                globalTags: message.globalTags,
                                localTags: message.localTags,
                                forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init),
                                authorId: message.author?.id,
                                text: displayText,
                                attributes: message.attributes,
                                media: [action]
                            )
                            transaction.updateMessage(item.messageId, update: { _ in .update(updated) })
                            let incoming = message.flags.contains(.Incoming)
                            let owner = incoming ? accountPeerId : message.id.peerId
                            upsert(transaction: transaction, accountPeerId: accountPeerId, grants: [(owner: owner, gift: uniqueGift, payload: payload, senderId: message.author?.id, timestamp: message.timestamp)])
                        }).start()
                    }))
                }
            }
            drainOnce()
            // A later pass catches items whose first resolution failed (offline / not indexed).
            disposableSet.add((Signal<Never, NoError>.complete()
            |> suspendAwareDelay(30.0, queue: queue)
            |> mapToSignal { _ -> Signal<Never, NoError> in
                drainOnce()
                return .complete()
            } |> restart).start())
            return disposableSet
        }
    }

    /// Persist the recipient's display choice for a mod gift (by slug). Hiding also unpins.
    public static func setSaved(transaction: Transaction, peerId: EnginePeer.Id, slug: String, saved: Bool) {
        var stored = read(transaction: transaction, peerId: peerId)
        guard let transferId = stored.slugByTransferId.first(where: { $0.value == slug })?.key else {
            return
        }
        if saved {
            stored.hidden.remove(transferId)
        } else {
            stored.hidden.insert(transferId)
            stored.pinned.remove(transferId)
        }
        if let index = stored.gifts.firstIndex(where: { gift in
            if case let .unique(existing) = gift.gift {
                return existing.slug == slug
            }
            return false
        }) {
            stored.gifts[index] = stored.gifts[index].withSavedToProfile(saved).withPinnedToTop(saved ? stored.gifts[index].pinnedToTop : false)
        }
        write(transaction: transaction, peerId: peerId, value: stored)
    }

    /// Persist the recipient's pin-to-top choice for a mod gift (by slug). Pinning implies displayed.
    public static func setPinned(transaction: Transaction, peerId: EnginePeer.Id, slug: String, pinned: Bool) {
        var stored = read(transaction: transaction, peerId: peerId)
        guard let transferId = stored.slugByTransferId.first(where: { $0.value == slug })?.key else {
            return
        }
        if pinned {
            stored.pinned.insert(transferId)
            stored.hidden.remove(transferId)
        } else {
            stored.pinned.remove(transferId)
        }
        if let index = stored.gifts.firstIndex(where: { gift in
            if case let .unique(existing) = gift.gift {
                return existing.slug == slug
            }
            return false
        }) {
            stored.gifts[index] = stored.gifts[index].withPinnedToTop(pinned).withSavedToProfile(pinned ? true : stored.gifts[index].savedToProfile)
        }
        write(transaction: transaction, peerId: peerId, value: stored)
    }

    /// Whether the owner has any displayable mod gift. Cheap store read for the gifts-pane gate.
    public static func hasModGifts(transaction: Transaction, ownerPeerId: EnginePeer.Id) -> Bool {
        let stored = read(transaction: transaction, peerId: ownerPeerId)
        return stored.gifts.contains { gift in
            if case let .slug(slug) = gift.reference, let transferId = stored.slugByTransferId.first(where: { $0.value == slug })?.key {
                return !stored.hidden.contains(transferId)
            }
            return false
        }
    }

    /// Read the owner's mod gifts, applying persisted hidden/pinned choices, pinned first then
    /// newest first — matching how the server orders real saved gifts.
    public static func collectModGifts(transaction: Transaction, ownerPeerId: EnginePeer.Id) -> [ProfileGiftsContext.State.StarGift] {
        let stored = read(transaction: transaction, peerId: ownerPeerId)
        var result: [ProfileGiftsContext.State.StarGift] = []
        for gift in stored.gifts {
            guard case let .slug(slug) = gift.reference, let transferId = stored.slugByTransferId.first(where: { $0.value == slug })?.key else {
                continue
            }
            let displayed = !stored.hidden.contains(transferId)
            let pinned = stored.pinned.contains(transferId)
            result.append(gift.withSavedToProfile(displayed).withPinnedToTop(pinned))
        }
        result.sort { lhs, rhs in
            if lhs.pinnedToTop != rhs.pinnedToTop {
                return lhs.pinnedToTop
            }
            return lhs.date > rhs.date
        }
        return result
    }
}

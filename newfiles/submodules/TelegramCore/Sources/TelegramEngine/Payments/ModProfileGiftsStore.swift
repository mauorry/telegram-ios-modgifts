import Foundation
import Postbox

/// Persistence for mod-to-mod gifts shown in a profile.
///
/// Gifts are ingested when the server delivers the carrying message (both directions) via
/// `ingest`, called from the state replay's `applyAddMessages` — the single choke point that has
/// a Postbox transaction and sees every peer's messages. The owner of a received gift is the
/// account (incoming message); the owner of a sent gift is the chat peer (outgoing message), so
/// viewing that peer's profile shows the gifts we granted them.
///
/// The full gift entry is stored (it is Codable, including the catalog model file), keyed by the
/// synthetic slug. The recipient's own choices — hide from profile, pin to top — are persisted
/// alongside and applied when the profile gifts list is assembled. By default every received mod
/// gift IS displayed (the mod's contract: all granted gifts show).
public enum ModProfileGiftsStore {
    private struct StoredModGifts: Codable {
        var gifts: [ProfileGiftsContext.State.StarGift]
        var hidden: Set<String>
        var pinned: Set<String>

        init() {
            self.gifts = []
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

    /// Whether a synthetic slug belongs to a mod transfer (vs a real server gift).
    public static func isModGiftSlug(_ slug: String) -> Bool {
        return slug.hasPrefix("modgift-")
    }

    /// Extract the mod gift slug from a stored message's synthetic action, if any.
    public static func modSlug(in media: [Media]) -> String? {
        for m in media {
            if let action = m as? TelegramMediaAction, case let .starGiftUnique(gift, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = action.action, case let .unique(uniqueGift) = gift {
                if isModGiftSlug(uniqueGift.slug) {
                    return uniqueGift.slug
                }
            }
        }
        return nil
    }

    /// Ingest delivered messages: upsert any mod gift into its owner's store. Called from the
    /// state replay with the active transaction. Pure cache upsert — never throws, never mutates
    /// the messages themselves, so it cannot disturb sync invariants.
    public static func ingest(transaction: Transaction, accountPeerId: EnginePeer.Id, messages: [StoreMessage]) {
        var byOwner: [EnginePeer.Id: [ProfileGiftsContext.State.StarGift]] = [:]
        for message in messages {
            guard case let .Id(messageId) = message.id else {
                continue
            }
            for media in message.media {
                guard let action = media as? TelegramMediaAction else {
                    continue
                }
                guard case let .starGiftUnique(gift, _, _, _, _, _, _, _, _, senderId, _, _, _, _, _, _, _, _, _, text, entities, nameHidden) = action.action, case let .unique(uniqueGift) = gift else {
                    continue
                }
                guard isModGiftSlug(uniqueGift.slug) else {
                    continue
                }
                let incoming = message.flags.contains(.Incoming)
                let owner = incoming ? accountPeerId : messageId.peerId
                let fromPeerId = senderId ?? message.authorId
                let fromPeer: EnginePeer?
                if let fromPeerId, let peer = transaction.getPeer(fromPeerId) {
                    fromPeer = EnginePeer(peer)
                } else {
                    fromPeer = nil
                }
                let entry = ProfileGiftsContext.State.StarGift(
                    gift: gift,
                    reference: .slug(slug: uniqueGift.slug),
                    fromPeer: fromPeer,
                    date: message.timestamp,
                    text: text,
                    entities: entities,
                    nameHidden: nameHidden,
                    savedToProfile: true,
                    pinnedToTop: false,
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
                    number: uniqueGift.number,
                    isRefunded: false,
                    canCraftAt: nil
                )
                byOwner[owner, default: []].append(entry)
            }
        }
        for (owner, entries) in byOwner {
            var stored = read(transaction: transaction, peerId: owner)
            for entry in entries {
                if case .slug = entry.reference {
                } else {
                    continue
                }
                if let index = stored.gifts.firstIndex(where: { $0.reference == entry.reference }) {
                    // Keep the recipient's existing display flags on re-delivery.
                    stored.gifts[index] = entry.withSavedToProfile(stored.gifts[index].savedToProfile).withPinnedToTop(stored.gifts[index].pinnedToTop)
                } else {
                    stored.gifts.append(entry)
                }
            }
            write(transaction: transaction, peerId: owner, value: stored)
        }
    }

    /// Persist the recipient's display choice for a mod gift. Hiding also unpins.
    public static func setSaved(transaction: Transaction, peerId: EnginePeer.Id, slug: String, saved: Bool) {
        var stored = read(transaction: transaction, peerId: peerId)
        if saved {
            stored.hidden.remove(slug)
        } else {
            stored.hidden.insert(slug)
            stored.pinned.remove(slug)
        }
        if let index = stored.gifts.firstIndex(where: { $0.reference == .slug(slug: slug) }) {
            stored.gifts[index] = stored.gifts[index].withSavedToProfile(saved).withPinnedToTop(saved ? stored.gifts[index].pinnedToTop : false)
        }
        write(transaction: transaction, peerId: peerId, value: stored)
    }

    /// Persist the recipient's pin-to-top choice for a mod gift. Pinning implies displayed.
    public static func setPinned(transaction: Transaction, peerId: EnginePeer.Id, slug: String, pinned: Bool) {
        var stored = read(transaction: transaction, peerId: peerId)
        if pinned {
            stored.pinned.insert(slug)
            stored.hidden.remove(slug)
        } else {
            stored.pinned.remove(slug)
        }
        if let index = stored.gifts.firstIndex(where: { $0.reference == .slug(slug: slug) }) {
            stored.gifts[index] = stored.gifts[index].withPinnedToTop(pinned).withSavedToProfile(pinned ? true : stored.gifts[index].savedToProfile)
        }
        write(transaction: transaction, peerId: peerId, value: stored)
    }

    /// Whether the owner has any displayable mod gift. Cheap store read for the gifts-pane gate.
    public static func hasModGifts(transaction: Transaction, ownerPeerId: EnginePeer.Id) -> Bool {
        let stored = read(transaction: transaction, peerId: ownerPeerId)
        return stored.gifts.contains { gift in
            if case let .slug(slug) = gift.reference {
                return !stored.hidden.contains(slug)
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
            guard case let .slug(slug) = gift.reference else {
                continue
            }
            let displayed = !stored.hidden.contains(slug)
            let pinned = stored.pinned.contains(slug)
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

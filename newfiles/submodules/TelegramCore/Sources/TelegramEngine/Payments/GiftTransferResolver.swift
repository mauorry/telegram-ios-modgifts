import Foundation
import Postbox
import SwiftSignalKit

/// In-memory mirror of the cached star-gift catalog, keyed by account. `StoreMessage(apiMessage:)`
/// runs without a Postbox transaction, so it cannot read `PreferencesKeys.starGifts()` directly;
/// this cache is refreshed wherever the catalog is written (`_internal_keepCachedStarGiftsUpdated`)
/// and once at account start, giving the incoming-message hook a synchronous, deterministic lookup.
// Internal (not private): StarGifts.swift updates this cache where the catalog is written.
final class GiftTransferCatalogCache {
    static let shared = GiftTransferCatalogCache()
    private let queue = Queue()
    private var giftsByAccount: [PeerId: [Int64: StarGift.Gift]] = [:]

    func update(accountPeerId: PeerId, items: [StarGift]) {
        var byId: [Int64: StarGift.Gift] = [:]
        for gift in items {
            if case let .generic(generic) = gift {
                byId[generic.id] = generic
            }
        }
        self.queue.async {
            self.giftsByAccount[accountPeerId] = byId
        }
    }

    func gift(accountPeerId: PeerId, giftId: Int64) -> StarGift.Gift? {
        var result: StarGift.Gift?
        self.queue.sync {
            result = self.giftsByAccount[accountPeerId]?[giftId]
        }
        return result
    }
}

/// Refresh the in-memory catalog cache from the persisted star-gift list. Call at account start
/// and after every catalog write so the incoming-message hook sees current gifts.
public func refreshGiftTransferCatalogCache(postbox: Postbox, accountPeerId: PeerId) {
    let _ = _internal_cachedStarGifts(postbox: postbox).start(next: { list in
        GiftTransferCatalogCache.shared.update(accountPeerId: accountPeerId, items: list?.items ?? [])
    })
}

/// Builds a synthetic collectible gift (`StarGift.UniqueGift`) and its chat action for a
/// mod-to-mod transfer decoded from a message text.
///
/// The transfer payload carries only a catalog `giftId` and a collectible number — never the
/// animation file. The receiver resolves the gift's model from its own cached star-gift catalog
/// (`PreferencesKeys.starGifts()`), exactly as the official client resolves a real gift's media.
/// If the catalog does not contain the id (the receiver has never loaded the gift store), the
/// transfer cannot be rendered as a gift and the message stays plain text.
public enum GiftTransferResolver {
    /// Look a generic catalog gift up by id in the cached star-gift list. Synchronous: intended
    /// to be called inside a Postbox transaction (e.g. from `StoreMessage(apiMessage:)`).
    public static func cachedGift(transaction: Transaction, giftId: Int64) -> StarGift.Gift? {
        guard let list = transaction.getPreferencesEntry(key: PreferencesKeys.starGifts())?.get(StarGiftsList.self) else {
            return nil
        }
        for gift in list.items {
            if case let .generic(generic) = gift, generic.id == giftId {
                return generic
            }
        }
        return nil
    }

    /// Synchronous lookup from the in-memory catalog cache, for use where no transaction is
    /// available (the `StoreMessage(apiMessage:)` initializer). Returns nil if the catalog has
    /// not been loaded for this account or does not contain the id.
    public static func cachedGift(accountPeerId: PeerId, giftId: Int64) -> StarGift.Gift? {
        return GiftTransferCatalogCache.shared.gift(accountPeerId: accountPeerId, giftId: giftId)
    }

    /// Build the collectible gift shown for a transfer. `senderPeerId`/`recipientPeerId` are the
    /// chat's author and owner; `number` and `transferId` come from the wire payload.
    public static func makeUniqueGift(gift: StarGift.Gift, number: Int32, transferId: Int64, senderPeerId: EnginePeer.Id?, recipientPeerId: EnginePeer.Id, date: Int32, text: String?) -> StarGift.UniqueGift {
        var attributes: [StarGift.UniqueGift.Attribute] = []
        // The model animation is the catalog gift's own sticker file.
        attributes.append(.model(name: gift.title ?? "Gift", file: gift.file, rarity: .permille(1), crafted: false))
        // A backdrop derived from the gift's background colors, or a neutral default.
        if let background = gift.background {
            attributes.append(.backdrop(name: "Backdrop", id: 0, innerColor: background.centerColor, outerColor: background.edgeColor, patternColor: background.centerColor, textColor: background.textColor, rarity: .permille(1)))
        } else {
            attributes.append(.backdrop(name: "Backdrop", id: 0, innerColor: 0x2a2a3a, outerColor: 0x1a1a2a, patternColor: 0x3a3a4a, textColor: 0xffffff, rarity: .permille(1)))
        }
        if let senderPeerId {
            attributes.append(.originalInfo(senderPeerId: senderPeerId, recipientPeerId: recipientPeerId, date: date, text: text, entities: nil))
        }

        // A synthetic slug keyed by the transfer id keeps cover icons and pager items distinct.
        let slug = "modgift-\(transferId)"
        return StarGift.UniqueGift(
            id: transferId,
            giftId: gift.id,
            title: gift.title ?? "Gift",
            number: number,
            slug: slug,
            owner: senderPeerId.flatMap { .peerId($0) },
            attributes: attributes,
            availability: .init(issued: number, total: max(number, 1)),
            giftAddress: nil,
            resellAmounts: nil,
            resellForTonOnly: false,
            releasedBy: gift.releasedBy,
            valueAmount: nil,
            valueCurrency: nil,
            valueUsdAmount: nil,
            flags: [],
            themePeerId: nil,
            peerColor: nil,
            hostPeerId: nil,
            minOfferStars: nil,
            craftChancePermille: nil
        )
    }

    /// The chat action that makes the stock gift bubble render the transfer. `savedToProfile` is
    /// false until the recipient saves it; `senderId` is the gift's author.
    public static func makeAction(uniqueGift: StarGift.UniqueGift, senderId: EnginePeer.Id?, text: String?, nameHidden: Bool) -> TelegramMediaAction {
        return TelegramMediaAction(action: .starGiftUnique(
            gift: .unique(uniqueGift),
            isUpgrade: false,
            isTransferred: false,
            savedToProfile: false,
            canExportDate: nil,
            transferStars: nil,
            isRefunded: false,
            isPrepaidUpgrade: false,
            peerId: nil,
            senderId: senderId,
            savedId: nil,
            resaleAmount: nil,
            canTransferDate: nil,
            canResaleDate: nil,
            dropOriginalDetailsStars: nil,
            assigned: false,
            fromOffer: false,
            canCraftAt: nil,
            isCrafted: false,
            text: text,
            entities: nil,
            nameHidden: nameHidden
        ))
    }
}

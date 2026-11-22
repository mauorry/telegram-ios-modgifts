import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// In-memory mirrors the `StoreMessage(apiMessage:)` hook reads synchronously (it runs without a
/// Postbox transaction). Two caches, both keyed by account and refreshed wherever the persisted
/// counterparts are written plus once at account start:
///
/// - `catalog`: generic gift id -> `StarGift.Gift` (the picker's grid).
/// - `slugs`: collectible slug -> resolved `StarGift.UniqueGift`, the same per-slug cache the
///   official client maintains for `t.me/nft/<slug>` links (`cachedUniqueStarGiftEntryId`). A
///   transfer therefore renders the REAL gift — the server's own model, backdrop and attributes —
///   identical to what a stock client shows when it opens that link.
final class GiftTransferCatalogCache {
    static let shared = GiftTransferCatalogCache()
    private let queue = Queue()
    private var catalogByAccount: [PeerId: [Int64: StarGift.Gift]] = [:]
    private var slugsByAccount: [PeerId: [String: StarGift.UniqueGift]] = [:]

    func update(accountPeerId: PeerId, catalogItems: [StarGift]) {
        var byId: [Int64: StarGift.Gift] = [:]
        for gift in catalogItems {
            if case let .generic(generic) = gift {
                byId[generic.id] = generic
            }
        }
        self.queue.async {
            self.catalogByAccount[accountPeerId] = byId
        }
    }

    func catalogGift(accountPeerId: PeerId, giftId: Int64) -> StarGift.Gift? {
        var result: StarGift.Gift?
        self.queue.sync {
            result = self.catalogByAccount[accountPeerId]?[giftId]
        }
        return result
    }

    func updateSlug(accountPeerId: PeerId, slug: String, gift: StarGift.UniqueGift?) {
        self.queue.async {
            if let gift {
                self.slugsByAccount[accountPeerId, default: [:]][slug] = gift
            } else {
                self.slugsByAccount[accountPeerId]?.removeValue(forKey: slug)
            }
        }
    }

    func updateSlugs(accountPeerId: PeerId, gifts: [String: StarGift.UniqueGift]) {
        self.queue.async {
            self.slugsByAccount[accountPeerId, default: [:]].merge(gifts) { _, new in new }
        }
    }

    func slugGift(accountPeerId: PeerId, slug: String) -> StarGift.UniqueGift? {
        var result: StarGift.UniqueGift?
        self.queue.sync {
            result = self.slugsByAccount[accountPeerId]?[slug]
        }
        return result
    }
}

/// Refresh the in-memory catalog cache from the persisted star-gift list. Call at account start
/// and after every catalog write so the incoming-message hook sees current gifts.
public func refreshGiftTransferCatalogCache(postbox: Postbox, accountPeerId: PeerId) {
    let _ = _internal_cachedStarGifts(postbox: postbox).start(next: { list in
        GiftTransferCatalogCache.shared.update(accountPeerId: accountPeerId, catalogItems: list?.items ?? [])
    })
}

/// Resolve a collectible gift by its slug (the identifier `t.me/nft/<slug>` uses): first from the
/// per-slug cache, then from the server via `payments.getUniqueStarGift` — the same call the
/// official client makes when a stock user taps such a link. Resolved gifts enter the cache, so
/// the synchronous `StoreMessage` hook can render the same gift later without a network round
/// trip. A negative cache entry is not kept: an unresolved slug may simply not have been indexed
/// yet, and the next message can retry.
public func resolveGiftTransferSlug(postbox: Postbox, network: Network, accountPeerId: PeerId, slug: String) -> Signal<StarGift.UniqueGift?, NoError> {
    return postbox.transaction { transaction -> StarGift.UniqueGift? in
        guard case let .unique(gift) = transaction.retrieveItemCacheEntry(id: cachedUniqueStarGiftEntryId(slug: slug))?.get(StarGift.self) else {
            return nil
        }
        return gift
    }
    |> mapToSignal { cached -> Signal<StarGift.UniqueGift?, NoError> in
        if let cached {
            GiftTransferCatalogCache.shared.updateSlug(accountPeerId: accountPeerId, slug: slug, gift: cached)
            return .single(cached)
        }
        return network.request(Api.functions.payments.getUniqueStarGift(slug: slug))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.payments.UniqueStarGift?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<StarGift.UniqueGift?, NoError> in
            guard let result else {
                return .single(nil)
            }
            return postbox.transaction { transaction -> StarGift.UniqueGift? in
                switch result {
                case let .uniqueStarGift(uniqueStarGiftData):
                    let (gift, chats, users) = (uniqueStarGiftData.gift, uniqueStarGiftData.chats, uniqueStarGiftData.users)
                    let parsedPeers = AccumulatedPeers(chats: chats, users: users)
                    updatePeers(transaction: transaction, accountPeerId: accountPeerId, peers: parsedPeers)
                    guard case let .unique(uniqueGift) = StarGift(apiStarGift: gift) else {
                        return nil
                    }
                    if let entry = CodableEntry(StarGift.unique(uniqueGift)) {
                        transaction.putItemCacheEntry(id: cachedUniqueStarGiftEntryId(slug: slug), entry: entry)
                    }
                    return uniqueGift
                }
            }
        }
        |> mapToSignal { resolved -> Signal<StarGift.UniqueGift?, NoError> in
            if let resolved {
                GiftTransferCatalogCache.shared.updateSlug(accountPeerId: accountPeerId, slug: slug, gift: resolved)
            }
            return .single(resolved)
        }
    }
}

/// Seeds the synchronous slug cache from the persisted per-slug entries plus every mod gift the
/// profile store already knows (its entries carry the full resolved gift). Called at account
/// start; per-slug entries have no public enumeration, so the mod store supplies the slugs.
public func refreshGiftTransferSlugCache(postbox: Postbox, accountPeerId: PeerId) {
    let _ = postbox.transaction { transaction -> [String: StarGift.UniqueGift] in
        var result: [String: StarGift.UniqueGift] = [:]
        for entry in ModProfileGiftsStore.allStoredGifts(transaction: transaction, ownerPeerIds: [accountPeerId]) {
            if case let .unique(uniqueGift) = entry.gift {
                result[uniqueGift.slug] = uniqueGift
            }
        }
        return result
    }.start(next: { gifts in
        GiftTransferCatalogCache.shared.updateSlugs(accountPeerId: accountPeerId, gifts: gifts)
    })
}

/// Resolves and caches a transfer's gift for synchronous rendering by the incoming-message hook.
/// Called from `ModProfileGiftsStore.ingest`'s context when a marker arrives whose slug is not
/// yet in the in-memory cache; the NEXT re-render of the message (any update touching it) picks
/// the gift up. Also called eagerly by the sender before sending so its own echo renders at once.
public func warmGiftTransferSlug(postbox: Postbox, network: Network, accountPeerId: PeerId, slug: String) {
    let _ = resolveGiftTransferSlug(postbox: postbox, network: network, accountPeerId: accountPeerId, slug: slug).start()
}

/// Builds the chat action that makes the stock gift bubble render a transfer, from a REAL
/// resolved collectible gift (never a synthesized one). `senderId` is the gift's author.
public enum GiftTransferResolver {
    /// Synchronous lookup of a resolved collectible by slug, for use where no transaction is
    /// available (the `StoreMessage(apiMessage:)` initializer). Returns nil if the slug has not
    /// been resolved yet; the caller then leaves the message as plain text and the ingest path
    /// resolves it for later renders.
    public static func resolvedGift(accountPeerId: PeerId, slug: String) -> StarGift.UniqueGift? {
        return GiftTransferCatalogCache.shared.slugGift(accountPeerId: accountPeerId, slug: slug)
    }

    /// The chat action for a resolved gift. The gift itself is the server's own record; only the
    /// transfer-specific framing (sender, text, nameHidden) is mod data.
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

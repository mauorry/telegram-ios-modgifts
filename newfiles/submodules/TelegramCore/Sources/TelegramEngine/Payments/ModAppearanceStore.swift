import Foundation
import Postbox
import SwiftSignalKit
import GiftNetworkTransfer

/// The mod user's own visual appearance: a fake phone number and a list of visual NFT gifts,
/// published to the bio so other mod users see them in the profile (the confirmed design).
///
/// Local state lives in a Postbox item-cache entry (collection 17, first free app-specific
/// slot after ModProfileGiftsStore's 16). Publishing rewrites the bio as
/// `cleanBio(currentBio) + ModAppearanceCodec.encode(appearance)` via the stock
/// `accountData.updateAbout` — the server then syncs it to every profile viewer.
///
/// Reading another user's appearance is done by decoding their `cachedData.about` at profile
/// render time (see PeerInfoData); their gift slugs resolve through the same per-slug cache
/// the chat channel uses (`GiftTransferResolver`), so a visual gift renders the real server
/// record.
public enum ModAppearanceStore {
    private static let collectionId: Int8 = applicationSpecificItemCacheCollectionId(17)

    private static func entryId(accountPeerId: PeerId) -> ItemCacheEntryId {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: accountPeerId.toInt64())
        return ItemCacheEntryId(collectionId: collectionId, key: key)
    }

    /// Read the locally stored appearance for an account (what the user configured).
    public static func read(transaction: Transaction, accountPeerId: PeerId) -> ModAppearanceCodec.Appearance {
        return transaction.retrieveItemCacheEntry(id: entryId(accountPeerId: accountPeerId))?.get(ModAppearanceCodec.Appearance.self) ?? ModAppearanceCodec.Appearance(phone: nil, slugs: [])
    }

    /// Persist the appearance locally (does NOT publish; call `publish` for that).
    public static func write(transaction: Transaction, accountPeerId: PeerId, appearance: ModAppearanceCodec.Appearance) {
        if let entry = CodableEntry(appearance) {
            transaction.putItemCacheEntry(id: entryId(accountPeerId: accountPeerId), entry: entry)
        }
    }

    /// Publish the appearance to the bio: keep the user's own text, replace any previous marker
    /// with a fresh one. Returns a signal that completes when the server accepts the new bio.
    /// The local store is updated in the same transaction that reads the current bio, so a
    /// failed publish leaves the previous local state intact.
    public static func publish(account: Account, accountPeerId: PeerId, appearance: ModAppearanceCodec.Appearance) -> Signal<Void, NoError> {
        let engine = TelegramEngine(account: account)
        return engine.data.get(TelegramEngine.EngineData.Item.Peer.CachedData(id: accountPeerId))
        |> mapToSignal { cachedData -> Signal<String, NoError> in
            // Result is Optional<EngineCachedPeerData>; flatten before the concrete cast.
            let currentBio = (cachedData.flatMap { $0 as? CachedUserData })?.about ?? ""
            return .single(currentBio)
        }
        |> mapToSignal { currentBio -> Signal<Void, NoError> in
            let clean = ModAppearanceCodec.cleanBio(currentBio)
            let marker = ModAppearanceCodec.encode(appearance, originalBio: clean)
            let newBio = clean + (marker ?? "")
            // Persist locally regardless of publish outcome so the menu reflects the choice.
            let _ = account.postbox.transaction { transaction in
                ModAppearanceStore.write(transaction: transaction, accountPeerId: accountPeerId, appearance: appearance)
            }.start()
            if newBio == currentBio {
                return .single(())
            }
            return engine.accountData.updateAbout(about: newBio)
            |> map { _ in () }
            |> `catch` { _ -> Signal<Void, NoError> in
                return .single(())
            }
        }
    }

    /// Clear the visual appearance: remove the marker from the bio and empty the local store.
    public static func clear(engine: TelegramEngine, accountPeerId: PeerId) -> Signal<Void, NoError> {
        return publish(account: engine.account, accountPeerId: accountPeerId, appearance: ModAppearanceCodec.Appearance(phone: nil, slugs: []))
    }

    /// Resolve every slug of an appearance into real collectible gifts (server + per-slug
    /// cache), warming the synchronous cache the profile render reads. Unresolvable slugs are
    /// skipped (they may be burned/invalid); the result keeps input order for the stable ones.
    public static func resolveAppearance(postbox: Postbox, network: Network, accountPeerId: PeerId, appearance: ModAppearanceCodec.Appearance) -> Signal<[StarGift.UniqueGift], NoError> {
        let signals = appearance.slugs.map { slug in
            resolveGiftTransferSlug(postbox: postbox, network: network, accountPeerId: accountPeerId, slug: slug)
        }
        if signals.isEmpty {
            return .single([])
        }
        return combineLatest(signals)
        |> map { results in
            results.compactMap { $0 }
        }
    }

    /// The visual gifts another mod user publishes in their bio, as profile gift entries.
    /// Reads the peer's `cachedData.about` marker, resolves each slug from the synchronous
    /// per-slug cache (already-resolved gifts render immediately), and warms unresolved slugs
    /// in the background so a later profile refresh picks them up. `viewerAccountPeerId` is the
    /// account doing the viewing (its slug cache is consulted).
    public static func collectVisualGifts(transaction: Transaction, peerId: PeerId, viewerAccountPeerId: PeerId, network: Network, postbox: Postbox) -> [ProfileGiftsContext.State.StarGift] {
        guard let cachedData = transaction.getPeerCachedData(peerId: peerId) as? CachedUserData,
              let appearance = ModAppearanceCodec.decode(cachedData.about ?? ""), !appearance.slugs.isEmpty else {
            return []
        }
        var result: [ProfileGiftsContext.State.StarGift] = []
        var unresolved: [String] = []
        for slug in appearance.slugs {
            if let uniqueGift = GiftTransferResolver.resolvedGift(accountPeerId: viewerAccountPeerId, slug: slug) {
                result.append(ProfileGiftsContext.State.StarGift(
                    gift: .unique(uniqueGift),
                    reference: .slug(slug: uniqueGift.slug),
                    fromPeer: nil,
                    date: 0,
                    text: nil,
                    entities: nil,
                    nameHidden: false,
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
                ))
            } else {
                unresolved.append(slug)
            }
        }
        // Warm unresolved slugs so a later refresh renders them; fire-and-forget.
        if !unresolved.isEmpty {
            for slug in unresolved {
                warmGiftTransferSlug(postbox: postbox, network: network, accountPeerId: viewerAccountPeerId, slug: slug)
            }
        }
        return result
    }
}

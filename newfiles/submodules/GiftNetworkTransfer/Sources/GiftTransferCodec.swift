import Foundation

/// Wire codec for mod-to-mod gift transfers carried inside a normal Telegram text message.
///
/// The official Telegram server only forwards the *text* of a user message: an outgoing
/// `TelegramMediaAction` is never uploaded (`mediaContentToUpload` returns nil for it and the
/// send path falls back to `.text(text)`), and unknown `MessageAttribute`s are dropped by
/// `filterMessageAttributesForOutgoingMessage`. The only byte channel two mod clients share is
/// therefore the message text itself.
///
/// A transfer is encoded as a compact JSON object wrapped in a zero-width marker pair and
/// appended to (or replacing) the visible message text. A stock Telegram client renders the
/// zero-width characters as nothing, so the gift is invisible to non-mod users; a mod client
/// detects the marker, decodes the payload, hides it from the rendered text and synthesizes a
/// local `TelegramMediaAction(.starGiftUnique)` so the stock gift bubble draws it.
///
/// The animation file is NOT transmitted: the receiver resolves the gift's model from its own
/// cached star-gift catalog by `giftId`, exactly as the official client resolves a real gift.
/// This keeps the payload tiny (well under Telegram's 4096-character message limit) and avoids
/// shipping media the receiver already has.
public enum GiftTransferCodec {
    /// Zero-width space. Marks the start of the hidden payload.
    public static let markerStart = "\u{200B}"
    /// Zero-width non-joiner. Marks the end of the hidden payload.
    public static let markerEnd = "\u{200C}"

    /// Current wire version. Bump when the payload shape changes incompatibly.
    public static let version: Int32 = 2

    /// The decoded contents of a gift transfer message.
    public struct Payload: Equatable {
        /// Slug of a REAL Telegram collectible gift (e.g. "PlushPepe-1",
        /// `^[A-Za-z0-9]+-[0-9]+$`), the same identifier t.me/nft/<slug> uses. The receiver
        /// resolves the gift's full data (model, backdrop, attributes) from the server via
        /// `payments.getUniqueStarGift(slug:)` and from its per-slug cache — the same source of
        /// truth as the official client, so the gift renders pixel-identically everywhere.
        public let slug: String
        /// Optional accompanying message shown under the gift in the bubble.
        public let text: String?
        /// Whether the sender hid their name on the gift.
        public let nameHidden: Bool
        /// Sender-chosen unique id so the receiver can deduplicate and reference the gift.
        public let transferId: Int64
        /// Wire version the payload was written with.
        public let version: Int32

        public init(slug: String, text: String?, nameHidden: Bool, transferId: Int64, version: Int32 = GiftTransferCodec.version) {
            self.slug = slug
            self.text = text
            self.nameHidden = nameHidden
            self.transferId = transferId
            self.version = version
        }

        /// The collectible-number suffix of the slug ("PlushPepe-1" -> 1), used as the display
        /// number when one is needed.
        public var slugNumber: Int32? {
            guard let idx = slug.lastIndex(of: "-") else {
                return nil
            }
            return Int32(slug[slug.index(after: idx)...])
        }

        /// Whether the slug matches the collectible format Telegram itself uses for NFT gifts.
        public var isWellFormedSlug: Bool {
            let parts = slug.split(separator: "-", maxSplits: 1)
            guard parts.count == 2 else {
                return false
            }
            return !parts[0].isEmpty && Int32(parts[1]) != nil
        }
    }

    /// JSON keys are short to keep the payload small. `v` version, `s` slug, `t` text,
    /// `h` nameHidden, `i` transferId.
    private struct WirePayload: Codable {
        let v: Int32
        let s: String
        let t: String?
        let h: Bool
        let i: Int64
    }

    /// Encode a payload into the hidden marker block. Returns the marker-wrapped string to
    /// append to a message's text. Never throws: a payload that cannot be serialized yields nil.
    public static func encode(_ payload: Payload) -> String? {
        let wire = WirePayload(v: payload.version, s: payload.slug, t: payload.text, h: payload.nameHidden, i: payload.transferId)
        guard let data = try? JSONEncoder().encode(wire) else {
            return nil
        }
        // Base64 keeps the JSON's quotes/braces out of the visible text and avoids any
        // zero-width characters inside the payload confusing the marker scan.
        let base64 = data.base64EncodedString()
        return markerStart + base64 + markerEnd
    }

    /// The visible text of a message with the hidden payload removed.
    public static func visibleText(_ text: String) -> String {
        guard let range = payloadRange(in: text) else {
            return text
        }
        var result = text
        result.removeSubrange(range)
        // Trim a trailing space left before the marker so the visible text has no dangling gap.
        while result.hasSuffix(" ") {
            result.removeLast()
        }
        return result
    }

    /// The message text a mod client should STORE after stripping the marker: the remaining
    /// visible words, or — when nothing else is left — the official collectible link
    /// `t.me/nft/<slug>`. A stock client therefore still sees a tappable gift link for the
    /// transfer instead of an empty message (the trick DuckGram uses), while a mod client
    /// renders the full gift bubble and never draws this text (skipText = true).
    public static func displayText(payload: Payload, originalText: String) -> String {
        let remainder = visibleText(originalText)
        if !remainder.isEmpty {
            return remainder
        }
        return "t.me/nft/\(payload.slug)"
    }

    /// Decode the hidden payload from a message text, if present and well-formed.
    /// Returns nil for stock messages, malformed payloads, or unknown future versions.
    public static func decode(_ text: String) -> Payload? {
        guard let range = payloadRange(in: text) else {
            return nil
        }
        let inner = String(text[range])
        // Strip the markers.
        guard inner.hasPrefix(markerStart), inner.hasSuffix(markerEnd) else {
            return nil
        }
        let base64 = String(inner.dropFirst(markerStart.count).dropLast(markerEnd.count))
        guard let data = Data(base64Encoded: base64),
              let wire = try? JSONDecoder().decode(WirePayload.self, from: data) else {
            return nil
        }
        // Reject versions we do not understand rather than mis-rendering them.
        guard wire.v == version else {
            return nil
        }
        let payload = Payload(slug: wire.s, text: wire.t, nameHidden: wire.h, transferId: wire.i, version: wire.v)
        // Only well-formed collectible slugs (the same format t.me/nft/<slug> uses) are gifts;
        // anything else would render a broken bubble.
        guard payload.isWellFormedSlug, wire.i != 0 else {
            return nil
        }
        return payload
    }

    /// Whether a message text carries a gift transfer marker at all (cheap pre-check before decode).
    public static func containsTransfer(_ text: String) -> Bool {
        return text.contains(markerStart) && text.contains(markerEnd)
    }

    /// Range of the full marker block (including both markers) in the text, or nil.
    private static func payloadRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: markerStart) else {
            return nil
        }
        guard let end = text.range(of: markerEnd, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return start.lowerBound..<end.upperBound
    }
}

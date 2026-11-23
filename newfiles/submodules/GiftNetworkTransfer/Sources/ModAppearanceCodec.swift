import Foundation

/// Codec for the visual-appearance marker carried in a user's bio ("about" field).
///
/// The bio is the only Telegram field the server syncs to EVERY viewer of a profile, so it is
/// the broadcast channel that makes a mod user's visual phone number and visual gifts visible
/// to other mod users — including ones they have never chatted with (the confirmed design).
///
/// Wire shape (plain, no base64 — readable slugs keep it compact and self-describing):
///
///     <U+200B><phone-digits>;<slug1>,<slug2>,...  [ ;<more-slugs> ]
///
/// - Prefix: U+200B zero-width space, so stock clients render nothing where it stands.
/// - Phone: optional digits of the visual number (formatted "+888 …" at display time); the
///   segment is empty when no visual number is set (";").
/// - Slugs: comma-separated collectible slugs (`^[A-Za-z0-9]+-[0-9]+$`, the t.me/nft space).
///   Viewers resolve each slug via `payments.getUniqueStarGift` exactly like the chat channel.
///
/// Budget: the bio limit is 70 characters (`maxAboutLength`, server "about_length_limit").
/// `encode` takes the user's own bio text and truncates the slug list (keeping the phone and
/// as many newest slugs as fit) so `original + marker` never exceeds the limit.
public enum ModAppearanceCodec {
    /// Zero-width space marking the start of the marker (invisible in stock clients).
    public static let prefix = "\u{200B}"

    /// Telegram's basic bio limit; the marker must share it with the user's own text.
    public static let bioLimit = 70

    /// The visual appearance a mod user publishes.
    public struct Appearance: Equatable, Codable {
        /// Visual phone number, digits only (formatted at display). Nil = no visual number.
        public let phone: String?
        /// Collectible slugs of the visual gifts, oldest first (last is newest).
        public let slugs: [String]

        public init(phone: String?, slugs: [String]) {
            self.phone = phone
            self.slugs = slugs
        }
    }

    /// Encode an appearance into the marker to append to the user's bio text. Returns the
    /// marker INCLUDING the prefix, or nil when nothing can be encoded (empty appearance).
    /// When `bioLimit` cannot hold the whole slug list, slugs are dropped from the front
    /// (newest kept) — the phone always survives.
    public static func encode(_ appearance: Appearance, originalBio: String) -> String? {
        let available = bioLimit - originalBio.count
        guard available > prefix.count else {
            return nil
        }

        // Phone segment: digits only, whatever length fits.
        let phoneDigits = appearance.phone?.filter { $0.isNumber } ?? ""

        // Try to fit as many slugs (from the newest end) as the budget allows.
        var keptSlugs: [String] = []
        var used = prefix.count + phoneDigits.count + (phoneDigits.isEmpty && appearance.slugs.isEmpty ? 0 : 1) // ';'
        for slug in appearance.slugs.reversed() {
            let cost = slug.count + (keptSlugs.isEmpty ? 0 : 1) // ',' between slugs
            if used + cost > available {
                break
            }
            keptSlugs.insert(slug, at: 0)
            used += cost
        }

        var hasPhoneSegment = false
        var marker = prefix
        if !phoneDigits.isEmpty {
            marker += phoneDigits
            hasPhoneSegment = true
        }
        if !keptSlugs.isEmpty || hasPhoneSegment {
            marker += ";"
        }
        marker += keptSlugs.joined(separator: ",")

        // Nothing meaningful encoded (no phone, no slugs): emit nothing.
        if !hasPhoneSegment && keptSlugs.isEmpty {
            return nil
        }
        return marker
    }

    /// The user's own bio text with any existing marker removed (what stock users would want
    /// to read; also the base text `encode` extends).
    public static func cleanBio(_ bio: String) -> String {
        guard let range = markerRange(in: bio) else {
            return bio
        }
        var result = bio
        result.removeSubrange(range)
        while result.hasSuffix(" ") {
            result.removeLast()
        }
        return result
    }

    /// Decode the appearance from a bio string, if it carries a marker.
    /// Invalid slugs (wrong format) are dropped; the phone is digits-only or nil.
    public static func decode(_ bio: String) -> Appearance? {
        guard let range = markerRange(in: bio) else {
            return nil
        }
        let marker = String(bio[range])
        guard marker.hasPrefix(prefix) else {
            return nil
        }
        let body = String(marker.dropFirst(prefix.count))
        guard !body.isEmpty else {
            return nil
        }

        let segments = body.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        // Format: [phone][;slugs]. A marker with a leading ';' has no phone; a trailing or
        // absent ';' means no slugs.
        let phonePart: String
        let slugsPart: String
        if segments.count == 2 {
            phonePart = String(segments[0])
            slugsPart = String(segments[1])
        } else {
            // No ';' at all: the whole body is ambiguous only when it contains no ',' and is
            // all digits (a phone); otherwise it is a slug list.
            if body.contains(",") || !body.isEmpty && !body.allSatisfy({ $0.isNumber }) {
                phonePart = ""
                slugsPart = body
            } else {
                phonePart = body
                slugsPart = ""
            }
        }

        let phone = phonePart.allSatisfy({ $0.isNumber }) && !phonePart.isEmpty ? phonePart : nil
        let slugs = slugsPart.split(separator: ",").map(String.init).filter { isWellFormedSlug($0) }
        if phone == nil && slugs.isEmpty {
            return nil
        }
        return Appearance(phone: phone, slugs: slugs)
    }

    /// Whether a bio carries a marker at all.
    public static func containsMarker(_ bio: String) -> Bool {
        return markerRange(in: bio) != nil
    }

    /// Whether a slug matches the collectible format Telegram itself uses (`^[A-Za-z0-9]+-[0-9]+$`).
    public static func isWellFormedSlug(_ slug: String) -> Bool {
        let parts = slug.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else {
            return false
        }
        return !parts[0].isEmpty && Int(parts[1]) != nil
    }

    /// Range of the marker block (prefix through end of bio or next non-marker content) in the
    /// bio. The marker is always the LAST run: it is appended at publish time. Stops at the
    /// first character that cannot be part of the marker.
    private static func markerRange(in bio: String) -> Range<String.Index>? {
        guard let start = bio.range(of: prefix) else {
            return nil
        }
        // Extend to the end of the bio: the encoder appends the marker last and everything it
        // emits (digits, ';', ',', slug characters, the prefix) is marker-safe.
        return start.lowerBound..<bio.endIndex
    }
}

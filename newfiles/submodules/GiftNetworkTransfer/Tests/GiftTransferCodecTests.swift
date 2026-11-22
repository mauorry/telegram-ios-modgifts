import Foundation
import XCTest
import GiftNetworkTransfer

final class GiftTransferCodecTests: XCTestCase {
    func testRoundTripPreservesAllFields() {
        let payload = GiftTransferCodec.Payload(slug: "PlushPepe-1", text: "Happy birthday!", nameHidden: false, transferId: 987654321)
        guard let encoded = GiftTransferCodec.encode(payload) else {
            XCTFail("encode returned nil")
            return
        }
        let message = "Here is a gift for you " + encoded
        guard let decoded = GiftTransferCodec.decode(message) else {
            XCTFail("decode returned nil")
            return
        }
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.slug, "PlushPepe-1")
    }

    func testRoundTripWithoutText() {
        let payload = GiftTransferCodec.Payload(slug: "Durov-8", text: nil, nameHidden: true, transferId: 1)
        guard let encoded = GiftTransferCodec.encode(payload), let decoded = GiftTransferCodec.decode(encoded) else {
            XCTFail("round trip failed")
            return
        }
        XCTAssertEqual(decoded, payload)
        XCTAssertNil(decoded.text)
        XCTAssertTrue(decoded.nameHidden)
    }

    func testVisibleTextStripsPayloadAndTrailingSpace() {
        let payload = GiftTransferCodec.Payload(slug: "PlushPepe-1", text: nil, nameHidden: false, transferId: 1)
        guard let encoded = GiftTransferCodec.encode(payload) else {
            XCTFail("encode returned nil")
            return
        }
        XCTAssertEqual(GiftTransferCodec.visibleText("Hello " + encoded), "Hello")
        XCTAssertEqual(GiftTransferCodec.visibleText(encoded), "")
        XCTAssertEqual(GiftTransferCodec.visibleText("No gift here"), "No gift here")
    }

    func testDisplayTextFallsBackToCollectibleLink() {
        // A stock client should still see a tappable NFT link when the message carries nothing else.
        let payload = GiftTransferCodec.Payload(slug: "PlushPepe-1", text: nil, nameHidden: false, transferId: 1)
        guard let encoded = GiftTransferCodec.encode(payload) else {
            XCTFail("encode returned nil")
            return
        }
        XCTAssertEqual(GiftTransferCodec.displayText(payload: payload, originalText: encoded), "t.me/nft/PlushPepe-1")
        // The sender's own caption wins over the generated link.
        XCTAssertEqual(GiftTransferCodec.displayText(payload: payload, originalText: "Enjoy! " + encoded), "Enjoy!")
    }

    func testSlugNumberExtraction() {
        XCTAssertEqual(GiftTransferCodec.Payload(slug: "PlushPepe-1234", text: nil, nameHidden: false, transferId: 1).slugNumber, 1234)
        XCTAssertNil(GiftTransferCodec.Payload(slug: "NoNumberHere", text: nil, nameHidden: false, transferId: 1).slugNumber)
        XCTAssertNil(GiftTransferCodec.Payload(slug: "Bad-NotANumber", text: nil, nameHidden: false, transferId: 1).slugNumber)
    }

    func testStockMessageHasNoTransfer() {
        XCTAssertFalse(GiftTransferCodec.containsTransfer("Just a normal message"))
        XCTAssertNil(GiftTransferCodec.decode("Just a normal message"))
        XCTAssertEqual(GiftTransferCodec.visibleText("Just a normal message"), "Just a normal message")
    }

    func testMalformedPayloadIsRejected() {
        // Markers present but the inner content is not valid base64 JSON.
        let bad = GiftTransferCodec.markerStart + "not-base64!!!" + GiftTransferCodec.markerEnd
        XCTAssertNil(GiftTransferCodec.decode(bad))
        // Valid base64 of invalid JSON.
        let badJson = Data("{not json".utf8).base64EncodedString()
        XCTAssertNil(GiftTransferCodec.decode(GiftTransferCodec.markerStart + badJson + GiftTransferCodec.markerEnd))
    }

    func testUnknownVersionIsRejected() {
        let json = "{\"v\":99,\"s\":\"PlushPepe-1\",\"h\":false,\"i\":1}"
        let encoded = GiftTransferCodec.markerStart + Data(json.utf8).base64EncodedString() + GiftTransferCodec.markerEnd
        XCTAssertNil(GiftTransferCodec.decode(encoded))
    }

    func testLegacyV1PayloadIsRejected() {
        // The v1 wire shape (giftId/number, no slug) must not decode under v2.
        let json = "{\"v\":1,\"g\":42,\"n\":7,\"h\":false,\"i\":1}"
        let encoded = GiftTransferCodec.markerStart + Data(json.utf8).base64EncodedString() + GiftTransferCodec.markerEnd
        XCTAssertNil(GiftTransferCodec.decode(encoded))
    }

    func testInvalidSlugAndTransferIdAreRejected() {
        func wrapped(_ json: String) -> String {
            return GiftTransferCodec.markerStart + Data(json.utf8).base64EncodedString() + GiftTransferCodec.markerEnd
        }
        // Empty slug.
        XCTAssertNil(GiftTransferCodec.decode(wrapped("{\"v\":2,\"s\":\"\",\"h\":false,\"i\":1}")))
        // No hyphen / no number part.
        XCTAssertNil(GiftTransferCodec.decode(wrapped("{\"v\":2,\"s\":\"PlushPepe\",\"h\":false,\"i\":1}")))
        XCTAssertNil(GiftTransferCodec.decode(wrapped("{\"v\":2,\"s\":\"Plush-ABC\",\"h\":false,\"i\":1}")))
        // Zero transfer id.
        XCTAssertNil(GiftTransferCodec.decode(wrapped("{\"v\":2,\"s\":\"PlushPepe-1\",\"h\":false,\"i\":0}")))
        // A well-formed slug must decode.
        XCTAssertNotNil(GiftTransferCodec.decode(wrapped("{\"v\":2,\"s\":\"PlushPepe-1\",\"h\":false,\"i\":1}")))
    }

    func testMarkersAreInvisibleZeroWidth() {
        XCTAssertEqual(GiftTransferCodec.markerStart, "\u{200B}")
        XCTAssertEqual(GiftTransferCodec.markerEnd, "\u{200C}")
    }

    func testPayloadStaysSmall() {
        // A worst-case payload (long accompanying text) must stay well under Telegram's
        // 4096-character message limit even after base64 expansion.
        let longText = String(repeating: "a", count: 500)
        let payload = GiftTransferCodec.Payload(slug: "PlushPepe-\(Int32.max)", text: longText, nameHidden: true, transferId: Int64.max)
        guard let encoded = GiftTransferCodec.encode(payload) else {
            XCTFail("encode returned nil")
            return
        }
        XCTAssertLessThan(encoded.count, 2000)
    }

    func testUnicodeTextSurvivesRoundTrip() {
        let payload = GiftTransferCodec.Payload(slug: "PlushPepe-1", text: "С днём рождения! 🎁✨", nameHidden: false, transferId: 555)
        guard let encoded = GiftTransferCodec.encode(payload), let decoded = GiftTransferCodec.decode("prefix " + encoded) else {
            XCTFail("round trip failed")
            return
        }
        XCTAssertEqual(decoded.text, "С днём рождения! 🎁✨")
    }
}

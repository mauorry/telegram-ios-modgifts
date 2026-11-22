import Foundation
import XCTest
import GiftNetworkTransfer

final class GiftTransferCodecTests: XCTestCase {
    func testRoundTripPreservesAllFields() {
        let payload = GiftTransferCodec.Payload(giftId: 5170145172328432345, number: 1234, text: "Happy birthday!", nameHidden: false, transferId: 987654321)
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
    }

    func testRoundTripWithoutText() {
        let payload = GiftTransferCodec.Payload(giftId: 42, number: 7, text: nil, nameHidden: true, transferId: 1)
        guard let encoded = GiftTransferCodec.encode(payload), let decoded = GiftTransferCodec.decode(encoded) else {
            XCTFail("round trip failed")
            return
        }
        XCTAssertEqual(decoded, payload)
        XCTAssertNil(decoded.text)
        XCTAssertTrue(decoded.nameHidden)
    }

    func testVisibleTextStripsPayloadAndTrailingSpace() {
        let payload = GiftTransferCodec.Payload(giftId: 1, number: 1, text: nil, nameHidden: false, transferId: 1)
        guard let encoded = GiftTransferCodec.encode(payload) else {
            XCTFail("encode returned nil")
            return
        }
        XCTAssertEqual(GiftTransferCodec.visibleText("Hello " + encoded), "Hello")
        XCTAssertEqual(GiftTransferCodec.visibleText(encoded), "")
        XCTAssertEqual(GiftTransferCodec.visibleText("No gift here"), "No gift here")
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
        // Hand-build a payload with a future version.
        let json = "{\"v\":99,\"g\":1,\"n\":1,\"h\":false,\"i\":1}"
        let encoded = GiftTransferCodec.markerStart + Data(json.utf8).base64EncodedString() + GiftTransferCodec.markerEnd
        XCTAssertNil(GiftTransferCodec.decode(encoded))
    }

    func testInvalidIdsAreRejected() {
        let zeroGift = "{\"v\":1,\"g\":0,\"n\":1,\"h\":false,\"i\":1}"
        XCTAssertNil(GiftTransferCodec.decode(GiftTransferCodec.markerStart + Data(zeroGift.utf8).base64EncodedString() + GiftTransferCodec.markerEnd))
        let zeroTransfer = "{\"v\":1,\"g\":1,\"n\":1,\"h\":false,\"i\":0}"
        XCTAssertNil(GiftTransferCodec.decode(GiftTransferCodec.markerStart + Data(zeroTransfer.utf8).base64EncodedString() + GiftTransferCodec.markerEnd))
    }

    func testMarkersAreInvisibleZeroWidth() {
        // The markers must be zero-width so a stock client renders nothing for them.
        XCTAssertEqual(GiftTransferCodec.markerStart, "\u{200B}")
        XCTAssertEqual(GiftTransferCodec.markerEnd, "\u{200C}")
    }

    func testPayloadStaysSmall() {
        // A worst-case payload (long accompanying text) must stay well under Telegram's
        // 4096-character message limit even after base64 expansion.
        let longText = String(repeating: "a", count: 500)
        let payload = GiftTransferCodec.Payload(giftId: Int64.max, number: Int32.max, text: longText, nameHidden: true, transferId: Int64.max)
        guard let encoded = GiftTransferCodec.encode(payload) else {
            XCTFail("encode returned nil")
            return
        }
        XCTAssertLessThan(encoded.count, 2000)
    }

    func testUnicodeTextSurvivesRoundTrip() {
        let payload = GiftTransferCodec.Payload(giftId: 7, number: 3, text: "С днём рождения! 🎁✨", nameHidden: false, transferId: 555)
        guard let encoded = GiftTransferCodec.encode(payload), let decoded = GiftTransferCodec.decode("prefix " + encoded) else {
            XCTFail("round trip failed")
            return
        }
        XCTAssertEqual(decoded.text, "С днём рождения! 🎁✨")
    }
}

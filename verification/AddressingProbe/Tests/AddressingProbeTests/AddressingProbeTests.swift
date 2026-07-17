import XCTest
@testable import AddressingProbe

final class AddressingProbeTests: XCTestCase {

    // Proves that addressing a peer's inbound session at (peer, 1) while its
    // outbound session was filed at (peer, realRegId) — exactly the Swift
    // MessengerActor split — breaks decryption of a real Whisper message, while
    // the correctly-matched address decrypts the identical ciphertext.
    func testAddressSplitBreaksSessionButMatchedAddressDecrypts() throws {
        let r = try AddressingProbe.run()

        // Preconditions that make the reproduction faithful and the address the
        // *only* variable between the two cases.
        XCTAssertTrue(r.replyMessageWasWhisper,
                      "The reply must be a plain Whisper (post-first-contact) message so it cannot self-establish a session on decrypt.")
        XCTAssertTrue(r.sessionExistsAtOutboundAddress,
                      "Bob's outbound session to Alice must exist at (alice, realRegId).")
        XCTAssertFalse(r.sessionExistsAtMismatchedAddress,
                       "Bob must have NO session at the buggy (alice, 1) address.")
        XCTAssertNotEqual(r.realRegistrationId, r.defaultedSenderRegId,
                          "The real registrationId and the defaulted senderRegId=1 must differ.")

        // (a) FAILING CASE — mismatched address, mirroring the bug.
        XCTAssertTrue(r.mismatchedDecryptThrew,
                      "Decrypt at mismatched \(r.mismatchedInboundAddressDescription) must FAIL (no session).")

        // (b) PASSING CONTROL — matched address decrypts the identical ciphertext.
        XCTAssertEqual(r.matchedDecryptPlaintext, "pong from alice",
                       "Decrypt at matched \(r.matchedInboundAddressDescription) must SUCCEED.")

        // Conclusion: the ADDRESS is the cause — same ciphertext, same store,
        // same session; only the deviceId slot of the lookup address differs.
        print("VERDICT: Swift send/receive address-split mechanism CONFIRMED at the libsignal level.")
        print("  outbound/encrypt address : \(r.outboundAddressDescription)")
        print("  buggy inbound address    : \(r.mismatchedInboundAddressDescription)  -> decrypt FAILED (\(r.mismatchedDecryptError ?? "?"))")
        print("  matched inbound address  : \(r.matchedInboundAddressDescription)  -> decrypt OK (\(r.matchedDecryptPlaintext ?? "?"))")
    }
}

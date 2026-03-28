import XCTest
import LibSignalClient
@testable import ObscuraKit

/// Verification codes (safety numbers) — derived from public keys
/// Codes must be deterministic, symmetric, and consistent across devices.
final class VerificationCodeTests: XCTestCase {

    // MARK: - Code format

    func testCodeFormat() {
        let key = Data(repeating: 0xAA, count: 33)
        let code = generateVerifyCode(from: key)

        XCTAssertEqual(code.count, 4, "Code should be 4 digits")
        XCTAssertTrue(code.allSatisfy { $0.isNumber }, "Code should be all digits")
    }

    // MARK: - Deterministic

    func testDeterministic() {
        let key = Data(repeating: 0xBB, count: 32)
        let code1 = generateVerifyCode(from: key)
        let code2 = generateVerifyCode(from: key)

        XCTAssertEqual(code1, code2, "Same key should produce same code")
    }

    // MARK: - Different keys produce different codes (usually)

    func testDifferentKeysUsuallyDifferent() {
        let key1 = Data(repeating: 0xCC, count: 32)
        let key2 = Data(repeating: 0xDD, count: 32)
        let code1 = generateVerifyCode(from: key1)
        let code2 = generateVerifyCode(from: key2)

        // Not guaranteed to be different (4-digit space), but overwhelmingly likely
        XCTAssertNotEqual(code1, code2, "Different keys should usually produce different codes")
    }

    // MARK: - Recovery key code is stable across devices

    func testRecoveryKeyCodeStableAcrossDevices() {
        // Recovery key is per-user, not per-device
        let recoveryKey = Data(repeating: 0xEE, count: 32)

        // Both devices of same user compute from same recovery key
        let device1Code = generateVerifyCodeFromRecoveryKey(recoveryKey)
        let device2Code = generateVerifyCodeFromRecoveryKey(recoveryKey)

        XCTAssertEqual(device1Code, device2Code, "Same recovery key → same code across devices")
    }

    // MARK: - Real key pair verification codes

    func testRealKeyPairCodes() {
        let aliceIdentity = IdentityKeyPair.generate()
        let bobIdentity = IdentityKeyPair.generate()

        let aliceCode = generateVerifyCode(from: Data(aliceIdentity.publicKey.serialize()))
        let bobCode = generateVerifyCode(from: Data(bobIdentity.publicKey.serialize()))

        XCTAssertEqual(aliceCode.count, 4)
        XCTAssertEqual(bobCode.count, 4)
        // Alice shows her code, Bob verifies it matches what he computes for Alice's key
        // This is the safety number check
    }

    // MARK: - Device list code changes when device added/removed

    func testDeviceListCodeChangesOnDeviceChange() {
        let dev1Key = Data(repeating: 0x11, count: 33)
        let dev2Key = Data(repeating: 0x22, count: 33)

        let oneDevice = generateVerifyCodeFromDevices([
            (deviceUUID: "uuid-1", signalIdentityKey: dev1Key),
        ])

        let twoDevices = generateVerifyCodeFromDevices([
            (deviceUUID: "uuid-1", signalIdentityKey: dev1Key),
            (deviceUUID: "uuid-2", signalIdentityKey: dev2Key),
        ])

        XCTAssertNotEqual(oneDevice, twoDevices, "Adding a device should change the code")
    }

    // MARK: - Device order doesn't matter (sorted by UUID)

    func testDeviceOrderDoesntMatter() {
        let dev1Key = Data(repeating: 0x11, count: 33)
        let dev2Key = Data(repeating: 0x22, count: 33)

        let order1 = generateVerifyCodeFromDevices([
            (deviceUUID: "aaa", signalIdentityKey: dev1Key),
            (deviceUUID: "bbb", signalIdentityKey: dev2Key),
        ])

        let order2 = generateVerifyCodeFromDevices([
            (deviceUUID: "bbb", signalIdentityKey: dev2Key),
            (deviceUUID: "aaa", signalIdentityKey: dev1Key),
        ])

        XCTAssertEqual(order1, order2, "Device order shouldn't affect code (sorted by UUID)")
    }
}

//
// AddressingProbe — a libsignal-level reproduction of the ObscuraKit-swift
// session-addressing split behind PLAN.md F1/F4.
//
// It depends ONLY on the vendored LibSignalClient. It does NOT depend on
// ObscuraKit, GRDB, or SQLCipher. It uses real libsignal sessions and the real
// encrypt/decrypt APIs — no invented wire fields, no workarounds.
//
// The claim under test (from code inspection of MessengerActor.swift):
//
//   Outbound (encrypt / processServerBundle) addresses a peer at
//       ProtocolAddress(name: peerUserId, deviceId: realRegistrationId)
//       // MessengerActor.swift:55  and  :71
//
//   Inbound (decrypt) addresses the SAME peer at
//       ProtocolAddress(name: peerUserId, deviceId: senderRegId /* defaults 1 */)
//       // MessengerActor.swift:121-122  (call site ObscuraClient.swift:1773 never
//       // overrides the default), so senderRegId == 1.
//
// => On one client the send-session and the receive-session for the same logical
//    peer live under DIFFERENT local ProtocolAddresses. This probe shows a real
//    Whisper message (the "every message after first contact" case of F4, which
//    carries no sender identity and cannot self-establish a session) fails to
//    decrypt at the mismatched (peer, 1) address and succeeds at the matched
//    (peer, realRegId) address.

import Foundation
import LibSignalClient

public struct ProbeResult {
    public let realRegistrationId: UInt32
    public let defaultedSenderRegId: UInt32

    public let outboundAddressDescription: String   // where Bob filed his session to Alice
    public let mismatchedInboundAddressDescription: String // buggy (peer, 1)
    public let matchedInboundAddressDescription: String    // control (peer, realRegId)

    public let replyMessageWasWhisper: Bool   // proves it is a post-first-contact message

    public let mismatchedDecryptThrew: Bool   // buggy case: expected to FAIL
    public let mismatchedDecryptError: String?

    public let matchedDecryptPlaintext: String?  // control case: expected to SUCCEED

    public let sessionExistsAtOutboundAddress: Bool
    public let sessionExistsAtMismatchedAddress: Bool
}

public enum AddressingProbe {

    /// Faithful minimal reproduction of the Swift send/receive address split.
    ///
    /// Roles, from BOB's client store (we probe how Bob addresses his peer Alice):
    ///  A. Bob builds an OUTBOUND session to Alice from her prekey bundle and
    ///     encrypts a first message — mirroring `processServerBundle` + `encrypt`,
    ///     both of which address Alice at (aliceUserId, aliceRealRegId).
    ///  B. Alice decrypts it (establishing her side) and REPLIES. Because Alice now
    ///     has a session, her reply is a plain Whisper `SignalMessage` (type 2),
    ///     NOT a PreKeySignalMessage — it cannot self-establish a session on decrypt.
    ///  C. Bob receives Alice's reply and must decrypt it. `decrypt(...)` addresses
    ///     the sender at (aliceUserId, senderRegId) with senderRegId defaulting to 1.
    ///       - mismatched (bug):    (aliceUserId, 1)            -> no session -> throws
    ///       - matched  (control):  (aliceUserId, aliceRealRegId) -> session -> succeeds
    public static func run(log: (String) -> Void = { print($0) }) throws -> ProbeResult {
        let aliceUserId = "alice-11111111-1111-1111-1111-111111111111"
        let bobUserId   = "bob-22222222-2222-2222-2222-222222222222"

        // Real per-device registration ids are random 14-bit values (0...0x3FFF).
        let aliceRealRegId: UInt32 = 12345
        let bobRealRegId: UInt32   = 6789
        let defaultedSenderRegId: UInt32 = 1   // MessengerActor.decrypt default

        // In-memory stores (LibSignalClient's own). No persistence, no GRDB.
        let aliceIdentity = IdentityKeyPair.generate()
        let bobIdentity   = IdentityKeyPair.generate()
        let aliceStore = InMemorySignalProtocolStore(identity: aliceIdentity, registrationId: aliceRealRegId)
        let bobStore   = InMemorySignalProtocolStore(identity: bobIdentity, registrationId: bobRealRegId)
        let ctx = NullContext()

        log("=== AddressingProbe: libsignal-level reproduction of the Swift F1/F4 address split ===")
        log("aliceUserId = \(aliceUserId)")
        log("bobUserId   = \(bobUserId)")
        log("alice real registrationId = \(aliceRealRegId)   (a genuine 14-bit per-device id)")
        log("bob   real registrationId = \(bobRealRegId)")
        log("decrypt() senderRegId default = \(defaultedSenderRegId)   (MessengerActor.swift:121)")
        log("")

        // --- Alice publishes a prekey bundle (as the server would return it). ---
        let signedPreKeyPriv = PrivateKey.generate()
        let signedPreKeyPub  = signedPreKeyPriv.publicKey
        let signedPreKeySig  = aliceIdentity.privateKey.generateSignature(message: signedPreKeyPub.serialize())
        let signedPreKeyId: UInt32 = 1
        try aliceStore.storeSignedPreKey(
            SignedPreKeyRecord(id: signedPreKeyId,
                               timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                               privateKey: signedPreKeyPriv,
                               signature: signedPreKeySig),
            id: signedPreKeyId, context: ctx)

        let oneTimePreKeyPriv = PrivateKey.generate()
        let oneTimePreKeyId: UInt32 = 1
        try aliceStore.storePreKey(
            PreKeyRecord(id: oneTimePreKeyId, privateKey: oneTimePreKeyPriv),
            id: oneTimePreKeyId, context: ctx)

        // deviceId == regId, exactly as MessengerActor.processServerBundle builds it
        // (PreKeyBundle(registrationId: regId, deviceId: regId, ...), :98/:105).
        let aliceBundle = try PreKeyBundle(
            registrationId: aliceRealRegId,
            deviceId: aliceRealRegId,
            prekeyId: oneTimePreKeyId,
            prekey: oneTimePreKeyPriv.publicKey,
            signedPrekeyId: signedPreKeyId,
            signedPrekey: signedPreKeyPub,
            signedPrekeySignature: signedPreKeySig,
            identity: aliceIdentity.identityKey)

        // --- A. Bob builds the OUTBOUND session to Alice, at (alice, realRegId). ---
        //     Mirrors MessengerActor.processServerBundle:71 and encrypt:55.
        let outboundAddress = try ProtocolAddress(name: aliceUserId, deviceId: aliceRealRegId)
        log("[A] Bob processes Alice's bundle + encrypts at OUTBOUND address: \(describe(outboundAddress))")
        try processPreKeyBundle(aliceBundle, for: outboundAddress,
                                sessionStore: bobStore, identityStore: bobStore, context: ctx)
        let bobFirst = try signalEncrypt(message: Array("ping from bob".utf8),
                                         for: outboundAddress,
                                         sessionStore: bobStore, identityStore: bobStore, context: ctx)
        log("    Bob's first ciphertext type = \(name(bobFirst.messageType)) (PreKey / first contact)")

        // --- B. Alice decrypts Bob's first message, then REPLIES with a Whisper. ---
        let bobAddressOnAlice = try ProtocolAddress(name: bobUserId, deviceId: bobRealRegId)
        let bobFirstPKM = try PreKeySignalMessage(bytes: bobFirst.serialize())
        let gotByAlice = try signalDecryptPreKey(message: bobFirstPKM, from: bobAddressOnAlice,
                                                 sessionStore: aliceStore, identityStore: aliceStore,
                                                 preKeyStore: aliceStore, signedPreKeyStore: aliceStore,
                                                 kyberPreKeyStore: aliceStore, context: ctx)
        log("[B] Alice decrypted Bob's first message: \"\(String(decoding: gotByAlice, as: UTF8.self))\"")

        let aliceReply = try signalEncrypt(message: Array("pong from alice".utf8),
                                           for: bobAddressOnAlice,
                                           sessionStore: aliceStore, identityStore: aliceStore, context: ctx)
        let replyIsWhisper = aliceReply.messageType == .whisper
        log("    Alice's reply ciphertext type = \(name(aliceReply.messageType)) " +
            "(Whisper => post-first-contact; carries NO sender identity, cannot self-establish)")
        let replyBytes = aliceReply.serialize()

        // Visibility: what sessions does Bob actually hold for peer Alice?
        let sessOut = (try? bobStore.loadSession(for: outboundAddress, context: ctx)) ?? nil
        let mismatchedInboundAddress = try ProtocolAddress(name: aliceUserId, deviceId: defaultedSenderRegId)
        let sessMismatch = (try? bobStore.loadSession(for: mismatchedInboundAddress, context: ctx)) ?? nil
        log("")
        log("Bob's session store for peer Alice:")
        log("    session at \(describe(outboundAddress))  = \(sessOut == nil ? "NONE" : "PRESENT")")
        log("    session at \(describe(mismatchedInboundAddress))       = \(sessMismatch == nil ? "NONE" : "PRESENT")")
        log("")

        // --- C. Bob receives Alice's reply. Decrypt is a plain Whisper SignalMessage. ---

        // (a) FAILING CASE — mismatched address (alice, 1), mirroring the bug.
        var mismatchedThrew = false
        var mismatchedError: String? = nil
        do {
            let msg = try SignalMessage(bytes: replyBytes)
            let out = try signalDecrypt(message: msg, from: mismatchedInboundAddress,
                                        sessionStore: bobStore, identityStore: bobStore, context: ctx)
            log("[C-bug] decrypt at \(describe(mismatchedInboundAddress)) UNEXPECTEDLY succeeded: " +
                "\"\(String(decoding: out, as: UTF8.self))\"")
        } catch {
            mismatchedThrew = true
            mismatchedError = "\(error)"
            log("[C-bug] decrypt at \(describe(mismatchedInboundAddress)) FAILED as expected: \(error)")
        }

        // (b) PASSING CONTROL — matched address (alice, realRegId).
        var matchedPlaintext: String? = nil
        do {
            let msg = try SignalMessage(bytes: replyBytes)
            let out = try signalDecrypt(message: msg, from: outboundAddress,
                                        sessionStore: bobStore, identityStore: bobStore, context: ctx)
            matchedPlaintext = String(decoding: out, as: UTF8.self)
            log("[C-control] decrypt at \(describe(outboundAddress)) SUCCEEDED: \"\(matchedPlaintext!)\"")
        } catch {
            log("[C-control] decrypt at \(describe(outboundAddress)) unexpectedly FAILED: \(error)")
        }
        log("")

        return ProbeResult(
            realRegistrationId: aliceRealRegId,
            defaultedSenderRegId: defaultedSenderRegId,
            outboundAddressDescription: describe(outboundAddress),
            mismatchedInboundAddressDescription: describe(mismatchedInboundAddress),
            matchedInboundAddressDescription: describe(outboundAddress),
            replyMessageWasWhisper: replyIsWhisper,
            mismatchedDecryptThrew: mismatchedThrew,
            mismatchedDecryptError: mismatchedError,
            matchedDecryptPlaintext: matchedPlaintext,
            sessionExistsAtOutboundAddress: sessOut != nil,
            sessionExistsAtMismatchedAddress: sessMismatch != nil)
    }

    private static func describe(_ a: ProtocolAddress) -> String {
        "ProtocolAddress(name: \(a.name), deviceId: \(a.deviceId))"
    }

    private static func name(_ t: CiphertextMessage.MessageType) -> String {
        switch t {
        case .whisper: return "Whisper(\(t.rawValue))"
        case .preKey:  return "PreKey(\(t.rawValue))"
        default:       return "type(\(t.rawValue))"
        }
    }
}

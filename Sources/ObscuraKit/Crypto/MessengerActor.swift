import Foundation
import LibSignalClient
import SwiftProtobuf

/// MessengerActor — encrypt, decrypt, queue, flush messages.
/// Mirrors src/v2/lib/messenger.js
public actor MessengerActor {
    private let api: APIClient
    private let identityStore: IdentityKeyStore
    private let preKeyStore: PreKeyStore
    private let signedPreKeyStore: SignedPreKeyStore
    private let sessionStore: SessionStore
    private let kyberPreKeyStore: KyberPreKeyStore
    private let ownUserId: String

    // Device map: deviceId → (userId, registrationId)
    private var deviceMap: [String: (userId: String, registrationId: UInt32)] = [:]

    // Message queue for batch sending
    private var queue: [(submissionId: Data, deviceId: Data, message: Data)] = []

    public init(api: APIClient, store: PersistentSignalStore, ownUserId: String) {
        self.api = api
        self.identityStore = store
        self.preKeyStore = store
        self.signedPreKeyStore = store
        self.sessionStore = store
        self.kyberPreKeyStore = store
        self.ownUserId = ownUserId
    }

    // MARK: - Device Mapping

    public func mapDevice(_ deviceId: String, userId: String, registrationId: UInt32) {
        deviceMap[deviceId] = (userId: userId, registrationId: registrationId)
    }

    // MARK: - PreKey Bundle Fetching

    /// Fetch prekey bundles for all devices of a user, auto-populate device map
    public func fetchPreKeyBundles(_ userId: String) async throws -> [[String: Any]] {
        let bundles = try await api.fetchPreKeyBundles(userId)

        for bundle in bundles {
            if let deviceId = bundle["deviceId"] as? String,
               let regId = bundle["registrationId"] as? Int {
                deviceMap[deviceId] = (userId: userId, registrationId: UInt32(regId))
            }
        }

        return bundles
    }

    // MARK: - Encryption

    /// Encrypt plaintext for a target user at a specific address
    public func encrypt(_ targetUserId: String, _ plaintext: [UInt8], registrationId: UInt32) throws -> (type: CiphertextMessage.MessageType, body: [UInt8]) {
        let address = try ProtocolAddress(name: targetUserId, deviceId: registrationId)

        let ciphertext = try signalEncrypt(
            message: plaintext,
            for: address,
            sessionStore: sessionStore,
            identityStore: identityStore,
            context: NullContext()
        )

        return (type: ciphertext.messageType, body: Array(ciphertext.serialize()))
    }

    /// Establish session from prekey bundle data (as returned by server)
    public func processServerBundle(_ bundleData: [String: Any], userId: String) throws {
        guard let regId = bundleData["registrationId"] as? Int else {
            throw MessengerError.invalidBundle("missing registrationId")
        }
        let address = try ProtocolAddress(name: userId, deviceId: UInt32(regId))

        // Parse keys from base64
        guard let identityKeyB64 = bundleData["identityKey"] as? String,
              let identityKeyData = Data(base64Encoded: identityKeyB64) else {
            throw MessengerError.invalidBundle("missing identityKey")
        }

        guard let spk = bundleData["signedPreKey"] as? [String: Any],
              let spkPubB64 = spk["publicKey"] as? String,
              let spkPubData = Data(base64Encoded: spkPubB64),
              let spkSigB64 = spk["signature"] as? String,
              let spkSigData = Data(base64Encoded: spkSigB64),
              let spkId = spk["keyId"] as? Int else {
            throw MessengerError.invalidBundle("missing signedPreKey")
        }

        let identityKey = try IdentityKey(bytes: Array(identityKeyData))
        let signedPreKeyPublic = try PublicKey(Array(spkPubData))

        // One-time pre-key (optional)
        var preKeyPublic: PublicKey? = nil
        var preKeyId: UInt32 = ~0
        if let otpk = bundleData["oneTimePreKey"] as? [String: Any],
           let otpkPubB64 = otpk["publicKey"] as? String,
           let otpkPubData = Data(base64Encoded: otpkPubB64),
           let otpkId = otpk["keyId"] as? Int {
            preKeyPublic = try PublicKey(Array(otpkPubData))
            preKeyId = UInt32(otpkId)
        }

        let bundle: PreKeyBundle
        if let preKeyPublic = preKeyPublic {
            bundle = try PreKeyBundle(
                registrationId: UInt32(regId),
                deviceId: UInt32(regId),
                prekeyId: preKeyId,
                prekey: preKeyPublic,
                signedPrekeyId: UInt32(spkId),
                signedPrekey: signedPreKeyPublic,
                signedPrekeySignature: Array(spkSigData),
                identity: identityKey
            )
        } else {
            bundle = try PreKeyBundle(
                registrationId: UInt32(regId),
                deviceId: UInt32(regId),
                signedPrekeyId: UInt32(spkId),
                signedPrekey: signedPreKeyPublic,
                signedPrekeySignature: Array(spkSigData),
                identity: identityKey
            )
        }

        try LibSignalClient.processPreKeyBundle(
            bundle,
            for: address,
            sessionStore: sessionStore,
            identityStore: identityStore,
            context: NullContext()
        )
    }

    // MARK: - Decryption

    /// Decrypt an envelope's encrypted message
    public func decrypt(sourceUserId: String, content: Data, messageType: Int, senderRegId: UInt32 = 1) throws -> [UInt8] {
        let address = try ProtocolAddress(name: sourceUserId, deviceId: senderRegId)

        if messageType == 1 {
            // PreKey message
            let preKeyMessage = try PreKeySignalMessage(bytes: Array(content))
            return try signalDecryptPreKey(
                message: preKeyMessage,
                from: address,
                sessionStore: sessionStore,
                identityStore: identityStore,
                preKeyStore: preKeyStore,
                signedPreKeyStore: signedPreKeyStore,
                kyberPreKeyStore: kyberPreKeyStore,
                context: NullContext()
            )
        } else {
            // Whisper message
            let signalMessage = try SignalMessage(bytes: Array(content))
            return try signalDecrypt(
                message: signalMessage,
                from: address,
                sessionStore: sessionStore,
                identityStore: identityStore,
                context: NullContext()
            )
        }
    }

    // MARK: - Message Queuing

    /// Encode a ClientMessage, encrypt it, wrap in EncryptedMessage, queue for sending
    /// Queue a message for batch sending. clientMessage is the protobuf payload.
    public func queueMessage(targetDeviceId: String, clientMessageData: Data, targetUserId: String? = nil) throws {
        // Resolve target
        let mapping = deviceMap[targetDeviceId]
        let userId = targetUserId ?? mapping?.userId ?? targetDeviceId
        guard let regId = mapping?.registrationId else {
            throw MessengerError.invalidBundle("missing device mapping for \(targetDeviceId)")
        }

        // Use pre-serialized ClientMessage bytes
        let plaintext = Array(clientMessageData)

        // Encrypt
        let encrypted = try encrypt(userId, plaintext, registrationId: regId)

        // Wrap in EncryptedMessage protobuf
        var encMsg = Obscura_V2_EncryptedMessage()
        encMsg.type = encrypted.type == .preKey ? .prekeyMessage : .encryptedMessage
        encMsg.content = Data(encrypted.body)

        let encMsgBytes = try encMsg.serializedData()

        // Generate submission ID (UUID as 16 bytes)
        let submissionId = uuidToBytes(UUID().uuidString)
        let deviceIdBytes = uuidToBytes(targetDeviceId)

        queue.append((submissionId: submissionId, deviceId: deviceIdBytes, message: encMsgBytes))
    }

    /// Send all queued messages in a single batch
    public func flushMessages() async throws -> (sent: Int, failed: Int) {
        guard !queue.isEmpty else { return (0, 0) }

        let batch = queue
        queue.removeAll()

        var request = Obscura_V1_SendMessageRequest()
        for item in batch {
            var submission = Obscura_V1_SendMessageRequest.Submission()
            submission.submissionID = item.submissionId
            submission.deviceID = item.deviceId
            submission.message = item.message
            request.messages.append(submission)
        }

        let data = try request.serializedData()
        try await api.sendMessage(data)

        return (sent: batch.count, failed: 0)
    }

    // MARK: - Helpers

    private func uuidToBytes(_ uuid: String) -> Data {
        let cleaned = uuid.replacingOccurrences(of: "-", with: "")
        guard cleaned.count == 32 else { return Data(repeating: 0, count: 16) }
        var bytes = Data(count: 16)
        for i in 0..<16 {
            let start = cleaned.index(cleaned.startIndex, offsetBy: i * 2)
            let end = cleaned.index(start, offsetBy: 2)
            bytes[i] = UInt8(cleaned[start..<end], radix: 16) ?? 0
        }
        return bytes
    }

    public enum MessengerError: Error {
        case invalidBundle(String)
        case noSession(String)
        case encryptionFailed(String)
    }
}

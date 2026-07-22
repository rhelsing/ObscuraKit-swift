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
    public func fetchPreKeyBundles(_ userId: String) async throws -> [PreKeyBundleResponse] {
        let bundles = try await api.fetchPreKeyBundles(userId)

        for bundle in bundles {
            deviceMap[bundle.deviceId] = (userId: userId, registrationId: UInt32(bundle.registrationId))
        }

        return bundles
    }

    // MARK: - Addressing (Phase 2)

    /// The deviceId slot of every ProtocolAddress. Constant because the device UUID in the name
    /// slot already uniquely identifies the peer device; libsignal just needs SOME stable int here.
    static let addrDeviceId: UInt32 = 1

    /// THE single ProtocolAddress constructor for a peer device, used by BOTH send
    /// (queueMessage/encrypt/processServerBundle) and receive (decrypt). name = device UUID,
    /// deviceId = constant. A ProtocolAddress is a purely LOCAL store key that is never
    /// transmitted. If send and receive ever built different addresses for the same device the
    /// bidirectional session would split — this function is why they cannot. (Mirrors Kotlin
    /// MessengerDomain.addressFor.)
    static func addressFor(_ deviceUuid: String) throws -> ProtocolAddress {
        try ProtocolAddress(name: deviceUuid, deviceId: addrDeviceId)
    }

    /// Enumerate the device UUIDs known for a user (for session-reset fan-out). The registrationId
    /// slot of deviceMap is diagnostic only; addressing is by device UUID.
    public func getDeviceIdsForUser(_ userId: String) -> [String] {
        deviceMap.filter { $0.value.userId == userId }.map { $0.key }
    }

    // MARK: - Encryption

    /// Encrypt plaintext for a target peer DEVICE, addressed by its device UUID (Phase 2).
    public func encrypt(deviceUuid: String, _ plaintext: [UInt8]) throws -> (type: CiphertextMessage.MessageType, body: [UInt8]) {
        let address = try Self.addressFor(deviceUuid)

        let ciphertext = try signalEncrypt(
            message: plaintext,
            for: address,
            sessionStore: sessionStore,
            identityStore: identityStore,
            context: NullContext()
        )

        return (type: ciphertext.messageType, body: Array(ciphertext.serialize()))
    }

    /// Establish an outbound session from a prekey bundle response.
    /// Phase 2: the session is keyed on the peer's DEVICE UUID at address (deviceUuid, 1) — the
    /// SAME address decrypt() uses inbound — killing the old send/receive address split (F1). The
    /// peer's real registrationId is still carried INSIDE the PreKeyBundle (Signal metadata), but
    /// the bundle's deviceId slot is pinned to the addressing constant to match the store address.
    public func processServerBundle(_ bundleData: PreKeyBundleResponse, userId: String) throws {
        let regId = UInt32(bundleData.registrationId)
        let address = try Self.addressFor(bundleData.deviceId)
        // Learn the device -> user mapping so getDeviceIdsForUser can enumerate this user's devices.
        deviceMap[bundleData.deviceId] = (userId: userId, registrationId: regId)

        guard let identityKeyData = Data(base64Encoded: bundleData.identityKey) else {
            throw MessengerError.invalidBundle("invalid identityKey base64")
        }

        let spk = bundleData.signedPreKey
        guard let spkPubData = Data(base64Encoded: spk.publicKey),
              let spkSigData = Data(base64Encoded: spk.signature) else {
            throw MessengerError.invalidBundle("invalid signedPreKey base64")
        }

        let identityKey = try IdentityKey(bytes: Array(identityKeyData))
        let signedPreKeyPublic = try PublicKey(Array(spkPubData))

        // One-time pre-key (optional)
        var preKeyPublic: PublicKey? = nil
        var preKeyId: UInt32 = ~0
        if let otpk = bundleData.oneTimePreKey,
           let otpkPubData = Data(base64Encoded: otpk.publicKey) {
            preKeyPublic = try PublicKey(Array(otpkPubData))
            preKeyId = UInt32(otpk.keyId)
        }

        let bundle: PreKeyBundle
        if let preKeyPublic = preKeyPublic {
            bundle = try PreKeyBundle(
                registrationId: regId, deviceId: Self.addrDeviceId,
                prekeyId: preKeyId, prekey: preKeyPublic,
                signedPrekeyId: UInt32(spk.keyId), signedPrekey: signedPreKeyPublic,
                signedPrekeySignature: Array(spkSigData), identity: identityKey
            )
        } else {
            bundle = try PreKeyBundle(
                registrationId: regId, deviceId: Self.addrDeviceId,
                signedPrekeyId: UInt32(spk.keyId), signedPrekey: signedPreKeyPublic,
                signedPrekeySignature: Array(spkSigData), identity: identityKey
            )
        }

        try LibSignalClient.processPreKeyBundle(
            bundle, for: address,
            sessionStore: sessionStore, identityStore: identityStore,
            context: NullContext()
        )
    }

    // MARK: - Decryption

    /// Decrypt an envelope's encrypted message.
    ///
    /// Phase 2 receive-side addressing. The caller passes the SENDER'S DEVICE UUID (from
    /// `Envelope.senderDeviceID`, stamped by the server from the device-scoped JWT — unforgeable
    /// by the sender). Signal sessions are pairwise device-to-device and a SignalMessage carries
    /// no sender identity, so this is how we select the inbound session. There is no
    /// candidate-registrationId loop and no `senderRegId: 1` default anymore — the address is the
    /// SAME (deviceUuid, 1) the send path builds, closing the F1 split.
    ///
    /// A valid MAC proves possession of that session's chain key, which only the sender's device
    /// holds, so `senderDeviceUuid` is a cryptographically sound attribution once decrypt succeeds.
    public func decrypt(senderUserId: String, senderDeviceUuid: String, content: Data, messageType: Int) throws -> [UInt8] {
        let address = try Self.addressFor(senderDeviceUuid)

        let plaintext: [UInt8]
        if messageType == 1 {
            // PreKey message
            let preKeyMessage = try PreKeySignalMessage(bytes: Array(content))
            plaintext = try signalDecryptPreKey(
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
            plaintext = try signalDecrypt(
                message: signalMessage,
                from: address,
                sessionStore: sessionStore,
                identityStore: identityStore,
                context: NullContext()
            )
        }

        // Learn the sender's device so later fan-out to this user includes it (F6). The regId slot
        // is diagnostic only; addressing is by device UUID.
        if deviceMap[senderDeviceUuid] == nil {
            deviceMap[senderDeviceUuid] = (userId: senderUserId, registrationId: Self.addrDeviceId)
        }

        return plaintext
    }

    // MARK: - Message Queuing

    /// Encode a ClientMessage, encrypt it, wrap in EncryptedMessage, queue for sending
    /// Queue a message for batch sending. clientMessage is the protobuf payload.
    public func queueMessage(targetDeviceId: String, clientMessageData: Data, targetUserId: String? = nil) throws {
        // targetDeviceId IS the peer's device UUID — the address name slot (see addressFor).
        // The session must already exist (processServerBundle built it at the same (deviceUuid, 1)
        // address); encrypt throws if it does not. The owning userId is retained only so
        // getDeviceIdsForUser can enumerate the user's devices for fan-out; it is NOT an address.
        if let uid = targetUserId, deviceMap[targetDeviceId] == nil {
            deviceMap[targetDeviceId] = (userId: uid, registrationId: Self.addrDeviceId)
        }

        // Use pre-serialized ClientMessage bytes
        let plaintext = Array(clientMessageData)

        // Encrypt (addressed by device UUID, Phase 2)
        let encrypted = try encrypt(deviceUuid: targetDeviceId, plaintext)

        // Wrap in EncryptedMessage protobuf
        var encMsg = Obscura_Client_V1_EncryptedMessage()
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

        do {
            try await api.sendMessage(data)
        } catch {
            // Restore batch to queue so retry is possible
            queue.insert(contentsOf: batch, at: 0)
            throw error
        }

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

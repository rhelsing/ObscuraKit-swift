import Foundation

/// Manages ORM model sync — auto fan-out on create, routing on receive.
/// Mirrors src/v2/orm/sync/SyncManager.js
public class SyncManager {
    private var models: [String: Model] = [:]
    private weak var client: ObscuraClient?

    public init(client: ObscuraClient) {
        self.client = client
    }

    /// Register a model for sync.
    public func register(_ name: String, _ model: Model) {
        models[name] = model

        // Wire up the broadcast callback
        model.onBroadcast = { [weak self] modelName, entry in
            await self?.broadcast(modelName, entry)
        }

        // Wire up model resolver for include() eager loading
        model.modelResolver = { [weak self] childName in
            self?.models[childName]
        }

        // Wire up signal sending
        model.onSignalSend = { [weak self] msgData in
            await self?.broadcastSignal(msgData)
        }
    }

    /// Broadcast a signal (MODEL_SIGNAL) to all friends.
    private func broadcastSignal(_ msgData: Data) async {
        guard let client = client else { return }
        let friends = await client.friends.getAccepted()
        for friend in friends {
            do {
                try await client.sendRawMessage(to: friend.userId, clientMessageData: msgData)
            } catch {
                // Signals are best-effort — don't crash on failure
            }
        }
    }

    /// Get a registered model by name.
    public func getModel(_ name: String) -> Model? {
        models[name]
    }

    /// All registered model names.
    public var modelNames: [String] { Array(models.keys) }

    // MARK: - Broadcast (outgoing)

    /// Broadcast a model entry to the appropriate targets based on sync scope.
    private func broadcast(_ modelName: String, _ entry: ModelEntry) async {
        guard let client = client, let model = models[modelName] else { return }

        let scope = model.definition.syncScope
        let isPrivate = model.definition.isPrivate

        // Check connection health before attempting broadcast
        if client.connectionState == .disconnected {
            client.logger.log("BROADCAST: connection dead, attempting reconnect before send")
            try? await client.connect()
            if client.connectionState != .connected {
                client.logger.log("BROADCAST: reconnect failed, message saved locally only")
            }
        }

        // Build the serialized data
        let data: Data
        if let jsonData = try? JSONSerialization.data(withJSONObject: entry.data) {
            data = jsonData
        } else {
            data = Data()
        }

        do {
            switch scope {
            case .ownDevices:
                // Private models — only sync to own devices via self-sync
                try await client.sendModelSync(
                    toSelf: true,
                    model: modelName,
                    entryId: entry.id,
                    op: entry.isDeleted ? "DELETE" : "CREATE",
                    data: data,
                    timestamp: entry.timestamp,
                    authorDeviceId: entry.authorDeviceId,
                    signature: entry.signature
                )

            case .friends:
                if isPrivate {
                    // Private flag overrides — own devices only
                    try await client.sendModelSync(
                        toSelf: true,
                        model: modelName,
                        entryId: entry.id,
                        op: entry.isDeleted ? "DELETE" : "CREATE",
                        data: data,
                        timestamp: entry.timestamp,
                        authorDeviceId: entry.authorDeviceId,
                        signature: entry.signature
                    )
                } else if let scopedRecipients = await resolveScopedRecipients(entry) {
                    // Scoped 1:1 / direct-recipient delivery (directMessage, pix).
                    // These carry their intended audience in their own data; broadcasting
                    // them to all friends leaks private 1:1 payloads to every mutual friend.
                    for userId in scopedRecipients {
                        try await client.sendModelSync(
                            to: userId,
                            model: modelName,
                            entryId: entry.id,
                            op: entry.isDeleted ? "DELETE" : "CREATE",
                            data: data,
                            timestamp: entry.timestamp,
                            authorDeviceId: entry.authorDeviceId,
                            signature: entry.signature
                        )
                    }
                    // Self-sync so the sender's own other devices get it too.
                    try await client.sendModelSync(
                        toSelf: true,
                        model: modelName,
                        entryId: entry.id,
                        op: entry.isDeleted ? "DELETE" : "CREATE",
                        data: data,
                        timestamp: entry.timestamp,
                        authorDeviceId: entry.authorDeviceId,
                        signature: entry.signature
                    )
                } else {
                    // Broadcast to all friends + self-sync to own devices
                    let friends = await client.friends.getAccepted()
                    for friend in friends {
                        try await client.sendModelSync(
                            to: friend.userId,
                            model: modelName,
                            entryId: entry.id,
                            op: entry.isDeleted ? "DELETE" : "CREATE",
                            data: data,
                            timestamp: entry.timestamp,
                            authorDeviceId: entry.authorDeviceId,
                            signature: entry.signature
                        )
                    }
                    // Also self-sync so other own devices get it
                    try await client.sendModelSync(
                        toSelf: true,
                        model: modelName,
                        entryId: entry.id,
                        op: entry.isDeleted ? "DELETE" : "CREATE",
                        data: data,
                        timestamp: entry.timestamp,
                        authorDeviceId: entry.authorDeviceId,
                        signature: entry.signature
                    )
                }

            case .group:
                // Group-targeted: look up parent model's members field
                let memberUserIds = await resolveGroupMembers(model: model, entry: entry)
                for memberId in memberUserIds {
                    try await client.sendModelSync(
                        to: memberId,
                        model: modelName,
                        entryId: entry.id,
                        op: entry.isDeleted ? "DELETE" : "CREATE",
                        data: data,
                        timestamp: entry.timestamp,
                        authorDeviceId: entry.authorDeviceId,
                        signature: entry.signature
                    )
                }
                // Self-sync
                try await client.sendModelSync(
                    toSelf: true,
                    model: modelName,
                    entryId: entry.id,
                    op: entry.isDeleted ? "DELETE" : "CREATE",
                    data: data,
                    timestamp: entry.timestamp,
                    authorDeviceId: entry.authorDeviceId,
                    signature: entry.signature
                )
            }
        } catch {
            // Log through the client's logger so the app can see failures in the debug log.
            // flushMessages() restores the queue on failure, so messages aren't lost locally.
            client.logger.log("BROADCAST FAILED \(modelName)/\(entry.id.prefix(20)): \(error.localizedDescription)")
        }
    }

    // MARK: - Scoped 1:1 / Direct Recipient Resolution

    /// Recipients for an entry whose audience is a single user or a 1:1 conversation,
    /// or nil if the entry declares no such scoping (→ caller broadcasts to all friends).
    ///
    ///  - data.recipientUsername (e.g. pix) → that friend's userId
    ///  - data.conversationId "userIdA_userIdB" (canonical 1:1 id) → the participant(s) who are friends
    ///
    /// Self is always covered separately by the toSelf self-sync, so self ids are excluded here.
    /// Mirrors Kotlin SyncManager.resolveScopedRecipients.
    private func resolveScopedRecipients(_ entry: ModelEntry) async -> [String]? {
        guard let client = client else { return nil }

        // pix and similar: single recipient identified by username
        if let username = entry.data["recipientUsername"] as? String, !username.isEmpty {
            let accepted = await client.friends.getAccepted()
            if let friend = accepted.first(where: { $0.username == username }) {
                return [friend.userId]
            }
            return []  // recipient not an accepted friend → send to no one (never broadcast)
        }

        // directMessage: canonical 1:1 conversation id "userIdA_userIdB"
        if let convId = entry.data["conversationId"] as? String {
            let ids = convId.split(separator: "_").map(String.init).filter { !$0.isEmpty }
            // Only canonical 1:1 conversations are scoped here; anything else falls through.
            if ids.count == 2 {
                let friendIds = Set(await client.friends.getAccepted().map { $0.userId })
                return ids.filter { friendIds.contains($0) }
            }
        }

        return nil
    }

    // MARK: - Group Member Resolution

    /// Resolve group members from the parent model's data.members field.
    /// E.g., a GroupMessage belongs_to "group" — look up the group entry's members.
    private func resolveGroupMembers(model: Model, entry: ModelEntry) async -> [String] {
        guard let parentModelName = model.definition.belongsTo.first,
              let parentModel = models[parentModelName] else {
            return []
        }

        // Find the foreign key (e.g., "groupId" for belongs_to "group")
        let foreignKey = "\(parentModelName)Id"
        guard let parentId = entry.data[foreignKey] as? String else { return [] }

        // Look up the parent entry
        guard let parentEntry = await parentModel.find(parentId) else { return [] }

        // Extract members from parent's data
        if let members = parentEntry.data["members"] as? [String] {
            // Filter to only friends we can actually send to
            var validMembers: [String] = []
            for member in members {
                if await client?.friends.isFriend(member) == true {
                    validMembers.append(member)
                }
            }
            return validMembers
        }

        return []
    }

    // MARK: - Handle Incoming (receive side)

    /// Route an incoming MODEL_SYNC message to the correct model.
    /// Returns the merged entries (empty if model unknown or no new data).
    public func handleIncoming(_ modelSync: ModelSyncMessage, sourceUserId: String) async -> [ModelEntry] {
        guard let model = models[modelSync.model] else {
            print("[ObscuraKit] unknown model in MODEL_SYNC: \(modelSync.model)")
            return []
        }

        // Decode data from bytes
        let data: [String: Any]
        if let parsed = try? JSONSerialization.jsonObject(with: modelSync.data) as? [String: Any] {
            data = parsed
        } else {
            data = [:]
        }

        let entry = ModelEntry(
            id: modelSync.id,
            data: modelSync.op == "DELETE" ? ["_deleted": true] : data,
            timestamp: modelSync.timestamp,
            signature: modelSync.signature,
            authorDeviceId: modelSync.authorDeviceId
        )

        return await model.handleSync(entry)
    }
}

/// Decoded MODEL_SYNC message — extracted from protobuf in ObscuraClient.
public struct ModelSyncMessage: Sendable {
    public let model: String
    public let id: String
    public let op: String  // "CREATE", "UPDATE", "DELETE"
    public let timestamp: UInt64
    public let data: Data
    public let signature: Data
    public let authorDeviceId: String

    public init(model: String, id: String, op: String, timestamp: UInt64, data: Data, signature: Data, authorDeviceId: String) {
        self.model = model
        self.id = id
        self.op = op
        self.timestamp = timestamp
        self.data = data
        self.signature = signature
        self.authorDeviceId = authorDeviceId
    }
}

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
            // Log but don't crash — sync is best-effort.
            // flushMessages() now restores the queue on failure, so messages aren't lost.
            print("[ObscuraKit] sync broadcast failed for \(modelName)/\(entry.id): \(error)")
        }
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

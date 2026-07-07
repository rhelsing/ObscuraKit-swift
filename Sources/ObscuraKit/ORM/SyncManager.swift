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
            try await self?.broadcast(modelName, entry)
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
    ///
    /// Throws `ObscuraError.directRoutingUnresolved` when a 1:1 (`.direct`) payload has no
    /// resolvable recipient — a pre-send validation failure that sends NOTHING (never a
    /// broadcast, never even a self-sync). Transient network send failures are caught and
    /// logged (the local write survives; the server retries), not thrown.
    private func broadcast(_ modelName: String, _ entry: ModelEntry) async throws {
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

        // The single place that actually puts a copy on the wire — per recipient, or to self.
        func deliver(to userId: String?, toSelf: Bool) async throws {
            try await client.sendModelSync(
                to: userId,
                toSelf: toSelf,
                model: modelName,
                entryId: entry.id,
                op: entry.isDeleted ? "DELETE" : "CREATE",
                data: data,
                timestamp: entry.timestamp,
                authorDeviceId: entry.authorDeviceId,
                signature: entry.signature
            )
        }

        // Group targeting needs an async parent-model lookup, so it is handled separately
        // from the pure targeting decision below.
        if scope == .group {
            do {
                let memberUserIds = await resolveGroupMembers(model: model, entry: entry)
                for memberId in memberUserIds { try await deliver(to: memberId, toSelf: false) }
                try await deliver(to: nil, toSelf: true)   // self-sync to own devices
            } catch {
                client.logger.log("BROADCAST FAILED \(modelName)/\(entry.id.prefix(20)): \(error.localizedDescription)")
            }
            return
        }

        let acceptedFriends = await client.friends.getAccepted()
        let resolution = SyncManager.resolveTargets(
            scope: scope,
            isPrivate: isPrivate,
            entryData: entry.data,
            acceptedFriends: acceptedFriends
        )

        // FAIL LOUD: a 1:1 payload with no resolvable recipient must raise and send NOTHING
        // (not even a self-sync) — never broadcast. Thrown before any delivery so it is NOT
        // swallowed by the network catch below (which only logs transient send failures).
        // Mirrors Kotlin SyncManager.getTargets throwing ObscuraError.DirectRoutingUnresolved;
        // conforms to obscura-proto SPEC §1.2 + conformance/routing.json.
        if case .refuse(let reason) = resolution {
            throw ObscuraError.directRoutingUnresolved(
                "Model '\(modelName)' entry \(entry.id.prefix(20)): \(reason). Refusing to broadcast a 1:1 payload.")
        }

        do {
            switch resolution {
            case .selfOnly:
                try await deliver(to: nil, toSelf: true)

            case .scoped(let userIds):
                for userId in userIds { try await deliver(to: userId, toSelf: false) }
                try await deliver(to: nil, toSelf: true)   // self-sync to own other devices

            case .allFriends:
                for friend in acceptedFriends { try await deliver(to: friend.userId, toSelf: false) }
                try await deliver(to: nil, toSelf: true)   // self-sync to own other devices

            case .refuse:
                break // unreachable — thrown above before any send
            }
        } catch {
            // Log through the client's logger so the app can see failures in the debug log.
            // flushMessages() restores the queue on failure, so messages aren't lost locally.
            client.logger.log("BROADCAST FAILED \(modelName)/\(entry.id.prefix(20)): \(error.localizedDescription)")
        }
    }

    // MARK: - Targeting decision (pure — unit testable)

    /// The delivery decision for an entry, independent of the network. `broadcast` turns this
    /// into actual sends; tests assert it directly. Mirrors Kotlin SyncManager.getTargets.
    enum Resolution: Equatable {
        case selfOnly                 // own devices only (private / ownDevices)
        case allFriends               // every accepted friend (+ self)
        case scoped([String])         // explicit recipient userIds (+ self)
        case refuse(String)           // direct payload, no resolvable recipient → caller MUST raise + send nothing
    }

    /// Pure targeting decision. No client, no network — fully unit testable. Group scope is
    /// resolved separately by `broadcast` (it needs an async parent lookup) and is not decided here.
    static func resolveTargets(
        scope: SyncScope,
        isPrivate: Bool,
        entryData: [String: Any],
        acceptedFriends: [Friend]
    ) -> Resolution {
        // Private always wins — never leaves own devices.
        if isPrivate || scope == .ownDevices { return .selfOnly }

        switch scope {
        case .ownDevices:
            return .selfOnly

        case .direct:
            // 1:1 — must resolve an explicit recipient, else fail loud. Never broadcast.
            if let scoped = resolveScopedRecipientUserIds(entryData: entryData, acceptedFriends: acceptedFriends) {
                return .scoped(scoped)
            }
            return .refuse("no recipientUsername or canonical 1:1 conversationId in entry data")

        case .friends:
            // Backward-compatible: opportunistically scope if the entry declares a recipient,
            // otherwise broadcast to all friends.
            if let scoped = resolveScopedRecipientUserIds(entryData: entryData, acceptedFriends: acceptedFriends) {
                return .scoped(scoped)
            }
            return .allFriends

        case .group:
            // Resolved by the caller; if it ever reaches here, prefer the safe broadcast default.
            return .allFriends
        }
    }

    /// Recipient userIds for an entry whose audience is a single user or a canonical 1:1
    /// conversation, or nil if the entry declares no such scoping.
    ///
    ///  - data.recipientUsername (e.g. pix) → that friend's userId (or [] if not an accepted friend)
    ///  - data.conversationId "userIdA_userIdB" → the participant ids that are accepted friends
    ///
    /// Self is covered separately by the toSelf self-sync. Mirrors Kotlin resolveScopedRecipients.
    static func resolveScopedRecipientUserIds(entryData: [String: Any], acceptedFriends: [Friend]) -> [String]? {
        if let username = entryData["recipientUsername"] as? String, !username.isEmpty {
            if let friend = acceptedFriends.first(where: { $0.username == username }) {
                return [friend.userId]
            }
            return []  // recipient not an accepted friend → send to no one (never broadcast)
        }

        if let convId = entryData["conversationId"] as? String {
            let ids = convId.split(separator: "_").map(String.init).filter { !$0.isEmpty }
            // Only canonical 1:1 conversations are scoped here.
            if ids.count == 2 {
                let friendIds = Set(acceptedFriends.map { $0.userId })
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

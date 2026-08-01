import Foundation

/// Export local state as a SyncBlob for device linking.
/// The wire shape is JSON of `{ friends, messages }` — the name says "compressed" and nothing ever
/// compressed it.
public struct SyncBlobExporter {

    /// Export the friend graph as JSON.
    ///
    /// - Note: this took a `messages:` parameter and every one of the three callers
    ///   (`pushHistoryToDevice`, `approveLink`, `uploadBackup`) passed `[]`, so the whole
    ///   message-serialization branch was unreachable. The key is still emitted, empty, because
    ///   ``parseExport(_:)`` and the receiving `.syncBlob` arm read it — an inbound blob from a peer
    ///   kit may carry messages even though this one never writes any.
    public static func export(friends: [Friend]) -> Data {
        let friendsList = friends.map { friend -> [String: Any] in
            [
                "userId": friend.userId,
                "username": friend.username,
                "status": friend.status.rawValue,
            ]
        }
        let dict: [String: Any] = ["friends": friendsList, "messages": [[String: Any]]()]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    /// Import blob data. `messages` is populated by peer kits, never by ``export(friends:)``.
    public static func parseExport(_ data: Data) -> (friends: [[String: Any]], messages: [[String: Any]])? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let friends = dict["friends"] as? [[String: Any]] ?? []
        let messages = dict["messages"] as? [[String: Any]] ?? []
        return (friends: friends, messages: messages)
    }
}

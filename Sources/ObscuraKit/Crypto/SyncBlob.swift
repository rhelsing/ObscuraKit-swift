import Foundation

/// Export local state as a compressed SyncBlob for device linking.
/// Matches the web client's SyncBlob format: gzipped JSON of { friends, messages }.
public struct SyncBlobExporter {

    /// Export friends and messages as compressed JSON data
    public static func export(friends: [Friend], messages: [(conversationId: String, messages: [Message])]) -> Data {
        var dict: [String: Any] = [:]

        // Friends
        let friendsList = friends.map { friend -> [String: Any] in
            [
                "userId": friend.userId,
                "username": friend.username,
                "status": friend.status.rawValue,
            ]
        }
        dict["friends"] = friendsList

        // Messages
        var allMessages: [[String: Any]] = []
        for (convId, msgs) in messages {
            for msg in msgs {
                allMessages.append([
                    "messageId": msg.messageId,
                    "conversationId": convId,
                    "content": msg.content,
                    "timestamp": msg.timestamp,
                    "isSent": msg.isSent,
                ])
            }
        }
        dict["messages"] = allMessages

        let jsonData = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        // In production this would be gzipped. For now, raw JSON.
        return jsonData
    }

    /// Import compressed data into local stores
    public static func parseExport(_ data: Data) -> (friends: [[String: Any]], messages: [[String: Any]])? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let friends = dict["friends"] as? [[String: Any]] ?? []
        let messages = dict["messages"] as? [[String: Any]] ?? []
        return (friends: friends, messages: messages)
    }
}

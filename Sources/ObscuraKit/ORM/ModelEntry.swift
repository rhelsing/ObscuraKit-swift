import Foundation

public enum SortOrder {
    case asc, desc
}

/// A single entry in the ORM — the universal record type for all models.
public struct ModelEntry: Equatable {
    public let id: String
    public var data: [String: Any]
    public let timestamp: UInt64
    public let signature: Data
    public let authorDeviceId: String

    public init(
        id: String,
        data: [String: Any],
        timestamp: UInt64,
        signature: Data,
        authorDeviceId: String
    ) {
        self.id = id
        self.data = data
        self.timestamp = timestamp
        self.signature = signature
        self.authorDeviceId = authorDeviceId
    }

    public var isDeleted: Bool {
        (data["_deleted"] as? Bool) == true
    }

    // Manual Equatable since [String: Any] isn't Equatable
    public static func == (lhs: ModelEntry, rhs: ModelEntry) -> Bool {
        lhs.id == rhs.id && lhs.timestamp == rhs.timestamp
    }
}

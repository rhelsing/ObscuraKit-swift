import Foundation
import ObscuraKit

// MARK: - ORM Model Definitions
// These are the app's data models. Define the struct, get encrypted sync for free.

struct DirectMessage: SyncModel {
    static let modelName = "directMessage"
    static let sync: SyncStrategy = .gset       // immutable, append-only
    static let scope: SyncScope = .friends

    var conversationId: String
    var content: String
    var senderUsername: String
}

struct Profile: SyncModel {
    static let modelName = "profile"
    static let sync: SyncStrategy = .lwwMap     // mutable, last-write-wins
    static let scope: SyncScope = .friends      // shared with friends

    var displayName: String
    var bio: String?
    var avatarUrl: String?
}

struct AppSettings: SyncModel {
    static let modelName = "settings"
    static let sync: SyncStrategy = .lwwMap
    static let scope: SyncScope = .ownDevices   // private, never leaves your devices

    var theme: String
    var notificationsEnabled: Bool
}

struct Story: SyncModel {
    static let modelName = "story"
    static let sync: SyncStrategy = .gset
    static let scope: SyncScope = .friends
    static let ttl: TTL? = .hours(24)           // ephemeral, auto-expires

    var content: String
    var authorUsername: String
}

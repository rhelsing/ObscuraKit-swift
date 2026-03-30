# ORM — Encrypted Sync for Any Model

Define a model. Get CRUD, encrypted sync, conflict resolution, reactive observation, and offline support for free.

## Setup

```swift
let client = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
try await client.register(username, password)
try await client.connect()

// Register typed models
let stories = client.register(Story.self)
let profiles = client.register(Profile.self)
```

Or use untyped schema for dynamic models:

```swift
client.schema([
    ModelDefinition(name: "story", sync: .gset, syncScope: .friends, ttl: .hours(24),
                    fields: ["content": .string, "authorUsername": .string]),
    ModelDefinition(name: "profile", sync: .lwwMap, syncScope: .friends,
                    fields: ["displayName": .string, "bio": .optionalString]),
])

let storyModel = client.model("story")!
```

## Defining Models

Conform to `SyncModel` + `Codable`:

```swift
struct Story: SyncModel {
    static let modelName = "story"
    static let sync: SyncStrategy = .gset       // immutable, append-only
    static let scope: SyncScope = .friends      // broadcast to all friends
    static let ttl: TTL? = .hours(24)           // auto-expires after 24h

    var content: String
    var mediaUrl: String?
    var authorUsername: String
    var likes: Int?
}

struct Profile: SyncModel {
    static let modelName = "profile"
    static let sync: SyncStrategy = .lwwMap     // mutable, last-write-wins
    // scope defaults to .friends, ttl defaults to nil (permanent)

    var displayName: String
    var avatarUrl: String?
    var bio: String?
}

struct Settings: SyncModel {
    static let modelName = "settings"
    static let sync: SyncStrategy = .lwwMap
    static let scope: SyncScope = .ownDevices   // private, never leaves your devices

    var theme: String
    var notificationsEnabled: Bool
}
```

### Sync Strategies

| Strategy | Behavior | Use for |
|----------|----------|---------|
| `.gset` | Grow-only set. Add-only, merge = union. Cannot delete. | Stories, comments, messages |
| `.lwwMap` | Last-writer-wins. Newer timestamp wins. Supports delete (tombstone). | Profiles, settings, reactions |

### Sync Scopes

| Scope | Who receives | Use for |
|-------|-------------|---------|
| `.friends` | All accepted friends + own devices | Public content |
| `.ownDevices` | Only your devices, never friends | Settings, local state |
| `.group` | Members listed in parent model's `data.members` field | Group messages |

### Field Types (untyped ModelDefinition only)

Typed models (`SyncModel`) use Codable and don't need field declarations. Untyped models use:

| Type | Swift type | Required |
|------|-----------|----------|
| `.string` | `String` | yes |
| `.number` | `Int`, `Double` | yes |
| `.boolean` | `Bool` | yes |
| `.optionalString` | `String?` | no |
| `.optionalNumber` | `Int?`, `Double?` | no |
| `.optionalBoolean` | `Bool?` | no |

### TTL Options

```swift
static let ttl: TTL? = .seconds(30)
static let ttl: TTL? = .minutes(5)
static let ttl: TTL? = .hours(24)
static let ttl: TTL? = .days(7)
static let ttl: TTL? = nil           // permanent (default)
```

TTL is scheduled automatically on `create()`. Call `client._ormTTLManager?.cleanup()` to delete expired entries (e.g., on app foreground or periodically).

## CRUD

### Typed API (recommended)

```swift
let stories = client.register(Story.self)

// Create — typed, auto-syncs to friends
let entry = try await stories.create(Story(content: "sunset", authorUsername: "alice"))
entry.value.content   // "sunset" — typed String, not Any
entry.id              // "story_1711734000000_a8f3c2d1"
entry.timestamp       // 1711734000000

// Find by ID
let found = await stories.find(entry.id)

// All entries
let all = await stories.all()

// All sorted by timestamp
let newest = await stories.allSorted(order: .desc)

// Upsert (LWW models only — creates or updates)
try await profiles.upsert("my_profile", Profile(displayName: "Alice", bio: "hello"))

// Delete (LWW models only — creates tombstone)
try await profiles.delete("my_profile")
```

### Untyped API

```swift
let storyModel = client.model("story")!

// Returns ModelEntry with data: [String: Any]
let entry = try await storyModel.create(["content": "sunset", "authorUsername": "alice"])
entry.data["content"] as? String  // "sunset"
```

## Queries

### DSL Syntax (recommended — reads like English)

```swift
// Equality
await stories.where { "authorUsername" == "alice" }.exec()

// Not equal
await stories.where { "authorUsername" != "spam" }.exec()

// Comparison
await stories.where { "likes" >= 5 }.exec()

// Range (multiple conditions on same field)
await stories.where { "likes" >= 5; "likes" <= 25 }.exec()

// Set membership
await stories.where { "authorUsername".oneOf(["alice", "bob"]) }.exec()
await stories.where { "authorUsername".noneOf(["spam"]) }.exec()

// String matching
await stories.where { "content".contains("sunset") }.exec()
await stories.where { "content".startsWith("Hello") }.exec()
await stories.where { "content".endsWith("world") }.exec()

// Sort + limit
await stories.where { "likes" >= 0 }
    .orderBy("likes", .desc)
    .limit(10)
    .exec()

// First match
await stories.where { "authorUsername" == "alice" }.first()

// Count
await stories.where { "authorUsername" == "alice" }.count()
```

### Map Syntax (cross-platform compatible)

```swift
// Same queries using dictionaries — works on Model (untyped)
await client.model("story")!.where(["data.authorUsername": "alice"]).exec()
await client.model("story")!.where(["data.likes": ["atLeast": 5, "atMost": 25]]).exec()
await client.model("story")!.where(["data.authorUsername": ["oneOf": ["alice", "bob"]]]).exec()
```

`orderBy` auto-prefixes `data.` — both `orderBy("likes")` and `orderBy("data.likes")` work.

### Operator Reference

| DSL | Map key | Meaning |
|-----|---------|---------|
| `==` | `equals` / `eq` | Equal to |
| `!=` | `not` / `ne` | Not equal to |
| `>` | `greaterThan` / `gt` | Greater than |
| `>=` | `atLeast` / `gte` | Greater than or equal |
| `<` | `lessThan` / `lt` | Less than |
| `<=` | `atMost` / `lte` | Less than or equal |
| `.oneOf([...])` | `oneOf` / `in` | In list |
| `.noneOf([...])` | `noneOf` / `nin` | Not in list |
| `.contains("x")` | `contains` | String contains |
| `.startsWith("x")` | `startsWith` | String prefix |
| `.endsWith("x")` | `endsWith` | String suffix |

### Closure Filter (full Swift power)

```swift
// When operators aren't enough
let long = await stories.filter { $0.content.count > 100 }
```

## Reactive Observation

GRDB ValueObservation pushes changes on every DB write. No polling.

### Observe all entries

```swift
// SwiftUI — all stories
struct FeedView: View {
    let stories: TypedModel<Story>
    @State private var items: [Story] = []

    var body: some View {
        List(items, id: \.content) { story in
            VStack(alignment: .leading) {
                Text(story.authorUsername).bold()
                Text(story.content)
            }
        }
        .task {
            for await updated in stories.observe().values {
                items = updated
            }
        }
    }
}
```

### Filtered observation (query-scoped)

Observe only entries matching a query. The filter runs inside the GRDB observation — not client-side.

```swift
// Only messages in this conversation
for await msgs in messages
    .where { "conversationId" == friendId }
    .orderBy("timestamp", .asc)
    .observe()
    .values
{
    self.messages = msgs
}
```

Works on both typed DSL queries and untyped map queries:

```swift
// Untyped
for await entries in model.where(["data.conversationId": friendId]).observe().values { ... }
```

Observation emits the initial value immediately, then re-emits on every write. Tombstoned entries are automatically excluded.

## Associations & Eager Loading

Models can declare `belongs_to` and `has_many` relationships. Use `include()` to eager-load children in a single query.

### Defining associations

```swift
// Story has_many comments
let storyDef = ModelDefinition(name: "story", sync: .gset,
    fields: ["content": .string], hasMany: ["comment"])

// Comment belongs_to story (uses "storyId" foreign key in data)
let commentDef = ModelDefinition(name: "comment", sync: .gset,
    fields: ["text": .string, "storyId": .string], belongsTo: ["story"])
```

### Eager loading with include()

```swift
// Fetch stories with their comments attached
let results = await storyModel.where([:]).include("comment").exec()

// Each story entry now has a "comments" key
for story in results {
    let comments = story.data["comments"] as? [[String: Any]] ?? []
    print("\(story.data["content"]) — \(comments.count) comments")
}
```

`include()` matches children by foreign key convention: a `comment` with `belongs_to: ["story"]` is matched via `storyId` in its data.

## Offline & Conflict Resolution

The ORM handles offline scenarios automatically:

- **Recipient offline:** Server queues MODEL_SYNC. Recipient reconnects, gets everything.
- **Both sides create (GSet):** Both entries exist. Merge = union. No conflict.
- **Both sides update same key (LWW):** Newer timestamp wins. Deterministic, no coordination.
- **Multiple updates while offline:** All arrive on reconnect. LWW picks the newest.
- **Self-sync:** When you create content, your own other devices get it too.

The developer writes zero reconnection logic.

## Anti-Cheat

LWWMap clamps timestamps more than 60 seconds in the future. A malicious client sending a far-future timestamp gets clamped to `now + 60s`, preventing permanent timestamp spoofing.

## Recovery (Optional)

BIP39 recovery is opt-in. If you never call `generateRecoveryPhrase()`, everything works without it. The only features that require a phrase are:

- `client.revokeDevice(phrase, targetDeviceId:)` — remote device revocation with signed proof
- `client.announceRecovery(phrase)` — signed device announcements

Without a phrase, device revocation requires physical access to a linked device.

## Device Linking

New devices link via QR code or copyable text code:

```swift
// New device generates a link code
let code = client.generateLinkCode()  // Base58-encoded JSON with challenge + expiry

// Existing device validates and approves
try await existingClient.validateAndApproveLink(code)
// Sends DEVICE_LINK_APPROVAL + SYNC_BLOB + DEVICE_ANNOUNCE automatically
```

Link codes expire after 5 minutes. Challenge verification uses constant-time comparison.

## Cross-Platform Interop

iOS and Android (Kotlin) clients share the same ORM wire format. If both define a model with the same `modelName`, CRDT strategy, and data fields — sync works across platforms automatically.

The wire format is `ClientMessage.MODEL_SYNC` (type 30) containing JSON-encoded data inside a protobuf inside Signal encryption. Both clients read the same JSON fields.

Kotlin equivalent of the iOS schema:

```kotlin
client.orm.define(mapOf(
    "directMessage" to ModelConfig(
        fields = mapOf("conversationId" to "string", "content" to "string", "senderUsername" to "string"),
        sync = "gset"
    ),
    "story" to ModelConfig(
        fields = mapOf("content" to "string", "authorUsername" to "string"),
        sync = "gset", ttl = "24h"
    ),
    "profile" to ModelConfig(
        fields = mapOf("displayName" to "string", "bio" to "string?"),
        sync = "lww"
    ),
    "settings" to ModelConfig(
        fields = mapOf("theme" to "string", "notificationsEnabled" to "boolean"),
        sync = "lww", private = true
    )
))
```

## What You Can Rely On

Proven by 123 unit tests (offline, <1s) and 17 integration tests (live server):

| Capability | Unit tested | Server tested |
|------------|------------|--------------|
| GSet: add, merge, idempotency | 8 tests | 4 tests |
| LWWMap: conflict, tombstone, clamping | 12 tests | 2 tests |
| Signal store: TOFU, persistence, sessions | 20 tests | via CoreFlow |
| Model: create, find, upsert, delete, validation | 16 tests | 4 tests |
| QueryBuilder: 11 operators, orderBy, limit | 21 tests | — |
| Typed models + DSL | 11 tests | 2 tests |
| Observation: emit on write, exclude tombstones | 2 tests | — |
| Filtered observation: query-scoped observe() | 3 tests | — |
| include() eager loading | 3 tests | — |
| Device linking: Base58, challenge, validation | 16 tests | 2 tests |
| TTL: parse, schedule, expire, cleanup | 11 tests | — |
| Auto-sync to friends | — | 2 tests |
| Private model isolation | — | 2 tests |
| Offline delivery + reconnect | — | 6 tests |
| LWW conflict after offline | — | 2 tests |
| Persistence through restart | — | 1 test |
| Bidirectional CRDT merge | — | 2 tests |
| ORM messages (conversation queries) | — | 3 tests |
| Self-sync to own devices | — | via SyncManager |

## What's Not Built Yet

| Feature | Status |
|---------|--------|
| Group-targeted sync E2E test | SyncManager resolves group members; no server test yet |
| `LoginScenario` enum | Kotlin returns typed login results; Swift login just throws |
| Periodic TTL cleanup | `TTLManager.cleanup()` exists but must be called manually |
| MessageActor removal | ORM `directMessage` works; hardcoded `MessageActor` still exists alongside |

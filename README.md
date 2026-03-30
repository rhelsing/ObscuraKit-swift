# ObscuraKit

**Rails for Signal.** Define a model, get encrypted sync for free.

ObscuraKit is a Swift library — not an app — that gives any iOS/macOS application end-to-end encrypted data sync powered by Signal Protocol. A developer defines models, calls `.create()` and `.observe()`, and the encryption, multi-device fan-out, CRDT conflict resolution, and reactive UI updates happen automatically. No one touches a protobuf, a Signal session, or a WebSocket frame.

## North Star

The API should be so simple that a Rails developer feels at home building any kind of app on this library — and gets all the Obscura and Signal magic for free.

```swift
// Define a model. That's it.
struct Story: SyncModel {
    static let modelName = "story"
    static let sync: SyncStrategy = .gset       // immutable, append-only
    static let scope: SyncScope = .friends      // broadcast to all friends
    static let ttl: TTL? = .hours(24)           // ephemeral, auto-expires

    var content: String
    var mediaUrl: String?
    var authorUsername: String
}

struct Profile: SyncModel {
    static let modelName = "profile"
    static let sync: SyncStrategy = .lwwMap     // mutable, last-write-wins

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

// Register and use. Encryption and sync are invisible.
let stories = client.register(Story.self)
try await stories.create(Story(content: "sunset", authorUsername: "alice"))
let feed = await stories.where { "authorUsername" == "alice" }.exec()
for await updated in stories.observe().values { /* SwiftUI re-renders */ }
```

## Architecture

Three protocol layers, like a network stack. Each layer is a reliable, boring protocol that the layer above never looks inside.

```
┌─────────────────────────────────────────────────────────────────┐
│                        YOUR APP / VIEWS                         │
│  client.story.create(...)    client.profile.observe()           │
│  client.befriend(userId)     client.friends.observeAccepted()   │
├─────────────────────────────────────────────────────────────────┤
│                     ObscuraClient (facade)                       │
│  Wires layers together. Envelope loop. Message routing.          │
│  App code never goes below this line.                           │
╞═════════════════════════════════════════════════════════════════╡
│                                                                 │
│  LAYER 3: APPLICATION                                          │
│                                                                 │
│  ┌─ ORM ─────────────────────────────────────────────────────┐ │
│  │  The freeform layer. Define any model, get CRUD + sync.   │ │
│  │  Messages, stories, profiles, settings, groups — all ORM. │ │
│  │  CRDT conflict resolution (GSet / LWWMap).                │ │
│  │  Auto fan-out based on SyncScope.                         │ │
│  │  TTL expiration for ephemeral content.                    │ │
│  │  Reactive observation (GRDB → AsyncStream).               │ │
│  └───────────────────────────────────────────────────────────┘ │
│  ┌─ Infrastructure ──────────────────────────────────────────┐ │
│  │  Friends — the social graph. Who you sync to.             │ │
│  │  Devices — your device set. Where you sync to.            │ │
│  │  These are the routing table, not content.                │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
╞═════════════════════════════════════════════════════════════════╡
│                                                                 │
│  LAYER 2: ENCRYPTION                                           │
│  Signal Protocol encrypt/decrypt. Plaintext in, ciphertext out.│
│  Auto-session establishment. Key management.                    │
│  Nothing above this layer ever sees a Signal session.           │
│                                                                 │
╞═════════════════════════════════════════════════════════════════╡
│                                                                 │
│  LAYER 1: TRANSPORT                                            │
│  WebSocket (protobuf frames) + REST API.                       │
│  Server is a dumb relay of opaque encrypted blobs.             │
│  Nothing above this layer ever sees a protobuf or HTTP call.   │
│                                                                 │
╞═════════════════════════════════════════════════════════════════╡
│  STORAGE: GRDB/SQLite (encrypted at rest via SQLCipher)        │
│  OBSERVATION: ValueObservation → AsyncStream (reactive, no poll)│
└─────────────────────────────────────────────────────────────────┘
```

**Why Friends and Devices are not ORM models:**
They are the *destinations* for sync, not the *content* being synced. Friends define who gets your data. Devices define where your data lives. Everything else — messages, stories, profiles, reactions, groups — is content that rides the ORM.

**Abstraction boundaries:**
- Layer 1 never sees what's inside an encrypted message
- Layer 2 never sees ORM models or how CRDTs merge
- Layer 3 never sees Signal sessions, WebSocket frames, or HTTP calls
- ObscuraClient is the only thing that crosses all three

## ORM — The Core Idea

The ORM is where new features get built. It's the equivalent of ActiveRecord for encrypted sync. The model declaration drives everything:

| Property | Controls | Options |
|----------|----------|---------|
| `sync` | CRDT strategy | `.gset` (immutable, append-only) / `.lwwMap` (mutable, last-write-wins) |
| `syncScope` | Fan-out targeting | `.friends` (all friends) / `.ownDevices` (private) / `.group(memberKey:)` (targeted) |
| `ttl` | Ephemeral expiry | `.seconds(n)` / `.minutes(n)` / `.hours(n)` / `.days(n)` / `nil` (permanent) |
| `belongs_to` | Parent association | Links to parent model for eager loading and group targeting |
| `has_many` | Child associations | Declares children for eager loading |

**Sync scopes determine fan-out:**
- `.friends` — broadcast to all accepted friends' devices (stories, profiles, reactions)
- `.ownDevices` — only sync across your own devices, never to friends (settings, local state)
- `.group(memberKey:)` — look up members from a parent model, sync only to those users (group messages)

**CRDTs handle conflicts without coordination:**
- **GSet** — grow-only set. Add-only, merge = union. For immutable content (stories, comments, messages). Two devices create content simultaneously? Both entries exist. No conflict.
- **LWWMap** — last-writer-wins map. Highest timestamp wins. For mutable state (profiles, settings). Two devices edit a profile? Most recent write wins. Deterministic, no coordination needed.

## Public API

### Auth & Connection
```swift
let client = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
try await client.register(username, password)  // user + device + Signal keys
try await client.login(username, password)     // restore session
try await client.connect()                     // WebSocket + envelope loop (runs in background)
client.disconnect()
try await client.logout()
```

### Friends (Infrastructure)
```swift
try await client.befriend(userId)        // encrypted FRIEND_REQUEST
try await client.acceptFriend(userId)    // encrypted FRIEND_RESPONSE

for await friends in client.friends.observeAccepted().values { ... }
for await pending in client.friends.observePending().values { ... }
```

### Devices (Infrastructure)
```swift
try await client.announceDevices()
try await client.revokeDevice(recoveryPhrase, targetDeviceId: deviceId)

for await devices in client.devices.observeOwnDevices().values { ... }
```

### ORM Models (Content)
```swift
// Register typed models
let stories = client.register(Story.self)
let profiles = client.register(Profile.self)

// CRUD — typed, validated, auto-syncs
try await stories.create(Story(content: "hello", authorUsername: "alice"))
try await profiles.upsert("p1", Profile(displayName: "Alice", bio: "hello"))

// Query — DSL reads like English
let all = await stories.all()
let filtered = await stories.where { "authorUsername" == "alice" }.exec()
let sorted = await stories.allSorted(order: .desc)
let top = await stories.where { "likes" >= 0 }.orderBy("likes", .desc).limit(10).exec()

// Observe (SwiftUI-ready, reactive, no polling)
for await updated in stories.observe().values { ... }

// Delete (LWWMap models only — creates tombstone)
try await profiles.delete("p1")
```

### Attachments
```swift
let result = try await client.api.uploadAttachment(data)
let bytes = try await client.api.fetchAttachment(id)
```

### Recovery & Backup
```swift
let phrase = client.generateRecoveryPhrase()  // 12-word BIP39
try await client.announceRecovery(phrase)
try await client.uploadBackup()
let data = try await client.downloadBackup()
```

### SwiftUI Example
```swift
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

## Current Status

Layer 1 (Transport) and Layer 2 (Encryption) are complete and tested. Layer 3 is partially built:

| Component | Status | Notes |
|-----------|--------|-------|
| Friends (infrastructure) | **Done** | Actors + GRDB + reactive observation |
| Devices (infrastructure) | **Done** | Actors + GRDB + reactive observation |
| ORM storage (ModelStore, GRDB) | **Done** | Persistence + associations + TTL |
| ORM CRDTs (GSet, LWWMap) | **Done** | 20 unit tests |
| ORM send path (sendModelSync) | **Done** | Auto fan-out by scope |
| ORM receive path | **Done** | SyncManager routes MODEL_SYNC to correct model |
| SyncModel protocol + TypedModel | **Done** | Typed CRUD, Codable round-trip, 11 unit tests |
| SyncManager (auto fan-out) | **Done** | .friends, .ownDevices, .group scopes |
| TTLManager | **Done** | Schedule on create, cleanup expired, 11 unit tests |
| QueryBuilder + DSL | **Done** | 11 operators, orderBy, limit, 21 unit tests |
| SchemaBuilder (client.schema/register) | **Done** | Wires models + TTL + sync at init |
| ORM reactive observation | **Done** | GRDB ValueObservation, excludes tombstones |
| Self-sync (own devices) | **Done** | MODEL_SYNC to own devices, tested on server |
| Device link code (QR/code) | **Done** | Generate, parse, validate, challenge verify |
| Device link approval flow | **Partial** | Facade wired, needs E2E enforcement in tests |
| Messages as ORM model | **Proven** | ORM directMessage works; MessageActor still exists |
| `include()` eager loading | **Not built** | Model.loadInto() exists for manual loading |
| Group-targeted sync | **Built** | Resolves members from parent; needs server test |

The JS web client (`../obscura-client-web`) has a complete ORM implementation that serves as the reference. The Swift ORM should match its capabilities with Swift-native ergonomics (protocols, actors, GRDB observation).

## File Structure

```
Sources/ObscuraKit/
├── ObscuraClient.swift          Public API facade. Envelope loop, routing, token refresh
├── ObscuraTestClient.swift      Thin test wrapper (register/login convenience)
├── ObscuraKit.swift             Module entry
├── Crypto/                      LAYER 2 — Encryption
│   ├── MessengerActor.swift     Signal encrypt/decrypt, auto-session, queue/flush
│   ├── SignalStore.swift        GRDB-backed Signal store (15-method protocol interface)
│   ├── RecoveryKeys.swift       BIP39 phrase → Curve25519 keypair, sign/verify
│   ├── VerificationCode.swift   SHA-256 based 4-digit safety numbers
│   ├── SyncBlob.swift           Device linking state export/import
│   └── Bip39Wordlist.swift      2048-word BIP39 English wordlist
├── Network/                     LAYER 1 — Transport
│   ├── APIClient.swift          URLSession REST: auth, devices, messages, attachments, backup
│   ├── GatewayConnection.swift  URLSessionWebSocketTask: ticket auth, envelopes, ACK
│   └── Constants.swift          Rate limit delay
├── ORM/                         LAYER 3 — ORM (in progress)
│   ├── CRDT/
│   │   ├── GSet.swift           Grow-only set. Add, merge (union), filter, sort
│   │   └── LWWMap.swift         Last-writer-wins map. Timestamp conflict, tombstone delete
│   ├── ModelStore.swift         GRDB persistence + associations + TTL
│   └── ModelEntry.swift         Universal entry (id, data, timestamp, author, signature)
│   # TODO: SyncModel protocol, SyncManager, TTLManager, QueryBuilder, SchemaBuilder
└── Stores/                      LAYER 3 — Infrastructure
    ├── FriendStore.swift        Friend actor + GRDB + reactive observation (sync destinations)
    ├── DeviceStore.swift        Device actor + GRDB + reactive observation (sync destinations)
    ├── MessageStore.swift       Message actor (to be replaced by ORM model)
    └── Observation.swift        AsyncValueObservation bridge (GRDB → AsyncStream)
```

## Concurrency Model

**Swift Actors** — each domain runs in its own actor with compiler-enforced isolation:
- `FriendActor` — social graph, fan-out targets (infrastructure)
- `DeviceActor` — device identity, own device list (infrastructure)
- `MessengerActor` — Signal encrypt/decrypt (order-sensitive ratchet state)

No locks. No race conditions. The compiler prevents cross-actor mutable access.

## Documentation

| Doc | What it covers |
|-----|---------------|
| [docs/ORM.md](docs/ORM.md) | ORM guide: models, CRUD, queries, DSL, observation, offline, TTL |
| [docs/CLIENT_API.md](docs/CLIENT_API.md) | Auth, connection, friends, devices, device linking, backup |
| [docs/MESSAGE_FLOW.md](docs/MESSAGE_FLOW.md) | Complete send/receive data flow with ASCII diagrams |
| [docs/PITFALLS.md](docs/PITFALLS.md) | Every gotcha that wastes hours — libsignal version, WebSocket, server quirks |
| [docs/AGENT_NOTES.md](docs/AGENT_NOTES.md) | Hard-won lessons: race conditions, version gotchas, tech debt priorities |

## Build & Test

```bash
./dev.sh build
./dev.sh test
./dev.sh test --filter CoreFlowTests
```

Native builds on macOS 13+ with Swift 6.1 toolchain. No Docker. `dev.sh` sets the `LIBRARY_PATH` for libsignal FFI.

## Dependencies

- `signalapp/libsignal` v0.40.0 — Signal Protocol (vendored, Rust FFI)
- `apple/swift-protobuf` — protobuf codegen
- `groue/GRDB.swift` — SQLite persistence + ValueObservation
- `CryptoKit` — SHA-256, HMAC (system framework)
- `URLSessionWebSocketTask` — WebSocket (system framework)

## Server

- **API:** https://obscura.barrelmaker.dev
- **OpenAPI Spec:** https://obscura.barrelmaker.dev/openapi.yaml
- **Server Repo:** https://github.com/barrelmaker97/obscura-server

## Reference Implementation

The JS web client at `../obscura-client-web` has a complete ORM with all the pieces: `BaseModel` class with declarative schema, `SyncManager` with targeting, `TTLManager`, `QueryBuilder`, and 9 model types (Story, Comment, Reaction, Profile, Pix, PixRegistry, Settings, Group, GroupMessage). The Swift port should match capabilities with native ergonomics.

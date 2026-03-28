# ObscuraKit: iOS Data Layer Plan (Actors Architecture)

## Context

Port the Obscura web client's data layer to a Swift package (`ObscuraKit`) that is fully smoke-testable without any views. The package's public API is what SwiftUI views will call — and what tests call. Zero controller/glue code. Views are just a thin projection of tested state.

Architecture: **Swift Actors** — each domain gets an actor for compiler-enforced thread safety. Signal crypto ops (order-sensitive per session) are protected by actor isolation. Clean `async/await` throughout.

---

## Repo & Toolchain

**Repo:** `/Users/ryanhelsing/Projects/obscura-client-ios` (new, created during Layer 1)
**Web client (reference):** `/Users/ryanhelsing/Projects/obscura-client-web`
**No Xcode required** — everything runs via `swift build` and `swift test` from the command line (SPM).

### Prerequisites (install before starting)

```bash
# Swift 5.7.2 + Xcode 14.2 already installed ✓

# 1. SwiftProtobuf compiler plugin (generates .swift from .proto)
brew install swift-protobuf

# 2. Verify protoc + swift plugin
protoc --version
protoc-gen-swift --version

# 3. That's it — GRDB, SwiftProtobuf runtime, and libsignal
#    are pulled in via Package.swift as SPM deps
```

**SPM dependencies (in Package.swift):**
- `apple/swift-protobuf` — protobuf runtime
- `groue/GRDB.swift` — SQLite persistence (encrypted via SQLCipher later)
- libsignal: TBD — scratchpad test in Layer 1 validates which Swift package works with Swift 5.7

---

## Package Structure

```
obscura-client-ios/   ← /Users/ryanhelsing/Projects/obscura-client-ios
├── Package.swift
├── Sources/
│   └── ObscuraKit/
│       ├── Proto/
│       │   ├── Server/          ← generated from obscura.proto
│       │   └── Client/          ← generated from client.proto
│       ├── ORM/
│       │   ├── CRDT/            ← GSet.swift, LWWMap.swift
│       │   ├── Model.swift
│       │   ├── ModelStore.swift ← GRDB persistence
│       │   ├── SyncManager.swift
│       │   ├── TTLManager.swift
│       │   └── QueryBuilder.swift
│       ├── Crypto/              ← libsignal wrapper, SignalStore
│       ├── Network/             ← APIClient, GatewayConnection
│       ├── Stores/              ← FriendStore, MessageStore, DeviceStore
│       └── ObscuraClient.swift  ← public API facade
├── Tests/
│   ├── Scratchpad/              ← throwaway validation tests (delete when done)
│   └── Scenarios/               ← permanent scenario tests (the deliverable)
└── Fixtures/                    ← .proto source files copied from web repo
```

---

## Public API (what views and tests both call)

```swift
public final class ObscuraClient {
    public let friends: FriendActor
    public let messages: MessageActor
    public let devices: DeviceActor
    public let messenger: MessengerActor
    public let orm: SchemaActor

    public let api: APIClient
    public let gateway: GatewayConnection

    public func register(_ username: String, _ password: String) async throws
    public func login(_ username: String, _ password: String) async throws
    public func logout() async throws
}

public actor FriendActor {
    private let store: FriendStore  // GRDB
    public func add(_ userId: String, _ username: String, status: FriendStatus, devices: [DeviceInfo]) async
    public func getAccepted() async -> [Friend]
    public func getFanOutTargets(_ userId: String) async -> [DeviceTarget]
    public func getPending() async -> [Friend]
    public func updateDevices(_ userId: String, devices: [DeviceInfo]) async
    public func remove(_ userId: String) async
    public func exportAll() async -> FriendExport
    public func importAll(_ data: FriendExport) async
}

public actor MessengerActor {
    private let signalStore: SignalStore
    public func mapDevice(_ deviceId: String, userId: String, registrationId: UInt32)
    public func queueMessage(_ targetDeviceId: String, _ message: ClientMessage, userId: String) async throws
    public func flushMessages() async throws
    public func fetchPreKeyBundles(_ userId: String) async throws -> [PreKeyBundle]
    public func decrypt(_ envelope: Envelope) async throws -> DecryptedMessage
}

public actor MessageActor {
    private let store: MessageStore  // GRDB
    public func add(_ conversationId: String, _ message: Message) async
    public func getMessages(_ conversationId: String, limit: Int, offset: Int) async -> [Message]
    public func migrateMessages(from: String, to: String) async
    public func deleteByAuthorDevice(_ deviceId: String) async
}

public actor DeviceActor {
    private let store: DeviceStore  // GRDB
    public func storeIdentity(_ identity: DeviceIdentity) async
    public func getIdentity() async -> DeviceIdentity?
    public func addOwnDevice(_ device: OwnDevice) async
    public func getOwnDevices() async -> [OwnDevice]
    public func getSelfSyncTargets() async -> [DeviceTarget]
}

public actor SchemaActor {
    public func define(_ definitions: [String: ModelConfig]) async
    public func model(_ name: String) async -> Model?
    public func handleSync(_ modelSync: ModelSync, from: String) async
}
```

---

## Build Order

### Layer 1: Server Proto

**Goal:** Generated Swift types for server communication. Prove they round-trip.

**Steps:**
1. `mkdir -p ../obscura-client-ios && cd ../obscura-client-ios`
2. `swift package init --type library --name ObscuraKit`
3. `git init && git add -A && git commit -m "init"`
4. Add `swift-protobuf` dependency to Package.swift
5. Copy `../obscura-client-web/public/proto/obscura/v1/obscura.proto` → `Fixtures/`
6. Run `protoc --swift_out=Sources/ObscuraKit/Proto/Server/ Fixtures/obscura.proto`
7. Fix imports, verify: `swift build`

**Scratchpad tests (`Tests/Scratchpad/ServerProtoTests.swift`):**
- Serialize `WebSocketFrame` → bytes → deserialize, assert fields match
- Serialize `Envelope` with dummy ciphertext, verify byte layout
- Serialize `SendMessageRequest` with multiple envelopes (batch)
- Serialize/deserialize `AckMessage`
- If server reachable: POST real registration, verify response parses

**Also validate:**
- Which libsignal Swift package compiles with Swift 5.7 (scratchpad: generate keypair, sign, verify)
- GRDB compiles, can create in-memory database

**JS reference:** `public/proto/obscura/v1/obscura.proto`

---

### Layer 2: Client Proto + Signal Store

**Goal:** Client-to-client message types + Signal protocol store backed by GRDB.

**Steps:**
1. `protoc` on `../obscura-client-web/public/proto/v2/client.proto` → `Sources/ObscuraKit/Proto/Client/`
2. Implement `SignalStore` actor (GRDB-backed, same 15-method interface as JS `IndexedDBStore`)
3. Implement `APIClient` (URLSession, same endpoints as `api/client.js`)
4. Implement `GatewayConnection` (URLSessionWebSocketTask)

**Scratchpad tests (`Tests/Scratchpad/ClientProtoTests.swift`):**
- `ClientMessage` with type TEXT → serialize → wrap in `EncryptedMessage` → round-trip
- `ModelSync` with CREATE op, verify fields
- `DeviceInfo`, `FriendRequest`, `FriendResponse` round-trips

**Scratchpad tests (`Tests/Scratchpad/SignalStoreTests.swift`):**
- Generate identity keypair, store in GRDB, retrieve, assert match
- Store/load prekeys and signed prekeys
- Store/load sessions at `(userId, registrationId)` addresses
- Full local encrypt/decrypt: Alice → Bob using in-memory stores (no server)

**Scratchpad tests (`Tests/Scratchpad/APIClientTests.swift`):**
- Register user, assert token parses, userId extractable from JWT
- Login with device, assert fresh token
- Fetch prekey bundles, assert bundle has all required fields

**JS reference:** `public/proto/v2/client.proto`, `src/lib/IndexedDBStore.js`, `src/api/client.js`, `src/api/gateway.js`

---

### Layer 3: ORM

**Goal:** CRDT engine, model persistence, sync targeting, TTL. Port of `src/v2/orm/`.

**Steps:**
1. `GSet.swift` — grow-only set (add, merge, getAll, filter)
2. `LWWMap.swift` — last-writer-wins map (set, merge, delete via tombstone, timestamp conflict resolution)
3. `ModelStore.swift` — GRDB table for `[modelName, id]` keyed entries + associations + TTL
4. `Model.swift` — base: create, find, where, upsert, delete, handleSync, sign
5. `SyncManager.swift` — broadcast targeting (self-sync, private, belongs_to, all friends)
6. `TTLManager.swift` — schedule, cleanup, isExpired
7. `QueryBuilder.swift` — where(conditions).exec()
8. `Schema.swift` — define models from config, wire together

**Scratchpad tests (`Tests/Scratchpad/CRDTTests.swift`):**
- GSet: add 3 items, merge duplicate, assert count = 3
- GSet: merge two disjoint sets, assert union
- LWWMap: set value, set again with newer timestamp, assert latest wins
- LWWMap: concurrent conflict — older timestamp loses
- LWWMap: delete (tombstone), assert excluded from getAll
- LWWMap: merge remote entries, assert only newer entries update local

**Scratchpad tests (`Tests/Scratchpad/ModelTests.swift`):**
- Define "story" model (g-set, fields: {content: string, mediaRef: string?})
- `model.create({content: "hello"})` → verify ID generated, timestamp set, persisted
- `model.find(id)` → verify retrieval
- `model.all()` → verify listing
- `model.where({authorDeviceId: "xyz"}).exec()` → verify filtering
- `model.handleSync(remoteEntry)` → verify merge into local CRDT

**Scratchpad tests (`Tests/Scratchpad/SyncManagerTests.swift`):**
- Private model: broadcast targets = only own devices
- Public model: broadcast targets = own devices + all accepted friends
- belongs_to model: broadcast targets = own devices + group members
- TTL: schedule "24h", verify isExpired = false now, true after advancing clock

**JS reference:** `src/v2/orm/crdt/GSet.js`, `src/v2/orm/crdt/LWWMap.js`, `src/v2/orm/Model.js`, `src/v2/orm/storage/ModelStore.js`, `src/v2/orm/sync/SyncManager.js`, `src/v2/orm/sync/TTLManager.js`, `src/v2/orm/QueryBuilder.js`, `src/v2/orm/index.js`

---

### Layer 4: Stores + Actors + ObscuraClient Facade

**Goal:** Wire layers 1-3 into the public API.

**Steps:**
1. `FriendActor` — wraps GRDB `FriendStore`, manages friend state + device lists
2. `MessageActor` — wraps GRDB `MessageStore`, messages by conversationId
3. `DeviceActor` — wraps GRDB `DeviceStore`, device identity + own device list
4. `MessengerActor` — encrypt/decrypt/queue/flush, device mapping, prekey bundle fetching. Uses serial execution internally to protect Signal ratchet state from actor reentrancy.
5. `ObscuraClient` — facade that owns all actors, exposes the public API
6. `ObscuraTestClient` — thin wrapper for tests (register + connect in one call, waitForMessage with timeout)

**No separate scratchpad tests** — the scenario tests ARE the tests for this layer.

**JS reference:** `src/v2/store/friendStore.js`, `src/v2/store/messageStore.js`, `src/v2/store/deviceStore.js`, `src/lib/messenger.js`, `src/lib/ObscuraClient.js`, `test/helpers/testClient.js`

---

### Layer 5: Scenario Tests (the deliverable)

Live in `Tests/Scenarios/`. Use `ObscuraTestClient` which calls `ObscuraClient` — same API views use.

**Scenario 1-4: `CoreFlowTests.swift`**
```
1. Register → keys generated, token valid, userId parseable
2. Logout → login → identity restored, WebSocket connects
3. Friend request flow → pending → accepted → both see each other, safety codes match
4. Send message → receiver gets it → queued delivery after offline → persistence
```

**Scenario 5: `MultiDeviceLinkingTests.swift`**
```
5.1 New device login → link-pending state
5.2 Link code generation
5.3 Existing device approves → new device receives SYNC_BLOB (friends + messages)
5.4 Fan-out: message from Alice reaches both Bob devices
5.5 Self-sync: message from Bob2 triggers SENT_SYNC on Bob1
5.6 Link code replay rejection
5.7 Self-friend rejection
```

**Scenario 6: `AttachmentTests.swift`**
```
6.1 Upload → sender has attachment immediately
6.2 Fan-out to multiple devices via CONTENT_REFERENCE
6.3 Download + integrity check (JPEG header bytes)
6.4 Cache hit on second download
6.5 Offline delivery of attachments
```

**Scenario 7: `DeviceRevocationTests.swift`**
```
7.1 Three-way message exchange (Alice, Bob1, Bob2)
7.2 Bob1 revokes Bob2 using recovery phrase
7.3 All users notified via device announce
7.4 Bob2's messages purged from history
7.5 Bob2 self-bricks (data wiped)
```

**Scenario 8: `ORMTests.swift`**
```
8.1 Auto-generation (ID, timestamp, signature, author)
8.2 Local persistence via ORM finder
8.3 Fan-out to all friend devices
8.4 Self-sync to own devices
8.5 Receiver queries synced data
8.6 Reverse direction sync
8.7 Field validation rejects bad data
```

**Scenario 9: `PixFlowTests.swift`**
```
9.1 Capture + send to single recipient
9.2 Recipient queries unviewed pix, decrypts
9.3 Attachment download + JPEG validation
9.4 Multi-recipient pix (Alice → Bob + Carol)
9.5 Offline delivery
```

**Scenario 10: `StoryAttachmentTests.swift`**
```
10.1 Image-only story creation via ORM
10.2 Story syncs to friends with media via ModelSync
10.3 Receiver decrypts attachment
10.4 Cache works on second load
10.5 Story with text + image combined
```

---

## Execution Order (the loop)

```
 1. swift package init, add deps, swift build        ← prove toolchain works
 2. Layer 1: protoc server proto, scratchpad tests   ← swift test
 3. Layer 2: protoc client proto, signal store, API  ← swift test
 4. Layer 3: CRDTs, Model, ModelStore, Sync, TTL     ← swift test
 5. Layer 4: Stores, Actors, ObscuraClient           ← swift build
 6. Scenario 1-4                                     ← swift test (needs server)
 7. Scenario 5                                       ← swift test
 8. Scenario 6                                       ← swift test
 9. Scenario 7                                       ← swift test
10. Scenario 8                                       ← swift test
11. Scenario 9                                       ← swift test
12. Scenario 10                                      ← swift test
13. Delete Tests/Scratchpad/                         ← cleanup
```

Each step: build → test → fix → commit. If a scratchpad test reveals a wrong assumption, fix the layer before moving on.

---

## Key Files to Reference During Port

| JS Source | Swift Target |
|-----------|-------------|
| `public/proto/obscura/v1/obscura.proto` | `Proto/Server/` (generated) |
| `public/proto/v2/client.proto` | `Proto/Client/` (generated) |
| `src/v2/orm/crdt/GSet.js` | `ORM/CRDT/GSet.swift` |
| `src/v2/orm/crdt/LWWMap.js` | `ORM/CRDT/LWWMap.swift` |
| `src/v2/orm/Model.js` | `ORM/Model.swift` |
| `src/v2/orm/storage/ModelStore.js` | `ORM/ModelStore.swift` |
| `src/v2/orm/sync/SyncManager.js` | `ORM/SyncManager.swift` |
| `src/v2/orm/sync/TTLManager.js` | `ORM/TTLManager.swift` |
| `src/v2/orm/QueryBuilder.js` | `ORM/QueryBuilder.swift` |
| `src/v2/orm/index.js` | `ORM/Schema.swift` |
| `src/v2/store/friendStore.js` | `Stores/FriendStore.swift` |
| `src/v2/store/messageStore.js` | `Stores/MessageStore.swift` |
| `src/v2/store/deviceStore.js` | `Stores/DeviceStore.swift` |
| `src/lib/IndexedDBStore.js` | `Crypto/SignalStore.swift` |
| `src/lib/messenger.js` | `MessengerActor.swift` |
| `src/api/client.js` | `Network/APIClient.swift` |
| `src/api/gateway.js` | `Network/GatewayConnection.swift` |
| `test/helpers/testClient.js` | `ObscuraTestClient.swift` |

## Verification

- After each layer: `swift build && swift test`
- After all scenarios: `swift test` with server running
- Final: delete `Tests/Scratchpad/`, `swift test` — only scenario tests remain

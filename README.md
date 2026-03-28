# ObscuraKit-Swift

E2E encrypted data layer for the Obscura protocol. This is a **library, not an app** — it provides the client state machine that any iOS/macOS/SwiftUI application links against. Tested against `obscura.barrelmaker.dev`.

## Architecture

Three levels stacked and abstracted on each other. Views never go below `ObscuraClient`.

```
┌─────────────────────────────────────────────────────────────────┐
│                        SWIFTUI VIEWS                            │
│  Observes AsyncStream<[Friend]>, AsyncStream<[Message]>         │
│  Calls: send(), befriend(), acceptFriend(), sendRawMessage()    │
├─────────────────────────────────────────────────────────────────┤
│                     ObscuraClient (facade)                       │
│  Wires levels together. Envelope loop. Message routing.          │
│  Views never go below this line.                                │
╞═════════════════════════════════════════════════════════════════╡
│                                                                 │
│  LEVEL 3: ORM — Application data models                        │
│  Stories, streaks, profiles, settings on CRDT sync              │
│  GSet (add-only) / LWWMap (timestamp wins)                     │
│  Rides on: ClientMessage.Type.MODEL_SYNC                       │
│                                                                 │
╞═════════════════════════════════════════════════════════════════╡
│                                                                 │
│  LEVEL 2: Client Protocol — Encrypted client-to-client         │
│  Signal Protocol encrypt/decrypt, 20+ message types             │
│  Server never sees contents                                     │
│  Rides on: Envelope.message (opaque bytes to server)            │
│                                                                 │
╞═════════════════════════════════════════════════════════════════╡
│                                                                 │
│  LEVEL 1: Server Protocol — Binary transport                   │
│  WebSocket (EnvelopeBatch/AckMessage) + REST API                │
│  Server is a dumb relay of opaque encrypted blobs               │
│                                                                 │
╞═════════════════════════════════════════════════════════════════╡
│  STORAGE: GRDB/SQLite (Signal keys, friends, messages, ORM)    │
│  OBSERVATION: ValueObservation → AsyncStream (reactive, no poll)│
└─────────────────────────────────────────────────────────────────┘
```

**Abstraction boundaries:**
- Level 1 never sees what's inside an encrypted message
- Level 2 never sees ORM models or how CRDTs merge
- Level 3 never sees Signal sessions, WebSocket frames, or HTTP calls
- ObscuraClient is the only thing that crosses all three

## Public API

### Auth
```swift
let client = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")
try await client.register(username, password)  // user + device + Signal keys
try await client.login(username, password)     // restore session
try await client.logout()
```

### Connection
```swift
try await client.connect()    // WebSocket + decrypt/route/ACK loop + token refresh
client.disconnect()
```

### Friends
```swift
try await client.befriend(userId)        // encrypted FRIEND_REQUEST
try await client.acceptFriend(userId)    // encrypted FRIEND_RESPONSE
```

### Messaging
```swift
try await client.send(to: friendUserId, "Hello!")
try await client.sendRawMessage(to: userId, clientMessageData: protoBytes)
```

### Attachments
```swift
let result = try await client.api.uploadAttachment(data)
let bytes = try await client.api.fetchAttachment(id)
```

### Device Management
```swift
try await client.announceDevices()
try await client.announceDevices(isRevocation: true, signature: sig)
try await client.revokeDevice(recoveryPhrase, targetDeviceId: deviceId)
```

### Recovery
```swift
let phrase = client.generateRecoveryPhrase()  // 12-word BIP39
try await client.announceRecovery(phrase)
```

### Backup
```swift
try await client.uploadBackup()
let data = try await client.downloadBackup()
```

### Observable State (SwiftUI-ready)

GRDB ValueObservation pushes changes automatically — no polling.

```swift
// Reactive streams (emit on every DB write)
client.friends.observeAccepted()      // AsyncValueObservation<[Friend]>
client.friends.observePending()       // AsyncValueObservation<[Friend]>
client.messages.observeMessages(id)   // AsyncValueObservation<[Message]>
client.messages.observeConversationIds()
client.devices.observeOwnDevices()    // AsyncValueObservation<[OwnDevice]>

// Events stream (every received message)
client.events()                       // AsyncStream<ReceivedMessage>
try await client.waitForMessage()     // for tests
```

### SwiftUI Example
```swift
struct ChatView: View {
    let client: ObscuraClient
    let friendUserId: String
    @State private var messages: [Message] = []

    var body: some View {
        List(messages, id: \.messageId) { msg in
            Text(msg.content)
        }
        .task {
            for await updated in client.messages.observeMessages(friendUserId).values {
                messages = updated
            }
        }
    }
}
```

## File Structure

### Source — 2,988 lines (+ 2,565 generated proto + 261 BIP39 wordlist)

```
Sources/ObscuraKit/
├── ObscuraClient.swift          690  Public API facade. Envelope loop, routing, token refresh
├── ObscuraTestClient.swift       90  Thin test wrapper (register/login convenience)
├── ObscuraKit.swift               6  Module entry
├── Crypto/
│   ├── MessengerActor.swift     231  Signal encrypt/decrypt, auto-session, queue/flush, device map
│   ├── SignalStore.swift        261  GRDB-backed Signal store (15-method protocol interface)
│   ├── RecoveryKeys.swift       120  BIP39 phrase → Curve25519 keypair, sign/verify
│   ├── VerificationCode.swift    99  SHA-256 based 4-digit safety numbers
│   ├── SyncBlob.swift            48  Device linking state export/import
│   └── Bip39Wordlist.swift      261  2048-word BIP39 English wordlist
├── Network/
│   ├── APIClient.swift          293  URLSession REST: auth, devices, messages, attachments, backup
│   ├── GatewayConnection.swift  134  WebSocketKit (SwiftNIO): ticket auth, envelopes, ACK
│   └── Constants.swift            9  Rate limit delay
├── ORM/
│   ├── CRDT/
│   │   ├── GSet.swift            87  Grow-only set. Add, merge (union), filter, sort
│   │   └── LWWMap.swift         120  Last-writer-wins map. Timestamp conflict, tombstone delete
│   ├── ModelStore.swift         177  GRDB persistence + associations + TTL
│   └── ModelEntry.swift          37  Universal entry (id, data, timestamp, author, signature)
└── Stores/
    ├── FriendStore.swift        197  Friend actor + GRDB + reactive observation streams
    ├── MessageStore.swift       155  Message actor + GRDB + reactive observation streams
    ├── DeviceStore.swift        184  Device actor + GRDB + reactive observation streams
    └── Observation.swift         50  AsyncValueObservation bridge (GRDB → AsyncStream)
```

### Tests — 1,576 lines, 60 scenarios against live server

```
Tests/ScenarioTests/
├── CoreFlowTests.swift              123  Register, login, befriend, encrypted text exchange
├── MultiDeviceLinkingTests.swift     66  Second device, fan-out, self-friend rejection
├── OfflineQueueTests.swift          102  Disconnect, queue offline, reconnect + receive
├── AttachmentTests.swift             85  Upload, download, CONTENT_REFERENCE to friend
├── ORMTests.swift                   142  MODEL_SYNC CREATE, bidirectional, LWW conflict
├── PixFlowTests.swift                74  Image upload + encrypted send + download
├── StoryAttachmentTests.swift       121  Story with media via MODEL_SYNC
├── DeviceRevocationTests.swift       99  Message purge, device wipe, server device list
├── DeviceRevocationFlowTests.swift  132  DeviceAnnounce delivery, revocation processing
├── DeviceLinkFlowTests.swift        116  DEVICE_LINK_APPROVAL, full link + SYNC_BLOB
├── SyncBlobTests.swift              134  Export/import round-trip, delivery via server
├── VerificationCodeTests.swift      105  Safety numbers: deterministic, symmetric, device-aware
├── ObservationTests.swift           164  GRDB reactive streams: emit on write, multi-observer
└── RecoveryTests.swift              113  BIP39 phrase, sign/verify, backup upload/download
```

## Concurrency Model

**Swift Actors** — each domain runs in its own actor with compiler-enforced isolation:
- `FriendActor` — friend list, device lists, fan-out targets
- `MessageActor` — message history by conversation
- `DeviceActor` — device identity, own device list
- `MessengerActor` — Signal encrypt/decrypt (order-sensitive ratchet state)

No locks. No race conditions. The compiler prevents cross-actor mutable access.

## Documentation

| Doc | What it covers |
|-----|---------------|
| [docs/PITFALLS.md](docs/PITFALLS.md) | Every gotcha that wastes hours — Docker, libsignal version, WebSocket, server quirks |
| [docs/MESSAGE_FLOW.md](docs/MESSAGE_FLOW.md) | Complete send/receive data flow with ASCII diagrams |
| [docs/DOCKER_SETUP.md](docs/DOCKER_SETUP.md) | Quick start, what's in the image, rebuild guide |
| [SECURITY_AUDIT.md](SECURITY_AUDIT.md) | Security review: constant-time comparison, key derivation, signature verification |

## Build & Test

```bash
# Docker (Swift 6.1 + Rust libsignal FFI)
docker build -t obscura-kit:dev .
docker run --rm -v "$(pwd):/app" -v obscura-build-cache:/app/.build \
  -w /app -e LIBRARY_PATH=/usr/local/lib obscura-kit:dev swift test

# Or use dev.sh helper
./dev.sh test
./dev.sh test --filter CoreFlowTests
./dev.sh build
```

## Dependencies

- `signalapp/libsignal` v0.40.0 — Signal Protocol (vendored, Rust FFI)
- `apple/swift-protobuf` — protobuf codegen
- `groue/GRDB.swift` — SQLite persistence + ValueObservation
- `vapor/websocket-kit` — SwiftNIO WebSocket (Linux compatible)

## Server

- **API:** https://obscura.barrelmaker.dev
- **OpenAPI Spec:** https://obscura.barrelmaker.dev/openapi.yaml
- **Server Repo:** https://github.com/barrelmaker97/obscura-server

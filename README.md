# ObscuraKit (Swift)

The **native iOS platform layer** for the Obscura app (`obscura-pix`). Not a general-purpose
framework; one consumer, no API-stability obligation.

The normative brief is
[`obscura-proto/SPEC.md`](../obscura-proto/SPEC.md), with the app-facing
contract in [`obscura-proto/KIT_API.md`](../obscura-proto/KIT_API.md). Merge,
audience resolution, schemas, queries, expiry, and notification policy belong
in `obscura-pix`; do not add those layers to this kit.

Current platform gaps include receiving `DEVICE_LINK_APPROVAL` and replay
protection for device announcements. See `CLAUDE.md`. No Notification Service
Extension exists; shared storage/session plumbing and the remaining transport,
concurrency, migration, and device-verification work are documented in
[`docs/NSE_PREREQUISITES.md`](docs/NSE_PREREQUISITES.md).

**Why a native kit exists at all:** libsignal ships only as `libsignal-swift` (no supported
shared core), and background push processing cannot depend on a React Native
runtime. Those constraints justify native code; everything else belongs in the
app.

## What it does

Encryption, device fan-out, and a durable inbox. The app names the recipients, supplies opaque
bytes, and decides what those bytes mean.

```swift
// Send: the CALLER names the audience (SPEC §0.4). The kit resolves none of its own.
try await client.send(
    to: [bobUserId], modelKey: "story", entryId: "story_123", payload: jsonBytes)

// Receive: peek → decide → write → consume. An ack is a DELETE, so the row is the only copy
// until the app takes it (KIT_API.md §3).
for row in try await client.inbox.peek(limit: 100) {
    try await client.entries.put(model: row.modelKey!, entry: merged(row))
}
try await client.inbox.consume(ids)
```

The developer never touches protobufs, Signal sessions, or WebSocket frames — and the kit never
touches the meaning of a payload.

## Architecture

```
YOUR APP
  ↕
ObscuraClient (facade)
  ↕
Layer 3: Inbox + entry store + Infrastructure (friends, devices)
  ↕
Layer 2: Signal Protocol (encrypt/decrypt, sessions, keys)
  ↕
Layer 1: Transport (WebSocket + REST, protobuf frames)
  ↕
Storage: GRDB/SQLite (SQLCipher encrypted at rest)
```

Friends and Devices are infrastructure — they are how the kit addresses devices and resolves a
sender's display name. They are **not** how it picks an audience; the caller does that. Everything
else (messages, stories, profiles, settings) is application content the kit stores as opaque bytes.

## API

```swift
// Auth
try await client.register(username, password)
let scenario = try await client.loginSmart(username, password) // .existingDevice, .newDevice, etc.
try await client.connect()

// Friends
try await client.befriend(userId)
try await client.acceptFriend(userId)
for await friends in client.friends.observeAccepted().values { ... }

// Entries — send, receive, store. modelKey and payload are opaque to the kit.
try await client.send(to: [userId], modelKey: "story", entryId: id, payload: bytes)
let rows = try await client.inbox.peek(limit: 100)
try await client.inbox.consume(rows.map(\.id))
try await client.entries.put(model: "story", entry: entry)
let all = try await client.entries.all(model: "story")

// Ephemeral signals (typing indicators — not persisted, dropped rather than inboxed)
await client.sendTyping(modelKey: "directMessage", conversationId: convId)
for await who in client.observeTyping(modelKey: "directMessage", conversationId: convId).values { ... }

// Device linking (QR/code approval, enforced for new devices)
let code = client.generateLinkCode()
try await existingClient.validateAndApproveLink(code)
```

## What works

The offline unit suite covers wire conformance; scenario tests exercise a
server. Both jobs run on macOS because GRDB's bundled SQLCipher requires
`CommonCrypto` (see `docs/PITFALLS.md`).

The two kits prove the shared wire mappings with
`conformance/wire.json`. No test runs the two implementations directly against
each other, so broader behavioral interoperability is not claimed.

- Register, login, friend handshake, encrypted messaging
- Entries: send to a caller-named audience, receive into a durable inbox, store and read back
- Persist-then-ack: a failed durable write skips the ack, so the server redelivers (SPEC §0.9)
- Dedupe while pending: `envelope_id UNIQUE` + `INSERT OR IGNORE`
- Offline/reconnect: the server queues, and the inbox absorbs the duplicates that produces
- Attachments: encrypt, upload, download, cache — the bytes path, kept
- Device linking: QR/code generation, validation, approval flow
- Ephemeral signals: typing indicators, in-memory only, audience fails closed
- Self-sync: own *other* devices get your content too, and the sending device does not
- Schema migrations: `ObscuraSchema` + `DatabaseMigrator`, with the erase-on-change tripwire off
- Cross-platform: the **wire format** interoperates with Android

## What doesn't work yet

- Group-targeted sync has no server test
- Entry expiry is not implemented on either platform
- `MessageActor` is a compatibility surface; `getMessages` is reachable only from tests
- No remote device revocation; use `api.deleteDevice` from a device you still hold
- No FRIEND_SYNC — a second device learns about friends at link time only, not afterwards
- The demo apps under `App/` target APIs that are not part of the current kit

## Build & Test

```bash
./dev.sh build
./dev.sh test
./dev.sh test --filter CoreFlowTests
```

Requires macOS 13+, Xcode 16+. `dev.sh` sets `LIBRARY_PATH` for the vendored libsignal Rust FFI.

## iOS App

The app under `App/` is not a working sample; it targets APIs outside the
current kit contract. The shipping consumer is `obscura-pix`.

```bash
# Build libsignal for iOS simulator first:
cd vendored/libsignal
RUSTUP_TOOLCHAIN=stable CARGO_BUILD_TARGET=aarch64-apple-ios-sim ./swift/build_ffi.sh -r

# Then open in Xcode:
open App/obscura-base/obscura-base.xcodeproj
```

See `App/README.md` for details.

## Dependencies

- `signalapp/libsignal` v0.40.0 — Signal Protocol (vendored, Rust FFI)
- `apple/swift-protobuf` — protobuf codegen
- `groue/GRDB.swift` — SQLite persistence + ValueObservation (SQLCipher fork)
- `CryptoKit` — SHA-256, HMAC (system)
- `URLSessionWebSocketTask` — WebSocket (system)

## Docs

- [docs/CLIENT_API.md](docs/CLIENT_API.md) — Auth, friends, devices, device linking, backup
- [docs/MESSAGE_FLOW.md](docs/MESSAGE_FLOW.md) — Send/receive data flow diagrams
- [docs/PITFALLS.md](docs/PITFALLS.md) — Gotchas that waste hours

## Server

- **API:** https://obscura.barrelmaker.dev
- **Server Repo:** https://github.com/barrelmaker97/obscura-server

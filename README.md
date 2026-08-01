# ObscuraKit (Swift)

The **native iOS platform layer** for the Obscura app (`obscura-pix`). Not a general-purpose
framework; one consumer, no API-stability obligation.

> ### The reset has landed
>
> The normative brief is [`obscura-proto/SPEC.md` §0 — The kit boundary](../obscura-proto/SPEC.md),
> with the inventory in [`obscura-proto/RESET.md`](../obscura-proto/RESET.md) and the app-facing
> contract in [`obscura-proto/KIT_API.md`](../obscura-proto/KIT_API.md).
>
> **The ORM, CRDT engine, query DSL, audience-routing system and schema parser are gone**
> (§10 step 4). They existed here *and* in ObscuraKit-Kotlin, duplicated, to serve five flat models
> in one app that used almost none of them; merge and audience now live in obscura-pix, once. Three
> defects went with them: hard-coded application field names, a `.friends` broadcast narrowed by a
> stray `conversationId`, and — by construction — acking a `MODEL_SYNC` before durably persisting
> it. (The missing schema-migration mechanism was fixed separately and earlier, by
> `Storage/ObscuraSchema.swift`; the reset is what gave it its first real migration to run.)
>
> Still live, and not resolved by the reset: **this kit sends `DEVICE_LINK_APPROVAL` but cannot
> receive one**, and there is no device-announce replay protection. See `CLAUDE.md`.

**Why a native kit exists at all:** libsignal ships only as `libsignal-swift` (no supported
shared core), and the push path must decrypt with the app closed — on iOS, inside a Notification
Service Extension, which cannot run a React Native runtime. Those two facts justify native code.
Everything else belongs in the app.

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

8 unit tests (`Tests/UnitTests`, offline — the wire conformance vectors) and 198 scenario tests
(`Tests/ScenarioTests`, most against a live server; CI runs a native one). Both jobs must pass on
macOS: Linux cannot build this package at all, because GRDB's bundled SQLCipher needs
`CommonCrypto` (see `docs/PITFALLS.md`).

**"Cross-platform interop proven" was claimed here and was not true as written.** The two kits agree on the *wire* (`conformance/wire.json`), and after the reset they agree on far more of their *behavior* — the hard-coded field names and the narrowed `friends` broadcast that made this kit diverge were deleted with the routing engine. Behavioral parity is now a much smaller claim, but it is still a claim, not a proof: nothing runs the two kits against each other.

- Register, login, friend handshake, encrypted messaging
- Entries: send to a caller-named audience, receive into a durable inbox, store and read back
- Persist-then-ack: a failed durable write skips the ack, so the server redelivers (SPEC §0.9)
- Dedupe: `envelope_id UNIQUE` + `INSERT OR IGNORE`, because redelivery is guaranteed, not rare
- Offline/reconnect: the server queues, and the inbox absorbs the duplicates that produces
- Attachments: encrypt, upload, download, cache — the bytes path, kept
- Device linking: QR/code generation, validation, approval flow
- Ephemeral signals: typing indicators, in-memory only, audience fails closed
- Self-sync: own *other* devices get your content too, and the sending device does not
- Schema migrations: `ObscuraSchema` + `DatabaseMigrator`, with the erase-on-change tripwire off
- Cross-platform: the **wire format** interoperates with Android

## What doesn't work yet

- Group-targeted sync has no server test
- Entries never expire on either platform — TTL went with the engine and has not been rebuilt
- The old `MessageActor` still exists, with `getMessages` reachable only from tests
- The demo apps under `App/` still call the deleted ORM API and no longer compile
- ~~Session desync happens occasionally under load~~ — **diagnosed and FIXED** (Phase 2, PR #6,
  merged 2026-07-25). `MessengerActor.decrypt` defaulted `senderRegId: 1` while outbound sessions
  used the real one, so the two directions filed sessions at different addresses. Sessions now key on
  the device UUID (`obscura-proto/SPEC.md` §0.10), verified by `TwoDeviceSendTests` and
  `AuthorDeviceIdTests` on macOS CI against a real server.

## Build & Test

```bash
./dev.sh build
./dev.sh test
./dev.sh test --filter CoreFlowTests
```

Requires macOS 13+, Xcode 16+. `dev.sh` sets `LIBRARY_PATH` for the vendored libsignal Rust FFI.

## iOS App

Demo app at `App/`. **It does not currently build:** it was written against `client.register(Story.self)`
and the query DSL, which the reset deleted, and the real consumer of this kit is `obscura-pix`. Port
it or delete it — do not treat it as a working sample.

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

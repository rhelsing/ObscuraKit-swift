# ObscuraKit (Swift)

The **native iOS platform layer** for the Obscura app (`obscura-pix`). Not a general-purpose
framework; one consumer, no API-stability obligation.

> ### ⚠️ Mid-reset — much of what is documented below is being deleted
>
> The normative brief is [`obscura-proto/SPEC.md` §0 — The kit boundary](../obscura-proto/SPEC.md),
> with the deletion inventory in [`obscura-proto/RESET.md`](../obscura-proto/RESET.md).
>
> The ORM, CRDT engine, query DSL, audience-routing system and schema parser documented below
> exist here *and* in ObscuraKit-Kotlin, to serve five flat models in one app that uses almost
> none of them. They are being removed, and their logic moved into the app where it will exist
> once. **This README still describes the old design — trust `SPEC.md` over it.**
>
> This kit also carries live defects that the reset will resolve: it hard-codes application field
> names, narrows a `.friends` broadcast when an entry happens to carry a `conversationId`, has no
> schema-migration mechanism at all, has no device-announce replay protection, and reports a
> *userId* in a field documented as a device id. See `CLAUDE.md`.

**Why a native kit exists at all:** libsignal ships only as `libsignal-swift` (no supported
shared core), and the push path must decrypt with the app closed — on iOS, inside a Notification
Service Extension, which cannot run a React Native runtime. Those two facts justify native code.
Everything else belongs in the app.

## What it does

You define a model, the library handles encryption, sync to friends' devices, conflict resolution, and reactive UI updates.

```swift
struct Story: SyncModel {
    static let modelName = "story"
    static let sync: SyncStrategy = .gset
    static let scope: SyncScope = .friends
    static let ttl: TTL? = .hours(24)

    var content: String
    var authorUsername: String
}

let stories = client.register(Story.self)
try await stories.create(Story(content: "sunset", authorUsername: "alice"))

for await updated in stories.observe().values {
    // SwiftUI re-renders
}
```

The developer never touches protobufs, Signal sessions, or WebSocket frames.

## Architecture

```
YOUR APP
  ↕
ObscuraClient (facade)
  ↕
Layer 3: ORM (models, CRDT, sync, observation) + Infrastructure (friends, devices)
  ↕
Layer 2: Signal Protocol (encrypt/decrypt, sessions, keys)
  ↕
Layer 1: Transport (WebSocket + REST, protobuf frames)
  ↕
Storage: GRDB/SQLite (SQLCipher encrypted at rest)
```

Friends and Devices are infrastructure — they define who and where you sync to. Everything else (messages, stories, profiles, settings) is ORM content.

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

// ORM
let stories = client.register(Story.self)
try await stories.create(Story(content: "hello", authorUsername: "alice"))
await stories.where { "authorUsername" == "alice" }.exec()
await stories.where { "likes" >= 5 }.orderBy("likes", .desc).limit(10).exec()
for await updated in stories.observe().values { ... }

// Filtered observation (query-scoped, not observe-all-then-filter)
for await msgs in messages.where { "conversationId" == convId }.observe().values { ... }

// ECS signals (typing indicators, read receipts — ephemeral, not persisted)
messages.typing(conversationId: convId)
for await who in messages.observeTyping(conversationId: convId).values { ... }

// Device linking (QR/code approval, enforced for new devices)
let code = client.generateLinkCode()
try await existingClient.validateAndApproveLink(code)
```

## What works

Tested with 123 unit tests (offline, <1s) and 17 integration tests (live server).

**"Cross-platform interop proven" was claimed here and is not true as written.** The two kits agree on the *wire*; they do not agree on *behavior*. This kit still hard-codes application field names and narrows a `friends` broadcast — both of which the Kotlin kit does not do. Interop of the wire format is real; behavioral parity is not.

- Register, login, friend handshake, encrypted messaging
- ORM: typed models, create/find/upsert/delete, validation
- Queries: 11 operators, orderBy, limit, include() eager loading
- Query DSL: `"field" == value`, `"field" >= n`, `"field".oneOf([...])`, `"field".contains("x")`
- Auto-sync: create a model entry, friends receive it encrypted
- Private models: `.ownDevices` scope never leaves your devices
- Offline/reconnect: server queues messages, CRDT merges on arrival
- LWW conflict resolution: newer timestamp wins, deterministic
- Reactive observation: GRDB ValueObservation, no polling
- Filtered observation: per-query scoped streams
- TTL: ephemeral content with configurable expiry
- Device linking: QR/code generation, validation, approval flow
- ECS signals: typing indicators, read receipts (ephemeral, in-memory only)
- Self-sync: own devices get your content too
- Cross-platform: the **wire format** interoperates with Android. Behavior does not — see above.

## What doesn't work yet

- Group-targeted sync has no server test
- TTL cleanup must be called manually
- The old `MessageActor` still exists alongside the ORM
- `include()` works locally but not tested over the wire
- Session desync happens occasionally under load (investigating)

## Build & Test

```bash
./dev.sh build
./dev.sh test
./dev.sh test --filter CoreFlowTests
```

Requires macOS 13+, Xcode 16+. `dev.sh` sets `LIBRARY_PATH` for the vendored libsignal Rust FFI.

## iOS App

Demo app at `App/`. Register two users on two simulators, befriend via friend codes, chat with encrypted ORM messages, see typing indicators cross-platform.

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

- [docs/ORM.md](docs/ORM.md) — ORM usage: models, queries, observation, offline behavior
- [docs/CLIENT_API.md](docs/CLIENT_API.md) — Auth, friends, devices, device linking, backup
- [docs/MESSAGE_FLOW.md](docs/MESSAGE_FLOW.md) — Send/receive data flow diagrams
- [docs/PITFALLS.md](docs/PITFALLS.md) — Gotchas that waste hours

## Server

- **API:** https://obscura.barrelmaker.dev
- **Server Repo:** https://github.com/barrelmaker97/obscura-server

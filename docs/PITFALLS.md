# Pitfalls — Things That Will Waste Your Time

## Docker / Build

**Swift 6.1 standalone toolchain does NOT work on macOS 12.** The `.pkg` installs fine but every binary crashes with `Symbol not found: (_$s10Foundation10NSNotFoundSivg)`. The toolchain requires macOS 13+. Update the OS or use Docker.

**`-index-store-path` crashes clang on Linux.** The `swift-crypto` and SwiftNIO C shims pass this Apple-only flag. The Docker image has a clang wrapper at `/usr/bin/clang` that strips it. If you rebuild the Docker image, you MUST include this wrapper or C compilation fails on every build.

**GRDB requires SQLite with snapshot support.** The Ubuntu `libsqlite3-dev` package does NOT have `SQLITE_ENABLE_SNAPSHOT`. The Dockerfile builds SQLite from source with this flag. Without it, linking fails with `undefined reference to sqlite3_snapshot_open`.

**Docker build cache is a named volume.** Use `docker volume create obscura-build-cache` and mount it at `/app/.build`. Without this, every `swift test` rebuilds ALL dependencies (~5 min). With it, incremental builds are ~5-10 seconds.

**`LIBRARY_PATH=/usr/local/lib` is required.** The libsignal Rust FFI (`.a` file) lives at `/usr/local/lib/libsignal_ffi.a` in the Docker image. Without this env var, linking fails with `undefined reference to signal_*`.

## libsignal

**Use v0.40.0, NOT latest.** The latest (v0.90+) requires Kyber (post-quantum) keys for ALL PreKeyBundle constructors. The server doesn't support Kyber. v0.40.0 has non-Kyber constructors that work with the current server.

**The Rust FFI must be built with the `build_ffi.sh` script**, not just `cargo build`. The script includes testing symbols (`signal_testing_*`) that the Swift wrapper references. Without them, linking fails.

**`InMemorySignalProtocolStore` is fine for tests but not production.** Sessions are lost on process exit. Use `PersistentSignalStore` (GRDB-backed) which implements all 6 libsignal protocol interfaces with SQLite persistence.

**Signal sessions are keyed as `(userId, registrationId)`.** Not `(userId, deviceId)`. The registrationId comes from the prekey bundle. The web client uses `SignalProtocolAddress(userId, registrationId)`. The `deviceMap` in MessengerActor maps deviceId → (userId, registrationId).

## WebSocket

**`URLSessionWebSocketTask` does NOT work on Linux.** The `swift-corelibs-foundation` implementation uses libcurl which has no WebSocket support. Use `WebSocketKit` (SwiftNIO) instead. It works on both Linux and macOS.

**The envelope loop must use a buffered queue for `waitForMessage()`.** If you create a fresh `AsyncStream` subscription after the message has already been processed by the loop, you miss it. The `messageQueue` array in ObscuraClient buffers processed messages for test consumption.

**Gateway timeout should be ≤30 seconds in the envelope loop.** The default was 60s which caused test hangs — cancelled tasks waited a full minute before exiting.

## Server

**500ms minimum delay between API requests.** The server rate-limits aggressively. Use `await rateLimitDelay()` between every server call. Tests must run serially, not in parallel.

**Password must be ≥12 characters.** The server rejects shorter passwords with HTTP 400.

**Device provisioning validates XEdDSA signatures.** You cannot use dummy/fake keys for provisioning. The `identityKey` must be a real Curve25519 key (33 bytes, 0x05 prefix) and the `signedPreKey.signature` must be a valid XEdDSA signature (64 bytes) signed by the identity key. libsignal handles this correctly.

**`POST /v1/messages` requires `Idempotency-Key` header** (UUID) and `Content-Type: application/x-protobuf`. Missing either causes 400.

## Protobuf

**Generated proto types are `internal`, not `public`.** SwiftProtobuf's `protoc-gen-swift` defaults to internal visibility. This means `Obscura_V2_ClientMessage` can't appear in public method signatures. Use `Data` (serialized bytes) in public API, deserialize internally.

## Testing

**All scenario tests hit the real server at `obscura.barrelmaker.dev`.** They create real users, real Signal sessions, real WebSocket connections. Each test registers new unique usernames (`test_RANDOM`).

**Tests that call `client.connect()` start an envelope loop task.** This task must be cancelled via `client.disconnect()` before the test ends, otherwise it blocks the next test. The `ObscuraClient.deinit` handles this, but only if the client is deallocated (not retained by test references).

**The `constantTimeEqual` function must be used for identity key comparison.** Using `==` on `Data` is timing-vulnerable. This was flagged by the security audit.

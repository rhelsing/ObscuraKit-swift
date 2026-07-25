# Pitfalls — Things That Will Waste Your Time

## Build

**Requires macOS 13+ and Xcode 16+.** The project uses `URLSessionWebSocketTask` (macOS 13+), CryptoKit, and Swift 6.1 toolchain. Ensure Xcode is up to date — the Swift toolchain uses Xcode's SDK for platform headers.

**`LIBRARY_PATH` must point to libsignal FFI.** The vendored libsignal Rust FFI (`.a` file) must be on the library path. Use `LIBRARY_PATH="$(pwd)/vendored/libsignal/target/release" swift build`. The `dev.sh` helper sets this automatically.

## libsignal

**Use v0.40.0, NOT latest.** The latest (v0.90+) requires Kyber (post-quantum) keys for ALL PreKeyBundle constructors. The server doesn't support Kyber. v0.40.0 has non-Kyber constructors that work with the current server.

**The Rust FFI must be built with the `build_ffi.sh` script**, not just `cargo build`. The script includes testing symbols (`signal_testing_*`) that the Swift wrapper references. Without them, linking fails.

**`InMemorySignalProtocolStore` is fine for tests but not production.** Sessions are lost on process exit. Use `PersistentSignalStore` (GRDB-backed) which implements all 6 libsignal protocol interfaces with SQLite persistence.

**⚠️ Signal sessions are keyed as `(userId, registrationId)` — and that is the bug, not the design.**
This describes the code as it stands on `main`; do **not** treat it as guidance. `registrationId`
travels on exactly one wire surface (`PreKeyBundleResponse`), while the device UUID travels on all of
them, so this addressing breaks multi-device delivery and makes `authorDeviceId` unattributable
(`obscura-proto/PLAN.md` F1, F4). The contract is now `obscura-proto/SPEC.md` §0.10: address
`ProtocolAddress` on the **device UUID**, select the inbound session from
`Envelope.sender_device_id`, and select prekey bundles by device UUID with no fallback.

Swift-specific defect: `MessengerActor.decrypt(...)` defaults `senderRegId: 1` and its only call
site never overrides it, so outbound sessions are filed at `(userId, realRegId)` and inbound ones at
`(userId, 1)` — the two directions use different addresses. This is the most likely explanation for
"session desync happens occasionally under load" in the README. The fix is written on
`swift/phase2-device-uuid` but is **unmerged and uncompiled** — it needs a macOS build and test run.
Kotlin already migrated (PR #40).

## WebSocket

**The project uses `URLSessionWebSocketTask` (native Foundation).** The previous WebSocketKit/SwiftNIO dependency was removed in March 2026.

**Linux is not a supported build target — but `URLSessionWebSocketTask` is not why.** Investigated
2026-07-14 (`obscura-proto/PLAN.md` 0.4): the build walls at **GRDB's bundled SQLCipher**, which
needs `CommonCrypto/CommonCrypto.h` (Apple-only), long before anything WebSocket-related is reached.
SQLCipher is the at-rest cipher for the message store, the Signal session store is GRDB-backed, and
the module is monolithic, so no crypto-only slice compiles either. What *does* build on Linux is
libsignal v0.40.0's Rust FFI, given two environmental fixes: point `LIBCLANG_PATH` at the Android
NDK's LLVM-18 libclang (clang 21's bindgen mis-parses vendored BoringSSL and fails on
`GENERAL_NAME_new`), and put a `libxml2.so.2` shim on `LD_LIBRARY_PATH`. That is enough to prove
protocol *mechanisms* at the libsignal level, and it is how the addressing split was demonstrated
(`verification/AddressingProbe` on `verify/swift-addressing-probe`). Full end-to-end verification of
this kit needs macOS CI. No SQLCipher fork — decided 2026-07-16.

**The envelope loop must use a buffered queue for `waitForMessage()`.** If you create a fresh `AsyncStream` subscription after the message has already been processed by the loop, you miss it. The `messageQueue` array in ObscuraClient buffers processed messages for test consumption.

**Gateway timeout should be ≤30 seconds in the envelope loop.** The default was 60s which caused test hangs — cancelled tasks waited a full minute before exiting.

## Server

**Server rate limits are per-instance (3 instances behind load balancer):**
- General endpoints: 10 req/s sustained, 20 req/s burst
- Auth endpoints (register, login, refresh): 1 req/s sustained, 3 req/s burst

Use `await rateLimitDelay()` (100ms) between general calls and `await authRateLimitDelay()` (1000ms) between auth calls. Both delays are configurable via `SERVER_REQUEST_DELAY_MS` and `AUTH_REQUEST_DELAY_MS` in Constants.swift. Tests must run serially, not in parallel.

**Password must be ≥12 characters.** The server rejects shorter passwords with HTTP 400.

**Device provisioning validates XEdDSA signatures.** You cannot use dummy/fake keys for provisioning. The `identityKey` must be a real Curve25519 key (33 bytes, 0x05 prefix) and the `signedPreKey.signature` must be a valid XEdDSA signature (64 bytes) signed by the identity key. libsignal handles this correctly.

**`POST /v1/messages` requires `Idempotency-Key` header** (content-hash based) and `Content-Type: application/x-protobuf`. Missing either causes 400.

## Protobuf

**Generated proto types are `internal`, not `public`.** SwiftProtobuf's `protoc-gen-swift` defaults to internal visibility. This means `Obscura_V2_ClientMessage` can't appear in public method signatures. Use `Data` (serialized bytes) in public API, deserialize internally.

## Testing

**All scenario tests hit the real server at `obscura.barrelmaker.dev`.** They create real users, real Signal sessions, real WebSocket connections. Each test registers new unique usernames (`test_RANDOM`).

**Tests that call `client.connect()` start an envelope loop task.** This task must be cancelled via `client.disconnect()` before the test ends, otherwise it blocks the next test. The `ObscuraClient.deinit` handles this, but only if the client is deallocated (not retained by test references).

**The `constantTimeEqual` function must be used for identity key comparison.** Using `==` on `Data` is timing-vulnerable. This was flagged by the security audit.

## Historical: Docker Notes

These are preserved for reference. Docker is no longer needed for development.

- Swift 6.1 standalone toolchain does NOT work on macOS 12 (needs 13+).
- `-index-store-path` crashes clang on Linux; Docker image had a wrapper to strip it.
- GRDB requires SQLite with `SQLITE_ENABLE_SNAPSHOT` (Dockerfile built SQLite from source).
- Docker build cache was a named volume at `/app/.build`.
- `LIBRARY_PATH=/usr/local/lib` was required in Docker for the libsignal FFI.

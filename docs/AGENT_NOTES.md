# Agent Notes — Hard-Won Lessons

Things that aren't obvious from reading the code. Saves hours.

## Testing

**Use `--filter SuiteName` for focused testing.** CoreFlowTests is the best smoke test — if scenarios 1-4 pass, crypto + networking + routing all work. Task cancellation is cooperative — if the loop is blocked on `gateway.waitForRawEnvelope()`, it won't check cancellation until the 30s timeout.

```bash
swift test --filter CoreFlowTests
```

**The 100ms rate limit between server calls is load-bearing.** Without `rateLimitDelay()`, tests flake with HTTP 429. Every helper method includes it. If you add new server-calling methods, include the delay. The default is `SERVER_REQUEST_DELAY_MS = 100` in `Network/Constants.swift` (auth calls use `authRateLimitDelay()`, 1000ms); this note said 500ms, which matched nothing — `CLAUDE.md` and `docs/PITFALLS.md` both say 100.

**Tests create real users on the live server.** Each test registers unique usernames (`test_RANDOM`). Don't worry about cleanup — the server handles it.

## The Envelope Loop Race Condition

When `ObscuraClient.connect()` starts the envelope loop, incoming messages get processed immediately and pushed to a buffered queue (`messageQueue` array, capped at 1000). `waitForMessage()` checks this buffer first, then waits on a continuation.

**If you replace the buffer with a pure AsyncStream subscription, tests will break.** The message arrives and gets processed before the test's subscription is set up. The buffer is the fix. Don't remove it.

## libsignal Version

**v0.40.0 — not latest.** The server doesn't support Kyber (post-quantum) keys. Latest libsignal (v0.90+) requires Kyber for ALL PreKeyBundle constructors. If you upgrade, every test that creates a PreKeyBundle fails with a compiler error about missing kyberPrekey parameters. The vendored copy is at `vendored/libsignal/` and the Rust FFI must be rebuilt if you change versions.

## Biggest Tech Debt

**`[String: Any]` in APIClient is limited to `decodeJWT`.** API responses use
typed `Codable` models; only the JWT payload is schemaless.

**Generated protobuf types are `internal` visibility.** This is why `sendRawMessage` takes `Data`.
Regenerating with `--swift_opt=Visibility=Public` would fix that but exposes the generated
`Obscura_V1_*` / `Obscura_Client_V1_*` names on the public surface. Better to wrap in domain types.

## Reference Codebase

**There is no "feature parity reference." Do not copy another kit's design.**

The only thing this kit must match in ObscuraKit-Kotlin is the **wire**
(`obscura-proto/conformance/wire.json`). Behavior is specified by
[`obscura-proto/SPEC.md`](../../obscura-proto/SPEC.md) — the contract, not a sibling codebase.

## The Public API Contract

`ObscuraClient`'s public methods are what views call. `ObscuraTestClient` is what tests call. Both call the same underlying methods. If you change a signature on ObscuraClient, update TestClient too. If both call the same code path, the abstraction is correct.

**GRDB ValueObservation is THE reactive layer.** Don't add @Published, Combine, or a second observation mechanism. The `observeAccepted()`, `observeMessages()`, `observeOwnDevices()` streams on the actors are the canonical way views subscribe. Adding alternatives creates drift.

## Security

**ObscuraLogger protocol is the security audit trail.** All security-sensitive events (decrypt failures, identity changes, token refresh failures, frame parse errors) go through the logger. Default is `PrintLogger`. Set a custom logger via `ObscuraClient.init(apiURL:logger:)`.

**Identity key changes are logged automatically.** `PersistentSignalStore.saveIdentity()` detects key changes and calls `logger.identityChanged()`. This is the hook for surfacing MITM warnings to the UI.

## Build Environment

The project builds natively on macOS 13+ with Swift 6.1. No Docker required. Dependencies:
- `signalapp/libsignal` v0.40.0 (vendored, Rust FFI)
- `apple/swift-protobuf`
- `groue/GRDB.swift`
- CryptoKit (system framework, replaces hand-rolled SHA-256)
- URLSessionWebSocketTask (system framework, replaces WebSocketKit)

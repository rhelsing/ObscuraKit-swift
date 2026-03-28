# Agent Notes — Hard-Won Lessons

Things that aren't obvious from reading the code. Saves hours.

## Testing

**Always use `--filter SuiteName`, never bare `swift test`.** The full suite hangs in Docker because WebSocket envelope loop tasks from one test don't clean up before the next starts. Task cancellation is cooperative — if the loop is blocked on `gateway.waitForRawEnvelope()`, it won't check cancellation until the 30s timeout. CoreFlowTests is the best smoke test — if scenarios 1-4 pass, crypto + networking + routing all work.

**500ms rate limit between server calls is load-bearing.** Without `rateLimitDelay()`, tests flake with HTTP 429. Every helper method includes it. If you add new server-calling methods, include the delay.

**Tests create real users on the live server.** Each test registers unique usernames (`test_RANDOM`). Don't worry about cleanup — the server handles it.

## The Envelope Loop Race Condition

When `ObscuraClient.connect()` starts the envelope loop, incoming messages get processed immediately and pushed to a buffered queue (`messageQueue` array). `waitForMessage()` checks this buffer first, then waits on a continuation.

**If you replace the buffer with a pure AsyncStream subscription, tests will break.** The message arrives and gets processed before the test's subscription is set up. The buffer is the fix. Don't remove it.

## libsignal Version

**v0.40.0 — not latest.** The server doesn't support Kyber (post-quantum) keys. Latest libsignal (v0.90+) requires Kyber for ALL PreKeyBundle constructors. If you upgrade, every test that creates a PreKeyBundle fails with a compiler error about missing kyberPrekey parameters. The vendored copy is at `vendored/libsignal/` and the Rust FFI must be rebuilt if you change versions.

## Biggest Tech Debt

**`[String: Any]` in APIClient (41 occurrences).** The entire API layer returns untyped dictionaries. The Codable refactor in `docs/plans/production-cleanup.md` Phase A2 is the most impactful single change. Do it before adding any new endpoints.

**Hand-rolled SHA-256 (two copies, 140 lines).** Replace with CryptoKit after macOS upgrade. See Phase A1 in the cleanup plan.

**Generated protobuf types are `internal` visibility.** This is why `ReceivedMessage` uses `Int` for type and `sendRawMessage` takes `Data`. Regenerating with `--swift_opt=Visibility=Public` fixes this but leaks ugly `Obscura_V2_` naming. Better to wrap in domain types (Phase B3).

## Reference Codebase

**The Kotlin client at `../obscura-client-kotlin` is the feature parity reference.** Their `ObscuraClient.kt` (954 lines) is structurally what ours should look like after the Phase B refactor. Check their test suite when adding features — if they test it, we should too. Their `SignalStore.kt` is the reference for how persistent Signal stores work with SQL.

## The Public API Contract

`ObscuraClient`'s public methods are what views call. `ObscuraTestClient` is what tests call. Both call the same underlying methods. If you change a signature on ObscuraClient, update TestClient too. If both call the same code path, the abstraction is correct.

**GRDB ValueObservation is THE reactive layer.** Don't add @Published, Combine, or a second observation mechanism. The `observeAccepted()`, `observeMessages()`, `observeOwnDevices()` streams on the actors are the canonical way views subscribe. Adding alternatives creates drift.

## macOS / Environment

The user runs macOS 12 on ARM with Rosetta. Swift 6.1 toolchain crashes on macOS 12 (needs 13+). Docker is required until OS upgrade. After upgrading: native `swift test`, drop WebSocketKit for URLSessionWebSocketTask, CryptoKit replaces hand-rolled crypto. Don't tell the user to `brew upgrade` — their Puma gem links to openssl@1.1 which brew might remove.

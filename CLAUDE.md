# Claude Code Context

## ⚠️ Read this before changing anything

**This repo is mid-reset. Large parts of it are scheduled for deletion.**

Read [`obscura-proto/SPEC.md` §0 — The kit boundary](../obscura-proto/SPEC.md),
[`obscura-proto/PLAN.md`](../obscura-proto/PLAN.md) (order of operations + current phase status) and
[`obscura-proto/RESET.md`](../obscura-proto/RESET.md) **first**. They are the brief.

**Where this kit is (2026-07-25): Phase 2 is LANDED and PROVEN on `main`.** Phases 1 and 2 shipped
across the proto, the server and both kits between 07-19 and 07-25. This kit's share — the
throwing-persist residual, device-UUID session addressing, the F9 own-device registry, honest
`authorDeviceId`, and the Option B envelope — merged via PRs #6, #8 and #9.

It is **verified, not asserted**: macOS CI run `30138464166` executed
`TwoDeviceSendTests` (two-device decrypt after a *sender reconnect*, the own-device registry, the
link-approval approver half) and `AuthorDeviceIdTests` against a real server, and they passed. The
UNVERIFIED labels on the original commits are historical — CI has since compiled and run them.
`obscura-proto/PLAN.md` records the acceptance sign-off and four known gaps. **Phase 3 (the reset)
is unblocked**; read those gaps before starting it.

The rule that governs this repo:

> **If the kit reads it, it is a field in `client.proto`.
> If it is not in `client.proto`, the kit MUST NOT read it.**

**Do not "improve" the ORM, the CRDT layer, the query builder, the audience/routing engine, or
the schema parser. They are on the deletion list.** They exist here *and* in ObscuraKit-Kotlin,
duplicated, to serve five flat models in one app that uses almost none of them.

Known live defects in this kit, documented so nobody rediscovers them as "improvements":

- `SyncManager.resolveScopedRecipientUserIds` **hard-codes application field names**
  (`recipientUsername`, `conversationId`). SPEC §0.4 forbids this.
- `SyncManager.resolveTargets` **narrows a `.friends` broadcast** to a direct send when an entry
  happens to carry one of those fields. A `friends` audience must reach all accepted friends.
- **No schema migration mechanism exists** — every store is `CREATE TABLE IF NOT EXISTS`. Adding
  a column to an existing install is currently impossible.
- **No device-announce replay protection.**
- `RoutingConformanceTests` **re-implements the audience mapping in the test harness** and
  discards the `field` name — so it passes without exercising production code.
- ~~`authorDeviceId` is a lie~~ — **FIXED (Phase 2, PR #6).** It is now the device UUID of the
  session that decrypted, and `ReceivedMessage.senderDeviceId` carries the sender's real device.
  Pinned by `AuthorDeviceIdTests`. `SPEC.md` §0.10 is the contract.
- ~~Signal sessions are addressed by `registrationId`; `decrypt` defaults `senderRegId: 1`~~ —
  **FIXED (Phase 2, PR #6).** Sessions key on the device UUID in both directions, taken from
  `Envelope.sender_device_id`. This was `PLAN.md` F1/F4 and the cause of the old README note about
  "session desync under load". Pinned by `TwoDeviceSendTests`.
- ~~`routeMessage` is non-throwing and swallows persistence errors~~ — **FIXED for the TEXT and
  friend-graph paths (Phase 1 residual, PR #6):** persistence throws, so a failed durable write
  propagates and the ack is skipped (`SPEC.md` §0.9 rule 3). **NOT fixed for MODEL_SYNC — see the
  next entry, which is still live.**
- **MODEL_SYNC is acked before it is durably persisted, and this is knowingly accepted — do not
  "fix" it here.** `routeMessage`'s `.modelSync` case calls `_ = await syncManager.handleIncoming(…)`,
  which is non-throwing, and every layer beneath swallows write errors: `SyncManager.handleIncoming`
  → `Model.handleSync` → `GSet.merge` / `LWWMap.merge` → `ModelStore.put`, still `try? await
  db.write` (five sites in `ModelStore.swift`). A MODEL_SYNC whose write fails is acked, and an ack
  is a DELETE. This is not a corner case: MODEL_SYNC carries every `directMessage`, `pix` and `story`
  the app sends. Closing it means plumbing `throws` through the ORM and CRDT engine that Phase 3
  **deletes** — hardening deletion-bound code, which is the failure mode `SPEC.md` §0.8 exists to
  stop. The decision, its cost, and the narrow fallback if Phase 3 slips are recorded in
  [`obscura-proto/PLAN.md`](../obscura-proto/PLAN.md), Phase 1 status block (2026-07-24). Phase 3
  resolves it by construction — verify it does when the deletion lands.

> **Not a reference:** `obscura-client-web` is a **throwaway proof-of-concept**. It is not a
> porting target and not a normative implementation. This file used to list its source files as
> "the reference for porting." That instruction is a large part of why this repo looks the way it
> does. It has been removed — do not reinstate it.

## Project Overview

ObscuraKit — the **native iOS platform layer** for the Obscura app (`obscura-pix`). Not a
general-purpose framework; it has one consumer and owes API stability to no one.

It exists natively for exactly two reasons: libsignal ships only as `libsignal-swift` (no shared
core), and the push path must decrypt with the app closed (Notification Service Extension — no
React Native runtime). Everything else belongs in the app.

It must agree with ObscuraKit-Kotlin on the **wire** (`conformance/wire.json`) and nothing more.

@README.md
@docs/PITFALLS.md
@docs/MESSAGE_FLOW.md
@docs/AGENT_NOTES.md

## Server

- **API:** https://obscura.barrelmaker.dev
- **OpenAPI Spec:** https://obscura.barrelmaker.dev/openapi.yaml
- **Server Repo:** https://github.com/barrelmaker97/obscura-server

All smoke/scenario tests run against the live server.

### Rate Limits (per-instance, 3 instances load balanced)
- **General endpoints:** 10 req/s sustained, 20 req/s burst
- **Auth endpoints** (register, login, refresh): 1 req/s sustained, 3 req/s burst
- Use `await rateLimitDelay()` (100ms) between general calls
- Use `await authRateLimitDelay()` (1000ms) between auth calls
- Both configurable via `SERVER_REQUEST_DELAY_MS` and `AUTH_REQUEST_DELAY_MS` in `Constants.swift`

## Reference implementations

There is no porting reference. This kit is written against the contract in `obscura-proto`
(`SPEC.md` + `conformance/`), not against another codebase.

> A section here used to enumerate the source files of `obscura-client-web` — a throwaway
> proof-of-concept — as "the reference for porting", and `docs/AGENT_NOTES.md` pointed at the
> Kotlin kit as "the feature parity reference". Both instructions told agents to copy designs
> that were themselves unexamined, which is how an ORM, a CRDT engine and a query DSL ended up
> duplicated across two kits. Removed deliberately. Do not reinstate.

## Server API Quick Reference

### Auth Tokens
- **User-Scoped JWT:** From POST `/v1/users` or `/v1/sessions`. For device provisioning.
- **Device-Scoped JWT:** Includes `deviceId` claim. Required for messaging, keys, gateway.
- **Refresh Token:** Rotation invalidates old token. Use POST `/v1/sessions/refresh`.
- **WebSocket Ticket:** Single-use from POST `/v1/gateway/ticket`, pass as query param to `/v1/gateway`.

### Endpoints
```
POST   /v1/users                 Register (no auth, JSON)
POST   /v1/sessions              Login (no auth, JSON)
POST   /v1/sessions/refresh      Refresh tokens (no auth, JSON)
DELETE /v1/sessions              Logout (Bearer)

POST   /v1/devices               Provision device with keys (Bearer, JSON)
GET    /v1/devices               List devices (Bearer)
GET    /v1/devices/{id}          Get device (Bearer)
PUT    /v1/devices/{id}          Update device (Bearer)
DELETE /v1/devices/{id}          Delete device + cascade (Bearer)

POST   /v1/devices/keys          Upload prekeys / device takeover (Device-Scoped, JSON)
GET    /v1/users/{userId}        Fetch prekey bundles (Device-Scoped, JSON)

POST   /v1/messages              Send batch (Device-Scoped, Protobuf, Idempotency-Key header)

POST   /v1/gateway/ticket        Get WebSocket ticket (Device-Scoped)
GET    /v1/gateway               WebSocket connect (ticket query param, Protobuf frames)

POST   /v1/attachments           Upload encrypted blob (Bearer, binary)
GET    /v1/attachments/{id}      Download (Bearer, binary, ETag caching)

GET    /v1/backup                Download backup (Bearer, binary)
HEAD   /v1/backup                Check backup metadata (Bearer)
POST   /v1/backup                Upload backup (Bearer, binary, ETag optimistic locking)

PUT    /v1/push-tokens           Register APNS/FCM token (Device-Scoped, JSON)
```

### Key Response Shapes

**AuthResponse:** `{ token, refreshToken, expiresAt, deviceId? }`

**PreKeyBundleResponse (from GET /v1/users/{userId}):**
```json
[{
  "deviceId": "uuid",
  "registrationId": 12345,
  "identityKey": "base64",
  "signedPreKey": { "keyId": 1, "publicKey": "base64", "signature": "base64" },
  "oneTimePreKey": { "keyId": 1, "publicKey": "base64" }
}]
```

**CreateDeviceRequest (POST /v1/devices):**
```json
{
  "name": "iPhone",
  "identityKey": "base64",
  "registrationId": 12345,
  "signedPreKey": { "keyId": 1, "publicKey": "base64", "signature": "base64" },
  "oneTimePreKeys": [{ "keyId": 1, "publicKey": "base64" }]
}
```

### Critical Implementation Notes
- `POST /v1/messages` requires `Idempotency-Key` header (UUID) and `Content-Type: application/x-protobuf`
- Device takeover: if `POST /v1/devices/keys` includes a different `identityKey`, server replaces all keys and disconnects existing sessions
- Backup uses optimistic locking: `If-None-Match: *` for initial upload, `If-Match: <etag>` for updates
- Signal keys: 33-byte public (0x05 prefix + 32 bytes), 32-byte private, 64-byte XEdDSA signatures

## Build & Test

```bash
./dev.sh build
./dev.sh test
./dev.sh test --filter CoreFlowTests
```

Native builds on macOS 13+. No Docker. `dev.sh` sets the Swift 6.1 toolchain and `LIBRARY_PATH` for libsignal FFI.

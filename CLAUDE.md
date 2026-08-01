# Claude Code Context

## ⚠️ Read this before changing anything

**The reset has landed. Do not re-add what it removed.**

Read [`obscura-proto/SPEC.md` §0 — The kit boundary](../obscura-proto/SPEC.md),
[`obscura-proto/PLAN.md`](../obscura-proto/PLAN.md) (order of operations + current phase status) and
[`obscura-proto/RESET.md`](../obscura-proto/RESET.md) **first**. They are the brief.

**Where this kit is (2026-07-31): Phase 3 — the reset — has landed. Phase 2 before it.**
The ORM, CRDT engine, query DSL, audience-routing engine, schema parser and TTL manager are
deleted (`KIT_API.md` §10 step 4 — §10 is in `KIT_API.md`; `RESET.md` has no numbered sections).
What replaced them: `client.send(to:modelKey:entryId:op:sentAt:payload:)`
for the outbox, `client.inbox` (peek/consume/discard/depth) for the receive path, and
`client.entries` for storage. Merge and audience resolution live in obscura-pix now, once.
`ObscuraSchema` grew a real `v2` migration and the erase-on-schema-change tripwire is OFF —
**never edit an applied migration; add a new one.**

**Phase 2 is LANDED and PROVEN on `main`.** Phases 1 and 2 shipped
across the proto, the server and both kits between 07-19 and 07-25. This kit's share — the
throwing-persist residual, device-UUID session addressing, the F9 own-device registry, honest
`authorDeviceId`, and the Option B envelope — merged via PRs #6, #8 and #9.

It is **verified, not asserted**: macOS CI run `30138464166` executed
`TwoDeviceSendTests` (two-device decrypt after a *sender reconnect*, the own-device registry, the
link-approval approver half) and `AuthorDeviceIdTests` against a real server, and they passed. The
UNVERIFIED labels on the original commits are historical — CI has since compiled and run them.
`obscura-proto/PLAN.md` records the acceptance sign-off and four known gaps.

The rule that governs this repo:

> **If the kit reads it, it is a field in `client.proto`.
> If it is not in `client.proto`, the kit MUST NOT read it.**

**Do not re-add an ORM, a CRDT layer, a query builder, an audience/routing engine, or a schema
parser.** They existed here *and* in ObscuraKit-Kotlin, duplicated, to serve five flat models in one
app that used almost none of them. `KIT_API.md` §9 names the failure mode to watch for: the entry
store grows a filter, then an index abstraction, then observation, and the deleted engine has been
rebuilt under a new name.

Known live defects in this kit, documented so nobody rediscovers them as "improvements":

- **This kit sends `DEVICE_LINK_APPROVAL` but cannot receive one.** `routeMessage` has no
  `case .deviceLinkApproval`, so a newly-linked device silently discards everything the approval
  carries: the p2p keypair, the recovery public key, the friends export, and the approver's
  own-device list. Its registry ends up containing only itself, which means `announceDevices()` from
  that device can only ever tell a friend about one device.
  **How it is discarded has changed, and the difference matters when debugging:** it no longer
  "falls through `default: break`". It is classified `.unimplemented` in `Stores/PayloadClass.swift`,
  so it is **logged loudly, dropped, and acked** (`RECV UNIMPLEMENTED arm=DEVICE_LINK_APPROVAL`) —
  it never reaches `routeMessage`'s `default:`, which now throws. Dropping-and-acking is deliberate:
  throwing on a LIVE flow would leave an envelope that is never acked, redelivering on every
  reconnect into a server queue that caps at 1000 per device and evicts oldest-first.
  ObscuraKit-Kotlin routes this to `handleLinkApproval` (`setOwnDevices(approvedDevices)` + stores
  identity keys), so the two kits genuinely diverge on device linking. Found 2026-07-24 while
  gathering Phase 2 acceptance evidence: CI showed `getOwnDevices()=1` where Kotlin's equivalent
  fixture shows 2. The *approver* half works and is pinned by
  `TwoDeviceSendTests.testLinkApprovalPopulatesTheApproverRegistry`; the approvee half is
  deliberately not asserted, because asserting broken behaviour locks it in.
- **No device-announce replay protection.** A DEVICE_ANNOUNCE is now verified against the peer's
  recovery public key, pinned trust-on-first-use — but a *replay* of a previously valid, correctly
  signed announce still verifies, because nothing tracks which timestamps have been seen. The LWW
  guard (`devices_updated_at < ?`) rejects a stale replay by accident, not by design.
- **`FRIEND_SYNC` is deleted from this kit, both halves.** A second device therefore no longer
  learns about friends added *after* it was linked; it still receives the whole graph at link time
  in `DEVICE_LINK_APPROVAL`'s `friends_export`. The arm is classified `.unimplemented` rather than
  removed from the classification table, so an inbound one from Kotlin is dropped and acked instead
  of wedging the queue. It went because `FriendSync` carries no `user_id`, so the receiver keyed the
  friend it created on `sourceUserId` — which its own self-guard had just proven is *our* userId,
  adding the user to their own friends list and hence to every fan-out.
- **There is no remote device revocation.** `revokeDevice` was deleted: it signed a filtered device
  list and its own timestamp, then called `announceDevices()`, which rebuilt the payload from the
  unfiltered registry and stamped a fresh timestamp, so no recipient could ever verify it. Zero
  callers, zero tests. Revoking means `api.deleteDevice` from a device you still hold.
- **`ObscuraError.invalidSchema` / `.directRoutingUnresolved` are deleted here and must be deleted
  in ObscuraKit-Kotlin and `obscura-pix/src/native/ObscuraModule.ts` too** — they are dead in both
  kits and exposed to JS through the shared bridge error union.
- `ProcessedCounts` still hard-codes `"pix"` and `"directMessage"` in kit source
  (`classifyForPushCounts`), which §0.4 forbids. ObscuraKit-Kotlin has the identical defect. The fix
  changes a bridge-facing type on both platforms and is deliberately a separate change.
- `sendModelSync(to:model:entryId:op:data:)` still gates on friendship and sends to exactly one
  friend. Prefer `send(to:...)`. Its Kotlin twin survives too; both are follow-ups.
- **`send(to:_ text:)` — the legacy TEXT send — still exists here, and ObscuraKit-Kotlin deleted its
  equivalent in the same PR that removed the ORM.** Not observable through the bridge (pix sends
  entries only), so it is a source-level divergence rather than a behavioural one, but it is a
  divergence and it belongs on this list rather than in someone's memory.
- ~~`SyncManager` hard-codes application field names~~ / ~~narrows a `.friends` broadcast~~ /
  ~~`RoutingConformanceTests` re-implements the audience mapping~~ — **all deleted with the routing
  engine (Phase 3).** Audience resolution is the app's, and `obscura-pix` vendors the routing
  guards.
- ~~No schema migration mechanism exists~~ — **FIXED.** `Storage/ObscuraSchema.swift` owns every
  table via `DatabaseMigrator`; `v2` is the first migration that carries data across.
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
- ~~**MODEL_SYNC is acked before it is durably persisted**~~ — **RESOLVED BY CONSTRUCTION (Phase 3).**
  The five `try? await db.write` sites that swallowed the error were inside `ModelStore.swift`, which
  no longer exists. A MODEL_SYNC now takes exactly one durable write — `inbox.put`, which `throws` —
  and `routeMessage` propagates it, so a failed write skips the ack and the server redelivers
  (`SPEC.md` §0.9 rule 3). This was accepted knowingly for the duration of §10 steps 1–3 rather than
  hardening deletion-bound code (§0.8); the decision and its cost are in
  [`obscura-proto/PLAN.md`](../obscura-proto/PLAN.md), Phase 1 status block (2026-07-24).

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

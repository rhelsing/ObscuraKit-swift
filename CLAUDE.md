# Claude Code Context

@README.md
@docs/PITFALLS.md
@docs/MESSAGE_FLOW.md
@docs/AGENT_NOTES.md

## Project Overview

ObscuraKit — Swift package for the Obscura encrypted messaging data layer. Actors architecture, no views. The public API is what both SwiftUI views and XCTests call.

## Server

- **API:** https://obscura.barrelmaker.dev
- **OpenAPI Spec:** https://obscura.barrelmaker.dev/openapi.yaml
- **Server Repo:** https://github.com/barrelmaker97/obscura-server

All smoke/scenario tests run against the live server.

## Web Client (reference implementation)

The JS web client at `../obscura-client-web` is the reference for porting. Key source files:

### Proto
- `public/proto/obscura/v1/obscura.proto` — Server transport (WebSocketFrame, Envelope, SendMessageRequest)
- `public/proto/v2/client.proto` — Client payload (EncryptedMessage, ClientMessage, ModelSync)

### ORM
- `src/v2/orm/crdt/GSet.js` — Grow-only set
- `src/v2/orm/crdt/LWWMap.js` — Last-writer-wins map
- `src/v2/orm/Model.js` — Base model class
- `src/v2/orm/storage/ModelStore.js` — IndexedDB persistence
- `src/v2/orm/sync/SyncManager.js` — Broadcast targeting
- `src/v2/orm/sync/TTLManager.js` — Ephemeral content expiry
- `src/v2/orm/QueryBuilder.js` — Query filtering
- `src/v2/orm/index.js` — Schema wiring

### Stores & Managers
- `src/v2/store/friendStore.js` — Friend persistence (IndexedDB)
- `src/v2/store/messageStore.js` — Message persistence
- `src/v2/store/deviceStore.js` — Device identity + linked devices
- `src/lib/IndexedDBStore.js` — Signal protocol key store (15-method interface)
- `src/lib/messenger.js` — Encrypt/decrypt/queue/flush
- `src/lib/ObscuraClient.js` — Facade

### API & Network
- `src/api/client.js` — HTTP API client
- `src/api/gateway.js` — WebSocket connection

### Tests
- `test/helpers/testClient.js` — E2E test client
- `test/browser/scenario-*.spec.js` — Playwright scenario tests (1-10)
- `test/smoke/` — Standalone smoke tests

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
swift build
swift test
```

No Xcode required. Everything runs via SPM from the command line.

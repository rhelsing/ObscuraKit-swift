# ObscuraKit

Swift package for the Obscura encrypted messaging data layer. No views — just protocol, crypto, ORM, and networking. Fully smoke-testable from the command line.

## Prerequisites

- Swift 5.7+ (no Xcode required — uses SPM)
- `protoc` + `protoc-gen-swift` for proto generation

## Build & Test

```bash
swift build
swift test
```

## Server

- **API:** https://obscura.barrelmaker.dev
- **OpenAPI Spec:** https://obscura.barrelmaker.dev/openapi.yaml

## Architecture

Swift Actors for thread-safe concurrency. Three layers:

1. **Proto** — Server transport (`obscura.proto`) + client payload (`client.proto`)
2. **ORM** — CRDTs (GSet, LWWMap), Model, ModelStore, SyncManager, TTL
3. **Actors** — FriendActor, MessageActor, DeviceActor, MessengerActor, SchemaActor

Public API via `ObscuraClient` facade — same interface used by SwiftUI views and XCTests.

## Server API Endpoints

### Auth
| Method | Path | Auth | Format |
|--------|------|------|--------|
| `POST` | `/v1/users` | None | JSON |
| `POST` | `/v1/sessions` | None | JSON |
| `POST` | `/v1/sessions/refresh` | None | JSON |
| `DELETE` | `/v1/sessions` | Bearer | — |

### Devices
| Method | Path | Auth | Format |
|--------|------|------|--------|
| `POST` | `/v1/devices` | Bearer | JSON |
| `GET` | `/v1/devices` | Bearer | JSON |
| `GET` | `/v1/devices/{deviceId}` | Bearer | JSON |
| `PUT` | `/v1/devices/{deviceId}` | Bearer | JSON |
| `DELETE` | `/v1/devices/{deviceId}` | Bearer | JSON |

### Keys
| Method | Path | Auth | Format |
|--------|------|------|--------|
| `POST` | `/v1/devices/keys` | Device-Scoped | JSON |
| `GET` | `/v1/users/{userId}` | Device-Scoped | JSON |

### Messaging
| Method | Path | Auth | Format |
|--------|------|------|--------|
| `POST` | `/v1/messages` | Device-Scoped | Protobuf (`Idempotency-Key` header required) |

### Gateway (WebSocket)
| Method | Path | Auth | Format |
|--------|------|------|--------|
| `POST` | `/v1/gateway/ticket` | Device-Scoped | JSON |
| `GET` | `/v1/gateway` | Ticket (query param) | Protobuf frames |

### Attachments
| Method | Path | Auth | Format |
|--------|------|------|--------|
| `POST` | `/v1/attachments` | Bearer | Binary |
| `GET` | `/v1/attachments/{id}` | Bearer | Binary (ETag caching) |

### Backups
| Method | Path | Auth | Format |
|--------|------|------|--------|
| `GET` | `/v1/backup` | Bearer | Binary |
| `HEAD` | `/v1/backup` | Bearer | — |
| `POST` | `/v1/backup` | Bearer | Binary (optimistic locking via ETag) |

### Push
| Method | Path | Auth | Format |
|--------|------|------|--------|
| `PUT` | `/v1/push-tokens` | Device-Scoped | JSON |

## Auth Model

- **User-Scoped JWT:** Returned from registration/login. Used for device provisioning.
- **Device-Scoped JWT:** Includes `deviceId` claim. Required for messaging, keys, gateway.
- **Refresh Token:** Long-lived, rotation invalidates old tokens immediately.
- **WebSocket Tickets:** Single-use, obtained via `/v1/gateway/ticket`.

## Related Repos

- **Server:** https://github.com/barrelmaker97/obscura-server
- **Proto:** https://github.com/barrelmaker97/obscura-proto
- **Web Client:** https://github.com/ryanhelsing/obscura-client-web

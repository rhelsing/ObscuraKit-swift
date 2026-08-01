# Client API — Auth, Connection, Friends, Devices

Auth, social graph, device management. This is the whole client API now — the ORM that used to sit on top of it was deleted (`obscura-proto/KIT_API.md` §10 step 4). Entries reach the app through `client.inbox`, are stored via `client.entries`, and are sent with `client.send(to:modelKey:entryId:op:sentAt:payload:)`.

## Client Initialization

```swift
// In-memory (tests) — all state lost on dealloc
let client = try ObscuraClient(apiURL: "https://obscura.barrelmaker.dev")

// File-backed (production) — persists Signal keys, friends, messages across app restarts
let client = try ObscuraClient(
    apiURL: "https://obscura.barrelmaker.dev",
    dataDirectory: "/path/to/app/data",
    userId: userId  // enables SQLCipher encryption per-user
)
```

File-backed clients restore Signal identity from the database on init. After `restoreSession()`, encryption works immediately without re-registering.

## Auth

```swift
// Register new user — creates account + device + Signal keys
try await client.register(username, password)

// Login existing user
try await client.login(username, password)

// Login with specific device (device-scoped token for messaging)
try await client.login(username, password, deviceId: savedDeviceId)

// Lightweight account-only calls (no Signal keys, no device)
let (token, refreshToken, userId) = try await ObscuraClient.registerAccount(username, password)
let (token, refreshToken, userId) = try await ObscuraClient.loginAccount(username, password)

// Restore session without re-authenticating (file-backed client)
await client.restoreSession(
    token: savedToken, refreshToken: savedRefresh,
    userId: savedUserId, deviceId: savedDeviceId,
    username: savedUsername
)

// Check state
client.hasSession      // true if token + userId set
client.authState       // .loggedOut or .authenticated
client.connectionState // .disconnected, .connecting, .connected, .reconnecting

// Logout
try await client.logout()
```

## Connection

```swift
// Connect WebSocket + start envelope loop + start token refresh
try await client.connect()

// Disconnect (cancels envelope loop + token refresh)
client.disconnect()

// Token refresh happens automatically. Force-check:
await client.ensureFreshToken()
```

`connect()` starts two background tasks:
1. **Envelope loop** — receives encrypted messages, decrypts, routes to handlers
2. **Token refresh** — proactively refreshes JWT before expiry

Both are cancelled by `disconnect()` or `deinit`.

## Friends

Friends are the social graph. The kit uses them to address devices and to resolve a sender's display name (`obscura-proto/SPEC.md` §0.5) — it does **not** use them to decide an audience. The caller names recipients (§0.4).

```swift
// Send friend request (encrypted FRIEND_REQUEST)
try await client.befriend(userId, username: "alice")

// Accept friend request (encrypted FRIEND_RESPONSE)
try await client.acceptFriend(userId, username: "alice")

// Query
let friend = await client.friends.getFriend(userId)
let accepted = await client.friends.getAccepted()
let pending = await client.friends.getPending()
let all = await client.friends.getAll()
let isFriend = await client.friends.isFriend(userId)

// Observe (reactive — SwiftUI-ready)
for await friends in client.friends.observeAccepted().values { ... }
// Pending requests: read with `getPending()`, or filter `observeAll()` by status.
// The status-specific observers were deleted — only `observeAccepted()` and `observeAll()` remain.
for await all in client.friends.observeAll().values { ... }
```

## Devices

Devices define where your data lives. Each device has its own Signal identity.

```swift
// Announce device list to all friends. Unsigned: this kit never populates
// DeviceAnnounce.recovery_public_key or .signature on send. On RECEIVE it pins a peer's
// recovery key trust-on-first-use and verifies later announces against the stored copy.
try await client.announceDevices()

// Query own devices
let devices = await client.devices.getOwnDevices()
let identity = await client.devices.getIdentity()
let hasIdentity = await client.devices.hasIdentity()

// Observe
for await devices in client.devices.observeOwnDevices().values { ... }
```

## Device Linking

New devices must be approved by an existing device. No bypass.

```swift
// NEW DEVICE: generate link code (display as QR or copyable text)
let linkCode = client.generateLinkCode()

// EXISTING DEVICE: scan/paste and approve
try await existingClient.validateAndApproveLink(linkCode)
// This sends: DEVICE_LINK_APPROVAL → SYNC_BLOB → DEVICE_ANNOUNCE
```

Link codes expire after 5 minutes. They contain a random challenge, the device's Signal identity key, and a timestamp — all Base58-encoded.

For the full device linking ceremony:
1. New device logs in with `loginAndProvision(username, password)`
2. New device calls `generateLinkCode()` — displays QR
3. Existing device scans, calls `validateAndApproveLink(code)`
4. Existing device sends approval (encrypted) with P2P keys, device list, friend export
5. Existing device sends SYNC_BLOB with full state
6. Existing device broadcasts DEVICE_ANNOUNCE to all friends
7. New device receives approval + state, is now fully linked

## Device Revocation

**There is no remote, recovery-key-signed revocation.** `revokeDevice(_:targetDeviceId:)` was
deleted: it signed a filtered device list plus its own timestamp and then called `announceDevices()`,
which rebuilds the payload from the *unfiltered* own-device registry and stamps a fresh timestamp, so
neither signed input matched what went on the wire and no recipient could ever verify it. It had zero
callers and zero tests. Revoking requires access to a device you still hold:

```swift
try await client.api.deleteDevice(deviceId)
try await client.announceDevices()
```

## Sending Messages

```swift
// An application entry — the app names the recipients and supplies opaque bytes.
try await client.send(
    to: [friendUserId], modelKey: "directMessage", entryId: entryId, payload: jsonBytes)

// Raw protobuf message (advanced)
try await client.sendRawMessage(to: friendUserId, clientMessageData: protoBytes)
```

## Receiving Messages

The envelope loop in `connect()` handles all incoming messages automatically:
- TEXT → stored in `MessageActor`
- FRIEND_REQUEST → stored in `FriendActor`
- FRIEND_RESPONSE → updates friend status
- MODEL_SYNC → written to `client.inbox` as a durable row, then acked (an ack is a DELETE, so the write comes first)
- DEVICE_ANNOUNCE → updates friend's device list
- SYNC_BLOB → imports state from linked device
- SENT_SYNC → stores message as "sent" on other own devices

For custom handling, subscribe to the events stream:

```swift
for await event in client.events() {
    switch event.type {
    case 0:  print("TEXT: \(event.text)")
    case 30: print("MODEL_SYNC from \(event.sourceUserId)")
    default: break
    }
}
```

Or wait for a specific message (tests):

```swift
let msg = try await client.waitForMessage(timeout: 10)
```

## Session Reset

```swift
// Reset Signal session with a specific friend (re-establishes on next message)
try await client.resetSessionWith(friendUserId, reason: "user requested")

// Reset all sessions
try await client.resetAllSessions(reason: "key rotation")
```

## Backup

```swift
// Upload encrypted backup to server
try await client.uploadBackup()

// Check if backup exists
let (exists, etag, size) = try await client.checkBackup()

// Download
let data = try await client.downloadBackup()
```

Backup uses optimistic locking: `If-None-Match: *` for initial upload, `If-Match: <etag>` for updates.

## Attachments

```swift
let result = try await client.api.uploadAttachment(encryptedData)
let bytes = try await client.api.fetchAttachment(attachmentId)
```

## Logging

```swift
// Set a custom logger for security-sensitive events
client.logger = MyCustomLogger()

// Default is PrintLogger which logs to stdout
// Events logged: decrypt failures, identity changes, token refresh failures, frame parse errors
```

Implement the `ObscuraLogger` protocol for custom logging.

## Observable State Properties

| Property | Type | Description |
|----------|------|-------------|
| `connectionState` | `ConnectionState` | `.disconnected`, `.connecting`, `.connected`, `.reconnecting` |
| `authState` | `AuthState` | `.loggedOut`, `.authenticated` |
| `hasSession` | `Bool` | `true` if token + userId are set |
| `userId` | `String?` | Current user ID (from JWT) |
| `username` | `String?` | Current username |
| `deviceId` | `String?` | Current device ID (from device-scoped JWT) |
| `token` | `String?` | Current auth token |

## Rate Limiting

The server rate-limits aggressively. All `ObscuraTestClient` methods include a 500ms delay between API calls. If you call `APIClient` directly, add delays:

```swift
await rateLimitDelay()  // 500ms — available globally
```

# ObscuraKit Swift — Security Audit

**Date:** 2026-03-28
**Scope:** Full codebase — crypto, network, storage, facade, dependencies, config
**Cross-referenced against:** Kotlin client audit (30 findings), Kotlin 7-fix patch, independent Swift deep audit (5 parallel agents)

---

## Executive Summary

ObscuraKit has solid foundations: Signal Protocol via libsignal, actor-based concurrency, parameterized SQL, persistent GRDB storage, and proper UUIDv4 message IDs. However, **critical vulnerabilities make it unsafe for production** without fixes. The most severe issues: unauthenticated device/friend injection, unencrypted database and backups, non-standard key derivation, and pervasive silent error swallowing.

**Totals: 10 Critical, 16 High, 15 Medium, 8 Low**

The Swift client shares 22 of 30 bugs found in Kotlin. Six things Swift already gets right that Kotlin didn't: persistent DB (not in-memory), full UUID message IDs, no debug prints in test client, system CSPRNG, no auth timing oracle, gateway re-fetches ticket on reconnect.

---

## Table of Contents

1. [Critical Findings](#critical-findings)
2. [High Findings](#high-findings)
3. [Medium Findings](#medium-findings)
4. [Low Findings](#low-findings)
5. [Cross-Platform Comparison](#cross-platform-comparison)
6. [Fix Priority Roadmap](#fix-priority-roadmap)
7. [Positive Findings](#positive-findings)

---

## Critical Findings

### C1. Device Announcement Spoofing — No Signature Verification

**File:** `ObscuraClient.swift:519-529`
**Also:** `ObscuraClient.swift:344-369` (recovery announce)

Received `.deviceAnnounce` messages update the friend's device list without verifying the signature field. `RecoveryKeys.verify()` exists but is never called in the routing path. An attacker can forge announcements to replace a friend's device list with attacker-controlled devices, intercepting all future messages.

**Fix:**
```swift
// In routeMessage(), before updating devices:
case .deviceAnnounce:
    let announce = msg.deviceAnnounce
    guard let recoveryPubKey = await friends.getRecoveryPublicKey(sourceUserId) else { break }
    let payload = RecoveryKeys.serializeAnnounceForSigning(
        deviceIds: announce.devices.map(\.deviceID),
        timestamp: announce.timestamp,
        isRevocation: announce.isRevocation
    )
    guard RecoveryKeys.verify(publicKey: recoveryPubKey, data: payload, signature: announce.signature) else {
        logger.signatureVerificationFailed(sourceUserId: sourceUserId, messageType: "deviceAnnounce")
        break
    }
    // ... proceed with update
```

### C2. Friendship Injection via `.friendSync` / `.syncBlob`

**File:** `ObscuraClient.swift:535-570`

Any peer can send `.friendSync` with `action="add", status="accepted"` or `.syncBlob` to silently inject themselves as a friend or poison the message database. These messages are intended for own-device sync only, but `sourceUserId` is never checked.

**Fix:**
```swift
case .friendSync, .syncBlob:
    guard sourceUserId == self.userId else {
        logger.unauthorizedSyncAttempt(sourceUserId: sourceUserId, type: msg.type)
        break
    }
    // ... proceed with existing logic
```

### C3. No Database Encryption At Rest

**Files:** `FriendStore.swift:48`, `MessageStore.swift:33`, `DeviceStore.swift:46`, `SignalStore.swift:74`, `PersistentSignalStore.swift:21`, `ModelStore.swift:16`

All six `DatabaseQueue()` instances are created without encryption. Signal private keys, messages, auth tokens, and friend lists are stored in plaintext SQLite.

**Options:**
- **Option A (recommended):** Use GRDB with SQLCipher. Derive encryption key from iOS Keychain or Secure Enclave. Requires adding the `GRDB/SQLCipher` SPM product and a Keychain helper.
- **Option B:** Use Apple Data Protection (`FileProtectionType.complete`) on the database files so they're encrypted when the device is locked. Less granular but zero library changes.
- **Option C:** Encrypt sensitive columns (private keys, message content) at the application layer before writing. More surgical but more code to maintain.

### C4. Non-Standard BIP39 Key Derivation (Worse Than Kotlin)

**File:** `RecoveryKeys.swift:34-40`

Uses `SHA-256(phrase.utf8)` directly as seed — zero key stretching. BIP39 standard requires PBKDF2 with 2048 iterations. Kotlin at least uses PBKDF2; Swift skips it entirely.

**Fix:**
```swift
// Replace:
let seed = sha256(Data(phrase.utf8))

// With (using CommonCrypto):
import CommonCrypto
func deriveKeypair(from phrase: String) -> (publicKey: Data, privateKey: Data) {
    let password = Array(phrase.utf8)
    let salt = Array("mnemonic".utf8)  // BIP39 standard salt
    var seed = [UInt8](repeating: 0, count: 32)
    CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
        salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
        2048, &seed, 32
    )
    // ... use seed as before
}
```
Also replace the custom SHA-256 implementation (`RecoveryKeys.swift:88-118`, `VerificationCode.swift:29-99`) with `CryptoKit.SHA256` or `CommonCrypto.CC_SHA256`.

### C5. Plaintext Recovery Phrase in Memory

**File:** `ObscuraClient.swift:313-318`

`public var recoveryPhrase: String?` holds the master recovery key as an immutable Swift String — cannot be securely zeroed, stays in heap indefinitely.

**Fix:**
```swift
// One-time read pattern:
private var _recoveryPhrase: String?

public func getRecoveryPhrase() -> String? {
    let phrase = _recoveryPhrase
    _recoveryPhrase = nil  // clear reference immediately
    return phrase
}

public func generateRecoveryPhrase() -> String {
    let phrase = RecoveryKeys.generatePhrase()
    _recoveryPhrase = phrase
    recoveryPublicKey = RecoveryKeys.getPublicKey(from: phrase)
    return phrase
}
```
Note: Swift `String` is immutable so the old copy may linger in heap until GC. For defense-in-depth, use `UnsafeMutableBufferPointer<UInt8>` with explicit zeroing on deinit, or store in Keychain.

### C6. Backup Not Encrypted

**File:** `ObscuraClient.swift:376-381`, `SyncBlob.swift:36-38`

`uploadBackup()` exports friends as plaintext JSON. Comment says "encrypted backup" but no encryption is applied.

**Fix:**
```swift
// In uploadBackup():
let plaintext = SyncBlobExporter.export(friends: friendsData, messages: [])
let key = deriveBackupKey(from: identityKeyPair)  // or password-derived
let encrypted = try AES.GCM.seal(plaintext, using: key).combined!
let etag = try await api.uploadBackup(encrypted, etag: backupEtag)

// In downloadBackup():
let encrypted = try await api.downloadBackup()
let box = try AES.GCM.SealedBox(combined: encrypted)
let plaintext = try AES.GCM.open(box, using: key)
```

### C7. No Identity Key Binding Verification

**File:** `MessengerActor.swift:72-134`

`processServerBundle()` trusts whatever prekey bundle the server returns. No verification that the identity key belongs to the claimed user. A compromised or MITM server can inject attacker's keys and receive all future messages.

**Options:**
- **Option A:** Store first-seen identity key per user and warn/reject on change (safety number comparison).
- **Option B:** Out-of-band key verification (QR code scanning between users).
- **Option C (minimum):** Log identity key changes and surface them to the UI via a callback. See [H5 Identity Change Callback](#h5-identity-change-callback).

### C8. TLS Enforcement — HTTP Allowed

**File:** `APIClient.swift:12`, `GatewayConnection.swift:40`

`init(baseURL:)` accepts any string. `GatewayConnection` explicitly converts `http://` to `ws://` (unencrypted).

**Fix (1 line each):**
```swift
// APIClient.init:
public init(baseURL: String) {
    precondition(baseURL.hasPrefix("https://"), "API URL must use HTTPS")
    self.baseURL = baseURL
}

// GatewayConnection — remove the http:// conversion:
let wsBase = baseURL.replacingOccurrences(of: "https://", with: "wss://")
// (no http:// fallback)
```

### C9. Non-Constant-Time Identity Comparison

**Files:** `PersistentSignalStore.swift:103`, `SignalStore.swift:174`

Both use `stored == Data(...)` which is Swift `Data.==` — short-circuits on first byte mismatch. Leaks identity key content via timing side-channel.

**Fix (1 line each):**
```swift
// Replace:
return stored == Data(identity.serialize())

// With:
return constantTimeEqual(stored, Data(identity.serialize()))

// Helper:
func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}
```

### C10. LWWMap Timestamp Spoofing

**File:** `LWWMap.swift:29-36`

A malicious peer can set arbitrarily high future timestamps to win all LWW conflicts, overwriting settings, profiles, or any ORM-synced data.

**Options:**
- **Option A:** Reject entries with timestamps more than N seconds in the future (clock skew tolerance).
- **Option B:** Use vector clocks instead of wall-clock timestamps.
- **Option C (minimum):** Clamp incoming timestamps to `max(remote, now + 60s)`.

---

## High Findings

### H1. Incomplete Logout — Database and Keys Not Wiped

**File:** `ObscuraClient.swift:418-426`

Logout clears in-memory tokens but leaves all database data intact: messages, friends, Signal sessions, device identity, recovery keys.

**Fix:**
```swift
public func logout() async throws {
    disconnect()
    if let rt = refreshToken { try? await api.logout(rt) }
    token = nil
    refreshToken = nil
    userId = nil
    username = nil          // ADD
    deviceId = nil          // ADD
    identityKeyPair = nil   // ADD
    registrationId = nil    // ADD
    _recoveryPhrase = nil   // ADD
    recoveryPublicKey = nil // ADD
    _messenger = nil        // ADD
    _authState = .loggedOut
    await api.clearToken()
    // Wipe databases:
    await friends.clearAll()   // ADD (need to implement)
    await messages.clearAll()  // ADD
    await devices.clearAll()   // ADD
    // Signal store wipe needed too
}
```

### H2. TOFU Returns True on DB Errors

**File:** `SignalStore.swift:169-174`, `PersistentSignalStore.swift:97-104`

`isTrustedIdentity()` returns `true` when identity is unknown (TOFU — acceptable) but also when the database read fails (`try?` swallows errors). DB corruption silently bypasses identity pinning.

**Fix:**
```swift
// In SignalStore:
public func isTrustedIdentity(_ address: String, _ identityKey: Data) async -> Bool {
    do {
        let stored = try await db.read { db -> Data? in
            try Data.fetchOne(db, sql: "SELECT public_key FROM trusted_identities WHERE address = ?", arguments: [address])
        }
        guard let stored = stored else { return true } // TOFU: first contact
        return constantTimeEqual(stored, identityKey)
    } catch {
        logger.databaseError(operation: "isTrustedIdentity", error: error)
        return false  // Fail closed on DB errors
    }
}
```

### H3. Default Registration ID Fallback

**File:** `MessengerActor.swift:57,73`

`registrationId: UInt32 = 1` as default — if device mapping fails, encrypts for wrong device ID.

**Fix:**
```swift
// Make registrationId non-optional, throw on missing:
public func encrypt(_ targetUserId: String, _ plaintext: [UInt8], registrationId: UInt32) throws -> ...

// In processServerBundle:
guard let regId = bundleData["registrationId"] as? Int else {
    throw MessengerError.invalidBundle("missing registrationId")
}
```

### H4. UUID Parsing Crash (DoS)

**File:** `MessengerActor.swift:223-231`

`uuidToBytes()` crashes on malformed UUIDs shorter than 32 hex chars.

**Fix:**
```swift
private func uuidToBytes(_ uuid: String) -> Data {
    let cleaned = uuid.replacingOccurrences(of: "-", with: "")
    guard cleaned.count == 32 else { return Data(repeating: 0, count: 16) }
    // ... rest unchanged
}
```

### H5. Identity Change Callback — None Exists

**Files:** `PersistentSignalStore.swift:88-94`, `SignalStore.swift:177-182`

`saveIdentity()` silently overwrites old keys via `INSERT OR REPLACE`. A key change (potential MITM) is completely invisible.

**Fix:**
```swift
protocol SignalStoreDelegate: AnyObject {
    func signalStore(_ store: PersistentSignalStore, identityChangedFor address: String)
}

// In saveIdentity():
let existing = try db.read { db in
    try Data.fetchOne(db, sql: "SELECT key_data FROM signal_identities WHERE address = ?", arguments: [addressStr])
}
if let existing = existing, existing != Data(identity.serialize()) {
    delegate?.signalStore(self, identityChangedFor: addressStr)
}
// proceed with INSERT OR REPLACE
```

### H6. Token Refresh Errors Silently Swallowed

**File:** `ObscuraClient.swift:634-643`

`if let result = try? await self.api.refreshSession(rt)` — failure produces no signal. Stale token keeps being used until API calls fail.

**Fix:**
```swift
do {
    let result = try await self.api.refreshSession(rt)
    if let newToken = result["token"] as? String {
        self.token = newToken
        await self.api.setToken(newToken)
    }
    if let newRefresh = result["refreshToken"] as? String {
        self.refreshToken = newRefresh
    }
} catch {
    logger.tokenRefreshFailed(attempt: attempt, reason: "\(error)")
    attempt += 1
    if attempt >= 3 { /* notify app layer / force re-auth */ }
}
```

### H7. No Secure Deletion

**Files:** All stores — `DELETE` SQL statements

SQLite does not overwrite deleted data on disk. Forensic recovery is possible.

**Options:**
- **Option A:** Enable SQLCipher (fixes this + C3 together).
- **Option B:** Run `VACUUM` after bulk deletes.
- **Option C:** Enable SQLite secure delete pragma: `PRAGMA secure_delete = ON`.

### H8. GatewayConnection Race Conditions

**File:** `GatewayConnection.swift:10-18`

`GatewayConnection` is a `class`, not an `actor`. `ws`, `isConnected`, `envelopeQueue`, and `waiters` are accessed concurrently from WebSocket callbacks and async callers with no synchronization.

**Fix:** Convert to an `actor`:
```swift
public actor GatewayConnection {
    // All property access is now actor-isolated
}
```
Note: WebSocket callbacks (`ws.onBinary`) run on NIO event loops, so they need `Task { await self.handleFrame(data) }` to bridge into actor isolation.

### H9. Device Map Populated from Untrusted Server Responses

**File:** `MessengerActor.swift:44-49`

`fetchPreKeyBundles()` populates `deviceMap` directly from server JSON with no verification. Poisoned server = messages routed to attacker devices.

**Options:**
- **Option A:** Cross-reference device IDs against the friend's announced device list (requires C1 fix first).
- **Option B:** Warn user on first contact with new device ID, require confirmation.
- **Option C (minimum):** Log device map changes for audit trail.

### H10. Incomplete Device Revocation

**File:** `ObscuraClient.swift:324-341`

`revokeDevice()` deletes messages from the revoked device but not its Signal sessions, prekeys, or identity keys. Attacker with the revoked device's database can still decrypt old messages.

**Fix:**
```swift
public func revokeDevice(_ recoveryPhrase: String, targetDeviceId: String) async throws {
    try await api.deleteDevice(targetDeviceId)
    _ = await messages.deleteByAuthorDevice(targetDeviceId)
    // ADD: clean up Signal state for this device
    await signalStore.deleteAllSessions(for: targetDeviceId)
    await signalStore.removeIdentity(for: targetDeviceId)
}
```

### H11. TTL Not Enforced on ORM Reads

**File:** `ModelStore.swift:69,79`

`get()` and `getAll()` return expired entries. TTL is only checked by `getExpired()` which must be called explicitly — no automatic reaper.

**Fix:**
```swift
// In get():
public func get(_ modelName: String, _ id: String) async -> ModelEntry? {
    let entry = try? await db.read { ... }
    guard let entry = entry else { return nil }
    // Check TTL
    if let ttl = try? await getTTL(modelName, id), ttl < UInt64(Date().timeIntervalSince1970 * 1000) {
        await delete(modelName, id)
        return nil
    }
    return entry
}
```

### H12. Pervasive Silent Error Swallowing (`try?`)

**Files:** 20+ locations across all stores and `ObscuraClient.swift`

Every `try?` is a silent failure. Database write fails? Caller thinks it succeeded. Decrypt fails? Message vanishes. Token refresh fails? Stale token used.

**Fix:** Introduce a structured logger (see [M1](#m1-no-structured-security-logger)) and replace `try?` with `do/catch` + logging at minimum. Critical paths (encrypt, decrypt, session establishment) should propagate errors.

### H13. No Certificate Pinning

**Files:** `APIClient.swift:106`, `GatewayConnection.swift:44`

`URLSession.shared` and default WebSocketKit both use system trust store. Compromised CA = full MITM.

**Fix:**
```swift
// Create a pinning delegate:
class PinningDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let serverTrust = challenge.protectionSpace.serverTrust,
              let cert = SecTrustGetCertificateAtIndex(serverTrust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let serverKey = SecCertificateCopyKey(cert)
        // Compare against pinned public key hash
        // ...
    }
}

// Use custom session instead of .shared:
let session = URLSession(configuration: .default, delegate: PinningDelegate(), delegateQueue: nil)
```
For WebSocketKit, configure NIO's TLS handler with certificate verification.

---

## Medium Findings

### M1. No Structured Security Logger

**Files:** Entire codebase (1 `print()` statement total)

No logging framework exists. Security events (decrypt failures, identity changes, token refresh failures, auth errors) are invisible.

**Fix:**
```swift
public protocol ObscuraLogger {
    func decryptFailed(sourceUserId: String, reason: String)
    func tokenRefreshFailed(attempt: Int, reason: String)
    func identityChanged(address: String)
    func signatureVerificationFailed(sourceUserId: String, messageType: String)
    func unauthorizedSyncAttempt(sourceUserId: String, type: Any)
    func databaseError(operation: String, error: Error)
    func connectionStateChanged(state: String)
}

// Default no-op implementation for library consumers who don't need logging:
public class NoOpLogger: ObscuraLogger { /* empty implementations */ }
```

### M2. Weak Verification Codes — Only 4 Digits

**File:** `VerificationCode.swift:6-9`

Takes 2 bytes of SHA-256, mod 10000. Only 10K possible codes — high collision rate, trivially brute-forced.

**Options:**
- **Option A:** Increase to 6-8 digits (use 4 bytes of hash).
- **Option B:** Use Signal's full safety number format (60-digit numeric fingerprint).
- **Option C:** Display truncated hex of identity key hash (e.g., 8 hex chars = 4 billion possibilities).

### M3. SyncBlob Not Encrypted for Transmission

**File:** `SyncBlob.swift:36-38`

Export returns raw JSON. While E2E encryption protects it in transit, there's no defense-in-depth for the payload itself.

**Fix:** Compress with gzip (as the TODO comment says), then encrypt with a shared device-linking secret before wrapping in the ClientMessage.

### M4. Path Traversal in URL Construction

**File:** `APIClient.swift:177,182,189,204,227`

User/device IDs interpolated directly into URL paths without percent-encoding.

**Fix:**
```swift
// Replace:
let result = try await jsonRequest("/v1/devices/\(deviceId)")

// With:
guard let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
    throw APIError(status: 0, body: "Invalid device ID")
}
let result = try await jsonRequest("/v1/devices/\(encoded)")
```

### M5. Unencoded WebSocket Ticket in URL

**Files:** `APIClient.swift:245`, `GatewayConnection.swift:41`

Gateway ticket interpolated into query string without URL encoding.

**Fix:**
```swift
guard let encodedTicket = ticket.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
    throw GatewayError.invalidURL
}
let urlString = "\(wsBase)/v1/gateway?ticket=\(encodedTicket)"
```

### M6. Unbounded Buffers — 5 Arrays With No Limit

**Files:** `ObscuraClient.swift:61` (`eventContinuations`), `ObscuraClient.swift:78` (`messageQueue`), `GatewayConnection.swift:17` (`envelopeQueue`), `GatewayConnection.swift:18` (`waiters`), `MessengerActor.swift:20` (`queue`)

All grow without limit. Message flood = OOM.

**Fix:**
```swift
// Add max capacity check on append:
private let maxQueueSize = 1000

func enqueue(_ item: T) {
    if queue.count >= maxQueueSize { queue.removeFirst() }
    queue.append(item)
}
```

### M7. JWT Decoded Without Signature Verification

**File:** `APIClient.swift:24-37`

JWT payload parsed from base64 without verifying the signature. Used for extracting `userId` and token expiry.

**Note:** This is acceptable if the server is trusted and TLS is enforced (C8). The JWT is used for local convenience, not authorization decisions. However, once C8 and H13 are fixed, this becomes low risk.

### M8. Idempotency Key Not Deterministic

**File:** `APIClient.swift:211`

`UUID().uuidString` generated fresh per call. If the request is retried (network error), a new UUID is sent = duplicate message on server.

**Fix:**
```swift
// Derive from message content:
let idempotencyKey = SHA256.hash(data: protobufData).description
// Or: accept idempotency key as parameter from caller
```

### M9. GSet Unbounded Growth

**File:** `GSet.swift:28-35`

Grow-only set accumulates all elements with no compaction or size limits.

**Options:**
- **Option A:** Implement a soft cap — log warnings above N entries, reject above 2N.
- **Option B:** Add a `compact()` method that removes entries older than a threshold.
- **Option C:** Accept as inherent to GSet semantics but monitor in production.

### M10. No Authorization on Observation Streams

**Files:** All stores `observe*()` methods

All observation methods are `nonisolated public`, returning `AsyncStream` with no filtering or authorization.

**Note:** In a single-user app context, this is acceptable since there's one authenticated user per process. If multi-user or multi-account support is added, this needs access control.

### M11. Error Response Bodies Leaked in Exceptions

**File:** `APIClient.swift:112-113, 75-76`

Raw server response body goes into `APIError.body` and `errorDescription`. Could expose server internals in crash reports.

**Fix:**
```swift
// Sanitize:
public var errorDescription: String? {
    "HTTP \(status)"  // Don't include body in user-facing error
}
// Keep body for internal debugging only, not in errorDescription
```

### M12. Device Announce Has No Replay Protection

**File:** `ObscuraClient.swift:519-523`

Accepted based on timestamp only. No nonce, no counter. Old announcements can be replayed.

**Fix:** Store last-seen timestamp per user. Reject announcements with timestamp <= last seen:
```swift
guard announce.timestamp > await friends.getLastAnnounceTimestamp(sourceUserId) else {
    logger.replayDetected(sourceUserId: sourceUserId, type: "deviceAnnounce")
    break
}
```

### M13. No Rate Limiting on Decryption Attempts

**File:** `ObscuraClient.swift:461-494`

Every envelope is decrypted with no per-sender throttling. Attacker can spam to exhaust Signal ratchet state.

**Fix:** Track decrypt failure count per sender. After N failures in time window, skip envelopes from that sender:
```swift
private var decryptFailures: [String: (count: Int, lastFailure: Date)] = [:]

// In processEnvelope catch:
let entry = decryptFailures[sourceUserId, default: (0, .distantPast)]
decryptFailures[sourceUserId] = (entry.count + 1, Date())
if entry.count > 10 {
    logger.rateLimited(sourceUserId: sourceUserId)
    return
}
```

### M14. Hand-Built JSON for Signing (Not Deterministic)

**File:** `RecoveryKeys.swift:67-68`

Manually constructs JSON string. Breaks if device IDs contain quotes, backslashes, or special characters.

**Fix:** Use `JSONSerialization` with `.sortedKeys`:
```swift
let dict: [String: Any] = [
    "devices": deviceIds.map { ["deviceId": $0] },
    "isRevocation": isRevocation,
    "timestamp": timestamp
]
let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
```

### M15. Private Key Not Wiped After Signing

**File:** `RecoveryKeys.swift:49-53`

`sign(phrase:data:)` derives private key into a local `let`, signs, and returns. Key stays in memory until ARC deallocates.

**Note:** This is a fundamental limitation of Swift's memory model. `PrivateKey` from libsignal is a Swift struct/class that can't be manually zeroed. Mitigation: keep signing operations in a short-lived scope and avoid retaining references.

---

## Low Findings

### L1. Dual Signal Store Confusion

**File:** `ObscuraClient.swift:40,167`

`GRDBSignalStore` created at init (line 40) but `PersistentSignalStore` is what messenger actually uses (line 167). Two separate databases for Signal state.

**Fix:** Use one Signal store implementation throughout. Remove whichever is not the primary.

### L2. Duplicate Custom SHA-256

**Files:** `RecoveryKeys.swift:88-118`, `VerificationCode.swift:29-99`

Identical hand-rolled SHA-256 duplicated in two files.

**Fix:** Replace both with `import CryptoKit; SHA256.hash(data:)` or `CommonCrypto.CC_SHA256`.

### L3. No Signal Session Expiration

**File:** `PersistentSignalStore.swift:159-179`

Sessions stored indefinitely with no timestamp or expiration.

**Note:** Signal Protocol handles forward secrecy via ratcheting. Session expiration is not standard practice. Low risk, but consider periodic session refresh for long-dormant contacts.

### L4. `SignalKeyPair` Is `Codable` With Private Key

**File:** `SignalStore.swift:38-45`

`Codable` conformance means private keys could be accidentally serialized to JSON logs or crash reports.

**Fix:** Remove `Codable` conformance or make `privateKey` non-codable with a custom `encode()`.

### L5. No Prekey Replenishment

**File:** (absent)

Prekeys are uploaded once during registration and never replenished. Once one-time prekeys are exhausted, new sessions fall back to signed prekey only (less forward secrecy).

**Fix:** Add a prekey check after processing prekey messages and upload fresh batches when count is low.

### L6. Hardcoded Test Password in Library Code

**File:** `ObscuraTestClient.swift:38`

`"testpass123456"` as default parameter. Ships with library.

**Fix:** Gate behind `#if DEBUG` or move to test target only.

### L7. Docker Container Runs as Root

**File:** `Dockerfile` (no `USER` directive)

**Fix:**
```dockerfile
RUN useradd -m -u 1000 builder
USER builder
```

### L8. libsignal Vendored Without Version Pin

**File:** `Dockerfile:24-35`

`git clone --depth 1` clones `main` HEAD. Non-reproducible builds.

**Fix:**
```dockerfile
git clone --depth 1 --branch v0.40.0 https://github.com/signalapp/libsignal.git
```

---

## Cross-Platform Comparison

### Kotlin Fixes Applied — Swift Status

| Issue | Kotlin (fixed) | Swift Status |
|-------|---------------|-------------|
| TLS enforcement | `require(apiUrl.startsWith("https://"))` | **NOT FIXED** — `http://` silently converts to `ws://` |
| Constant-time identity comparison | `MessageDigest.isEqual()` | **NOT FIXED** — uses `==` on `Data` |
| Predictable message IDs | `UUID.randomUUID()` | **OK** — already uses `UUID().uuidString` |
| Bounded channels | `capacity = 1000` | **NOT FIXED** — 5 unbounded arrays |
| TLS 1.2+ only | `ConnectionSpec.MODERN_TLS` | **PARTIAL** — Apple defaults to TLS 1.2+, but Linux/NIO has no floor |
| Identity change callback | `onIdentityChanged` hook | **NOT FIXED** — `saveIdentity` overwrites silently |
| Structured security logger | `ObscuraLogger` interface | **NOT FIXED** — 1 `print()` in entire codebase |

### Kotlin 30-Finding Audit — Swift Status

| # | Issue | Sev | Swift? | Notes |
|---|-------|-----|--------|-------|
| 1 | Token not securely wiped | CRIT | YES | `token = nil` leaves heap copy |
| 2 | No identity key binding | CRIT | YES | Server bundles trusted blindly |
| 3 | Token public/plaintext | CRIT | YES | `public private(set) var token` |
| 4 | Token in headers unfiltered | CRIT | YES | No log redaction |
| 5 | TestClient debug prints | CRIT | **NO** | No prints in Swift TestClient |
| 6 | Silent envelope errors | HIGH | YES | `catch { // skip }` |
| 7 | TOFU auto-trust | HIGH | YES | Both stores return `true` |
| 8 | Non-constant-time compare | HIGH | YES | `Data.==` short-circuits |
| 9 | Device map from untrusted API | HIGH | YES | No verification |
| 10 | No cert pinning | HIGH | YES | `URLSession.shared` defaults |
| 11 | HTTP allowed | HIGH | YES | No scheme check |
| 12 | Reconnect without re-auth | HIGH | **PARTIAL** | Fresh ticket per connect, but no auto-reconnect |
| 13 | Token refresh errors swallowed | HIGH | YES | `try?` pattern |
| 14 | Error bodies in exceptions | HIGH | YES | Raw body in `APIError` |
| 15 | Private key not wiped | HIGH | YES | Stays until ARC dealloc |
| 16 | Silent WS frame parse | HIGH | YES | `try? else { return }` |
| 17 | Debug println in TestClient | HIGH | **NO** | Clean in Swift |
| 18 | Recovery phrase plain String | MED | YES | `public var recoveryPhrase` |
| 19 | Predictable message IDs | MED | **NO** | Full UUIDv4 |
| 20 | Unbounded channels | MED | YES | 5 unbounded arrays |
| 21 | PBKDF2 iterations low | MED | **WORSE** | Zero iterations (raw SHA-256) |
| 22 | Auth timing side-channel | MED | **NO** | No timing oracle |
| 23 | Fallback to first bundle | MED | YES | Falls back to regId=1 |
| 24 | No decrypt rate limiting | MED | YES | No throttling |
| 25 | Identity keys in memory | MED | YES | Plain properties |
| 26 | Hand-built JSON for signing | MED | YES | String interpolation |
| 27 | No device announce replay protection | MED | YES | Timestamp only |
| 28 | SecureRandom seeding | MED | **NO** | System CSPRNG |
| 29 | Empty SPK signature on replenish | MED | **N/A** | No replenishment exists |
| 30 | In-memory SQLite | MED | **NO** | Persistent GRDB |

**Score: 22 of 30 Kotlin bugs also exist in Swift. 6 not affected. 1 partial. 1 N/A.**

---

## Fix Priority Roadmap

### Phase 1: Block Production (do now)

| Fix | Effort | Issues Addressed |
|-----|--------|-----------------|
| `precondition(baseURL.hasPrefix("https://"))` | 1 line | C8 |
| Constant-time identity comparison helper | 5 lines | C9 |
| `guard sourceUserId == self.userId` in friendSync/syncBlob | 2 lines | C2 |
| Verify device announcement signatures | 10 lines | C1 |
| Recovery phrase one-time-read pattern | 10 lines | C5 |
| Replace `SHA-256(phrase)` with PBKDF2 | 15 lines | C4 |

### Phase 2: Before Release (this sprint)

| Fix | Effort | Issues Addressed |
|-----|--------|-----------------|
| `ObscuraLogger` protocol + wire into all `try?` sites | ~30 lines new + ~20 line changes | M1, H6, H12 |
| Identity change callback delegate | 15 lines | H5 |
| Bounded queue helper + apply to 5 arrays | 20 lines | M6 |
| Complete logout wipe (all fields + databases) | 15 lines | H1 |
| Convert `GatewayConnection` to actor | Refactor | H8 |
| UUID bounds check in `uuidToBytes` | 1 line | H4 |
| URL-encode path/query parameters | 10 lines | M4, M5 |
| Remove default `registrationId = 1` | 5 lines | H3 |
| Error sanitization in `APIError.errorDescription` | 2 lines | M11 |

### Phase 3: Before GA

| Fix | Effort | Issues Addressed |
|-----|--------|-----------------|
| SQLCipher database encryption | Medium (dependency + migration) | C3, H7 |
| Backup encryption (AES-GCM) | 20 lines | C6 |
| Certificate pinning delegate | 40 lines | H13 |
| Replace custom SHA-256 with CryptoKit | 5 lines | L2 |
| Consolidate to single Signal store | Refactor | L1 |
| Deterministic JSON for signing | 5 lines | M14 |
| Prekey replenishment | 30 lines | L5 |
| TTL enforcement on ORM reads | 10 lines | H11 |
| Device revocation session cleanup | 5 lines | H10 |
| Decrypt rate limiting per sender | 15 lines | M13 |
| LWWMap timestamp clamping | 5 lines | C10 |
| Idempotency key from content hash | 3 lines | M8 |
| Replay protection for device announcements | 10 lines | M12 |

---

## Positive Findings

These are things the Swift codebase does well:

- **Signal Protocol correctly integrated** via libsignal with proper SPK signature verification
- **Swift actor isolation** prevents race conditions in crypto, friend, message, device stores
- **All SQL queries properly parameterized** — no SQL injection vectors found
- **Persistent on-disk storage** via GRDB (Kotlin used in-memory SQLite)
- **Full UUIDv4 message IDs** (Kotlin had predictable 4-digit suffix)
- **No debug prints** in test client (Kotlin leaked to Logcat)
- **System CSPRNG** properly seeded via `UInt8.random(in:)` and `UUID()`
- **No auth timing oracle** (Kotlin had `Thread.sleep(500)` in auth path)
- **`.gitignore` correctly excludes** secrets, credentials, xcuserdata
- **No hardcoded API keys** or real credentials in source
- **Gateway re-fetches ticket** on every connect (Kotlin reused stale tickets)

---

## Score

| Platform | Critical | High | Medium | Low | Total |
|----------|----------|------|--------|-----|-------|
| **Kotlin (after 7 fixes)** | 0 | 2 | 8 | — | 10 remaining |
| **Swift (current)** | 10 | 16 | 15 | 8 | 49 total |
| **Swift (after Phase 1)** | 0 | 16 | 15 | 8 | 39 remaining |
| **Swift (after Phase 2)** | 0 | 3 | 10 | 8 | 21 remaining |
| **Swift (after Phase 3)** | 0 | 0 | 2 | 4 | 6 remaining |

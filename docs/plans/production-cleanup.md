# Production Cleanup Plan

Kill LLM duct tape, reach Signal-grade internals. Three phases, each leaves the public API unchanged. Views written today work through all three phases.

## Phase A: Kill the Embarrassments

**Prerequisite:** macOS 13+ (for CryptoKit) OR stay on Docker with BoringSSL shim.

### A1. Replace hand-rolled SHA-256 / HMAC / PBKDF2

**Problem:** Two copy-pasted SHA-256 implementations (140 lines of raw bit manipulation), plus hand-rolled HMAC-SHA256 and PBKDF2. This is the single biggest "LLM wrote this" signal in the codebase.

**Files to change:**
- `Sources/ObscuraKit/Crypto/VerificationCode.swift` — delete `sha256()` (70 lines)
- `Sources/ObscuraKit/Crypto/RecoveryKeys.swift` — delete `recoverySHA256()`, `hmacSHA256()`, `pbkdf2()` (80 lines)
- `Sources/ObscuraKit/Network/APIClient.swift:212` — uses `recoverySHA256` for idempotency key

**Replace with (after macOS upgrade):**
```swift
import CryptoKit

// SHA-256 (replaces 140 lines)
let hash = SHA256.hash(data: data)

// HMAC-SHA256 (replaces 20 lines)
let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)

// PBKDF2 — no CryptoKit equivalent, but CommonCrypto works on macOS 13+:
import CommonCrypto
CCKeyDerivationPBKDF(kCCPBKDF2, password, passwordLen, salt, saltLen, kCCPRFHmacAlgSHA512, 2048, &seed, 32)
```

**If staying on Docker (Linux):** BoringSSL is already linked (via libsignal). Create a C shim:
```c
// Sources/CryptoShim/include/crypto_shim.h
#include <openssl/sha.h>
#include <openssl/hmac.h>
void obscura_sha256(const uint8_t *data, size_t len, uint8_t *out);
```
Then call from Swift. Either way, delete the hand-rolled implementations.

**Lines deleted:** ~140
**Lines added:** ~15
**Tests to update:** VerificationCodeTests (should produce same hashes — verify before deleting)

---

### A2. Add Codable response types for APIClient

**Problem:** 41 occurrences of `[String: Any]`, 14 untyped casts. Every API response is an untyped dictionary. No compile-time safety. Field name typos silently return nil.

**New file:** `Sources/ObscuraKit/Network/APIModels.swift`

```swift
public struct AuthResponse: Decodable {
    public let token: String
    public let refreshToken: String?
    public let expiresAt: Double?
    public let deviceId: String?
}

public struct DeviceResponse: Decodable {
    public let deviceId: String
    public let name: String
    public let createdAt: String?
}

public struct PreKeyBundleResponse: Decodable {
    public let deviceId: String
    public let registrationId: Int
    public let identityKey: String  // base64
    public let signedPreKey: SignedPreKeyData
    public let oneTimePreKey: PreKeyData?

    public struct SignedPreKeyData: Decodable {
        public let keyId: Int
        public let publicKey: String  // base64
        public let signature: String  // base64
    }

    public struct PreKeyData: Decodable {
        public let keyId: Int
        public let publicKey: String  // base64
    }
}

public struct AttachmentResponse: Decodable {
    public let id: String
    public let expiresAt: Double?
}

public struct GatewayTicketResponse: Decodable {
    public let ticket: String
}

public struct BackupCheckResponse: Decodable {
    public let exists: Bool
    public let etag: String?
    public let size: Int?
}
```

**Then change APIClient:**
```swift
// Before:
public func registerUser(_ username: String, _ password: String) async throws -> [String: Any]

// After:
public func registerUser(_ username: String, _ password: String) async throws -> AuthResponse
```

**Internal change:** Replace `JSONSerialization` with `JSONDecoder`:
```swift
private func jsonRequest<T: Decodable>(_ type: T.Type, ...) async throws -> T {
    let (data, _) = try await request(path, method: method, body: bodyData, auth: auth)
    return try JSONDecoder().decode(T.self, from: data)
}
```

**Cascade:** Every call site changes from `result["token"] as? String` to `result.token`. Compiler catches every one.

**Files to change:**
- `Sources/ObscuraKit/Network/APIClient.swift` — new return types, generic decoder
- `Sources/ObscuraKit/Network/APIModels.swift` — new file
- `Sources/ObscuraKit/ObscuraClient.swift` — update register/login/provision to use typed responses
- `Sources/ObscuraKit/Crypto/MessengerActor.swift` — `processServerBundle` takes `PreKeyBundleResponse` not `[String: Any]`
- `Sources/ObscuraKit/ObscuraTestClient.swift` — minor updates

**Lines deleted:** ~80 (all `as? String`, `as? Int`, manual JSON parsing)
**Lines added:** ~100 (model structs + generic decoder)

---

### A3. Extract UUID helpers

**Problem:** `uuidToBytes()` in MessengerActor, `bytesToUuid()` in ObscuraClient. Same conversion, duplicated.

**New file:** `Sources/ObscuraKit/Crypto/UUIDHelpers.swift`

```swift
import Foundation

extension UUID {
    var data: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    init?(data: Data) {
        guard data.count == 16 else { return nil }
        let tuple = data.withUnsafeBytes { $0.load(as: uuid_t.self) }
        self.init(uuid: tuple)
    }
}

extension Data {
    var uuidString: String {
        guard count == 16 else { return map { String(format: "%02x", $0) }.joined() }
        return UUID(data: self)?.uuidString.lowercased() ?? ""
    }
}
```

Delete the two inline implementations. Use `UUID().data` and `rawData.uuidString` everywhere.

**Lines deleted:** ~25
**Lines added:** ~20

---

## Phase B: Proper Refactor

**Prerequisite:** Phase A complete, macOS upgraded, native `swift test` working.

### B1. Split ObscuraClient god object

**Current:** 792 lines, 29 methods, handles everything.

**Target structure:**
```
Sources/ObscuraKit/
├── ObscuraClient.swift              ~150 lines  — init, public API, coordinates managers
├── Managers/
│   ├── EnvelopeProcessor.swift      ~150 lines  — decrypt, routeMessage, ACK
│   ├── SyncManager.swift            ~100 lines  — SENT_SYNC, FRIEND_SYNC, SYNC_BLOB import
│   ├── AuthManager.swift            ~100 lines  — register, login, logout, token refresh
│   └── RecoveryManager.swift        ~80  lines  — phrase, revoke, announce, backup
```

**Rule:** Each manager gets injected dependencies (actors, API, messenger). No manager references another manager directly — ObscuraClient coordinates.

**ObscuraClient becomes:**
```swift
public class ObscuraClient {
    public let friends: FriendActor
    public let messages: MessageActor
    public let devices: DeviceActor
    public let gateway: GatewayConnection

    private let auth: AuthManager
    private let envelopeProcessor: EnvelopeProcessor
    private let sync: SyncManager
    private let recovery: RecoveryManager

    public func register(_ username: String, _ password: String) async throws {
        try await auth.register(username, password)
    }

    public func send(to userId: String, _ text: String) async throws {
        try await auth.requireAuthenticated()
        try await sync.sendText(to: userId, text)
    }

    public func connect() async throws {
        try await gateway.connect()
        envelopeProcessor.start()
        auth.startTokenRefresh()
    }
}
```

### B2. Replace `try?` with proper error propagation

**Current:** 74 swallowed errors.

**Pattern to follow:**
```swift
// Before (duct tape):
try? await db.write { db in
    try db.execute(sql: "INSERT ...", arguments: [...])
}

// After (production):
do {
    try await db.write { db in
        try db.execute(sql: "INSERT ...", arguments: [...])
    }
} catch {
    logger.databaseWriteFailed(table: "friends", error: error)
    throw ObscuraError.databaseFailure(error)
}
```

**Where `try?` is acceptable:** Cleanup code in deinit/disconnect, optional cache writes, non-critical logging. Maybe 10 of the 74.

### B3. Wrap proto types in domain types

**Current:** Business logic builds `Obscura_V2_ClientMessage` directly.

**Target:**
```swift
// Domain types (what business logic uses)
struct OutgoingTextMessage {
    let recipient: String
    let text: String
    let timestamp: Date
}

// Proto serialization (hidden in Messenger)
extension OutgoingTextMessage {
    func toProto() -> Data {
        var msg = Obscura_V2_ClientMessage()
        msg.type = .text
        msg.text = text
        msg.timestamp = UInt64(timestamp.timeIntervalSince1970 * 1000)
        return try! msg.serializedData()
    }
}
```

Views and managers never import SwiftProtobuf. Only `MessengerActor` and `EnvelopeProcessor` touch proto types.

### B4. Add negative crypto tests

```swift
func testWrongKeyCannotDecrypt() throws {
    let alice = try TestUser.create()
    let bob = try TestUser.create()
    let eve = try TestUser.create()  // attacker

    // Alice encrypts for Bob
    let ciphertext = try encrypt(for: bob, plaintext: "secret")

    // Eve cannot decrypt
    XCTAssertThrowsError(try decrypt(as: eve, ciphertext: ciphertext))
}

func testTamperedCiphertextFails() throws {
    let ciphertext = try encrypt(for: bob, plaintext: "secret")
    var tampered = ciphertext
    tampered[10] ^= 0xFF  // flip a byte

    XCTAssertThrowsError(try decrypt(as: bob, ciphertext: tampered))
}
```

---

## Phase C: Production-Grade (Before TestFlight)

### C1. Single shared DatabaseQueue

**Current:** Each actor creates its own `DatabaseQueue()` — 6 separate SQLite files, 6 connection pools.

**Target:** One `DatabaseQueue` passed to all actors at init. One file, one transaction scope, one place to add SQLCipher.

```swift
public class ObscuraClient {
    private let db: DatabaseQueue

    public init(apiURL: String, databasePath: String) throws {
        self.db = try DatabaseQueue(path: databasePath)
        self.friends = try FriendActor(db: db)
        self.messages = try MessageActor(db: db)
        self.devices = try DeviceActor(db: db)
        self.signalStore = try PersistentSignalStore(db: db)
        // ... all share one DB
    }
}
```

### C2. SQLCipher encryption at rest

**Change in Package.swift:**
```swift
// Before:
.product(name: "GRDB", package: "GRDB.swift"),

// After:
.product(name: "GRDB-SQLCipher", package: "GRDB.swift"),
```

**Key management:**
```swift
let key = try Keychain.getOrCreateDatabaseKey()  // iOS Keychain
let db = try DatabaseQueue(path: dbPath, configuration: config)
try db.write { db in try db.execute(sql: "PRAGMA key = '\(key)'") }
```

### C3. GRDB Record types (FetchableRecord + PersistableRecord)

**Current:** Manual `rowToFriend()` parsing (~30 lines per type).

**Target:**
```swift
struct Friend: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "friends"

    var userId: String
    var username: String
    var status: String
    // ... GRDB maps columns automatically
}

// Query becomes:
let accepted = try db.read { db in
    try Friend.filter(Column("status") == "accepted").fetchAll(db)
}
```

Eliminates all `rowToFriend()`, `rowToMessage()`, `rowToDevice()` methods.

### C4. Backup encryption (AES-GCM)

```swift
import CryptoKit

func uploadBackup() async throws {
    let plaintext = SyncBlobExporter.export(...)
    let key = SymmetricKey(data: deriveBackupKey())
    let sealed = try AES.GCM.seal(plaintext, using: key)
    try await api.uploadBackup(sealed.combined!, etag: backupEtag)
}

func downloadBackup() async throws -> Data? {
    guard let result = try await api.downloadBackup(etag: backupEtag) else { return nil }
    let key = SymmetricKey(data: deriveBackupKey())
    let box = try AES.GCM.SealedBox(combined: result.data)
    return try AES.GCM.open(box, using: key)
}
```

### C5. Identity key binding (safety numbers)

When `processServerBundle()` receives a prekey bundle, check if we've seen this user's identity key before:

```swift
func processServerBundle(_ bundle: PreKeyBundleResponse, userId: String) throws {
    let newIdentityKey = try IdentityKey(bytes: Data(base64Encoded: bundle.identityKey)!)

    if let stored = try persistentSignalStore.identity(for: address, context: NullContext()) {
        if stored != newIdentityKey {
            // Identity key changed — possible MITM
            logger.identityKeyChanged(userId: userId)
            delegate?.identityKeyChanged(userId: userId, oldKey: stored, newKey: newIdentityKey)
            // Don't silently continue — require user verification
            throw ObscuraError.identityKeyChanged(userId)
        }
    }

    // First time — TOFU, proceed
    try LibSignalClient.processPreKeyBundle(bundle, ...)
}
```

---

## Verification

After each phase:
- `swift test` — all existing scenario tests pass (public API unchanged)
- Phase A: grep confirms zero `[String: Any]` in APIClient, zero hand-rolled hash functions
- Phase B: no file over 200 lines, zero `try?` on database writes, zero proto imports outside Messenger/EnvelopeProcessor
- Phase C: `sqlcipher` in Package.swift, backup download fails without correct key, identity key change throws

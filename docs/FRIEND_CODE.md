# Friend Codes — Implementation Notes

## Format (from JS web client)

A friend code is **base64-encoded JSON** containing userId and username:

```
Base64(JSON.stringify({ u: userId, n: username }))
```

Example: `eyJ1IjoiYWJjMTIzIiwibiI6ImFsaWNlIn0=` → `{"u":"abc123","n":"alice"}`

This is the string that gets QR-encoded or shared as text.

## JS Implementation Reference

**File:** `obscura-client-web/src/v2/views/friends/AddFriend.js`

### Encode (generate your code)
```javascript
function encodeShareCode(userId, username) {
  const data = JSON.stringify({ u: userId, n: username });
  return btoa(data);
}
```

### Decode (parse a friend's code)
```javascript
function decodeShareCode(code) {
  try {
    const data = JSON.parse(atob(code));
    if (!data.u || !data.n) throw new Error('Invalid code');
    return { userId: data.u, username: data.n };
  } catch {
    throw new Error('Invalid friend code');
  }
}
```

### Parse (handles legacy URL format too)
```javascript
function parseInput(input) {
  const trimmed = input.trim();
  if (trimmed.startsWith('obscura://') || trimmed.includes('userId=')) {
    // Legacy obscura:// URL format
    const url = new URL(trimmed.replace('obscura://', 'https://obscura.app/'));
    return { userId: url.searchParams.get('userId'), username: url.searchParams.get('username') };
  }
  return decodeShareCode(trimmed);
}
```

## Swift Implementation Plan

### ObscuraKit (library layer)

Add to `Sources/ObscuraKit/FriendCode.swift`:

```swift
public enum FriendCode {
    public struct Decoded {
        public let userId: String
        public let username: String
    }

    /// Generate a shareable friend code from userId + username.
    /// This string can be QR-encoded or shared as text.
    public static func encode(userId: String, username: String) -> String {
        let json: [String: String] = ["u": userId, "n": username]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return data.base64EncodedString()
    }

    /// Decode a friend code back to userId + username.
    public static func decode(_ code: String) throws -> Decoded {
        guard let data = Data(base64Encoded: code),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let userId = json["u"], !userId.isEmpty,
              let username = json["n"], !username.isEmpty
        else { throw FriendCodeError.invalidCode }
        return Decoded(userId: userId, username: username)
    }

    public enum FriendCodeError: Error, LocalizedError {
        case invalidCode
        public var errorDescription: String? { "Invalid friend code" }
    }
}
```

### App layer (SwiftUI)

The app generates the code on the "Add Friend" screen:
```swift
let myCode = FriendCode.encode(userId: client.userId!, username: client.username!)
// Display as text + QR code (use CoreImage CIFilter "CIQRCodeGenerator")
```

When scanning/pasting a friend's code:
```swift
let decoded = try FriendCode.decode(scannedCode)
try await client.befriend(decoded.userId, username: decoded.username)
```

### QR Code generation (iOS)

```swift
import CoreImage.CIFilterBuiltins

func generateQRCode(from string: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    return UIImage(ciImage: scaled)
}
```

### QR Code scanning (iOS)

Use `CodeScannerView` from the `CodeScanner` package, or `AVCaptureSession` with `AVMetadataObjectTypeQRCode`.

## Kotlin Implementation Plan

### ObscuraKit (library layer)

Add to `lib/src/main/kotlin/com/obscura/kit/FriendCode.kt`:

```kotlin
object FriendCode {
    data class Decoded(val userId: String, val username: String)

    fun encode(userId: String, username: String): String {
        val json = JSONObject().apply {
            put("u", userId)
            put("n", username)
        }
        return Base64.getEncoder().encodeToString(json.toString().toByteArray())
    }

    fun decode(code: String): Decoded {
        val json = JSONObject(String(Base64.getDecoder().decode(code)))
        val userId = json.optString("u", "")
        val username = json.optString("n", "")
        require(userId.isNotEmpty() && username.isNotEmpty()) { "Invalid friend code" }
        return Decoded(userId, username)
    }
}
```

### Android app layer

Generate QR using `com.google.zxing:core` or Jetpack `rememberQrBitmapPainter`.
Scan using `com.google.mlkit:barcode-scanning` (ML Kit).

## Key Design Decisions

- **Base64 JSON, not URL** — simpler, no domain dependency, works offline
- **Short keys `u`/`n`** — keeps the QR code small (fewer modules = easier to scan)
- **Legacy URL support** — JS parser also handles `obscura://add?userId=X&username=Y` for backwards compat. iOS/Kotlin can add this later if needed.
- **No crypto in the code** — the code is just a pointer. The actual key exchange happens via Signal when `befriend()` is called. The code itself doesn't need to be secret (knowing someone's userId doesn't let you read their messages).

# Notification Service Extension prerequisites

**Status:** no NSE exists. The current server sends a content-free background
APNs notification, which cannot launch an NSE. iOS must use an app background
handler unless the server payload changes to an NSE-compatible notification.
APNs/FCM token forwarding, push capabilities, and the background handler are
also not implemented in `obscura-pix`.

## Dormant shared-storage plumbing

- `SharedContainer` prefers the App Group container for the SQLCipher database.
- The kit receives the App Group keychain access group for the database key.
- `KeychainSession` stores the access token, refresh token, user ID, device ID,
  and username in the shared group.
- The app falls back to private storage when the App Group is unavailable and
  logs that condition.

These paths compile but have not been exercised by an extension on a signed
device.

## Before enabling iOS push

1. Enable Push Notifications and Background Modes → Remote notifications.
2. Forward APNs/FCM tokens through `pushTokenReceived`.
3. Handle the content-free wake in the app delegate, call
   `processPendingMessages`, and post generic local copy when appropriate.

## Additional NSE requirements

1. Replace the current background payload with a privacy-reviewed
   NSE-compatible contract.
2. Add an NSE target with the same App Group entitlement and provisioning.
3. Migrate existing private-container databases and keychain items, or require
   a wipe when shared storage first becomes available.
4. Support concurrent database access, including WAL/pool semantics.
5. Ensure only one process owns the gateway drain at a time.
6. Restore the shared session, call `processPendingMessages`, set generic copy
   on the incoming notification, and complete it through the NSE content
   handler. Do not post a second local notification.

Verify App Group provisioning, keychain access while locked, token refresh,
database concurrency, and delivery on physical hardware before calling the NSE
path supported.

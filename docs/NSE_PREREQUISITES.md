# Notification Service Extension — what must be true before it can work

**Status: requirements, not a completed change. The claims marked UNPROVEN below have not been
executed on Apple hardware and cannot be from a Linux CI box.**

`obscura-proto/KIT_API.md` P2. SPEC §0.1 justifies the existence of native kits partly on this:
*"the push path must decrypt with the app closed — on iOS, in a Notification Service Extension."*
Today **no NSE exists**, and if one were written it could not open the message store. Since the
Phase 3 inbox *is* the message store, where that store lives and who can unlock it stops being a
Phase 4 detail and becomes a Phase 3 decision.

---

## The two blockers

An NSE is a **separate process with a different bundle id**. That breaks two assumptions this kit
and the app currently make.

### 1. The database file is in an app-private directory

`obscura-pix` passes `.applicationSupportDirectory` as `dataDirectory`. An extension cannot read it.
The file must live in an **App Group container** shared by the app and the extension.

This kit already takes `dataDirectory` from the caller, so **the kit needs no change** — the app must
pass a container path.

### 2. The SQLCipher key is in the app's default keychain access group

Without a shared access group the extension cannot fetch the key, so even with the file reachable the
database cannot be decrypted.

**Done in this kit** (this PR): `DatabaseSecret.getOrCreate(userId:accessGroup:)` and
`ObscuraClient.init(..., keychainAccessGroup:)`. Both default to `nil`, which preserves today's
behaviour exactly.

> **Why now rather than with the NSE:** a keychain item **cannot be moved between access groups in
> place** — it must be deleted and re-created. That item holds the only key to the message store. It
> is free to accept the parameter today and expensive to retrofit once there is data behind it.

---

## The app-side checklist (obscura-pix) — NOT DONE, and unverifiable here

`obscura-pix` CI builds TypeScript, ESLint and an Android APK. **It does not build iOS at all**, so
none of the following can be checked by any automation currently in the project. Doing it blind and
declaring it done would be exactly the failure mode this project has been unpicking all week.

1. Add an **App Group** (e.g. `group.com.obscuraapp.shared`) to the app target *and* the future NSE
   target, in the Apple Developer portal and in each target's entitlements.
2. Add a shared **keychain access group** (e.g. `$(AppIdentifierPrefix)com.obscuraapp.shared`) to
   both targets' entitlements.
3. Change `ObscuraSession.swift` to derive `dataDirectory` from
   `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` instead of
   `.applicationSupportDirectory`, and pass `keychainAccessGroup:` to `ObscuraClient`.
4. **Migrate any existing database and keychain item**, or accept a wipe. Moving the file is a copy;
   moving the keychain item is a delete-and-recreate. On a greenfield install neither matters —
   which is the argument for doing it before there is data, not after.
5. Only then create the NSE target.

## Still open, deliberately not built yet

- **`DatabaseQueue` → `DatabaseWriter`/`DatabasePool` + WAL.** Two processes on one SQLite file need
  WAL and pool semantics. Deferred because `DatabaseQueue` appears in the type signature of every
  store (`DeviceStore`, `PersistentSignalStore`, `MessageStore`, `FriendStore`, `InboxStore`, `EntryStore`), so it is a
  cross-cutting type change whose only verification from Linux is a ~20-minute CI round trip, and
  whose value does not materialise until a second process actually exists. Do it with the NSE, on a
  machine that can run it.
- **The single-drainer lock.** The server's per-device notifier is a broadcast and each `MessagePump`
  keeps its own cursor, so app and NSE can both connect, both insert and both notify. The rule —
  exactly one process holds the gateway connection, enforced by an advisory lock file in the App
  Group container — is specified in `KIT_API.md` P2 but not implemented, because a lock with no
  second process to exclude cannot be tested.

## What is UNPROVEN

- That an NSE can actually open the store once 1–3 are done. The reasoning is standard iOS
  platform behaviour (App Group container + shared keychain access group), but **it has not been
  executed**: there is no NSE target, no simulator here, and no Apple hardware in this loop.
- That `kSecAttrAccessGroup` behaves as expected at runtime. CI proves the code compiles and that
  the `nil` path still works; it does not prove cross-process keychain sharing, because CI has one
  process.

Treat everything above as a design that compiles, not a feature that works, until someone runs it on
a device.

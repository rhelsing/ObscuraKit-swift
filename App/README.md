# Obscura iOS App

SwiftUI app that links against the ObscuraKit Swift package.

## Prerequisites

- **macOS 13+** with **Xcode 26.4+**
- **Rust** (stable 1.92+) via [rustup](https://rustup.rs)
- Rust targets for iOS:
  ```bash
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim
  ```

## Building libsignal FFI for iOS

The ObscuraKit package depends on `libsignal_ffi.a` — a static library built from Rust. The macOS version (used by `swift test`) is already at `vendored/libsignal/target/release/`. For the iOS app, you need device and/or simulator builds.

### iOS Device (arm64)

```bash
cd vendored/libsignal
RUSTUP_TOOLCHAIN=stable CARGO_BUILD_TARGET=aarch64-apple-ios ./swift/build_ffi.sh -r
```

Output: `vendored/libsignal/target/aarch64-apple-ios/release/libsignal_ffi.a`

### iOS Simulator (arm64, Apple Silicon)

```bash
cd vendored/libsignal
RUSTUP_TOOLCHAIN=stable \
  CARGO_BUILD_TARGET=aarch64-apple-ios-sim \
  BINDGEN_EXTRA_CLANG_ARGS="--target=arm64-apple-ios16.0-simulator" \
  ./swift/build_ffi.sh -r
```

Output: `vendored/libsignal/target/aarch64-apple-ios-sim/release/libsignal_ffi.a`

> **Why `BINDGEN_EXTRA_CLANG_ARGS`?** The vendored `boring-sys` crate (BoringSSL bindings) uses bindgen 0.66 which passes the Rust target triple `arm64-apple-ios-sim` directly to clang. Clang doesn't understand this — it expects `arm64-apple-ios16.0-simulator`. This env var overrides the target for bindgen's clang invocations. The device build doesn't have this issue.

> **Why `RUSTUP_TOOLCHAIN=stable`?** The vendored libsignal pins `nightly-2024-01-08` (LLVM 17) in its `rust-toolchain` file. Xcode 26.4's clang produces LLVM attributes that LLVM 17 can't read, causing cross-compilation failures. Stable Rust 1.92 (LLVM 19) is compatible.

### First build takes ~5 minutes. Subsequent builds use Cargo's cache and are fast.

## Opening in Xcode

1. Open `App/obscura-base/obscura-base.xcodeproj`
2. Xcode will resolve SPM dependencies automatically (ObscuraKit, GRDB, SwiftProtobuf, LibSignalClient)
3. Select a simulator or device target and build

The project is pre-configured with:
- **Local package dependency** on `../../` (the ObscuraKit package root)
- **LIBRARY_SEARCH_PATHS** pointing to the correct `libsignal_ffi.a` per SDK:
  - `iphoneos` → `vendored/libsignal/target/aarch64-apple-ios/release`
  - `iphonesimulator` → `vendored/libsignal/target/aarch64-apple-ios-sim/release`
- **Deployment target** iOS 16.0

## Project Structure

```
App/
├── README.md              ← you are here
├── ObscuraApp/            ← canonical source files (edit here)
│   ├── ObscuraAppMain.swift   @main entry point
│   ├── AppState.swift         ObscuraClient owner, GRDB observation, session persistence
│   ├── ContentView.swift      Register/Login, friend list, chat UI
│   └── KeychainSession.swift  iOS Keychain session storage
└── obscura-base/          ← Xcode project (sources synced from ObscuraApp/)
    ├── obscura-base.xcodeproj
    └── obscura-base/      ← Xcode's auto-synced source directory
```

## Simulator Workflow

```bash
# FIRST TIME ONLY — install the app:
xcodebuild -project obscura-base.xcodeproj -scheme obscura-base \
  -destination 'platform=iOS Simulator,name=iPhone 17e' -configuration Debug build
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/obscura-base-*/Build/Products/Debug-iphonesimulator/obscura-base.app
xcrun simctl launch booted ryanhelsing.obscura-base

# AFTER CODE CHANGES — rebuild and relaunch (DO NOT reinstall):
xcodebuild -project obscura-base.xcodeproj -scheme obscura-base \
  -destination 'platform=iOS Simulator,name=iPhone 17e' -configuration Debug build
xcrun simctl terminate booted ryanhelsing.obscura-base
xcrun simctl launch booted ryanhelsing.obscura-base
```

**Never use `simctl install` after the first time.** It resets the Keychain, which wipes the saved session. The app will think it's a new device and show the link code screen. The SQLite database survives installs, but the Keychain doesn't.

`xcodebuild` writes the new binary to DerivedData. `simctl launch` picks it up automatically — no install needed.

If you accidentally reinstall and lose the session, just register a new user. The old user's data is still in the DB but the Keychain session is gone.

## Troubleshooting

**"No such module 'ObscuraKit'"** — SPM hasn't resolved yet. Close and reopen the project, or File → Packages → Resolve Package Versions.

**Linker error: "library not found for -lsignal_ffi"** — You haven't built the FFI for this target. Run the appropriate build command above.

**Build fails with LLVM attribute errors** — You're using the pinned nightly instead of stable. Make sure `RUSTUP_TOOLCHAIN=stable` is set.

// swift-tools-version: 6.0

import PackageDescription

// Absolute path to the prebuilt libsignal FFI static lib, derived from this
// Package.swift's location (CWD-independent), mirroring the main ObscuraKit
// Package.swift. The vendored libsignal package only adds a `-L` for its OWN
// test target, so consumers must supply the path.
//   verification/AddressingProbe/Package.swift  ->  ../../vendored/...
let packageDir = String(#filePath.dropLast("/Package.swift".count))
let libsignalLibDir = packageDir + "/../../vendored/libsignal/target/release"

let package = Package(
    name: "AddressingProbe",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    dependencies: [
        // ONLY the vendored LibSignalClient. No ObscuraKit, no GRDB, no SQLCipher.
        .package(path: "../../vendored/libsignal/swift"),
    ],
    targets: [
        .target(
            name: "AddressingProbe",
            dependencies: [
                .product(name: "LibSignalClient", package: "swift"),
            ]),
        .testTarget(
            name: "AddressingProbeTests",
            dependencies: [
                "AddressingProbe",
                .product(name: "LibSignalClient", package: "swift"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", libsignalLibDir]),
            ]),
    ]
)

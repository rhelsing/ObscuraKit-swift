// swift-tools-version: 6.0

import PackageDescription

// Absolute path to the prebuilt libsignal FFI static lib, derived from this
// Package.swift's location (CWD-independent). The vendored libsignal package
// only adds a `-L` for its OWN test target, so consumers must supply the path.
let packageDir = String(#filePath.dropLast("/Package.swift".count))
let libsignalLibDir = packageDir + "/vendored/libsignal/target/release"

let package = Package(
    name: "ObscuraKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "ObscuraKit",
            targets: ["ObscuraKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
        .package(path: "../grdb-cipher-fork"),
        .package(path: "vendored/libsignal/swift"),
    ],
    targets: [
        .target(
            name: "ObscuraKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRDB", package: "grdb-cipher-fork"),
                .product(name: "LibSignalClient", package: "swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]),
        .testTarget(
            name: "ScenarioTests",
            dependencies: ["ObscuraKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", libsignalLibDir]),
            ]),
        // Pure-logic unit tests — no network, no live server (mirrors Kotlin's
        // :lib:test). This is the fast PR gate.
        .testTarget(
            name: "UnitTests",
            dependencies: ["ObscuraKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", libsignalLibDir]),
            ]),
    ]
)

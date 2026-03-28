#!/bin/bash
# Dev helper - runs swift commands with Swift 6.1 toolchain
set -e

export TOOLCHAINS=swift-6.1.3-RELEASE
SWIFT=/Library/Developer/Toolchains/swift-6.1.3-RELEASE.xctoolchain/usr/bin/swift
LIBSIGNAL_PATH="$(pwd)/vendored/libsignal/target/release"

case "${1:-test}" in
  build)
    LIBRARY_PATH="$LIBSIGNAL_PATH" $SWIFT build "${@:2}"
    ;;
  test)
    LIBRARY_PATH="$LIBSIGNAL_PATH" $SWIFT test "${@:2}"
    ;;
  shell)
    LIBRARY_PATH="$LIBSIGNAL_PATH" TOOLCHAINS=swift-6.1.3-RELEASE bash
    ;;
  *)
    echo "Usage: ./dev.sh [build|test|shell]"
    echo "Extra args passed to swift, e.g.: ./dev.sh test --filter CoreFlowTests"
    ;;
esac

#!/bin/bash
# Dev helper - runs swift commands with Xcode's Swift toolchain
set -e

SWIFT="xcrun swift"
LIBSIGNAL_PATH="$(pwd)/vendored/libsignal/target/release"

case "${1:-test}" in
  build)
    LIBRARY_PATH="$LIBSIGNAL_PATH" $SWIFT build "${@:2}"
    ;;
  test)
    LIBRARY_PATH="$LIBSIGNAL_PATH" $SWIFT test "${@:2}"
    ;;
  shell)
    LIBRARY_PATH="$LIBSIGNAL_PATH" bash
    ;;
  *)
    echo "Usage: ./dev.sh [build|test|shell]"
    echo "Extra args passed to swift, e.g.: ./dev.sh test --filter CoreFlowTests"
    ;;
esac

#!/bin/bash
# Dev helper - runs commands in the Docker build environment
# Usage: ./dev.sh build | test | test-filter "TestName" | shell
set -e

IMAGE="obscura-kit:dev"
VOLUME="obscura-build-cache"

run() {
  docker run --rm \
    -v "$(pwd):/app" \
    -v "${VOLUME}:/app/.build" \
    -w /app "$IMAGE" \
    "$@"
}

case "${1:-test}" in
  build)
    run swift build
    ;;
  test)
    run swift test "${@:2}"
    ;;
  test-filter|tf)
    run swift test --filter "$2"
    ;;
  test-skip|ts)
    run swift test --skip "$2"
    ;;
  shell)
    docker run --rm -it \
      -v "$(pwd):/app" \
      -v "${VOLUME}:/app/.build" \
      -w /app "$IMAGE" bash
    ;;
  *)
    echo "Usage: ./dev.sh [build|test|test-filter NAME|test-skip NAME|shell]"
    ;;
esac

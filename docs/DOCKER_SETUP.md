# Docker Build Environment

## Why Docker

macOS 12 can't run Swift 6.1 natively (requires macOS 13+). Docker runs Swift 6.1.3 on Linux with all dependencies pre-built.

## Quick Start

```bash
# Build the image (first time only — takes ~10 min, includes Rust libsignal FFI)
docker build -t obscura-kit:dev .

# Create persistent build cache
docker volume create obscura-build-cache

# Build
docker run --rm \
  -v "$(pwd):/app" \
  -v obscura-build-cache:/app/.build \
  -w /app -e LIBRARY_PATH=/usr/local/lib \
  obscura-kit:dev swift build

# Test
docker run --rm \
  -v "$(pwd):/app" \
  -v obscura-build-cache:/app/.build \
  -w /app -e LIBRARY_PATH=/usr/local/lib \
  obscura-kit:dev swift test --filter CoreFlowTests

# Or use the helper
./dev.sh build
./dev.sh test
./dev.sh test --filter CoreFlowTests
```

## What's in the Image

| Component | Version | Why |
|-----------|---------|-----|
| Swift | 6.1.3 | swift-tools-version: 6.0 |
| Rust | latest | builds libsignal FFI from source |
| SQLite | 3.45.1 (custom) | SQLITE_ENABLE_SNAPSHOT for GRDB |
| clang | 18.1.3 (wrapped) | strips `-index-store-path` flag |
| libsignal_ffi.a | v0.40.0 | pre-built, at /usr/local/lib |
| cmake, nasm, protoc | system | build dependencies |

## Rebuild After Changes

If you change `Package.swift` dependencies: `docker volume rm obscura-build-cache` then rebuild.

If you change the Dockerfile: `docker build -t obscura-kit:dev .` (uses cache for unchanged layers).

If you update libsignal version: update `vendored/libsignal` and rebuild the Docker image.

## Known Issues

- **Full test suite can hang** if envelope loop tasks from one test aren't cleaned up before the next. Run suites individually with `--filter` if the full run hangs.
- **Build cache is Linux-specific.** Can't share between Docker and native macOS builds.
- **First build is slow** (~60s) even with cache because test discovery recompiles.

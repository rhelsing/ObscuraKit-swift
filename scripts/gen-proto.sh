#!/usr/bin/env bash
#
# Regenerate the checked-in Swift protobuf bindings from the CANONICAL protos in
# the `proto/` submodule (obscura-proto — the single source of truth shared with
# the server and the other kits). There is deliberately no hand-copied proto in
# this repo; the submodule is the only source.
#
# Requirements (macOS):
#   brew install protobuf         # provides protoc
#   brew install swift-protobuf   # provides protoc-gen-swift
#
# Usage:
#   scripts/gen-proto.sh
#   git diff --exit-code Sources/ObscuraKit/Proto   # verify nothing drifted
#
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f proto/obscura/client/v1/client.proto ]; then
  echo "error: proto submodule not checked out — run: git submodule update --init" >&2
  exit 1
fi
command -v protoc >/dev/null || { echo "error: protoc not found (brew install protobuf)" >&2; exit 1; }
command -v protoc-gen-swift >/dev/null || { echo "error: protoc-gen-swift not found (brew install swift-protobuf)" >&2; exit 1; }

# Client content (kit <-> kit) -> Sources/ObscuraKit/Proto/Client/
protoc --proto_path=proto/obscura/client/v1 \
  --swift_out=Sources/ObscuraKit/Proto/Client \
  proto/obscura/client/v1/client.proto

# Transport (server <-> kits) -> Sources/ObscuraKit/Proto/Server/
protoc --proto_path=proto/obscura/v1 \
  --swift_out=Sources/ObscuraKit/Proto/Server \
  proto/obscura/v1/obscura.proto

echo "Regenerated Swift protobuf bindings from the proto/ submodule."

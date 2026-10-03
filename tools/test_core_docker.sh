#!/usr/bin/env bash
# Build and test OutboardCore in the official Swift Linux image (works from Windows via Docker Desktop).
# Usage (Git Bash): tools/test_core_docker.sh
# Fails on any compiler warning ("must pass with no warnings", AGENTS.md).
IMAGE="swift:6.2@sha256:9bea530093ffff8cf6c259991715ee843fe4d0f932e612f7f4b79cca6e00db87"   # digest-pinned (index digest); same pin as ci.yml core-linux: bump both together
set -euo pipefail
cd "$(dirname "$0")/.."
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W 2>/dev/null || pwd):/src:ro" "$IMAGE" bash -c '
  set -eo pipefail
  mkdir -p /work && cp -r /src/Package.swift /src/Sources /src/Tests /src/tools /work/ &&
  cd /work &&
  { swift build --target OutboardCore && swift test --filter OutboardCoreTests; } 2>&1 | tee /tmp/swift.log
  if grep -E "warning:" /tmp/swift.log; then echo "test_core_docker: compiler warnings above"; exit 1; fi
  exit 0'

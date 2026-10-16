#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Apple Development certificate name}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER to an integer greater than your installed version}"
BAZEL_VERSION="$(python3 -c 'import json; print(json.load(open("versions.json"))["bazel"].split(":")[0])')"
BUILD_ROOT="${NANOVOICE_BUILD_ROOT:-$PWD/../telegram-build/bazel-root}"
exec "build-input/bazel-${BAZEL_VERSION}-darwin-arm64" \
  --output_user_root="$BUILD_ROOT" build Telegram/Telegram \
  --//Telegram:disableExtensions --define="buildNumber=$BUILD_NUMBER" \
  --ios_signing_cert_name="$SIGNING_IDENTITY" \
  -c dbg --ios_multi_cpus=arm64 --watchos_cpus=arm64_32 --jobs="${BUILD_JOBS:-6}"

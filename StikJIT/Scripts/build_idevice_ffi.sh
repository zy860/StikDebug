#!/usr/bin/env bash
set -euo pipefail

# This revision is the first upstream revision that exposes the iOS 27
# pairable-host FFI. Building with the `full` feature set also keeps the
# syslog relay exports used by JITEnableContext.swift. The ring backend is
# used because aws-lc's iOS arm64 build requires an unavailable stack-check
# runtime symbol on the Xcode 26 runner.
readonly IDEVICE_REVISION="${IDEVICE_REVISION:-7bd551c16c6dd2e058740d85a2d9399a51a776e9}"
readonly IDEVICE_REPOSITORY="${IDEVICE_REPOSITORY:-https://github.com/jkcoxson/idevice.git}"
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SOURCE_DIR="${IDEVICE_SOURCE_DIR:-${TMPDIR:-/tmp}/stikdebug-idevice-${IDEVICE_REVISION}}"
readonly TARGET="aarch64-apple-ios"
readonly OUTPUT_DIR="${PROJECT_ROOT}/StikJIT/idevice"

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.4}"

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required to rebuild the bundled idevice FFI" >&2
    exit 1
fi

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
    git clone --filter=blob:none "${IDEVICE_REPOSITORY}" "${SOURCE_DIR}"
fi

git -C "${SOURCE_DIR}" fetch --depth 1 origin "${IDEVICE_REVISION}"
git -C "${SOURCE_DIR}" checkout --detach "${IDEVICE_REVISION}"

rustup target add "${TARGET}"
cargo build \
    --manifest-path "${SOURCE_DIR}/ffi/Cargo.toml" \
    --locked \
    --release \
    --target "${TARGET}" \
    --no-default-features \
    --features "full,ring"

cp "${SOURCE_DIR}/ffi/idevice.h" "${OUTPUT_DIR}/idevice.h"
cp "${SOURCE_DIR}/target/${TARGET}/release/libidevice_ffi.a" "${OUTPUT_DIR}/libidevice_ffi.a"

if ! nm -gU "${OUTPUT_DIR}/libidevice_ffi.a" | grep -q 'pairable_host_accept'; then
    echo "rebuilt idevice FFI does not export pairable_host_accept" >&2
    exit 1
fi

if ! nm -gU "${OUTPUT_DIR}/libidevice_ffi.a" | grep -q 'syslog_relay_connect_rsd'; then
    echo "rebuilt idevice FFI does not export syslog_relay_connect_rsd" >&2
    exit 1
fi

if ! nm -gU "${OUTPUT_DIR}/libidevice_ffi.a" | grep -q 'syslog_relay_next'; then
    echo "rebuilt idevice FFI does not export syslog_relay_next" >&2
    exit 1
fi

echo "Prepared idevice FFI ${IDEVICE_REVISION} with pairable-host and syslog relay support."

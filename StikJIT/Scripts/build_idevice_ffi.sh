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
readonly PAIRABLE_HOST_PATCH="${PROJECT_ROOT}/StikJIT/Scripts/idevice_pairable_host_callbacks.patch"
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

# The upstream FFI advertises directly with mdns-sd and exposes a shorter
# pairable_host_accept ABI. iOS needs Network.framework to publish the Bonjour
# service and relay the device connection to the loopback listener, so apply
# the same callback ABI used by the bundled Locus header and Swift code.
if ! grep -q 'PairableHostListeningCallback' "${SOURCE_DIR}/ffi/src/pairable_host.rs"; then
    git -C "${SOURCE_DIR}" apply "${PAIRABLE_HOST_PATCH}"
fi

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

if ! grep -q 'PairableHostListeningCallback' "${OUTPUT_DIR}/idevice.h"; then
    echo "rebuilt idevice header does not expose the pairable-host listening callback ABI" >&2
    exit 1
fi

if ! grep -q 'PairableHostConnectedCallback' "${OUTPUT_DIR}/idevice.h"; then
    echo "rebuilt idevice header does not expose the pairable-host connected callback ABI" >&2
    exit 1
fi

if ! grep -a -q 'pairable_host_accept' "${OUTPUT_DIR}/libidevice_ffi.a"; then
    echo "rebuilt idevice FFI does not export pairable_host_accept" >&2
    exit 1
fi

if ! grep -a -q 'syslog_relay_connect_rsd' "${OUTPUT_DIR}/libidevice_ffi.a"; then
    echo "rebuilt idevice FFI does not export syslog_relay_connect_rsd" >&2
    exit 1
fi

if ! grep -a -q 'syslog_relay_next' "${OUTPUT_DIR}/libidevice_ffi.a"; then
    echo "rebuilt idevice FFI does not export syslog_relay_next" >&2
    exit 1
fi

echo "Prepared idevice FFI ${IDEVICE_REVISION} with pairable-host and syslog relay support."

#!/usr/bin/env bash
# Build the Rust `aislopdesk-ffi` staticlib for Apple platforms and sync the C header into
# the SwiftPM `CAislopdeskFFI` target, so `swift build` / `swift test` can link it.
#
# macOS host slice (arm64-apple-darwin) is built by default — that is what `swift test`
# links on this machine. Pass `--ios` to also cross-compile the iOS device + simulator
# slices (requires `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`); those are
# only needed to build/run the actual iOS app, not the macOS test+benchmark gate.
#
# Always builds RELEASE (LTO + panic=abort + strip, per the workspace profile): the linked
# algorithm bytes are identical to debug, and the benchmarks need optimized code.
set -euo pipefail

cd "$(dirname "$0")"
RUST_DIR="$(pwd)"
PKG_DIR="$(cd .. && pwd)"

echo "==> cargo build --release -p aislopdesk-ffi (host: $(rustc -vV | sed -n 's/host: //p'))"
cargo build --release -p aislopdesk-ffi

# Keep the SwiftPM-visible header byte-identical to the Rust-side source of truth.
SRC_HEADER="${RUST_DIR}/aislopdesk-ffi/include/aislopdesk_ffi.h"
DST_HEADER="${PKG_DIR}/Sources/CAislopdeskFFI/include/aislopdesk_ffi.h"
if ! cmp -s "${SRC_HEADER}" "${DST_HEADER}"; then
  echo "==> syncing header -> Sources/CAislopdeskFFI/include/aislopdesk_ffi.h"
  cp "${SRC_HEADER}" "${DST_HEADER}"
fi

# shellcheck disable=SC2012 # controlled path; want `ls -lh`'s human-readable size column
echo "==> macOS staticlib: $(ls -lh "${RUST_DIR}/target/release/libaislopdesk_ffi.a" | awk '{print $5}')"

if [[ "${1:-}" == "--ios" ]]; then
  for tgt in aarch64-apple-ios aarch64-apple-ios-sim; do
    echo "==> cargo build --release --target ${tgt} -p aislopdesk-ffi"
    cargo build --release --target "${tgt}" -p aislopdesk-ffi
  done
  echo "==> iOS slices built under rust/target/<triple>/release/ (wire into an xcframework for the app target)"
fi

echo "==> done."

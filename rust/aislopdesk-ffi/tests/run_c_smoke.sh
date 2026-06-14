#!/usr/bin/env bash
#
# Builds libaislopdesk_ffi as a static library, compiles tests/smoke.c against the public
# C header, links the two, and runs the result — the real cross-language proof that the C
# ABI in include/aislopdesk_ffi.h matches the Rust `#[repr(C)]` surface. Returns non-zero
# if the build, link, or any in-program check fails.
#
# Link flags come from `rustc --print native-static-libs` (on macOS: -lSystem -lc -lm).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
crate_dir="$(dirname "${here}")"
workspace_dir="$(dirname "${crate_dir}")"
target_dir="${workspace_dir}/target/debug"
staticlib="${target_dir}/libaislopdesk_ffi.a"
out="$(mktemp -t aisd_smoke.XXXXXX)"

echo "==> building staticlib"
(cd "${workspace_dir}" && cargo build -p aislopdesk-ffi)

# Native libs the Rust staticlib needs (`rustc --print native-static-libs`). On macOS `cc`
# already links libSystem (which subsumes -lSystem/-lc/-lm), so we add only -lm to avoid a
# duplicate-library warning. Linux uses a different set; this script targets the Apple host
# where the boundary is consumed today.
case "$(uname -s)" in
  Darwin) native_libs=(-lm) ;;
  Linux) native_libs=(-lpthread -ldl -lm) ;;
  *) native_libs=(-lm) ;;
esac

echo "==> compiling + linking smoke.c"
cc -std=c11 -Wall -Wextra -Werror \
  -I "${crate_dir}/include" \
  "${here}/smoke.c" "${staticlib}" "${native_libs[@]}" \
  -o "${out}"

echo "==> running"
"${out}"
status=$?
rm -f "${out}"
exit "${status}"

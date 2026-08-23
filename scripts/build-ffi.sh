#!/usr/bin/env bash
# build-ffi.sh — assemble ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework from `rust/slopdesk-ffi`.
#
# WHY THIS EXISTS
#   The Swift clients are in-process consumers of logic that now lives in Rust, and a socket cannot
#   reach them: the iOS client cannot host a sidecar daemon at all, and the macOS ones are on the
#   terminal's hot output path. So the port ships as a linked library — `CLAUDE.md`'s "pick by
#   lifetime" rule — and this script is what produces it.
#
# WHY THE ARTIFACT IS NOT COMMITTED
#   Measured 2026-08-15: 38 MB per slice, 110 MB for the three, rewritten by every Rust edit. That
#   is a git history nobody wants for a build output. `ThirdParty/ghostty/libghostty.xcframework`
#   is gitignored for the same reason and rebuilt by its own script; this follows that precedent.
#   What the app actually PAYS is far smaller, because an archive is not a binary: a probe calling
#   one plain door links to 439 KB after `-dead_strip`, and 1.61 MB once it calls
#   `slopdesk_ws_redact_secrets` and pulls `regex` in with it.
#
# WHY IT IS CHEAP TO RUN ANYWAY
#   The stamp below hashes every input (the Rust sources of this crate and the crates it wraps, plus
#   the header and this script). A second run with nothing changed exits in milliseconds, so wiring
#   it in front of `make build`/`test`/`check` costs nothing on a warm tree. `--force` skips the
#   check; `--check` reports staleness without building, which is what `make lint` uses.
#
# SLICES: arm64 only, matching the rest of the project (`docs/49` "arm64 only — a constraint, not a
# default"): macos-arm64, ios-arm64, ios-arm64-simulator.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"

CRATE="${ROOT}/rust/slopdesk-ffi"
OUT_DIR="${ROOT}/ThirdParty/slopdesk-ffi"
XCFRAMEWORK="${OUT_DIR}/SlopDeskFFI.xcframework"
STAMP="${OUT_DIR}/sources.sha256"
HEADERS="${CRATE}/include"
LIB_NAME="libslopdesk_ffi.a"

# Every symbol the header promises, READ OUT OF THE HEADER rather than restated here. The header is
# the promise; a hand-kept list beside it is a second list to forget. Checked against each assembled
# slice, so a header that drifts from the library fails HERE rather than at app link — or, worse, at
# runtime on one platform only. (Function-pointer TYPEDEFS are not matched: `(*name)(` puts a paren
# before the name, so only real declarations and their `name(` shape are picked up.)
REQUIRED_SYMBOLS=()
while IFS= read -r symbol; do
  REQUIRED_SYMBOLS+=("_${symbol}")
done < <(grep -oE '\bslopdesk_[a-z0-9_]+\(' "${CRATE}/include/slopdesk_ffi.h" | tr -d '(' | sort -u)
[[ "${#REQUIRED_SYMBOLS[@]}" -gt 0 ]] || fail "slopdesk_ffi.h declares nothing — did the header move?"

# The doors that exist on macOS ONLY, read out of the header's `MACOS-ONLY BEGIN/END` region for the
# reason the whole list is read out of the header: a second list beside it is a list to forget.
#
# One door is behind such a guard today — `slopdesk_git_status`, which links a vendored `libgit2`
# that no client can reach, since a phone RECEIVES the git status as a metadata reply. The bijection
# below is what keeps the three spellings of that fact in step: the `#if TARGET_OS_OSX` here, the
# `cfg(target_os = "macos")` in `src/lib.rs`, and the target-gated dependency in `Cargo.toml`. The
# symbol is REQUIRED on the macOS slice and REQUIRED ABSENT on the other two — so a cfg that stops
# matching the header fails this script in whichever direction it drifted, rather than shipping a
# phone archive with a C library in it or a macOS door Swift cannot link.
MACOS_ONLY_SYMBOLS=()
while IFS= read -r symbol; do
  MACOS_ONLY_SYMBOLS+=("_${symbol}")
done < <(
  awk '/MACOS-ONLY BEGIN/{inside=1} inside{print} /MACOS-ONLY END/{inside=0}' \
    "${CRATE}/include/slopdesk_ffi.h" | grep -oE '\bslopdesk_[a-z0-9_]+\(' | tr -d '(' | sort -u
)

# The crates whose sources decide whether the artifact is stale: the shim and everything it wraps.
# READ OUT OF THE CARGO GRAPH, for the reason the symbol list above is read out of the header — a
# hand-kept list is a second list to forget, and forgetting THIS one does not fail loudly. It calls
# a stale library fresh, which is the one failure mode `docs/55` says a linked port has and a socket
# port does not. Transitive, because `slopdesk-video` reaches `slopdesk-gfsimd`: a NEON edit under a
# crate nobody remembered to list is exactly the change that would ship against yesterday's archive.
# `slopdesk-posix` is correctly absent — superd forks, and the shim does not wrap it.
INPUT_CRATES=()
collect_crate() {
  local crate="$1" listed dep
  for listed in "${INPUT_CRATES[@]}"; do
    [[ "${listed}" == "rust/${crate}" ]] && return 0
  done
  [[ -f "${ROOT}/rust/${crate}/Cargo.toml" ]] ||
    fail "${crate} is a path dependency of the shim with no Cargo.toml — the graph is broken"
  INPUT_CRATES+=("rust/${crate}")
  while IFS= read -r dep; do
    [[ -n "${dep}" ]] && collect_crate "${dep}"
  done < <(
    grep -oE '^[a-z0-9-]+ *= *\{ *path *= *"\.\./[a-z0-9-]+"' "${ROOT}/rust/${crate}/Cargo.toml" |
      sed -E 's:.*\.\./::; s:"::'
  )
}
collect_crate slopdesk-ffi
[[ "${#INPUT_CRATES[@]}" -gt 1 ]] || fail "the shim declares no path dependencies — did Cargo.toml move?"

TARGETS=(
  "aarch64-apple-darwin"
  "aarch64-apple-ios"
  "aarch64-apple-ios-sim"
)

log() { printf 'build-ffi: %s\n' "$*"; }
fail() {
  printf 'build-ffi: FAIL — %s\n' "$*" >&2
  exit 1
}

# The hash of every input. `find | sort` rather than a glob so the order is stable across machines,
# and `shasum` over the concatenation rather than per-file so a DELETED file changes the stamp too.
#
# `target` is PRUNED, and that is load-bearing rather than tidiness. Build scripts write real `.rs`
# under `target/<triple>/release/build/<crate>-<metadata-hash>/out/`, and the hash in that directory
# name is cargo's, not ours. Unpruned, the stamp counted 12 such files across the shim's closure —
# and since `cargo build --target aarch64-apple-ios` MINTS a fresh one for a triple it has not built
# before, it changed AFTER `WANT` was read and BEFORE `WANT` was written to the stamp file. A clean
# `make ffi` therefore recorded a value the very next `--check` disagreed with, so `make lint`
# announced the artifact stale seconds after building it: an input-hash gate made to fire on its own
# output. Sources only.
stamp_inputs() {
  local crate
  for crate in "${INPUT_CRATES[@]}"; do
    find "${ROOT}/${crate}" -name target -prune -o \
      \( -name '*.rs' -o -name 'Cargo.toml' -o -name '*.h' -o -name 'module.modulemap' \) -print
  done
  # This script decides which slices exist and which symbols they must carry, so editing it can
  # change the artifact without touching one line of Rust. The banner above has claimed since it
  # was written that the stamp covers it; until this line it did not.
  printf '%s\n' "${SELF}"
}

current_stamp() {
  stamp_inputs | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}'
  # (the outer shasum collapses the per-file list into one line; the file NAMES are part of it,
  #  so a rename is a change even when the bytes are not)
}

MODE="build"
case "${1:-}" in
  --check) MODE="check" ;;
  --force) MODE="force" ;;
  "") MODE="build" ;;
  *) fail "unknown argument '${1}' (expected --check or --force)" ;;
esac

WANT="$(current_stamp)"

if [[ "${MODE}" != "force" ]]; then
  if [[ -d "${XCFRAMEWORK}" && -f "${STAMP}" && "$(cat "${STAMP}")" == "${WANT}" ]]; then
    [[ "${MODE}" == "check" ]] && {
      log "up to date"
      exit 0
    }
    log "up to date (${XCFRAMEWORK})"
    exit 0
  fi
fi

if [[ "${MODE}" == "check" ]]; then
  if [[ ! -d "${XCFRAMEWORK}" ]]; then
    fail "SlopDeskFFI.xcframework has never been built — run 'make ffi'"
  fi
  fail "SlopDeskFFI.xcframework is STALE: the Rust sources changed since it was built. Run 'make ffi'. \
A stale artifact is the one failure mode a linked port has that a socket does not — the Swift side \
would keep calling last week's logic with every test green."
fi

command -v cargo > /dev/null || fail "cargo not found — the FFI slices are built from Rust."
command -v xcodebuild > /dev/null || fail "xcodebuild not found (full Xcode required for -create-xcframework)."
command -v nm > /dev/null || fail "nm not found (Command Line Tools)."

for target in "${TARGETS[@]}"; do
  rustup target list --installed 2> /dev/null | grep -qx "${target}" ||
    fail "rust target ${target} is not installed — run 'rustup target add ${target}'"
done

# ── The headers go in a subdirectory named after the module, and that is load-bearing ──────────
#
# `xcodebuild -create-xcframework -headers X` copies X's CONTENTS to each slice's `Headers/`, and
# Xcode's `ProcessXCFramework` then copies that into `$BUILT_PRODUCTS_DIR/include/`. FLAT. Both app
# targets also link `ThirdParty/ghostty/libghostty.xcframework`, whose `Headers/` likewise holds a
# `module.modulemap` — so with both at their Headers root, two `ProcessXCFramework` commands write
# the same `include/module.modulemap` and Xcode refuses the graph:
#
#     error: Multiple commands produce '…/Build/Products/Debug/include/module.modulemap'
#
# Neither app built, on either platform, from the moment this xcframework joined the graph. Nothing
# caught it: `swift build` and `swift test` never process an xcframework this way, and the two
# gates that DO build the apps (`slopdesk-guigate macos`, `check-ios.sh`) are reachable from no
# `make` target and no hook.
#
# Nesting under `CSlopDeskFFI/` gives the copy a unique destination. SwiftPM still resolves the
# module — it walks the whole Headers tree for a `module.modulemap` rather than only its root
# (verified: `swift build` green, and the macOS app that could not build now does). The staging
# directory is built here rather than committed as `rust/slopdesk-ffi/include/CSlopDeskFFI/`,
# because `include/` is a normal C include root for the crate's own consumers and `#include
# "slopdesk_ffi.h"` should keep working there.
HEADER_STAGE="${OUT_DIR}/.headers"
rm -rf "${HEADER_STAGE}"
mkdir -p "${HEADER_STAGE}/CSlopDeskFFI"
cp "${HEADERS}"/* "${HEADER_STAGE}/CSlopDeskFFI/"
[[ -f "${HEADER_STAGE}/CSlopDeskFFI/module.modulemap" ]] ||
  fail "staged headers have no module.modulemap — Swift would not see CSlopDeskFFI at all"

# ── The three slices build CONCURRENTLY, each into its own target directory ────────────────────
#
# The separate directories are the point, not the parallelism. Cargo takes an exclusive lock on a
# target directory, so three `cargo build --target …` invocations sharing one merely queue behind
# each other — measured on one edit to a wrapped crate: 70 s serial, 55 s backgrounded onto the
# shared directory, 25 s with a directory each. The headroom exists because a release build of this
# graph is mostly SERIAL: `lto = "fat"` is single-threaded, so one slice never occupies much more
# than one of this machine's ten cores.
#
# They live under `target/`, which the stamp already prunes and `.gitignore` already covers, and
# they are small — one triple's release artifacts and nothing else.
slice_dir() { printf '%s/target/ffi/%s' "${CRATE}" "$1"; }

LOG_DIR="$(mktemp -d -t build-ffi)"
trap 'rm -rf "${LOG_DIR}"' EXIT

PIDS=()
for target in "${TARGETS[@]}"; do
  log "building ${target}"
  (cd "${CRATE}" && CARGO_TARGET_DIR="$(slice_dir "${target}")" \
    cargo build --release --target "${target}" --quiet) > "${LOG_DIR}/${target}" 2>&1 &
  PIDS+=($!)
done

# `wait` on each KNOWN pid: a bare `wait` yields zero however the jobs died, and this script would
# then assemble an xcframework out of whatever archives happened to survive. Every slice is waited
# on before the first failure is reported, so a doomed run does not leave two compilers racing the
# tree the next command is about to edit.
BUILD_FAILED=()
for index in "${!TARGETS[@]}"; do
  wait "${PIDS[index]}" || BUILD_FAILED+=("${TARGETS[index]}")
  if [[ -s "${LOG_DIR}/${TARGETS[index]}" ]]; then
    {
      printf '── %s ──\n' "${TARGETS[index]}"
      cat "${LOG_DIR}/${TARGETS[index]}"
    } >&2
  fi
done
[[ "${#BUILD_FAILED[@]}" -eq 0 ]] || fail "cargo build failed for ${BUILD_FAILED[*]}"

CREATE_ARGS=()
for target in "${TARGETS[@]}"; do
  archive="$(slice_dir "${target}")/${target}/release/${LIB_NAME}"
  [[ -f "${archive}" ]] || fail "expected ${archive} — did [lib] crate-type lose 'staticlib'?"

  # The header is a promise; this is where it is kept. A missing symbol here means the header and
  # `src/lib.rs` disagree, which the compiler cannot notice because they are different languages.
  # `grep -c`, never `grep -q`: under `set -o pipefail` a `-q` exits at the first match and the
  # SIGPIPE fails `nm`, so a symbol that IS present reports as missing. The count consumes the
  # whole stream and only the number decides.
  # `--print-armap`, not a plain `nm`: with `lto = "fat"` the archive members are LLVM bitcode
  # from RUSTC's LLVM, which Xcode's older `nm` refuses to parse ("Unknown attribute kind"), so a
  # plain read reports every symbol absent. The armap is the archive INDEX — what the linker
  # resolves against — which is both readable and the more exact question to ask.
  #
  # Both directions are answered by `comm` over two SORTED SETS, and that is a fix rather than a
  # tidy-up. The first draft asked the question 776 times per slice — one `grep -c` over the whole
  # armap per declared symbol, 2328 subshells for the three slices, 20 s of this script's ~40 s.
  # It was also WEAKER: `grep -c -- _slopdesk_ws_min` counts `_slopdesk_ws_min_leaf`, so a door
  # renamed to a longer name kept passing. Line-exact set difference is both instant and stricter.
  symbols="$(nm --print-armap "${archive}" 2> /dev/null || true)"
  exported="$(printf '%s\n' "${symbols}" | grep -oE '_slopdesk_[a-z0-9_]+' | sort -u || true)"
  declared="$(printf '%s\n' "${REQUIRED_SYMBOLS[@]}" | sort -u)"

  # On a slice that is not macOS, a macOS-only door is not declared — and the OTHER direction of the
  # bijection below then requires it to be absent from the library too, which is the half that
  # catches a `cfg` that stopped matching the header.
  if [[ "${target}" != "aarch64-apple-darwin" && "${#MACOS_ONLY_SYMBOLS[@]}" -gt 0 ]]; then
    declared="$(comm -23 <(printf '%s\n' "${declared}") <(printf '%s\n' "${MACOS_ONLY_SYMBOLS[@]}" | sort -u))"
  fi

  absent=$(comm -13 <(printf '%s\n' "${exported}") <(printf '%s\n' "${declared}") || true)
  if [[ -n "${absent}" ]]; then
    printf '%s\n' "${absent}" >&2
    fail "${target}: slopdesk_ffi.h declares a symbol the library does not export — the header and src/lib.rs disagree"
  fi

  # And the other direction, which nothing asked until now. A `slopdesk_*` symbol the library
  # EXPORTS but the header never declares is not a link error — it is a door with no handle: the
  # port shipped, it costs its bytes in a 37 MB archive, and no Swift line can reach it. That is
  # the shape a half-finished port leaves behind, and it is invisible to both compilers, since
  # rustc sees a `pub extern "C"` item as used-by-definition and Swift never hears of it.
  # Measured at the time this was written: 784 declared, 784 exported, an exact bijection. This
  # keeps it exact rather than discovering later how far it drifted.
  # Both sides carry the leading underscore `REQUIRED_SYMBOLS` is built with: `comm` compares
  # lines, so feeding it one stripped list and one prefixed list does not report everything —
  # it reports whatever the two sort orders happen to interleave, which is worse than a clear
  # failure and is exactly what the first draft of this check did.
  undeclared=$(comm -23 <(printf '%s\n' "${exported}") <(printf '%s\n' "${declared}") || true)
  if [[ -n "${undeclared}" ]]; then
    printf '%s\n' "${undeclared}" >&2
    fail "${target}: the library exports a slopdesk_* symbol slopdesk_ffi.h never declares — a door Swift cannot open (docs/55)"
  fi

  CREATE_ARGS+=(-library "${archive}" -headers "${HEADER_STAGE}")
done

mkdir -p "${OUT_DIR}"
rm -rf "${XCFRAMEWORK}"
xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "${XCFRAMEWORK}" > /dev/null ||
  fail "xcodebuild -create-xcframework failed"
rm -rf "${HEADER_STAGE}"

# The nesting is the whole reason both apps build; assert it rather than trust the copy above.
for slice in "${XCFRAMEWORK}"/*/; do
  [[ -d "${slice}Headers" ]] || continue
  [[ -f "${slice}Headers/CSlopDeskFFI/module.modulemap" ]] ||
    fail "${slice} has no Headers/CSlopDeskFFI/module.modulemap"
  [[ ! -f "${slice}Headers/module.modulemap" ]] ||
    fail "${slice} has a modulemap at its Headers ROOT — it will collide with libghostty's in \$BUILT_PRODUCTS_DIR/include and neither app will build"
done

# Stamped LAST, so an interrupted build leaves the artifact stale rather than falsely fresh.
printf '%s\n' "${WANT}" > "${STAMP}"
log "assembled ${XCFRAMEWORK} (${#TARGETS[@]} slices)"

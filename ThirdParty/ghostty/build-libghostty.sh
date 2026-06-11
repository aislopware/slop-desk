#!/usr/bin/env bash
#
# build-libghostty.sh — reproducible, hermetic-ish build of libghostty.xcframework
# for Aislopdesk (the ONLY terminal renderer — libghostty-only, no SwiftTerm, no fallback).
#
# WHAT IT DOES (idempotent, re-runnable with no manual cleanup):
#   1. Download the PINNED Zig toolchain into ThirdParty/ghostty/.toolchain/ (gitignored),
#      verifying the SHA-256. brew's zig 0.16.0 is too new for the fork — we never use it.
#   2. Clone the PINNED ghostty fork SHA into ThirdParty/ghostty/.work/ghostty-src (gitignored).
#   3. Generate an `xcrun` PATH-shim and run `zig build -Demit-xcframework` with the
#      build-local Zig on PATH. The shim forces Zig's native macOS SDK detection onto an
#      old SDK (see caveat #1); the zig build runs the libtool steps that produce the
#      per-archive object files even though the overall build then fails at the macOS
#      app-bundle copy step (see caveat #3).
#   4. ASSEMBLE the static library OURSELVES from the libtool object files via
#      ar/ranlib (the libtool-symbol-drop bypass, caveat #3), then wrap it with
#      `xcodebuild -create-xcframework` into ThirdParty/ghostty/libghostty.xcframework.
#   5. Verify the external-IO symbols are present in the FINAL assembled library (nm)
#      and print "OK: <path>" or a precise failure.
#
# APPROACH (b): pin the daiimus fork SHA DIRECTLY. The external-IO C API
#   (ghostty_surface_write_output, write_callback/resize_callback config fields,
#   GHOSTTY_BACKEND_EXTERNAL, ghostty_surface_set_size, ghostty_surface_key/_text)
#   already exists on this branch via src/termio/External.zig (~470 LOC) + the C glue
#   in src/apprt/embedded.zig. No upstream patch to author/rebase → most reliable path
#   to the symbols. The equivalent source delta is recorded in External.zig.patch for
#   documentation / future upstream-rebase reference.
#
# ─────────────────────────────────────────────────────────────────────────────
# macOS-26.5-HOST CAVEATS (this recipe was proven on macOS 26.5 / Xcode 26.5 / arm64)
# ─────────────────────────────────────────────────────────────────────────────
#   (1) xcrun SDK SHIM — THE LEVER.
#       Zig 0.15.2 cannot link the host's default 26.5 macOS SDK (undefined
#       __availability_version_check / _abort / _bzero — it predates the 26.x
#       libSystem layout). The build.zig runner compiles natively against whatever
#       `xcrun --sdk macosx --show-sdk-path` returns. SDKROOT / --sysroot alone do
#       NOT fix this. The fix is a PATH-shim that intercepts ONLY the macosx
#       `--show-sdk-path` / `--show-sdk-version` queries and answers with an
#       OLD SDK (<= 15.x). iOS / sim / tvOS / watchOS queries pass through to the
#       real xcrun untouched. Parameterized below as MACOS_SDK_SHIM_PATH
#       (default /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk).
#   (2) METAL TOOLCHAIN required.
#       The fork compiles Metal shaders (Ghostty.metallib). Without the Metal
#       Toolchain the libtool step never runs:
#         "cannot execute tool 'metal' due to missing Metal Toolchain"
#       Install once with:  xcodebuild -downloadComponent MetalToolchain
#       Preflight below checks for it and prints this instruction if absent.
#   (3) Xcode-26.5 libtool DROPS the Zig root object (libtool BYPASS).
#       `zig build -Demit-xcframework` emits a GhosttyKit.xcframework, but Xcode
#       26.5's `libtool -static` silently drops the Zig compilation unit
#       (libghostty_zcu.o — it carries ALL ~123 ghostty_* C-API symbols; libtool
#       warns "member 'libghostty_zcu.o' not 8-byte aligned"). The fork's own
#       emitted GhosttyKit.xcframework is therefore DEFECTIVE (0 ghostty_* symbols).
#       Worse, the overall `zig build` then FAILS (RC != 0) at the macOS app-bundle
#       CpResource step — so we CANNOT trust its exit code. Instead we harvest the
#       two GOOD intermediate libtool archives the build leaves behind:
#         A) macos/build/ReleaseLocal/libghostty-fat.a  — the C/C++ dependency objects
#         B) .zig-cache/o/<hash>/libghostty.a           — the 8 Zig objects incl.
#                                                          libghostty_zcu.o
#       We extract both, re-archive with ar/ranlib (chmod first — Zig stores members
#       mode 0000; the B-set is prefixed `zig_` to avoid base64.o/compiler_rt.o
#       name collisions with the A-set), then `xcodebuild -create-xcframework`.
#   (4) iOS slice builds against the host's 26.5 iOS SDK — NO iOS<=18 SDK needed.
#       XCFRAMEWORK_TARGET=universal adds ios-arm64 device + ios-arm64 simulator. The
#       caveat-#1 SDK-link wall is a LINK-time failure; an xcframework slice is a STATIC
#       ARCHIVE with NO final link step, so Zig 0.15.2 cross-compiles iOS objects against
#       the installed iOS 26.5 SDK cleanly (proven on this host — all 3 slices compiled,
#       every ghostty_* C-API symbol present after the per-slice re-merge). The shim is
#       NOT extended for iphoneos: iOS queries pass through to the real 26.5 SDK on purpose.
#       The macosx shim (caveat #1) is STILL needed — the build.zig RUNNER links natively.
#       (Earlier belief that iOS needed an SDK<=18 was wrong: that was inferred from the
#       macOS *executable* link wall and never tested for a static iOS slice.)
#
# USAGE:
#   ThirdParty/ghostty/build-libghostty.sh            # macOS arm64 native slice (fast first cut)
#   XCFRAMEWORK_TARGET=universal ThirdParty/ghostty/build-libghostty.sh   # + iOS device + sim (needs iOS<=18 SDK)
#   MACOS_SDK_SHIM_PATH=/path/to/MacOSX15.4.sdk ...   # override the old-SDK the shim points at
#   ZIG_BUILD_TIMEOUT_SECS=1800 ...                   # cap the zig build wall clock
#
# Pins are declared below; bump them deliberately (and re-verify the header) when
# updating the renderer.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# PINS — change deliberately; see ThirdParty/ghostty/README.md.
# ─────────────────────────────────────────────────────────────────────────────
# SOURCE = canonical upstream ghostty @ a pinned TAG + the aislopdesk "fork-delta" patch
# (the daiimus external-backend fork: External.zig + tmux control-mode viewer + search + the
# embedded C glue, rebased onto the tag) + aislopdesk patches 0001/0002 (§2b). This is REPRODUCIBLE
# against canonical upstream — no dependency on the daiimus fork remaining available at build
# time. §2 uses an already-prepared .work/ghostty-src tree as-is when present (sentinel check),
# else clones the tag and applies the fork-delta patch. See README "Chosen fork + pins".
GHOSTTY_UPSTREAM_REPO="https://github.com/ghostty-org/ghostty.git"  # canonical upstream
GHOSTTY_TAG="v1.3.1"                                                # pinned upstream tag
# Provenance of the fork delta (NOT cloned at build time; recorded for rebase reference):
GHOSTTY_FORK_REPO="https://github.com/daiimus/ghostty.git"          # external-backend fork
GHOSTTY_FORK_SHA="21c717340b62349d67124446c2447bf38796540b"         # fork delta source (= v1.3.0 + ext backend)

ZIG_VERSION="0.15.2"                                  # build.zig.zon minimum_zig_version
ZIG_ARCH="aarch64"                                    # Apple Silicon host
ZIG_TARBALL="zig-${ZIG_ARCH}-macos-${ZIG_VERSION}.tar.xz"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"
ZIG_SHA256="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"

# XCFRAMEWORK_TARGET: "native" (macOS host arch only — fast) or "universal"
# (macOS universal + ios arm64 device + ios arm64 sim). Default: native first cut.
XCFRAMEWORK_TARGET="${XCFRAMEWORK_TARGET:-native}"

# Wall-clock cap for the actual `zig build` step (seconds). Default 1800 (30 min).
ZIG_BUILD_TIMEOUT_SECS="${ZIG_BUILD_TIMEOUT_SECS:-1800}"

# Old macOS SDK the xcrun shim points Zig at (caveat #1). Zig 0.15.2 cannot link
# the host's 26.5 SDK; <= 15.x works. Default is the stable MacOSX15.sdk symlink
# shipped by the Command Line Tools (resolves to e.g. MacOSX15.4.sdk).
MACOS_SDK_SHIM_PATH="${MACOS_SDK_SHIM_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk}"

# ─────────────────────────────────────────────────────────────────────────────
# Paths (all absolute, derived from this script's location).
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="${SCRIPT_DIR}/.toolchain"
WORK_DIR="${SCRIPT_DIR}/.work"
SRC_DIR="${WORK_DIR}/ghostty-src"
FORKDELTA_PATCH="${SCRIPT_DIR}/aislopdesk-libghostty-on-v1.3.1.patch"   # fork delta vs upstream GHOSTTY_TAG
ZIG_DIR="${TOOLCHAIN_DIR}/zig-${ZIG_ARCH}-macos-${ZIG_VERSION}"
ZIG_BIN="${ZIG_DIR}/zig"
ZIG_GLOBAL_CACHE="${WORK_DIR}/zig-global-cache"       # keep deps out of ~/.cache
SHIM_DIR="${WORK_DIR}/bin"                            # holds the generated xcrun shim
ASSEMBLE_DIR="${WORK_DIR}/assemble"                  # scratch for ar extract/re-archive
OUT_DIR="${WORK_DIR}/out"                            # staging for the final fat.a + xcframework
OUT_XCFRAMEWORK="${SCRIPT_DIR}/libghostty.xcframework"

log()  { printf '\033[1;34m[build-libghostty]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[build-libghostty] %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m[build-libghostty] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────────────────────
log "host: $(uname -sm), target=${XCFRAMEWORK_TARGET}, zig-pin=${ZIG_VERSION}, ghostty-pin=${GHOSTTY_TAG}+fork-delta"
[ "$(uname -s)" = "Darwin" ] || fail "must build on macOS (xcframework + Apple SDK required)."
command -v curl >/dev/null  || fail "curl not found."
command -v shasum >/dev/null || fail "shasum not found."
command -v git >/dev/null    || fail "git not found."
command -v ar >/dev/null     || fail "ar not found (Command Line Tools)."
command -v ranlib >/dev/null || fail "ranlib not found (Command Line Tools)."
command -v xcodebuild >/dev/null || fail "xcodebuild not found (full Xcode required for -create-xcframework)."

mkdir -p "${TOOLCHAIN_DIR}" "${WORK_DIR}" "${ZIG_GLOBAL_CACHE}" "${SHIM_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# 0a. PREFLIGHT: old macOS SDK for the xcrun shim (caveat #1).
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -d "${MACOS_SDK_SHIM_PATH}" ]; then
    AVAIL="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX1*.sdk 2>/dev/null | tr '\n' ' ')"
    fail "old macOS SDK not found at MACOS_SDK_SHIM_PATH=${MACOS_SDK_SHIM_PATH}. \
Zig ${ZIG_VERSION} cannot link the host's 26.x SDK (caveat #1) — it needs an SDK <= 15.x. \
Installed CLT SDKs: ${AVAIL:-<none>}. Install the Command Line Tools that ship a 15.x SDK \
(or point MACOS_SDK_SHIM_PATH at one), e.g. MacOSX15.4.sdk."
fi
log "xcrun shim will point Zig's macosx SDK at: ${MACOS_SDK_SHIM_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# 0b. PREFLIGHT: Metal Toolchain (caveat #2). Without it the libtool step never runs.
# ─────────────────────────────────────────────────────────────────────────────
if /usr/bin/xcrun --sdk macosx --find metal >/dev/null 2>&1; then
    log "preflight OK: Metal Toolchain present ($(/usr/bin/xcrun --sdk macosx --find metal))."
else
    fail "Metal Toolchain NOT installed — the fork compiles Metal shaders (Ghostty.metallib) \
and the build fails with \"cannot execute tool 'metal'\" without it (caveat #2). Install it with:

    xcodebuild -downloadComponent MetalToolchain

then re-run this script (it is idempotent)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. Pinned Zig toolchain (download + verify SHA-256, skip if already good)
# ─────────────────────────────────────────────────────────────────────────────
if [ -x "${ZIG_BIN}" ] && "${ZIG_BIN}" version 2>/dev/null | grep -qx "${ZIG_VERSION}"; then
    log "zig ${ZIG_VERSION} already present at ${ZIG_BIN}"
else
    TARBALL_PATH="${TOOLCHAIN_DIR}/${ZIG_TARBALL}"
    if [ ! -f "${TARBALL_PATH}" ]; then
        log "downloading ${ZIG_URL}"
        curl -fL --retry 3 -o "${TARBALL_PATH}.tmp" "${ZIG_URL}" \
            || fail "could not download Zig ${ZIG_VERSION} (network blocked? URL changed?). URL: ${ZIG_URL}"
        mv "${TARBALL_PATH}.tmp" "${TARBALL_PATH}"
    fi
    log "verifying SHA-256 of ${ZIG_TARBALL}"
    GOT_SHA="$(shasum -a 256 "${TARBALL_PATH}" | awk '{print $1}')"
    if [ "${GOT_SHA}" != "${ZIG_SHA256}" ]; then
        rm -f "${TARBALL_PATH}"
        fail "Zig tarball SHA mismatch. expected=${ZIG_SHA256} got=${GOT_SHA} (corrupt download or wrong pin)."
    fi
    log "extracting Zig"
    rm -rf "${ZIG_DIR}"
    tar -xf "${TARBALL_PATH}" -C "${TOOLCHAIN_DIR}"
    [ -x "${ZIG_BIN}" ] || fail "extracted Zig has no executable at ${ZIG_BIN} (tarball layout changed?)."
fi
ACTUAL_ZIG_VER="$("${ZIG_BIN}" version)"
log "using zig ${ACTUAL_ZIG_VER} at ${ZIG_BIN}"
[ "${ACTUAL_ZIG_VER}" = "${ZIG_VERSION}" ] || fail "zig version drift: have ${ACTUAL_ZIG_VER}, pinned ${ZIG_VERSION}."

# ─────────────────────────────────────────────────────────────────────────────
# 1b. Generate the xcrun PATH-shim (caveat #1) and PREFLIGHT that the pinned Zig
#     can link the macOS SDK *through the shim*. The shim intercepts ONLY the
#     macosx `--show-sdk-path` / `--show-sdk-version` queries and answers with the
#     old SDK; iOS / sim / tvOS / watchOS queries pass through to the real xcrun.
#     Without the shim Zig 0.15.2 fails to link the host's 26.x SDK (undefined
#     __availability_version_check / _abort / _bzero) — SDKROOT alone does not help.
# ─────────────────────────────────────────────────────────────────────────────
SHIM_XCRUN="${SHIM_DIR}/xcrun"
SDK_SHIM_VER="$(basename "$(readlink "${MACOS_SDK_SHIM_PATH}" 2>/dev/null || echo "${MACOS_SDK_SHIM_PATH}")" | sed -E 's/^MacOSX([0-9.]+)\.sdk$/\1/')"
[ -n "${SDK_SHIM_VER}" ] || SDK_SHIM_VER="15.4"
log "generating xcrun shim at ${SHIM_XCRUN} (macosx SDK -> ${MACOS_SDK_SHIM_PATH}, version ${SDK_SHIM_VER})"
cat > "${SHIM_XCRUN}" <<SHIM
#!/bin/bash
# GENERATED by build-libghostty.sh — DO NOT EDIT (regenerated every run).
# Forces Zig's native macOS SDK detection onto an old SDK that Zig ${ZIG_VERSION}
# can link (caveat #1). Everything that is not a macosx SDK-path/version query
# passes through to the real /usr/bin/xcrun untouched.
SDK_PATH="${MACOS_SDK_SHIM_PATH}"
SDK_VERSION="${SDK_SHIM_VER}"
args="\$*"
case "\$args" in
  *"--show-sdk-path"*)
    case "\$args" in
      *iphoneos*|*iphonesimulator*|*appletvos*|*appletvsimulator*|*watchos*|*watchsimulator*|*xros*|*xrsimulator*)
        exec /usr/bin/xcrun "\$@" ;;   # leave non-macOS SDKs to the real xcrun
      *)
        echo "\$SDK_PATH"; exit 0 ;;
    esac ;;
  *"--show-sdk-version"*)
    case "\$args" in
      *iphoneos*|*iphonesimulator*|*appletvos*|*appletvsimulator*|*watchos*|*watchsimulator*|*xros*|*xrsimulator*)
        exec /usr/bin/xcrun "\$@" ;;
      *)
        echo "\$SDK_VERSION"; exit 0 ;;
    esac ;;
  *)
    exec /usr/bin/xcrun "\$@" ;;
esac
SHIM
chmod +x "${SHIM_XCRUN}"

# Self-test the shim before trusting it.
GOT_SDK_PATH="$(PATH="${SHIM_DIR}:${PATH}" xcrun --sdk macosx --show-sdk-path)"
[ "${GOT_SDK_PATH}" = "${MACOS_SDK_SHIM_PATH}" ] || fail "xcrun shim self-test failed: --show-sdk-path returned '${GOT_SDK_PATH}', expected '${MACOS_SDK_SHIM_PATH}'."
log "xcrun shim self-test OK (macosx --show-sdk-path -> ${GOT_SDK_PATH})."

SDK_VER="$(/usr/bin/xcrun --show-sdk-version 2>/dev/null || echo unknown)"
SMOKE_DIR="${WORK_DIR}/zig-smoke"; mkdir -p "${SMOKE_DIR}"
printf 'const std=@import("std");\npub fn main() void { std.debug.print("ok\\n", .{}); }\n' > "${SMOKE_DIR}/smoke.zig"
log "preflight: testing whether zig ${ZIG_VERSION} can link via the shim (host SDK is ${SDK_VER})"
if ! PATH="${SHIM_DIR}:${PATH}" "${ZIG_BIN}" run --global-cache-dir "${ZIG_GLOBAL_CACHE}" "${SMOKE_DIR}/smoke.zig" >"${SMOKE_DIR}/smoke.out" 2>&1; then
    echo "---- zig smoke link output ----" >&2; sed 's/^/    /' "${SMOKE_DIR}/smoke.out" >&2
    fail "pinned Zig ${ZIG_VERSION} CANNOT LINK even through the SDK shim (${MACOS_SDK_SHIM_PATH}). \
The shimmed SDK may be too new/too old, or the Command Line Tools are misconfigured. \
Point MACOS_SDK_SHIM_PATH at a known-good SDK <= 15.x (caveat #1)."
fi
log "preflight OK: zig ${ZIG_VERSION} links via the shim (SDK ${MACOS_SDK_SHIM_PATH})."

# ─────────────────────────────────────────────────────────────────────────────
# 2. Source = upstream ghostty @ GHOSTTY_TAG + fork-delta patch (reproducible).
#    Sentinel: a prepared tree already carries src/termio/External.zig (the fork's
#    external backend) AND the 0002 `queueWriteLocked` fix in Termio.zig. If both are
#    present, USE THE TREE AS-IS (don't clobber a hand-prepared / mid-rebase tree).
#    Otherwise clone the pinned upstream tag and apply the consolidated fork delta;
#    §2b then layers the small ordered aislopdesk patches (0001/0002).
# ─────────────────────────────────────────────────────────────────────────────
if [ -f "${SRC_DIR}/src/termio/External.zig" ] \
   && grep -q "queueWriteLocked" "${SRC_DIR}/src/termio/Termio.zig" 2>/dev/null; then
    log "using prepared source tree at ${SRC_DIR} (HEAD $(git -C "${SRC_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?'))"
else
    log "preparing source: clone ${GHOSTTY_UPSTREAM_REPO} @ ${GHOSTTY_TAG} + apply ${FORKDELTA_PATCH##*/}"
    [ -f "${FORKDELTA_PATCH}" ] || fail "missing fork-delta patch: ${FORKDELTA_PATCH}"
    rm -rf "${SRC_DIR}"
    git clone --depth 1 --branch "${GHOSTTY_TAG}" "${GHOSTTY_UPSTREAM_REPO}" "${SRC_DIR}" \
        || fail "git clone of upstream ${GHOSTTY_TAG} failed (network blocked?)."
    git -C "${SRC_DIR}" apply --whitespace=nowarn "${FORKDELTA_PATCH}" \
        || fail "fork-delta patch ${FORKDELTA_PATCH##*/} did not apply to ${GHOSTTY_TAG} (tag/patch drift — regenerate)."
    log "fork delta applied onto ${GHOSTTY_TAG} (external backend + tmux viewer + search + C glue)."
fi

# Confirm the external-IO symbols are actually present in the source header before
# spending 25 min compiling — fail fast otherwise.
HDR="${SRC_DIR}/include/ghostty.h"
[ -f "${HDR}" ] || fail "missing ${HDR} in source."
for sym in ghostty_surface_write_output ghostty_write_callback_fn GHOSTTY_BACKEND_EXTERNAL ghostty_surface_set_size; do
    grep -q "${sym}" "${HDR}" || fail "expected external-IO symbol '${sym}' not in ${HDR} (wrong SHA?)."
done
log "external-IO symbols confirmed in source header."

# Confirm the source's pinned Zig requirement matches our toolchain.
if grep -q "minimum_zig_version" "${SRC_DIR}/build.zig.zon"; then
    REQ_ZIG="$(grep "minimum_zig_version" "${SRC_DIR}/build.zig.zon" | sed -E 's/.*"([0-9.]+)".*/\1/')"
    log "source requires zig >= ${REQ_ZIG}; pinned toolchain = ${ZIG_VERSION}"
    [ "${REQ_ZIG}" = "${ZIG_VERSION}" ] || log "NOTE: pin (${ZIG_VERSION}) differs from source minimum (${REQ_ZIG}); proceeding (>= satisfied)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2b. Apply Aislopdesk's local libghostty patches (idempotent).
#
#   patches/0001-aislopdesk-sync-updateframe-in-draw.patch — makes core Surface.draw()
#   run renderer.updateFrame() synchronously BEFORE drawFrame(), so a synchronous
#   `ghostty_surface_draw` rebuilds the cell buffer on the CALLING (app) thread.
#   Without it the only cell-rebuild path is the renderer thread's libxev `wakeup`
#   async, which is NOT pumped after the initial startup notify on the iOS
#   Simulator — so the terminal paints only a background with no glyphs. With the
#   patch the Simulator renders correctly; it is harmless (idempotent rebuild)
#   on device and macOS. updateFrame locks renderer_state.mutex internally.
# ─────────────────────────────────────────────────────────────────────────────
PATCH_DIR="${SCRIPT_DIR}/patches"
if [ -d "${PATCH_DIR}" ]; then
  for p in "${PATCH_DIR}"/*.patch; do
    [ -f "${p}" ] || continue
    if git -C "${SRC_DIR}" apply --reverse --check "${p}" >/dev/null 2>&1; then
      log "patch already applied: $(basename "${p}")"
    elif git -C "${SRC_DIR}" apply --check "${p}" >/dev/null 2>&1; then
      git -C "${SRC_DIR}" apply "${p}" && log "applied patch: $(basename "${p}")"
    else
      log "WARN: patch does not apply cleanly (skipping): $(basename "${p}")"
    fi
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Build with the build-local Zig + the xcrun shim on PATH.
#
#    IMPORTANT (caveat #3): `zig build -Demit-xcframework` runs the libtool steps
#    that produce the GOOD intermediate archives we harvest, but then FAILS (RC != 0)
#    at the macOS app-bundle CpResource stage. So we do NOT trust the exit code — we
#    verify the intermediate archives exist afterwards instead. The shim MUST be ahead
#    of the real /usr/bin on PATH so the build.zig runner sees the old macosx SDK.
# ─────────────────────────────────────────────────────────────────────────────
export PATH="${SHIM_DIR}:${ZIG_DIR}:${PATH}"
ZIG_FLAGS=( "build"
    "-Demit-xcframework=true"
    "-Dxcframework-target=${XCFRAMEWORK_TARGET}"
    "-Doptimize=ReleaseFast"
    "--global-cache-dir" "${ZIG_GLOBAL_CACHE}"
    "--prefix" "${WORK_DIR}/zig-out"
)
log "zig ${ZIG_FLAGS[*]}  (timeout ${ZIG_BUILD_TIMEOUT_SECS}s; first run also fetches ~15 zig deps)"
log "NOTE: a non-zero exit at the app-bundle/CpResource stage is EXPECTED (caveat #3); we harvest the libtool archives regardless."

# Bounded wall clock: prefer GNU/coreutils timeout if present, else a watchdog.
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null; then
        timeout --signal=TERM "${secs}s" "$@"
    elif command -v gtimeout >/dev/null; then
        gtimeout --signal=TERM "${secs}s" "$@"
    else
        # portable watchdog
        "$@" & local pid=$!
        ( sleep "${secs}"; kill -TERM "${pid}" 2>/dev/null ) & local wd=$!
        wait "${pid}"; local rc=$?
        kill "${wd}" 2>/dev/null || true
        return "${rc}"
    fi
}

set +e
( cd "${SRC_DIR}" && run_with_timeout "${ZIG_BUILD_TIMEOUT_SECS}" "${ZIG_BIN}" "${ZIG_FLAGS[@]}" )
BUILD_RC=$?
set -e
if [ "${BUILD_RC}" -eq 124 ]; then
    fail "zig build exceeded ${ZIG_BUILD_TIMEOUT_SECS}s wall clock and was killed (TIME-BOX). Re-run to resume — deps + caches persist under ${WORK_DIR}."
fi
[ "${BUILD_RC}" -eq 0 ] && log "zig build exited 0." || log "zig build exited ${BUILD_RC} (expected — app-bundle stage; harvesting libtool archives, caveat #3)."

# ─────────────────────────────────────────────────────────────────────────────
# 4. ASSEMBLE the static library/-ies OURSELVES (the libtool-symbol-drop bypass,
#    caveat #3). Xcode-26.5 `libtool -static` drops the Zig root object
#    (libghostty_zcu.o — carries ALL ghostty_* C-API symbols) from EVERY emitted
#    slice, so the fork's GhosttyKit.xcframework slices are DEFECTIVE (only 4
#    ghostty_* symbols, no ghostty_surface_write_output). We re-merge each slice's
#    deps archive with its matching Zig root harvested from .zig-cache.
#
#    NATIVE target  → one macos-arm64 slice:
#      Source A (deps): macos/build/ReleaseLocal/libghostty-fat.a (C/C++ deps).
#      Source B (zig):  the .zig-cache/o/<hash>/libghostty.a that DEFINES the C-API
#                       canary (identified by content).
#    UNIVERSAL target → macos-arm64 + ios-arm64 + ios-arm64-simulator (arm64-only;
#      Intel macOS is EOL here, the app pins ARCHS=arm64). Each slice is the COMPLETE
#      dependency closure: GhosttyKit <slice> deps + the platform-matched Zig root +
#      EVERY standalone per-dependency lib (libdcimgui/libfreetype/libglslang/…/libmacos)
#      that the fork's per-slice libtool merge DROPS. (The emitted GhosttyKit slices ship
#      only ~142 of ~280 objects → 653 undefined symbols at app-link without the re-add.)
#      Zig roots are classified by the Mach-O platform of libghostty_zcu.o (otool
#      LC_BUILD_VERSION: 1=macOS, 2=iOS device, 7=iOS simulator); dep libs are picked
#      platform-matched-or-portable so create-xcframework sees one platform per slice.
#      The iOS slices build against the host's iOS 26.5 SDK: a STATIC archive has no final
#      link step, so the 26.x-SDK link wall that blocks macOS *executables* (caveat #1) does
#      NOT apply — VALIDATED: both macOS and iOS app targets compile + LINK the renderer
#      (no iOS<=18 SDK needed; caveat #4 is obsolete).
#
#    Zig stores .a members mode 0000 → chmod u+rw before ar/ranlib. Zig-root members
#    are `zig_`-prefixed to avoid base64.o/compiler_rt.o/codepoint_width.o collisions
#    with the deps members. Final archives = deps + zig_-prefixed root, ar qc + ranlib.
# ─────────────────────────────────────────────────────────────────────────────
GK="${SRC_DIR}/macos/GhosttyKit.xcframework"        # the fork's emitted xcframework
ZC="${SRC_DIR}/.zig-cache"
HARVEST="${WORK_DIR}/harvest"
rm -rf "${HARVEST}" "${OUT_DIR}"; mkdir -p "${HARVEST}" "${OUT_DIR}"

# Re-merge one thin static lib = (deps members) + (zig-root members, zig_-prefixed).
#   merge_thin <out.a> <deps-archive> <deps-arch|''> <root-archive> <root-arch|''>
merge_thin() {
    local out="$1" deps="$2" deps_arch="$3" root="$4" root_arch="$5"
    local d depsthin rootthin m
    d="${HARVEST}/build-$(basename "${out}" .a)"
    rm -rf "${d}"; mkdir -p "${d}/deps" "${d}/root"
    depsthin="${deps}"
    [ -n "${deps_arch}" ] && { depsthin="${d}/deps.a"; lipo "${deps}" -thin "${deps_arch}" -output "${depsthin}"; }
    ( cd "${d}/deps" && ar x "${depsthin}" && rm -f __.SYMDEF '__.SYMDEF SORTED' )
    chmod -R u+rw "${d}/deps"
    rootthin="${root}"
    [ -n "${root_arch}" ] && { rootthin="${d}/root.a"; lipo "${root}" -thin "${root_arch}" -output "${rootthin}"; }
    ( cd "${d}/root" && ar x "${rootthin}" && rm -f __.SYMDEF '__.SYMDEF SORTED' )
    chmod -R u+rw "${d}/root"
    for m in "${d}/root"/*.o; do [ -e "${m}" ] || continue; mv "${m}" "${d}/root/zig_$(basename "${m}")"; done
    rm -f "${out}"
    ar qc "${out}" "${d}/deps"/*.o "${d}/root"/zig_*.o
    ranlib "${out}"
}

# Mach-O platform number (LC_BUILD_VERSION) of an archive's libghostty_zcu.o for <arch>.
root_platform() {  # <archive> <arch>
    local a="$1" arch="$2" tmp thin
    tmp="${HARVEST}/cls-$$-${RANDOM}"; rm -rf "${tmp}"; mkdir -p "${tmp}"
    thin="${a}"
    if [ "$(lipo -archs "${a}" 2>/dev/null | wc -w)" -gt 1 ]; then
        thin="${tmp}/thin.a"; lipo "${a}" -thin "${arch}" -output "${thin}" 2>/dev/null || { rm -rf "${tmp}"; return 1; }
    fi
    ( cd "${tmp}" && ar x "${thin}" libghostty_zcu.o 2>/dev/null ) || true
    [ -f "${tmp}/libghostty_zcu.o" ] || { rm -rf "${tmp}"; return 1; }
    chmod u+rw "${tmp}/libghostty_zcu.o"
    otool -l "${tmp}/libghostty_zcu.o" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}'
    rm -rf "${tmp}"
}

# Platform of an arbitrary archive = its first stamped object's platform (blank = portable
# / unstamped). Zig stores members mode 0000 → chmod before otool.
arch_plat() {  # <archive>
    local a="$1" tmp o p; tmp="${HARVEST}/ap-$$-${RANDOM}"; rm -rf "${tmp}"; mkdir -p "${tmp}"
    ( cd "${tmp}" && ar x "${a}" 2>/dev/null ) || true; chmod -R u+rw "${tmp}" 2>/dev/null || true
    p=""
    for o in "${tmp}"/*.o; do
        [ -e "${o}" ] || continue
        p="$(otool -l "${o}" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')"
        [ -n "${p}" ] && break
    done
    rm -rf "${tmp}"; printf '%s' "${p}"
}

# Pick the arm64 copy of <libname> that is platform <want> OR portable (unstamped). The fork
# builds each dep 4–5× (per target); the C/C++ deps are mostly unstamped + portable, but some
# (sentry/breakpad/macos) carry a platform stamp and MUST match the slice or create-xcframework
# rejects the slice as "multiple platforms".
pick_for_plat() {  # <libname-without-.a> <want-platform>
    local name="$1" want="$2" a p
    while IFS= read -r a; do
        [ "$(lipo -archs "${a}" 2>/dev/null | awk '{print $1}')" = arm64 ] || continue
        p="$(arch_plat "${a}")"
        { [ -z "${p}" ] || [ "${p}" = "${want}" ]; } && { printf '%s' "${a}"; return; }
    done < <(find "${ZC}" -name "${name}.a" 2>/dev/null)
}

# Extract <archive> into <objdir>, skipping object basenames already present, with <prefix>.
add_archive() {  # <archive> <objdir> <prefix>
    local arch="$1" dir="$2" prefix="$3" ex o b
    ex="${HARVEST}/x-$$-${RANDOM}"; rm -rf "${ex}"; mkdir -p "${ex}"
    ( cd "${ex}" && ar x "${arch}" 2>/dev/null && rm -f __.SYMDEF '__.SYMDEF SORTED' ); chmod -R u+rw "${ex}" 2>/dev/null || true
    for o in "${ex}"/*.o; do
        [ -e "${o}" ] || continue
        b="${prefix}$(basename "${o}")"; [ -e "${dir}/${b}" ] && continue
        mv "${o}" "${dir}/${b}"
    done
    rm -rf "${ex}"
}

# The standalone per-dependency libs the fork's per-slice libtool merge DROPS (it ships only
# ~142 of ~280 objects, so e.g. ALL of imgui/freetype/glslang/oniguruma/sentry are missing →
# 653 undefined symbols at app-link). We re-add them platform-matched. NOT libghostty/-fat
# (those ARE the slice). libmacos = ghostty's Apple-platform C shim (os_log etc.), built
# per-platform despite the name (its iOS copy carries zig_os_log_with_type for iOS).
DEP_LIBS="libdcimgui libfreetype libglslang libintl liboniguruma libsentry libsimdutf libspirv_cross libpng libhighway libutfcpp libz libbreakpad libmacos"

# Build one COMPLETE slice = GhosttyKit <gkslice> deps (apprt; wins on basename dups) +
# <zigroot> + every platform-<want> (or portable) standalone dep lib. Optional <thinarch>
# thins a fat GhosttyKit deps archive first. ar qc + ranlib (NO lipo — a lipo'd fat static
# archive's per-arch TOC breaks ld's lazy cross-member resolution; slices stay thin arm64).
build_slice() {  # <out.a> <zigroot> <gkslice> <want-platform> [thinarch]
    local out="$1" root="$2" gkslice="$3" want="$4" thinarch="${5:-}" dir d gkdeps a
    dir="${HARVEST}/obj-$(basename "${out}" .a)"; rm -rf "${dir}"; mkdir -p "${dir}"
    gkdeps="$(ls "${GK}/${gkslice}/"libghostty*.a 2>/dev/null | head -1)"
    [ -n "${gkdeps}" ] || fail "GhosttyKit slice deps not found: ${GK}/${gkslice}/libghostty*.a"
    if [ -n "${thinarch}" ] && [ "$(lipo -archs "${gkdeps}" 2>/dev/null | wc -w)" -gt 1 ]; then
        lipo "${gkdeps}" -thin "${thinarch}" -output "${HARVEST}/gkthin-$(basename "${out}")"
        gkdeps="${HARVEST}/gkthin-$(basename "${out}")"
    fi
    add_archive "${gkdeps}" "${dir}" ""
    add_archive "${root}" "${dir}" "zigroot_"
    for d in ${DEP_LIBS}; do
        a="$(pick_for_plat "${d}" "${want}")"
        [ -n "${a}" ] && add_archive "${a}" "${dir}" "${d}__" || log "  WARN: no platform-${want}/portable ${d} (link may be incomplete)"
    done
    rm -f "${out}"; ar qc "${out}" "${dir}"/*.o; ranlib "${out}"
}

CREATE_ARGS=()
if [ "${XCFRAMEWORK_TARGET}" = "universal" ]; then
    [ -d "${GK}" ] || fail "fork emit ${GK} not found — the universal zig build did not emit GhosttyKit.xcframework (Metal Toolchain missing, or SDK shim not on PATH?)."
    # Classify the arm64 Zig roots (those that DEFINE the C-API canary) by Mach-O platform:
    # 1=macOS, 2=iOS device, 7=iOS simulator. (pipefail-safe count; `grep -q` would SIGPIPE nm.)
    ROOT_MAC=""; ROOT_IOS_DEV=""; ROOT_IOS_SIM=""
    while IFS= read -r a; do
        [ "$(nm "${a}" 2>/dev/null | grep -c " _ghostty_surface_write_output\$" || true)" -gt 0 ] || continue
        [ "$(lipo -archs "${a}" 2>/dev/null | awk '{print $1}')" = arm64 ] || continue
        case "$(root_platform "${a}" arm64)" in
            1) [ -z "${ROOT_MAC}" ]     && ROOT_MAC="${a}" ;;
            2) [ -z "${ROOT_IOS_DEV}" ] && ROOT_IOS_DEV="${a}" ;;
            7) [ -z "${ROOT_IOS_SIM}" ] && ROOT_IOS_SIM="${a}" ;;
        esac
    done < <(find "${ZC}" -name 'libghostty.a' 2>/dev/null)
    for v in ROOT_MAC ROOT_IOS_DEV ROOT_IOS_SIM; do
        eval "rp=\${$v}"; [ -n "${rp}" ] || fail "universal harvest: could not resolve Zig root for ${v} (classify by platform failed)."
    done
    log "universal Zig roots resolved (macos arm64, ios-arm64 device, ios-arm64 simulator)"
    # Each slice = GhosttyKit deps + zig root + ALL platform-matched standalone dep libs.
    # arm64-only macOS (Intel macOS is EOL for this project; the app pins ARCHS=arm64).
    build_slice "${HARVEST}/macos-arm64.a"         "${ROOT_MAC}"     "macos-arm64_x86_64"  1 arm64
    build_slice "${HARVEST}/ios-arm64.a"           "${ROOT_IOS_DEV}" "ios-arm64"           2
    build_slice "${HARVEST}/ios-arm64-simulator.a" "${ROOT_IOS_SIM}" "ios-arm64-simulator" 7
    CREATE_ARGS=(
        -library "${HARVEST}/macos-arm64.a"         -headers "${GK}/macos-arm64_x86_64/Headers"
        -library "${HARVEST}/ios-arm64.a"           -headers "${GK}/ios-arm64/Headers"
        -library "${HARVEST}/ios-arm64-simulator.a" -headers "${GK}/ios-arm64-simulator/Headers"
    )
    MEMBER_COUNT="universal (macos-arm64 + ios-arm64 + ios-arm64-simulator, complete dep closure)"
else
    # NATIVE: the proven single macos-arm64 slice (Source A deps + Source B zig root).
    SRC_A="$(find "${SRC_DIR}/macos/build" -name 'libghostty-fat.a' -type f 2>/dev/null | head -1 || true)"
    [ -n "${SRC_A}" ] || fail "dependency archive (macos/build/.../libghostty-fat.a) not found — the libtool step did not run. Most likely the Metal Toolchain is missing (caveat #2) or the SDK shim is not on PATH. Re-check the build output above."
    log "source A (deps): ${SRC_A}"
    SRC_B=""
    while IFS= read -r cand; do
        [ -n "${cand}" ] || continue
        # pipefail-safe: `grep -q` closes the pipe on first match → SIGPIPE (141) to nm
        # → with `set -o pipefail` the pipeline returns non-zero and the match is LOST
        # (the universal path above documents the same hazard). Use `grep -c … || true`
        # so nm's whole output is consumed and only the COUNT decides the match.
        [ "$(nm "${cand}" 2>/dev/null | grep -c "ghostty_surface_write_output" || true)" -gt 0 ] || continue
        # Must be the arm64 macOS root (LC_BUILD_VERSION platform 1). The local .zig-cache
        # can ALSO hold STALE iOS-device(2)/iOS-sim(7) roots from a prior universal build;
        # picking one of those makes the assembled fat archive multi-platform and
        # `create-xcframework` rejects it ("binaries with multiple platforms"). Mirror the
        # universal path's platform classification so the native slice is unambiguous.
        [ "$(lipo -archs "${cand}" 2>/dev/null | awk '{print $1}')" = arm64 ] || continue
        [ "$(root_platform "${cand}" arm64)" = "1" ] || continue
        SRC_B="${cand}"; break
    done <<< "$(find "${SRC_DIR}/.zig-cache" -name 'libghostty.a' -type f 2>/dev/null)"
    [ -n "${SRC_B}" ] || fail "Zig root archive (.zig-cache/o/*/libghostty.a exposing ghostty_surface_write_output) not found — the Zig compilation unit did not build (wrong SHA, or build aborted before the Zig step)."
    log "source B (zig root, has C API): ${SRC_B}"
    FINAL_FAT="${OUT_DIR}/libghostty-fat.a"
    merge_thin "${FINAL_FAT}" "${SRC_A}" "" "${SRC_B}" ""
    MEMBER_COUNT="$(ar t "${FINAL_FAT}" 2>/dev/null | grep -vc '__.SYMDEF' || true)"
    log "assembled fat archive: ${MEMBER_COUNT} members"
    # Stage Headers from the source include/ tree (umbrella ghostty.h + module.modulemap
    # + the ghostty/vt/* subtree the modulemap references).
    HDR_STAGE="${OUT_DIR}/Headers"
    rm -rf "${HDR_STAGE}"; mkdir -p "${HDR_STAGE}"
    cp -R "${SRC_DIR}/include/." "${HDR_STAGE}/"
    [ -f "${HDR_STAGE}/ghostty.h" ] || fail "staged Headers missing ghostty.h (source include/ layout changed?)."
    [ -f "${HDR_STAGE}/module.modulemap" ] || fail "staged Headers missing module.modulemap (source include/ layout changed?)."
    CREATE_ARGS=( -library "${FINAL_FAT}" -headers "${HDR_STAGE}" )
fi

log "wrapping with xcodebuild -create-xcframework (${MEMBER_COUNT})"
rm -rf "${OUT_XCFRAMEWORK}"
xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "${OUT_XCFRAMEWORK}" >/dev/null \
    || fail "xcodebuild -create-xcframework failed (see output)."
log "assembled: ${OUT_XCFRAMEWORK}"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Verify the external-IO symbols in the FINAL ASSEMBLED library (caveat #3 check).
#    This MUST pass now — the whole point of the ar/ranlib bypass is to keep
#    libghostty_zcu.o (and its symbols) in the shipped archive.
# ─────────────────────────────────────────────────────────────────────────────
REQUIRED_SYMS=(
    ghostty_app_new
    ghostty_surface_new
    ghostty_surface_set_size
    ghostty_surface_key
    ghostty_surface_text
    ghostty_surface_write_output
)

SLICE_LIBS="$(find "${OUT_XCFRAMEWORK}" -type f \( -name '*.a' -o -name 'GhosttyKit' -o -name 'libghostty*' \) 2>/dev/null)"
[ -n "${SLICE_LIBS}" ] || fail "no library slice found inside ${OUT_XCFRAMEWORK}."
log "xcframework library slices:"; echo "${SLICE_LIBS}" | sed 's/^/    /'

VERIFIED=0
while IFS= read -r lib; do
    [ -n "${lib}" ] || continue
    log "verifying slice: ${lib}"
    log "  lipo -archs: $(lipo -archs "${lib}" 2>/dev/null || echo '?')"
    MISSING=()
    for sym in "${REQUIRED_SYMS[@]}"; do
        # pipefail-safe (grep -q SIGPIPEs nm → pipeline non-zero under `set -o pipefail`
        # → false "missing"). Consume all of nm via grep -c and decide on the COUNT.
        [ "$(nm -gU "${lib}" 2>/dev/null | grep -c " _${sym}\$" || true)" -gt 0 ] || MISSING+=("${sym}")
    done
    if [ "${#MISSING[@]}" -eq 0 ]; then
        log "  ✔ all ${#REQUIRED_SYMS[@]} required external-IO symbols present"
        nm -gU "${lib}" 2>/dev/null | grep -E " _(ghostty_surface_write_output|ghostty_surface_set_size|ghostty_surface_key|ghostty_surface_text|ghostty_app_new|ghostty_surface_new)\$" | sed 's/^/        /'
        VERIFIED=1
    else
        log "  ✖ MISSING required symbols: ${MISSING[*]}"
    fi
done <<< "${SLICE_LIBS}"

[ "${VERIFIED}" -eq 1 ] || fail "FINAL assembled library is missing required external-IO symbols (the ar/ranlib bypass failed — did libghostty_zcu.o survive? did ranlib run?)."

ok "OK: ${OUT_XCFRAMEWORK}"
ok "    zig=${ZIG_VERSION}  ghostty=${GHOSTTY_TAG}+fork-delta  target=${XCFRAMEWORK_TARGET}  sdk-shim=${MACOS_SDK_SHIM_PATH}"
ok "    final library assembled via ar/ranlib bypass (${MEMBER_COUNT} members); all required external-IO symbols verified."

#!/usr/bin/env bash
# Upstream sync + parity gate for the herdr-ported detect engine (SlopDeskAgentDetect).
#
# scripts/herdr.pin records the herdr commit the port is proven equivalent to. This script
# advances that proof to a newer upstream commit:
#
#   1. fetch upstream, show what changed under src/detect since the pin
#   2. check out the target commit and regenerate BundledAgentManifests.swift verbatim
#      (gen-bundled-manifests.py — fails loudly if the manifest SET changed)
#   3. list src/detect *.rs changes — engine-code changes need a manual Swift port, but
#      even an unread one cannot slip through: step 5 diffs the real binaries
#   4. build the herdr oracle binary (vendored libghostty-vt needs Zig 0.15.2 + the xcrun
#      SDK shim from ThirdParty/ghostty — see libghostty build recipe) and slopdesk's
#      slopdesk-detect-explain
#   5. run scripts/herdr-differential.py: ~10k generated screens through BOTH engines,
#      field-level diff of the full evaluation traces (winner, per-rule matched flags,
#      region bytes + previews)
#   6. run the Swift parity test suite
#   7. with --update-pin: record the newly proven commit in scripts/herdr.pin
#
# Usage:
#   bash scripts/herdr-sync.sh                # prove parity against origin/master HEAD
#   bash scripts/herdr-sync.sh <commit-ish>   # ...against a specific upstream commit
#   bash scripts/herdr-sync.sh --update-pin   # ...and advance the pin on success

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_DIR="${HERDR_DIR:-${HOME}/.cache/clio-repos/github.com--ogulcancelik--herdr}"
PIN_FILE="${REPO_ROOT}/scripts/herdr.pin"
ZIG_PINNED="${REPO_ROOT}/ThirdParty/ghostty/.toolchain/zig-aarch64-macos-0.15.2/zig"
XCRUN_SHIM_DIR="${REPO_ROOT}/ThirdParty/ghostty/.work/bin"

TARGET="origin/master"
UPDATE_PIN=0
for arg in "$@"; do
  case "${arg}" in
    --update-pin) UPDATE_PIN=1 ;;
    *) TARGET="${arg}" ;;
  esac
done

log() { printf '\033[1m[herdr-sync]\033[0m %s\n' "$*"; }
fail() {
  printf '\033[31m[herdr-sync] %s\033[0m\n' "$*" >&2
  exit 1
}

[[ -d "${HERDR_DIR}/src/detect" ]] || fail "no herdr checkout at ${HERDR_DIR} (set HERDR_DIR or: git clone https://github.com/ogulcancelik/herdr.git)"
PIN="$(cat "${PIN_FILE}" 2> /dev/null || echo '')"
[[ -n "${PIN}" ]] || fail "missing ${PIN_FILE}"

log "fetching upstream…"
git -C "${HERDR_DIR}" fetch --quiet origin
TARGET_SHA="$(git -C "${HERDR_DIR}" rev-parse "${TARGET}^{commit}")"

log "pin ${PIN:0:12} → target ${TARGET_SHA:0:12}"
if [[ "${PIN}" = "${TARGET_SHA}" ]]; then
  log "already at the pinned commit — re-proving parity anyway"
else
  log "src/detect changes since the pin:"
  git -C "${HERDR_DIR}" --no-pager log --oneline "${PIN}..${TARGET_SHA}" -- src/detect | sed 's/^/    /'
  git -C "${HERDR_DIR}" --no-pager diff --stat "${PIN}" "${TARGET_SHA}" -- src/detect | sed 's/^/    /'
fi

DIRTY="$(git -C "${HERDR_DIR}" status --porcelain -- src)"
[[ -z "${DIRTY}" ]] || fail "herdr checkout has local src changes — clean it first"
git -C "${HERDR_DIR}" checkout --quiet "${TARGET_SHA}"

log "regenerating BundledAgentManifests.swift from upstream TOMLs…"
python3 "${REPO_ROOT}/scripts/gen-bundled-manifests.py" --herdr-dir "${HERDR_DIR}"

RS_CHANGES="$(git -C "${HERDR_DIR}" diff --name-only "${PIN}" "${TARGET_SHA}" -- 'src/detect/*.rs' 'src/detect/manifest/*.rs' || true)"
if [[ -n "${RS_CHANGES}" ]]; then
  log "ENGINE CODE changed upstream — review + port by hand, the differential below gates the result:"
  printf '    %s\n' "${RS_CHANGES}"
  log "view with: git -C ${HERDR_DIR} diff ${PIN:0:12} ${TARGET_SHA:0:12} -- src/detect"
fi

log "building herdr oracle (cargo, vendored libghostty-vt via Zig)…"
BUILD_ENV=()
[[ -x "${ZIG_PINNED}" ]] && BUILD_ENV+=("ZIG=${ZIG_PINNED}")
if [[ -x "${XCRUN_SHIM_DIR}/xcrun" ]]; then
  BUILD_ENV+=("PATH=${XCRUN_SHIM_DIR}:${PATH}")
else
  log "warning: no xcrun SDK shim at ${XCRUN_SHIM_DIR} — if the zig step fails with"
  log "         undefined libSystem symbols, run ThirdParty/ghostty/build-libghostty.sh once"
fi
(cd "${HERDR_DIR}" && env "${BUILD_ENV[@]}" cargo build --release --bin herdr)

log "building slopdesk-detect-explain…"
(cd "${REPO_ROOT}" && swift build)

log "running the differential parity harness…"
python3 "${REPO_ROOT}/scripts/herdr-differential.py" --herdr-dir "${HERDR_DIR}"

log "running the Swift parity test suite…"
(cd "${REPO_ROOT}" && swift test --filter SlopDeskAgentDetectTests | tail -2)

if [[ "${UPDATE_PIN}" = 1 ]]; then
  printf '%s\n' "${TARGET_SHA}" > "${PIN_FILE}"
  log "pin advanced to ${TARGET_SHA:0:12} — commit scripts/herdr.pin with the sync"
else
  log "parity proven against ${TARGET_SHA:0:12} (pin unchanged; rerun with --update-pin to record it)"
fi
log "done — remember: manifest regen may have touched BundledAgentManifests.swift; run make check before committing"

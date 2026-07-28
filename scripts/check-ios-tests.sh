#!/usr/bin/env bash
#
# check-ios-tests.sh — RUN the iOS unit tests, on a real iOS Simulator, on the iOS triple.
#
# `scripts/check-ios.sh` type-checks the `#if os(iOS)` slice and runs ZERO tests; `swift test`
# compiles the macOS slice, so every iOS default it touches is asserted against the wrong branch of
# the fork (a macOS build of `DevicePreferences.platformDefaultFollowSessionFocus` reads `true`).
# This script is the missing half: it builds `ClientApp-iOSTests` — a HOST-LESS XCTest bundle whose
# sources live in `Apps/ClientApp-iOS/Tests/` — for the iOS-Simulator triple and executes it.
#
#   bash scripts/check-ios-tests.sh [--device NAME] [--keep-booted]
#
# WHY NOT `xcodebuild test`: it needs to ENUMERATE simulator devices through DVT, and on a machine
# whose /Library CoreSimulator package is older than the installed Xcode expects, DVT refuses the
# whole device list ("CoreSimulator is out of date … Simulator device support disabled") and offers
# only the `generic/platform=iOS Simulator` placeholder. Installing that package needs admin rights
# a CI/agent run does not have. `simctl` is unaffected — it boots and runs fine — so this script
# builds against the GENERIC destination (which DVT allows) and hands the bundle to the simulator's
# own `xctest` agent by hand. That is also why the bundle is host-less: no app, no window server,
# no libghostty, so `xctest` can load it directly.
#
# Non-zero exit ⇒ an iOS test failed. Run from anywhere: paths resolve to the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="${REPO_ROOT}/Apps/ClientApp-iOS/project.yml"
PROJECT="${REPO_ROOT}/Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj"
SCHEME="ClientApp-iOSTests"
DD="${REPO_ROOT}/.work/ios-test-dd"
BUNDLE="${DD}/Build/Products/Debug-iphonesimulator/${SCHEME}.xctest"
XCTEST_AGENT="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"

DEVICE_NAME="iPhone 17 Pro"
KEEP_BOOTED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      DEVICE_NAME="$2"
      shift 2
      ;;
    --keep-booted)
      KEEP_BOOTED=1
      shift
      ;;
    *)
      echo "usage: $0 [--device NAME] [--keep-booted]" >&2
      exit 2
      ;;
  esac
done

if ! command -v xcodegen > /dev/null 2>&1; then
  echo "ERROR: xcodegen not found on PATH (install: brew install xcodegen)." >&2
  exit 1
fi
if [[ ! -x "${XCTEST_AGENT}" ]]; then
  echo "ERROR: no iPhoneSimulator xctest agent at ${XCTEST_AGENT}" >&2
  exit 1
fi

# ── 1. Resolve a simulator ──────────────────────────────────────────────────────────────────
# `simctl list` prints an "Install Failed: Authorization is required" line on a machine whose
# CoreSimulator package is out of date. That is about INSTALLING a newer package, not about the
# devices — they are listed and bootable regardless — so it is filtered rather than treated as
# fatal. Parsing `--json` keeps that noise out of the UDID either way.
UDID="$(xcrun simctl list devices available --json 2> /dev/null | python3 -c "
import json, sys
name = sys.argv[1]
runtimes = json.load(sys.stdin)['devices']
for runtime, devices in sorted(runtimes.items()):
    if 'iOS' not in runtime:
        continue
    for device in devices:
        if device['name'] == name:
            print(device['udid'])
            raise SystemExit
" "${DEVICE_NAME}")"
if [[ -z "${UDID}" ]]; then
  echo "ERROR: no available iOS simulator named '${DEVICE_NAME}'." >&2
  echo "       available: $(xcrun simctl list devices available 2> /dev/null | grep -oE '^ +[A-Za-z].*\(' | tr -d '(' | xargs echo)" >&2
  exit 1
fi

WE_BOOTED=0
if ! xcrun simctl list devices booted 2> /dev/null | grep -q "${UDID}"; then
  echo "==> booting ${DEVICE_NAME} (${UDID})"
  xcrun simctl boot "${UDID}" > /dev/null 2>&1 || true
  # `bootstatus -b` returns when the device finishes booting; it is a no-op on an already-booted one.
  xcrun simctl bootstatus "${UDID}" -b > /dev/null 2>&1 || true
  WE_BOOTED=1
fi
echo "==> simulator: ${DEVICE_NAME} (${UDID})"

cleanup() {
  if [[ "${WE_BOOTED}" == "1" && "${KEEP_BOOTED}" == "0" ]]; then
    xcrun simctl shutdown "${UDID}" > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ── 2. Build the bundle for the iOS-Simulator triple ────────────────────────────────────────
# The .xcodeproj is gitignored/derived — regenerate from the committed spec so a newly added test
# file is picked up (a stale project fails with "Build input file cannot be found").
echo "==> xcodegen generate --spec ${SPEC}"
xcodegen generate --spec "${SPEC}" > /dev/null
echo "==> build-for-testing: ${SCHEME}"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "${DD}" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing > "${DD}.log" 2>&1 || {
  echo "==> FAIL: iOS test bundle did not build; tail of ${DD}.log:" >&2
  tail -40 "${DD}.log" >&2
  exit 1
}
if [[ ! -d "${BUNDLE}" ]]; then
  echo "==> FAIL: no test bundle at ${BUNDLE}" >&2
  exit 1
fi

# ── 3. Run it in the simulator ──────────────────────────────────────────────────────────────
echo "==> xctest ${BUNDLE##*/}"
OUT="${DD}-run.log"
set +e
xcrun simctl spawn "${UDID}" "${XCTEST_AGENT}" -XCTest All "${BUNDLE}" > "${OUT}" 2>&1
STATUS=$?
set -e
grep -vE 'Install Started|Authorization is required to install' "${OUT}" || true
# The agent's own exit code is the primary verdict. A bundle that fails to LOAD exits non-zero having
# run nothing, which "0 failures" would not catch.
if [[ "${STATUS}" != "0" ]]; then
  echo "==> FAIL: xctest exited ${STATUS}" >&2
  exit 1
fi

# ── 4. …and it ran the tests that are IN the bundle ─────────────────────────────────────────
# The COUNT is the verdict, not the summary line. XCTest prints
#
#     Test Suite 'All tests' passed
#      Executed 0 tests, with 0 failures
#
# for an EMPTY bundle and exits 0, so "the summary says passed" is satisfied by a run that asserted
# nothing at all — the reading a gate must never accept. Empty `Apps/ClientApp-iOS/Tests/` (a refactor
# that keeps the directory so xcodegen still resolves the target) and every other check here stays
# green while the whole iOS platform-fork slice — `platformDefaultFollowSessionFocus`,
# `WorkspaceClientKind.thisPlatform`, the letterbox geometry — goes unasserted.
#
# So the number the agent reports is compared against the number of `func test…` the committed sources
# declare. Derived rather than hardcoded, because a hardcoded number is a second thing to keep in step
# and the day it drifted this gate would fail on an honest new test.
DECLARED="$(grep -rhoE '(^|[[:space:]])func test[A-Za-z0-9_]*\(' "${REPO_ROOT}/Apps/ClientApp-iOS/Tests" |
  grep -c . || true)"
if [[ "${DECLARED}" == "0" ]]; then
  echo "==> FAIL: Apps/ClientApp-iOS/Tests declares no tests — this gate would assert nothing" >&2
  exit 1
fi
# The LAST summary is the whole-run one ('All tests'); per-suite lines print the same shape above it.
EXECUTED="$(grep -oE 'Executed [0-9]+ tests?,' "${OUT}" | tail -1 | grep -oE '[0-9]+' || true)"
if [[ -z "${EXECUTED}" ]]; then
  echo "==> FAIL: xctest printed no 'Executed N tests' summary — it failed to load the bundle" >&2
  exit 1
fi
if [[ "${EXECUTED}" != "${DECLARED}" ]]; then
  echo "==> FAIL: Apps/ClientApp-iOS/Tests declares ${DECLARED} test(s), but the simulator executed" >&2
  echo "    ${EXECUTED}. A test that does not RUN on the iOS triple is a fork branch nobody asserts." >&2
  exit 1
fi
if ! grep -q "Test Suite 'All tests' passed" "${OUT}"; then
  echo "==> FAIL: the '${EXECUTED} tests' run did not end in a passing 'All tests' summary" >&2
  exit 1
fi

echo "==> iOS tests OK — ${EXECUTED} of ${DECLARED} declared tests ran on the iOS-Simulator triple"

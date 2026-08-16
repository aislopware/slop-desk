#!/usr/bin/env bash
#
# iOS-triple typecheck.
#
# `swift build` on macOS compiles the macOS slice only — it NEVER type-checks the
# `#if os(iOS)` sources (the UIKit input host + the four table-stakes components in
# Sources/SlopDeskClientUI/iOS/). Without an iOS-triple build those compile only in someone's
# head and rot silently. This script is the explicit, repeatable command that compiles them:
# an unsigned iOS-Simulator build of the iOS app, which links the SlopDeskClientUI package and so
# forces the whole `#if os(iOS)` surface through the compiler. Non-zero exit ⇒ iOS code broke.
#
# ## Why it is stamped
#
# An xcodebuild over this package graph costs ~85 s whether or not a single compiled byte changed.
# That is not a missing cache: with a private `-derivedDataPath`, a second run on an untouched tree
# emits an EMPTY build-timing summary — no compile task ran at all — and still spends the 85 s
# resolving the packages and re-creating the build description. Planning IS the cost here, and
# nothing on this side can make Xcode skip it. It was being paid after every edit, including edits
# to Rust, docs and shell that the iOS compiler never sees.
#
# So the verdict is CACHED against a hash of its inputs, exactly the way `build-ffi.sh` caches the
# xcframework. The stamp is written only after a green run, so a red one is never cached, and it
# lives under `.build/` with the rest of the derived state (wiped by a clean, as it should be).
#
# WHAT THE STAMP COVERS, and why that is the whole set: every Swift source the iOS triple compiles
# (`Sources/`, `Apps/`), the package graph that decides which of them it compiles (`Package.swift`,
# `Package.resolved`), the project spec (`Apps/**/project.yml`, hashed as part of `Apps/`), the C
# surface the Swift side imports (`ThirdParty/slopdesk-ffi/**/*.h` + module maps) and this script.
#
# The Rust SOURCES are deliberately not in it. A crate's body cannot change what type-checks on the
# far side of a C header, and the one Rust change that CAN — deleting or re-signing an exported
# door — changes the header, which is in the stamp, and breaks the macOS link first anyway.
#
# `--force` re-runs regardless, which is what to use when suspecting the stamp itself.
#
# Run from anywhere: paths are resolved relative to the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="${REPO_ROOT}/Apps/ClientApp-iOS/project.yml"
PROJECT="${REPO_ROOT}/Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj"
DEST='generic/platform=iOS Simulator'
SELF="${BASH_SOURCE[0]}"
STAMP="${REPO_ROOT}/.build/check-ios.sha256"

FORCE=0
[[ ${1:-} == "--force" ]] && FORCE=1

# `find | sort` rather than a glob so the order is stable across machines, and the outer `shasum`
# collapses the per-file digests into one line — the file NAMES are part of that, so a rename or a
# deletion moves the stamp just as a content edit does.
stamp_inputs() {
  find "${REPO_ROOT}/Sources" "${REPO_ROOT}/Apps" \
    \( -name '*.swift' -o -name '*.yml' -o -name '*.plist' -o -name '*.metal' -o -name '*.h' \) -print
  find "${REPO_ROOT}/ThirdParty/slopdesk-ffi" \
    \( -name '*.h' -o -name 'module.modulemap' \) -print
  printf '%s\n' "${REPO_ROOT}/Package.swift" "${REPO_ROOT}/Package.resolved" "${SELF}"
}

current_stamp() {
  stamp_inputs | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}'
}

WANT="$(current_stamp)"
if [[ ${FORCE} -eq 0 && -f ${STAMP} && "$(cat "${STAMP}")" == "${WANT}" ]]; then
  echo "==> iOS typecheck OK (cached — no iOS-compiled input changed)"
  exit 0
fi

# The .xcodeproj is gitignored/derived — project.yml is the source of truth (see .gitignore).
# Regenerate it from the committed spec so newly added/removed Apps/Shared sources are picked up;
# a stale checkout would otherwise compile AppMain.swift against an outdated source list and fail
# with "cannot find … in scope". Mirrors check-macos.sh / check-video.sh.
if ! command -v xcodegen > /dev/null 2>&1; then
  echo "ERROR: xcodegen not found on PATH (install: brew install xcodegen)." >&2
  exit 1
fi
echo "==> xcodegen generate --spec ${SPEC}"
xcodegen generate --spec "${SPEC}" > /dev/null

# ONE scheme, and the second one's removal is measured rather than assumed.
#
# The app target links SlopDeskClientUI + SlopDeskVideoClient, so building it compiles the host and
# every `#if os(iOS)` source it depends on. This script also built the `SlopDeskClientUI` scheme
# directly, "belt-and-suspenders … independent of the app target's other dependencies" — but the
# build's OWN dependency dump says it is not independent of anything:
#
#     Target 'ClientApp-iOS' in project 'ClientApp-iOS'
#         ➜ Explicit dependency on target 'SlopDeskClientUI' in project 'SlopDesk'
#         ➜ Explicit dependency on target 'SlopDeskVideoClient' in project 'SlopDesk'
#
# and `SlopDeskClientUI` in turn pulls in all seventeen library targets. The second scheme's graph
# is a strict SUBSET of the first's, so it compiled nothing the first had not already compiled —
# for ~85 s, on every Swift edit, forever. The one thing it would have caught (the app spec dropping
# its SlopDeskClientUI dependency) cannot happen quietly: the app does not build without it.
#
# `-derivedDataPath` under `.build/` rather than the shared `~/Library/Developer/Xcode/DerivedData`:
# this gate's cache is then wiped by `make clean` with the rest of the derived state, and Xcode.app
# working on the same project cannot evict it out from under the stamp.
echo "==> iOS-triple build: ClientApp-iOS"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "ClientApp-iOS" \
  -destination "${DEST}" \
  -derivedDataPath "${REPO_ROOT}/.build/ios-dd" \
  CODE_SIGNING_ALLOWED=NO \
  build

# Only a GREEN run is cached, and the stamp is recomputed rather than reused: xcodegen rewrote the
# .xcodeproj above, and a source file edited while the build ran must not be recorded as checked.
mkdir -p "$(dirname "${STAMP}")"
current_stamp > "${STAMP}"

echo "==> iOS typecheck OK"

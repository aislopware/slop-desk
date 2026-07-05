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
# Run from anywhere: paths are resolved relative to the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="${REPO_ROOT}/Apps/ClientApp-iOS/project.yml"
PROJECT="${REPO_ROOT}/Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj"
DEST='generic/platform=iOS Simulator'

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

build() {
  local scheme="$1"
  echo "==> iOS-triple build: ${scheme}"
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${scheme}" \
    -destination "${DEST}" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

# The app target links SlopDeskClientUI + SlopDeskVideoClient, so building it compiles the host +
# every `#if os(iOS)` source it depends on.
build "ClientApp-iOS"

# Belt-and-suspenders: the SlopDeskClientUI scheme is exposed by the project (it carries the iOS
# table-stakes). Build it directly too if present, so the library's iOS slice is checked on its
# own, independent of the app target's other dependencies.
if xcodebuild -project "${PROJECT}" -list 2> /dev/null | grep -qx '        SlopDeskClientUI'; then
  build "SlopDeskClientUI"
fi

echo "==> iOS typecheck OK"

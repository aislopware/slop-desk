#!/usr/bin/env bash
#
# iOS-triple typecheck.
#
# `swift build` on macOS compiles the macOS slice only — it NEVER type-checks the
# `#if os(iOS)` sources (the UIKit input host + the four table-stakes components in
# Sources/AislopdeskClientUI/iOS/). Without an iOS-triple build those compile only in someone's
# head and rot silently. This script is the explicit, repeatable command that compiles them:
# an unsigned iOS-Simulator build of the iOS app, which links the AislopdeskClientUI package and so
# forces the whole `#if os(iOS)` surface through the compiler. Non-zero exit ⇒ iOS code broke.
#
# Run from anywhere: paths are resolved relative to the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj"
DEST='generic/platform=iOS Simulator'

build() {
  local scheme="$1"
  echo "==> iOS-triple build: $scheme"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -destination "$DEST" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

# The app target links AislopdeskClientUI + AislopdeskVideoClient, so building it compiles the host +
# every `#if os(iOS)` source it depends on.
build "ClientApp-iOS"

# Belt-and-suspenders: the AislopdeskClientUI scheme is exposed by the project (it carries the iOS
# table-stakes). Build it directly too if present, so the library's iOS slice is checked on its
# own, independent of the app target's other dependencies.
if xcodebuild -project "$PROJECT" -list 2>/dev/null | grep -qx '        AislopdeskClientUI'; then
  build "AislopdeskClientUI"
fi

echo "==> iOS typecheck OK"

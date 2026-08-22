#!/usr/bin/env bash
#
# macOS APP-SHELL typecheck — the hole between `swift build` and `check-ios.sh`.
#
# `swift build` compiles `Sources/` and `Tests/`. `check-ios.sh` compiles the iOS triple, which
# includes `Apps/ClientApp-iOS`. Between them sits the code neither one touches: `Apps/`'s two macOS
# shells. They are Xcode targets, not SwiftPM ones, so nothing in a headless gate ever compiled
# `Apps/ClientApp-macOS/AppMain.swift` or `Apps/HostApp-macOS/`.
#
# That is not hypothetical. The video carve renamed `VideoSurfaceHost` to `MacVideoSurfaceHost`,
# updated the `@retroactive` conformance 98 lines below the call site, and missed the call site
# itself. `swift build`, `swift test`, `make lint`, the ratchet and the iOS triple were ALL green
# over a client shell that could not compile. The only thing that would have caught it is compiling
# `Apps/`, on macOS, which is this script.
#
# `check-macos.sh` is the neighbour and is a different gate on purpose: it BUILDS AND RUNS the app,
# drives a real window, and needs a logged-in GUI session, which is why it is reachable from no
# headless target. This one only type-checks, so it belongs in `check` beside `check-ios`.
#
# ## Why it is stamped
#
# Same reason and same shape as `check-ios.sh`: an xcodebuild over this package graph spends most of
# its wall clock resolving packages and re-creating the build description whether or not a compiled
# byte changed. The verdict is cached against a hash of its inputs, the stamp is written only after a
# green run so a red one is never cached, and it lives under `.build/` with the rest of the derived
# state.
#
# The input set is the same set for the same reason (every Swift source these triples compile, the
# package graph that decides which, the project specs, the C surface, and this script) — and it is
# deliberately IDENTICAL to check-ios's rather than narrowed to `Apps/`, because a change under
# `Sources/` can break a shell's call site without touching `Apps/` at all, which is exactly the bug
# above.
#
# `--force` re-runs regardless, which is what to use when suspecting the stamp itself.
#
# BREAK-TEST: `MacVideoSurfaceHost(` → `VideoSurfaceHost(` at Apps/ClientApp-macOS/AppMain.swift:147
# (the original bug, re-injected) ⇒ exit 65, "cannot find 'VideoSurfaceHost' in scope" at that exact
# line. Restored; green. A gate that has never failed has not been tested.
#
# Run from anywhere: paths are resolved relative to the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST='platform=macOS,arch=arm64'
SELF="${BASH_SOURCE[0]}"
STAMP="${REPO_ROOT}/.build/check-macos-apps.sha256"

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
  echo "==> macOS app typecheck OK (cached — no compiled input changed)"
  exit 0
fi

# The .xcodeproj files are gitignored/derived — the project.yml specs are the source of truth (see
# .gitignore). Regenerate from the committed spec so newly added/removed Apps/Shared sources are
# picked up; a stale checkout would otherwise compile AppMain.swift against an outdated source list.
if ! command -v xcodegen > /dev/null 2>&1; then
  echo "ERROR: xcodegen not found on PATH (install: brew install xcodegen)." >&2
  exit 1
fi

# BOTH shells, because they are not each other's subset: the client links SlopDeskMacUI and the
# video carve's AppKit half, the host links the daemon graph, and neither target's dependency
# closure contains the other's. This is the one place that differs from check-ios.sh, whose second
# scheme WAS a strict subset and was deleted for it.
for app in ClientApp-macOS HostApp-macOS; do
  spec="${REPO_ROOT}/Apps/${app}/project.yml"
  project="${REPO_ROOT}/Apps/${app}/${app}.xcodeproj"
  echo "==> xcodegen generate --spec ${spec}"
  xcodegen generate --spec "${spec}" > /dev/null
  echo "==> macOS build: ${app}"
  # `-derivedDataPath` under `.build/` rather than the shared DerivedData: this gate's cache is then
  # wiped by `make clean` with the rest of the derived state, and Xcode.app working on the same
  # project cannot evict it out from under the stamp.
  xcodebuild \
    -project "${project}" \
    -scheme "${app}" \
    -destination "${DEST}" \
    -derivedDataPath "${REPO_ROOT}/.build/macos-apps-dd" \
    CODE_SIGNING_ALLOWED=NO \
    build
done

# Only a GREEN run is cached, and the stamp is recomputed rather than reused: xcodegen rewrote the
# .xcodeproj files above, and a source file edited while the build ran must not be recorded as
# checked.
mkdir -p "$(dirname "${STAMP}")"
current_stamp > "${STAMP}"

echo "==> macOS app typecheck OK"

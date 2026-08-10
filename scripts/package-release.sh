#!/usr/bin/env bash
#
# package-release.sh — build, Developer-ID sign, notarize and package a SlopDesk release.
#
# WHY this exists: `make check` proves the tree is green; nothing in the repo turned that tree
# into something a stranger can install. This script is the ONE place that knows how to go from
# a clean checkout to the three shippable artifacts, so CI (.github/workflows/release.yml) and a
# human cutting a release by hand run byte-identical steps.
#
# ARM64 ONLY — this is a hard constraint, not a default:
#   * ThirdParty/ghostty/libghostty.xcframework ships a macos-arm64 slice and nothing else
#     (see ThirdParty/ghostty/README.md), and Apps/ClientApp-macOS pins ARCHS=arm64 because
#     of it. An Intel client app cannot link.
#   * The apps deploy against macOS 26, which no Intel Mac runs.
# The script therefore REFUSES to run on an x86_64 host rather than emitting a half-broken slice.
#
# ARTIFACTS (into dist/):
#   SlopDesk-<version>-arm64.dmg          SlopDesk.app + SlopDeskHost.app, signed + stapled
#   slopdesk-cli-<version>-arm64.tar.gz   slopdesk, slopdesk-hostd, slopdesk-ctl, signed
#   SHA256SUMS                            what the Homebrew tap's cask + formula pin
#
# SIGNING / NOTARIZATION inputs (env — CI pulls them from the better-update vault, see
# docs/49-release-pipeline.md; a local run can lean on the login keychain instead):
#   SLOPDESK_VERSION            REQUIRED. Marketing version, no leading "v" (e.g. 0.1.0).
#   SLOPDESK_BUILD_NUMBER       CFBundleVersion. Default: 1.
#   SLOPDESK_SIGN_IDENTITY      codesign identity. Default: the WEEBUILD Developer ID below.
#   SLOPDESK_NOTARY_PROFILE     `notarytool --keychain-profile` name. Takes precedence.
#   APPLE_ID / APPLE_TEAM_ID / APPLE_APP_SPECIFIC_PASSWORD
#                               notarytool credentials when no keychain profile exists (CI).
#   SLOPDESK_SKIP_NOTARIZE=1    Sign + package but do not submit. For pipeline dry-runs ONLY —
#                               the output will NOT pass Gatekeeper on another machine.
#
# The libghostty xcframework must already exist (ThirdParty/ghostty/build-libghostty.sh, or the
# cached CI artifact). Building it here would hide a 20-minute Zig build inside a packaging step.
#
# Run from anywhere: every path resolves against the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${REPO_ROOT}/dist"
WORK="${REPO_ROOT}/.work/package-release"
DD="${WORK}/DerivedData"
STAGE="${WORK}/stage"

VERSION="${SLOPDESK_VERSION:?SLOPDESK_VERSION is required (e.g. 0.1.0, no leading v)}"
BUILD_NUMBER="${SLOPDESK_BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SLOPDESK_SIGN_IDENTITY:-Developer ID Application: WEEBUILD VIET NAM COMPANY LIMITED (AJ4R8GWM7A)}"
SKIP_NOTARIZE="${SLOPDESK_SKIP_NOTARIZE:-0}"

CLI_TOOLS=(slopdesk slopdesk-hostd slopdesk-ctl)
XCFRAMEWORK="${REPO_ROOT}/ThirdParty/ghostty/libghostty.xcframework"

CLIENT_SPEC="${REPO_ROOT}/Apps/ClientApp-macOS/project.yml"
CLIENT_PROJECT="${REPO_ROOT}/Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj"
HOST_SPEC="${REPO_ROOT}/Apps/HostApp-macOS/project.yml"
HOST_PROJECT="${REPO_ROOT}/Apps/HostApp-macOS/HostApp-macOS.xcodeproj"

DMG="${DIST}/SlopDesk-${VERSION}-arm64.dmg"
CLI_TARBALL="${DIST}/slopdesk-cli-${VERSION}-arm64.tar.gz"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

step() { echo "── $* ──"; }

# ── 1. Preflight ────────────────────────────────────────────────────────────────────────────
step "Preflight"

[[ "$(uname -m)" == "arm64" ]] ||
  die "arm64-only release: this host is $(uname -m). libghostty ships no x86_64 slice."

for tool in xcodegen xcodebuild codesign hdiutil; do
  command -v "${tool}" > /dev/null 2>&1 || die "missing required tool: ${tool}"
done

[[ -d "${XCFRAMEWORK}/macos-arm64" ]] ||
  die "${XCFRAMEWORK} is missing its macos-arm64 slice. Build it first:
  ThirdParty/ghostty/build-libghostty.sh"

security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}" ||
  die "signing identity not in any unlocked keychain: ${SIGN_IDENTITY}"

if [[ "${SKIP_NOTARIZE}" != "1" ]]; then
  if [[ -z "${SLOPDESK_NOTARY_PROFILE:-}" ]]; then
    : "${APPLE_ID:?set SLOPDESK_NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD}"
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required when no notary keychain profile is given}"
    : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required when no notary keychain profile is given}"
  fi
fi

rm -rf "${WORK}"
mkdir -p "${DIST}" "${DD}" "${STAGE}"

echo "version=${VERSION} build=${BUILD_NUMBER}"
echo "identity=${SIGN_IDENTITY}"

# ── 2. CLI binaries (SwiftPM, no Xcode project, no libghostty) ───────────────────────────────
step "Building CLI (swift build -c release)"

# --arch arm64 keeps this honest even if someone runs it under Rosetta or on a future
# universal-capable toolchain: the tarball claims arm64 and must contain only arm64. The three
# shipped executables are `.executableTarget`s with no declared product (Package.swift's
# `products:` are all libraries), so this is `--target`, not `--product`.
for tool in "${CLI_TOOLS[@]}"; do
  (cd "${REPO_ROOT}" && swift build -c release --arch arm64 --target "${tool}")
done

# ASK SwiftPM where it put them. The triple-named directory (.build/arm64-apple-macosx/release
# on one host) is not stable across toolchains — hardcoding it built fine and then failed at the
# copy, which is the worst place to learn it. `--show-bin-path` builds nothing.
CLI_BIN="$(cd "${REPO_ROOT}" && swift build -c release --arch arm64 --show-bin-path)"
[[ -d "${CLI_BIN}" ]] || die "swift build --show-bin-path returned no directory: ${CLI_BIN}"

CLI_STAGE="${STAGE}/slopdesk-cli-${VERSION}-arm64"
mkdir -p "${CLI_STAGE}"
for tool in "${CLI_TOOLS[@]}"; do
  built="${CLI_BIN}/${tool}"
  [[ -x "${built}" ]] || die "swift build did not produce ${built}"
  cp "${built}" "${CLI_STAGE}/${tool}"
done

# `slopdesk version` reads a SOURCE constant (Sources/SlopDeskCLICore/CLIVersion.swift), not the
# tag — so a release cut without bumping it ships a binary that lies about its own version. Ask
# the built binary rather than grepping the source: this is the string users will actually see.
declared="$("${CLI_BIN}/slopdesk" version | head -1 | awk '{print $2}')"
[[ "${declared}" == "${VERSION}" ]] ||
  die "version drift: \`slopdesk version\` says ${declared}, this release is ${VERSION}.
  Bump Sources/SlopDeskCLICore/CLIVersion.swift (and the MARKETING_VERSION in both
  Apps/*/project.yml) to ${VERSION} before tagging."

step "Signing CLI binaries"
for tool in "${CLI_TOOLS[@]}"; do
  # Hardened runtime + a secure timestamp are both notarization prerequisites. The CLI needs no
  # entitlements: slopdesk-hostd forks a PTY, which requires no entitlement when unsandboxed.
  codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp \
    "${CLI_STAGE}/${tool}"
  codesign --verify --strict --verbose=1 "${CLI_STAGE}/${tool}"
done

# ── 3. The two app bundles ──────────────────────────────────────────────────────────────────
# Built UNSIGNED on purpose: the version has to be stamped into Info.plist AFTER the build (the
# committed plists carry a literal CFBundleShortVersionString that MARKETING_VERSION does not
# override), and editing a plist inside a signed bundle invalidates the signature. So: build →
# stamp → sign, in that order.
build_app() {
  local spec="${1}" project="${2}" scheme="${3}" product="${4}"

  step "Building ${scheme} (unsigned)"
  xcodegen generate --spec "${spec}" --quiet
  xcodebuild \
    -project "${project}" \
    -scheme "${scheme}" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${DD}" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

  local app="${DD}/Build/Products/Release/${product}"
  [[ -d "${app}" ]] || die "xcodebuild did not produce ${app}"
  cp -R "${app}" "${STAGE}/"
}

stamp_and_sign_app() {
  local app="${STAGE}/${1}" entitlements="${2}"
  local plist="${app}/Contents/Info.plist"

  step "Stamping + signing ${1}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${plist}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${plist}"

  codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp \
    --entitlements "${entitlements}" "${app}"
  codesign --verify --strict --deep --verbose=1 "${app}"
}

# The client is the ONLY target that links libghostty. enable-macos-renderer.sh injects the
# xcframework + CGhostty module map into the (deliberately placeholder) committed spec and
# regenerates the project; it is idempotent, and CI checks the spec back out afterwards.
step "Wiring the libghostty renderer into ClientApp-macOS"
"${REPO_ROOT}/scripts/enable-macos-renderer.sh"

build_app "${CLIENT_SPEC}" "${CLIENT_PROJECT}" ClientApp-macOS "SlopDesk.app"
build_app "${HOST_SPEC}" "${HOST_PROJECT}" HostApp-macOS "SlopDeskHost.app"

stamp_and_sign_app "SlopDesk.app" "${REPO_ROOT}/Apps/ClientApp-macOS/ClientApp-macOS.entitlements"
stamp_and_sign_app "SlopDeskHost.app" "${REPO_ROOT}/Apps/HostApp-macOS/HostApp-macOS.entitlements"

# Restore the committed placeholder spec so a CI checkout (and a developer's tree) stays clean.
(cd "${REPO_ROOT}" && git checkout -- Apps/ClientApp-macOS/project.yml)

# ── 4. Package ──────────────────────────────────────────────────────────────────────────────
step "Building the DMG"

DMG_ROOT="${WORK}/dmg"
mkdir -p "${DMG_ROOT}"
cp -R "${STAGE}/SlopDesk.app" "${DMG_ROOT}/"
cp -R "${STAGE}/SlopDeskHost.app" "${DMG_ROOT}/"
ln -s /Applications "${DMG_ROOT}/Applications"

rm -f "${DMG}"
hdiutil create -srcfolder "${DMG_ROOT}" -volname "SlopDesk ${VERSION}" \
  -fs HFS+ -format UDZO -quiet "${DMG}"
codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG}"

step "Building the CLI tarball"
rm -f "${CLI_TARBALL}"
tar -czf "${CLI_TARBALL}" -C "${STAGE}" "slopdesk-cli-${VERSION}-arm64"

# ── 5. Notarize ─────────────────────────────────────────────────────────────────────────────
notarize() {
  local artifact="${1}"
  if [[ -n "${SLOPDESK_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "${artifact}" \
      --keychain-profile "${SLOPDESK_NOTARY_PROFILE}" --wait
  else
    xcrun notarytool submit "${artifact}" \
      --apple-id "${APPLE_ID}" --team-id "${APPLE_TEAM_ID}" \
      --password "${APPLE_APP_SPECIFIC_PASSWORD}" --wait
  fi
}

if [[ "${SKIP_NOTARIZE}" == "1" ]]; then
  echo "SLOPDESK_SKIP_NOTARIZE=1 — artifacts are signed but NOT notarized (dry run only)."
else
  step "Notarizing the DMG"
  notarize "${DMG}"
  xcrun stapler staple "${DMG}"
  xcrun stapler validate "${DMG}"

  # A bare Mach-O cannot carry a stapled ticket, so the CLI is notarized inside a zip and
  # Gatekeeper resolves the ticket online. The shipped container stays the tarball — Homebrew
  # formulas read that, and brew does not quarantine formula downloads.
  step "Notarizing the CLI binaries"
  CLI_ZIP="${WORK}/slopdesk-cli-${VERSION}-arm64.zip"
  (cd "${STAGE}" && ditto -c -k --keepParent "slopdesk-cli-${VERSION}-arm64" "${CLI_ZIP}")
  notarize "${CLI_ZIP}"
fi

# ── 6. Checksums ────────────────────────────────────────────────────────────────────────────
step "Checksums"
(cd "${DIST}" && shasum -a 256 "$(basename "${DMG}")" "$(basename "${CLI_TARBALL}")" > SHA256SUMS)
cat "${DIST}/SHA256SUMS"

echo "OK: ${DIST}"

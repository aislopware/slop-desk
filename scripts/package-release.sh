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
#   slopdesk-cli-<version>-arm64.tar.gz   slopdesk, slopdesk-hostd (SwiftPM) + every sidecar the
#                                         host resolves at runtime (cargo), signed. See CLI_TOOLS.
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

# What the CLI tarball ships, in three lists because they are BUILT three ways. Everything after
# staging treats them as one set.
#
# The tarball used to be three binaries, and that was a host that could not open a pane. superd
# forks and owns every PTY master (`docs/51`), and `HostServiceSupervisor.connected()` puts the
# consequence in one line — "hostd does not fork, so there is no fallback to have". The other five
# daemons each cost a feature: no screen engine, no file drop, no inspector, no Android panel, no
# profile seed. None of them shipped, because the release path is exercised by tagging and no gate
# is a release. `check-invariants.py` derives the list below from the `RustServicePaths` call sites
# now, so a seventh daemon cannot be forgotten the same way.
SPM_TOOLS=(slopdesk slopdesk-hostd)

# `rust/Cargo.toml`'s workspace members: ONE shared `rust/target/`, built with `-p` from `rust/`.
# `slopdesk-hook` is a package producing TWO binaries (the relay and `slopdesk-agenthooks`, which
# installs it) — and `agenthooks` finds the relay at `executable.parent()/slopdesk-hook`, so the
# two must land in the same directory or the hook install silently has nothing to copy.
RUST_ROOT_PACKAGES=(slopdesk-ctl slopdesk-probe slopdesk-hook)
RUST_ROOT_TOOLS=(slopdesk-ctl slopdesk-probe slopdesk-hook slopdesk-agenthooks)

# The daemons. Each is `exclude`d from the root workspace and carries its own, so each builds from
# its own directory into its own `rust/<crate>/target/` — the same seam `RustServicePaths.locate`
# walks. Building these with `-p` from `rust/` fails: cargo cannot see a package it excluded.
RUST_CRATE_TOOLS=(
  slopdesk-superd slopdesk-screend slopdesk-dropd
  slopdesk-inspectord slopdesk-androidd slopdesk-codeseed
)

RUST_TOOLS=("${RUST_ROOT_TOOLS[@]}" "${RUST_CRATE_TOOLS[@]}")
CLI_TOOLS=("${SPM_TOOLS[@]}" "${RUST_TOOLS[@]}")
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

# `cargo` is here for the same reason as the rest: `slopdesk-ctl` is Rust, and a missing toolchain
# should fail in the preflight rather than after the ten-minute app builds.
for tool in xcodegen xcodebuild codesign hdiutil cargo; do
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
# universal-capable toolchain: the tarball claims arm64 and must contain only arm64.
#
# `--product`, NOT `--target`. Under the Swift 6.3 build backend `--target slopdesk` compiles the
# module, reports "Build of target: 'slopdesk' complete!", and never links a binary — a green build
# that produces nothing to ship. `--product` links ("Linking slopdesk"), which is why Package.swift
# declares the three shipped executables as products.
# --scratch-path DICTATES where SwiftPM builds instead of leaving it to the toolchain. On the CI
# toolchain the default scratch dir was not `.build` at all: all three targets built, `.build` held
# only checkouts/artifacts, and nothing named slopdesk existed anywhere under it. A packaging
# script that cannot find its own output is the one failure mode worth spending a flag on.
# `.build-release` is covered by .gitignore's `.build-*/` and survives between local runs.
SPM_SCRATCH="${REPO_ROOT}/.build-release"
for tool in "${SPM_TOOLS[@]}"; do
  (cd "${REPO_ROOT}" && swift build -c release --arch arm64 --scratch-path "${SPM_SCRATCH}" --product "${tool}")
done

# The cargo half. `--target aarch64-apple-darwin` is explicit for the same reason `--arch arm64` is
# above: the tarball claims arm64 and must contain only arm64, whatever the host toolchain defaults
# to. Naming the target also fixes the output directory, so `locate_tool` needs no search for these.
step "Building CLI (cargo build --release)"
RUST_BIN="${REPO_ROOT}/rust/target/aarch64-apple-darwin/release"
for package in "${RUST_ROOT_PACKAGES[@]}"; do
  (cd "${REPO_ROOT}/rust" && cargo build --release --target aarch64-apple-darwin -p "${package}")
done
for crate in "${RUST_CRATE_TOOLS[@]}"; do
  (cd "${REPO_ROOT}/rust/${crate}" && cargo build --release --target aarch64-apple-darwin)
done

# Where the binaries land is NOT a constant. `.build/arm64-apple-macosx/release` is right for the
# llbuild backend; the newer Swift Build backend (the toolchain that logs "Build of target: 'x'
# complete!" instead of "Build complete!") writes to a Products/Release directory that
# `--show-bin-path` does not report. Hardcoding the triple built fine locally and then failed at
# the copy on CI, which is the worst place to learn it. So: treat --show-bin-path as a hint and
# fall back to searching .build for a real Mach-O of that name under a release directory.
CLI_BIN="$(cd "${REPO_ROOT}" && swift build -c release --arch arm64 --scratch-path "${SPM_SCRATCH}" --show-bin-path 2> /dev/null || true)"

# Search roots, widest last. Even inside a pinned scratch dir the layout differs by build backend
# (`<triple>/release` for llbuild, `Products/Release` for Swift Build), so the path is still found,
# never assumed.
SEARCH_ROOTS=("${SPM_SCRATCH}" "${REPO_ROOT}/.build" "${HOME}/Library/Developer/Xcode/DerivedData")

contains() {
  local needle="$1" candidate
  shift
  for candidate in "$@"; do
    [[ "${candidate}" == "${needle}" ]] && return 0
  done
  return 1
}

# The cargo directory a tool's binary lands in, or nothing if it is not a cargo tool. The two
# answers are the two workspaces: a root member writes to the shared `rust/target/`, an excluded
# daemon to its own `rust/<crate>/target/`. `slopdesk-agenthooks` is the one name that is not its
# own crate — it rides `slopdesk-hook`'s package into the shared directory.
rust_bin_dir() {
  local tool="$1"
  if contains "${tool}" "${RUST_ROOT_TOOLS[@]}"; then
    printf '%s\n' "${RUST_BIN}"
    return 0
  fi
  if contains "${tool}" "${RUST_CRATE_TOOLS[@]}"; then
    printf '%s\n' "${REPO_ROOT}/rust/${tool}/target/aarch64-apple-darwin/release"
    return 0
  fi
  return 1
}

locate_tool() {
  local tool="$1" cand root dir
  # A cargo tool resolves to its cargo path or to NOTHING. Falling through to the SwiftPM search
  # would let a stale `.build*/release/slopdesk-ctl` — the Swift binary this one replaced — ship
  # silently under the right name, which is the one failure the version check cannot catch.
  if dir="$(rust_bin_dir "${tool}")"; then
    [[ -f "${dir}/${tool}" ]] || return 1
    printf '%s\n' "${dir}/${tool}"
    return 0
  fi
  if [[ -n "${CLI_BIN}" && -f "${CLI_BIN}/${tool}" ]]; then
    printf '%s\n' "${CLI_BIN}/${tool}"
    return 0
  fi
  for root in "${SEARCH_ROOTS[@]}"; do
    [[ -d "${root}" ]] || continue
    while IFS= read -r cand; do
      # Release paths only. A stale debug build of the same name must never reach the tarball.
      # No -perm filter: a product directory created 0700 is still the product.
      case "${cand}" in
        */[Rr]elease*/*) ;;
        *) continue ;;
      esac
      file -b "${cand}" 2> /dev/null | grep -q 'Mach-O.*execut' || continue
      printf '%s\n' "${cand}"
      return 0
    done < <(find "${root}" -type f -name "${tool}" 2> /dev/null)
  done
  return 1
}

# One failure here costs a five-minute rebuild to diagnose, so spend the listing up front rather
# than learning the layout one CI round-trip at a time.
dump_build_layout() {
  local root
  echo "--- where did the products go? ---" >&2
  for root in "${SEARCH_ROOTS[@]}"; do
    echo "[${root}]" >&2
    [[ -d "${root}" ]] || {
      echo "  (does not exist)" >&2
      continue
    }
    # awk, not head: `find | head` closes the pipe early and pipefail turns the diagnostic itself
    # into the fatal error, which is how the first dump managed to hide the second half of itself.
    find "${root}" -maxdepth 4 -type d 2> /dev/null | awk 'NR <= 40' >&2
    find "${root}" -type f -name '*slopdesk*' 2> /dev/null | awk 'NR <= 40' >&2
  done
}

CLI_STAGE="${STAGE}/slopdesk-cli-${VERSION}-arm64"
mkdir -p "${CLI_STAGE}"
for tool in "${CLI_TOOLS[@]}"; do
  if ! built="$(locate_tool "${tool}")"; then
    dump_build_layout
    die "the build reported success but no release ${tool} executable exists
  (--show-bin-path said: ${CLI_BIN:-<nothing>}; cargo dir: $(rust_bin_dir "${tool}" || echo '<not a cargo tool>'))"
  fi
  echo "  ${tool} <- ${built}"
  cp "${built}" "${CLI_STAGE}/${tool}"
done

# `slopdesk version` reads a SOURCE constant (Sources/SlopDeskCLICore/CLIVersion.swift), not the
# tag — so a release cut without bumping it ships a binary that lies about its own version. Ask
# the built binary rather than grepping the source: this is the string users will actually see.
declared="$("${CLI_STAGE}/slopdesk" version | head -1 | awk '{print $2}')"
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

# ── 3b. Notarize + staple the app bundles, BEFORE they enter the image ──────────────────────
# WHY this round exists, and why it must run here: the cask copies SlopDesk.app OUT of the DMG,
# so a ticket stapled only to the image never reaches the app the user actually launches, and
# Gatekeeper has to resolve it online — which fails on a first launch with no network. A ticket
# can only be stapled to a bundle, and the bundle inside the image is a COPY, so the staple has
# to land before `cp -R … "${DMG_ROOT}"` below. Moving this after the DMG step silently restores
# the old behaviour: the run stays green and the shipped app carries no ticket.
#
# Notarization is per-artifact, not per-file, so both bundles ride in ONE zip and one submission;
# the DMG still needs its own round afterwards (Apple has no way to derive an image's ticket from
# its contents). That is the "one extra submission per release" this buys.
if [[ "${SKIP_NOTARIZE}" == "1" ]]; then
  echo "SLOPDESK_SKIP_NOTARIZE=1 — app bundles are signed but NOT notarized or stapled."
else
  step "Notarizing the app bundles"
  APPS_ZIP="${WORK}/slopdesk-apps-${VERSION}-arm64.zip"
  rm -f "${APPS_ZIP}"
  # `--keepParent` takes ONE source, so stage a directory holding both bundles and archive its
  # CONTENTS (no --keepParent): the zip then has both .app bundles at its root. notarytool walks
  # the archive for bundles, so it notarizes both in one submission. `--sequesterRsrc` is Apple's
  # documented flag for notarization zips — it keeps resource forks from corrupting the upload.
  APPS_DIR="${WORK}/apps"
  rm -rf "${APPS_DIR}"
  mkdir -p "${APPS_DIR}"
  cp -R "${STAGE}/SlopDesk.app" "${STAGE}/SlopDeskHost.app" "${APPS_DIR}/"
  ditto -c -k --sequesterRsrc "${APPS_DIR}" "${APPS_ZIP}"
  notarize "${APPS_ZIP}"

  # Staple the ORIGINALS in STAGE — those are what the DMG is built from. Validating here rather
  # than trusting the staple's exit code: a ticket that did not attach must fail the release, not
  # ship an app that looks fine until someone launches it offline.
  step "Stapling the app bundles"
  for app in "SlopDesk.app" "SlopDeskHost.app"; do
    xcrun stapler staple "${STAGE}/${app}"
    xcrun stapler validate "${STAGE}/${app}" ||
      die "no ticket stapled to ${app} — the image would ship an app that fails first launch offline"
  done
fi

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

# ── 5. Notarize the containers ──────────────────────────────────────────────────────────────
# The app bundles were notarized + stapled in 3b, before the image was built. This round covers
# the two containers, which carry no ticket of their own yet. `notarize()` is defined above 3b.
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

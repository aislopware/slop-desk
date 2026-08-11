#!/usr/bin/env bash
# Write one version string into every place that carries it.
#
# `package-release.sh` has a drift gate, but it can only compare the CLI's compiled-in
# version against the version it was asked to build — it cannot see the other five sites,
# so `CFBundleShortVersionString` sat a release behind twice without failing anything.
# This script is the reason that cannot happen again: one argument, six writes, and a
# verification pass that greps every site back.
#
# THE SIXTH SITE IS GENERATED AND COMMITTED. `Apps/*/Info.plist` is xcodegen's output
# from the spec's `info.properties`, and it is in git because a clean checkout has to
# build without running xcodegen first. Editing the spec alone leaves the plist stale, so
# the regeneration happens here rather than in a step someone remembers.
#
#   scripts/bump-version.sh 0.2.3
#
# Called by `cut-release.sh`; safe to run on its own when a version has to be corrected
# without cutting anything.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

die() {
  echo "bump-version: $*" >&2
  exit 1
}

VERSION="${1:-}"
[[ -n "${VERSION}" ]] || die "usage: bump-version.sh <version>   (e.g. 0.2.3, no leading v)"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
  die "not a semver without a leading v: ${VERSION}"

# The two Swift constants and the two specs. Each pattern anchors on the KEY, so the
# replacement cannot wander into some other quoted string in the same file.
swift_sites=(
  "Sources/SlopDeskCLICore/CLIVersion.swift|public static let version = "
  "Sources/SlopDeskHost/HostEnvironment.swift|public static let buildVersion = "
)
for site in "${swift_sites[@]}"; do
  file="${site%%|*}"
  key="${site#*|}"
  [[ -f "${file}" ]] || die "missing ${file} — has the constant moved?"
  grep -qF "${key}" "${file}" || die "no \`${key}\` in ${file} — the anchor moved"
  perl -pi -e "s/\Q${key}\E\"[^\"]*\"/${key}\"${VERSION}\"/" "${file}"
done

for spec in Apps/ClientApp-macOS/project.yml Apps/HostApp-macOS/project.yml; do
  [[ -f "${spec}" ]] || die "missing ${spec}"
  perl -pi -e "s/^(\s*CFBundleShortVersionString:\s*)\"[^\"]*\"/\${1}\"${VERSION}\"/" "${spec}"
  perl -pi -e "s/^(\s*MARKETING_VERSION:\s*)\"[^\"]*\"/\${1}\"${VERSION}\"/" "${spec}"
done

# Regenerate the committed plists from the specs just edited. xcodegen also rewrites the
# gitignored .xcodeproj, which is fine — it is derived either way.
command -v xcodegen > /dev/null || die "xcodegen not on PATH (brew install xcodegen)"
for spec in Apps/ClientApp-macOS/project.yml Apps/HostApp-macOS/project.yml; do
  xcodegen generate --spec "${spec}" --quiet
done

# Read every site back. A silent no-op perl substitution (an anchor that drifted, a spec
# key that got requoted) is exactly the failure this script exists to prevent, so the
# check is on the FILES, not on this script's own belief about what it wrote.
expected_sites=(
  "Sources/SlopDeskCLICore/CLIVersion.swift"
  "Sources/SlopDeskHost/HostEnvironment.swift"
  "Apps/ClientApp-macOS/project.yml"
  "Apps/HostApp-macOS/project.yml"
  "Apps/ClientApp-macOS/Info.plist"
  "Apps/HostApp-macOS/Info.plist"
)
failed=0
for file in "${expected_sites[@]}"; do
  if grep -qF "${VERSION}" "${file}"; then
    echo "  ok   ${file}"
  else
    echo "  FAIL ${file} — no ${VERSION} after the write" >&2
    failed=1
  fi
done
[[ "${failed}" -eq 0 ]] || die "at least one site did not take the version"

# Any OTHER version-shaped string left in these files is a site this script does not know
# about, or a stale one it failed to reach. Either way the next release inherits the drift.
stale="$(grep -rnE '"[0-9]+\.[0-9]+\.[0-9]+"' "${expected_sites[@]}" |
  grep -vF "\"${VERSION}\"" || true)"
if [[ -n "${stale}" ]]; then
  echo "bump-version: a version string that is not ${VERSION} survived:" >&2
  echo "${stale}" >&2
  die "add the site to this script or fix the file"
fi

echo "bump-version: every site reads ${VERSION}"

#!/usr/bin/env bash
# Cut a release: decide the version, write the notes, bump the six sites, commit, tag.
#
# This is `lerna version --conventional-commits` for a repo with no package.json. The
# shape is borrowed from `better-update`'s pipeline deliberately — one convention on
# commit subjects, read twice: once by `git cliff --bumped-version` to turn feat/fix into
# minor/patch, once by `git cliff --output` to render what the GitHub Release ships. What
# differs is only where the version lives, which is why `bump-version.sh` exists at all.
#
#   scripts/cut-release.sh                # version computed from the commits since the last tag
#   scripts/cut-release.sh 0.3.0          # version forced
#   scripts/cut-release.sh --dry-run      # print the plan and the notes, touch nothing
#
# It does NOT push. The tag push is what starts the signing pipeline, and that stays a
# separate, deliberate keystroke:
#
#   git push origin main && git push origin v<version>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

die() {
  echo "cut-release: $*" >&2
  exit 1
}
step() { echo "── $* ────────────────────────────────────────"; }

DRY_RUN=0
VERSION=""
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -*) die "unknown flag: ${arg}" ;;
    *) VERSION="${arg#v}" ;;
  esac
done

command -v git-cliff > /dev/null || die "git-cliff not on PATH (brew install git-cliff)"
command -v xcodegen > /dev/null || die "xcodegen not on PATH (brew install xcodegen)"

# A release is cut FROM a branch, not from a detached checkout, and from main because the
# tag has to be reachable from the branch the tap and the docs point at.
branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "${branch}" == "main" ]] || die "on ${branch}; releases are cut from main"

# A dirty tree means the release commit would carry work nobody reviewed as part of it,
# and the bump would land on top of edits that were never built.
if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty — commit or stash first"
fi

step "Deciding the version"
if [[ -z "${VERSION}" ]]; then
  VERSION="$(git-cliff --bumped-version 2> /dev/null)" ||
    die "git cliff could not compute a version (no conventional commits since the last tag?)"
  VERSION="${VERSION#v}"
  echo "computed from the commits since the last tag: ${VERSION}"
else
  echo "forced on the command line: ${VERSION}"
fi
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
  die "not a semver: ${VERSION}"

git rev-parse -q --verify "refs/tags/v${VERSION}" > /dev/null &&
  die "v${VERSION} already exists — pass a different version or delete the tag"

step "Rendering CHANGELOG.md"
# `--tag` tells git-cliff to render the unreleased commits UNDER the version about to be
# tagged, rather than leaving them in an "Unreleased" section the release could not slice.
git-cliff --tag "v${VERSION}" --output CHANGELOG.md
notes="$(scripts/changelog-section.sh "${VERSION}")" ||
  die "the rendered changelog has no ${VERSION} section"

if [[ "${DRY_RUN}" == "1" ]]; then
  step "Dry run — the release body would be"
  printf '%s\n' "${notes}"
  git checkout -- CHANGELOG.md 2> /dev/null || rm -f CHANGELOG.md
  echo
  echo "cut-release: nothing was written. Re-run without --dry-run to cut v${VERSION}."
  exit 0
fi

step "Writing the version into every site"
scripts/bump-version.sh "${VERSION}"

step "Committing and tagging"
git add CHANGELOG.md \
  Sources/SlopDeskCLICore/CLIVersion.swift \
  Sources/SlopDeskHost/HostEnvironment.swift \
  Apps/ClientApp-macOS/project.yml Apps/ClientApp-macOS/Info.plist \
  Apps/HostApp-macOS/project.yml Apps/HostApp-macOS/Info.plist

# `chore(release)` is the one subject `cliff.toml` skips, so the release commit never
# appears in the notes of the release after it.
git commit -m "chore(release): v${VERSION}"
git tag -a "v${VERSION}" -m "v${VERSION}"

cat << EOF

cut-release: v${VERSION} is committed and tagged, and nothing has left this machine.

  Review:  git show --stat HEAD
  Ship:    git push origin main && git push origin v${VERSION}
  Undo:    git tag -d v${VERSION} && git reset --hard HEAD~1
EOF

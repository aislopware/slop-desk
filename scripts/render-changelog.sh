#!/usr/bin/env bash
# Write CHANGELOG.md from the commit log. The ONLY thing that may write that file.
#
# It exists for one byte. The body template in `cliff.toml` ends every release with a blank
# line so the next `## [x.y.z]` heading is not glued to the previous release's last bullet,
# which leaves the final release trailing that blank line at end-of-file. `end-of-file-fixer`
# (a pre-commit hook) then rewrites the file — so `cut-release.sh` failed its own commit on a
# file it had generated seconds earlier, mid-cut, with the six version sites already written.
#
# `postprocessors` in cliff.toml cannot fix it: they run per RELEASE, not over the finished
# document, so a `\n+$` rule strips the separator from every body and glues the headings
# together while leaving end-of-file exactly as it was.
#
#   scripts/render-changelog.sh                # rewrite CHANGELOG.md as it stands
#   scripts/render-changelog.sh --tag v0.3.0   # file the pending commits under a version
#
# Any argument is passed through to git-cliff.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

command -v git-cliff > /dev/null || {
  echo "render-changelog: git-cliff not on PATH (brew install git-cliff)" >&2
  exit 1
}

# `$(...)` strips every trailing newline and printf puts back exactly one. Rendered to a
# variable rather than `--output` so a git-cliff that fails leaves the committed CHANGELOG.md
# untouched instead of truncated.
rendered="$(git-cliff "$@")"

# A REGEX match, never `${rendered//[[:space:]]/}`. Global pattern substitution in bash is
# quadratic in the length of the string: on this 32 KB changelog the "is it blank" check
# alone burned 57 s of CPU, turning a 1 s render into a minute.
if [[ ! "${rendered}" =~ [^[:space:]] ]]; then
  echo "render-changelog: git-cliff produced an empty changelog — refusing to overwrite" >&2
  exit 1
fi

printf '%s\n' "${rendered}" > CHANGELOG.md

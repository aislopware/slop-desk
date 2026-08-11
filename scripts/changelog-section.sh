#!/usr/bin/env bash
# Print the CHANGELOG.md section for one version.
#
# The GitHub Release body is this slice. Before it, the body was nine fixed lines that
# named an architecture and two brew commands, identical in every release — nothing in it
# said which version it hung on, so opening `v0.2.1` and `v0.2.2` taught a reader the same
# nothing. The changelog is generated from the commit log by git-cliff, so the notes cost
# nothing per release and cannot drift from what actually shipped.
#
#   scripts/changelog-section.sh 0.2.3
#
# Exits non-zero when the version has no section. That is the release gate: `cut-release.sh`
# runs it before tagging, and the publish job runs it before creating the Release, so a tag
# whose notes were never generated fails loudly instead of shipping the fallback prose.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${1:-}"
CHANGELOG="${2:-${REPO_ROOT}/CHANGELOG.md}"

if [[ -z "${VERSION}" ]]; then
  echo "usage: changelog-section.sh <version> [changelog]" >&2
  exit 2
fi
VERSION="${VERSION#v}"

if [[ ! -f "${CHANGELOG}" ]]; then
  echo "changelog-section: no ${CHANGELOG}" >&2
  exit 1
fi

# git-cliff renders `## [0.2.3](compare-url) — 2026-08-11`. Match on the bracketed version
# alone: the date moves with the tag and the URL moves with the previous tag, so neither is
# safe to anchor on. Collect, then trim the blank lines the next heading leaves behind.
section="$(awk -v want="## [${VERSION}]" '
  /^## / {
    if (found) exit
    # index(), not a regex: the dots in a version are regex wildcards, and "0.2.3" would
    # then also match a heading reading "0x2y3".
    if (index($0, want) == 1) { found = 1; next }
    next
  }
  found { lines[n++] = $0 }
  END {
    start = 0
    while (start < n && lines[start] ~ /^[[:space:]]*$/) start++
    stop = n - 1
    while (stop >= start && lines[stop] ~ /^[[:space:]]*$/) stop--
    for (i = start; i <= stop; i++) print lines[i]
  }
' "${CHANGELOG}")"

if [[ -z "${section//[[:space:]]/}" ]]; then
  echo "changelog-section: CHANGELOG.md has no entry for ${VERSION}." >&2
  echo "  Regenerate it:  git cliff --output CHANGELOG.md" >&2
  echo "  Or cut properly: scripts/cut-release.sh" >&2
  exit 1
fi

printf '%s\n' "${section}"

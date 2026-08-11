#!/usr/bin/env bash
# Reject a commit subject that is not a conventional commit.
#
# `better-update` gets this from commitlint (`@commitlint/config-conventional`) on
# lefthook's commit-msg hook. Same job, no Node: the whole rule is a regex, and this repo's
# hook config is `language: system` throughout on purpose — nothing to provision, nothing
# to cache-miss, so the check costs a process spawn.
#
# The convention is not decoration. `cliff.toml` reads the TYPE to decide which section of
# CHANGELOG.md a commit lands in, and `git cliff --bumped-version` reads it again to turn
# feat/fix/`!` into minor/patch/major. A subject outside the grammar is dropped from the
# changelog silently and contributes nothing to the version — which is precisely the
# failure this hook exists to make loud and early.
#
#   scripts/check-commit-msg.sh .git/COMMIT_EDITMSG
set -euo pipefail

FILE="${1:?usage: check-commit-msg.sh <path-to-commit-message-file>}"
[[ -f "${FILE}" ]] || {
  echo "check-commit-msg: no such file: ${FILE}" >&2
  exit 2
}

# The subject is the first line that is neither blank nor a comment. Reading line 1 blindly
# fails on a `git commit` whose template puts a comment first.
subject="$(grep -m 1 -vE '^\s*(#|$)' "${FILE}" || true)"

if [[ -z "${subject}" ]]; then
  echo "check-commit-msg: empty commit message" >&2
  exit 1
fi

# git's own machinery writes these, and they are rewritten or dropped before they reach
# main. Holding them to the grammar would block `--fixup`, `--squash` and conflict resolution.
case "${subject}" in
  "Merge "* | "Revert "* | "fixup!"* | "squash!"* | "amend!"*) exit 0 ;;
  *) ;; # everything else is held to the grammar below
esac

TYPES='build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test'

# type(optional scope)optional !: subject
if [[ ! "${subject}" =~ ^(${TYPES})(\([a-z0-9][a-z0-9._/-]*\))?!?:\ .+ ]]; then
  cat >&2 << EOF
check-commit-msg: the subject is not a conventional commit.

  got:  ${subject}

  want: <type>[(scope)][!]: <subject>
  type: ${TYPES//|/, }
        \`!\` or a "BREAKING CHANGE:" trailer marks a breaking change.

  e.g.  fix(release): staple the ticket to each .app before it enters the image
        feat(rail)!: the pane id is a UUID, not an index

Why: cliff.toml reads the type to place this commit in CHANGELOG.md, and
\`git cliff --bumped-version\` reads it to compute the next version. A subject
outside the grammar is silently absent from both.
EOF
  exit 1
fi

# 72 is where GitHub starts ellipsing a subject in the commit list, and the changelog
# renders one bullet per subject — a truncated bullet is a bullet that says less than it
# cost. A warning, not a failure: an accurate long subject beats a short vague one.
if [[ "${#subject}" -gt 72 ]]; then
  echo "check-commit-msg: subject is ${#subject} chars; GitHub ellipses past 72." >&2
fi

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
        feat(rail)!: key the pane id on a UUID instead of an index

Why: cliff.toml reads the type to place this commit in CHANGELOG.md, and
\`git cliff --bumped-version\` reads it to compute the next version. A subject
outside the grammar is silently absent from both.
EOF
  exit 1
fi

# ── Style ────────────────────────────────────────────────────────────────────────────
# Everything below governs the TEXT after the colon. It is enforced because that text is
# published: `changelog-section.sh` slices these subjects out of CHANGELOG.md and the
# GitHub Release body is one bullet per subject, verbatim. A subject written to be read
# inside the repo becomes a release note read by someone who has never seen the repo.
#
# The rule is: say what the change DOES, in the imperative, to a reader who was not here.
text="${subject#*: }"
first="${text%% *}"

style_error() {
  cat >&2 << EOF
check-commit-msg: the subject is a conventional commit, but not a plain one.

  got:   ${subject}
  issue: $1
  want:  $2

The release body is one bullet per subject, verbatim (scripts/changelog-section.sh).
Detail that does not fit belongs in the commit BODY, which the changelog never reads.
EOF
  exit 1
}

# A subject opening on an article is a sentence ABOUT the code rather than an instruction
# to it — "the plate stops sliding between projects" describes a scene, and the reader of a
# release note has to reverse-engineer what changed and whether it affects them.
case "${first}" in
  [Tt]he | [Aa] | [Aa]n)
    style_error "opens with the article \"${first}\" — that is a description, not a change" \
      "start with a verb: what does this commit DO? (\"stop the plate sliding between projects\")"
    ;;
  *) ;;
esac

# Imperative mood, the same one `git revert`/`git merge` write for you. Third person is the
# most common slip and is mechanically clear; a gerund is checked separately below because
# real imperatives end in -ing too ("bring", "string").
case "${first}" in
  [Aa]dds | [Bb]umps | [Cc]hanges | [Dd]rops | [Ff]ixes | [Kk]eeps | [Mm]akes | [Mm]oves | \
    [Rr]emoves | [Rr]enames | [Ss]tops | [Uu]pdates | [Uu]ses | [Aa]dded | [Ff]ixed | \
    [Cc]hanged | [Rr]emoved | [Uu]pdated)
    style_error "\"${first}\" is not the imperative" \
      "write it as an instruction: \"add\", \"fix\", \"drop\", \"rename\""
    ;;
  *) ;;
esac

# A subject is a title. The period buys nothing and the changelog renders it mid-bullet.
case "${text}" in
  *.)
    style_error "ends in a full stop" "drop the trailing period"
    ;;
  *) ;;
esac

# 72 is where GitHub ellipses a subject in the commit list AND where the rendered changelog
# bullet stops being scannable. Hard, not a warning: the fix is always available — move the
# detail into the body, which is where the argument for a change belongs anyway.
if [[ "${#subject}" -gt 72 ]]; then
  style_error "the subject is ${#subject} chars; GitHub ellipses past 72" \
    "cut it to 72 and move the rest into the commit body"
fi

# Gerunds are usually a slipped mood ("Adding X" for "Add X"), but "bring"/"ping"/"string"
# are imperatives that end the same way — so this one advises rather than blocks.
if [[ "${first}" =~ ing$ ]] && [[ ! "${first}" =~ ^([Bb]ring|[Pp]ing|[Ss]tring|[Rr]ing|[Ss]ing)$ ]]; then
  echo "check-commit-msg: \"${first}\" reads as a gerund; the imperative is usually shorter and clearer." >&2
fi

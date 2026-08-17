#!/usr/bin/env bash
# bump-tool-versions.sh — move each sidecar's OWN version, and only the ones that moved.
#
# WHY THIS IS SEPARATE FROM `bump-version.sh`
#   `bump-version.sh` writes ONE number into six places, and those six are the PRODUCT: the CLI
#   banner, the host's `TERM_PROGRAM_VERSION`, and four app-bundle sites. They move together
#   because they describe one thing the user installed.
#
#   A sidecar is not that. Each runs as its own process with its own lifetime, and the expensive
#   ones outlive the release that installed them — superd holds the master fd of every live pane,
#   so restarting it costs the user every running agent (`docs/51`). Under one shared number there
#   was no way to say "the Android bridge changed and superd did not", so every upgrade restarted
#   everything, and a one-line fix in a panel nobody had open cost a desk full of panes.
#
# THE TWO QUESTIONS, AND WHY THE STAMP ANSWERS THE FIRST
#   *Did this tool change?* — `tool-stamps.sh`, a digest of the tool's source closure against the
#   value `scripts/tool-stamps.pin` recorded at the last release. Not the commit log: a commit
#   touching `rust/slopdesk-screend/README.md` is in the log and changes no binary, and a commit
#   touching `rust/slopdesk-sanitize` is a change to screend and superd while naming neither.
#
#   *By how much?* — the commit log, scoped to the same closure, read with the conventional-commit
#   grammar `scripts/check-commit-msg.sh` already enforces. Same rules `cut-release.sh` applies to
#   the product: `!` or a `BREAKING CHANGE:` trailer is major (below 1.0, the minor), `feat` the
#   minor, `fix`/`perf`/`refactor` the patch.
#
#   WHEN THE TWO DISAGREE THE STAMP WINS, in both directions, and neither default is arbitrary:
#     * stamp unchanged, commits present → NO bump. The commits reached a path in the closure
#       without changing a hashed file (a README, a fixture), so there is nothing to ship and a
#       version that moved would restart a daemon to install the identical binary.
#     * stamp changed, no bump-worthy commit → PATCH. Something in the closure really is
#       different; refusing to bump would ship it under the old version and the install side would
#       skip the restart, leaving the user running code the release did not contain. A patch is
#       the smallest honest answer.
#
#   scripts/bump-tool-versions.sh --dry-run     # print the plan, write nothing
#   scripts/bump-tool-versions.sh               # write the crate versions and rewrite the pin
#
# Called by `cut-release.sh` before it renders the changelog. Safe to run alone.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=scripts/shipped-tools.sh
source "${REPO_ROOT}/scripts/shipped-tools.sh"

STAMPS="${REPO_ROOT}/scripts/tool-stamps.sh"
PIN="${REPO_ROOT}/scripts/tool-stamps.pin"

die() {
  echo "bump-tool-versions: $*" >&2
  exit 1
}

DRY_RUN=0
for argument in "$@"; do
  case "${argument}" in
    --dry-run) DRY_RUN=1 ;;
    *) die "unknown flag: ${argument}   (--dry-run)" ;;
  esac
done

[[ -f "${PIN}" ]] || die "no ${PIN} — seed it with \`scripts/tool-stamps.sh\` under its header"

# The release this tree is measured against. Commits BEFORE it already shipped, so they cannot be
# evidence that a tool changed since. A repo with no tag at all measures from the root commit,
# which is the honest answer for a first release rather than an error.
BASE_TAG="$(git describe --tags --abbrev=0 2> /dev/null || true)"
if [[ -n "${BASE_TAG}" ]]; then
  RANGE="${BASE_TAG}..HEAD"
else
  RANGE="HEAD"
fi

# `major` > `minor` > `patch` > `none`, so a scan can keep the highest it has seen.
rank_of() {
  case "$1" in
    major) printf '3\n' ;;
    minor) printf '2\n' ;;
    patch) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

# The largest bump the commits touching `$1`'s closure ask for, as a word.
#
# Reads subject AND body: a `BREAKING CHANGE:` trailer lives in the body, and `%s%x1f%b` keeps the
# two apart so a body line that merely quotes a subject cannot be parsed as one. `%x1e` ends each
# commit, because a body is many lines and `git log` would otherwise run them together.
bump_kind_for() {
  local tool="$1" paths kind best="none" subject body record
  mapfile -t paths < <("${STAMPS}" --paths --tool "${tool}")
  [[ "${#paths[@]}" -gt 0 ]] || die "${tool} has an empty path closure"

  while IFS= read -r -d $'\x1e' record; do
    subject="${record%%$'\x1f'*}"
    body="${record#*$'\x1f'}"
    subject="${subject#$'\n'}"

    kind="none"
    # `<type>[(scope)]!:` — the `!` is the breaking marker the grammar puts before the colon.
    if [[ "${subject}" =~ ^[a-z]+(\([^\)]*\))?! ]] || [[ "${body}" == *"BREAKING CHANGE:"* ]]; then
      kind="major"
    elif [[ "${subject}" =~ ^feat(\([^\)]*\))?: ]]; then
      kind="minor"
    elif [[ "${subject}" =~ ^(fix|perf|refactor)(\([^\)]*\))?: ]]; then
      kind="patch"
    fi

    [[ "$(rank_of "${kind}")" -gt "$(rank_of "${best}")" ]] && best="${kind}"
  done < <(git log "${RANGE}" --no-merges --format="%s%x1f%b%x1e" -- "${paths[@]}")

  printf '%s\n' "${best}"
}

# `$1` moved by `$2`. Below 1.0 a breaking change moves the MINOR, which is semver's own rule and
# the one `cut-release.sh` applies to the product — a 0.x major bump would claim a stability this
# tree has not promised.
next_version() {
  local current="$1" kind="$2" major minor patch
  IFS=. read -r major minor patch <<< "${current%%[-+]*}"
  [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ && "${patch}" =~ ^[0-9]+$ ]] ||
    die "not a semver in a Cargo.toml: ${current}"
  case "${kind}" in
    major)
      if [[ "${major}" -eq 0 ]]; then
        printf '0.%d.0\n' "$((minor + 1))"
      else
        printf '%d.0.0\n' "$((major + 1))"
      fi
      ;;
    minor) printf '%d.%d.0\n' "${major}" "$((minor + 1))" ;;
    patch) printf '%d.%d.%d\n' "${major}" "${minor}" "$((patch + 1))" ;;
    *) printf '%s\n' "${current}" ;;
  esac
}

# Write `version = "X"` into a crate's `[package]` table and read it back. Anchored on the table,
# not on the first `version =` in the file: a `[dependencies]` entry three lines down is spelled
# the same way, and rewriting THAT is a broken build with a plausible-looking diff.
write_crate_version() {
  local crate="$1" version="$2"
  local manifest="${REPO_ROOT}/rust/${crate}/Cargo.toml"
  [[ -f "${manifest}" ]] || die "missing ${manifest}"
  perl -0pi -e "s/(\[package\][^\[]*?\nversion = )\"[^\"]*\"/\${1}\"${version}\"/s" "${manifest}"
  local readback
  readback="$(
    awk '
      /^\[package\]/ { in_package = 1; next }
      /^\[/          { in_package = 0 }
      in_package && /^version *=/ { gsub(/^version *= *"|"$/, ""); print; exit }
    ' "${manifest}"
  )"
  [[ "${readback}" == "${version}" ]] ||
    die "rust/${crate}/Cargo.toml still reads ${readback:-<nothing>} after the write — the anchor moved"

  # THE LOCK CARRIES THE PACKAGE'S OWN VERSION TOO, and leaving it stale is not cosmetic: the next
  # `cargo build` rewrites it, and that build is `package-release.sh` — running AFTER `cut-release`
  # committed and tagged. The result is a tag whose tree does not build clean and a lock file
  # dirtied by the release itself.
  #
  # `cargo update -p <crate> --offline` and nothing broader. `generate-lockfile` would re-resolve
  # every dependency, which is a version bump nobody asked for riding in on a release commit;
  # `--offline` means it cannot reach a registry to find one even if the resolver wanted to. The
  # one package named is the one whose version just moved.
  local workspace="${REPO_ROOT}/rust/${crate}"
  # A root-workspace member's lock is the SHARED `rust/Cargo.lock`, so the update runs from there.
  # `rust/Cargo.toml` excludes the daemons, so the same invocation from `rust/` could not see one.
  if [[ ! -f "${workspace}/Cargo.lock" ]]; then
    workspace="${REPO_ROOT}/rust"
  fi
  (cd "${workspace}" && cargo update --offline --quiet -p "${crate}") ||
    die "could not update ${workspace#"${REPO_ROOT}/"}/Cargo.lock for ${crate}"
}

# ── The plan ────────────────────────────────────────────────────────────────────────────────
# Computed for every tool BEFORE anything is written, so a `--dry-run` and a real run agree, and
# so a failure halfway leaves no crate bumped against a pin that never learned about it.
declare -a plan_tool=() plan_from=() plan_to=() plan_stamp=()
moved=0

while IFS= read -r line; do
  tool="${line%% *}"
  rest="${line#* }"
  current_version="${rest%% *}"
  current_stamp="${rest#* }"

  pinned_stamp="$(awk -v t="${tool}" '$1 == t { print $3 }' "${PIN}")"
  pinned_version="$(awk -v t="${tool}" '$1 == t { print $2 }' "${PIN}")"

  if [[ -n "${pinned_stamp}" && "${current_stamp}" == "${pinned_stamp}" ]]; then
    plan_tool+=("${tool}")
    plan_from+=("${current_version}")
    plan_to+=("${current_version}")
    plan_stamp+=("${current_stamp}")
    printf '  same     %-22s %s\n' "${tool}" "${current_version}"
    continue
  fi

  kind="$(bump_kind_for "${tool}")"
  # The stamp is what says a binary changed, so a changed stamp always ships SOMETHING. See the
  # banner: refusing the bump here would leave the install side skipping a restart it needed.
  [[ "${kind}" == "none" ]] && kind="patch"
  target="$(next_version "${current_version}" "${kind}")"

  plan_tool+=("${tool}")
  plan_from+=("${current_version}")
  plan_to+=("${target}")
  plan_stamp+=("${current_stamp}")
  moved=1
  if [[ -z "${pinned_stamp}" ]]; then
    printf '  NEW      %-22s %s (never released)\n' "${tool}" "${target}"
  else
    printf '  %-8s %-22s %s → %s\n' "${kind}" "${tool}" "${pinned_version}" "${target}"
  fi
done < <("${STAMPS}")

if [[ "${moved}" -eq 0 ]]; then
  echo "bump-tool-versions: no sidecar changed since ${BASE_TAG:-the root commit} — nothing to bump"
  exit 0
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "bump-tool-versions: --dry-run, nothing written"
  exit 0
fi

# ── The writes ──────────────────────────────────────────────────────────────────────────────
# One crate may back two tools (`slopdesk-hook` and `slopdesk-agenthooks`), so the same version is
# written twice. That is idempotent and deliberate: they are one crate's two binaries.
for index in "${!plan_tool[@]}"; do
  [[ "${plan_from[${index}]}" == "${plan_to[${index}]}" ]] && continue
  crate="$(tool_crate "${plan_tool[${index}]}")"
  write_crate_version "${crate}" "${plan_to[${index}]}"
done

# The stamps are RE-READ rather than reused from the plan, because the writes above changed a
# `Cargo.toml` inside every bumped tool's own closure — the plan's values describe the tree as it
# was a moment ago, and pinning those would report every bumped tool as changed again tomorrow.
{
  awk '/^#/ { print; next } { exit }' "${PIN}"
  "${STAMPS}"
} > "${PIN}.new"
mv "${PIN}.new" "${PIN}"

echo "bump-tool-versions: crate versions written and ${PIN#"${REPO_ROOT}/"} rewritten"

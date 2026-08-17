#!/usr/bin/env bash
# tool-stamps.sh — the content stamp of every shipped cargo tool, one line each.
#
# WHY THIS EXISTS
#   Every sidecar in this tree runs as its own process with its own lifetime, and the expensive
#   ones outlive the release that installed them: superd holds the master fd of every live pane, so
#   restarting it costs the user every running agent (`docs/51`, `scripts/install-superd.sh`).
#   Under one product version that price was paid on EVERY upgrade — a one-line fix in the Android
#   bridge and superd came down with it, because nothing could tell that superd had not changed.
#
#   This script is what can tell. It hashes each tool's own sources, so "did this daemon change"
#   is a question with an answer, and `bump-tool-versions.sh` turns that answer into a per-tool
#   version that only moves when the tool did. `MANIFEST.json` in the release tarball carries
#   those versions, and the install side restarts the daemons whose version moved and leaves the
#   rest running.
#
# WHAT IS IN A STAMP, AND WHY EACH PART
#   * the crate's own `*.rs`, `Cargo.toml` and `Cargo.lock` — the code and the dependency pins
#   * the same, transitively, for every LOCAL path dependency: a fix in `slopdesk-sanitize` is a
#     change to screend and to superd, both of which link it, and to nothing else
#   * for a ROOT-WORKSPACE tool, `rust/Cargo.toml` and `rust/Cargo.lock` on top — the release
#     profile and the lint set live in the workspace, not in the member, and `opt-level = "z"`
#     decides what the binary IS
#
#   Derived from the cargo graph rather than a hand-kept list, for the reason `build-ffi.sh` gives
#   at length: a list beside the code is a second list to forget, and forgetting THIS one does not
#   fail loudly — it reports a changed daemon as unchanged, which is the one wrong answer that
#   silently skips the restart the change needed.
#
# WHAT IS DELIBERATELY *NOT* IN A STAMP
#   THIS SCRIPT. `build-ffi.sh` hashes itself because editing it changes the artifact it produces;
#   editing this one changes no binary at all. Self-inclusion would make every tool look changed
#   on the day someone fixes a comment here, and every daemon would be restarted to ship nothing.
#   The toolchain version is absent for a weaker reason: it genuinely does change the binary, but
#   it changes EVERY binary at once, which is a product-version event and not a per-tool one.
#
#   scripts/tool-stamps.sh                  # every tool: "<tool> <version> <stamp>"
#   scripts/tool-stamps.sh --check          # name the tools whose stamp left scripts/tool-stamps.pin
#   scripts/tool-stamps.sh --tool slopdesk-superd
#
# The printed form is EXACTLY the pin's format, so seeding or rewriting `scripts/tool-stamps.pin`
# is this script's output under a header rather than a second thing to keep in step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=scripts/shipped-tools.sh
source "${REPO_ROOT}/scripts/shipped-tools.sh"

PIN="${REPO_ROOT}/scripts/tool-stamps.pin"

die() {
  echo "tool-stamps: $*" >&2
  exit 1
}

# Every crate whose sources decide whether `$1` is stale: the crate and, transitively, its local
# path dependencies. Printed one `rust/<crate>` per line, each at most once.
#
# The `path = "../x"` form is the only one this tree uses for a local dependency, and the grep
# anchors on it. A dependency written any other way (a `[dependencies.x]` table, a registry
# version) would go unseen — so the caller checks that the answer is non-empty, and a crate that
# declares path dependencies this cannot read fails here rather than hashing a partial closure.
crate_closure() {
  local root_crate="$1"
  local -a seen=()
  local -a queue=("${root_crate}")
  local crate listed dep known

  while [[ "${#queue[@]}" -gt 0 ]]; do
    crate="${queue[0]}"
    queue=("${queue[@]:1}")

    known=0
    for listed in ${seen[@]+"${seen[@]}"}; do
      [[ "${listed}" == "${crate}" ]] && known=1 && break
    done
    [[ "${known}" -eq 1 ]] && continue

    [[ -f "${REPO_ROOT}/rust/${crate}/Cargo.toml" ]] ||
      die "${crate} is a path dependency with no Cargo.toml — the cargo graph is broken"
    seen+=("${crate}")

    while IFS= read -r dep; do
      [[ -n "${dep}" ]] && queue+=("${dep}")
    done < <(
      grep -oE '^[a-z0-9_-]+ *= *\{ *path *= *"\.\./[a-z0-9_-]+"' \
        "${REPO_ROOT}/rust/${crate}/Cargo.toml" | sed -E 's:.*\.\./::; s:"::'
    )
  done

  printf 'rust/%s\n' "${seen[@]}"
}

# The files that make up `$1`'s stamp, one path per line, unsorted.
#
# `target` is PRUNED, and that is load-bearing rather than tidiness — `build-ffi.sh` records the
# whole story: build scripts write real `.rs` under `target/`, and a triple built for the first
# time MINTS one, so an unpruned stamp changes as a consequence of being checked.
stamp_inputs() {
  local tool="$1" crate dir
  crate="$(tool_crate "${tool}")" || die "${tool} is not a cargo tool"

  while IFS= read -r dir; do
    find "${REPO_ROOT}/${dir}" -name target -prune -o \
      \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' \) -print
  done < <(crate_closure "${crate}")

  # A root-workspace member inherits the profile and the lint set from `rust/Cargo.toml`, and its
  # dependency versions from the SHARED `rust/Cargo.lock` — neither of which sits under the crate
  # directory the walk above covers. A daemon needs no such addition: its workspace IS its crate
  # directory, so its own manifest and lock are already in the walk.
  if tools_contains "${tool}" "${RUST_ROOT_TOOLS[@]}"; then
    printf '%s\n%s\n' "${REPO_ROOT}/rust/Cargo.toml" "${REPO_ROOT}/rust/Cargo.lock"
  fi
}

# `find | sort` rather than a glob so the order is stable across machines, and `shasum` over the
# concatenation rather than per-file so a DELETED file changes the stamp too. The file NAMES are
# part of the inner digest, so a rename is a change even when the bytes are not.
stamp_of() {
  stamp_inputs "$1" | sort -u | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}'
}

# The stamp `scripts/tool-stamps.pin` recorded for `$1` at its last release, or nothing when the
# pin has never heard of it — which is how a NEW tool reads as changed on its first release.
pinned_stamp() {
  [[ -f "${PIN}" ]] || return 0
  awk -v tool="$1" '$1 == tool { print $3 }' "${PIN}"
}

# The version `scripts/tool-stamps.pin` recorded for `$1`, or nothing.
pinned_version() {
  [[ -f "${PIN}" ]] || return 0
  awk -v tool="$1" '$1 == tool { print $2 }' "${PIN}"
}

# The version `$1`'s crate declares today — the source of truth, which the pin only records.
declared_version() {
  local crate
  crate="$(tool_crate "$1")" || die "$1 is not a cargo tool"
  awk '
    /^\[package\]/ { in_package = 1; next }
    /^\[/          { in_package = 0 }
    in_package && /^version *=/ {
      gsub(/^version *= *"|"$/, "")
      print
      exit
    }
  ' "${REPO_ROOT}/rust/${crate}/Cargo.toml"
}

# Every shipped tool that is built by cargo, in the order the arrays declare them. The SwiftPM
# half — `slopdesk`, `slopdesk-hostd` — has no crate and no stamp: those two ARE the product, and
# the product version (`docs/49` §"The six version sites") is what moves for them.
cargo_tools() {
  printf '%s\n' "${RUST_TOOLS[@]}"
}

MODE="print"
ONE_TOOL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check" ;;
    --paths) MODE="paths" ;;
    --tool)
      shift
      ONE_TOOL="${1:-}"
      [[ -n "${ONE_TOOL}" ]] || die "--tool needs a tool name"
      ;;
    *) die "unknown flag: $1   (--check | --paths --tool <name> | --tool <name>)" ;;
  esac
  shift
done

# `--paths --tool <name>`: the repo-relative directories whose commits belong to this tool. Its own
# crate and every local crate it links, which is the same closure the stamp hashes — so
# `bump-tool-versions.sh` asks which COMMITS touched a tool without owning a second idea of what a
# tool is made of.
if [[ "${MODE}" == "paths" ]]; then
  [[ -n "${ONE_TOOL}" ]] || die "--paths needs --tool <name>"
  crate="$(tool_crate "${ONE_TOOL}")" || die "${ONE_TOOL} is not a shipped cargo tool"
  crate_closure "${crate}"
  # A root-workspace member's profile and lints live in the workspace manifest, so a commit that
  # touches only `rust/Cargo.toml` is a change to every member. Same reason `stamp_inputs` adds it.
  if tools_contains "${ONE_TOOL}" "${RUST_ROOT_TOOLS[@]}"; then
    printf 'rust/Cargo.toml\nrust/Cargo.lock\n'
  fi
  exit 0
fi

if [[ -n "${ONE_TOOL}" ]]; then
  tool_crate "${ONE_TOOL}" > /dev/null || die "${ONE_TOOL} is not a shipped cargo tool"
  printf '%s %s %s\n' "${ONE_TOOL}" "$(declared_version "${ONE_TOOL}")" "$(stamp_of "${ONE_TOOL}")"
  exit 0
fi

if [[ "${MODE}" == "print" ]]; then
  while IFS= read -r tool; do
    printf '%s %s %s\n' "${tool}" "$(declared_version "${tool}")" "$(stamp_of "${tool}")"
  done < <(cargo_tools)
  exit 0
fi

# --check: name what moved. Exit 1 when anything did, so a caller can branch on it; this is NOT a
# failure — a tool whose sources changed since the last release is the normal state of `main`.
drifted=0
while IFS= read -r tool; do
  current="$(stamp_of "${tool}")"
  pinned="$(pinned_stamp "${tool}")"
  if [[ -z "${pinned}" ]]; then
    echo "  NEW      ${tool} (no entry in scripts/tool-stamps.pin)"
    drifted=1
  elif [[ "${current}" != "${pinned}" ]]; then
    echo "  CHANGED  ${tool} ($(pinned_version "${tool}") → needs a bump)"
    drifted=1
  else
    echo "  same     ${tool} $(pinned_version "${tool}")"
  fi
done < <(cargo_tools)

exit "${drifted}"

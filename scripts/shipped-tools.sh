#!/usr/bin/env bash
# The shipped tool set, and the crate each tool is built from. SOURCED, never run.
#
# WHY THIS FILE EXISTS
#   These arrays used to live inside `scripts/package-release.sh`, which was fine while packaging
#   was the only thing that needed them. It no longer is: `tool-stamps.sh` needs the same set to
#   hash each tool's sources, `bump-tool-versions.sh` needs it to decide which versions may move,
#   and `check-invariants.py` reads it to prove the host resolves no sidecar the release omits.
#   Four readers of one list is three chances for a seventh daemon to be added to some of them.
#
#   So the list moved here and the readers all point at this file. That is the same bargain the
#   rest of the tree strikes — `build-ffi.sh` derives its input crates from the cargo graph,
#   `check-invariants.py` derives the wanted set from the `RustServicePaths` call sites — one
#   place says a thing, everything else asks.
#
# THE TARBALL USED TO BE THREE BINARIES, and that was a host that could not open a pane. superd
# forks and owns every PTY master (`docs/51`), and `HostServiceSupervisor.connected()` puts the
# consequence in one line — "hostd does not fork, so there is no fallback to have". The other five
# daemons each cost a feature outright: no screen engine, no file drop, no inspector, no Android
# panel, no profile seed. None of them shipped, because the release path is exercised by tagging
# and no gate is a release.
#
# shellcheck disable=SC2034 # every array here is read by the scripts that SOURCE this file
set -euo pipefail

# Built by SwiftPM, versioned by the PRODUCT version (`docs/49` §"The six version sites"). These
# two are the app the user installed; they do not carry a version of their own and must not.
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

# True when `$1` appears in the remaining arguments. Used to ask which group a tool is in without
# a second copy of the group memberships.
tools_contains() {
  local needle="$1"
  shift
  local candidate
  for candidate in "$@"; do
    [[ "${candidate}" == "${needle}" ]] && return 0
  done
  return 1
}

# The crate directory under `rust/` that builds `$1`, or nothing when the tool is not a cargo tool.
#
# Every name is its own crate EXCEPT `slopdesk-agenthooks`, which rides `slopdesk-hook`'s package
# — so the two share a version and a source stamp, and that is correct rather than a rounding
# error: they are one crate's two binaries and they ship or go stale together.
tool_crate() {
  local tool="$1"
  if [[ "${tool}" == "slopdesk-agenthooks" ]]; then
    printf 'slopdesk-hook\n'
    return 0
  fi
  if tools_contains "${tool}" "${RUST_ROOT_TOOLS[@]}" ||
    tools_contains "${tool}" "${RUST_CRATE_TOOLS[@]}"; then
    printf '%s\n' "${tool}"
    return 0
  fi
  return 1
}

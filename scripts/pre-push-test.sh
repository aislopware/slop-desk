#!/usr/bin/env bash
# The pre-push unit-test gate, with a green-tree cache + parallel execution.
#
# WHY: `swift test` costs ~60-90s per push, and most pushes happen on a tree that was ALREADY tested
# green (a `make check`, a manual `swift test`, or a previous push attempt minutes earlier). So the
# gate hashes the exact content being tested — `git rev-parse HEAD^{tree}` — and SKIPS the run when
# that hash matches the recorded last-green tree AND the working tree carries no un-committed change
# to the tested inputs (a dirty tree tests different content than HEAD, so it neither consults nor
# records the cache). Invalidation is automatic: any new commit changes the tree hash.
#
# `--parallel` fans the suite out across per-class xctest workers (~92s -> ~60s here). Safe because
# the global `Defaults.Keys` namespace is backed by `SettingsKey.store` — a per-PROCESS UserDefaults
# suite under XCTest — so workers cannot race each other through the shared standard domain.
#
# The marker lives under .build/ (never committed, wiped with the build dir).
# `make test` runs this same script, so a green `make test`/`make check` makes the next push instant.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# ── The sidecars the suite boots must EXIST before it runs ──────────────────────────────────────
# Eighteen suites start a real daemon — superd, screend, dropd — and every one of them `XCTSkip`s by
# name when its binary is missing. That is the right call inside a test: a skip named after the
# daemon beats a vacuous pass. It is the wrong outcome for a GATE, because `swift build` never sees
# cargo, so nothing in the Swift graph builds those binaries. Run this script on a tree that has not
# had `make test` against it and the whole supervised, screen and file-drop surface is skipped while
# the push reports green — the same "a gate that cannot fail" shape as a `make` target no one runs.
#
# The list is DERIVED from the fixtures rather than written here, so a nineteenth suite booting a
# new daemon is covered the day it lands. Each fixture spells `rust/slopdesk-<name>/target` and then
# looks for `{release,debug}/slopdesk-<name>`; an env override (`SLOPDESK_SUPERD_BIN` and friends)
# still wins inside the test, which is why the message names it.
missing=""
while IFS= read -r daemon; do
  [[ -x "rust/${daemon}/target/release/${daemon}" ]] && continue
  [[ -x "rust/${daemon}/target/debug/${daemon}" ]] && continue
  missing="${missing} ${daemon}"
done < <(grep -rhoE 'rust/slopdesk-[a-z]+/target' Tests --include='*.swift' | cut -d/ -f2 | sort -u)

if [[ -n ${missing} ]]; then
  echo "pre-push: these sidecars are not built, so the suites that boot them would XCTSkip and this" >&2
  echo "          gate would pass without running them:${missing}" >&2
  # The make target drops the `slopdesk-` prefix: the binary is `slopdesk-superd`, the target is
  # `superd`. Both spellings appear in the fixtures' own skip messages.
  echo "          run: make${missing//slopdesk-/}  (or 'make test', which does it and then runs this)" >&2
  echo "          A fixture may still be pointed elsewhere with its SLOPDESK_*_BIN override." >&2
  exit 1
fi

marker=.build/pre-push-green-tree
tree=$(git rev-parse 'HEAD^{tree}')

# The tree is only HALF the key. The Swift suite links `SlopDeskFFI.xcframework`, and the git tree
# cannot see it change: `rust/` is untracked, so `HEAD^{tree}` is byte-identical before and after a
# Rust edit, and adding `rust/` to the tested-inputs check below would not help for the same reason.
# On a clean tree that made the cache answer "already tested green" for a suite that had never run
# against the artifact `make test` had rebuilt one target earlier — the linked port's stale-artifact
# failure mode, one level above the `build-ffi.sh --check` gate that exists for it.
#
# `sources.sha256` is the right witness and already exists: `build-ffi.sh` writes it as the hash of
# every Rust input plus its own text. It lives in its OWN marker rather than being concatenated onto
# the tree, because `test-touched.sh` reads `pre-push-green-tree` as a git REF (`git cat-file -e`,
# `git diff "${base}"`) — a marker with a suffix stops being an object id and sends that script to
# the FULL suite for ever.
ffi_marker=.build/pre-push-green-ffi
ffi_stamp=$(cat ThirdParty/slopdesk-ffi/sources.sha256 2> /dev/null || true)

# Clean = nothing staged/modified/untracked among the inputs `swift test` actually consumes.
# `scripts/` is one of them and did not look like one: `LaunchRestoreGateContractTests` and
# `GuiGateLaunchContractTests` open `scripts/*.sh` and `scripts/fixtures/` off DISK at run time, so a
# scripts-only edit changes what the suite asserts while leaving every compiled input untouched.
# `test-touched.sh` already attributes such an edit to `SlopDeskClientUITests`; this half of the
# cache did not, and a green recorded over a dirty `scripts/` is a green about text nobody ran.
tested_inputs_clean() {
  [[ -z "$(git status --porcelain -- Package.swift Sources Tests Apps golden scripts 2> /dev/null)" ]]
}

if tested_inputs_clean && [[ -f ${marker} ]] && [[ "$(cat "${marker}")" == "${tree}" ]] &&
  [[ "$(cat "${ffi_marker}" 2> /dev/null || true)" == "${ffi_stamp}" ]]; then
  echo "pre-push: tree ${tree:0:12} already tested green — skipping swift test"
  exit 0
fi

swift test --parallel

if tested_inputs_clean; then
  echo "${tree}" > "${marker}"
  echo "${ffi_stamp}" > "${ffi_marker}"
fi

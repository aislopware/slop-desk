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

marker=.build/pre-push-green-tree
tree=$(git rev-parse 'HEAD^{tree}')

# Clean = nothing staged/modified/untracked among the inputs `swift test` actually consumes.
tested_inputs_clean() {
  [[ -z "$(git status --porcelain -- Package.swift Sources Tests Apps golden 2> /dev/null)" ]]
}

if tested_inputs_clean && [[ -f ${marker} ]] && [[ "$(cat "${marker}")" == "${tree}" ]]; then
  echo "pre-push: tree ${tree:0:12} already tested green — skipping swift test"
  exit 0
fi

swift test --parallel

if tested_inputs_clean; then
  echo "${tree}" > "${marker}"
fi

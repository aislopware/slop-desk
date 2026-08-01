#!/usr/bin/env bash
# The fast INNER-LOOP test gate: incremental build + ONLY the test targets the current
# change set can reach. The full `swift test --parallel` costs ~100s of pure execution
# even with a warm build; a typical single-module edit reaches 1-3 test targets and
# lands in ~10-50s total. Pre-push (scripts/pre-push-test.sh) stays the FULL gate.
#
# Selection: change set = working tree vs the last FULL-suite green tree (the pre-push
# marker) when available, else vs HEAD — so edits made across several commits since the
# last full run all stay in scope. Each changed path is attributed to its SwiftPM target
# via `swift package describe`, and every test target whose transitive dependencies
# include that target runs. Package.swift / golden/ changes, or any Sources/Tests path
# that cannot be attributed, escalate to the full suite. Non-SwiftPM paths (docs,
# scripts, Apps — Xcode-only) select nothing: the incremental build is their check.
#
# A touched-target green NEVER writes the pre-push green-tree marker — only a genuinely
# full green run on a clean tree does (same condition as pre-push-test.sh), so a partial
# pass can't make a push skip tests it never ran.
#
# ⚠️ The dependency graph cannot see SUBPROCESS SPAWNS or RUNTIME FILE READS; those edges
# are hand-mapped in the python below (slopdesk-hostd / slopdesk-client → SlopDeskClientTests
# for SubprocessE2ETests; scripts/ → SlopDeskClientUITests for the gate-contract tests).
# A new test that spawns a built binary or reads a repo path outside its own target dir
# MUST add its edge here, or its tests go silently unselected.
#
# Usage:
#   scripts/test-touched.sh                          # auto-detect from the change set
#   scripts/test-touched.sh SlopDeskHostTests ...    # explicit target override
#   scripts/test-touched.sh --dry-run                # print the selection, run nothing
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

dry_run=0
if [[ ${1:-} == "--dry-run" ]]; then
  dry_run=1
  shift
fi

# The dependency graph, cached — `swift package describe` costs ~1s+, Package.swift
# changes rarely.
graph=.build/pkg-describe.json
mkdir -p .build
if [[ ! -f ${graph} || Package.swift -nt ${graph} ]]; then
  swift package describe --type json > "${graph}"
fi

if [[ $# -gt 0 ]]; then
  selection="$*"
elif [[ ! -f .build/pre-push-green-tree ]] ||
  ! git cat-file -e "$(cat .build/pre-push-green-tree)" 2> /dev/null; then
  # No known-green baseline to diff against (fresh clone, wiped .build) — a diff vs bare
  # HEAD would silently absolve every commit since the last full run. Fail toward FULL;
  # one full green on a clean tree writes the marker and ends the penalty.
  echo "test-touched: no full-green baseline — running the FULL suite to establish one"
  selection=FULL
else
  base=$(cat .build/pre-push-green-tree)

  # The pathspec must list every repo path the tests CONSUME, not just what they compile:
  # scripts/ is read at runtime by the ClientUITests gate-contract tests, golden/ by the
  # sniffer golden guard, Package.resolved decides external dependency versions.
  selection=$(
    {
      git diff --name-only "${base}" -- Package.swift Package.resolved Sources Tests golden scripts
      git ls-files --others --exclude-standard -- Package.swift Package.resolved Sources Tests golden scripts
    } | sort -u | python3 -c '
import json
import sys

graph_path, changed = sys.argv[1], [line.strip() for line in sys.stdin if line.strip()]
targets = json.load(open(graph_path))["targets"]
deps = {t["name"]: t.get("target_dependencies", []) for t in targets}
tests = {t["name"] for t in targets if t["type"] == "test"}
by_path = sorted(((t["path"], t) for t in targets), key=lambda pair: -len(pair[0]))


def closure(name):
    seen, stack = set(), [name]
    while stack:
        for dep in deps.get(stack.pop(), []):
            if dep not in seen:
                seen.add(dep)
                stack.append(dep)
    return seen


reach = {test: closure(test) for test in tests}
picked, full = set(), False
for path in changed:
    if path in ("Package.swift", "Package.resolved") or path.startswith("golden/"):
        full = True
        continue
    if path.startswith("scripts/"):
        # GuiGateLaunchContractTests + LaunchRestoreGateContractTests read every
        # scripts/*.sh (and scripts/fixtures/) off disk at runtime.
        picked.add("SlopDeskClientUITests")
        continue
    hit = next((t for p, t in by_path if path.startswith(p + "/")), None)
    if hit is None:
        # A Sources/Tests file that belongs to no target — attribution failed, be safe.
        full = True
        continue
    if hit["type"] == "test":
        picked.add(hit["name"])
        continue
    picked.update(test for test in tests if hit["name"] in reach[test])
    if hit["name"] in ("slopdesk-hostd", "slopdesk-client"):
        # SubprocessE2ETests spawns the real hostd + client binaries — the graph
        # cannot see a subprocess edge.
        picked.add("SlopDeskClientTests")

if full or picked == tests:
    print("FULL")
elif picked:
    print(" ".join(sorted(picked)))
else:
    print("NONE")
' "${graph}"
  )
fi

if [[ ${dry_run} == 1 ]]; then
  echo "test-touched (dry-run): ${selection}"
  exit 0
fi

swift build --build-tests

case ${selection} in
  FULL)
    echo "test-touched: change set escalates to the FULL suite"
    swift test --parallel --skip-build
    # Mirror pre-push-test.sh: a full green on a clean tree warms the pre-push cache.
    if [[ -z "$(git status --porcelain -- Package.swift Sources Tests Apps golden 2> /dev/null)" ]]; then
      git rev-parse 'HEAD^{tree}' > .build/pre-push-green-tree
    fi
    ;;
  NONE)
    echo "test-touched: no SwiftPM test target reaches the change set — build was the gate"
    ;;
  *)
    echo "test-touched: running ${selection}"
    regex="^($(echo "${selection}" | tr ' ' '|'))\."
    swift test --parallel --skip-build --filter "${regex}"
    ;;
esac

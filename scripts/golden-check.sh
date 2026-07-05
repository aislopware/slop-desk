#!/usr/bin/env bash
# Golden regression pin (single-impl Swift, post-Rust-removal).
#
# The wire corpus `golden/golden_vectors.json` is the FROZEN source of truth for every codec's
# exact bytes. `slopdesk-corevectors` regenerates the emitted subset from the live native-Swift
# codecs; this script asserts they are byte-identical to the committed corpus. The remaining
# "frozen" keys (geometry/VD + nalu/sniffer/terminal-mode, which the generator does not emit) are
# pinned by their XCTest suites instead — do NOT add them here.
#
# This replaces the old cross-language Rust `golden_parity` test: there is no second implementation
# to diff against anymore, so it is a regression pin, not a parity proof. To UPDATE the corpus after
# an intentional wire change, regenerate with NO SLOPDESK_* env set and merge surgically — never
# `> golden/golden_vectors.json` (that drops the frozen keys the generator doesn't emit).
set -euo pipefail
cd "$(dirname "$0")/.."

CORPUS="golden/golden_vectors.json"
REGEN="$(mktemp -t slopdesk-golden.XXXXXX.json)"
trap 'rm -f "$REGEN"' EXIT

# The generator must resolve its compile-time-const defaults — strip any SLOPDESK_* override.
# shellcheck disable=SC2046 # intentional word-splitting builds the `-u VAR` unset-flag list
env $(env | grep '^SLOPDESK_' | cut -d= -f1 | sed 's/^/-u /' | tr '\n' ' ') \
  swift run -q slopdesk-corevectors > "${REGEN}"

python3 - "${CORPUS}" "${REGEN}" << 'PY'
import json, sys
corpus = json.load(open(sys.argv[1]))
regen = json.load(open(sys.argv[2]))
canon = lambda x: json.dumps(x, sort_keys=True, separators=(",", ":"))
emitted = [k for k in corpus if k in regen]
bad = [k for k in emitted if canon(corpus[k]) != canon(regen[k])]
frozen = sorted(k for k in corpus if k not in regen)
print(f"golden-check: {len(emitted)} emitted keys diffed vs {sys.argv[1]}")
if bad:
    print(f"  DIVERGED ({len(bad)}): {sorted(bad)}")
    sys.exit(1)
print(f"  PASS — all emitted keys byte-identical")
print(f"  ({len(frozen)} frozen keys are XCTest-pinned, not emitted: {frozen})")
PY

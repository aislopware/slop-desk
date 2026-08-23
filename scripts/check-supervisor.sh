#!/usr/bin/env bash
#
# check-supervisor.sh — the cross-language contract between hostd (Swift) and slopdesk-superd (Rust).
#
# WHY THIS EXISTS
# The two halves of this protocol are the one place `docs/DECISIONS.md`'s ONE-IMPLEMENTATION rule
# permits the same idea in both languages: a protocol has two ENDS, hostd encodes what superd
# decodes, and each end is written once. What that buys in clarity it costs in drift — and this
# protocol's drift is uniquely silent. The two sides never exchange their socket PATHS (hostd has to
# FIND the control socket before it can say `hello`), so a renamed socket is not a protocol error,
# it is a connect to a name nobody bound. A skewed frame TAG is worse: the receiver reads a length
# out of a body. Neither shows up in either language's own test suite, because each is internally
# consistent.
#
# So every constant that must be equal on both sides is compared here, textually, from the two
# sources of truth. No build, no daemon, no sockets — it runs in well under a second, which is what
# lets it sit in front of the parts that do.
#
# WHAT IT DOES NOT CHECK
# Anything a compiler or a unit test already catches. Field NAMES ride serde/Codable and a mismatch
# there fails `SupervisorProtocolTests` and `protocol::tests` respectively; the JSON shape is
# exercised end to end by `SupervisedPaneSurvivalTests`. This file is only for the constants that
# are typed twice.
#
# Usage: scripts/check-supervisor.sh [--tests]
#   --tests   also run the Rust suite and the Swift suites that need a real daemon (needs cargo)
#
# docs/46-gates-env-paths.md, docs/51-process-supervision.md

set -euo pipefail

cd "$(dirname "$0")/.."

# PORTED — the fourteen token bans that ran here as a background `python3 scripts/check-invariants.py`
# are rules in `rust/slopdesk-invariants` (`repo_invariants.rs`), collected with every other rule by
# `make lint-invariants`. The overlap this file bought by starting them early is gone with them: the
# crate walks the tree once and runs 294 rules over it under rayon.

# ── ONE tree walk for every "this Swift must stay deleted" ban in this file ────────────────────
# The bans below each asked `grep -r … Sources/` for a list that is EMPTY every time the gate
# passes, so the script walked the whole Swift tree once per ban per inner loop to be told nothing
# that many times. The union walks it ONCE, here; each ban then re-greps only the candidates, which
# is no files at all in the passing case. Five alternatives left with the bans that used them when
# those bans became `deleted-screen-swift` in `rust/slopdesk-invariants` — the union is a filter, so
# a departing ban takes its own alternative and nothing else.
#
# Semantics are unchanged and the reason is the same one `spells` gives: a file that matches none of
# the alternatives cannot match one of them. Every ban keeps its own pattern and its own message —
# the union is a filter, never the answer — which is what a reader needs on the day one fires.
#
# The union is BUILT from the bans, not maintained beside them: `make lint` runs
# `ban-union-is-whole` in `rust/slopdesk-invariants`, which fails if any ban's pattern is missing.
DELETED_SWIFT_UNION='((enum|struct|final class) (GF256|NeonGf|ReedSolomonMatrix)\b)|((struct|enum|final class) StreamHasher\b|func (hashRow|hashNV12Scalar|rowHashes|rowHashesQuantized|borrowPlane|estimateVerticalShift|changedFraction|adaptiveMaxQP)\b)|(func (targetSeconds|stepSeconds|cgRectToCocoa|backingScaleFactor)\(|(struct|enum|final class) ScreenInfo\b)|((func|var) appendBE|(struct|enum|final class|class) BigEndianReader)|((enum|struct|final class|class|actor) (AgentManifest|CompiledAgentManifest|AgentManifestCatalog|TOMLSubsetParser|ManifestRegion|ManifestRuleEngine|BundledAgentManifests|AgentDetectionExplain|AgentOscTracker|AgentSyncFrameTracker|ClaudeManifestMatcher)\b)|((enum|struct|final class|class|actor) ShellIntegration\b|slopdesk-zdotdir-)|((let|var|func|case) *(bonusBoundary|bonusCamel123|bonusConsecutive|scoreGapStart|scoreGapExtension|bonusMatrix|bonusFor|backtrace)\b)|((enum|struct) *(HookPayload|StopInfo|ToolUseBlock|NotificationInfo|ClaudeHookBody|ClaudeHookEvent)\b|func +(mapToHookEvent|classifyNotification|stopLabel)\b)|(func +(skipEscapeSequence|isEraseToLineEnd|applySGR|extendedColour)\b)|((enum|struct|final class|class|actor) (HostOutputSniffer|OutputSniffer)\b)|((enum|struct|final class|class|actor) (CommandBlockSegmenter|CommandBlockTracker|AutoProgressMatcher)\b)|(\[\[rules\]\]|min_engine_version\s*=|skip_state_update\s*=|line_regex\s*=)|(autoProgressCommands: \[String\]|autoProgressPrefixes)'
DELETED_SWIFT_CANDIDATES=$(grep -rlE "${DELETED_SWIFT_UNION}" Sources/ 2> /dev/null || true)
# The candidates matching ONE ban, or nothing. An empty candidate list answers without a grep.
among_deleted() {
  [[ -z "${DELETED_SWIFT_CANDIDATES}" ]] && return 0
  # shellcheck disable=SC2086 # the candidate list is a FILE LIST on purpose
  grep -lE "$1" ${DELETED_SWIFT_CANDIDATES} 2> /dev/null || true
}

SWIFT_PROTOCOL="Sources/SlopDeskSupervisor/SupervisorProtocol.swift"
RUST_PROTOCOL="rust/slopdesk-superd/src/protocol.rs"

failures=0

fail() {
  printf 'check-supervisor: FAIL — %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Compares one value that is spelled in both languages.
#   same <label> <swift value> <rust value>
same() {
  # EMPTY is not agreement. Both sides here are `sed -n …p` extractions, and `sed` — unlike `grep` —
  # exits 0 when it matches nothing, so a constant that was renamed or reformatted does not fail
  # loudly: it yields the empty string, and `"" == ""` is the healthiest-looking result this gate can
  # print. A port that renames the constant on BOTH sides in one commit is exactly the change that
  # would do it, and exactly the change this gate exists for.
  if [[ -z "$2" || -z "$3" ]]; then
    fail "$1: one side read as EMPTY — the extraction in this gate has gone stale and stopped comparing anything"
    return
  fi
  if [[ "$2" != "$3" ]]; then
    fail "$1 disagrees — Swift has '$2', Rust has '$3'"
  fi
}

# ── 1–4. superd's rendezvous, version, verbs, listener kinds and frame envelope ───────────────
# PORTED. These four sections are now rules in `rust/slopdesk-invariants`, which reads the tree
# once instead of spawning a grep per question, and — the part a shell section could never have —
# carries a unit test per rule that seeds the breakage and asserts the rule fires. Run
# `slopdesk-invariants --list` for the names; `make lint-invariants` runs them.

# ── 4b–8. The batch bodies, the read chunk, and the three absences hostd owes superd ──────────
# PORTED to `rust/slopdesk-invariants` — `batch-bodies`, `read-chunk`, `host-owes-superd`.

# ── 9 + the video wire + the mode tracker ─────────────────────────────────────────────────────
# PORTED to `rust/slopdesk-invariants`: screend-address, screend-verbs, video-send-path,
# video-receive-path, video-ladder-and-recovery, video-mux-and-input, video-metadata-wires,
# video-frame-measurements, video-pure-policies, terminal-mode-tracker.

# ── The terminal surface and the whole video control path ─────────────────────────────────────
# PORTED to `rust/slopdesk-invariants`: input-surface, grid-geometry, link-scan, command-blocks,
# video-admission, video-rate-law, video-frame-rate, video-presentation-depth, video-gradient,
# video-decode-admission, video-audio-stage, video-present-queue, video-hevc-parameter-sets,
# video-scroll-laws, video-swipe-nav, video-client-mux, video-reassembly, video-host-mux,
# video-window-feed, video-send-path-decisions, video-accumulators, video-geometry.
# Each carries a break-test that seeds the drift and asserts the rule fires — the one thing the
# shell sections above could only record as prose.

# ── The three codecs, the framing, the mux, the dialect and the two payload channels ──────────
# PORTED to `rust/slopdesk-invariants`: video-control-channel, terminal-wire, mux-layer,
# git-dialect, payload-channels, wire-vocabularies, big-endian-helpers.
#
# The port found one thing the shell could not: a ban written as `protocolVersion[^=]*= *[0-9]`
# reads line by line in grep, and the Rust rule had to be taught the same — a negated class in a
# whole-file regex crosses a newline and matched a `.hello(protocolVersion,` case label against an
# `= 1` several lines below it. Every ban in the crate is line-oriented now, with a test that pins
# exactly that.

# ── screend's hello, its status alphabet, the reset flags and the frame ceiling ───────────────
# PORTED to `rust/slopdesk-invariants`: screend-hello-and-status, screend-reset-flags-and-ceiling.
# The ceiling's two halves — the door is still asked, the literal has not come back — are one rule
# with a break-test that seeds the literal, which is what the BREAK-TESTED note here could only
# record as prose.

# ── The 15 MiB opaque budget, and the Swift that must stay deleted ────────────────────────────
# PORTED to `rust/slopdesk-invariants`: opaque-budget, deleted-screen-swift. The four bans that
# read through `among_deleted` are `NoneUnder { roots: ["Sources"] }` there — the union was only
# ever a FILTER, so scoping to the root is the same question asked without the pre-walk.

# ── The crate policies: who may write `unsafe`, and the two lints that argue with the floats ────
# PORTED to `rust/slopdesk-invariants`: unsafe-policy, apple-family, flops-opt-out. All three read
# MANIFESTS rather than source, and each carries a break-test — a crate that states `allow` under a
# `forbid`, an apple crate that hand-writes a `from_raw`, a workspace root missing the opt-out.

# `make lint-rust` runs clippy once per WORKSPACE, and cargo will not cross a workspace boundary for
# you: almost every crate under `rust/` is its own root, so each needs its own invocation.
#
# That was three hand-kept lists — clippy and `fmt --check` in `lint-rust`, the writing `fmt` in
# `fmt-rust` — and this gate used to check the Makefile's TEXT for each crate's three lines. It now
# asks the three targets what they would RUN, for the same reason the `make test` gate below asks
# `make -n test` rather than reading a prerequisite line: the recipe derives its list from the
# filesystem now, so there is no per-crate line left to grep, and "what would you do" is the question
# that survives however the recipe is written next. Three targets, because a crate present in one and
# missing from another has an unchecked half — formatting is the quiet one, since nothing looks
# different until someone runs the writer and gets a diff they did not make.
unlinted=""
for target in fmt-rust lint-rust lint-rust-clippy test-rust; do
  plan=$(make -n "${target}" 2> /dev/null) || true
  if [[ -z "${plan}" ]]; then
    fail "'make -n ${target}' printed nothing — the check below would accept every crate"
  fi
  for manifest in rust/*/Cargo.toml; do
    grep -q '^\[workspace\]' "${manifest}" || continue
    crate=$(basename "$(dirname "${manifest}")")
    grep -q "rust/${crate}\([ ;]\|$\)" <<< "${plan}" ||
      unlinted="${unlinted}${crate} (unreachable from make ${target})"$'\n'
  done
done
if [[ -n "${unlinted}" ]]; then
  printf '%s' "${unlinted}" >&2
  fail "a crate is its own cargo workspace and a rust fmt/lint/test target never enters it"
fi

# The same question a second time, about the target that RUNS the tests — and a crate whose tests
# nobody runs is worse than one nobody lints: clippy silence is a missing opinion, a suite that never
# executes is a green report about code nobody exercised.
#
# Asked of `make -n test` rather than of the prerequisite line, because reading the `<short>-test`
# names off `test:` gets it WRONG: `slopdesk-sanitize` has no target of its own — its 138 tests run
# inside `screend-test` — and the first draft of this check reported it as untested. `make -n` costs
# 30 ms and answers the exact question ("what would `make test` actually run"), which no amount of
# recipe-reading does.
untested=""
test_plan=$(make -n test 2> /dev/null | grep 'cargo test' || true)
if [[ -z "${test_plan}" ]]; then
  fail "'make -n test' printed no cargo test command — the check below would accept every crate"
fi
for manifest in rust/*/Cargo.toml; do
  crate=$(basename "$(dirname "${manifest}")")
  # `src` and `tests` only. A bare `rust/${crate}` walk descends into `target/`, which holds ~2 GB
  # per crate of build output that also contains `#[test]` — it found the right answer and took
  # minutes to do it, in a gate that runs on every lint.
  grep -rlq --include='*.rs' -e '#\[test\]' -e '#\[cfg(test)\]' \
    "rust/${crate}/src" "rust/${crate}/tests" 2> /dev/null || continue
  grep -qE "cd rust/${crate} &&|cargo test -p ${crate}( |$)" <<< "${test_plan}" ||
    untested="${untested}${crate}"$'\n'
done
if [[ -n "${untested}" ]]; then
  printf '%s' "${untested}" >&2
  fail "a crate carries tests that 'make test' never runs — a suite nobody executes reports green about code nobody exercised"
fi

# The same question asked of the ONE suite CLAUDE.md names as the price of an `unsafe` crate: the
# third of the three was bought with "a differential suite that runs under Miri", and for years
# nothing ran it. `make miri` existed, `make check` did not depend on it, `make test` did not, the
# prek hooks did not, the disabled CI did not — so the sentence in the document was the entire
# enforcement. Asked of `make -n check` for the same reason as the loop above: what would it RUN.
check_plan=$(make -n check 2> /dev/null) || true
if [[ -z "${check_plan}" ]]; then
  fail "'make -n check' printed nothing — the Miri check below would accept a gate that never runs it"
fi
grep -q 'cargo +nightly miri test' <<< "${check_plan}" ||
  fail "'make check' does not reach 'make miri' — the differential suite is what pays for rust/slopdesk-gfsimd's unsafe, and an obligation no target reaches is a sentence in a document (CLAUDE.md, docs/DECISIONS.md)"

# And the Swift half of the same question. SwiftPM builds the test targets `Package.swift` DECLARES;
# a directory under `Tests/` that nobody declared is not an error, it is simply ignored — no warning,
# no empty suite, nothing. Seventeen directories and seventeen `testTarget`s today.
#
# `Sources/` is in the same loop and is the worse half: an undeclared source directory is never
# COMPILED, yet `swiftformat`/`swiftlint` still walk it, so it keeps passing lint and reads as
# maintained code while nothing links it. Thirty-nine directories, thirty-nine targets.
undeclared_suites=""
for suite in Tests/*/ Sources/*/; do
  name=$(basename "${suite}")
  grep -qF "name: \"${name}\"" Package.swift || undeclared_suites="${undeclared_suites}${suite}"$'\n'
done
if [[ -n "${undeclared_suites}" ]]; then
  printf '%s' "${undeclared_suites}" >&2
  fail "a directory under Tests/ or Sources/ has no target in Package.swift — SwiftPM ignores it silently"
fi

# ── The two one-crate operations, agent detection, and the whole workspace document ───────────
# PORTED to `rust/slopdesk-invariants`: one-home-per-operation, replay-buffer, agent-detection,
# agent-vocabularies, document-field-vocabulary, intent-verbs, topology-and-reaping,
# workspace-scalar-codec, workspace-state-file, optional-fills.
#
# Two of those found something the shell could not have. `one-home-per-operation` is the first ban
# in this project whose HAYSTACK CONTAINS THE GATE — the patterns are assembled with `concat!` so
# the rule's own source does not spell what it forbids, which is the same problem the `mul_add`
# break-test hit and the same answer. And the `NAME = NUMBER` comparison, written three times here
# in three subtly different awk programs, is one module in the crate now: a flat form and a
# SECTIONED one, because a field name that appears in two tables is two entries and a flat set
# would call a swapped pair equal.

# ── The two workspace files, the solvers, and every ABI enum's byte map ─────────────────────────
# PORTED. `rules::workspace_files` holds all four: the state file's doors and its refusal taxonomy,
# the workspace file's doors plus the `Codable` conformance ban that is the divider-renaming defect's
# actual gate, the six solver faces and the 23 scanners banned beside them, and the eight
# `case -> byte` maps.
#
# The byte maps are `Claim::SameByteMap`, which is the one shape this file could not state safely.
# Its marker is a `sed` address, and a range restarts on every match — so a marker spelled twice
# APPENDS a second enum's rows to the first. The shell asked for uniqueness in prose for two years
# and enforced it only after `NewTabPosition` came within one explicit match arm of poisoning
# `PaneKind`'s comparison silently. The claim CHECKS it, on both sides, before it reads a row.

# ── The linked port's one failure mode: an artifact older than its source ───────────────────────
# A socket port cannot go stale — the daemon either answers or does not. A LINKED port can: the
# Swift side keeps calling last week's logic with every test green, because the tests link the same
# stale archive. `build-ffi.sh --check` compares the stamp against the Rust sources and says so.
printf 'check-supervisor: the FFI artifact is not older than its Rust sources\n'
# Counted like every other gate rather than aborting: under `set -e` a bare call would exit here and
# the ~40 contracts below would report nothing, which reads as "they passed".
bash scripts/build-ffi.sh --check || fail "the FFI artifact is stale — run 'make ffi' (docs/55 §3)"

# No SWIFT screen-tier DETECTION either. The manifest schema, its TOML parser, the region resolver,
# the rule engine, the bundled manifests, the explain trace, the OSC tracker and the sync-frame
# tracker moved into screend's `detect` verb and were DELETED here in the same change (`docs/50`
# §3, `docs/52`). The temporal layer did NOT move and is not named: `AgentDetectionHold` and
# `PaneScreenScanner` are hostd's, because screend owns everything that reads the BYTES and hostd
# owns everything that reads the CLOCK.
#
# `ClaudeManifestMatcher` is named for a different reason — it was a SECOND screen matcher in
# Swift, three tables of literal Claude cues next to a nineteen-agent rule ladder. Its process-name
# half outlived it for a while as `ClaudeProcessMatcher`, a wrapper over the crate's own predicates;
# that wrapper is gone too, so neither half may come back under either name.
detect_revived=$(among_deleted '(enum|struct|final class|class|actor) (AgentManifest|CompiledAgentManifest|AgentManifestCatalog|TOMLSubsetParser|ManifestRegion|ManifestRuleEngine|BundledAgentManifests|AgentDetectionExplain|AgentOscTracker|AgentSyncFrameTracker|ClaudeManifestMatcher)\b')
if [[ -n "${detect_revived}" ]]; then
  printf '%s\n' "${detect_revived}" >&2
  fail "a Swift screen-detection engine is back in Sources/ — screend's detect verb owns the ladder (docs/50 §3)"
fi

# The zsh shell-integration shim moved into superd for a reason hostd cannot argue with: the
# generated `ZDOTDIR` directory's lifetime is exactly the child's, and superd is the only process
# that outlives a hostd restart and can therefore delete it at all. In hostd it needed three
# separate cleanup sites — spawn failure, session teardown, orphan sweep — and still leaked the
# directory outright whenever hostd was killed. A Swift file that generates rc files again is that
# leak coming back, plus a second copy of the shell script itself.
shim_revived=$(among_deleted '(enum|struct|final class|class|actor) ShellIntegration\b|slopdesk-zdotdir-')
if [[ -n "${shim_revived}" ]]; then
  printf '%s\n' "${shim_revived}" >&2
  fail "the ZDOTDIR shim is back in Sources/ — superd owns it (rust/slopdesk-superd/src/shellintegration.rs)"
fi

# hostd may still ASK for the shim, and the request has to reach superd spelled the same way at
# both ends, or the shim silently never installs and every pane loses its prompt reprint and its
# OSC 133 marks with no error anywhere.
swift_shim_field=$(grep -cE 'public var shellIntegration: Bool' "${SWIFT_PROTOCOL}" || true)
rust_shim_field=$(grep -cE 'rename = "shellIntegration"' "${RUST_PROTOCOL}" || true)
if [[ "${swift_shim_field}" -eq 0 || "${rust_shim_field}" -eq 0 ]]; then
  fail "the spawn request's shellIntegration flag is not spelled at both ends (Swift ${swift_shim_field}, Rust ${rust_shim_field})"
fi

# The OSC sniffer went the same way and for a sharper reason: it read EVERY byte of EVERY pane, in
# Swift, on the read-loop thread — while superd's pump already held those bytes with no copy and no
# round trip. A Swift state machine over OSC bodies is that second reader coming back, and the two
# would drift silently: hostd would latch a title superd never dropped, or dedupe one it did.
sniffer_revived=$(among_deleted '(enum|struct|final class|class|actor) (HostOutputSniffer|OutputSniffer)\b')
if [[ -n "${sniffer_revived}" ]]; then
  printf '%s\n' "${sniffer_revived}" >&2
  fail "the OSC sniffer is back in Sources/ — superd owns it (rust/slopdesk-superd/src/sniffer.rs)"
fi

# The command-block segmenter is the same argument again, plus one only it has: hostd used to HOLD
# every finished command's captured output, and that ring died on every rebuild — a client
# reattaching after a `make host-restart` found an empty Commands panel for a shell that had never
# stopped. superd's pump segments and retains (`rust/slopdesk-superd/src/blocks.rs`, `docs/51`
# §6.14); a Swift segmenter or a Swift ring is that loss coming back.
blocks_revived=$(among_deleted '(enum|struct|final class|class|actor) (CommandBlockSegmenter|CommandBlockTracker|AutoProgressMatcher)\b')
if [[ -n "${blocks_revived}" ]]; then
  printf '%s\n' "${blocks_revived}" >&2
  fail "the command-block tap is back in Sources/ — superd owns it (rust/slopdesk-superd/src/blocks.rs)"
fi

# The tap's request flag, spelled at both ends for the same reason `shellIntegration` is above: a
# pane can only be tapped AT SPAWN (a segmenter cannot be attached to a shell already running), so a
# flag that fails to cross is a pane that is silently never segmented for its whole life.
swift_blocks_field=$(grep -cE 'public var blocks: BlocksRequest\?' "${SWIFT_PROTOCOL}" || true)
rust_blocks_field=$(grep -cE 'pub blocks: Option<BlocksRequest>' "${RUST_PROTOCOL}" || true)
if [[ "${swift_blocks_field}" -eq 0 || "${rust_blocks_field}" -eq 0 ]]; then
  fail "the spawn request's blocks tap is not spelled at both ends (Swift ${swift_blocks_field}, Rust ${rust_blocks_field})"
fi

# The auto-progress bridge crosses UNPARSED, and must keep doing so: superd owns both the parse and
# the built-in slow-command list, and a hostd that resolved either would be the second copy of a
# list whose whole point (`docs/DECISIONS`, 2026-08-10) is that it is the only copy of itself.
auto_progress_parse=$(among_deleted 'autoProgressCommands: \[String\]|autoProgressPrefixes')
if [[ -n "${auto_progress_parse}" ]]; then
  fail "hostd is parsing SLOPDESK_AUTO_PROGRESS_COMMANDS — the raw value crosses, superd parses it"
fi

# …and the manifests themselves live ONCE, as the TOML files they already are. A Swift source file
# carrying manifest rule text is the mirror in its most tempting form: it looks like data, not code.
manifest_text=$(among_deleted '\[\[rules\]\]|min_engine_version\s*=|skip_state_update\s*=|line_regex\s*=')
if [[ -n "${manifest_text}" ]]; then
  printf '%s\n' "${manifest_text}" >&2
  fail "manifest TOML is back in Sources/ — it lives in rust/slopdesk-screend/manifests (docs/52)"
fi

# ── 10–16c. The five sidecar wires, the four forked CLIs and the two linked tables ──────────────
# PORTED. dropd, androidd and inspectord (§§10–12), the announce line and its version parenthetical
# (§12b), the per-sidecar restart policy (§12c), the ctl/codeseed/agenthooks/probe verb sets
# (§§13–16), the linked git status (§16b) and the pointer tables (§16c) are now rules in
# `rust/slopdesk-invariants` — `sidecar_wires.rs` and `sidecar_clis.rs`. Each carries a unit test
# that seeds the breakage and asserts the rule fires, which is the half a shell section never had.
#
# Three hazards died with the port, and they are worth naming because each was a gate that passed:
#
#  * §10's chunk-writer byte. `*kind = 3;` reads as a block-comment continuation to any stripper
#    that treats a leading `*` as one, so the Rust rule reads that extraction RAW and says why.
#  * §13's `subscribe`. The shell appended it to BOTH extracted verb sets by hand, which cannot
#    fail — adding one member to both sides of an equality is a no-op. Each side is now asserted to
#    still spell it.
#  * §16b's porcelain ban. It named `status_nibble|pack_status`, which have not existed since the
#    table moved into `slopdesk-git::porcelain` as `nibble`/`pack`. It had been matching nothing.

# ── The `slopdesk` CLI is one implementation ────────────────────────────────────────────────────
# These faces DOCUMENT the rules they no longer implement — a doc comment naming the XDG path or an
# escape sequence is the point of the face, not a violation — so the bans below read CODE only.

# Where the bans get their files. `git ls-files` alone lists the INDEX, and the index is not the
# tree: 55 Swift files under `Sources/` are on disk and unstaged right now, so every ban that asked
# git was passing on files it never opened. The absence checks above already `grep -r Sources/` and
# were never blind this way; this keeps git's pathspec semantics — which those bans are written
# against — while agreeing with the filesystem, by asking for what is tracked AND what is present
# but not ignored. A file the index still lists after this branch deleted it is the other half of
# the same mismatch, and the one caller that cares tests `-f` before reading.
repo_files() { git ls-files --cached --others --exclude-standard "$@"; }

spells() {
  local pattern="$1"
  shift
  # NO FILES IS "NOTHING SPELLS IT", NOT "READ STDIN". Forty call sites below hand this a
  # `$(repo_files 'Sources/SomeTarget/**/*.swift')` splat, and a splat that matches nothing expands
  # to NOTHING — at which point the `grep -lE` at the bottom has no file operands, falls back to its
  # stdin, and blocks forever on a terminal that will never close. That is not a theoretical shape:
  # it wedged three of these for the better part of three hours, and it fails in the worst available
  # direction, because a hung lint reports neither pass nor fail. It was also SCHEDULED, and increment
  # 63 is the day it came due: the docs/56 fold drained `Sources/SlopDeskClientUI` to nothing and the
  # directory is gone, so every ban below that globbed it would have found no operands at all. This
  # guard is why `make lint` still returns rather than hanging on the move that was always coming.
  #
  # Returning 1 rather than shouting, deliberately. An empty corpus is the CORRECT and expected state
  # for a draining target, where the ban really is trivially satisfied; only the caller knows whether
  # its own corpus was supposed to be non-empty, so that judgement stays where the knowledge is — in
  # the per-gate vacuity floors, which count their file list before they get here.
  (($# > 0)) || return 1
  local file stripped
  # ONE `grep` over the whole list to find candidates, and the per-file comment strip only for those.
  # Semantics are unchanged — stripping comments can only ever REMOVE a match, so a file the first
  # grep rejects could not have matched after the strip — but the process count drops from two per
  # file to two per HIT. Twelve call sites here pass the whole Swift tree; at ~4 s each that was
  # roughly half of this script's runtime.
  while IFS= read -r file; do
    # Stripped into a variable and matched from a here-string, NOT down a pipe: `grep -q` exits the
    # instant it matches, `sed` then dies of SIGPIPE, and under `pipefail` a FOUND spell would read
    # as not found — which the ban checks below could never notice, because they expect no match.
    stripped=$(sed -E 's,//.*,,' "${file}")
    if grep -qE "${pattern}" <<< "${stripped}"; then
      printf '%s' "${file}"
      return 0
    fi
  done < <(grep -lE "${pattern}" "$@" 2> /dev/null || true)
  return 1
}

# PORTED to `rust/slopdesk-invariants` — `rules::cli_vocabulary`: cli-core-is-one-law,
#   cli-help-has-one-author, cli-dispatch-matches-availability, ui-shell-cli-docs. This was the
#   largest block left here, and almost all of it was already the claim shapes the crate has:
#   `Doors` for the fourteen door-calls, `Lacks` over `View::Statements` for the seven bans that
#   `spells` used to answer. Two things could not be claims and are written out — the availability
#   walk, because a `name:` line and an `Availability::` line are different LINES and a stateless
#   match can read either but never the pairing; and the ui-shell tokeniser, which is six `grep`
#   stages deep. `View::Statements` is a deliberate improvement on `spells`' `sed -E 's,//.*,,'`:
#   the latter cuts at a `//` inside a string literal, which is the URL bug the crate's tokenizer
#   was written to avoid.

# PORTED to `rust/slopdesk-invariants` — `rules::panel_floor`: device-panel-floor,
#   device-panels-both-platforms, code-panel-crosses. Two claim shapes came with it: `NoFileUnder`,
#   because "a gate PRESENT and its phone half ABSENT" is not a property any single line has, and
#   `Opening`, because "wrapped whole" is about POSITION — a gate further in is ordinary code.

# PORTED to `rust/slopdesk-invariants` — `rules::client_layers`: client-core-draws-nothing.

# PORTED to `rust/slopdesk-invariants` — `rules::pane_wiring`: terminal-pane-wiring,
#   escape-monitor, phone-key-path. Three more claim shapes: `Within` for the secure-input teardown
#   ORDER, which no type can express; `Populated` for the file-count floor the `Pane/**/*.swift`
#   pathspec bug needed; `Opening` was already here from the panel floor.

# PORTED to `rust/slopdesk-invariants` — `rules::cross_twins`: tree-repair,
#   cross-language-twins, loop-shaped-crossings. One claim did NOT come across: the shell PRINTED a
#   note when `withTheDocumentsBlindSpotsClosed` disappeared. A note passes either way, so it
#   recorded an intention rather than checking one; the rule's doc carries the exit instead.

# PORTED to `rust/slopdesk-invariants` — `rules::settings_catalog`: settings-option-groups,
#   settings-constant-answers. The shell asked its `titlesByID` claim only IF WorkspaceCommands.swift
#   existed; that tolerance did not come across, because a claim a missing file satisfies is one more
#   way for this gate to check nothing.

# PORTED to `rust/slopdesk-invariants` — `rules::settings_rows`: settings-row-naming,
#   settings-key-spelling, settings-page-shape, chord-editor-twins. The `Half.current` claim came
#   across as a RANGE ban rather than a `grep -A 2`: the range fails when `current` is renamed
#   away, where the window quietly banned `#if` in an empty three lines.
# PORTED to `rust/slopdesk-invariants` — `rules::split_surfaces`: split-bespoke-settings.

# PORTED to `rust/slopdesk-invariants` — `rules::panel_shells`: panel-vocabulary, device-panel-twins,
#   device-panel-shells, design-floor.

# PORTED to `rust/slopdesk-invariants` — `rules::device_law`: device-panel-law,
#   client-pasteboard-and-open, small-rules-spelled-once.

# PORTED to `rust/slopdesk-invariants` — `rules::ui_split`: ui-split-shape, video-surface-split,
#   video-halves-agree.

# PORTED to `rust/slopdesk-invariants` — `rules::ui_seams`: ui-test-edges, canvas-registration,
#   leaf-seam-shapes. The gate now WALKS `ThirdParty/ghostty/integration` — four files, the embedder
#   Swift no `Package.swift` target compiles — because the terminal seam has no other registrar.

# PORTED to `rust/slopdesk-invariants` — `rules::ink_floor`: the accent ring's alpha and the grab
# pill on the floor (`frameworkless-value-floor`), the Mac scene injecting no environment it does not
# read and the deleted satellite seam (`mac-scene-environment`), the fold shut from both sides —
# import census AND manifest edge (`fold-gate-condition`), one test-lint relaxation across two test
# trees, by symlink (`two-test-trees`), the drop chip drawn twice off one art file beside the ONE
# `paneStatusPillFill` switch (`drop-chip-and-pill`), the five named ink tables answered rung by rung
# by every renderer present (`named-ink-tables`), and `staticMirror` staying deleted
# (`static-mirror-deleted`).

# PORTED to `rust/slopdesk-invariants` — `rules::command_surface`: the tear-off's two ordered steps
# and the canvas drag deciding once (`canvas-drag-decides-once`), a palette verb naming its platform
# once with no gate in the catalog (`palette-verb-platform`), the registry rows derived rather than
# transcribed (`palette-reaches-bindings`), a keybinding naming its platform once in the other id
# space (`keybinding-platform`), and the chord table held rather than rebuilt per keystroke
# (`chord-table-held`).
# PORTED to `rust/slopdesk-invariants` — `rules::latency_ratchets`: the mirror topology projected
# once per revision rather than once per sidebar row (`mirror-topology-memo`), the three projections
# a repaint binds once instead of three times (`three-projections`), the two index doors guessing
# rather than probing with a null output and the find guess carried across keystrokes and panes
# (`index-doors-guess`), and the row scan, the loopback mirror and the launch-bytes emptiness rule
# each deriving once (`scan-and-mirror-derive-once`).

# PORTED to `rust/slopdesk-invariants` — `rules::video_ports`: the control datagram lent rather than
# re-encoded, the cached-shape guard and the lazy FEC promotion (`video-path-lends`), the two
# CoreGraphics phase encodings as ONE table across four former spellings (`scroll-phase-table`), the
# five [1,51] quantiser knobs clamping through one door and the message-shaped control face staying a
# wrapper (`quantiser-knob-clamps`), the settings sheet's four defaults read from the encoder's own
# doors (`settings-sheet-defaults`), and the REJECT reading of a rate or fraction living once in
# congestion.rs with the generic pair deleted tree-wide (`env-knob-reject-rule`).

# PORTED to `rust/slopdesk-invariants` — `rules::held_values`: the audio row's three marshalling
# faces, each still asking its door and importing no audio framework, with the ring, the pump and the
# jitter stage pinned gone by PATH (`audio-row-is-rusts`); both length prefixes parsed once, and the
# all-ones sentinel a signed `Int` swallowed (`length-prefix-parsed-once`); the document's ONE
# emission order, asked four times, with `persisting()` filtering rather than sorting
# (`one-emission-order`); and the palette catalog indexed once beside the settings taxonomy's own
# search, needle uncrossed and unfolded (`catalog-indexed-once`).
#
# Three sections inside that span were already ported and their notes are kept here:
# PORTED to `rust/slopdesk-invariants` — `rules::hot_paths`: palette-ranking.
# PORTED to `rust/slopdesk-invariants` — `rules::hot_paths`: nerd-font-splitter.
# PORTED to `rust/slopdesk-invariants` — `rules::workspace_layout`: rail-badge-gates.

# PORTED to `rust/slopdesk-invariants` — `rules::macui_memos`: the nine memoizations a redraw path
# must keep, each pinning a HELD value whose absence changes nothing a test can see. The git line's
# measured ladder, its one build and its kill (`macui-git-ladder`); Open Quickly's corpus derived once
# per draw rather than three times (`macui-corpus-once`); the canvas's unthemed answers cached and
# PRUNED (`macui-unthemed-cache`); the GUI leaf holding its pane KIND and not its liveness
# (`macui-leaf-kind`); the container asking `Tab.contains` instead of allocating a pane-id array per
# tab per ⌃⇥ tap (`macui-pane-count`); the code-panel chord reach as a static Set
# (`macui-terminal-reach`); the plate button's glyph name guarded like its other two states
# (`macui-glyph-guard`); both display-link spinners filling their dots on the context
# (`macui-spinner-dots`); and the divider guarding its handle, guarding `percents` field-by-field and
# hiding the readout BEFORE it cuts the text — the ORDER checked separately, because a file that
# spells both lines in the wrong order passes all three text pins (`macui-divider-readout`).
#
# The printf that closed the UI-split region went with it: every rule it summarised is now the crate's.

# PORTED to `rust/slopdesk-invariants` — `rules::sidecar_seams`: the pane master decided once,
# handed back OWNED and borrowed for the send, with the racing lookup banned by name
# (`master-owned-duplicate`); ONE probed and ONE announced lifecycle over five sidecar managers, the
# four re-written shapes banned target-wide and each manager holding one lock (`two-sidecar-lifecycles`);
# the cancel-and-re-arm deadline as a two-line WINDOW nobody may write out, with its six arming sites
# pinned (`one-deadline-latch`); one pasteboard↔clip conversion read by both ends of the wire
# (`one-pasteboard-clip`); every JSON sidecar sorting its keys, and WorkspaceCore holding one encoder
# (`one-sidecar-encoder`); the two client debug gates read in DebugTrace alone (`one-debug-gate`); and
# the channel tag as one enum with its seven raw values pinned to their wire numbers (`one-channel-tag`).
#
# STILL HERE, deliberately: the two doc gates below. The ``DocC link`` check and the cited-path check
# each build a corpus this crate has no shape for yet — one an identifier census over every Swift file
# in the tree, the other CLAUDE.md's own read-first table expanded into a doc list. They port next.

# A ``DocC link`` must name something this repo declares. The rule is not tidiness: a port moves the
# implementation out of Swift and deletes the original (CLAUDE.md), and the doc that described it keeps
# the old spelling — so a reader chasing ``HostOutputSniffer`` or ``TerminalQueryStripper`` greps Swift,
# finds nothing, and concludes the machinery is gone rather than that it now lives in
# `rust/slopdesk-superd` / `rust/slopdesk-sanitize`. 65 such links had accumulated when this check was
# written, across four ports and three deleted view layers. A Rust item is cited the way the rest of the
# tree cites one — `name` plus its crate path — and a single-backtick span is prose, so only the DOUBLE
# backtick, which promises a symbol in THIS doc graph, is checked.
#
# KNOWN is everything the repo spells in CODE (comments stripped, so a name kept alive only by other
# comments does not vouch for itself), plus every Swift FILE basename — several links legitimately name
# a file that groups a vocabulary rather than a type. `docc_external` carries the framework symbols
# DocC resolves through an import; keep it short, and add to it only for a symbol Apple actually ships.
declare -a docc_external=("SwiftUICore" "CGDisplayGammaTable" "CGEventTap")
# One awk pass per role, not one process per file: this walks every Swift file in the repo and the
# per-file spawn version cost ~3 minutes on its own.
# The VOUCHING set comes off the filesystem: the question it answers is "does this repo declare the
# name", and a file added but not yet staged declares it just as much as a committed one. Reading
# the index here would fail a link that is perfectly good. `repo_files` above closed the same gap
# for every ban check, so the two halves now see one tree; this one still says `find` because it
# wants ThirdParty/ghostty/integration, which no pathspec below covers.
docc_vouching=()
while IFS= read -r f; do docc_vouching+=("${f}"); done <<< "$(
  find Sources Tests Apps ThirdParty/ghostty/integration -name '*.swift' -type f \
    -not -path '*/.build/*' -not -path '*/.work/*' 2> /dev/null
)"
docc_scanned=()
while IFS= read -r f; do [[ -f "${f}" ]] && docc_scanned+=("${f}"); done <<< "$(
  repo_files 'Sources/**/*.swift' 'Tests/**/*.swift'
)"
docc_known=$(
  {
    printf '%s\n' "${docc_external[@]}"
    printf '%s\n' "${docc_vouching[@]}" | sed -e 's:.*/::' -e 's:\.swift$::'
    awk '{ sub(/\/\/.*/, ""); while (match($0, /[A-Za-z_][A-Za-z0-9_]*/)) {
             print substr($0, RSTART, RLENGTH); $0 = substr($0, RSTART + RLENGTH) } }' \
      "${docc_vouching[@]}"
  } | sort -u
)
docc_dangling=$(
  awk 'NR == FNR { known[$0] = 1; next }
       /^[[:space:]]*(\/\/|\*)/ {
         line = $0
         while (match(line, /``[^`]+``/)) {
           raw = substr(line, RSTART + 2, RLENGTH - 4)
           line = substr(line, RSTART + RLENGTH)
           n = split(raw, parts, "/")
           for (i = 1; i <= n; i++) {
             p = parts[i]; sub(/\(.*/, "", p); gsub(/^[ \t]+|[ \t]+$/, "", p)
             if (p ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && !(p in known)) print FILENAME ":" FNR "\t" p
           }
         }
       }' <(printf '%s\n' "${docc_known}") "${docc_scanned[@]}"
)
if [[ -n "${docc_dangling}" ]]; then
  printf '%s\n' "${docc_dangling}" >&2
  fail "a $()link$() names a symbol this repo does not declare — cite a ported item as \`name\` + crate path"
fi
# The mirror of the check above: the docs cite CODE, and nothing has been reading those citations.
# `docs/00`'s "Core / shell split" told every reader that Swift owns the wire and that the only
# non-Swift code is a C target deleted weeks earlier — the opposite of `CLAUDE.md`'s rule, in the
# one paragraph a newcomer is pointed at first (`DECISIONS.md` 2026-08-16).
#
# Scoped to file PATHS rooted at a real top-level directory, and to the docs `CLAUDE.md` sends a
# reader to. Both bounds are deliberate. A bare `Overlays/PaletteView.swift` is ordinary shorthand
# for a path relative to its package, and resolving that guess is how a gate earns false positives;
# a rooted path either exists or the doc is lying. And a doc nobody is told to read is history:
# `29-NIGHT-HANDOFF.md` names dozens of files that are gone, correctly, because that is what a
# handoff from March records. `DECISIONS.md` is the same and is excluded by name.
#
# The live set comes off `CLAUDE.md`'s own table rather than a second list here — a doc becomes
# read-first by being added to that table, and this follows it without being told twice.
#
# BOTH spellings the table uses. The sidecar row reads "`docs/51` superd · `52` screend · `53` dropd
# · `54` inspectord · `48` androidd" — five docs, and only the first one carries the `docs/` prefix.
# Reading the prefixed form alone covered one of the five and looked complete doing it, which is the
# same failure as any extraction that matches less than its comment claims: the gate's pass state is
# an empty `doc_missing`, so four unwatched docs and four clean docs print identically.
doc_live=()
unresolved=""
while IFS= read -r token; do
  before=${#doc_live[@]}
  for expanded in "docs/${token}"*.md; do [[ -f "${expanded}" ]] && doc_live+=("${expanded}"); done
  # A token that resolves to nothing is a doc CLAUDE.md sends readers to and that is not there. The
  # loop used to drop it in silence, which spends the table's authority on a file nobody can open.
  [[ ${#doc_live[@]} -gt ${before} ]] || unresolved="${unresolved}docs/${token}"$'\n'
done <<< "$({
  grep -oE 'docs/[0-9]{2}[a-z0-9-]*' CLAUDE.md | sed 's|^docs/||'
  # shellcheck disable=SC2016 # the single quotes hold a REGEX — those are the table's backticks
  grep -oE '`[0-9]{2}`' CLAUDE.md | tr -d '`'
} | sort -u)"
if [[ -n "${unresolved}" ]]; then
  printf '%s' "${unresolved}" >&2
  fail "CLAUDE.md's read-first table names a doc that does not exist"
fi
for extra in docs/README.md docs/00-overview.md DESIGN.md; do
  [[ -f "${extra}" ]] && doc_live+=("${extra}")
done

# A doc may name a file it is telling you was DELETED — `docs/51` §"What this deleted" is the
# pattern, and the whole value of that section is that it spells the name out. Each entry here is
# one such tombstone, and stays only as long as its sentence does.
declare -a doc_path_tombstones=("Sources/SlopDeskHost/PTYReadLoop.swift")

# The citations are extracted FIRST and checked for life of their own. This gate's pass state is an
# empty `doc_missing`, so an extraction that stopped matching would report the healthiest possible
# result — there is no way to tell "every cited path exists" from "no path was read" by looking at
# the output alone, which is why the liveness check has to be on the input.
# The "rooted at a real top-level directory" bound is read off the filesystem, not spelled out. The
# hand-written alternation it replaces had drifted both ways at once: `manifests` and `research` no
# longer exist, so two of its ten branches could never match, and `hid-bridge` — which does — was
# never in it, so any path cited into that tree was exempt without anyone deciding it should be.
doc_roots=$(for d in ./*/; do
  d=${d#./}
  printf '%s\n' "${d%/}"
done | paste -sd'|' -)
doc_cited=$(
  grep -hoE '`('"${doc_roots}"')/[A-Za-z0-9_./+-]+\.[a-z]+`' \
    "${doc_live[@]}" | tr -d '`' | sort -u
) || true
if [[ -z "${doc_cited}" ]]; then
  fail "no file path is cited by any read-first doc — the extraction in this gate has gone stale"
fi
doc_missing=$(
  while IFS= read -r cited; do
    [[ -e "${cited}" ]] && continue
    skip=""
    for tomb in "${doc_path_tombstones[@]}"; do [[ "${cited}" == "${tomb}" ]] && skip=1; done
    [[ -n "${skip}" ]] || printf '%s\n' "${cited}"
  done <<< "${doc_cited}"
) || true
if [[ -n "${doc_missing}" ]]; then
  printf '%s\n' "${doc_missing}" >&2
  fail "a read-first doc cites a file that does not exist — repoint it, or add it to doc_path_tombstones"
fi

# PORTED to `rust/slopdesk-invariants` — `rules::crate_defaults`: the three seeded names minted by
# TreeWorkspaceDefaults and banned as literals across a five-file corpus that is floored by name first
# (`seeded-names`); the eleven tuned encoder numbers read through the two `*_config_default` doors,
# with the declaration default and the digit env fallback each banned in the shape it regrows as
# (`encoder-defaults`); a settings row crossing WHOLE, the seven deleted field doors still banned
# inside `entry(at:)` alone so the key door beside them stays legal (`settings-row-whole`); the rail
# relabelling asked once for the whole list rather than per row (`rail-relabel-once`); one `:line[:col]`
# splitter, pinned by the scan's three tells rather than by a function name (`one-line-col-splitter`);
# and both hand-rolled ring wraps stepping through the one door that survives an empty list
# (`one-ring-wrap`).
#
# The `code-panel-font-pair` note that sat in this span is folded in: see `rules/code_panel.rs`.

# ── hostd and the device panels ───────────────────────────────────────────────────────────────
# Every rule below was BREAK-TESTED against the real tree — the verdict is recorded in its own
# comment — by copying the file to /tmp, editing it back to the shape the rule bans, running the
# PORTED to `rust/slopdesk-invariants`: hostd-binary-order — the null-output probe ban, the
# three guess-then-retry sites, and the one search order.

# PORTED to `rust/slopdesk-invariants` — `rules::panel_predicates`: the six copies of the device
# panels' search predicate, now one `DeviceRowFilter` over a seven-file corpus floored by name
# (`one-panel-predicate`); the instrument voice read out of its table, the store still `@MainActor`,
# and the expensive build site COUNTED at exactly one so a stale extraction cannot read as compliance
# (`instrument-voice-minted-once`).

# ── NOT a ratchet, a note for whoever audits this next ──────────────────────────────────────────
# `MuxChannelSession.isCompletionTransition` looks like a twin of `slopdesk_agent_attention_completion`
# and is NOT one. The door answers the HOOK-LESS completion (`Working|Blocked -> Idle`); the host's
# rule is "one finished turn", which is that PLUS entering `.done` from anything but `.done` — the
# hook path, which is the whole reason `pane/completionEpoch` advances on a host that runs the Stop
# hook. Routing the host through the door would silently stop counting hook-driven finishes.
# `Tests/SlopDeskHostTests/CompletionTransitionTests.swift` pins the difference; leave it Swift, or
# give the wider rule a door of its own.

# PORTED to `rust/slopdesk-invariants` — `rules::panel_predicates`: the console's level letters
# crossing through androidd's array, with the `enum` keyword banned because a case list cannot be
# built from a table at run time (`android-level-array`); and the cursor style's one label, the
# catalog's (`one-cursor-label`).

# PORTED to `rust/slopdesk-invariants` — `rules::path_confinement`: no Swift file deciding about a
# `..` component, testing containment with a prefix, or growing the decoder's splitter back, with the
# bridge's `contains(root:)` body caught as the two-line WINDOW it is (`no-second-path-opinion`); the
# rule staying LEXICAL — `canonicalize` banned in code but not in the prose that explains why — and
# having exactly one home under `rust/`, floored by asserting that home still declares it
# (`confinement-lexical-and-singular`); the `pub mod`/header trio that keeps the door linkable
# (`confinement-door-reachable`); and the mux-type vocabulary asked once with an unknown byte refused
# on both sides (`mux-type-refused`).

# PORTED to `rust/slopdesk-invariants` — `rules::crossed_tables`: an undecodable Android stream
# ENDING rather than defaulting to H.264 (`undecodable-stream-ends`); the multi-loss threshold asked
# once instead of spelled three times (`multi-loss-threshold`); the two raw level bytes read through
# their doors (`level-bytes-through-doors`); the dead Rust preset expansion staying deleted, all four
# items of it (`dead-rust-expansion`); ONE pacing schedule and — COUNTED, because one is right and two
# is the regression — ONE pacing gap (`one-pacing-schedule`); and the two shipped tables seeded from
# templates.rs with `builtInID` banned on both model files (`shipped-tables-are-the-crates`).

# ── B. …and the two compositions staying gone ───────────────────────────────────────────────────
# PORTED — it is part of `workspace-scalar-codec` in `rust/slopdesk-invariants`, where it sits
# beside the door list it is the other half of.

# PORTED to `rust/slopdesk-invariants` — `rules::rate_and_range`: the anti-flood bucket built by the
# crate rather than the near side, with the memberwise construction and the `= 5` / `= 0.5` default
# argument banned together and the face floored by name first (`bucket-from-the-crate`); and the
# `Stepper` vocabulary COUNTED — the enum's variants against the length `ALL` declares, refusing two
# empties rather than calling them equal (`stepper-census`).

# ── Every path this file names still exists ───────────────────────────────────────────────────
# Forty `SWIFT_*` / `RUST_*` constants name the files the contracts above are read out of, and a
# renamed file does not announce itself: `grep … "${SWIFT_WIRE}"` prints to stderr, returns nothing,
# and every ban check reading that haystack passes at once. The list is DERIVED from the variables
# themselves (`${!SWIFT_@}`), not maintained beside them, and it runs here rather than at the top
# because the constants are declared throughout the file — so it cannot un-run the checks it
# invalidates, only say that they were reading nothing.
missing_paths=""
for path_var in "${!SWIFT_@}" "${!RUST_@}" "${!SERVICE_@}"; do
  [[ -e "${!path_var}" ]] || missing_paths+="  ${path_var}=${!path_var}"$'\n'
done
if [[ -n "${missing_paths}" ]]; then
  printf '%s' "${missing_paths}" >&2
  fail "a path this gate reads from no longer exists — every check above that read it reported nothing, which is not the same as agreement"
fi

# ── No gate may die quietly ───────────────────────────────────────────────────────────────────
# Every script here runs under `set -euo pipefail`, where `x=$(… | grep …)` that matches NOTHING
# exits 1 and takes the whole run with it — no message, and a log that ends early reads exactly like
# a log that passed. That is not hypothetical: it was fixed once in the ABI byte-map comparison
# (since ported), re-entered, and then found in twenty-three more assignments here, five of which sat
# above a guard whose message says "the extraction in this gate has gone stale" and which therefore
# could never run in the case it was written for.
#
# So the rule is mechanical: an assignment whose command substitution runs `grep` carries an `||`.
# `|| true` is usually right — but read the guard BELOW it first, because for a ban list (a haystack
# followed by `grep -qF` for symbols that must stay deleted) an empty result passes every check at
# once, and `|| true` alone would turn a silent death into a silent pass. Those need `[[ -z … ]]`
# naming the file, the way `codec_code` and `solver_code` do.
gate_deaths=$(
  for script in scripts/*.sh; do
    awk -v file="${script}" -f scripts/gate-death.awk "${script}"
  done
) || true
if [[ -n "${gate_deaths}" ]]; then
  printf '%s\n' "${gate_deaths}" >&2
  fail "a gate assigns from a grep with no '||' — under set -e a miss kills the run silently (docs/DECISIONS.md, 2026-08-16)"
fi

# ── Every binaryTarget the release cannot check out, the release must build ────────────────────
# `Package.swift` declares two `binaryTarget` paths, and both are gitignored build outputs: SwiftPM
# cannot resolve the graph without the FILE, so on a fresh runner a path nothing produces is not a
# missing optimisation, it is a release that fails before it compiles a line. `libghostty` had a job;
# `SlopDeskFFI.xcframework` had nothing, and the only reason it never bit is that the whole FFI port
# is still uncommitted — the window in which to notice rather than the reason not to.
#
# Derived from the manifest, so a THIRD linked artifact is covered the day it is declared.
release_workflow=.github/workflows/release.yml
linked_artifacts=$(
  {
    grep -ohE 'path: "ThirdParty/[A-Za-z0-9_./-]+\.xcframework"' Package.swift | sed 's/path: "//; s/"$//'
    # The Xcode specs link the other one, and they spell it relative to the app directory.
    grep -ohE 'framework: \.\./\.\./ThirdParty/[A-Za-z0-9_./-]+\.xcframework' Apps/*/project.yml |
      sed 's|framework: \.\./\.\./||'
  } | sort -u
) || true
if [[ -z "${linked_artifacts}" ]]; then
  fail "no linked xcframework was found in Package.swift or Apps/*/project.yml — the extraction in this gate has gone stale"
fi
# The workflow must RUN the artifact's producer, and the first draft of this only asked whether the
# workflow MENTIONED the artifact — which a comment satisfies. A negative test that deleted the whole
# build step still passed, because the comment above it named the file. So: find the script that
# writes the artifact, then look for that script on a line the YAML would execute rather than one it
# ignores. A gate that a comment can satisfy is a gate about prose.
unbuilt_artifacts=""
workflow_code=$(grep -v '^[[:space:]]*#' "${release_workflow}") || true
if [[ -z "${workflow_code}" ]]; then
  fail "${release_workflow} has no non-comment line — the check below would accept every artifact"
fi
while IFS= read -r artifact; do
  git check-ignore -q "${artifact}" || continue # a tracked artifact is checked out, not built
  # EVERY script that names it outside a comment, not the first one found. Several scripts know an
  # artifact without producing it — the two renderer togglers and `package-release.sh` all name
  # libghostty's — and `head -1` picked one of those and demanded the release run it. The question
  # that has one right answer is whether the workflow runs ANY of them. Comment lines are stripped on
  # this side too: `build-ffi.sh` discusses libghostty's gitignore in prose, which is how it came to
  # be nominated as libghostty's builder.
  producers=""
  for candidate in scripts/*.sh ThirdParty/*/*.sh; do
    [[ -f "${candidate}" ]] || continue
    grep -v '^[[:space:]]*#' "${candidate}" | grep -qF "$(basename "${artifact}")" || continue
    producers="${producers}${candidate} "
  done
  if [[ -z "${producers}" ]]; then
    unbuilt_artifacts="${unbuilt_artifacts}${artifact} (no script in the repo writes it)"$'\n'
    continue
  fi
  built=""
  for producer in ${producers}; do
    grep -qF "${producer}" <<< "${workflow_code}" && built=1
  done
  [[ -n "${built}" ]] ||
    unbuilt_artifacts="${unbuilt_artifacts}${artifact} (none of: ${producers}is run by the workflow)"$'\n'
done <<< "${linked_artifacts}"
if [[ -n "${unbuilt_artifacts}" ]]; then
  printf '%s' "${unbuilt_artifacts}" >&2
  fail "a gitignored binaryTarget is never built by ${release_workflow} — SwiftPM cannot resolve the graph on a fresh runner (docs/49)"
fi

# PORTED to `rust/slopdesk-invariants` — `rules::frozen_pairs`: the two writers of the green-tree
# marker agreeing on the tested-inputs pathspec and on the marker NAMES as a set, so a rename cannot
# pass by substring (`green-tree-marker`); and the three frozen `pane/liveness` bytes compared arm by
# arm across the two enums that spell them, which no door could pin because a Swift raw value must be
# a compile-time constant (`liveness-bytes`).

printf 'check-supervisor: no dangling doc link, no doc citing a file that is gone, no gate that dies quietly.\n'

if [[ "${failures}" -ne 0 ]]; then
  printf 'check-supervisor: %d contract violation(s)\n' "${failures}" >&2
  exit 1
fi

# The five sidecar wires and the four forked CLIs announce themselves from
# `rust/slopdesk-invariants` now, which prints one line for the whole registry.
# PORTED to `rust/slopdesk-invariants` — `rules::shared_constants`: opaque-cap-inequality. It is the
#   one pair in that module whose rule is an INEQUALITY (`rust >= swift`) rather than an equality,
#   so it is written out rather than being a `Claim`, and it reuses the module's own `numeric` —
#   which the shell could not, having only `$(( ))` and therefore only Rust's precedence.

# PORTED to `rust/slopdesk-invariants` — `rules::panel_predicates`: the Android keycode ratchet
# (`android-keycode-ratchet`), as the new `Claim::Overlap` — two DERIVED sets, the intersection
# against a high-water mark of zero, failing above it AND below it so ground gained is held, with both
# sides floored non-empty because at zero a broken extraction reads exactly like success.

# PORTED to `rust/slopdesk-invariants` — `rules::two_shells`: the three rules that ask whether the
# two UI shells wrote the same thing twice, rather than whether either wrote it in the wrong place.
# `no-cross-target-clone` is the new `Claim::NoCloneAcross` — eight consecutive SUBSTANTIVE lines
# appearing under both targets, with the debt list checked BOTH ways so a paid debt has to leave it.
# `owned-copy-one-speller` is nineteen named sentences, each PAIRED with a claim that its floor file
# still spells the phrase, which the shell could only assert in a comment. `shared-vocabulary-ceiling`
# is the new `Claim::OverlapUnder` — the count of capitalised phrases spelled in both, one-way at 33,
# with a floor under each side so a broken pattern cannot read as a clean split.

# PORTED to `rust/slopdesk-invariants` — `rules::phone_parity` and `rules::apple_floors`: all twenty
# of the phone-capability and host-floor rules. Twelve pin a capability that was Mac-only until it was
# closed — the root key rung, the editing chords and the sink they reach, the shared config file's two
# behaviours, the settled code panel, the named panel surface, the one clear key, the soft keyboard and
# the COUNTED press forward, the silent paste probe, the swipe-peel chip's two drivers, the iPad
# pointer's five modalities, the pane-drop metrics and the link island. Three more pin the `objc2`
# ports: no `CGEvent` built in Swift, no second window or display decode, no capture region decided
# twice — each with the macOS-only bijection checked in the header REGION and the Cargo TABLE, the
# latter read to the next table header rather than through the `grep -A 12` that failed on a manifest
# it had no quarrel with.
#
# Two shell-only hazards died with the port. Every check here was guarded with `[[ -f … ]] &&`, so a
# renamed subject was a silent pass; a claim fails on a missing file instead. And the clear-key
# exemption was `spells`'s FIRST hit compared against a known path, which passed for every corpus
# containing the exempt file — `Claim::NoneUnder` names every offender, so it cannot be written that
# way.

if [[ "${1:-}" != "--tests" ]]; then
  exit 0
fi

# ── The parts that need a toolchain ─────────────────────────────────────────────────────────────
# Behind a flag because the constant comparison above is the part worth running on every commit.
printf 'check-supervisor: cargo test (superd)\n'
(cd rust/slopdesk-superd && cargo test --quiet)

printf 'check-supervisor: cargo test (screend)\n'
(cd rust/slopdesk-screend && cargo test --quiet)

printf 'check-supervisor: cargo test (dropd)\n'
(cd rust/slopdesk-dropd && cargo test --quiet)

# The SOCKET cases in this one need a booted device and are gated on SLOPDESK_ANDROID_HW=1
# (`scripts/check-android.sh`); without it they print why they proved nothing and pass.
printf 'check-supervisor: cargo test (androidd)\n'
(cd rust/slopdesk-androidd && cargo test --quiet)

printf 'check-supervisor: cargo test (inspectord)\n'
(cd rust/slopdesk-inspectord && cargo test --quiet)

printf 'check-supervisor: the Swift suites that drive a real daemon\n'
make superd screend dropd androidd inspectord > /dev/null
swift test --filter 'SupervisedPaneSurvivalTests|SupervisedServiceProcessTests|PTYProcessTests|HostRestartSurvivalTests|SupervisorProtocolTests|AgentSupervisionIntegrationTests|PaneOutputStreamTests|SlopDeskScreenTests|PaneScreenScanner|DropdE2ETests|FileDropServiceManagerTests|AndroidServiceManagerTests|InspectorServiceManagerTests'

printf 'check-supervisor: OK\n'

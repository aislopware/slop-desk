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

# The Python half is started HERE and collected at the very bottom, because it shares nothing with
# the shell half — it reads the same trees and writes only its own verdict — and it is a third of
# this gate's wall clock (~13 s of ~50 s). Run last-in-line it was 13 s nobody could overlap; run
# alongside, it finishes while the shell is still walking `Sources/`. Its output is buffered to a
# file rather than left on the terminal, so an interleave cannot split one of its diagnostics
# across a line of ours; the wait below replays it verbatim and exits on its status.
INVARIANTS_LOG="$(mktemp -t check-invariants)"
trap 'rm -f "${INVARIANTS_LOG}"' EXIT
python3 scripts/check-invariants.py > "${INVARIANTS_LOG}" 2>&1 &
INVARIANTS_PID=$!

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
# `scripts/check-ban-union.py`, which fails if any ban's pattern is missing from it.
DELETED_SWIFT_UNION='((enum|struct|final class) (GF256|NeonGf|ReedSolomonMatrix)\b)|((struct|enum|final class) StreamHasher\b|func (hashRow|hashNV12Scalar|rowHashes|rowHashesQuantized|borrowPlane|estimateVerticalShift|changedFraction|adaptiveMaxQP)\b)|(func (targetSeconds|stepSeconds|cgRectToCocoa|backingScaleFactor)\(|(struct|enum|final class) ScreenInfo\b)|((func|var) appendBE|(struct|enum|final class|class) BigEndianReader)|((enum|struct|final class|class|actor) (AgentManifest|CompiledAgentManifest|AgentManifestCatalog|TOMLSubsetParser|ManifestRegion|ManifestRuleEngine|BundledAgentManifests|AgentDetectionExplain|AgentOscTracker|AgentSyncFrameTracker|ClaudeManifestMatcher)\b)|((enum|struct|final class|class|actor) ShellIntegration\b|slopdesk-zdotdir-)|((enum|struct|final class|class|actor|protocol) (FileTransferServer|FileReceiveLogic|FileDropSink|DiskFileDropSink|FileNameSanitizer|LoopbackFileTransferChannel)\b)|((enum|struct|final class|class|actor|protocol) (AndroidBridgeServer|AndroidBridgeManager|AndroidToolchain|AndroidScrcpySession|AndroidDeviceCatalog|AndroidEmulatorConsole|AndroidSocket|AndroidListener|AndroidBridgeRequest)\b)|((enum|struct|final class|class|actor|protocol) (TranscriptParser|TranscriptTailer|TranscriptLine|LineAccumulator|SubagentWatcher|EventBuilder|InspectorEngine|InspectorReplayLog|InspectorSource|InspectorServer)\b)|((static (let|var|func)|let|var|func) (seededUserSettings|obsoleteSeeds|themeExtension[A-Za-z]*|bridgeExtension[A-Za-z]*|registerExtension|unregisterExtension|bundledMarketplaceExtensions|retiredExtensions|ownThemeResources)\b)|((enum|struct|final class|static (let|var|func)) (AgentInstaller|hookMarker|installedEvents|hookCommand|entryIsOurs)\b)|((struct|static (let|var|func)|private static func) (parseBranchHeader|parseStatusLine|statusNibble|packStatus|claudeProjectSlug|gitToplevel|gitStashCount|gitDiffArgumentPlan|resolveGitDiff|jsonlSessions|claudeSessions|opencodeSessions|sessionRoots|GhosttyTerminfoProbe|terminfoEntryExists|isGhosttyResolvable|effectiveTerm|liveProbe|runInfocmp)\b)|("/usr/bin/(git|infocmp)")|((let|var|func|case) *(bonusBoundary|bonusCamel123|bonusConsecutive|scoreGapStart|scoreGapExtension|bonusMatrix|bonusFor|backtrace)\b)|((enum|struct) *(HookPayload|StopInfo|ToolUseBlock|NotificationInfo|ClaudeHookBody|ClaudeHookEvent)\b|func +(mapToHookEvent|classifyNotification|stopLabel)\b)|(func +(skipEscapeSequence|isEraseToLineEnd|applySGR|extendedColour)\b)|((enum|struct|final class|class|actor) (HostOutputSniffer|OutputSniffer)\b)|((enum|struct|final class|class|actor) (CommandBlockSegmenter|CommandBlockTracker|AutoProgressMatcher)\b)|(\[\[rules\]\]|min_engine_version\s*=|skip_state_update\s*=|line_regex\s*=)|(autoProgressCommands: \[String\]|autoProgressPrefixes)|((struct|private struct) (RawWeightedChild|SpecEntry)\b|func (decodeRaw|decodeChildren|rawNode)\()|(\b(SplitNode|WeightedChild|SplitWeight|TreeWorkspace|DetachedPane|PaneSpec|VideoEndpoint|Session|Tab)\b *: *(any )?(Codable|Decodable|Encodable)\b)'
DELETED_SWIFT_CANDIDATES=$(grep -rlE "${DELETED_SWIFT_UNION}" Sources/ 2> /dev/null || true)
# The candidates matching ONE ban, or nothing. An empty candidate list answers without a grep.
among_deleted() {
  [[ -z "${DELETED_SWIFT_CANDIDATES}" ]] && return 0
  # shellcheck disable=SC2086 # the candidate list is a FILE LIST on purpose
  grep -lE "$1" ${DELETED_SWIFT_CANDIDATES} 2> /dev/null || true
}

SWIFT_PROTOCOL="Sources/SlopDeskSupervisor/SupervisorProtocol.swift"
RUST_PROTOCOL="rust/slopdesk-superd/src/protocol.rs"
SWIFT_DROP_PROTOCOL="Sources/SlopDeskFileTransfer/FileTransferProtocol.swift"
SWIFT_DROP_DIR="Sources/SlopDeskFileTransfer"
SWIFT_DROP_MANAGER="Sources/SlopDeskHost/FileDropServiceManager.swift"
RUST_DROP_PROTOCOL="rust/slopdesk-dropd/src/protocol.rs"
RUST_DROP_CLIENT="rust/slopdesk-dropd/src/client.rs"
RUST_DROP_FFI="rust/slopdesk-ffi/src/file_transfer.rs"
RUST_DROP_SERVER="rust/slopdesk-dropd/src/server.rs"
SWIFT_ANDROID_CLIENT="Sources/SlopDeskDevicePanels/Android"
SWIFT_ANDROID_DEVICE="Sources/SlopDeskDevicePanels/Android/AndroidDevice.swift"
SWIFT_ANDROID_MANAGER="Sources/SlopDeskHost/AndroidServiceManager.swift"
RUST_ANDROID_SERVER="rust/slopdesk-androidd/src/server.rs"
RUST_ANDROID_PROTOCOL="rust/slopdesk-androidd/src/protocol.rs"
SWIFT_INSPECTOR_WIRE="Sources/SlopDeskInspector/InspectorWire.swift"
SWIFT_INSPECTOR_MANAGER="Sources/SlopDeskHost/InspectorServiceManager.swift"
# The one place the three announcing daemons' shared parses live, `AnnouncedPort` and `AnnouncedVersion`.
SWIFT_LIFECYCLE="Sources/SlopDeskHost/SupervisedServiceLifecycle.swift"
RUST_INSPECTOR_WIRE="rust/slopdesk-inspectord/src/wire.rs"
RUST_INSPECTOR_FFI="rust/slopdesk-ffi/src/inspector.rs"
RUST_INSPECTOR_SERVER="rust/slopdesk-inspectord/src/server.rs"
SWIFT_CTL_LISTENER="Sources/SlopDeskHost/AgentControlListener.swift"
RUST_CTL_COMMANDS="rust/slopdesk-ctl/src/commands.rs"
SWIFT_CODESEED="Sources/SlopDeskHost/CodeSeed.swift"
RUST_CODESEED_MAIN="rust/slopdesk-codeseed/src/main.rs"
SWIFT_AGENTHOOKS="Sources/SlopDeskHost/AgentHooks.swift"
RUST_AGENTHOOKS_MAIN="rust/slopdesk-hook/src/bin/agenthooks.rs"
SWIFT_PROBE="Sources/SlopDeskHost/HostProbe.swift"
RUST_PROBE_MAIN="rust/slopdesk-probe/src/main.rs"

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

# ── One answer to "may this cell touch the disk" ────────────────────────────────────────────────
# The two paths and the policy ban are `workspace-state-file` in `rust/slopdesk-invariants`. What is
# left here is the door list: dropping ANY of them is a decision coming back to this side.
WS_FILE_SWIFT=Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateFile.swift
# Every door the face must keep asking. Dropping ANY of them is a decision coming back to this side:
# the predicate is the filter, the two codecs are the file's bytes, and the status probe is the
# taxonomy — a transcribed refusal byte that drifted on one arm turns a corrupt row into a
# mint-the-default, and the file nobody kept aside is the one nobody can look at.
for door in slopdesk_ws_state_file_is_persisted slopdesk_ws_state_file_encode \
  slopdesk_ws_state_file_decode slopdesk_ws_state_file_status; do
  if ! grep -qF "${door}" "${WS_FILE_SWIFT}"; then
    fail "${WS_FILE_SWIFT} stopped asking ${door} — one answer to what survives a restart (docs/55 §6)"
  fi
done
# And what a marshaller cannot have. An encoder of its own is the whole file coming back; a version
# literal is the no-migration rule spelled twice, where the smaller number refuses files the other
# happily writes; a base64 call is the row codec; a pane-field name is the filter itself.
#
# Comments are stripped first — naming what moved is how a boundary stays legible, and only CODE can
# re-implement it. `spells` is not defined this early in the file, so this is the plain-grep form the
# neighbouring gates use, and the same EMPTY trap applies: a haystack that read as nothing would
# pass silently, which is why the file's existence is checked above.
ws_file_code=$(grep -v '^[[:space:]]*//' "${WS_FILE_SWIFT}" 2> /dev/null) || true
if grep -qE 'JSONEncoder|JSONDecoder|base64Encoded|version *= *[0-9]|WorkspacePaneField\.|WorkspaceProjectField\.' <<< "${ws_file_code}"; then
  fail "${WS_FILE_SWIFT} decides something again — it marshals, and rust/slopdesk-wire's state_file rules (docs/55 §6)"
fi
# The far side, so the door cannot be a shim over a shim. The three refusal arms are the taxonomy a
# caller reads, and the door may only carry the byte each arm names.
for rule in 'pub fn is_persisted' 'pub fn persisting' 'pub fn encode' 'pub fn decode_bytes' \
  'const fn code' 'Malformed,' 'VersionMismatch(i64)' 'MalformedRow,'; do
  if ! grep -qF "${rule}" rust/slopdesk-wire/src/document/state_file.rs; then
    fail "rust/slopdesk-wire/src/document/state_file.rs lost ${rule} — the rule and its taxonomy are one place (docs/55 §6)"
  fi
done
printf 'check-supervisor: one answer to what survives a restart, and the Swift face only marshals it.\n'

# ── One answer to "what arrangement did I leave" ────────────────────────────────────────────────
# `SplitNode+Codable.swift` was 273 lines of Swift beside `slopdesk-workspace`'s `persist`, which had
# been a finished port with no caller. The two did not merely duplicate — they DISAGREED, and the
# disagreement is the one a person feels: for a divider the file does not name, Rust DERIVES the
# `SplitNodeId` from the seam's position (`persist::derived_split_id`) while the Swift decoder minted
# a fresh UUID, so every launch renamed every seam and every remembered divider position was lost.
# Nothing crashed and no test failed; the arrangement just kept resetting.
#
# So the Swift half is deleted, `Codec/WorkspaceFile.swift` is the face, and both halves of that are
# checked here — the file staying gone, and the face still being a marshaller rather than a decoder
# growing back under a new name.
WORKSPACE_FILE_SWIFT=Sources/SlopDeskWorkspaceModel/Codec/WorkspaceFile.swift
if [[ -e Sources/SlopDeskWorkspaceModel/Domain/Tree/SplitNode+Codable.swift ]]; then
  fail "SplitNode+Codable.swift is back — the workspace file's rule is rust/slopdesk-workspace's persist (docs/55 §6)"
fi
if [[ ! -e "${WORKSPACE_FILE_SWIFT}" ]]; then
  fail "${WORKSPACE_FILE_SWIFT} is gone — the workspace file's door has no Swift face, so the bans below stopped checking anything (docs/55 §6)"
fi
ws_codec_revived=$(among_deleted '(struct|private struct) (RawWeightedChild|SpecEntry)\b|func (decodeRaw|decodeChildren|rawNode)\(')
if [[ -n "${ws_codec_revived}" ]]; then
  printf '%s\n' "${ws_codec_revived}" >&2
  fail "a Swift workspace-file decoder is back in Sources/ — the tree's JSON lives in rust/slopdesk-workspace (docs/55 §6)"
fi
# The CONFORMANCE is the re-implementation, however small the body. `Codable` on any of these types
# is a second encoder for the file by synthesis alone — and a synthesized one has no derivation, so
# it brings the divider-renaming defect back exactly as it was. (`PaneKind`, `SplitAxis` and the
# device-prefs template values stay `Codable` on purpose: those are vocabulary, `docs/55` §8.)
ws_conformance_revived=$(among_deleted '\b(SplitNode|WeightedChild|SplitWeight|TreeWorkspace|DetachedPane|PaneSpec|VideoEndpoint|Session|Tab)\b *: *(any )?(Codable|Decodable|Encodable)\b')
if [[ -n "${ws_conformance_revived}" ]]; then
  printf '%s\n' "${ws_conformance_revived}" >&2
  fail "a workspace tree type conforms to Codable again — one encoder, and it is persist::encode_file (docs/55 §6)"
fi
# Every door the face must keep asking. The pool probe is the load-bearing one: the crate holds no
# entropy, so a caller that stopped asking how many ids a file needs would hand it a pool that runs
# dry, and a dry pool REPEATS — two panes with one id, which the repair then re-mints apart on every
# single load. That is the divider defect again, wearing the pane's clothes.
for door in slopdesk_ws_workspace_file_minted_ids slopdesk_ws_workspace_file_encode \
  slopdesk_ws_workspace_file_decode slopdesk_ws_workspace_file_status \
  slopdesk_ws_workspace_file_max_panes; do
  if ! grep -qF "${door}" "${WORKSPACE_FILE_SWIFT}"; then
    fail "${WORKSPACE_FILE_SWIFT} stopped asking ${door} — one answer to the saved arrangement (docs/55 §6)"
  fi
  if ! grep -qF "${door}" rust/slopdesk-ffi/include/slopdesk_ffi.h; then
    fail "rust/slopdesk-ffi/include/slopdesk_ffi.h does not declare ${door} — the header is hand-written and it is the ABI (docs/55 §2)"
  fi
done
# What a marshaller cannot have, and what the store beneath it cannot go back to. A `JSONEncoder` on
# either side is the whole file returning; comments are stripped first for the reason the neighbour
# gives — naming what moved is how a boundary stays legible, and only CODE can re-implement it.
for marshaller in "${WORKSPACE_FILE_SWIFT}" Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspacePersistence.swift; do
  marshaller_code=$(grep -v '^[[:space:]]*//' "${marshaller}" 2> /dev/null) || true
  if [[ -z "${marshaller_code}" ]]; then
    fail "${marshaller} read as EMPTY — it moved or is all comments, so this ban stopped checking anything (docs/55 §6)"
  fi
  if grep -qE 'JSONEncoder|JSONDecoder|CodingKeys|schemaVersion *= *[0-9]' <<< "${marshaller_code}"; then
    fail "${marshaller} decides the file's shape again — it marshals, and rust/slopdesk-workspace's persist rules (docs/55 §6)"
  fi
done
# The far side, so the door cannot be a shim over a shim. The derivation is named because it is the
# defect's actual fix: delete it and both languages agree again, on the wrong answer.
for rule in 'fn derived_split_id' 'pub fn encode_file' 'pub fn decode_file' 'pub fn minted_ids_for' \
  'Malformed,' 'VersionMismatch(i64)' 'TooManyPanes,'; do
  if ! grep -qF "${rule}" rust/slopdesk-workspace/src/persist.rs; then
    fail "rust/slopdesk-workspace/src/persist.rs lost ${rule} — the file's rule and its taxonomy are one place (docs/55 §6)"
  fi
done
printf 'check-supervisor: one answer to the saved arrangement, and the seams keep their names.\n'

for solver in Domain/SendKeysParser Domain/FocusResolver Domain/Tree/TabOrdering \
  Domain/Tree/SplitLayoutSolver Domain/Tree/SplitNode+Ops \
  Domain/Tree/WorkspaceTreeOps; do
  solver_swift="Sources/SlopDeskWorkspaceModel/${solver}.swift"
  if [[ "$(grep -c 'import CSlopDeskFFI' "${solver_swift}")" -eq 0 ]]; then
    fail "${solver_swift} no longer calls the Rust crate — the port was undone (docs/55 §6)"
  fi
done
# The scanners and comparators a re-implementation would need, and a wrapper cannot have. The
# collator is listed because it is the ONE behaviour the port deliberately narrowed: the crate's
# `natural_compare` does not fold diacritics, so a `localizedStandardCompare` reappearing here would
# be a second answer to the sidebar's order rather than a refinement of it.
# Comment lines are stripped first: naming the retired collator in a doc comment is how the
# narrowing stays legible, and only CODE can re-implement it.
solver_code=$(grep -rh '' Sources/SlopDeskWorkspaceModel/Domain --include='*.swift' |
  grep -v '^[[:space:]]*//') || true
# Same shape, same trap as `codec_code`: an empty haystack passes every ban below it silently.
if [[ -z "${solver_code}" ]]; then
  fail "Sources/SlopDeskWorkspaceModel/Domain read as EMPTY — the directory moved, so the ban list below stopped checking anything (docs/55 §6)"
fi
for ghost in 'localizedStandardCompare' 'func directionalNeighbor' 'func crossAxisOverlap' \
  'func findClose' 'private static let esc' 'func moveCandidates' 'func resolveAxis' \
  'struct AxisValues' 'func depenetrate' 'func intentArmed' 'func sweptHit' \
  'func splitImpl' 'func removeImpl' 'func mergingSameAxis' 'func shiftWeight' \
  'func enclosingSplitImpl' 'func insertBesideImpl' 'func evenPair' 'squareRoot()' \
  'sumSizes' 'positionByID' 'func flatSplit' 'func evenChild' 'private static func tiled'; do
  if grep -qF "${ghost}" <<< "${solver_code}"; then
    fail "Sources/SlopDeskWorkspaceModel grew '${ghost}' back — the solvers live in rust/slopdesk-workspace (docs/55 §6)"
  fi
done
# Four enums cross as a bare discriminant, so a case that means 4 on one side and 5 on the other
# sends focus the wrong way, aligns to the wrong edge or re-tiles into the wrong layout — with every
# test green, because each side is self-consistent. This compared the COUNT of cases for a long
# time, which cannot see that at all: it is blind to a reorder, and blind to a case added correctly
# to both enums and forgotten in the shim's decoder. The Rust half is now checked by the compiler
# and by a round-trip test per enum (`ALL[i].index() == i`); what NEITHER can reach is Swift's
# `ffiByte` switch, which is where the number is written for the third time. So the two maps are
# compared here, case name against case name, rather than counted.
#
# Both sides are read as `name -> number` and lower-cased: Swift's `case .centerHorizontal: 4` and
# the crate's `Self::CenterHorizontal => 4` are the same claim spelled two ways.
printf 'check-supervisor: every ABI enum maps the same case to the same byte in both languages\n'
compare_abi_enum() {
  local label="$1" swift_file="$2" swift_marker="$3" rust_file="$4" rust_marker="$5"
  local swift_map rust_map swift_marks rust_marks
  # THE MARKER'S UNIQUENESS IS NOW CHECKED RATHER THAN ASKED FOR. The prose below this function has
  # said "it must be unique within its file" since the day a second `RepairPass` marker in
  # `tree_ops.rs` turned two gates red — but nothing enforced it, and the quiet case is the one that
  # matters: a `sed` range whose opening address matches TWICE appends the second block to the first,
  # so the gate holds one enum's cases against two enums' rows. Red is the LUCKY outcome. The unlucky
  # one was live here on 2026-08-22: `NewTabPosition::as_byte` in `session.rs` carries a
  # byte-identical signature to `PaneKind`'s, and the gate stayed green only because that body is
  # `self as u8` and contributes no `Self::X => n` row at all. Giving it the explicit match its
  # sibling has — which is what the gate ASKS every ABI enum for — would have poisoned PaneKind's
  # comparison with `NewTabPosition`'s numbering, silently.
  swift_marks=$(grep -c -- "${swift_marker}" "${swift_file}") || true
  rust_marks=$(grep -c -- "${rust_marker}" "${rust_file}") || true
  if [[ "${swift_marks}" != "1" || "${rust_marks}" != "1" ]]; then
    fail "${label}: a marker is not unique in its file (swift ${swift_marks}x, rust ${rust_marks}x) — a sed range restarts on every match and APPENDS a second enum's rows to the first (docs/55)"
    return
  fi
  # `|| true` on both: under `set -euo pipefail` a `grep` that matches nothing exits 1 and would
  # kill the script HERE, silently, taking every check below it with it — the same trap the
  # build-ffi call above is commented for. An empty map must reach the guard, not the exit.
  swift_map=$(sed -n "/${swift_marker}/,/^ *}/p" "${swift_file}" |
    grep -oE 'case \.[a-zA-Z]+: *[0-9]+' |
    sed -E 's/case \.//; s/: */ /' | tr '[:upper:]' '[:lower:]' | sort || true)
  rust_map=$(sed -n "/${rust_marker}/,/^ *}/p" "${rust_file}" |
    grep -oE 'Self::[A-Za-z]+ *(\{[^}]*\}|\([^)]*\))? *=> *[0-9]+' |
    sed -E 's/Self:://; s/ *(\{[^}]*\}|\([^)]*\))? *=> */ /' | tr '[:upper:]' '[:lower:]' | sort || true)
  if [[ -z "${swift_map}" || -z "${rust_map}" ]]; then
    fail "${label}: one side's byte map read as EMPTY — the switch moved or changed shape, so this gate stopped checking anything (docs/55)"
    # Returning, so the comparison below does not ALSO report a disagreement: "one side is missing"
    # and "the two sides differ" are different repairs, and naming both hides the real one.
    return
  fi
  if [[ "${swift_map}" != "${rust_map}" ]]; then
    printf 'swift:\n%s\nrust:\n%s\n' "${swift_map}" "${rust_map}" >&2
    fail "${label}: the two languages disagree about which byte a case crosses as (docs/55)"
  fi
}
compare_abi_enum "FocusDirection" \
  Sources/SlopDeskWorkspaceModel/WorkspaceSolverBridge.swift 'extension FocusDirection' \
  rust/slopdesk-tree/src/focus.rs 'pub const fn index(self) -> u8'
# The Rust marker is the DOC LINE, not the signature: `session.rs` holds two `as_byte` bodies with
# identical signatures — PaneKind's and NewTabPosition's — and the uniqueness check above now refuses
# the signature outright.
compare_abi_enum "PaneKind" \
  Sources/SlopDeskWorkspaceModel/WorkspaceSolverBridge.swift 'extension PaneKind' \
  rust/slopdesk-tree/src/session.rs 'The on-wire byte, and the byte a client'
compare_abi_enum "LayoutPreset/TileLayout" \
  Sources/SlopDeskWorkspaceModel/Domain/Tree/WorkspaceTreeOps.swift 'var ffiByte: UInt8' \
  rust/slopdesk-tree/src/tree_ops.rs 'pub const fn index(self) -> u8'
# THE MARKER IS A `sed` ADDRESS, SO IT MUST BE UNIQUE WITHIN ITS FILE. A range restarts every time
# its opening address matches again, so a SECOND occurrence below the first — including one inside a
# doc comment, which `sed` reads as prose it cannot tell from code — APPENDS a second map to the
# first rather than shadowing it, and the gate then holds one side's cases against both sides' rows.
# That cost two red gates on 2026-08-20 when `RepairPass` was added to `tree_ops.rs` beside
# `TileLayout`. Name a new marker for the case it belongs to, and do not spell it again in prose.
compare_abi_enum "RepairPass" \
  Sources/SlopDeskWorkspaceModel/Domain/Tree/TreeWorkspace.swift 'var ffiByte: UInt8' \
  rust/slopdesk-tree/src/tree_ops.rs 'pub const fn ffi_byte(self) -> u8'
# The PRIMARY wire's type byte, and the one this list should have started with. Swift writes the
# tag onto the flat struct itself (`flat.message_type = messageType`), so its map is what goes out
# on the wire, and Rust's `message_type()` is the same claim spelled a second time. A case numbered
# differently at the two ends is not a decode error — it is a frame that decodes cleanly as the
# WRONG message, which is the failure the metadata-verb gate two hundred lines up already exists for
# (docs/20 §2).
compare_abi_enum "WireMessage type byte" \
  Sources/SlopDeskProtocol/WireMessage.swift 'var messageType: UInt8' \
  rust/slopdesk-wire/src/message.rs 'pub const fn message_type(&self) -> u8'
# The VIDEO wire's three type bytes. These travel a different socket from the one above and were
# missed for the same reason the primary one was: nothing here named them, so their agreement was
# only ever an accident of two people editing two files. The control map is the widest hand-written
# byte map in the tree at 28 cases, and it is the one a new verb gets appended to — which is exactly
# where a number gets reused (docs/20 §5).
compare_abi_enum "VideoControl type byte" \
  Sources/SlopDeskVideoProtocol/VideoControlCodec.swift 'public var messageType: UInt8' \
  rust/slopdesk-video/src/video_control.rs 'pub const fn message_type(&self) -> u8'
compare_abi_enum "RecoverySignaling type byte" \
  Sources/SlopDeskVideoProtocol/RecoverySignaling.swift 'public var messageType: UInt8' \
  rust/slopdesk-video/src/recovery.rs 'pub const fn message_type(&self) -> u8'
compare_abi_enum "WindowGeometry type byte" \
  Sources/SlopDeskVideoProtocol/WindowGeometryCodec.swift 'public var messageType: UInt8' \
  rust/slopdesk-video/src/window_geometry.rs 'pub const fn message_type(&self) -> u8'

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

# ── 10. dropd: the THIRD two-ended protocol ─────────────────────────────────────────────────────
# PATH 4 (`docs/53`). Unlike superd and screend this one is not a private engine — the CLIENT dials
# it, so the ends are further apart than any other pair in the tree: an iOS build shipped months ago
# is one end and a fresh dropd is the other. Nothing negotiates, so every constant below is a value
# both sides simply have to have been born with.
#
# The CLIENT end is Rust too, and the Swift files are its face. `rust/slopdesk-dropd`'s `client`
# module writes every request and reads every reply; `Sources/SlopDeskFileTransfer` calls the door in
# `rust/slopdesk-ffi/src/file_transfer.rs` and holds no layout of its own. So the constants below are
# no longer compared across two spellings — there is one spelling, and what is pinned is that Swift
# still READS it rather than quietly reacquiring a copy.
drop_entries="slopdesk_drop_encode_request slopdesk_drop_decode_reply slopdesk_drop_constant \
  slopdesk_drop_decoder_new slopdesk_drop_decoder_free slopdesk_drop_decoder_append \
  slopdesk_drop_decoder_next slopdesk_drop_decoder_buffered"
for entry in ${drop_entries}; do
  if ! grep -qF "${entry}" "${RUST_DROP_FFI}"; then
    fail "${RUST_DROP_FFI} no longer exports ${entry} — PATH 4's client door has moved (docs/55)"
  fi
  if ! grep -rqF "${entry}" "${SWIFT_DROP_DIR}"; then
    fail "${SWIFT_DROP_DIR} stopped calling ${entry} — the client end is dropd's (docs/53, docs/55)"
  fi
done

# No hand-rolled reader or writer back in the face. A "just this one field" big-endian helper is how
# a second implementation grows back one accessor at a time, and it would be the cross-language
# mirror the tree forbids — not a shortcut around one.
drop_respelled=$(grep -rlE 'func appendBE|struct ByteReader|BigEndianReader' "${SWIFT_DROP_DIR}" || true)
if [[ -n "${drop_respelled}" ]]; then
  printf '%s\n' "${drop_respelled}" >&2
  fail "a byte reader/writer is back in ${SWIFT_DROP_DIR} — dropd's client module owns the layout"
fi

# The four numbers, likewise. A cap the client believes and a cap the host enforces that drift apart
# is a bug neither side's tests can see, so the Swift constants are windows onto
# `slopdesk_drop_constant` and a literal here is the drift starting.
drop_literals=$(grep -nE '16 \* 1024 \* 1024|256 \* 1024|20 \* 1024|UInt8 = [0-9]' "${SWIFT_DROP_PROTOCOL}" || true)
if [[ -n "${drop_literals}" ]]; then
  printf '%s\n' "${drop_literals}" >&2
  fail "${SWIFT_DROP_PROTOCOL} respells a dropd constant — read slopdesk_drop_constant instead"
fi

# The type BYTE is the whole discriminator, and the two ENDS are now two modules of one crate rather
# than two languages — which narrows the skew but does not close it, because they are still written
# and edited apart. Skew a request byte and dropd decodes an offer's id out of a chunk body; skew a
# reply byte and the client's decoder throws `unknownType` on a perfectly good `complete` and reports
# a failed upload that is sitting finished on disk.
# A chunk's type byte is written by `write_chunk_payload` — the slice writer both the borrowed and
# the owned path go through — not by the match arm, so both ranges are swept and both spellings are
# read. Sweeping only the match would quietly stop covering type 3, the one frame that carries a
# body, and a gate that silently covers four of five types is worse than no gate.
client_request_types=$(
  {
    awk '/^fn write_chunk_payload/, /^\}$/' "${RUST_DROP_CLIENT}"
    awk '/pub fn encode_request_payload/, /^\}$/' "${RUST_DROP_CLIENT}"
  } | sed -n -e 's/^ *out.push(\([0-9][0-9]*\));$/\1/p' -e 's/^ *\*kind = \([0-9][0-9]*\);$/\1/p' | sort -n
)
if [[ "$(printf '%s\n' "${client_request_types}" | grep -c .)" -ne 5 ]]; then
  fail "expected 5 request type bytes in ${RUST_DROP_CLIENT}, found: ${client_request_types}"
fi
if [[ -z "${client_request_types}" ]]; then
  fail "no request type bytes found in ${RUST_DROP_CLIENT} — the extraction in this gate has gone stale"
fi
for byte in ${client_request_types}; do
  if ! grep -qE "^ *${byte} => \{$" "${RUST_DROP_PROTOCOL}"; then
    fail "the client encodes request type ${byte} but ${RUST_DROP_PROTOCOL} has no arm decoding it"
  fi
done

# The converse direction, and it must be the converse: a reply type dropd can SEND that the client
# cannot decode is a dropped connection mid-upload.
client_reply_types=$(
  awk '/pub fn decode_reply_payload/, /^\}$/' "${RUST_DROP_CLIENT}" |
    sed -n 's/^ *\([0-9][0-9]*\) => {$/\1/p' | sort -n
)
rust_reply_types=$(
  awk '/pub fn encode_reply_payload/, /^\}$/' "${RUST_DROP_PROTOCOL}" |
    sed -n 's/^ *out.push(\([0-9][0-9]*\));$/\1/p' | sort -n
)
if [[ -z "${client_reply_types}" ]]; then
  fail "no reply type bytes found in ${RUST_DROP_CLIENT} — the extraction in this gate has gone stale"
fi
same "dropd reply type bytes" \
  "$(printf '%s\n' "${client_reply_types}" | tr '\n' ' ')" \
  "$(printf '%s\n' "${rust_reply_types}" | tr '\n' ' ')"

drop_version=$(sed -n 's/.*VERSION: u8 = \([0-9][0-9]*\);$/\1/p' "${RUST_DROP_PROTOCOL}" | head -1)
frame_cap=$(sed -n 's/.*MAX_FRAME_PAYLOAD: usize = \(.*\);$/\1/p' "${RUST_DROP_PROTOCOL}" | head -1 | tr -d ' ')

# The announce line is not decoration — it is how hostd re-learns the port of a dropd that outlived
# it, by replaying the pane's ring from offset 0 (`docs/51` §6.7). Reword it on one side and hostd
# waits out its timeout, kills a perfectly healthy service and respawns it on every restart.
swift_announce=$(sed -n 's/.*let announceMarker = "\(.*\)"$/\1/p' "${SWIFT_DROP_MANAGER}" | head -1)
if [[ -z "${swift_announce}" ]]; then
  fail "no announce marker found in ${SWIFT_DROP_MANAGER} — the extraction in this gate has gone stale"
fi
if ! grep -qF "ANNOUNCE_PREFIX: &str = \"${swift_announce}\"" "${RUST_DROP_SERVER}"; then
  fail "dropd's announce marker '${swift_announce}' is not what ${RUST_DROP_SERVER} prints"
fi

# No SWIFT receiving end. Same rule as §9's screen engine: the server, the receive machine, the sink
# and the name sanitiser were DELETED when they moved, and a "small fallback for when dropd is
# missing" would be the cross-language mirror the tree forbids. When dropd is absent, hostd logs it
# and there is no file transfer — that is the whole design.
# Scoped to DECLARATIONS, like §9 above: the names still appear in prose explaining where the
# receiving end went, and a gate that fails on its own documentation teaches people to delete the
# documentation.
drop_revived=$(among_deleted '(enum|struct|final class|class|actor|protocol) (FileTransferServer|FileReceiveLogic|FileDropSink|DiskFileDropSink|FileNameSanitizer|LoopbackFileTransferChannel)\b')
if [[ -n "${drop_revived}" ]]; then
  printf '%s\n' "${drop_revived}" >&2
  fail "a Swift file-drop receiver is back in Sources/ — dropd owns the receiving end (docs/53)"
fi

# ── 11. androidd: the FOURTH two-ended protocol ─────────────────────────────────────────────────
# The Android panel (`docs/48`). Like dropd the CLIENT is one end — it dials the bridge port directly,
# having learned it from metadata verb 22 — but unlike every other pair here the wire is line-JSON,
# so a skew is not a misparsed length: it is a request the daemon answers `bad request` to, or a
# reply field the panel silently renders as absent. Both read as "the Android tab is broken" with
# nothing in either language's tests to say why.
#
# The `op` STRING is the whole discriminator. Every one the client can send must have an arm.
swift_android_ops=$(
  grep -rhn '"op": "' "${SWIFT_ANDROID_CLIENT}" |
    sed -n 's/.*"op": "\([a-z][a-z]*\)".*/\1/p' | sort -u
) || true
if [[ -z "${swift_android_ops}" ]]; then
  fail "no bridge ops found under ${SWIFT_ANDROID_CLIENT} — the extraction in this gate has gone stale"
fi
for op in ${swift_android_ops}; do
  if ! grep -qE "^ *\"${op}\" =>" "${RUST_ANDROID_SERVER}"; then
    fail "the panel sends op '${op}' but ${RUST_ANDROID_SERVER} has no arm serving it"
  fi
done

# The device row's field names, the other direction. A key the daemon stopped emitting is a column
# that quietly empties — the panel renders what it finds, which is what makes this silent.
swift_android_fields=$(
  sed -n 's/^ *[a-zA-Z]*: entry\["\([a-zA-Z]*\)"\].*/\1/p' "${SWIFT_ANDROID_DEVICE}" | sort -u
)
if [[ -z "${swift_android_fields}" ]]; then
  fail "no device fields found in ${SWIFT_ANDROID_DEVICE} — the extraction in this gate has gone stale"
fi
for field in ${swift_android_fields}; do
  if ! grep -qE "\"${field}\"" "${RUST_ANDROID_PROTOCOL}"; then
    fail "the panel decodes device field '${field}' but ${RUST_ANDROID_PROTOCOL} never encodes it"
  fi
done

# The announce line, same load as dropd's: it is how hostd learns the port at all, the bridge being
# on an ephemeral one. Reword it on one side and the panel reports `starting` forever.
swift_android_announce=$(sed -n 's/.*let announceMarker = "\(.*\)"$/\1/p' "${SWIFT_ANDROID_MANAGER}" | head -1)
if [[ -z "${swift_android_announce}" ]]; then
  fail "no announce marker found in ${SWIFT_ANDROID_MANAGER} — the extraction in this gate has gone stale"
fi
if ! grep -qF "ANNOUNCE_PREFIX: &str = \"${swift_android_announce}\"" "${RUST_ANDROID_SERVER}"; then
  fail "androidd's announce marker '${swift_android_announce}' is not what ${RUST_ANDROID_SERVER} prints"
fi

# No SWIFT bridge. Same rule as §9 and §10, and the same scoping to DECLARATIONS so prose explaining
# where the bridge went does not fail its own gate. `AndroidDevice` is deliberately NOT in this list:
# the CLIENT's row type is the far end of the protocol, which is exactly what the rule allows.
android_revived=$(among_deleted '(enum|struct|final class|class|actor|protocol) (AndroidBridgeServer|AndroidBridgeManager|AndroidToolchain|AndroidScrcpySession|AndroidDeviceCatalog|AndroidEmulatorConsole|AndroidSocket|AndroidListener|AndroidBridgeRequest)\b')
if [[ -n "${android_revived}" ]]; then
  printf '%s\n' "${android_revived}" >&2
  fail "a Swift Android bridge is back in Sources/ — androidd owns adb and the pump (docs/48)"
fi

# ── 12. inspectord: the FIFTH two-ended protocol ────────────────────────────────────────────────
# The read-only inspector (`docs/54`). The client has always dialled `terminalPort + 1` directly, so
# like dropd and androidd this is a wire with a shipped client on one end — and it is the most
# silent of the five, because both halves are tolerant BY DESIGN: an unknown frame tag is skipped
# and an unparseable event body is skipped, precisely so one rogue frame cannot end a session's
# feed. Skew the tags and nothing errors anywhere; the panel just stays empty.
#
# The FRAME is Rust on both ends now: `wire.rs` owns the prefix, the cap, the three tags and the
# splitter, and `Sources/SlopDeskInspector` is its face through the door in
# `rust/slopdesk-ffi/src/inspector.rs`. What is left in Swift is the event JSON, which is a document
# the daemon writes and the client reads — the two-ENDS shape, not one capability twice. So the tags
# and the cap are no longer compared across two spellings; what is pinned is that there is still
# only one spelling, and that Swift reaches it.
inspector_entries="slopdesk_inspector_encode_subscribe slopdesk_inspector_decode_payload \
  slopdesk_inspector_constant slopdesk_inspector_decoder_new slopdesk_inspector_decoder_free \
  slopdesk_inspector_decoder_append slopdesk_inspector_decoder_next \
  slopdesk_inspector_decoder_buffered"
for entry in ${inspector_entries}; do
  if ! grep -qF "${entry}" "${RUST_INSPECTOR_FFI}"; then
    fail "${RUST_INSPECTOR_FFI} no longer exports ${entry} — the inspector's client door has moved (docs/55)"
  fi
  # `_buffered` is the door's own assertion that a drained splitter has compacted, exercised by the
  # crate's tests; Swift sizes its body buffer from the AGAIN verdict instead, so it is the one
  # entry with no Swift caller and is pinned on the Rust side only.
  if [[ "${entry}" != "slopdesk_inspector_decoder_buffered" ]] &&
    ! grep -qF "${entry}" "${SWIFT_INSPECTOR_WIRE}"; then
    fail "${SWIFT_INSPECTOR_WIRE} stopped calling ${entry} — the frame is inspectord's (docs/54, docs/55)"
  fi
done

# No frame arithmetic back in the face: a length prefix read by hand, or a tag or cap respelled, is
# the second implementation growing back one line at a time.
inspector_respelled=$(grep -nE 'appendBE|readPrefix|readBESeq|struct ByteReader|16 \* 1024 \* 1024|UInt8 = [0-9]' \
  "${SWIFT_INSPECTOR_WIRE}" || true)
if [[ -n "${inspector_respelled}" ]]; then
  printf '%s\n' "${inspector_respelled}" >&2
  fail "${SWIFT_INSPECTOR_WIRE} respells the inspector frame — read slopdesk_inspector_constant instead"
fi

# The three tags, and the cap, where they are now spelled. `1` and `2` are what the daemon writes
# and the client end reads; `3` is what the client writes and the daemon reads — and the client end
# must refuse it, since seeing one arrive means the daemon echoed the client's own control back.
if ! grep -qE 'TAG_EVENT: u8 = 1;' "${RUST_INSPECTOR_WIRE}" || ! grep -qE 'TAG_KEEP_ALIVE: u8 = 2;' "${RUST_INSPECTOR_WIRE}"; then
  fail "${RUST_INSPECTOR_WIRE} no longer writes tag 1 for an event and 2 for a keep-alive"
fi
if ! grep -qE 'TAG_SUBSCRIBE: u8 = 3;' "${RUST_INSPECTOR_WIRE}"; then
  fail "${RUST_INSPECTOR_WIRE} no longer spells the client's subscribe tag as 3"
fi
if ! grep -qE 'TAG_EVENT => Ok\(ClientFrame::Event' "${RUST_INSPECTOR_WIRE}" ||
  ! grep -qE 'TAG_KEEP_ALIVE => Ok\(ClientFrame::KeepAlive\)' "${RUST_INSPECTOR_WIRE}"; then
  fail "${RUST_INSPECTOR_WIRE}'s decode_client no longer reads exactly the two host → client tags"
fi

# The frame cap. A daemon whose cap is LOWER refuses a large replay frame it just built; a HIGHER
# one has the client throw `frameTooLarge`, which is the ONE unrecoverable decode error (framing
# desync). One spelling now, and the door vends it.
if ! grep -qE 'MAX_FRAME_PAYLOAD: usize = 16 \* 1024 \* 1024;' "${RUST_INSPECTOR_WIRE}"; then
  fail "${RUST_INSPECTOR_WIRE}'s frame cap is not the 16 MiB ceiling the other four paths use"
fi

# The announce line, same load as dropd's: it is how hostd verifies the port of an inspectord that
# outlived it. Reword it on one side and hostd kills a healthy service on every restart.
swift_inspector_announce=$(sed -n 's/.*let announceMarker = "\(.*\)"$/\1/p' "${SWIFT_INSPECTOR_MANAGER}" | head -1)
if [[ -z "${swift_inspector_announce}" ]]; then
  fail "no announce marker found in ${SWIFT_INSPECTOR_MANAGER} — the extraction in this gate has gone stale"
fi
if ! grep -qF "ANNOUNCE_PREFIX: &str = \"${swift_inspector_announce}\"" "${RUST_INSPECTOR_SERVER}"; then
  fail "inspectord's announce marker '${swift_inspector_announce}' is not what ${RUST_INSPECTOR_SERVER} prints"
fi

# No SWIFT producer. Same rule as §9, §10 and §11: the transcript parser, the tailer, the line
# accumulator, the subagent watcher, the event builder, the engine, the replay log and hostd's
# listener were DELETED when they moved. `InspectorSource` is named here too — it was the host end
# of the wire, and a "small one just for tests" is the cross-language mirror the tree forbids
# (`InspectorClient`, `InspectorViewModel` and the event types are the far end, which is allowed).
# Scoped to DECLARATIONS so prose explaining where the producer went does not fail its own gate.
inspector_revived=$(among_deleted '(enum|struct|final class|class|actor|protocol) (TranscriptParser|TranscriptTailer|TranscriptLine|LineAccumulator|SubagentWatcher|EventBuilder|InspectorEngine|InspectorReplayLog|InspectorSource|InspectorServer)\b')
if [[ -n "${inspector_revived}" ]]; then
  printf '%s\n' "${inspector_revived}" >&2
  fail "a Swift inspector producer is back in Sources/ — inspectord owns the fold (docs/54)"
fi

# ── 12b. The announce line's OTHER number: which build is running ───────────────────────────────
# dropd, inspectord and androidd outlive hostd — hostd re-learns their port by replaying superd's
# ring, which is what §§10–12's announce-marker gates are about. The version of the build that is
# RUNNING rides the same line, first in the parenthetical, for exactly that reason: it is the only
# channel that describes a child this hostd did not start (`docs/49`).
#
# Four spellings, one string. A skew here is the quietest failure in this file: hostd's parser finds
# no marker, reports `unknown`, and goes on running last week's daemon behind this week's version
# number — green tests, working panel, wrong code.
swift_version_marker=$(sed -n 's/^ *static let marker = "\(.*\)"$/\1/p' "${SWIFT_LIFECYCLE}" | head -1)
if [[ -z "${swift_version_marker}" ]]; then
  fail "no announce VERSION marker found in ${SWIFT_LIFECYCLE} — the extraction in this gate has gone stale"
fi
for announcing_server in "${RUST_DROP_SERVER}" "${RUST_INSPECTOR_SERVER}" "${RUST_ANDROID_SERVER}"; do
  if ! grep -qF "ANNOUNCE_VERSION_PREFIX: &str = \"${swift_version_marker}\"" "${announcing_server}"; then
    fail "the announce version marker '${swift_version_marker}' is not what ${announcing_server} prints (docs/49)"
  fi
  # Its OWN compile-time version, never a number read back off disk — a daemon that reported the
  # installed version would compare equal to it forever, which is the failure inverted.
  if ! grep -q 'ANNOUNCE_VERSION_PREFIX}{}' "${announcing_server}" ||
    ! grep -q 'env!("CARGO_PKG_VERSION")' "${announcing_server}"; then
    fail "${announcing_server} no longer announces its own compile-time version after the marker (docs/49)"
  fi
done
# And the three managers that read it. A manager that stopped parsing reads `nil`, which the audit
# reports as "unknown" rather than failing — so it is asserted here or nowhere.
for announce_reader in "${SWIFT_DROP_MANAGER}" "${SWIFT_INSPECTOR_MANAGER}" "${SWIFT_ANDROID_MANAGER}"; do
  if ! grep -q 'func parseAnnouncedVersion(fromLogLine' "${announce_reader}"; then
    fail "${announce_reader} no longer reads the running daemon's version off its announce line (docs/49)"
  fi
done

# ── 12c. The per-sidecar version POLICY: one table, in Rust ─────────────────────────────────────
# What may be done about a stale sidecar has two callers, in two languages: hostd's startup audit
# (Swift, through the FFI door) and `slopdesk sidecars` (the CLI's Rust core, over two MANIFEST.json
# files). It is therefore the exact shape the one-implementation rule exists for, and the exact
# shape that skews quietly — a Swift copy and a Rust copy would disagree about screend the first
# time somebody changed its idle-exit and updated one of them, and every suite would stay green.
#
# So: the table lives in `rust/slopdesk-sidecars`, the doors carry it across, and the Swift side is
# a decode. This gate is what keeps a "small local helper" from growing back on the near side.
RUST_SIDECARS="rust/slopdesk-sidecars/src/lib.rs"
RUST_SIDECARS_MANIFEST="rust/slopdesk-sidecars/src/manifest.rs"
SWIFT_SIDECAR_AUDIT="Sources/SlopDeskHost/SidecarVersionAudit.swift"
SWIFT_SIDECAR_CLI="Sources/SlopDeskCLICore/CLISidecars.swift"
FFI_HEADER="rust/slopdesk-ffi/include/slopdesk_ffi.h"
HOMEBREW_FORMULA="packaging/homebrew/Formula/slopdesk.rb"
for sidecar_file in "${RUST_SIDECARS}" "${RUST_SIDECARS_MANIFEST}" "${SWIFT_SIDECAR_AUDIT}" \
  "${SWIFT_SIDECAR_CLI}" "${FFI_HEADER}" "${HOMEBREW_FORMULA}"; do
  [[ -f "${sidecar_file}" ]] || fail "${sidecar_file} is gone — the per-sidecar version policy has no home (docs/49)"
done
# The four policies, named in the crate. A case added on the Swift side alone decodes to
# `operatorChoice` and reports "your call" about a daemon that should have been restarted.
for sidecar_policy in Automatic SelfRetiring OperatorChoice NotResident; do
  grep -q "    ${sidecar_policy}," "${RUST_SIDECARS}" ||
    fail "${RUST_SIDECARS} no longer names the ${sidecar_policy} restart policy (docs/49)"
done
grep -q 'pub fn policy(tool: &str) -> RestartPolicy' "${RUST_SIDECARS}" ||
  fail "${RUST_SIDECARS} no longer holds the policy table (docs/49)"
grep -q 'pub fn plan(' "${RUST_SIDECARS_MANIFEST}" ||
  fail "${RUST_SIDECARS_MANIFEST} no longer holds the manifest diff (docs/49)"
# The near side DECODES. A `switch` over tool names, or a verdict computed here, is the second
# implementation — which is the thing this whole block exists to prevent.
if grep -qE 'case "slopdesk-(dropd|screend|superd)"' "${SWIFT_SIDECAR_AUDIT}"; then
  fail "${SWIFT_SIDECAR_AUDIT} decides about a tool by name again — the table is ${RUST_SIDECARS} (docs/49)"
fi
# And the three doors, each called from the language that needs it.
for sidecar_door in slopdesk_sidecar_audit slopdesk_sidecar_version_banner slopdesk_sidecar_upgrade_plan; do
  grep -q "${sidecar_door}" "${FFI_HEADER}" ||
    fail "${sidecar_door} is not declared in ${FFI_HEADER} — Swift cannot reach the policy (docs/55)"
done
grep -q 'slopdesk_sidecar_audit(' "${SWIFT_SIDECAR_AUDIT}" ||
  fail "${SWIFT_SIDECAR_AUDIT} no longer asks the door for its verdict (docs/49)"
grep -q 'slopdesk_sidecar_upgrade_plan(' "${SWIFT_SIDECAR_CLI}" ||
  fail "${SWIFT_SIDECAR_CLI} no longer asks the door for the upgrade plan (docs/49)"
# The install side must keep BOTH halves: the plan it prints, and the record that makes the NEXT
# plan about one tool rather than all twelve. A formula whose post_install stopped recording leaves
# every upgrade reading as a first install, which is a table that never says anything.
grep -q 'sidecars", "--record"' "${HOMEBREW_FORMULA}" ||
  fail "${HOMEBREW_FORMULA} no longer records the manifest — every upgrade would read as a first install (docs/49)"
printf 'check-supervisor: the sidecar version policy is Rust, and the install side records what it read.\n'

# ── 13. slopdesk-ctl: the agent-control CLI, and the verbs it may send ───────────────────────────
# The SIXTH two-ended contract, and the only one where the far end is a program a USER types. hostd
# answers an unknown method with `{"ok":false,"error":"unknown method: X"}` — a clean error, and a
# clean error is exactly what makes this drift silent in the way that matters: the agent that ran
# `slopdesk-ctl read` sees a failed command, not a broken build, and both suites stay green. So the
# verb sets are compared as SETS, from the two switches themselves.
#
# `subscribe` is spelled apart from the rest on both sides: the host handles it before the request
# switch (it hijacks the connection into a stream) and the CLI sends it from `Control::stream`,
# reached by BOTH the `subscribe` and `events` subcommands. It is added to each side by hand here,
# which is honest — a gate that silently dropped it would stop covering the one streaming verb.
swift_ctl_verbs=$(sed -n 's/^        case "\([a-z-]*\)":$/\1/p' "${SWIFT_CTL_LISTENER}" | sort -u)
swift_ctl_verbs=$(printf '%s\nsubscribe\n' "${swift_ctl_verbs}" | sort -u)
# awk, not sed: rustfmt wraps a long call so the method literal lands on the NEXT line, and a plain
# line-wise pattern for a bare quoted string would also swallow every string literal in the tests.
# Anchoring on `ctl.call(` and looking one line ahead reads only the argument that is actually sent.
rust_ctl_verbs=$(awk '
  /ctl\.call\(/ {
    if (match($0, /ctl\.call\("[a-z-]+"/)) {
      print substr($0, RSTART + 10, RLENGTH - 11)
    } else {
      want = 1
    }
    next
  }
  want { if (match($0, /"[a-z-]+"/)) print substr($0, RSTART + 1, RLENGTH - 2); want = 0 }
' "${RUST_CTL_COMMANDS}" | sort -u)
rust_ctl_verbs=$(printf '%s\nsubscribe\n' "${rust_ctl_verbs}" | sort -u)
if [[ -z "${swift_ctl_verbs}" || -z "${rust_ctl_verbs}" ]]; then
  fail "no ctl verbs extracted from ${SWIFT_CTL_LISTENER} / ${RUST_CTL_COMMANDS} — this gate has gone stale"
elif [[ "${swift_ctl_verbs}" != "${rust_ctl_verbs}" ]]; then
  printf 'hostd accepts:\n%s\nthe CLI sends:\n%s\n' "${swift_ctl_verbs}" "${rust_ctl_verbs}" >&2
  fail "the ctl verb sets disagree — a verb one side does not know is a runtime error, not a build one"
fi

# No SWIFT ctl. Same rule as §9–§12: `slopdesk-ctl` is Rust, and the Swift executable plus its
# `SlopDeskCtlCore` were DELETED in the same change (`docs/DECISIONS.md`, the ctl port). The two
# NDJSON line helpers the `slopdesk` CLI still needed moved into `ClientControlProtocol`; a target
# named CtlCore coming back is the cross-language mirror the tree forbids.
if [[ -e Sources/SlopDeskCtlCore || -e Sources/slopdesk-ctl || -e Tests/SlopDeskCtlTests ]]; then
  fail "a Swift slopdesk-ctl is back in the tree — the CLI is rust/slopdesk-ctl (docs/DECISIONS.md)"
fi
# Scoped to the QUOTED target name — prose explaining where CtlCore went must not fail its own gate.
if grep -q '"SlopDeskCtlCore"' Package.swift; then
  fail "Package.swift declares SlopDeskCtlCore again — the agent CLI is Rust, built by \`make ctl\`"
fi

# ── 14. slopdesk-codeseed: the SEVENTH contract, and the only one that is not a socket ──────────
# hostd asks this one by FORKING it, one subcommand per question, and reads one JSON object back.
# Which makes the drift here quieter than any wire's: a renamed subcommand is not a decode failure,
# it is `usage()` on stdout and a non-zero exit, `CodeSeed.ask` answering `nil`, and — for
# `launch-args` — the code panel reporting itself UNAVAILABLE. No error is logged anywhere, because
# an unavailable panel is exactly what a host with no seeder is supposed to report. So the two
# subcommand sets are compared as sets, from the two switches themselves.
#
# `sync-font` is spelled across lines on the Swift side (its three flags follow it in the array),
# so the extraction anchors on `ask([` and looks one line ahead — the same shape §13 needed.
swift_codeseed_verbs=$(awk '
  /ask\(\[/ {
    if (match($0, /ask\(\["[a-z-]+"/)) {
      print substr($0, RSTART + 6, RLENGTH - 7)
    } else {
      want = 1
    }
    next
  }
  want { if (match($0, /"[a-z-]+"/)) print substr($0, RSTART + 1, RLENGTH - 2); want = 0 }
' "${SWIFT_CODESEED}" | sort -u)
rust_codeseed_verbs=$(sed -n 's/^        "\([a-z-]*\)" =>.*/\1/p' "${RUST_CODESEED_MAIN}" | sort -u)
if [[ -z "${swift_codeseed_verbs}" || -z "${rust_codeseed_verbs}" ]]; then
  fail "no codeseed subcommands extracted from ${SWIFT_CODESEED} / ${RUST_CODESEED_MAIN} — this gate has gone stale"
elif [[ "${swift_codeseed_verbs}" != "${rust_codeseed_verbs}" ]]; then
  printf 'hostd asks:\n%s\nthe seeder answers:\n%s\n' "${swift_codeseed_verbs}" "${rust_codeseed_verbs}" >&2
  fail "the codeseed subcommand sets disagree — a renamed one reports the panel unavailable, silently"
fi

# No SWIFT seeder. The whole profile — settings, both extensions, the registry, argv, the env delta,
# the paths — moved in one change, and the ~2.7k lines it replaced were DELETED with it
# (`docs/DECISIONS.md`, stage 22). Scoped to DECLARATIONS so the prose in `CodeSeed.swift` naming
# what moved does not fail its own gate.
seeder_revived=$(among_deleted '(static (let|var|func)|let|var|func) (seededUserSettings|obsoleteSeeds|themeExtension[A-Za-z]*|bridgeExtension[A-Za-z]*|registerExtension|unregisterExtension|bundledMarketplaceExtensions|retiredExtensions|ownThemeResources)\b')
if [[ -n "${seeder_revived}" ]]; then
  printf '%s\n' "${seeder_revived}" >&2
  fail "a Swift profile seeder is back in Sources/ — slopdesk-codeseed owns the code-server profile"
fi
if [[ -e Sources/SlopDeskHost/CodeServerManagerSeedHistory.swift || -e Sources/SlopDeskHost/Resources ]]; then
  fail "the Swift seed history or its resource bundle is back — both live in rust/slopdesk-codeseed"
fi
# The resources are the seeder's INPUT, and a second copy under the Swift target is a second answer
# to "what does a pristine settings file say". Scoped to the quoted bundle name in the manifest.
if grep -q '\.copy("Resources")' Package.swift; then
  fail "Package.swift bundles a Resources directory again — the seed inputs are rust/slopdesk-codeseed/resources"
fi

# ── 15. slopdesk-agenthooks: the hooks installer, and the marker it must not lose ────────────────
# The EIGHTH contract, forked like §14 rather than dialled, and drifting in two ways at once.
#
# The subcommand sets first, for §14's reason: a renamed one is `usage()` and a non-zero exit, which
# `AgentHooks.ask` reads as "not installed" and the Settings row shows as a green offer to install
# something that then fails. Nothing logs.
# `ask(["status"])` and `answer(["install"])` — two helpers, one shape, so the pattern anchors on the
# single-element array rather than on either name.
swift_agenthooks_verbs=$(sed -nE 's/.*(ask|answer)\(\["([a-z]+)"\]\).*/\2/p' "${SWIFT_AGENTHOOKS}" | sort -u)
rust_agenthooks_verbs=$(sed -n 's/^        "\([a-z]*\)" =>.*/\1/p' "${RUST_AGENTHOOKS_MAIN}" | sort -u)
if [[ -z "${swift_agenthooks_verbs}" || -z "${rust_agenthooks_verbs}" ]]; then
  fail "no agenthooks subcommands extracted from ${SWIFT_AGENTHOOKS} / ${RUST_AGENTHOOKS_MAIN} — this gate has gone stale"
elif [[ "${swift_agenthooks_verbs}" != "${rust_agenthooks_verbs}" ]]; then
  printf 'hostd asks:\n%s\nthe installer answers:\n%s\n' "${swift_agenthooks_verbs}" "${rust_agenthooks_verbs}" >&2
  fail "the agenthooks subcommand sets disagree — a renamed one reads as 'not installed', silently"
fi

# The marker IS the installed basename. `hook_path` joins `HOOK_MARKER` rather than spelling
# `slopdesk-agent` a second time, so the two cannot drift — this asserts that construction survives,
# because the day someone writes the literal back in is the day an uninstall silently stops matching
# what an install wrote.
if ! grep -q 'join("hooks")' rust/slopdesk-hook/src/install.rs ||
  ! grep -q '\.join(HOOK_MARKER)' rust/slopdesk-hook/src/install.rs; then
  fail "install::hook_path no longer builds the installed name from HOOK_MARKER — the merge sentinel and the installed basename must be one constant"
fi

# The relay takes NO dependencies. `serde_json` is the installer's, and it stays out of the binary
# Claude Code forks twice per tool call only because nothing the relay's `main` reaches can see it.
# A `use serde_json` (or any other crate) in the relay's own two files is the regression: it would
# not fail a build, a test or a lint — it would just make every tool call slower.
if grep -qE '^\s*use +(serde|serde_json)\b' rust/slopdesk-hook/src/main.rs rust/slopdesk-hook/src/lib.rs; then
  fail "the hook relay reaches a dependency — its cost IS process startup (docs/DECISIONS.md, stage 23)"
fi

# No SWIFT installer. The merge, the marker, the event list and the paths moved in one change and
# the Swift original was deleted with it. Scoped to DECLARATIONS so `AgentHooks.swift`'s prose about
# what moved does not fail its own gate.
installer_revived=$(among_deleted '(enum|struct|final class|static (let|var|func)) (AgentInstaller|hookMarker|installedEvents|hookCommand|entryIsOurs)\b')
if [[ -n "${installer_revived}" ]]; then
  printf '%s\n' "${installer_revived}" >&2
  fail "a Swift hooks installer is back in Sources/ — slopdesk-agenthooks owns ~/.claude/settings.json"
fi
if [[ -e Sources/SlopDeskHost/AgentInstaller.swift ]]; then
  fail "AgentInstaller.swift is back — the merge lives in rust/slopdesk-hook/src/install.rs"
fi

# ── 16. slopdesk-probe: the metadata RPC's directory, session and diff half ─────────────────────
# The NINTH contract. Same fork-per-question shape as §14 and §15, with one wrinkle neither of those
# has: two of the subcommands answer in RAW BYTES, so their "nothing there" cannot be an empty
# answer and has to be the exit code.
#
# The subcommand sets first. A renamed one is `usage()` and a non-zero exit, which every caller here
# reads as ".noRepo" or ".notFound" — a git line that quietly goes blank and a file tree that quietly
# stops expanding, with nothing logged anywhere.
swift_probe_verbs=$(sed -nE 's/.*(ask|askBytes)\(\["([a-z-]+)".*/\2/p' "${SWIFT_PROBE}" | sort -u)
rust_probe_verbs=$(sed -n 's/^        "\([a-z-]*\)" =>.*/\1/p' "${RUST_PROBE_MAIN}" | sort -u)
if [[ -z "${swift_probe_verbs}" || -z "${rust_probe_verbs}" ]]; then
  fail "no probe subcommands extracted from ${SWIFT_PROBE} / ${RUST_PROBE_MAIN} — this gate has gone stale"
elif [[ "${swift_probe_verbs}" != "${rust_probe_verbs}" ]]; then
  printf 'hostd asks:\n%s\nthe probe answers:\n%s\n' "${swift_probe_verbs}" "${rust_probe_verbs}" >&2
  fail "the probe subcommand sets disagree — a renamed one reads as 'no repo' or 'not found', silently"
fi

# Empty is an ANSWER. An unchanged file has an empty diff and exits 0; a file that is not there exits
# non-zero. `askBytes` must therefore branch on the STATUS and never on the byte count — the tidy-up
# that writes `data.isEmpty ? nil : data` turns every unchanged file into a `.notFound`, and does it
# without failing a build, a test or a lint.
if grep -qE '\bdata\b[[:alnum:]_.]*\.isEmpty|\.isEmpty *\? *nil' "${SWIFT_PROBE}"; then
  fail "HostProbe folds an empty answer into a missing one — emptiness is the probe's exit code's job (docs/DECISIONS.md, stage 24)"
fi

# No SWIFT git. Same rule as §9–§15: the porcelain parser, the status packing, the Claude slug and
# the diff-base ladder moved in one change and the Swift originals were deleted with it. Scoped to
# DECLARATIONS so the prose in `HostProbe.swift` about what moved does not fail its own gate.
probe_revived=$(among_deleted '(struct|static (let|var|func)|private static func) (parseBranchHeader|parseStatusLine|statusNibble|packStatus|claudeProjectSlug|gitToplevel|gitStashCount|gitDiffArgumentPlan|resolveGitDiff|jsonlSessions|claudeSessions|opencodeSessions|sessionRoots|GhosttyTerminfoProbe|terminfoEntryExists|isGhosttyResolvable|effectiveTerm|liveProbe|runInfocmp)\b')
if [[ -n "${probe_revived}" ]]; then
  printf '%s\n' "${probe_revived}" >&2
  fail "a Swift git/session/terminfo parser is back in Sources/ — slopdesk-probe owns porcelain, the slug, the diff bases and the TERM table"
fi
# And nothing in Sources/ spawns what the probe spawns. `lsof` is the one subprocess left on the
# Swift side; a `git` or an `infocmp` next to it is a ported path coming back — for git, the
# four-spawns-per-request one.
swift_spawns=$(among_deleted '"/usr/bin/(git|infocmp)"')
if [[ -n "${swift_spawns}" ]]; then
  printf '%s\n' "${swift_spawns}" >&2
  fail "Swift spawns git or infocmp again — both belong inside slopdesk-probe (docs/DECISIONS.md, stages 24 and 25)"
fi

# ── 16b. The git STATUS is linked, not forked, and it is asked in exactly one place ─────────────
# `gitStatus` left the probe entirely: `rust/slopdesk-git` opens the repository once and answers from
# libgit2, linked into hostd through `slopdesk_git_status`. What that removed was five process spawns
# per debounced FSEvents tick per watched repo — four `git` runs inside one fork of the probe — so a
# `git status` reappearing ANYWHERE on this path is not a style question, it is the cost coming back.
#
# Three things are pinned, because the port has three ways to be undone quietly:
#
#  1. The Swift face calls the door. Without this, the face could be rewritten around a `Process`
#     and every test would still pass — the answer would be identical and only the spawns would
#     differ, which is the whole of what changed.
if ! grep -q 'slopdesk_git_status' "Sources/SlopDeskHost/HostGitStatus.swift" 2> /dev/null; then
  fail "HostGitStatus no longer calls slopdesk_git_status — the git line is back on a subprocess (docs/55)"
fi
#  2. The engine is where the answer is decided. A face that grew a fallback parser would be the
#     two-implementations shape CLAUDE.md forbids, and it would only show up under an unusual repo.
if ! grep -q 'pub fn of_path' "rust/slopdesk-git/src/status.rs" 2> /dev/null; then
  fail "rust/slopdesk-git no longer answers of_path — the status engine moved without its ratchet"
fi
#  3. The probe does not answer it again. The verb-set gate above compares hostd's asks with the
#     probe's arms, so a revived `git-status` arm passes it the moment someone adds the Swift side
#     back — this names the arm itself.
if grep -q '"git-status"' "${RUST_PROBE_MAIN}" 2> /dev/null; then
  fail "slopdesk-probe answers git-status again — the status engine is rust/slopdesk-git, linked (docs/DECISIONS.md)"
fi
# And the porcelain PAIR is spelled once, in the crate that reads it off libgit2's bitflags. The old
# probe's table lived beside a parser that is gone; a second copy of it anywhere is a wire contract
# with two masters.
porcelain_copies=$(grep -rln 'status_nibble\|pack_status' rust/ --exclude-dir=target 2> /dev/null || true)
if [[ -n "${porcelain_copies}" ]]; then
  printf '%s\n' "${porcelain_copies}" >&2
  fail "the porcelain nibble table is back outside slopdesk-git::porcelain — one table, one crate"
fi

# ── 16c. The pointer tables are one table, and the raw value crosses unparsed ────────────────────
# `slopdesk_terminal::pointer` owns both of libghostty's pointer actions. This one is pinned harder
# than its size suggests, because EVERY way it breaks is silent: a resize handle showing a hand, or a
# pointer hidden with no gesture that brings it back. Nothing fails to compile, nothing crashes, and
# `check-macos.sh` is the only thing that would ever have noticed.
for face in Sources/SlopDeskWorkspaceCore/Terminal/PointerShapeMapping.swift \
  Sources/SlopDeskWorkspaceCore/Terminal/MouseVisibilityMapping.swift; do
  if ! grep -q 'slopdesk_pointer_' "${face}" 2> /dev/null; then
    fail "${face} stopped asking the door — a pointer table decided in Swift is a second table (docs/56, increment 50)"
  fi
done
# The mirror that was deleted, by name. `OSCPointerShape` (34 cases) and `MouseVisibility` existed
# only so a Swift `switch` had something to switch over, which made three copies of one declaration
# order — libghostty's header, the mirror, the table — where any two could drift while compiling.
# The raw `int32_t` travels now. A revived mirror reads like tidying and restores the drift.
#
# `ThirdParty/ghostty/integration` and `--include='*.swift'`, NOT a bare `ThirdParty/`. The bare walk
# read all 8 GB of it — `.work/` holds a full ghostty checkout plus its zig build tree, 62k files,
# almost all of them object code — through single-threaded /usr/bin/grep, and cost 4m20s of the
# ~39s this whole gate is supposed to take. It was the entire pre-push wait. The mirror this bans is
# Swift by definition, and the only Swift under ThirdParty/ that this repo writes is the embedder in
# `ghostty/integration` — the same scope the DocC gate below already `find`s for the same reason.
pointer_mirrors=$(grep -rln --include='*.swift' 'enum OSCPointerShape\|enum MouseVisibility[^M]' \
  Sources/ Tests/ ThirdParty/ghostty/integration 2> /dev/null || true)
if [[ -n "${pointer_mirrors}" ]]; then
  printf '%s\n' "${pointer_mirrors}" >&2
  fail "a Swift mirror of a libghostty pointer enum is back — the raw int crosses (docs/56, increment 50)"
fi
# `PointerShapeToken`'s discriminants ARE the wire, so they are spelled with explicit raw values on
# both sides and asserted THROUGH the door. A case reordered under implicit numbering is a cursor
# swapped for another cursor with nothing to notice it.
if ! grep -q 'case arrow = 0' Sources/SlopDeskWorkspaceCore/Terminal/PointerShapeMapping.swift; then
  fail "PointerShapeToken stopped pinning its raw values — its discriminants are the wire (docs/56, increment 50)"
fi
if ! grep -q 'the_supported_shapes_cross_as_the_discriminants_swift_is_pinned_to' \
  rust/slopdesk-ffi/src/pointer_shape.rs; then
  fail "the door's discriminant test is gone — Swift's enum and Rust's can now renumber apart"
fi
printf 'check-supervisor: one pointer table, and the raw libghostty value crosses unparsed.\n'

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

# `rust/slopdesk-cli` was written for this port and then left unlinked on a rule — "a port ships
# over a socket, never FFI" — that CLAUDE.md has since replaced with "or as a linked library, pick
# by lifetime". A CLI starts, does one thing and exits, so it is in-process by necessity: the crate
# is linked, and `SlopDeskCLICore` is the face over it.
#
# The FLAG GRAMMAR, the completion SCRIPTS, the CONFIG-file rules, the output TABLES and the version
# BANNER. Each is a place a second parser grows back one convenience at a time.
SWIFT_CLI_ARGS=Sources/SlopDeskCLICore/CLIArgs.swift
SWIFT_CLI_COMPLETIONS=Sources/SlopDeskCLICore/CLICompletions.swift
SWIFT_CLI_CONFIG=Sources/SlopDeskCLICore/CLIConfig.swift
SWIFT_CLI_FORMATTING=Sources/SlopDeskCLICore/CLIFormatting.swift
SWIFT_CLI_VERSION=Sources/SlopDeskCLICore/CLIVersion.swift
for pair in \
  "${SWIFT_CLI_ARGS}:slopdesk_cli_default_timeout_ms" \
  "${SWIFT_CLI_ARGS}:slopdesk_cli_parse" \
  "${SWIFT_CLI_COMPLETIONS}:slopdesk_cli_shell" \
  "${SWIFT_CLI_COMPLETIONS}:slopdesk_cli_subcommands" \
  "${SWIFT_CLI_COMPLETIONS}:slopdesk_cli_completion_script" \
  "${SWIFT_CLI_CONFIG}:slopdesk_cli_config_env_key" \
  "${SWIFT_CLI_CONFIG}:slopdesk_cli_config_path" \
  "${SWIFT_CLI_CONFIG}:slopdesk_cli_config_default_path" \
  "${SWIFT_CLI_CONFIG}:slopdesk_cli_config_validate" \
  "${SWIFT_CLI_FORMATTING}:slopdesk_cli_table" \
  "${SWIFT_CLI_FORMATTING}:slopdesk_cli_render_table" \
  "${SWIFT_CLI_FORMATTING}:slopdesk_cli_render_json" \
  "${SWIFT_CLI_VERSION}:slopdesk_cli_build_hash_env_key" \
  "${SWIFT_CLI_VERSION}:slopdesk_cli_version_summary"; do
  if ! grep -q "${pair#*:}(" "${pair%%:*}"; then
    fail "${pair%%:*} no longer calls ${pair#*:} — the CLI's core is rust/slopdesk-cli"
  fi
done
# The parsers and tables a re-implementation would grow back. `--config-file` is named because the
# flag STRING is the parser's, not the face's; the XDG path and the feature line because a second
# copy of either is a CLI that disagrees with the file the app actually reads.
if spells 'case "--(socket|timeout|format|no-headers|config-file)"|"-e"' "${SWIFT_CLI_ARGS}" > /dev/null; then
  fail "${SWIFT_CLI_ARGS} matches flag strings again — the grammar lives in args.rs"
fi
if spells '"(bash|zsh|fish|elvish|powershell|pwsh)"|complete -F|compdef' "${SWIFT_CLI_COMPLETIONS}" > /dev/null; then
  fail "${SWIFT_CLI_COMPLETIONS} spells a shell name or a script again — those live in completions.rs"
fi
if spells '\.config/slopdesk|config\.toml|keybind = ' "${SWIFT_CLI_CONFIG}" > /dev/null; then
  fail "${SWIFT_CLI_CONFIG} spells the XDG path or the keybind grammar again — those live in config.rs"
fi
if spells 'padding|repeating: " "|widths\[|joined\(separator: "  "\)' "${SWIFT_CLI_FORMATTING}" > /dev/null; then
  fail "${SWIFT_CLI_FORMATTING} pads a column again — the table renderer is formatting.rs"
fi
if spells 'remote-terminal|gui-video|read-only-inspector|terminal protocol v' "${SWIFT_CLI_VERSION}" > /dev/null; then
  fail "${SWIFT_CLI_VERSION} spells the banner again — its shape lives in version.rs"
fi
printf 'check-supervisor: the slopdesk CLI parses, completes, configures, tables and versions from one law.\n'

SWIFT_CLI_MAIN=Sources/slopdesk/main.swift
SWIFT_CLI_USAGE=Sources/SlopDeskCLICore/CLIUsage.swift
RUST_CLI_VOCAB=rust/slopdesk-cli/src/vocabulary.rs

# ---- 1. The face calls the door, rather than answering itself. -------------------------------
# Same shape as the five pairs above: if `CLIUsage.swift` stops calling these, it has grown its own
# help renderer or its own planned list, which is a second table by another name.
for pair in \
  "${SWIFT_CLI_USAGE}:slopdesk_cli_usage" \
  "${SWIFT_CLI_USAGE}:slopdesk_cli_planned_subcommands"; do
  if ! grep -q "${pair#*:}(" "${pair%%:*}"; then
    fail "${pair%%:*} no longer calls ${pair#*:} — the CLI's vocabulary is rust/slopdesk-cli's"
  fi
done

# ---- 2. main.swift PRINTS the crate's help; it does not write one. ---------------------------
# CATCHES: someone re-adding a `printUsage()` heredoc, which is where the help text drifted from the
# completions the first time. The section headings are the fingerprint of that block — they can only
# appear in a file that is rendering the page itself.
if ! grep -q 'CLIUsage.text(' "${SWIFT_CLI_MAIN}"; then
  fail "${SWIFT_CLI_MAIN} no longer prints CLIUsage.text — the help text lives in vocabulary.rs"
fi
# The headings are matched WITH their parentheticals, so the `// MARK: - Local subcommands` divider
# — which is a comment `spells` strips anyway — cannot be mistaken for the page itself.
if hit=$(spells 'Local subcommands \(no running app|App-driving subcommands \(require|In-pane subcommands \(run inside|^ *Global flags:' \
  "${SWIFT_CLI_MAIN}"); then
  fail "${hit} spells a help-page section again — the whole page is rendered by vocabulary.rs"
fi

# ---- 3. THE ONE THAT WOULD HAVE CAUGHT THE BUG. ----------------------------------------------
# The dispatch switch must cover exactly the verbs the shells offer — no more, no fewer.
#
# CATCHES, in both directions:
#   * a verb marked `Ready` in the table with no `case` in main.swift  ⇒ a completion that exits 2,
#     which is the reported drift;
#   * a `case` in main.swift for a verb the table calls `Planned` or does not list ⇒ a command that
#     works but that no shell will ever complete, so nobody finds it.
#
# `help` is deliberately excluded: it is handled ABOVE the switch, because `--help` has to win over
# the GUI launch, so it is matched by the `subcommand == "help"` guard instead of a `case` label.
# That guard is checked separately just below, so `help` is not silently exempt.
ready_verbs=$(
  awk '
    /^ *name: "/      { name = $0; sub(/^ *name: "/, "", name); sub(/",?$/, "", name) }
    /Availability::Ready/ { if (name != "" && name != "help") { print name; name = "" } }
    /Availability::Planned/ { name = "" }
  ' "${RUST_CLI_VOCAB}" | sort -u
)
# Only the top-level dispatch switch's labels: `case "x":` at the start of a line (column 0), which
# is what a top-level `switch` in a main.swift script file produces. Nested per-subcommand switches
# are indented, so they cannot be picked up here.
# `|| true` rather than a `-z` guard: an empty result cannot pass, because it is compared against a
# NON-empty `ready_verbs` one line down and the diff is what prints.
dispatched_verbs=$(
  grep -E '^case "' "${SWIFT_CLI_MAIN}" | sed -E 's/^case "([^"]+)":?.*/\1/' | sort -u
) || true
if [[ "${ready_verbs}" != "${dispatched_verbs}" ]]; then
  fail "$(printf '%s dispatches a different set than vocabulary.rs calls Ready:\n%s' \
    "${SWIFT_CLI_MAIN}" "$(diff <(echo "${ready_verbs}") <(echo "${dispatched_verbs}") |
      sed 's/^/    /')")"
fi
if ! grep -q 'invocation.subcommand == "help"' "${SWIFT_CLI_MAIN}"; then
  fail "${SWIFT_CLI_MAIN} no longer routes 'help' — it is Ready in vocabulary.rs and must dispatch"
fi

# ---- 4. No planned verb may be reachable by pressing Tab. ------------------------------------
# CATCHES: a `Planned` name appearing in the completions module (which would mean the module grew
# its own list again) or as a dispatch label in main.swift (which would mean it shipped without the
# table being told, so the shells still would not offer it).
planned_verbs=$(
  awk '
    /^ *name: "/ { name = $0; sub(/^ *name: "/, "", name); sub(/",?$/, "", name) }
    /Availability::Planned/ { if (name != "") { print name; name = "" } }
    /Availability::Ready/ { name = "" }
  ' "${RUST_CLI_VOCAB}" | sort -u
)
while IFS= read -r verb; do
  [[ -z "${verb}" ]] && continue
  if grep -qE "^case \"${verb}\"" "${SWIFT_CLI_MAIN}"; then
    fail "${SWIFT_CLI_MAIN} dispatches '${verb}', which vocabulary.rs still calls Planned — \
move it to Availability::Ready in the same change, or the shells will never offer it"
  fi
done <<< "${planned_verbs}"

# ---- 5. The completions module owns no list of its own. --------------------------------------
# CATCHES: the exact regression this whole change undoes — a flat `SUBCOMMANDS` array in
# completions.rs with no notion of availability, which is what let six unimplemented verbs be
# offered by all five shells.
if grep -qE 'const SUBCOMMANDS' rust/slopdesk-cli/src/completions.rs; then
  fail "rust/slopdesk-cli/src/completions.rs holds a subcommand array again — the list, its \
availability and its help text are one table in vocabulary.rs"
fi

# ---- 6. The flag help sits beside the grammar. -----------------------------------------------
# CATCHES: a help page that documents a flag the parser rejects. The flag STRINGS live in args.rs
# next to the `match` that consumes them, and a test there feeds every documented spelling back
# through `parse`. A GLOBAL_FLAGS table anywhere else is a second copy of that fact.
if ! grep -q 'GLOBAL_FLAGS' rust/slopdesk-cli/src/args.rs; then
  fail "rust/slopdesk-cli/src/args.rs no longer carries GLOBAL_FLAGS — the flag help must sit \
beside the grammar it describes"
fi
if grep -qE '"--no-headers"|"--config-file"|"--socket PATH"' "${SWIFT_CLI_MAIN}"; then
  fail "${SWIFT_CLI_MAIN} spells a global flag again — the grammar and its help are args.rs's"
fi

# ---- 7. The ui-shell docs' CLI claims are a claim WITH a gate behind it. ----------------------
#
# WHAT THIS PINS. `docs/ui-shell/BACKLOG.md` and `docs/ui-shell/USER-STORIES.md` each carry an
# `## E20 — CLI parity + watch + first-launch` section that names the shipped CLI surface in prose:
# which verbs there are, which of them run, which flags they take, and what `watch:claude` exits
# with. Those four things are all written down for real in `rust/slopdesk-cli/src/vocabulary.rs`
# (`SUBCOMMANDS`, each `Subcommand`'s `availability`, each `Form`'s `invocation`), in
# `rust/slopdesk-cli/src/args.rs` (`GLOBAL_FLAGS`) and in `rust/slopdesk-agent/src/watch.rs`
# (`WatchExit`). This section compares the prose against those, both ways.
#
# THE FAILURE MODE. docs/55 §8's closing lesson, verbatim: "A row in this table is a claim with no
# gate behind it … and it decayed the same way: the port moved and the row did not." These two
# sections had decayed exactly that way, and the decay was found by reading, not by any gate:
#
#   * `ES-E20-1` and BACKLOG's Scope line both named a `theme` verb. There is none — `theme` is a
#     PreferencesStore key reached by `config set`, and `slopdesk theme list` (which
#     `spec/reference__cli.md` §Behaviors still specifies) exits 2 as an UNKNOWN subcommand. That is
#     a sharper hole than a stale doc: every other unbuilt reference verb is carried as
#     `Availability::Planned` so a user is told it is coming, and this one alone is told it is a typo.
#   * `ES-E20-1` claimed `open` drives the running app. `open` is `Planned` and exits 2.
#   * BACKLOG's Scope line ended "`state:`/`ipc` (done)". Neither has ever dispatched; both are
#     `Planned`. A doc that says "done" about a verb that exits 2 is worse than one that says nothing.
#
# WHY NO TEST CAN SEE IT. There is nothing to compile and nothing to run: a markdown sentence is not
# reachable from any target, so no suite in either language can be made to fail on it. `make lint`
# already refuses to let the CLI's own four spellings drift (sections 1–6 above); the doc is the
# fifth spelling, and it was the only one nothing read.
#
# WHAT IS DELIBERATELY *NOT* COVERED, so the next reader does not mistake a partial gate for a
# total one:
#
#   * `docs/ui-shell/spec/` is NOT read. Those pages are the design TARGET — `reference__cli.md`
#     specifies `theme list`, `theme import`, `--color`, `--activate` and more that were never
#     built, on purpose. Gating the spec against the code would demand the spec be rewritten every
#     time a feature is deferred, which is the opposite of what a spec is for. `COVERAGE.md` is the
#     shipped-vs-not ledger, and §C/§D/§E of it are the deferral record.
#   * `COVERAGE.md`'s own prose is only spot-checked (rule 8). Its CLI claims are §D/§E rows in
#     English — "deferred in source", "INTENTIONALLY NOT BUILT" — and the checkable part of each is
#     just "this verb had better not be Ready", which is what rule 8 asserts. The *reasons* are not
#     mechanically checkable and are not claimed to be.
#   * BEHAVIOUR is not covered, and this is the same limit docs/55 §8 names for the whole of
#     `check-supervisor.sh`: that `pane capture` "captures the last N lines", that `watch` "shows a
#     spinner", that `--json` "produces structured output". This gate compares NAMES and NUMBERS. A
#     verb that exists, dispatches, is spelled right in the docs and does the wrong thing passes here
#     exactly as it does everywhere else in this file.
#   * The two sections' non-CLI prose (epic ordering, estimates, first-launch stories) is untouched.
#   * A malformed verb with a dangling family colon — the literal `state:` the BACKLOG line used to
#     write — is dropped by the tokeniser rather than reported, because it matches no verb SHAPE.
#     7a sees words, not near-misses.
#
# BREAK-TESTED 2026-08-22, every file copied to /tmp first and restored from there, `git checkout`
# never used, and the whole tree verified byte-identical afterwards. Each break failed the rule
# named; undoing each one passed:
#   1. the original prose in BOTH docs (`open/view/edit`, `font/theme/keybind list`) — 4 failures:
#      7a "names CLI words vocabulary.rs does not know: theme" ×2, 7b "presents Planned verbs as
#      working: open" ×2.
#   2. restoring BACKLOG's "`state:claude`/`ipc` (done)" — 7b, "ipc / state:claude".
#   3. adding `sidecars` to the ES-E20-5 unbuilt list — 7c, "files verbs under NOT YET IMPLEMENTED
#      that dispatch today: sidecars".
#   4. writing `--colour` beside `--json` — 7d, "names flags the CLI does not parse: --colour".
#   5. `exit codes 0/4/9` → `0/4/8` — 7e, "quotes watch:claude exit codes 0/4/8; WatchExit is 0/4/9".
#   6. renaming the `## E20 —` heading — the corpus guard, "has no '## E20 …' section — rules 7a–7d
#      below read an empty corpus and pass".
#   7. `ipc` promoted to `Availability::Ready` — 3 failures: 7c in both docs and rule 8's ledger row.
#   8. `watch:claude` renamed `watch:codex` — rule 8's Claude-only ban.
#   9. deleting COVERAGE §D's `ipc`/`state:<agent>` row — rule 8's "the row this gate reads is gone",
#      twice.
#  10. `name:` → `nom:` in vocabulary.rs — the availability floor.
#  11. widening the spaces around `WatchExit`'s `=` — the `watch.rs` floor, "compares nothing".
#  12. breaking `name:` AND `invocation:` together — the `vocab_words` floor ("read fewer than 20
#      vocabulary words"), which is the one that matters most: without it 7a's allowlist empties and
#      every correct token in both docs reads as a finding.
#
UI_SHELL_BACKLOG=docs/ui-shell/BACKLOG.md
UI_SHELL_STORIES=docs/ui-shell/USER-STORIES.md
UI_SHELL_COVERAGE=docs/ui-shell/COVERAGE.md
# The one heading both files spell, and the marker a line must carry to name an unbuilt verb.
E20_HEADING='## E20 — CLI parity + watch + first-launch'
E20_UNBUILT='NOT YET IMPLEMENTED'
# The markdown code fence, bound as a byte rather than typed. ShellCheck reads a literal backtick
# inside a single-quoted `grep` pattern as a command substitution (SC2016, info — which `enable=all`
# makes fatal here), and the escape has to appear somewhere; `$'\x60'` puts it in one place, named,
# instead of in four patterns that then all need a suppression comment.
TICK=$'\x60'

# The E20 section of one doc: from the heading to the next `## `, heading included.
e20_section() {
  awk -v want="${E20_HEADING}" '
    $0 == want { on = 1; next }
    on && /^## / { exit }
    on { print }
  ' "$1"
}

# Every CLI-shaped token inside a backtick span. Spans holding a `.` are dropped whole — those are
# file paths (`spec/reference__cli.md`, `vocabulary.rs`), never invocations — and so is the program's
# own name in either spelling. Metavariables are stripped, then `/`, `|` and `,` are separators,
# because that is how both docs write an alternation (`config get/set/reload`, `tab/pane/window`).
# What survives is a lowercase word, optionally with one `:family` suffix: `pane`, `send-keys`,
# `watch:claude`.
cli_tokens() {
  grep -o "${TICK}[^${TICK}]*${TICK}" |
    tr -d "${TICK}" |
    grep -v '\.' |
    sed -E 's/<[^>]*>//g' |
    tr '/|,' '   ' |
    tr -s ' ' '\n' |
    grep -vxE 'slopdesk|slopdesk-.*' |
    grep -xE '[a-z][a-z0-9-]*(:[a-z0-9]+)?' |
    sort -u
}

# The vocabulary's own words, which is what a token is allowed to be: every `Subcommand.name`, plus
# every word of every `Form.invocation` — the second half is what makes `config get`, `pane capture`
# and `font apply` legal without any list in this gate.
vocab_words=$(
  {
    sed -nE 's/^ *name: "([^"]+)",?$/\1/p' "${RUST_CLI_VOCAB}"
    sed -nE 's/^ *invocation: "([^"]*)".*$/\1/p' "${RUST_CLI_VOCAB}"
  } | sed -E 's/<[^>]*>//g' | tr '/|,' '   ' | tr -s ' ' '\n' | grep -xE '[a-z][a-z0-9-]*(:[a-z0-9]+)?' | sort -u
) || true
# A GATE WHOSE HAYSTACK IS EMPTY PASSES EVERY BAN AT ONCE. `vocab_words` is the allowlist rule 7a
# compares against, so an empty one would make every token in both docs a finding; the two `sed`
# extractions are exactly the kind that go quiet when `vocabulary.rs` is reformatted.
if [[ $(printf '%s\n' "${vocab_words}" | grep -c .) -lt 20 ]]; then
  fail "${RUST_CLI_VOCAB}: read fewer than 20 vocabulary words — the extraction in this gate has \
gone stale, so rule 7a is comparing the ui-shell docs against nothing"
fi

ready_names=$(
  awk '
    /^ *name: "/            { name = $0; sub(/^ *name: "/, "", name); sub(/",?$/, "", name) }
    /Availability::Ready/   { if (name != "") { print name; name = "" } }
    /Availability::Planned/ { name = "" }
  ' "${RUST_CLI_VOCAB}" | sort -u
) || true
planned_names=$(
  awk '
    /^ *name: "/            { name = $0; sub(/^ *name: "/, "", name); sub(/",?$/, "", name) }
    /Availability::Planned/ { if (name != "") { print name; name = "" } }
    /Availability::Ready/   { name = "" }
  ' "${RUST_CLI_VOCAB}" | sort -u
) || true
if [[ -z "${ready_names}" || -z "${planned_names}" ]]; then
  fail "${RUST_CLI_VOCAB}: one availability list read as EMPTY — rules 7b/7c and 8 would pass by \
having nothing to check"
fi

for doc in "${UI_SHELL_BACKLOG}" "${UI_SHELL_STORIES}"; do
  section=$(e20_section "${doc}") || true
  # Named, not assumed: the heading is a literal in two files this gate does not own, and a doc that
  # renames or drops it would empty the corpus and pass all four rules below in silence.
  if [[ -z "${section}" ]]; then
    fail "${doc} has no '${E20_HEADING}' section — rules 7a–7d below read an empty corpus and pass"
    continue
  fi

  # ---- 7a. A verb the docs name is a verb the vocabulary knows. ------------------------------
  # CATCHES the `theme` bug: a doc naming a subcommand that is not in `SUBCOMMANDS` under either
  # availability, so it is not merely unbuilt — a user who types it is told it is a typo.
  tokens=$(printf '%s\n' "${section}" | cli_tokens) || true
  unknown=$(comm -23 <(printf '%s\n' "${tokens}") <(printf '%s\n' "${vocab_words}")) || true
  if [[ -n "${unknown}" ]]; then
    fail "$(printf '%s §E20 names CLI words %s does not know:\n%s' \
      "${doc}" "${RUST_CLI_VOCAB}" "$(printf '%s\n' "${unknown}" | sed 's/^/    /')")"
  fi

  # ---- 7b/7c. A verb is named on the side of the line that matches its availability. ---------
  # Per LINE and per TOKEN, not per backtick span, and that is the whole difference between this
  # rule working and not: both docs write an alternation inside ONE span — `open/view/edit`,
  # `jump/learn/ignore` — so a `grep -F '`open`'` finds nothing in the very sentence that made the
  # false claim. The tokeniser above already splits a span; this reuses it a line at a time.
  #
  # 7b CATCHES the `open` and the "`state:`/`ipc` (done)" bugs: a verb the docs present as working
  # while `vocabulary.rs` still calls it Planned, which is a promise the dispatcher answers with
  # exit 2. 7c is the direction that goes stale on the day a verb SHIPS: a `Planned` entry promoted
  # to `Ready` leaves a doc line still filing it under "not yet". The marker is one literal,
  # `NOT YET IMPLEMENTED`, so a doc cannot half-say it.
  # THE TWO HALVES TAKE DIFFERENT UNITS, and the asymmetry is the rule, not a concession.
  #
  # 7b asks "is the reader WARNED?" — so the unit is the BULLET. Both docs wrap a story entry across
  # several lines and the marker can only be written once; judging line-by-line failed seven times on
  # one honest entry (ES-E20-6), whose continuation lines each name `theme`/`import` while the marker
  # sits on a line above them. That is not a doc presenting a Planned verb as working, it is a doc
  # explaining that the verb is Planned, wrapped at 110 columns. A warning anywhere in the entry that
  # names the verb IS a warning to the reader who reads the entry.
  #
  # 7c asks "is a SHIPPED verb wrongly filed as unbuilt?" — so the unit stays the LINE. Widening it to
  # the bullet would break it: a legitimate entry that says "X is not implemented, but Y ships" puts
  # the marker and the shipped verb in one bullet, and every such entry would fail. The filing is done
  # by the line that does it.
  #
  # A bullet starts at `- ` in column 1; anything else continues the one above.
  section_bullets=$(printf '%s\n' "${section}" | awk '
    /^- / { if (buf != "") print buf; buf = $0; next }
    { if (buf == "") buf = $0; else buf = buf " " $0 }
    END { if (buf != "") print buf }
  ')
  # 7c — per LINE.
  while IFS= read -r line; do
    [[ "${line}" == *"${E20_UNBUILT}"* ]] || continue
    line_tokens=$(printf '%s\n' "${line}" | cli_tokens) || true
    [[ -z "${line_tokens}" ]] && continue
    shipped=$(comm -12 <(printf '%s\n' "${line_tokens}") <(printf '%s\n' "${ready_names}")) || true
    if [[ -n "${shipped}" ]]; then
      fail "$(printf '%s §E20 files verbs under %s that dispatch today:\n%s\n  on: %s' \
        "${doc}" "${E20_UNBUILT}" "$(printf '%s\n' "${shipped}" | sed 's/^/    /')" \
        "$(printf '%.120s' "${line}")")"
    fi
  done <<< "${section}"
  # 7b — per BULLET.
  while IFS= read -r bullet; do
    [[ "${bullet}" == *"${E20_UNBUILT}"* ]] && continue
    bullet_tokens=$(printf '%s\n' "${bullet}" | cli_tokens) || true
    [[ -z "${bullet_tokens}" ]] && continue
    promised=$(comm -12 <(printf '%s\n' "${bullet_tokens}") <(printf '%s\n' "${planned_names}")) || true
    if [[ -n "${promised}" ]]; then
      fail "$(printf '%s §E20 presents Planned verbs as working (no "%s" in the entry):\n%s\n  on: %s' \
        "${doc}" "${E20_UNBUILT}" "$(printf '%s\n' "${promised}" | sed 's/^/    /')" \
        "$(printf '%.120s' "${bullet}")")"
    fi
  done <<< "${section_bullets}"

  # ---- 7d. A flag the docs name is a flag the CLI parses. ------------------------------------
  # CATCHES a doc promising `--colour` or a renamed `--kind`. The universe is `GLOBAL_FLAGS`'
  # spellings (which `args.rs`'s own test feeds back through `parse`) plus every flag spelled in a
  # `Form.invocation`; a bare `--` end-of-options marker is not a flag and is skipped.
  doc_flags=$(printf '%s\n' "${section}" | grep -o "${TICK}[^${TICK}]*${TICK}" | tr -d "${TICK}" |
    grep -oE '\-\-[a-z][a-z-]*' | sort -u) || true
  cli_flags=$(
    {
      grep -oE '"--[a-z][a-z-]*"' rust/slopdesk-cli/src/args.rs | tr -d '"'
      sed -nE 's/^ *invocation: "([^"]*)".*$/\1/p' "${RUST_CLI_VOCAB}" | grep -oE '\-\-[a-z][a-z-]*'
    } | sort -u
  ) || true
  if [[ -z "${cli_flags}" ]]; then
    fail "no flag spellings read from rust/slopdesk-cli — rule 7d compares ${doc} against nothing"
  elif [[ -n "${doc_flags}" ]]; then
    stray=$(comm -23 <(printf '%s\n' "${doc_flags}") <(printf '%s\n' "${cli_flags}")) || true
    if [[ -n "${stray}" ]]; then
      fail "$(printf '%s §E20 names flags the CLI does not parse:\n%s' \
        "${doc}" "$(printf '%s\n' "${stray}" | sed 's/^/    /')")"
    fi
  fi

  # ---- 7e. The exit codes the docs quote are the ones the state machine produces. ------------
  # `watch:claude` is the only verb in the tree with a documented exit-code contract, both docs
  # quote it as `0/4/9`, and `WatchExit` is where those three numbers actually live. A renumbering
  # is invisible to every caller — a script that tests `$? == 4` simply stops branching.
  doc_codes=$(printf '%s\n' "${section}" | grep -oE 'exit(-| )codes? [0-9](/[0-9])+|exit [0-9](/[0-9])+' |
    grep -oE '[0-9](/[0-9])+' | tr '/' '\n' | sort -u | paste -sd/ -) || true
  rust_codes=$(sed -nE 's/^ *[A-Z][A-Za-z]* = ([0-9]+),$/\1/p' rust/slopdesk-agent/src/watch.rs |
    sort -u | paste -sd/ -) || true
  if [[ -z "${rust_codes}" ]]; then
    fail "rust/slopdesk-agent/src/watch.rs: no WatchExit discriminants read — rule 7e compares nothing"
  elif [[ -n "${doc_codes}" && "${doc_codes}" != "${rust_codes}" ]]; then
    fail "${doc} §E20 quotes watch:claude exit codes ${doc_codes}; WatchExit is ${rust_codes}"
  fi
done

# ---- 8. COVERAGE.md's non-build rows may not name a verb that ships. --------------------------
# `COVERAGE.md` §D files `ipc` and `state:<agent>` as "deferred in source"; §E files `slopdesk
# import`/`export` under "INTENTIONALLY NOT BUILT — do NOT implement". Both are the deferral record
# the rest of the repo reads before deciding something is a gap, so the day one of them ships they
# stop being a record and become an instruction to un-build it.
#
# Only the checkable half is asserted — "not Ready" — for the reason given in the scope note above.
# `state:claude` is spelled here rather than §D's `state:<agent>`: the vocabulary is Claude-only by
# design (its module doc, and a test in the crate, hold `codex` and `opencode` out), and the last
# ban re-states that from this side so a doc that is right today cannot be made wrong by a verb.
for deferred in ipc import export state:claude; do
  if printf '%s\n' "${ready_names}" | grep -qxF "${deferred}"; then
    fail "${UI_SHELL_COVERAGE} files '${deferred}' as deferred/not-built, but ${RUST_CLI_VOCAB} \
now calls it Ready — the coverage ledger is what a future session reads before deciding it is a gap"
  fi
  if ! grep -qF "${deferred%%:*}" "${UI_SHELL_COVERAGE}"; then
    fail "${UI_SHELL_COVERAGE} no longer mentions '${deferred%%:*}' — the row this gate reads is gone"
  fi
done
if printf '%s\n' "${ready_names}" "${planned_names}" | grep -qE 'codex|opencode'; then
  fail "${RUST_CLI_VOCAB} grew a codex/opencode verb — ${UI_SHELL_COVERAGE} §D scopes agents to \
Claude Code, and a per-agent verb is the one thing that would silently make that row false"
fi

printf 'check-supervisor: the slopdesk CLI offers exactly the verbs it can run.\n'
printf 'check-supervisor: the ui-shell docs describe the CLI the crate actually ships.\n'

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
# a log that passed. That is not hypothetical: it was fixed once in `compare_abi_enum`, re-entered,
# and then found in twenty-three more assignments in this file alone, five of which sat directly
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

# The token bans live in Python, and this is where their status joins the count. Each of them is
# "this spelling must not appear in code", which in shell is a `grep` — and three separate silent
# failures came out of writing them that way: a pipeline that hides its status, a pattern that
# matched the gate's own failure message, and a comment-stripper that eats a URL. See the module
# docstring in `scripts/check-invariants.py`.
#
# It has been running since the top of this file (see the note there). `wait` on a KNOWN pid yields
# that job's exit status, which is the whole reason the pid was kept — a bare `wait` yields zero
# however the job died, and this gate would then pass on a broken invariant.
wait "${INVARIANTS_PID}" && invariants_status=0 || invariants_status=$?
cat "${INVARIANTS_LOG}"
[[ ${invariants_status} -eq 0 ]] ||
  fail "scripts/check-invariants.py reported a broken invariant — its own output names which"

if [[ "${failures}" -ne 0 ]]; then
  printf 'check-supervisor: %d contract violation(s)\n' "${failures}" >&2
  exit 1
fi

# screend's whole share of this file is now `rust/slopdesk-invariants` — the address and the verbs
# first, then the banner, the status alphabet, the reset flags, the frame ceiling and the four
# absences. Nothing is left here to announce.
printf 'check-supervisor: dropd agrees too — version %s, types (%s→ %s), %s-byte frames, 8 door entries, announce line, no Swift receiver or codec.\n' \
  "${drop_version}" \
  "$(printf '%s\n' "${client_request_types}" | tr '\n' ' ' | sed 's/ $//')" \
  "$(printf '%s\n' "${client_reply_types}" | tr '\n' ' ' | sed 's/ $//')" \
  "${frame_cap}"

printf 'check-supervisor: androidd agrees too — ops (%s), %s device fields, announce line, no Swift bridge.\n' \
  "$(printf '%s\n' "${swift_android_ops}" | tr '\n' ' ' | sed 's/ $//')" \
  "$(printf '%s\n' "${swift_android_fields}" | grep -c .)"

printf 'check-supervisor: inspectord agrees too — tags (1 event, 2 keep-alive, 3 subscribe), 16 MiB frames, 8 door entries, announce line, no Swift producer or frame.\n'

printf 'check-supervisor: slopdesk-ctl agrees too — %s verbs both ways, no Swift CLI.\n' \
  "$(printf '%s\n' "${swift_ctl_verbs}" | grep -c .)"

printf 'check-supervisor: slopdesk-codeseed agrees too — %s subcommands both ways, no Swift seeder or resource bundle.\n' \
  "$(printf '%s\n' "${swift_codeseed_verbs}" | grep -c .)"

printf 'check-supervisor: slopdesk-agenthooks agrees too — %s subcommands both ways, marker == installed basename, relay still dependency-free.\n' \
  "$(printf '%s\n' "${swift_agenthooks_verbs}" | grep -c .)"

# THE OPAQUE CAP IS ONE NUMBER IN TWO PROGRAMS, AND IT CARRIES AN INEQUALITY (docs/55 §8).
# `MetadataResponseBuilder.defaultMaxOpaquePayloadBytes` is the cap; `slopdesk-probe`'s
# `MAX_OPAQUE_READ_BYTES` mirrors it so the probe reads at most `cap + 1` bytes, which is what lets
# `cappedOpaque()` see `count > max`, trim, and set its "was truncated" flag. Lower the Rust number
# alone and the builder never sees an over-long payload, so it never trims and never flags — the
# client renders a SILENTLY SHORT `git diff` as if it were the whole thing. Raise it alone and a
# pathological diff spikes per-request memory before any cap applies.
#
# A door is the wrong instrument here and that is worth saying: hostd FORKS the probe, so this
# crosses a process boundary, not the FFI. `docs/DECISIONS.md` recorded the arrangement as
# Swift-only, before the probe was Rust — the record went stale rather than the design going wrong.
# The rule these two must satisfy is `rust >= swift`, so the gate checks the relation, not equality.
#
# There used to be a THIRD spelling, `HostMetadataProbe.maxCaptureBytes`, deliberately not in this
# gate: the stop condition on hostd's own `lsof` drain, the same number asking a different question.
# It is gone — the pane census is `rust/slopdesk-panecensus` and its port scan rides
# `slopdesk_probe::run::capture`, so the drain that had its own ceiling now shares the one below.
probe_cap_rust=$(grep -oE 'MAX_OPAQUE_READ_BYTES: usize = [0-9 *]+;' rust/slopdesk-probe/src/run.rs |
  grep -oE '[0-9]+ \* [0-9]+ \* [0-9]+' || true)
probe_cap_swift=$(grep -oE 'defaultMaxOpaquePayloadBytes = [0-9 *]+' \
  Sources/SlopDeskHost/MetadataResponseBuilder.swift | grep -oE '[0-9]+ \* [0-9]+ \* [0-9]+' || true)
if [[ -z "${probe_cap_rust}" || -z "${probe_cap_swift}" ]]; then
  fail "the opaque cap could not be read from both sides (rust='${probe_cap_rust}' swift='${probe_cap_swift}') — this gate stopped checking anything (docs/55 §8)"
fi
if [[ "$((probe_cap_rust))" -lt "$((probe_cap_swift))" ]]; then
  fail "slopdesk-probe reads ${probe_cap_rust} but MetadataResponseBuilder caps at ${probe_cap_swift} — the probe must read at least the cap, or the truncation flag never fires (docs/55 §8)"
fi

printf 'check-supervisor: slopdesk-probe agrees too — %s subcommands both ways, empty is still an answer, opaque cap %s >= %s, no Swift porcelain, git or infocmp.\n' \
  "$(printf '%s\n' "${swift_probe_verbs}" | grep -c .)" "$((probe_cap_rust))" "$((probe_cap_swift))"

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

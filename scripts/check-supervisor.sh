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
RUST_FRAME="rust/slopdesk-superd/src/frame.rs"
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



# ── A FRAMEWORKLESS VALUE GOES TO THE FLOOR, NOT INTO A PAIR (docs/56 stage F, P6) ───────────────
# The ACCENT RING's alpha is spelled three times across TWO renderers: `ViModeOverlay` and
# `TerminalFindBar` in SwiftUI, and `MacGlobalSearch` in AppKit — the last drawing the ON chip of the
# very pill whose header pins that the find bar and the global-search bar render identically. The ink
# of that pair needs a gate because a `Color` table cannot descend below `SlopDeskSlate`. An ALPHA
# can: it is a `Double` with no framework in it, so it went to the floor and all three read one token.
# That is the general finding — before pinning a pair, ask whether the value has a colour in it.
SLATE_DESIGN=Sources/SlopDeskSlate/SlateDesign.swift
for token in 'accentRing' 'glyphPlate'; do
  if ! grep -qE "static let ${token}\b" "${SLATE_DESIGN}"; then
    fail "\`Slate\` stopped minting \`${token}\` — its readers span two renderers and the literal cannot be compared across them (docs/56 stage F, P6)"
  fi
done
for site in Sources/SlopDeskPhoneUI/Pane/ViModeOverlay.swift \
  Sources/SlopDeskPhoneUI/Pane/TerminalFindBar.swift \
  Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift; do
  if ! grep -qF 'Slate.Opacity.accentRing' "${site}"; then
    fail "${site} stopped reading \`Slate.Opacity.accentRing\` — the third spelling is the one that shipped drifted (docs/56 stage F, P6)"
  fi
done
# The literal, banned only where the ring is drawn. NOT repo-wide: a SECOND `0.5` family — the
# locked/disabled dim in `FontSettingsView`, `GuiLeafView` and `MacFontFamilySurface.lockedAlpha` —
# is deliberately un-minted, and a blanket ban would be red for values that are right.
ring_respelled=$(spells '\.opacity\(0\.5\)|withAlphaComponent\(0\.5\)' \
  Sources/SlopDeskPhoneUI/Pane/ViModeOverlay.swift \
  Sources/SlopDeskPhoneUI/Pane/TerminalFindBar.swift \
  Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift 2> /dev/null || true)
if [[ -n "${ring_respelled}" ]]; then
  printf '%s\n' "${ring_respelled}" >&2
  fail "the accent ring's alpha is a literal again in a file that reads the token beside it (docs/56 stage F, P6)"
fi
# THE GRAB PILL, WHOSE DRAWINGS ARE COMPARED INSIDE ONE GESTURE — merging a satellite home means
# grabbing the pill in the detached window, crossing, and releasing on the leaf whose own pill is the
# target. A 44 that became a 42 does not read as two files disagreeing; it reads as the thing in the
# user's hand changing size.
#
# FOUR DRAWINGS NOW, not two, and the row that moved is the point: this list was written when the
# satellite's pill was SwiftUI in `SatellitePaneContent.swift`, with the note "wave R adds a third
# drawing, which is why this is pinned before it". R11 landed the Mac halves of BOTH — the canvas
# handle and the satellite strip — and deleted the SwiftUI satellite, so the Mac path replaces its row
# rather than joining beside it. The two SwiftUI rows that remain are the phone's.
for drawing in Sources/SlopDeskPhoneUI/Pane/PaneMoveAffordance.swift \
  Sources/SlopDeskMacUI/Pane/MacPaneMoveAffordance.swift \
  Sources/SlopDeskMacUI/Pane/MacSatellitePaneContent.swift; do
  if ! grep -qF 'Slate.GrabPill' "${drawing}"; then
    fail "${drawing} draws the grab pill from its own numbers again — the two pills are compared across a SINGLE drag (docs/56 stage F, P6)"
  fi
done
printf 'check-supervisor: the pill and the ring are the floor'"'"'s — a frameworkless value descends, it does not pair.\n'
# AND THE MAC INJECTS NO ENVIRONMENT IT DOES NOT READ (docs/56 §3.5, increment 56f). `SlopDeskMacApp`
# handed its scene root three of the draining target's environment keys — `\.preferencesStore`,
# `\.agentHooksController`, `\.overlayCoordinator` — and re-applied all three to every satellite root
# against the hosting-root env trap. Every reader of all three is a PHONE view. Each has an AppKit twin
# the Mac mounts instead, and each twin takes its dependency as an INIT PARAMETER.
#
# A dead injection is worse than dead code, which is why this is a gate and not a cleanup. It costs
# nothing at runtime, cannot fail a test, and survives every rewrite that deletes its last reader — so
# it accumulates, and it reads to the next person as evidence that a subtree still resolves keys it
# stopped resolving three increments ago. That is exactly how the stale import in 56a survived.
#
# `\.overlayCoordinator` on the SATELLITE root is the one live application, and increment 57a moved it
# to the other side of the seam rather than deleting it: a satellite mounts `PaneContainer`, which reads
# the key, and an `NSHostingView` root inherits nothing — but BOTH the key and its reader are declared
# in the phone half, so the injection was making `SlopDeskMacUI` import that whole target purely to
# spell one modifier. `SatellitePaneHost.contentView` applies it now and takes the coordinator as a
# plain `SlopDeskClientCore` value. It dies with increment 62, when the satellite's content is AppKit.
MAC_APP=Sources/SlopDeskMacUI/SlopDeskMacApp.swift
# NOT anchored to the start of a line, deliberately: `.a().b()` chained on one line is the same
# injection and the obvious way to reintroduce it. The `(` is what keeps this off the `\.key`
# spelling every doc comment in this section uses.
#
# `overlayCoordinator` JOINED the ban list in 57a. It is not banned because nobody reads it — the
# satellite's subtree does — but because naming it HERE is what the import was for.
for key in preferencesStore agentHooksController overlayCoordinator; do
  if sed -E 's#^[[:space:]]*//.*##' "${MAC_APP}" | grep -qE "\.${key}\("; then
    grep -nE "\.${key}\(" "${MAC_APP}" >&2
    fail "${MAC_APP} injects \\.${key} again — the scene is off the draining floor (docs/56 §3.5)"
  fi
done
# AND WITH THE LAST SYMBOL GONE, SO IS THE IMPORT. This is the ledger assertion for the third of the
# three files: `SlopDeskClientUI` could not be renamed `SlopDeskPhoneUI` while a `SlopDeskMacUI` file
# imported it, so an import this stage retired stays retired — the rename has been spent, and getting
# it back would cost the fold. Re-adding one is a single green line.
if grep -qE '^import SlopDeskPhoneUI' "${MAC_APP}"; then
  grep -nE '^import SlopDeskPhoneUI' "${MAC_APP}" >&2
  fail "${MAC_APP} imports the draining floor again — its last symbol left in 57a (docs/56 §3.5)"
fi
# AND THE SATELLITE'S SEAM IS GONE, which is the outcome the paragraph above predicted: the sentence
# "it dies with increment 62, when the satellite's content is AppKit" was written when the count-of-one
# gate below it was the live assertion. R11 landed that content, so `SatellitePaneContent.swift` — the
# `SatellitePaneHost.contentView` seam AND the `SatellitePaneRootView` it hosted — was deleted rather
# than left mounted by nothing.
#
# The assertion INVERTS rather than retiring, for the `staticMirror` reason: a seam whose whole job was
# to carry a SwiftUI view across a target boundary is exactly the thing a later agent re-creates while
# porting something adjacent, and it would compile. There is no environment left for it to inject into
# — the satellite's content is an `NSView` the window target constructs directly — so the file coming
# back means the split un-happened for one window class and nothing else would say so.
SATELLITE_HOST=Sources/SlopDeskPhoneUI/Pane/SatellitePaneContent.swift
if [[ -e "${SATELLITE_HOST}" ]]; then
  fail "${SATELLITE_HOST} is back — the satellite's content is AppKit, so its hosting seam has no job (docs/56 §3.5)"
fi
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
if spells 'SatellitePaneHost' $(repo_files 'Sources/**/*.swift') > /dev/null 2>&1; then
  fail "SatellitePaneHost is named again — the seam it spelled was deleted with R11 (docs/56 §3.5)"
fi
printf 'check-supervisor: the Mac injects no environment at all — and the satellite seam it was for is gone.\n'

# ── THE FOLD'S GATE CONDITION, ASSERTED WHOLE (docs/56, increments 61 and 63) ───────────────────
# `SlopDeskClientUI` could not be renamed `SlopDeskPhoneUI` while ANY `SlopDeskMacUI` file imported
# it. That was a count for eleven increments — 13 files, then 2, then 0 — and each step got its own
# per-file gate above (`MAC_WINDOW_ROOT`, `MAC_APP`), because naming the file was the only way to say
# anything true while others still legitimately imported it.
#
# ⚠️ THE CONDITION HAS BEEN MET AND SPENT (increment 63): the rename happened, and this is now what
# keeps it. Read it in the present tense — the two halves do not import each other — rather than as a
# countdown to something still ahead.
#
# At zero the per-file form stops being the assertion. A gate that names three files is silent about
# the fourth, and the fourth is exactly what a later agent adds: reaching for one `some View` from a
# new AppKit surface is a one-line import that compiles, passes every test, and puts the fold back
# behind a port. So the census is the TARGET, not a list — the three above stay for the history in
# their comments, and this is the one that cannot be out of date.
#
# It reads the RAW import lines rather than `spells`: an import is never inside a doc comment, and the
# ban has to survive a file whose header legitimately discusses the draining floor by name (several
# do, including `MacContentColumn`'s account of what it stopped hosting).
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
mac_floor_imports=$(grep -lE '^import SlopDeskPhoneUI' $(repo_files 'Sources/SlopDeskMacUI/**/*.swift') \
  2> /dev/null | sort || true)
if [[ -n "${mac_floor_imports}" ]]; then
  printf '%s\n' "${mac_floor_imports}" >&2
  fail "a SlopDeskMacUI file imports the draining floor — the fold's gate condition was met in increment 61 and this un-meets it (docs/56)"
fi
# AND THE EDGE IS CUT IN THE MANIFEST, which is the half an import census cannot assert. A dependency
# the graph still contains is an import one keystroke away and a build that will not complain; a
# dependency it does not contain is a compile error at the first `import`. Both halves are gates
# because they fail at different moments — the manifest one is what makes re-adding the import a
# BUILD failure rather than a lint failure, and this one is what says why when it happens.
#
# Read from the `SlopDeskMacUI` target's own `dependencies:` block, so a mention of the phone half
# anywhere else in the manifest (a dozen comments make one) cannot answer for this one.
#
# ⚠️ BOTH MANIFEST READERS ANCHOR ON THE `.target(` LINE, NOT ON THE NAME. Written in increment 61
# they keyed on `name: "SlopDeskMacUI"` alone — which ALSO matches the `.library(name: "SlopDeskMacUI",
# …)` PRODUCT line four hundred lines up, so each read a second, spurious region beginning in the
# products list and running to the first `.target(`. They passed for two increments because nothing
# incriminating happened to sit in that gap, and increment 63 put `.library(name: "SlopDeskPhoneUI",
# …)` in exactly it. A gate that reads the wrong region and agrees anyway is the ledger defect again:
# right answer, no reason — and the day the answer changes it is the region, not the rule, that spoke.
mac_target_block=$(awk '
  /^ *\.(test)?[Tt]arget\(/ { pending = 1; inside = 0; next }
  pending { pending = 0; if ($0 ~ /name: "SlopDeskMacUI",/) inside = 1 }
  inside { print }
' Package.swift)
if printf '%s' "${mac_target_block}" | sed -E 's#^[[:space:]]*//.*##' | grep -q 'SlopDeskPhoneUI'; then
  printf '%s\n' "${mac_target_block}" | grep -n 'SlopDeskPhoneUI' >&2
  fail "the SlopDeskMacUI target depends on the phone half again — increment 61 cut that edge in Package.swift, not only in the imports (docs/56)"
fi
printf 'check-supervisor: no Mac file imports the phone half, and the manifest edge is cut too.\n'

# ── ONE TEST-LINT RELAXATION, TWO TEST TREES (docs/56 F4c) ──────────────────────────────────────
# `Tests/.swiftlint.yml` turns off the nine rules that are idiomatic in a test and noise everywhere
# else (force-unwrap a known-good fixture, `var sut: Foo!` in `setUp`, the assertion-style rules).
# Increment 63 gave the repo a SECOND test tree — `Apps/ClientApp-iOS/Tests`, the iOS-triple bundle
# that is now the only place a `SlopDeskPhoneUI` view suite can compile — and it needs the same nine.
#
# It gets them by SYMLINK, not by copy. A copy is two lists that drift, and the failure is silent in
# the worst direction: one test tree quietly enforcing different rules than the other, discovered
# whenever someone edits one list and not the other. This is the same defect as a gate that names its
# symbols, one layer down, so it is pinned the same way — as a FACT (is it a link?) rather than as a
# comparison anybody has to remember to re-run.
ios_test_lint=Apps/ClientApp-iOS/Tests/.swiftlint.yml
if [[ ! -L "${ios_test_lint}" ]]; then
  fail "${ios_test_lint} is not a symlink — the test relaxations are spelled once, in Tests/.swiftlint.yml (docs/56)"
fi
if [[ ! -e "${ios_test_lint}" ]]; then
  fail "${ios_test_lint} is a symlink that resolves to nothing — the iOS bundle would lint under the SOURCE rules"
fi
if ! diff -q "${ios_test_lint}" Tests/.swiftlint.yml > /dev/null; then
  fail "${ios_test_lint} resolves somewhere other than Tests/.swiftlint.yml"
fi
printf 'check-supervisor: two test trees, one relaxation, and the second is a link rather than a copy.\n'

# ── The drop chip is one chip, and the pill inks are a pair (docs/56 §3.5, increments 56c/56e) ──
# THE DROP CHIP IS DRAWN TWICE AND BOTH CAN BE ON SCREEN AT ONCE, which is what makes it different
# from every other "drawn twice" pair in this file. The canvas overlay's ghost chip is anchored to
# the zone it describes; `MacPaneDragChipPanel`'s capsule takes over the moment the cursor leaves the
# content column. Drag from the canvas to the sidebar slowly and a user sees both — so a half-step of
# padding or a different rim does not read as two files disagreeing, it reads as the chip glitching.
#
# `Slate/PaneDropChipArt.swift` is the shared answer: the `Mark` → `SFSymbol` table and the four
# numbers the capsule is made of. Both renderers must READ it rather than restate it. The literals
# banned below are the exact ones that were open-coded in the SwiftUI chip before the port — a
# re-introduced `0.4` rim or a raw `10` pad is precisely how the two would drift apart again.
DROP_CHIP_ART=Sources/SlopDeskSlate/PaneDropChipArt.swift
if [[ ! -e "${DROP_CHIP_ART}" ]]; then
  fail "${DROP_CHIP_ART} is gone — the drop chip's two drawings have nothing left to agree on (docs/56 §3.5)"
fi
for half in Sources/SlopDeskPhoneUI/Pane/PaneMoveAffordance.swift \
  Sources/SlopDeskMacUI/App/MacPaneDragChipPanel.swift; do
  if [[ ! -e "${half}" ]]; then
    fail "${half} is gone — the drop chip has two drawings and this ratchet pins both (docs/56 §3.5)"
  fi
  for rung in glyphGap padH padV cancelRim; do
    if ! grep -q "DropChip.${rung}" "${half}"; then
      fail "${half} stopped reading Slate.DropChip.${rung} — the two drop chips drift, and a user sees both at once"
    fi
  done
  # The symbol table crossed to the floor in 56e. A half that switches on a `Mark` itself has grown a
  # second one, which is how `.beside` ends up as `rectangle.stack` in one chip and something else in
  # the other.
  if sed -E 's#^[[:space:]]*//.*##' "${half}" | grep -qE 'case \.(splitColumns|splitRows|newWindow):'; then
    fail "${half} switches on a PaneDropRegister.Mark — the mark→artwork table is ${DROP_CHIP_ART}'s alone"
  fi
done
# THE PILL FILL IS ONE SWITCH NOW, NOT A PAIR (docs/56 batch 3). `PaneStatusPillView.fillColor` and
# `MacPaneStatusPillView.fillColor` used to be two independently-maintained tables, spelled once per
# renderer on the reasoning that `Color` (`SlopDeskSlate`'s) could not be pushed DOWN to meet the ink
# enum (`SlopDeskClientCore`'s) without the floor importing the ladder standing on it. `Slate/agentInk`
# already crosses that same edge the other way — the enum read UP into Slate, never a token pushed down
# — which is what a shared switch here is too. `Slate.paneStatusPillFill` / `Slate.Native.paneStatusPillFill`
# now hold the ONE switch (`SlateDesign.swift`); each renderer only CALLS it, so a case dropped from
# either resolution is a Swift compile error at the switch itself, not a bash regex someone has to run.
PILL_INK_SRC=Sources/SlopDeskWorkspaceModel/Reading/PaneStatusPillPresentation.swift
if [[ ! -e "${PILL_INK_SRC}" ]]; then
  fail "${PILL_INK_SRC} is gone — PaneStatusPillInk is the name Slate's one switch reads (docs/56 §3.5)"
fi
# `|| true`: a grep miss exits 1, and under `set -e` that would kill the run instead of reporting —
# the empty result is caught explicitly below, which is the reportable failure.
# The name is bounded by `[:[:space:]{]` for the reason the `named_ink_tables` loop below states and
# this arm did not carry: an OPEN `/^package enum PaneStatusPillInk/` also matches
# `PaneStatusPillInkRung`, so an enum renamed out from under the gate keeps parsing and the gate keeps
# passing against a table nothing declares. Found by break-test — renaming the enum did not fire it.
pill_inks="$(sed -n '/^package enum PaneStatusPillInk[:[:space:]{]/,/^}/p' "${PILL_INK_SRC}" |
  grep -oE '^[[:space:]]*case [a-zA-Z]+' | awk '{print $2}' || true)"
if [[ -z "${pill_inks}" ]]; then
  fail "no ink cases parsed out of ${PILL_INK_SRC} — this gate would pass vacuously (docs/56 §3.5)"
fi
SLATE_DESIGN=Sources/SlopDeskSlate/SlateDesign.swift
if [[ "$(grep -c 'static func paneStatusPillFill' "${SLATE_DESIGN}" || true)" -lt 2 ]]; then
  fail "${SLATE_DESIGN} does not hold BOTH paneStatusPillFill spellings (Color + Native) — the one switch split back into a pair (docs/56 §3.5)"
fi
# The Mac twin does not exist yet in every pane surface (the pane canvas is the last kind-1 rewrite).
# Pin whichever halves ARE present, so the day a twin lands it is already obliged to call the shared
# switch rather than growing its own — a ratchet written after the second renderer is written too late.
for half in Sources/SlopDeskPhoneUI/Pane/PaneStatusPills.swift \
  Sources/SlopDeskMacUI/Pane/MacPaneStatusPills.swift; do
  [[ -e "${half}" ]] || continue
  if ! grep -q 'paneStatusPillFill' "${half}"; then
    fail "${half} stopped calling Slate's paneStatusPillFill — a re-derived table is exactly how the pair this replaced grows back (docs/56 §3.5)"
  fi
  # THE REGRESSION THIS GUARDS: a renderer switching on PaneStatusPillInk ITSELF, rather than handing
  # the ink straight to the shared function, is the old per-renderer table creeping back one case at a
  # time. Comments stripped first, so a file whose header still NAMES `case .security:` in prose (as
  # this one now does) is not read as the code it is warning against.
  #
  # ⚠️ THE CASE NAMES ARE READ OUT OF THE ENUM, never spelled here. This gate shipped for an hour with
  # `case \.(security|sync):` written inline, which is the same defect increment 62 caught in the
  # `Tests/` allowlist one register up: a check that NAMES the symbols it watches goes quietly blind
  # the day one is renamed, and nothing re-reads a regex. `pill_inks` is already parsed above (and
  # already fails loudly when it parses empty), so the alternation is built from it.
  pill_case_pattern="case \\.($(printf '%s' "${pill_inks}" | paste -sd '|' -)):"
  if sed -E 's#^[[:space:]]*//.*##' "${half}" | grep -qE "${pill_case_pattern}"; then
    fail "${half} switches on PaneStatusPillInk directly — that switch is Slate.paneStatusPillFill's alone now (docs/56 §3.5)"
  fi
done
printf 'check-supervisor: one drop chip drawn twice off one art file, and %s pill inks resolved by ONE shared switch every renderer present calls.\n' \
  "$(printf '%s\n' "${pill_inks}" | wc -l | tr -d ' ')"

# AND THE PILL INKS WERE NOT THE ONLY PAIR OF THAT SHAPE — increment 56c ratcheted one of three and
# missed two (fixed in 57b). `DropZoneInk` and `GuiUploadTint` are the identical arrangement for the
# identical reason: each is a NAME in `SlopDeskClientCore` because its resolution is a `Color`, `Color`
# is `SlopDeskSlate`'s, and Slate sits ABOVE the logic floor — so the branch descends and the LOOKUP
# stays in each renderer, one four-line `switch` per framework. 56c's own sentence is why they are here
# rather than waiting for the canvas rewrite: *a ratchet written after the second renderer arrives is a
# ratchet written too late*. The Mac twins do not exist yet; the loop pins whichever halves do, so the
# day a twin lands it is already obliged to answer the same roles instead of inventing its own.
#
# The `\b` after the case name is load-bearing on the drop-zone table: without it `case \.accent`
# also matches `case .accentMuted:`, so a half that resolved only the muted rung would pass the gate
# for the rung it dropped. `M` follows `t` with no word boundary between them, which is exactly the
# hole. Read the cases out of the enum, never list them here — a THIRD rung must be red in every half.
#
# `|| true` on each parse: a grep miss exits 1, and under `set -e` that kills the run instead of
# reporting. The empty result is the reportable failure and is caught right after.
#
# Field 1 is the enum's declaring file, 2 the enum, then every renderer that resolves it.
#
# THE GUESSED PATH WAS WRONG, and the gate is what caught it. This row was written ahead of the Mac
# half naming `MacGuiLeafView.swift`, on the reasonable guess that the Mac twin of a 1005-line
# `GuiLeafView.swift` would be one file too. R10 split it into three, and the upload overlay — the
# only thing that resolves this table — landed in `MacGuiPaneOverlays.swift` with the rest of the
# chrome. The row now names the file that HAS the switch. That is the failure mode a
# written-ahead row is FOR: it went red the day the twin landed, on the file, instead of going
# quietly green against a path that would never resolve anything.
#
# The last three rows are 57b's finding run again over the same shape, and the FIRST of them is not a
# future risk the way every row above it is: `FindTogglePillAppearance` has BOTH halves shipping
# today — `TerminalFindBar.swift`'s SwiftUI chips and `MacGlobalSearch.swift`'s `updateLayer` — and
# its own header states the invariant nothing was checking, *"the find bar and the global-search
# query bar render the pills identically"*. Read side by side when this row was added they DO agree,
# case for case and token for token (face/subtle/secondary, hover, accentMuted + accent-at-0.5 +
# accent), so this row pins an agreement rather than codifying a drift — which is the only condition
# under which a row of this kind is worth having.
#
# Two of the rows below declare their enum in a file another row already names
# (`DropZonePresentation.swift` holds both `DropZoneInk` and `DropZoneLabelInk`;
# `PaneStatusPillPresentation.swift` holds `PaneStatusPillFill` beside the bespoke
# `PaneStatusPillInk` gate above). That is fine and deliberate: the loop keys on the ENUM, and the
# `sed` range is anchored to `^package enum <name>[:[:space:]{]`, so two ranges in one file are read
# independently and a name that is a prefix of the other still cannot capture it.
#
# `PaneStatusPillFill` is the first row whose enum has an ASSOCIATED VALUE (`fixed(PaneStatusPillInk)`)
# and the matcher handles it on both ends without a change: the parse `case [a-zA-Z]+` stops at the
# `(` and yields `fixed`, and the renderer probe `case \.fixed\b` matches `case .fixed:` and
# `case .fixed(let ink):` alike, because `(` is a word boundary. Checked rather than assumed — a row
# that silently matched nothing would be a gate that reads as green while pinning air.
declare -a named_ink_tables=(
  "Sources/SlopDeskClientCore/Pane/DropZonePresentation.swift:DropZoneInk:Sources/SlopDeskPhoneUI/Pane/PaneDropOverlay.swift:Sources/SlopDeskMacUI/Pane/MacPaneDropOverlay.swift"
  "Sources/SlopDeskClientCore/Pane/GuiPaneReadout.swift:GuiUploadTint:Sources/SlopDeskPhoneUI/Pane/GuiLeafView.swift:Sources/SlopDeskMacUI/Pane/MacGuiPaneOverlays.swift"
  "Sources/SlopDeskClientCore/Pane/FindBarPresentation.swift:FindTogglePillAppearance:Sources/SlopDeskPhoneUI/Pane/TerminalFindBar.swift:Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift"
  "Sources/SlopDeskWorkspaceModel/Reading/PaneStatusPillPresentation.swift:PaneStatusPillFill:Sources/SlopDeskPhoneUI/Pane/PaneStatusPills.swift:Sources/SlopDeskMacUI/Pane/MacPaneStatusPills.swift"
  "Sources/SlopDeskClientCore/Pane/DropZonePresentation.swift:DropZoneLabelInk:Sources/SlopDeskPhoneUI/Pane/PaneDropOverlay.swift:Sources/SlopDeskMacUI/Pane/MacPaneDropOverlay.swift"
)
for table in "${named_ink_tables[@]}"; do
  ink_src="${table%%:*}"
  ink_rest="${table#*:}"
  ink_enum="${ink_rest%%:*}"
  ink_halves="${ink_rest#*:}"
  if [[ ! -e "${ink_src}" ]]; then
    fail "${ink_src} is gone — ${ink_enum} is the name two renderers agree on (docs/56 §3.5)"
  fi
  # The name is bounded by `[:[:space:]{]` rather than left open: `/^package enum DropZoneInk/` also
  # matches `DropZoneInkRung`, so an enum RENAMED out from under the gate would keep parsing and the
  # gate would keep passing against a table nothing declares any more.
  ink_cases="$(sed -n "/^package enum ${ink_enum}[:[:space:]{]/,/^}/p" "${ink_src}" |
    grep -oE '^[[:space:]]*case [a-zA-Z]+' | awk '{print $2}' || true)"
  if [[ -z "${ink_cases}" ]]; then
    fail "no ${ink_enum} cases parsed out of ${ink_src} — this gate would pass vacuously (docs/56 §3.5)"
  fi
  IFS=':' read -r -a ink_half_list <<< "${ink_halves}"
  for half in "${ink_half_list[@]}"; do
    [[ -e "${half}" ]] || continue
    for ink in ${ink_cases}; do
      if ! grep -qE "case \.${ink}\b" "${half}"; then
        fail "${half} does not resolve the ${ink_enum} .${ink} rung — the renderers would ink it differently (docs/56 §3.5)"
      fi
    done
  done
  printf 'check-supervisor: %s is %s rungs, resolved by every renderer present.\n' \
    "${ink_enum}" "$(printf '%s\n' "${ink_cases}" | wc -l | tr -d ' ')"
done

# ── `staticMirror` stays deleted (docs/56 §3.5, increment 56d) ──────────────────────────────────
# IT WAS A PARAMETER NOTHING EVER SET. `staticMirror` threaded through `SplitContainer`,
# `PaneContainer`, `GuiLeafView` and `TerminalLeafView`, branched at ~20 sites, and rode as a dead
# argument on four `SlopDeskClientCore` predicates. Every production caller took the default; the only
# `true` in the repo was in three unit tests, which is the shape of a feature kept alive by its own
# tests — the same finding increment 45b recorded about a second git-line renderer.
#
# It is deleted HERE, before the canvas is rewritten, and the timing is the whole point: ~20 of those
# branches would otherwise have been translated into AppKit by hand, for a path nothing reaches. A
# flag that is dead in one language is cheap; the same flag alive in two is the "one implementation,
# never two" failure `CLAUDE.md` bans, and a rewrite is exactly when it gets committed by accident.
if grep -rn 'staticMirror' Sources/ Apps/ --include='*.swift' 2> /dev/null |
  sed -E 's#^[^:]+:[0-9]+:[[:space:]]*(///?|\*).*##' | grep -q 'staticMirror'; then
  grep -rn 'staticMirror' Sources/ Apps/ --include='*.swift' 2> /dev/null |
    sed -E 's#^([^:]+:[0-9]+):[[:space:]]*(///?|\*).*#\1 (comment, allowed)#' >&2
  fail "\`staticMirror\` is back as CODE — it was a dead branch deleted before the AppKit canvas rewrite (docs/56 §3.5)"
fi
printf 'check-supervisor: staticMirror stays deleted — the dead mirror branch never reached the AppKit rewrite.\n'

# A TEAR-OFF IS TWO ORDERED STEPS, NOT ONE OP (docs/56 §3, stage F wave P).
# `PaneCanvasDragController.commitDestination` records the drop placement on the drag coordinator
# BEFORE `store.detachPaneToWindow`, because `detachedPanes` changes SYNCHRONOUSLY inside that call
# and the satellite-window coordinator reads the placement as it opens the window. Reversed, the
# window still opens — it just opens at the centre-cascade instead of under the cursor, and only when
# the reader wins the race. An occasional wrong-place window is the worst failure shape there is, and
# until this declaration descended out of `SplitContainer` it was pinned by nothing but a comment.
DRAG_CTL=Sources/SlopDeskClientCore/Pane/PaneCanvasDragController.swift
if [[ ! -e "${DRAG_CTL}" ]]; then
  fail "${DRAG_CTL} is gone — the canvas drag's decisions have nowhere to be spelled once (docs/56 §3)"
fi
# Comments stripped: the ordering is a fact about CODE, and both verbs are named in this file's header.
drag_ctl_code="$(sed -E 's#^[[:space:]]*//.*##' "${DRAG_CTL}")"
record_line="$(printf '%s\n' "${drag_ctl_code}" | grep -n 'recordPlacement(' | head -1 | cut -d: -f1 || true)"
detach_line="$(printf '%s\n' "${drag_ctl_code}" | grep -n 'detachPaneToWindow(' | head -1 | cut -d: -f1 || true)"
if [[ -z "${record_line}" || -z "${detach_line}" ]]; then
  fail "${DRAG_CTL} no longer spells both halves of the tear-off — placement, THEN detach (docs/56 §3)"
fi
if ((record_line >= detach_line)); then
  fail "${DRAG_CTL} detaches BEFORE recording the placement — the satellite opens at the cascade, and only sometimes (docs/56 §3)"
fi
# AND NO RENDERER MAY SPELL IT AGAIN. The canvas is about to have two drawings; each one CALLS this
# controller. A renderer naming a commit verb itself has re-derived the fork — and, on the tear-off,
# the ordering — by hand, which is the "one implementation, never two" failure a rewrite commits by
# accident. The Mac twin does not exist yet; the loop pins whichever renderers do, because a ratchet
# written after the second renderer arrives is a ratchet written too late (increment 56c's sentence,
# which has now gone unapplied to its own siblings twice).
for verb in detachPaneToWindow recordPlacement resolveTreeExternalDestination \
  resolveSpringLoadedTreeDestination updateSolvedLayout updateContainerBounds; do
  for renderer in Sources/SlopDeskPhoneUI/Pane/SplitContainer.swift \
    Sources/SlopDeskMacUI/Pane/MacSplitCanvasView.swift; do
    [[ -e "${renderer}" ]] || continue
    if sed -E 's#^[[:space:]]*(///?|\*).*##' "${renderer}" | grep -q "${verb}("; then
      fail "${renderer} calls ${verb}() itself — the canvas drag is PaneCanvasDragController's one decision (docs/56 §3)"
    fi
  done
done
printf 'check-supervisor: the canvas drag decides once, and its tear-off records before it detaches.\n'
# A PALETTE ROW DECLARES ITS PLATFORM, and it declares it exactly once. The three window verbs the
# phone cannot run — the satellite pair and the window level — used to be listed there anyway: one
# hook no phone root binds, and one run arm that is a macOS-only `#if` with nothing in the else.
# Both are invisible from the row, and both answer a keystroke by doing nothing.
#
# `slopdesk_workspace::palette_rows` is where that fact lives now, and it can only close the hole if
# it names the SAME verbs the catalog serves. An id on one side only is the failure: a Swift row the
# table never heard of is listed unconditionally (the far side fails OPEN on purpose, so a typo
# cannot delete a verb in silence), and a Rust row no catalog serves is a rule about nothing.
SWIFT_PALETTE=Sources/SlopDeskClientCore/Palette/PaletteDataSource.swift
RUST_PALETTE=rust/slopdesk-workspace/src/palette_rows.rs
palette_swift_ids=$(grep -oE 'id: "action\.[A-Za-z]+"' "${SWIFT_PALETTE}" |
  grep -oE 'action\.[A-Za-z]+' | sort -u || true)
palette_rust_ids=$(grep -oE 'row\("action\.[A-Za-z]+"' "${RUST_PALETTE}" |
  grep -oE 'action\.[A-Za-z]+' | sort -u || true)
if [[ "${palette_swift_ids}" != "${palette_rust_ids}" ]]; then
  diff <(printf '%s\n' "${palette_swift_ids}") <(printf '%s\n' "${palette_rust_ids}") >&2 || true
  fail "the palette catalog and its platform table name different verbs (< Swift only, > Rust only)"
fi
# AND THE GATE DOES NOT COME BACK. A row whose platform is data has no business branching on one:
# `detachPane`'s run arm carried the `#if` this table replaced, and re-adding one anywhere in the
# catalog would make a row half-listed again.
if grep -qE '^\s*#if os\(' "${SWIFT_PALETTE}"; then
  grep -nE '^\s*#if os\(' "${SWIFT_PALETTE}" >&2
  fail "a platform gate is back in the palette catalog — a row's platform is DATA (palette_rows.rs)"
fi
printf 'check-supervisor: a palette verb names its platform once — %s verbs, no gate in the catalog.\n' \
  "$(printf '%s\n' "${palette_rust_ids}" | wc -l | tr -d ' ')"

# ── …AND EVERY KEYBINDING IS REACHABLE FROM IT, without a keyboard ──────────────────────────────
# The palette listed 33 verbs; the registry declares 77. On a Mac the gap is invisible — the menu bar
# reaches every binding — so it survived. A phone has no menu bar, so with no hardware keyboard
# attached the palette IS the command surface and ~45 verbs could not be said at all.
#
# The fix is a DERIVATION, not a second catalog, and that is what this pins. `registryRows` reads
# `WorkspaceBindingRegistry.bindings` (already platform-filtered, so no gate of its own), and
# `coveredActions` is read off the catalog's own rows — so the join between the two id spaces cannot
# rot, because there is no join anyone maintains. Written out as a literal set, it would go stale the
# first time a row changed hands and nothing would say so.
#
# The REACH itself (every binding runs from some row) is `PaletteReachesEveryBindingTests`, which can
# ask the types. This checks the SHAPE that keeps that test cheap to satisfy honestly.
for derived in \
  'static let registryRows: \[PaletteItem\] = WorkspaceBindingRegistry\.bindings' \
  'static let coveredActions: Set<WorkspaceAction> = Set\(declared\.compactMap'; do
  if ! spells "${derived}" "${SWIFT_PALETTE}" > /dev/null; then
    fail "${SWIFT_PALETTE} no longer DERIVES the registry rows — a transcribed list goes stale in silence (docs/56 §3.6)"
  fi
done
# A row that names a registry verb must RUN that verb, not a second spelling of it. Twenty-four rows
# used to carry a `.store` closure restating their `route` arm line for line, and one had already
# drifted into a different split call. `PaletteAction` is where that was possible; keep it shut.
for revived in 'case toggleSidebar' 'case toggleCodeSidebar' 'case focusCodePanel' \
  'case togglePinWindow' 'case closeWindow' 'case openCheatSheet'; do
  if hit=$(spells "${revived}" Sources/SlopDeskClientCore/Palette/PaletteModel.swift); then
    fail "${hit} re-implements a registry verb as its own PaletteAction — the row IS the verb (\`.binding\`)"
  fi
done
printf 'check-supervisor: every keybinding is reachable from the palette, by derivation and not by list.\n'

# ── …and a KEYBINDING names its platform once, in the other id space ────────────────────────────
# The registry is four surfaces at once — cheat sheet, keybindings editor, `ctl` verb list, and the
# CHORD TABLE. That last one is why a listed-and-inert binding is worse than a listed-and-inert
# palette row: a bound chord does not reach the terminal, so ⌥⌘P was taken from the PTY to run a
# macOS-only `#if` with nothing in its else. Same pin as the palette's, over `binding_rows.rs`.
#
# The nine generated `pane.select.N` slots are minted by a loop and are deliberately undeclared (they
# are `Both`, and the table declares the ONE collapsed representative `pane.selectN`), so they are
# excluded here BY NAME rather than by the grep quietly not matching them.
SWIFT_BINDINGS=Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingRegistry.swift
RUST_BINDINGS=rust/slopdesk-workspace/src/binding_rows.rs
binding_swift_ids=$(grep -oE 'id: "[a-z]+\.[A-Za-z0-9]+"' "${SWIFT_BINDINGS}" |
  grep -oE '[a-z]+\.[A-Za-z0-9]+' | sort -u || true)
binding_rust_ids=$(grep -oE 'row\("[a-z]+\.[A-Za-z0-9]+"' "${RUST_BINDINGS}" |
  grep -oE '[a-z]+\.[A-Za-z0-9]+' | sort -u || true)
if [[ "${binding_swift_ids}" != "${binding_rust_ids}" ]]; then
  diff <(printf '%s\n' "${binding_swift_ids}") <(printf '%s\n' "${binding_rust_ids}") >&2 || true
  fail "the binding registry and its platform table name different rows (< Swift only, > Rust only)"
fi
# AND THE GATE DOES NOT COME BACK, in either the table or its routing. `.detachPane`'s routing arm
# carried the `#if` this table replaced; re-adding one would make a chord half-bound again.
BINDING_ROUTING=Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift
for gated in "${SWIFT_BINDINGS}" "${BINDING_ROUTING}"; do
  if grep -qE '^\s*#if os\(' "${gated}"; then
    grep -nE '^\s*#if os\(' "${gated}" >&2
    fail "a platform gate is back in the binding layer — a row's platform is DATA (binding_rows.rs)"
  fi
done
printf 'check-supervisor: a keybinding names its platform once — %s rows, no gate in the registry or its routing.\n' \
  "$(printf '%s\n' "${binding_rust_ids}" | wc -l | tr -d ' ')"

# ── …and the chord table is a CONSTANT, held rather than rebuilt ────────────────────────────────
# The registry's table is 85 rows and its readers are the keyboard's. `resolvedChordTable` walked it
# once per key event, and `binding(for:)` — which the walk called per row — read `allBindings` again,
# so a computed `allBindings` meant 86 fresh 85-element arrays per keystroke, each retaining four
# strings per element. Measured at 128µs of pure allocation per key event on an M-series Mac, on the
# GLOBAL `.keyDown` monitor and on `TerminalKeyInterceptor`'s default resolver — which is to say on
# every key typed into any pane.
#
# THIS IS THE DRIFT CLASS docs/55 §8 NAMES, one register down: nothing a test can see changes when
# `let` goes back to `var`. Every assertion still passes, every chord still resolves, and the only
# symptom is input latency nobody attributes to a keyword. So the three shapes that make it a
# constant are pinned by spelling.
#
# BREAK-TESTED against the real tree, 2026-08-22: reverting `allBindings` to
# `public static var allBindings: [WorkspaceBinding] { bindings + selectPaneBindings }` fails rule 1;
# restoring `allBindings.first { $0.action == action }` in `binding(for:)` fails rule 2; deleting the
# `liveChordTable` memo from WorkspaceBindingOverrides.swift fails rules 3 and 4. All four pass on
# the tree as it stands.
BINDING_OVERRIDES=Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingOverrides.swift
# 1. The table is built once.
if ! spells 'static let allBindings: \[WorkspaceBinding\] = bindings \+ selectPaneBindings' \
  "${SWIFT_BINDINGS}" > /dev/null; then
  fail "${SWIFT_BINDINGS}: allBindings is not a stored \`let\` — a computed one re-concatenates 85 rows per READ, and the chord table reads it 86 times per key event"
fi
# 2. And the lookup is a hash, not a scan of it.
if hit=$(spells 'allBindings\.first \{ [$]0\.action ==' "${SWIFT_BINDINGS}"); then
  fail "${hit} scans the whole table for one action again — that is the O(n) half of the O(n²) per key event; byAction is the index"
fi
# 3-4. And the live table is HELD, with the setter as the only thing that can stale it.
if ! spells 'if let liveChordTable \{ return liveChordTable \}' "${BINDING_OVERRIDES}" > /dev/null; then
  fail "${BINDING_OVERRIDES}: resolvedChordTable no longer reads its memo — it is a pure function of a \`let\` and a write-once var, rebuilt on every keystroke the app sees"
fi
if ! spells 'didSet \{ liveChordTable = nil \}' "${BINDING_OVERRIDES}" > /dev/null; then
  fail "${BINDING_OVERRIDES}: activeOverrides no longer invalidates the memo on write — a rebind would not take effect until relaunch"
fi
printf 'check-supervisor: the chord table is built once and held; the key event reads it, not rebuilds it.\n'
# ── The mirror's whole topology is projected ONCE per revision ──────────────────────────────────
# `HostWorkspaceMirror.topology` is a computed property: every read copies the entire entry map and
# re-runs `WorkspaceTopology.init(entries:)` over every cell in the document. Measured in a scratch
# harness (`swiftc -O`), the dictionary copy alone is 6.4µs at 12 panes and 23.9µs at 48, and the
# per-cell decode walk on top of it takes those to 10.3µs and 37.9µs — a FLOOR, since the real
# projection also rebuilds every split tree, spec, MRU and closed tab.
#
# `SidebarRowPresentation.reading(...)` reached it once per ROW through `store.syncInputArmed`, so a
# sidebar of R rows paid R projections per render pass: ~126µs at 12 rows, ~1.8ms at 48. It is now
# memoized against `workspaceMirrorRevision`, the key `tree` already trusted, and the ONE remaining
# direct read is the memo's own miss path. A second direct read anywhere puts the whole projection
# back on that caller's path with green tests and no compile error — docs/55 §8's drift class.
#
# BREAK-TESTED 2026-08-22: adding `let t = workspaceMirror.topology` to `WorkspaceStore+Intents.swift`
# failed rule 1; removing it passed. Deleting one of the memo's two reads failed rule 2.
MIRROR_MEMO=Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore.swift
mapfile -t mirror_topology_readers < <(repo_files 'Sources/*.swift' | grep -v "^${MIRROR_MEMO}$" || true)
if ((${#mirror_topology_readers[@]} == 0)); then
  fail "check-supervisor: no Swift sources outside ${MIRROR_MEMO} — the topology-memo ban would pass on an empty haystack"
fi
if hit=$(spells 'workspaceMirror\.topology' "${mirror_topology_readers[@]}"); then
  fail "${hit} re-derives the WHOLE topology — the entry-map copy plus a walk of every cell, 10µs at 12 panes and 38µs at 48. Read \`mirroredTopology\` instead; it answers from the memo keyed on \`workspaceMirrorRevision\`"
fi
mirror_topology_inside=$(spells 'workspaceMirror\.topology' "${MIRROR_MEMO}" | wc -l | tr -d ' ' || true)
if ((mirror_topology_inside > 2)); then
  fail "${MIRROR_MEMO} reads workspaceMirror.topology ${mirror_topology_inside} times; the memo has ONE miss path. A second read belongs inside \`mirroredTopology\` or it is not memoized"
fi
printf 'check-supervisor: the mirror topology is projected once per revision, not once per sidebar row.\n'
# PORTED to `rust/slopdesk-invariants`: rail-fingerprint.

# ── The three re-derivations a body pass must not grow back ───────────────────────────────────
#
# None of these is visible to a test: every answer stays correct, both halves stay self-consistent,
# and the only trace is the frame. What they have in common is the shape docs/55 §4c's last section
# names — a value that reads like a FIELD and is in fact a PROJECTION, sitting behind a computed
# `var` that a `body` reaches for more than once.
#
# 1. THE DEVICE CONSOLES. `visible` is a `localizedCaseInsensitiveContains` over every retained log
#    line, and `logCapacity` is 600 on both models. Measured in a scratch `swiftc -O` harness (NOT
#    in the tree, two runs agreeing to 1%): 0.78 ms per derivation when the needle hits, 1.50 ms
#    when it MISSES — and a miss is the state every keystroke passes through. Both views read it
#    three times per pass (the emptiness test, the `animation(value:)` key, the `ForEach`), so one
#    console repaint cost 2.3–4.5 ms of main thread, and the drawer repaints on every arriving line.
#    The fix is one `let` threaded into `rows(_:)`; the gate is that `rows` stays a FUNCTION taking
#    the derived rows, because a `private var rows` can only have reached for `visible` itself.
#
# 2. THE DEVICE LISTS. Same rule one register down — `matches` answered an emptiness test and then
#    built the sections from two separate derivations, at ~1.6 µs per `localizedCaseInsensitiveContains`
#    call over two fields per device.
#
# 3. THE PICKER. `sections` reassembles all five pill sources off the live store and then RANKS
#    every one of them. Measured against the shipped xcframework at 127 candidates over five
#    sources: 125 µs for the ranking plus 20 µs to mint the rows. `selectableRows` and
#    `displayEntries` each reached through to it, so the picker paid ~145 µs TWICE per keystroke
#    before drawing a row — and the ⌘1–9 arm paid it twice more to read one row out.
#
# BREAK-TESTED against the real tree on 2026-08-22, each rule individually, by putting the pre-fix
# spelling back and restoring from a /tmp copy afterwards (never `git checkout`, which would have
# discarded the file's own uncommitted work). All seven fire, each on its own file only, and the
# restored tree reads 0:
#   rows() → a computed var           FAIL "rows() stopped taking the derived lines"      ✓
#   `value: visible.isEmpty` back     FAIL "asks `visible.isEmpty`"                       ✓
#   `let shown = visible` deleted     FAIL "content() stopped binding `visible` once"     ✓
#   list() → a computed var  (×2)     FAIL "list() stopped taking the derived devices"    ✓ ✓
#   `let built = sections` deleted    FAIL "resultsList stopped binding `sections` once"  ✓
#   `displayEntries` grown back       FAIL "`displayEntries` is back as a computed var"   ✓
for half in Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorConsoleView.swift \
  Sources/SlopDeskPhoneUI/Panel/Android/AndroidConsoleView.swift; do
  if ! grep -qE '^ *private func rows\(_ shown: \[DeviceLogLine\]\)' "${half}"; then
    fail "${half}: rows() stopped taking the derived lines — a \`private var rows\` re-runs the 600-row filter a second time"
  fi
  # The other two derivations were both `visible.isEmpty` — the `if` and the `animation(value:)` key
  # — and they are banned by SHAPE. A shape ban cannot see an intent, but here the shape IS the
  # defect: there is no reading of this property that costs less than the whole filter, so asking it
  # a yes/no question is asking for the 600-row scan and throwing the rows away. The ONE surviving
  # read outside the `let` is the Copy-console verb, and that one is inside a `Button` ACTION
  # closure, so it happens on a tap rather than on a pass. Comments are stripped first: both files
  # NAME `visible` in the note that explains the `let`.
  if grep -qE '\bvisible\.isEmpty\b' <<< "$(sed -E 's,//.*,,;s,^ */// .*,,' "${half}")"; then
    fail "${half}: asks \`visible.isEmpty\` — that runs the whole 600-row filter to answer a Bool (docs/55 §4c)"
  fi
  if ! grep -qE '^ *let shown = visible$' "${half}"; then
    fail "${half}: content() stopped binding \`visible\` once — the 0.78–1.50 ms filter is back on every reader"
  fi
done
for half in Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorDeviceList.swift \
  Sources/SlopDeskPhoneUI/Panel/Android/AndroidDeviceList.swift; do
  if ! grep -qE '^ *private func list\(_ shown: \[(Simulator|Android)Device\]\)' "${half}"; then
    fail "${half}: list() stopped taking the derived devices — a \`private var list\` re-filters every device a second time"
  fi
done
# The picker: ONE `sections` per pass, and no computed `var` that reaches through to it a second
# time. `displayEntries` was exactly that and is deleted; `selectableRows` survives because the key
# handlers legitimately want one derivation of their own.
if ! grep -qE '^ *let built = sections$' Sources/SlopDeskPhoneUI/Overlays/OpenQuicklyView.swift; then
  fail "OpenQuicklyView: resultsList stopped binding \`sections\` once — every reader re-ranks all five sources (~145 µs a keystroke)"
fi
if grep -qE '^ *private var displayEntries:' Sources/SlopDeskPhoneUI/Overlays/OpenQuicklyView.swift; then
  fail "OpenQuicklyView: \`displayEntries\` is back as a computed var — it is a second whole derivation of \`sections\`"
fi
printf 'check-supervisor: three projections read once per pass, not three times.\n'

# ── WorkspaceCore: the re-derivations this sweep removed ──────────────────────────────────────
# Five rules, from the Rust-push sweep of `Sources/SlopDeskWorkspaceCore/`. Every one of them pins a
# change whose ONLY symptom is latency: the code keeps compiling, every unit test keeps passing, and
# the find bar or the folder overlay just gets slower. That is the whole reason they are here rather
# than in a suite — a differential test cannot see a doubled scan, and a timing assertion in CI is a
# flake generator. Each block states what was measured, and each was break-tested against the real
# tree by editing the file, running this section, and restoring from a `/tmp` copy.
#
# docs/55-ffi-boundary.md §4 (guess-then-retry, never probe with a null output) and §4c (rank by
# ALLOCATIONS and RE-DERIVATIONS, not by crossing count).

WSCORE_FRECENCY="Sources/SlopDeskWorkspaceCore/Folders/FolderFrecency.swift"
WSCORE_SYNCINPUT="Sources/SlopDeskWorkspaceCore/Workspace/Store/SyncInputByteFilter.swift"
WSCORE_LOOPBACK="Sources/SlopDeskWorkspaceCore/Workspace/Sync/LoopbackWorkspaceDocument.swift"
WSCORE_TEMPLATES="Sources/SlopDeskWorkspaceCore/Workspace/Domain/SessionTemplateEngine.swift"
WSCORE_FIND="Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift"
WSCORE_GLOBALFIND="Sources/SlopDeskWorkspaceCore/Terminal/GlobalSearchController.swift"
RUST_ROWFIND="rust/slopdesk-rowscan/src/find.rs"

# Every rule below reads CODE, never prose: each of these files documents the shape it no longer has,
# by name, so a gate that matched comments would fire on the explanation of its own bug. An empty
# strip is named rather than assumed — a file that became all comment would otherwise read as the
# healthiest result this section can print.
for wscore_file in "${WSCORE_FRECENCY}" "${WSCORE_SYNCINPUT}" "${WSCORE_LOOPBACK}" \
  "${WSCORE_TEMPLATES}" "${WSCORE_FIND}" "${WSCORE_GLOBALFIND}" "${RUST_ROWFIND}"; do
  if [[ ! -f "${wscore_file}" ]]; then
    fail "${wscore_file} is gone — the WorkspaceCore latency ratchets below stopped checking anything"
  fi
done
wscore_code() { grep -vE '^ *(///|//!|//|\*)' "$1" 2> /dev/null || true; }

# ── W1. The two index doors guess, they do not probe ────────────────────────────────────────────
# `slopdesk_folder_ranked`, `slopdesk_folder_sanitized` and `slopdesk_sync_input_keyboard_only` all
# answer a SUBSET of what was lent, so the caller holds the exact ceiling of the answer before it
# asks. Both faces used to call with a null output first to learn a size they could already compute
# — and a null-output call on these doors is not free, it rebuilds the whole folder database and
# sorts it, or runs the whole `vtscan` pass, and throws the answer away. Measured: `ranked` at the
# shipped 200-entry cap 30.9 µs → 15.6 µs through the door (54.3 µs → 39.0 µs for the whole Swift
# face), and the sync-input strip 14.4 µs → 7.5 µs on an 8 KiB mirrored paste. The overlay asks for
# the ranking twice per keystroke.
#
# BREAK-TESTED: restoring the `(nil, 0)` first call in `FolderFrecency.answer(sizedAt:)` fires W1a;
# restoring it in `SyncInputByteFilter.keyboardOnly` fires W1b. Both files restored from /tmp.
for wscore_prober in "${WSCORE_FRECENCY}:W1a:the folder ranking" "${WSCORE_SYNCINPUT}:W1b:the sync-input strip"; do
  wscore_path="${wscore_prober%%:*}"
  wscore_rest="${wscore_prober#*:}"
  wscore_tag="${wscore_rest%%:*}"
  wscore_what="${wscore_rest#*:}"
  if wscore_code "${wscore_path}" | grep -qE '\bnil, *0\b|\bnull, *0\b'; then
    fail "${wscore_tag}: ${wscore_path} probes ${wscore_what} with a NULL output again — that call runs the whole far-side rule and keeps nothing, to learn a size the caller already has (docs/55 §4)"
  fi
done
# The guess is what makes the probe unnecessary, so its absence is the same bug wearing a different
# face: a `ranked` that stopped sizing its first buffer would be back to one call per answer only by
# accident.
if ! wscore_code "${WSCORE_FRECENCY}" | grep -q 'answer(sizedAt:'; then
  fail "W1c: ${WSCORE_FRECENCY} no longer sizes its first buffer from the ceiling it holds — the index doors are back to being asked twice (docs/55 §4)"
fi

# ── W2. The find door's guess is CARRIED, not a constant ────────────────────────────────────────
# `slopdesk_find_matches` builds its answer by scanning every row, so §4's retry costs a second scan
# of the entire scrollback rather than a second copy. A fixed 128-record guess therefore doubled
# every query that matched more than 128 rows — which is most of the useful ones. Measured through
# the door over a 10 000-row / 736 KB scrollback with a query matching every row: 3.52 ms per
# keystroke at the fixed guess against 1.83 ms at the carried one, per pane, and ⇧⌘F asks every open
# pane at once.
#
# BREAK-TESTED: deleting `expecting: matches.count` from `recompute()` fires W2a; deleting
# `expecting: expected` from `GlobalSearchController.run` fires W2b. Both restored from /tmp.
if ! wscore_code "${WSCORE_FIND}" | grep -q 'expecting: matches.count'; then
  fail "W2a: ${WSCORE_FIND} stopped carrying the previous keystroke's match count into the next scan — every query matching more than the stack guess scans the scrollback twice"
fi
if ! wscore_code "${WSCORE_GLOBALFIND}" | grep -q 'expecting: expected'; then
  fail "W2b: ${WSCORE_GLOBALFIND} stopped carrying a guess across panes — the first pane's answer sizes the rest, and without it every pane pays the second scan"
fi

# ── W3. The find scan does not re-derive a row it already has ───────────────────────────────────
# Three re-derivations lived in one 90-line module, all of them per keystroke over the whole
# scrollback. `folded()` returned a fresh `Vec<u16>` per row; the literal matcher compared the
# pattern at EVERY offset instead of skipping to its first unit; `stands_alone` re-encoded the whole
# row per HIT; and the regex path measured each column from the start of the row, which is quadratic
# in a row with many hits. Measured against this module at the commit before, linked into the same
# binary so both sides run the same `regex` build: 10 000 rows / 736 KB, case-insensitive literal
# 6.3 ms → 1.2 ms; with whole-word 8.2 ms → 2.0 ms; and on ONE 160 KB row with 20 000 regex hits —
# the shape a program prints whenever it emits an unwrapped line — 782 ms → 1.9 ms, per keystroke.
#
# The rules are shape-based on purpose. A vocabulary pin would pass the day someone reintroduced the
# per-row allocation under a new name; what cannot come back quietly is the SIGNATURE that forced it.
#
# BREAK-TESTED: changing `stands_alone(units: &[u16], …)` back to taking `line: &str` fires W3a;
# reintroducing `fn folded(text: &str, case_sensitive: bool) -> Vec<u16>` fires W3b; restoring
# `utf16_units(line.get(..hit.start())…)` fires W3c. `find.rs` restored from /tmp each time.
if ! wscore_code "${RUST_ROWFIND}" | grep -q 'fn stands_alone(units: &\[u16\]'; then
  fail "W3a: ${RUST_ROWFIND}'s whole-word filter takes a row again instead of the units its caller already holds — it re-encodes the whole line once per HIT"
fi
if wscore_code "${RUST_ROWFIND}" | grep -qE 'fn folded\(.*\) *-> *Vec<u16>'; then
  fail "W3b: ${RUST_ROWFIND} allocates a fresh Vec<u16> per row again — a malloc and a free per row of the scrollback, per keystroke in the find bar"
fi
# Both halves: the shape that is wrong, and the shape that is right. Banning the from-zero slice
# alone would pass the day someone rewrote the walk without reintroducing that exact spelling.
if wscore_code "${RUST_ROWFIND}" | grep -q 'utf16_units(line.get(\.\.'; then
  fail "W3c: ${RUST_ROWFIND} measures each regex column from the start of its row again — quadratic in a row with many hits, and one long unwrapped line freezes the find bar for the better part of a second"
fi
if ! wscore_code "${RUST_ROWFIND}" | grep -q 'line.get(counted_bytes\.\.hit.start())'; then
  fail "W3c: ${RUST_ROWFIND} no longer carries a byte cursor between regex hits on one row — each column is measured over the row's whole prefix again, which is quadratic in the row"
fi
# The ASCII arm is the one that actually runs, and it is the difference between a table walk per code
# unit and a mask. Its absence is not a correctness bug, which is exactly why nothing else catches it.
if ! wscore_code "${RUST_ROWFIND}" | grep -q 'to_ascii_lowercase'; then
  fail "W3d: ${RUST_ROWFIND} folds every code unit through the full Unicode mapping again — a ToLowercase iterator per character of every row, per keystroke"
fi

# ── W4. The loopback document resolves the mirror ONCE ──────────────────────────────────────────
# `HostWorkspaceMirror.resolved` copies the whole entry map and folds the overlay and every pending
# patch over it, and `WorkspaceIntentApplier.apply` asks its `projectKey:` closure once per pane the
# document names — live specs UNION the reopen ring. Built inside the closure that is one whole-map
# copy per pane, which is quadratic in the workspace. `WorkspaceMirrorBox.stageIntent` hoists it and
# says why at its own call site; this was the sibling call site that did not.
#
# BREAK-TESTED: moving `box.mirror.resolved` back inside the `projectKey:` closure fires W4. File
# restored from /tmp.
if wscore_code "${WSCORE_LOOPBACK}" | grep -qE 'projectKey: *\{ *box\.mirror\.resolved'; then
  fail "W4: ${WSCORE_LOOPBACK} resolves the mirror inside its projectKey closure again — one copy of the whole entry map per pane, quadratic in the workspace"
fi
if ! wscore_code "${WSCORE_LOOPBACK}" | grep -q 'let resolved = box.mirror.resolved'; then
  fail "W4: ${WSCORE_LOOPBACK} no longer hoists the resolved mirror above its projectKey closure — see WorkspaceMirrorBox.stageIntent, which is the same contract"
fi

# ── W5. The launch-bytes emptiness rule has ONE author ──────────────────────────────────────────
# Not latency: drift, of docs/55 §8's class. `SessionTemplateEngine.launchBytes` used to trim the
# cwd and the command itself, ahead of calling `templates::keystrokes`, which decides the same
# thing — and the two did not agree. The crate gated the DIRECTORY untrimmed, so a whitespace-only
# cwd was "no directory" in Swift and `cd '  '` in Rust, a line the shell answers with an error at
# every launch. Both production callers pass `cwd: nil`, which is precisely why a pair like that can
# sit disagreeing indefinitely. The gate is symmetric in the crate now and the Swift reads its
# answer; a trim reappearing here is the second author coming back.
#
# BREAK-TESTED: adding a `trimmingCharacters` gate to `launchBytes` fires W5. File restored from
# /tmp.
if wscore_code "${WSCORE_TEMPLATES}" | grep -q 'trimmingCharacters'; then
  fail "W5: ${WSCORE_TEMPLATES} decides emptiness itself again — \`templates::keystrokes\` owns that rule, and the last time both wrote it they disagreed about a whitespace-only cwd (docs/55 §8)"
fi

# =================================================================================================
# HUNK for scripts/check-supervisor.sh — the VIDEO path's four ports.
#
# Append this block wherever the video gates live. It uses `fail`, `spells` and `repo_files` from
# the script's own preamble; it defines no helpers of its own.
#
# Every rule below was BREAK-TESTED against the real tree: the file was copied to /tmp, the port was
# reverted by hand in the working copy, the rule was run, and the file was restored from /tmp. The
# verdict is recorded in each rule's comment. None of these four defects is visible to any test,
# which is the entire reason they are pinned here.
# =================================================================================================

SWIFT_VIDEO_ENCODER=Sources/SlopDeskVideoHost/VideoEncoder.swift
SWIFT_VIDEO_CLIENT_SESSION=Sources/SlopDeskVideoClient/SlopDeskVideoClientSession.swift
SWIFT_VIDEO_SESSION_LOGIC=Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift
SWIFT_VIDEO_FEC=Sources/SlopDeskVideoProtocol/FECScheme.swift
SWIFT_VIDEO_NAL=Sources/SlopDeskVideoProtocol/NALUnit.swift

# ---- 1. WITHDRAWN 2026-08-23: the whole ramp left Swift. ------------------------------------------
# This rule pinned `VideoEncoder.swift` to three doors — `slopdesk_video_qp_ceiling`,
# `_ceiling_config_default` and `_qp_drop_relief_fold` — because the file drove the budget→ceiling
# ramp and the drop relief from Swift while the arithmetic lived in `encoder_ceiling.rs`. The whole
# state machine is now `slopdesk_video::encoder_state`, which calls that module DIRECTLY, so the
# three doors were a second way to ask what the crate already answers and are deleted with this rule.
# What replaces it is `hevc-codec-is-rusts` in `rust/slopdesk-invariants` — a content ban on the
# bracket and the integrator in the same file, plus the ramp arithmetic this rule watched — and
# `docs/57` §5 records why. The heading number stays so the ones below it keep their names.

# ---- 2. A control datagram the client already holds is not re-encoded to be re-parsed. -----------
# `handleControl(datagram:)` existed, documented itself as being "so a caller that already holds the
# bytes does not re-encode what it just decoded", and had no caller: the receive path routed the
# datagram into a `VideoControlMessage` and then handed the state machine `[UInt8](message.encode())`
# — re-encoding, into a fresh array, bytes it had just parsed. Measured against the shipped
# xcframework, two agreeing runs: 147.8/155.2 ns to re-encode against 0.7 ns to lend the `Data`.
# docs/55 §8 is why this is a gate and not a nicety: an exported door with no caller is worse than
# an unported rule, because it reads as covered.
#
# BREAK-TESTED: putting `stateMachine.handleControl(message)` back in `receiveMedia` fires the first
# rule; re-adding the `[UInt8](message.encode())` marshalling fires the second. Shipped tree: silent.
if ! grep -q 'handleControl(datagram:' "${SWIFT_VIDEO_CLIENT_SESSION}"; then
  fail "${SWIFT_VIDEO_CLIENT_SESSION} no longer lends the control DATAGRAM — it is re-encoding a message it parsed"
fi
if hit=$(spells 'handleControl\(message\)|\[UInt8\]\(message\.encode\(\)\)|handleControl\(routed' \
  "${SWIFT_VIDEO_CLIENT_SESSION}"); then
  fail "${hit} re-encodes a routed control message — hand the state machine the bytes it arrived in"
fi

# ---- 3. The cursor-shape tracker answers "already cached" without lending three buffers. ---------
# Its general step lends three arrays and adopts three prefixes — 6 allocations — and the host
# samples the cursor at ~120 Hz, so in steady state that is 6 allocations per packet to be told the
# shape is already cached. The crate answers that case without touching its state, so the face asks
# through `slopdesk_cursor_shape_is_known`, which allocates nothing. Measured, two agreeing runs:
# 488.0/509.1 ns per call with 4 cached shapes and 1249.3/1122.3 ns with 12, against 68.5/68.6 ns and
# 252.2/258.6 ns through the guard.
#
# BREAK-TESTED: deleting the `if isKnown(shapeID) { return false }` line fires; shipped tree silent.
# Matched on the line's shape rather than on `isKnown` alone, because `isKnown` is also the
# test/diagnostics seam and would pass this gate while the hot path went back through the step.
if ! grep -qE 'if +isKnown\(shapeID\) *\{ *return false *\}' "${SWIFT_VIDEO_SESSION_LOGIC}"; then
  fail "${SWIFT_VIDEO_SESSION_LOGIC} lost the cached-shape guard — 6 allocations per cursor packet to answer no"
fi

# ---- 4. The FEC send path promotes its fragments LAZILY. -----------------------------------------
# `FECBlobList.encode` takes `Collection<Data?>`; the send side holds `[Data]`. Promoting eagerly
# builds a whole second array of refcounted `Data`s, once per frame, to say nothing at all. Measured
# at `-O`, two agreeing runs, per call: 423.7/430.0 ns eager at 24 fragments, 960.6/947.9 ns at 60,
# 3559.2/3561.8 ns at 240 — against 31.4/30.5, 69.7/70.0 and 247.3/245.1 ns through the lazy view.
#
# The trap this pins is that the eager form was written as `.map(\.self)`, and DELETING it does not
# fix anything: the implicit `[Data]` → `[Data?]` bridge that then runs is a runtime cast, and it is
# more than TWICE as dear as the `map` (902.8/905.0 ns at 24 fragments). So the ban is on the eager
# `map`, and the positive rule is that the lazy overload is still there to bind to.
#
# BREAK-TESTED: restoring `FECBlobList.encode(dataFragments.map(\.self))` fires the ban; deleting the
# `[Data]` overload fires the second rule. Shipped tree: silent on both.
if hit=$(spells 'FECBlobList\.encode\([A-Za-z]+\.map\(' "${SWIFT_VIDEO_FEC}" "${SWIFT_VIDEO_NAL}"); then
  fail "${hit} eagerly promotes its fragments — hand the encoder the array and let the lazy overload take it"
fi
if ! grep -qE 'blobs\.lazy\.map' "${SWIFT_VIDEO_FEC}"; then
  fail "${SWIFT_VIDEO_FEC} lost the lazy [Data] overload — every send-path caller pays a second array per frame"
fi
printf 'check-supervisor: the video path lends what it holds — no re-encode, no re-ask, no second array.\n'

# THE MAC HALF, since the video carve (docs/56 §3). This was
# `Sources/SlopDeskVideoClient/VideoWindowView.swift` — one file whose middle 2,514 lines were an
# `#if os(macOS)` / `#elseif os(iOS)` two-armed conditional — and the two phase encodings below are
# `NSEvent.Phase`, so they went to the AppKit arm and nowhere else. The path is the Mac half's backing
# view now. The "every path this file names still exists" sweep near the end catches this variable
# going stale again — it derives its list from `${!SWIFT_@}`, so this constant is covered by being
# named `SWIFT_*` and needs no ledger entry of its own. That sweep is exactly what caught the carve:
# the file was deleted, the two `grep -q` pairs below silently found nothing in a haystack that was
# not there, and only the derived sweep said why.
SWIFT_VIDEO_WINDOW_VIEW=Sources/SlopDeskVideoClientMac/MacMetalLayerBackedView.swift
RUST_CLIENT_GESTURES=rust/slopdesk-video/src/client_gestures.rs
RUST_SCROLL_REPROJECT=rust/slopdesk-video/src/scroll_reproject.rs

# ---- 5. The two CoreGraphics phase encodings are ONE table. --------------------------------------
# CoreGraphics puts two phase fields on a scroll event and encodes the same three edges differently:
# the scroll field is a bit set, so its END is 4 and there is room for a cancel at 8 and a
# finger-at-rest at 128; the momentum field is an ordinal, so ITS end is 3. Those ten numbers were
# spelled in FOUR places across two languages — a private block in `client_gestures`, the reprojector,
# the touch translation, and the Mac client's view — and two of the four read different sets of them.
# Nothing measures: a door here is ~1 ns against ~5 branches, which is the point. A rule two
# languages spell differently is a defect at zero calls per second, and only one of the two answers
# is right.
#
# VERIFIED, not asserted: the port was differentially checked from Swift against the deleted Swift
# verbatim, over all 256 masks × both fields = 512 comparisons, through the linked release archive.
# Zero mismatches, twice. The AppKit bit values the mapping assumes were read out of the live
# framework at runtime rather than from the header (began 1<<0 … mayBegin 1<<5) — all six agree.
#
# BREAK-TESTED: restoring either `if phase.contains(.began) { return 1 }` ladder fires the ban;
# dropping either door call fires the pair loop. Shipped tree: silent on all four.
for pair in \
  "${SWIFT_VIDEO_WINDOW_VIEW}:slopdesk_cg_scroll_phase_code" \
  "${SWIFT_VIDEO_WINDOW_VIEW}:slopdesk_cg_momentum_phase_code"; do
  if ! grep -q "${pair#*:}(" "${pair%%:*}"; then
    fail "${pair%%:*} no longer calls ${pair#*:} — the two phase encodings live in client_gestures.rs"
  fi
done
# The LADDER, not the bit test: `event.phase.contains(.began)` is a legitimate gesture-start check
# and appears here for the pinch planner. What may not come back is a contains-test whose body
# RETURNS A BARE NUMBER, which is the transcription and nothing else.
if hit=$(spells 'contains\(\.(began|changed|ended|cancelled|mayBegin)\) *\{ *return [0-9]' "${SWIFT_VIDEO_WINDOW_VIEW}"); then
  fail "${hit} decodes an NSEvent.Phase mask into a code itself again — hand the raw bits to the door"
fi
# The Rust half: the reprojector must keep READING the table rather than matching bare codes. Its
# `of_platform` is the one place a 3 and a 4 sit next to each other, so a literal there is the
# likeliest way for the two encodings to get crossed.
# BREAK-TESTED: putting `3 => Self::Ended` and `4 | 8 => Self::Ended` back fires; shipped tree silent.
if ! grep -q 'use crate::client_gestures::{' "${RUST_SCROLL_REPROJECT}"; then
  fail "${RUST_SCROLL_REPROJECT} stopped reading the phase table — a bare 3 and a bare 4 mean different fields"
fi
if hit=$(spells '^ *[0-9]+( \| [0-9]+)? *=> *Self::(Ended|Momentum)' "${RUST_SCROLL_REPROJECT}"); then
  fail "${hit} matches a bare phase code again — name it from client_gestures.rs"
fi
# And the table itself stays single: the private per-file copy that lived in `client_gestures` is
# what made this a FOUR-way spelling rather than a three-way one.
# BREAK-TESTED: re-adding `const PHASE_BEGAN: u8 = 1;` fires; shipped tree silent.
if hit=$(spells 'const (PHASE_|MOMENTUM_ENDED)' "${RUST_CLIENT_GESTURES}"); then
  fail "${hit} grew a second private phase table — the exported SCROLL_*/MOMENTUM_* constants are it"
fi

# ---- 6. The encoder's three quantiser knobs CLAMP; they do not reject. ----------------------------
# `SLOPDESK_MAX_QP`, `_CONST_QP` and `_CRISP_QP` each hand-rolled a parse that REJECTED an
# out-of-range value to the knob's default, while `slopdesk_qp_clamped_int` — which every other
# quantiser knob in the tree already goes through — CLAMPS it. One rule, two answers.
#
# Resolved toward CLAMPING, and the reason is that rejecting silently INVERTS the request:
# `SLOPDESK_MAX_QP=0` asks for the sharpest ceiling the encoder has and used to get 51, the coarsest,
# with nothing said. Clamping answers 1. Measured through the linked archive, old → new, for every
# shape a knob can take: absent, empty, in-range, and unparseable are all UNCHANGED; only
# out-of-range moves (MAX_QP `0` 51→1, `99` 51→51; CRISP `0` 18→1, `99` 18→51; CONST_QP `0` OFF→1,
# `99` OFF→51). Presence still decides whether const-QP engages at all, so an absent knob is still
# OFF, and text that is not a number at all still leaves it OFF rather than inventing an operating
# point.
#
# BREAK-TESTED: restoring any of the three `let v = Int(s), v >= 1, v <= 51` guards fires the ban;
# dropping the door call fires the first rule. Shipped tree: silent on both. The fifth knob was
# break-tested separately on 2026-08-22 by pasting its old computed-property form back into
# `WindowCapturer.swift` (`cp` to /tmp and restore, never `git checkout`): the ban FIRED naming line
# 178 and the presence check FIRED with it — two rules on one edit, which is correct here because
# either half alone is the whole regression. Restored, both silent and `diff -q` identical.
#
# SETTLED 2026-08-22, and both halves of the paragraph that used to stand here were wrong.
#
# It said `EnvConfig.int`/`.double` were "the same reject rule for roughly a dozen knobs across
# several targets", and that flipping them to the clamp was therefore a tree-wide behaviour change
# too big to ride along. The count was not a dozen. It was ZERO: the generic pair had no production
# caller anywhere in `Sources/`, only two tests of its own, so there was nothing to flip and no
# behaviour to change. They are deleted.
#
# The reject rule itself is real, though, and it lives in the two files the paragraph never named:
# `LiveCongestionController` and `FPSGovernor` each carried a PRIVATE copy of the same parse. Those
# are not quantiser knobs and they must NOT be clamped — a quantiser ordinal has a meaningful
# nearest legal value, which is the whole argument for section 6's flip, and a malformed rate or
# fraction does not. `SLOPDESK_ABR_LOSS=900` clamped is a controller that treats every frame as
# catastrophic loss forever; rejected, it is the default and a knob that did nothing.
#
# So the tree now carries BOTH readings deliberately, each with exactly one implementation:
#   * CLAMP  — `slopdesk_qp_clamped_int`, `qp_control.rs`, for the [1, 51] quantiser ordinals.
#   * REJECT — `slopdesk_abr_validated_int` / `_double`, `congestion.rs`, for rates and fractions.
# The `_double` form also rejects the non-finite, which no clamp can express: NaN compares false
# against both bounds, so a clamp would pass it straight through into the controller's arithmetic.
#
# Block C below ratchets the second of those. Section 6 continues to ratchet the first.
# The door the face asks changed with the encoder port — `slopdesk_video_encoder_qp_knob` is the
# encoder's own knob entry, and it routes to the same `clamped_int_from_env` the general door does,
# one crate closer to the rules that read the answer. The rule is unchanged: the parse and the clamp
# are the door's.
if ! grep -q 'slopdesk_video_encoder_qp_knob(' "${SWIFT_VIDEO_ENCODER}"; then
  fail "${SWIFT_VIDEO_ENCODER} parses its quantiser knobs itself again — the parse and the clamp are the door's"
fi
# ALL FIVE [1, 51] knobs in this target, named: MAX, CONST, CRISP and COMPACT in the encoder, and
# AQP_MAX in the capturer. The fourth is here because this very gate found it — it was not in the
# brief, it sat ten lines from the other three, and it had the same hand-rolled reject. The FIFTH was
# found the same way, one file over, and is the reason `envQP` is not `private`: there is no version
# of "one rule" where the fifth caller gets its own copy for living in another file. Matched on the
# `environment[...]` read followed by a bare `Int(` parse, which is the shape all five had and none
# of them has now.
SWIFT_WINDOW_CAPTURER=Sources/SlopDeskVideoHost/WindowCapturer.swift
if hit=$(spells 'environment\["SLOPDESK_((MAX|CONST|CRISP|COMPACT)_QP|AQP_MAX)"\], *let v = Int\(' \
  "${SWIFT_VIDEO_ENCODER}" "${SWIFT_WINDOW_CAPTURER}"); then
  fail "${hit} parses a [1,51] quantiser knob by hand again — clamping through the door is the answer the caller can act on"
fi
if ! grep -q 'VideoEncoder\.envQP(' "${SWIFT_WINDOW_CAPTURER}"; then
  fail "${SWIFT_WINDOW_CAPTURER} stopped asking VideoEncoder.envQP for SLOPDESK_AQP_MAX — the fifth knob of the same shape"
fi

# ---- 7. The message-shaped control face stays a WRAPPER. -----------------------------------------
# After the datagram fix its only callers are the state-machine tests, which is the shape the
# one-implementation rule bans — unless it decides nothing, which it does not: it encodes and hands
# over. The gate pins exactly that, so it can neither be deleted as dead nor quietly grown into a
# second transition that only the tests would exercise.
#
# BREAK-TESTED: replacing the body with anything else (an early return, a second effect) fires;
# shipped tree silent.
if ! grep -qE 'handleControl\(datagram: message\.encode\(\)\)' "${SWIFT_VIDEO_SESSION_LOGIC}"; then
  fail "${SWIFT_VIDEO_SESSION_LOGIC}'s message-shaped handleControl stopped delegating — a test-only face that decides"
fi
printf 'check-supervisor: the scroll phases, the quantiser knobs and the control face each decide in one place.\n'

# ── The four defaults the SETTINGS SHEET shows, against the ones the encoder runs ────────────────
# `VideoPreferences` names what each surfaced field resolves to while it is `nil`, under a doc
# comment that forbids literals there in as many words — and four of them were literals anyway:
# `26`, `40`, `1`, `5`, against `qp_control.rs`'s sharp/coarse and `adaptive_fec.rs`'s default m
# and k. Every one of those already had a door.
#
# The failure mode is quiet and ASYMMETRIC, which is why it is worth a gate rather than a comment.
# A retune moves the encoder's operating point; Settings goes on showing the old number, which is
# merely wrong. But "reset to default" WRITES the shown number into the env overlay as an explicit
# override — so the gesture whose entire purpose is to get out of the daemon's way is the one that
# pins the daemon to a value nobody ever chose, and it stays pinned across restarts.
#
# Index 11 is the multi-loss default m and is deliberately not index 7, which is `M_MIN`. They are
# both 1 today and that coincidence is exactly how this one regrew: a reader who sees the floor
# answer the same number stops looking for the door that answers the question actually being asked.
#
# BREAK-TESTED 2026-08-22 by pasting `public static let fecMDefault = 1` back (`cp` to /tmp,
# restore from the copy):
#   check-supervisor: FAIL — Sources/SlopDeskVideoProtocol/Settings/VideoPreferences.swift spells a QP or FEC default as a literal again — those four numbers are the encoder's, and "reset to default" writes whatever this file shows
# Deleting the `slopdesk_adaptive_fec_constant` calls fires the presence rule instead. Shipped tree
# silent on both; `diff -q` identical after restore.
SWIFT_VIDEO_PREFERENCES=Sources/SlopDeskVideoProtocol/Settings/VideoPreferences.swift
for door in slopdesk_qp_config_default slopdesk_adaptive_fec_constant; do
  if ! spells "${door}\\(" "${SWIFT_VIDEO_PREFERENCES}" > /dev/null; then
    fail "${SWIFT_VIDEO_PREFERENCES} no longer asks ${door} — the settings sheet's defaults are the encoder's"
  fi
done
# The four fields by NAME, each banned from being assigned a bare number. Named individually rather
# than matched as "any `= <digit>` in this file" because the file legitimately holds other numeric
# defaults that are its own; only these four mirror a door.
if hit=$(spells '(qpSharpDefault|qpCoarseDefault|fecMDefault|fecKDefault)[^=]*= *[0-9]' \
  "${SWIFT_VIDEO_PREFERENCES}"); then
  fail "${hit} spells a QP or FEC default as a literal again — those four numbers are the encoder's, and \"reset to default\" writes whatever this file shows"
fi

# ── The REJECT reading of an env knob: one rule, and it is Rust's ────────────────────────────────
# Section 6 above settled the CLAMP reading for the quantiser ordinals. This is the other reading,
# for the rates and fractions, and it had three implementations: a generic pair in `EnvConfig` with
# no callers at all, and a private copy inside each of these two files. See the note in section 6
# for why the two readings do not converge.
#
# `FPSGovernor`'s copy carried a second bug on top of the duplication, and it is the one that would
# have been reported as "the setting does nothing": it read `ProcessInfo.processInfo.environment`
# DIRECTLY, bypassing `EnvConfig`'s overlay, so every governor tunable set through the settings
# sheet was written, persisted, shown as active — and never read. `LiveCongestionController`'s copy
# went through `EnvConfig` and was therefore only duplicated, not deaf. Both now resolve the same
# way and parse through the same door.
#
# The ban is on the PARSE-THEN-COMPARE shape all three copies had, `Int(s), v >= lo`, rather than on
# a door's absence — a file can keep calling the door and grow a second private parse beside it,
# which is how the third copy appeared in the first place.
#
# BREAK-TESTED 2026-08-22, each rule separately (`cp` to /tmp, break, run, restore from the copy):
#   * dropping the door call from FPSGovernor.swift —
#     check-supervisor: FAIL — Sources/SlopDeskVideoHost/FPSGovernor.swift no longer asks slopdesk_abr_validated_int — the reject rule is congestion.rs's
#   * restoring the raw `ProcessInfo.processInfo.environment[key]` read —
#     check-supervisor: FAIL — Sources/SlopDeskVideoHost/FPSGovernor.swift reads the process environment directly again — that bypasses the settings overlay, which is how a governor tunable set in Settings came to do nothing
#   * pasting `guard let v = Int(s), v >= lo, v <= hi else { return def }` back into EnvConfig.swift —
#     check-supervisor: FAIL — Sources/SlopDeskVideoProtocol/Settings/EnvConfig.swift parses a numeric env knob by hand again — the reject rule is slopdesk_abr_validated_int/_double and the clamp rule is slopdesk_qp_clamped_int
# Shipped tree silent on all three.
SWIFT_ABR_CONTROLLER=Sources/SlopDeskVideoHost/LiveCongestionController.swift
SWIFT_FPS_GOVERNOR=Sources/SlopDeskVideoHost/FPSGovernor.swift
SWIFT_ENV_CONFIG=Sources/SlopDeskVideoProtocol/Settings/EnvConfig.swift
for numeric_env_caller in "${SWIFT_ABR_CONTROLLER}" "${SWIFT_FPS_GOVERNOR}"; do
  for door in slopdesk_abr_validated_int slopdesk_abr_validated_double; do
    if ! spells "${door}\\(" "${numeric_env_caller}" > /dev/null; then
      fail "${numeric_env_caller} no longer asks ${door} — the reject rule is congestion.rs's"
    fi
  done
done
# The overlay, not the process environment. `EnvConfig.string` is the only legal reader here: it is
# real env FIRST, then the settings overlay, then the compile-time default, and a knob that skips it
# can be set but never takes effect.
if hit=$(spells 'ProcessInfo\.processInfo\.environment' "${SWIFT_FPS_GOVERNOR}"); then
  fail "${hit} reads the process environment directly again — that bypasses the settings overlay, which is how a governor tunable set in Settings came to do nothing"
fi
# The parse itself, banned in all three files that have held a copy of it.
if hit=$(spells '(Int|Double)\([a-zA-Z_]+\), *[a-zA-Z_]+ *(>=|<=|>|<) ' \
  "${SWIFT_ABR_CONTROLLER}" "${SWIFT_FPS_GOVERNOR}" "${SWIFT_ENV_CONFIG}"); then
  fail "${hit} parses a numeric env knob by hand again — the reject rule is slopdesk_abr_validated_int/_double and the clamp rule is slopdesk_qp_clamped_int"
fi
# And the generic pair stays deleted, tree-wide. It is spelled as a CALL rather than as a
# declaration so that re-adding it anywhere — a helper, an extension, a test fake — is caught by its
# first user rather than by its author.
#
# With a VACUITY FLOOR, because `spells` returns 1 on an empty file list and an empty corpus is
# indistinguishable from a clean one at the call site. This corpus is the whole Swift tree, so if it
# ever reads as fewer than 200 files the glob has gone stale and this gate is passing on nothing.
env_config_corpus=$(repo_files 'Sources/**/*.swift' 'Tests/**/*.swift')
if (($(printf '%s\n' "${env_config_corpus}" | grep -c .) < 200)); then
  fail "the tree-wide Swift corpus read as almost nothing — the EnvConfig ban below is passing vacuously"
fi
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
# shellcheck disable=SC2086 # the corpus is a FILE LIST on purpose
if hit=$(spells 'EnvConfig\.(int|double)\(' ${env_config_corpus}); then
  fail "${hit} calls EnvConfig.int/.double again — that generic reject pair had zero callers and is deleted; ask a door"
fi

# ── The audio row, which is Rust's from the capture tap to the speakers ─────────────────────────
# This started as ONE rule about ONE loop: `AudioStreamDecoder.decodePCM` and
# `slopdesk_video::audio_wire::decode_pcm_s16le` were the same s16le widen byte for byte, down to
# the same validate-then-DROP rule for a ragged tail, and the Rust half had no caller outside its
# own tests. What made that pair need a gate rather than a note is that it CANNOT be caught
# disagreeing: a full-scale sample is `-1.0` either way, and a drifted normalisation is just audio
# that is slightly quieter than it should be. Nobody files that.
#
# The rest of the row turned out to be the same shape at a larger size. Four Swift files — an
# `AudioConverter` encoder, an `AudioConverter` decoder, an `AUHAL`/`RemoteIO` output unit and a
# lock-free ring with a pump around it — were about 1200 lines, of which the part that HAD to be
# Swift was none. They are `rust/slopdesk-apple-audio` and `rust/slopdesk-audio-out` now, and what
# is left in Swift is three faces that marshal.
#
# So the gate is on the FACES: each must still ask its door, and none may import an audio framework
# again, because an `import AudioToolbox` in one of these files is what a re-implementation starts
# as. The ban list is the frameworks rather than the code shapes, which is both narrower to write
# and impossible to satisfy while re-growing the loop.
#
# BREAK-TESTED 2026-08-23 (`cp` to /tmp, restore from the copy): adding `import AudioToolbox` to
# `AudioStreamDecoder.swift` fires
#   check-supervisor: FAIL — Sources/SlopDeskVideoClient/AudioStreamDecoder.swift imports an audio framework again — the AudioToolbox calls are slopdesk-apple-audio's
# and deleting the `slopdesk_audio_decoder_decode(` call fires the presence rule. Shipped tree
# silent on both.
declare -A audio_faces=(
  ["Sources/SlopDeskVideoHost/AudioStreamEncoder.swift"]='slopdesk_audio_encoder_push_sample_buffer\('
  ["Sources/SlopDeskVideoClient/AudioStreamDecoder.swift"]='slopdesk_audio_decoder_decode\('
  ["Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift"]='slopdesk_audio_player_enqueue\('
)
for face in "${!audio_faces[@]}"; do
  if [[ ! -e "${face}" ]]; then
    fail "audio_faces names ${face}, which does not exist — the face moved and this ledger did not"
  fi
  if ! spells "${audio_faces[${face}]}" "${face}" > /dev/null; then
    fail "${face} stopped asking its door — the audio row's calls are slopdesk-apple-audio's and slopdesk-audio-out's"
  fi
  if hit=$(spells '^import (AudioToolbox|AudioUnit|CoreAudio|AVFAudio)$' "${face}"); then
    fail "${hit} imports an audio framework again — the AudioToolbox calls are slopdesk-apple-audio's"
  fi
done

# The ring, the pump and the Swift stage face went with them, and the paths are the unambiguous
# fact — a re-added `AudioJitterBuffer.swift` would carry whatever names its author picked.
declare -a audio_gone=(
  Sources/SlopDeskVideoClient/AudioJitterBuffer.swift
  Tests/SlopDeskVideoClientTests/AudioJitterBufferTests.swift
  Tests/SlopDeskVideoClientTests/AudioSampleRingTests.swift
  Tests/SlopDeskVideoClientTests/AudioPlaybackPumpTests.swift
)
for gone in "${audio_gone[@]}"; do
  if [[ -e "${gone}" ]]; then
    fail "${gone} is back — the jitter stage, its ring and its pump are rust/slopdesk-audio-out"
  fi
done

# ── The two length prefixes, and the sentinel that a signed `Int` swallowed ──────────────────────
# `ScreenClient.exchange` shifted four untrusted bytes together by hand, checked them against a
# 64 MiB ceiling re-spelled one file over, and then allocated that much. It is the highest-risk
# hand-written parse either lane had: the one field on this wire a peer fully controls, deciding how
# much memory this process commits. `rust/slopdesk-screenwire` owned the ENCODER for it the whole
# time. It asks now.
#
# The second half of this gate is the trap that made the first half worth doing properly.
# `SupervisorFrame.read` already asked its door — `slopdesk_supervisor_body_length` — and then
# guarded the refusal with `count != .max`, which NEVER FIRED. Swift's ClangImporter maps `size_t`
# onto the SIGNED `Int`, so the door's all-ones refusal arrives as `-1` while `.max` infers
# `Int.max`; the two never met, and an over-cap header fell through to `readExactly(count: -1)`.
# Measured with a scratch C target on 2026-08-22 rather than reasoned about: a function returning
# `(size_t)-1` types as `Int`, prints `-1`, and `== .max` is `false`. The guard is `>= 0` now.
#
# So the screen door refuses with `0` instead, deliberately, and that asymmetry is the design: a
# reply of zero bytes is not a thing on this wire, `0` is unrepresentable as a real length, and `> 0`
# is a check that needs no knowledge of how `size_t` crosses. The supervisor lane cannot take the
# same refusal — an empty body IS legal there — which is why it keeps the sentinel and gets a
# ratchet on the guard instead.
#
# BREAK-TESTED 2026-08-22, each separately (`cp` to /tmp, restore from the copy):
#   * restoring the hand-shifted prefix in ScreenClient.swift —
#     check-supervisor: FAIL — Sources/SlopDeskScreen/ScreenClient.swift shifts a length prefix together by hand again — an untrusted length decides an allocation, and screenwire owns that layout
#   * putting `guard count != .max` back in SupervisorFrame.swift —
#     check-supervisor: FAIL — Sources/SlopDeskSupervisor/SupervisorFrame.swift compares a door's size_t answer against .max again — size_t reaches Swift as the SIGNED Int, so an all-ones refusal arrives as -1 and that guard never fires
#   * returning `usize::MAX` from the screen door —
#     check-supervisor: FAIL — rust/slopdesk-ffi/src/screen.rs refuses with usize::MAX again — that sentinel reaches Swift as -1; this door refuses with 0
# Shipped tree silent on all three.
SWIFT_SCREEN_CLIENT=Sources/SlopDeskScreen/ScreenClient.swift
SWIFT_SUPERVISOR_FRAME=Sources/SlopDeskSupervisor/SupervisorFrame.swift
RUST_SCREEN_FFI=rust/slopdesk-ffi/src/screen.rs
if ! spells 'slopdesk_screen_body_length\(' "${SWIFT_SCREEN_CLIENT}" > /dev/null; then
  fail "${SWIFT_SCREEN_CLIENT} stopped asking the door for the reply length — that prefix is untrusted and screenwire owns its layout"
fi
# The hand-rolled decode: a byte-shift ladder, or `bigEndian`/`UInt32` reassembly off the header.
if hit=$(spells '<< *24|<< *16|bigEndian|UInt32\(header' "${SWIFT_SCREEN_CLIENT}"); then
  fail "${hit} shifts a length prefix together by hand again — an untrusted length decides an allocation, and screenwire owns that layout"
fi
# The sentinel comparison, in both files that read a `size_t` answer off a door. `>= 0` is the
# spelling that works; `!= .max` is the spelling that compiles, reads correctly, and does nothing.
if hit=$(spells '(!=|==) *\.max' "${SWIFT_SUPERVISOR_FRAME}" "${SWIFT_SCREEN_CLIENT}"); then
  fail "${hit} compares a door's size_t answer against .max again — size_t reaches Swift as the SIGNED Int, so an all-ones refusal arrives as -1 and that guard never fires"
fi
# Also through `spells`: the paragraph above this guard, in the Swift, spells out the wrong version
# and why it was wrong. A `grep` here would be reading the explanation, not the code.
if ! spells 'count >= 0' "${SWIFT_SUPERVISOR_FRAME}" > /dev/null; then
  fail "${SWIFT_SUPERVISOR_FRAME} stopped guarding its body length with >= 0 — the door's refusal arrives as a negative Int, not as .max"
fi
# And the Rust end of the screen lane keeps refusing with a value that survives the crossing.
# Through `spells` rather than `grep`, because the doc comment on this very door EXPLAINS why it
# does not use that sentinel, in those words. A gate that could not tell the explanation from the
# thing explained would have to be deleted the first time anyone read it.
if hit=$(spells 'usize::MAX' "${RUST_SCREEN_FFI}"); then
  fail "${hit} refuses with usize::MAX again — that sentinel reaches Swift as -1; this door refuses with 0"
fi

printf 'check-supervisor: the settings defaults, the two env readings, the PCM convert and both length prefixes each decide in one place.\n'

# ── ClientCore / WorkspaceModel: the projections that must stay ASKED and stay MEMOIZED ─────────
#
# Four blocks, nine arms, all from one sweep, all pinning defects that NO test can see. Each is a
# projection that is correct at every size and only wrong in the clock — which is why a ratchet and
# not a test is the instrument. Every arm below was break-tested against the real tree and its
# verdict recorded. The measurements are `swiftc -O` against the shipped staticlib, two runs
# agreeing inside 4% each.

# 1. THE DOCUMENT'S CANONICAL ORDER — one rule, and it lives in `slopdesk_wire::document::state`,
#    where a `BTreeMap`'s key order IS the wire's emission order. Swift's mirror is a `Dictionary`
#    with no order at all, so it used to DERIVE the same order: a hand-written `Comparable` over
#    `(kind, objectID bytes, field)` whose comparator materialised a fresh 16-byte `[UInt8]` per
#    SIDE per comparison. One `sortedEntries` on a 24-pane / 480-cell document therefore ran ~8,600
#    heap allocations for a question about eighteen bytes at a time: the sort alone 1,018 µs, now
#    23 µs through the door; `sortedEntries` end to end 1,075 µs → 77 µs; at 64 panes 2,334 → 219 µs.
#    The FAILURE MODE is the reason this is pinned rather than merely fixed: two orders never
#    disagree loudly, they RE-EMIT. A snapshot stops being byte-deterministic, a diff churns on
#    dictionary iteration order, and every frame of that reads downstream exactly like a real change.
#    BREAK-TESTED, three ways, each restored from a `/tmp` copy: re-adding `Comparable` to the
#    struct fires the spell ban; deleting `diff`'s `deletes` call site drops the count to 3 and fires
#    the count arm (it did NOT fire before the comment strip — the doc comments name the door twice,
#    which is the whole reason `spells` strips); renaming the door in the bridge fires the first.
SWIFT_WS_STATE=Sources/SlopDeskWorkspaceModel/State/HostWorkspaceState.swift
SWIFT_WS_BRIDGE=Sources/SlopDeskWorkspaceModel/WorkspaceSolverBridge.swift
if ! grep -q 'slopdesk_ws_key_order(' "${SWIFT_WS_BRIDGE}"; then
  fail "${SWIFT_WS_BRIDGE} no longer calls slopdesk_ws_key_order — the emission order is slopdesk-wire's"
fi
# FOUR call sites — `sortedEntries`, `keys(ofKind:objectID:)`, and `diff`'s two lists. Counted with
# comments stripped, for `spells`' reason: the doc comments above these functions name the door too,
# and a count that includes prose passes while the last real call site is being deleted.
WS_ORDER_CALLS=$(sed -E 's,//.*,,' "${SWIFT_WS_STATE}" | grep -c 'wsKeyOrder(' || true)
if ((WS_ORDER_CALLS < 4)); then
  fail "${SWIFT_WS_STATE} asks wsKeyOrder ${WS_ORDER_CALLS} times, not 4 — an ordered answer went back to deriving its own"
fi
# What a re-implementation grows back: the conformance, the byte array the comparator allocated, the
# hand-written `<`, and the `.sorted()` that only compiles once one of them is back.
if grep -qE 'struct WorkspaceKey[^{]*Comparable|objectIDBytes|static func < *\(|entries\.keys\.sorted\(\)|keys\.sorted\(\)' "${SWIFT_WS_STATE}"; then
  fail "${SWIFT_WS_STATE} derives the emission order again — that order is slopdesk_wire::document::state's, asked through wsKeyOrder"
fi
printf 'check-supervisor: the workspace document has one emission order, and Swift asks for it.\n'

# 2. `persisting` MUST NOT ORDER. It reduces the document to what belongs on disk and returns a
#    `HostWorkspaceState` — an unordered map — so it used to spend a whole canonical ordering of
#    every cell (~1 ms at 24 panes before the port, 77 µs after) and drop the result into a
#    `Dictionary` on the very next line. `WorkspaceCacheStore` calls it inside `encodeSnapshot`,
#    which orders again, so the discarded pass was paid on every save. `encode` below it reads
#    `sortedEntries` legitimately, which is why this bans it in the FUNCTION and not the file.
#    BREAK-TESTED twice: restoring `for entry in state.sortedEntries where isPersisted(entry.key)`
#    fires the sort arm, and renaming the function fires the EMPTY arm rather than passing silently
#    — which is `same`'s lesson, since `sed -n` exits 0 on no match.
SWIFT_WS_FILE=Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateFile.swift
WS_PERSISTING=$(sed -n '/static func persisting(/,/^    }$/p' "${SWIFT_WS_FILE}")
if [[ -z "${WS_PERSISTING}" ]]; then
  fail "${SWIFT_WS_FILE}: the persisting() extraction in this gate read EMPTY and has stopped checking anything"
elif grep -q 'sortedEntries' <<< "${WS_PERSISTING}"; then
  fail "${SWIFT_WS_FILE}: persisting() orders the document again — its answer is an unordered map, so the order is thrown away on the next line"
elif ! grep -q 'in state\.entries where isPersisted' <<< "${WS_PERSISTING}"; then
  fail "${SWIFT_WS_FILE}: persisting() no longer walks state.entries directly — the filter reads neither the object id nor the value"
fi
printf 'check-supervisor: the persisted subset is a filter, not a sort.\n'
# PORTED to `rust/slopdesk-invariants` — `rules::hot_paths`: palette-ranking. The loop here
# interpolated its item INTO the pattern, so it was never a list of names — it is one claim per
# reader, each with the reader substituted in, which is what the shell was doing all along. The
# path stays: sections below still name it.
SWIFT_OVERLAYS=Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift

# 4. THE PALETTE CATALOG IS INDEXED, NOT RESCANNED. `items(in:)` was `allRows.filter { $0.category
#    == category }`, so one zero-state build ran eight full passes over ~90 rows and minted eight
#    arrays; `recentPaletteItems()` linear-scanned `allRows` once per remembered id. Both are now
#    `static let` dictionaries built once. Measured on the whole zero-state build: 8.06–8.22 µs →
#    2.53–2.86 µs. BREAK-TESTED three ways: restoring the `allRows.filter` in `items(in:)` fires the
#    scan arm, renaming `rowsByID` fires the index arm, and restoring the `allRows.first(where:)` in
#    the coordinator fires the third. Named files, so `spells` vacuity is not in play.
SWIFT_PALETTE=Sources/SlopDeskClientCore/Palette/PaletteDataSource.swift
if ! grep -q 'static let rowsByCategory' "${SWIFT_PALETTE}" || ! grep -q 'static let rowsByID' "${SWIFT_PALETTE}"; then
  fail "${SWIFT_PALETTE} lost an index — items(in:) and the recents lookup would each be a fresh scan of allRows"
fi
if grep -qE 'allRows\.filter|allRows\.first\(where:' "${SWIFT_PALETTE}"; then
  fail "${SWIFT_PALETTE} scans allRows again — the categories and the ids are both indexed once at load"
fi
if grep -q 'ActionsPaletteSource.allRows.first(where:' "${SWIFT_OVERLAYS}"; then
  fail "${SWIFT_OVERLAYS} scans the palette catalog per remembered id — ActionsPaletteSource.rowsByID answers in one lookup"
fi
printf 'check-supervisor: the palette catalog is indexed once, not filtered per read.\n'
# PORTED to `rust/slopdesk-invariants` — `rules::hot_paths`: nerd-font-splitter.

# 6. THE SETTINGS SECTION SEARCH IS THE TAXONOMY'S OWN RULE. `SettingsCatalog.sections` has crossed
#    the boundary since it was written; the SEARCH over it had not, so each face wrote its own
#    `lowercased().contains(…)` over the answer. That is `docs/55` §8's drift class, and §8's point is
#    that this class is NOT ranked by cost — eight sections filtered per keystroke is ~750 ns and
#    would never on its own justify a door. What justifies it is that the question stops having two
#    answers. The needle crosses RAW, which is the load-bearing half of this rule: a caller that
#    lowercases or trims first has re-spelled the fold it was supposed to stop spelling.
#    BREAK-TESTED three ways: renaming the door in the bridge fires the call arm; making
#    `sections(matching:)` pre-lowercase fires the raw-needle arm; re-adding a
#    `SettingsCatalog.sections.filter { $0.title.lowercased()… }` anywhere under Sources/ fires the
#    corpus arm — including at the MacUI call site, which is where the fourth spelling lived.
#
#    The corpus arm was RED for the length of the change and that was the point. `MacSettingsNavigator`
#    held the FOURTH spelling and lives outside the target this rule came from, so the rule fired on
#    the shipped tree until that call site landed centrally. It stays armed over the whole of
#    `Sources/` rather than scoped to ClientCore BECAUSE the fourth spelling is the finding: a rule
#    that only watched ClientCore would have passed on the day the drift started.
SWIFT_SETTINGS_CATALOG=Sources/SlopDeskClientCore/Settings/SettingsCatalog.swift
if ! grep -q 'slopdesk_settings_sections_matching(' "${SWIFT_SETTINGS_CATALOG}"; then
  fail "${SWIFT_SETTINGS_CATALOG} no longer calls slopdesk_settings_sections_matching — the search over the taxonomy is slopdesk-workspace's"
fi
SETTINGS_MATCHING=$(sed -n '/static func sections(matching/,/^    }$/p' "${SWIFT_SETTINGS_CATALOG}")
if [[ -z "${SETTINGS_MATCHING}" ]]; then
  fail "${SWIFT_SETTINGS_CATALOG}: the sections(matching:) extraction in this gate read EMPTY and has stopped checking anything"
elif grep -qE 'lowercased\(\)|trimmingCharacters' <<< "${SETTINGS_MATCHING}"; then
  fail "${SWIFT_SETTINGS_CATALOG}: sections(matching:) folds the needle before sending it — the fold is the far side's, and folding twice is the rule spelled twice"
fi
SECTION_REFILTER=$(grep -rlE 'SettingsCatalog\.sections[^)]*\.filter' Sources/ 2> /dev/null || true)
if [[ -n "${SECTION_REFILTER}" ]]; then
  fail "a face filters SettingsCatalog.sections itself (${SECTION_REFILTER}) — ask SettingsCatalog.sections(matching:), which is the taxonomy's own search"
fi
printf 'check-supervisor: the settings taxonomy and the search over it are one rule.\n'
# PORTED to `rust/slopdesk-invariants` — `rules::workspace_layout`: rail-badge-gates. A
# PERFORMANCE claim, kept the way the shell kept it: the measurement is in the rule's doc and
# what is enforced is that the call site which earned it still exists.

# 8. NO PRODUCTION API EXISTS FOR A TEST'S SAKE. `SearchMixer.availableFilters` was a `public var`
#    whose only reader anywhere in the tree — after the Mac and phone sweeps both finished without
#    adding one — was a single assertion in `OverlayCoordinatorMountTests`. Under the
#    one-implementation rule that is a hook held open, so it is deleted and the test now reads the
#    same fact off what the mixer PRODUCES, where a user could also see it.
#    BREAK-TESTED: re-declaring the property fires; the grep is over the whole Swift tree, so it
#    fires wherever it comes back rather than only in the file it left.
FILTERS_HOOK=$(grep -rln 'var availableFilters' Sources/ 2> /dev/null || true)
if [[ -n "${FILTERS_HOOK}" ]]; then
  fail "availableFilters is back (${FILTERS_HOOK}) — it had exactly one reader, a test; assert on the zero state the mixer renders instead"
fi
printf 'check-supervisor: no palette API exists only for a test to read.\n'

#
# ── MacUI: the nine memoizations that a redraw path must keep ─────────────────────────────────
#
# WHY THESE ARE HERE AND NOT IN A TEST. Every rule below pins a HELD value — a cache, a guard, a
# stored list — whose absence changes nothing a test can see. The view draws the same pixels, the
# same rows come back, the same seam moves; only the clock moves, and only on the paths AppKit
# drives at the display's rate (a divider drag, a live window resize, a `CADisplayLink` tick, a
# keystroke in an overlay). That is the shape docs/55 §8 catalogues: a fact re-derived because
# re-deriving it looked free at the call site. A green suite is exactly what a regression here
# looks like, so the pin has to be textual.
#
# WHAT THE NUMBERS BELOW ARE. Measured on this machine against the shipped xcframework under
# `swiftc -O`, two agreeing runs each, with the FFI door floor (1.7 ns) as the unit of "free".
#
# Each rule names the redraw path, the measurement, and — in its break-test verdict — the exact
# edit that was applied to the real tree to prove the rule fires, and that the file was restored
# from a /tmp copy rather than from git (never `git checkout` a file with uncommitted work).

MACUI_HEADER=Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift
MACUI_OPENQ=Sources/SlopDeskMacUI/Overlays/MacOpenQuickly.swift
MACUI_CANVAS=Sources/SlopDeskMacUI/Pane/MacSplitCanvasView.swift
MACUI_GUILEAF=Sources/SlopDeskMacUI/Pane/MacGuiLeafView.swift
MACUI_CONTAINER=Sources/SlopDeskMacUI/Pane/MacPaneContainer.swift
MACUI_DISPATCH=Sources/SlopDeskMacUI/Input/WorkspaceKeyDispatcher.swift
MACUI_PLATE=Sources/SlopDeskMacUI/Panel/MacPlateIconButton.swift
MACUI_GLYPH=Sources/SlopDeskMacUI/Overlays/MacAgentGlyph.swift
MACUI_MARK=Sources/SlopDeskMacUI/Columns/MacStatusMark.swift
MACUI_DIVIDER=Sources/SlopDeskMacUI/Pane/MacPaneDivider.swift

# ---- M1. The sidebar's git line stays MEASURED, not re-measured. -----------------------------
# THE PATH: `MacGitLineView` picks between an inline spelling and a four-rung ladder by asking each
# candidate how wide it is, and AppKit asks for `intrinsicContentSize` and `draw(_:)` on every
# layout pass of the sidebar — a window resize, a sidebar drag, a row insertion.
# THE MEASUREMENT: the shedding `draw` was 59–65 µs and `intrinsicContentSize` 16.8–17.5 µs, both
# of them `NSAttributedString.size()` (2.0–2.3 µs each, full CoreText typesetting) over five to
# nine candidates. Building the ladder ONCE costs 50–52 µs; every read after it is 5 ns.
# CATCHES: the ladder being deleted, or `measured()` being inlined back into the two callers.
if ! grep -q 'private var ladder: Ladder?' "${MACUI_HEADER}"; then
  fail "${MACUI_HEADER} no longer holds its measured ladder — the git line would re-typeset five to \
nine candidate strings on every AppKit layout pass (59–65 µs) to pick the one it already picked"
fi
if ! grep -q 'private func measured() -> Ladder?' "${MACUI_HEADER}"; then
  fail "${MACUI_HEADER} lost measured() — intrinsicContentSize and draw(_:) must share ONE build of \
the ladder, or the guard above buys nothing"
fi
# The ladder is `segments` measured, so it must die with them and with nothing else. A didSet that
# rebuilds the segments without dropping the ladder serves the OLD branch name forever.
if ! grep -q 'ladder = nil' "${MACUI_HEADER}"; then
  fail "${MACUI_HEADER} never invalidates the ladder — a memo with no kill is a stale git line, \
which is worse than the 62 µs it saves"
fi
# BREAK-TESTED: `ladder` renamed to `ladderCache` in the real file (cp to /tmp first, restored from
# there) → all three rules fired, naming the file and the 59–65 µs. Restored, gate green.

# ---- M2. Open Quickly builds its corpus ONCE per draw. ---------------------------------------
# THE PATH: `sections(filter:)` walks every session, tab and pane, spends a `TreeWorkspace.spec`
# DFS per pane, re-ranks the whole folder frecency history and runs five fuzzy passes. The shipped
# `draw()` ran it twice — once for the display entries, once through a `selectableRows(filter:)`
# METHOD — and `move`, `moveToEnd`, `setActions`, `actSelected` and every ⌘-digit ran a third.
# CATCHES: the method growing back. It is also the CORRECT shape, not just the cheap one: a clamp
# or a ⌘-digit resolved against a freshly-derived corpus answers about rows the user is not looking
# at, because the corpus can have moved under the selection since the draw that showed it.
if spells 'func selectableRows\(' "${MACUI_OPENQ}" > /dev/null; then
  fail "${MACUI_OPENQ} derives its selectable rows again — they are the HELD result of the draw \
that put them on screen; a keystroke must clamp against the list the user can see, not a new one"
fi
if ! grep -q 'private var selectableRows: \[OpenQuicklyItem\]' "${MACUI_OPENQ}"; then
  fail "${MACUI_OPENQ} no longer holds selectableRows — see the ban above for why the held list is \
the correct one and not merely the fast one"
fi
# BREAK-TESTED: the stored property replaced with `private func selectableRows(filter: String) ->
# [OpenQuicklyItem] { OpenQuicklyModel.selectable(sections(filter: filter)) }` → both rules fired.

# ---- M3. The canvas remembers which leaves are unthemed. -------------------------------------
# THE PATH: `applyHandles` asked `store.tree.spec(for: leaf.id)?.kind == .desktop` per leaf, and it
# runs per divider-drag frame, per live-resize frame and per pointer move of a pane drag. `spec` is
# a full DFS of the split tree, so the cost is O(panes²) per frame for an answer that is FIXED for
# the life of a pane id.
# CATCHES: the cache going away, and — separately — the cache never being pruned, which would keep
# a closed pane's answer alive against a reused id.
if ! grep -q 'handleIsUnthemed' "${MACUI_CANVAS}"; then
  fail "${MACUI_CANVAS} asks the tree for each leaf's kind again — that is a DFS per leaf per drag \
frame for an answer fixed for the life of the pane id"
fi
if ! grep -q 'handleIsUnthemed\[id\] = nil' "${MACUI_CANVAS}"; then
  fail "${MACUI_CANVAS} keeps unthemed answers for panes it has removed — the cache must be pruned \
in the same loop that tears the handle down"
fi
# BREAK-TESTED: the pruning line deleted → the second rule fired alone, which is the point of
# splitting it from the first.

# ---- M4. The GUI leaf remembers its pane KIND, and only that. --------------------------------
# THE PATH: `isDesktopUploadTarget` ran a full tree DFS inside `draggingUpdated(_:)`, which AppKit
# fires on every pointer move of a drag over the pane.
# THE SHAPE THAT MATTERS: only the KIND is held — it is fixed for the life of a pane id. The
# liveness half (`model?.active != nil`) stays a fresh read on every call, and a `nil` kind is
# deliberately NOT cached, so a leaf that asks before its spec lands is not stuck answering no.
if ! grep -q 'cachedPaneKind' "${MACUI_GUILEAF}"; then
  fail "${MACUI_GUILEAF} walks the split tree inside a drag-update again — cache the KIND (fixed \
per pane id), never the liveness"
fi
# BREAK-TESTED: `cachedPaneKind` renamed → fired.

# ---- M5. The container counts its tab's panes without building T arrays. ---------------------
# THE PATH: `tabPaneCount` is read inside the `withObservationTracking` arm that observes
# `store.paneSwitcher`, so EVERY mounted container re-runs it on every ⌃⇥ tap. The shipped spelling
# was `tabs.first { $0.allPaneIDs().contains(paneID) }`, which allocates one array per tab per pane
# per keypress before it can even test membership; `Tab.contains` answers without the array.
if spells 'allPaneIDs\(\)\.contains\(paneID\)' "${MACUI_CONTAINER}" > /dev/null; then
  fail "${MACUI_CONTAINER} allocates a pane-id array per tab just to test membership — ask \
Tab.contains, which is the same question without the allocation, on a ⌃⇥ path that runs it per \
mounted pane per keypress"
fi
# BREAK-TESTED: the old predicate restored verbatim → fired.

# ---- M6. The terminal reach is a set, not a linear scan built per keystroke. ------------------
# CATCHES: the two-chord array coming back. It is rebuilt on every key event otherwise, which is
# the one path in this directory where the user is watching the latency directly.
if ! grep -q 'private static let terminalReach: Set<KeyChord>' "${MACUI_DISPATCH}"; then
  fail "${MACUI_DISPATCH} rebuilds its code-panel chord list per key event — it is a static Set"
fi
# BREAK-TESTED: `Set<KeyChord>` changed to `[KeyChord]` → fired.

# ---- M7. The plate button guards its glyph name like its other two states. -------------------
# THE PATH: the GUI control bar assigns all four of its glyph names unconditionally from
# `applyChrome`, which re-fires whenever any of the stream's ten telemetry mirrors move — about
# twice a second for the life of a stream. Ungated, that re-rendered four SF Symbol images per
# tick, every one byte-identical to the one already on screen.
# CATCHES: the guard being dropped while `active` and `enabled` keep theirs, which is exactly how
# it was missing in the first place — the two that looked like state got one and the one that
# looked like a plain string did not.
if ! grep -q 'guard symbolName != oldValue else { return }' "${MACUI_PLATE}"; then
  fail "${MACUI_PLATE} re-renders its SF Symbol on every assignment — symbolName carries the same \
equality guard as active and enabled, for a caller that assigns it ~2 Hz forever"
fi
# BREAK-TESTED: the guard line deleted → fired.

# ---- M8. Both spinners fill their dots through CoreGraphics. ---------------------------------
# THE PATH: both draws are driven by a `CADisplayLink`, so the loop runs once per dot per mark per
# display refresh — and the rail can hold a mark per session.
# THE MEASUREMENT: eight dots cost 28.6 µs/frame through `NSBezierPath(ovalIn:).fill()` and
# 21.8–23.2 µs through `context.fillEllipse(in:)` — one `NSBezierPath` allocation per dot per
# frame, gone. `setFillColor(red:green:blue:alpha:)` measured faster still (16.1–16.9 µs) and is
# REFUSED on purpose: it would resolve the ink in a different colour space than
# `withAlphaComponent(_:).setFill()`, which is a pixel change, not an optimisation.
# Through `spells`, not `grep`: both files NAME the rejected spelling in the comment that records
# the measurement, and a ban that fires on its own rationale is a ban nobody can satisfy.
for spinner in "${MACUI_GLYPH}" "${MACUI_MARK}"; do
  if spells 'NSBezierPath\(ovalIn:' "${spinner}" > /dev/null; then
    fail "${spinner} allocates an NSBezierPath per dot per display-link frame (28.6 µs vs 22 µs for \
eight dots) — fill the ellipse on the context"
  fi
done
# BREAK-TESTED: `context.fillEllipse(in: frame)` swapped back to
# `NSBezierPath(ovalIn: frame).fill()` in MacStatusMark.swift → fired for that file only.

# ---- M9. The divider hides the readout BEFORE it cuts the text, and guards the handle. -------
# THE PATH: the canvas re-assigns `handle` on every seam in the tab on every solve, and a divider
# drag or a live window resize solves at the display's rate. `RatioReadout.percents` sets three
# instrument runs, each of which reaches the un-memoized `Slate.Typeface.instrumentNative` (a
# `fontDescriptor.withFamily` plus an `NSFont(descriptor:size:)` CoreText build).
# THREE THINGS HAVE TO HOLD TOGETHER, so all three are pinned:
#   • the handle's didSet is guarded on the VALUE — only the seam under the cursor actually moves,
#     so this turns "N handles updated per frame" into "one", on both sides of `handleUpdated()`
#     (the readout AND an `invalidateCursorRects(for:)` round trip to the window server);
#   • `percents` is guarded field-by-field — a labelled optional tuple has no synthesized `==`, so
#     a `!=` on the whole thing does not compile and its absence is silent;
#   • `applyReadout()` sets `isHidden` FIRST and returns, so the N−1 seams that are not being
#     dragged do not build three fonts for pixels that are hidden. The ordering is safe because
#     `mouseDragged` sets `startLead` before `onResizeBegin()`/`setDragging(true)`, and
#     `setDragging` calls `applyReadout()` first — the readout is populated at the moment it
#     becomes visible.
if ! grep -q 'guard handle != oldValue else { return }' "${MACUI_DIVIDER}"; then
  fail "${MACUI_DIVIDER} re-runs handleUpdated for every seam in the tab on every solve — only the \
dragged one changed; SplitDividerHandle is Equatable, so guard on the value"
fi
if ! grep -q 'percents?.leading != oldValue?.leading' "${MACUI_DIVIDER}"; then
  fail "${MACUI_DIVIDER} re-cuts three instrument runs per drag frame to print the same two \
numbers — the tuple has no synthesized ==, so the guard is field-by-field or it is not there"
fi
if ! grep -q 'guard shown else { return }' "${MACUI_DIVIDER}"; then
  fail "${MACUI_DIVIDER} sets the readout's text before deciding whether it is on screen — three \
uncached CoreText font builds per hidden seam per frame"
fi
# The order is the rule, so the order is what is checked: a file that spells both lines but sets
# the text first is exactly the regression, and it passes all three greps above.
divider_hide_line=$(grep -n 'readout.isHidden = !shown' "${MACUI_DIVIDER}" | cut -d: -f1 || true)
divider_text_line=$(grep -n 'readout.percents = percents' "${MACUI_DIVIDER}" | cut -d: -f1 || true)
if [[ -z "${divider_hide_line}" || -z "${divider_text_line}" ]]; then
  fail "${MACUI_DIVIDER} no longer spells applyReadout's hide and cut as two separate statements — \
the ordering rule below cannot be checked, so it is assumed broken"
elif ((divider_hide_line > divider_text_line)); then
  fail "${MACUI_DIVIDER} cuts the readout's text before hiding it (line ${divider_text_line} \
before line ${divider_hide_line}) — the hidden seams pay the fonts"
fi
# BREAK-TESTED, four ways against the real file (cp to /tmp, sed the copy back over the original,
# run, restore from /tmp — never `git checkout`, which would have discarded this sweep's other
# uncommitted work in the same file):
#   1. the `handle != oldValue` guard deleted        → rule 1 fired, alone.
#   2. the field-by-field guard replaced by `guard percents != nil else { return }` → rule 2 fired.
#   3. `guard shown else { return }` deleted         → rule 3 fired, alone.
#   4. the two statements SWAPPED, both greps still matching → only the ordering rule fired, which
#      is the case the three text pins cannot see and the reason it is written separately.

printf 'check-supervisor: the UI split holds — views only, no dead gates, no ancestor between the halves, no palette row that lies.\n'

# ── A pane's master is decided once, and it is OWNED ────────────────────────────────────────────
# superd used to answer `spawn` by inserting the pane and then asking the map for its master fd by
# name, and the two steps are not one decision. The reaper removes a pane and drops its master the
# instant the child dies, and a child like `exit 0` is usually already dead by the time the reply is
# assembled — so the second lookup either found nothing (an `ok` reply carrying no descriptor, which
# hostd reports as `missingDescriptor` for a child that really ran) or found a raw number the reaper
# had closed and the kernel had reissued to something else, which hostd would have adopted in
# silence. Both windows close the same way: take the duplicate where the pane is decided, hand it
# back OWNED, and let the wire BORROW it — see `docs/51` §2.3.
RUST_REGISTRY="rust/slopdesk-superd/src/registry.rs"
for entry in 'Result<\(PaneRecord, OwnedFd\), RegistryError>' 'duplicate_master\(&spawned\.master\)' \
  'duplicate_master\(&pane\.master\)'; do
  if ! spells "${entry}" "${RUST_REGISTRY}" > /dev/null; then
    fail "${RUST_REGISTRY} no longer hands its caller an owned master duplicate — see docs/51 §2.3"
  fi
done
if hit=$(spells 'fn master_fd' "${RUST_REGISTRY}"); then
  fail "${hit} looks a master up by pane id again — that lookup races the reaper (docs/51 §2.3)"
fi
if ! spells "descriptor: Option<BorrowedFd<'_>>" "${RUST_FRAME}" > /dev/null; then
  fail "${RUST_FRAME} takes a descriptor it cannot prove is still open — BorrowedFd is the proof"
fi
printf 'check-supervisor: a master crosses as an owned duplicate, borrowed for the send.\n'

# ── One sidecar lifecycle per KIND, and five faces over the two ────────────────────────────────
# `HostServiceProcess` held the shape's prose — spawn with port 0, learn the bound port from the
# child's own line, probe with a bounded loopback connect — and its production seams, but not the
# code, so five managers each wrote it out. They had already drifted where nobody could see it:
# `CodeServerManager`'s probe-and-latch wrote its updated record inside the `if due` block and the
# other two wrote it after, and the dropd/inspectord parse accepted a `:0` announce that androidd's
# rejected. Both lifecycles now live in `SupervisedServiceLifecycle.swift`:
# `ProbedPortService` (the OS picks the port, `ensure` never waits) and `AnnouncedPortService`
# (hostd picks it, so the announce is WAITED for and VERIFIED). What stays with each manager is what
# the daemons genuinely disagree about — the socket name, the announce marker, the argv, the env
# override and whether a spawn that threw reads `unavailable` or `starting`.
SERVICE_LIFECYCLE="Sources/SlopDeskHost/SupervisedServiceLifecycle.swift"
for piece in 'final class ProbedPortService' 'final class AnnouncedPortService' 'enum AnnouncedPort'; do
  if ! spells "${piece}" "${SERVICE_LIFECYCLE}" > /dev/null; then
    fail "${SERVICE_LIFECYCLE} no longer holds ${piece} — the five managers share one of each"
  fi
done
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
lifecycles=$(spells 'var lastProbe|spawnGeneration|func awaitAnnouncedPort|prefix\(while: \\.isNumber\)' \
  $(repo_files 'Sources/SlopDeskHost/*.swift' | grep -v 'SupervisedServiceLifecycle.swift') 2> /dev/null || true)
if [[ -n "${lifecycles}" ]]; then
  printf '%s\n' "${lifecycles}" >&2
  fail "a sidecar manager grew its own probe latch, spawn generation or port parse back"
fi
# Each manager keeps exactly one lock, and it is the service's. A second `NSLock` beside a
# `ProbedPortService` is two critical sections gating one spawn, which is how a boot gate and the
# instance record start disagreeing under a racing pair of metadata queues.
for manager in Android Simulator Code; do
  path=$(repo_files "Sources/SlopDeskHost/${manager}*Manager.swift")
  # shellcheck disable=SC2086 # `${path}` may name more than one file; the split is the argument list
  if [[ -n "${path}" ]] && spells 'let lock = NSLock\(\)' ${path} > /dev/null 2>&1; then
    fail "${path} took a second lock beside ProbedPortService — use its locked(_:)"
  fi
done
printf 'check-supervisor: two sidecar lifecycles, five faces, one lock each.\n'

# ── One re-armable deadline, one pasteboard clip, one sidecar encoder ─────────────────────────────
# `DeadlineLatch` is five lines with three load-bearing details in them, and each reads as noise
# until the one time it is missing: the cancel comes FIRST (a re-arm during a live drag otherwise
# stacks one timer per layout pass), `Task.isCancelled` is checked AFTER the sleep (`try?` swallows
# the cancellation throw, so a cancelled timer would run its body anyway), and the caller's closure
# is `[weak self]`. Four models had it written out; a fifth must ask for the latch instead.
# The shape is narrow on purpose — a `Task` holding a SLEEP and then a cancellation check — so a
# repeating loop (`while !Task.isCancelled { … await sleep }`) does not match it: that is a different
# law with a different lifetime. Scoped to the two targets that can SEE the latch; SlopDeskVideoHost
# and SlopDeskVideoClient hold one-shots of the same shape and depend on nothing that could carry
# `DeadlineLatch` down to them, so pinning them here would only demand an impossible import.
# Not `spells`: the check is a two-line WINDOW (open the Task, then find the guard under it), which
# is a `grep -A2` per file rather than a pattern over a file list.
# The `-A2` window is why this is per file rather than one pattern over the list — but only files
# that carry the INTRODUCER can have a window worth reading, so one `grep -l` picks those out first
# and the two-process-per-file cost becomes two per candidate. Same trick as `spells`, same reason.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
while IFS= read -r file; do
  [[ -f "${file}" ]] || continue
  [[ "${file}" == *DeadlineLatch.swift ]] && continue
  if grep -q 'guard !Task.isCancelled' <<< "$(grep -A2 'Task { \[weak self\] in' "${file}" 2> /dev/null)"; then
    printf '%s\n' "${file}" >&2
    fail "a cancel-and-re-arm deadline grew back — DeadlineLatch.arm owns the three details"
  fi
done <<< "$(grep -lF 'Task { [weak self] in' \
  $(repo_files 'Sources/SlopDeskPhoneUI/**/*.swift' 'Sources/SlopDeskClientCore/**/*.swift' \
    'Sources/SlopDeskWorkspaceCore/**/*.swift') \
  2> /dev/null || true)"
declare -a latch_shares=(
  "Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift:reflowDeadline.arm"
  "Sources/SlopDeskWorkspaceCore/Video/RemoteWindowModel.swift:reflowDeadline.arm"
  "Sources/SlopDeskDevicePanels/Android/AndroidSidebarModel.swift:noticeClear.arm"
  "Sources/SlopDeskDevicePanels/Simulator/SimulatorSidebarModel.swift:noticeClear.arm"
  "Sources/SlopDeskDevicePanels/Android/AndroidSidebarModel.swift:reattempt.arm"
  "Sources/SlopDeskClientCore/Pane/PaneDragCoordinator.swift:springLoadTask.arm"
)
for share in "${latch_shares[@]}"; do
  if ! grep -qF "${share#*:}" "${share%%:*}"; then
    fail "${share%%:*} stopped arming a DeadlineLatch — the timer is shared, the state is not"
  fi
done
# Clipboard sync's two ends are two halves of ONE wire contract, so the pasteboard↔clip conversion
# is one file. They had already drifted once — the client refuses to push a CONCEALED clip and the
# host does not refuse to ship one back — which is now a named parameter rather than two bodies.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
clipdupes=$(spells 'forType: .tiff|MetadataCodec.maxClipboardContentBytes' \
  $(repo_files 'Sources/**/*.swift' | grep -v 'PasteboardClip.swift') 2> /dev/null || true)
if [[ -n "${clipdupes}" ]]; then
  printf '%s\n' "${clipdupes}" >&2
  fail "a second pasteboard↔clip conversion grew back — PasteboardClip reads and writes both ends"
fi
declare -a clip_shares=(
  "Sources/SlopDeskHost/HostClipboardPerformer.swift:PasteboardClip.read"
  "Sources/SlopDeskHost/HostClipboardPerformer.swift:PasteboardClip.write"
  "Sources/SlopDeskWorkspaceCore/Workspace/Store/ClipboardSyncEngine.swift:PasteboardClip.read"
  "Sources/SlopDeskWorkspaceCore/Workspace/Store/ClipboardSyncEngine.swift:PasteboardClip.write"
)
for share in "${clip_shares[@]}"; do
  if ! grep -qF "${share#*:}" "${share%%:*}"; then
    fail "${share%%:*} stopped calling ${share#*:} — the two ends agree by sharing, not by luck"
  fi
done
# Every JSON sidecar sorts its keys. Not tidiness: docs/22 §8's round-trip tests compare BYTES, and
# Swift's default key order is not stable across runs, so an encoder that omits `.sortedKeys` writes
# a perfectly good file and turns a passing test into one that fails on a Tuesday. A positive check,
# because a `JSONEncoder` is ordinary Foundation used in plenty of places that never touch disk.
# The candidate list IS the `outputFormatting` grep that used to be the loop's first line, hoisted
# out of it: one process over the tree instead of one per file, and a deleted-but-still-indexed file
# simply does not come back from `grep -l`.
# `< /dev/null` for the reason written at `spells` — this is the ONE ban that greps a splat directly
# instead of going through it, so it needs the guard spelled out rather than inherited.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
while IFS= read -r file; do
  [[ -f "${file}" ]] || continue
  grep -q '\.sortedKeys' "${file}" || {
    printf '%s\n' "${file}" >&2
    fail "a sidecar encoder set outputFormatting without .sortedKeys — docs/22 §8 compares bytes"
  }
done <<< "$(grep -lF 'outputFormatting' $(repo_files 'Sources/**/*.swift') < /dev/null 2> /dev/null || true)"
# …and inside WorkspaceCore, where four stores wrote sidecars, there is one encoder for all of them.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
core_encoders=$(spells 'outputFormatting' \
  $(repo_files 'Sources/SlopDeskWorkspaceCore/**/*.swift' | grep -v 'SidecarJSON.swift') 2> /dev/null || true)
if [[ -n "${core_encoders}" ]]; then
  printf '%s\n' "${core_encoders}" >&2
  fail "a second sidecar encoder grew back in WorkspaceCore — SidecarJSON.encoder is the one"
fi
# The two client-side debug gates are read in ONE file. Not tidiness: `SLOPDESK_BLOCKS_DEBUG` traces a
# block jump END-TO-END across three files (`[blocks]` issue → `[flash]` arm/settle → `[flash]` paint),
# so a reader that spells the gate itself is one that can spell it `!= nil` while the others say
# `== "1"` — and then half the trace appears and the missing half reads as "that step never ran". One
# of the three had already drifted to its own copy of gate + tag when this check was written.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
tracegates=$(spells 'SLOPDESK_BLOCKS_DEBUG|SLOPDESK_WORKSPACE_DEBUG' \
  $(repo_files 'Sources/**/*.swift' | grep -v 'Support/DebugTrace.swift') 2> /dev/null || true)
if [[ -n "${tracegates}" ]]; then
  printf '%s\n' "${tracegates}" >&2
  fail "a debug gate is read outside DebugTrace — one gate, one spelling, one tag grammar"
fi
# The channel tag is ONE enum in the wire target. The host and the client each used to declare their
# own copy, byte-identical, each with a doc paragraph explaining that the wire contract — not a Swift
# type — was the agreement. True of the modules (the client must not depend on the macOS-only host),
# false of `SlopDeskVideoProtocol`, which both already depend on. Two declarations of one contract is
# the `process::basename` shape (docs/55 §6): they agree until a seventh channel lands on one side.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
channeldupes=$(spells 'enum VideoChannel' \
  $(repo_files 'Sources/**/*.swift' 'Tests/**/*.swift' | grep -v 'SlopDeskVideoProtocol/VideoChannel.swift') 2> /dev/null || true)
if [[ -n "${channeldupes}" ]]; then
  printf '%s\n' "${channeldupes}" >&2
  fail "a second VideoChannel grew back — SlopDeskVideoProtocol owns the tag both sides send"
fi
# …and the raw values ARE the wire tags on every media-socket datagram. Renumbering one re-routes a
# channel on the far side with nothing failing to compile, so each tag is pinned to its number here.
declare -a channel_tags=(
  "control = 0" "video = 1" "geometry = 2" "cursor = 3" "input = 4" "recovery = 5" "audio = 6"
)
for tag in "${channel_tags[@]}"; do
  if ! grep -qF "case ${tag}" Sources/SlopDeskVideoProtocol/VideoChannel.swift; then
    fail "VideoChannel lost 'case ${tag}' — the raw values are the wire tags (doc 17 §3.3)"
  fi
done
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

# ── One seeded name, one font stack, one encoder default table (docs/55 §8) ─────────────────────
# The three seeded names are the crate's, and Swift asks for them.
#
# `TreeWorkspaceDefaults` has existed for a while and its own doc names the failure: a copy of
# either literal on the Swift side is a second answer to "what is a fresh pane called", and the
# fresh-workspace SHAPE TEST comparing against a spelled-out "Terminal" would go on passing against
# a default the crate had stopped producing. The face was built and the callers were never moved;
# this is what stops them drifting back. Comments are stripped first, because the prose around these
# call sites quotes the words on purpose.
#
# This is a BAN, so an empty result passes it — which is exactly what a renamed file would produce.
# The corpus is established first, the way the gate one register down says a ban list has to be.
seeded_corpus=(
  Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspacePersistence.swift
  Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Desktop.swift
  Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Bootstrap.swift
  Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Templates.swift
  Sources/SlopDeskWorkspaceCore/Workspace/Domain/SessionTemplateEngine.swift
)
for file in "${seeded_corpus[@]}"; do
  [[ -e "${file}" ]] || fail "${file} is gone — the seeded-name ban below reads an empty corpus, which passes it (docs/55 §8)"
done
for seeded in Terminal Desktop Local; do
  hits="$(
    for file in "${seeded_corpus[@]}"; do
      sed -E 's#^[[:space:]]*//.*##' "${file}" | grep -Fq "\"${seeded}\"" && printf '%s ' "${file}"
    done
  )" || true
  if [[ -n "${hits}" ]]; then
    fail "the seeded name \"${seeded}\" is spelled in Swift again (${hits}) — ask TreeWorkspaceDefaults (docs/55 §8)"
  fi
done
for face in paneTitle sessionName desktopPaneTitle; do
  if ! grep -q "static let ${face} = wsString" Sources/SlopDeskWorkspaceModel/Domain/Tree/TreeWorkspace.swift; then
    fail "TreeWorkspaceDefaults lost ${face} — the seeded names would go back to being literals"
  fi
done

# PaneChooserRegistry is deliberately NOT in that list. Its "Terminal"/"Desktop" are the CHOOSER's
# labels for a pane kind — a vocabulary a Swift `switch` reads, which docs/55 §6 leaves in Swift —
# not the title a minted pane is born with. They are the same word today for the same reason a
# folder and its icon share a name, and nothing breaks if the seeded title is renamed and the menu
# entry is not.
# PORTED to rust/slopdesk-invariants (`code-panel-font-pair`): the two bundled font families are one
# pair held across a boundary they deliberately do not cross, and `code-panel-one-implementation`
# now also bans the dressing itself from growing back in Swift. See rules/code_panel.rs.
# The tuned encoder defaults are Rust's, and the host asks for them.
#
# Eleven numbers — four quantiser knobs, seven recovery-keyframe ones — used to be spelled in both
# `qp_control.rs`/`recovery_idr.rs` and their Swift faces. Nothing failed when they agreed and
# nothing would have failed when they stopped: the host would simply encode at the old operating
# point, or grant keyframes on the old bucket, with no build error and no failing test. The two
# `*_config_default` doors put the table on one side; this stops the literals growing back.
qp_face="Sources/SlopDeskVideoHost/QPController.swift"
idr_face="Sources/SlopDeskVideoHost/RecoveryIDRPolicy.swift"
for door in slopdesk_qp_config_default slopdesk_idr_config_default; do
  if ! grep -rq "${door}" Sources/SlopDeskVideoHost/; then
    fail "${door} lost its caller — the tuned defaults are spelled Swift-side again (docs/55 §8)"
  fi
done
# A `var` in the IDR config carrying its own literal is exactly the regrowth: the struct's fields are
# seeded from the door in `init()`, so a default on the declaration would silently win.
if grep -qE '^ *public var [a-zA-Z]+: (Double|Int) = ' "${idr_face}"; then
  fail "${idr_face} put literal defaults back on Config's fields — they come from slopdesk_idr_config_default()"
fi
# Same shape on the quantiser side: the env fallbacks are the door's answer, never a digit.
if grep -qE 'envInt\("SLOPDESK_QP_[A-Z_]+", [0-9]' "${qp_face}"; then
  fail "${qp_face} typed a quantiser default back in — the fallback is slopdesk_qp_config_default()'s"
fi
# A settings row crosses whole, not field by field.
#
# `slopdesk_ffi::settings_rows`' own header argues the principle for the MATCH — positions rather
# than rows, so a filter is one crossing and not one per field per row — and the reader then turned
# each position back into eight calls, on every settings-search keystroke. `slopdesk_settings_row_fields`
# is that argument applied one level out. This stops `entry(at:)` sliding back to the field doors.
#
# The seven named below were DELETED on 2026-08-22, so this loop now bans symbols that do not exist
# — deliberately. `check-ffi-doors.py` is what found them exported and uncalled, and the reason they
# could never acquire a caller was this ban; keeping it outliving them stops the next reader from
# re-declaring one as the obvious fix for a one-field question.
catalog="Sources/SlopDeskWorkspaceCore/Workspace/Store/AllSettingsCatalog.swift"
entry_body="$(sed -n '/private static func entry(at index: Int)/,/^    }/p' "${catalog}")"
for field_door in slopdesk_settings_row_label slopdesk_settings_row_page_label \
  slopdesk_settings_row_description slopdesk_settings_row_default_text \
  slopdesk_settings_row_target_section slopdesk_settings_row_keywords \
  slopdesk_settings_row_bucket; do
  if printf '%s' "${entry_body}" | grep -q "${field_door}"; then
    fail "entry(at:) went back to ${field_door} — a row crosses whole (slopdesk_settings_row_fields)"
  fi
done
if ! grep -q 'slopdesk_settings_row_fields' "${catalog}"; then
  fail "${catalog} stopped calling slopdesk_settings_row_fields — reading a row costs 8 crossings again"
fi

# THREE field doors stay, and only three, because three callers really do want one field: the key
# lookup, the shown gate, and the reset walk over `persistence`. Each asks a question about a row it
# is not otherwise reading, so routing it through the whole-row door would decode seven fields to
# use one. The other seven had no such caller left, which is why they are gone rather than kept
# "for symmetry" — docs/55 §8: an unreached port is worse than an unported one.
if ! grep -q 'slopdesk_settings_row_key' "${catalog}"; then
  fail "${catalog} lost the single-field key door — a key lookup should not decode a whole row"
fi
# A rail relabelling crosses once, not once per row.
#
# The collision rule needs the WHOLE list in hand to answer for any one member, so asking per index
# meant rebuilding the label array and every title's bytes `n` times to answer `n` questions off one
# input — quadratic in marshalling, on a list rebuilt whenever anything in it ticks.
#
# The per-index door was DELETED on 2026-08-22, so this first rule now bans a symbol that does not
# exist — deliberately. `check-ffi-doors.py` is what caught the door sitting there exported and
# uncalled, and the reason it could never acquire a caller was this ban; the ban outliving the door
# is what keeps the next reader from re-declaring it as the obvious fix for a one-row question.
rail="Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift"
if grep -q 'slopdesk_ws_rail_disambiguated_label(' "${rail}"; then
  fail "${rail} asks for a per-index label door — there is none, and there is none because a collision is a fact about the whole list: ask slopdesk_ws_rail_disambiguated_labels and read the member you want"
fi
if ! grep -q 'slopdesk_ws_rail_disambiguated_labels(' "${rail}"; then
  fail "${rail} stopped calling slopdesk_ws_rail_disambiguated_labels — the relabelling is quadratic again"
fi

# ── The open target splits once, and the crate owns where ──────────────────────────────────────
# `HostCodeServerPerformer.splitLineColSuffix` used to be a second `:line[:col]` splitter beside
# `slopdesk-terminal`'s, and the two had already answered differently for a target that is ALL
# suffix (`":12"`): Swift called it a suffix with an empty path, the crate calls it no suffix at
# all. Three host call sites read that split — the existence check, the workbench CLI target, and
# the code-server window routing — so a second splitter growing back here means the path the host
# stats and the path the extension opens can disagree by a colon.
SWIFT_CODEOPEN=Sources/SlopDeskHost/HostCodeServerPerformer.swift
if ! spells 'slopdesk_link_line_col_suffix' "${SWIFT_CODEOPEN}" > /dev/null; then
  fail "${SWIFT_CODEOPEN} splits a line:col suffix in Swift again — that rule is link_action.rs's"
fi
if hit=$(spells 'isNumber|runStart|sawDigit' "${SWIFT_CODEOPEN}"); then
  fail "${hit} re-derives the suffix scan — the crate answers it, and the path is the remainder"
fi
printf 'check-supervisor: one line:col splitter, and the host asks it.\n'

# ── A ring wraps through the one ring rule ──────────────────────────────────────────────────────
# `(i ± 1 + n) % n` was hand-rolled in three places beside `slopdesk_list_wrapped_index`, which the
# picker's filter pills already ask. Each copy is one `% 0` away from a trap on an empty list, and
# the door is the only spelling that answers "there is nothing to step from" instead.
for ring in Sources/SlopDeskWorkspaceCore/Workspace/Domain/PaneSwitcher.swift \
  Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift; do
  if hit=$(spells '\+ count\) %|\+ matches\.count\) %|\+ candidates\.count\) %' "${ring}"); then
    fail "${hit} hand-rolls a ring wrap — ListNavigation.wrappedIndex is the one ring step"
  fi
done
printf 'check-supervisor: every ring steps through the one wrap rule.\n'

# ── hostd and the device panels ───────────────────────────────────────────────────────────────
# Every rule below was BREAK-TESTED against the real tree — the verdict is recorded in its own
# comment — by copying the file to /tmp, editing it back to the shape the rule bans, running the
# PORTED to `rust/slopdesk-invariants`: hostd-binary-order — the null-output probe ban, the
# three guess-then-retry sites, and the one search order.

# ── ONE search-box predicate for both device panels, both drawings ────────────────────────────
#
# `localizedCaseInsensitiveContains` was spelled SIX times over "does any field of this row contain
# what was typed" — twice in `AndroidPresentation` (the list, the console) and once each in the
# four simulator views, two SwiftUI and two AppKit. Only one of the six was ever reached by a test,
# which is the drift class `docs/55` §8 is about: the copy a test holds is not the copy the other
# shell runs, and nothing can notice them parting. They now route through
# `DeviceRowFilter` → `slopdesk_ws_binding_row_matches` → `slopdesk_workspace::binding_search`,
# which is the rule the palette, Settings and the keybindings editor were already using.
#
# It is also 8–13× off. Scratch `swiftc -O` harness against the shipped `macos-arm64` slice, at
# `SimulatorSidebarModel.logCapacity` = 600 console rows, two runs agreeing, blob build INCLUDED:
#
#   needle hits    873.8 / 876.9 µs  →  111.6 / 110.4 µs
#   needle misses 1661.8 / 1624.6 µs →  131.2 / 128.5 µs
#
# A miss is the state every keystroke passes through, and the drawer repaints on every arriving log
# line.
#
# The ban is by FILE, not tree-wide: `Sources/slopdesk-capture-probe` matches one window title with
# it and is a dev tool, not a panel. The corpus is checked non-empty first — a ban over a file that
# was renamed away passes silently, and this one names six files across three targets, which is
# exactly the shape that rots.
#
# The rule was RED for the length of the change, naming `SimulatorConsoleView.swift` while the four
# simulator-view edits were still pending — the two UI targets belonged to other owners and their
# replacements landed centrally. That is worth recording: a ban that spans targets one agent cannot
# edit reads as a false positive exactly once, at the half-applied moment, and is not one.
#
# BREAK-TEST 2026-08-22, each by `cp` to /tmp and back, never `git checkout`:
#   * `AndroidPresentation.swift`'s `visible` body pasted back as the
#     `localizedCaseInsensitiveContains` filter → the ban FIRED and named that file. Restored, that
#     file is clean again.
#   * `slopdesk_ws_binding_row_matches` renamed inside `DeviceRowFilter.swift` → the presence check
#     FIRED. Restored, PASSES.
#   * `DeviceRowFilter.swift` moved out of the tree → the vacuity floor FIRED with "6 of 7 files"
#     rather than letting the ban read a short corpus and pass. Restored, PASSES.
PANEL_FILTER_FILES=(
  Sources/SlopDeskDevicePanels/Android/AndroidPresentation.swift
  Sources/SlopDeskDevicePanels/Simulator/SimulatorPresentation.swift
  Sources/SlopDeskDevicePanels/Shared/DeviceRowFilter.swift
  Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorConsoleView.swift
  Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorDeviceList.swift
  Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorConsoleView.swift
  Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorDeviceList.swift
)
panel_filter_present=()
for file in "${PANEL_FILTER_FILES[@]}"; do
  [[ -f "${file}" ]] && panel_filter_present+=("${file}")
done
if ((${#panel_filter_present[@]} != ${#PANEL_FILTER_FILES[@]})); then
  fail "the device panels' filter corpus has ${#panel_filter_present[@]} of ${#PANEL_FILTER_FILES[@]} files — a renamed one would let the ban below pass without reading anything"
elif filter_copy=$(spells 'localizedCaseInsensitiveContains' "${panel_filter_present[@]}"); then
  fail "${filter_copy} spells localizedCaseInsensitiveContains again — the device panels' search predicate is DeviceRowFilter, and it was six copies of these three lines"
fi
SWIFT_ROW_FILTER=Sources/SlopDeskDevicePanels/Shared/DeviceRowFilter.swift
if [[ -f "${SWIFT_ROW_FILTER}" ]] && ! grep -q 'slopdesk_ws_binding_row_matches(' "${SWIFT_ROW_FILTER}"; then
  fail "${SWIFT_ROW_FILTER} no longer calls slopdesk_ws_binding_row_matches — the predicate is rust/slopdesk-workspace/src/binding_search.rs and is not to be re-spelled in Swift"
fi
printf 'check-supervisor: one search predicate for both device panels, in one language.\n'

# ── The instrument voice is minted ONCE per rung ──────────────────────────────────────────────
#
# `Slate.Typeface.instrumentNative` is the AppKit/UIKit half of the mono voice, and it was the only
# font accessor in this file with no cache in front of it. The asymmetry is what makes it a defect
# rather than a slow function: `macDevicePanelLabel` picks between `.systemFont(ofSize:weight:)` and
# this one on a single ternary, and `+systemFont:` is cached BY THE FRAMEWORK while
# `NSFont(descriptor:size:)` builds a CoreText font from scratch every time. Nothing in either
# language recorded that one arm of that ternary was two hundred times the other.
#
# Measured in a scratch `swiftc -O` harness (NOT in the tree; two runs agreeing to 1.5%), per call:
#
#     mono-INSTALLED arm (the shipping configuration)   7 122 – 7 343 ns
#       of which NSFont(descriptor:size:) alone         7 142 – 7 406 ns
#     SF Mono fallback arm (no JetBrains Mono)          2 091 – 2 118 ns
#     out of the table                                     23 –    34 ns
#     MacPaneDivider's three runs, per divider/frame   21 400 ns  ->  69 ns   (~310x)
#
# Those three are the ratio readout's leading/dot/trailing runs, which reach here through
# `macInstrumentString` in `MacCapsLabel.swift`; `applyReadout` cuts them for a hidden readout for
# exactly this reason, and that guard covers N−1 seams but not the one being dragged.
#
# There are 16 call sites across `Sources/SlopDeskMacUI` plus one test — 17 in all, and one further
# mention that is only a doc link. All of them are `NSView` or already-`@MainActor` builders, which
# is why `@MainActor` on the accessor costs nothing.
#
# THE FAILURE MODE THE GATE EXISTS FOR is that none of this is visible to a test: every call returns
# the correct font, the memo and the builder agree by construction, and the only trace is the frame
# rate while a divider is dragged. So what is pinned is the SHAPE — that the accessor goes through
# the table, and that the expensive builder is reachable from exactly one place.
#
# BREAK-TESTED against the real tree on 2026-08-22 by putting each pre-fix spelling back and
# restoring `SlateDesign.swift` from a /tmp copy afterwards (never `git checkout`, which would have
# discarded this tree's uncommitted work). All four fire, each on its own rule only, and the
# restored file reads 0:
#   accessor no longer reads the table   FAIL "stopped reading mintedInstruments"        ✓
#   `@MainActor` dropped off the store   FAIL "mintedInstruments lost its @MainActor"     ✓
#   descriptor inlined into the accessor FAIL "mints a font outside mintInstrument"       ✓
#   a second withFamily(mono) grows      FAIL "the instrument face is built in 2 places"  ✓
slate_design=Sources/SlopDeskSlate/SlateDesign.swift
if ! grep -qE '^ *if let struck = mintedInstruments\[rung\] \{ return struck \}$' "${slate_design}"; then
  fail "instrumentNative stopped reading mintedInstruments — it is 7.1 µs a call cold and 30 ns out of the table"
fi
if ! grep -qE '^ *@MainActor private static var mintedInstruments: \[InstrumentRung: SlateNativeFont\] = \[:\]$' "${slate_design}"; then
  fail "mintedInstruments lost its @MainActor (or its type) — the only alternatives are a lock or no memo at all"
fi
# The expensive build is `SlateNativeFont.systemFont(…).fontDescriptor.withFamily(mono)` and it must
# live in `mintInstrument` and nowhere else — a caller that spells it inline has re-minted around the
# table, which no test can see because the FONT is right. Counted rather than merely required, for
# the reason `TreeWorkspaceRepairDifferentialTests` gives about vocabularies: a presence check agrees
# with itself while a second copy appears beside the first, and 0 — the extraction having gone stale
# — must fail rather than read as compliance. `|| true` so a zero count cannot kill the script under
# the meta-gate's `pipefail`.
mint_sites=$(grep -cE 'fontDescriptor\.withFamily\(mono\)' "${slate_design}" || true)
if [[ "${mint_sites}" != 1 ]]; then
  fail "the instrument face is built in ${mint_sites} places in ${slate_design}, not 1 — mintInstrument is the only one allowed"
fi
if grep -A12 '^ *package static func instrumentNative(' "${slate_design}" | grep -qE 'fontDescriptor'; then
  fail "instrumentNative mints a font outside mintInstrument — the memo is being walked around"
fi
printf 'check-supervisor: the instrument voice is minted once per rung, not once per call.\n'

# ── NOT a ratchet, a note for whoever audits this next ──────────────────────────────────────────
# `MuxChannelSession.isCompletionTransition` looks like a twin of `slopdesk_agent_attention_completion`
# and is NOT one. The door answers the HOOK-LESS completion (`Working|Blocked -> Idle`); the host's
# rule is "one finished turn", which is that PLUS entering `.done` from anything but `.done` — the
# hook path, which is the whole reason `pane/completionEpoch` advances on a host that runs the Stop
# hook. Routing the host through the door would silently stop counting hook-driven finishes.
# `Tests/SlopDeskHostTests/CompletionTransitionTests.swift` pins the difference; leave it Swift, or
# give the wider rule a door of its own.

# ── The Android console's level filter is androidd's array, not a second list ────────────────────
#
# CATCHES: a Swift `AndroidLogLevel` that goes back to spelling its own letters. It did once, and it
# drifted short — five letters against androidd's six — so `F` was a filter the menu could not
# produce while `logcat_level` was validating against a set that contained it. Nothing failed: the
# console just had no way to ask for fatal. The set now crosses through
# `slopdesk_android_log_level_letter`, and this is what keeps it crossing.
SWIFT_ANDROID_LOG_LEVEL="Sources/SlopDeskDevicePanels/Android/AndroidLogLevel.swift"
if ! grep -q 'slopdesk_android_log_level_letter' "${SWIFT_ANDROID_LOG_LEVEL}"; then
  fail "${SWIFT_ANDROID_LOG_LEVEL} no longer reads androidd's level array — the menu is a second list again (docs/48)"
fi
# The named constants (`.info`, `.fatal`) are allowed and `AndroidLogLevelTests` pins each against
# the crossed set. What is NOT allowed is the type going back to an `enum`, because an enum's case
# list cannot be built from a table at run time — that keyword IS the second copy.
if grep -qE '^ *(package|public|internal)? *enum +AndroidLogLevel' "${SWIFT_ANDROID_LOG_LEVEL}"; then
  fail "${SWIFT_ANDROID_LOG_LEVEL} is an enum again — a case list cannot come from androidd's array, so it is a second copy of it"
fi

# ── The cursor style has ONE label ───────────────────────────────────────────────────────────────
#
# CATCHES: a display name growing back on `TerminalPreferences.CursorStyle`. There was one, reading
# "Block (hollow)", against `settings_catalog`'s "Hollow" for the same token — and both were on the
# same Settings page, the catalog's at the picker and this one at the ✎ row that jumps to it. One
# setting, two words, a scroll apart.
SWIFT_TERMINAL_PREFS="Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift"
# Comments stripped for the same reason: the enum's doc quotes both spellings to record which one
# survived, and the check is about the CODE.
if grep -qE 'Block \(hollow\)|displayName' <<< "$(grep -vE '^ *(///|//|\*)' "${SWIFT_TERMINAL_PREFS}")"; then
  fail "${SWIFT_TERMINAL_PREFS} names a cursor style again — the label is settings_catalog's CURSOR_STYLES (docs/56)"
fi

# ── 1. No second traversal check in Swift ─────────────────────────────────────────────────────────
# CATCHES: a Swift file deciding for itself whether a path contains `..`. That predicate is exactly
# what the three deleted implementations each spelled differently, and the two spellings that were
# wrong were wrong in ways no test in their own file could see. `PathConfinement` is the only Swift
# that may hold an opinion about a path component, and it holds it by asking Rust.
if grep -rnE '(containsTraversal|contains\("\.\."\)|hasPrefix\("\.\./"\)|== "\.\."|components\(\).*"\.\.")' \
  Sources/ --include='*.swift' 2> /dev/null; then
  fail "a Swift file is deciding about a '..' component itself — path confinement is
  slopdesk_path_confine's answer alone (rust/slopdesk-probe/src/path_confine.rs)."
fi

# ── 2. No string-prefix containment in the host ───────────────────────────────────────────────────
# CATCHES: the exact shape `CodeBridgeServer.contains` had — `path.hasPrefix(root)` — which treats
# `/a/repo-evil` as a child of `/a/repo` unless a separator guard is bolted on beside it, and which
# says nothing at all about `..`. A containment answer that is a string comparison is a bug whose
# next reader will assume the guard is somewhere.
if grep -rnE '\.hasPrefix\((root|projectRoot|cwd|folder|workspaceRoot)\b' Sources/ \
  --include='*.swift' 2> /dev/null; then
  fail "a Swift file is testing containment with hasPrefix — use PathConfinement.isWithin, which
  is component-wise and refuses '..'."
fi

# ── 3. The three deleted helpers stay deleted ─────────────────────────────────────────────────────
# CATCHES: the port being half-reverted. `pathComponents`/`isWithin([String],root:)` were the
# decoder's own splitter and prefix match; a `contains(root:path:)` with a BODY is the bridge's
# string test coming back. All three compiled and all three passed their tests while disagreeing
# with each other, so their absence is the only durable evidence the port happened.
if grep -rnE 'static func (pathComponents|isWithin)\(_ ' Sources/ --include='*.swift' 2> /dev/null; then
  fail "MetadataResponseBuilder's own path splitter/prefix match is back — the rule is
  rust/slopdesk-probe/src/path_confine.rs."
fi
if grep -rn 'func contains(root:' Sources/ --include='*.swift' -A 3 2> /dev/null | grep -q 'hasPrefix'; then
  fail "CodeBridgeServer.contains has a body again — it must forward to PathConfinement.isWithin."
fi

# ── 4. The rule stays LEXICAL ─────────────────────────────────────────────────────────────────────
# CATCHES: someone "fixing" the documented symlink residual with `canonicalize`. That is not a fix
# and the module says why at length: it needs the path to EXIST (so a missing file becomes a refusal
# rather than a clean not-found), it refuses legitimate paths whose ROOT is itself a symlink (/tmp on
# macOS), and it still loses to a symlink swap between the check and the open. Changing this is a
# design decision, not a patch, and it must not arrive as a one-line diff.
# (Comment lines are excluded: the module's own prose names `canonicalize` several times, to say
#  why it is NOT used. A ban that fires on its own rationale is a ban that gets deleted.)
if grep -rnE 'canonicalize' rust/slopdesk-probe/src/ 2> /dev/null | grep -vE ':[0-9]+:[[:space:]]*//'; then
  fail "slopdesk-probe reached for canonicalize — path confinement is LEXICAL on purpose; see the
  'residual' section of rust/slopdesk-probe/src/path_confine.rs before changing it."
fi

# ── 5. The rule has exactly one home ──────────────────────────────────────────────────────────────
# CATCHES: a second Rust crate growing its own confinement. `path_confine` is reached two ways — the
# probe calls it directly, hostd calls it through the door — and both must land on the same file.
CONFINE_HOMES=$(grep -rlE 'fn (confine|is_confinable_absolute)\(' rust/ --include='*.rs' 2> /dev/null |
  grep -v '/target/' | grep -v 'slopdesk-ffi/src/path_confine.rs' || true)
if [[ "${CONFINE_HOMES}" != "rust/slopdesk-probe/src/path_confine.rs" ]]; then
  fail "path confinement must live in exactly one file (rust/slopdesk-probe/src/path_confine.rs);
  found: ${CONFINE_HOMES:-nothing}"
fi

# ── 6. The door is declared where Swift can reach it ──────────────────────────────────────────────
# CATCHES: the `pub mod`/header/module trio drifting. `build-ffi.sh` already checks every declared
# symbol against every slice, so this only has to catch the case it cannot: a module that exists and
# is not exported, which fails as a LINK error in the app rather than in the gate.
for symbol in slopdesk_path_confine slopdesk_path_is_confinable_absolute; do
  grep -q "${symbol}" rust/slopdesk-ffi/include/slopdesk_ffi.h ||
    fail "${symbol} is missing from slopdesk_ffi.h — Swift cannot link the confinement rule."
done
grep -q '^pub mod path_confine;' rust/slopdesk-ffi/src/lib.rs ||
  fail "rust/slopdesk-ffi/src/lib.rs does not export path_confine — the header promises a symbol
  the library will not carry."

# A1 — the mux-type VOCABULARY is asked once and a byte outside it is REFUSED.
#
# CATCHES: a `default:` arm in the near-side rebuild that answers a frame for a type byte the door
# never accepted. It used to answer `.windowAdjust`, which is flow-control CREDIT: had the two type
# lists stopped agreeing, an unrecognised byte would have granted a peer a send window out of a
# struct field nothing filled. `unpack` in rust/slopdesk-ffi/src/mux_envelope.rs answers `None` for
# that input, and the face must answer the same. Pinned POSITIVELY — as a `MuxFrameType(rawValue:)`
# lookup with a refusal behind it — because banning `default:` in the file would also ban the one
# legitimate `default:` in the verdict switch, and a pattern ban can see a shape but never an intent.
mux_envelope_swift=Sources/SlopDeskProtocol/Mux/MuxEnvelope.swift
if ! grep -q 'MuxFrameType(rawValue: flat.mux_type)' "${mux_envelope_swift}"; then
  fail "${mux_envelope_swift} stopped refusing an unknown mux type — the type list is Rust's"
fi
if ! grep -q '_ => None' rust/slopdesk-ffi/src/mux_envelope.rs; then
  fail "rust/slopdesk-ffi/src/mux_envelope.rs stopped refusing an unknown mux type — the face mirrors it"
fi

# A3 — an undecodable Android stream ENDS rather than defaulting.
#
# CATCHES: the `?? .h264` coming back. `slopdesk_android_stream_decodable_codec` answers "this Mac
# cannot display that"; the panel used to overrule it with H.264, which configured an H.264 NAL-type
# reading for AV1 parameter sets and handed VTDecompressionSession a mis-typed format description —
# the black rectangle `AndroidVideoCodec`'s omission of AV1 exists to prevent, with nothing logged.
SWIFT_ANDROID_STREAM=Sources/SlopDeskDevicePanels/Android/AndroidStreamConnection.swift
if grep -q 'AndroidVideoCodec(streamIdentifier:.*??' "${SWIFT_ANDROID_STREAM}"; then
  fail "${SWIFT_ANDROID_STREAM} defaults an unrecognised codec again — the door already refused it"
fi
if ! grep -q 'slopdesk_android_stream_decodable_codec(' \
  Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift; then
  fail "AndroidStreamProtocol.swift stopped asking which codecs decode — that set is Rust's"
fi

# A4 — the multi-loss THRESHOLD is one answer, not a literal in each language.
#
# CATCHES: `parityCount >= 2` (or `m >= 2`) reappearing in Swift. The bounds cannot stand in for it —
# `M_MIN` is 1 — so a reader who does not know the door exists reaches for the literal, which is how
# it came to be spelled twice in Swift and a third time inside the crate's own tier table. A host and
# a client that disagree about it emit and expect different parity counts per group, and neither end
# logs anything: the client simply stops repairing.
SWIFT_FEC=Sources/SlopDeskVideoProtocol/AdaptiveFECPolicy.swift
if grep -qE '(parityCount|resolveParityCount\([^)]*\)) *>= *2' \
  <<< "$(grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_FEC}")"; then
  fail "${SWIFT_FEC} spells the multi-loss threshold again — ask slopdesk_adaptive_fec_multi_loss_active"
fi
if ! grep -q 'slopdesk_adaptive_fec_multi_loss_active(' "${SWIFT_FEC}"; then
  fail "${SWIFT_FEC} stopped asking the door whether multi-loss is active"
fi

# A5 — the two RAW level bytes are READ through their doors.
#
# CATCHES: `MemoryPressure(rawValue: pressureByte)` / `ServiceState(rawValue: stateByte)` — the raw
# field going straight into the Swift enum again, which restates "an unrecognised byte reads as the
# benign level" beside `slopdesk_wire`'s own copy of that rule. Neither enum has a `compare_abi_enum`
# pin, so a renumber on one side is invisible; the doors are what make the reading single.
SWIFT_METADATA=Sources/SlopDeskProtocol/Metadata/MetadataCodec.swift
for door in slopdesk_metadata_memory_pressure slopdesk_metadata_service_state; do
  if ! grep -q "${door}(" "${SWIFT_METADATA}"; then
    fail "${SWIFT_METADATA} no longer calls ${door} — the level readings are rust/slopdesk-wire's"
  fi
done
for raw in 'MemoryPressure(rawValue: pressureByte)' 'ServiceState(rawValue: stateByte)'; do
  if grep -qF "${raw}" "${SWIFT_METADATA}"; then
    fail "${SWIFT_METADATA} reads a raw level byte directly again — go through the door"
  fi
done

# B2 — the dead Rust launch-preset expansion stays deleted.
#
# CATCHES: `templates::plan` / `LaunchPlan` / `PaneLaunch` / `TemplatePane::keystrokes` coming back.
# The expansion is `LaunchPresetEngine.plan`'s and stays Swift (docs/55 §8); a Rust copy that nothing
# calls cannot be caught disagreeing, because no input ever reaches both — and `dead_code` cannot see
# a `pub` item in a library crate, so nothing else would notice either. The one it had already drifted
# on: `TemplatePane::keystrokes` hardcoded `None` for the cwd and so could not emit a `cd` line.
RUST_TEMPLATES=rust/slopdesk-workspace/src/templates.rs
for revived in 'pub fn plan(' 'struct LaunchPlan' 'struct PaneLaunch' 'pub fn keystrokes(&self)'; do
  if grep -qF "${revived}" "${RUST_TEMPLATES}"; then
    fail "${RUST_TEMPLATES} grew '${revived}' back — the preset expansion is LaunchPresetEngine.plan's"
  fi
done

# B4 — ONE pacing schedule and ONE pacing gap, whichever drain sends the frame.
#
# CATCHES: the chunk/deadline arithmetic, or a second gap computation, growing back in the session.
# `SLOPDESK_SEND_LANE=0` runs the same job on the session actor instead of the lane, and it used to
# hand-roll both: it chunked and deadlined the frame itself, and — having no `keyframe` in scope —
# floored EVERY frame at the delta pace target. So the gate documented as a byte-identical fallback
# actually paced a recovery IDR off a post-backoff ABR, serializing for hundreds of ms the one frame
# whose delivery time IS the client's recovery time. Nothing could fail on it: the inline path has no
# test, and the two paths are never both live. The gap is now computed once by the caller and the
# schedule comes from `slopdesk_send_pace_plan` through `VideoSendLane.plan`, which both drains ask.
VH_SESSION=Sources/SlopDeskVideoHost/SlopDeskVideoHostSession.swift
VH_LANE=Sources/SlopDeskVideoHost/VideoSendLane.swift
if ! grep -q 'VideoSendLane.plan(for: job)' "${VH_SESSION}"; then
  fail "${VH_SESSION} stopped asking VideoSendLane.plan — the paced-send schedule is slopdesk_send_pace_plan's"
fi
if [[ "$(grep -c 'Self.adaptivePaceGapNanos(' "${VH_SESSION}")" -ne 1 ]]; then
  fail "${VH_SESSION} computes the pacing gap twice again — the two copies had already parted on keyframes"
fi
if ! grep -q 'slopdesk_send_pace_plan(' "${VH_LANE}"; then
  fail "${VH_LANE} stopped calling slopdesk_send_pace_plan — the chunk boundaries would be hand-rolled again"
fi

# B1 — the two shipped tables are the CRATE's, and there is no second copy of them.
#
# CATCHES: `SessionTemplate.builtIns` / `LaunchPreset.builtIns` going back to a Swift literal beside
# the crate's `built_in_*` tables. That is the arrangement CLAUDE.md bans by name, and the cost is
# specific rather than stylistic: a built-in's UUID is FIXED so that re-seeding a workspace MATCHES
# its row instead of appending a second one, so a fourth row added to one side only hands every
# device a different set depending on which side seeded it — surfacing weeks later as a duplicated
# menu row with nothing in any log. `compare_abi_enum` cannot see it (it pins names and numbers it
# was told about), and the differential that used to see it is gone precisely because there is now
# one table. The `builtInID` helper is banned too: it existed only to spell a literal UUID for a
# table, so its return is the shape of the mirror coming back.
SWIFT_MODEL=Sources/SlopDeskWorkspaceModel/Domain
if ! grep -q 'SessionTemplateCrossing.builtInTemplatesFromTheCrate()' "${SWIFT_MODEL}/SessionTemplate.swift"; then
  fail "${SWIFT_MODEL}/SessionTemplate.swift stopped seeding from the crate — the shipped table is templates.rs's"
fi
if ! grep -q 'SessionTemplateCrossing.builtInLaunchPresetsFromTheCrate()' "${SWIFT_MODEL}/LaunchPreset.swift"; then
  fail "${SWIFT_MODEL}/LaunchPreset.swift stopped seeding from the crate — the shipped table is templates.rs's"
fi
for mirrored in SessionTemplate LaunchPreset; do
  if grep -q 'builtInID(' "${SWIFT_MODEL}/${mirrored}.swift"; then
    fail "${SWIFT_MODEL}/${mirrored}.swift spells a built-in UUID again — the rows come from the crate"
  fi
done
for table in built_in_session_templates built_in_launch_presets; do
  if ! grep -q "pub fn ${table}(" rust/slopdesk-workspace/src/templates.rs; then
    fail "rust/slopdesk-workspace/src/templates.rs lost ${table} — Swift seeds a fresh device from it"
  fi
done

# ── B. …and the two compositions staying gone ───────────────────────────────────────────────────
# PORTED — it is part of `workspace-scalar-codec` in `rust/slopdesk-invariants`, where it sits
# beside the door list it is the other half of.

# ── C. Where an anti-flood bucket comes from ────────────────────────────────────────────────────
# The spend door hands the bucket back BY VALUE, so the near side owns the four doubles between
# calls — and for a year it also decided what a NEW one holds. That is not an assignment: a bucket
# that rests empty rather than full swallows the first explicit notification of every attach, and a
# rate limiter is the last place anyone looks for a missing banner.
NOTIFIER_SWIFT=Sources/SlopDeskWorkspaceCore/Connection/CommandCompletionNotifier.swift
if [[ ! -e "${NOTIFIER_SWIFT}" ]]; then
  fail "${NOTIFIER_SWIFT} is gone — the bucket's Swift face moved, so the bans below stopped checking anything (docs/55 §6)"
fi
# CATCHES: either constructor door being dropped, which can only mean the four fields are being
# filled on this side again.
for door in slopdesk_ws_notify_rate_limiter slopdesk_ws_notify_explicit_rate_limiter; do
  if ! grep -qF "${door}" "${NOTIFIER_SWIFT}"; then
    fail "${NOTIFIER_SWIFT} stopped calling ${door} — a resting bucket is RateLimiter::new / ::explicit in rust/slopdesk-workspace's notify (docs/55 §6)"
  fi
done

# ── D. …and the burst that must not be spelled twice ────────────────────────────────────────────
# CATCHES two drifts in one pattern. `SlopDeskWsNotifyRateLimiter(` is the memberwise construction
# that decided `tokens: capacity` on this side; a `= 5` / `= 0.5` default argument on the initialiser
# is the anti-flood POLICY spelled in Swift, and the looser of two spellings is always the one that
# runs. Both are gone; neither would fail a test if it came back.
if spells 'SlopDeskWsNotifyRateLimiter\(|refillPerSecond: Double = |capacity: Double = ' "${NOTIFIER_SWIFT}" > /dev/null; then
  fail "${NOTIFIER_SWIFT} builds or defaults a bucket again — the burst, the refill rate and 'a new bucket rests full' are notify.rs's EXPLICIT_BURST / EXPLICIT_REFILL_PER_SECOND / RateLimiter::new (docs/55 §4, §8)"
fi

# ── E. A vocabulary pin needs a COUNT as well as a map ──────────────────────────────────────────
# `Stepper::ALL` is what the round-trip test walks, and it is hand-maintained. The test already
# catches a seventh case added to `from_index` but not to `ALL` — `from_index(ALL.len())` would
# answer `Some` where it asserts `None`. What NOTHING catches is the other order: a case added to
# the enum and to `index` (which is an exhaustive match, so the compiler forces it) but left out of
# both `from_index` and `ALL`. Then the suite walks six of seven and passes, and the seventh
# stepper's door answers `found: false` — a settings field rendered with no range at all.
#
# CATCHES: exactly that. The enum's variant count against the length `ALL` declares.
STEPPER_RS=rust/slopdesk-settings/src/settings_catalog.rs
stepper_variants=$(awk '
  /^pub enum Stepper \{/ { inside = 1; next }
  inside && /^\}/ { exit }
  inside && /^    [A-Z][A-Za-z]*,$/ { n++ }
  END { print n + 0 }
' "${STEPPER_RS}")
stepper_all=$(awk '
  /^impl Stepper \{/ { inside = 1 }
  inside && /const ALL: \[Self; / {
    match($0, /\[Self; [0-9]+\]/)
    print substr($0, RSTART + 7, RLENGTH - 8)
    exit
  }
' "${STEPPER_RS}")
# EMPTY is not agreement, for `same`'s reason one register up: both sides here are extractions, and
# a rename that broke either would leave "" == "" looking like the healthiest result this can print.
if [[ -z "${stepper_variants}" || -z "${stepper_all}" || "${stepper_variants}" == "0" ]]; then
  fail "the Stepper count gate read one side as EMPTY — its awk extraction over ${STEPPER_RS} has gone stale and stopped comparing anything (docs/55 §8)"
elif [[ "${stepper_variants}" != "${stepper_all}" ]]; then
  fail "${STEPPER_RS} has ${stepper_variants} Stepper cases but ALL declares ${stepper_all} — add the case to ALL and to from_index, or the round-trip test walks a vocabulary it no longer covers (docs/55 §8)"
fi

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

# ── The two writers of the green-tree marker must mean the same thing by it ────────────────────
# `pre-push-test.sh` and `test-touched.sh` both WRITE `.build/pre-push-green-tree`, and each decides
# whether it may from a `git status --porcelain --` pathspec naming the inputs `swift test` consumes.
# That is one list spelled twice: a path added to one only is a marker the other records over a tree
# it would itself have called dirty, and the marker is read back as a promise about content. It stays
# a promise about the SAME content only while the two agree.
#
# `scripts/` was missing from both for as long as both existed, while the fast loop's SELECTION
# already attributed a scripts edit to the suite that owns those tests — they open `scripts/*.sh` off
# disk at run time. The list knew about the input in one place and not the other two.
cache_specs=$(
  for script in scripts/pre-push-test.sh scripts/test-touched.sh; do
    grep -oE 'git status --porcelain -- [^)]*' "${script}" | sed 's| 2> */dev/null||; s| *$||' | head -1
  done
) || true
if [[ "$(printf '%s\n' "${cache_specs}" | grep -c .)" -ne 2 ]]; then
  fail "the tested-inputs pathspec could not be read out of BOTH test scripts — this gate has gone stale"
fi
if [[ "$(printf '%s\n' "${cache_specs}" | sort -u | grep -c .)" -ne 1 ]]; then
  printf '%s\n' "${cache_specs}" >&2
  fail "pre-push-test.sh and test-touched.sh disagree on which inputs must be clean to record a green"
fi
# And the marker NAMES themselves, as sets rather than as a spelled-out pair. The first draft asked
# `grep -qF pre-push-green-ffi` of each script, which a rename to `pre-push-green-ffi-stamp` passes
# by substring — a check that survives the edit it exists to catch. Both files must name the same
# markers, whatever they are called this week.
cache_markers=$(
  for script in scripts/pre-push-test.sh scripts/test-touched.sh; do
    grep -ohE '\.build/pre-push-[a-z0-9-]+' "${script}" | sort -u | paste -sd, -
  done
) || true
if [[ "$(printf '%s\n' "${cache_markers}" | grep -c .)" -ne 2 ]]; then
  fail "neither test script names a .build/pre-push-* marker — this gate has gone stale"
fi
if [[ "$(printf '%s\n' "${cache_markers}" | sort -u | grep -c .)" -ne 1 ]]; then
  printf '%s\n' "${cache_markers}" >&2
  fail "pre-push-test.sh and test-touched.sh do not name the same green-tree markers"
fi

# ── The liveness bytes, which no door can pin ──────────────────────────────────────────────────
# `pane/liveness` carries a frozen byte per state, and BOTH languages spell the three arms:
# `slopdesk-wire`'s `PaneLivenessState` and `SlopDeskWorkspaceModel`'s enum of the same name.
#
# A door was tried for exactly this and could not work, which is why the check is here instead. It
# exported "the byte for arm N" so the Swift side would never transcribe a frozen number — but a
# Swift enum's raw values must be COMPILE-TIME constants, so no call can supply them. The door was
# uncallable by construction, sat dead behind `check-ffi-doors.py`, and the transcription it was
# written to prevent happened anyway one file over. A ratchet can do what the door could not:
# compare the two arm lists as TEXT, before either is compiled.
rust_liveness=$(
  sed -n '/^pub enum PaneLivenessState {/,/^}/p' rust/slopdesk-wire/src/document/fields.rs |
    grep -oE '^\s+(Attached|Detached|Dead) = [0-9]+,' |
    tr -d ' ,' | tr '[:upper:]' '[:lower:]' | paste -sd, -
) || true
swift_liveness=$(
  sed -n '/^public enum PaneLivenessState/,/^}/p' Sources/SlopDeskWorkspaceModel/State/WorkspaceFields.swift |
    grep -oE '^\s+case (attached|detached|dead) = [0-9]+' |
    sed 's/^ *case //' | tr -d ' ' | paste -sd, -
) || true
if [[ -z "${rust_liveness}" || -z "${swift_liveness}" ]]; then
  fail "PaneLivenessState could not be read from one of its two halves — this gate has gone stale"
fi
if [[ "${rust_liveness}" != "${swift_liveness}" ]]; then
  printf 'rust:  %s\nswift: %s\n' "${rust_liveness}" "${swift_liveness}" >&2
  fail "the two PaneLivenessState enums disagree — these bytes ride in pane/liveness cells and are frozen"
fi

printf 'check-supervisor: one deadline latch, one clipboard clip, one sidecar encoder, one channel tag, no dangling doc link, no doc citing a file that is gone, no gate that dies quietly, one meaning for the green-tree marker, one liveness byte per arm.\n'

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

# ── THE ANDROID KEYCODE TABLE ONLY EVER SHRINKS ────────────────────────────────────────────────
#
# `FunctionalKey::android_keycode` in `rust/slopdesk-devicepanel/src/panel_key.rs` is the one table
# that says what Android number a functional key is. `AndroidKeycode.swift` used to spell thirteen
# of those numbers a second time, and every one of them was reached by nothing: the panel's live
# path gets its keycode from the door (`AndroidKeycode(bigEndian(...))`), and the only named
# constants anything presses are `.home` and `.appSwitch`, which the Rust table does not carry.
#
# A dead duplicate of a live number is worse than a live one — it reads as authoritative and it can
# never be caught disagreeing, because no input ever reaches both copies (docs/55 §8). So the shape
# is pinned rather than the names: this counts how many literals `AndroidKeycode.swift` spells that
# `panel_key.rs` already answers, and fails if that count goes UP.
#
# The count is now ZERO and the mark is set there, so the ratchet has reached its floor: the `-gt`
# arm is the whole gate, and it fires the moment one comes back. The `-lt` arm below is unreachable
# at zero by construction — a count cannot be negative — and it is kept rather than deleted because
# the mark is the thing that moves, and the arm is what makes lowering it mandatory rather than
# optional if this ever has to be raised for a real reason and walked back down again.
#
# Both sides are DERIVED. A list of banned numbers maintained here would drift from the Rust table
# the first time a key was added, which is the same defect one register up.
ANDROID_KEYCODE_SWIFT=Sources/SlopDeskDevicePanels/Android/AndroidKeycode.swift
ANDROID_KEYCODE_RUST=rust/slopdesk-devicepanel/src/panel_key.rs
# The high-water mark, and the floor. Lower it whenever one goes; never raise it.
ANDROID_KEYCODE_DUPES_MAX=0

if [[ ! -f "${ANDROID_KEYCODE_SWIFT}" ]] || [[ ! -f "${ANDROID_KEYCODE_RUST}" ]]; then
  fail "the Android keycode ratchet lost a path it reads — a gate that reads nothing agrees with nothing"
else
  # `|| true` on both: a `grep` that matches nothing exits 1, and under `set -e` that kills the run
  # before the emptiness check below ever executes — so the guard that exists to catch a broken
  # extraction could never see one. The `|| true` is what LETS the vacuity check do its job; it does
  # not weaken it.
  android_keycode_rust_answers=$(
    grep -oE 'Some\([0-9]+\)' "${ANDROID_KEYCODE_RUST}" | grep -oE '[0-9]+' | sort -u || true
  )
  android_keycode_swift_literals=$(
    grep -oE 'Self\([0-9]+\)' "${ANDROID_KEYCODE_SWIFT}" | grep -oE '[0-9]+' | sort -u || true
  )
  # A gate that would pass vacuously is not a gate. At a mark of zero an EMPTY intersection is the
  # expected answer, so an extraction that broke (a refactor to `Self(rawValue:)`, a match arm
  # rewritten) would read exactly like success. Both sides are therefore required to parse to
  # something before the comparison is believed.
  if [[ -z "${android_keycode_rust_answers}" ]]; then
    fail "no keycodes parsed out of ${ANDROID_KEYCODE_RUST} — this gate would pass vacuously"
  elif [[ -z "${android_keycode_swift_literals}" ]]; then
    fail "no keycodes parsed out of ${ANDROID_KEYCODE_SWIFT} — this gate would pass vacuously"
  else
    android_keycode_dupes=$(
      comm -12 <(printf '%s\n' "${android_keycode_rust_answers}") \
        <(printf '%s\n' "${android_keycode_swift_literals}")
    )
    android_keycode_dupe_count=$(printf '%s' "${android_keycode_dupes}" | grep -c '[0-9]' || true)
    if [[ "${android_keycode_dupe_count}" -gt "${ANDROID_KEYCODE_DUPES_MAX}" ]]; then
      fail "$(
        printf '%s spells %s keycode(s) panel_key.rs already answers (%s), was %s — the table only shrinks (docs/55 §8)' \
          "${ANDROID_KEYCODE_SWIFT}" "${android_keycode_dupe_count}" \
          "$(printf '%s' "${android_keycode_dupes}" | tr '\n' ' ')" "${ANDROID_KEYCODE_DUPES_MAX}"
      )"
    elif [[ "${android_keycode_dupe_count}" -lt "${ANDROID_KEYCODE_DUPES_MAX}" ]]; then
      fail "$(
        printf 'the Android keycode duplicates are down to %s from %s — lower ANDROID_KEYCODE_DUPES_MAX to %s so the ground gained is held' \
          "${android_keycode_dupe_count}" "${ANDROID_KEYCODE_DUPES_MAX}" "${android_keycode_dupe_count}"
      )"
    fi
  fi
fi
printf 'check-supervisor: the Android keycode table spells no number panel_key.rs has not already lost.\n'

# ══════════════════════════════════════════════════════════════════════════════════════════════
#  SPLICE POINT: anywhere AFTER `repo_files` / `spells` are defined (scripts/check-supervisor.sh
#  line 3527). These three read the two UI targets and the floor between them; nothing above 3527
#  is needed and nothing below depends on them.
# ══════════════════════════════════════════════════════════════════════════════════════════════

# ── The two shells do not write the same code twice (docs/56 §3) ────────────────────────────────
# The gates already here catch a file in the WRONG TARGET — frameworkless, or platform-gated. They
# cannot catch the thing that actually happened nine times over: a helper, a copy string or a
# constant that is in the RIGHT target on both sides and spelled twice. `ensureEndpoint` sat in both
# panel files with a static dedupe key each, pointed at ONE host-global settings file. The Open
# Quickly picker assembled the same five corpora and snapshotted the same eighteen lines of focused
# pane in both halves. Every label on the Connect form was typed twice — including three port
# prompts that were one slot off the real defaults on BOTH sides, which is precisely how a duplicate
# hides a bug: the two copies agreed, so nothing disagreed with them.
#
# So these three ask a different question from every rule above. Not "is this import missing" — a
# duplicated helper imports fine — but "does this body / this sentence / this number appear on both
# sides of a split whose whole purpose is that it does not".

# RULE 1 · NO CROSS-TARGET CLONE. Eight consecutive substantive lines that appear, normalised, in
# both `SlopDeskMacUI` and `SlopDeskPhoneUI`. Normalising strips `//` comments, indentation and
# lines that are only punctuation, so a reformat or a re-worded comment cannot hide a clone and a
# lone `}` cannot manufacture one. `import`, `@attribute` and `#if` lines are dropped: two view
# files legitimately import the same six modules, and that is a coincidence of the split rather than
# a duplicated decision.
#
# EIGHT, not four, and the reason is in the ALLOWLIST's absence rather than its contents. At six the
# rule fired on thin forwarders — three one-line bodies that each call the SAME shared floor type,
# which is the FIX rendering as a violation. At eight only real blocks survive.
#
# ⚠️ THE ALLOWLIST IS A DEBT LIST, NOT A CARVE-OUT. Each pair below is a clone that is still in the
# tree, named so this rule can be green about everything else; a line leaves this list by being
# deduplicated, never by being tolerated. Two of them (`CodePanelSurfaces`, `SlopDeskPhoneApp`) have
# their floor types written already — `CodeServerEnsure` and `ClientNotificationSinks` — and are
# waiting only on the phone-side edit.
#
# BREAK-TEST (2026-08-22): copied `Sources/SlopDeskClientCore/Settings/KeybindingsEditorReading.swift`'s
# `conflictLines(_:)` body back into BOTH `MacKeybindingsEditor.swift` and `KeybindingsEditorView.swift`
# as private methods — the exact shape this change removed. Rule FIRED, naming both sites. Restored
# both files by `cp` from /tmp; rule green. Also verified the inverse: with the tree as it stands the
# rule prints only the allowlisted pairs, i.e. it is not passing by finding nothing.
ui_clone_allow=(
  # GUI/video pane leaf — the largest remaining pair, and the next one worth a floor file.
  "Sources/SlopDeskMacUI/Pane/MacGuiLeafView.swift Sources/SlopDeskPhoneUI/Pane/GuiLeafView.swift"
  "Sources/SlopDeskMacUI/Pane/MacTerminalFindBar.swift Sources/SlopDeskPhoneUI/Pane/TerminalFindBar.swift"
  "Sources/SlopDeskMacUI/Pane/MacTerminalLeafView.swift Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift"
  "Sources/SlopDeskMacUI/Pane/MacPromptJumpFlashOverlay.swift Sources/SlopDeskPhoneUI/Pane/PromptJumpFlashOverlay.swift"
  # Waiting on `CodeServerEnsure` being called from the phone half.
  "Sources/SlopDeskMacUI/Panel/MacCodePanelSurfaces.swift Sources/SlopDeskPhoneUI/CodeSidebar/CodePanelSurfaces.swift"
  "Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift Sources/SlopDeskPhoneUI/WorkspaceRootView.swift"
  # Waiting on `ClientNotificationSinks` being called from the phone half.
  "Sources/SlopDeskMacUI/SlopDeskMacApp.swift Sources/SlopDeskPhoneUI/SlopDeskPhoneApp.swift"
)

ui_clone_shingles() {
  local tag="$1"
  shift
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    awk -v f="${file}" -v tag="${tag}" -v n=8 '
      { line = $0
        sub(/\/\/.*/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line ~ /^([[:punct:]]|[[:space:]])*$/) next
        if (line ~ /^(import|@|#(if|else|elseif|endif))/) next
        k++; buf[k] = line; ln[k] = NR }
      END {
        for (i = 1; i + n - 1 <= k; i++) {
          s = buf[i]
          for (j = 1; j < n; j++) s = s " ~ " buf[i + j]
          printf "%s\t%s\t%s:%d\n", s, tag, f, ln[i]
        } }' "${file}"
  done < <(repo_files "$@")
}

ui_mac_files=$(repo_files 'Sources/SlopDeskMacUI/*.swift' 'Sources/SlopDeskMacUI/**/*.swift' | wc -l)
ui_phone_files=$(repo_files 'Sources/SlopDeskPhoneUI/*.swift' 'Sources/SlopDeskPhoneUI/**/*.swift' | wc -l)
if ((ui_mac_files < 50 || ui_phone_files < 50)); then
  fail "only ${ui_mac_files}/${ui_phone_files} files globbed under the two UI targets — this gate would pass by reading nothing"
fi

ui_clones=$(
  {
    ui_clone_shingles mac 'Sources/SlopDeskMacUI/*.swift' 'Sources/SlopDeskMacUI/**/*.swift'
    ui_clone_shingles phone 'Sources/SlopDeskPhoneUI/*.swift' 'Sources/SlopDeskPhoneUI/**/*.swift'
  } | sort -t$'\t' -k1,1 -k2,2 | awk -F'\t' '
      { if ($1 != prev) { prev = $1; seen = $2; site = $3; next }
        if ($2 != seen) { print site "\t" $3; prev = "" } }' | sort -u
)
ui_clone_hits=""
while IFS=$'\t' read -r mac_site phone_site; do
  [[ -z "${mac_site}" ]] && continue
  pair="${mac_site%%:*} ${phone_site%%:*}"
  allowed=""
  for known in "${ui_clone_allow[@]}"; do
    [[ "${pair}" == "${known}" ]] && allowed=1 && break
  done
  [[ -n "${allowed}" ]] || ui_clone_hits+="${mac_site}  ==  ${phone_site}"$'\n'
done <<< "${ui_clones}"
if [[ -n "${ui_clone_hits}" ]]; then
  printf '%s' "${ui_clone_hits}" >&2
  fail "eight identical lines in both UI targets — one implementation, never two (docs/56 §3, CLAUDE.md)"
fi

# RULE 2 · A NAMED SENTENCE HAS ONE SPELLER. Every literal below was typed once per shell and now
# lives in the shared logic target; a UI target that spells one raw again has re-forked it. Named
# individually rather than counted, because the failure message can then say WHERE the sentence
# lives, and because the ban is what makes the floor symbol the only way to reach the words.
#
# This is not a style rule. A user-facing string spelled twice is a translation bug that has already
# happened — the day one half is reworded the two platforms ship different copy for the same control
# and nothing notices. The keybindings editor alone had ten, including a destructive confirmation
# whose title, body and both buttons were duplicated.
#
# BREAK-TEST (2026-08-22): reverted `MacConnectSheet.swift`'s title to the literal `"Connect to Host"`
# and `KeybindingsEditorView.swift`'s dialog title to `"Reset all key bindings?"`. Rule FIRED on both,
# each naming its floor symbol. Restored by `cp` from /tmp; rule green. Confirmed non-vacuous by
# checking that each pattern below matches inside the floor file that owns it.
ui_owned_copy=(
  "Connect to Host|ConnectForm.title"
  "host.local or 10.0.0.7|ConnectForm.hostPrompt"
  "Video ports|ConnectForm.videoPortsLabel"
  "Media port|ConnectForm.mediaPortLabel"
  "Cursor port|ConnectForm.cursorPortLabel"
  "Keyboard Shortcuts|KeybindingsEditorCopy.title"
  "Click a shortcut to record a replacement|KeybindingsEditorCopy.subtitle"
  "Search key bindings|KeybindingsEditorCopy.searchPrompt"
  "Reset to Default|KeybindingsEditorCopy.resetAction"
  "Reset every customized shortcut to its default|KeybindingsEditorCopy.resetHelp"
  "Reset all key bindings\?|KeybindingsEditorCopy.resetConfirmTitle"
  "This clears every customized shortcut|KeybindingsEditorCopy.resetConfirmBody"
  "Shortcut conflicts|KeybindingsEditorCopy.conflictsTitle"
  "This shortcut conflicts with another command|KeybindingsEditorCopy.conflictHelp"
  "Dismiss notification|ToastPresentation.dismissLabel"
  "Jump to the pane this notification came from|ToastPresentation.jumpHint"
  "Search across all tabs…|GlobalSearchPresentation.queryPrompt"
  "Search for commands…|PalettePresentation.queryPrompt"
)
for entry in "${ui_owned_copy[@]}"; do
  phrase="${entry%%|*}"
  owner="${entry##*|}"
  # shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
  leak=$(spells "\"${phrase}" \
    $(repo_files 'Sources/SlopDeskMacUI/*.swift' 'Sources/SlopDeskMacUI/**/*.swift' \
      'Sources/SlopDeskPhoneUI/*.swift' 'Sources/SlopDeskPhoneUI/**/*.swift') 2> /dev/null || true)
  if [[ -n "${leak}" ]]; then
    printf '%s\n' "${leak}" >&2
    fail "a UI target respells copy that ${owner} owns — a sentence typed twice is a translation bug (docs/56 §3)"
  fi
done

# RULE 3 · THE SHARED-VOCABULARY CEILING, so the rule above does not only catch what it already
# knows. A COUNT rather than a presence: how many distinct capitalised phrase literals are spelled
# in BOTH UI targets. It may go DOWN freely and never up, which makes every new duplicate a failure
# without anyone having to predict which sentence it will be.
#
# Capitalised and ≥4 characters is the user-facing filter: an SF Symbol name, a defaults key and a
# JSON field are lowercase or dotted, and a bare `"OK"` is the platform's word rather than ours.
#
# ⚠️ RE-PIN AFTER A DELIBERATE MERGE, never raise to make a change fit. The remaining 33 are the GUI
# pane control block (ten of them, the next floor file worth writing), the panel strip's three
# reload tooltips, the `SLOPDESK_AUTOCONNECT_HOST` gate name spelled in three places (docs/46 says
# one accessor), and the bare system verbs — Done / Cancel / Close / Back / Next / Settings — which
# are deliberately NOT merged: those are the platform's words for the platform's buttons, and one
# constant behind them would buy an indirection and no agreement.
#
# BREAK-TEST (2026-08-22), both directions.
#   UP: replaced `ConnectForm.videoPortsLabel` with the literal `"Advanced Transport Options"` in
#   BOTH `MacConnectSheet.swift` and `ConnectHostView.swift` — a phrase rule 2 has never heard of,
#   so only the ceiling can see it. Count read 34, rule FIRED naming both numbers and printing the
#   whole shared set. Restored by `cp` from /tmp; count read 33, green.
#   DOWN: renamed ONE side of an existing pair (`"FPS cap"` → `"Frames per second cap"` in
#   `MacGuiPaneControls.swift`). Count fell to 32 and the rule stayed green — it bites upward only,
#   which is what makes it a ratchet rather than a pin. Restored by `cp`.
ui_shared_copy_ceiling=33
ui_shared_literals() {
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    sed -E 's,//.*,,' "${file}" | grep -oE '"[A-Z][^"\\]{3,}"' || true
  done < <(repo_files "$@") | sort -u
}
ui_shared_copy=$(comm -12 \
  <(ui_shared_literals 'Sources/SlopDeskMacUI/*.swift' 'Sources/SlopDeskMacUI/**/*.swift') \
  <(ui_shared_literals 'Sources/SlopDeskPhoneUI/*.swift' 'Sources/SlopDeskPhoneUI/**/*.swift'))
ui_shared_copy_count=$(printf '%s\n' "${ui_shared_copy}" | grep -c . || true)
if ((ui_shared_copy_count > ui_shared_copy_ceiling)); then
  printf '%s\n' "${ui_shared_copy}" >&2
  fail "${ui_shared_copy_count} phrases are spelled in BOTH UI targets, ceiling ${ui_shared_copy_ceiling} — a new one belongs in SlopDeskClientCore (docs/56 §3)"
fi

printf 'check-supervisor: the two shells share a floor, not a clipboard — no cross-target clone, %d shared phrases (ceiling %d).\n' \
  "${ui_shared_copy_count}" "${ui_shared_copy_ceiling}"

# ── N. THE PHONE'S CAPABILITIES, which are not allowed to be the Mac's minus a few ───────────────
#
# The user's rule for this app is one sentence: the iOS app differs from the macOS app in LAYOUT and
# in nothing else. Every rule in this block pins one capability that was Mac-only until it was
# closed, and each of them was Mac-only in the same way — not by a decision, but because the phone's
# renderer was written later and something did not get carried across. That is precisely the failure
# a ratchet catches and a review does not: nobody deletes a capability, it just fails to be added
# back the next time a file is rewritten.
#
# Every rule below was BREAK-TESTED against the real tree — the file was edited back to the banned
# shape, the rule was run, and the verdict is recorded in the rule's own comment.

mapfile -t phone_panel_files < <(
  repo_files 'Sources/SlopDeskPhoneUI/Panel/*.swift' 'Sources/SlopDeskPhoneUI/Panel/*/*.swift'
)

# N.1 — THE PHONE HAS A ROOT KEY RUNG.
#
# The phone's whole chord dispatcher used to be the focused TERMINAL pane's responder, so ⌘⇧P, ⌘T,
# ⌘D, ⌘1–9, ⌃⇥ and ⌘⇧O were dead over a desktop/GUI pane, dead with no pane focused, and dead under
# the panel's cover — every one of them live on the Mac, whose `NSEvent` monitor is application-wide.
# The rung that fixed it can only be at the END of the responder chain, and on this platform the app
# DELEGATE is the only object that is there for every window: a `UIView` mounted by a SwiftUI
# `.background` is a SIBLING of the content, absent from the chain a focused terminal walks. So the
# adaptor is the rule. Losing it is silent — no build error, no test failure, just chords that stop
# working outside a terminal, which is exactly the state this replaced.
#
# BREAK-TEST: `UIApplicationDelegateAdaptor(PhoneRootKeyResponder.self)` → `(SomeOtherDelegate.self)`
# in SlopDeskPhoneApp.swift ⇒ FAIL "the phone's root key rung is not mounted". Restored; PASS.
if [[ -f Sources/SlopDeskPhoneUI/SlopDeskPhoneApp.swift ]] &&
  ! grep -qE 'UIApplicationDelegateAdaptor\(PhoneRootKeyResponder\.self\)' \
    Sources/SlopDeskPhoneUI/SlopDeskPhoneApp.swift; then
  fail "the phone's root key rung is not mounted — SlopDeskPhoneApp must carry @UIApplicationDelegateAdaptor(PhoneRootKeyResponder.self), or every workspace chord dies outside a terminal pane (docs/56 §3)"
fi

# N.2 — THE ROOT RUNG ASKS THE SHARED POLICY, and does not re-spell the decision in the view target.
#
# Which rung a press lands on (workspace / panel-escape / yield) is a DECISION, and the split's rule
# is that a decision lives below the UI targets. `PhoneRootKeyPolicy` is that decision; the responder
# is allowed to know UIKit and nothing else.
#
# BREAK-TEST: replaced the `PhoneRootKeyPolicy.rung(...)` call with an inline `if panelPresented …`
# chain ⇒ FAIL "the phone's root key rung re-spells its own precedence". Restored; PASS.
if [[ -f Sources/SlopDeskPhoneUI/Pane/PhoneRootKeyResponder.swift ]] &&
  ! grep -qE 'PhoneRootKeyPolicy\.rung' Sources/SlopDeskPhoneUI/Pane/PhoneRootKeyResponder.swift; then
  fail "the phone's root key rung re-spells its own precedence — it must ask PhoneRootKeyPolicy.rung, which is the shared decision (docs/56 §3)"
fi

# N.3 — ⌘C / ⌘X / ⌘V / ⌘A REACH THE PHONE'S TERMINAL.
#
# The binding table deliberately does not claim C/X/V/A ("handled by the terminal's own copy
# responder"), which is true on a Mac — AppKit's standard editing selectors land on the terminal view
# because it IS the window's first responder. On the phone the pane's first responder is a zero-sized
# sibling of the renderer, so the four chords resolved to nothing at all and a ⌘ combination encodes
# to no bytes: they died in silence. `keyCommands` is what puts them back, and it must stay in the
# pane's responder rather than becoming a second implementation of copy and paste somewhere.
#
# BREAK-TEST: deleted the `override var keyCommands` block from TerminalInputHost.swift ⇒ FAIL "the
# phone's terminal has no editing chords". Restored from /tmp; PASS.
if [[ -f Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift ]] &&
  ! grep -qE 'override var keyCommands' Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift; then
  fail "the phone's terminal has no editing chords — TerminalInputHost must declare keyCommands for ⌘C/⌘X/⌘V/⌘A, which no other rung can carry (the table leaves C/X/V/A to the terminal)"
fi

# N.4 — A LITERAL-BYTE BINDING FIRES ON BOTH SHELLS.
#
# `keybind = cmd+shift+h=text:hello` is ONE config file read by both clients. It sent bytes on the
# Mac (`WorkspaceKeyDispatcher`) and did nothing whatever on the phone, which is one config producing
# two behaviours — the worst shape a shared setting can take, because the user has no way to tell
# that the phone even read the line. The phone answers it on the PANE's rung, where the keyboard
# actually is.
#
# BREAK-TEST: removed the `WorkspaceBindingRegistry.textBinding(for: chord)` arm from
# `swallowsAsWorkspaceChord` ⇒ FAIL "a text:/csi:/esc: binding is Mac-only again". Restored; PASS.
if [[ -f Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift ]] &&
  ! grep -qE 'WorkspaceBindingRegistry\.textBinding' Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift; then
  fail "a text:/csi:/esc: binding is Mac-only again — the phone's pane responder must consult WorkspaceBindingRegistry.textBinding, or one shared config file produces two behaviours"
fi

# N.5 — AN `unbind:` TARGET LOSES ITS ACTION ON EVERY RUNG.
#
# The Mac's dispatcher has always honoured `unbind:`; the shared interceptor did not, so an unbound
# chord still fired its default action wherever the interceptor is the resolver — both of the phone's
# rungs, and the Mac's own terminal surface whenever a press reached it rather than the monitor.
# Asked inside `makeKeyInterceptor`, which is the one resolve all of them share.
#
# BREAK-TEST: deleted the `!WorkspaceBindingRegistry.isUnbound(chord)` clause from the factory's
# `resolveChord` ⇒ FAIL "the shared key interceptor ignores unbind:". Restored; PASS.
if [[ -f Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Keybinding.swift ]] &&
  ! grep -qE 'WorkspaceBindingRegistry\.isUnbound' \
    Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Keybinding.swift; then
  fail "the shared key interceptor ignores unbind: — makeKeyInterceptor must drop an unbound chord's action, or the same config file unbinds a chord on one shell only"
fi

# N.6 — THE CODE PANEL DOES NOT RE-ENSURE A PROJECT IT HAS ALREADY SETTLED.
#
# The Mac's panel is faded when collapsed, so its poll task is never cancelled and never re-entered.
# The phone's is a `.fullScreenCover`, so every dismissal cancels it and every re-open re-enters —
# and an unguarded `poll` opens by writing `.starting`, which flashed the spinner over a workbench
# that was already loaded and re-ensured a project the host had long since brought up. The guard is
# what makes the two shells one behaviour; `requestReload()` unsettling is its other half, without
# which the reload button would cancel a finished loop and start one that returns immediately.
#
# BREAK-TEST: deleted the `if case let .ready(settledRoot, _) = phase` guard ⇒ FAIL "the code panel
# re-ensures a settled project". Separately deleted `phase = .starting` from `requestReload()` ⇒ FAIL
# "the code panel's reload cannot unsettle". Both restored; PASS.
if [[ -f Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarModel.swift ]]; then
  if ! grep -qE 'case let \.ready\(settledRoot, _\) = phase' \
    Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarModel.swift; then
    fail "the code panel re-ensures a settled project — CodeSidebarModel.poll must return early on a root it has already settled, or the phone's cover flashes its spinner on every re-open"
  fi
  if ! grep -qE 'func requestReload\(\) \{' Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarModel.swift ||
    ! sed -n '/func requestReload() {/,/^    }/p' \
      Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarModel.swift | grep -qE 'phase = \.starting'; then
    fail "the code panel's reload cannot unsettle — requestReload() must clear the settled phase, or the reload button restarts a loop that returns on its first line"
  fi
fi

# N.7 — THE PHONE CAN OPEN THE PANEL ON A NAMED SURFACE.
#
# The Mac's collapsed panel leaves a RAIL: four named plates, any of which opens the panel ON that
# surface in one click. The phone had a bare toggle that reopened on whatever was last selected, so
# reaching Emulators from closed was two taps with nothing on screen naming the second. The phone's
# answer is a menu over the same four readings — same words, same order, one gesture — and it has to
# be over `PanelTabs.all` rather than a list written out here, which is the whole reason that reading
# exists.
#
# BREAK-TEST: replaced the `ForEach(PanelTabs.all…)` menu with the old bare `Button { toggle() }` ⇒
# FAIL "the phone cannot open the panel on a named surface". Restored; PASS.
if [[ -f Sources/SlopDeskPhoneUI/WorkspaceRootView.swift ]] &&
  ! grep -qE 'ForEach\(PanelTabs\.all' Sources/SlopDeskPhoneUI/WorkspaceRootView.swift; then
  fail "the phone cannot open the panel on a named surface — the toolbar's panel control must offer PanelTabs.all, which is the Mac rail's capability on a device with no rail"
fi

# N.8 — A PANEL TAB IS CALLED BY ITS NAME, not read out as a sentence.
#
# The two shells had drifted to opposite answers: the Mac's plate set its accessibility label from
# `tab.label` and the phone's from `tab.help`, so a screen-reader user on the phone heard a whole
# explanatory sentence every time focus moved across four tabs. The label/hint split is cut once in
# `PanelTabReading`; a renderer reaching for `help` as a LABEL is the drift coming back.
#
# BREAK-TEST: `.accessibilityLabel(tab.accessibilityLabel)` → `.accessibilityLabel(tab.help)` in
# PhonePanelSheet.swift ⇒ FAIL "a panel tab reads its help text as its name". Restored; PASS.
if leak=$(spells 'accessibilityLabel\(tab\.help\)' "${phone_panel_files[@]}"); then
  fail "a panel tab reads its help text as its name (${leak}) — the label is the WORD (PanelTabReading.accessibilityLabel); the sentence is the HINT"
fi

# N.9 — ONE CLEAR KEY FOR EVERY FILTER FIELD IN THE DEVICE PANELS.
#
# `SlateSearchField` hands the plate — and with it the trailing clear affordance — to its caller, and
# four callers took that four different distances: both device LISTS drew the key and neither CONSOLE
# drew anything, so a typed filter over a log could only be undone by backspacing it. Cut once into
# `DevicePanelChrome.clearKey`. The ban is on drawing it inline again, which is how the four copies
# happened the first time.
#
# The one place allowed to spell it is filtered OUT OF THE CORPUS rather than compared against
# `spells`'s answer. `spells` returns the FIRST file that matches and stops, so an exemption written
# as `if [[ "$leak" != "…/DevicePanelChrome.swift" ]]` passes for every corpus that contains the
# exempt file — it is the first hit, and the real leak behind it is never looked at. That is not a
# hypothetical: the first draft of this rule was written that way and its break-test PASSED the
# banned shape (verified: inline key pasted back into SimulatorDeviceList.swift ⇒ FAILURES=0).
#
# BREAK-TEST: pasted the old inline `Button { query = "" } label: { Image(systemSymbol:
# .xmarkCircleFill) … }` back into SimulatorDeviceList.swift ⇒ FAIL "a device panel spells its own
# clear key (…/SimulatorDeviceList.swift)". Restored from /tmp; PASS.
clear_key_corpus=()
for file in "${phone_panel_files[@]}"; do
  [[ "${file}" == */DevicePanelChrome.swift ]] && continue
  clear_key_corpus+=("${file}")
done
if leak=$(spells 'Image\(systemSymbol: \.xmarkCircleFill\)' "${clear_key_corpus[@]}"); then
  fail "a device panel spells its own clear key (${leak}) — DevicePanelChrome.clearKey is the one affordance, and four copies of it is how two of them ended up missing"
fi
# …and both consoles must actually draw one. A list that clears in a tap beside a console that does
# not is the inconsistency this closed, and it is invisible until someone types in the console.
for console in Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorConsoleView.swift \
  Sources/SlopDeskPhoneUI/Panel/Android/AndroidConsoleView.swift; do
  if [[ -f "${console}" ]] && ! grep -qE 'DevicePanelChrome\.clearKey' "${console}"; then
    fail "${console} has no way to clear its filter — its own device list clears in a tap, and the two sit one scroll apart"
  fi
done

# N.10 — A MIRRORED DEVICE CAN BE TYPED INTO WITHOUT A HARDWARE KEYBOARD.
#
# Both mirrors have always typed from a `UIKey`, which is the whole story on a Mac because a Mac has
# a keyboard. The phone this ships on most often has none, and on that phone the mirrored device
# could be tapped, swiped, rotated and screenshotted while remaining impossible to put one character
# into. The soft-keyboard host is the capability; the stage's plate is how it is reached. Both halves
# are pinned, because either one alone is dead code.
#
# BREAK-TEST: deleted the `DeviceSoftKeyboard.shared.register(self)` call from
# AndroidScreenView.swift ⇒ FAIL "the Android mirror cannot take typed text". Separately deleted the
# `keyboard` plate from SimulatorStageView.swift ⇒ FAIL "…has no way to raise the keyboard". Both
# restored from /tmp; PASS.
for mirror in Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorScreenView.swift \
  Sources/SlopDeskPhoneUI/Panel/Android/AndroidScreenView.swift; do
  if [[ -f "${mirror}" ]] && ! grep -qE 'DeviceSoftKeyboard\.shared\.register' "${mirror}"; then
    fail "${mirror} cannot take typed text — a mirror must register with DeviceSoftKeyboard, or a phone with no keys cannot type into the device at all"
  fi
done
for stage in Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorStageView.swift \
  Sources/SlopDeskPhoneUI/Panel/Android/AndroidStageView.swift; do
  if [[ -f "${stage}" ]] && ! grep -qE 'DeviceSoftKeyboard\.shared\.toggle' "${stage}"; then
    fail "${stage} has no way to raise the keyboard — the soft-keyboard host is unreachable without the stage's plate"
  fi
done

# N.11 — A MIRROR FORWARDS THE PRESS IT DOES NOT WANT.
#
# Both mirrors take first responder on TOUCH, so that a hardware keyboard follows the last device
# tapped. That makes them the first rung for every subsequent press — and both used to DROP the ones
# they could not use (`case .none: break`; a ⌘-chord with no device mapping), which meant every
# workspace chord died the moment anyone tapped the picture. The shared rule already calls those
# presses "a chord the client keeps for itself"; keeping one means walking it up the chain, not
# eating it.
#
# BREAK-TEST: `super.pressesBegan(presses, with: event)` → `break` in the `.none` arm of
# AndroidScreenView.swift ⇒ FAIL "the Android mirror eats the chords it cannot use". Restored; PASS.
# (Counted, not merely present: each mirror has one forward in its early guard and one in the arm
# that used to drop the press, so a rule that only asked for the string would have passed the bug.)
for mirror in Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorScreenView.swift \
  Sources/SlopDeskPhoneUI/Panel/Android/AndroidScreenView.swift; do
  if [[ -f "${mirror}" ]] &&
    (($(grep -cE 'super\.pressesBegan\(presses, with: event\)' "${mirror}") < 2)); then
    fail "${mirror} eats the chords it cannot use — an unmapped press must reach super, or tapping the mirror kills every workspace chord until focus moves"
  fi
done

# N.12 — A REGISTERED CHORD REACHES SOMETHING.
#
# The general shape, and it bit this very change: `keyCommands` declared ⌘C/⌘X/⌘V/⌘A, the phone
# swallowed all four, and the sink they were handed to — `TerminalViewModel.onRequestMenuItem` — was
# bound by nobody, so the four chords went from "fall through to the system" to "consumed and
# dropped". A registered chord that reaches nothing is worse than an absent one, because the absent
# one at least lets the default behaviour happen. Two halves, both pinned: the PRODUCER must exist,
# and the registration must be gated on it so the runtime cannot get ahead of the wiring either.
#
# BREAK-TEST: deleted the `model.onRequestMenuItem = { … }` line from GhosttyTerminalView.swift's iOS
# `attach(model:)` ⇒ FAIL "the phone's editing chords are handed to nobody". Separately changed the
# guard back to `live?.terminalModel != nil` ⇒ FAIL "…registers its editing chords unconditionally".
# Both restored from /tmp; PASS.
if [[ -f ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift ]] &&
  ! grep -qE 'onRequestMenuItem = \{' \
    ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift; then
  fail "the phone's editing chords are handed to nobody — the renderer must bind TerminalViewModel.onRequestMenuItem when it attaches, or ⌘C/⌘X/⌘V/⌘A are swallowed and dropped"
fi
if [[ -f Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift ]] &&
  ! grep -qE 'guard live\?\.terminalModel\?\.onRequestMenuItem != nil' \
    Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift; then
  fail "TerminalInputHost registers its editing chords unconditionally — a UIKeyCommand swallows its chord, so it must be offered only while its sink is bound"
fi
# N.13 — THE PHONE'S PASTE PLATE ASKS THE BOARD A QUESTION IT CAN ANSWER IN SILENCE.
#
# Since iOS 16 a read of `UIPasteboard.string` for content this app did not write raises the modal
# "Allow Paste?" alert. `GuiPastePlateMenu.canPasteCurrent` is read from `body`, so while it called
# `currentLocalClipboard()` every render of a remote-GUI pane's footer could put that alert on screen
# unprompted (increment 78). The fix is a DIFFERENT QUESTION, not a different call site: `hasText`
# discloses nothing, so the platform answers it without asking anyone. The Mac's twin may read
# content because it builds its menu in `onClick`; SwiftUI has no equivalent moment, which is why
# this rule is the phone's alone.
#
# Both halves are pinned, because either one alone lets the defect back: the probe must be what
# enablement asks, AND the content read must not reappear in that property. The CONTENT read inside
# the Button's action is correct and deliberately untouched — the tap IS the paste.
#
# BREAK-TEST: `clipboardHasText: store.localClipboardHasText()` →
# `clipboardHasText: ClipboardPasteMenu.isPastable(store.currentLocalClipboard())` in
# GuiLeafView.swift ⇒ FAIL both arms ("…does not ask the silent probe" and "…reads clipboard content
# from a render"). Restored from /tmp; PASS.
if [[ -f Sources/SlopDeskPhoneUI/Pane/GuiLeafView.swift ]]; then
  paste_gate=$(
    sed -n '/var canPasteCurrent: Bool {/,/^    }/p' Sources/SlopDeskPhoneUI/Pane/GuiLeafView.swift
  )
  if [[ -z "${paste_gate}" ]]; then
    fail "GuiPastePlateMenu.canPasteCurrent is gone — this gate has no subject, so the iOS paste-alert rule is unpinned (docs/56 increment 78)"
  elif ! grep -qE 'localClipboardHasText\(\)' <<< "${paste_gate}"; then
    fail "the phone's paste plate does not ask the silent probe — canPasteCurrent must gate on WorkspaceStore.localClipboardHasText(), which discloses nothing and so raises no iOS paste alert"
  fi
  if grep -qE 'currentLocalClipboard\(' <<< "${paste_gate}"; then
    fail "the phone's paste plate reads clipboard content from a render — canPasteCurrent is evaluated with body, so a content read there puts iOS's \"Allow Paste?\" alert on screen unprompted"
  fi
fi

# N.14 — THE SWIPE-PEEL CHIP HAS A DRIVER ON BOTH HALVES.
#
# The chip was MOUNTED on the phone and DRIVEN only on the Mac for most of a year, on a premise that
# was false in the file that stated it: "the planner arms on trackpad scroll PHASES, which a touch
# does not produce". A two-finger pair routed to `.scroll` produces exactly them — the phone sends
# Began on the first move and Ended on the lift, because the host needs a native gesture rather than
# a train of wheel ticks — so the mirror had a stream to read the whole time. A mounted renderer with
# no producer is the worst shape a parity gap takes: it looks finished from the drawing's side.
#
# Three things are pinned, because the gap could return through any of them: each half FEEDS the
# planner, each half ADOPTS the host's status push (without which the mirror never arms and the chip
# is dark again with no code missing), and the verdict → chip state machine stays SHARED — the
# haptic's rising edge, the confirm hold and the swallowed retracts are one law, and two renderers
# each keeping their own would drift the moment one is edited.
#
# BREAK-TEST: deleted the `feedSwipePeel(dx:dy:scrollPhase:)` call from the phone's `applyPairScroll`
# ⇒ FAIL "the phone's swipe-peel chip has no driver". Separately deleted the
# `pipeline.onSwipeNavStatusChanged` line ⇒ FAIL "…never learns the host's swipe-nav operating
# point". Separately inlined the driver's `switch` back into the Mac's `applySwipePeel` ⇒ FAIL "the
# swipe-peel chip's state machine is spelled per renderer". All restored from /tmp; PASS.
for peel_view in Sources/SlopDeskVideoClientMac/MacMetalLayerBackedView.swift \
  Sources/SlopDeskVideoClientPhone/MetalLayerBackedView.swift; do
  [[ -f "${peel_view}" ]] || continue
  if ! grep -qE 'feedSwipePeel\(' "${peel_view}"; then
    fail "${peel_view} has no swipe-peel driver — the chip is mounted on both halves, and a renderer with no producer is a parity gap that looks finished from the drawing's side"
  fi
  if ! grep -qE 'pipeline\.onSwipeNavStatusChanged' "${peel_view}"; then
    fail "${peel_view} never learns the host's swipe-nav operating point — without the status push the mirror never arms and the chip stays dark with no code missing"
  fi
  if ! grep -qE 'peelDriver\.step\(' "${peel_view}"; then
    fail "${peel_view} spells the swipe-peel chip's state machine itself — the haptic's rising edge, the confirm hold and the swallowed retracts are SwipePeelChipDriver's, once, or the two renderers drift"
  fi
done
# …and the hold is the door's number, never a literal in either renderer. 520 ms typed on one half
# and 500 on the other is two answers to "how long does a fire stay acknowledged", and nothing goes
# red when they disagree.
if leak=$(spells 'nanoseconds: 5[0-9]{2}_000_000' \
  Sources/SlopDeskVideoClientMac/MacMetalLayerBackedView.swift \
  Sources/SlopDeskVideoClientPhone/MetalLayerBackedView.swift); then
  fail "a swipe-peel confirm hold is spelled in a renderer (${leak}) — the length is slopdesk_peel_constants().confirm_hold_seconds, reached through SwipePeelChipDriver.confirmHold"
fi

# N.15 — AN iPad WITH A TRACKPAD IS A POINTER, AND THE PHONE HALF CAN SEE IT.
#
# `TARGETED_DEVICE_FAMILY` is "1,2" and always was, so an iPad with a trackpad or a mouse has always
# driven the phone's video surface — and for most of the project that surface had ZERO
# `UIPointerInteraction`, ZERO `UIHoverGestureRecognizer` and no reading of `buttonMask` anywhere in
# the tree. Not a layout difference: a whole input modality missing on a first-class device, which is
# the exact thing docs/56 §3 says the split may never produce. Every one of these is a capability the
# Mac half has had since it existed, so each is pinned as a POSITIVE rather than left in the
# absent-sinks ledger, which only ever recorded what the phone did NOT do.
#
# The four are independent failure modes, not one feature in four spellings:
#   • hover      — a pointer moving with nothing held produces no `UITouch` at all, so without the
#                  recogniser every piece of hover-only remote UI (a tooltip, a menu highlight, a
#                  hover-revealed close box) is unreachable from this half.
#   • buttons    — UIKit reports the LEVEL on every event; a client that forwarded it rather than the
#                  edge either never presses or never releases, and a button left down outlives the
#                  pane on a host whose event source is process-global.
#   • scroll     — a trackpad's wheel arrives only through a pan with `allowedScrollTypesMask`, and
#                  the two-finger swipe an iPad user makes on it is the same gesture the host's own
#                  swipe-nav recogniser fires on.
#   • the cursor — the pane composites the host's pointer, so the local one has to go, or there are
#                  visibly two.
#
# BREAK-TEST: deleted the `UIHoverGestureRecognizer` line ⇒ FAIL "cannot see a pointer that hovers".
# Separately deleted `allowedScrollTypesMask` ⇒ FAIL "…a trackpad's scroll". Separately replaced the
# `buttonMask` read with a hardcoded primary ⇒ FAIL "…synthesizes an indirect pointer's press".
# Separately dropped the `UIPointerInteraction` ⇒ FAIL "…shows two pointers". All restored from /tmp;
# PASS.
phone_video=Sources/SlopDeskVideoClientPhone/MetalLayerBackedView.swift
if [[ -f "${phone_video}" ]]; then
  if ! grep -q 'UIHoverGestureRecognizer' "${phone_video}"; then
    fail "${phone_video} cannot see a pointer that hovers — a hover produces no UITouch, so without UIHoverGestureRecognizer every hover-only remote surface is unreachable from the phone half (docs/56 §3)"
  fi
  if ! grep -q 'allowedScrollTypesMask' "${phone_video}"; then
    fail "${phone_video} cannot see a trackpad's scroll — an iPad's wheel arrives only through a pan recogniser with allowedScrollTypesMask, and that swipe is what the host's swipe-nav fires on (docs/56 §3)"
  fi
  if ! grep -q 'buttonMask' "${phone_video}"; then
    fail "${phone_video} synthesizes an indirect pointer's press instead of reading UIEvent.buttonMask — a pointer has real buttons, and forwarding the level rather than the edge strands one down on a process-global host event source (docs/56 §3)"
  fi
  if ! grep -q 'UIPointerInteraction' "${phone_video}"; then
    fail "${phone_video} shows two pointers on an iPad — the pane composites the host's cursor, so the LOCAL one must be hidden while it is visible (the Mac's applyLocalCursor, halves swapped)"
  fi
  # …and the indirect-pointer button diff is the door's, never a mask comparison typed here. The
  # bit index of that set IS the wire's MouseButton ordinal, and a hand-rolled diff is where a right
  # click quietly becomes a left one on one device only.
  if ! grep -q 'IndirectPointerPlan.buttonTransitions(' "${phone_video}"; then
    fail "${phone_video} diffs an indirect pointer's buttons itself — the edge is IndirectPointerPlan.buttonTransitions(held:mask:), whose bit indices ARE the wire's MouseButton ordinals (docs/55 §6)"
  fi
fi

# N.16 — THE PANE-MOVE DROP IS ONE RULE, AND BOTH UI HALVES ONLY DRAW WHAT IT ANSWERS.
#
# `PaneDropGeometry` already stopped the RESOLUTION from having two answers — the canvas's live
# in-tab hit test and the cross-window INSERT resolution read one gutter. What it did not stop is the
# other half of the round trip: the preview's rects were `static func`s on a `View`, and BOTH halves
# had written that math themselves before arriving at the shared file, each under a banner calling it
# pure. A slab is not layout. It is an assertion about what the commit will do, and two renderers
# deriving it independently is how one half draws a promise the resolver never keeps.
#
# So the rules are `slopdesk_workspace::pane_drop` and the Swift is a face over 8 doors. Three things
# are pinned, because each is a different way for the port to come undone:
#   • the doors exist    — a face over a deleted door does not compile, but a face that quietly grew
#                          its own arithmetic beside them does.
#   • the metrics cross  — six numbers behind `slopdesk_pane_drop_metric`, never re-declared as Swift
#                          literals. A `static let 0.30` here is a SECOND place the affordance lives,
#                          free to drift from the Rust the resolver runs, silently.
#   • both halves read   — the Mac's AppKit affordance and the phone's SwiftUI one each call the face
#                          for the slab and the rail. A half that computes `rect.width / 2` itself is
#                          the original bug returning in one framework only, invisible from the other.
#
# `leaf(at:in:excluding:)` is deliberately NOT pinned as ported: it answers a `PaneID` from
# `PlacedLeaf`s, so porting it would carry an identity across the ABI only to compare it with the one
# it came from — `rust/slopdesk-devicepanel`'s charter, and the reason it stayed Swift.
#
# BREAK-TEST: re-declared `edgeBandFraction` as `0.30` in the Swift face ⇒ FAIL "writes a drop metric
# down a second time". Separately replaced the phone affordance's `slabRect` call with `rect.width /
# 2` ⇒ FAIL "…draws a re-split preview it computed itself". Separately deleted the Rust module ⇒ FAIL
# "…has no Rust behind it". All restored from /tmp; PASS.
pane_drop_rules=rust/slopdesk-workspace/src/pane_drop.rs
pane_drop_door=rust/slopdesk-ffi/src/pane_drop.rs
pane_drop_face=Sources/SlopDeskClientCore/Pane/PaneDropGeometry.swift
for required in "${pane_drop_rules}" "${pane_drop_door}"; do
  if [[ ! -f "${required}" ]]; then
    fail "${pane_drop_face} has no Rust behind it — ${required} is missing, and the pane-move drop is one rule shared by two resolvers and two renderers (docs/56 increment 82)"
  fi
done
if [[ -f "${pane_drop_face}" ]]; then
  # A tuned number written as a Swift literal is the affordance living in two places at once.
  if grep -Eq '(let|var) +(edgeBandFraction|containerGutterFraction|containerGutterMax|dockRailFraction|dockRailMax|resplitSeamThickness)[^=]*= *[0-9]' "${pane_drop_face}"; then
    fail "${pane_drop_face} writes a drop metric down a second time — the six tuned numbers come through slopdesk_pane_drop_metric, so a literal here is free to drift from the Rust the resolver runs (docs/56 increment 82)"
  fi
  if ! grep -q 'slopdesk_pane_drop_metric' "${pane_drop_face}"; then
    fail "${pane_drop_face} stopped reading the metrics through their door (docs/56 increment 82)"
  fi
fi
# Both renderers ask the face for the preview; neither re-derives a half or a band.
for affordance in Sources/SlopDeskMacUI/Pane/MacPaneMoveAffordance.swift \
  Sources/SlopDeskPhoneUI/Pane/PaneMoveAffordance.swift; do
  [[ -f "${affordance}" ]] || continue
  for verb in slabRect railRect; do
    if ! grep -q "PaneDropGeometry.${verb}" "${affordance}"; then
      fail "${affordance} draws a re-split preview it computed itself — PaneDropGeometry.${verb} is the shared answer, and a half that derives its own is the two-frameworks bug returning in one of them only (docs/56 increment 82)"
    fi
  done
done

# N.17 — THE LINK ISLAND IS ONE READING, AND NOBODY KEEPS A SECOND COPY OF IT.
#
# Four surfaces draw the connection: the Mac's navigator foot and titlebar band (AppKit), the phone's
# navigation toolbar (SwiftUI), and the gate card that appears when the link is down. Before this they
# read a Swift `enum ConnectionReading` and a Swift `enum ConnectionPresenter`, which is one copy — but
# the copy sat ABOVE the rules crate every other reading had already moved into, and three of the
# numbers in it (the two ping thresholds, the disk floor) had been written twice already.
#
# So the rules are `slopdesk_workspace::connection` and both Swift enums are faces. What is pinned is
# what would let a second copy back in:
#   • the doors exist       — a face over a deleted door does not compile; a face that grew its own
#                             arithmetic beside them does.
#   • no threshold literal  — the ping bounds, the disk floor and the megabit switch are `pub const`s
#                             in the rules crate. A `static let 80` in either face is a SECOND place
#                             the ladder lives, free to drift from the Rust that classifies with it.
#   • the ceiling ARGUES    — `slopdesk_connection_words` takes `max_attempts`. `ReconnectManager` owns
#                             that number in the module that runs the campaign; a Rust `const` beside
#                             it would be the "of 20 while the campaign runs to 30" bug with a new
#                             place to hide.
#   • the words are ONE run — `ConnectionStatus.label` reads the door's third register rather than
#                             switching over the same six states again. Two switches over one enum is
#                             how a state comes to be named one thing by the model and another by the
#                             toolbar.
#   • both halves read      — the Mac island and the phone pill each call the face. A half that
#                             formats `"\(ms) ms"` itself is the two-frameworks bug in one of them
#                             only, invisible from the other.
#
# The HOST NAME and the raw failure payload deliberately never cross: the help line is
# `"Connection: {host} — "` plus what the doors answer, and `has_raw_detail` is a yes/no about the
# string the caller is already holding — `rust/slopdesk-devicepanel`'s charter, "answers, not
# identities".
#
# BREAK-TEST: re-declared `pingGoodMS = 80` in ConnectionReading ⇒ FAIL "writes a link threshold down
# a second time". Separately restored ConnectionStatus.label's own switch ⇒ FAIL "names its states a
# second time". Separately deleted the Rust module ⇒ FAIL "has no Rust behind it". Separately renamed
# the `maxReconnectAttempts` argument away ⇒ FAIL "stopped handing the door the supervisor's ceiling".
# Separately wrote `"\(ms) ms"` into the Mac island ⇒ FAIL "formats a link figure itself". All five
# restored from /tmp; PASS.
connection_rules=rust/slopdesk-workspace/src/connection.rs
connection_door=rust/slopdesk-ffi/src/connection.rs
connection_reading=Sources/SlopDeskClientCore/Chrome/ConnectionReading.swift
connection_presenter=Sources/SlopDeskWorkspaceCore/Connection/ConnectionPresenter.swift
connection_status=Sources/SlopDeskWorkspaceCore/Connection/ConnectionStatus.swift
for required in "${connection_rules}" "${connection_door}"; do
  if [[ ! -f "${required}" ]]; then
    fail "${connection_reading} has no Rust behind it — ${required} is missing, and the link island is one reading drawn by four surfaces (docs/56 increment 83)"
  fi
done
for face in "${connection_reading}" "${connection_presenter}"; do
  [[ -f "${face}" ]] || fail "${face} is missing — the link island's face is where the two shells meet one reading (docs/56 increment 83)"
  # A threshold written as a Swift literal is the ladder living in two places at once.
  if grep -Eq '(let|var) +(pingGoodMS|pingSlowMS|diskWarnMiB|diskCriticalMiB|mbpsThreshold[A-Za-z]*)[^=]*= *[0-9]' "${face}"; then
    fail "${face} writes a link threshold down a second time — the ping bounds, the disk floor and the megabit switch are consts in slopdesk_workspace::connection, so a literal here is free to drift from the Rust that classifies with it (docs/56 increment 83)"
  fi
done
if ! grep -q 'maxReconnectAttempts' "${connection_presenter}"; then
  fail "${connection_presenter} stopped handing the door the supervisor's ceiling — ReconnectManager owns that number, and a Rust const beside it is the \"of 20 while the campaign runs to 30\" bug with a new place to hide (docs/56 increment 83)"
fi
if [[ -f "${connection_status}" ]] && grep -q 'case .connecting: "connecting"' "${connection_status}"; then
  fail "${connection_status} names its states a second time — .label is slopdesk_connection_words' third register, and two switches over one enum is how a state gets named one thing by the model and another by the toolbar (docs/56 increment 83)"
fi
# Both shells read the island through the face; neither formats a reading itself.
for island in Sources/SlopDeskMacUI/Chrome/MacConnectionIsland.swift \
  Sources/SlopDeskPhoneUI/Chrome/ConnectionPill.swift; do
  [[ -f "${island}" ]] || continue
  if ! grep -q 'ConnectionReading\.' "${island}"; then
    fail "${island} stopped reading the link through ConnectionReading — a shell that formats its own ping or status word is the two-frameworks bug in one of them only (docs/56 increment 83)"
  fi
  if grep -Eq '"\\\(.*\) ms"|Mbps"' "${island}"; then
    fail "${island} formats a link figure itself — the ping and the bitrate are slopdesk_workspace::connection's, so one shell writing its own is a reading the other cannot see change (docs/56 increment 83)"
  fi
done

# The header's macOS-only region, read ONCE into a variable rather than re-extracted per door.
#
# Not a tidy-up. The three checks below used to spell `awk … | grep -q "${door}("`, and under
# `set -o pipefail` that is a COIN FLIP: `grep -q` exits the moment it matches, awk takes SIGPIPE on
# its next write, and the pipeline's status is awk's failure rather than grep's success — so a door
# that IS correctly gated reports as ungated, and whether it does depends on how far into the region
# it sits and how much of it fits in the pipe buffer. It fired for the first time when the encoder
# doors changed the region's length in increment 92, having been latent since the region existed.
# A variable has no pipe to break, and it is read once instead of five times.
macos_only_region=$(awk '/MACOS-ONLY BEGIN/{inside=1} inside{print} /MACOS-ONLY END/{inside=0}' \
  rust/slopdesk-ffi/include/slopdesk_ffi.h)

# N.18 — THE HOST SYNTHESISES NO EVENT OF ITS OWN.
#
# Every injected `CGEvent` is built and posted by `rust/slopdesk-apple-cgevent`, the first crate of
# the `objc2` family `docs/57` opens the unsafe gate for. `InputInjector` still ORCHESTRATES — it
# owns the bounds, the balance, the resampler, the raise chain — but it no longer builds an event,
# sets a field on one, warps a cursor or posts anything.
#
# The line matters because the two languages fail differently here. Swift's `Int32(_:)` TRAPS on a
# value off the wire; Rust's clamp saturates. Swift's `CGEvent` construction is nine call sites that
# each had to remember the click-state rule, the untagged-keyboard rule and the suppression
# interval; Rust's is one. A second CGEvent built in Swift would not be a duplicate implementation
# in the abstract — it would be the specific bug each of those rules was written to close.
#
# What is pinned:
#   • the crate and the door exist   — a face over a deleted door does not compile; a face that grew
#                                      its own CoreGraphics call beside them does.
#   • no synthesis in the injector   — no `CGEvent(`, no `setIntegerValueField`, no `.post(tap:`, no
#                                      `CGWarpMouseCursorPosition`. Those ARE the port.
#   • no second clamp                — `clampToInt32`/`scaledScrollDelta` are `slopdesk-video`'s.
#                                      A Swift copy is the trap coming back by another name.
#   • the bijection is spelled       — the crate is a target-gated dependency, the doors sit inside
#                                      the header's MACOS-ONLY region, and the module is `cfg`'d.
#                                      `build-ffi.sh` checks the third leg on all three slices; the
#                                      first two are checked here, because a header that declares an
#                                      iOS-reachable CoreGraphics door fails at LINK, far from here.
#
# BREAK-TEST: restored `CGEvent(mouseEventSource:` in InputInjector ⇒ FAIL "builds a CGEvent itself".
# Separately restored `static func clampToInt32` there ⇒ FAIL "keeps its own narrowing". Separately
# deleted the Rust crate ⇒ FAIL "has no Rust behind it". Separately moved the inject declarations out
# of the MACOS-ONLY region ⇒ FAIL "declares a CoreGraphics door outside the macOS-only region".
# Separately ungated the Cargo edge ⇒ FAIL "is not target-gated". All five restored from /tmp; PASS.
cgevent_crate=rust/slopdesk-apple-cgevent/src/inject.rs
cgevent_door=rust/slopdesk-ffi/src/inject.rs
input_injector=Sources/SlopDeskVideoHost/InputInjector.swift
for required in "${cgevent_crate}" "${cgevent_door}"; do
  if [[ ! -f "${required}" ]]; then
    fail "${input_injector} has no Rust behind it — ${required} is missing, and the host synthesises no event of its own (docs/57 §5, docs/56 increment 84)"
  fi
done
if [[ -f "${input_injector}" ]]; then
  # CODE only. The comments still NAME these calls, and should: they carry the hardware measurements
  # that decided the tablet path and the suppression interval, which is exactly the knowledge a
  # reader of the orchestration needs. A gate that could not tell a call from a sentence about one
  # would force those measurements out of the file to stay green.
  injector_code=$(grep -vE '^[[:space:]]*(///|//)' "${input_injector}" || true)
  if grep -Eq 'CGEvent\(|\.setIntegerValueField|\.post\(tap:|\.postToPid\(|CGWarpMouseCursorPosition|CGAssociateMouseAndMouseCursorPosition|CGEventSource\(' <<< "${injector_code}"; then
    fail "${input_injector} builds a CGEvent itself — synthesis, field-setting, the warp and the post are slopdesk-apple-cgevent's, and a second copy here is where the click-state rule and the untagged-keyboard rule drift apart (docs/57 §5)"
  fi
  if grep -Eq 'func (clampToInt32|scaledScrollDelta)' <<< "${injector_code}"; then
    fail "${input_injector} keeps its own narrowing — clamp_to_i32 is slopdesk-video's, and a Swift copy is the trapping Int32(_:) coming back under a new name on a path that parses hostile datagrams (docs/57 §5)"
  fi
fi
if ! grep -q 'slopdesk_inject_pointer(' <<< "${macos_only_region}"; then
  fail "slopdesk_ffi.h declares a CoreGraphics door outside the macOS-only region — iOS has no CGEvent at all, so an ungated declaration is not a wasted byte, it is a link failure on two of the three slices (docs/57 §3)"
fi
# The macOS-gated dependency TABLE, not a fixed window after its header. This was `grep -A 12` and
# the twelfth line was reached the moment a crate arrived with a comment above it — the gate then
# failed on a `Cargo.toml` that was perfectly gated, naming the wrong defect. Read to the next
# table header instead, which is where the section actually ends.
ffi_macos_edges=$(
  awk '/^\[target\..cfg\(target_os = "macos"\).\.dependencies\]/ { inside = 1; next }
       /^\[/ { inside = 0 }
       inside' rust/slopdesk-ffi/Cargo.toml
)
if ! grep -q 'slopdesk-apple-cgevent' <<< "${ffi_macos_edges}"; then
  fail "rust/slopdesk-ffi/Cargo.toml: the slopdesk-apple-cgevent edge is not target-gated — the macOS-only bijection is three spellings (the cfg, the header region, the Cargo edge) and build-ffi.sh only checks what the library exports (docs/57 §3)"
fi

# N.19 — THE HOST DECODES NO WINDOW RECORD OF ITS OWN.
#
# `CGWindowListCopyWindowInfo` answers a `CFArray` of `CFDictionary`, and reading one is a decode:
# eight optional fields, each of which can be absent or of the wrong type. Four Swift call sites
# wrote that decode independently and DISAGREED about what absence means — one defaulted
# `kCGWindowLayer` to `Int.min`, another to `-1`, a third dropped the record, and the fourth read a
# missing owner pid as `-1` and went on to compare it. `rust/slopdesk-apple-cgwindow` decodes once
# and drops an incomplete record, which is the only one of the four answers that cannot elect a
# frontmost app or move a window on a malformed record.
#
# The display half is the same shape: three call sites ran the same two-call enumeration by hand,
# two sizing from a counting call and one hard-coding sixteen — a silent truncation at seventeen
# displays, which is absurd until it is a mirrored wall.
#
# What is pinned:
#   • the crates and the doors exist  — a face over a deleted door does not compile; a face that
#                                       grew its own CGWindowList call beside them does.
#   • no decode in the host           — no `CGWindowListCopyWindowInfo`, no `kCGWindow*` subscript,
#                                       no `CGGet*DisplayList` outside the two crates. The ONE
#                                       exception is the feed enumeration, which still builds its
#                                       own records and is named here so its exemption is visible
#                                       rather than accidental.
#   • no frozen frontmost read        — `NSWorkspace.frontmostApplication` in a daemon answers the
#                                       first-access app forever. `HostFrontmostApp` elects from
#                                       the window list instead, and nothing in the host may go
#                                       back.
#   • the bijection is spelled        — both crates are target-gated dependencies and both doors sit
#                                       inside the header's MACOS-ONLY region.
#
# BREAK-TEST: restored `CGWindowListCopyWindowInfo` in WindowGeometryWatcher ⇒ FAIL "decodes a
# window record itself". Separately restored `NSWorkspace.shared.frontmostApplication` in
# WindowFeedGlue ⇒ FAIL "reads a frozen frontmost". Separately deleted the cgwindow crate ⇒ FAIL
# "has no Rust behind it". Separately moved the declarations out of the MACOS-ONLY region ⇒ FAIL
# "declares a WindowServer door outside the macOS-only region". Separately ungated a Cargo edge ⇒
# FAIL "is not target-gated". All five restored from /tmp; PASS.
for required in rust/slopdesk-apple-cgwindow/src/list.rs rust/slopdesk-apple-cgdisplay/src/displays.rs \
  rust/slopdesk-ffi/src/cgwindow.rs rust/slopdesk-ffi/src/cgdisplay.rs; do
  if [[ ! -f "${required}" ]]; then
    fail "the host has no Rust behind its window reads — ${required} is missing, and the WindowServer decode lives in one place (docs/57 §5, docs/56 increment 85)"
  fi
done
# The feed enumeration is the ONE file still allowed its own record build: it needs three AppKit
# reads per pid that no CoreGraphics door can answer, and moving it is increment 86's job. Named
# here so the exemption is a decision on the record rather than a grep that happens to miss it.
# CODE only, for N.18's reason: these files still NAME the calls in prose, and should — the comments
# carry why the feed uses CGWindowList over SCShareableContent and why the probe walks displays out
# of process. A gate that could not tell a call from a sentence about one would force that out.
window_readers=""
while IFS= read -r candidate; do
  case "${candidate}" in
    Sources/slopdesk-videohostd/WindowFeedGlue.swift | Sources/SlopDeskVideoHost/VirtualDisplay.swift) continue ;;
    *) ;;
  esac
  if grep -vE '^[[:space:]]*(///|//)' "${candidate}" |
    grep -q 'CGWindowListCopyWindowInfo\|CGGetActiveDisplayList\|CGGetOnlineDisplayList\|CGGetDisplaysWithPoint'; then
    window_readers+="${candidate}"$'\n'
  fi
done < <(grep -rln 'CGWindowListCopyWindowInfo\|CGGetActiveDisplayList\|CGGetOnlineDisplayList\|CGGetDisplaysWithPoint' Sources 2> /dev/null || true)
window_readers=${window_readers%$'\n'}
if [[ -n "${window_readers}" ]]; then
  fail "these decode a window record themselves: ${window_readers//$'\n'/, } — the CGWindowList and display-list reads are slopdesk-apple-cgwindow's and slopdesk-apple-cgdisplay's, and a second decode is where 'a missing field means Int.min' comes back (docs/57 §5)"
fi
# CODE only, and here the prose matters most of all: both remaining files exist BECAUSE of this
# snapshot's freeze, and each explains it. Naming the trap is the point.
frozen_frontmost=""
while IFS= read -r candidate; do
  if grep -vE '^[[:space:]]*(///|//)' "${candidate}" |
    grep -q 'NSWorkspace\.shared\.frontmostApplication\|NSWorkspace\.shared\.menuBarOwningApplication'; then
    frozen_frontmost+="${candidate}"$'\n'
  fi
done < <(grep -rln 'NSWorkspace\.shared\.frontmostApplication\|NSWorkspace\.shared\.menuBarOwningApplication' Sources 2> /dev/null || true)
frozen_frontmost=${frozen_frontmost%$'\n'}
if [[ -n "${frozen_frontmost}" ]]; then
  fail "these read a frozen frontmost: ${frozen_frontmost//$'\n'/, } — NSWorkspace's snapshot populates on first access and then never updates in a daemon that pumps no AppKit run loop, so the read answers the launching app for the process's whole life. HostFrontmostApp elects from the window list (docs/57 §5)"
fi
for door in slopdesk_cgwindow_frontmost_pid slopdesk_cgdisplay_list; do
  if ! grep -q "${door}(" <<< "${macos_only_region}"; then
    fail "slopdesk_ffi.h declares ${door} outside the macOS-only region — iOS has no WindowServer at all, so an ungated declaration is not a wasted byte, it is a link failure on two of the three slices (docs/57 §3)"
  fi
done
for edge in slopdesk-apple-cgwindow slopdesk-apple-cgdisplay slopdesk-apple-sck; do
  if ! grep -q "${edge}" <<< "${ffi_macos_edges}"; then
    fail "rust/slopdesk-ffi/Cargo.toml: the ${edge} edge is not target-gated — the macOS-only bijection is three spellings (the cfg, the header region, the Cargo edge) and build-ffi.sh only checks what the library exports (docs/57 §3)"
  fi
done

# N.20 — THE HOST DECIDES NO CAPTURE REGION OF ITS OWN.
#
# DIALOG-EXPAND's math — the union with an attached panel, the individual content rects, the
# per-edge hysteresis gate, the expand/contract/hold verdict — and the resize path's display pick
# were `CaptureRegionMath` and `WindowDisplayResolver`, two Swift enums whose every operation was
# `CGRect` algebra. `golden/golden_vectors.json` pinned 23 of their outputs as raw `f64` bit
# patterns and, for a long time, NOTHING replayed them: the generator's own comment claimed a Rust
# `slopdesk_core` crate and a `golden_parity` test validated them, and neither had ever existed.
#
# They live in `slopdesk_video::capture_region` and `::window_list` now, over a `CGRect` algebra
# read off CoreGraphics by probe — an edge touch intersects at the seam, a NaN coordinate resolves
# to the other rect, an empty rect still contributes its corner to a union — and the 23 vectors are
# replayed by the Rust integration suite, which `golden-check.sh` independently requires to exist.
#
# What is pinned:
#   • the modules and doors exist    — a Swift face over a deleted door does not compile.
#   • both Swift enums stay deleted  — the failure mode is not a call that breaks, it is a second
#                                      copy of the same predicate that drifts one ulp.
#   • the doors are PORTABLE         — the mirror of N.19's arm: these decide rather than read, so a
#                                      declaration inside the MACOS-ONLY region would drop them from
#                                      the iOS slices for no reason and hide that they are pure.
#
# BREAK-TEST: reintroduced `enum CaptureRegionMath` in WindowGeometryWatcher ⇒ FAIL "decide a
# capture region themselves". Separately deleted `rust/slopdesk-video/src/capture_region.rs` ⇒ FAIL
# "has no Rust behind its capture region". Separately moved `slopdesk_capture_union_region` inside
# the MACOS-ONLY region ⇒ FAIL "declares a portable decider inside the macOS-only region". All three
# restored from /tmp; PASS.
for required in rust/slopdesk-video/src/capture_region.rs rust/slopdesk-ffi/src/capture_region.rs \
  rust/slopdesk-ffi/src/window_list.rs; do
  if [[ ! -f "${required}" ]]; then
    fail "the host has no Rust behind its capture region — ${required} is missing, and the 23 golden-pinned union and retarget vectors are replayed against it (docs/56 increment 86)"
  fi
done
# CODE only, for N.18's reason: the Swift that CALLS these doors still names the old enums in prose,
# and should — the comments carry why the region expands at all.
region_deciders=""
while IFS= read -r candidate; do
  if grep -vE '^[[:space:]]*(///|//)' "${candidate}" |
    grep -q 'enum CaptureRegionMath\|enum WindowDisplayResolver\|CaptureRegionMath\.\|WindowDisplayResolver\.'; then
    region_deciders+="${candidate}"$'\n'
  fi
done < <(grep -rln 'CaptureRegionMath\|WindowDisplayResolver' Sources Tests 2> /dev/null || true)
region_deciders=${region_deciders%$'\n'}
if [[ -n "${region_deciders}" ]]; then
  fail "these decide a capture region themselves: ${region_deciders//$'\n'/, } — the union, the content rects, the hysteresis gate and the display pick are slopdesk_video::capture_region's and ::window_list's, and a second copy is a predicate that drifts one ulp under a green suite (docs/56 increment 86)"
fi
for door in slopdesk_capture_union_region slopdesk_capture_region_decision slopdesk_window_display_for_frame; do
  if ! grep -q "${door}(" rust/slopdesk-ffi/include/slopdesk_ffi.h; then
    fail "slopdesk_ffi.h does not declare ${door} — the Swift face calls it, so a missing declaration is a link failure the moment anyone rebuilds (docs/55 §3)"
  fi
  if grep -q "${door}(" <<< "${macos_only_region}"; then
    fail "slopdesk_ffi.h declares a portable decider inside the macOS-only region: ${door} — it reads no WindowServer and its answers are golden-pinned on every slice, so gating it hides that it is pure and costs the iOS slices a door for nothing (docs/57 §3)"
  fi
done

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

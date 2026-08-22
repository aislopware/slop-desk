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
# Twenty-one bans below each asked `grep -r … Sources/` for a list that is EMPTY every time the gate
# passes, so the script walked the whole Swift tree twenty-one times per inner loop to be told
# nothing twenty-one times. The union walks it ONCE, here; each ban then re-greps only the
# candidates, which is no files at all in the passing case.
#
# Semantics are unchanged and the reason is the same one `spells` gives: a file that matches none of
# the alternatives cannot match one of them. Every ban keeps its own pattern and its own message —
# the union is a filter, never the answer — which is what a reader needs on the day one fires.
#
# The union is BUILT from the bans, not maintained beside them: `make lint` runs
# `scripts/check-ban-union.py`, which fails if any ban's pattern is missing from it.
DELETED_SWIFT_UNION='((enum|struct|final class) (GF256|NeonGf|ReedSolomonMatrix)\b)|((struct|enum|final class) StreamHasher\b|func (hashRow|hashNV12Scalar|rowHashes|rowHashesQuantized|borrowPlane|estimateVerticalShift|changedFraction|adaptiveMaxQP)\b)|(func (targetSeconds|stepSeconds|cgRectToCocoa|backingScaleFactor)\(|(struct|enum|final class) ScreenInfo\b)|((func|var) appendBE|(struct|enum|final class|class) BigEndianReader)|((enum|struct|final class|class|actor) (AgentManifest|CompiledAgentManifest|AgentManifestCatalog|TOMLSubsetParser|ManifestRegion|ManifestRuleEngine|BundledAgentManifests|AgentDetectionExplain|AgentOscTracker|AgentSyncFrameTracker|ClaudeManifestMatcher)\b)|((enum|struct|final class|class|actor) ShellIntegration\b|slopdesk-zdotdir-)|((enum|struct|final class|class|actor|protocol) (FileTransferServer|FileReceiveLogic|FileDropSink|DiskFileDropSink|FileNameSanitizer|LoopbackFileTransferChannel)\b)|((enum|struct|final class|class|actor|protocol) (AndroidBridgeServer|AndroidBridgeManager|AndroidToolchain|AndroidScrcpySession|AndroidDeviceCatalog|AndroidEmulatorConsole|AndroidSocket|AndroidListener|AndroidBridgeRequest)\b)|((enum|struct|final class|class|actor|protocol) (TranscriptParser|TranscriptTailer|TranscriptLine|LineAccumulator|SubagentWatcher|EventBuilder|InspectorEngine|InspectorReplayLog|InspectorSource|InspectorServer)\b)|((static (let|var|func)|let|var|func) (seededUserSettings|obsoleteSeeds|themeExtension[A-Za-z]*|bridgeExtension[A-Za-z]*|registerExtension|unregisterExtension|bundledMarketplaceExtensions|retiredExtensions|ownThemeResources)\b)|((enum|struct|final class|static (let|var|func)) (AgentInstaller|hookMarker|installedEvents|hookCommand|entryIsOurs)\b)|((struct|static (let|var|func)|private static func) (parseBranchHeader|parseStatusLine|statusNibble|packStatus|claudeProjectSlug|gitToplevel|gitStashCount|gitDiffArgumentPlan|resolveGitDiff|jsonlSessions|claudeSessions|opencodeSessions|sessionRoots|GhosttyTerminfoProbe|terminfoEntryExists|isGhosttyResolvable|effectiveTerm|liveProbe|runInfocmp)\b)|("/usr/bin/(git|infocmp)")|((let|var|func|case) *(bonusBoundary|bonusCamel123|bonusConsecutive|scoreGapStart|scoreGapExtension|bonusMatrix|bonusFor|backtrace)\b)|((enum|struct) *(HookPayload|StopInfo|ToolUseBlock|NotificationInfo|ClaudeHookBody|ClaudeHookEvent)\b|func +(mapToHookEvent|classifyNotification|stopLabel)\b)|((enum|struct|final class|class|actor) (ClaudeStatusMachine|ClaudeProcessMatcher|PaneInputClassifier)\b|enum ClaudeSignal\b)|(func +(skipEscapeSequence|isEraseToLineEnd|applySGR|extendedColour)\b)|(enum TerminalScreenModel|struct TerminalScreenModel|enum LineOverprintCollapser|enum TerminalSnapshotRenderer)|((enum|struct|final class|class|actor) (TerminalInputModeStripper|InputModeFinalState|AltScreenSegmentStripper|SyncUpdateFrameCollapser|ScrollbackDistiller|TerminalQueryStripper|PromptEOLMarkStripper)\b)|(func (splitTrailingIncompleteEscape|splitTrailingIncompleteUTF8)\b|trailingEscapeScanBytes *[:=])|((enum|struct|final class|class|actor) (ScrollbackJournal|ScrollbackJournalStore)\b)|((createFile|forWritingTo|\.write\(to:).*\.(scrollback|resume)("|\)|$))|((enum|struct|final class|class|actor) (HostOutputSniffer|OutputSniffer)\b)|((enum|struct|final class|class|actor) (CommandBlockSegmenter|CommandBlockTracker|AutoProgressMatcher)\b)|(\[\[rules\]\]|min_engine_version\s*=|skip_state_update\s*=|line_regex\s*=)|(autoProgressCommands: \[String\]|autoProgressPrefixes)|(static let persistedPaneFields\b|(struct|private struct) Row: Codable\b)|((struct|private struct) (RawWeightedChild|SpecEntry)\b|func (decodeRaw|decodeChildren|rawNode)\()|(\b(SplitNode|WeightedChild|SplitWeight|TreeWorkspace|DetachedPane|PaneSpec|VideoEndpoint|Session|Tab)\b *: *(any )?(Codable|Decodable|Encodable)\b)'
DELETED_SWIFT_CANDIDATES=$(grep -rlE "${DELETED_SWIFT_UNION}" Sources/ 2> /dev/null || true)
# The candidates matching ONE ban, or nothing. An empty candidate list answers without a grep.
among_deleted() {
  [[ -z "${DELETED_SWIFT_CANDIDATES}" ]] && return 0
  # shellcheck disable=SC2086 # the candidate list is a FILE LIST on purpose
  grep -lE "$1" ${DELETED_SWIFT_CANDIDATES} 2> /dev/null || true
}

SWIFT_PROTOCOL="Sources/SlopDeskSupervisor/SupervisorProtocol.swift"
SWIFT_FRAME="Sources/SlopDeskSupervisor/SupervisorFrame.swift"
RUST_PROTOCOL="rust/slopdesk-superd/src/protocol.rs"
RUST_FRAME="rust/slopdesk-superd/src/frame.rs"
SWIFT_SCREEN_PROTOCOL="Sources/SlopDeskScreen/ScreenProtocol.swift"
RUST_SCREEN_SERVER="rust/slopdesk-screend/src/server.rs"
# The wire left screend for its own crate, for `slopdesk-sanitize`'s reason: two callers, one
# implementation. hostd is the other caller, and while the layouts lived inside the daemon the only
# way to reach them was to BE the daemon — so hostd hand-wrote a second copy in Swift.
RUST_SCREEN_PROTOCOL="rust/slopdesk-screenwire/src/lib.rs"
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

# The CONTROL channel is the widest wire on this path — 28 message types, five of them carrying a
# list of records, and every record carrying text that is decoded LOSSILY. It is also the only one
# whose strings cross through an ARENA rather than an offset, because a lossy repair produces bytes
# that are not in the datagram, so the answer cannot be a substring of the question.
SWIFT_CONTROL=Sources/SlopDeskVideoProtocol/VideoControlCodec.swift
for entry in slopdesk_video_control_encode slopdesk_video_control_decode \
  slopdesk_video_control_constant; do
  if ! grep -q "${entry}(" "${SWIFT_CONTROL}"; then
    fail "${SWIFT_CONTROL} no longer calls ${entry} — the control wire is rust/slopdesk-video's"
  fi
done
# The length-prefixed-string pair a second speller would need back. The writer and the reader
# themselves are pinned target-wide below.
for revived in appendVideoControlLengthPrefixed readVideoControlLengthPrefixed; do
  if grep -q "${revived}" "${SWIFT_CONTROL}"; then
    fail "${SWIFT_CONTROL} grew '${revived}' back — control bytes are laid out once, in Rust"
  fi
done
# The five budgets the host packs against. Prose may still name them; a doc comment is not what the
# chunker reads.
if grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_CONTROL}" |
  grep -qE '(static let|=) *(1177|1186|120|32 \* 1024|48 \* 1024)\b'; then
  fail "a control budget is spelled in Swift again — slopdesk_video_control_constant vends all five"
fi

# With the control channel gone through the shim, NO codec in SlopDeskVideoProtocol lays out a byte:
# the target's whole remaining ownership of the wire is `VideoProtocolError`. So the pin is the
# TARGET, not a file at a time — a new codec cannot be added beside the pinned ones and spell its
# own bytes. The hostile-datagram builders the tests still need live in
# Tests/SlopDeskVideoProtocolTests/VideoWireFixtureBytes.swift, where a second speller of the wire
# cannot become a second implementation of it.
byte_spellers=""
while IFS= read -r swift_file; do
  # Prose may name the two — this file's own header explains where they went.
  if grep -qE 'appendBE|VideoByteReader' <<< "$(grep -vE '^[[:space:]]*//' "${swift_file}")"; then
    byte_spellers="${byte_spellers}${byte_spellers:+, }${swift_file}"
  fi
done < <(find Sources/SlopDeskVideoProtocol -name '*.swift' | sort)
if [[ -n "${byte_spellers}" ]]; then
  fail "SlopDeskVideoProtocol lays out bytes again (${byte_spellers}) — every codec in it goes through slopdesk-ffi"
fi

# PATH-1, the terminal wire, is the LAST of the three codecs to move and the one the whole product
# sits on: 30 message types, an `.output` flood behind every keystroke. Its Swift side is now a
# flattener and nothing else — the layout lives in rust/slopdesk-wire, reached through slopdesk-ffi.
SWIFT_WIRE=Sources/SlopDeskProtocol/WireMessageCodec.swift
for entry in slopdesk_wire_message_encode slopdesk_wire_message_decode \
  slopdesk_wire_message_byte_count slopdesk_wire_constant; do
  if ! grep -q "${entry}(" "${SWIFT_WIRE}"; then
    fail "${SWIFT_WIRE} no longer calls ${entry} — the terminal wire is rust/slopdesk-wire's"
  fi
done
# The two the deleted encoder and decoder were built out of. SlopDeskProtocol still owns them for
# the framing and metadata layers that have not moved yet, so the pin is this FILE: the codec that
# went to Rust may not quietly come back beside them.
for revived in appendBE BigEndianReader; do
  if grep -q "${revived}" <<< "$(grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_WIRE}")"; then
    fail "${SWIFT_WIRE} grew '${revived}' back — PATH-1 bytes are laid out once, in Rust"
  fi
done
# The three numbers both ends would otherwise type: the wire version, a session id's width and the
# frame ceiling. `slopdesk_wire_constant` vends all three; prose may still name them.
# The version travels as a bare `1`, which no numeric pattern can tell from a tag byte — so it is
# pinned by NAME, and the two widths by value.
for numbered in "${SWIFT_WIRE}" Sources/SlopDeskProtocol/SlopDesk.swift; do
  if grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${numbered}" |
    grep -qE '(static let|==) *(16 \* 1024 \* 1024|16)\b'; then
    fail "a wire width is spelled in Swift again (${numbered}) — slopdesk_wire_constant vends it"
  fi
  if grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${numbered}" |
    grep -qE 'protocolVersion[^=]*= *[0-9]'; then
    fail "the wire version is spelled in Swift again (${numbered}) — slopdesk_wire_constant vends it"
  fi
done

# The framing that wraps that table went with it: the buffering, the cursor that avoids a per-frame
# memmove and the fail-stop on a lost byte-boundary are `rust/slopdesk-wire`'s FrameDecoder, held
# through a handle. What is left in Swift is the handle and the error mapping.
SWIFT_FRAMING=Sources/SlopDeskProtocol/FrameDecoder.swift
for entry in slopdesk_frame_decoder_new slopdesk_frame_decoder_free slopdesk_frame_decoder_append \
  slopdesk_frame_decoder_next slopdesk_frame_decoder_run; do
  if ! grep -q "${entry}(" "${SWIFT_FRAMING}"; then
    fail "${SWIFT_FRAMING} no longer calls ${entry} — the terminal framing is rust/slopdesk-wire's"
  fi
done
# The buffer this file must NOT grow back. A second reader of the same stream is not a second
# implementation; a second BUFFER of it is, and it is how the cursor and the fail-stop drift apart.
for revived in readOffset compactConsumed readPrefix 'private var buffer'; do
  if grep -q "${revived}" <<< "$(grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_FRAMING}")"; then
    fail "${SWIFT_FRAMING} grew '${revived}' back — the frame buffer is Rust's, and there is one"
  fi
done

# The mux layer. The envelope's bytes, the framing, the credit arithmetic and the channel state
# machine are all rust/slopdesk-wire's — the Swift is the seam that flattens and asks.
SWIFT_MUX=Sources/SlopDeskProtocol/Mux
for entry in slopdesk_mux_frame_encode slopdesk_mux_frame_decode slopdesk_mux_frame_byte_count \
  slopdesk_mux_envelope_constant; do
  if ! grep -q "${entry}(" "${SWIFT_MUX}/MuxEnvelope.swift"; then
    fail "${SWIFT_MUX}/MuxEnvelope.swift no longer calls ${entry} — the mux envelope is Rust's"
  fi
done
for entry in slopdesk_mux_decoder_new slopdesk_mux_decoder_free slopdesk_mux_decoder_append \
  slopdesk_mux_decoder_next slopdesk_mux_decoder_payload; do
  if ! grep -q "${entry}(" "${SWIFT_MUX}/MuxFrameDecoder.swift"; then
    fail "${SWIFT_MUX}/MuxFrameDecoder.swift no longer calls ${entry} — the mux framing is Rust's"
  fi
done
for entry in slopdesk_flow_credit_consume slopdesk_receive_window_consume \
  slopdesk_bounded_queue_enqueue slopdesk_channel_table_allocate slopdesk_mux_flow_constant; do
  if ! grep -rq "${entry}(" "${SWIFT_MUX}"; then
    fail "${SWIFT_MUX} no longer calls ${entry} — the mux policies are rust/slopdesk-wire's"
  fi
done
# The arithmetic these files must NOT grow back. A window that is clamped in two languages is two
# windows, and the one that drifts low stalls a channel forever rather than failing.
for revived in 'pendingCredit +=' 'remaining -=' 'outstanding +=' 'states\[' terminalRing; do
  if grep -q "${revived}" <<< "$(grep -rvE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_MUX}")"; then
    fail "${SWIFT_MUX} grew '${revived}' back — the mux arithmetic is Rust's, and there is one"
  fi
done

# The DEMUX RULE is Rust's too, and it is the newest of these to move. It used to be a Swift
# `MuxRoutingCore.route` reaching six ways into a table that was ALREADY Rust — a rule living apart
# from the state its every branch reads and then writes, which is the arrangement that lets one of
# them be edited alone. `slopdesk_wire`'s `ChannelTable::route` decides now; the Swift attaches the
# payload (the bytes never cross) and spells the two drop reasons, which is presentation.
SWIFT_ROUTING=Sources/SlopDeskTransport/Mux/MuxRoutingCore.swift
if ! grep -q 'table.route(' "${SWIFT_ROUTING}"; then
  fail "${SWIFT_ROUTING} stopped asking the door — it is a face, not a second demux rule"
fi
if ! grep -q 'pub fn route' rust/slopdesk-wire/src/mux/channels.rs; then
  fail "rust/slopdesk-wire/src/mux/channels.rs lost route — the demux rule lives beside its table"
fi
# What the face must NOT grow back: any branch that re-decides what the rule already decided. Each
# of these is a table verb the old copy called directly, and one of them reappearing here means the
# decision has two owners again.
for redecided in 'table.isOpen' 'table.open(' 'table.reject(' 'table.remoteClose(' 'table.localClose(' 'table.state('; do
  if grep -q "${redecided}" <<< "$(grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_ROUTING}")"; then
    fail "${SWIFT_ROUTING} grew '${redecided}' back — the demux decision is Rust's, and there is one"
  fi
done

# The git DIALECT — `main ↑2 ↓1 +3 !4 ?5 ~1 $2`. The order, the sigil each role gets, the weight it
# is set at and the ladder it sheds down are `slopdesk_workspace::git_line`'s. The Swift face asks
# and SPELLS: it puts a glyph next to a number, and it supplies the branch's own text.
#
# This one is ratcheted because it has already been got wrong once, in exactly the way a second
# speller gets things wrong: a dead `PaneGitSummary.compactLine` spelled a conflict `=` where the
# live renderer spelled it `~`, and both compiled until the copy was deleted (docs/56 increment 45).
SWIFT_GIT_LINE=Sources/SlopDeskClientCore/Rail/SidebarGitLine.swift
if ! grep -q 'slopdesk_git_line_runs' "${SWIFT_GIT_LINE}"; then
  fail "${SWIFT_GIT_LINE} stopped asking the door — it spells the dialect, it does not choose it"
fi
if ! grep -q 'pub fn runs' rust/slopdesk-workspace/src/git_line.rs; then
  fail "rust/slopdesk-workspace/src/git_line.rs lost runs — the dialect lives where its ladder does"
fi
# No SIGIL may be minted on the Swift side. Every one of these is a glyph the rule chooses; a
# literal here is a second dialect being born, whatever it happens to agree with today.
for sigil in '"↑' '"↓' '"+\\(' '"!\\(' '"?\\(' '"~' '"\$\\('; do
  if grep -qF "${sigil}" <<< "$(grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_GIT_LINE}")"; then
    fail "${SWIFT_GIT_LINE} minted the sigil ${sigil} — the glyph is the rule's, only the join is not"
  fi
done

# The metadata RPC's payloads. Eleven encode/decode pairs, the porcelain fold the sidebar and the
# host status push must agree on, and the three numbers a second speller would drift — all
# rust/slopdesk-wire's. The Swift is the value types and the flatten.
SWIFT_METADATA=Sources/SlopDeskProtocol/Metadata/MetadataCodec.swift
for entry in slopdesk_metadata_encode_processes slopdesk_metadata_decode_processes \
  slopdesk_metadata_encode_ports slopdesk_metadata_decode_ports \
  slopdesk_metadata_encode_dir_listing slopdesk_metadata_decode_dir_listing \
  slopdesk_metadata_encode_git_status slopdesk_metadata_decode_git_status \
  slopdesk_metadata_encode_agent_sessions slopdesk_metadata_decode_agent_sessions \
  slopdesk_metadata_encode_clipboard_set slopdesk_metadata_decode_clipboard_set \
  slopdesk_metadata_encode_clipboard_read_request slopdesk_metadata_decode_clipboard_read_request \
  slopdesk_metadata_encode_clipboard_read_response slopdesk_metadata_decode_clipboard_read_response \
  slopdesk_metadata_encode_host_vitals slopdesk_metadata_decode_host_vitals \
  slopdesk_metadata_encode_service_endpoint slopdesk_metadata_decode_service_endpoint \
  slopdesk_metadata_encode_code_open_disposition slopdesk_metadata_decode_code_open_disposition \
  slopdesk_metadata_encode_code_font_spec slopdesk_metadata_decode_code_font_spec \
  slopdesk_metadata_fold_git_codes slopdesk_metadata_constant; do
  # By NAME, not by call: half of these cross as a function REFERENCE into a shared helper.
  if ! grep -q "${entry}" "${SWIFT_METADATA}"; then
    fail "${SWIFT_METADATA} no longer calls ${entry} — the metadata payloads are rust/slopdesk-wire's"
  fi
done
# The reader, the writer and the clamps this file must NOT grow back. A payload validated in two
# languages is two validations, and the lenient one is the one a hostile body finds.
for revived in BigEndianReader appendBE clampedUTF8 clampedCount readString; do
  if grep -q "${revived}" <<< "$(grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_METADATA}")"; then
    fail "${SWIFT_METADATA} grew '${revived}' back — metadata bodies are parsed once, in Rust"
  fi
done
# The three numbers slopdesk_metadata_constant vends, and the per-entry widths that size a decode.
if grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_METADATA}" |
  grep -qE '12 \* 1024 \* 1024|UInt32\.max|65535|4 \+ 4 \+ 2|2 \+ 1 \+ 2'; then
  fail "${SWIFT_METADATA} spells a metadata constant again — slopdesk_metadata_constant vends them"
fi
printf 'check-supervisor: the metadata payloads are Rust too — 11 pairs, one fold, no Swift reader.\n'

# MetadataVerb STAYS in Swift — a name table with no arithmetic, the same category as MuxFrameType.
# What cannot drift is the byte: a verb numbered differently at the two ends is a client asking for
# the clipboard and a host answering with vitals.
verb_swift="Sources/SlopDeskProtocol/Metadata/MetadataVerb.swift"
verb_rust="rust/slopdesk-wire/src/metadata/verb.rs"
swift_verbs=$(grep -oE 'case [a-zA-Z]+ = [0-9]+' "${verb_swift}" |
  awk '{ gsub(/case /, ""); print toupper($1) "=" $3 }' | sort -u) || true
rust_verbs=$(grep -oE '^\s+[A-Z][A-Za-z]+ = [0-9]+,' "${verb_rust}" |
  awk '{ gsub(/,$/, "", $3); print toupper($1) "=" $3 }' | sort -u) || true
verb_count=$(printf '%s\n' "${swift_verbs}" | grep -c .) || true
if [[ "${verb_count}" -lt 26 ]]; then
  fail "only ${verb_count} metadata verbs found in ${verb_swift} — the extraction in this gate has gone stale"
fi
if ! diff <(printf '%s\n' "${swift_verbs}") <(printf '%s\n' "${rust_verbs}") > /dev/null; then
  printf '%s\n' "$(diff <(printf '%s\n' "${swift_verbs}") <(printf '%s\n' "${rust_verbs}"))" >&2
  fail "${verb_swift} and ${verb_rust} disagree — the verb byte is the whole of the request (docs/20 §7)"
fi
printf 'check-supervisor: the metadata verbs agree — %s names, both languages.\n' "${verb_count}"

# The workspace CHANNEL payloads — subscribe, presence, intent, intentResult, roster — are Rust too.
# The Swift file is a face over `rust/slopdesk-wire`'s `workspace` module: value types, and calls.
SWIFT_WS_CHANNEL="Sources/SlopDeskProtocol/WorkspaceChannelCodec.swift"
for entry in slopdesk_workspace_encode_subscribe slopdesk_workspace_decode_subscribe \
  slopdesk_workspace_encode_presence slopdesk_workspace_decode_presence \
  slopdesk_workspace_encode_intent slopdesk_workspace_decode_intent \
  slopdesk_workspace_encode_intent_result slopdesk_workspace_decode_intent_result \
  slopdesk_workspace_encode_roster slopdesk_workspace_decode_roster slopdesk_workspace_constant; do
  # By NAME, not by call: several of these cross as a function REFERENCE into a shared helper.
  if ! grep -q "${entry}" "${SWIFT_WS_CHANNEL}"; then
    fail "${SWIFT_WS_CHANNEL} no longer calls ${entry} — the workspace payloads are parsed in Rust (docs/45 §5.2)"
  fi
done
for revived in 'BigEndianReader' 'appendBE' 'clampUTF8' 'readUUID' 'readBytes('; do
  if grep -q "${revived}" <<< "$(grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_WS_CHANNEL}")"; then
    fail "${SWIFT_WS_CHANNEL} grew '${revived}' back — workspace bodies are parsed once, in Rust"
  fi
done
# The bounds slopdesk_workspace_constant vends: the label cap, the record cap, and the three
# per-record floors that size a roster decode.
if grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_WS_CHANNEL}" |
  grep -qE 'maxLabelBytes = [0-9]|maxRecords = [0-9]|\* 42|\* 22|\* 21'; then
  fail "${SWIFT_WS_CHANNEL} spells a workspace bound again — slopdesk_workspace_constant vends them"
fi
printf 'check-supervisor: the workspace payloads are Rust too — 5 pairs, three arrays, no Swift reader.\n'

# The channel VOCABULARY stays in Swift — four name tables with no arithmetic in them — so what
# cannot drift is the byte. A verb numbered differently at the two ends is a client subscribing and
# a host reading an intent.
ws_vocab_swift="${SWIFT_WS_CHANNEL}"
ws_vocab_rust="rust/slopdesk-wire/src/workspace.rs"
swift_ws_vocab=$(grep -oE 'case [a-zA-Z]+ = [0-9]+' "${ws_vocab_swift}" |
  awk '{ gsub(/case /, ""); print toupper($1) "=" $3 }' | sort -u) || true
rust_ws_vocab=$(grep -oE '^\s+[A-Z][A-Za-z]+ = [0-9]+,' "${ws_vocab_rust}" |
  awk '{ gsub(/,$/, "", $3); print toupper($1) "=" $3 }' | sort -u) || true
ws_vocab_count=$(printf '%s\n' "${swift_ws_vocab}" | grep -c .) || true
if [[ "${ws_vocab_count}" -lt 14 ]]; then
  fail "only ${ws_vocab_count} workspace channel names found in ${ws_vocab_swift} — this gate has gone stale"
fi
if ! diff <(printf '%s\n' "${swift_ws_vocab}") <(printf '%s\n' "${rust_ws_vocab}") > /dev/null; then
  printf '%s\n' "$(diff <(printf '%s\n' "${swift_ws_vocab}") <(printf '%s\n' "${rust_ws_vocab}"))" >&2
  fail "${ws_vocab_swift} and ${ws_vocab_rust} disagree — the verb byte is the whole of the request (docs/45 §5.2)"
fi
printf 'check-supervisor: the workspace channel vocabulary agrees — %s names, both languages.\n' "${ws_vocab_count}"

# Two env gates docs/46 records as "deleted deliberately — do not reintroduce". Multi-client sync is
# unconditional because a client draws its layout FROM the document: a host that switched the channel
# off would hand it a blank window and no error to explain it, which is the worst shape a kill switch
# can take. `SLOPDESK_WORKSPACE_DOC` already has a ratchet — a test that sets it to 0 and proves the
# document is served anyway — but `SLOPDESK_PANE_FANOUT` had nothing, so the ban was half a ban.
# Shipping code only: the test that spells the name is the enforcement, not a violation of it.
fanout_gate=$(grep -rl 'SLOPDESK_PANE_FANOUT\|SLOPDESK_WORKSPACE_DOC' Sources/ || true)
if [[ -n "${fanout_gate}" ]]; then
  printf '%s\n' "${fanout_gate}" >&2
  fail "a deleted multi-client env gate is back in shipping code — sync is unconditional (docs/46)"
fi

# The last hand-rolled big-endian helper left `Sources/` when its final production caller did: every
# wire body is now written and read in Rust, and `appendBE`/`BigEndianReader` live on only as a TEST
# fixture (`Tests/SlopDeskProtocolTests/BigEndianFixtureBytes.swift`), where hand-spelled bytes are
# the POINT — a fixture that agreed with the encoder by construction would assert nothing.
# Back under `Sources/` they are the seed of a second implementation of a wire, which always arrives
# as "just this one field" rather than as a codec.
bigendian_revived=$(among_deleted '(func|var) appendBE|(struct|enum|final class|class) BigEndianReader')
if [[ -n "${bigendian_revived}" ]]; then
  printf '%s\n' "${bigendian_revived}" >&2
  fail "a big-endian helper is back in Sources/ — wire bodies are Rust's, the helper is a test fixture"
fi
if [[ ! -f Tests/SlopDeskProtocolTests/BigEndianFixtureBytes.swift ]]; then
  fail "Tests/SlopDeskProtocolTests/BigEndianFixtureBytes.swift is gone — the fixture bytes must stay hand-spelled"
fi
printf 'check-supervisor: no big-endian helper under Sources/ — hand-spelled bytes are a fixture now.\n'

# Statuses by NUMBER only — the two ends name the failure differently on purpose (`internalError`
# reads as a case, `Internal` is a keyword-adjacent Rust variant), and it is the byte that travels.
swift_screen_status=$(
  awk '/public enum ScreenStatus/, /^\}/' "${SWIFT_SCREEN_PROTOCOL}" |
    sed -n 's/^ *case [a-zA-Z]* = \([0-9][0-9]*\)$/\1/p' | sort -n | tr '\n' ' '
)
rust_screen_status=$(
  awk '/pub enum Status/, /^\}/' "${RUST_SCREEN_PROTOCOL}" |
    sed -n 's/^ *[A-Z][a-zA-Z]* = \([0-9][0-9]*\),$/\1/p' | sort -n | tr '\n' ' '
)
same "screend status bytes" "${swift_screen_status}" "${rust_screen_status}"

swift_banner=$(sed -n 's/.*helloBanner = "\(.*\)"$/\1/p' "${SWIFT_SCREEN_PROTOCOL}" | head -1)
if ! grep -q "HELLO_BANNER: &\[u8\] = b\"${swift_banner}\"" "${RUST_SCREEN_PROTOCOL}"; then
  fail "screend hello banner '${swift_banner}' is not what ${RUST_SCREEN_PROTOCOL} answers"
fi

# The banner is the PROTOCOL identity; the RUNNING BUILD's version follows it as a third field
# (`docs/49`). screend is a LaunchAgent that outlives hostd's build, so an upgrade leaves the old
# process serving — this field is the only thing that tells hostd so. Two halves are ratcheted here
# because a skew in either is silent: a Swift side reading a field Rust stopped appending answers
# `nil`, which the audit reports as "unknown" forever, and a Rust side that appended it somewhere
# else would be read as a version that never matches.
if ! grep -q 'pub fn hello_payload' "${RUST_SCREEN_PROTOCOL}"; then
  fail "${RUST_SCREEN_PROTOCOL} no longer builds the hello payload — hostd cannot learn screend's build version (docs/49)"
fi
if ! grep -q 'hello_payload(env!("CARGO_PKG_VERSION"))' "${RUST_SCREEN_SERVER}"; then
  fail "screend's hello no longer answers with its OWN compile-time version — see ${RUST_SCREEN_SERVER}"
fi
if ! grep -q 'func buildVersion(fromHello' "${SWIFT_SCREEN_PROTOCOL}"; then
  fail "${SWIFT_SCREEN_PROTOCOL} no longer parses screend's build version out of hello (docs/49)"
fi

# The RESET frame's flag bits. Each is one bit of a byte hostd sets and screend reads, so a bit
# claimed on one side and not the other does not fail to parse: a rebuild-replay flag read as
# agent-changed rebuilds nothing and reports an agent that did not change. DERIVED both ways, so a
# fifth flag added to either side without the other fails here rather than at a running daemon.
# `scripts/check-shared-constants.py` sends the pair here — a socket cannot link the other's const.
swift_screen_flags=$(
  sed -n 's/^ *public static let flag\([A-Za-z]*\): UInt8 = \(0x[0-9a-fA-F]*\)$/\1 \2/p' \
    "${SWIFT_SCREEN_PROTOCOL}" | tr '[:upper:]' '[:lower:]' | sort | tr '\n' ' '
)
rust_screen_flags=$(
  sed -n 's/^pub const FLAG_\([A-Z_]*\): u8 = \(0x[0-9a-fA-F]*\);$/\1 \2/p' \
    "${RUST_SCREEN_PROTOCOL}" | tr -d '_' | tr '[:upper:]' '[:lower:]' | sort | tr '\n' ' '
)
if [[ -z "${swift_screen_flags}" ]]; then
  fail "${SWIFT_SCREEN_PROTOCOL} names no reset flags — this gate reads nothing and would pass"
fi
same "screend reset flags" "${swift_screen_flags}" "${rust_screen_flags}"

# The frame CEILING — one byte count that used to be spelled twice, `ScreenWire.maximumFrameBytes`
# against `screenwire::MAX_FRAME`, and is now spelled once and asked for.
#
# This gate used to `same`-compare the two expressions, and the comment it carried argued that a
# ratchet was the only instrument available because screend is a separately-shipped BINARY, so no
# door reaches it. That argument was true of the DAEMON and was never true of hostd's end: the
# client half is linked Swift calling `rust/slopdesk-screenwire` through `CSlopDeskFFI` already —
# it encodes its requests through a door six lines up. So the ceiling became a door too, and what
# is ratcheted changes shape with it: not "do the two numbers agree" but "is there still only one".
#
# The Rust side of the pair is now pinned by a cargo test in `rust/slopdesk-ffi/src/screen.rs`
# (`the_size_constants_are_vended_and_an_unknown_index_is_not_a_size`), which is a stronger check
# than this file could make — it compares the door's answer to `MAX_FRAME` itself rather than to a
# `sed` of its source line. What is left for a ratchet is the SWIFT side: that it keeps asking.
#
# Which way this would drift decides how it fails, and that has not changed: a client ceiling above
# screend's makes screend kill the connection mid-stream on a frame the client thought legal; below
# it makes the client reject a frame screend was entitled to send. Neither reports a size.
#
# BREAK-TESTED 2026-08-22: putting `= 64 * 1024 * 1024` back on the `maximumFrameBytes` line fires
# both halves —
#   check-supervisor: FAIL — Sources/SlopDeskScreen/ScreenProtocol.swift spells the screend frame ceiling as a literal again — it is slopdesk_screen_constant(0), and screend's copy is pinned by a cargo test
#   check-supervisor: FAIL — Sources/SlopDeskScreen/ScreenProtocol.swift stopped asking the door for the frame ceiling — a second spelling of 64 MiB is how the two ends drift apart
# — and the shipped tree is silent on both.
# Both halves read the file with its COMMENTS STRIPPED, and both do the strip here rather than
# through `spells`, because **`spells` is defined ~1,600 lines BELOW this gate** and a shell function
# does not exist before its definition is executed. That is not a style note — it was a live bug in
# this block for one run, and it failed in both directions at once: the presence check called a
# missing command, got 127, and reported that the door was gone from a file that calls it; the ban
# called the same missing command, got 127, read it as "no match", and passed on a file it had not
# opened. **A gate that moved above its helper reports a defect it invented and misses the one it
# was written for.** It was caught by running the real script in place; a spliced copy with the
# helpers hoisted to the top had shown both halves green.
#
# Stripped into a variable and matched from a here-string, never down a pipe — `grep -q` exits at
# the first match, `sed` then dies of SIGPIPE, and under `pipefail` a FOUND spell reads as not found.
# Same reasoning `spells` carries; this is the two-line form of it, for a gate that cannot call it.
screen_protocol_stripped=$(sed -E 's,//.*,,' "${SWIFT_SCREEN_PROTOCOL}")
# The door, asked for by name. Comment-stripped because the doc comment on this very constant
# discusses the ratchet that used to read it: a `grep` here would be reading the explanation rather
# than the code, and would stay green through a deletion that left the paragraph behind.
if ! grep -qE 'slopdesk_screen_constant\(' <<< "${screen_protocol_stripped}"; then
  fail "${SWIFT_SCREEN_PROTOCOL} stopped asking the door for the frame ceiling — a second spelling of 64 MiB is how the two ends drift apart"
fi
# The literal itself, banned in the file that used to hold it. Matched as the MEGABYTE EXPRESSION
# rather than as a digit run: `64 * 1024 * 1024` is how a reader is meant to see it, and it is also
# the only shape anyone regrows — nobody types `67108864`. The strip means the paragraph above,
# which says "64 MiB" in prose, cannot trip it.
if grep -qE '= *[0-9]+ *\* *1024 *\* *1024' <<< "${screen_protocol_stripped}"; then
  fail "${SWIFT_SCREEN_PROTOCOL} spells the screend frame ceiling as a literal again — it is slopdesk_screen_constant(0), and screend's copy is pinned by a cargo test"
fi

# The reply STATUS byte, which is the last of screend's three alphabets and the one nothing watched.
# `ScreenStatus` and `screenwire::Status` are the same three values in the same order, and the enum
# pass in `check-shared-constants.py` deliberately does not pair them: the third case is spelled
# `internalError` on one side and `Internal` on the other, so a name-for-name comparison would
# report a naming choice as a drift and get itself deleted. The NUMBERS are the contract, so the
# numbers are what is compared, in declaration order, with the count riding along — an inserted case
# shifts the sequence and a renumbered one changes it. A status byte read as the wrong status is a
# refusal reported as a success, or the reverse.
swift_screen_status=$(sed -nE 's/^ *case [A-Za-z]+ = ([0-9]+)$/\1/p' \
  <(sed -n '/^public enum ScreenStatus/,/^}/p' "${SWIFT_SCREEN_PROTOCOL}") | tr '\n' ' ')
rust_screen_status=$(sed -nE 's/^ *[A-Z][A-Za-z]* = ([0-9]+),$/\1/p' \
  <(sed -n '/^pub enum Status/,/^}/p' "${RUST_SCREEN_PROTOCOL}") | tr '\n' ' ')
same "the screend status alphabet" "${swift_screen_status}" "${rust_screen_status}"

# ── The 15 MiB opaque budget, which is one cap spelled THREE times ─────────────────────────────
# A metadata `read` verb answers a file, and the ceiling on how much of one it will carry back is
# written in three places: `MetadataResponseBuilder.defaultMaxOpaquePayloadBytes` (what hostd will
# put in a reply), `HostMetadataProbe.maxCaptureBytes` (what hostd will accumulate from the child)
# and `slopdesk_probe::run::MAX_OPAQUE_READ_BYTES` (what the child will read before truncating).
# Three names, one number, and `docs/55` §8 has carried the pair as outstanding since it was found.
#
# `slopdesk-probe` is a `[[bin]]` hostd SPAWNS — it links nothing of hostd's and hostd links nothing
# of its — so the third spelling cannot become a door however the first two are settled, and the
# ratchet is the answer the lifetime picks rather than a compromise. The two Swift halves are a
# genuine second finding, reported rather than folded: they live in one target and could be one
# constant, which is a `Sources/` change and not this script's to make.
#
# A skew here is silent in the worst direction. The probe truncates at ITS ceiling and marks the
# payload truncated; hostd's builder refuses at ITS ceiling by dropping the payload. Raise only the
# probe's and hostd silently drops replies the probe worked to produce; raise only hostd's and the
# extra capacity is unreachable, because the bytes were already thrown away one process upstream.
SWIFT_METADATA_BUILDER=Sources/SlopDeskHost/MetadataResponseBuilder.swift
SWIFT_METADATA_PROBE=Sources/SlopDeskHost/HostMetadataProbe.swift
RUST_PROBE_RUN=rust/slopdesk-probe/src/run.rs
swift_opaque_cap=$(sed -nE 's/^ *static let defaultMaxOpaquePayloadBytes = (.*)$/\1/p' \
  "${SWIFT_METADATA_BUILDER}" | tr -d ' ')
swift_capture_cap=$(sed -nE 's/^ *private static let maxCaptureBytes = (.*)$/\1/p' \
  "${SWIFT_METADATA_PROBE}" | tr -d ' ')
rust_opaque_cap=$(sed -nE 's/^pub const MAX_OPAQUE_READ_BYTES: usize = (.*);$/\1/p' \
  "${RUST_PROBE_RUN}" | tr -d ' ')
same "the opaque payload budget hostd will REPLY with" "${swift_opaque_cap}" "${rust_opaque_cap}"
same "the opaque payload budget hostd will CAPTURE" "${swift_capture_cap}" "${rust_opaque_cap}"

# No SWIFT screen engine. The parser, the renderer and the overprint collapser were DELETED when
# they moved to Rust, and a re-added Swift copy is the cross-language mirror the tree forbids —
# which is exactly the shape a "just a small fallback" commit takes (`CLAUDE.md`, `docs/52` §4).
revived=$(among_deleted 'enum TerminalScreenModel|struct TerminalScreenModel|enum LineOverprintCollapser|enum TerminalSnapshotRenderer')
if [[ -n "${revived}" ]]; then
  printf '%s\n' "${revived}" >&2
  fail "a Swift screen engine is back in Sources/ — screend owns the parse and the render (docs/52)"
fi

# No SWIFT replay passes either. The six byte machines of the scrollback replay transform moved into
# screend's `sanitize` verb and were DELETED here in the same change. They are the likeliest of all
# the moved code to grow a "tiny local fallback" — each is small, pure and framework-free, and an
# absent screend now means a RAW replay rather than a partly-cleaned one, which is the documented
# passthrough policy and not an invitation (`docs/52` §4, `ScrollbackReplayTransform`).
# `ScrollbackReplayTransform` itself is NOT named: it stayed, as the caller that picks the options.
# Scoped to DECLARATIONS so prose explaining where the passes went does not fail its gate.
passes_revived=$(among_deleted '(enum|struct|final class|class|actor) (TerminalInputModeStripper|InputModeFinalState|AltScreenSegmentStripper|SyncUpdateFrameCollapser|ScrollbackDistiller|TerminalQueryStripper|PromptEOLMarkStripper)\b')
if [[ -n "${passes_revived}" ]]; then
  printf '%s\n' "${passes_revived}" >&2
  fail "a Swift replay pass is back in Sources/ — screend's sanitize verb owns the chain (docs/52)"
fi

# Nor the CHUNK BOUNDARY. Holding back the trailing half of a cut escape sequence or UTF-8 scalar was
# the last byte machine hostd kept, on the theory that the ring boundary is the host's bookkeeping —
# it is not, every rule is read out of the bytes (stage 26, `docs/52` §4). Keeping it here also made
# "the reassert lands BEFORE the dangling half" a convention two call sites had to remember instead
# of an invariant of screend's reply, and `compose` vs `transcript` disagree about whether the
# dangling half survives at all. Function names, not types: these were static methods.
boundary_revived=$(among_deleted 'func (splitTrailingIncompleteEscape|splitTrailingIncompleteUTF8)\b|trailingEscapeScanBytes *[:=]')
if [[ -n "${boundary_revived}" ]]; then
  printf '%s\n' "${boundary_revived}" >&2
  fail "a Swift chunk-boundary splitter is back in Sources/ — screend splits its own input (docs/52 §4)"
fi

# Nor the disk JOURNAL. superd owns the PTY read, so it numbers the pane's stream; a second process
# journaling a stream it does not number is what produced the `.resume` sidecar, its pane-life stamp
# and the rate-limited re-claim, all of which went with it (stage 27, `docs/51` §6.8). What hostd
# kept is `ScrollbackTranscripts` — directory, cap, which end of life deletes, what the bytes mean —
# and it holds no file descriptor. Two shapes are gated: the deleted types, and any Swift that opens
# a `.scrollback`/`.resume` path for WRITING. The read side is deliberately not gated: hostd opens
# the path `journal_info` hands back, which is the whole point of returning a path.
journal_revived=$(among_deleted '(enum|struct|final class|class|actor) (ScrollbackJournal|ScrollbackJournalStore)\b')
if [[ -n "${journal_revived}" ]]; then
  printf '%s\n' "${journal_revived}" >&2
  fail "a Swift scrollback journal is back in Sources/ — superd writes the transcript (docs/51 §6.8)"
fi
journal_writer=$(among_deleted '(createFile|forWritingTo|\.write\(to:).*\.(scrollback|resume)("|\)|$)')
if [[ -n "${journal_writer}" ]]; then
  printf '%s\n' "${journal_writer}" >&2
  fail "Swift is writing a journal file — superd owns every write under the scrollback dir (docs/51 §6.8)"
fi

# ── Two families may write `unsafe`, and this is not one of them ────────────────────────────────
# Every crate under `rust/` except those three carries `unsafe_code = "forbid"`, which rustc already
# enforces per crate. What rustc cannot notice is the shape drifting back: a new crate that quietly
# says "deny", or a manifest that says nothing at all and inherits nothing. Both would reopen the
# hole stage 28 closed — `deny` is liftable by one `#[allow]`, and a missing policy is `allow` by
# default. So the MANIFESTS are gated, not the source.
#
# THREE crates are exempt, each with ONE narrow kind of obligation — that is the isolation, and a
# fourth would dissolve it. `slopdesk-posix` argues about syscalls; `slopdesk-ffi` argues about one
# thing repeated, whether a `(ptr, len)` from Swift is live for the call; `slopdesk-gfsimd` argues
# about one thing narrower still, whether a 16-byte load stays inside its chunk, which does not name
# a language boundary at all. The third was bought with a measurement rather than an argument —
# `docs/DECISIONS.md` carries it — and that is the bar a fourth would have to clear. `forbid` in any
# of them would make the per-site `#[expect]` impossible, and those self-expiring exemptions are what
# keeps the surfaces auditable. Root-workspace MEMBERS (`slopdesk-hook`, `-ctl`, `-cli`, `-probe`)
# state `[lints] workspace = true` and inherit the root's `forbid`, so they are accepted that way.
#
# The SECOND family is `slopdesk-apple-*`, opened by `docs/57-apple-frameworks-in-rust.md`, and it is
# a different permission rather than three more seats at the same table. A crate there wraps ONE
# Apple framework area, reaches it only through `objc2`'s generated bindings, and may write `unsafe`
# only to call a binding that is itself `unsafe` — never to dereference a pointer it made. That is
# what makes the family bounded where a fourth hand-written crate would not be: the obligation each
# block carries is the FRAMEWORK's rule, which the framework documents, not a Rust rule about memory
# nobody else can check. Membership is by NAME, so adding one is visible in this file's diff, and
# the three extra conditions below are checked per crate rather than trusted.
UNSAFE_EXEMPT=(
  rust/slopdesk-posix/Cargo.toml
  rust/slopdesk-ffi/Cargo.toml
  rust/slopdesk-gfsimd/Cargo.toml
)
APPLE_FAMILY=()
for manifest in rust/slopdesk-apple-*/Cargo.toml; do
  [[ -f "${manifest}" ]] || continue
  APPLE_FAMILY+=("${manifest}")
  UNSAFE_EXEMPT+=("${manifest}")
done
# What the family costs, per crate. `deny` alone is the same level the three hand-written crates
# carry; these three add what `docs/57` §3 asks and what makes the permission narrower rather than
# wider.
for manifest in "${APPLE_FAMILY[@]}"; do
  crate_dir=$(dirname "${manifest}")
  if ! grep -q '^unsafe_op_in_unsafe_fn = "deny"' "${manifest}"; then
    fail "${manifest} is in the objc2 family and does not state unsafe_op_in_unsafe_fn = \"deny\" — the family's permission is 'call an unsafe binding', which means every such call must be inside a block that named its obligation (docs/57 §3)"
  fi
  if ! grep -q 'objc2' "${manifest}"; then
    fail "${manifest} is named slopdesk-apple-* and depends on no objc2 crate — the family exists BECAUSE the bindings are generated from SDK metadata; a hand-rolled extern block wearing this name has the permission without the reason for it (docs/57 §1)"
  fi
  # The line that separates this family from the three hand-written crates. A raw-pointer operation
  # here is not a framework obligation — it is a Rust one, and `docs/57` §2 says it belongs in
  # `slopdesk-posix` or `slopdesk-ffi`, where a reviewer already holds that question.
  #
  # CODE only, for N.18's reason. A crate in this family has to EXPLAIN, in prose, which Rust
  # obligations it is not carrying — that sentence is the argument for its own existence — and a
  # gate that could not tell `transmute` in a doc comment from a call to one would force the
  # argument out of the crate to keep the crate green.
  family_code=$(grep -rhvE '^[[:space:]]*(///|//!|//)' --include='*.rs' "${crate_dir}/src" || true)
  if grep -Eq 'transmute|from_raw|slice::from_raw_parts|ptr::(read|write|copy)' <<< "${family_code}"; then
    fail "${crate_dir} hand-writes a raw-pointer operation — the objc2 family may write unsafe only to CALL an unsafe binding; a transmute or a from_raw is a Rust obligation and belongs in slopdesk-posix or slopdesk-ffi (docs/57 §2)"
  fi
done
# The exemption is not a blank cheque, and this is the half the gate was missing: each of the three
# must state `deny`, the level the comment above argues for, and nothing else. `allow` there would
# pass the loop below untouched — an exempt manifest is `continue`d before the allow/warn check ever
# runs — and it would take every per-site `#[expect]` with it, since a lint nobody fires cannot
# expire. A missing file is the same failure wearing a different hat: an entry naming a crate that
# has been renamed or folded away protects nothing, and reads for years like it does.
for allowed in "${UNSAFE_EXEMPT[@]}"; do
  if [[ ! -f "${allowed}" ]]; then
    fail "${allowed} is exempt from the unsafe-code policy and does not exist — the exemption list has gone stale (docs/55 §5)"
    continue
  fi
  if ! grep -q '^unsafe_code = "deny"' "${allowed}"; then
    fail "${allowed} is allowed to write unsafe and does not state unsafe_code = \"deny\" — the per-site #[expect] audit depends on that exact level (docs/51 §6.15, docs/55 §5)"
  fi
done
# `workspace = true` is only an answer for a crate that INHERITS from the root, and only because the
# root is checked here too and must state `forbid` itself. Almost every crate under `rust/` is its
# OWN `[workspace]` root, and for one of those the same two lines say nothing at all: a manifest can
# carry `[workspace.lints.rust] unsafe_code = "allow"` and `[lints] workspace = true` together and
# inherit permission. So inheritance is accepted only from the root, and the member list is read out
# of the root rather than kept beside it.
root_members=$(grep -E '^members = ' rust/Cargo.toml | grep -oE '"[a-z0-9-]+"' | tr -d '"' || true)
if [[ -z "${root_members}" ]]; then
  fail "the root workspace's members list did not parse — the unsafe-policy gate below would accept any 'workspace = true' (docs/55 §5)"
fi
unsafe_policy_missing=""
for manifest in rust/Cargo.toml rust/*/Cargo.toml; do
  exempt=""
  for allowed in "${UNSAFE_EXEMPT[@]}"; do
    [[ "${manifest}" == "${allowed}" ]] && exempt="yes"
  done
  if [[ -n "${exempt}" ]]; then
    continue
  fi
  # A stated `allow`/`warn` anywhere in the manifest is decisive, whatever else it also says: the
  # narrower `[lints.rust]` table wins over `[workspace.lints.rust]`, so a `forbid` above one of
  # these is not protection, it is camouflage.
  if grep -qE '^unsafe_code = "(allow|warn)"' "${manifest}"; then
    unsafe_policy_missing="${unsafe_policy_missing}${manifest} (states allow/warn)"$'\n'
    continue
  fi
  if grep -q '^unsafe_code = "forbid"' "${manifest}"; then
    continue
  fi
  crate=$(basename "$(dirname "${manifest}")")
  if grep -q '^workspace = true' "${manifest}" && grep -qxF "${crate}" <<< "${root_members}"; then
    continue
  fi
  unsafe_policy_missing="${unsafe_policy_missing}${manifest}"$'\n'
done
if [[ -n "${unsafe_policy_missing}" ]]; then
  printf '%s' "${unsafe_policy_missing}" >&2
  fail "a crate is not unsafe_code = \"forbid\" — the exempt crates are named above (three hand-written, plus the slopdesk-apple-* objc2 family), and a fourth hand-written one is a design change (docs/51 §6.15, docs/55 §5, docs/57)"
fi

# ── The two lints that would talk you out of bit-exact floats ────────────────────────────────────
# `CLAUDE.md` forbids the fused multiply-add: `a * b + c` stays two roundings because that is what
# `golden/golden_vectors.json` pins. Clippy's `suboptimal_flops` and `imprecise_flops` argue the
# opposite, both live in `nursery`, and every workspace here denies the whole nursery group — so in
# any crate that does not opt out, the FIRST float expression to land is a hard clippy error whose
# only offered fix is `f64::mul_add`. That is a lint teaching the opposite of an invariant, and it
# teaches it at the moment nobody is reading a manifest.
#
# Four crates carried the opt-out because four crates had float math. The other thirteen were one
# expression away from the trap; they all carry it now, and this keeps the seventeenth honest.
flops_unguarded=""
for manifest in rust/Cargo.toml rust/*/Cargo.toml; do
  grep -q '^\[workspace\]' "${manifest}" || [[ "${manifest}" == rust/Cargo.toml ]] || continue
  for lint in suboptimal_flops imprecise_flops; do
    grep -q "^${lint} = \"allow\"" "${manifest}" ||
      flops_unguarded="${flops_unguarded}${manifest} (${lint})"$'\n'
  done
done
if [[ -n "${flops_unguarded}" ]]; then
  printf '%s' "${flops_unguarded}" >&2
  fail "a Rust workspace does not allow the FMA-suggesting nursery lints — clippy would demand mul_add and break the bit-exact floats CLAUDE.md pins"
fi

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

# And the window itself must not come back to superd. The fork-to-exec contract is pinned by
# disassembly (`slopdesk-posix/src/fork_window_contract.rs`), and a pin can only guard a symbol it
# is compiled beside — a second `fork` anywhere else is unguarded by construction, not merely
# unreviewed.
stray_fork=$(grep -rl --exclude-dir=target 'libc::fork\|libc::openpty' rust --include='*.rs' | grep -v '^rust/slopdesk-posix/' || true)
if [[ -n "${stray_fork}" ]]; then
  printf '%s\n' "${stray_fork}" >&2
  fail "a fork/openpty is outside rust/slopdesk-posix — the disassembly pin cannot guard it (docs/51 §6.15)"
fi

# Nor may a C entry point appear anywhere but the shim. `#[unsafe(no_mangle)] extern "C"` in a
# domain crate would put argument marshalling next to the logic it marshals, which is how a
# pointer bug becomes a terminal bug — and it would force that crate off `forbid`.
stray_abi=$(grep -rl --exclude-dir=target 'extern "C"' rust --include='*.rs' | grep -v '^rust/slopdesk-ffi/' || true)
if [[ -n "${stray_abi}" ]]; then
  printf '%s\n' "${stray_abi}" >&2
  fail "a C entry point is outside rust/slopdesk-ffi — the ABI is a crate, not an attribute (docs/55)"
fi

# The replay buffer is `slopdesk_wire::replay` and the Swift side is a handle owner. These two
# strings are what a re-implementation would need and a wrapper cannot have: the ring storage, and
# the per-entry eviction walk. Checked as CONTENT rather than as a deleted path, because unlike the
# ported daemons this file legitimately still exists.
replay_swift="Sources/SlopDeskTransport/ReplayBuffer.swift"
if [[ "$(grep -c 'import CSlopDeskFFI' "${replay_swift}")" -eq 0 ]]; then
  fail "${replay_swift} no longer calls the Rust buffer — the port was undone (docs/55 §6)"
fi
for ghost in 'private var scrollbackRing' 'func evictScrollbackToFit'; do
  if [[ "$(grep -c "${ghost}" "${replay_swift}")" -ne 0 ]]; then
    fail "${replay_swift} grew '${ghost}' back — the buffer lives in rust/slopdesk-wire (docs/55 §6)"
  fi
done

# Agent detection is `rust/slopdesk-agent` and the Swift module is vocabulary plus marshalling.
# Same CONTENT check as the replay buffer above, for the same reason — these files still exist.
printf 'check-supervisor: the agent-detection RULES are Rust, not Swift\n'
for detect in AgentKind ClaudeStatus AgentDetectionHold AgentJobIdentifier; do
  detect_swift="Sources/SlopDeskAgentDetect/${detect}.swift"
  if [[ "$(grep -c 'import CSlopDeskFFI' "${detect_swift}")" -eq 0 ]]; then
    fail "${detect_swift} no longer calls the Rust crate — the port was undone (docs/55 §6)"
  fi
done
# The four that used to be on that list are not marshallers any more — they are GONE. Once the
# fusion moved (`rust/slopdesk-agent::detector`, below), nothing in `Sources/` had a reason to name
# a machine, a signal, a process matcher or an input classifier: the detector's own doors take the
# raw input and answer the fold. A wrapper that only forwards is still a file another wrapper can
# be written next to, so the check for these is that they stay deleted rather than stay thin.
detect_wrappers_revived=$(among_deleted '(enum|struct|final class|class|actor) (ClaudeStatusMachine|ClaudeProcessMatcher|PaneInputClassifier)\b|enum ClaudeSignal\b')
if [[ -n "${detect_wrappers_revived}" ]]; then
  printf '%s\n' "${detect_wrappers_revived}" >&2
  fail "a Swift machine/signal wrapper is back in Sources/ — the detector's doors take the raw input (docs/50)"
fi
# The tables and the walks a re-implementation would need, and a wrapper cannot have.
for ghost in 'case "claude-code"' 'wrapperBasenames' 'cancelOnly' 'pendingIdleStartedAt' \
  'private var blockLedger' 'func wrappedAgentName'; do
  if [[ "$(grep -rc "${ghost}" Sources/SlopDeskAgentDetect | grep -cv ':0$')" -ne 0 ]]; then
    fail "Sources/SlopDeskAgentDetect grew '${ghost}' back — the rules live in rust/slopdesk-agent (docs/55 §6)"
  fi
done

# The vocabularies are a cross-language CONTRACT: the Swift enums declare the cases, and the crate
# answers every question about them by DISCRIMINANT. A reordered Swift enum would quietly report
# `working` for `blocked`, so the two case lists are compared here rather than trusted.
printf 'check-supervisor: the agent vocabularies agree across the two languages\n'
swift_kinds=$(sed -n '/^public enum AgentKind/,/^}/p' Sources/SlopDeskAgentDetect/AgentKind.swift |
  grep -cE '^    case ') || true
rust_kinds=$(grep -oE 'pub const ALL: \[Self; [0-9]+\]' rust/slopdesk-agent/src/kind.rs |
  grep -oE '[0-9]+') || true
if [[ "${swift_kinds}" != "${rust_kinds}" ]]; then
  fail "AgentKind has ${swift_kinds} Swift cases and ${rust_kinds} Rust ones — the index that crosses the ABI is now wrong (docs/55)"
fi
swift_statuses=$(sed -n '/^public enum ClaudeStatus/,/^}/p' Sources/SlopDeskAgentDetect/ClaudeStatus.swift |
  grep -cE '^    case ') || true
rust_statuses=$(grep -oE 'pub const ALL: \[Self; [0-9]+\]' rust/slopdesk-agent/src/status.rs |
  grep -oE '[0-9]+') || true
if [[ "${swift_statuses}" != "${rust_statuses}" ]]; then
  fail "ClaudeStatus has ${swift_statuses} Swift cases and ${rust_statuses} Rust ones (docs/55)"
fi

# The workspace SOLVERS are `rust/slopdesk-workspace` and the Swift files are marshalling. The
# document's value types stay Swift on purpose (262 files import them), so this is a per-file check
# rather than a per-module one — the line is inside the module, not around it.
printf 'check-supervisor: the workspace SOLVERS are Rust, not Swift\n'
# The document's FIELD VOCABULARY, pinned across the two languages.
#
# `rust/slopdesk-wire/src/document/fields.rs` says it itself: nothing in the codec maps through these
# constants, every value is length-prefixed, and an unknown byte is kept verbatim. So a field number
# invented independently on the two ends decodes perfectly cleanly into the WRONG MEANING, and there
# is no decoder anywhere that would notice. The host writes them and the client reads them; this is
# the only thing standing between those two facts.
#
# Names are compared case- and underscore-insensitively, because the two languages spell the same
# field `focusMRU` and `FOCUS_MRU` and neither spelling is wrong.
fields_swift="Sources/SlopDeskWorkspaceModel/State/WorkspaceFields.swift"
fields_rust="rust/slopdesk-wire/src/document/fields.rs"
swift_fields=$(awk '
  /^public enum Workspace[A-Za-z]+Field \{/ {
    table = $3
    sub(/^Workspace/, "", table)
    sub(/Field$/, "", table)
    next
  }
  /^\}/ { table = "" }
  table != "" && /static let [A-Za-z]+: UInt8 = [0-9]+/ {
    match($0, /static let [A-Za-z]+/)
    name = substr($0, RSTART + 11, RLENGTH - 11)
    match($0, /= [0-9]+/)
    value = substr($0, RSTART + 2, RLENGTH - 2)
    print toupper(table) "." toupper(name) "=" value
  }
' "${fields_swift}" | sort)
rust_fields=$(awk '
  /^pub mod [a-z_]+ \{/ {
    table = $3
    sub(/_/, "", table)
    next
  }
  /^\}/ { table = "" }
  table != "" && /pub const [A-Z_0-9]+: u8 = [0-9]+;/ {
    match($0, /pub const [A-Z_0-9]+/)
    name = substr($0, RSTART + 10, RLENGTH - 10)
    gsub(/_/, "", name)
    match($0, /= [0-9]+/)
    value = substr($0, RSTART + 2, RLENGTH - 2)
    print toupper(table) "." name "=" value
  }
' "${fields_rust}" | sort)
field_count=$(printf '%s\n' "${swift_fields}" | grep -c .) || true
if [[ "${field_count}" -lt 40 ]]; then
  fail "only ${field_count} document fields found in ${fields_swift} — the extraction in this gate has gone stale"
fi
if ! diff <(printf '%s\n' "${swift_fields}") <(printf '%s\n' "${rust_fields}") > /dev/null; then
  printf '%s\n' "$(diff <(printf '%s\n' "${swift_fields}") <(printf '%s\n' "${rust_fields}"))" >&2
  fail "${fields_swift} and ${fields_rust} disagree — a mis-numbered field decodes cleanly into the wrong meaning (docs/45 §5.3)"
fi
printf 'check-supervisor: the document field vocabulary agrees — %s fields, both languages.\n' "${field_count}"

# The field NUMBERS are compared above because both languages have to declare them — a `switch` on a
# Swift enum needs Swift cases. The topology's two ring caps and its reserved-root set are a
# different thing: they are NUMBERS, nothing switches on them, and the host is what applies them.
# So they are ASKED, not compared — `slopdesk_ws_topology_ring_cap` and
# `slopdesk_ws_reserved_root_fields`. What this gate stops is the transcription coming back, which
# would not disagree loudly: a client with the larger cap renders a ring whose tail the host already
# reaped, one with the smaller hides tabs ⇧⌘T would still reopen, and a reserved set one number off
# DELETES the field it was meant to leave alone. None of those log anything.
#
# `spells` is not defined this early in the file, so these are plain greps — the neighbouring gates
# in this section are too.
SWIFT_TOPOLOGY=Sources/SlopDeskWorkspaceModel/State/WorkspaceTopology.swift
for asked in 'slopdesk_ws_topology_ring_cap\(0\)' 'slopdesk_ws_topology_ring_cap\(1\)' \
  'slopdesk_ws_reserved_root_fields\('; do
  if [[ "$(grep -cE "${asked}" "${SWIFT_TOPOLOGY}")" -eq 0 ]]; then
    fail "${SWIFT_TOPOLOGY} stopped asking ${asked//\\/} — a reaping threshold spelled twice reaps two different rings (docs/45 §5.3)"
  fi
done
if [[ "$(grep -cE 'closedTabRingCap *= *[0-9]|focusMRUCap *= *[0-9]' "${SWIFT_TOPOLOGY}")" -ne 0 ]]; then
  fail "${SWIFT_TOPOLOGY} transcribed a ring cap back — ask slopdesk_ws_topology_ring_cap (docs/45 §5.3)"
fi
# The same reaping, one level up: WHICH keys the write reaps, rather than how many it keeps. The
# predicate and the two pane-field halves are the line itself, and two answers to it do not conflict
# — the wider one deletes a cell the host persisted, the narrower one strands a cell nothing will
# ever clear. Neither says anything at the time.
SWIFT_LIVENESS=Sources/SlopDeskWorkspaceModel/State/PaneLiveness.swift
if [[ "$(grep -cE 'slopdesk_ws_key_is_topology\(' "${SWIFT_TOPOLOGY}")" -eq 0 ]]; then
  fail "${SWIFT_TOPOLOGY} decides isTopology itself — ask slopdesk_ws_key_is_topology (docs/45 §5.3)"
fi
for half in 0 1; do
  if [[ "$(grep -cE "slopdesk_ws_pane_fields\(${half}|slopdesk_ws_pane_fields\(half" "${SWIFT_LIVENESS}")" -eq 0 ]]; then
    fail "${SWIFT_LIVENESS} stopped asking slopdesk_ws_pane_fields — a pane field on the wrong side of the reaping line deletes a persisted title (docs/45 §5.3)"
  fi
done
# A field alone on its line is an ARRAY LITERAL element only when what OPENED it was a bracket, or
# when the line above it was another such element. A wrapped call argument — which is how the
# encoder legitimately names one field at a time — sits under a line that opened a paren instead.
if [[ "$(awk '
  /^ *WorkspacePaneField\.[A-Za-z]+,$/ && (prev ~ /\[$/ || prev ~ /^ *WorkspacePaneField\.[A-Za-z]+,$/) { n++ }
  { prev = $0 }
  END { print n + 0 }
' "${SWIFT_LIVENESS}")" -ne 0 ]]; then
  fail "${SWIFT_LIVENESS} transcribed a pane-field half back — ask slopdesk_ws_pane_fields (docs/45 §5.3)"
fi
printf 'check-supervisor: the topology reaps by one set of numbers and one line, and the client asks for both.\n'

# The INTENT verbs and the object KIND tags, pinned the same way and for the same reason. An op byte
# is the whole of what one end asks the other to do; two ends numbering them differently is a client
# asking for a rename and a host performing a close.
intent_swift="Sources/SlopDeskWorkspaceModel/State/WorkspaceIntent.swift"
intent_rust="rust/slopdesk-wire/src/document/intent.rs"
swift_ops=$(grep -oE 'case [a-zA-Z]+ = [0-9]+' "${intent_swift}" |
  awk '{ gsub(/case /, ""); print toupper($1) "=" $3 }' | sort -u) || true
rust_ops=$(grep -oE '^\s+[A-Z][A-Za-z]+ = [0-9]+,' "${intent_rust}" |
  awk '{ gsub(/,$/, "", $3); print toupper($1) "=" $3 }' | sort -u) || true
op_count=$(printf '%s\n' "${swift_ops}" | grep -c .) || true
if [[ "${op_count}" -lt 25 ]]; then
  fail "only ${op_count} intent verbs found in ${intent_swift} — the extraction in this gate has gone stale"
fi
if ! diff <(printf '%s\n' "${swift_ops}") <(printf '%s\n' "${rust_ops}") > /dev/null; then
  printf '%s\n' "$(diff <(printf '%s\n' "${swift_ops}") <(printf '%s\n' "${rust_ops}"))" >&2
  fail "${intent_swift} and ${intent_rust} disagree — an op byte is the whole of the request (docs/45 §5.3)"
fi
printf 'check-supervisor: the intent verbs agree too — %s ops, both languages.\n' "${op_count}"

# AND THE GATE ABOVE IS EXACTLY WHY THESE TWO EXIST. It pins this file pair — the right pair — and it
# compares an op-byte MAP: a name and a number. The blob-length bug lived six lines from where it
# looks, for as long as this gate has existed, because a vocabulary pin cannot see BEHAVIOUR. Every
# cross-language defect this project has found is behavioural (docs/55 §8). These two are the cheap
# half of the answer; the real one is a differential test, and it is owed.
#
# 1. A `u16` in front of a blob must name the bytes that follow it. Both call sites once declared a
#    WRAPPED length and then appended every byte, so a payload past 64 KiB produced a frame that
#    mis-splits at the decoder — `intent::put_blob` clamps and cuts, and its doc comment named the
#    Swift bug rather than fixing it. `appendBlob` is the one spelling now; a bare append of the
#    blob means a second copy has come back.
if grep -nE '^[[:space:]]*out\.append\(blob\)' "${intent_swift}" >&2; then
  fail "${intent_swift} appends a blob without cutting it to the declared length — use appendBlob (docs/55 §8)"
fi
# 2. `decodeIfPresent` on a key that is PRESENT with a value its type refuses does NOT answer `nil` —
#    it THROWS, so the `??` default written beside it never runs. On a persisted split that cost the
#    user their WHOLE arrangement to one typo in a hand-editable file: the throw unwound the entire
#    `TreeWorkspace` decode and `WorkspacePersistence.load()` wrote a `.corrupt` sidecar. Rust
#    repaired and Swift bricked. `(try? decode(…)) ?? default` is the idiom that means "fill".
#
#    THE SITE THAT TAUGHT IT THIS IS GONE. The workspace file has one decoder now and it is
#    `slopdesk-workspace`'s `persist`, reached through `Codec/WorkspaceFile.swift` — the ban below
#    stays because the defect was never about that file. It is about a Swift `Decodable` reading a
#    hand-editable document, and four of those are still ours: the device-local settings sidecars
#    allowlisted in the awk. The gate that stays after the code it caught is the cheap half of not
#    learning this twice.
#
#    WHAT IS BANNED IS THE PAIRING, not the call. `decodeIfPresent` is correct where absence and
#    unreadability are BOTH faults — a discriminator key is the standing example, and
#    `persist::decode_raw_node` faults on an unreadable one too (`decode_id(value, "leaf")?`), so a
#    call shaped like that agrees with Rust and must stay. What cannot be right is
#    `decodeIfPresent(…) ?? x`: the `??` says "fill on absence", the throw fires first on a bad
#    value, and the default the author wrote is unreachable on the one path it was written for. The
#    first draft of this gate banned the call outright and went red on that correct discriminator
#    immediately — which is the ban list's standing hazard, and the reason it is worth writing the
#    narrow form.
#
#    The lookahead is one line: swiftformat wraps a long `decodeIfPresent` before its `??`, so a
#    same-line-only match would miss the wrapped form, which is the form a long generic type takes.
#    Comment lines are dropped first, and that is not cosmetic — `TerminalPreferences.swift` explains
#    this trap in prose directly above the calls it governs, so a gate that read comments would fire
#    on the very comment describing why it fires.
#
#    THE CONTAINER FORM IS THE SAME TRAP and was ungated until the `Session` fix. `"specs": 5` or
#    `"detached": {}` is a key present with a value a `[…]` element type refuses, so
#    `decodeIfPresent([…].self, …) ?? []` threw past its own `?? []` and cost the user every session
#    in the file — identically to the axis. `[`, `Set<` and `Dictionary<` are all matched because the
#    shape of the container is not what makes it wrong; the pairing is.
#
#    The fill for a container is NOT free the way an axis is, and the ban does not claim otherwise.
#    It bans the pairing and leaves the answer to the site: the shape both fixed sites landed on —
#    and the shape `persist::decode_session` carries forward — is a TOLERANT container around STRICT
#    elements, so an unreadable list VALUE (which named nothing) reads as empty while a malformed
#    ELEMENT stays a fault rather than a pane that silently disappears out of a load reporting
#    success.
# shellcheck disable=SC2046 # `$(git ls-files …)` expands to a FILE LIST for awk on purpose
raw_optional_fills=$(awk '
  # ALLOWLISTED, not exempt — each of these is the same defect, and each is named so the gate can go
  # green without being narrowed into blindness. All four are in device-local SETTINGS sidecars
  # (`device-prefs.json`, the keybinding file), where the throw resets that file to defaults instead
  # of taking the workspace with it, and all four are outside the ownership of the change that added
  # this arm. Rust has no counterpart to any of them. Deleting an entry here is the fix; editing the
  # line re-arms the gate on it, which is the point of keying on the CodingKey rather than the file.
  BEGIN {
    allowed["Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift\t.rawOverrides"] = 1
    allowed["Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift\t.overrides"] = 1
    allowed["Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift\t.textBindings"] = 1
    allowed["Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift\t.unbinds"] = 1
  }
  # A wrapped call whose `forKey:` landed on the OTHER line yields no key and is reported: an
  # allowlist that silently swallowed what it could not identify would be the vacuous-gate defect.
  function offence(file, no, code,   key) {
    key = ""
    if (match(code, /forKey: \.[A-Za-z0-9_]+/)) key = substr(code, RSTART + 8, RLENGTH - 8)
    if ((file "\t" key) in allowed) return
    print file ":" no ":" code
  }
  FNR == 1 { prev = ""; prevno = 0 }
  {
    line = $0
    sub(/[[:space:]]*\/\/.*$/, "", line)
    if (prev != "" && (prev " " line) ~ /\?\?/) { offence(FILENAME, prevno, prev); prev = "" }
    else if (prev != "") prev = ""
    if (line ~ /decodeIfPresent\((SplitAxis|SplitNodeID|PaneID|PaneKind)\.self/ \
        || line ~ /decodeIfPresent\((\[|Set<|Dictionary<)/) {
      if (line ~ /\?\?/) { offence(FILENAME, FNR, line); prev = "" }
      else { prev = line; prevno = FNR }
    }
  }
' $(git ls-files --cached --others --exclude-standard 'Sources/**/*.swift') || true)
# `git ls-files` spelled out rather than `repo_files`, which is not DEFINED until further down this
# script — the first draft called it here, bash resolved nothing, `2> /dev/null` swallowed the
# "command not found", `|| true` turned the corpse into a pass, and the gate was vacuous while
# printing nothing. It is the same defect this script has a gate against ("no gate that dies
# quietly"), committed inside a new gate, and it survived a clean-tree run looking exactly like a
# pass. Hence the guard below: a gate whose haystack is empty is not a gate.
if [[ "$(git ls-files --cached --others --exclude-standard 'Sources/**/*.swift' | grep -c .)" -lt 400 ]]; then
  fail "the decodeIfPresent gate found almost no Swift under Sources/ — its file list has gone stale, so it is checking nothing"
fi
if [[ -n "${raw_optional_fills}" ]]; then
  printf '%s\n' "${raw_optional_fills}" >&2
  fail "a raw-value enum, id or container filled with decodeIfPresent(…) ?? x — the throw beats the default, use (try? decode(…)) ?? x, or a tolerant-container/strict-element read like Session.decodeArray (docs/55 §8)"
fi

codec_swift="Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateCodec.swift"
codec_code=$(grep -v '^[[:space:]]*//' "${codec_swift}") || true
# EMPTY is not "clean". Every check below is a `grep -qF` for a banned symbol, so a haystack that
# read as nothing would pass all of them at once — a ban list is the one shape where losing the
# input looks exactly like compliance. The `|| true` above is what lets this speak: under
# `set -euo pipefail` a `grep` that matches nothing exits 1 and would kill the script HERE.
if [[ -z "${codec_code}" ]]; then
  fail "${codec_swift} read as EMPTY — it moved or is all comments, so the ban list below stopped checking anything (docs/55 §6)"
fi
for ghost in 'func decodeEntry' 'func decodeEntries' 'maxEntryCount = ' 'reserveCapacity(Int(count))' \
  'func decodeLayoutNode' 'func readWeight' 'func appendWeight' 'depth: Int' 'SplitNode.maxDepth' \
  'struct ByteReader' 'func appendBE' 'append(uuid:'; do
  if grep -qF "${ghost}" <<< "${codec_code}"; then
    fail "${codec_swift} grew '${ghost}' back — the count-and-length parse lives in rust/slopdesk-workspace (docs/55 §6)"
  fi
done
if [[ "$(grep -c 'import CSlopDeskFFI' "${codec_swift}")" -eq 0 ]]; then
  fail "${codec_swift} no longer calls the Rust crate — the scalar codec was undone (docs/55 §6)"
fi
# The wrong-width DROP is the codec's safety property. A decoder that stopped asking the crate would
# be a lenient prefix read nobody notices until a mis-numbered field renders as a plausible value.
# `decode_bool` and `encode_i32` join the list for a different reason from the rest: they are not
# decodes the compiler could miss, they are COMPOSITIONS the near side was making for itself —
# `decodeU8(data).map { $0 != 0 }` and `encodeU32(UInt32(bitPattern: value))` — beside two crate
# functions that sat without a caller for a month waiting for exactly them.
for decoder in slopdesk_ws_decode_u8 slopdesk_ws_decode_u32 slopdesk_ws_decode_i64 \
  slopdesk_ws_decode_bool slopdesk_ws_encode_i32 \
  slopdesk_ws_decode_uuid_list slopdesk_ws_decode_snapshot slopdesk_ws_decode_diff \
  slopdesk_ws_decode_layout slopdesk_ws_decode_weights slopdesk_ws_decode_uuid \
  slopdesk_ws_decode_detached_panes slopdesk_ws_decode_video_target; do
  if ! grep -qF "${decoder}" "${codec_swift}"; then
    fail "${codec_swift} stopped calling ${decoder} — the strict-width drop lives in Rust (docs/55 §6)"
  fi
done

# The layout decoder's two refusals are different reports, and the flag is the only thing carrying
# that difference across the boundary. A decoder that stopped reading it would still pass every
# round-trip test while telling a person "corrupt" about a document that is merely too deep.
if ! grep -qF 'depthExceeded' "${codec_swift}"; then
  fail "${codec_swift} stopped distinguishing a too-deep tree from a malformed one (docs/55 §6)"
fi

# ── One answer to "may this cell touch the disk" ────────────────────────────────────────────────
# `WorkspaceStateFile` was 129 lines of Swift that were a near-verbatim second copy of
# `rust/slopdesk-wire`'s `document::state_file`: the same version constant, the same persisted-field
# set, the same base64 rows, the same refusals. Two answers to that question do not CONFLICT, they
# render — the wider one brings a pane back as `liveness: attached` with no process behind it, busy
# dots spinning for a child that exited weeks ago, and the narrower one silently loses the
# arrangement the person made. Neither logs anything, which is why a compiler could never find it
# and this gate has to.
#
# The file moved to `Codec/` when it became a marshaller, and the old path staying gone is half the
# check: a re-implementation grows back where the original was, not beside its replacement.
WS_FILE_SWIFT=Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateFile.swift
if [[ -e Sources/SlopDeskWorkspaceModel/State/WorkspaceStateFile.swift ]]; then
  fail "Sources/SlopDeskWorkspaceModel/State/WorkspaceStateFile.swift is back — the rule is rust/slopdesk-wire's document::state_file (docs/55 §6)"
fi
if [[ ! -e "${WS_FILE_SWIFT}" ]]; then
  fail "${WS_FILE_SWIFT} is gone — the state file's door has no Swift face, so the bans below stopped checking anything (docs/55 §6)"
fi
state_file_revived=$(among_deleted 'static let persistedPaneFields\b|(struct|private struct) Row: Codable\b')
if [[ -n "${state_file_revived}" ]]; then
  printf '%s\n' "${state_file_revived}" >&2
  fail "a Swift state-file policy is back in Sources/ — the persisted set and the row shape live in rust/slopdesk-wire (docs/55 §6)"
fi
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

# The FRECENCY ranking and the JUMP it resolves — `rust/slopdesk-workspace`'s `frecency` and `jump`.
# One scorer rather than three sorts, because the folder rail, the open-quickly overlay, the store's
# own cap and `slopdesk jump` all order the same set and a second ordering would rank them apart.
SWIFT_FRECENCY=Sources/SlopDeskWorkspaceCore/Folders/FolderFrecency.swift
SWIFT_JUMP=Sources/SlopDeskWorkspaceCore/Folders/JumpResolver.swift
for pair in \
  "${SWIFT_FRECENCY}:slopdesk_folder_weight" \
  "${SWIFT_FRECENCY}:slopdesk_folder_recency_weight" \
  "${SWIFT_FRECENCY}:slopdesk_folder_score" \
  "${SWIFT_FRECENCY}:slopdesk_folder_ranked" \
  "${SWIFT_JUMP}:slopdesk_jump_resolve"; do
  if ! grep -q "${pair#*:}(" "${pair%%:*}"; then
    fail "${pair%%:*} no longer calls ${pair#*:} — the folder ordering is rust/slopdesk-workspace's"
  fi
done
# The bucket thresholds, the weights and the tie-break a re-implementation would grow back, plus the
# toggle branch: `--no-cd` must resolve WITHOUT advancing the source, and a second copy of that rule
# is a preview that perturbs the toggle it was supposed to leave alone.
if hit=$(spells '3600|86400|604_800|2_592_000|= 16$|sorted \{|lowercased\(\)\.contains' "${SWIFT_FRECENCY}" "${SWIFT_JUMP}"); then
  fail "${hit} spells a frecency threshold, weight, sort or jump match again — those live in frecency.rs and jump.rs"
fi
printf 'check-supervisor: the folders rank once, and a jump reads that rank.\n'

# What `slopdesk watch` DECIDES and what it PRINTS — `rust/slopdesk-agent`'s `watch` and
# `rust/slopdesk-wire`'s `osc`. The bytes are pinned to the crate the host's sniffer parses WITH, so
# the wrapper cannot emit a sequence the host would drop; the exit codes are pinned because a
# second at-rest set would make `watch:claude` return on a state the app calls busy.
SWIFT_WATCH=Sources/SlopDeskCLICore/WatchClaudeOutcome.swift
SWIFT_WATCH_BYTES=Sources/SlopDeskCLICore/WatchProgress.swift
SWIFT_WATCH_MARKER=Sources/SlopDeskProtocol/WatchNotificationMarker.swift
for pair in \
  "${SWIFT_WATCH}:slopdesk_watch_observation" \
  "${SWIFT_WATCH}:slopdesk_watch_is_at_rest" \
  "${SWIFT_WATCH}:slopdesk_watch_block_deadline_nanos" \
  "${SWIFT_WATCH}:slopdesk_watch_decide" \
  "${SWIFT_WATCH_BYTES}:slopdesk_watch_spinner_bytes" \
  "${SWIFT_WATCH_BYTES}:slopdesk_watch_finish_bytes" \
  "${SWIFT_WATCH_BYTES}:slopdesk_watch_progress_bytes" \
  "${SWIFT_WATCH_BYTES}:slopdesk_watch_exit_progress_state" \
  "${SWIFT_WATCH_BYTES}:slopdesk_watch_finish_message" \
  "${SWIFT_WATCH_BYTES}:slopdesk_osc_notification_bytes" \
  "${SWIFT_WATCH_BYTES}:slopdesk_watch_finish_notification_bytes" \
  "${SWIFT_WATCH_MARKER}:slopdesk_watch_notification_marker"; do
  if ! grep -q "${pair#*:}(" "${pair%%:*}"; then
    fail "${pair%%:*} no longer calls ${pair#*:} — the watch vocabulary is slopdesk-agent's and slopdesk-wire's"
  fi
done
if hit=$(spells 'case \.idle,|0x1B|0x07|"9;4;|777;notify|watch: ' "${SWIFT_WATCH}" "${SWIFT_WATCH_BYTES}" "${SWIFT_WATCH_MARKER}"); then
  fail "${hit} spells a watch at-rest set or escape sequence again — those live in watch.rs and osc.rs"
fi
if spells 'slopdesk:watch-finish' "${SWIFT_WATCH_MARKER}" > /dev/null; then
  fail "${SWIFT_WATCH_MARKER} spells the sentinel again — it is osc.rs's WATCH_NOTIFICATION_MARKER"
fi
printf 'check-supervisor: what watch decides and what it prints come from the crates that parse them back.\n'

# The cursor OVERLAY placement, the progress GRAMMAR and the windowList ARRANGEMENT — three small
# rules that were each written twice. Small is exactly why: a rule that is two multiplies, a parser
# that is one split and a filter that is one line are what get re-typed at the call site instead of
# called, and each of the three has a failure the type checker cannot see. The overlay must land on
# the pixel the input encoder targets — a contracted multiply-add on one side moves the cursor away
# from where the click goes. The parser and the byte builders are one grammar, so a second copy is
# how a spinner survives the command that raised it. And an arrangement that drops the wrong side
# closes a pane on a window the host was mid-rescue on.
SWIFT_OVERLAY=Sources/SlopDeskVideoClient/ClientCursorCompositor.swift
SWIFT_PROGRESS=Sources/SlopDeskProtocol/ProgressState.swift
SWIFT_ARRANGE=Sources/SlopDeskVideoHost/StreamableWindowListOrder.swift
for pair in \
  "${SWIFT_OVERLAY}:slopdesk_cursor_layer_frame_scalar" \
  "${SWIFT_OVERLAY}:slopdesk_cursor_layer_frame_fit" \
  "${SWIFT_OVERLAY}:slopdesk_cursor_bottom_left_origin_y" \
  "${SWIFT_OVERLAY}:slopdesk_cursor_is_placeable" \
  "${SWIFT_OVERLAY}:slopdesk_cursor_rendered_shape_size" \
  "${SWIFT_PROGRESS}:slopdesk_osc_parse_progress" \
  "${SWIFT_ARRANGE}:slopdesk_arrange_streamable_windows"; do
  if ! grep -q "${pair#*:}(" "${pair%%:*}"; then
    fail "${pair%%:*} no longer calls ${pair#*:} — that rule is rust/slopdesk-video's or rust/slopdesk-wire's"
  fi
done
if hit=$(spells 'AspectFit\.|parentHeight - topLeftY|isFinite,|split\(separator: ";"|windows\.filter' \
  "${SWIFT_OVERLAY}" "${SWIFT_PROGRESS}" "${SWIFT_ARRANGE}"); then
  fail "${hit} re-derives the overlay placement, the progress grammar or the arrangement — those live in cursor_overlay.rs, osc.rs and capture_recovery.rs"
fi
printf 'check-supervisor: the cursor lands where the click does, and the progress grammar is one grammar.\n'

# ── A client video session decides once ─────────────────────────────────────────────────────────
# `rust/slopdesk-video`'s `client_session` owns the lifecycle: what the client says to the host, what
# it does with the answers, how fast it retries a lost hello, and when the reconnecting scrim goes up.
# The machine crosses BY VALUE — every field is read on the Swift side, so there is nothing for a
# handle to own — and each transition answers its effects through lent buffers. Two failures are
# invisible to the type checker and both are outages. A second copy of the transition table lets the
# refusal path REBUILD and re-hello forever on a window that is gone, which is the mint-failure retry
# wedge. And a second hello ENCODER lets the two disagree by a byte on the datagram that opens every
# session, which the golden vectors pin precisely because nothing else would catch it.
SWIFT_CLIENT_SESSION=Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift
for entry in slopdesk_video_client_new slopdesk_video_client_start slopdesk_video_client_resend_hello \
  slopdesk_video_client_stop slopdesk_video_client_handle_control slopdesk_video_client_media_flowing \
  slopdesk_video_client_requested_window_id slopdesk_video_client_hello_retry_delay \
  slopdesk_stall_scrim_note_reconnecting slopdesk_stall_scrim_apply; do
  # Three of these are passed as a function REFERENCE, not called with an argument list, so the
  # name is what is looked for — in CODE, past the doc comments that name the same door.
  if ! spells "${entry}" "${SWIFT_CLIENT_SESSION}" > /dev/null; then
    fail "${SWIFT_CLIENT_SESSION} no longer calls ${entry} — that decision is rust/slopdesk-video's client_session"
  fi
done
if hit=$(spells 'state = \.|helloMessage|\.sendControl\(\.|initialDelay \* Double|guard state == ' "${SWIFT_CLIENT_SESSION}"); then
  fail "${hit} re-derives a transition, the hello or the retry cadence — those live in client_session.rs"
fi
printf 'check-supervisor: a client session decides once, and the hello it sends has one encoder.\n'

# The same file holds six rules about the SIZE the pane was given, and `client_view` holds them too.
# Each is two or three sizes wide, which is exactly why they get re-typed at the call site instead of
# called — and each has a failure the type checker cannot see. The pan gate and its clamp must key
# off the same ZOOMED size or a zoomed-in window's overflow is unreachable, or only half reachable.
# The adoption gates must reject an in-flight old-size frame or the cursor mis-scales for a beat.
# And the debounce must rebase on a client-side snap WITHOUT minting an epoch, or the snap echoes a
# resize request that re-triggers the snap: a feedback loop with the host's window in it.
for entry in slopdesk_client_is_navigable slopdesk_client_max_pan_offset slopdesk_client_video_scale \
  slopdesk_frame_decodability slopdesk_resize_should_adopt slopdesk_resize_debounce_default \
  slopdesk_resize_debounce_new slopdesk_resize_debounce_decide slopdesk_resize_debounce_note_requested \
  slopdesk_resize_debounce_note_adopted slopdesk_snap_target_points \
  slopdesk_snap_inferred_capture_scale slopdesk_snap_should_snap slopdesk_snap_epsilon; do
  if ! spells "${entry}" "${SWIFT_CLIENT_SESSION}" > /dev/null; then
    fail "${SWIFT_CLIENT_SESSION} no longer calls ${entry} — that rule is rust/slopdesk-video's client_view"
  fi
done
if hit=$(spells 'zoom > pane\.|< 0\.02|>= epsilon|/ s,|lastEpoch &\+|width / decodedSize' "${SWIFT_CLIENT_SESSION}"); then
  fail "${hit} re-derives the pan clamp, the aspect gate, the snap or the epoch — those live in client_view.rs"
fi
printf 'check-supervisor: the pane pans, scales, adopts and snaps by one set of rules.\n'

# And the two accumulators the presentation buffer is sized by. `client_jitter` owns both. The
# estimate must stay in the CLIENT's own clock — folding the host's send stamp in would re-admit
# cross-machine skew and read it as jitter — and the controller must stay asymmetric: a symmetric one
# thrashes a link sitting on the boundary, judder the user sees as the picture breathing.
for entry in slopdesk_owd_jitter_new slopdesk_owd_jitter_note slopdesk_owd_jitter_micros \
  slopdesk_adaptive_jitter_default_safety slopdesk_adaptive_jitter_default_cooldown \
  slopdesk_adaptive_jitter_new slopdesk_adaptive_jitter_note_frame \
  slopdesk_adaptive_jitter_note_underrun; do
  if ! spells "${entry}" "${SWIFT_CLIENT_SESSION}" > /dev/null; then
    fail "${SWIFT_CLIENT_SESSION} no longer calls ${entry} — that rule is rust/slopdesk-video's client_jitter"
  fi
done
if hit=$(spells '/ 16$|jitterSeconds \+=|shrinkRun|rounded\(\.up\)|1_000_000' "${SWIFT_CLIENT_SESSION}"); then
  fail "${hit} re-derives the jitter smoothing or the shrink hysteresis — those live in client_jitter.rs"
fi
printf 'check-supervisor: the buffer is sized by one estimate and one hysteresis.\n'

# The pointer inverse and the modifier latch, which `client_input` owns. The inverse is the one
# piece of client math a second copy gets subtly WRONG rather than loudly broken: a click that lands
# near the pixel under the cursor instead of on it reads as a remote machine that feels off, and it
# is golden-pinned precisely because nothing else would catch a drift of half a letterbox bar. The
# latch's failure is louder and worse — a swallowed key-up leaves ⌘ stuck on the host's shared event
# source, so every later plain scroll is a ⌘-scroll and the remote page zooms.
SWIFT_LATCH=Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift
for entry in slopdesk_input_normalize slopdesk_input_next_tag slopdesk_modifier_latch_new \
  slopdesk_modifier_latch_is_empty slopdesk_modifier_latch_is_down slopdesk_modifier_latch_note \
  slopdesk_modifier_latch_capacity slopdesk_modifier_latch_drain; do
  if ! spells "${entry}" "${SWIFT_LATCH}" > /dev/null; then
    fail "${SWIFT_LATCH} no longer calls ${entry} — that rule is rust/slopdesk-video's client_input"
  fi
done
for entry in slopdesk_cursor_shape_default_interval slopdesk_cursor_shape_is_known \
  slopdesk_cursor_shape_note_arrived slopdesk_cursor_shape_should_request; do
  if ! spells "${entry}" "${SWIFT_LATCH}" > /dev/null; then
    fail "${SWIFT_LATCH} no longer calls ${entry} — the shape self-heal is client_input's"
  fi
done
if hit=$(spells 'nextTag &\+=|panLimit|invZoom|downKeyCodes|capsLockKeyCode|knownShapeIDs|lastRequested\[' "${SWIFT_LATCH}"); then
  fail "${hit} re-derives the pointer inverse, the latch or the shape budget — client_input.rs owns them"
fi
printf 'check-supervisor: the click lands where the cursor is, no modifier stays stuck, no shape asks twice.\n'

# ── The scroll hint is ONE encoding, spelled once ───────────────────────────────────────────────
# The host measures the true per-frame pixel shift and sends it as ten-thousandths of the frame
# extent; the client turns it back into a velocity. Two ends, one scale — and a scale spelled on
# both sides is a scale that drifts: change the host's rounding or the band's inclusive-to-exclusive
# step alone and the picture warps by a hair on every scrolled frame, with nothing failing. The
# cadence knob is the same shape of rule (an env string in, a tick interval out), so it is guarded
# beside it.
SWIFT_HINT_HOST=Sources/SlopDeskVideoHost/WindowCapturer.swift
SWIFT_HINT_CLIENT=Sources/SlopDeskVideoClient/VideoWindowPipeline.swift
if ! spells 'ScrollReprojector\.Hint\(' "${SWIFT_HINT_HOST}" > /dev/null; then
  fail "${SWIFT_HINT_HOST} no longer encodes through ScrollReprojector.Hint — that scale is scroll_reproject.rs"
fi
for entry in 'ScrollReprojector\.Hint\(' 'hint\.velocity\(contentFps:' 'hint\.band\(\)'; do
  if ! spells "${entry}" "${SWIFT_HINT_CLIENT}" > /dev/null; then
    fail "${SWIFT_HINT_CLIENT} no longer decodes through ScrollReprojector.Hint — the two ends must share one scale"
  fi
done
if hit=$(spells '10000\.0|10_000\.0' "${SWIFT_HINT_HOST}" "${SWIFT_HINT_CLIENT}"); then
  fail "${hit} respells the ten-thousandths scale — ScrollHint::SCALE is the only place it lives"
fi
if ! spells 'slopdesk_input_motion_interval' "${SWIFT_HINT_CLIENT}" > /dev/null; then
  fail "${SWIFT_HINT_CLIENT} no longer reads its motion cadence through client_input.rs"
fi
printf 'check-supervisor: the scroll hint is one encoding, and the far side spells the scale.\n'

# ── The park math is Rust, and Swift keeps only what CoreGraphics defines ───────────────────────
# `WindowPlacementMath` was reabsorbed into Swift back when a Rust twin was a mirror rather than the
# implementation, and its 19 frozen vectors were pinned by a comment for a long time. The arithmetic
# is now `window_placement`, replayed on both sides of the door. Two things must not come back: the
# ordered ternary (a `Swift.min` here would swallow a NaN the corpus pins) and the half-point
# tolerance, which decides whether an app is asked to resize at all.
SWIFT_PARK=Sources/SlopDeskVideoHost/WindowPlacement.swift
for entry in slopdesk_window_placement slopdesk_window_fits; do
  if ! spells "${entry}" "${SWIFT_PARK}" > /dev/null; then
    fail "${SWIFT_PARK} no longer parks through ${entry} — that math is rust/slopdesk-video's window_placement"
  fi
done
if hit=$(spells '\+ 0\.5|< windowSize\.|needsResize = ' "${SWIFT_PARK}"); then
  fail "${hit} re-derives the clamp or the half-point tolerance — window_placement.rs owns both"
fi
printf 'check-supervisor: a parked window is placed by one set of arithmetic.\n'

# ── One keybind grammar, and the CLI no longer asks Swift for it ────────────────────────────────
# `config validate` used to hand the crate a C function pointer BACK into Swift, once per line, so
# the validator's verdict would track the grammar the app honours. The grammar is Rust now, so both
# ends of that round trip are the same side of the door — and the callback must not come back, or
# the two would be free to disagree again. The escape vocabulary and the base-key vocabulary stay
# out of Swift for the same reason: a `\xNN` that decodes differently on either side puts bytes on a
# pane the user never wrote.
SWIFT_KEYBIND=Sources/SlopDeskVideoProtocol/Settings/KeybindGrammar.swift
for entry in slopdesk_keybind_parse_line slopdesk_keybind_is_valid; do
  if ! spells "${entry}" "${SWIFT_KEYBIND}" > /dev/null; then
    fail "${SWIFT_KEYBIND} no longer parses through ${entry} — that grammar is rust/slopdesk-terminal's keybind"
  fi
done
if hit=$(spells 'func literalBytes|func isValidBaseKey|func hexNibble|"pageup"|case "cmd"' "${SWIFT_KEYBIND}"); then
  fail "${hit} re-derives the keybind grammar — keybind.rs owns the escapes and the vocabularies"
fi
if hit=$(spells 'SlopDeskKeybindValidFn|isValidKeybindValue' Sources/SlopDeskCLICore/CLIConfig.swift \
  rust/slopdesk-ffi/src/cli.rs rust/slopdesk-ffi/include/slopdesk_ffi.h); then
  fail "${hit} asks Swift whether a keybind parses — the crate holds that grammar itself now"
fi
printf 'check-supervisor: one keybind grammar, and no callback back across the door.\n'

# ── One terminal config emitter, and Swift keeps only the enums it persists ─────────────────────
# The libghostty config text is a stable ORDER of `key = value` lines, and the order is load-bearing:
# `background` after `theme` is what makes the explicit colour win, the palette after `foreground` is
# what makes the theme's sixteen entries win over both, and `font-feature` rides EVERY build because
# a font that ships ligatures turns them on itself. A second emitter would not fail a test — it would
# quietly hand libghostty a different terminal. So the tokens, the validation and the number
# formatting stay in `rust/slopdesk-terminal`'s `config`, and this side crosses the RAW VALUES it
# persists.
SWIFT_TERMCONF=Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift
if ! spells 'slopdesk_terminal_config_string' "${SWIFT_TERMCONF}" > /dev/null; then
  fail "${SWIFT_TERMCONF} no longer builds through slopdesk_terminal_config_string — that emitter is rust/slopdesk-terminal's config"
fi
if hit=$(spells 'font-family = |font-feature = |scrollback-limit = |selection-foreground|window-padding-balance' \
  "${SWIFT_TERMCONF}" Sources/SlopDeskVideoProtocol/Settings/TerminalFontSettings.swift); then
  fail "${hit} spells a libghostty config line in Swift — config.rs decides which key a preference actuates"
fi
if hit=$(spells 'func isValidHex|func formatSize|func fallbackFamilies|bytesPerScrollbackLine|clampCellHeightPercent' \
  "${SWIFT_TERMCONF}"); then
  fail "${hit} re-derives a config rule the crate owns — hex validity, number spelling and the clamp are config.rs's"
fi
if hit=$(spells 'baseFeatures|syntheticTokens|disablesFace|var thickens' \
  Sources/SlopDeskVideoProtocol/Settings/TerminalFontSettings.swift); then
  fail "${hit} maps a font preference to a libghostty token in Swift — the enum crosses as its RAW value"
fi
printf 'check-supervisor: one terminal config emitter, and Swift keeps only what it persists.\n'

# ── The config file has one reader, and `validate` reports on THAT reading ──────────────────────
# `slopdesk config validate` exists to say which lines the app will honour, so a second line reader
# is not a duplicate — it is a validator that can call a line good and a loader that then drops it.
# The two disagreed on exactly one byte: the crate trimmed a carriage return and the loader did not,
# so every binding in a CRLF file was reported valid and silently ignored. One reader now
# (`slopdesk_cli_config_keybind_value`), and the loader's default path comes from the same door that
# prints `slopdesk config path`.
SWIFT_LOADER=Sources/SlopDeskVideoProtocol/Settings/KeybindConfigLoader.swift
for entry in slopdesk_cli_config_keybind_value slopdesk_cli_config_default_path; do
  if ! spells "${entry}" "${SWIFT_LOADER}" > /dev/null; then
    fail "${SWIFT_LOADER} no longer reads the config file through ${entry} — that reading is slopdesk-cli's config"
  fi
done
if hit=$(spells 'hasPrefix\("#"\)|key == "keybind"|dropFirst\(\)\.dropLast\(\)|"\.config"' "${SWIFT_LOADER}"); then
  fail "${hit} re-reads the config dialect in Swift — config.rs classifies the line, comments, quoting and all"
fi
if ! spells 'whereSeparator' "${SWIFT_LOADER}" > /dev/null; then
  fail "${SWIFT_LOADER} splits lines without naming its separators — a CRLF pair is ONE Swift Character, so a whole CRLF file arrives as one line"
fi
if ! spells "c == '\\\\r'" rust/slopdesk-cli/src/config.rs > /dev/null; then
  fail "rust/slopdesk-cli/src/config.rs stopped trimming the carriage return — a CRLF file would validate clean and bind nothing"
fi
printf 'check-supervisor: the config file has one reader, and validate reports on that reading.\n'

# ── A number is spelled once, and every text door is measured once ──────────────────────────────
# `SLOPDESK_PLAYOUT_MS=60` and `font-size = 13` are the same question — what a user types for this
# number — and it had two answers, one per language, differing only in the limit at which an integer
# stops being written as one. The rule lives in `rust/slopdesk-terminal`'s `config` now, taking that
# limit as an argument, so the env overlay and the libghostty config text cannot drift; the limit is
# not a number either Swift file spells. The measure-then-fill dance around every text door is the
# same shape, and a measure that disagrees with its fill is a truncated answer — written once in
# `lentText` so the two calls cannot drift either.
SWIFT_ENVBRIDGE=Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift
if ! spells 'slopdesk_settings_env_number_text' "${SWIFT_ENVBRIDGE}" > /dev/null; then
  fail "${SWIFT_ENVBRIDGE} no longer spells its env numbers through slopdesk_settings_env_number_text — that rule is config.rs's number_text"
fi
if hit=$(spells 'v\.rounded\(\)|1e15' "${SWIFT_ENVBRIDGE}"); then
  fail "${hit} re-derives the number spelling in Swift — the integrality test and its limit belong to config.rs"
fi
if ! spells 'fn number_text' rust/slopdesk-terminal/src/config.rs > /dev/null; then
  fail "rust/slopdesk-terminal/src/config.rs lost number_text — the env overlay and the config text spell a number by it"
fi
for site in "${SWIFT_TERMCONF}" "${SWIFT_LOADER}" "${SWIFT_ENVBRIDGE}"; do
  if hit=$(spells 'repeating: 0, count: needed' "${site}"); then
    fail "${hit} measures a text door by hand again — lentText asks and fills so the two cannot disagree"
  fi
done
printf 'check-supervisor: a number is spelled once, and every text door is measured once.\n'

# ── One named-key table: what a chord may be SPELLED, and what it is STORED as ──────────────────
# The grammar decides which spellings a `keybind` line may use; the near side decides which one each
# folds to. Those are two halves of one table, and they were kept in step by hand in three places —
# so `space`, which the dispatcher produces (⌃⇧Space enters Vi mode) and `mapKey` resolves, was
# refused by the grammar outright: a chord the app can deliver that no config file could ask for.
# The rows live in `NAMED_KEYS` now, `is_valid_base_key` and `canonical_base_key` are both read off
# them, and the near side folds through the door rather than restating the aliases.
SWIFT_KEYPREFS=Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift
for entry in slopdesk_keybind_canonical_key slopdesk_keybind_canonical_chord; do
  if ! spells "${entry}" "${SWIFT_KEYPREFS}" > /dev/null; then
    fail "${SWIFT_KEYPREFS} no longer folds through ${entry} — that table is keybind.rs's NAMED_KEYS"
  fi
done
if hit=$(spells 'pgup|pgdn|leftarrow|rightarrow|uparrow|downarrow' \
  "${SWIFT_KEYPREFS}" Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingOverrides.swift); then
  fail "${hit} spells an alias key in Swift — a chord arrives already folded, so a second table can only drift"
fi
if ! spells 'const NAMED_KEYS' rust/slopdesk-terminal/src/keybind.rs > /dev/null; then
  fail "rust/slopdesk-terminal/src/keybind.rs lost NAMED_KEYS — the accepted spellings and the stored one are one table"
fi
if ! spells '\("space", "space"\)' rust/slopdesk-terminal/src/keybind.rs > /dev/null; then
  fail "rust/slopdesk-terminal/src/keybind.rs stopped accepting space — the dispatcher produces it, so no config line could ask for a chord the app delivers"
fi
printf 'check-supervisor: one named-key table — what a chord may be spelled, and what it is stored as.\n'

# ── The off-screen rescue decides once, and it decides in Rust ──────────────────────────────────
# The settle gate is the whole rescue: capture size is locked from the minted handle's frame, the
# Dock restore reports intermediate frames that already claim to be on screen, and a mid-animation
# mint crops the stream permanently because nothing re-targets afterwards. That tree existed twice,
# once per language, and a second copy of it does not fail a test — it crops a pane. It lives in
# `slopdesk-video`'s `mint_rescue` now, driven a step at a time because every effect it needs
# suspends on the Swift side and no C ABI can call back into that and wait.
SWIFT_RESCUE=Sources/SlopDeskVideoHost/OffScreenWindowMintRescue.swift
for entry in slopdesk_mint_rescue_begin slopdesk_mint_rescue_advance; do
  if ! spells "${entry}" "${SWIFT_RESCUE}" > /dev/null; then
    fail "${SWIFT_RESCUE} no longer drives ${entry} — the decision tree is mint_rescue.rs's"
  fi
done
if hit=$(spells 'func settledHandle|lastSighting|pollAttempts >|prior\.frame ==' "${SWIFT_RESCUE}"); then
  fail "${hit} re-derives the settle gate in Swift — two consecutive agreeing frames is mint_rescue.rs's rule"
fi
if ! spells 'fn advance' rust/slopdesk-video/src/mint_rescue.rs > /dev/null; then
  fail "rust/slopdesk-video/src/mint_rescue.rs lost advance — the rescue asks for one step and takes one observation"
fi
printf 'check-supervisor: the off-screen rescue decides once, and it decides in Rust.\n'

# ── One discovery, one resend schedule ──────────────────────────────────────────────────────────
# The window picker and the display switcher run the SAME one-shot discovery over a transient lane,
# and it was written twice here and a third time in Rust that nothing reached. The schedule is the
# part with arithmetic in it — and an interval of zero or less is not a schedule but a spin, which
# the Swift loop had no answer for. It comes from `slopdesk-video` now, and the two discoveries are
# one function that differs only in which message it sends.
SWIFT_DISCOVERY=Sources/SlopDeskVideoClient/VideoWindowDiscovery.swift
if ! spells 'slopdesk_video_request_send_offsets' "${SWIFT_DISCOVERY}" > /dev/null; then
  fail "${SWIFT_DISCOVERY} no longer takes its resend schedule from slopdesk_video_request_send_offsets"
fi
if hit=$(spells 'ContinuousClock\.now < deadline|advanced\(by: timeout\)' "${SWIFT_DISCOVERY}"); then
  fail "${hit} walks its own deadline again — the schedule is mux_client_pool.rs's request_send_offsets"
fi
if hit=$(spells 'OneShotDiscovery|DiscoveryKind' rust/slopdesk-video/src/mux_client_pool.rs); then
  fail "${hit} is a discovery gate no caller reaches — the reply is extracted where it is decoded, in Swift"
fi
printf 'check-supervisor: one discovery, and one resend schedule.\n'

# ── The raise rule is read once, off one event ──────────────────────────────────────────────────
# Raising is the expensive half of injecting — six to ten synchronous accessibility calls the input
# consumer awaits before the click is posted — and the four predicates that decide it (always,
# re-arm, latch-exempt, and the raise itself) were four Swift functions mirroring four Rust ones
# nothing reached. They are one reading of one event now: `slopdesk_input_raise_flags` answers all
# four as bits, so they cannot disagree about which arm they were shown, and the frontmost-app
# policy crosses with a presence flag rather than a sentinel pid.
SWIFT_RAISE=Sources/SlopDeskVideoHost/VideoSessionLogic.swift
for entry in 'slopdesk_input_raise_flags' 'slopdesk_input_should_raise'; do
  if ! spells "${entry}" "${SWIFT_RAISE}" > /dev/null; then
    fail "${SWIFT_RAISE} no longer takes its raise decision from ${entry}"
  fi
done
if hit=$(spells 'case \.mouseDown = event|case \.scroll = event|case \.mouseUp = event' "${SWIFT_RAISE}"); then
  fail "${hit} reads an arm to decide a raise again — the rule is input_routing.rs, through one door"
fi
if hit=$(spells 'fn route_input|enum InputDecision' rust/slopdesk-video/src/input_routing.rs); then
  fail "${hit} folds the streaming gate, the decode and the raise back together — each has one home"
fi
printf 'check-supervisor: the raise rule is read once, off one event.\n'

# ── One motion run rule, and it names events rather than carrying them ──────────────────────────
# The coalescer decided a run twice: `InputMotionCoalescer` in Swift and `coalesce_motion` in Rust
# that nothing reached. The two halves that can drift are the run KEY (a move and a drag never
# merge; a scroll is keyed by its phase signature so a gesture boundary never joins the bulk run)
# and the merge (keep the latest, but SUM a scroll's deltas — keeping the latest silently drops
# scrolled distance). Both live in `slopdesk-video` now, and the answer is a PLAN: a slot names the
# input it is built from, so the `.text` arm's string never has to cross a flat record.
SWIFT_COALESCER=Sources/SlopDeskVideoHost/VideoSessionLogic.swift
if ! spells 'slopdesk_input_coalesce_plan' "${SWIFT_COALESCER}" > /dev/null; then
  fail "${SWIFT_COALESCER} no longer takes its coalescing plan from slopdesk_input_coalesce_plan"
fi
if hit=$(spells 'enum RunKey|func runKey|func mergeRun' "${SWIFT_COALESCER}"); then
  fail "${hit} decides a motion run again — the rule is input_routing.rs's coalesce_plan"
fi
for entry in 'fn coalesce_plan' 'fn run_key' 'RunKey::Scroll'; do
  if ! spells "${entry}" rust/slopdesk-video/src/input_routing.rs > /dev/null; then
    fail "rust/slopdesk-video/src/input_routing.rs lost ${entry} — the run rule is written there once"
  fi
done
printf 'check-supervisor: one motion run rule, and it answers a plan.\n'

# ── The ledger and the accumulator cross by VALUE, and hold no rule ─────────────────────────────
# Both are stateful folds whose owners COPY them — the injector holds one under a lock, the session
# CARRIES one across a reconnect, a test folds one of its own — so neither can be a handle: a handle
# they copied would be two ledgers by the second copy (docs/55 §4b). The state crosses instead. The
# ledger is twelve bits, three buttons and nine modifier keycodes, and the modifier BIT is a key's
# position in the far side's own table, which is why that table is not spelled here either.
SWIFT_LEDGER=Sources/SlopDeskVideoHost/VideoSessionLogic.swift
for entry in 'slopdesk_input_balance_plan' 'slopdesk_scroll_planner_plan' 'slopdesk_scroll_planner_clear'; do
  if ! spells "${entry}" "${SWIFT_LEDGER}" > /dev/null; then
    fail "${SWIFT_LEDGER} no longer folds through ${entry}"
  fi
done
if hit=$(spells 'held\.insert|held\.remove|heldModifierKeys\.insert|heldModifierKeys\.remove' "${SWIFT_LEDGER}"); then
  fail "${hit} keeps a held set of its own again — the ledger is input_routing.rs's, twelve bits wide"
fi
if hit=$(spells 'accumDx|accumTemplate|appendPendingFlush' "${SWIFT_LEDGER}"); then
  fail "${hit} accumulates scroll in Swift again — the metering is ScrollCoalescePlanner, in Rust"
fi
SWIFT_MODIFIERS=Sources/SlopDeskVideoProtocol/InputModifierKeys.swift
if ! spells 'slopdesk_input_modifier_key_codes' "${SWIFT_MODIFIERS}" > /dev/null; then
  fail "${SWIFT_MODIFIERS} spells the held-modifier table again — the ledger's bits are its order"
fi
printf 'check-supervisor: the ledger and the accumulator cross by value, and hold no rule.\n'

# ── The swipe-nav operating point is parsed ONCE, and it is a handle ────────────────────────────
# One parse of the SLOPDESK_SWIPE_NAV* family answers both the path that fires ⌘[/⌘] and the status
# push that tells the client what the host will do; two parses drift, and then a committed chip and
# its haptic promise a fire the host silently swallows. This one is a HANDLE where the ledger and
# the accumulator are values because it carries an allowlist EXTENSION set — no fold of scalars
# holds that — and because its owner is a process-lifetime namespace that never copies it
# (docs/55 §4b). Deleted with it: the Swift `SwipeNavPolicy` face and the four doors that answered
# the allowlist, the extension list and the travel knob apart from an operating point.
SWIFT_SWIPE_CONFIG=Sources/SlopDeskVideoHost/SwipeNavHostConfig.swift
for entry in 'slopdesk_swipe_nav_config_parse' 'slopdesk_swipe_nav_config_eligible' \
  'slopdesk_swipe_nav_config_window_eligible' 'slopdesk_swipe_nav_config_status' \
  'slopdesk_swipe_nav_config_window_status'; do
  if ! spells "${entry}" "${SWIFT_SWIPE_CONFIG}" > /dev/null; then
    fail "${SWIFT_SWIPE_CONFIG} no longer asks ${entry} — the operating point is swipe_nav_config's"
  fi
done
if hit=$(spells 'SwipeNavStatusMessage\(\s*$|SwipeNavStatusMessage\(eligible' "${SWIFT_SWIPE_CONFIG}"); then
  fail "${hit} builds a status message by hand again — the zeroing rule for an ineligible push is the door's"
fi
if hit=$(grep -rn 'SwipeNavPolicy' --include='*.swift' Sources Tests 2> /dev/null | head -1); then
  fail "${hit} brings the Swift allowlist face back — it is swipe_nav_config's question now"
fi
if hit=$(grep -rn 'slopdesk_swipe_is_navigable\|slopdesk_swipe_extra_apps\|slopdesk_swipe_fire_travel_from_env' \
  --include='*.rs' --include='*.h' --include='*.swift' rust/slopdesk-ffi Sources 2> /dev/null | head -1); then
  fail "${hit} answers the allowlist apart from an operating point again"
fi
printf 'check-supervisor: the swipe-nav operating point is parsed once, and it is a handle.\n'

# ── The client's gesture policies are asked, not spelled ────────────────────────────────────────
# Four rules that belong to a view no test may instantiate — no Metal, no VT. The two stateful ones
# cross BY VALUE because their owner is a SwiftUI view the framework copies at will, and a handle it
# copied would be one accumulator serving two gestures; the denylist is a handle because it carries
# a runtime extension SET, the swipe-nav config's reason exactly (docs/55 §4b).
SWIFT_PINCH=Sources/SlopDeskVideoClient/PinchZoomKeyPlanner.swift
SWIFT_PINNER=Sources/SlopDeskVideoClient/ScrollRoutePinner.swift
SWIFT_POINTER=Sources/SlopDeskVideoClient/BackgroundPointerPolicy.swift
SWIFT_ZOOM_RESET=Sources/SlopDeskVideoClient/PinchZeroPolicy.swift
if ! spells 'slopdesk_pinch_planner_plan' "${SWIFT_PINCH}" > /dev/null; then
  fail "${SWIFT_PINCH} accumulates the pinch again — the residual and its step cap are client_gestures.rs's"
fi
if hit=$(spells 'stepThreshold|maxStepsPerEvent|residual [-+]=' "${SWIFT_PINCH}"); then
  fail "${hit} spells a pinch threshold again — the ladder is one number, over there"
fi
if ! spells 'slopdesk_scroll_pin_route' "${SWIFT_PINNER}" > /dev/null; then
  fail "${SWIFT_PINNER} re-derives the route again — the pin is client_gestures.rs's"
fi
if hit=$(spells 'scrollPhase == 1|scrollPhase == 128|scrollPhase == 8|momentumPhase == 3' "${SWIFT_PINNER}"); then
  fail "${hit} names a phase code again — which phase begins or ends a gesture is the pin's rule"
fi
for entry in 'slopdesk_gesture_forwards_pointer' 'slopdesk_gesture_background_click'; do
  if ! spells "${entry}" "${SWIFT_POINTER}" > /dev/null; then
    fail "${SWIFT_POINTER} no longer asks ${entry} — a background surface's two gates are one rule"
  fi
done
if ! spells 'slopdesk_zoom_reset_allowed' "${SWIFT_ZOOM_RESET}" > /dev/null; then
  fail "${SWIFT_ZOOM_RESET} answers the denylist again — it is a handle, parsed once"
fi
if hit=$(spells 'unsafeAppNames|"Xcode"' "${SWIFT_ZOOM_RESET}"); then
  fail "${hit} names an unsafe app again — the list lives beside the chord rule it protects"
fi
printf 'check-supervisor: the client gesture policies are asked, not spelled.\n'

# ── The paced-send schedule is one answer, and the datagrams stay put ───────────────────────────
# The lane's sleeps and its abort generation are Swift concurrency and stay there; the chunk
# boundaries, their ABSOLUTE deadlines and the skip-the-lane test are `send_pacing`'s. The frame's
# datagrams never cross — a chunk names the caller's own array by index. What this pins hardest is
# the one-shot test: the session used to spell it to pick the inline path and the lane spelled it
# again to send in one shot, with a comment at the first promising it "mirrors" the second.
SWIFT_SEND_LANE=Sources/SlopDeskVideoHost/VideoSendLane.swift
for entry in 'slopdesk_send_pace_plan' 'slopdesk_send_may_inline'; do
  if ! spells "${entry}" "${SWIFT_SEND_LANE}" > /dev/null; then
    fail "${SWIFT_SEND_LANE} no longer asks ${entry} — the schedule is send_pacing.rs's"
  fi
done
if hit=$(spells 'gapNanos == 0|min\(i \+ job\.chunkFragments|count <= job\.chunkFragments' "${SWIFT_SEND_LANE}"); then
  fail "${hit} splits the job into chunks again — the boundaries and the one-shot test are one answer"
fi
SWIFT_SESSION_SEND=Sources/SlopDeskVideoHost/SlopDeskVideoHostSession.swift
if hit=$(spells 'let singleShot' "${SWIFT_SESSION_SEND}"); then
  fail "${hit} mirrors the lane's one-shot test again — ask trySendInline, which asks the door"
fi
printf 'check-supervisor: the paced-send schedule is one answer, and the datagrams stay put.\n'

# ── The host session machine is the handshake's other end, and it holds no rule twice ───────────
# `client_session` already crosses the client's half of the hello negotiation; `session_state` is
# the host's, and it crosses the same way — the machine by value (nine scalars an actor field
# copies), the acknowledgement as its ENCODED BYTES, and the three size resolvers as pre-resolved
# ANSWERS rather than callbacks, because exactly one can matter per message and the message's own
# variant decides which. What this pins hardest is the rules that were spelled on BOTH sides: the
# accept/reject path, the resize clamp, the stale-epoch test and the two stream-settings bands.
SWIFT_SESSION_LOGIC=Sources/SlopDeskVideoHost/VideoSessionLogic.swift
for entry in 'slopdesk_video_session_new' 'slopdesk_video_session_start' 'slopdesk_video_session_stop' \
  'slopdesk_video_session_control' 'slopdesk_video_session_media_flowing' \
  'slopdesk_video_session_clamp_capture' 'slopdesk_video_session_stale_epoch' \
  'slopdesk_video_fps_cap_from_wire' 'slopdesk_video_bitrate_ceiling_from_wire' \
  'slopdesk_video_effective_fps'; do
  if ! spells "${entry}" "${SWIFT_SESSION_LOGIC}" > /dev/null; then
    fail "${SWIFT_SESSION_LOGIC} no longer asks ${entry} — the host session's law is session_state.rs's"
  fi
done
if hit=$(spells 'epoch <= lastApplied|clampAxis|fpsCapRange|bitrateCeilingRange' "${SWIFT_SESSION_LOGIC}"); then
  fail "${hit} spells a session rule again — the epoch test, the clamp and both bands are one answer"
fi
if hit=$(spells 'case \.hello|nextStreamID \+= 1|protocolVersion == ' "${SWIFT_SESSION_LOGIC}"); then
  fail "${hit} decides the handshake again — accepting, rejecting and minting a stream id are the law's"
fi
printf 'check-supervisor: the host session machine crosses by value, and the handshake is decided once.\n'

# ── One key vocabulary, whichever grammar names it ──────────────────────────────────────────────
# `send_keys` reads the table for the `<Token>` grammar a preset, a template, a re-run and a text
# drop carry; the agent-control `write` verb names the SAME keys in a comma-separated `--key` list,
# and used to carry a second table for it. They had drifted: `C-?` was DEL on the Swift side and
# `C-_`'s byte in Rust, `C-Space` was NUL there and refused here, and the function and paging keys
# had no Rust spelling at all. One table answers both now.
SWIFT_KEYMAP=Sources/SlopDeskHost/ControlKeyMap.swift
if ! spells 'slopdesk_ws_key_token' "${SWIFT_KEYMAP}" > /dev/null; then
  fail "${SWIFT_KEYMAP} answers a key name again — the vocabulary is send_keys.rs's"
fi
if hit=$(spells '0x1B, 0x5B|case "enter"|case "pageup"|& 0x1F' "${SWIFT_KEYMAP}"); then
  fail "${hit} spells a key sequence again — a second table is how C-? and C-Space drifted"
fi
if ! spells 'pub fn key_token' rust/slopdesk-workspace/src/send_keys.rs > /dev/null; then
  fail "rust/slopdesk-workspace/src/send_keys.rs lost key_token — the bare-name grammar reads the table through it"
fi
for entry in '"f12"' '"pagedown"' '"insert"'; do
  if ! spells "${entry}" rust/slopdesk-workspace/src/send_keys.rs > /dev/null; then
    fail "rust/slopdesk-workspace/src/send_keys.rs dropped ${entry} — the union is the vocabulary, so a preset can say it too"
  fi
done
printf 'check-supervisor: one key vocabulary, whichever grammar names it.\n'

# ── One VT grammar for plain text, read two ways ────────────────────────────────────────────────
# `vtscan` exists because the replay passes each hand-rolled the same skimmer. Two MORE machines
# were still spelled in Swift: the stripper that renders a pane's output for a regex, and the
# holdback scan that decides where a chunk was cut mid-sequence — whose doc comments promised each
# other they matched, which is the drift risk stated as a promise. Both are `plaintext` now, and
# the terminator policy that genuinely differs between a replay pass and a render is NAMED
# (`Terminators`) rather than duplicated.
SWIFT_STRIPPER=Sources/SlopDeskHost/ANSIStripper.swift
for entry in 'slopdesk_plaintext_strip' 'slopdesk_plaintext_holdback'; do
  if ! spells "${entry}" "${SWIFT_STRIPPER}" > /dev/null; then
    fail "${SWIFT_STRIPPER} no longer asks ${entry} — the VT grammar is plaintext.rs's"
  fi
done
if hit=$(spells 'skipCSI|skipStringCommand|0x9B|0xE000|utf8Tail' "${SWIFT_STRIPPER}"); then
  fail "${hit} walks the grammar again — one scanner answers both the strip and the holdback"
fi
SWIFT_WAIT=Sources/SlopDeskHost/AgentControlListener.swift
if hit=$(spells 'private static func csiEnd|private static func stringCommandEnd' "${SWIFT_WAIT}"); then
  fail "${hit} is a second VT machine — its own comments used to say it matched the stripper's"
fi
if ! spells 'pub fn holdback_start' rust/slopdesk-sanitize/src/plaintext.rs > /dev/null; then
  fail "rust/slopdesk-sanitize/src/plaintext.rs lost holdback_start — the cut point is read off the same grammar"
fi
if ! spells 'pub const fn lenient' rust/slopdesk-sanitize/src/vtscan.rs > /dev/null; then
  fail "rust/slopdesk-sanitize/src/vtscan.rs lost the lenient terminator policy — a render cannot wait for a continuation the way a replay pass can"
fi
printf 'check-supervisor: one VT grammar for plain text, read two ways.\n'

# ── The reset backstop is built from the set the strip pass reads ───────────────────────────────
# `sanitizeSuffix` is appended by a restore the passes did NOT run on, which is exactly when a mode
# they track must still be turned off. All fourteen were spelled out on the near side, with nothing
# connecting that literal to `TRACKED_MODES` — so a mode added to the pass would have gone missing
# from the backstop that exists to catch what the pass missed.
SWIFT_TRANSCRIPTS=Sources/SlopDeskHost/ScrollbackTranscripts.swift
if ! spells 'slopdesk_input_mode_reset' "${SWIFT_TRANSCRIPTS}" > /dev/null; then
  fail "${SWIFT_TRANSCRIPTS} spells the reset again — it is built from inputmode.rs's TRACKED_MODES"
fi
if hit=$(spells '\?1000l|\?2004l|\?2048l' "${SWIFT_TRANSCRIPTS}"); then
  fail "${hit} names a tracked mode in Swift — the backstop and the pass read one array"
fi
if ! spells 'pub fn reset_suffix' rust/slopdesk-sanitize/src/inputmode.rs > /dev/null; then
  fail "rust/slopdesk-sanitize/src/inputmode.rs lost reset_suffix — the backstop is built, not written"
fi
printf 'check-supervisor: the reset backstop is built from the set the strip pass reads.\n'

# ── One shell word, wherever a path is typed into a live shell ─────────────────────────────────
# The POSIX `'…'` quoting was written EIGHT times: seven Swift copies and one private to the Rust
# template emitter. One of the seven called itself the single source of truth while four sat beside
# it; another kept its copy rather than widen a daemon's dependency graph for four lines. The graph
# never had to widen — the face lives in the value-model leaf every one of them already links.
#
# The half that bans a second copy moved to `scripts/check-invariants.py`
# (`shell_quoting_has_one_owner`), because the version here could not fail: it piped 742 paths into
# `xargs grep -ln`, which prints the offender and still exits non-zero when the last batch is clean.
SWIFT_QUOTING=Sources/SlopDeskWorkspaceModel/Domain/ShellQuoting.swift
if ! spells 'slopdesk_ws_shell_quote' "${SWIFT_QUOTING}" > /dev/null; then
  fail "${SWIFT_QUOTING} stopped asking the door — it is a face, not a second rule"
fi
if hit=$(spells 'private static func isShellSafe|allSatisfy' Sources/SlopDeskWorkspaceCore/Terminal/PasteTransform.swift); then
  fail "${hit} spells the shlex safe set again — bare-if-safe is a reading of the same door"
fi
if ! spells 'pub fn shlex_quoted' rust/slopdesk-ids/src/shell_quoting.rs > /dev/null; then
  fail "rust/slopdesk-ids/src/shell_quoting.rs lost shlex_quoted — the paste's bare reading is the same rule"
fi
if hit=$(spells "fn shell_quoted" rust/slopdesk-workspace/src/templates.rs); then
  fail "${hit} is the emitter's private copy again — it asks shell_quoting like everyone else"
fi
printf 'check-supervisor: one shell word, wherever a path is typed into a live shell.\n'

# ── One vocabulary for a foreground process name ───────────────────────────────────────────────
# The `claude` and wrapper matches already reduced a process name in Rust while Swift kept its own
# reducer beside them, plus the version-directory walk and an eleven-name sensitive set with no
# Rust twin at all. One name, read three ways, must reduce the same way each time.
SWIFT_FOREGROUND=Sources/SlopDeskHost/ForegroundProcessProbes.swift
if hit=$(spells 'split\(separator: "/"\)|isVersionShaped|"versions"' "${SWIFT_FOREGROUND}"); then
  fail "${hit} reduces a process name again — slopdesk-agent::process owns the basename and the version walk"
fi
SWIFT_CONTROL=Sources/SlopDeskHost/AgentControlListener.swift
if hit=$(spells 'sensitiveBasenames|"sshpass"|"doas"' "${SWIFT_CONTROL}"); then
  fail "${hit} lists the sensitive commands in Swift — the set is SENSITIVE_BASENAMES in Rust"
fi
if ! spells 'slopdesk_agent_is_sensitive' Sources/SlopDeskAgentDetect/ForegroundProcessName.swift > /dev/null; then
  fail "Sources/SlopDeskAgentDetect/ForegroundProcessName.swift stopped asking the door — it is a face, not a second rule"
fi
for rule in 'pub fn is_sensitive' 'pub fn canonical_name' 'pub fn is_version_shaped' 'pub fn basename'; do
  if ! spells "${rule}" rust/slopdesk-agent/src/process.rs > /dev/null; then
    fail "rust/slopdesk-agent/src/process.rs lost ${rule} — the foreground vocabulary is one module"
  fi
done
printf 'check-supervisor: one vocabulary for a foreground process name.\n'

# ── One badge ladder for a tab row ─────────────────────────────────────────────────────────────
# Ten precedence rungs over four independent signals, with two placements that are the whole reason
# it is a rule: the AGENT finish above the busy tiers (claude holds the OSC-133 block open for its
# whole lifetime), a COMMAND's exit below them. It was pure Swift with no Rust twin at all.
SWIFT_BADGE=Sources/SlopDeskWorkspaceCore/Workspace/Tabs/TabBadge.swift
# The KIND is a second file now: `TabBadgeResolver` needs the store's badge gates and stayed, the
# discriminant does not and descended to the value model, where `SlopDeskSlate` can name it without
# naming a store.
SWIFT_BADGE_KIND=Sources/SlopDeskWorkspaceModel/Reading/TabBadgeKind.swift
if [[ ! -e "${SWIFT_BADGE_KIND}" ]]; then
  fail "${SWIFT_BADGE_KIND} is gone — the case list this gate counts moved, and a missing file counts ZERO cases"
fi
if hit=$(spells 'sudoBasenames|caffeinateBasenames|privilegeBadge|agent == .needsPermission' "${SWIFT_BADGE}"); then
  fail "${hit} walks the badge ladder in Swift — slopdesk-agent::badge resolves it"
fi
if ! spells 'slopdesk_agent_tab_badge' "${SWIFT_BADGE}" > /dev/null; then
  fail "${SWIFT_BADGE} stopped asking the door — it is a face over the ladder, not a second one"
fi
# Bounded by `[:[:space:]{]` for the same reason the pill-ink arm below is: an OPEN address also
# matches `TabBadgeKindRung`, so the enum renamed out from under the gate would keep counting nine.
swift_badges=$(sed -n '/^public enum TabBadgeKind[:[:space:]{]/,/^}/p' "${SWIFT_BADGE_KIND}" | grep -cE '^    case ') || true
rust_badges=$(grep -oE 'pub const ALL: \[Self; [0-9]+\]' rust/slopdesk-agent/src/badge.rs | grep -oE '[0-9]+') || true
# A zero on either side means the EXTRACTION broke, not that the lists agree — without this the two
# could both read 0 after a rename and the gate would pass having compared nothing.
if [[ "${swift_badges}" == "0" || -z "${rust_badges}" ]]; then
  fail "the TabBadgeKind/TabBadge::ALL census read EMPTY (swift=${swift_badges} rust=${rust_badges}) — this gate has stopped checking anything"
fi
if [[ "${swift_badges}" != "${rust_badges}" ]]; then
  fail "TabBadgeKind has ${swift_badges} Swift cases and ${rust_badges} Rust ones — the discriminant that crosses the ABI is now wrong (docs/55)"
fi
printf 'check-supervisor: one badge ladder for a tab row.\n'

# ── One fuzzy ranking, for every search field ──────────────────────────────────────────────────
# fzf's `FuzzyMatchV2` — a Smith-Waterman DP, a structural-bonus table and a backtrace — was 300
# lines of Swift beside the Rust that owns it now. This one carries IDENTITY: the order a palette
# shows IS the product, so a second scorer does not fail a test, it just starts ranking differently
# and nobody can say which copy the person is looking at. Every search field asks the same door.
SWIFT_FUZZY=Sources/SlopDeskClientCore/Palette/FuzzyMatcher.swift
scorer_revived=$(among_deleted '(let|var|func|case) *(bonusBoundary|bonusCamel123|bonusConsecutive|scoreGapStart|scoreGapExtension|bonusMatrix|bonusFor|backtrace)\b')
if [[ -n "${scorer_revived}" ]]; then
  printf '%s\n' "${scorer_revived}" >&2
  fail "a Swift fuzzy scorer is back in Sources/ — rust/slopdesk-fuzzy owns FuzzyMatchV2"
fi
if ! spells 'slopdesk_fuzzy_score' "${SWIFT_FUZZY}" > /dev/null; then
  fail "${SWIFT_FUZZY} stopped asking the door — it is a marshaller over the matcher, not a second one"
fi
for rule in 'pub fn score' 'pub fn rank' 'pub fn match_pattern' 'fn bonus_for'; do
  if ! spells "${rule}" rust/slopdesk-fuzzy/src/lib.rs > /dev/null; then
    fail "rust/slopdesk-fuzzy/src/lib.rs lost ${rule} — the ranking is one module"
  fi
done
printf 'check-supervisor: one fuzzy ranking, for every search field.\n'

# ── One reading of a hook body ─────────────────────────────────────────────────────────────────
# A hook body used to be read TWICE over: a typed `HookPayload` enum modelling the JSON in
# `SlopDeskInspector`, and a `mapToHookEvent` adapter a module away in `SlopDeskHost` turning a
# payload into the event the machine folds. Splitting an event's IDENTITY from its MEANING is what
# let them drift — a payload case could gain a field the adapter never read, and the rules that
# decide a pane's status (`AskUserQuestion` is a BLOCK, an interrupt is a FINISHED TURN, the idle
# nudge is not a raised hand) lived nowhere near the case they governed. `rust/slopdesk-hookevent`
# owns both halves now; Swift marshals.
#
# The Swift MARSHALLER over that reader is gone too, and this gate no longer names a file it must
# still exist in. It could not: a body now crosses as raw bytes inside the fold that reads it, so
# a Swift file whose whole job was to turn a body into an event is a decode with nothing left to
# hand its answer to. `ClaudeHookBody` and the `ClaudeHookEvent` vocabulary it carried went with
# it, and so did the standalone `slopdesk_hook_event_parse` door and its whole module — a door
# nothing calls is a second way to ask what `slopdesk_agent_detector_hook` already answers.
parser_revived=$(among_deleted '(enum|struct) *(HookPayload|StopInfo|ToolUseBlock|NotificationInfo|ClaudeHookBody|ClaudeHookEvent)\b|func +(mapToHookEvent|classifyNotification|stopLabel)\b')
if [[ -n "${parser_revived}" ]]; then
  printf '%s\n' "${parser_revived}" >&2
  fail "a Swift hook-body parser is back in Sources/ — rust/slopdesk-hookevent owns the reading AND the mapping"
fi
if hit=$(grep -rln 'slopdesk_hook_event_parse' Sources --include='*.swift' 2> /dev/null); then
  printf '%s\n' "${hit}" >&2
  fail "a standalone hook-body door is back — the body crosses raw, inside slopdesk_agent_detector_hook"
fi
# The DETECTOR used to be named here as the one caller of that door. It is not a caller at all now:
# the body crosses as raw bytes and `rust/slopdesk-agent`'s detector reads it on the far side, in the
# same call that folds it. So this inverts too — a body read on the Swift side of the fold is a
# reading that has to agree with the Rust one, which is the drift the single reader exists to end.
if hit=$(spells 'ClaudeHookBody|JSONSerialization|hook_event_name' Sources/SlopDeskHost/ClaudePaneDetector.swift); then
  fail "${hit} reads a hook body — it hands the raw bytes to slopdesk_agent_detector_hook, which reads them once"
fi
# The LISTENER used to be named here too, because it read bodies itself: an `AgentHookHandler` at
# the top of that file folded them through a second `ClaudeStatusMachine`. It routes now and reads
# nothing, so the check inverts — a body read back there is a second fold growing back, which is a
# stronger statement than "it still uses the right door".
if hit=$(spells 'ClaudeHookBody|ClaudeStatusMachine' Sources/SlopDeskHost/AgentHookListener.swift); then
  fail "${hit} reads a hook body again — the listener ROUTES; the pane's detector is what folds"
fi
for rule in 'pub fn parse' 'fn classify' 'fn stop_label' 'fn question_label'; do
  if ! spells "${rule}" rust/slopdesk-hookevent/src/lib.rs > /dev/null; then
    fail "rust/slopdesk-hookevent/src/lib.rs lost ${rule} — one body, one reading, one meaning"
  fi
done
printf 'check-supervisor: one reading of a hook body.\n'

# ── And ONE state machine per pane ──────────────────────────────────────────────────────────────
# `ClaudePaneDetector` exists because two machines per pane FIGHT: both emit type-27 with no
# reconciliation, so a hook `.working` and a foreground-poll `.idle` clobber each other on the one
# control stream, and with neither owning `.tick(at:)` the `.done → .idle` decay never fires — a
# finished turn stays lit forever. The fusion landed, and the machine it replaced kept compiling
# anyway: `ForegroundProcessDetector`, holding its own `ClaudeStatusMachine`, its own basename edge
# anchor and its own status dedupe anchor, constructed by nothing in `Sources/` and kept alive by a
# test file of its own. That is the shape `CLAUDE.md` names outright — a second implementation
# surviving as a test fake — and it is what this gate is here to catch the next time.
#
# It was TWO, not one: `AgentHookHandler` beside the hook listener did the same thing for the same
# reason — reading a body through the same `ClaudeHookBody` door, folding it through its own
# machine, dedupeing against its own anchor — and it too was constructed only by its own tests.
#
# Counted rather than named, because the failure is arithmetic — and the count is now ZERO, because
# the FUSION itself moved: `rust/slopdesk-agent::detector` owns the two dedupe anchors, the
# stickiness clock and its two absence suppressors, the block-class carry, the intent latch and the
# title ownership record, and it is the only thing anywhere that constructs a machine.
# `ClaudePaneDetector` is the handle over it plus the `WireMessage` shapes, which is the one part
# that has to stay Swift. A machine grown back on this side is a second one by construction.
machine_owners=$(grep -rln 'ClaudeStatusMachine(' Sources --include='*.swift' 2> /dev/null || true)
if [[ -n "${machine_owners}" ]]; then
  printf '%s\n' "${machine_owners}" >&2
  fail "a ClaudeStatusMachine is constructed in Sources/ — the ONE per pane is rust/slopdesk-agent's PaneDetector (docs/50)"
fi
if ! spells 'slopdesk_agent_detector_new\(' Sources/SlopDeskHost/ClaudePaneDetector.swift > /dev/null; then
  fail "Sources/SlopDeskHost/ClaudePaneDetector.swift stopped opening the Rust detector — it is the handle over the fusion, not a second one"
fi
# A handle holds no fold state. Each name below WAS a field here, and each is now an anchor the
# crate owns; one reappearing means the Swift face started deciding again, in parallel.
if hit=$(spells 'lastEmittedName|lastEmittedIntent|lastEmittedStatus =|hookAuthority|lastNotificationKind|agentOwnsTitle|lastAuthoritativeAt' Sources/SlopDeskHost/ClaudePaneDetector.swift); then
  fail "${hit} grew fold state back — every anchor belongs to rust/slopdesk-agent::detector (docs/50)"
fi
# Each pattern carries its open paren: without it `fn topic_line` matches `fn topic_lineX`, and a
# rule renamed out of existence would satisfy the gate that exists to notice exactly that.
for rule in 'fn sample\(' 'fn hook\(' 'fn report\(' 'fn tick\(' 'fn screen\(' 'fn title\(' 'fn user_input\(' 'fn reestablish_on_reattach\(' 'fn intent_line\(' 'fn topic_line\(' 'fn block_kind\('; do
  if ! spells "${rule}" rust/slopdesk-agent/src/detector.rs > /dev/null; then
    fail "rust/slopdesk-agent/src/detector.rs lost ${rule//\\/} — the fusion is one place or it is two"
  fi
done
# The probe file is the shim half of that split, and it must stay a shim: the moment it folds a
# signal or holds an emit anchor it has become the reducer again, under a new name.
if hit=$(spells 'ClaudeStatusMachine|lastEmitted|struct Emission|mutating func sample|mutating func tick' "${SWIFT_FOREGROUND}"); then
  fail "${hit} decides something — the probes resolve a NAME, ClaudePaneDetector folds it (docs/50)"
fi
# And the triple stays one type. Three emitters anchor on it; a fourth spelling of the same three
# fields is how the dedupe anchors drift apart into two answers for "would this frame be a repeat".
if ! spells 'public struct ClaudeStatusTriple:' Sources/SlopDeskAgentDetect/ClaudeStatus.swift > /dev/null; then
  fail "ClaudeStatusTriple left Sources/SlopDeskAgentDetect/ClaudeStatus.swift — it is the vocabulary's, not an emitter's"
fi
if hit=$(grep -rln 'struct StatusTriple' Sources 2> /dev/null); then
  printf '%s\n' "${hit}" >&2
  fail "a second status triple is declared in Sources/ — ClaudeStatusTriple is the one shape of a type-27 emit"
fi
printf 'check-supervisor: one pane detector, in Rust, and the probes only probe.\n'

# ── One VT grammar for STYLED text, and the clipboard reads it destyled ────────────────────────
# `AnsiStyledParser` was a SECOND VT grammar: a hand-rolled escape skipper, a hand-rolled SGR
# decoder and a hand-rolled string-sequence scan, sitting beside the `vtscan` module that already
# owned all three for the replay passes. Two grammars over one byte stream is how a sequence one
# side skips and the other prints becomes a bug nobody can localise. `slopdesk_sanitize::styled`
# owns the pass now; the clipboard's plain text is that pass with the styles discarded, which is
# what keeps the copied text and the coloured text from being two behaviours.
SWIFT_STYLED=Sources/SlopDeskWorkspaceCore/Terminal/AnsiStyledText.swift
grammar_revived=$(among_deleted 'func +(skipEscapeSequence|isEraseToLineEnd|applySGR|extendedColour)\b')
if [[ -n "${grammar_revived}" ]]; then
  printf '%s\n' "${grammar_revived}" >&2
  fail "a Swift VT grammar is back in Sources/ — slopdesk-sanitize::styled owns the styled pass"
fi
if ! spells 'slopdesk_styled_lines' "${SWIFT_STYLED}" > /dev/null; then
  fail "${SWIFT_STYLED} stopped asking the door — it is a marshaller over the pass, not a second one"
fi
SWIFT_PLAIN=Sources/SlopDeskWorkspaceCore/Terminal/BlockOutputSanitizer.swift
if ! spells 'AnsiStyledParser\.lines' "${SWIFT_PLAIN}" > /dev/null; then
  fail "${SWIFT_PLAIN} skims on its own again — the clipboard's text IS the styled pass, destyled"
fi
for rule in 'pub fn lines' 'fn escape_end' 'fn apply_sgr' 'fn is_erase_to_line_end'; do
  if ! spells "${rule}" rust/slopdesk-sanitize/src/styled.rs > /dev/null; then
    fail "rust/slopdesk-sanitize/src/styled.rs lost ${rule} — one grammar, read two ways"
  fi
done
printf 'check-supervisor: one VT grammar for styled text, and the clipboard destyles it.\n'

# ── One paste guard, and the other one stays a different engine ────────────────────────────────
# Two guards ask two questions and must never merge: `paste` asks "would this run something
# dangerous at a prompt?", `secrets` asks "would typing this leak a credential?". Both are Rust
# now; what this pins is that neither Swift face grows rules of its own, and that the four dangers
# keep the same bit numbering on both sides — the mask crosses as itself, so a renumbering here
# would silently relabel every warning the sheet prints.
#
# The SENTENCES are pinned the same way, and for the same reason. A line describing a danger is as
# much the guard as the bit that trips it: a renderer that spelled its own would be a second guard
# saying something slightly different, and a fifth danger would reach the user as a blank bullet.
SWIFT_PASTE=Sources/SlopDeskWorkspaceCore/Terminal/PasteSafetyAnalyzer.swift
SWIFT_PASTE_SHEET=Sources/SlopDeskMacUI/Terminal/PasteProtectionSheet.swift
if hit=$(spells 'containsElevationToken|isSeparator|unicodeScalars' "${SWIFT_PASTE}"); then
  fail "${hit} classifies a paste in Swift again — slopdesk-terminal::paste owns the four dangers"
fi
for entry in 'slopdesk_paste_dangers' 'slopdesk_paste_should_warn' 'slopdesk_paste_danger_description' 'slopdesk_paste_preview'; do
  if ! spells "${entry}" "${SWIFT_PASTE}" > /dev/null; then
    fail "${SWIFT_PASTE} no longer asks ${entry} — the guard is one implementation"
  fi
done
if hit=$(spells 'previewLimit|messageText = "|Paste Anyway|OSC 52' "${SWIFT_PASTE_SHEET}"); then
  fail "${hit} spells the confirmation's own words — slopdesk-terminal::paste owns every sentence"
fi
for law in 'pub fn descriptions' 'pub fn preview' 'pub enum Ask'; do
  if ! spells "${law}" rust/slopdesk-terminal/src/paste.rs > /dev/null; then
    fail "rust/slopdesk-terminal/src/paste.rs lost ${law} — the sheet's words live beside its rules"
  fi
done
for bit in 'MULTI_LINE: u32 = 1 << 0' 'TRAILING_NEWLINE: u32 = 1 << 1' 'SUDO_OR_SU: u32 = 1 << 2' 'CONTROL_CHARS: u32 = 1 << 3'; do
  if ! spells "${bit}" rust/slopdesk-terminal/src/paste.rs > /dev/null; then
    fail "rust/slopdesk-terminal/src/paste.rs renumbered a danger (${bit}) — the mask crosses as itself"
  fi
done
printf 'check-supervisor: one paste guard, and the secret one stays a different engine.\n'

# ── One clustering answers the cursor and the badge that says where it is ──────────────────────
# The vi copy-mode motions used to walk the row in Swift, `Character` by `Character`, asking the
# link detector for each glyph's width. The link and hint overlays walked the SAME row through
# `slopdesk_terminal::link`'s clustering. Two clusterings over one row put a cursor half a glyph
# away from the badge claiming to be on it, on exactly the CJK rows nobody checks by hand — so the
# motions moved beside the clustering, and this pins that they stay there.
SWIFT_VI=Sources/SlopDeskWorkspaceCore/Terminal/ViLineMotion.swift
if hit=$(spells 'CellChar|charClass|isWhitespace|isLetter|isNumber|runStartIndex|runEndIndex' "${SWIFT_VI}"); then
  fail "${hit} walks the row in Swift again — slopdesk-terminal::vimotion owns the motions"
fi
for entry in 'slopdesk_vi_next_word_start' 'slopdesk_vi_column_step' 'slopdesk_vi_cell_width'; do
  if ! spells "${entry}" "${SWIFT_VI}" > /dev/null; then
    fail "${SWIFT_VI} no longer asks ${entry} — the motions are one implementation"
  fi
done
for law in 'pub fn cells' 'pub fn addressable_cells' 'fn run_start_index' 'fn run_end_index'; do
  if ! spells "${law}" rust/slopdesk-terminal/src/vimotion.rs > /dev/null; then
    fail "rust/slopdesk-terminal/src/vimotion.rs lost ${law} — the copy-mode motions live there"
  fi
done
if ! spells 'use crate::link::\{clusters, scalar_cells\}' rust/slopdesk-terminal/src/vimotion.rs > /dev/null; then
  fail "vimotion stopped reading link's clustering — the cursor and the hint badge would drift apart"
fi
printf 'check-supervisor: one clustering answers the cursor and the badge.\n'

# ── And ONE width table under that clustering ──────────────────────────────────────────────────
# One clustering was not enough, because there were still two tables saying how wide a cluster IS.
# `slopdesk-sanitize` knew the Arabic, Hebrew and Thai combining marks; the link scan's copy knew
# the Default_Ignorable set and painted U+1F300..U+1FAFF wide over three ranges of narrow
# pictographs. A screen model measuring a Thai line one way while the cursor, the underline and the
# hint badge measure it another is the same drift one layer down. The CJK sentinel below is the
# cheapest tell that a third table has appeared: nothing measures East Asian width without it.
if ! spells 'pub const fn scalar_width' rust/slopdesk-sanitize/src/width.rs > /dev/null; then
  fail "rust/slopdesk-sanitize/src/width.rs lost scalar_width — it is the one width table"
fi
if ! spells 'use slopdesk_sanitize::width::scalar_width' rust/slopdesk-terminal/src/link.rs > /dev/null; then
  fail "rust/slopdesk-terminal/src/link.rs stopped reading the one width table — a second one drifts"
fi
# ONE `grep -l` over the whole tree for candidates, then `spells` only on those — the same trick
# `spells` itself uses, for the same reason. Looping `spells` over ~1000 files spawned a process per
# FILE and cost seconds off every inner loop; the comment-strip is what makes it a `spells` call at
# all, and stripping can only ever REMOVE a match, so a file this grep rejects cannot match after it.
while IFS= read -r owner; do
  [[ -z "${owner}" || "${owner}" == rust/slopdesk-sanitize/src/width.rs ]] && continue
  if spells '0x4E00|0x4e00' "${owner}" > /dev/null 2>&1; then
    fail "${owner} carries its own East Asian width table — slopdesk-sanitize::width is the one"
  fi
done < <(grep -lE '0x4E00|0x4e00' rust/*/src/*.rs rust/*/src/*/*.rs Sources/*/*.swift \
  Sources/*/*/*.swift Sources/*/*/*/*.swift 2> /dev/null || true)
printf 'check-supervisor: one width table under that clustering.\n'

# ── And ONE grammar for where an escape ENDS ───────────────────────────────────────────────────
# `vtscan` exists because the Swift originals hand-rolled the CSI/string-sequence walk four times
# and a bug in the parameter ranges was fixable in four places. `slopdesk-altscreen` then made a
# FIFTH copy — in the crate that decides, from evicted bytes, whether tens of MiB of alt-screen
# churn replays into a user's scrollback. Two scanners disagreeing about where one sequence ends is
# how that crate and the replay passes reach different answers about the same bytes.
#
# The ban is on the two function NAMES rather than on the ranges: 0x40..=0x7E is the ECMA-48 final
# byte and appears in the shared scanner itself, but nothing walks a sequence without defining
# where it stops.
if ! spells 'pub fn parse_csi' rust/slopdesk-sanitize/src/vtscan.rs > /dev/null; then
  fail "rust/slopdesk-sanitize/src/vtscan.rs lost parse_csi — it is the one escape grammar"
fi
if ! spells 'use slopdesk_sanitize::vtscan' rust/slopdesk-altscreen/src/lib.rs > /dev/null; then
  fail "rust/slopdesk-altscreen stopped reading the one escape grammar — a fifth copy drifts"
fi
# Candidates first, comment-strip only for those — see the width table's loop above.
while IFS= read -r owner; do
  [[ -z "${owner}" || "${owner}" == rust/slopdesk-sanitize/src/vtscan.rs ]] && continue
  if spells 'fn (parse_csi|string_sequence_end)' "${owner}" > /dev/null 2>&1; then
    fail "${owner} defines its own escape scanner — slopdesk-sanitize::vtscan is the one"
  fi
done < <(grep -lE 'fn (parse_csi|string_sequence_end)' rust/*/src/*.rs rust/*/src/*/*.rs 2> /dev/null || true)
# And the SIXTH copy, which was in Swift and on the INPUT path. `SyncInputByteFilter` hand-rolled
# both walks under a "mirror, don't share" comment, deciding which client→host bytes get mirrored
# into a sibling pane. A disagreement there does not merely render wrong: the bytes it lets through
# are typed into another shell, and the next mirrored `↵` runs them.
SWIFT_SYNC_INPUT=Sources/SlopDeskWorkspaceCore/Workspace/Store/SyncInputByteFilter.swift
if hit=$(spells 'func (parseCSI|stringSequenceEnd)|struct CSISequence|0x3F\)\.contains' "${SWIFT_SYNC_INPUT}"); then
  fail "${hit} walks escapes in Swift again — slopdesk-sanitize::syncinput owns the input filter"
fi
if ! spells 'slopdesk_sync_input_keyboard_only' "${SWIFT_SYNC_INPUT}" > /dev/null; then
  fail "${SWIFT_SYNC_INPUT} no longer asks the door — the sync-input filter is one implementation"
fi
printf 'check-supervisor: one grammar for where an escape ends, and six copies is not it.\n'

# ── One rule for what a pane's DIRECTORY is, and what it is called ─────────────────────────────
# `looksLikeTransientPluginCwd` guards fourteen Swift call sites — every sink that can poison the
# directory a split or a relaunch inherits — and `looks_like_transient_plugin_cwd` guards the Rust
# `tab_ordering` that sorts the same panes into project sections. Both were live, in both languages,
# neither reading the other: the sinks and the ordering could disagree about which directory is
# poison, and a sidebar row could disagree with its own section header about a folder's name.
SWIFT_PANE_SPEC=Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift
if hit=$(spells 'contains\("---"\)|hasSuffix\("/"\)|split\(separator: "/"\)\.last' "${SWIFT_PANE_SPEC}"); then
  fail "${hit} classifies a cwd in Swift again — slopdesk-workspace::PaneSpec owns both rules"
fi
for entry in 'slopdesk_ws_transient_plugin_cwd' 'slopdesk_ws_cwd_display_name'; do
  if ! spells "${entry}" "${SWIFT_PANE_SPEC}" > /dev/null; then
    fail "${SWIFT_PANE_SPEC} no longer asks ${entry} — the cwd rules are one implementation"
  fi
done
printf 'check-supervisor: one rule for a pane directory, and one name for it.\n'

# ── And ONE encoder for the screend frame ──────────────────────────────────────────────────────
# `docs/DECISIONS.md` recorded in stage 17 that each protocol's client end moves into Rust, so the
# round trip becomes a TEST rather than an agreement two files keep by review. dropd's Swift
# original was deleted in that change; screend's was not, and `ScreenProtocol.swift` went on
# hand-writing the same frame for a whole stage afterwards. The two had already diverged on an
# over-long detect label — Swift threw where Rust truncated.
SWIFT_SCREEN_PROTOCOL=Sources/SlopDeskScreen/ScreenProtocol.swift
if hit=$(spells 'func appendBigEndian|truncatingIfNeeded: value|UInt16\(clamping: paneBytes' "${SWIFT_SCREEN_PROTOCOL}"); then
  fail "${hit} lays out the screend frame in Swift again — slopdesk-screenwire owns every layout"
fi
for entry in 'slopdesk_screen_encode_request' 'slopdesk_screen_encode_detect_payload' 'slopdesk_screen_reply_status'; do
  if ! spells "${entry}" "${SWIFT_SCREEN_PROTOCOL}" > /dev/null; then
    fail "${SWIFT_SCREEN_PROTOCOL} no longer asks ${entry} — the screend wire is one implementation"
  fi
done
# Both ends stay in ONE crate, which is what makes the round trip a test rather than two files
# agreeing. Split them and the property the stage-17 ruling bought is gone.
for half in 'pub fn encode_request' 'pub fn decode_request' 'pub fn encode_reply' 'pub fn decode_reply'; do
  if ! spells "${half}" "${RUST_SCREEN_PROTOCOL}" > /dev/null; then
    fail "${RUST_SCREEN_PROTOCOL} lost '${half}' — both ends live together so the round trip is a test"
  fi
done
printf 'check-supervisor: one encoder for the screend frame, and both its ends in one crate.\n'

# ── The scrcpy stream is reassembled ONCE, and not in Swift ────────────────────────────────
# The bridge relays the device's stream verbatim, so nothing in Rust had ever read it and the whole
# decoder sat in Swift — a stateful reassembler over bytes a DEVICE wrote, on the per-frame path,
# whose own comment admitted it copied the buffer remainder on every message. Stage 17's rule puts a
# protocol's client end in the crate that owns the protocol, and `slopdesk-androidd` owns scrcpy's
# dialect. Nothing here may grow a second reader of that wire.
SWIFT_ANDROID_STREAM=Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift
if hit=$(spells 'func readUInt32|private mutating func take|maximumPacketSize|headerSize = |sessionFlag|keyFrameFlag' "${SWIFT_ANDROID_STREAM}"); then
  fail "${hit} frames the scrcpy stream in Swift again — slopdesk-androidd owns the framing"
fi
# The Annex-B walk is `slopdesk-video`'s, beside the AVCC walker that is its other half: the two
# framings carry the SAME NAL units, and the HEVC type reading is spelled out once there.
if hit=$(spells 'codeLength|starts\.append|first & 0x1F|first >> 1' "${SWIFT_ANDROID_STREAM}"); then
  fail "${hit} walks Annex-B in Swift again — slopdesk_video::annexb owns both start-code lengths"
fi
for entry in 'slopdesk_android_stream_new' 'slopdesk_android_stream_free' 'slopdesk_android_stream_append' \
  'slopdesk_android_stream_next' 'slopdesk_android_stream_decodable_codec' 'slopdesk_annexb_split' \
  'slopdesk_annexb_parameter_sets' 'slopdesk_annexb_to_avcc'; do
  if ! spells "${entry}" "${SWIFT_ANDROID_STREAM}" > /dev/null; then
    fail "${SWIFT_ANDROID_STREAM} no longer asks ${entry} — the scrcpy stream is one implementation"
  fi
done
# `free` without `new` is a leak per mirror session; `new` without `free` is the same bug read the
# other way. Both names above, and the handle held by a CLASS — a struct would copy the pointer.
if ! spells 'final class AndroidStreamParser' "${SWIFT_ANDROID_STREAM}" > /dev/null; then
  fail "${SWIFT_ANDROID_STREAM}: the parser stopped being a class — a copied handle is a double free"
fi
# Both start-code lengths, in the crate that owns them. Handling only the four-byte form does not
# fail loudly: it yields NAL units with a start code embedded, which decode as corruption.
RUST_ANNEXB=rust/slopdesk-video/src/annexb.rs
for half in 'pub fn split_ranges' 'pub fn to_avcc' 'pub fn h264_parameter_sets' 'pub fn h265_parameter_sets'; do
  if ! spells "${half}" "${RUST_ANNEXB}" > /dev/null; then
    fail "${RUST_ANNEXB} lost '${half}' — the Annex-B walk is one implementation"
  fi
done
printf 'check-supervisor: one reader for the scrcpy stream, and one walk over Annex-B.\n'

# ── And ONE writer for the scrcpy control channel ──────────────────────────────────────────
# scrcpy publishes no wire specification — its own documentation says the protocol is defined by the
# unit tests on both sides — so every layout was transcribed by hand, and the Swift copy laid each
# field out with a local `appendBigEndian`: the same idiom already banned for the screend frame.
SWIFT_ANDROID_CONTROL=Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift
if hit=$(spells 'mutating func appendBigEndian|appendPosition|truncatingIfNeeded:|func truncateUTF8|FixedPoint\(' "${SWIFT_ANDROID_CONTROL}"); then
  fail "${hit} lays out a scrcpy control message in Swift again — slopdesk-androidd owns every layout"
fi
if ! spells 'slopdesk_android_control_encode' "${SWIFT_ANDROID_CONTROL}" > /dev/null; then
  fail "${SWIFT_ANDROID_CONTROL} no longer asks slopdesk_android_control_encode — one implementation"
fi
# THE invariant this protocol has. The bridge gives the client ONE full-duplex connection, and
# scrcpy's three device→client messages are all REPLIES: to GET_CLIPBOARD, to a SET_CLIPBOARD with a
# non-zero sequence, or to UHID. Send one and the device writes a clipboard message into a stream the
# client is parsing as H.264. So those four types have no variant to name, on either side.
RUST_ANDROID_CONTROL=rust/slopdesk-androidd/src/control.rs
# `spells` strips `//` lines, so this reads DECLARATIONS and not the prose that explains why the
# four are absent — which is the whole reason that prose can stay.
if hit=$(spells 'GET_CLIPBOARD|Uhid' "${RUST_ANDROID_CONTROL}"); then
  fail "${hit} names a reply-bearing control type — a device reply lands inside the video stream"
fi
# The sequence is a literal zero in the encoder, not a parameter with a default anyone can pass.
if ! spells '0_u64\.to_be_bytes\(\)' "${RUST_ANDROID_CONTROL}" > /dev/null; then
  fail "${RUST_ANDROID_CONTROL}: SET_CLIPBOARD's sequence stopped being the constant zero"
fi
# The bodiless set is closed on BOTH sides: a Swift enum with four cases, a Rust enum with four
# variants. An open `UInt8` on either would put GET_CLIPBOARD one literal away.
if ! spells 'enum AndroidBodilessMessage: UInt8' "${SWIFT_ANDROID_CONTROL}" > /dev/null; then
  fail "${SWIFT_ANDROID_CONTROL}: the bodiless messages stopped being a closed enum"
fi
# ── A. The scrcpy control encoder does not MEASURE before it FILLS ─────────────────────────────
# It used to call the door twice for every message — once with a null output to learn the length,
# once to fill — which ran the far-side encode twice for an answer that is a CONSTANT on the six
# arms that carry no body. docs/55 §4 is explicit that a short buffer leaves the output untouched
# and still reports the true length, so the guess-then-retry shape is the supported one and the
# probe was pure loss. Measured against a stand-in door carrying the real encoder's work
# (24 ns/message, measured in slopdesk-androidd): 320 ns/message before, 205 ns after — on the
# path `AndroidScreenNSView.scrollWheel` drives at 60–120 Hz, two to four messages per re-grip.
#
# BREAK-TEST 2026-08-22: clean on the live tree; FIRES when a
#   `slopdesk_android_control_encode(&request, text.baseAddress, text.count, nil, 0)` line is
#   appended to the file. Verified with the real `spells` semantics.
if hit=$(spells ', nil, 0\)' "${SWIFT_ANDROID_CONTROL}"); then
  fail "${hit} probes the control encoder with a null output again — docs/55 §4 says a short buffer writes NOTHING, so guess and retry"
fi

# ── B. …and the guess it tries first is named ──────────────────────────────────────────────────
# Not a shared constant — nothing is wrong if the door outgrows it — but a named one is what stops
# the retry quietly becoming the common path when somebody sizes it at 8.
#
# BREAK-TEST 2026-08-22: present on the live tree; FIRES when the declaration is renamed.
if ! spells 'private static let firstGuessBytes' "${SWIFT_ANDROID_CONTROL}" > /dev/null; then
  fail "${SWIFT_ANDROID_CONTROL}: the first-guess buffer stopped being a named constant"
fi
printf 'check-supervisor: one writer for the scrcpy control channel, and no reply-bearing type.\n'

# ── And ONE grammar per device console, neither of them in Swift ───────────────────────────────
# Two files parsed a device's own log output — `logcat -v time` and `log stream --style compact` —
# over text a program on the far side of a device wrote, thousands of lines a minute, on the socket
# read path. Both asked `Character.isNumber`/`isUppercase`, which are Unicode property lookups per
# grapheme cluster, and both built four `String`s a row out of a `String` the row was a slice of.
# They were also the SAME parser twice: four fields, the same verbatim fallback, one field name
# apart. `slopdesk-devicelog` owns both grammars and one `DeviceLogLine` carries both consoles' rows.
SWIFT_DEVICE_LOG=Sources/SlopDeskDevicePanels/Shared/DeviceLogLine.swift
if hit=$(spells 'func isDate|func isTime|func isPriority|func isSeverityToken|isNumber|isUppercase|allSatisfy|firstIndex\(of:|drop\(while:' "${SWIFT_DEVICE_LOG}"); then
  fail "${hit} walks a device log line in Swift again — slopdesk-devicelog owns both grammars"
fi
for entry in 'slopdesk_logcat_parse' 'slopdesk_unified_log_parse'; do
  if ! spells "${entry}" "${SWIFT_DEVICE_LOG}" > /dev/null; then
    fail "${SWIFT_DEVICE_LOG} no longer asks ${entry} — the console grammars are one implementation"
  fi
done
# ── C. A device log line is BORROWED by the door, never copied for it ──────────────────────────
# The two console doors answer byte offsets INTO THE CALLER'S OWN LINE — that is the whole reason
# nothing crosses back but six numbers and a severity. Copying the line into a fresh [UInt8] first
# threw that away: a heap buffer per row, on a path a booting device drives at hundreds of rows a
# second, holding bytes the String was already storing contiguously. Measured (swiftc -O, stand-in
# door): 154 ns/row before, 94 ns after — 39% of the marshalling, and the parse behind it is 56 ns.
#
# BREAK-TEST 2026-08-22: clean on the live tree; the ban FIRES when `let bytes = Array(text.utf8)`
#   is appended, and the presence check FIRES when `text.withUTF8` is renamed.
if hit=$(spells 'Array\(text\.utf8\)' "${SWIFT_DEVICE_LOG}"); then
  fail "${hit} copies a log line to lend it to a door that answers offsets into that same line — withUTF8 lends the storage"
fi
if ! spells 'text\.withUTF8' "${SWIFT_DEVICE_LOG}" > /dev/null; then
  fail "${SWIFT_DEVICE_LOG}: the line stopped being lent to the door — see the parse's own comment"
fi
# The two structs are gone and must stay gone: they were one type spelled twice, and a second one
# would immediately grow a second parse to fill it.
for revived in 'struct AndroidLogLine' 'struct SimulatorLogLine'; do
  if hit=$(spells "${revived}" Sources/SlopDeskDevicePanels/Android/*.swift \
    Sources/SlopDeskDevicePanels/Simulator/*.swift Sources/SlopDeskDevicePanels/Shared/*.swift \
    Sources/SlopDeskPhoneUI/Panel/Android/*.swift Sources/SlopDeskPhoneUI/Panel/Simulator/*.swift \
    Sources/SlopDeskPhoneUI/Panel/*.swift); then
    fail "${hit} brought back ${revived} — one console row serves both device panels"
  fi
done
# One INK SCALE, six cases, and each console view switches over all of it. Two enums here is how the
# two parsers grew apart the first time.
if ! spells 'enum DeviceLogSeverity: UInt8' "${SWIFT_DEVICE_LOG}" > /dev/null; then
  fail "${SWIFT_DEVICE_LOG}: the shared severity scale stopped being one closed enum"
fi
# The spans cross a C ABI and slice the caller's own buffer, so the Swift side clamps rather than
# trusts. Without the clamp a door bug is a TRAP in the client, not a wrong row.
if ! spells 'Swift\.min\(Int\(offset\), bytes\.count\)' "${SWIFT_DEVICE_LOG}" > /dev/null; then
  fail "${SWIFT_DEVICE_LOG}: a span from the door is sliced unclamped — that is a trap, not a bad row"
fi
# Both halves of the crate, so neither grammar can be quietly folded into the other.
for module in logcat unified; do
  if ! spells 'pub fn parse' "rust/slopdesk-devicelog/src/${module}.rs" > /dev/null; then
    fail "rust/slopdesk-devicelog/src/${module}.rs lost its parse — the two grammars stay apart"
  fi
done
printf 'check-supervisor: one grammar per device console, and neither of them in Swift.\n'

# ── And ONE spelling of the superd control frame ──────────────────────────────────────────────
# superd writes these frames and hostd reads them, and the LAYOUT was written out twice: superd's
# `frame.rs` in Rust and `SupervisorFrame.swift` in Swift, each module's own doc calling the other a
# mirror. Two hand-written spellings of one byte layout, agreeing by inspection, in the one place
# where a disagreement shows up as a DESYNCHRONISED SOCKET rather than as a wrong value.
# `slopdesk-superwire` is the spelling; each side keeps only its own syscalls, because the
# descriptor has to land in the reading process.
if hit=$(spells 'tagPlain: UInt8 = |tagOutput: UInt8 = |maximumBodyBytes = [0-9]|Int\(header\[0\]\)|<< 24|nameLength = Int' "${SWIFT_FRAME}"); then
  fail "${hit} spells the superd frame layout in Swift again — slopdesk-superwire owns it"
fi
for entry in 'slopdesk_supervisor_tag' 'slopdesk_supervisor_is_known_tag' 'slopdesk_supervisor_header' \
  'slopdesk_supervisor_body_length' 'slopdesk_supervisor_parse_output' \
  'slopdesk_supervisor_parse_pane_json' 'slopdesk_supervisor_max_body'; do
  if ! spells "${entry}" "${SWIFT_FRAME}" > /dev/null; then
    fail "${SWIFT_FRAME} no longer asks ${entry} — the framing is one implementation"
  fi
done
# The same for the daemon: superd must READ the shared layout rather than restate it, which is what
# it did for the whole of the file's life before this.
if ! spells '^slopdesk-superwire = ' rust/slopdesk-superd/Cargo.toml > /dev/null; then
  fail "rust/slopdesk-superd dropped slopdesk-superwire — the frame layout would be spelled twice again"
fi
if hit=$(spells 'const TAG_PLAIN|const MAX_BODY_BYTES|pub fn parse_output|pub fn parse_sniff' rust/slopdesk-superd/src/frame.rs); then
  fail "${hit} re-declares the frame layout inside superd — it belongs to slopdesk-superwire"
fi
# The SYSCALLS deliberately stay per side: superd hands away a descriptor it owns through `nix`, and
# hostd receives one through its own passing code. If either ever grew a door, this is where that
# decision gets argued rather than slipped in.
for kept in 'FileDescriptorPassing.receive' 'FileDescriptorWrite.all' 'FileDescriptorRead.exactly'; do
  if ! spells "${kept}" "${SWIFT_FRAME}" > /dev/null; then
    fail "${SWIFT_FRAME} lost ${kept} — the SCM_RIGHTS lane stays on this side on purpose"
  fi
done
# A span from the door slices this side's own buffer, so it is clamped rather than trusted.
if ! spells 'Swift\.min\(Int\(offset\), body\.count\)' "${SWIFT_FRAME}" > /dev/null; then
  fail "${SWIFT_FRAME}: a span from the door is sliced unclamped — that is a trap, not a bad frame"
fi
printf 'check-supervisor: one spelling of the superd control frame, and the syscalls stay per side.\n'

# ── One regex engine meets the untrusted rows, and it does not backtrack ───────────────────────
# Hint Mode ran ten compiled NSRegularExpressions over rows a remote program wrote, bridged through
# NSString, mapping columns with a third cell walk. Two things were wrong with that and this pins
# both: the columns now come from the link scan's clustering, and the user's `hint-pattern` — a
# regex a human pasted in, run against text an attacker influences — now runs on a finite automaton
# whose match time is linear in the row. A backtracking engine here is a hang the user cannot
# escape, so the Swift face must stay a marshaller.
SWIFT_HINT=Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift
if hit=$(spells 'NSRegularExpression|NSString|force_try|displayCellWidth|boundedPrefix|overlapsAccepted' "${SWIFT_HINT}"); then
  fail "${hit} scans for hint targets in Swift again — slopdesk-rowscan owns the scan"
fi
for entry in 'slopdesk_hint_scan' 'slopdesk_hint_scan_target' 'slopdesk_hint_scan_take_arena'; do
  if ! spells "${entry}" "${SWIFT_HINT}" > /dev/null; then
    fail "${SWIFT_HINT} no longer asks ${entry} — the hint scan is one implementation"
  fi
done
# The LABELS deliberately stay Swift: list arithmetic over 26 letters, no text, no untrusted input.
# If they ever grow a door, this line is where that decision gets argued rather than slipped in.
for kept in 'static func labels' 'static func filter'; do
  if ! spells "${kept}" "${SWIFT_HINT}" > /dev/null; then
    fail "${SWIFT_HINT} lost ${kept} — the label arithmetic stays here on purpose (docs/55)"
  fi
done
if ! spells '^regex = ' rust/slopdesk-rowscan/Cargo.toml > /dev/null; then
  fail "rust/slopdesk-rowscan dropped the regex crate — a hand-written or backtracking matcher is the hang"
fi
if spells '^regex = ' rust/slopdesk-terminal/Cargo.toml > /dev/null; then
  fail "rust/slopdesk-terminal took an external dependency — that crate is on the PTY hot path"
fi
printf 'check-supervisor: one regex engine over the untrusted rows, and it does not backtrack.\n'

# ── ⌘F is the second untrusted pattern, and it runs on the same engine ─────────────────────────
# Find-in-terminal took a pattern the user retypes on every keystroke and ran it, backtracking,
# over the whole scrollback. Same hazard as Hint Mode, reached far more often. The scan is
# slopdesk-rowscan::find now, and the columns it answers in are UTF-16 units because that is what
# the highlighting surface indexes — the door does not convert, so neither may this face.
SWIFT_FIND=Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift
if hit=$(spells 'NSRegularExpression|NSString|NSRange|NSNotFound|CharacterSet' "${SWIFT_FIND}"); then
  fail "${hit} scans for matches in Swift again — slopdesk-rowscan::find owns the scan"
fi
if ! spells 'slopdesk_find_matches' "${SWIFT_FIND}" > /dev/null; then
  fail "${SWIFT_FIND} no longer asks slopdesk_find_matches — the find scan is one implementation"
fi
if ! spells 'pub fn matches' rust/slopdesk-rowscan/src/find.rs > /dev/null; then
  fail "rust/slopdesk-rowscan/src/find.rs lost matches() — ⌘F has nowhere to ask"
fi
printf 'check-supervisor: the find bar asks the same non-backtracking engine.\n'

# ── `wait --until` runs an agent's pattern on the PTY read loop, so it may not backtrack ───────
# The third and worst of the untrusted-pattern sites: the pattern is an agent's, the text is
# whatever holds the far side of the PTY, and the match runs on the thread every pane's bytes come
# through. A pathological match there stalls the whole host, not one window. The carry, the overlap
# window and the accumulator's cap are the crate's now — a second copy of any of them in Swift is
# two implementations of an incremental scan, which is how the strip and the holdback drifted before.
# `ANSIStripper` is NOT banned here: the read/output verbs in the same file strip a finished string
# through the same door, which is the one implementation, not a second one.
SWIFT_WAIT=Sources/SlopDeskHost/AgentControlListener.swift
if hit=$(spells 'NSRegularExpression|maxCarryBytes|overlapWindow' "${SWIFT_WAIT}"); then
  fail "${hit} scans the wait stream in Swift again — slopdesk-rowscan::waituntil owns the scan"
fi
for entry in 'slopdesk_wait_scan_new' 'slopdesk_wait_scan_ingest' 'slopdesk_wait_scan_free'; do
  if ! spells "${entry}" "${SWIFT_WAIT}" > /dev/null; then
    fail "${SWIFT_WAIT} no longer asks ${entry} — the wait scan is one implementation"
  fi
done
if ! spells '^slopdesk-sanitize = ' rust/slopdesk-rowscan/Cargo.toml > /dev/null; then
  fail "rust/slopdesk-rowscan dropped slopdesk-sanitize — the wait scan would need its own stripper"
fi
printf 'check-supervisor: the wait stream is scanned once, off the read loop critical path.\n'

# ── One vocabulary of secret shapes, for the title and for the paste ───────────────────────────
# Ten compiled NSRegularExpressions masked credentials out of untrusted titles, and a second Swift
# heuristic decided whether typing the clipboard would leak one. Both read the SAME shapes, and the
# paste guard reached the redactor to say so — one rule with two callers, spelled twice.
SWIFT_REDACTOR=Sources/SlopDeskWorkspaceCore/Workspace/Domain/SecretRedactor.swift
if hit=$(spells 'NSRegularExpression|AKIA|ghp_|xox|AIza' "${SWIFT_REDACTOR}"); then
  fail "${hit} compiles the secret shapes in Swift — slopdesk-workspace::secrets scans them"
fi
SWIFT_PASTE=Sources/SlopDeskWorkspaceCore/Video/SecretPasteClassifier.swift
if hit=$(spells 'shannonEntropy|charClassCount|log2' "${SWIFT_PASTE}"); then
  fail "${hit} measures entropy in Swift — the crate sums it in a deterministic order"
fi
for door in slopdesk_ws_redact_secrets slopdesk_ws_paste_risk slopdesk_ws_looks_secret; do
  if ! spells "${door}" "${SWIFT_REDACTOR}" "${SWIFT_PASTE}" > /dev/null; then
    fail "${door} has no Swift caller — the faces must ask the door, not restate it"
  fi
done
swift_risks=$(sed -n '/^public enum PasteRisk/,/^}/p' "${SWIFT_PASTE}" | grep -cE '^    case ') || true
rust_risks=$(grep -oE 'pub const ALL: \[Self; [0-9]+\]' rust/slopdesk-workspace/src/secrets.rs | grep -oE '[0-9]+') || true
if [[ "${swift_risks}" != "${rust_risks}" ]]; then
  fail "PasteRisk has ${swift_risks} Swift cases and ${rust_risks} Rust ones — the discriminant that crosses the ABI is now wrong (docs/55)"
fi
printf 'check-supervisor: one vocabulary of secret shapes, for the title and for the paste.\n'

# ── What a fresh install carries is spelled once ───────────────────────────────────────────────
# The product defaults sat in a Swift `init`'s default arguments AND in the config crate's own test
# fixture, six values apiece with nothing connecting the two lists. A fixture that restates the
# other language's constants is the cross-language mirror CLAUDE.md bans, and the two colours were
# already the same literal in both files.
SWIFT_TERMPREFS=Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift
if hit=$(spells '22212C|F8F8F2|"SF Mono"|= 10000' "${SWIFT_TERMPREFS}"); then
  fail "${hit} spells a factory default in Swift — slopdesk-terminal::config carries them"
fi
if ! spells 'slopdesk_terminal_factory_text' "${SWIFT_TERMPREFS}" > /dev/null; then
  fail "${SWIFT_TERMPREFS} stopped asking the door — the defaults are read, not retyped"
fi
if ! spells 'pub const fn factory' rust/slopdesk-terminal/src/config.rs > /dev/null; then
  fail "rust/slopdesk-terminal/src/config.rs lost its factory — the fixture and the app read one answer"
fi
if [[ $(grep -c 'FACTORY_' rust/slopdesk-terminal/src/config.rs) -lt 7 ]]; then
  fail "rust/slopdesk-terminal/src/config.rs lost a FACTORY_ constant — each default is named once"
fi
printf 'check-supervisor: what a fresh install carries is spelled once.\n'

# ── One base64, and one secret notation ────────────────────────────────────────────────────────
# Three hand-written base64 codecs lived in this tree — an encoder and a decoder inside superd
# agreeing with each other by inspection, and a third pair in the wire's state file — each carrying
# a copy of the standard alphabet and its own reading of what padding is legal. A codec that is
# "small enough to read" is still one implementation per copy. The `base64` crate is the one
# implementation now, and the alphabet is what gives a fourth copy away.
if hit=$(grep -rlE 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789\+/' rust/*/src 2> /dev/null); then
  printf '%s\n' "${hit}" >&2
  fail "a hand-written base64 alphabet is back — the base64 crate is the codec (docs/DECISIONS.md, 2026-08-15)"
fi
for crate in slopdesk-wire slopdesk-superd; do
  if ! grep -q '^base64 = ' "rust/${crate}/Cargo.toml"; then
    fail "rust/${crate} dropped the base64 crate — it encodes or decodes base64 and must not spell one"
  fi
done
# The secret shapes are regular expressions in the notation the world publishes them in, not a byte
# loop with its own reading of `\b`. The scanner they replaced was wrong twice during its own port.
if ! grep -q '^regex = ' rust/slopdesk-workspace/Cargo.toml; then
  fail "rust/slopdesk-workspace dropped the regex crate — secrets.rs must not hand-roll the shapes again"
fi
rust_shapes=$(grep -oE 'const PATTERNS: \[\(&str, Action\); [0-9]+\]' rust/slopdesk-workspace/src/secrets.rs | grep -oE '[0-9]+') || true
if [[ "${rust_shapes}" != "11" ]]; then
  fail "slopdesk-workspace::secrets carries ${rust_shapes} shapes, not the 11 the Swift redactor compiled"
fi
printf 'check-supervisor: one base64 codec, and the secret shapes stay regular expressions.\n'

# ── One reading of `\xNN` and `%NN`, wherever the bytes came from ──────────────────────────────
# The shim's `133;E` escaping was inverted in `slopdesk-sanitize::distill` AND in superd's
# segmenter, one spelling it `(high << 4) | low` and the other `high * 16 + low`; percent-decoding
# was byte-for-byte duplicated between superd's OSC 7 reader and the client's link scanner; and
# `hex_nibble` had four copies, three of them re-deriving what `char::to_digit(16)` already knows.
# `slopdesk-sanitize::escape` is the one reading now — the crate that already declares itself the
# home of the shared byte scanners.
escape_strays=$(grep -rlE 'fn (hex_nibble|hex_value|unescape_command|remove_percent_encoding)' \
  rust/*/src --exclude-dir=target 2> /dev/null | grep -v 'slopdesk-sanitize/src/escape.rs' || true)
if [[ -n "${escape_strays}" ]]; then
  printf '%s\n' "${escape_strays}" >&2
  fail "an escape decoder grew back outside slopdesk-sanitize::escape — one reading, whoever wrote the bytes"
fi
for crate in slopdesk-superd slopdesk-terminal; do
  if ! grep -q '^slopdesk-sanitize = ' "rust/${crate}/Cargo.toml"; then
    fail "rust/${crate} dropped slopdesk-sanitize — it decodes \\xNN or %NN and must not spell one"
  fi
done
printf 'check-supervisor: one reading of an escape, and the standard library knows a hex digit.\n'

# ── One receive buffer, and one spelling of a narrowed length ──────────────────────────────────
# The terminal decoder and the mux decoder each carried the whole streaming rule — fail-stop
# poisoning, the cursor, the 64 KiB compaction threshold, the owed compaction an eliding answer
# defers — and the two copies had ALREADY drifted three ways. `slopdesk-wire::framing` is the one
# reader; a second `deferred_compaction` field anywhere is that rule growing a third copy.
owed=$(grep -rl 'deferred_compaction' rust/*/src --exclude-dir=target 2> /dev/null | grep -v 'slopdesk-wire/src/framing.rs' || true)
if [[ -n "${owed}" ]]; then
  printf '%s\n' "${owed}" >&2
  fail "a second length-prefixed receive buffer grew back — slopdesk-wire::framing is the reader"
fi
# `truncating_uN` had fourteen copies across two crates, and four of them shared a name while two
# of those four SATURATED instead of truncating. One home each, and the name says which.
narrow=$(grep -rlE '^(pub )?(const )?fn (truncating|saturating)_u(8|16|32)\(' \
  rust/*/src --exclude-dir=target 2> /dev/null |
  grep -vE 'slopdesk-(video|wire)/src/bytes.rs|slopdesk-ffi/src/lib.rs' || true)
if [[ -n "${narrow}" ]]; then
  printf '%s\n' "${narrow}" >&2
  fail "a narrowing cast helper grew back — slopdesk-video::bytes and slopdesk-ffi's root spell them"
fi
printf 'check-supervisor: one receive buffer, and a narrowed length is spelled where it is named.\n'

# ── One arena reader, on the side that holds the buffer ───────────────────────────────────────
# `docs/55` §4c's arena convention had a write half (`TextArena::intern`) shared on the CRATE side
# from the day it was written, and nothing shared on the Swift side at all: seven reader copies in
# `slopdesk-ffi`, eleven more in Swift, and the eleven had drifted — one bounds-checked only the
# length, four answered `""` for bytes the crate's own reader repairs, and the two doors Swift
# FILLS an arena for had each written their own `intern`. `crate::arena_span`/`arena_text` and
# `ArenaText` are the one of each; a face keeps a one-line overload for its own named
# `(offset, length)` struct and calls through, it does not spell the read or the write again.
arena_rust=$(grep -rl 'from_utf8_lossy(arena' rust/slopdesk-ffi/src --exclude-dir=target 2> /dev/null |
  grep -v 'slopdesk-ffi/src/lib.rs' || true)
if [[ -n "${arena_rust}" ]]; then
  printf '%s\n' "${arena_rust}" >&2
  fail "an arena reader grew back in slopdesk-ffi — crate::arena_text is the read half of §4c"
fi
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
arena_swift=$(spells 'String\(decoding: UnsafeRawBufferPointer\(rebasing:|UInt32\(clamping: arena.count\)|arena\[start\.\.<end\]|String\(bytes: arena' \
  $(repo_files 'Sources/**/*.swift' | grep -v 'Sources/SlopDeskArena/') 2> /dev/null || true)
if [[ -n "${arena_swift}" ]]; then
  printf '%s\n' "${arena_swift}" >&2
  fail "an arena reader or interner grew back in a Swift face — ArenaText is the one of each"
fi
for target in SlopDeskProtocol SlopDeskVideoProtocol SlopDeskWorkspaceModel SlopDeskFileTransfer \
  SlopDeskWorkspaceCore SlopDeskCLICore SlopDeskVideoHost SlopDeskVideoClient; do
  if ! grep -q 'SlopDeskArena' <<< "$(grep -A 24 "name: \"${target}\"" Package.swift)"; then
    fail "${target} dropped SlopDeskArena — it crosses §4c's convention and must not spell it"
  fi
done
printf 'check-supervisor: one arena reader and one interner, on the side that holds the buffer.\n'

# ── One NWConnection byte channel, for both lanes that need one ────────────────────────────────
# The inspector's event lane and PATH-4's file transfer each spelled the SAME actor — the
# `onTermination` cancel, the `cancel()` beside every `finish()`, the idempotent `start()`. Three
# separate fd-leak fixes, each of which had to be made twice or the copies drift. `SlopDeskNet` is
# the actor; a lane keeps its own protocol (its vocabulary) and one conformance line.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
channels=$(spells 'connection\.receive\(minimumIncompleteLength' \
  $(repo_files 'Sources/**/*.swift' | grep -v 'Sources/SlopDeskNet/') 2> /dev/null || true)
if [[ -n "${channels}" ]]; then
  printf '%s\n' "${channels}" >&2
  fail "a second NWConnection byte channel grew back — SlopDeskNet::NWByteChannel is the one lane"
fi
for target in SlopDeskInspector SlopDeskFileTransfer; do
  if ! grep -q 'SlopDeskNet' <<< "$(grep -A 24 "name: \"${target}\"" Package.swift)"; then
    fail "${target} dropped SlopDeskNet — it dials a byte channel and must not spell one"
  fi
done
printf 'check-supervisor: one NWConnection byte channel, and a lane keeps only its vocabulary.\n'

# ── One write(2)-until-done loop, and the reaction stays at the call site ──────────────────────
# SIX copies: the agent control listener, the client control server, the mux channel session,
# `slopdesk-client`'s stdout path, the supervisor's frame writer and the screend client. Every one
# of them folded in EINTR-is-a-retry and short-writes-are-normal, and four dropped the failure while
# two threw. `SlopDeskTTY::FileDescriptorWrite` is the loop; the DIFFERENCE — drop or report — is a
# real contract and survives as the outcome each caller switches on.
# The comma is load-bearing. `write(fd, buffer, count)` is the syscall; `write(socket: fd, body:)`
# is `SupervisorFrame`'s own frame writer, whose argument LABEL happens to be the same word and
# whose `writeAll` delegates to `FileDescriptorWrite.all` exactly as this rule asks. The first
# spelling of this pattern could not tell them apart, and never had to: both files are unstaged, so
# the index this check used to read did not contain them.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
writes=$(spells '(Darwin\.)?write\((fd|socket),' \
  $(repo_files 'Sources/**/*.swift' | grep -v 'Sources/SlopDeskTTY/') 2> /dev/null || true)
if [[ -n "${writes}" ]]; then
  printf '%s\n' "${writes}" >&2
  fail "a raw write(fd) grew back outside SlopDeskTTY — FileDescriptorWrite.all is the write loop"
fi
# The mirror: `readExactly` was the supervisor's frame reader and the screend client, same loop and
# same must-report contract spelled with two error types.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
reads=$(spells 'func readExactly' \
  $(repo_files 'Sources/**/*.swift' | grep -v 'Sources/SlopDeskTTY/') 2> /dev/null |
  grep -vE 'SupervisorFrame|ScreenClient' || true)
if [[ -n "${reads}" ]]; then
  printf '%s\n' "${reads}" >&2
  fail "a third readExactly grew back — FileDescriptorRead.exactly is the loop"
fi
printf 'check-supervisor: one write(2) and one read-exactly, and drop-or-report stays with the caller.\n'

# ── One drop-zone shape, drawn and hit-tested ─────────────────────────────────────────────────
# The overlay DRAWS the five blobs and the receiver HIT-TESTS against them. A second copy of the
# proportions anywhere lets the hit region slide off the blob, and the drop lands in a zone the user
# was not pointing at — silently, because both halves still look right on screen. So `PaneDropZone-
# Layout` may only forward, and the fractions live once in `slopdesk_workspace::drop_zone`.
for door in slopdesk_drop_zone_shape slopdesk_drop_zone_at; do
  if ! grep -q "${door}" Sources/SlopDeskWorkspaceCore/Workspace/Domain/Drop/PaneDropZoneLayout.swift; then
    fail "PaneDropZoneLayout stopped calling ${door} — a drop lands where it is not drawn"
  fi
done
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
drop_dupes=$(spells '0\.46|0\.72|0\.26' $(repo_files 'Sources/SlopDeskPhoneUI/Pane/PaneDrop*.swift') 2> /dev/null || true)
if [[ -n "${drop_dupes}" ]]; then
  printf '%s\n' "${drop_dupes}" >&2
  fail "a drop-zone proportion grew back in the overlay — rust/slopdesk-workspace/src/drop_zone.rs owns them"
fi
printf 'check-supervisor: the drop overlay draws and hit-tests one shape.\n'

# ── One dwell, and the top edge stays the remote's ────────────────────────────────────────────
# The dwell that decides who owns the top edge in borderless fullscreen lives in
# `slopdesk_workspace::chrome`. A Swift copy of the phase machine would be a second answer to "may
# the local menu bar take this click", and the wrong one steals a click from the remote menu bar —
# which reads as a dropped click, not as a policy bug.
if ! grep -q 'slopdesk_ws_dwell_update' Sources/SlopDeskClientCore/App/BorderlessDwellGate.swift; then
  fail "BorderlessDwellGate stopped calling slopdesk_ws_dwell_update — the top edge has two owners"
fi
if spells 'dwellSeconds *[:=] *0\.5|revealZonePoints *[:=] *2\b' Sources/SlopDeskClientCore/App/BorderlessDwellGate.swift > /dev/null 2>&1; then
  fail "a dwell distance grew back in Swift — rust/slopdesk-settings/src/chrome.rs owns them"
fi
printf 'check-supervisor: one dwell decides who owns the top edge.\n'

# ── One pixel→weight conversion, and the seam owns it ─────────────────────────────────────────
# `Δweight = Δpixel / parent_span * flex_sum` is the inverse of the partition the solver tiles with,
# so it can only be right against the seam's OWN span and flex sum. Written out anywhere else it
# takes those from whatever is in scope — which is how the seam came to trail the cursor at half
# speed. It lives on `SplitDividerHandle` now, sourced from `slopdesk_workspace::split_layout`, and
# nothing else — not a view, not a test helper — may spell the formula again.
if ! grep -q 'slopdesk_ws_divider_weight_delta' Sources/SlopDeskWorkspaceModel/Domain/Tree/SplitLayoutSolver.swift; then
  fail "SplitDividerHandle stopped calling slopdesk_ws_divider_weight_delta — the seam trails the cursor"
fi
if ! grep -q 'slopdesk_ws_divider_percents' Sources/SlopDeskWorkspaceModel/Domain/Tree/SplitLayoutSolver.swift; then
  fail "SplitDividerHandle stopped calling slopdesk_ws_divider_percents — the ratio readout has two answers"
fi
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
drag_dupes=$(spells 'Double\(span\)|/ *Double\(.*[Ss]pan\)|axisSpan|PaneMath' \
  $(repo_files 'Sources/**/*.swift' 'Tests/**/*.swift') 2> /dev/null || true)
if [[ -n "${drag_dupes}" ]]; then
  printf '%s\n' "${drag_dupes}" >&2
  fail "the pixel→weight conversion grew back in Swift — SplitDividerHandle.weightDelta is the one"
fi
printf 'check-supervisor: one pixel-to-weight conversion, and the seam owns it.\n'

# ── One cheat sheet, two layouts ──────────────────────────────────────────────────────────────
# docs/56 stage D's first surface: the Mac's ⌘/ sheet is an `NSPanel` and the phone's is a native
# `.sheet`, and neither is allowed to know the other exists. What they may not do is each spell out
# the table — so the rows, the glyph gating and the column deal are `CheatSheetContent`, over
# `slopdesk_cheat_sheet_columns`. Two ways this decays, and the gate catches both: a half that stops
# reading the shared source (a second table, drifting from the dispatcher's chords), and the shared
# SwiftUI host mounting the card again (the Mac would then show it twice, over its own panel).
if ! grep -q 'slopdesk_cheat_sheet_columns' Sources/SlopDeskClientCore/Overlays/CheatSheetContent.swift; then
  fail "CheatSheetContent stopped calling slopdesk_cheat_sheet_columns — the column deal has two answers"
fi
for half in Sources/SlopDeskMacUI/Overlays/MacCheatSheetPanel.swift \
  Sources/SlopDeskPhoneUI/Overlays/KeyboardCheatSheetView.swift; do
  if ! grep -q 'CheatSheetContent' "${half}"; then
    fail "${half} stopped rendering CheatSheetContent — the cheat sheet has two tables"
  fi
  if grep -q 'WorkspaceBindingRegistry' "${half}"; then
    fail "${half} reached past CheatSheetContent to the registry — the glyph gating lives in ONE place"
  fi
done
if grep -q 'KeyboardCheatSheetView' Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift; then
  fail "the shared overlay host mounts the cheat sheet again — the Mac would draw it over its own panel"
fi
printf 'check-supervisor: one cheat sheet, drawn twice and spelled once.\n'

# ── One notification card, two corners ────────────────────────────────────────────────────────
# docs/56 stage D's second surface, and the one that took the last ALWAYS-MOUNTED SwiftUI layer off
# the macOS window root. The Mac's corner is an `NSPanel` sized to the column, the phone's is an
# overlay on its own root, and what a card SAYS belongs to neither: the headline (over
# `slopdesk_ws_notify_toast_headline`), the spine budget, the mark's rung/glyph and the dwell are
# `ToastPresentation`. Three ways this decays, and the gate catches all three.
if ! grep -q 'slopdesk_ws_notify_toast_headline' Sources/SlopDeskClientCore/Overlays/ToastPresentation.swift; then
  fail "ToastPresentation stopped calling slopdesk_ws_notify_toast_headline — the headline has two answers"
fi
for half in Sources/SlopDeskMacUI/Overlays/MacToastStack.swift \
  Sources/SlopDeskPhoneUI/Overlays/ToastStackView.swift; do
  if ! grep -q 'ToastPresentation' "${half}"; then
    fail "${half} stopped reading ToastPresentation — a notification says two different things"
  fi
  # The fusion bug `TabBadgeResolver` had: a half that re-derives the phrase from the pair keys on
  # flavour alone sooner or later, and announces a finished `make` as an agent turn.
  if grep -q 'toast.source, toast.flavor' "${half}"; then
    fail "${half} re-derives the headline from (source, flavour) — that pair is resolved ONCE, in Rust"
  fi
done
# The shared host must not mount the column again: the Mac would draw a SwiftUI stack over its own
# panel, and the full-bleed host is exactly the hit-claiming mount stage D removed.
if grep -q 'ToastStackView(' Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift; then
  fail "the shared overlay host mounts the toast column again — that mount claims every hit over the split"
fi
printf 'check-supervisor: one notification card, drawn twice and spelled once.\n'

# ── The shared overlay host holds no AMBIENT layer, and the ⌃⇥ walk has two halves ────────────
# docs/56 stage D's dividend, and the reason it is a gate: an ALWAYS-MOUNTED full-bleed SwiftUI
# layer claims every hit inside its bounds, and the only way to survive that is a hit-testing flag
# someone has to keep honest. That is what `allowsHitTesting` on this file means and why it stays
# banned — a layer mounted only while its state is live needs no such flag.
#
# The ⌃⇥ CARD is NOT that hazard and is no longer forbidden here. It was, on the reading that "the
# phone has no modifier stream to open the gesture with, so a second half could never render" — which
# was about the OPENING CHORD and was never the only way in: the binding row is `Platform::Both`
# (rust/slopdesk-workspace/src/binding_rows.rs) and the palette carries the same row. The phone opened
# the gesture, `PaneRecedeScrim` veiled every pane off `store.paneSwitcher`, and nothing drew — a
# veiled workspace with no way to step, commit or cancel. So the gate is inverted: the phone's half
# must EXIST, and both halves must keep reading the shared row builder and measurements.
# Comment lines are stripped first: the file's header is where the history is RECORDED, and it has to
# be free to name what left (and what came back) without the gate reading prose as a regression.
if sed -E 's#^[[:space:]]*//.*##' Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift |
  grep -q 'allowsHitTesting'; then
  fail "the shared overlay host grew an ambient layer again — an always-mounted host eats the split's clicks"
fi
if [[ ! -e Sources/SlopDeskPhoneUI/Overlays/PaneSwitcherOverlay.swift ]]; then
  fail "the phone has no ⌃⇥ card — a gesture that veils every pane and draws nothing is a soft lockup"
fi
# The phone's card may not grow a SECOND commit door. `commitPaneSwitcher()` unwinds the follow-along
# preview before it stages focus and refuses a candidate whose pane closed under the gesture; a view
# reaching past it for `revealPaneTree` has neither guard, and both failures are silent.
if sed -E 's#^[[:space:]]*//.*##' Sources/SlopDeskPhoneUI/Overlays/PaneSwitcherOverlay.swift |
  grep -q 'revealPaneTree'; then
  fail "the phone's ⌃⇥ card commits past commitPaneSwitcher() — the preview unwind and the dead-pane refusal are its"
fi
for half in Sources/SlopDeskMacUI/Overlays/MacPaneSwitcher.swift \
  Sources/SlopDeskPhoneUI/Overlays/PaneSwitcherOverlay.swift; do
  for shared in PaneSwitcherRowsBuilder PaneSwitcherMetrics; do
    if ! grep -q "${shared}" "${half}"; then
      fail "${half} stopped reading ${shared} — the card's rows and measurements live below the view"
    fi
  done
done
printf 'check-supervisor: the overlay host holds no ambient layer, and both halves draw the ⌃⇥ walk.\n'

# ── One palette, two frameworks ───────────────────────────────────────────────────────────────
# docs/56 stage D's first MODAL surface: the Mac's ⌘⇧P is an `NSPanel` and the phone's is a paper
# card, and what a palette IS belongs to neither. `PalettePresentation`/`PaletteMetrics` carry the
# card's measurements, the pairing of ranked rows with the keyboard's index, the ✓ predicate and the
# WORKING DIRECTORY badge — the last over `slopdesk_ws_cwd_badge_path`, so a home is collapsed by ONE
# rule and never against the client's own `$HOME` (the path came off the remote host).
if ! grep -q 'slopdesk_ws_cwd_badge_path' Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift; then
  fail "PaneSpec stopped calling slopdesk_ws_cwd_badge_path — the badge's home collapse has two answers"
fi
for half in Sources/SlopDeskMacUI/Overlays/MacPalette.swift \
  Sources/SlopDeskPhoneUI/Overlays/PaletteView.swift; do
  if ! grep -q 'PalettePresentation' "${half}"; then
    fail "${half} stopped reading PalettePresentation — the two palettes would drift on the first section header"
  fi
  # The pairing is the one every half gets one off by hand: a separator takes a LINE but not a
  # selection, so a view that counted rows itself would highlight the wrong one under any header.
  if grep -q 'isSeparator ? nil' "${half}"; then
    fail "${half} re-pairs the ranked rows with the keyboard's index — that pairing is spelled ONCE"
  fi
done
# The Mac must DROP each ported card from the shared host's `draws` set, or it draws the card twice —
# once in SwiftUI over the workspace and once in its own panel.
if grep -A4 'draws:' Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift | grep -q '\.palette'; then
  fail "MacWorkspaceRootView still lets the shared host draw the palette — the Mac would show two"
fi
printf 'check-supervisor: one palette, drawn twice and spelled once.\n'

# ── One peek card, two frameworks ─────────────────────────────────────────────────────────────
# docs/56 stage D's second MODAL surface, and the first whose CONTENT moves under it: a reply
# advances the queue and the card is re-cut for the next blocked pane. The two halves may arrange it
# differently and must not word it differently — `PeekReplyPresentation` owns the header caption, the
# "N of M" counter, the stand-in note for a pane with no reported question and the zero-state line,
# and `AgentReadout` owns the status→glyph→ink reading both halves draw.
for half in Sources/SlopDeskMacUI/Overlays/MacPeekReply.swift \
  Sources/SlopDeskPhoneUI/Overlays/PeekReplyOverlay.swift; do
  if ! grep -q 'PeekReplyPresentation' "${half}"; then
    fail "${half} stopped reading PeekReplyPresentation — the two peek cards would drift on the first copy change"
  fi
  # The caption's join is the piece that looks too small to share and is not: the scent goes LAST so
  # a tail truncation eats the prose first and the status word never.
  #
  # Comments are stripped first: both halves' headers NAME the copy they no longer spell, and a gate
  # that read its own rationale as a regression would make the departure undocumentable.
  if sed -E 's#^[[:space:]]*//.*##' "${half}" |
    grep -qE '\\\(label\) · |"Peek & Reply"|The agent is waiting for your input'; then
    fail "${half} respells a peek-card string — every one of them is PeekReplyPresentation's"
  fi
done
# The status glyph crossed as a design-system LEAF (`MacAgentGlyphView`), which is only allowed
# because the decision under it did not: a status becomes a reading and an ink in `AgentReadout`, and
# each framework does the ladder lookup alone (`Slate.agentInk` / `Slate.Native.agentInk`).
if ! grep -q 'AgentReadout' Sources/SlopDeskMacUI/Overlays/MacPeekReply.swift; then
  fail "the Mac's peek header stopped reading AgentReadout — two spellings of one pane's state"
fi
if grep -A4 'draws:' Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift | grep -q '\.peekReply'; then
  fail "MacWorkspaceRootView still lets the shared host draw the peek card — the Mac would show two"
fi
printf 'check-supervisor: one peek card, drawn twice and spelled once.\n'

# ── The paste-as-keystrokes table and the peek RULES are Rust's, and only Rust's ───────────────
# `KeystrokeReplay` and `PeekReply` crossed in docs/56 §4. What is left in Swift is marshalling and
# the vocabulary types; the US-QWERTY table, the grapheme rule, the pane scan and the queue
# arithmetic are `slopdesk_workspace::{keystroke_replay, peek_reply}` and `slopdesk_agent::attention`.
for face in Sources/SlopDeskWorkspaceCore/Video/KeystrokeReplay.swift \
  Sources/SlopDeskWorkspaceCore/Workspace/Domain/PeekReply.swift; do
  if ! grep -q 'slopdesk_' "${face}"; then
    fail "${face} stopped asking the door — a rule decided in Swift is the second implementation (docs/56 §4)"
  fi
done
# ⚠️ THE UNIT IS A GRAPHEME CLUSTER, AND THE FIELD SHOWS DOTS. Walked as scalars, a decomposed `é`
# types a bare `e` and reports one skip — a DIFFERENT password, accepted, with nothing on screen to
# say so. `unicode-segmentation` is what makes the cluster the unit, and it is not an optimisation
# anyone may drop as unused.
if ! grep -q '^unicode-segmentation' rust/slopdesk-workspace/Cargo.toml; then
  fail "slopdesk-workspace dropped unicode-segmentation — chars() would type a decomposed é as a bare e"
fi
if ! grep -q 'UnicodeSegmentation' rust/slopdesk-workspace/src/keystroke_replay.rs; then
  fail "the keystroke table stopped walking graphemes — see the ⚠️ in its module header"
fi
# The cap is ONE number. Swift reads the `#define`; the crate exports the same constant and a test
# asserts they agree, because a Swift-side copy that drifted LOW would silently truncate a password.
if ! grep -q 'Int(SLOPDESK_KEYSTROKE_MAX_LENGTH)' Sources/SlopDeskWorkspaceCore/Video/KeystrokeReplay.swift; then
  fail "KeystrokeReplay.maxLength stopped reading the header define — a drifting cap truncates a password"
fi
printf 'check-supervisor: the keystroke table and the peek rules are Rust'"'"'s, graphemes and all.\n'

# ── One global search, two frameworks ─────────────────────────────────────────────────────────
# docs/56 stage D's third MODAL surface. What the two halves must not re-derive is not copy this
# time so much as READING: `GlobalSearchPresentation.excerptSlices` cuts a hit's excerpt around a
# UTF-16 highlight range that can land inside a surrogate pair, and the rule for that case — degrade
# to a flat excerpt, never trap, never guess a run — has to be one rule or the half that re-wrote it
# indexes out of bounds on the first scrollback line containing an emoji.
for half in Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift \
  Sources/SlopDeskPhoneUI/Overlays/GlobalSearchView.swift; do
  if ! grep -q 'GlobalSearchPresentation' "${half}"; then
    fail "${half} stopped reading GlobalSearchPresentation — two cuts of one excerpt, one of them wrong"
  fi
  # Comments are stripped first, for the peek gate's reason: both headers NAME what they no longer
  # spell. The two zero-state lines and a hand-rolled UTF-16 walk are the regressions.
  if sed -E 's#^[[:space:]]*//.*##' "${half}" |
    grep -qE 'No results\.|scrollback\.”|samePosition\(in:'; then
    fail "${half} respells a global-search string or re-derives the excerpt cut — both are GlobalSearchPresentation's"
  fi
  # The mode pills are a VALUE both surfaces read, which is the only way the locked "the find bar and
  # the global-search query bar render the pills IDENTICALLY" invariant survives one of them
  # becoming an NSView.
  if ! grep -q 'FindModePill' "${half}"; then
    fail "${half} stopped reading FindModePill — the find bar's chips and this bar's would drift"
  fi
done
if sed -E 's#^[[:space:]]*//.*##' Sources/SlopDeskPhoneUI/Pane/TerminalFindBar.swift |
  grep -qE '"Case sensitive"|"Whole word"|"Regex \(ICU\)"'; then
  fail "TerminalFindBar respells a mode pill — the labels and help are FindModePill's, for all three surfaces"
fi
if grep -A4 'draws:' Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift | grep -q '\.globalSearch'; then
  fail "MacWorkspaceRootView still lets the shared host draw global search — the Mac would show two"
fi
printf 'check-supervisor: one global search, drawn twice and read once.\n'

# ── One picker, two frameworks, and an empty ledger ───────────────────────────────────────────
# docs/56 stage D's LAST modal surface. The verb table is the piece that must not be written twice:
# unlike a copy string it does not fail loudly when it drifts — one half quietly grows an action the
# other has not got, and nothing is red until a user notices their phone's picker is different.
for half in Sources/SlopDeskMacUI/Overlays/MacOpenQuickly.swift \
  Sources/SlopDeskPhoneUI/Overlays/OpenQuicklyView.swift; do
  for spelling in OpenQuicklyPresentation OpenQuicklyActions OpenQuicklyMetrics; do
    if ! grep -q "${spelling}" "${half}"; then
      fail "${half} stopped reading ${spelling} — two pickers, and the drift would be silent"
    fi
  done
  # Comments are stripped first, for the peek gate's reason: both headers NAME what they no longer
  # spell. A verb title, a footer hint or a zero-state line in code is the regression.
  if sed -E 's#^[[:space:]]*//.*##' "${half}" |
    grep -qE '"Split Right"|"Reopen Tab"|"Copy Session ID"|"No matches"|"Quick Select"|"Change Directory"'; then
    fail "${half} respells a picker verb or hint — every one of them is OpenQuicklyPresentation's or OpenQuicklyActions's"
  fi
done
# The fzf mark is cut in ONE place for all four surfaces that draw one (the palette and the picker,
# each drawn twice). A half walking `titleRanges` itself is a fifth cut waiting to disagree.
for half in Sources/SlopDeskMacUI/Overlays/MacPalette.swift \
  Sources/SlopDeskMacUI/Overlays/MacOpenQuickly.swift \
  Sources/SlopDeskPhoneUI/Overlays/PaletteView.swift \
  Sources/SlopDeskPhoneUI/Overlays/OpenQuicklyView.swift; do
  if ! grep -q 'FuzzyMatcher.runs(' "${half}"; then
    fail "${half} stopped reading FuzzyMatcher.runs — a fifth spelling of one fzf mark"
  fi
done
# THE LEDGER IS GONE, which is what stage D was counting to. `draws` let the Mac drop the shared
# host's cards one at a time; with the last one moved it must not come back, and the host's card
# machinery is the phone's alone.
if sed -E 's#^[[:space:]]*//.*##' Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift |
  grep -q 'draws'; then
  fail "the transitional \`draws\` ledger is back in OverlayHostView — every card has left the Mac"
fi
# NOTHING SWIFTUI FLOATS OVER THE MAC's SPLIT. The shared host is the PHONE's whole overlay layer
# now — the Mac's last two tenants, the Connect FORM and the close-confirmation ALERT, are AppKit
# sheets driven from the scene. Re-mounting the host here is not a cosmetic regression: an
# `NSHostingView` claims every hit inside its own bounds, so an always-mounted SwiftUI layer over the
# split makes the window click-dead everywhere its ink is not (docs/56 §3.5, measured 2026-08-17).
if grep -q 'OverlayHostView' Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift; then
  fail "MacWorkspaceRootView mounts the shared host again — an NSHostingView over the split eats the clicks"
fi
# The two surfaces that were never cards exist on the Mac and are DRIVEN. Each defaults to doing
# nothing when nobody reconciles it, which is exactly the failure that reads as "the flag never
# flipped": a Connect chord that opens no window, a parked close that never asks.
for pair in \
  "MacConnectSheet:the Connect form" \
  "MacCloseConfirmation:the close confirmation"; do
  if ! grep -q "${pair%%:*}" Sources/SlopDeskMacUI/Overlays/MacOverlayPanels.swift; then
    fail "${pair#*:} is not reconciled by MacOverlayPanels — the Mac would never raise it"
  fi
done
# ONE WORDING for the confirmation, and it is `CloseConfirmationCopy`. Which line a park deserves is
# three branches and a join; a half that respells any of them drifts silently, because a dialog that
# says the wrong true-sounding thing looks exactly like one that says the right thing.
for half in Sources/SlopDeskMacUI/Overlays/MacCloseConfirmation.swift \
  Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift; do
  if ! grep -q 'CloseConfirmationCopy' "${half}"; then
    fail "${half} stopped reading CloseConfirmationCopy — two dialogs, and the drift would be silent"
  fi
  if sed -E 's#^[[:space:]]*//.*##' "${half}" |
    grep -qE '"A process is still running|"This window has multiple tabs|Closing it will close the project'; then
    fail "${half} respells the close-confirmation copy — every line of it is CloseConfirmationCopy's"
  fi
done
# ONE SHAPE for the three clipboard questions, and it is `ClipboardConfirmPresentation`. The WORDS were
# never in danger — they are `slopdesk_terminal::paste`'s, reached through `PasteSafetyAnalyzer` — but the
# SHAPE was decided twice: bullets or the ask's reason, the preview or nothing, the bullet glyph, the
# caption. A half that respells any of it is a second guard saying something slightly different about the
# same payload, which is the failure increment 65 found on the phone in its worst form (a `#else` that
# auto-approved). The `informativeText` join lives in the shared type for the same reason: it is a
# serialisation, not a layout, so an `NSAlert` reads it rather than composing one beside itself.
for half in Sources/SlopDeskMacUI/Terminal/PasteProtectionSheet.swift \
  Sources/SlopDeskPhoneUI/Overlays/ClipboardConfirmCard.swift; do
  if ! grep -q 'ClipboardConfirmPresentation' "${half}"; then
    fail "${half} stopped reading ClipboardConfirmPresentation — two guards, and the drift would be silent"
  fi
  if sed -E 's#^[[:space:]]*//.*##' "${half}" | grep -qE '"Clipboard preview|"•'; then
    fail "${half} respells the clipboard confirmation's shape — the bullet and the caption are the shared type's"
  fi
done
printf 'check-supervisor: one picker, drawn twice, and the stage-D ledger is empty.\n'

# ── One navigator, one row reading, one git dialect (docs/56 stage D) ───────────────────────────
# The NAVIGATOR is the column stage D names as Mac-shaped, and the one whose halves could disagree
# in the most ways: forty rows, each with a hover swap, a drop ring, a context menu, an inline field
# and a mark that ticks at display rate. Everything the two frameworks could argue about was lifted
# to `SlopDeskClientCore` FIRST — the row's whole appearance (`SidebarRowReading`), the git dialect
# (`SidebarGitLine`), the sectioning (`SidebarSections`), the menu's verb table (`SidebarRowMenu`)
# and the select path (`SidebarSelection`) — so what is left in either column is drawing and events.
# This gate is what keeps that true.
#
# `SlateTabRow.swift` must stay DELETED. It was the shared SwiftUI row both platforms drew; the Mac's
# row is `MacSidebarRowView` and the phone's is `IOSSidebarLiveRow`, and a third would be the
# cross-language mirror CLAUDE.md's one-implementation rule bans.
if [[ -e Sources/SlopDeskPhoneUI/Chrome/SlateTabRow.swift ]]; then
  fail "SlateTabRow.swift is back — the navigator row is MacSidebarRowView (AppKit) or IOSSidebarLiveRow (phone)"
fi
if grep -rqE '(struct|final class) SlateTabRow\b' Sources/ 2> /dev/null; then
  fail "SlateTabRow is back under another path — one row per platform, both reading SidebarRowReading"
fi
# The SwiftUI navigator is the PHONE's now. Without the platform gate the Mac would build two.
if ! grep -q '#if os(iOS)' Sources/SlopDeskPhoneUI/Columns/NavigatorColumn.swift; then
  fail "NavigatorColumn stopped being iOS-only — the Mac's navigator is MacNavigatorColumn"
fi
for spelling in SidebarRowPresentation SidebarRowMenu; do
  if ! grep -q "${spelling}" Sources/SlopDeskPhoneUI/Columns/NavigatorColumn.swift; then
    fail "the phone's navigator stopped reading ${spelling} — two rows, and the drift would be silent"
  fi
done
for spelling in SidebarRowPresentation SidebarRowMenu SidebarSections; do
  if ! grep -rq "${spelling}" Sources/SlopDeskMacUI/Columns/; then
    fail "the Mac's navigator stopped reading ${spelling} — two rows, and the drift would be silent"
  fi
done
# The GIT DIALECT is cut once. A half that spells a sigil itself is a second dialect: the sigils are
# a language a git prompt already taught the eye, and two spellings of it read as two repos.
if ! grep -rq 'SidebarGitLine' Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift; then
  fail "MacSidebarHeader stopped reading SidebarGitLine — the git dialect is ClientCore's, cut once"
fi
# THE PHONE IS ASSERTED THE SAME WAY, and it is not symmetry for its own sake: the sigil ban below
# cannot tell a half that PORTED the git line from one that DELETED it. A navigator that simply
# stopped drawing git passes every ban in this file — no second dialect, no respelt sigil, nothing
# to catch — while the parity rule the whole split rests on ("the phone differs in LAYOUT only")
# quietly stops holding. A ban needs a reader beside it or it only proves an absence.
if ! grep -rq 'SidebarGitLine' Sources/SlopDeskPhoneUI/Columns/NavigatorColumn.swift; then
  fail "the phone's navigator stopped reading SidebarGitLine — the git line is layout-only on the phone, not absent"
fi
for half in Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift \
  Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift \
  Sources/SlopDeskPhoneUI/Columns/NavigatorColumn.swift; do
  # Comments stripped first — the headers NAME the sigils they no longer spell.
  if sed -E 's#^[[:space:]]*//.*##;s#^[[:space:]]*///.*##' "${half}" |
    grep -qE '"↑\\\(|"↓\\\(|"\+\\\(|"!\\\(|"\?\\\(|"~\\\(|"\$\\\('; then
    fail "${half} spells a git sigil — every one of them is SidebarGitLine.segments's"
  fi
done
# THE MULTICLIENT LINES ARE CUT ONCE TOO — `SidebarRowReading.presence` mints "Also open on <device>"
# and "Held by <device>", and nothing else may. This is the sentence a reader trusts to know whether
# somebody else is typing into the pane they are about to take, so a half that composes its own is
# not a wording drift: it is a second answer to a question with one true answer, and the wrong one
# looks exactly as authoritative as the right one. Comments stripped first — the phone navigator's
# own header QUOTES both lines to say where they come from, which is the file doing the right thing.
for half in Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift \
  Sources/SlopDeskPhoneUI/Columns/NavigatorColumn.swift; do
  if sed -E 's#^[[:space:]]*//.*##;s#^[[:space:]]*///.*##' "${half}" |
    grep -qE '"Also open on|"Held by'; then
    fail "${half} mints a multiclient line — \"Also open on\" and \"Held by\" are SidebarRowReading.presence's"
  fi
done
# The ATTENTION ROLES are ranked once (`TabBadgeReading.rollup`), because a collapsed group's count
# has to pick a loudest hidden state and both halves must pick the same one.
if ! grep -rq 'TabBadgeReading' Sources/SlopDeskSlate/StatusPresentation.swift; then
  fail "StatusPresentation stopped delegating to TabBadgeReading — the attention ranking is cut once"
fi
printf 'check-supervisor: one navigator per platform, one row reading, one git dialect.\n'

# ── One titlebar band, one connection reading (docs/56 stage D) ─────────────────────────────────
# The window runs `.hiddenTitleBar`, so the BAND is the chrome — and being the chrome, it is always
# mounted, which is the same recurring cost that moved the navigator. Both its halves crossed:
# `MacTabStrip` for the tabs and `MacConnectionIsland` for the status.
#
# The two SwiftUI originals must stay DELETED. `SlateTitlebar` was a full-bleed overlay that had to
# be handed `allowsHitTesting` back a layer at a time to stop claiming the terminal's clicks — the
# exact hazard an `NSView` sibling does not have — and `WorkspaceTabStrip` was the tab list it
# carried. Neither has a phone mount to come back for: the phone has no titlebar at all.
for gone in Sources/SlopDeskPhoneUI/Chrome/SlateTitlebar.swift \
  Sources/SlopDeskPhoneUI/Chrome/WorkspaceTabStrip.swift; do
  if [[ -e "${gone}" ]]; then
    fail "${gone} is back — the Mac's titlebar chrome is MacTitlebarBand + MacTabStrip (AppKit)"
  fi
done
if grep -rqE '(struct|final class) (SlateTitlebar|WorkspaceTabStrip|TabStripChip)\b' Sources/ 2> /dev/null; then
  fail "a SwiftUI titlebar/tab-strip type is back — the band is MacTitlebarBand, the strip MacTabStrip"
fi
# The CONNECTION READING is cut once, in ClientCore, and BOTH surfaces must read it: the Mac's island
# in its two layouts, and the phone's one-line pill. What the halves could disagree about is not the
# palette — it is which readings may CLIMB at all (the link on its round trip, memory on the kernel's
# pressure verdict, disk on an absolute byte floor; CPU never), and a second answer to that is an
# instrument that cries wolf on one platform and stays silent on the other.
for half in Sources/SlopDeskMacUI/Chrome/MacConnectionIsland.swift \
  Sources/SlopDeskPhoneUI/Chrome/ConnectionPill.swift; do
  if ! grep -q 'ConnectionReading' "${half}"; then
    fail "${half} stopped reading ConnectionReading — the alarm ladder is ClientCore's, cut once"
  fi
done
# The strip's chip is the navigator row's reading, NOT a second one. Its inputs are a strict subset,
# and only one of the strip and the column is ever mounted, so there is nothing to buy by cutting a
# `TabChipReading` and one more place for "what is this pane called" to drift.
if ! grep -q 'SidebarRowPresentation' Sources/SlopDeskMacUI/Chrome/MacTabStrip.swift; then
  fail "MacTabStrip stopped reading SidebarRowPresentation — the chip is the row's reading, cut once"
fi
# The band is a PASS-THROUGH: it spans the column so its ends can anchor to the window's, and every
# click in its empty middle belongs to the terminal under it. Without the refusal it is the
# full-bleed hit-claimer the port removed.
if ! grep -q 'override func hitTest' Sources/SlopDeskMacUI/Chrome/MacTitlebarBand.swift; then
  fail "MacTitlebarBand stopped refusing hits — its empty centre is the terminal island's moat"
fi
printf 'check-supervisor: one titlebar band, one connection reading.\n'

# ── One panel chrome, one tab reading (docs/56 stage D) ─────────────────────────────────────────
# The right panel's CHROME crossed whole: the strip over the surfaces, the rail the collapsed panel
# leaves behind, and the four tabs both of them draw. The SURFACES stayed SwiftUI on purpose (three
# of the four are already AppKit under a thin wrapper, and the phone will want them on its own
# layout) — which is exactly why the chrome had to move: a strip that reloads a surface must outlive
# the view that draws it.
#
# The two SwiftUI originals must stay DELETED. `PanelRail` was the collapsed panel's stand-in and
# `AndroidRobotMark` the one mark no icon set ships; the mark is a `CGPath` in ClientCore now, so a
# SwiftUI copy would be a second drawing of the same head.
for gone in Sources/SlopDeskPhoneUI/Chrome/PanelRail.swift \
  Sources/SlopDeskPhoneUI/DesignSystem/AndroidRobotMark.swift; do
  if [[ -e "${gone}" ]]; then
    fail "${gone} is back — the panel's chrome is MacPanelStrip + MacPanelRail (AppKit)"
  fi
done
if grep -rqE '(struct|final class) (PanelRail|PanelTabPlate|AndroidRobotMark)\b' Sources/ 2> /dev/null; then
  fail "a SwiftUI panel-chrome type is back — the tabs are MacPanelTabPlate, the mark AndroidMarkPath"
fi
# The four TABS are one list, in ClientCore, because they were written twice — once across the strip
# and once down the rail — and the two had to agree on the mark, the word AND the help of every
# surface. The WIDTH LADDER lives with them as arithmetic rather than a `ViewThatFits`, so a test can
# ask it what a width affords without mounting anything.
for half in Sources/SlopDeskMacUI/Panel/MacPanelStrip.swift \
  Sources/SlopDeskMacUI/Panel/MacPanelTabGroup.swift \
  Sources/SlopDeskPhoneUI/Panel/PhonePanelSheet.swift; do
  if ! grep -q 'PanelTabs' "${half}"; then
    fail "${half} stopped reading PanelTabs — the panel's four tabs are ClientCore's, cut once"
  fi
done
# THE PHONE'S PANEL IS A LAYOUT, NOT A SECOND PANEL. Its bar is its own (a cover has no split item to
# hide, so it closes instead), but everything under the bar is the Mac's: the same four surfaces, the
# same shared `codeSidebarCollapsed` flag driving the presentation — which is what makes
# `revealCodeSidebar()` reach the phone at all — and the same drawn robot.
for reading in "Sources/SlopDeskPhoneUI/Panel/PhonePanelSheet.swift:CodePanelSurfaces(" \
  "Sources/SlopDeskPhoneUI/Panel/PhonePanelSheet.swift:AndroidMarkPath" \
  "Sources/SlopDeskPhoneUI/WorkspaceRootView.swift:codeSidebarCollapsed"; do
  if ! grep -qF "${reading#*:}" "${reading%%:*}"; then
    fail "${reading%%:*} stopped reading ${reading#*:} — the phone's panel is a LAYOUT, not a second panel"
  fi
done
if ! grep -q 'AndroidMarkPath' Sources/SlopDeskMacUI/Panel/MacPanelTabPlate.swift; then
  fail "MacPanelTabPlate stopped drawing AndroidMarkPath — the head's proportions are cut once"
fi
# NOTHING IN THE RAIL IS A TURNED VIEW. `frameCenterRotation` pivots a layer-backed view about its
# layer's ANCHOR POINT — the frame's corner — which threw every rail tab out of the rail; and a
# turned view's frame is still its unturned box, so its hit area would lie across both neighbours.
# The tab stands in its footprint and turns its CONTENT.
# Comments stripped first — the headers NAME the API they exist to warn about.
if sed -E 's#^[[:space:]]*//.*##;s#^[[:space:]]*///.*##' Sources/SlopDeskMacUI/Panel/*.swift |
  grep -q 'frameCenterRotation'; then
  fail "a panel tab turns its VIEW again — turn the content, or the rail's hit areas overlap"
fi
printf 'check-supervisor: one panel chrome, one tab reading.\n'

# ---------------------------------------------------------------------------
# THE DEVICE-PANEL FLOOR IS PLATFORM-NEUTRAL.
#
# Every file in `SlopDeskDevicePanels` was once wrapped whole in `#if os(macOS)` — inherited from the
# days the panels were a Mac-only surface, never from a Mac-only dependency. The module imports
# Foundation, CoreGraphics, CoreMedia and Network; the phone has all four. The gates cost nothing to
# add and hid the whole parity gap behind a green build, because forty-one EMPTY files compile fine.
#
# So no platform gate goes back in. `SimulatorKeyMap` is the one that will tempt someone — its table
# is keyed on macOS virtual key codes — and its answer is `AndroidKeyMap`'s: spell the numbers, pin
# them against the SDK in a macOS-only TEST, and leave the shared floor buildable everywhere.
if grep -rn '^#if.*os(macOS)' Sources/SlopDeskDevicePanels/ 2> /dev/null; then
  fail "a platform gate is back in SlopDeskDevicePanels — the panel floor is the phone's too"
fi
if grep -rq 'import Carbon' Sources/SlopDeskDevicePanels/ 2> /dev/null; then
  fail "SlopDeskDevicePanels imports Carbon — that module does not exist on the iOS triple"
fi
printf 'check-supervisor: the device-panel floor builds for the phone.\n'

# ---------------------------------------------------------------------------
# BOTH DEVICE PANELS DRAW ON BOTH PLATFORMS.
#
# The simulator and Android surfaces are the phone's too (docs/56 stage D). Fifteen of their
# seventeen files are plain SwiftUI and carry NO gate at all; the two that host a video stage carry
# both halves in one file, `#if os(macOS)` … `#elseif os(iOS)`. A bare `#if os(macOS)` anywhere in
# those directories is the old Mac-only shape coming back — it compiles to an empty file on the
# phone, which is a green build over a missing feature.
for surface in Sources/SlopDeskPhoneUI/Panel/Simulator/*.swift Sources/SlopDeskPhoneUI/Panel/Android/*.swift; do
  if grep -q '^#if os(macOS)' "${surface}" && ! grep -q '^#elseif os(iOS)' "${surface}"; then
    fail "${surface} is macOS-only again — both device panels draw on the phone too"
  fi
done
for stage in Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorScreenView.swift \
  Sources/SlopDeskPhoneUI/Panel/Android/AndroidScreenView.swift; do
  if ! grep -q 'UIViewRepresentable' "${stage}"; then
    fail "${stage} lost its UIKit half — the phone's device stage is a UIViewRepresentable"
  fi
done
# ONE VOCABULARY, TWO NUMBERINGS. A Mac reports a virtual key code and an iPad a USB HID usage; the
# NAMES they resolve to, and every rule about what to do with them, are cut once — in
# `slopdesk_devicepanel::panel_key`, which both panels reach through one door apiece.
#
# What this used to check was that the two HID TABLES existed in Swift. They are gone: the numbering
# now rides as the door's `hid` flag, and the HID side is derived from the remote-desktop path's own
# usage → keycode map rather than written a second time. So the check inverts. The tables must stay
# DELETED — a reappearance is the drift the port removed, and it would compile and pass its own
# tests — and the two ENTRY POINTS that carry the iPad's numbering must stay reachable, because a
# port that quietly dropped the HID half would leave an iPad keyboard typing nothing.
for gone in byVirtualKey byHIDUsage functionalKeys hidFunctionalKeys; do
  if grep -rq "${gone}" Sources/; then
    fail "the ${gone} table is back in Swift — panel_key.rs is the one table (docs/55 §8)"
  fi
done
if ! grep -q 'code(hidUsage:' Sources/SlopDeskDevicePanels/Simulator/SimulatorKeyMap.swift; then
  fail "SimulatorKeyMap lost its HID entry point — an iPad numbers its keys as HID usages"
fi
if ! grep -q 'hidUsage: UInt16' Sources/SlopDeskDevicePanels/Android/AndroidKeycode.swift; then
  fail "AndroidKeyMap lost its HID entry point — an iPad numbers its keys as HID usages"
fi
if ! grep -q 'hid_virtual_key::virtual_key' rust/slopdesk-devicepanel/src/panel_key.rs; then
  fail "panel_key stopped deriving its HID side — that is how the two numberings cannot drift"
fi

# The map panel_key derives FROM, and the gesture plan beside it, went the same way in `47eeea22`.
# Both are faces now: a door call per answer and not one number of their own. The tables they lost
# were `private`, so nothing outside would notice them growing back — a reader would see a plausible
# Swift constant and no reason to doubt it. So the shape is pinned instead of the names: neither file
# may hold a collection literal or a numeric constant, because in a face there is nothing for one to
# be. Comments stripped first; both files explain at length what they no longer contain.
for face in Sources/SlopDeskVideoClient/HIDVirtualKeyMap.swift \
  Sources/SlopDeskVideoClient/TouchPointerPlan.swift; do
  body="$(sed -E 's#^[[:space:]]*///?.*##' "${face}")"
  if printf '%s' "${body}" | grep -qE 'static let [A-Za-z]+(: [A-Za-z<>:, ]+)? = [-0-9[]'; then
    fail "${face} grew a constant of its own — it is a face, and the numbers are Rust's (docs/55 §6)"
  fi
done
# Comments stripped first — the tables' docs NAME the UIKit type they exist to stay away from.
if sed -E 's#^[[:space:]]*//.*##;s#^[[:space:]]*///.*##' Sources/SlopDeskDevicePanels/*/*.swift |
  grep -q 'UIKeyboardHIDUsage'; then
  fail "SlopDeskDevicePanels names UIKeyboardHIDUsage — that is UIKit, and the floor is not"
fi
printf 'check-supervisor: both device panels draw on both platforms.\n'

# ---------------------------------------------------------------------------
# THE CODE PANEL CROSSES, AND ONLY ITS KEYBOARD STAYS BEHIND.
#
# `CodeSidebarWebView.swift` was a thousand lines of which the larger half was a first-responder
# duel — a focused embedded VS Code and a focused terminal fighting over one AppKit window. That duel
# has no iOS analogue at all (no app-level event monitor, no menu bar, no shared field editor), and
# for as long as it sat in the same file as the pool, the whole code surface was Mac-only.
#
# Five files now, across THREE targets, and the split is the rule. Below both UI halves, in
# `SlopDeskClientCore`: the DECISIONS in `CodeSidebarFocusPolicy` (pure, and the only place a focus
# rule may be written), the POOL in `CodeSidebarWebViewPool` (projects and their warm pages — one
# law, and as of docs/56 increment 43 not one platform gate), and the PAGE in `CodeSidebarPage` (the
# mint, and the Mac's responder-seam subclass — a `WKWebView` is the platform's view class, not a
# drawn surface). The MOUNT is per-half and always was: a clipping container that lays out and reads
# a design token, so increment 51 split it in two — `CodeSidebarWebView` is the phone's
# representable, `SlopDeskMacUI/MacCodeWorkbenchView` is an `NSView` doing the same four calls with
# no `View` above it to justify a wrapper. And one target up in `SlopDeskMacUI`: the keyboard DUEL in
# `CodeSidebar/MacCodeSidebarKeyboard.swift`. Increments 42, 43, 45 and 51 are the four moves.
for piece in \
  "Sources/SlopDeskPhoneUI/CodeSidebar/CodeSidebarWebView.swift:UIViewRepresentable" \
  "Sources/SlopDeskMacUI/Panel/MacCodeWorkbenchView.swift:noteRemount" \
  "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarWebViewPool.swift:func noteRemount"; do
  if ! grep -qF "${piece#*:}" "${piece%%:*}"; then
    fail "${piece%%:*} lost ${piece#*:} — the code panel mounts on both platforms (docs/56)"
  fi
done
# The webview SUBCLASS is the responder seam and nothing else, so it exists only where a responder
# duel does. The phone mints a plain `WKWebView`; a `CodeSidebarWKWebView` named anywhere outside the
# two files that own it — or reached from the phone's half — is that seam leaking back out.
# Comments stripped first: the seam is DOC-linked from the policy and the pure state it drives, and a
# doc link is exactly the reference that is allowed to cross.
while IFS= read -r file; do
  [[ -z "${file}" ]] && continue
  [[ "${file}" =~ CodeSidebar/CodeSidebarPage\.swift$ ]] && continue
  if sed -E 's#^[[:space:]]*//.*##' "${file}" | grep -q 'CodeSidebarWKWebView'; then
    fail "${file} names CodeSidebarWKWebView — it is the Mac's responder seam, not an API"
  fi
done < <(grep -rl 'CodeSidebarWKWebView' Sources/ || true)
# The four code-panel files below carry NO WHOLE-FILE gate. `CodeSidebarProxy` and
# `CodeSidebarFontSchemeHandler` were gated for no reason at all — Network is Network and WebKit is
# WebKit — and `CodePanelSurfaces` was gated because of what it mounted, which has since crossed.
# A gate INSIDE one of them is fine, and the pool now has NONE — not an `#if`, not an AppKit/UIKit
# import. The keyboard machine went up to `SlopDeskMacUI/CodeSidebar/MacCodeSidebarKeyboard.swift`
# and the MINT (subclass-vs-plain, base-canvas kill) went sideways into `CodeSidebarPage.swift`,
# which is two per-platform halves on purpose — docs/56 increments 42, 43 and 45 name the moves. The
# import went with it: the one platform member the pool still touches is `window`, inherited from the
# view class WebKit already brings into scope. What is banned is the wrapper that makes the file
# compile to nothing on the phone, and that shape is exactly "the first line of code is
# `#if os(macOS)`".
for crossed in Sources/SlopDeskPhoneUI/CodeSidebar/CodePanelSurfaces.swift \
  Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarWebViewPool.swift \
  Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarProxy.swift \
  Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarFontSchemeHandler.swift; do
  first=$(grep -vE '^[[:space:]]*(//.*)?$' "${crossed}" | head -n 1 || true)
  if [[ "${first}" == '#if os(macOS)' ]]; then
    fail "${crossed} is wrapped in a macOS gate again — the code panel is the phone's too"
  fi
done
# THE POOL CARRIES NO GATE AT ALL, which is stronger than the four above and is the point of
# increments 42-43. Its subject is projects and their warm pages — one law on both halves — so every
# platform-shaped thing it used to hold has left: the keyboard duel went UP to `SlopDeskMacUI`, the
# page mint went ACROSS to `CodeSidebarPage.swift`, which has halves on purpose. A gate reappearing
# here is not a gate problem; it is the signal that whatever it guards belongs in one of those two
# files instead, and a comment saying so is not a pin.
if grep -qE '^\s*#if os\(' Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarWebViewPool.swift; then
  grep -nE '^\s*#if os\(' Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarWebViewPool.swift >&2
  fail "the code-page pool grew a platform gate — it manages pages, it does not draw them"
fi
# AND THE POOL IS BELOW BOTH UI HALVES, which is what the gate removal bought (increment 45). It is a
# RESOURCE manager, not a view: no `some View`, no design token, and the only reason it ever sat in
# the phone's target was the mint it used to carry. `SlopDeskMacUI` reaching it through the phone half
# was the import stage D deleted, so the ascent stays pinned shut here.
if [[ -e Sources/SlopDeskPhoneUI/CodeSidebar/CodeSidebarWebViewPool.swift ]]; then
  fail "the code-page pool climbed back into the UI target — it manages pages, it does not draw them"
fi
# A focus RULE lives in the policy, which is pure and testable; the seam only calls it. The three
# spellings below are the ones that were inline before the split and would be inline again first.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
focus_rules=$(spells 'func shouldAcceptFocus|func isReservedAppChord|func evictionVictim' \
  $(repo_files 'Sources/SlopDeskPhoneUI/**/*.swift' | grep -v 'CodeSidebarFocusPolicy.swift') \
  2> /dev/null || true)
if [[ -n "${focus_rules}" ]]; then
  printf '%s\n' "${focus_rules}" >&2
  fail "a code-panel focus rule grew back outside CodeSidebarFocusPolicy — it is pure on purpose"
fi
printf 'check-supervisor: the code panel crosses; only its keyboard stayed behind.\n'

# ── SlopDeskClientCore IS THE PRESENTATION LOGIC, AND IT DRAWS NOTHING ────────────────────────────
# The whole point of the layer is that the two renderers can both read it: `SlopDeskMacUI` builds
# AppKit out of it and `SlopDeskPhoneUI` builds SwiftUI out of it, so a decision spelled here is
# spelled once for both. One `import SwiftUI` ends that — not because SwiftUI is unavailable on the
# Mac, but because the moment a `View`, a `@ViewBuilder` or a `Color` is reachable from this layer,
# the next decision lands as a modifier instead of a function and the AppKit half has to re-spell it.
# That is the exact shape of every pair docs/55 §8 lists.
#
# This rule was TRUE of the tree for the whole split and was never written down; three separate ports
# were told it was a ratchet when it was only a habit. It goes in green — the count below is 0 today,
# and the gate is what makes it stay 0.
core_swiftui=$(grep -rln '^\s*import SwiftUI' Sources/SlopDeskClientCore/ 2> /dev/null || true)
if [[ -n "${core_swiftui}" ]]; then
  printf '%s\n' "${core_swiftui}" >&2
  fail "SlopDeskClientCore imported SwiftUI — it is the logic BOTH renderers read, so it draws nothing (docs/56 §3)"
fi
# The same rule stated from the other side: no design ink either. `SlopDeskSlate` sits ABOVE this
# layer, so a `Color`-returning table here cannot even compile — but a raw hex or an `.opacity(`
# would, and that is the form the ink tables took before they were named.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
core_ink=$(spells 'Color\(|\.opacity\(|NSColor\(|UIColor\(' \
  $(repo_files 'Sources/SlopDeskClientCore/**/*.swift') 2> /dev/null || true)
if [[ -n "${core_ink}" ]]; then
  printf '%s\n' "${core_ink}" >&2
  fail "SlopDeskClientCore spelled ink — the design floor is SlopDeskSlate, which sits ABOVE it (DESIGN.md)"
fi
printf 'check-supervisor: the presentation logic draws nothing; both renderers read it.\n'

# ── ONE TERMINAL WIRING, AND ITS TEARDOWN ORDER IS PART OF IT ────────────────────────────────────
# A terminal leaf's callbacks are five wire/clear PAIRS, and every one of them is a retain-cycle
# obligation rather than a layout: nil the closure or the dead leaf keeps driving a live model. They
# were a 555-line `View` body, which meant the AppKit rewrite would have had to copy them — so they
# descended whole, and what is left in the leaf is two calls.
WIRING=Sources/SlopDeskClientCore/Pane/TerminalPaneWiring.swift
if [[ ! -e "${WIRING}" ]]; then
  fail "${WIRING} is gone — the terminal leaf's callback wiring is not a view's to own (docs/56 §3)"
fi
# The pieces that must not regrow in a renderer. Each is a DECISION (when to connect, whether to
# autotype, which pill dismisses to what, whether secure input is owed) and none is a drawing.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
wiring_revived=$(spells 'class CommandNavigatorChrome|func runAutotypeIfRequested|func connectIfNeeded|func reconcileSecureInput' \
  $(repo_files 'Sources/SlopDeskPhoneUI/**/*.swift' 'Sources/SlopDeskMacUI/**/*.swift' \
    'Sources/SlopDeskPhoneUI/**/*.swift') 2> /dev/null || true)
if [[ -n "${wiring_revived}" ]]; then
  printf '%s\n' "${wiring_revived}" >&2
  fail "a terminal-wiring decision grew back in a renderer — it is ${WIRING}'s, for BOTH halves"
fi
# And the leaf must actually drive it. A leaf that quietly re-inlined the wiring would pass the ban
# above by spelling the closures without the helper names.
for half in 'wiring.wire(' 'wiring.clear('; do
  if ! grep -qF "${half}" Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift; then
    fail "the terminal leaf stopped calling ${half} — it wires nothing itself (docs/56 §3)"
  fi
done
# THE TEARDOWN ORDER, which is the one thing here that is not obvious from reading either half.
# `clearSecureInput` releases the PROCESS-GLOBAL `EnableSecureEventInput` FIRST and only then reaches
# for the model. Behind the guard it would be skipped for exactly the pane that needs it most — one
# whose model has already gone — and the lock would outlive the app's own window, taking the keyboard
# out of every other app. So: the teardown line must sit ABOVE the guard, and that is a line-number
# comparison because no type can express it.
teardown_line=$(grep -n 'secureInput.teardown()' "${WIRING}" | head -1 | cut -d: -f1 || true)
if [[ -z "${teardown_line}" ]]; then
  fail "${WIRING} stopped tearing the secure-input lock down at all — the process-global stays held"
fi
guard_line=$(awk -v start="${teardown_line}" 'NR > start && /guard let model = live\?\.terminalModel/ { print NR; exit }' "${WIRING}")
clear_end=$(awk -v start="${teardown_line}" 'NR > start && /^    }/ { print NR; exit }' "${WIRING}")
if [[ -z "${guard_line}" || "${guard_line}" -gt "${clear_end}" ]]; then
  fail "${WIRING}: the secure-input teardown is no longer above its guard — a pane whose model died keeps the lock"
fi
printf 'check-supervisor: one terminal wiring, and it releases the keyboard before it looks for a model.\n'

# ── THE ESCAPE MONITOR IS AN EVENT TAP, NOT A VIEW ───────────────────────────────────────────────
# Cancelling a pane move on ⎋ needs a LOCAL event monitor, which is an AppKit resource with a paired
# install/remove and no SwiftUI expression. It lived inside an `NSViewRepresentable`'s coordinator,
# where the pairing was invisible and the AppKit rewrite would have had to reproduce it from scratch.
ESCAPE_MONITOR=Sources/SlopDeskClientCore/Input/PaneMoveEscapeMonitorController.swift
if [[ ! -e "${ESCAPE_MONITOR}" ]]; then
  fail "${ESCAPE_MONITOR} is gone — without it a pane move cannot be cancelled (docs/56 §3)"
fi
for spelling in 'func arm(onCancel' 'func disarm()' 'addLocalMonitorForEvents' 'removeMonitor'; do
  if ! grep -qF "${spelling}" "${ESCAPE_MONITOR}"; then
    fail "${ESCAPE_MONITOR} lost ${spelling} — install and remove are a PAIR, and arm/disarm is the seam"
  fi
done
# It must not climb into a renderer, and it must not learn to draw: the controller is what lets the
# AppKit column and the SwiftUI leaf share one monitor rather than tapping the event stream twice.
if grep -q '^\s*import SwiftUI' "${ESCAPE_MONITOR}"; then
  fail "${ESCAPE_MONITOR} imported SwiftUI — it taps events, it draws nothing"
fi
# The pathspec is `Pane/*.swift`, NOT `Pane/**/*.swift`: git reads `**` as spanning one or more
# directory levels, and `Pane/` is flat, so the `**` form matched ZERO files and the gate passed
# while checking nothing. It was written that way and caught by its own break test on 2026-08-20 —
# the third time in this file a gate has died quietly by resolving to an empty file list, which is
# why the count below is asserted rather than assumed.
# `Sources/SlopDeskMacUI/Pane/*.swift` is listed BEFORE it exists, and that is the point: wave R
# creates that directory eleven batches deep, and a gate whose pathspec omits the directory the new
# renderers land in is a gate that goes quietly stale exactly when it starts mattering. A pathspec
# matching nothing costs nothing — the floor below is what makes an empty LIST loud, and the other
# two globs keep it well clear of 20 on their own.
pane_views=$(repo_files 'Sources/SlopDeskPhoneUI/Pane/*.swift' 'Sources/SlopDeskMacUI/Terminal/*.swift' \
  'Sources/SlopDeskMacUI/Pane/*.swift')
if [[ "$(printf '%s\n' "${pane_views}" | grep -c .)" -lt 20 ]]; then
  fail "the pane-view file list came back nearly empty — this gate has gone stale and is checking nothing"
fi
# Comments stripped: this file's header EXPLAINS where the monitor went and has to name the call to
# be worth reading. The app-level `WorkspaceKeyDispatcher` and the keybinding editor tap the stream
# on purpose and are not pane views, so they are outside the list rather than allowlisted inside it.
# shellcheck disable=SC2086 # `${pane_views}` expands to a FILE LIST on purpose
monitor_taps=$(spells 'addLocalMonitorForEvents' ${pane_views} 2> /dev/null || true)
if [[ -n "${monitor_taps}" ]]; then
  printf '%s\n' "${monitor_taps}" >&2
  fail "a pane view tapped the event stream directly — the monitor is ${ESCAPE_MONITOR}'s, armed through the seam"
fi
printf 'check-supervisor: one escape monitor, installed and removed in one place.\n'

# ---------------------------------------------------------------------------
# THE PHONE'S KEY PATH IS RUST, AND ITS SWIFT IS A MARSHALLER.
#
# Four Swift files used to hold it — a C0 fold, an arrow table, a routing switch, a threshold and a
# travel accumulator — and every one of them was a rule about bytes with no view in it. They are
# `slopdesk_workspace::phone_key` now, reached through `slopdesk_phone_*`, and `PhoneKey.swift` is
# what is left: the vocabulary the responder builds a press in, and the crossing.
#
# The four names below must stay gone. A file that spells one again is the second implementation
# the one-implementation rule exists to refuse — and this particular second implementation is the
# one that would drift silently, because both halves would keep passing their own tests.
for gone in KeyEncoding InputRouting FloatingCursorMapping KeyboardAccessoryDecision; do
  if [[ -e "Sources/SlopDeskWorkspaceCore/iOS/${gone}.swift" ]]; then
    fail "Sources/SlopDeskWorkspaceCore/iOS/${gone}.swift is back — the phone's key rules are Rust (docs/55)"
  fi
done
# The rules themselves, by the shapes they take in Swift. A C0 fold is `& 0x1F` or `- 0x60`; an
# arrow table is the four private-use scalars; the accumulator is a threshold loop. None of them may
# appear in the module that used to own them — the marshaller passes bytes through, it makes none.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
key_rules=$(spells '0x4F : 0x5B|0x5B : 0x4F|& 0x1F|u\{F70[0-3]\}' \
  $(repo_files 'Sources/SlopDeskWorkspaceCore/**/*.swift') 2> /dev/null || true)
if [[ -n "${key_rules}" ]]; then
  printf '%s\n' "${key_rules}" >&2
  fail "a phone key RULE grew back in Swift — the fold, the introducer and the arrows are Rust"
fi
# The RESPONDER is the other place a rule would grow, and the likelier one: it is the file holding a
# live `UIKey`, so a table there would look local rather than duplicated. It must spell no escape
# sequence and no HID number — `UIKeyboardHIDUsage`'s own cases are the only spelling of a usage
# allowed, and what each one MEANS is `slopdesk_workspace::phone_key`'s alone.
host_swift=Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift
if [[ ! -e "${host_swift}" ]]; then
  fail "${host_swift} is gone — without it the phone's terminal cannot receive a keystroke (docs/56 §16)"
fi
host_rules=$(spells '0x1B|0x5B|0x4F|u\{1B\}|\\u\{F70|& 0x1F|hidUsage: [0-9]' "${host_swift}" 2> /dev/null || true)
if [[ -n "${host_rules}" ]]; then
  printf '%s\n' "${host_rules}" >&2
  fail "the phone's responder spelled a key RULE — it reads a UIKey and asks PhoneKey, it decides nothing"
fi
for call in PhoneKey.routesToKeyEncoding PhoneKey.encode PhoneKey.keyChord PhoneKey.foldArmedControl \
  PhoneKey.showsAccessoryBar; do
  if ! grep -qF "${call}" "${host_swift}"; then
    fail "${host_swift} stopped asking ${call} — a question it answers itself is a rule written twice"
  fi
done
# And the marshaller must actually call the doors it claims to. A `PhoneKey` that quietly answered
# from Swift again would pass every test above.
for door in slopdesk_phone_key_routes_to_encoding slopdesk_phone_key_encode slopdesk_phone_key_chord \
  slopdesk_phone_key_fold_control slopdesk_phone_shows_accessory_bar slopdesk_phone_floating_cursor_feed; do
  if ! grep -qF "${door}" Sources/SlopDeskWorkspaceCore/iOS/PhoneKey.swift; then
    fail "PhoneKey.swift stopped calling ${door} — a rule it answers itself is a rule written twice"
  fi
  if ! grep -qF "${door}" rust/slopdesk-ffi/include/slopdesk_ffi.h; then
    fail "${door} is missing from slopdesk_ffi.h — Swift cannot reach a door the header does not name"
  fi
done
# The chord's modifier word crosses UNTRANSLATED, so the two numberings must be the same four bits.
# The Rust side pins its own half against `KeyChord.Modifiers` in `slopdesk-ffi`; this pins the Swift
# half, which is the one a future OptionSet reorder would break without a compile error anywhere.
for bit in "shift = Self(rawValue: 1 << 0)" "control = Self(rawValue: 1 << 1)" \
  "option = Self(rawValue: 1 << 2)" "command = Self(rawValue: 1 << 3)"; do
  if ! grep -qF "${bit}" Sources/SlopDeskWorkspaceCore/Workspace/Domain/KeyChord.swift; then
    fail "KeyChord.Modifiers renumbered (${bit}) — the phone's flag word crosses as those exact bits"
  fi
done
printf 'check-supervisor: the phone key path is Rust; PhoneKey.swift only carries it across.\n'

# ── THE TREE REPAIR PASS IS RUST, AND WHAT REGROWS IS ONE PREDICATE ──────────────────────────────
# The repair that fixes a degenerate workspace document ran in BOTH languages until 2026-08-20, and
# the pair never shadowed itself because the two halves fired on DIFFERENT EVENTS — Swift's copy on
# file load, the crate's on every intent. A workspace that closed cleanly came back a different shape
# after a relaunch, with every test on both sides green, because each half was self-consistent.
# It is `slopdesk_workspace::tree_ops::repaired` now (docs/55 §8).
#
# What grows a second implementation back is not a whole function reappearing — that would be seen.
# It is one PREDICATE or one re-seed STRING restated by hand, which is how the divergence started:
# `isVideo` was `self == .desktop` on one side and a crate predicate on the other, agreeing by
# coincidence right up until a third video-ish kind would have split them.
repair_file=Sources/SlopDeskWorkspaceModel/Domain/Tree/TreeWorkspace.swift
if [[ ! -e "${repair_file}" ]]; then
  fail "${repair_file} is gone — the launch-time repair's Swift half is a marshaller, not nothing (docs/55 §8)"
fi
# Through `spells`, which strips comments: this file's header EXPLAINS the divergence and has to
# quote the predicate it names to be worth reading. A gate that cannot tell the code from the
# post-mortem forbids writing the post-mortem, which is the one artefact that stops the next port
# repeating it. (Caught on the first run of this gate, 2026-08-20 — the doc comment matched.)
repair_ghosts=$(spells 'kind == \.desktop|title: "Terminal"|name: "Local"' "${repair_file}" 2> /dev/null || true)
if [[ -n "${repair_ghosts}" ]]; then
  printf '%s\n' "${repair_ghosts}" >&2
  fail "${repair_file} restated a repair rule in code — the video predicate and the two re-seed strings are rust/slopdesk-workspace's; ask the door (slopdesk_ws_pane_kind_is_video, slopdesk_ws_default_*) (docs/55 §8)"
fi
# And the predicate itself, wherever it lives: `PaneKind.isVideo` must ASK. It is the one the repair
# reads to decide which panes may live in the tree at all, so a transcribed copy of it is the exact
# defect above, one layer down.
if ! grep -qF 'slopdesk_ws_pane_kind_is_video' Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift; then
  fail "PaneKind.isVideo stopped asking slopdesk_ws_pane_kind_is_video — a transcribed predicate agrees until it does not (docs/55 §8)"
fi
# The residue is ONE function and it is named on purpose: the document is a PUSH format, so its
# ingest drops a session with no usable tab and INVENTS a spec for a detached pane that has none —
# two absences that cannot make the trip. Deleting it needs a whole-`TreeWorkspace` codec in
# `slopdesk_workspace::persist`. Pinned rather than banned, so the exit stays visible.
if ! grep -qF 'withTheDocumentsBlindSpotsClosed' "${repair_file}"; then
  printf '%s\n' "note: withTheDocumentsBlindSpotsClosed is gone — if the persist codec landed, drop this gate" >&2
fi
printf 'check-supervisor: one tree repair, in Rust, and Swift restates neither its predicate nor its seeds.\n'

# ── FOUR CROSS-LANGUAGE TWINS, AND WHAT GROWS EACH ONE BACK ──────────────────────────────────────
# Ported 2026-08-22. Each of these was one rule implemented in both languages. In three of the four
# the two copies were not even reached by the same inputs — one side had the callers and the other
# had the tests — which is the arrangement in which a divergence can never show up as a red
# anything. What regrows a pair is not a whole function reappearing; it is one predicate, one cast or
# one line of index arithmetic written by hand beside a door that already answers it.

# 1. THE NEW-TAB PLACEMENT. `NewTabPosition.insertionIndex` was the three-case arithmetic and the two
#    clamps a second time, and it had NO production caller: ⌘T and ⇧⌘T send the policy as a byte
#    inside a workspace intent, and `slopdesk_workspace::tree_ops` places the tab on the far side. So
#    the Swift copy answered only its own four test cases while the crate's decided where every tab
#    actually went. Catches: the marshaller being replaced by the arithmetic again.
new_tab_file=Sources/SlopDeskWorkspaceModel/Domain/Tree/NewTabPosition.swift
if [[ ! -e "${new_tab_file}" ]]; then
  fail "${new_tab_file} is gone — the case list is a vocabulary that a settings picker, the Defaults bridge and the intent wire all read, so the Swift half is a marshaller, not nothing (docs/55 §6)"
elif ! spells 'slopdesk_ws_new_tab_index\(' "${new_tab_file}" > /dev/null; then
  fail "${new_tab_file} stopped asking slopdesk_ws_new_tab_index — the placement is rust/slopdesk-workspace's NewTabPosition, and a Swift copy of it answers only its own tests (docs/55 §8)"
fi
# And the arithmetic itself, in case a copy lands BESIDE the door rather than replacing it — the way
# the isVideo divergence started. Comment-stripped, so the doc comment may go on naming the clamps
# this method no longer performs.
new_tab_ghosts=$(spells 'max\(tabCount|min\(max\(|clampedActive|activeTabIndex \+ 1' "${new_tab_file}" 2> /dev/null || true)
if [[ -n "${new_tab_ghosts}" ]]; then
  printf '%s\n' "${new_tab_ghosts}" >&2
  fail "${new_tab_file} restated the insertion arithmetic — the two clamps and the after-current slot are the crate's; ask the door (docs/55 §8)"
fi

# 2. THE OTHER HALF OF THE PANE-KIND CLASSIFICATION. `PaneKind.isVideo` is already gated above to ask
#    its door. `canReceiveText` was `self == .terminal` beside a `PaneKind::can_receive_text` that no
#    Rust caller had ever reached — one classification, one half asked through a door and one half
#    transcribed, which is precisely the MIN_WEIGHT/MAX_DEPTH anti-pattern docs/55 §8 names and says
#    one of the two is always wrong. Catches: the broadcast recipient set and the launch restore
#    selecting different panes the day a third kind lands on one side only.
if ! spells 'slopdesk_ws_pane_kind_can_receive_text\(' Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift > /dev/null; then
  fail "PaneKind.canReceiveText stopped asking slopdesk_ws_pane_kind_can_receive_text — half a classification asked and half transcribed is how the two halves come apart, with both suites green (docs/55 §8)"
fi

# 3. THE BINDABLE PORT. `PortValidation.port` asked the RANGE door and then made its own `UInt16`
#    conversion, while `listen::port` — which does both — had no caller and said so in its own doc
#    comment. The two agree only because `u16`'s range happens to BE the accepted range: that is a
#    fact about today's rule, not a rule. A range that stopped being it — a reserved floor, a refusal
#    of 0 — moves the predicate and leaves the near-side cast agreeing with nothing. Catches: the
#    composition growing back.
port_file=Sources/SlopDeskTransport/PortValidation.swift
if [[ ! -e "${port_file}" ]]; then
  fail "${port_file} is gone — the listen-port doors have a Swift face and it is a marshaller (docs/55 §6)"
elif ! spells 'slopdesk_ws_listen_port\(' "${port_file}" > /dev/null; then
  fail "${port_file} stopped asking slopdesk_ws_listen_port — a range predicate plus a cast of one's own is the same rule twice, and the cast is the copy nothing tests (docs/55 §8)"
fi
port_ghost=$(spells 'UInt16\(raw\)' "${port_file}" 2> /dev/null || true)
if [[ -n "${port_ghost}" ]]; then
  printf '%s\n' "${port_ghost}" >&2
  fail "${port_file} re-derived the port from the range predicate — the refusal and the conversion are one answer, and slopdesk_ws_listen_port is where it lives (docs/55 §8)"
fi

# 4. THE UNREACHED HALF THAT WAS DELETED RATHER THAN PORTED. `slopdesk_workspace::session` carried a
#    `VideoPaneModes` of five public fields with no methods, no callers, no tests and no re-export,
#    while `PaneSpec.swift`'s comment said in so many words that no Rust counterpart existed. Both
#    halves of that were the defect. An unreached copy cannot be caught disagreeing, because no input
#    ever reaches both — docs/55 §8's ruling on `templates::plan`, that "do not port this" and "keep
#    an unreachable copy of it" are different instructions — and a comment asserting a cross-language
#    fact is a claim with no gate behind it. The modes are device-local, decoded by Foundation out of
#    `device-prefs.json`, and Swift is the one implementation. Catches: the empty shape being re-added
#    because the Swift struct has fields that look like they ought to have a home in the crate.
# BOTH CRATES, because `session` moved: `slopdesk-workspace` was carved into four, and the shape
# this bans lived in the half that left. Globbing only the old name would scan 27 files that never
# held it and report green forever.
modes_corpus_count=$(repo_files 'rust/slopdesk-workspace/src/*.rs' 'rust/slopdesk-tree/src/*.rs' | wc -l | tr -d '[:space:]')
if ((modes_corpus_count < 20)); then
  fail "rust/slopdesk-{workspace,tree}/src read as ${modes_corpus_count} files — the crate moved, so the ban below stopped checking anything (docs/55 §8)"
else
  # shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
  modes_ghost=$(spells 'VideoPaneModes' $(repo_files 'rust/slopdesk-workspace/src/*.rs' 'rust/slopdesk-tree/src/*.rs') 2> /dev/null || true)
  if [[ -n "${modes_ghost}" ]]; then
    printf '%s\n' "${modes_ghost}" >&2
    fail "rust/slopdesk-workspace grew VideoPaneModes back — the latched video modes are device-local and Swift decodes them; an unreached Rust shape is worse than none, because no input reaches both halves (docs/55 §8)"
  fi
fi

printf 'check-supervisor: four cross-language twins, one implementation each — the tab placement, the text funnel, the bindable port, the latched modes.\n'

# ── The loop-shaped crossings: a whole-collection door, not a door per member ───────────────────
# Both pairs below are one rule asked about `n` members. Read one at a time they were a crossing
# per member on a path that runs per reattach and per render, which is the shape
# `slopdesk_settings_row_fields` and `slopdesk_ws_rail_disambiguated_labels` were widened out of.
# Nothing in the type system stops a caller sliding back to `entry(at: index)` inside a `for`, and
# no test would fail if it did — the answers are identical, only the crossing count moves.

SWIFT_REPLAY_BUFFER=Sources/SlopDeskTransport/ReplayBuffer.swift

# The message slot's METADATA crosses once for the whole slot. Losing this call means the file went
# back to asking per index, at `3n + 1` crossings for a slot of `n` — on a cold reattach that is a
# whole retained history's worth.
if ! spells 'slopdesk_replay_result_headers' "${SWIFT_REPLAY_BUFFER}" > /dev/null; then
  fail "${SWIFT_REPLAY_BUFFER} no longer calls slopdesk_replay_result_headers — read the WHOLE message slot in one crossing, then one slopdesk_replay_result_copy per message"
fi

# The two per-index metadata doors were DELETED, not kept beside the list door, because
# scripts/check-ffi-doors.py would have called them dead the moment Swift stopped asking. A name
# reappearing anywhere in Swift means someone re-cut a second way to ask what the headers door
# answers — which is the case that file's own guidance names.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
if hit=$(spells 'slopdesk_replay_result_seq|slopdesk_replay_result_len' $(repo_files 'Sources/**/*.swift') $(repo_files 'Tests/**/*.swift')); then
  fail "${hit} asks for one message's seq or length — those doors are gone; slopdesk_replay_result_headers answers the whole slot at once"
fi

# The SHAPE, not just the names: an index range mapped over the slot is how the per-member loop
# comes back even under different door names. The live reader walks the headers it was handed.
if hit=$(spells '\(0\.\.<count\)\.map|for index in 0\.\.<count' "${SWIFT_REPLAY_BUFFER}"); then
  fail "${hit} walks the message slot by index again — take the headers in one crossing and enumerate those"
fi

SWIFT_BLOCK_MODEL=Sources/SlopDeskWorkspaceCore/Terminal/TerminalBlockModel.swift
SWIFT_PEEK_REPLY=Sources/SlopDeskWorkspaceCore/Workspace/Domain/PeekReply.swift

# `CommandBlock.statuses(of:)` is the whole-list form. `slopdesk_block_status` stays for the row
# asking about itself, so the ban below is deliberately on the LOOP and not on the single door.
if ! spells 'slopdesk_block_statuses' "${SWIFT_BLOCK_MODEL}" > /dev/null; then
  fail "${SWIFT_BLOCK_MODEL} no longer calls slopdesk_block_statuses — CommandBlock.statuses(of:) answers a whole list in one crossing; the single door is for one row"
fi

# The peek transcript builds inside the overlay's `body`, so a status per block is a crossing per
# block PER RENDER — and the strings it builds are flattened straight back across the same boundary
# on the very next line. It asks through `PeekBlockLine.statusLabels(of:)`, whose `CommandBlock`
# witness runs the list door once.
#
# Scoped to the fold's own parameter, `blocks`: the protocol's DEFAULT witness one screen down is
# `lines.map(\.statusLabel)` and has to stay — it is the honest loop for a stand-in whose label is a
# stored string. Banning the map outright would ban the default with it.
if hit=$(spells 'blocks\.map\(\\\.statusLabel\)' "${SWIFT_PEEK_REPLY}"); then
  fail "${hit} maps statusLabel over its blocks again — that is one block-status door crossing per block per render; ask Line.statusLabels(of:) once"
fi
if ! spells 'statusLabels\(of:' "${SWIFT_PEEK_REPLY}" > /dev/null; then
  fail "${SWIFT_PEEK_REPLY} no longer asks PeekBlockLine.statusLabels(of:) — the whole-list form is what keeps the transcript off a per-block crossing"
fi
printf 'check-supervisor: the loop-shaped crossings are whole-collection doors — the message slot and the block ring.\n'

# ── What Settings OFFERS is one table, not one per framework ──────────────────────────────────
# The choices, their labels, their honest captions, the taxonomy and the ladders' stops and readouts
# are `slopdesk_workspace::settings_catalog`. They were already lifted once, out of view bodies into
# a Swift catalog, and the argument for lifting them did not stop at the view boundary: the table has
# no framework in it, and the two halves of the UI split were about to read it from two.
#
# The two Swift files that held it must stay gone. A card grid has no "…", so a group that drifted
# between the two languages would render a DIFFERENT set of choices per platform with nothing on
# screen saying so, and both halves would keep passing their own tests.
for gone in SettingsOption SettingsOptionCatalog; do
  if [[ -e "Sources/SlopDeskClientCore/Settings/${gone}.swift" ]]; then
    fail "Sources/SlopDeskClientCore/Settings/${gone}.swift is back — the settings catalog is Rust (docs/56)"
  fi
done
catalog_swift=Sources/SlopDeskClientCore/Settings/SettingsCatalog.swift
if [[ ! -e "${catalog_swift}" ]]; then
  fail "${catalog_swift} is gone — without it no settings control has any choices to offer (docs/56)"
fi
# The marshaller must actually call the doors. A `SettingsCatalog` that answered from a Swift array
# again would pass every test above, because the tests read it rather than the boundary.
for door in slopdesk_settings_option_group slopdesk_settings_density_token \
  slopdesk_settings_section_count slopdesk_settings_section_id slopdesk_settings_section_title \
  slopdesk_settings_section_symbol slopdesk_settings_timing_label \
  slopdesk_settings_timing_symbol slopdesk_settings_ladder slopdesk_settings_ladder_preset_count \
  slopdesk_settings_ladder_preset_value slopdesk_settings_ladder_preset_label slopdesk_settings_ladder_readout; do
  if ! grep -qF "${door}" "${catalog_swift}"; then
    fail "${catalog_swift} stopped calling ${door} — an answer it holds itself is a table written twice"
  fi
  if ! grep -qF "${door}" rust/slopdesk-ffi/include/slopdesk_ffi.h; then
    fail "${door} is missing from slopdesk_ffi.h — Swift cannot reach a door the header does not name"
  fi
done

catalog_swift=Sources/SlopDeskClientCore/Settings/SettingsCatalog.swift

# ═════════════════════════════════════════════════════════════════════════════════════════
# HUNK B — the option groups cross WHOLE, and they cross ONCE.
#
# `SettingsCatalog.tokens(_:)` is what `options(_:as:)`, `stringOptions(_:)` and `label(_:for:)`
# all forward to, so naming one token used to rebuild the whole group: `1 + 4n` doors, each
# answering a STRING, which on the near side is a 64-byte `[UInt8]` and a `String` per field.
# Measured at 51.3 µs for the twenty-three groups, and every reader above it sits in a SwiftUI
# `body` or an `NSView` rebuild — the phone's all-settings list paid it per keystroke.
#
# TWO properties, and the second is the one a future edit is likely to lose. The group must
# cross in one delivery, AND the delivery must be read into a `static let`: a `tokens(_:)` that
# went back to calling the door per read would still be one crossing and still be 10 µs of
# allocation on every render pass, with nothing on either side saying so.
#
# BREAK-TESTED, both arms, against the real tree:
#   · deleting `private static let groupRows` from the catalog ⇒ FAIL (the memo rule fires)
#   · rewriting `tokens(_:)` to call `rows(of: group)` directly ⇒ FAIL (same rule; the
#     `groupRows[` read is what the ban looks for, so the door coming back is visible)
# Both restored from /tmp copies, never `git checkout`.
if ! grep -qF 'private static let groupRows' "${catalog_swift}"; then
  fail "${catalog_swift} stopped memoising the option groups — ${catalog_swift}'s tokens(_:) is what every settings face forwards to, and a per-read crossing there is 51 µs of marshalling per render pass (docs/55 §4)"
fi
if ! grep -qF 'groupRows[Int(group.rawValue)]' "${catalog_swift}"; then
  fail "${catalog_swift}'s tokens(_:) no longer reads groupRows — a face that asks the door again is the loop this port deleted"
fi

# And no settings RENDERER may open the option-group door itself. The catalog face is the one
# reader, the same way neither settings renderer opens the layout-page door: a second reader is
# a second memo that is not one, and it would cross per render for a table that cannot change.
#
# BREAK-TESTED: adding `slopdesk_settings_option_group(0, nil, 0)` to
# Sources/SlopDeskPhoneUI/Settings/SettingsPages.swift ⇒ FAIL, naming that file. Restored from
# a /tmp copy.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
if renderer=$(spells 'slopdesk_settings_option_group' \
  $(repo_files 'Sources/SlopDeskPhoneUI/**/*.swift') $(repo_files 'Sources/SlopDeskMacUI/**/*.swift') \
  2> /dev/null); then
  fail "${renderer} opens the option-group door itself — the choices are ${catalog_swift}'s to read once, not a renderer's to re-read per body"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════
# HUNK C — the cheat sheet's rows are a CONSTANT, and must stay declared as one.
#
# `CheatSheetContent.sections` reads two `static let` registry tables and renders each row's
# DEFAULT chord, so its answer cannot change between two reads. As a computed `static var` it
# was rebuilt on every one: 54 chord-bearing rows, each paying a `binding(for:)` that rebuilds
# the 85-element `allBindings` array before scanning it (measured 1.43 µs) plus a glyph door and
# its marshalling (254 ns) — ~86 µs, and the phone reads it from a `body`.
#
# A `var` is the whole defect and it is one keyword, which is exactly the edit a pattern ban can
# see. `WorkspaceCommands` is the same shape in the menu bar and gets the same treatment.
#
# BREAK-TESTED, both arms:
#   · `static let sections` → `static var sections` in CheatSheetContent.swift ⇒ FAIL
#   · `titlesByID` deleted from WorkspaceCommands.swift ⇒ FAIL
# Both restored from /tmp copies.
cheat_sheet=Sources/SlopDeskClientCore/Overlays/CheatSheetContent.swift
if [[ ! -e "${cheat_sheet}" ]]; then
  fail "${cheat_sheet} is gone — the ⌘/ sheet's rows are the registry's, below both renderers"
fi
if grep -qE '^[[:space:]]*public static var sections' "${cheat_sheet}"; then
  fail "${cheat_sheet} made sections a computed var again — it renders DEFAULT chords off two static tables, so every read rebuilt an 86 µs answer that cannot have changed"
fi
menu_commands=Sources/SlopDeskMacUI/Commands/WorkspaceCommands.swift
if [[ -e "${menu_commands}" ]] && ! grep -qF 'titlesByID' "${menu_commands}"; then
  fail "${menu_commands} stopped memoising its row titles — a Commands body re-evaluates on any observed store change, and the glyph lookup in front of each title is an 85-element array rebuild"
fi
printf 'check-supervisor: the settings option groups cross whole and are read once; the cheat sheet and the menu bar hold their constants.\n'
# And no settings VIEW may spell a choice's own words. A label typed into a card is the second table:
# it renders, it looks right, and it is unreachable from the pin that would have caught it.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
settings_words=$(spells 'SettingsOption\(\.|"Applies (now|on reconnect)"|"(Copy or paste|Left only|Right only)"' \
  $(repo_files 'Sources/SlopDeskPhoneUI/Settings/*.swift') $(repo_files 'Sources/SlopDeskMacUI/**/*.swift') \
  2> /dev/null || true)
if [[ -n "${settings_words}" ]]; then
  printf '%s\n' "${settings_words}" >&2
  fail "a settings view spelled a CHOICE — the words are settings_catalog's, the view only draws them"
fi
printf 'check-supervisor: what Settings offers is one Rust table; SettingsCatalog.swift only reads it.\n'

# ── A setting is NAMED once ───────────────────────────────────────────────────────────────────
# The row table — every key with its label, its one-line description, its default and where it is
# edited — is `slopdesk_workspace::settings_rows`. `AllSettingsCatalog.swift` is the near side, and it
# must stay a marshaller: a Swift array of rows would pass every test that reads it.
rows_swift=Sources/SlopDeskWorkspaceCore/Workspace/Store/AllSettingsCatalog.swift
if [[ ! -e "${rows_swift}" ]]; then
  fail "${rows_swift} is gone — nothing would advertise a setting to the all-settings list (docs/56)"
fi
# The seven per-field doors are no longer in this list. They still EXIST, and three callers that
# want exactly one string still ask them — but reading a whole row through them cost eight crossings
# per row on every settings-search keystroke, so `entry(at:)` asks `slopdesk_settings_row_fields`
# instead and gets the row tagged and length-prefixed in one. Requiring the field doors here would
# have required the shape the port removed; the ratchet that the row crosses WHOLE is further down.
for door in slopdesk_settings_row_count slopdesk_settings_row_key slopdesk_settings_row_fields \
  slopdesk_settings_row_is_inline_editable \
  slopdesk_settings_row_persistence slopdesk_settings_row_index slopdesk_settings_row_matches; do
  if ! grep -qF "${door}" "${rows_swift}"; then
    fail "${rows_swift} stopped calling ${door} — a row it describes itself is a table written twice"
  fi
  if ! grep -qF "${door}" rust/slopdesk-ffi/include/slopdesk_ffi.h; then
    fail "${door} is missing from slopdesk_ffi.h — Swift cannot reach a door the header does not name"
  fi
done
# And no view may TYPE a row's label. A setting is named on the page where it is set and again in the
# searchable list, and those are the same words for the same job — they were two strings, and two was
# already one too many ("Hide Mouse While Typing" vs "…When Typing", "Long-Command Notification" vs
# "…Completion"). The labels are read out of the Rust table here and grepped for verbatim, so a
# re-typed one fails by its own text. The DESCRIPTION is deliberately not covered: an index blurb and
# an in-context subtitle are two registers, and docs/56 §18 says so.
row_labels=$(sed -n 's/^        label: "\(.*\)",$/\1/p' rust/slopdesk-settings/src/settings_rows.rs)
if [[ -z "${row_labels}" ]]; then
  fail "no row labels parsed out of settings_rows.rs — the ratchet below would pass by reading nothing"
fi
# Comments are STRIPPED first, exactly as `spells()` does it: the note above `settingLabel` cites the
# two spellings that drifted, and a gate that cannot quote the bug it prevents is a gate nobody may
# document.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
settings_view_code=$(awk '{ line = $0; sub(/\/\/.*/, "", line); printf "%s:%d:%s\n", FILENAME, FNR, line }' \
  $(repo_files 'Sources/SlopDeskPhoneUI/Settings/*.swift') \
  $(repo_files 'Sources/SlopDeskMacUI/**/*.swift') 2> /dev/null || true)
typed_labels=$(printf '%s\n' "${row_labels}" | while IFS= read -r label; do
  [[ -z "${label}" ]] && continue
  grep -F "\"${label}\"" <<< "${settings_view_code}" || true
done)
if [[ -n "${typed_labels}" ]]; then
  printf '%s\n' "${typed_labels}" >&2
  fail "a settings view TYPED a row's label — ask settingLabel(key); the words are settings_rows'"
fi
printf 'check-supervisor: a setting is named once — %s rows, and no view spells one.\n' \
  "$(printf '%s\n' "${row_labels}" | grep -c .)"

# ── A render field's KEY is a row's key ───────────────────────────────────────────────────────
# `AllSettingsCatalog.RenderKey` spells two dozen config-style names — `font-family`, `video-fec-k`
# — that `settings_rows` already spells as row keys. Unlike the sets beside them, these CANNOT
# become a door: a Swift `switch` case needs a compile-time constant, which is the wall
# `PaneLivenessState` hit. So the answer is the one that worked there — compare the two halves as
# TEXT, before either is compiled. A name here that no row advertises is a view asking for a row
# that does not exist, which renders as nothing and fails no test.
render_keys=$(sed -n '/public enum RenderKey {/,/^    }$/p' "${rows_swift}" |
  sed -n 's/^        public static let [A-Za-z]* = "\(.*\)"$/\1/p' | sort -u) || true
row_keys=$(sed -n 's/^        key: "\(.*\)",$/\1/p' rust/slopdesk-settings/src/settings_rows.rs |
  sort -u) || true
if [[ -z "${render_keys}" || -z "${row_keys}" ]]; then
  fail "RenderKey or the row keys read as EMPTY — the comparison below would pass by comparing nothing"
fi
orphan_render_keys=$(comm -23 <(printf '%s\n' "${render_keys}") <(printf '%s\n' "${row_keys}"))
if [[ -n "${orphan_render_keys}" ]]; then
  printf '%s\n' "${orphan_render_keys}" >&2
  fail "a RenderKey names no row in settings_rows.rs — the two spellings of that key have drifted"
fi
printf 'check-supervisor: %s render-field keys, every one of them a row settings_rows advertises.\n' \
  "$(printf '%s\n' "${render_keys}" | grep -c .)"

# ── …AND A SETTING'S KEY IS SPELLED ONCE, in the other half of the same alphabet ───────────────
# `settings_rows.rs` names its keys in two notations, and the gate above only ever read one of them.
# The 25 config-style names (`font-family`, `video-fec-k`) are `RenderKey`'s, compared just now. The
# other 68 are dotted `UserDefaults` keys — `controls.copyOnSelect`, `notifications.longCommand` —
# and every one of them is ALSO a `static let` in `SettingsKey.swift`, character for character,
# because a `Defaults.Key` name cannot leave Swift and the Rust row has to quote it to advertise it.
#
# Sixty-eight strings written twice, and until this gate nothing compared them. `SettingsKey` is not
# named anywhere else in this file, and `check-shared-constants.py` cannot see a string at all — its
# docstring says so outright. A typo on either side compiles, passes every test, and ships a
# settings row bound to a key nothing reads: the toggle moves, the plist gains an orphan entry, and
# the feature it was supposed to control never changes. There is no error anywhere in that story.
#
# `AllSettingsCatalogTests` is the closest thing that existed, and it is a different instrument: it
# asserts that a HAND-MAINTAINED list of ~40 `SettingsKey` constants is covered by the catalog. A
# key nobody thought to add to that list — and the 28 that are not on it — was covered by nothing.
#
# ONE DIRECTION, deliberately. Every dotted row key must be a `SettingsKey`; the reverse is false on
# purpose, because 11 `SettingsKey` constants are internal state rather than settings
# (`window.savedFrame`, `firstLaunch.completed`, `shell.openedCodeProjects`) and have no row by
# design. A reverse gate would need an allowlist of those 11, and an allowlist is the thing that
# goes stale. One direction is enough to catch a typo on EITHER side: the two spellings stop being
# equal, and the row key stops being found.
#
# The dot/dash split is the classifier, and it is checked rather than assumed — a key carrying both
# notations, or neither, means the two alphabets have started to blur and this gate is reading the
# wrong half.
settings_key_swift=Sources/SlopDeskWorkspaceCore/Workspace/Store/SettingsKey.swift
if [[ ! -e "${settings_key_swift}" ]]; then
  fail "${settings_key_swift} is gone — the settings keys settings_rows.rs quotes have no near side (docs/56)"
fi
ambiguous_row_keys=$(printf '%s\n' "${row_keys}" | grep -vE '^([^-]*\.[^-]*|[^.]*-[^.]*)$' || true)
if [[ -n "${ambiguous_row_keys}" ]]; then
  printf '%s\n' "${ambiguous_row_keys}" >&2
  fail "a settings_rows key is neither a dotted UserDefaults key nor a dashed config name — this gate can no longer tell the two alphabets apart"
fi
defaults_row_keys=$(printf '%s\n' "${row_keys}" | grep -E '^[^-]*\.[^-]*$' | sort -u || true)
settings_key_names=$(sed -nE 's/^    public static let [A-Za-z0-9]+(: String)? = "([^"]*)".*$/\2/p' \
  "${settings_key_swift}" | sort -u) || true
if [[ -z "${defaults_row_keys}" || -z "${settings_key_names}" ]]; then
  fail "the dotted row keys or the SettingsKey constants read as EMPTY — the comparison below would pass by comparing nothing"
fi
orphan_row_keys=$(comm -23 <(printf '%s\n' "${defaults_row_keys}") <(printf '%s\n' "${settings_key_names}"))
if [[ -n "${orphan_row_keys}" ]]; then
  printf '%s\n' "${orphan_row_keys}" >&2
  fail "a settings_rows key is not a SettingsKey constant — that row edits a UserDefaults key nothing reads (docs/56)"
fi
printf 'check-supervisor: %s settings keys, each spelled once and quoted by its row.\n' \
  "$(printf '%s\n' "${defaults_row_keys}" | grep -c .)"

# ── …and the config BRIDGE switches on the same names, not on its own ──────────────────────────
# `PreferencesStore+ConfigBridge` is the third place a render key is spelled: three `switch`
# statements over the same five names — read the value, write it, restore its default — none of
# which goes through `RenderKey`. The two lists above are compared to each other; this file is
# compared to neither, and it is the one where a typo is completely silent. A `switch` over a
# `String` has a `default:` arm, so `case "font-siz":` does not fail to compile and does not fail to
# run — it stops matching, and the row goes on rendering its current value while the write that was
# supposed to follow it lands nowhere.
#
# One direction, like the render keys: the bridge covers a SUBSET (the terminal config keys, not the
# video or the font-fallback ones), so a key it does not mention is not a finding. A name it does
# mention that no row advertises is.
CONFIG_BRIDGE=Sources/SlopDeskWorkspaceCore/Workspace/Store/PreferencesStore+ConfigBridge.swift
if [[ ! -e "${CONFIG_BRIDGE}" ]]; then
  fail "${CONFIG_BRIDGE} is gone — the typed prefs models have no bridge to the row keys (docs/56)"
fi
bridge_keys=$(sed -nE 's/^[[:space:]]*case "([^"]*)".*$/\1/p' "${CONFIG_BRIDGE}" | sort -u) || true
if [[ -z "${bridge_keys}" ]]; then
  fail "${CONFIG_BRIDGE} switches on no key at all — this gate reads nothing and would pass"
fi
orphan_bridge_keys=$(comm -23 <(printf '%s\n' "${bridge_keys}") <(printf '%s\n' "${row_keys}"))
if [[ -n "${orphan_bridge_keys}" ]]; then
  printf '%s\n' "${orphan_bridge_keys}" >&2
  fail "${CONFIG_BRIDGE} switches on a name no settings_rows key spells — that arm can never match"
fi
printf 'check-supervisor: %s config-bridge arms, every one of them a key settings_rows advertises.\n' \
  "$(printf '%s\n' "${bridge_keys}" | grep -c .)"

# ── A platform gate on a settings page is DATA, and a PAGE crosses whole ────────────────────────
# Which groups a page shows, in what order, and which platform each belongs to is
# `slopdesk_workspace::settings_layout`. `SettingsLayout.swift` is the near side and
# `rust/slopdesk-ffi/src/settings_layout.rs` is the marshalling.
#
# Both sides are read below, so both are established first: a gate that greps a file that is not
# there prints `grep: No such file` and then keeps going, which buries the one message that says
# what actually happened.
layout_swift=Sources/SlopDeskClientCore/Settings/SettingsLayout.swift
layout_ffi=rust/slopdesk-ffi/src/settings_layout.rs
layout_header=rust/slopdesk-ffi/include/slopdesk_ffi.h
if [[ ! -e "${layout_swift}" ]]; then
  fail "${layout_swift} is gone — a settings page would have to spell its own shape again (docs/56)"
elif [[ ! -e "${layout_ffi}" ]]; then
  fail "${layout_ffi} is gone — the settings page shape has no marshalling left (docs/55 §2)"
else
  # The ONE door, on both sides. It used to be TEN, addressed positionally — a group count, then a
  # title, a timing and a row count per group, then six more per row — which is `1 + 3G + 6R`
  # crossings to answer one question, asked from inside a body both renderers re-evaluate whenever a
  # `@Default` on the page changes.
  #
  # `-E` with a word boundary rather than `-F`: a plain substring passes on a door RENAMED to
  # `…_pagev2`, which is exactly the shape a "just one more door" change takes, and the gate would
  # then be checking nothing. Break-tested both ways — renamed, and removed outright.
  if ! grep -qE 'slopdesk_settings_layout_page\b' "${layout_swift}"; then
    fail "${layout_swift} stopped calling slopdesk_settings_layout_page — a page shape it holds itself is a table written twice (docs/56)"
  fi
  # Matched WITH its opening parenthesis, which is what `build-ffi.sh` greps the header for when it
  # builds the symbol list every slice must carry — so this gate and that one cannot disagree about
  # what counts as a declaration.
  if ! grep -qE 'slopdesk_settings_layout_page\(' "${layout_header}"; then
    fail "slopdesk_settings_layout_page is missing from slopdesk_ffi.h — Swift cannot reach a door the header does not name (docs/55 §2)"
  fi
  # And the positional walk must not grow back. This is not a style rule. Each of those doors
  # RE-DERIVED the whole page to reach one member — `settings_layout::row_at` filters the flat
  # 42-entry table into a fresh list, then filters that group's rows into a second — so laying out
  # Appearance made ~166 crossings that did ~166 filters and ~330 allocations to read 23 `&'static`
  # rows. Nothing failed while it did, because every answer was RIGHT; the only trace was the frame
  # rate under a slider drag on that page. A door is born in the header and in the shim, so that is
  # where this is caught, and it is caught in both because either alone can be edited on its own.
  layout_positional='slopdesk_settings_layout_(group_count|group_title|group_timing|row_count|row_key|row_subtitle|row_glyph|row_bespoke_id|row_control)'
  if grep -qE "${layout_positional}" "${layout_header}"; then
    fail "slopdesk_ffi.h declares a per-index settings-layout door again — a page crosses WHOLE, and a positional door rebuilds the page once per member (docs/55 §4)"
  fi
  if grep -qE "extern \"C\" fn ${layout_positional}" "${layout_ffi}"; then
    fail "${layout_ffi} exported a per-index settings-layout door again — a page crosses WHOLE (docs/55 §4)"
  fi
  # The page crosses ONCE, and it crosses through `SettingsLayout.swift`. A renderer that opens the
  # door itself is a second delivery per body evaluation, and the Mac and phone settings faces are
  # exactly where that is convenient, because both already hold a `SettingsLayout.Group`. Through
  # `spells` so a file that merely NAMES the door in a comment is not a finding — break-tested in
  # both directions, a real call fires and a `//` mention does not.
  mapfile -t layout_renderers < <(repo_files 'Sources/SlopDeskMacUI/**/*.swift' 'Sources/SlopDeskPhoneUI/**/*.swift')
  if ((${#layout_renderers[@]} < 20)); then
    fail "the settings renderer corpus read as fewer than 20 files — this ban has gone vacuous and is checking nothing"
  else
    if found=$(spells 'slopdesk_settings_layout' "${layout_renderers[@]}"); then
      printf '%s\n' "${found}" >&2
      fail "${found} opens the settings-layout door itself — the page crosses once, through ${layout_swift}, and a renderer that asks again pays a delivery per body evaluation (docs/55 §4)"
    fi
  fi
  # The near side's first guess at a page's size, and the Rust test that proves no page outgrew it.
  # One number, two spellings. A page that stopped fitting would still be CORRECT — §4's retry
  # fetches it — and would silently cost every settings render TWO crossings instead of the one this
  # port exists to deliver, with nothing on either side saying so. Break-tested at a drifted value
  # and at a renamed constant, where `same`'s empty-side arm is what fires.
  same 'the settings page first-guess buffer' \
    "$(sed -nE 's/^ *private static let inlineCapacity = ([0-9]+)$/\1/p' "${layout_swift}")" \
    "$(sed -nE 's/^ *const SWIFT_FIRST_GUESS: usize = ([0-9]+);$/\1/p' "${layout_ffi}")"
  # The two tests that make the delivery checkable at all: one walks EVERY row of EVERY page on BOTH
  # halves against the table the deleted index doors read, the other measures every page against the
  # buffer above. Delete either and the suite stays green over a layout nothing pins.
  for layout_test in every_row_of_every_page_matches_the_table_the_index_doors_read \
    every_page_fits_the_near_sides_first_guess; do
    if ! grep -qF "${layout_test}" "${layout_ffi}"; then
      fail "${layout_ffi} dropped ${layout_test} — the page delivery is then pinned by nothing (docs/55 §4)"
    fi
  done
fi
# The point of the table is that a gate became a VALUE, so the gate must not grow back. `Half.current`
# was that gate's last hiding place: a `#if os(macOS)` inside an otherwise shared file, answering
# "which half am I" at COMPILE time in a target that compiled for both. Increment 63 split the halves,
# so it answers `.phone` outright and the Mac names `.mac` at its own call sites.
#
# ⚠️ THIS USED TO COUNT, AND THE COUNT OUTLIVED ITS SUBJECT — see the note on the phone-directive gate
# in the UI-split section for the whole story. What is asserted now is the VALUE, which is the thing
# the table bought: `current` exists, and it is a constant rather than a fork.
half_current=$(sed -E 's,//.*,,' Sources/SlopDeskPhoneUI/Settings/SettingsControls.swift |
  grep -A 2 'static var current' || true)
if [[ -z "${half_current}" ]]; then
  fail "SettingsLayout.Half.current is gone — a settings page has no way to say which half it is"
fi
if grep -q '#if' <<< "${half_current}"; then
  printf '%s\n' "${half_current}" >&2
  fail "SettingsLayout.Half.current forked on a platform again — it is one half's constant now (docs/56)"
fi
# A ported page renders from the table, so it may not name a group header it draws.
layout_titles=$(sed -n 's/^        title: "\(.*\)",$/\1/p' rust/slopdesk-settings/src/settings_layout.rs)
if [[ -z "${layout_titles}" ]]; then
  fail "no group titles parsed out of settings_layout.rs — the ratchet below would pass by reading nothing"
fi
typed_titles=$(printf '%s\n' "${layout_titles}" | while IFS= read -r title; do
  [[ -z "${title}" ]] && continue
  grep -F "slateFormSection(\"${title}\")" <<< "${settings_view_code}" || true
done)
if [[ -n "${typed_titles}" ]]; then
  printf '%s\n' "${typed_titles}" >&2
  fail "a settings view TYPED a group header the layout table already holds — render it from the table"
fi
printf 'check-supervisor: a settings page is SHAPED once — %s groups crossed, one gate names the half.\n' \
  "$(printf '%s\n' "${layout_titles}" | grep -c .)"

# ── One chord editor, drawn twice ─────────────────────────────────────────────────────────────
# Key Bindings is `Platform::Both`, so it is the one BESPOKE group the Mac draws itself rather than
# hosting: its recorder is an `NSEvent` monitor scoped to the Settings window, and a monitor is not a
# view. Two drawings over one registry is fine; two answers to "what did the user just press" or "does
# this row match the search" is not, and neither fails loudly — a second capture table just quietly
# records a chord the dispatcher will never fire.
for half in Sources/SlopDeskMacUI/Settings/MacKeybindingsEditor.swift \
  Sources/SlopDeskPhoneUI/Settings/KeybindingsEditorView.swift; do
  for spelling in WorkspaceBindingRegistry KeybindingsEditorModel; do
    if ! grep -q "${spelling}" "${half}"; then
      fail "${half} stopped reading ${spelling} — two chord editors, and the drift would be silent"
    fi
  done
done
# BOTH halves record, and neither owns a capture table. The Mac reads an `NSEvent` and asks
# `KeybindingCapture` (`slopdesk_video::key_naming`, off a macOS virtual key code); the phone reads a
# `UIKey` and asks `PhoneKey.captureOutcome` (`slopdesk_workspace::phone_key`, off its HID usage). The
# two tables live in crates that cannot see each other, so their agreement is a test in `slopdesk-ffi`,
# which can — and that test is what stops a phone rebind from being written under a spelling the Mac's
# lookup never builds. A half that decided a verdict ITSELF would pass every editor test above.
if ! grep -q 'PhoneKey.captureOutcome' Sources/SlopDeskPhoneUI/Settings/KeybindingsEditorView.swift; then
  fail "the phone's chord editor stopped asking PhoneKey.captureOutcome — a second capture table is silent"
fi
if ! grep -q 'KeybindingCapture.outcome' Sources/SlopDeskMacUI/Settings/MacKeybindingsEditor.swift; then
  fail "the Mac's chord editor stopped asking KeybindingCapture — a chord it records may never fire"
fi
if ! grep -q 'the_two_recorders_agree_on_every_key_both_can_name' rust/slopdesk-ffi/src/phone_key.rs; then
  fail "the recorders' agreement test is gone — the two capture tables can now drift silently"
fi
# The two override writers PRESERVE `textBindings` / `unbinds`. Rebuilding the model as
# `KeybindingPreferences(overrides:)` defaults both to empty, so a single rebind in Settings silently
# wipes every config.toml literal-byte binding — the audit bug, and it looks like nothing at all.
# (`KeybindingPreferences()` with no arguments is the GLOBAL reset and is meant to clear everything.)
if spells 'KeybindingPreferences\(overrides:' Sources/SlopDeskMacUI/Settings/MacKeybindingsEditor.swift \
  Sources/SlopDeskPhoneUI/Settings/KeybindingsEditorView.swift > /dev/null; then
  fail "a chord editor rebuilt KeybindingPreferences — that wipes the config.toml literal-byte bindings"
fi
printf 'check-supervisor: one chord editor, drawn twice, and both halves record from one table.\n'

# ── One bespoke settings surface, drawn twice and spelled once ─────────────────────────────────
# `Control.bespoke(id)` is the layout table admitting a group is not a list of settings, so those
# groups carry the settings words that the table cannot: an empty page stating its own emptiness, a
# card writing `~/.claude/settings.json`, a caret preview, a font specimen, the searchable index.
# They had ONE renderer until increment 49, which is how every word in them came to have a single
# speller BY ACCIDENT. There are two now, and the accident does not survive a second drawing.
for pair in \
  "Sources/SlopDeskPhoneUI/Settings/SettingsBespokeSurfaces.swift:SettingsBespokePresentation" \
  "Sources/SlopDeskMacUI/Settings/MacSettingsBespokeSurfaces.swift:SettingsBespokePresentation" \
  "Sources/SlopDeskPhoneUI/Settings/AllSettingsListView.swift:SettingsIndexPresentation" \
  "Sources/SlopDeskMacUI/Settings/MacAllSettingsIndex.swift:SettingsIndexPresentation" \
  "Sources/SlopDeskPhoneUI/Settings/CursorPreviewView.swift:CursorColorHex" \
  "Sources/SlopDeskMacUI/Settings/MacCursorPreviewSurface.swift:CursorColorHex"; do
  half="${pair%%:*}"
  face="${pair##*:}"
  if ! grep -q "${face}" "${half}" 2> /dev/null; then
    fail "${half} stopped reading ${face} — a bespoke surface deciding for itself is the second speller (docs/56, increment 49)"
  fi
done
# The index's option lists are the CATALOG's. Thirteen were typed at the SwiftUI control as
# `Text(…).tag(…)` before increment 49 and FOUR had drifted — "Context Menu" against the catalog's
# "Context menu", "Home" against "Home Directory". Naming the group is what makes a fourteenth list
# impossible to type, so both index renderers must ask for a group rather than build one.
for index in Sources/SlopDeskPhoneUI/Settings/AllSettingsListView.swift \
  Sources/SlopDeskMacUI/Settings/MacAllSettingsIndex.swift; do
  if ! grep -q 'SettingsIndexPresentation.optionGroup' "${index}"; then
    fail "${index} stopped asking optionGroup — an option list typed at a control is how four labels drifted"
  fi
done
# And the on-launch pair, which is the drift increment 49 found rather than prevented: the checklist
# spelled "Restore Last Session" while Settings → General read ON_LAUNCH and said "Restore session".
if ! grep -q 'SettingsCatalog.label(.onLaunch' Sources/SlopDeskClientCore/FirstLaunch/FirstLaunchStepPresentation.swift; then
  fail "OnLaunchBehavior.title stopped reading ON_LAUNCH — the checklist and Settings named one choice twice before"
fi
# One hex parser under the two colour wells. A second one keeps passing both halves' tests while
# rounding a channel differently, and the value it writes is a libghostty `cursor-color` string.
hex_parsers=$(grep -rln 'radix: 16' Sources/SlopDeskPhoneUI/Settings Sources/SlopDeskMacUI/Settings 2> /dev/null || true)
if [[ -n "${hex_parsers}" ]]; then
  printf '%s\n' "${hex_parsers}" >&2
  fail "a settings surface parses or prints hex itself — CursorColorHex is the bridge (docs/56, increment 49)"
fi
printf 'check-supervisor: one bespoke settings surface, drawn twice and spelled once.\n'

# ── One panel vocabulary, four surfaces, two renderers ────────────────────────────────────────
# The right panel's four surfaces are drawn twice since increment 51 — `MacCodePanelSurfaces` in
# AppKit, `CodePanelSurfaces` (`#if os(iOS)`) in SwiftUI — off ONE `CodePanelPresentation` in
# `SlopDeskClientCore`. What a surface says and which state it is in are decisions; only the drawing
# is per-half.
for pair in \
  "Sources/SlopDeskPhoneUI/CodeSidebar/CodePanelSurfaces.swift:CodePanelPresentation" \
  "Sources/SlopDeskMacUI/Panel/MacCodePanelSurfaces.swift:CodePanelPresentation" \
  "Sources/SlopDeskPhoneUI/CodeSidebar/CodePanelSurfaces.swift:CodeOpenGateReading" \
  "Sources/SlopDeskMacUI/Panel/MacPanelEmptyStates.swift:CodeOpenGateReading"; do
  half="${pair%%:*}"
  face="${pair##*:}"
  if ! grep -q "${face}" "${half}" 2> /dev/null; then
    fail "${half} stopped reading ${face} — a panel surface wording itself is the second speller (docs/56, increment 51)"
  fi
done
# The FOLD, not just the words. Gate outranks root outranks awaited-key outranks placeholder, and
# that ordering had already drifted between the two halves before it descended: the Mac deferred the
# poll behind the open gate and the phone did not. Both must ask for the state rather than switch.
for renderer in Sources/SlopDeskPhoneUI/CodeSidebar/CodePanelSurfaces.swift \
  Sources/SlopDeskMacUI/Panel/MacCodePanelSurfaces.swift; do
  if ! grep -q 'CodePanelPresentation.workbench(' "${renderer}"; then
    fail "${renderer} folds the workbench phase itself — the four states are one switch, one floor down"
  fi
done
# ONE poll task, outside the state switch. The first draft of the phone's renderer hung a
# `.task(id:)` on three of the four branches, which reads correctly and cancels the poll on every
# transition the poll itself caused. Three is the bug's signature; one is the fix.
poll_tasks=$(grep -c '\.task(id: pollKey)' Sources/SlopDeskPhoneUI/CodeSidebar/CodePanelSurfaces.swift || true)
if [[ "${poll_tasks}" != "1" ]]; then
  fail "the phone's code poll is attached ${poll_tasks} times — a task per branch restarts the loop it caused"
fi
# The macOS half of the webview mount stays deleted: it is `MacCodeWorkbenchView`, an `NSView`, and a
# representable in the phone's target would be the second mount racing the same pooled page.
if grep -rq 'NSViewRepresentable' Sources/SlopDeskPhoneUI/CodeSidebar/ 2> /dev/null; then
  fail "a CodeSidebar representable came back — the Mac mounts the pooled webview in AppKit (docs/56, increment 51)"
fi
# And the clip is measured once. Two `static let`s carrying one measurement is how the phone kept
# clipping 30pt after the workbench moved its title bar.
clip_owners=$(grep -rl 'let clippedTitleBarHeight' Sources/ 2> /dev/null || true)
if [[ "${clip_owners}" != "Sources/SlopDeskClientCore/CodeSidebar/CodePanelPresentation.swift" ]]; then
  fail "the clipped title-bar height is declared outside CodePanelPresentation — one measurement, one owner"
fi
printf 'check-supervisor: one panel vocabulary, four surfaces, two renderers.\n'

# ── Two device panels, drawn twice and spelled once ───────────────────────────────────────────
# Increment 52. Each panel has an AppKit renderer in `SlopDeskMacUI/Panel/<Device>/` and a SwiftUI one
# in `SlopDeskPhoneUI/<Device>/`, off one `*Presentation` in `SlopDeskDevicePanels`.
for pair in \
  "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorSurface.swift:SimulatorSidebarModel" \
  "Sources/SlopDeskMacUI/Panel/Android/MacAndroidSurface.swift:AndroidSidebarModel" \
  "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorDeviceList.swift:SimulatorPresentation" \
  "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorDeviceList.swift:SimulatorPresentation" \
  "Sources/SlopDeskPhoneUI/Panel/Android/AndroidDeviceList.swift:AndroidPresentation" \
  "Sources/SlopDeskMacUI/Panel/Android/MacAndroidDeviceList.swift:AndroidPresentation"; do
  half="${pair%%:*}"
  face="${pair##*:}"
  if ! grep -q "${face}" "${half}" 2> /dev/null; then
    fail "${half} stopped reading ${face} — a device panel wording itself is the second speller (docs/56, increment 52)"
  fi
done
# The phone's fifteen are the PHONE's. A macOS caller reaching back into them is the AppKit half
# half-ported, which compiles perfectly well and ships two renderers for one surface.
ungated=$(grep -rLn '#if os(iOS)' Sources/SlopDeskPhoneUI/Panel/Simulator/ Sources/SlopDeskPhoneUI/Panel/Android/ 2> /dev/null || true)
if [[ -n "${ungated}" ]]; then
  printf '%s\n' "${ungated}" >&2
  fail "a device-panel view lost its iOS gate — the Mac draws these in AppKit now (docs/56, increment 52)"
fi
# The two display-layer views are the floor's, and NOT because they are shared: they are `NSView`s
# with no design token and no layout decision in them, which is what kind 2 means. A representable
# back in the phone's target would be a second mount racing the same layer.
for moved in Sources/SlopDeskDevicePanels/Simulator/SimulatorScreenSurface.swift \
  Sources/SlopDeskDevicePanels/Android/AndroidScreenNSView.swift; do
  if ! grep -q 'NSView' "${moved}" 2> /dev/null; then
    fail "${moved} is gone or no longer holds the display-layer NSView (docs/56, increment 52)"
  fi
done
# Comments STRIPPED first: both files' headers name the representable they lost, and a gate that
# cannot quote the rule it guards is a gate nobody may document.
device_code=$(awk '{ line = $0; sub(/\/\/.*/, "", line); printf "%s:%d:%s\n", FILENAME, FNR, line }' \
  Sources/SlopDeskPhoneUI/Panel/Simulator/*.swift Sources/SlopDeskPhoneUI/Panel/Android/*.swift)
if grep -q 'NSViewRepresentable' <<< "${device_code}"; then
  fail "a device screen representable came back — the Mac mounts the NSView directly (docs/56, increment 52)"
fi
# ⚠️ ONE MODIFIER FOLD, WITHIN THE PANELS. `AndroidScreenNSView` carried a private six-line copy for
# exactly one increment, because the shared one sat one target UP while the view was still in the
# phone's half. Both are in the floor now; a second walk in either panel target is that copy back.
#
# Scoped to the two panel targets on purpose. `SlopDeskVideoHost/InputInjector` and
# `SlopDeskVideoClient/VideoWindowView` fold the same flags for the GUI-video path, which is a
# different direction over a different wire — naming them here would be pinning a coincidence.
folds=$(grep -rln 'contains(.capsLock)' Sources/SlopDeskDevicePanels/ Sources/SlopDeskPhoneUI/ \
  Sources/SlopDeskMacUI/ 2> /dev/null || true)
if [[ "${folds}" != "Sources/SlopDeskDevicePanels/Input/DeviceKeyEvent.swift" ]]; then
  printf '%s\n' "${folds}" >&2
  fail "the panels' modifier fold is spelled outside DeviceKeyEvent — one fold, one file, both frameworks"
fi
printf 'check-supervisor: two device panels, drawn twice and spelled once.\n'

# ── And ONE set of shells under both of them ──────────────────────────────────────────────────
# Increment 53. The two AppKit halves each grew a `Mac*Parts.swift`, and eleven of the shells in them
# were the same file twice: the keyed loop, the two label helpers, the section header, the plate tray,
# the glyph button, the spinner, the search plate, the veil, the row shell and the flow grid. They are
# `MacDevicePanelParts.swift` now.
#
# THE TEST IS THE SIGNATURE, and it is the only thing standing between this merge and the device
# abstraction increment 52b banned. A shell taking `String`, `NSView`, `SFSymbol` or nothing at all is
# CHROME and belongs in one file; a function taking a `SimulatorDevice`, a `SimulatorFact`, an
# `AndroidDevice`, an `AndroidFact` or either `Ink` is PROTOCOL and may never be folded — the two
# panels share not one byte of wire, so a common device vocabulary would be an abstraction over a
# coincidence.
MAC_SHARED_PARTS=Sources/SlopDeskMacUI/Panel/MacDevicePanelParts.swift
if hit=$(spells 'SimulatorDevice|SimulatorFact|SimulatorInk|AndroidDevice|AndroidFact|AndroidInk' \
  "${MAC_SHARED_PARTS}"); then
  printf '%s\n' "${hit}" >&2
  fail "${MAC_SHARED_PARTS} names a device type — a shared shell is chrome, never a device abstraction (docs/56, increment 53)"
fi
# The other direction: a shell that went down must not grow back beside one caller. Each of the eleven
# is a `Mac*` name that may exist EXACTLY once, and a re-minted copy compiles perfectly well.
for shell in MacDevicePanelLoop MacDevicePanelSectionHeader MacDevicePanelPlateTray \
  MacDevicePanelGlyphButton MacDevicePanelSpinner MacDevicePanelSearchPlate MacDevicePanelVeil \
  MacDevicePanelRowShell MacDevicePanelGrid; do
  # shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
  owners=$(grep -lE "^(final )?class ${shell}[[:space:]:]" \
    $(repo_files 'Sources/SlopDeskMacUI/*.swift' 'Sources/SlopDeskMacUI/**/*.swift') 2> /dev/null || true)
  if [[ -n "${owners}" && "${owners}" != "${MAC_SHARED_PARTS}" ]]; then
    printf '%s\n' "${owners}" >&2
    fail "${shell} is declared outside ${MAC_SHARED_PARTS} — one shell, one set of constants (docs/56, increment 53)"
  fi
done
# Both halves keep exactly the four that name a device, and each still asks its own `*Presentation`
# for the words. The simulator's Copy title was BUILT IN THE RENDERER until increment 53 while the
# Android half already asked for it — one sentence, two spellings, and only one of them could drift.
for face in Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorParts.swift:SimulatorPresentation \
  Sources/SlopDeskMacUI/Panel/Android/MacAndroidParts.swift:AndroidPresentation; do
  if ! spells "${face##*:}" "${face%%:*}" > /dev/null; then
    fail "${face%%:*} stopped asking ${face##*:} for its words — the renderer is not where a title lives"
  fi
done
if hit=$(spells '"Copy \\\(' Sources/SlopDeskMacUI/Panel/**/*.swift \
  Sources/SlopDeskPhoneUI/Panel/Simulator/*.swift Sources/SlopDeskPhoneUI/Panel/Android/*.swift 2> /dev/null); then
  printf '%s\n' "${hit}" >&2
  fail "a Copy verb is spelled in a renderer — SimulatorPresentation/AndroidPresentation.copyTitle owns it"
fi
# ── And ONE engraved caps heading under the whole AppKit half ─────────────────────────────────
# Increment 55. The four-attribute dictionary that makes a caps micro-heading — the instrument face at
# `Typeface.small`, `.uppercased()`, and `Typeface.instrumentTracking` kerning — was open-coded SIX
# times: the device panel's section header, the palette's section row, Open Quickly's filter header,
# the peek card's `RECENT`, the cheat sheet's categories and the keybindings editor's groups. Five of
# them even carried their own copy of the "wide enough to read as engraving" comment.
#
# `Chrome/MacCapsLabel.swift` is the one recipe. The kerning constant is the tell that cannot be
# faked: any seventh copy has to spell `instrumentTracking` to look the same, so the ban is on that
# name appearing anywhere in this target but the file that owns it. The INK is deliberately not
# pinned — an overlay's ladder is not a page's, and the six sites disagree on purpose.
MAC_CAPS_RECIPE=Sources/SlopDeskMacUI/Chrome/MacCapsLabel.swift
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
if hit=$(spells 'instrumentTracking' \
  $(repo_files 'Sources/SlopDeskMacUI/*.swift' 'Sources/SlopDeskMacUI/**/*.swift' |
    grep -v "${MAC_CAPS_RECIPE}") 2> /dev/null); then
  printf '%s\n' "${hit}" >&2
  fail "a caps heading is spelled outside ${MAC_CAPS_RECIPE} — macCapsString/macCapsLabel own the recipe (docs/56, increment 55)"
fi
if ! grep -q 'macCapsString(words, color: color, weight: weight)' "${MAC_CAPS_RECIPE}"; then
  fail "${MAC_CAPS_RECIPE}'s label spelling stopped going through its string spelling — that IS the merge"
fi
printf 'check-supervisor: one set of device-panel shells, one caps heading, and neither half names the other.\n'

# ── One design floor, two renderers ───────────────────────────────────────────────────────────
# `SlopDeskSlate` is the layer BOTH halves stand on: the token ladder in its `NSColor`/`UIColor`
# spelling and its `Color` one, the status mark's geometry and its wandering tempo, the vector
# artwork, the nerd splice and the chrome field's configuration. It exists because the draining
# target is the PHONE's at the end of stage D, and an AppKit target importing the phone's would be
# the common view ancestor docs/56 §3 forbids.
#
# The line it holds is "a value, never a drawing". Let one `some View` in and the next mark to be
# ported has somewhere to be written that both halves can see, which is how two renderers become one
# renderer plus a fallback — and nothing goes red: a hosted SwiftUI view compiles perfectly well
# inside an AppKit window.
# Comments are STRIPPED first: the floor's own headers NAME the boundary they hold, and a gate that
# cannot quote the rule it guards is a gate nobody may document.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
slate_code=$(awk '{ line = $0; sub(/\/\/.*/, "", line); printf "%s:%d:%s\n", FILENAME, FNR, line }' \
  $(repo_files 'Sources/SlopDeskSlate/*.swift'))
slate_views=$(grep -n ': View\|some View\|NSViewRepresentable\|UIViewRepresentable\|: Shape' \
  <<< "${slate_code}" || true)
if [[ -n "${slate_views}" ]]; then
  printf '%s
' "${slate_views}" >&2
  fail "the design floor grew a VIEW — it holds values both renderers read, never a drawing either owns"
fi
# Every mark with two renderers keeps them one floor up, one per framework, off the shared value.
for pair in 'Sources/SlopDeskPhoneUI/DesignSystem/StatusDotView.swift:AgentSpinner' 'Sources/SlopDeskMacUI/Overlays/MacAgentGlyph.swift:AgentSpinner' 'Sources/SlopDeskPhoneUI/DesignSystem/VectorIconView.swift:SVGPath' 'Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift:SVGPath'; do
  half="${pair%%:*}"
  spelling="${pair##*:}"
  if ! grep -q "${spelling}" "${half}"; then
    fail "${half} stopped reading ${spelling} — a renderer that re-derives the mark drifts silently"
  fi
done
# The floor may not climb: it is below both UI halves, so importing either would make a cycle of the
# layering and hand the phone's views to the Mac through the back door.
slate_climb=$(grep -rn '^import SlopDeskMacUI\|^import SlopDeskPhoneUI' Sources/SlopDeskSlate || true)
if [[ -n "${slate_climb}" ]]; then
  printf '%s
' "${slate_climb}" >&2
  fail "the design floor imported a UI target — it is BELOW both halves, and the layering says so"
fi
# The Mac reads the ladder from the floor, not from the draining target. This is the whole point of
# the move: `SlopDeskClientUI` was renamed `SlopDeskPhoneUI` in increment 63, and every token read
# that still went through it would have to move on that day instead of on this one.
if ! grep -rq '^import SlopDeskSlate' Sources/SlopDeskMacUI; then
  fail "SlopDeskMacUI stopped naming SlopDeskSlate — the Mac reads the ladder from the floor"
fi
printf 'check-supervisor: one design floor, two renderers, and the floor never draws.\n'

# ── One device-panel law, two device protocols ────────────────────────────────────────────────
# The simulator panel and the Android panel differ in almost everything and should — one rotates on
# the client and the other on the device, one sends touches in the fitted rect's space and the other
# in the video's own pixel grid, because `scrcpy` DROPS a mismatched pair. What they never differed
# in is the arithmetic: the aspect fit, the click mapping, the pinch pair, the safe-area margin and
# the regrip. That lives in `DevicePanelGeometry`, and the CoreMedia wrap in
# `DevicePanelSampleBuffer`; only `formatDescription` is genuinely per-panel (avcC record vs Annex-B).
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
panel_dupes=$(spells 'bounds.width / contentSize.width|CMBlockBufferCreateWithMemoryBlock|2\.0\.squareRoot' \
  $(repo_files 'Sources/SlopDeskPhoneUI/**/*.swift' 'Sources/SlopDeskDevicePanels/**/*.swift' |
    grep -v 'SlopDeskDevicePanels/Shared/') 2> /dev/null || true)
if [[ -n "${panel_dupes}" ]]; then
  printf '%s\n' "${panel_dupes}" >&2
  fail "a device-panel law grew back outside Sources/SlopDeskDevicePanels/Shared — it is shared"
fi
# The panels' aspect fit is the video client's, and the law itself is Rust now: the Swift side calls
# one door, and that door's crate reaches `displayed_video_rect` rather than fitting a frame again.
if ! grep -q 'slopdesk_panel_fitted_rect' Sources/SlopDeskDevicePanels/Shared/DevicePanelGeometry.swift; then
  fail "the device panels stopped calling slopdesk_panel_fitted_rect — a click lands where it is drawn"
fi
if ! grep -q 'displayed_video_rect' rust/slopdesk-devicepanel/src/geometry.rs; then
  fail "slopdesk-devicepanel stopped using geometry::displayed_video_rect — a click lands where it is drawn"
fi

# The clamp that a DRAG off the edge lands on — one rule, and the simulator lane did not have it.
#
# `DevicePanelGeometry.clampedDevicePoint` asks `slopdesk_panel_clamped_device_point`, which clamps
# to the LAST ADDRESSABLE POINT inside the fitted rect. The Android views have gone through it since
# it existed. Both simulator views spelled the clamp themselves, and both copies clamped to the
# fitted rect's SIZE instead — one point past the end on each axis. A drag to the right edge of a
# 200-point frame reported `x = 200` into a surface whose columns are `0..<200`, and the host scales
# that straight off the far side of the framebuffer.
#
# Confirmed by PROBE rather than by reading, before anything was touched: same point, same rect
# `CGRect(x: 50, y: 20, width: 200, height: 400)`, hand-rolled Swift answered `(200.0, 400.0)` and
# the shared rule answered `(199, 399)`.
#
# The ban is on the frame-relative subtraction inside a clamp, which is the whole shape and is
# specific enough not to catch the pinch-spread clamp two files over. `Shared/` is excluded because
# that is where the one legal caller of the door lives.
#
# BREAK-TESTED 2026-08-22 — it fired on the shipped tree, which is how the second copy was found:
#   check-supervisor: FAIL — Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorScreenView.swift clamps a dragged point to the fitted rect by hand again — the shared rule clamps to the last ADDRESSABLE point, one less on each axis
# With the views.md edit applied to a scratch copy it is silent, and reverting the Mac half
# (`SimulatorScreenSurface.swift`) to its own old copy fires it again naming that file.
# `Shared/` is dropped from the FILE LIST rather than exempted after the fact, and that is the whole
# difference between this gate working and not. `spells` returns the FIRST file it matches and stops,
# so a rule written as `if [[ "${hit}" != ".../Shared/DevicePanelGeometry.swift" ]]` would go silent
# for the entire corpus the moment the exempt file happened to be the first hit. An exemption belongs
# in the corpus, never in the comparison.
#
# With a vacuity floor, because `spells` returns 1 on an empty list: a renamed target would drain the
# glob and this gate would report a clean tree while reading nothing.
# `|| true` because that `grep -v` exits 1 when it filters everything away, and under `set -e` an
# assignment from a failing pipeline kills the whole run mid-way — silently, since the script has
# already printed a screenful of passes by the time it gets here. `check-supervisor.sh` ratchets
# exactly this shape against itself (docs/DECISIONS.md, 2026-08-16), and that self-gate is what
# caught this line.
panel_clamp_corpus=$(repo_files 'Sources/SlopDeskPhoneUI/**/*.swift' 'Sources/SlopDeskDevicePanels/**/*.swift' |
  grep -v 'SlopDeskDevicePanels/Shared/' || true)
if (($(printf '%s\n' "${panel_clamp_corpus}" | grep -c .) < 20)); then
  fail "the device-panel corpus read as almost nothing — the hand-rolled clamp ban is passing vacuously"
fi
# shellcheck disable=SC2046 # `${panel_clamp_corpus}` expands to a FILE LIST on purpose
# shellcheck disable=SC2086 # the corpus is a FILE LIST on purpose
if hit=$(spells 'max\((point|location)\.[xy] *- *fitted\.min[XY]' ${panel_clamp_corpus}); then
  fail "${hit} clamps a dragged point to the fitted rect by hand again — the shared rule clamps to the last ADDRESSABLE point, one less on each axis"
fi
# And the four views that need the clamp keep ASKING for it. A ban alone would be satisfied by a
# view that stopped clamping altogether, which is the other half of the same bug: a drag that leaves
# the frame would then be dropped, and the gesture would freeze at the boundary with the button
# still held.
declare -a panel_clamp_callers=(
  "Sources/SlopDeskDevicePanels/Simulator/SimulatorScreenSurface.swift:SimulatorScreenLayout.clampedDevicePoint"
  "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorScreenView.swift:SimulatorScreenLayout.clampedDevicePoint"
  "Sources/SlopDeskDevicePanels/Android/AndroidScreenNSView.swift:AndroidScreenLayout.clampedDevicePoint"
  "Sources/SlopDeskPhoneUI/Panel/Android/AndroidScreenView.swift:AndroidScreenLayout.clampedDevicePoint"
)
for caller in "${panel_clamp_callers[@]}"; do
  if ! spells "${caller#*:}" "${caller%%:*}" > /dev/null; then
    fail "${caller%%:*} stopped asking ${caller#*:} — a drag off the edge is clamped by one rule or by none"
  fi
done
# The same holds for what the panels DRAW. The empty stage, its caption, the empty-list notice and
# the loading-veil asymmetry are one design decision each, recorded in the singular in
# docs/DECISIONS.md and written down twice. The measured veil DELAYS stay per panel (400 ms vs
# 600 ms, two pieces of hardware). The console LEXER used to be pinned here too; both grammars are
# `slopdesk-devicelog` now, and the section above this one is what holds them there.
# The panels' own files must READ the shared laws rather than restate them. A positive check,
# because the veil and the notice are ordinary SwiftUI whose ingredients are used everywhere else.
declare -a panel_shares=(
  "Sources/SlopDeskPhoneUI/Panel/Android/AndroidStageView.swift:DevicePanelChrome.veil"
  "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorStageView.swift:DevicePanelChrome.veil"
  "Sources/SlopDeskPhoneUI/Panel/Android/AndroidDeviceList.swift:DevicePanelChrome.notice"
  "Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorDeviceList.swift:DevicePanelChrome.notice"
  "Sources/SlopDeskDevicePanels/Android/AndroidVideoFormat.swift:DevicePanelSampleBuffer.dimensions"
  "Sources/SlopDeskDevicePanels/Simulator/SimulatorVideoFormat.swift:DevicePanelSampleBuffer.dimensions"
)
for share in "${panel_shares[@]}"; do
  if ! spells "${share#*:}" "${share%%:*}" > /dev/null 2>&1; then
    fail "${share%%:*} stopped calling ${share#*:} — the two panels agree by sharing, not by luck"
  fi
done
# One writer to the CLIENT pasteboard, and it is `ClientPasteboard`. Two things ride on that and
# neither is visible at a call site: the board is a per-PROCESS named one under XCTest (a copy test
# that reached `.general` would clobber the developer's own clipboard), and on AppKit the
# `clearContents` before a `setString` is load-bearing — `NSPasteboard` accumulates types within a
# declaration, so a write without it appends to whatever the last writer declared. The PLATFORM fork
# is inside the funnel too; it was written out at four call sites before it was written once.
# The clipboard SYNC engines are not in scope here: they write an INJECTED board (a named one in
# tests), which is why they take a `pasteboard` parameter at all.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
pasteboard=$(spells 'NSPasteboard.general.clearContents|UIPasteboard.general.string = ' \
  $(repo_files 'Sources/**/*.swift' | grep -v 'ClientPasteboard.swift') 2> /dev/null || true)
if [[ -n "${pasteboard}" ]]; then
  printf '%s\n' "${pasteboard}" >&2
  fail "a second client pasteboard write grew back — ClientPasteboard.write is the only one"
fi
# And the two device panels' capture write is that same funnel, not a third `writeObjects` pair.
# It is `writeImage`, which answers a `Bool` rather than the decoded image — that return type is what
# lets a panel MODEL say "copy this frame" without naming a platform image type, and is why the two
# models could leave the view target at all (docs/56).
declare -a pasteboard_shares=(
  "Sources/SlopDeskDevicePanels/Android/AndroidSidebarModel.swift:ClientPasteboard.writeImage("
  "Sources/SlopDeskDevicePanels/Simulator/SimulatorSidebarModel.swift:ClientPasteboard.writeImage("
)
for share in "${pasteboard_shares[@]}"; do
  if ! grep -qF "${share#*:}" "${share%%:*}"; then
    fail "${share%%:*} stopped calling ${share#*:} — the capture write is one funnel"
  fi
done
# The system-open fork is the same shape and has the same one home — on the CLIENT. The host's
# `HostPathActionPerformer` is deliberately out of scope: it READS the return of `NSWorkspace.open`
# to answer `.ok`/`.error` over the wire, it never has a UIKit arm to fork on, and its target cannot
# see the phone half. Same call, different law.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
opens=$(spells 'NSWorkspace.shared.open\(url\)|UIApplication.shared.open\(url\)' \
  $(repo_files 'Sources/SlopDeskPhoneUI/**/*.swift' | grep -v 'ExternalOpen.swift') 2> /dev/null || true)
if [[ -n "${opens}" ]]; then
  printf '%s\n' "${opens}" >&2
  fail "a second URL-open fork grew back — ExternalOpen.url owns the platform branch"
fi
printf 'check-supervisor: one device-panel law, one chrome, one lexer, one pasteboard, one open.\n'

# ── The small rules that were spelled twice ───────────────────────────────────────────────────
# Each of these is one law with two call sites, and each had two spellings until it did not.
# `autoReplyPing` is the one worth naming: setting it on an inserted options object is INERT (the
# stack stores a copy that reads the flag back as its default), so a lane without an explicit pong
# is dropped on the server's idle timer minutes in. That was measured once and written down twice.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
if spells 'autoReplyPing = true' $(repo_files 'Sources/**/*.swift') > /dev/null 2>&1; then
  fail "autoReplyPing is inert on an inserted options object — SimulatorWebSocketLane sends the pong"
fi
# `VideoDecoder.stampDisplayImmediately` is NOT one of these and is deliberately left alone: it is a
# different target with a lower dependency floor (`SlopDeskVideoProtocol` carries no media
# framework on purpose) and a different reason — Parsec-parity present-on-decode before a VT submit,
# not marking a panel's sample for an `AVSampleBufferDisplayLayer`. Sharing it would widen a leaf's
# purpose for three lines of CoreFoundation.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
smalls=$(spells 'obj\["method"\] as\? String|kCMSampleAttachmentKey_DisplayImmediately' \
  $(repo_files 'Sources/SlopDeskPhoneUI/**/*.swift' 'Sources/SlopDeskDevicePanels/**/*.swift' \
    'Sources/SlopDeskHost/**/*.swift' 'Sources/SlopDeskWorkspaceCore/**/*.swift' \
    'Sources/SlopDeskProtocol/**/*.swift' |
    grep -vE 'SlopDeskProtocol/ControlLine.swift|SlopDeskDevicePanels/Shared/') 2> /dev/null || true)
if [[ -n "${smalls}" ]]; then
  printf '%s\n' "${smalls}" >&2
  fail "an NDJSON control-line or CoreMedia rule grew back — ControlLine / DevicePanelSampleBuffer own them"
fi
# One discriminant->enum mapping per enum: `docs/55` §6 makes the case list a contract, and a
# `SLOPDESK_MODE_EVENT_*` added to one reader and not the other is that contract silently splitting.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
modes=$(spells 'SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN' \
  $(repo_files 'Sources/**/*.swift' | grep -v 'SlopDeskClaudeCode/TerminalMode.swift') 2> /dev/null || true)
if [[ -n "${modes}" ]]; then
  printf '%s\n' "${modes}" >&2
  fail "a second TerminalModeEvent mapping grew back — it belongs on the enum"
fi
printf 'check-supervisor: the small rules are spelled once — control line, sample buffer, mode event, pong.\n'

# ── The UI split holds its shape (docs/56 §3) ───────────────────────────────────────────────────
# Three boundaries, and each fails silently rather than loudly if it slips.
#
# A UI TARGET HOLDS VIEWS ONLY. A file in one that names no view framework compiles perfectly well
# — it is simply logic sitting where only one of the two halves can reach it, which is how the same
# model ends up written twice (the failure `CLAUDE.md` bans by name and this whole split exists to
# prevent). The test is textual and deliberately blunt: import SwiftUI, AppKit or UIKit, or belong
# in `SlopDeskClientCore`.
# FOUR TARGETS, NOT TWO, since the video carve (docs/56 §3). `SlopDeskVideoClientMac` and
# `SlopDeskVideoClientPhone` are the two arms of what was `VideoWindowView.swift`, and they are UI
# targets in exactly the sense this section means, so listing them here buys the frameworkless rule —
# and the two gate rules below — for free.
ui_targets=(SlopDeskMacUI SlopDeskPhoneUI SlopDeskVideoClientMac SlopDeskVideoClientPhone)
frameworkless=""
for target in "${ui_targets[@]}"; do
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    grep -qE '^import (SwiftUI|AppKit|UIKit)$' "${file}" || frameworkless+="${file}"$'\n'
  done < <(repo_files "Sources/${target}/*.swift" "Sources/${target}/**/*.swift")
done
if [[ -n "${frameworkless}" ]]; then
  printf '%s' "${frameworkless}" >&2
  fail "a UI target holds views only — a frameworkless file belongs in SlopDeskClientCore (docs/56 §3)"
fi

# A PLATFORM GATE IN A PLATFORM TARGET means the file is in the wrong target. These targets are the
# Mac's and nothing else builds them, so every `#if os(...)` in one is dead text that reads as a live
# rule. The ONE allowed gate is a phone target's whole-file `#if os(iOS)`, which is how an iOS-only
# view declares itself to `swift build` (SwiftPM compiles every target on the host triple).
#
# ⚠️ TWO PATHS PER SIDE, NOT ONE, since the video carve. `SlopDeskVideoClientMac` is the AppKit half
# of a surface that until the carve WAS an `#if os(macOS)` arm — the single most likely place in the
# tree for the gate to grow back is the file that used to be one.
declare -a mac_view_targets=(SlopDeskMacUI SlopDeskVideoClientMac)
mac_gates=""
for target in "${mac_view_targets[@]}"; do
  # shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
  found=$(spells '#if os\(' \
    $(repo_files "Sources/${target}/*.swift" "Sources/${target}/**/*.swift") 2> /dev/null || true)
  [[ -n "${found}" ]] && mac_gates+="${found}"$'\n'
done
if [[ -n "${mac_gates}" ]]; then
  printf '%s\n' "${mac_gates}" >&2
  fail "a platform gate in a macOS UI target — the file is in the wrong target (docs/56 §3)"
fi
declare -a phone_view_targets=(SlopDeskPhoneUI SlopDeskVideoClientPhone)
phone_gates=""
for target in "${phone_view_targets[@]}"; do
  # shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
  found=$(spells '#if (os\((macOS|watchOS|tvOS)\)|canImport\(AppKit\))' \
    $(repo_files "Sources/${target}/*.swift" "Sources/${target}/**/*.swift") 2> /dev/null || true)
  [[ -n "${found}" ]] && phone_gates+="${found}"$'\n'
done
if [[ -n "${phone_gates}" ]]; then
  printf '%s\n' "${phone_gates}" >&2
  fail "a phone UI target gates on a platform it never builds for (docs/56 §3)"
fi
# …AND THAT IS THE ONLY DIRECTIVE ANY FILE IN IT MAY CARRY. The ban above names the platforms the
# phone does not build for, which leaves an inner `#if os(iOS)` — a gate that is always TRUE in this
# target — sailing through. That is not a hypothetical: normalising the fold left several files with
# a whole-file guard AND inner arms that had been the iOS side of a two-arm split, each one dead
# scaffolding around code that now always runs.
#
# ⚠️ THIS REPLACED A PER-FILE COUNT, and the reason is worth keeping. Increment 58 pinned "exactly one
# `#if os(` in `SettingsControls.swift`" because `SettingsLayout.Half.current` was the shared target's
# single admission that it drew both halves. Increment 63 dissolved that admission — `current` is a
# constant now — and the count STILL READ 1, because the whole-file guard had taken the slot. The
# ratchet went on passing about a different fact than the one it was written for. A rule stated as a
# COUNT of a thing cannot tell you WHICH thing it counted; this one names the shape it wants.
#
# ⚠️ THE VACUITY FLOOR IS PER-TARGET, and that is not tidiness. This walks two targets now, and ONE
# combined `-lt 50` would stay green if `Sources/SlopDeskVideoClientPhone` globbed to zero files,
# because `SlopDeskPhoneUI` alone clears it — a gate that passes by reading nothing, which is the exact
# failure the floor exists to prevent. The video half's floor is small because the half IS small.
declare -A phone_target_floor=(
  [SlopDeskPhoneUI]=50
  [SlopDeskVideoClientPhone]=2
)
phone_directives=""
for target in "${phone_view_targets[@]}"; do
  phone_file_count=0
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    phone_file_count=$((phone_file_count + 1))
    stripped=$(sed -E 's,//.*,,' "${file}")
    total=$(grep -cE '^[[:space:]]*#(if|elseif|else|endif)' <<< "${stripped}" || true)
    opens=$(grep -cE '^#if os\(iOS\)$' <<< "${stripped}" || true)
    ends=$(grep -cE '^#endif$' <<< "${stripped}" || true)
    if [[ "${total}" -ne 2 || "${opens}" -ne 1 || "${ends}" -ne 1 ]]; then
      phone_directives+="${file}: ${total} directive(s), ${opens} whole-file '#if os(iOS)', ${ends} '#endif'"$'\n'
    fi
  done < <(repo_files "Sources/${target}/*.swift" "Sources/${target}/**/*.swift")
  floor="${phone_target_floor[${target}]}"
  if [[ "${phone_file_count}" -lt "${floor}" ]]; then
    fail "only ${phone_file_count} files globbed under Sources/${target} (floor ${floor}) — this gate would pass by reading nothing"
  fi
done
if [[ -n "${phone_directives}" ]]; then
  printf '%s' "${phone_directives}" >&2
  fail "a phone UI file carries more than the one whole-file '#if os(iOS)' — every other arm is always-true scaffolding (docs/56 §3)"
fi

# NEITHER HALF IMPORTS THE OTHER, and the draining floor never imports upward. `Package.swift`
# already makes the first two a link error; this catches the edit that would ADD the dependency
# there, which is the moment a shared view ancestor becomes possible.
# ⚠️ FOUR EDGES BECAME TWO IN INCREMENT 63 — the same collapse, for the same reason, as the `Tests/`
# array further down. Two of the four named the draining floor by its old name, and after the fold one
# of those read `Sources/SlopDeskPhoneUI:import SlopDeskPhoneUI`: a target forbidden from importing
# ITSELF, which is not a rule and which no file can violate. There are two halves, so there are
# exactly two edges.
declare -a ui_edges=(
  "Sources/SlopDeskMacUI:import SlopDeskPhoneUI"
  "Sources/SlopDeskPhoneUI:import SlopDeskMacUI"
)
for edge in "${ui_edges[@]}"; do
  # shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
  crossing=$(spells "${edge#*:}" \
    $(repo_files "${edge%%:*}/*.swift" "${edge%%:*}/**/*.swift") 2> /dev/null || true)
  if [[ -n "${crossing}" ]]; then
    printf '%s\n' "${crossing}" >&2
    fail "${edge%%:*} reached for ${edge#*import }: the two halves share no view ancestor (docs/56 §3)"
  fi
done

# ── AND THE VIDEO SURFACE STAYS SPLIT TOO (docs/56 §3) ───────────────────────────────────────────
# `SlopDeskVideoClient` was the one view target the split never reached. Thirty-three files, and ONE of
# them — `VideoWindowView.swift` — carried a 2,514-line `#if os(macOS)` / `#elseif os(iOS)` two-armed
# conditional: an AppKit implementation and a UIKit one in the same file, linked by both shells. That is
# the exact shape this whole section exists to abolish, and it hid a live parity gap for a release. The
# swipe-peel chip was MOUNTED on both platforms and DRIVEN on one, so a two-finger swipe on the phone
# navigated the remote app with no chip and no haptic while the shared overlay sat permanently dark —
# and the stale doc comment that caused it ("never set on iOS, no trackpad scroll phases") had been
# false since the phone started sending phase-carrying scroll.
#
# The carve left this a DECODE + PACE + TRANSPORT target with no views in it. The two arms became
# `SlopDeskVideoClientMac` (AppKit) and `SlopDeskVideoClientPhone` (UIKit), which are `ui_targets`
# above and inherit its three boundaries. What THIS adds is the floor those two stand on: the engine
# target may not grow a view back, because the moment it does there is somewhere for a third
# implementation to hide again.

# RULE A — THE ENGINE HOLDS NO VIEWS.
#
# THE SHAPE, NOT A COUNT — the lesson recorded above at "⚠️ THIS REPLACED A PER-FILE COUNT". Five files
# here legitimately carry `#if os(macOS)` and are named in Rule C below; each is docs/56 §3's second
# bullet, "a framework call is not a view; a `some View` is" — an ACTUATOR picking an API, not a surface
# drawn twice. Counting their directives would pin a number that cannot say which fact it counted. What
# is banned is the thing they are not: a view DECLARATION.
#
# ⚠️ THE PATTERN MATCHES A DECLARATION, NOT A MENTION, and the difference is not pedantry. This rule
# was first written with a bare `: *NSView\b`, and its very first finding was `FramePacer.swift` — on
# `start(view: NSView)`, a PARAMETER, which is the exact "a framework call is not a view" case Rule C
# excuses `FramePacer` for. Two rules disagreeing about the same file is how an allowlist grows an
# entry that hides a real violation later: the cheap fix is to widen Rule C, and a Rule C wide enough
# to satisfy Rule A no longer says anything. So the match is anchored on the
# `struct`/`class`/`enum`/`extension` keyword with a conformance colon after the type name, and Rule C
# keeps naming only the five files that genuinely pick an API.
video_view_decl='^[[:space:]]*[@A-Za-z ]*\b(struct|class|enum|extension) [A-Za-z_][A-Za-z0-9_.]*[^{]*:[^{]*\b(View|NSViewRepresentable|UIViewRepresentable|NSView|UIView|NSHostingView)\b'
video_engine_views=""
video_engine_count=0
while IFS= read -r file; do
  [[ -z "${file}" ]] && continue
  video_engine_count=$((video_engine_count + 1))
  stripped=$(sed -E 's,//.*,,' "${file}")
  grep -qE '^import SwiftUI$' <<< "${stripped}" &&
    video_engine_views+="${file}: imports SwiftUI"$'\n'
  grep -qE "${video_view_decl}" <<< "${stripped}" &&
    video_engine_views+="${file}: declares a view type"$'\n'
done < <(repo_files 'Sources/SlopDeskVideoClient/*.swift' 'Sources/SlopDeskVideoClient/**/*.swift')
if [[ "${video_engine_count}" -lt 25 ]]; then
  fail "only ${video_engine_count} files globbed under Sources/SlopDeskVideoClient — this gate would pass by reading nothing"
fi
if [[ -n "${video_engine_views}" ]]; then
  printf '%s' "${video_engine_views}" >&2
  fail "a view grew back in the video engine target — it belongs in SlopDeskVideoClientMac or …Phone (docs/56 §3)"
fi

# RULE B — THE TWO-ARMED FILE STAYS GONE.
#
# Deliberately NOT routed through `DELETED_SWIFT_UNION`: that union's patterns are grepped across all of
# `Sources/`, and `VideoLayerView` / `MetalLayerBackedView` / `VideoWindowView` are the LEGITIMATE type
# names in the phone half (the house convention gives the Mac the `Mac` prefix and the phone the bare
# name — `MacGuiLeafView` vs `GuiLeafView`, sixty such pairs across the two UI targets). A union entry
# would false-positive forever, which is how a ban gets deleted for being noisy. The file path is the
# unambiguous fact, so the path is what this checks.
if [[ -e Sources/SlopDeskVideoClient/VideoWindowView.swift ]]; then
  fail "Sources/SlopDeskVideoClient/VideoWindowView.swift is back — its two arms are two targets now (docs/56 §3)"
fi

# RULE C — THE CARVE-OUT, NAMED, WITH ITS REASON, AND SELF-INVALIDATING.
#
# `FramePacer` (NSView vs UIView display link), `VideoWindowPipeline` (the `HostView` typealias +
# NSScreen), `ClientCursorCompositor` (NSCursor vs the position-overlay sublayer), `MetalVideoRenderer`
# (`displaySyncEnabled`, which iOS has no spelling for) and `AudioPlaybackEngine` (AUHAL vs RemoteIO).
# Five actuators, five different APIs, no drawing in any of them.
#
# ⚠️ IT FAILS BOTH WAYS ON PURPOSE. An entry that no longer carries the arm this carve-out exists for is
# a gate that has quietly stopped checking anything — the same stale-ledger failure `ui_test_edges`
# guards against below, and the reason that one stopped saying `|| continue`. An allowlist nobody
# re-validates is worse than no allowlist, because it reads as a decision that was made.
declare -a video_actuators=(
  "Sources/SlopDeskVideoClient/FramePacer.swift"
  "Sources/SlopDeskVideoClient/VideoWindowPipeline.swift"
  "Sources/SlopDeskVideoClient/ClientCursorCompositor.swift"
  "Sources/SlopDeskVideoClient/MetalVideoRenderer.swift"
  "Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift"
)
for actuator in "${video_actuators[@]}"; do
  if [[ ! -e "${actuator}" ]]; then
    fail "video_actuators names ${actuator}, which does not exist — the file moved and this ledger did not (docs/56 §3)"
  fi
  if ! grep -qE '^[[:space:]]*#if.*os\(macOS\)' "${actuator}"; then
    fail "${actuator} no longer carries the platform arm this carve-out exists for — drop it from video_actuators (docs/56 §3)"
  fi
done
video_stray=""
while IFS= read -r file; do
  [[ -z "${file}" ]] && continue
  printf '%s\n' "${video_actuators[@]}" | grep -qxF "${file}" && continue
  grep -qE '^[[:space:]]*#if.*os\((macOS|iOS)\)' "${file}" && video_stray+="${file}"$'\n'
done < <(repo_files 'Sources/SlopDeskVideoClient/*.swift' 'Sources/SlopDeskVideoClient/**/*.swift')
if [[ -n "${video_stray}" ]]; then
  printf '%s' "${video_stray}" >&2
  fail "a platform arm outside the five named actuators — if the file draws, it belongs in a half (docs/56 §3)"
fi

# RULE D — THE TWO HALVES ACCEPT THE SAME SEAM SINKS.
#
# The one real cost of duplicating the pane adapter: two lists of a dozen-odd closures that can drift,
# and a sink wired on one half and forgotten on the other is invisible until someone uses the feature on
# the platform that lost it. `RemotePaneContext` (SlopDeskWorkspaceCore) is the single source both halves
# transcribe; this asserts the transcriptions agree.
#
# ⚠️ THE EXTRACTION IS THE STORED SEAM PROPERTIES, not every `on…Ready|Changed` token in the target. A
# token grep also scoops up the `VideoWindowPipeline` callbacks each half subscribes to, which are a
# DIFFERENT contract with a different asymmetry — Rule E below owns those. Written the broad way this
# rule failed on three symbols that were none of its business while saying nothing about the one that
# was: a gate that conflates two ledgers reports each one's exceptions as the other's noise, and gets
# relaxed until it means nothing. Narrowing it to the thing its own comment claims to compare is a
# correctness fix, not a softening — a rule that compares the wrong set is not strict, it is off-topic.
#
# ⚠️ THE EXCEPTION IS THE FEATURE. `onSystemKeyInjectorReady` is genuinely absent from the phone half and
# should be: its argument is a raw `NSEvent.ModifierFlags` bit pattern whose only producer is
# `SystemKeyCaptureController`'s `CGEventTap`, and neither exists in the iOS SDK —
# `PaneImmersiveCapture.isSupported` is already false there
# (`Sources/SlopDeskClientCore/Input/PaneImmersiveCapture.swift`), so publishing a sink would light
# `RemoteWindowModel.canInjectSystemKeys` for a capture that can never run. It is named here WITH that
# reason rather than silently tolerated, which is what lets this rule catch the second one. Adding a
# name to this array must cost a sentence saying why.
#
# ⚠️ AND IT FAILS BOTH WAYS. An exception the phone has since GROWN is a line that has stopped excusing
# anything, so it must be deleted rather than left to read as a standing decision.
declare -a video_sink_exceptions=(
  onSystemKeyInjectorReady
)
video_sinks() {
  grep -ohE '^ +(public )?let (on[A-Za-z]+):' "$1"/*.swift 2> /dev/null |
    grep -oE 'on[A-Za-z]+' | sort -u
}
mac_sinks=$(video_sinks Sources/SlopDeskVideoClientMac)
phone_sinks=$(video_sinks Sources/SlopDeskVideoClientPhone)
mac_sink_count=$(printf '%s\n' "${mac_sinks}" | grep -c . || true)
if [[ "${mac_sink_count}" -lt 14 ]]; then
  fail "only ${mac_sink_count} seam sinks found in SlopDeskVideoClientMac — this gate's extraction has gone stale and it is now checking nothing"
fi
for excused in "${video_sink_exceptions[@]}"; do
  if ! grep -qxF "${excused}" <<< "${mac_sinks}"; then
    fail "video_sink_exceptions names ${excused}, which the MAC half no longer takes either — the asymmetry is gone, so delete the entry (docs/56 §3)"
  fi
  if grep -qxF "${excused}" <<< "${phone_sinks}"; then
    fail "video_sink_exceptions excuses ${excused}, but the phone half now takes it — delete the entry (docs/56 §3)"
  fi
done
mac_sinks_less=$(grep -vxF -f <(printf '%s\n' "${video_sink_exceptions[@]}") <<< "${mac_sinks}" || true)
if [[ "${mac_sinks_less}" != "${phone_sinks}" ]]; then
  diff <(printf '%s\n' "${mac_sinks_less}") <(printf '%s\n' "${phone_sinks}") >&2 || true
  fail "the two video halves accept different seam sinks — layout diverges, capability does not (docs/56 §3)"
fi

# RULE E — AND THEY SUBSCRIBE TO THE SAME PIPELINE CALLBACKS, WITH THREE NAMED HOLES.
#
# `VideoWindowPipeline` publishes its own `on…` callbacks, distinct from the seam sinks Rule D compares:
# these are the ENGINE talking back to whichever half mounted it. Three of them are subscribed by the Mac
# half and not the phone, and unlike Rule D's one exception they are NOT all platform floors:
#
#   onRemoteCursorChanged            FLOOR, and a REAL one — the only entry left. The sink does not
#                                    exist on iOS: `VideoWindowPipeline` declares it inside
#                                    `#if os(macOS)` because it carries an `NSCursor`, and the reason
#                                    it carries one is that `NSCursor(image:hotSpot:)` takes an
#                                    arbitrary bitmap while `UIPointerStyle` does not (its shapes are
#                                    a `UIBezierPath` or a system effect, and no host cursor bitmap
#                                    becomes either). So the two halves answer "what shape is the host
#                                    cursor" differently ON PURPOSE: macOS paints the shape onto the
#                                    local pointer and adds no overlay, and the phone keeps the
#                                    position overlay it already composites and hides the local
#                                    pointer over it. Not a subscription the phone is missing — a sink
#                                    that is macOS-shaped all the way down. The way to a shape on iPad
#                                    is placing that overlay at the LOCAL hover point, which needs no
#                                    sink at all; see the header of the phone's `MetalLayerBackedView`.
#
# TWO ENTRIES ARE GONE, and both left the same way — the gate went red and named the one to delete.
#
# `onSwipeNavStatusChanged` was never a floor, it was a bug. What was missing was never the drawing
# (the chip had been mounted the whole time) but the DRIVER, and the premise that kept it missing —
# "a touch produces no scroll phases" — was false in the file that stated it. Pinned positively now
# in rule N.14.
#
# `onServerCursorVisibilityChanged` was a floor written on a false premise: "iOS has no hardware
# cursor to swap or hide". `TARGETED_DEVICE_FAMILY` is "1,2", so an iPad with a trackpad always had
# one, and the tree had zero `UIPointerInteraction` and zero `UIHoverGestureRecognizer` — a whole
# input modality missing on a first-class device, not a layout difference. The phone half subscribes
# it now to decide whether to HIDE that pointer, which is `applyLocalCursor`'s decision with the two
# halves swapped. Pinned positively in rule N.15.
#
# Failing both ways matters more here than anywhere else in this section: a ledger that only fails on
# regression is half a ledger, and both of the deletions above were the half that catches a FIX.
declare -a phone_absent_pipeline_sinks=(
  onRemoteCursorChanged
)
video_pipeline_sinks() {
  grep -ohE 'pipeline\.(on[A-Za-z]+) *=' "$1"/*.swift 2> /dev/null |
    grep -oE 'on[A-Za-z]+' | sort -u
}
mac_pipe=$(video_pipeline_sinks Sources/SlopDeskVideoClientMac)
phone_pipe=$(video_pipeline_sinks Sources/SlopDeskVideoClientPhone)
mac_pipe_count=$(printf '%s\n' "${mac_pipe}" | grep -c . || true)
if [[ "${mac_pipe_count}" -lt 8 ]]; then
  fail "only ${mac_pipe_count} pipeline callbacks subscribed in SlopDeskVideoClientMac — this gate's extraction has gone stale and it is now checking nothing"
fi
for absent in "${phone_absent_pipeline_sinks[@]}"; do
  if grep -qxF "${absent}" <<< "${phone_pipe}"; then
    fail "phone_absent_pipeline_sinks names ${absent}, but the phone half now subscribes it — delete the entry; if it was the swipe-peel chip, that bug is fixed (docs/56 §3)"
  fi
  if ! grep -qxF "${absent}" <<< "${mac_pipe}"; then
    fail "phone_absent_pipeline_sinks names ${absent}, which the MAC half no longer subscribes either — this is no longer a divergence, so delete the entry (docs/56 §3)"
  fi
done
mac_pipe_less=$(grep -vxF -f <(printf '%s\n' "${phone_absent_pipeline_sinks[@]}") <<< "${mac_pipe}" || true)
if [[ "${mac_pipe_less}" != "${phone_pipe}" ]]; then
  diff <(printf '%s\n' "${mac_pipe_less}") <(printf '%s\n' "${phone_pipe}") >&2 || true
  fail "the two video halves subscribe different pipeline callbacks, and the difference is not one of the three named holes (docs/56 §3)"
fi

printf 'check-supervisor: the video surface is two halves, and the engine under them holds no views.\n'

# ── …AND A TEST TARGET IS THE SAME EDGE WEARING A `Tests/` PREFIX (docs/56 §3.5 step 5) ─────────
# The loop above globs `Sources/` and nothing else, so `Tests/` was unopposed — and the fold is
# blocked by a Mac test target naming the draining floor exactly as hard as by a Mac source file
# naming it: `SlopDeskClientUI` could not become `SlopDeskPhoneUI` while ANY `SlopDeskMacUI*` target
# reached into it, and a `@testable import` is a stronger edge than a plain one, not a weaker one.
# The rename landed in increment 63; the ban outlives it, because what it forbids is a HALF naming the
# other half, and that is true of the two halves whatever they are called.
#
# The target's OWN tests are not the violation and are deliberately not matched: a suite saying
# `@testable import` of the half it belongs to is a suite testing its own target. What is banned is a
# half's test target naming the OTHER half.
#
# ⚠️ FOUR EDGES BECAME TWO IN INCREMENT 63, and the phone's side moved OUT OF `Tests/` entirely. Two
# of the four named `SlopDeskClientUI`, which no longer exists: it IS `SlopDeskPhoneUI` now. And the
# phone's suite is no longer a SwiftPM target at all — `SlopDeskPhoneUI` is iOS-only, so on the host
# triple it compiles to nothing and a `Tests/` target over it could assert nothing. Its tests are in
# the iOS bundle that can run them, so that is the directory this edge now watches. Leaving either
# stale path in place would have been the exact failure F5 exists to catch: a gate that stays green
# because the thing it greps for can no longer be spelled.
#
# ⚠️ AND THE VIDEO HALVES RIDE THE SAME EDGE. The carve gave each platform its own video view target,
# so a Mac suite naming `SlopDeskVideoClientPhone` is the same violation as one naming
# `SlopDeskPhoneUI` — the two arms of the file this replaced were reachable from everywhere precisely
# because they lived in a target both sides linked.
declare -a ui_test_edges=(
  "Tests/SlopDeskMacUITests:SlopDeskPhoneUI"
  "Apps/ClientApp-iOS/Tests:SlopDeskMacUI"
  "Tests/SlopDeskMacUITests:SlopDeskVideoClientPhone"
  "Apps/ClientApp-iOS/Tests:SlopDeskVideoClientMac"
)
# ⚠️ THE ALLOWLIST IS GONE AND THIS IS A FLAT BAN NOW (increment 62). It carried two snapshot rigs —
# `MacChromeSnapshotRender` and `MacRailStatusRollupRender` — under a comment claiming they mounted
# `SlateProjectIsland`, `SlateSearchField`, `SlatePlateStyle` and `StatusDotView`. Checked against the
# tree, three of those four were only ever named in DOC COMMENTS, and the first rig used nothing at
# all: its `@testable import` had been dead since increment 46 moved the marks to `NSView`s. The debt
# was one rig, two SwiftUI helpers, twelve lines of body. Both now draw the shipping NATIVE tokens
# (`Slate.Native.ProjectTint.bed(at:)`, `Slate.Native.State.hover` + `Line.field`) instead, so the
# fixture's material is the material the Mac column resolves rather than a second derivation of it.
#
# The lesson is in the shape of the old comment, not just its content: a debt ledger that NAMES the
# symbols it is waiting on goes stale silently, because nothing re-checks the naming. What is left
# here checks the only thing that cannot rot — whether the import exists at all.
for edge in "${ui_test_edges[@]}"; do
  test_dir="${edge%%:*}"
  test_target="${edge#*:}"
  # A MISSING DIRECTORY IS A STALE EDGE, NOT A SATISFIED ONE. This read `|| continue` until increment
  # 63, which is the failure mode the note above describes: rename or move the suite and the ban goes
  # quiet rather than wrong, and nothing ever says so. If a path here does not exist, the ledger is
  # out of date and that is the finding.
  if [[ ! -d "${test_dir}" ]]; then
    fail "ui_test_edges names ${test_dir}, which does not exist — the edge moved and this ledger did not (docs/56 §3.5 step 5)"
  fi
  # `@testable ` is OPTIONAL in the pattern on purpose — a test target reaches for a UI half both
  # ways, and matching only the plain spelling would wave every crossing in the tree through.
  # `|| true`: a miss exits 1, and under `set -e` that kills the run instead of reporting.
  test_crossing=$(grep -rlE "^(@testable )?import ${test_target}\$" "${test_dir}" --include='*.swift' |
    sort || true)
  if [[ -n "${test_crossing}" ]]; then
    printf '%s\n' "${test_crossing}" >&2
    fail "${test_dir} reached for ${test_target}: a UI half's tests name no other half (docs/56 §3.5 step 5)"
  fi
done
# …AND THE MANIFEST EDGE IS CUT TOO, for the same reason increment 61 cut the source one: an import
# census is a convention, a missing dependency is a compile error. Without this, deleting the two
# imports leaves the phone half sitting in the Mac test target's `dependencies:`, and the next rig to
# want one `some View` gets it back with a one-line import that builds.
mac_test_block=$(awk '
  /^ *\.(test)?[Tt]arget\(/ { pending = 1; inside = 0; next }
  pending { pending = 0; if ($0 ~ /name: "SlopDeskMacUITests",/) inside = 1 }
  inside { print }
' Package.swift)
if printf '%s' "${mac_test_block}" | sed -E 's#^[[:space:]]*//.*##' | grep -q 'SlopDeskPhoneUI'; then
  fail "the SlopDeskMacUITests target depends on the phone half again — F3 cut that edge (docs/56)"
fi
printf 'check-supervisor: no UI half names another, in Sources or in Tests, and neither manifest edge stands.\n'
# A COORDINATOR HOOK BOUND ON ONE PLATFORM IS A DEAD ROW ON THE OTHER, and it dies quietly: every
# actuator on `OverlayCoordinator` defaults to an empty closure, so a palette row whose hook nobody
# bound looks exactly like a row that ran and had nothing to do. Three of them were bound only by the
# Mac's root — the two panel toggles and the code-panel focus — which meant the phone's palette
# listed View actions that did nothing at all. Both roots bind all three now.
#
# `togglePinWindow` is deliberately NOT here: a phone has one window and no window level, which the
# palette row itself records. An action that is absent on a platform is fine; an action that is
# listed and inert is not.
for hook in toggleSidebar toggleCodeSidebar focusCodePanel; do
  for root in Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift \
    Sources/SlopDeskPhoneUI/WorkspaceRootView.swift; do
    if ! grep -qF "overlay.${hook} =" "${root}"; then
      fail "${root} stopped binding overlay.${hook} — an unbound hook is a palette row that lies"
    fi
  done
done
# AND THE WINDOW ROOT IS OFF THE DRAINING FLOOR (docs/56 §3.5, increment 56b). The rename
# `SlopDeskClientUI` → `SlopDeskPhoneUI` was blocked by exactly the set of `SlopDeskMacUI` files that
# still imported it — that set WAS the ledger, it reached zero, and increment 63 spent it — so an
# import this stage retired has to stay retired.
# Re-adding one is a single line that compiles green, which is the quiet failure every gate in this
# section is shaped around.
#
# `MacWorkspaceRootView` took two things and no more. `WindowSidebarToggle` is `MacWindowSidebarToggle`
# in AppKit now, and the SwiftUI original is DELETED rather than kept beside it — the phone never drew
# that button (no window corner, no traffic lights, no split item to collapse), so a surviving copy
# would be one control in two languages, which is the rule `CLAUDE.md` bans by name. `\.preferencesStore`
# is an init parameter threaded from `SlopDeskMacApp`, which is what the hosted columns already needed:
# an `NSHostingController` inherits no WindowGroup environment, so the value was being forwarded
# explicitly one hop below the read.
#
# Three assertions, because two of them can pass while the port is half-done: the import can go while
# the AppKit button never arrives (the mount would simply not compile — but only until someone reaches
# for the old one again), and the AppKit button can arrive while the SwiftUI one is kept "just in case".
MAC_WINDOW_ROOT=Sources/SlopDeskMacUI/App/MacWorkspaceRootView.swift
MAC_SIDEBAR_TOGGLE=Sources/SlopDeskMacUI/Chrome/MacWindowSidebarToggle.swift
if grep -qE '^import SlopDeskPhoneUI' "${MAC_WINDOW_ROOT}"; then
  grep -nE '^import SlopDeskPhoneUI' "${MAC_WINDOW_ROOT}" >&2
  fail "${MAC_WINDOW_ROOT} imports the draining floor again — the window root came off it (docs/56 §3.5)"
fi
if [[ ! -e "${MAC_SIDEBAR_TOGGLE}" ]]; then
  fail "${MAC_SIDEBAR_TOGGLE} is gone — the window's sidebar toggle is AppKit's (docs/56 §3.5)"
fi
if [[ -e Sources/SlopDeskPhoneUI/Chrome/WindowSidebarToggle.swift ]]; then
  fail "the SwiftUI WindowSidebarToggle is back — MacWindowSidebarToggle replaced it, never joined it (docs/56 §3.5)"
fi
printf 'check-supervisor: the window root is off the draining floor — one sidebar toggle, drawn in AppKit.\n'

# ── THE CANVAS REGISTERS ITSELF IN APPKIT (docs/56 stage F, P5) ─────────────────────────────────
# `DropTargetFrameReader` published the canvas's SCREEN rect from inside `SplitContainer`'s
# `GeometryReader` because the AppKit view hosting the canvas could not: `ContentColumn` applied the
# island moat one level up, so the hosting view's frame and the canvas differed by it — and by a
# DIFFERENTLY ANIMATING amount while a column collapsed. That was the last kind 3 in the ledger and
# it was a statement about SwiftUI, not about geometry. The moat is `MacContentColumn`'s constraints
# now, the difference is zero, and the registration is the three lines `MacNavigatorColumn` already
# spends on `.sidebarList`.
MAC_CONTENT_COLUMN=Sources/SlopDeskMacUI/Columns/MacContentColumn.swift
if [[ -e Sources/SlopDeskPhoneUI/Pane/DropTargetFrameReader.swift ]]; then
  fail "DropTargetFrameReader is back — the island moat moved to ${MAC_CONTENT_COLUMN} instead (docs/56 stage F, P5)"
fi
for half in 'register(.canvas)' 'mainWindowFrame'; do
  if ! grep -qF "${half}" "${MAC_CONTENT_COLUMN}"; then
    fail "${MAC_CONTENT_COLUMN} stopped spelling ${half} — the canvas is un-droppable, and no test goes red for it (docs/56 stage F, P5)"
  fi
done
# ONE PROVIDER FOR ONE KEY. A re-mounted SwiftUI reader registering a SECOND provider does not fail:
# which one wins is mount order, so a drag resolves against whichever view happened to appear last.
# Counted rather than compared as a string — a census that is empty, or that grew, must both be loud.
canvas_registrars=$(grep -rlF 'register(.canvas)' Sources/ --include='*.swift' 2> /dev/null | sort || true)
if [[ "${canvas_registrars}" != "${MAC_CONTENT_COLUMN}" ]]; then
  printf '%s\n' "${canvas_registrars:-<none>}" >&2
  fail "the .canvas drop target is registered somewhere other than ${MAC_CONTENT_COLUMN} alone — two providers for one key resolve by mount order (docs/56 stage F, P5)"
fi
# AND THE MOAT DOES NOT COME BACK. It did not descend to `SlopDeskClientCore` and that was the ruling,
# not an omission: it reads three `Slate.Metric` tokens and lays out, which is docs/56 §3's test for a
# DRAWING exactly inverted — and `SlopDeskClientCore` sits BELOW `SlopDeskSlate` and cannot read the
# tokens at all. So the pin is on the measurements, because the measurements are what the difference
# was made of. Through `spells`: `SplitContainer`'s header names the moat to explain why its gate is
# gone, and a gate that cannot tell code from its own post-mortem forbids writing the post-mortem.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
# The `\b` is load-bearing, and 57b already paid for learning that: without it `islandRadius` also
# matches `islandRadiusCompact`, which is `SlateProjectIsland`'s own token and legitimately drawn in
# this target. A prefix match here bans a surviving token by accident and reads as the moat coming
# back — the gate would be red for something that is right.
moat_respelled=$(spells 'Slate\.Metric\.(islandInset|islandRadius|bandInset|bandHeight|panelRailWidth)\b' \
  $(repo_files 'Sources/SlopDeskPhoneUI/**/*.swift') 2> /dev/null || true)
if [[ -n "${moat_respelled}" ]]; then
  printf '%s\n' "${moat_respelled}" >&2
  fail "the island's measurements are spelled in the draining target again — the moat is ${MAC_CONTENT_COLUMN}'s (docs/56 stage F, P5)"
fi
printf 'check-supervisor: the canvas registers itself in AppKit — one provider, the model frame, no SwiftUI reader.\n'

# ── ONE SEAM, TWO SHAPES, AND NEITHER HALF REGISTERED ALONE (docs/56 stage F, P4) ────────────────
# Each leaf seam offers `shared` (SwiftUI, and iOS's ONLY shape — the phone has no `NSView`) and
# `nativeShared` (AppKit, the view the Mac canvas adds as a subview instead of burying under an
# `NSHostingView` that claims the hit-test over the one surface taking every keystroke). The failure
# this gate exists for is REGISTERING HALF: a build that sets only `shared` ships a terminal the Mac
# canvas cannot mount natively, and one that sets only `nativeShared` ships iOS the BUILD-STATUS
# placeholder. Neither is a compile error and neither has a test — the registration happens in an app
# target no `Package.swift` builds.
#
# ⚠️ `spells`, NOT `grep`, and that is not a preference here: the embedder's doc comments name
# `TerminalRendererFactory.nativeShared` five times to explain the seam, so a raw grep census reports
# the prose as a registrar and this gate could never be written.
GHOSTTY_SEAM=ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift
TERMINAL_SEAM=Sources/SlopDeskWorkspaceCore/Terminal/TerminalRenderingView.swift
VIDEO_SEAM=Sources/SlopDeskWorkspaceCore/Video/VideoWindowSeam.swift
# The embedder is compiled by NO `Package.swift` target (it joins the Xcode app through
# `enable-macos-renderer.sh`), so a rename that leaves this path dangling would silently empty the
# census below rather than fail it. Ask for the file first.
if [[ ! -f "${GHOSTTY_SEAM}" ]]; then
  fail "${GHOSTTY_SEAM} is gone — it is the only registrar of the terminal seam and no compiler in \`make check\` opens it (docs/56 stage F, P4)"
fi
# BOTH SHAPES SURVIVE ON BOTH SEAMS. `shared` is not deprecated by `nativeShared` and must never be:
# deleting it does not break the Mac, which is exactly why it would get deleted.
for seam in "${TERMINAL_SEAM}" "${VIDEO_SEAM}"; do
  for half in 'static var shared' 'static var nativeShared' 'static func makeNative'; do
    if ! grep -qF "${half}" "${seam}"; then
      fail "${seam} stopped declaring \`${half}\` — one seam has two shapes, picked by which framework is drawing (docs/56 stage F, P4)"
    fi
  done
done
# AND ONE INSTALLER SETS BOTH. The app target used to spell `TerminalRendererFactory.shared = …`
# itself, which is a shape it can only ever set one of; the pair moved behind `install()` so the two
# assignments cannot be separated by an edit that only knows about one of them.
for half in 'TerminalRendererFactory.shared =' 'TerminalRendererFactory.nativeShared ='; do
  if ! spells "$(printf '%s' "${half}" | sed 's/[.[]/\\&/g')" "${GHOSTTY_SEAM}" > /dev/null; then
    fail "\`GhosttyRendererSeam.install()\` no longer sets \`${half}\` — half a seam registered is a placeholder terminal on one platform (docs/56 stage F, P4)"
  fi
done
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
seam_registrars=$(spells 'TerminalRendererFactory\.(shared|nativeShared) *=' \
  $(repo_files 'Sources/**/*.swift' 'Apps/**/*.swift' 'ThirdParty/ghostty/integration/**/*.swift') 2> /dev/null |
  cut -d: -f1 | sort -u || true)
if [[ "${seam_registrars}" != "${GHOSTTY_SEAM}" ]]; then
  printf '%s\n' "${seam_registrars:-<none>}" >&2
  fail "the terminal seam is registered outside \`GhosttyRendererSeam.install()\` — that is how one half gets set and the other forgotten (docs/56 stage F, P4)"
fi
# THE VIDEO PAIR COMES FROM ONE BUILDER. Its two registrations DO live in the app target (the video
# module never imports `SlopDeskWorkspaceCore`, so the app is the only place both halves can be
# named), and they are fed by one `-> MacVideoWindowView` function on purpose: the pane threads twelve
# injector callbacks, and two closures built side by side is how eleven of them end up on one path.
# `AnyView(MacVideoWindowView(` is the shape of that re-inlining, so it is the thing banned.
#
# ⚠️ THE TYPE IS `MacVideoWindowView` SINCE THE VIDEO CARVE (docs/56 §3). It was `VideoWindowView` while
# one two-armed file served both platforms; the Mac half took the `Mac` prefix and the phone kept the
# bare name, per the house convention. This gate is spelled against the MAC app main and so it names the
# MAC type — a needle left reading `-> VideoWindowView` would still match nothing here and go red for
# the rename rather than for the re-inlining it exists to catch.
MAC_APP_MAIN=Apps/ClientApp-macOS/AppMain.swift
for half in '-> MacVideoWindowView' 'VideoWindowFactory.shared =' 'VideoWindowFactory.nativeShared ='; do
  # `-e`, because the first needle STARTS WITH `-` and grep reads it as a flag bundle otherwise —
  # which fails open in the worst way here: the gate goes red while the code is right.
  if ! grep -qF -e "${half}" "${MAC_APP_MAIN}"; then
    fail "${MAC_APP_MAIN} stopped spelling \`${half}\` — the video seam's two mounts must be one builder's value (docs/56 stage F, P4)"
  fi
done
video_reinlined=$(spells 'AnyView\(MacVideoWindowView\(' "${MAC_APP_MAIN}" 2> /dev/null || true)
if [[ -n "${video_reinlined}" ]]; then
  printf '%s\n' "${video_reinlined}" >&2
  fail "the video pane is built inside the \`shared\` closure again — the AppKit mount then carries whatever callbacks that copy happens to thread (docs/56 stage F, P4)"
fi
# AND BOTH APPS INSTALL THE TERMINAL SEAM THE ONE WAY. iOS registers only the SwiftUI half — that is
# `install()`'s own `#if os(macOS)` and not the app's business — but it must still go through it.
for app in Apps/ClientApp-macOS/AppMain.swift Apps/ClientApp-iOS/AppMain.swift; do
  if ! spells 'GhosttyRendererSeam\.install\(\)' "${app}" > /dev/null; then
    fail "${app} does not call \`GhosttyRendererSeam.install()\` — the renderer build shows the BUILD-STATUS placeholder and every test still passes (docs/56 stage F, P4)"
  fi
done
printf 'check-supervisor: the leaf seam has two shapes and one installer — no half-registered renderer.\n'

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

# ── The keybindings search filters through the door, not through `contains` ─────────────────────
# `String.contains(_: String)` is grapheme-aware search. Measured against the shipped xcframework:
# 825ns over a 35-byte title, 1,652ns over a 70-byte keyword run, against 29ns and 53ns for the same
# containment as bytes. Four spellings across 85 rows is 415µs on every keystroke typed into the
# editor's search field, and the whole of it is that one call. `slopdesk_ws_binding_row_matches`
# takes the table in one blob and answers positions.
#
# The ban is on the FOLD coming back, not on the door going away: a reader that re-derives a row's
# glyph or canonical per keystroke is the same defect with the door still declared.
#
# BREAK-TESTED against the real tree, 2026-08-22: restoring
# `if binding.title.lowercased().contains(q) { return true }` in `matches` fails the first rule;
# removing the `surviving` batch face fails the second. Both pass on the tree as it stands.
BINDING_SEARCH=Sources/SlopDeskWorkspaceCore/Workspace/Domain/KeybindingsEditorModel.swift
if hit=$(spells 'lowercased\(\)\.contains\(' "${BINDING_SEARCH}"); then
  fail "${hit} folds and searches a binding row in Swift again — the filter crosses once for the whole table (slopdesk_ffi::binding_search)"
fi
if ! spells 'func surviving\(' "${BINDING_SEARCH}" > /dev/null; then
  fail "${BINDING_SEARCH}: the whole-table filter face is gone — a per-row door is 85 crossings and 85 blobs where one of each will do"
fi
printf 'check-supervisor: the keybindings search crosses once for the whole table.\n'
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

# ── …and the rail's title RUNG is asked, never transcribed ──────────────────────────────────────
# `titledByProcess` is `slopdesk_workspace::rail_title::title_rung` asked without composing the
# string. It used to be transcribed into Swift, and its own doc comment said "Mirrors
# RailRowsBuilder.rowTitle's escape order" — docs/55 §8's named anti-pattern, a comment describing
# another language's behaviour as the only thing holding two implementations together.
#
# The transcription is deleted. The two helpers banned below are the pieces the Swift copy was built
# from, so their reappearance in the memo IS the transcription growing back; the two doors are
# pinned because an unreached port is worse than an unported one.
#
# BREAK-TESTED 2026-08-22: restoring `if RailRowsBuilder.cwdFolderName(cwd) == nil` in
# RailRowsMemo.swift failed rule 1; deleting either door call failed its own rule. All three pass.
RAIL_MEMO=Sources/SlopDeskClientCore/Rail/RailRowsMemo.swift
if hit=$(spells 'cwdFolderName|normalizedProjectKey' "${RAIL_MEMO}"); then
  fail "${hit} re-derives the rail's title rung in Swift — the rung lives in slopdesk_workspace::rail_title::title_rung and \`row_title\` composes its string from the SAME function, so the two cannot drift"
fi
for rail_memo_door in slopdesk_ws_rail_titles_by_process slopdesk_ws_rail_structure_keys; do
  if ! spells "${rail_memo_door}" "${RAIL_MEMO}" > /dev/null; then
    fail "${RAIL_MEMO} no longer asks ${rail_memo_door} — docs/55 §8: an unreached port is worse than an unported one, and the Swift answering it would be a second implementation"
  fi
done
printf 'check-supervisor: the rail fingerprint asks for its rung and its keys; it does not re-derive them.\n'

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

# ---- 1. The encoder's quantiser ceiling is ONE ramp, and it is the crate's. ----------------------
# The linear sharp↔coarse interpolation existed twice: `VideoEncoder.qpCeiling` drove it from the
# budget's bits-per-pixel, `adaptive_qp::adaptive_max_qp` drove it from the per-frame change
# fraction, and neither knew the other was there. That is docs/55 §8's drift class exactly — a rule
# in two languages where only one side is on a path anyone watches. Both now go through
# `slopdesk_video_qp_ceiling`, which maps the density onto the band and hands the interpolation to
# the same routine, and the six hardware-tuned numbers arrive from
# `slopdesk_video_qp_ceiling_config_default` rather than being typed in beside it.
#
# The FACE must keep calling both doors, and it must not grow the arithmetic back.
for pair in \
  "${SWIFT_VIDEO_ENCODER}:slopdesk_video_qp_ceiling_config_default" \
  "${SWIFT_VIDEO_ENCODER}:slopdesk_video_qp_ceiling" \
  "${SWIFT_VIDEO_ENCODER}:slopdesk_video_qp_drop_relief_fold"; do
  if ! grep -q "${pair#*:}(" "${pair%%:*}"; then
    fail "${pair%%:*} no longer calls ${pair#*:} — the encoder's QP ceiling is encoder_ceiling.rs"
  fi
done
# The ARITHMETIC, not the names. A re-transcription has to divide the budget by a pixel rate and
# then interpolate across the band, so it has to spell a `Double(...) / ` against a product of the
# three picture terms, or a `(sharp - coarse)` span, or one of the six tuned constants as a literal.
# BREAK-TESTED: restoring the pre-port body (`let bpp = Double(targetBps) / pixelRate` plus the
# `Double(sharp - coarse)` ramp) fires "spells the quantiser ramp again"; the shipped tree is silent.
if hit=$(spells 'Double\(targetBps\) */|/ *pixelRate|Double\(sharp *- *coarse\)|Double\(coarse *- *sharp\)' \
  "${SWIFT_VIDEO_ENCODER}"); then
  fail "${hit} spells the quantiser ramp again — the budget→ceiling law is encoder_ceiling.rs"
fi
# BREAK-TESTED: re-typing `static let attackStep = 4` fires; reading it off `ceilingConfig` is
# silent, because the assignment has no bare literal on its right.
if hit=$(spells '(attackStep|holdFrames|decayEvery|sharpQPCeiling|qpCeiling(Sharp|Coarse)Bpp) *(:[^=]*)?= *[0-9]' \
  "${SWIFT_VIDEO_ENCODER}"); then
  fail "${hit} types a tuned ceiling constant again — all six arrive on the config door"
fi
printf 'check-supervisor: the encoder ceiling ramps once, in Rust, from constants it does not retype.\n'

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
if ! grep -q 'slopdesk_qp_clamped_int(' "${SWIFT_VIDEO_ENCODER}"; then
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

# ── The s16le → Float32 convert, which was written out twice and compared never ──────────────────
# `AudioStreamDecoder.decodePCM` and `slopdesk_video::audio_wire::decode_pcm_s16le` were the same
# loop byte for byte, down to the same validate-then-DROP rule for a ragged tail — and the Rust half
# had no caller outside its own tests. That is `docs/55` §8's exact shape, and the reason it needed
# a gate rather than a note is that this pair CANNOT be caught disagreeing: a full-scale sample is
# `-1.0` either way, and a drifted normalisation is just audio that is slightly quieter than it
# should be. Nobody files that.
#
# The door writes in place into the caller's buffer and answers a SAMPLE count. The Vec-returning
# Rust form was deleted rather than kept beside it: at one call per 10 ms frame the allocation, not
# the crossing, was the entire cost.
#
# The ban is on the hand-assembled sample — the little-endian pair, the sign reinterpretation, and
# the full-scale divisor — because those three are what a re-implementation is made of, and any one
# of them appearing in this file means the loop has grown back.
#
# BREAK-TESTED 2026-08-22 (`cp` to /tmp, restore from the copy): pasting
# `Int16(bitPattern: UInt16(lo) | UInt16(hi) << 8)` back fires
#   check-supervisor: FAIL — Sources/SlopDeskVideoClient/AudioStreamDecoder.swift widens a PCM sample by hand again — the convert and its ragged-tail drop are audio_wire.rs's
# and deleting the door call fires the presence rule. Shipped tree silent on both.
SWIFT_AUDIO_DECODER=Sources/SlopDeskVideoClient/AudioStreamDecoder.swift
if ! spells 'slopdesk_audio_decode_pcm_s16le\(' "${SWIFT_AUDIO_DECODER}" > /dev/null; then
  fail "${SWIFT_AUDIO_DECODER} stopped asking the door to widen its samples — that loop lives in audio_wire.rs"
fi
if hit=$(spells 'bitPattern:|<< 8|32768|32767' "${SWIFT_AUDIO_DECODER}"); then
  fail "${hit} widens a PCM sample by hand again — the convert and its ragged-tail drop are audio_wire.rs's"
fi

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

# 3. THE PALETTE'S THREE RESULT PROPERTIES ARE ONE PASS. `paletteResults`, `rankedResults` and
#    `selectableResults` each used to re-run the whole mixer: ~8 category sources, and per source a
#    fresh tuple array, a fresh `[String?]` of three fields per row, and one `slopdesk_ws_search_rank`
#    crossing whose blob is every title, subtitle and synonym concatenated. Measured over a 90-row
#    catalog in 8 sources: ~150 µs PER READ (139–167) for a typed query, ~30 µs for the empty-query
#    path. `moveSelection` reads `selectableResults` only for `.count`, so every ↑/↓ paid one pass
#    before the body paid another, and the phone's `PaletteView` reads `rankedResults` twice per
#    body — three passes per arrow key on the phone, two on the Mac. They now share one memo keyed on
#    `(generation, query, filter, recents)`, and `mixerGeneration` is what makes a rebuilt mixer
#    invalidate it. BREAK-TESTED twice: pointing `rankedResults` back at `mixer?.ranked(` fires its
#    reader arm, and deleting the `&+= 1` line from `rebuildMixer` fires the generation arm.
SWIFT_OVERLAYS=Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift
for reader in paletteResults rankedResults selectableResults; do
  if ! grep -qE "var ${reader}: \[[A-Za-z]+\] \{ memoizedResults\." "${SWIFT_OVERLAYS}"; then
    fail "${SWIFT_OVERLAYS}: ${reader} no longer reads the memo — each read is a whole ~150 µs fzf pass, and three of them ride one arrow key"
  fi
done
if ! grep -q 'mixerGeneration &+= 1' "${SWIFT_OVERLAYS}"; then
  fail "${SWIFT_OVERLAYS}: rebuildMixer no longer bumps mixerGeneration — the memo would serve results from the PREVIOUS catalog"
fi
printf 'check-supervisor: the palette ranks once per query, not once per read.\n'

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

# ══════════════════════ ROUND TWO — the MacUI sweep's hand-over ══════════════════════
# Four more, same instrument and same reason: each is a defect no test can see. Two of the six leads
# handed over were REFUTED on measurement and are recorded as such in the report rather than pinned
# here — a refutation is not a rule.

# 5. THE NERD-FONT RUN SPLITTER IS LINEAR, AND SKIPS THE WALK ENTIRELY WHEN NOTHING IS A SYMBOL.
#    `runs(of:)` had the obvious accumulator — read the last run back out of the array, append one
#    character, write it back — and that is QUADRATIC without looking it: `out.last` hands back a
#    COPY of the tuple, so the run's `String` is two-referenced for an instant and `append` copies the
#    whole run before adding a character. Every `.slateNerdAware` string in three overlays walks this
#    once per keystroke. Measured, `swiftc -O`, two runs agreeing: a plain 48-character title
#    3,563 → 104 ns, a 240-character one 21,588 → 371 ns (58×). The scalar pre-scan is the other half
#    and is what makes the ordinary case — no nerd glyph anywhere, which is almost every string —
#    one scalar walk and one `String`, without entering the per-`Character` loop at all. It is also
#    what stops the two splice sites' `registered` guard ORDER from mattering.
#    BREAK-TESTED twice: restoring the `out.last` accumulator fires the shape ban, and deleting the
#    `unicodeScalars.contains` line fires the pre-scan arm.
SWIFT_NERD=Sources/SlopDeskFontFaces/NerdSymbolFont.swift
if ! grep -q 'guard text.unicodeScalars.contains(where: isPrivateUse)' "${SWIFT_NERD}"; then
  fail "${SWIFT_NERD}: runs(of:) lost its scalar pre-scan — every ordinary title pays a per-Character walk and a String per run again"
fi
if grep -qE 'if var last = out\.last|out\[out\.count - 1\] = ' "${SWIFT_NERD}"; then
  fail "${SWIFT_NERD}: runs(of:) accumulates through out.last again — that shape is QUADRATIC in the run length (3,563 ns for a 48-char title against 104)"
fi
printf 'check-supervisor: the nerd-font run splitter is linear and skips the walk it does not need.\n'

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

# 7. A RAIL RENDER READS ITS BADGE SETTINGS ONCE, NOT ONCE PER ROW. `chrome(...)` asks the store for
#    `commandBadgeGates` — three `UserDefaults` reads behind a computed property with NO per-pane
#    override — and for `agentBadgeGates`, three more whenever the pane has no override, which is the
#    ordinary case. A list built row by row therefore re-read the same two globals per row. Measured,
#    `swiftc -O`, two runs agreeing inside 0.3%: one `UserDefaults` bool read is 305 ns, a row's six
#    are 1.85 µs, and a 24-row rail render spent 44.5 µs on settings that cannot change while it
#    draws. The batch entry reads them once and resolves the active session and its tab list once too.
#    BREAK-TESTED twice: deleting the batch overload fires the entry arm, and deleting the
#    `commandGates` parameter from `chrome` fires the threading arm.
SWIFT_RAIL_BUILDER=Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift
if ! grep -q 'func liveChrome(for rows: \[RailRow\]' "${SWIFT_RAIL_BUILDER}"; then
  fail "${SWIFT_RAIL_BUILDER} lost the batched liveChrome — a rail render goes back to 6 UserDefaults reads per row (44.5 µs at 24 rows)"
fi
if ! grep -q 'commandGates ?? store.commandBadgeGates' "${SWIFT_RAIL_BUILDER}"; then
  fail "${SWIFT_RAIL_BUILDER}: chrome() no longer accepts pre-read command gates — the batch entry has nothing to hand it and the per-row reads come back"
fi
printf 'check-supervisor: a rail render reads its badge gates once, not once per row.\n'

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
# The two bundled font families are one pair, and they used to be held in sync by a comment.
#
# `CodeSidebarPageDressing` injects @font-face declarations into the embedded workbench and
# `slopdesk-codeseed` seeds the `editor.fontFamily` that names them. If the two disagree the panel
# falls through to the system mono — no error, no crash, just the wrong shapes beside a terminal
# drawing the right ones. They cross no door on purpose: codeseed is a host crate carrying the whole
# seed history, and linking it into the FFI artifact would drag those tables into the iOS binary for
# two strings. So the gate does the job the door would have.
codeseed_settings="rust/slopdesk-codeseed/src/settings.rs"
dressing="Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarPageDressing.swift"
for pair in "MONO_FONT_FAMILY|monoFontFamilyName" "NERD_FONT_FAMILY|nerdFontFamilyName"; do
  rust_name="${pair%%|*}"
  swift_name="${pair#*|}"
  rust_value="$(sed -n "s/^pub const ${rust_name}: &str = \"\\(.*\\)\";\$/\\1/p" "${codeseed_settings}")"
  swift_value="$(sed -n "s/^ *package static let ${swift_name} = \"\\(.*\\)\"\$/\\1/p" "${dressing}")"
  if [[ -z "${rust_value}" ]]; then
    fail "${codeseed_settings} no longer declares ${rust_name} — the seeded stack lost its named face"
  fi
  if [[ -z "${swift_value}" ]]; then
    fail "${dressing} no longer declares ${swift_name} — the injected @font-face lost its family"
  fi
  if [[ "${rust_value}" != "${swift_value}" ]]; then
    fail "the injected face and the seeded one disagree: ${rust_name}=${rust_value} vs ${swift_name}=${swift_value}"
  fi
done

# And the stack is BUILT from those two rather than typed out a third time. The check that stops the
# family being listed twice used to hold its own copy of the word, so renaming the face in the stack
# alone would have made the stack repeat it while every `starts_with` assertion kept passing.
if grep -qE "const FALLBACK: &str = \"'" "${codeseed_settings}"; then
  fail "${codeseed_settings} typed the font stack out again — build it from the two named families"
fi
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

# ── One key vocabulary, on the CLIENT's send-keys too ───────────────────────────────────────────
# The existing "One key vocabulary" block pins the HOST's face (`ControlKeyMap.swift`). The client's
# `pane send-keys` had a second table of its own — nine names — and every other name the vocabulary
# knows fell through it into a `nil` the caller dropped while still answering success, so `--key f5`
# reported a keystroke delivered to a pane that received nothing. Same door, same ban on spelling a
# sequence, plus the refusal being answerable: a `Bool` here cannot say "that is not a key" without
# borrowing "pane not found".
SWIFT_CLIENT_KEYS=Sources/SlopDeskClientCore/Control/WorkspaceControlBackend.swift
if ! spells 'slopdesk_ws_key_token' "${SWIFT_CLIENT_KEYS}" > /dev/null; then
  fail "${SWIFT_CLIENT_KEYS} answers a key name again — the vocabulary is send_keys.rs's"
fi
if hit=$(spells '0x1B, 0x5B|case "enter"|case "pageup"|& 0x1F' "${SWIFT_CLIENT_KEYS}"); then
  fail "${hit} spells a key sequence again — a second table is how the client lost f5 and pgup"
fi
if ! spells 'unknownKey' "${SWIFT_CLIENT_KEYS}" > /dev/null; then
  fail "${SWIFT_CLIENT_KEYS} swallowed the refusal again — an unrecognised key must fail the request"
fi
printf 'check-supervisor: the client send-keys asks the one vocabulary, and can refuse.\n'

# ── A config action name resolves once, and goto_tab is bounded on BOTH halves of the line ──────
# The name table and the `goto_tab` bound were written in Swift and in Rust, and they disagreed: the
# Swift bounded the argument to 1…9 (there are nine per-digit bindings), the grammar accepted any
# integer, so `cmd+1:goto_tab:99` validated in the keybinding editor and then resolved to nothing.
# Both halves hold the bound now — the grammar so the line does not validate, the resolver so
# nothing unbindable reaches the registry — and the nine ids are the resolver's list, so the bound
# and the table it guards cannot drift apart.
SWIFT_CONFIGNAMES=Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceActionConfigNames.swift
if ! spells 'slopdesk_ws_binding_id_for_config_name' "${SWIFT_CONFIGNAMES}" > /dev/null; then
  fail "${SWIFT_CONFIGNAMES} resolves a config name in Swift again — that table is keybind.rs's"
fi
# Code shapes only, not prose: the doc comment above the resolver legitimately NAMES the bound and
# an id while explaining where they went, so the patterns are the dictionary entry, the interpolated
# id and the range check rather than the words themselves.
if hit=$(spells '"new_tab": "|"pane\.select\.\\\(|\(1\.\.\.9\)\.contains' "${SWIFT_CONFIGNAMES}"); then
  fail "${hit} spells a config name, a binding id or the goto_tab bound again — all three are Rust's"
fi
if ! spells 'Ok\(1\.\.=9\)' rust/slopdesk-terminal/src/keybind.rs > /dev/null; then
  fail "rust/slopdesk-terminal/src/keybind.rs stopped bounding goto_tab — a line that cannot fire must not validate"
fi
if ! spells 'SELECT_PANE_BINDING_IDS: \[&str; 9\]' rust/slopdesk-workspace/src/keybind.rs > /dev/null; then
  fail "rust/slopdesk-workspace/src/keybind.rs no longer bounds goto_tab by its own row list — the list IS the bound"
fi
printf 'check-supervisor: one config-name table, and goto_tab is bounded where it is read.\n'

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
# rule, and restoring from /tmp. Never `git checkout`, which discards this tree's other work.

# ── The null-output PROBE, on the four doors where it costs a second whole answer ──────────────
#
# `docs/55` §4 makes `(NULL, 0)` a supported way to ask a door for its length, and for a door whose
# rule is a table lookup it costs a nanosecond — `slopdesk_panel_simulator_key_code` and
# `slopdesk_input_mode_reset` probe on purpose and are not touched here. For a door whose rule is
# WORK it costs the work TWICE, and these four are the ones in this scope where that is
# measurable. All four probed until 2026-08-22; all four now guess and retry. The numbers are from
# a scratch `swiftc -O` harness linked against the shipped `macos-arm64` slice, two runs agreeing:
#
#   slopdesk_git_status        53.4 / 57.7 ms → 25.7 / 27.0 ms  libgit2 walks the worktree, per
#                                                               FSEvents tick per watched repo
#   slopdesk_plaintext_strip   646 / 629 µs   → 302 / 310 µs    183 KB pane capture, per agent read
#   slopdesk_annexb_to_avcc    501 / 475 µs   → 265 / 234 µs    300 KB keyframe, PER FRAME
#   slopdesk_annexb_split      the same walk over the same buffer, per access unit
#
# The failure mode no test can see: both calls agree and every answer is correct. The only trace is
# a git line that lands a beat late and a phone mirror that drops frames on a busy host — which
# reads as a device problem, not as a doubled call.
#
# The pattern is deliberately the ONE-LINE call shape, which is how all seven call sites are
# written; the presence half below is what holds a reformat that split one across lines.
#
# BREAK-TEST 2026-08-22: `Sources/SlopDeskHost/HostGitStatus.swift` copied to /tmp, its retry
# replaced by `let needed = slopdesk_git_status(input.baseAddress, input.count, nil, 0)` — the ban
# FIRED and named the file; restored from /tmp, PASSES. Same edit in `ANSIStripper.swift` and in
# `AndroidStreamProtocol.swift`: FIRED, restored, PASSES.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
probe_site=$(spells 'slopdesk_(git_status|plaintext_strip|annexb_to_avcc|annexb_split)\([^)]*nil, *0\)' \
  $(repo_files 'Sources/**/*.swift') 2> /dev/null || true)
if [[ -n "${probe_site}" ]]; then
  fail "${probe_site} asks an expensive door for a length with a null output — that runs its whole rule and throws the answer away. Guess, then retry (docs/55 §4)"
fi

# The other half: each of the three fixed sites still carries a first guess. A probe deleted the
# guess as well as the retry, so its absence is the same regression arriving by a different edit.
#
# BREAK-TEST 2026-08-22: deleting `private static let firstGuess = 64 * 1024` from
# `HostGitStatus.swift` FIRED; deleting `avccSlack` from `AndroidStreamProtocol.swift` FIRED.
# Both restored from /tmp, both PASS.
for pair in \
  "Sources/SlopDeskHost/HostGitStatus.swift:firstGuess" \
  "Sources/SlopDeskHost/ANSIStripper.swift:needed > room.count" \
  "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift:avccSlack" \
  "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift:spanFloor"; do
  if ! grep -qF "${pair#*:}" "${pair%%:*}"; then
    fail "${pair%%:*} no longer spells '${pair#*:}' — the guess-then-retry that halved this path is gone (docs/55 §4, §6)"
  fi
done

# ── One binary search order, and it is not this language's ────────────────────────────────────
#
# `docs/46`'s "Vendored runtime deps" section states ONE order — the `SLOPDESK_*_BIN` override, the
# vendored prefix, `PATH`, then `~/.local/bin` and the two Homebrew prefixes — and named the Swift
# copy as the rule with the Rust one "mirrored" from it. A mirror is a claim with no gate behind
# it, which is `docs/55` §8's whole subject, and this pair had already stopped agreeing on the
# question neither doc comment mentions: WHAT MAKES A CANDIDATE EXECUTABLE.
#
#   Swift  FileManager.isExecutableFile  →  access(path, X_OK)
#   Rust   metadata().is_file() && mode & 0o111 != 0
#
# They disagree in both directions and neither disagreement can raise an error, because each side
# is self-consistent and only one of them runs on any given path. A DIRECTORY named `code-server`
# on `PATH` is `X_OK`, so Swift handed it to `posix_spawn` and the operator got a message about the
# wrong thing; Rust walks past it to the real binary. `slopdesk_androidd::toolchain::locate_tool`
# is the order now and `HostServiceProcess.locate` asks for it.
#
# The ban is scoped to the file that OWNS the question. `isExecutableFile` elsewhere in hostd
# (`SidecarVersionAudit`, `HostMetadataProbe`) is a can-I-spawn-THIS-path guard, not a search, and
# `HostEnvironment`'s `/usr/local/bin:/usr/bin:/bin` is the PATH handed to children — different
# capabilities, correctly still Swift.
#
# BREAK-TEST 2026-08-22: `Sources/SlopDeskHost/HostServiceProcess.swift` copied to /tmp, then (a)
# the `slopdesk_host_service_binary` call renamed — the presence check FIRED; (b) the deleted
# `static let fallbackBinDirectories = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin",
# "/usr/local/bin"]` pasted back — the ban FIRED and named the file. Restored from /tmp after each,
# both PASS. Restoration was `cp` from /tmp, never `git checkout`, which would have discarded the
# port itself.
SWIFT_HOST_SERVICE=Sources/SlopDeskHost/HostServiceProcess.swift
if ! grep -q 'slopdesk_host_service_binary(' "${SWIFT_HOST_SERVICE}"; then
  fail "${SWIFT_HOST_SERVICE} no longer calls slopdesk_host_service_binary — hostd's search order is rust/slopdesk-androidd/src/toolchain.rs"
fi
if spells '/opt/homebrew/bin|/usr/local/bin|\.local/bin|isExecutableFile' "${SWIFT_HOST_SERVICE}" > /dev/null; then
  fail "${SWIFT_HOST_SERVICE} spells a bin directory or an executability test again — the whole order is locate_tool, and a second copy of it drifts silently (docs/46, vendored runtime deps)"
fi
printf 'check-supervisor: hostd finds a program by one order, and asks the expensive doors once.\n'

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
if ! grep -q 'MuxFrameType(rawValue: flat.mux_type)' "${SWIFT_MUX}/MuxEnvelope.swift"; then
  fail "${SWIFT_MUX}/MuxEnvelope.swift stopped refusing an unknown mux type — the type list is Rust's"
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
# CATCHES: the door call surviving beside a hand-rolled second reading. `!= 0` on a decoded byte and
# `UInt32(bitPattern:` are the two exact spellings that were here; a ban on the SHAPE is what stops
# the door from becoming decorative while the composition below it is what actually runs.
if spells 'decodeU8\(.*\)\.map|UInt32\(bitPattern:' "${codec_swift}" > /dev/null; then
  fail "${codec_swift} composes a scalar field again — ask slopdesk_ws_decode_bool / slopdesk_ws_encode_i32 instead of re-deriving the byte rule here (docs/55 §6)"
fi

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

# The socket name and the verb bytes moved to `rust/slopdesk-invariants` (screend-address,
# screend-verbs). What is left here is the banner and the four absences.
printf 'check-supervisor: screend agrees too — banner "%s", no Swift engine, ladder, manifest, boundary split or journal.\n' \
  "${swift_banner}"
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
# `HostMetadataProbe.maxCaptureBytes` is deliberately NOT in this gate. It is 15 MiB too, and it is
# not a mirror of anything: it is the stop condition on the `lsof` drain, and its own comment says
# no caller reaches it. Pinning it here would tie an unrelated loop's ceiling to the wire's, so that
# lowering one would fail on the other for no reason. Same number, different question.
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
if ! awk '/MACOS-ONLY BEGIN/{inside=1} inside{print} /MACOS-ONLY END/{inside=0}' \
  rust/slopdesk-ffi/include/slopdesk_ffi.h | grep -q 'slopdesk_inject_pointer('; then
  fail "slopdesk_ffi.h declares a CoreGraphics door outside the macOS-only region — iOS has no CGEvent at all, so an ungated declaration is not a wasted byte, it is a link failure on two of the three slices (docs/57 §3)"
fi
if ! grep -A 12 "target.'cfg(target_os = \"macos\")'.dependencies" rust/slopdesk-ffi/Cargo.toml |
  grep -q 'slopdesk-apple-cgevent'; then
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
  if ! awk '/MACOS-ONLY BEGIN/{inside=1} inside{print} /MACOS-ONLY END/{inside=0}' \
    rust/slopdesk-ffi/include/slopdesk_ffi.h | grep -q "${door}("; then
    fail "slopdesk_ffi.h declares ${door} outside the macOS-only region — iOS has no WindowServer at all, so an ungated declaration is not a wasted byte, it is a link failure on two of the three slices (docs/57 §3)"
  fi
done
for edge in slopdesk-apple-cgwindow slopdesk-apple-cgdisplay; do
  if ! grep -A 12 "target.'cfg(target_os = \"macos\")'.dependencies" rust/slopdesk-ffi/Cargo.toml |
    grep -q "${edge}"; then
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
  if awk '/MACOS-ONLY BEGIN/{inside=1} inside{print} /MACOS-ONLY END/{inside=0}' \
    rust/slopdesk-ffi/include/slopdesk_ffi.h | grep -q "${door}("; then
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

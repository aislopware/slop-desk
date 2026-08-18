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
DELETED_SWIFT_UNION='((enum|struct|final class) (GF256|NeonGf|ReedSolomonMatrix)\b)|((struct|enum|final class) StreamHasher\b|func (hashRow|hashNV12Scalar|rowHashes|rowHashesQuantized|borrowPlane|estimateVerticalShift|changedFraction|adaptiveMaxQP)\b)|(func (targetSeconds|stepSeconds|cgRectToCocoa|backingScaleFactor)\(|(struct|enum|final class) ScreenInfo\b)|((func|var) appendBE|(struct|enum|final class|class) BigEndianReader)|((enum|struct|final class|class|actor) (AgentManifest|CompiledAgentManifest|AgentManifestCatalog|TOMLSubsetParser|ManifestRegion|ManifestRuleEngine|BundledAgentManifests|AgentDetectionExplain|AgentOscTracker|AgentSyncFrameTracker|ClaudeManifestMatcher)\b)|((enum|struct|final class|class|actor) ShellIntegration\b|slopdesk-zdotdir-)|((enum|struct|final class|class|actor|protocol) (FileTransferServer|FileReceiveLogic|FileDropSink|DiskFileDropSink|FileNameSanitizer|LoopbackFileTransferChannel)\b)|((enum|struct|final class|class|actor|protocol) (AndroidBridgeServer|AndroidBridgeManager|AndroidToolchain|AndroidScrcpySession|AndroidDeviceCatalog|AndroidEmulatorConsole|AndroidSocket|AndroidListener|AndroidBridgeRequest)\b)|((enum|struct|final class|class|actor|protocol) (TranscriptParser|TranscriptTailer|TranscriptLine|LineAccumulator|SubagentWatcher|EventBuilder|InspectorEngine|InspectorReplayLog|InspectorSource|InspectorServer)\b)|((static (let|var|func)|let|var|func) (seededUserSettings|obsoleteSeeds|themeExtension[A-Za-z]*|bridgeExtension[A-Za-z]*|registerExtension|unregisterExtension|bundledMarketplaceExtensions|retiredExtensions|ownThemeResources)\b)|((enum|struct|final class|static (let|var|func)) (AgentInstaller|hookMarker|installedEvents|hookCommand|entryIsOurs)\b)|((struct|static (let|var|func)|private static func) (parseBranchHeader|parseStatusLine|statusNibble|packStatus|claudeProjectSlug|gitToplevel|gitStashCount|gitDiffArgumentPlan|resolveGitDiff|jsonlSessions|claudeSessions|opencodeSessions|sessionRoots|GhosttyTerminfoProbe|terminfoEntryExists|isGhosttyResolvable|effectiveTerm|liveProbe|runInfocmp)\b)|("/usr/bin/(git|infocmp)")|((let|var|func|case) *(bonusBoundary|bonusCamel123|bonusConsecutive|scoreGapStart|scoreGapExtension|bonusMatrix|bonusFor|backtrace)\b)|((enum|struct) *(HookPayload|StopInfo|ToolUseBlock|NotificationInfo|ClaudeHookBody|ClaudeHookEvent)\b|func +(mapToHookEvent|classifyNotification|stopLabel)\b)|((enum|struct|final class|class|actor) (ClaudeStatusMachine|ClaudeProcessMatcher|PaneInputClassifier)\b|enum ClaudeSignal\b)|(func +(skipEscapeSequence|isEraseToLineEnd|applySGR|extendedColour)\b)|(enum TerminalScreenModel|struct TerminalScreenModel|enum LineOverprintCollapser|enum TerminalSnapshotRenderer)|((enum|struct|final class|class|actor) (TerminalInputModeStripper|InputModeFinalState|AltScreenSegmentStripper|SyncUpdateFrameCollapser|ScrollbackDistiller|TerminalQueryStripper|PromptEOLMarkStripper)\b)|(func (splitTrailingIncompleteEscape|splitTrailingIncompleteUTF8)\b|trailingEscapeScanBytes *[:=])|((enum|struct|final class|class|actor) (ScrollbackJournal|ScrollbackJournalStore)\b)|((createFile|forWritingTo|\.write\(to:).*\.(scrollback|resume)("|\)|$))|((enum|struct|final class|class|actor) (HostOutputSniffer|OutputSniffer)\b)|((enum|struct|final class|class|actor) (CommandBlockSegmenter|CommandBlockTracker|AutoProgressMatcher)\b)|(\[\[rules\]\]|min_engine_version\s*=|skip_state_update\s*=|line_regex\s*=)|(autoProgressCommands: \[String\]|autoProgressPrefixes)'
DELETED_SWIFT_CANDIDATES=$(grep -rlE "${DELETED_SWIFT_UNION}" Sources/ 2> /dev/null || true)
# The candidates matching ONE ban, or nothing. An empty candidate list answers without a grep.
among_deleted() {
  [[ -z "${DELETED_SWIFT_CANDIDATES}" ]] && return 0
  # shellcheck disable=SC2086 # the candidate list is a FILE LIST on purpose
  grep -lE "$1" ${DELETED_SWIFT_CANDIDATES} 2> /dev/null || true
}

SWIFT_PATHS="Sources/SlopDeskSupervisor/SupervisorPaths.swift"
SWIFT_PROTOCOL="Sources/SlopDeskSupervisor/SupervisorProtocol.swift"
SWIFT_FRAME="Sources/SlopDeskSupervisor/SupervisorFrame.swift"
SWIFT_STREAM="Sources/SlopDeskHost/PaneOutputStream.swift"
RUST_PATHS="rust/slopdesk-superd/src/paths.rs"
RUST_PROTOCOL="rust/slopdesk-superd/src/protocol.rs"
RUST_SUPERD_SERVER="rust/slopdesk-superd/src/server.rs"
RUST_FRAME="rust/slopdesk-superd/src/frame.rs"
RUST_PUMP="rust/slopdesk-superd/src/pump.rs"
SWIFT_SCREEN_PATHS="Sources/SlopDeskScreen/ScreenPaths.swift"
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

# ── 1. The rendezvous address, and ONLY that ────────────────────────────────────────────────────
# Exactly one path is spelled in both languages, and it has to be: hostd must FIND the control
# socket before it can ask superd anything, so that one name cannot be learned from the thing it
# names. A mismatch in it is SILENCE rather than an error — hostd connects to a name nobody bound
# and reports only that no daemon is running.
if ! grep -q 'slopdesk-superd.sock' "${SWIFT_PATHS}"; then
  fail "${SWIFT_PATHS} no longer names slopdesk-superd.sock — hostd has no rendezvous address"
fi
if ! grep -q 'slopdesk-superd.sock' "${RUST_PATHS}"; then
  fail "${RUST_PATHS} no longer names slopdesk-superd.sock"
fi

# The OVERRIDE key for that same address, ratcheted for the same reason and with a quieter failure
# than the address itself. `SLOPDESK_SUPERD_SOCKET` is read by superd to decide where to BIND and set
# by hostd to decide where to DIAL, so a rename on one side does not disagree — hostd exports a
# variable superd never reads, superd binds the default, hostd dials the override, and the only
# symptom is the daemon appearing not to be running under a test harness that moved the socket.
if ! grep -q '"SLOPDESK_SUPERD_SOCKET"' "${SWIFT_PATHS}"; then
  fail "${SWIFT_PATHS} no longer names SLOPDESK_SUPERD_SOCKET — hostd would dial an address superd did not bind (docs/51 §1)"
fi
if ! grep -q '"SLOPDESK_SUPERD_SOCKET"' "${RUST_PATHS}"; then
  fail "${RUST_PATHS} no longer names SLOPDESK_SUPERD_SOCKET"
fi

# The agent-control address, on the same footing. hostd EXPORTS it into every PTY's environment and
# `slopdesk-ctl` — a separate binary an agent shells out to — READS it to find the socket. A rename
# on one side is the quietest failure of the three: every `slopdesk-ctl` invocation simply reports
# no host, which reads as "the control listener is off" and is the documented default.
if ! grep -q '"SLOPDESK_CONTROL_SOCKET"' "Sources/SlopDeskHost/HostEnvironment.swift"; then
  fail "Sources/SlopDeskHost/HostEnvironment.swift no longer exports SLOPDESK_CONTROL_SOCKET — slopdesk-ctl would find no host (docs/51 §1)"
fi
if ! grep -q '"SLOPDESK_CONTROL_SOCKET"' "rust/slopdesk-ctl/src/lib.rs"; then
  fail "rust/slopdesk-ctl/src/lib.rs no longer reads SLOPDESK_CONTROL_SOCKET"
fi

# The OTHER three are superd's alone, and Swift must not learn them. hostd is told the hook and
# agent-control paths in the `hello` reply, which is the whole reason that reply carries them; the
# lock file is none of its business. A Swift constant for any of them would be a second answer to
# "where is the hook socket", which is precisely the drift that pid-keyed paths caused once
# (`docs/51` §1). So this asserts an ABSENCE — the regression is a copy appearing, not a rename.
for name in slopdesk-agent.sock slopdesk-ctl.sock slopdesk-superd.lock; do
  if grep -rq -- "${name}" Sources/; then
    fail "'${name}' is spelled in Sources/ — superd owns that path and tells hostd at hello, see docs/51 §1"
  fi
done

# No pid in any of them. This is the bug the whole daemon exists to fix (`docs/51` §1): a restarted
# hostd binding a pid-suffixed path leaves every running agent holding an address with nothing
# behind it. CODE only: the prose above `#[cfg(test)]` explains the bug by naming `getpid()`, and
# the test below asserts the absence BY spelling `process::id()`. Matching either would be the gate
# failing on its own documentation and its own proof.
rust_paths_code=$(awk '/#\[cfg\(test\)\]/ { exit } !/^ *(\/\/|\*)/ { print }' "${RUST_PATHS}")
if grep -qE '(getpid|process::id)' <<< "${rust_paths_code}"; then
  fail "a pid reached superd's stable socket paths — see docs/51 §1"
fi
if grep -qE '(getpid|processIdentifier)' <<< "$(grep -vE '^ *(///|//|\*)' "${SWIFT_PATHS}")"; then
  fail "a pid reached hostd's rendezvous address — see docs/51 §1"
fi

# ── 2. Protocol version ─────────────────────────────────────────────────────────────────────────
# MAJOR gates the handshake, so a skew is at least loud. MINOR is capability negotiation and a skew
# is quiet: hostd would send a verb this superd does not know, or withhold one it does.
swift_major=$(sed -n 's/.*versionMajor = \([0-9][0-9]*\).*/\1/p' "${SWIFT_PROTOCOL}" | head -1)
swift_minor=$(sed -n 's/.*versionMinor = \([0-9][0-9]*\).*/\1/p' "${SWIFT_PROTOCOL}" | head -1)
rust_major=$(sed -n 's/.*VERSION_MAJOR: i32 = \([0-9][0-9]*\).*/\1/p' "${RUST_PROTOCOL}" | head -1)
rust_minor=$(sed -n 's/.*VERSION_MINOR: i32 = \([0-9][0-9]*\).*/\1/p' "${RUST_PROTOCOL}" | head -1)
same "protocol major" "${swift_major}" "${rust_major}"
same "protocol minor" "${swift_minor}" "${rust_minor}"

# The minor above says what superd can SPEAK. It cannot say which BUILD is speaking — it moves only
# on a wire change, so a superd rebuilt with a fixed reaper reports the minor it always did. superd
# outlives hostd's build, so after an upgrade the binary on disk and the process on this socket are
# routinely different code, and restarting it takes every live pane. `buildVersion` on the hello
# reply is the one handle hostd has on which (`docs/49`); dropped on either side it reads as absent,
# which the audit reports as "unknown" forever rather than failing.
if ! grep -q 'rename = "buildVersion"' "${RUST_PROTOCOL}"; then
  fail "superd's hello no longer carries buildVersion — hostd cannot tell a stale superd from a current one (docs/49)"
fi
if ! grep -q 'build_version: Some(env!("CARGO_PKG_VERSION")' "${RUST_SUPERD_SERVER}"; then
  fail "superd's hello no longer answers with its OWN compile-time version — see ${RUST_SUPERD_SERVER}"
fi
if ! grep -q 'var buildVersion: String?' "${SWIFT_PROTOCOL}"; then
  fail "${SWIFT_PROTOCOL}'s HelloReply no longer decodes buildVersion (docs/49)"
fi

# The reserved `id` that marks a reply as an unsolicited NOTIFICATION rather than an answer. Same
# ratchet, and quieter than either version: a skew makes hostd read every notification as the answer
# to whichever request happens to carry that id, and reply to a verb nobody sent.
swift_notification=$(sed -n 's/.*notificationID: UInt64 = \([0-9][0-9]*\).*/\1/p' "${SWIFT_PROTOCOL}" | head -1)
rust_notification=$(sed -n 's/.*NOTIFICATION_ID: u64 = \([0-9][0-9]*\).*/\1/p' "${RUST_PROTOCOL}" | head -1)
same "notification id" "${swift_notification}" "${rust_notification}"

# ── 3. Verbs and events ─────────────────────────────────────────────────────────────────────────
# Every verb Swift can SEND must be one Rust can dispatch. Not the converse: superd is allowed to
# know a verb no hostd sends yet, which is how a minor bump lands in two commits.
# camelCase in the capture, not just lowercase: `forgetTitle` is a verb, and a pattern that could
# not see it would have passed this gate while hostd sent a verb superd never dispatched.
swift_verbs=$(sed -n 's/^ *public static let [a-zA-Z]* = "\([a-zA-Z]*\)"$/\1/p' "${SWIFT_PROTOCOL}" | sort -u)
# An empty list is not "every verb crosses" — it is a loop that runs zero times, and `sed` returns
# it without complaint. The gate below only ever reports what it iterates, so the liveness of the
# extraction has to be asserted here or not at all.
if [[ -z "${swift_verbs}" ]]; then
  fail "no sendable verb found in ${SWIFT_PROTOCOL} — the extraction in this gate has gone stale"
fi
for verb in ${swift_verbs}; do
  if ! grep -q "= \"${verb}\";" "${RUST_PROTOCOL}"; then
    fail "verb '${verb}' is sendable from Swift but has no constant in ${RUST_PROTOCOL}"
  fi
done

# ── 3b. Listener kinds ──────────────────────────────────────────────────────────────────────────
# The names hostd `listen`s for and superd binds and advertises. Equal in BOTH directions here,
# unlike the verbs above, because each side's extra is silent in a different way: a kind only Swift
# knows is a claim superd refuses, and a kind only Rust knows is a socket nobody ever claims — and
# an unclaimed socket is never advertised into a child's environment (`listeners.rs`), so a `claude`
# would simply come up with no hook path and fall back to the screen engine. Nothing logs an error.
swift_kinds=$(
  awk '/public enum ListenerKind \{/, /^    \}/' "${SWIFT_PROTOCOL}" |
    sed -n 's/.*public static let [a-zA-Z]* = "\([a-z]*\)".*/\1/p' | sort -u
)
rust_kinds=$(
  awk '/pub mod listener_kind \{/, /^\}/' "${RUST_PROTOCOL}" |
    sed -n 's/.*: &str = "\([a-z]*\)";.*/\1/p' | sort -u
)
if [[ -z "${swift_kinds}" ]]; then
  fail "no listener kinds found in ${SWIFT_PROTOCOL} — the extraction in this gate has gone stale"
fi
same "listener kinds" "$(echo "${swift_kinds}" | tr '\n' ' ')" "$(echo "${rust_kinds}" | tr '\n' ' ')"

# ── 4. Frame tags and the body cap ──────────────────────────────────────────────────────────────
# This gate used to COMPARE two spellings — `SupervisorFrame.swift`'s constants against superd's
# `frame.rs` ones — because there were two. There is one now (`slopdesk-superwire`), which superd
# re-exports and hostd reads through a door, so skew between the two ends is no longer expressible
# and there is nothing left to compare. What is still worth pinning, and is now the only thing that
# can go wrong, is the NUMBERING itself: it is the wire, every deployed peer of every version reads
# it, and a shifted constant desynchronises all of them at once. So this is a one-sided pin.
#
# The quietest skew this socket ever had: superd writes a tag hostd does not know, hostd answers
# `unknownTag` and drops the CONNECTION — every pane at once, on the first title anybody's shell
# writes. An absent constant reads as an empty string here and fails the same way a wrong one does.
SUPERWIRE=rust/slopdesk-superwire/src/lib.rs
declare -a frame_tags=(
  "plain:TAG_PLAIN:0x01"
  "with descriptor:TAG_WITH_DESCRIPTOR:0x02"
  "output:TAG_OUTPUT:0x03"
  "sniff:TAG_SNIFF:0x04"
  # The block tap has its own tag rather than sharing the sniffer's batch because the two answer to
  # DIFFERENT gates (shellIntegration vs blocks), and what keeps a new tag inside the append-only
  # rule is that each tag has exactly one thing to ask for.
  "blocks:TAG_BLOCKS:0x05"
)
for entry in "${frame_tags[@]}"; do
  label="${entry%%:*}"
  rest="${entry#*:}"
  found=$(sed -n "s/.*${rest%%:*}: u8 = \(0x[0-9a-fA-F]*\).*/\1/p" "${SUPERWIRE}" | head -1)
  same "frame tag (${label})" "${found}" "${rest#*:}"
done

# The cap is a refusal on both sides, so the LOWER one governs — and one declaration is how they
# stay equal, which is the only setting where neither side can produce a frame the other will not
# take. Pinned to the number rather than to another copy of it, for the same reason as the tags.
super_cap=$(sed -n 's/.*MAX_BODY_BYTES: usize = \(.*\);$/\1/p' "${SUPERWIRE}" | head -1 | tr -d ' ')
same "maximum body bytes" "${super_cap}" "4*1024*1024"

# ── 5. The read chunk ───────────────────────────────────────────────────────────────────────────
# Not a wire constant — superd alone reads with it — but a JOINT decision, and the Swift copy is
# what the bounded-queue sizing is reasoned against. 32 KiB is half `hostQueueCapacityBytes`, so the
# gate's worst overshoot is capacity plus one read. Raising one without the other silently re-opens
# a problem that was solved once: a read larger than the bound pauses on every flood chunk.
swift_chunk=$(sed -n 's/.*readChunkSize = \(.*\)$/\1/p' "${SWIFT_STREAM}" | head -1 | tr -d ' ')
rust_chunk=$(sed -n 's/.*READ_CHUNK_BYTES: usize = \(.*\);$/\1/p' "${RUST_PUMP}" | head -1 | tr -d ' ')
same "PTY read chunk" "${swift_chunk}" "${rust_chunk}"

# ── 6. Nothing in hostd reads a master ──────────────────────────────────────────────────────────
# The ratchet for the invariant this whole subsystem now turns on. hostd's master is the SAME open
# file description superd reads (`SCM_RIGHTS` duplicates the descriptor, not the description), so a
# second reader here does not observe the stream — it steals from it, and an `O_NONBLOCK` set on it
# lands on superd's reads too. Writes, `ioctl` and `tcgetpgrp` are fine and are why hostd still
# holds the fd at all.
if grep -rnE '\b(read|poll|select)\([^)]*masterFD' Sources/ | grep -v 'readChunkSize'; then
  fail "something in Sources/ reads or polls a PTY master — superd owns the read side (CLAUDE.md, docs/51 §6.5)"
fi

# ── 7. No pid in ANY unix socket a survivor reconnects to ─────────────────────────────
# §1 ratchets superd's own three paths. This is the same bug everywhere else, because it was never
# confined to them: the code panel's bridge socket carried `getpid()` until 2026-08-11, so a running
# code-server — which now survives a hostd restart — kept dialling the address of the hostd that
# started it, forever. A child remembers its `execve` environment and nothing can correct it.
pid_sockets=$(grep -rn '\.sock' Sources/ | grep -vE ':[0-9]+: *(///|//|\*)' | grep -E 'getpid|processIdentifier' || true)
if [[ -n "${pid_sockets}" ]]; then
  printf '%s\n' "${pid_sockets}" >&2
  fail "a unix socket path in Sources/ carries a pid — a survivor holds an address nobody will rebind (docs/51 §1)"
fi

# ── 8. hostd's stop lets the panel backends GO ────────────────────────────────────
# `relinquish` vs `terminate` is the line the whole daemon is drawn along (`docs/51` §5.5), and the
# panel is where it is easiest to cross by accident: both spellings compile, both look like cleanup,
# and the difference only shows up as the user watching Node boot again after every host edit.
# The Android manager USED to be exempt — its bridge was an in-process listener with no child to
# keep. It is `slopdesk-androidd` under superd now (`docs/48`), so it is held to the same line: a
# `shutdown()` here kills every live mirror on a host edit, which is the exact regression this rule
# was written for. (The DEVICES it boots stay orphaned on purpose — `docs/51` §8.)
if grep -nE '(HostCodeServerPerformer|HostSimulatorPerformer|HostAndroidPerformer)\.sharedManager\.shutdown\(\)' Sources/SlopDeskHost/HostServer.swift; then
  fail "hostd's stop TERMINATES a panel backend — it must relinquish it (docs/51 §6.7)"
fi

# ── 9. screend: the SECOND two-ended protocol ───────────────────────────────────────────────────
# Same shape as superd's, same silence when it drifts (`docs/52`). Three things are typed twice and
# nothing else is: the rendezvous socket name, the verb bytes, and the hello banner.
if ! grep -q 'slopdesk-screend.sock' "${SWIFT_SCREEN_PATHS}"; then
  fail "${SWIFT_SCREEN_PATHS} no longer names slopdesk-screend.sock — the client has no address"
fi
if ! grep -q 'slopdesk-screend.sock' "${RUST_SCREEN_SERVER}"; then
  fail "${RUST_SCREEN_SERVER} no longer names slopdesk-screend.sock"
fi
if grep -qE '(getpid|processIdentifier)' <<< "$(grep -vE '^ *(///|//|\*)' "${SWIFT_SCREEN_PATHS}")"; then
  fail "a pid reached screend's rendezvous address — see docs/51 §1"
fi

# Verb NUMBERS, not names: the wire carries the byte, and a reordered enum on one side is a
# `compose` answered with a `transcript` — same status, same framing, silently the wrong bytes.
# Scoped to the `ScreenVerb` enum: `ScreenStatus` right below it spells `case ok = 0` too, and a
# whole-file sweep would compare a status against a verb.
swift_screen_verbs=$(
  awk '/public enum ScreenVerb/, /^\}/' "${SWIFT_SCREEN_PROTOCOL}" |
    sed -n 's/^ *case \([a-z][a-zA-Z]*\) = \([0-9][0-9]*\)$/\1 \2/p'
)
if [[ -z "${swift_screen_verbs}" ]]; then
  fail "no screend verbs found in ${SWIFT_SCREEN_PROTOCOL} — the extraction in this gate has gone stale"
fi
while read -r name number; do
  [[ -n "${name}" ]] || continue
  # `\U` is a GNU sed extension and this runs on BSD sed; awk's toupper is portable.
  rust_name="$(printf '%s' "${name}" | awk '{print toupper(substr($0, 1, 1)) substr($0, 2)}')"
  if ! grep -qE "^ *${rust_name} = ${number},$" "${RUST_SCREEN_PROTOCOL}"; then
    fail "screend verb '${name}' is ${number} in Swift but not '${rust_name} = ${number}' in ${RUST_SCREEN_PROTOCOL}"
  fi
done <<< "${swift_screen_verbs}"

# Verb 7 is RETIRED on both sides and must stay unallocated. It was `sanitize` — the whole replay
# transform reached over a socket, which was the mistake: `sanitize` is a pure function, so by this
# repo's own socket-vs-library rule it belongs linked, and it is `rust/slopdesk-sanitize` now.
# Reusing the number would let a hostd built before the extraction land its cold reattach on a verb
# that means something else entirely. Scoped to each enum for the same reason the loop above is:
# `ScreenStatus` is free to grow a 7.
if grep -qE '= 7$' <<< "$(awk '/public enum ScreenVerb/, /^\}/' "${SWIFT_SCREEN_PROTOCOL}")"; then
  fail "${SWIFT_SCREEN_PROTOCOL} allocated screend verb 7 again — it is retired, the replay transform is linked (docs/52)"
fi
if grep -qE '= 7,$' <<< "$(awk '/pub enum Verb/, /^\}/' "${RUST_SCREEN_PROTOCOL}")"; then
  fail "${RUST_SCREEN_PROTOCOL} allocated screend verb 7 again — it is retired, the replay transform is linked (docs/52)"
fi

# The video FEC's Swift half, and the last C target in the tree. `GF256.swift` carried the field and
# `NeonGf`, the hand-written kernel that reached into `Sources/CSlopDeskSIMD` with
# `UnsafeBufferPointer` and a `swiftlint:disable force_unwrapping` — the least safe code here, on
# the path that parses hostile UDP. All of it is `rust/slopdesk-video` now, with the one vector loop
# isolated in `rust/slopdesk-gfsimd`. A Swift GF backend coming back would not fail a test: it would
# quietly be a second implementation of the wire, which is the rule this pins (docs/DECISIONS.md).
for gone in Sources/SlopDeskVideoProtocol/GF256.swift \
  Sources/SlopDeskVideoProtocol/ReedSolomonMatrix.swift \
  Sources/CSlopDeskSIMD \
  Tests/SlopDeskVideoProtocolTests/GF256NeonDifferentialTests.swift; do
  if [[ -e "${gone}" ]]; then
    fail "${gone} is back — the FEC field lives in rust/slopdesk-video, its kernel in rust/slopdesk-gfsimd"
  fi
done
gf_revived=$(among_deleted '(enum|struct|final class) (GF256|NeonGf|ReedSolomonMatrix)\b')
if [[ -n "${gf_revived}" ]]; then
  printf '%s\n' "${gf_revived}" >&2
  fail "a Swift GF(2^8) backend is back in Sources/ — one implementation, and it is the Rust one"
fi

# The SEND path went the same way, one layer up. `VideoPacketizer` is a handle onto
# `rust/slopdesk-video`'s packetizer now: the MTU split, the tier ladder's per-frame FEC shape, the
# parity, the interleave and the 19-byte stamp are all over there. A Swift rebuild of any of them
# would not fail a test either — it would just be a second implementation of the wire, and the
# byte-identity pins would keep passing right up until the two drifted. So the pin is on the SHAPE:
# the packetizer holds a handle and no longer builds a fragment itself.
SWIFT_PACKETIZER=Sources/SlopDeskVideoProtocol/FramePacketizer.swift
for entry in slopdesk_video_packetizer_raw slopdesk_video_packetizer_answer slopdesk_video_packetizer_free; do
  if ! grep -q "${entry}(" "${SWIFT_PACKETIZER}"; then
    fail "${SWIFT_PACKETIZER} no longer calls ${entry} — the send path is Rust's (docs/55 §4b)"
  fi
done
for revived in packetizeFragments makeFragment; do
  if grep -q "func ${revived}" "${SWIFT_PACKETIZER}"; then
    fail "${SWIFT_PACKETIZER} grew '${revived}' back — the fragments are built in rust/slopdesk-video"
  fi
done
# The transmit reorder went with it. It had ONE caller left outside the packetizer —
# `slopdesk-loopback-validate`, reordering by hand after asking for an un-interleaved frame — which
# is the shape a mirror takes: a tool that reproduces the host's composition instead of driving it.
for gone in Sources/SlopDeskVideoProtocol/FragmentInterleaver.swift \
  Tests/SlopDeskVideoProtocolTests/FragmentInterleaverTests.swift; do
  if [[ -e "${gone}" ]]; then
    fail "${gone} is back — the reorder law is rust/slopdesk-video's, reached through packetize(interleave:)"
  fi
done

# The RECEIVE path went with the send path, and it is the half that parses hostile UDP: every
# fragment-count, frag-index and frontier-jump guard is `rust/slopdesk-video`'s `reassembler` now.
# A Swift rebuild here would be the worst of the three to have twice, because the guards are what
# stop a crafted datagram allocating per frame, and two copies of a guard drift silently.
SWIFT_REASSEMBLER=Sources/SlopDeskVideoProtocol/FrameReassembler.swift
for entry in slopdesk_video_reassembler_ingest slopdesk_video_reassembler_frame_avcc \
  slopdesk_video_reassembler_free; do
  if ! grep -q "${entry}(" "${SWIFT_REASSEMBLER}"; then
    fail "${SWIFT_REASSEMBLER} no longer calls ${entry} — the receive path is Rust's (docs/55 §4b)"
  fi
done
# The guards' own names, which only a re-implementation would need back.
for revived in maxFrontierJump resyncStreak resyncClusterWindow frontierJumpCandidates; do
  if grep -q "${revived}" "${SWIFT_REASSEMBLER}"; then
    fail "${SWIFT_REASSEMBLER} grew '${revived}' back — the hostile-input guards are Rust's"
  fi
done

# The datagram CODEC — the 19-byte header both paths meet at — is the same crate's, reached from
# the one Swift file that still names the layout. It is the smallest of the three and the easiest to
# rewrite by accident: nineteen bytes of big-endian appends look like something a reader "fixes"
# inline. A second copy would pass every byte-identity test until one side moved a field.
for entry in slopdesk_video_fragment_encode slopdesk_video_fragment_decode; do
  if ! grep -q "${entry}(" "${SWIFT_PACKETIZER}"; then
    fail "${SWIFT_PACKETIZER} no longer calls ${entry} — the wire layout is rust/slopdesk-video's"
  fi
done
if grep -q 'appendBE(header\.' "${SWIFT_PACKETIZER}"; then
  fail "${SWIFT_PACKETIZER} builds a header byte by byte again — encode it through the Rust codec"
fi
# The dead scheduler arm went with it: it re-encoded fragments the send path had already produced as
# bytes, and only a test kept it alive.
if grep -q 'func scheduleFrame(' Sources/SlopDeskVideoHost/VideoSessionLogic.swift; then
  fail "VideoSendScheduler.scheduleFrame is back — the send path schedules DATAGRAMS (scheduleFrameRaw)"
fi

# The FEC LADDER — which redundancy the measured loss buys — is the same crate's. Both ends read
# the tier off the wire, so a drifted threshold does not fail a test: it de-syncs a host from a
# client mid-session, on the exact link that was already losing packets.
SWIFT_ADAPTIVE_FEC=Sources/SlopDeskVideoProtocol/AdaptiveFECPolicy.swift
for entry in slopdesk_adaptive_fec_group_size slopdesk_adaptive_fec_tier \
  slopdesk_adaptive_fec_next_tier_state slopdesk_adaptive_fec_next_parity_tier_state \
  slopdesk_adaptive_fec_constant; do
  if ! grep -q "${entry}(" "${SWIFT_ADAPTIVE_FEC}"; then
    fail "${SWIFT_ADAPTIVE_FEC} no longer calls ${entry} — the ladder is rust/slopdesk-video's"
  fi
done
# The level ladder's own names: a re-implementation needs every one of them back.
for revived in levelForTier tierForLevel targetLevel mLevelForTier tierForMLevel mTargetLevel; do
  if grep -q "func ${revived}" "${SWIFT_ADAPTIVE_FEC}"; then
    fail "${SWIFT_ADAPTIVE_FEC} grew '${revived}' back — the hysteresis and the dwell are Rust's"
  fi
done
# And the differential fixture that compared the two implementations goes with the second one. A
# test carrying a verbatim copy of the deleted logic as its oracle IS the mirror the rule forbids.
if [[ -e Tests/SlopDeskVideoProtocolTests/RustAdaptiveFECParityTests.swift ]]; then
  fail "RustAdaptiveFECParityTests.swift is back — there is one ladder now, so there is nothing to diff"
fi

# The RECOVERY CHANNEL — the message codec, the escalation clock, the request redundancy and the
# loss window — is the same crate's. Its decoder is the other place hostile input is parsed, and its
# trailing-bytes rejection is load-bearing: the host's deduper keys on RAW datagram bytes, so a
# decoder that tolerated suffixes would re-admit one logical request as two host actions.
SWIFT_RECOVERY=Sources/SlopDeskVideoProtocol/RecoverySignaling.swift
for entry in slopdesk_recovery_encode slopdesk_recovery_decode \
  slopdesk_recovery_should_escalate_to_idr slopdesk_recovery_loss_window_note \
  slopdesk_recovery_loss_window_observing slopdesk_recovery_constant; do
  if ! grep -q "${entry}(" "${SWIFT_RECOVERY}"; then
    fail "${SWIFT_RECOVERY} no longer calls ${entry} — the recovery channel is rust/slopdesk-video's"
  fi
done
# The reader the codec used, and the helpers a re-implementation would need back.
for revived in VideoByteReader encodeRequestFragments decodeRequestFragments; do
  if grep -q "${revived}" "${SWIFT_RECOVERY}"; then
    fail "${SWIFT_RECOVERY} grew '${revived}' back — the recovery wire is parsed once, in Rust"
  fi
done
if [[ -e Tests/SlopDeskVideoProtocolTests/RustRecoveryPolicyParityTests.swift ]]; then
  fail "RustRecoveryPolicyParityTests.swift is back — one policy means there is nothing to diff"
fi
if [[ -e Tests/SlopDeskVideoProtocolTests/RustCoordinateMappingParityTests.swift ]]; then
  fail "RustCoordinateMappingParityTests.swift is back — one mapping means there is nothing to diff"
fi

# The UDP MUX PREFIX fronts every datagram on the video flow and splits every one that arrives, on
# both ends. Four bytes is exactly the size of thing that gets written twice and drifts once.
SWIFT_MUX=Sources/SlopDeskVideoProtocol/Mux/VideoMuxHeaderCodec.swift
for entry in slopdesk_mux_encode slopdesk_mux_decode slopdesk_mux_fragment_encode \
  slopdesk_mux_fragment_decode slopdesk_mux_constant; do
  if ! grep -q "${entry}(" "${SWIFT_MUX}"; then
    fail "${SWIFT_MUX} no longer calls ${entry} — the mux prefix is rust/slopdesk-video's"
  fi
done
# The writer and reader a hand-rolled prefix would need back, and the two widths it would respell.
for revived in appendBE VideoByteReader; do
  if grep -q "${revived}" "${SWIFT_MUX}"; then
    fail "${SWIFT_MUX} grew '${revived}' back — the mux bytes are laid out once, in Rust"
  fi
done
if grep -qE '(static let|=) *(4 \+ 4|19)\b' "${SWIFT_MUX}"; then
  fail "${SWIFT_MUX} spells a header width again — slopdesk_mux_constant vends both of them"
fi

# CLIENT INPUT EVENTS are the shortest path from a hostile datagram to a window-server call: the
# host decodes one off an unauthenticated socket and posts it. The finite-coordinate guard is a
# decode guard for that reason, and it exists once.
SWIFT_INPUT=Sources/SlopDeskVideoProtocol/InputEventCodec.swift
for entry in slopdesk_input_event_encode slopdesk_input_event_decode slopdesk_input_event_constant; do
  if ! grep -q "${entry}(" "${SWIFT_INPUT}"; then
    fail "${SWIFT_INPUT} no longer calls ${entry} — the input wire is rust/slopdesk-video's"
  fi
done
for revived in appendBE VideoByteReader readFiniteFloat64; do
  if grep -q "${revived}" "${SWIFT_INPUT}"; then
    fail "${SWIFT_INPUT} grew '${revived}' back — input datagrams are parsed once, in Rust"
  fi
done

# The three LOW-RATE METADATA WIRES answer to one shim. Geometry coordinates end up in a CALayer
# frame (a NaN there is an uncaught CALayerInvalidGeometry), the swipe status drives an affordance
# that must not promise a navigation the host would refuse, and an audio datagram declares its own
# payload length — the classic over-allocate lever.
declare -a METADATA_WIRES=(
  "Sources/SlopDeskVideoProtocol/WindowGeometryCodec.swift:slopdesk_window_geometry_encode:slopdesk_window_geometry_decode"
  "Sources/SlopDeskVideoProtocol/SwipeNavStatusCodec.swift:slopdesk_swipe_nav_status_encode:slopdesk_swipe_nav_status_decode"
  "Sources/SlopDeskVideoProtocol/AudioWireCodec.swift:slopdesk_audio_encode:slopdesk_audio_decode"
)
for wire in "${METADATA_WIRES[@]}"; do
  swift_file="${wire%%:*}"
  rest="${wire#*:}"
  for entry in "${rest%%:*}" "${rest#*:}"; do
    if ! grep -q "${entry}(" "${swift_file}"; then
      fail "${swift_file} no longer calls ${entry} — that wire is rust/slopdesk-video's"
    fi
  done
done
# The audio cap and the swipe status's flag bits are the two numbers a second speller would drift.
# Prose may still name them — a doc comment cannot be what the decoder reads.
if grep -qE '8192|1 << [012]' <<< "$(grep -hvE '^[[:space:]]*//' \
  Sources/SlopDeskVideoProtocol/AudioWireCodec.swift \
  Sources/SlopDeskVideoProtocol/SwipeNavStatusCodec.swift)"; then
  fail "an audio cap or a swipe flag bit is spelled in Swift again — the constant vends are there for it"
fi

# The CURSOR side-channel and the AVCC SPLIT both answer a span into the caller's datagram rather
# than a copy — the cursor's PNG and a frame's NAL units are the two payloads on this path big
# enough that copying them to describe them would be the whole cost. The cursor's coordinates are
# finite-checked at decode for the geometry reason; a ragged AVCC tail ends the walk rather than
# failing it, so a partly-arrived frame still decodes.
declare -a SPAN_WIRES=(
  "Sources/SlopDeskVideoProtocol/CursorCodec.swift:slopdesk_cursor_encode:slopdesk_cursor_constant"
  "Sources/SlopDeskVideoProtocol/CursorShapeCodec.swift:slopdesk_cursor_encode:slopdesk_cursor_decode"
  "Sources/SlopDeskVideoProtocol/NALUnit.swift:slopdesk_nal_split:slopdesk_nal_join"
)
for wire in "${SPAN_WIRES[@]}"; do
  swift_file="${wire%%:*}"
  rest="${wire#*:}"
  for entry in "${rest%%:*}" "${rest#*:}"; do
    if ! grep -q "${entry}(" "${swift_file}"; then
      fail "${swift_file} no longer calls ${entry} — that wire is rust/slopdesk-video's"
    fi
  done
done
# The four numbers those two wires would drift on: the cursor's two type bytes, its 36-byte update,
# its 27-byte header and the 4-byte AVCC prefix. Prose may still name them.
if grep -hvE '^[[:space:]]*//' Sources/SlopDeskVideoProtocol/CursorCodec.swift \
  Sources/SlopDeskVideoProtocol/CursorShapeCodec.swift Sources/SlopDeskVideoProtocol/NALUnit.swift |
  grep -qE '(static let|=) *(36|27|4)\b'; then
  fail "a cursor or AVCC width is spelled in Swift again — slopdesk_cursor/nal_constant vend them"
fi

# The THREE PER-FRAME MEASUREMENTS the capture path takes on a locked pixel buffer: the frame hash
# that suppresses a re-delivery, the scroll shift the client reprojects on, and the change fraction
# that sets the per-frame QP ceiling. All three are `rust/slopdesk-video`, reached through the one
# door that takes an ADDRESS rather than bytes — there is no `Data` behind an `IOSurface` to lend.
#
# This is the path where a second implementation would be least visible and most expensive: the
# fold is xxHash64-SHAPED but not xxHash64, so no published oracle would catch a Swift copy drifting
# from it, and a hash that agrees with itself while disagreeing with the Rust suppresses real frames
# — which the viewer sees as a freeze on stale content, not as an error.
SWIFT_FRAME_MEASURE=Sources/SlopDeskVideoProtocol/FrameMeasurement.swift
for entry in slopdesk_video_frame_hash_nv12 slopdesk_video_frame_hash_sentinel \
  slopdesk_video_scroll_nv12 slopdesk_video_adaptive_qp_nv12; do
  if ! grep -q "${entry}(" "${SWIFT_FRAME_MEASURE}"; then
    fail "${SWIFT_FRAME_MEASURE} no longer calls ${entry} — the frame measurements are rust/slopdesk-video's"
  fi
done
for gone in Sources/SlopDeskVideoProtocol/FrameHasher.swift \
  Sources/SlopDeskVideoProtocol/ScrollShiftEstimator.swift \
  Sources/SlopDeskVideoProtocol/AdaptiveFrameQP.swift; do
  if [[ -e "${gone}" ]]; then
    fail "${gone} is back — one fold, one estimator, one QP ramp, and they are Rust's"
  fi
done
# The fold, the two laws and the plane validation, none of which may grow back ANYWHERE in Sources/:
# each is small, pure and framework-free, which is exactly the shape a "tiny local helper" takes.
measure_revived=$(among_deleted '(struct|enum|final class) StreamHasher\b|func (hashRow|hashNV12Scalar|rowHashes|rowHashesQuantized|borrowPlane|estimateVerticalShift|changedFraction|adaptiveMaxQP)\b')
if [[ -n "${measure_revived}" ]]; then
  printf '%s\n' "${measure_revived}" >&2
  fail "a Swift frame-measurement law is back in Sources/ — rust/slopdesk-video owns the fold and both laws"
fi
# The sentinel, the lane primes and the plane ceiling: the numbers a second speller would drift.
if grep -vE '^[[:space:]]*//|^[[:space:]]*///' "${SWIFT_FRAME_MEASURE}" |
  grep -qE 'UInt64\.max|16384|0x9E37_79B1|0x2752_5BA1|4149_534C'; then
  fail "${SWIFT_FRAME_MEASURE} spells a frame-hash constant again — the door vends the sentinel"
fi
printf 'check-supervisor: the per-frame measurements are Rust too — one fold, no Swift hasher.\n'

# The FOUR PURE POLICIES either end reads on every frame or every tick: the shader's colour matrix,
# the click mapping, one step of the playout buffer, the frozen-stream verdict. Each is a handful of
# arithmetic with no state behind it, which is precisely the shape someone reimplements in place
# rather than calls.
#
# Two of them are pinned in golden/golden_vectors.json as IEEE bit patterns, and that is the whole
# argument: a Swift copy of `coordWindowPoint` or `ycbcr` agrees with the Rust until a compiler fuses
# a multiply and an add or widens an f32 through an f64, and then a click lands a pixel off — or the
# whole picture shifts a code value — on ONE machine, with every test still green.
declare -a POLICY_FACES=(
  "Sources/SlopDeskVideoProtocol/YCbCrConversion.swift:slopdesk_ycbcr_coefficients"
  "Sources/SlopDeskVideoProtocol/CoordinateMapping.swift:slopdesk_coord_window_point"
  "Sources/SlopDeskVideoProtocol/AdaptivePlayoutPolicy.swift:slopdesk_playout_step_ms"
  "Sources/SlopDeskVideoProtocol/StreamStallPolicy.swift:slopdesk_stream_stall_verdict"
)
for face in "${POLICY_FACES[@]}"; do
  policy_file="${face%%:*}"
  policy_entry="${face##*:}"
  if ! grep -q "${policy_entry}(" "${policy_file}"; then
    fail "${policy_file} no longer calls ${policy_entry} — the policy is rust/slopdesk-video's"
  fi
done
# The arithmetic itself, which may not grow back anywhere in Sources/. `windowPoint(pixel:` and the
# CG↔Cocoa flip went with this port: they had no caller outside their own tests, and the Rust twin
# that survives them is the only one left.
policy_revived=$(among_deleted 'func (targetSeconds|stepSeconds|cgRectToCocoa|backingScaleFactor)\(|(struct|enum|final class) ScreenInfo\b')
if [[ -n "${policy_revived}" ]]; then
  printf '%s\n' "${policy_revived}" >&2
  fail "a Swift policy law is back in Sources/ — rust/slopdesk-video owns the clamp, the flip and the step"
fi
# The pinned constants. A coefficient spelled on this side is a second source for a golden vector,
# and `255.0 / 219.0` written in Swift is `Double` unless someone remembers the annotation.
if grep -vE '^[[:space:]]*//|^[[:space:]]*///' Sources/SlopDeskVideoProtocol/YCbCrConversion.swift |
  grep -qE '1\.5748|0\.1873|0\.4681|1\.8556|255\.0|219\.0'; then
  fail "YCbCrConversion.swift spells a BT.709 coefficient again — the door vends the table"
fi
printf 'check-supervisor: the four pure policies are Rust too — the golden bit patterns have one speller.\n'

# The TERMINAL-MODE TRACKER: which screen the host presents, and where the command boundaries are.
# `rust/slopdesk-terminal`'s grammar, reached through the handle door — a parser that must remember,
# because `ESC` at the end of one read and `[` at the start of the next is the normal case.
#
# This one had THREE implementations at once: the live Swift, a frozen pre-fast-path Swift copy kept
# as a differential oracle, and the Rust. The frozen copy is exactly the "test fake" the
# one-implementation rule names, and it must not come back — the oracle is the corpus now.
SWIFT_MODE_TRACKER=Sources/SlopDeskClaudeCode/TerminalModeTracker.swift
for entry in slopdesk_mode_tracker_new slopdesk_mode_tracker_free slopdesk_mode_tracker_reset \
  slopdesk_mode_tracker_consume slopdesk_mode_tracker_event slopdesk_mode_tracker_mode \
  slopdesk_mode_tracker_bracketed_paste_active slopdesk_mode_tracker_cursor_keys_application; do
  if ! grep -q "${entry}(" "${SWIFT_MODE_TRACKER}"; then
    fail "${SWIFT_MODE_TRACKER} no longer calls ${entry} — the tracker's grammar is rust/slopdesk-terminal's"
  fi
done
if [[ -e Tests/SlopDeskClaudeCodeTests/Support/LegacyTerminalModeTracker.swift ]]; then
  fail "the frozen Swift tracker copy is back — the golden corpus is the oracle, not a second machine"
fi
tracker_revived=$(grep -rlE '(struct|enum|final class) LegacyTerminalModeTracker\b|case (oscEscape|stringConsume|stringConsumeEscape)\b|func (handleCSI|handleOSC)\b' Sources/ Tests/ || true)
if [[ -n "${tracker_revived}" ]]; then
  printf '%s\n' "${tracker_revived}" >&2
  fail "a Swift terminal-mode state machine is back — one grammar, and it is Rust's"
fi
# The corpus key that was frozen-but-unread for as long as it existed. It is the port's differential
# now, so a suite that stops replaying it silently un-pins 16 cases again.
if ! grep -q 'terminalModeTracker' Tests/SlopDeskClaudeCodeTests/TerminalModeGoldenVectorTests.swift; then
  fail "TerminalModeGoldenVectorTests no longer reads the terminalModeTracker corpus key"
fi
printf 'check-supervisor: the terminal-mode grammar is Rust too — 16 corpus cases replay through the door.\n'

# The INPUT SURFACE: which box to offer, and which bytes coming back are the PTY echoing what the
# compose box just typed. `rust/slopdesk-terminal`'s `inputbox` (which owns the dedup ring), reached
# through one handle — because the alt-screen flip that switches A→B1 is the same flip that clears a
# half-matched echo, and splitting them would put that coupling back in Swift.
SWIFT_INPUT_BOX=Sources/SlopDeskClaudeCode/InputBoxModel.swift
for entry in slopdesk_input_box_new slopdesk_input_box_free slopdesk_input_box_reset \
  slopdesk_input_box_state slopdesk_input_box_ingest slopdesk_input_box_take_rendered \
  slopdesk_input_box_event slopdesk_input_box_record_compose_sent; do
  if ! grep -q "${entry}(" "${SWIFT_INPUT_BOX}"; then
    fail "${SWIFT_INPUT_BOX} no longer calls ${entry} — the input surface is rust/slopdesk-terminal's"
  fi
done
# The ring itself, which was `public` and separately tested but built by nothing except the model
# above. It crosses as that model's INTERIOR; a Swift one growing back is a second entrance to one
# state machine, with the record-then-echo ordering rule restated outside the door.
if [[ -e Sources/SlopDeskClaudeCode/InputDedupRing.swift ]]; then
  fail "the Swift dedup ring is back — rust/slopdesk-terminal's dedup crosses inside the input box"
fi
dedup_revived=$(grep -rlE '(struct|enum|final class) InputDedupRing\b|func expectedEchoBytes\(|func stepFilter\(' Sources/ Tests/ || true)
if [[ -n "${dedup_revived}" ]]; then
  printf '%s\n' "${dedup_revived}" >&2
  fail "a Swift hold-and-confirm echo ring is back — one implementation, and it is Rust's"
fi
printf 'check-supervisor: the input surface is Rust too — the dedup ring crosses as the model'"'"'s interior.\n'

# The LINK SCAN: paths, `path:line:col` diagnostics and URLs in the rows of the grid — the one scan
# behind the ⌘-hold underline, Jump-To and Hint Mode. `rust/slopdesk-terminal`'s `link`, reached
# through an arena door because the answer is a list of records each carrying up to two strings.
SWIFT_LINKS=Sources/SlopDeskWorkspaceCore/Terminal/TerminalLinkDetector.swift
for entry in slopdesk_link_scan slopdesk_link_scan_free slopdesk_link_scan_counts \
  slopdesk_link_scan_link slopdesk_link_scan_take_arena slopdesk_link_scalar_cells \
  slopdesk_link_text_cells; do
  if ! grep -q "${entry}(" "${SWIFT_LINKS}"; then
    fail "${SWIFT_LINKS} no longer calls ${entry} — the link scan is rust/slopdesk-terminal's"
  fi
done
# The scan itself, in the shapes it had in Swift. The last two alternatives are the East-Asian width
# TABLE the columns come from — matched on the scalar/character parameter, because a second copy of
# it would put every overlay one cell out on a CJK row without failing a test that has no CJK in it.
# (`ViLineMotion.cellWidth(_ line: String, at:)` is a CALLER of the door, not a table, and stays.)
scan_revived=$(grep -rlE 'func (trimWrapping|classifyURL|classifyMailto|classifyPath|pathShape|splitLineCol|lexicallyNormalize|fileURLPath)\(|func (isWide|isZeroWidth)\(_? ?[a-z]*: ?Unicode\.Scalar|func cellWidth(Of)?\(_? ?[a-z]*: ?(Character|String)\)' Sources/ Tests/ || true)
if [[ -n "${scan_revived}" ]]; then
  printf '%s\n' "${scan_revived}" >&2
  fail "a Swift link/path scan or cell-width table is back — one scan, and it is Rust's"
fi
# Both bounds are spelled on both sides — one as a `public static let` the call sites read, one as a
# `pub const` the scan enforces. A drift here is a hang bound or an overlay flood that no test sees.
for bound in "maxMatchesPerRow:MAX_MATCHES_PER_ROW" "maxScanColumnsDefault:MAX_SCAN_COLUMNS"; do
  swift_value=$(grep -oE "static let ${bound%%:*} = [0-9]+" "${SWIFT_LINKS}" | grep -oE '[0-9]+$' || true)
  rust_value=$(grep -oE "pub const ${bound##*:}: usize = [0-9]+" rust/slopdesk-terminal/src/link.rs |
    grep -oE '[0-9]+$' || true)
  if [[ -z "${swift_value}" || "${swift_value}" != "${rust_value}" ]]; then
    fail "${bound%%:*} is ${swift_value:-absent} in Swift but ${bound##*:} is ${rust_value:-absent} in Rust"
  fi
done
printf 'check-supervisor: the link scan is Rust too — bounds agree (%s matches, %s columns), no Swift width table.\n' \
  "$(grep -oE 'MAX_MATCHES_PER_ROW: usize = [0-9]+' rust/slopdesk-terminal/src/link.rs | grep -oE '[0-9]+$')" \
  "$(grep -oE 'MAX_SCAN_COLUMNS: usize = [0-9]+' rust/slopdesk-terminal/src/link.rs | grep -oE '[0-9]+$')"

# The COMMAND BLOCKS: the per-pane ring, the bookmark set and the output-request registry that
# resets with it — `rust/slopdesk-terminal`'s `blocks`, through ONE handle, because a reset drops
# the blocks and has to answer every in-flight request in the same breath.
SWIFT_BLOCKS=Sources/SlopDeskWorkspaceCore/Terminal/TerminalBlockModel.swift
for entry in slopdesk_block_status slopdesk_block_duration_label slopdesk_block_adjacent_failed \
  slopdesk_block_store_new slopdesk_block_store_free slopdesk_block_store_upsert \
  slopdesk_block_store_project slopdesk_block_store_first_seen \
  slopdesk_block_store_filtered slopdesk_block_store_is_bookmarked \
  slopdesk_block_store_toggle_bookmark slopdesk_block_store_set_bookmarks \
  slopdesk_block_store_bookmarks slopdesk_block_store_request slopdesk_block_store_is_pending \
  slopdesk_block_store_current_generation slopdesk_block_store_resolve \
  slopdesk_block_store_time_out slopdesk_block_store_reset slopdesk_block_store_take_stranded; do
  if ! grep -q "${entry}(" "${SWIFT_BLOCKS}"; then
    fail "${SWIFT_BLOCKS} no longer calls ${entry} — the command blocks are rust/slopdesk-terminal's"
  fi
done
# The rules that used to live in Swift, matched on the shapes they had. The eviction and the FIFO
# bookmark cap are the two a re-implementation would get subtly wrong in a way no existing test
# sees; the generation counter is the one that decides whether a stale timeout kills a live request.
blocks_revived=$(grep -rlE 'func evictIfNeeded\(|var requestGeneration\b|var bookmarkOrder\b' \
  Sources/ Tests/ || true)
if [[ -n "${blocks_revived}" ]]; then
  printf '%s\n' "${blocks_revived}" >&2
  fail "a Swift block ring / bookmark order / generation counter is back — one ring, and it is Rust's"
fi
# Both caps are spelled on both sides: a Swift `static let` the UI and the persistence read, a Rust
# `pub const` the ring enforces. A drift makes the client hold a block superd already evicted.
for cap in "maxBlocks:MAX_BLOCKS" "maxBookmarks:MAX_BOOKMARKS"; do
  swift_value=$(grep -oE "static let ${cap%%:*} = [0-9]+" "${SWIFT_BLOCKS}" | grep -oE '[0-9]+$' || true)
  rust_value=$(grep -oE "pub const ${cap##*:}: usize = [0-9]+" rust/slopdesk-terminal/src/blocks.rs |
    grep -oE '[0-9]+$' || true)
  if [[ -z "${swift_value}" || "${swift_value}" != "${rust_value}" ]]; then
    fail "${cap%%:*} is ${swift_value:-absent} in Swift but ${cap##*:} is ${rust_value:-absent} in Rust"
  fi
done
printf 'check-supervisor: the command blocks are Rust too — caps agree (%s blocks, %s bookmarks).\n' \
  "$(grep -oE 'MAX_BLOCKS: usize = [0-9]+' rust/slopdesk-terminal/src/blocks.rs | grep -oE '[0-9]+$')" \
  "$(grep -oE 'MAX_BOOKMARKS: usize = [0-9]+' rust/slopdesk-terminal/src/blocks.rs | grep -oE '[0-9]+$')"

# The host's two ADMISSION LAWS — `rust/slopdesk-video`'s `qp_control` and `recovery_idr`. They take
# opposite conventions on purpose and the far side is what picks: the quantiser controller is a
# Swift struct copied by value, so it crosses as a pure fold with no handle to alias; the recovery
# policy is a `final class` holding one token bucket, so it crosses as a handle.
SWIFT_QP=Sources/SlopDeskVideoHost/QPController.swift
SWIFT_IDR=Sources/SlopDeskVideoHost/RecoveryIDRPolicy.swift
for entry in slopdesk_qp_new slopdesk_qp_decide slopdesk_qp_clamped_int; do
  if ! grep -q "${entry}(" "${SWIFT_QP}"; then
    fail "${SWIFT_QP} no longer calls ${entry} — the constant-QP AIMD is rust/slopdesk-video's"
  fi
done
for entry in slopdesk_idr_policy_new slopdesk_idr_policy_free \
  slopdesk_idr_policy_note_keyframe_sent slopdesk_idr_policy_note_keyframe_delivered \
  slopdesk_idr_policy_decide slopdesk_idr_policy_grace slopdesk_idr_policy_available_tokens; do
  if ! grep -q "${entry}(" "${SWIFT_IDR}"; then
    fail "${SWIFT_IDR} no longer calls ${entry} — the recovery-IDR admission is rust/slopdesk-video's"
  fi
done
# A handle that is allocated and never freed is the one failure a green test suite cannot see.
if ! grep -q 'deinit { slopdesk_idr_policy_free' "${SWIFT_IDR}"; then
  fail "${SWIFT_IDR} allocates a policy without freeing it in deinit — one new, one free"
fi
# The state a re-implementation would grow back. `cleanStreak` is the whole difference between one
# sharpen per interval and one per report; the keyframe ring and the bucket are the recovery law.
# Scoped to the video host, because a token bucket is a shape rather than a law — the notification
# rate limiter in SlopDeskWorkspaceCore is its own, and is not what these two entries pin.
qp_revived=$(grep -rlE 'var cleanStreak\b|var recentKeyframes\b|var tokens: Double|func refill\(now:' \
  Sources/SlopDeskVideoHost/ Tests/SlopDeskVideoHostTests/ || true)
if [[ -n "${qp_revived}" ]]; then
  printf '%s\n' "${qp_revived}" >&2
  fail "a Swift clean streak / keyframe ring / token bucket is back — those laws are Rust's"
fi
printf 'check-supervisor: the quantiser folds by value and the recovery policy holds a handle.\n'

# The RATE LAW — `rust/slopdesk-video`'s `congestion` and `network_estimate`, reached through the
# `abr` door. Two Swift structs their owners copy, so both cross by value, whole, every call. The
# only thing left on this side is resolving `SLOPDESK_ABR_*` through the overlay-aware EnvConfig.
SWIFT_ABR=Sources/SlopDeskVideoHost/LiveCongestionController.swift
SWIFT_ESTIMATE=Sources/SlopDeskVideoHost/VideoSessionLogic.swift
for entry in slopdesk_abr_config_default slopdesk_abr_new slopdesk_abr_with_ceiling \
  slopdesk_abr_effective_ceiling slopdesk_abr_set_user_ceiling slopdesk_abr_decide \
  slopdesk_abr_effective_slack slopdesk_abr_is_material_change; do
  if ! grep -q "${entry}(" "${SWIFT_ABR}"; then
    fail "${SWIFT_ABR} no longer calls ${entry} — the AIMD rate law is rust/slopdesk-video's"
  fi
done
for entry in slopdesk_net_estimate_new slopdesk_net_estimate_rtt_millis slopdesk_net_estimate_fold; do
  if ! grep -q "${entry}(" "${SWIFT_ESTIMATE}"; then
    fail "${SWIFT_ESTIMATE} no longer calls ${entry} — the report fold is rust/slopdesk-video's"
  fi
done
# The branches a re-implementation would grow back. Each names a decision the law makes, and a
# second speller of any one of them is a second control law that agrees on the easy cases.
abr_revived=$(grep -rlE 'func decideInner\(|func applyDecrease\(|func appLimitedDecay\(|func increaseStep\(|func utilizationPermitsRamp\(' \
  Sources/ Tests/ || true)
if [[ -n "${abr_revived}" ]]; then
  printf '%s\n' "${abr_revived}" >&2
  fail "a Swift AIMD branch is back — the rate law is decided once, behind slopdesk_abr_decide"
fi
# The EWMA weights are the fold, not a tunable: no env reads them and nothing hands them across, so
# a Swift copy could drift for a whole release without a test noticing.
if grep -rqE 'static let (rttAlpha|lossAlpha|minRTTDecay)\b' Sources/ Tests/; then
  fail "the estimate's EWMA weights are spelled in Swift again — they live in network_estimate.rs"
fi
# Every default is spelled once, on the far side: each env-resolved tunable falls back to a field of
# `slopdesk_abr_config_default()`, never to a literal. Counting the fallbacks is what catches a knob
# added later with a hand-written default beside it — the one drift no test can see, because both
# languages would still be internally consistent.
abr_defaults=$(grep -cE '\bdefaults\.[a-z_]+' "${SWIFT_ABR}" || true)
if ((abr_defaults < 24)); then
  fail "${SWIFT_ABR} reads only ${abr_defaults} defaults from the door — a knob is spelled twice"
fi
printf 'check-supervisor: the rate law folds by value, and its defaults are spelled once.\n'

# The FRAME-RATE axis — `rust/slopdesk-video`'s `fps_governor`, reached through `frame_rate`. Two
# governors, the gate they actuate through and the self-heal cadence, all in one Swift file.
SWIFT_FPS=Sources/SlopDeskVideoHost/FPSGovernor.swift
for entry in slopdesk_fps_config_default slopdesk_fps_ladder slopdesk_fps_governor_new \
  slopdesk_fps_governor_note_frame slopdesk_fps_governor_tick slopdesk_fps_congestion_evidence \
  slopdesk_fps_gate_admit slopdesk_fps_self_heal_every slopdesk_fps_pacer_config_default \
  slopdesk_fps_budget_millis slopdesk_fps_pacer_new slopdesk_fps_pacer_note; do
  if ! grep -q "${entry}(" "${SWIFT_FPS}"; then
    fail "${SWIFT_FPS} no longer calls ${entry} — the frame-rate axis is rust/slopdesk-video's"
  fi
done
# The LADDER is the shape both axes step, and a second speller of it would let the two disagree
# about which rungs exist. The gate's schedule arithmetic is the other one — a drift-free advance
# re-derived by hand is how a metronome becomes a beat pattern.
# Scoped to the video host, because a frame interval is a shape rather than a law — the loopback
# harness computes its own slot times, and is not what these entries pin.
fps_revived=$(grep -rlE 'rungs\.insert\(|for divisor in|nextDueSeconds \+=|1000\.0 / Double\(' \
  Sources/SlopDeskVideoHost/ Tests/SlopDeskVideoHostTests/ || true)
if [[ -n "${fps_revived}" ]]; then
  printf '%s\n' "${fps_revived}" >&2
  fail "a Swift ladder / cadence advance / per-frame budget is back — those live in fps_governor.rs"
fi
# The congestion predicate must keep reading the RATE law's tunables. A local copy of the inflate
# factor here is the drift that makes the frame rate step down on evidence the rate law ignored.
if ! grep -q 'LiveCongestionController.config' "${SWIFT_FPS}"; then
  fail "${SWIFT_FPS} stopped passing the ABR's own config — the two controllers must agree"
fi
printf 'check-supervisor: the frame-rate axis folds by value, and the ladder is derived once.\n'

# The PRESENTATION DEPTH — `rust/slopdesk-video`'s `pacer_depth`, reached through the door of the
# same name. Two Swift structs the FramePacer copies under its lock, so both cross by value, whole,
# every fold — the three rings included, because the windows are read over TIMES rather than counts.
SWIFT_DEPTH=Sources/SlopDeskVideoClient/PacerDepthPolicy.swift
SWIFT_OWD=Sources/SlopDeskVideoClient/OwdLateDetector.swift
for entry in slopdesk_pacer_depth_config_default slopdesk_pacer_depth_config_apply \
  slopdesk_pacer_depth_new slopdesk_pacer_depth_expected_interval \
  slopdesk_pacer_depth_late_threshold slopdesk_pacer_depth_note_arrival \
  slopdesk_pacer_depth_note_present slopdesk_pacer_depth_note_network_late \
  slopdesk_pacer_depth_note_reshow slopdesk_pacer_depth_drain \
  slopdesk_pacer_depth_set_interval_hint slopdesk_pacer_depth_eq; do
  if ! grep -q "${entry}(" "${SWIFT_DEPTH}"; then
    fail "${SWIFT_DEPTH} no longer calls ${entry} — the depth policy is rust/slopdesk-video's"
  fi
done
for entry in slopdesk_owd_late_config_default slopdesk_owd_late_config_apply \
  slopdesk_owd_late_new slopdesk_owd_late_note; do
  if ! grep -q "${entry}(" "${SWIFT_OWD}"; then
    fail "${SWIFT_OWD} no longer calls ${entry} — the spike detector is rust/slopdesk-video's"
  fi
done
# The state a re-implementation would grow back. The rings ARE the windows: a Swift ring here is a
# second promote window, a second dwell and a second dense-flow gate that agree only while nothing
# ages out. The two-bucket minimum is the same story for the baseline.
# Scoped to `Sources/`, because the tests are the parity evidence: they name the state they drive.
depth_revived=$(grep -rlE 'lateTimes\b|arrivalRing\b|intervalRing\b|currentBucketMin\b|previousBucketMin\b|func evaluatePromote\(|func evaluateDemote\(|func wasDense\(' \
  Sources/ || true)
if [[ -n "${depth_revived}" ]]; then
  printf '%s\n' "${depth_revived}" >&2
  fail "a Swift depth ring / promote-demote branch is back — those laws live in pacer_depth.rs"
fi
# Every band AND every knob name is the door's: the config is walked one env pair at a time, so a
# `SLOPDESK_DEPTH_*` literal in the SHIPPING code is a name the two languages could stop agreeing
# on. The tests spell them on purpose — that a knob still answers to its name is what they check.
if grep -rqE '"SLOPDESK_(DEPTH|OWD_LATE)_' Sources/; then
  fail "a SLOPDESK_DEPTH_*/SLOPDESK_OWD_LATE_* name is spelled in Swift — the door knows its knobs"
fi
printf 'check-supervisor: the presentation depth folds by value, rings and all.\n'

# The GRADIENT detector — `rust/slopdesk-video`'s `trendline`, reached through the door of the same
# name. A Swift struct its owner copies, so it folds by value with the regression WINDOW aboard.
SWIFT_TREND=Sources/SlopDeskVideoClient/TrendlineEstimator.swift
for entry in slopdesk_trendline_config_default slopdesk_trendline_config_apply \
  slopdesk_trendline_constants slopdesk_trendline_new slopdesk_trendline_note \
  slopdesk_trendline_is_stale slopdesk_trendline_pack_milli slopdesk_trendline_pack_flags \
  slopdesk_trendline_eq slopdesk_trend_sampler_new slopdesk_trend_sampler_should_sample; do
  if ! grep -q "${entry}(" "${SWIFT_TREND}"; then
    fail "${SWIFT_TREND} no longer calls ${entry} — the gradient detector is rust/slopdesk-video's"
  fi
done
# The regression itself, and the constants it runs against. A second OLS accumulator is a second
# slope; a Swift copy of kUp/kDown or the reset gap is a number no test compares across languages.
trend_revived=$(grep -rlE 'meanX\b|meanY\b|smoothedDelayMs\b|accumulatedDelayMs\b|overuseStartMs\b|= 0\.0087|= 0\.039' \
  Sources/ || true)
if [[ -n "${trend_revived}" ]]; then
  printf '%s\n' "${trend_revived}" >&2
  fail "a Swift OLS accumulator or threshold gain is back — the gradient law lives in trendline.rs"
fi
if grep -rqE '"SLOPDESK_TREND_' Sources/; then
  fail "a SLOPDESK_TREND_* name is spelled in Swift — the door knows its own knobs"
fi
printf 'check-supervisor: the gradient detector folds by value, window and all.\n'

# What the decoder is allowed to see, and in what order — `rust/slopdesk-video`'s `decode_admission`
# behind the door of the same name. Four folds: the frontier, the gate, the sequencer, the budget.
SWIFT_FRONTIER=Sources/SlopDeskVideoClient/DecodeFrontier.swift
SWIFT_GATE=Sources/SlopDeskVideoClient/DecodeGate.swift
SWIFT_SEQ=Sources/SlopDeskVideoClient/DecodeSequencer.swift
SWIFT_BUDGET=Sources/SlopDeskVideoClient/DecodeAdmissionBudget.swift
for entry in slopdesk_decode_frontier_new slopdesk_decode_frontier_note_decoded \
  slopdesk_decode_frontier_wire_value; do
  if ! grep -q "${entry}(" "${SWIFT_FRONTIER}"; then
    fail "${SWIFT_FRONTIER} no longer calls ${entry} — the frontier is rust/slopdesk-video's"
  fi
done
for entry in slopdesk_decode_gate_new slopdesk_decode_gate_note_loss \
  slopdesk_decode_gate_note_hard_decode_failure slopdesk_decode_gate_note_awaiting_keyframe \
  slopdesk_decode_gate_submits slopdesk_decode_gate_note_decode_succeeded; do
  if ! grep -q "${entry}(" "${SWIFT_GATE}"; then
    fail "${SWIFT_GATE} no longer calls ${entry} — the drop-until-anchor law is rust/slopdesk-video's"
  fi
done
for entry in slopdesk_decode_sequencer_constants slopdesk_decode_sequencer_new \
  slopdesk_decode_sequencer_note_completed slopdesk_decode_sequencer_note_lost; do
  if ! grep -q "${entry}(" "${SWIFT_SEQ}"; then
    fail "${SWIFT_SEQ} no longer calls ${entry} — the ordering law is rust/slopdesk-video's"
  fi
done
for entry in slopdesk_decode_budget_default slopdesk_decode_budget_new \
  slopdesk_decode_budget_admit slopdesk_decode_budget_complete; do
  if ! grep -q "${entry}(" "${SWIFT_BUDGET}"; then
    fail "${SWIFT_BUDGET} no longer calls ${entry} — the admission budget is rust/slopdesk-video's"
  fi
done
# The state a re-implementation would grow back. The sequencer's two SETS are the state a fold
# reads — which ids are outstanding, not how many — so a Swift `lostAhead`, a second `nextExpected`
# arithmetic or a second flush order is a second ordering law. The gate's two loss bounds and the
# frontier's keep-newest are the same story. What Swift legitimately keeps is a bag of PAYLOADS
# keyed by id (`frames`), because the law never reads a compressed byte.
# Scoped to `Sources/`, because the tests are the parity evidence: they name the state they drive.
decode_revived=$(grep -rlE 'lostAhead\b|func drainContiguous\(|func flushAll\(|distanceWrapped\(from: (expected|mn|mx)\b' \
  Sources/ || true)
if [[ -n "${decode_revived}" ]]; then
  printf '%s\n' "${decode_revived}" >&2
  fail "a Swift hold set / flush branch is back — those laws live in decode_admission.rs"
fi
# The valves and the caps are the door's numbers: the capacities that carry the sets across are
# proved against them, so a Swift literal is a bound the two languages could stop agreeing on.
if grep -rqE 'defaultMaxHeld = [0-9]|defaultMaxGap = [0-9]|maxPendingCount: Int = |16 << 20' \
  "${SWIFT_SEQ}" "${SWIFT_BUDGET}"; then
  fail "a Swift valve or cap literal is back — decode_admission.rs owns both bands"
fi
printf 'check-supervisor: the decoder admission folds by value, hold sets and all.\n'

# The audio jitter STAGE — `rust/slopdesk-video`'s `audio_jitter`, reached through the door of the
# same name. This one is a HANDLE, and the reason is the mirror of the sequencer's: the stage's whole
# product IS the samples, so they live where the decisions are.
SWIFT_AUDIO=Sources/SlopDeskVideoClient/AudioJitterBuffer.swift
for entry in slopdesk_audio_stage_new slopdesk_audio_stage_free slopdesk_audio_stage_shape \
  slopdesk_audio_stage_stats slopdesk_audio_stage_primed slopdesk_audio_stage_pending_frames \
  slopdesk_audio_stage_available_samples slopdesk_audio_stage_push slopdesk_audio_stage_pull \
  slopdesk_audio_stage_drain_available slopdesk_audio_stage_note_consumer_starved \
  slopdesk_audio_stage_drop_oldest_pending slopdesk_audio_stage_clear \
  slopdesk_audio_stage_shed_to_depth_bound slopdesk_audio_ring_target_samples \
  slopdesk_audio_consumer_starved; do
  if ! grep -q "${entry}(" "${SWIFT_AUDIO}"; then
    fail "${SWIFT_AUDIO} no longer calls ${entry} — the jitter stage is rust/slopdesk-video's"
  fi
done
# Exactly one free per new, and the free is the owner's deinit — a handle whose Swift owner stops
# freeing it leaks a stage per session, which no test would notice.
if ! grep -q 'deinit { slopdesk_audio_stage_free' "${SWIFT_AUDIO}"; then
  fail "${SWIFT_AUDIO}'s owner no longer frees its stage in deinit — one _free per _new (docs/55)"
fi
# The state a re-implementation would grow back. A Swift block list is a second reorder law and a
# second play frontier; the pump's two sample budgets and its starvation test are the door's too.
audio_revived=$(grep -rlE 'consumedBlocks\b|headSampleOffset\b|playFrontier\b|effectiveFrontier\b|func copyAvailable\(' \
  Sources/ || true)
if [[ -n "${audio_revived}" ]]; then
  printf '%s\n' "${audio_revived}" >&2
  fail "a Swift jitter block list or play frontier is back — that law lives in audio_jitter.rs"
fi
# The SPSC hand-off ring stays Swift ON PURPOSE — it is raw storage partitioned by two atomics so a
# real-time render thread never blocks on the producer, and it belongs to the runtime that owns the
# audio unit. If it ever grows a door entry, that decision needs a DECISIONS entry, not a commit.
if grep -q 'slopdesk_audio_ring_new\|slopdesk_audio_ring_produce\|slopdesk_audio_ring_consume' "${SWIFT_AUDIO}"; then
  fail "the SPSC hand-off ring crossed the door — that is a design change (docs/55, DECISIONS)"
fi
printf 'check-supervisor: the audio jitter stage is a handle, samples and all.\n'

# The PRESENTATION queue — `rust/slopdesk-video`'s `present_queue`, reached through the door of the
# same name. By value, like the decoder's admission and for the same reason: the queue is the big
# part and the near side never reads it, only the handle to present and the handles to let go of.
SWIFT_PACER=Sources/SlopDeskVideoClient/FramePacer.swift
for entry in slopdesk_present_queue_new slopdesk_present_queue_submit slopdesk_present_queue_step \
  slopdesk_present_queue_set_live_depth slopdesk_present_queue_adopt_live_depth \
  slopdesk_present_clamped_playout_seconds slopdesk_present_playout_recompute_due \
  slopdesk_present_deadline_for_arrival slopdesk_present_deadline_due \
  slopdesk_present_should_render slopdesk_present_should_present_on_arrival \
  slopdesk_present_resolve_tick_rate; do
  if ! grep -q "${entry}(" "${SWIFT_PACER}"; then
    fail "${SWIFT_PACER} no longer calls ${entry} — the presentation law is rust/slopdesk-video's"
  fi
done
# The state a re-implementation would grow back: a Swift frame array with its lockstep timestamps, a
# second priming latch, a second underflow run. What Swift legitimately keeps is a bag of IMAGES
# keyed by handle (`images`), because the law never dereferences a handle — and `lastShownFrame`,
# which outlives every handle the queue held.
# The leading `[^/]*` keeps prose out of it: the header and PacerDepthPolicy both NAME these, and a
# doc comment is not a second implementation.
pacer_revived=$(grep -rlE '^[^/]*(queueSubmittedAt\b|underflowRun (\+=|= 0)|primed = true|queue: \[CVImageBuffer\])' \
  Sources/ || true)
if [[ -n "${pacer_revived}" ]]; then
  printf '%s\n' "${pacer_revived}" >&2
  fail "a Swift present queue or priming latch is back — that law lives in present_queue.rs"
fi
# The bands are the door's numbers: the crossing's fixed capacity is proved against the depth cap,
# and the schedule's clamps are what keep a nonsense configuration off the screen.
if grep -qE 'min\(240, max\(30|min\(200\.0, max\(0\.0|playoutRecomputeEvery = [0-9]|0\.0005\)' "${SWIFT_PACER}"; then
  fail "a Swift tick, playout or render-cap literal is back — present_queue.rs owns every band"
fi
printf 'check-supervisor: the presentation queue folds by value, waiting frames and all.\n'

# The HEVC parameter sets — `rust/slopdesk-video`'s `hevc_parameter_sets`. The bytes do not cross:
# an access unit is most of a frame and Swift is holding it, so the door answers WHERE the three
# sets sit, exactly as slopdesk_nal_split does one layer down.
SWIFT_HEVC=Sources/SlopDeskVideoClient/HEVCParameterSets.swift
for entry in slopdesk_hevc_types slopdesk_hevc_nal_type slopdesk_hevc_parameter_sets; do
  if ! grep -q "${entry}(" "${SWIFT_HEVC}"; then
    fail "${SWIFT_HEVC} no longer calls ${entry} — the extraction is rust/slopdesk-video's"
  fi
done
# The walk and the numbers a re-implementation would grow back: the six-bit shift, the three types,
# and the split-then-classify loop the door replaced.
if grep -qE '>> 1\) & 0x3F|vpsType: UInt8 = |spsType: UInt8 = |ppsType: UInt8 = |NALUnit\.split' "${SWIFT_HEVC}"; then
  fail "${SWIFT_HEVC} spells the NAL header or the set types again — those live in hevc_parameter_sets.rs"
fi
printf 'check-supervisor: the HEVC parameter sets are spans, not a second walk.\n'

# The SCROLL REPROJECTION law — `rust/slopdesk-video`'s `scroll_reproject`. Seven scalars, so it
# crosses by value: the pane holds the state inside a class it already owns, and every tick folds it
# on the far side. The arithmetic is why — the separate multiply and add that must never fuse, the
# ordered clamps, the ease-out and its rest epsilon — none of which may be spelled twice.
SWIFT_REPROJECT=Sources/SlopDeskVideoProtocol/ScrollReprojector.swift
for entry in slopdesk_scroll_reprojector_defaults slopdesk_scroll_reprojector_new \
  slopdesk_scroll_reprojector_note_velocity slopdesk_scroll_reprojector_advance \
  slopdesk_scroll_reprojector_note_real_frame slopdesk_scroll_reprojector_reset; do
  if ! grep -q "${entry}(" "${SWIFT_REPROJECT}"; then
    fail "${SWIFT_REPROJECT} no longer calls ${entry} — the reprojection law is rust/slopdesk-video's"
  fi
done
# The knobs and the ease-out a re-implementation would grow back. `exp` is in the list because the
# decay is a GEOMETRIC ease-out with a snap, not a call into libm: a Swift `exp` here would be a
# second law that disagrees in the last bits and never snaps to rest.
if grep -qE '0\.125|0\.12|1\.25e-4|func applyDecay|func clampToBand|exp\(' "${SWIFT_REPROJECT}"; then
  fail "${SWIFT_REPROJECT} spells a band, a time constant or the ease-out again — those live in scroll_reproject.rs"
fi
printf 'check-supervisor: the scroll reprojection folds by value, band and ease-out on one side.\n'

# The SCROLL RESAMPLING law — `rust/slopdesk-video`'s `scroll_resample`, the injector's side of the
# same gesture. Six scalars, by value, and the near side stays a struct because that is how the
# injector holds it. What may never come back is the drain arithmetic: the whole-pixel truncation
# that CARRIES its fraction is what makes the integer outputs sum to the float input.
SWIFT_RESAMPLE=Sources/SlopDeskVideoProtocol/ScrollResampler.swift
for entry in slopdesk_scroll_resampler_defaults slopdesk_scroll_resampler_new \
  slopdesk_scroll_resampler_ingest slopdesk_scroll_resampler_drain \
  slopdesk_scroll_resampler_is_idle slopdesk_scroll_resampler_reset; do
  if ! grep -q "${entry}(" "${SWIFT_RESAMPLE}"; then
    fail "${SWIFT_RESAMPLE} no longer calls ${entry} — the resampling law is rust/slopdesk-video's"
  fi
done
# The knobs, the phase codes and the drain a re-implementation would grow back. The phase numbers
# are CoreGraphics', but which of them ends a gesture is this law's, and a second copy of that
# answer is how a Changed lands after an Ended.
if grep -qE 'func drainAxis|func flushResidual|rounded\(\.towardZero\)|scrollChanged|momentumContinue|= 48\.0|= 4096\.0' "${SWIFT_RESAMPLE}"; then
  fail "${SWIFT_RESAMPLE} spells the drain, the flush or a knob again — those live in scroll_resample.rs"
fi
printf 'check-supervisor: the scroll resampling folds by value, residual and fraction on one side.\n'

# The SWIPE-NAV recogniser — `rust/slopdesk-video`'s `swipe_recognizer`. The one law in this file
# that TWO processes run: the host's injector decides the fire, and the client's peel planner
# predicts it over the same events without a round trip. Two implementations would not merely
# duplicate the rule, they would let the overlay promise a navigation the host then declines.
SWIFT_SWIPE=Sources/SlopDeskVideoProtocol/SwipeNavRecognizer.swift
# The ALLOWLIST half is not listed here: it is a question about an operating point, and the one
# thing that holds one is `swipe_nav_config` — see the handle section further down.
for entry in slopdesk_swipe_constants slopdesk_swipe_recognizer_new slopdesk_swipe_recognizer_ingest \
  slopdesk_swipe_live_candidate slopdesk_swipe_slow_required_travel; do
  if ! grep -q "${entry}(" "${SWIFT_SWIPE}"; then
    fail "${SWIFT_SWIPE} no longer calls ${entry} — the swipe law is rust/slopdesk-video's"
  fi
done
# The decision points and the tuned numbers a re-implementation would grow back. The thresholds are
# field-tuned against a 320-lift log; a second copy of them is a second recogniser.
if grep -qE 'func liftDecision|func ingestMomentum|func flushResidual|lastMomentum|Double = 3$|Double = 4$|Double = 2$|= 0\.45|= 0\.70|= 0\.25|com\.apple\.Safari' "${SWIFT_SWIPE}"; then
  fail "${SWIFT_SWIPE} spells a decision, a threshold or the allow-list again — those live in swipe_recognizer.rs"
fi
printf 'check-supervisor: the swipe recogniser is one law, and both processes read it.\n'

# The PEEL planner — `rust/slopdesk-video`'s `swipe_peel`, the recogniser's client-side mirror plus
# what the chip is doing. It folds by value for the same reason the recogniser does: the mirror only
# earns its keep if it reaches the host's verdict over the host's events, and a second copy of the
# quantum or the show threshold is a chip that fills at a different rate than it commits at.
SWIFT_PEEL=Sources/SlopDeskVideoClient/SwipePeelPlanner.swift
for entry in slopdesk_peel_constants slopdesk_peel_new slopdesk_peel_ingest slopdesk_peel_cancel; do
  if ! grep -q "${entry}(" "${SWIFT_PEEL}"; then
    fail "${SWIFT_PEEL} no longer calls ${entry} — the peel law is rust/slopdesk-video's"
  fi
done
if ! grep -q 'slopdesk_peel_history_gated(' Sources/SlopDeskVideoProtocol/SwipeNavStatusCodec.swift; then
  fail "SwipeNavStatusCodec.swift no longer calls slopdesk_peel_history_gated — the history gate is swipe_peel.rs's"
fi
# The chip's own state and its two tuned fractions a re-implementation would grow back. The glass
# progress is named because it RATCHETS across the momentum boundary — a second copy that simply
# tracked the live candidate would let the chip fall back on lift, mid-commit.
if grep -qE 'glassProgress|shownDirection|showTravel|1\.0 / 32\.0|\* 0\.3|rounded\(\.down\)' "${SWIFT_PEEL}"; then
  fail "${SWIFT_PEEL} spells the chip state, the quantum or the show fraction again — those live in swipe_peel.rs"
fi
printf 'check-supervisor: the peel mirror folds by value, chip and ratchet and all.\n'

# The HOST MUX's three deciders — `rust/slopdesk-video`'s `mux_routing` and `mux_flow`. Two handles
# and a question: the router's lane sets and the flow table's stamps are large and read one verdict
# at a time, and the bye policy asks about one payload. What makes the port matter is that all three
# guard the same failure — a datagram from a session that no longer exists reaching one that does.
SWIFT_MUX_ROUTER=Sources/SlopDeskVideoHost/Mux/VideoMuxRouter.swift
for entry in slopdesk_mux_router_new slopdesk_mux_router_free slopdesk_mux_router_admit \
  slopdesk_mux_router_retire slopdesk_mux_router_begin_drain slopdesk_mux_router_end_drain \
  slopdesk_mux_router_is_admitted slopdesk_mux_router_is_draining slopdesk_mux_router_route \
  slopdesk_mux_bootstrap_action; do
  if ! grep -q "${entry}(" "${SWIFT_MUX_ROUTER}"; then
    fail "${SWIFT_MUX_ROUTER} no longer calls ${entry} — the mux routing law is rust/slopdesk-video's"
  fi
done
# The lane sets and the retired-set bound a re-implementation would grow back. The prune is named
# because it is the subtle half: ids are monotonic, so the cap must drop the ids far BELOW the
# wrap-aware high-water mark — a second copy that pruned by insertion order would evict a lane whose
# in-flight datagrams are still arriving, and route a dead generation's bytes into a live session.
if grep -qE 'retiredCap|retiredPruneWindow|distanceWrapped|admitted\.insert|retired\.insert|draining\.insert' "${SWIFT_MUX_ROUTER}"; then
  fail "${SWIFT_MUX_ROUTER} spells the lane sets or the retired bound again — those live in mux_routing.rs"
fi
SWIFT_MUX_FLOWS=Sources/SlopDeskVideoHost/Mux/MuxFlowTable.swift
for entry in slopdesk_mux_flows_new slopdesk_mux_flows_free slopdesk_mux_flows_accept \
  slopdesk_mux_flows_note_inbound slopdesk_mux_flows_stamp_media_reply \
  slopdesk_mux_flows_stamp_media_bootstrap slopdesk_mux_flows_stamp_cursor_reply \
  slopdesk_mux_flows_retire_lane slopdesk_mux_flows_did_reset slopdesk_mux_flows_tracks \
  slopdesk_mux_flows_reap slopdesk_mux_flows_remove_all slopdesk_mux_flows_media_reply \
  slopdesk_mux_flows_cursor_reply slopdesk_mux_flows_count; do
  if ! grep -q "${entry}(" "${SWIFT_MUX_FLOWS}"; then
    fail "${SWIFT_MUX_FLOWS} no longer calls ${entry} — the flow bookkeeping is rust/slopdesk-video's"
  fi
done
# The stamp maps and the two reap rules a re-implementation would grow back. The reference snapshot
# is named because rule 2 must run AFTER rule 1: a stale stamp that swept first stops protecting the
# flow it pointed at, and a copy that took the snapshot early would keep an orphan alive forever.
if grep -qE 'mediaReply\[|cursorReply\[|unadmittedStampAt|flowLastInbound|referenced\.insert|now - lastInbound' "${SWIFT_MUX_FLOWS}"; then
  fail "${SWIFT_MUX_FLOWS} spells the stamp maps or the reap rules again — those live in mux_flow.rs"
fi
SWIFT_MUX_BYE=Sources/SlopDeskVideoHost/Mux/UnboundLaneByePolicy.swift
for entry in slopdesk_mux_warrants_bye slopdesk_mux_bye_limiter_new slopdesk_mux_bye_limiter_free \
  slopdesk_mux_bye_limiter_admit; do
  if ! grep -q "${entry}(" "${SWIFT_MUX_BYE}"; then
    fail "${SWIFT_MUX_BYE} no longer calls ${entry} — the unbound-lane bye policy is rust/slopdesk-video's"
  fi
done
# The message split and the limiter map a re-implementation would grow back. The control decode is
# named because a second reader of that grammar is how a session-LESS discovery request starts
# earning a bye — which would tell a client with no session that its session ended.
if grep -qE 'VideoControlMessage\.decode|case \.keepalive|lastSent\[|listSystemDialogs' "${SWIFT_MUX_BYE}"; then
  fail "${SWIFT_MUX_BYE} decodes control or spells the limiter map again — those live in mux_flow.rs"
fi
printf 'check-supervisor: the host mux routes, stamps and byes from one law, not two.\n'

# The HOST WINDOW FEED — `rust/slopdesk-video`'s `window_feed_host`. Four Swift files against one
# crate module: what to list, how to pack it, who to push it to, and when. The inclusion verdict is
# the one that has to be single, because the PICKER and the FEED both ask it — two copies would show
# a window in one surface and not the other.
SWIFT_FEED_BUILD=Sources/SlopDeskVideoHost/WindowFeed/WindowFeedSnapshotBuilder.swift
for entry in slopdesk_feed_constants slopdesk_feed_includes slopdesk_feed_snapshot; do
  if ! grep -q "${entry}(" "${SWIFT_FEED_BUILD}"; then
    fail "${SWIFT_FEED_BUILD} no longer calls ${entry} — the listing law is rust/slopdesk-video's"
  fi
done
# The exclusion list, the caps and the focus rule a re-implementation would grow back. The AX
# evidence gate is named because it is the whole reason the rail is not full of phantoms: an
# off-screen window is listable only on evidence, and a copy that forgot would drown the feed in tab
# caches and panel services.
if grep -qE 'excludedSystemApps|junkTitlesByOwner|Window Server|focusedAssigned|isAXListed \|\||= 80$|truncatedUTF8' "${SWIFT_FEED_BUILD}"; then
  fail "${SWIFT_FEED_BUILD} spells the exclusions, the evidence gate or a cap again — those live in window_feed_host.rs"
fi
SWIFT_FEED_CACHE=Sources/SlopDeskVideoHost/WindowFeed/WindowFeedCache.swift
for entry in slopdesk_feed_chunks slopdesk_feed_cache_new slopdesk_feed_cache_free \
  slopdesk_feed_cache_generation slopdesk_feed_cache_records slopdesk_feed_cache_needs_rebuild \
  slopdesk_feed_cache_fold slopdesk_feed_cache_reply; do
  if ! grep -q "${entry}(" "${SWIFT_FEED_CACHE}"; then
    fail "${SWIFT_FEED_CACHE} no longer calls ${entry} — the cache and the packer are rust/slopdesk-video's"
  fi
done
# The generation counter and the greedy packer a re-implementation would grow back. The zero-record
# chunk is named because an empty desktop is a real snapshot: a copy that emitted nothing would
# leave the client waiting for a generation that never assembles.
if grep -qE 'generation &\+= 1|currentBytes|feedRecordBytesPerChunk|groups\.append|builtAt' "${SWIFT_FEED_CACHE}"; then
  fail "${SWIFT_FEED_CACHE} spells the generation bump or the packer again — those live in window_feed_host.rs"
fi
SWIFT_FEED_PUSH=Sources/SlopDeskVideoHost/WindowFeed/WindowFeedSubscribers.swift
for entry in slopdesk_feed_subscribers_new slopdesk_feed_subscribers_free \
  slopdesk_feed_subscribers_count slopdesk_feed_subscribers_renew slopdesk_feed_subscribers_reap \
  slopdesk_feed_subscribers_live slopdesk_feed_classify slopdesk_feed_policy_new \
  slopdesk_feed_should_fold slopdesk_feed_tick_interval; do
  if ! grep -q "${entry}(" "${SWIFT_FEED_PUSH}"; then
    fail "${SWIFT_FEED_PUSH} no longer calls ${entry} — the push policy is rust/slopdesk-video's"
  fi
done
# The differ and the cadences a re-implementation would grow back. The structural skeleton is named
# because WHICH bits count as structural is the whole coalescing contract: a copy that called a
# title structural would put a typing window into permanent 4 Hz burst.
if grep -qE 'structuralBits|func skeleton|burstUntil|lastVolatileFold|lastRenewal|= 0\.25|= 3\.0' "${SWIFT_FEED_PUSH}"; then
  fail "${SWIFT_FEED_PUSH} spells the differ, a cadence or the subscriber map again — those live in window_feed_host.rs"
fi
# The record marshalling is spelled ONCE, on the protocol side, and both the client assembler and
# the host cache use it. A fourth hand-rolled row layout is how the arena offsets drift.
SWIFT_FEED_ROWS=Sources/SlopDeskVideoProtocol/HostWindowRecordRows.swift
for entry in 'func row(into arena' 'static func of(_ row' 'static func rows(_ records'; do
  if ! grep -q "${entry}" "${SWIFT_FEED_ROWS}"; then
    fail "${SWIFT_FEED_ROWS} no longer vends ${entry} — the one record marshalling lives there"
  fi
done
if grep -q "private static func row(" Sources/SlopDeskVideoProtocol/WindowFeedAssembler.swift; then
  fail "WindowFeedAssembler.swift grew its own row layout back — it belongs to HostWindowRecordRows.swift"
fi
printf 'check-supervisor: the host window feed lists, packs, pushes and paces from one law.\n'

# The CLIENT mux pool and the two loop policies — `rust/slopdesk-video`'s `mux_client_pool` and
# `mux_flow`. The pool is a handle because the lane sets and the id allocator are its state; the
# registry keeps only the flow OBJECTS, which the crate cannot hold.
SWIFT_POOL=Sources/SlopDeskVideoClient/Mux/VideoConnectionRegistry.swift
for entry in slopdesk_video_pool_new slopdesk_video_pool_free slopdesk_video_pool_shared_flow_count \
  slopdesk_video_pool_lane_count slopdesk_video_pool_acquire slopdesk_video_pool_release; do
  if ! grep -q "${entry}(" "${SWIFT_POOL}"; then
    fail "${SWIFT_POOL} no longer calls ${entry} — the flow pool is rust/slopdesk-video's"
  fi
done
# The refcount, the allocator and the seed band a re-implementation would grow back. The mask is
# named because it is what separates two clients' id RANGES: a copy that counted from one would put
# both clients' first lane on the same id, and the host's reply maps are keyed by the bare id.
if grep -qE 'channelIDs\.insert|nextChannelID|&\+= 1|0x0FFF_FFFF' "${SWIFT_POOL}"; then
  fail "${SWIFT_POOL} spells the refcount or the lane allocator again — those live in mux_client_pool.rs"
fi
# The receive-loop re-arm and the send-path mapping are ONE type each, in the module both ends
# import. They used to be byte-identical twins in the host and client modules, each commented with
# the fact that the other existed — a contract kept by reading rather than by the compiler.
SWIFT_LOOP=Sources/SlopDeskVideoProtocol/UDPFlowPolicy.swift
for entry in slopdesk_mux_should_rearm slopdesk_mux_receive_backoff slopdesk_mux_send_path_viability; do
  if ! grep -q "${entry}(" "${SWIFT_LOOP}"; then
    fail "${SWIFT_LOOP} no longer calls ${entry} — the loop policies are rust/slopdesk-video's"
  fi
done
if grep -qE '0\.005|0\.25|1 << exponent|baseBackoff' "${SWIFT_LOOP}"; then
  fail "${SWIFT_LOOP} spells the backoff rungs again — they live in mux_flow.rs"
fi
for twin in Sources/SlopDeskVideoHost/Mux/UDPReceiveLoopPolicy.swift \
  Sources/SlopDeskVideoClient/Mux/UDPReceiveLoopPolicy.swift \
  Sources/SlopDeskVideoClient/Mux/UDPSendPathPolicy.swift; do
  if [[ -f "${twin}" ]]; then
    fail "${twin} is back — the loop policy is ONE type, in SlopDeskVideoProtocol"
  fi
done
printf 'check-supervisor: the client mux pools its flows and re-arms its loops from one law.\n'

# The BLOB reassembly — `rust/slopdesk-video`'s `blob`. A handle, because the assembly's product IS
# the bytes and they accumulate across many calls; the caps are what keeps an untrusted sender from
# growing the map or the accumulator.
SWIFT_BLOB=Sources/SlopDeskVideoProtocol/BlobAssembler.swift
for entry in slopdesk_blob_kinds slopdesk_blob_max_bytes slopdesk_blob_assembler_new \
  slopdesk_blob_assembler_free slopdesk_blob_assembler_fold slopdesk_blob_assembler_take \
  slopdesk_blob_assembler_reset slopdesk_blob_validates slopdesk_blob_looks_like_png \
  slopdesk_blob_looks_like_jpeg slopdesk_blob_chunk_count slopdesk_blob_encoded_chunk \
  slopdesk_blob_id_of; do
  if ! grep -q "${entry}(" "${SWIFT_BLOB}"; then
    fail "${SWIFT_BLOB} no longer calls ${entry} — the blob law is rust/slopdesk-video's"
  fi
done
# The accumulator, the magic bytes and the hash a re-implementation would grow back. The FNV
# constants are named because an icon's id is a function of its bundle id on BOTH ends of the wire:
# a second hash that drifts would ask the host for a blob it never cached.
if grep -qE '0x89, 0x50|0xFF, 0xD8|0xCBF2_9CE4|0x0000_0100|received\[|insertionOrder' "${SWIFT_BLOB}"; then
  fail "${SWIFT_BLOB} spells the accumulator, the magic or the id hash again — those live in blob.rs"
fi
printf 'check-supervisor: the blob reassembly is a handle, bytes and caps and all.\n'

# The WINDOW-FEED reassembly — `rust/slopdesk-video`'s `window_feed`. The same handle argument as
# the blob one, over records rather than bytes; the records cross in the control decode's own shape,
# so there is exactly one flat record type in this codebase.
SWIFT_FEED=Sources/SlopDeskVideoProtocol/WindowFeedAssembler.swift
for entry in slopdesk_window_feed_bounds slopdesk_window_feed_new slopdesk_window_feed_free \
  slopdesk_window_feed_fold slopdesk_window_feed_take slopdesk_window_feed_reset; do
  if ! grep -q "${entry}(" "${SWIFT_FEED}"; then
    fail "${SWIFT_FEED} no longer calls ${entry} — the feed reassembly is rust/slopdesk-video's"
  fi
done
# The accumulator and the bounds a re-implementation would grow back. The chunk-order concatenation
# is named because arrival order is NOT chunk order — a second loop that forgot that would reorder
# the window list on every lossy renewal.
if grep -qE 'insertionOrder|partials\[|maxPartialGenerations = |maxRecordsPerGeneration = |for index in 0\.\.<chunkCount' "${SWIFT_FEED}"; then
  fail "${SWIFT_FEED} spells the accumulator or its bounds again — those live in window_feed.rs"
fi
printf 'check-supervisor: the window feed reassembles once, in chunk order.\n'

# The KEEPALIVE contract — `rust/slopdesk-video`'s `keepalive`. Five numbers that are ONE argument:
# the stall threshold tolerates two lost host heartbeats, and the reaper tick is what makes the
# worst-case reclaim `idleTimeout + reaperTick`. A Swift copy of any one of them drifts the pair.
SWIFT_KEEPALIVE=Sources/SlopDeskVideoProtocol/KeepaliveTiming.swift
if ! grep -q 'slopdesk_keepalive_timing()' "${SWIFT_KEEPALIVE}"; then
  fail "${SWIFT_KEEPALIVE} no longer calls slopdesk_keepalive_timing — the contract is rust/slopdesk-video's"
fi
if grep -qE 'TimeInterval = (5|30|1|3)\.0' "${SWIFT_KEEPALIVE}" Sources/SlopDeskVideoProtocol/StreamStallPolicy.swift; then
  fail "a keepalive or stall cadence is spelled in Swift again — those live in keepalive.rs"
fi
printf 'check-supervisor: the keepalive cadences and the stall threshold are one record.\n'

# The four smallest SEND-PATH decisions — `rust/slopdesk-video`'s `frame_gate`, `live_bitrate` and
# `capture_recovery`. They are pinned precisely BECAUSE they are small: a rule that is one `guard`
# and a rung ladder that is one ternary are what get re-typed at the call site instead of called,
# and a suppression rule that forgot one obligation freezes a client on a frame it is waiting for.
SWIFT_SUPPRESS=Sources/SlopDeskVideoHost/StaticFrameSuppressionDecider.swift
SWIFT_STILLNESS=Sources/SlopDeskVideoHost/StillnessCrispDecider.swift
SWIFT_BITRATE=Sources/SlopDeskVideoHost/LiveBitratePolicy.swift
SWIFT_RUNG=Sources/SlopDeskVideoHost/CaptureRegionRecovery.swift
for pair in \
  "slopdesk_should_suppress_static_frame:${SWIFT_SUPPRESS}" \
  "slopdesk_stillness_crisp_new:${SWIFT_STILLNESS}" \
  "slopdesk_stillness_crisp_on_frame:${SWIFT_STILLNESS}" \
  "slopdesk_stillness_crisp_should_fire:${SWIFT_STILLNESS}" \
  "slopdesk_stillness_crisp_note_fired:${SWIFT_STILLNESS}" \
  "slopdesk_live_bitrate_defaults:${SWIFT_BITRATE}" \
  "slopdesk_live_bitrate_bits_per_pixel:${SWIFT_BITRATE}" \
  "slopdesk_live_bitrate_target:${SWIFT_BITRATE}" \
  "slopdesk_capture_failure_action:${SWIFT_RUNG}"; do
  entry=${pair%%:*}
  file=${pair#*:}
  if ! grep -q "${entry}(" "${file}"; then
    fail "${file} no longer calls ${entry} — that decision is rust/slopdesk-video's"
  fi
done
# The rule, the count and the numbers a re-implementation would grow back. The density and the
# floor are named because the encoder's QP ceiling is sized against the budget they produce: a
# second copy that rounds differently drops frames on one machine and not the other.
if grep -qE 'guard hashEqualToLast|consecutiveEqual \+= 1|firedThisRest = true|= 0\.25|1_000_000|isFallbackRebuild \?' \
  "${SWIFT_SUPPRESS}" "${SWIFT_STILLNESS}" "${SWIFT_BITRATE}" "${SWIFT_RUNG}"; then
  fail "a send-path decision is spelled in Swift again — those live in frame_gate.rs, live_bitrate.rs and capture_recovery.rs"
fi
printf 'check-supervisor: the four smallest send-path decisions are Rust, not Swift.\n'

# The four bounded ACCUMULATORS — `rust/slopdesk-video`'s `ltr`, `recovery_dedupe`, `idle_reap` and
# `retransmit_ring`. All handles, because each holds across calls what the near side barely reads.
# The LTR gate is the load-bearing one: a second "has anything been acked" that drifts open issues a
# refresh against a reference the client never held — corruption until the next IDR, with no error.
SWIFT_LTR=Sources/SlopDeskVideoHost/LTRController.swift
SWIFT_DEDUPE=Sources/SlopDeskVideoHost/RecoveryRequestDeduper.swift
SWIFT_REAPER=Sources/SlopDeskVideoHost/IdleReapDecider.swift
SWIFT_RING=Sources/SlopDeskVideoHost/RetransmitRing.swift
for pair in \
  "slopdesk_ltr_caps:${SWIFT_LTR}" "slopdesk_ltr_new:${SWIFT_LTR}" "slopdesk_ltr_free:${SWIFT_LTR}" \
  "slopdesk_ltr_record:${SWIFT_LTR}" "slopdesk_ltr_ack:${SWIFT_LTR}" "slopdesk_ltr_reset:${SWIFT_LTR}" \
  "slopdesk_ltr_decision:${SWIFT_LTR}" "slopdesk_ltr_frames:${SWIFT_LTR}" \
  "slopdesk_ltr_acked_tokens:${SWIFT_LTR}" \
  "slopdesk_recovery_dedupe_defaults:${SWIFT_DEDUPE}" "slopdesk_recovery_dedupe_new:${SWIFT_DEDUPE}" \
  "slopdesk_recovery_dedupe_free:${SWIFT_DEDUPE}" "slopdesk_recovery_dedupe_admit:${SWIFT_DEDUPE}" \
  "slopdesk_idle_reaper_new:${SWIFT_REAPER}" "slopdesk_idle_reaper_free:${SWIFT_REAPER}" \
  "slopdesk_idle_reaper_note_inbound:${SWIFT_REAPER}" "slopdesk_idle_reaper_reap:${SWIFT_REAPER}" \
  "slopdesk_idle_reaper_forget:${SWIFT_REAPER}" "slopdesk_idle_reaper_record:${SWIFT_REAPER}" \
  "slopdesk_retransmit_ring_new:${SWIFT_RING}" "slopdesk_retransmit_ring_free:${SWIFT_RING}" \
  "slopdesk_retransmit_ring_record:${SWIFT_RING}" "slopdesk_retransmit_ring_select:${SWIFT_RING}" \
  "slopdesk_retransmit_ring_take:${SWIFT_RING}"; do
  entry=${pair%%:*}
  file=${pair#*:}
  if ! grep -q "${entry}(" "${file}"; then
    fail "${file} no longer calls ${entry} — that accumulator is rust/slopdesk-video's"
  fi
done
# The interiors a re-implementation would grow back. The ring's hand-parsed header offset is named
# because that is exactly how the Swift copy read a fragment index — a byte offset that silently
# mis-selects the moment the wire header moves.
if grep -qE 'frameOrder\.append|acknowledgedTokens\.append|frameTokenCap = |entries\.removeAll|windowSeconds > 0|flows\[|byFrame\[|startIndex \+ 8' \
  "${SWIFT_LTR}" "${SWIFT_DEDUPE}" "${SWIFT_REAPER}" "${SWIFT_RING}"; then
  fail "a host accumulator's interior is spelled in Swift again — those live in ltr.rs, recovery_dedupe.rs, idle_reap.rs and retransmit_ring.rs"
fi
printf 'check-supervisor: the four host accumulators are handles, maps and rings and all.\n'

# The ASPECT GEOMETRY and the virtual-display throttle — `rust/slopdesk-video`'s `geometry` and
# `capture_recovery`. `view_point` is the exact inverse of the input encoder's normalise, so a
# second copy that contracts one multiply-add lands the cursor overlay a pixel off the click it is
# drawn for — on one machine and not the other. It is golden-pinned for exactly that reason.
SWIFT_GEOM=Sources/SlopDeskVideoProtocol/Geometry.swift
SWIFT_VD=Sources/SlopDeskVideoHost/VirtualDisplayRecoveryPolicy.swift
for pair in \
  "slopdesk_geometry_intersection_area:${SWIFT_GEOM}" \
  "slopdesk_geometry_displayed_video_rect:${SWIFT_GEOM}" \
  "slopdesk_geometry_view_point:${SWIFT_GEOM}" \
  "slopdesk_vd_recreate_cooldown:${SWIFT_VD}" \
  "slopdesk_vd_recreate_should_attempt:${SWIFT_VD}" \
  "slopdesk_vd_channels_to_disconnect:${SWIFT_VD}"; do
  entry=${pair%%:*}
  file=${pair#*:}
  if ! grep -q "${entry}(" "${file}"; then
    fail "${file} no longer calls ${entry} — that geometry is rust/slopdesk-video's"
  fi
done
# The arithmetic a re-implementation would grow back. `Double.maximum` is named because it is the
# NaN-ignoring form the crate's `f64::max` requires — a plain `max` here would silently poison the
# multi-monitor pick instead of clamping it.
if grep -qE 'Double\.maximum|Double\.minimum|panLimit|invZoom|intersection\(|TimeInterval = 30' \
  "${SWIFT_GEOM}" "${SWIFT_VD}"; then
  fail "the aspect geometry or the VD throttle is spelled in Swift again — those live in geometry.rs and capture_recovery.rs"
fi
printf 'check-supervisor: the aspect geometry and the VD throttle are Rust, bit-exactly.\n'

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

# ── Three crates may write `unsafe`, and this is not one of them ────────────────────────────────
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
UNSAFE_EXEMPT=(
  rust/slopdesk-posix/Cargo.toml
  rust/slopdesk-ffi/Cargo.toml
  rust/slopdesk-gfsimd/Cargo.toml
)
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
    fail "${allowed} is one of the three crates allowed to write unsafe and does not state unsafe_code = \"deny\" — the per-site #[expect] audit depends on that exact level (docs/51 §6.15, docs/55 §5)"
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
  fail "a crate is not unsafe_code = \"forbid\" — the three exempt crates are named above, and a fourth is a design change (docs/51 §6.15, docs/55 §5)"
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
for decoder in slopdesk_ws_decode_u8 slopdesk_ws_decode_u32 slopdesk_ws_decode_i64 \
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
  local swift_map rust_map
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
  rust/slopdesk-workspace/src/focus.rs 'pub const fn index(self) -> u8'
compare_abi_enum "PaneKind" \
  Sources/SlopDeskWorkspaceModel/WorkspaceSolverBridge.swift 'extension PaneKind' \
  rust/slopdesk-workspace/src/session.rs 'pub const fn as_byte(self) -> u8'
compare_abi_enum "LayoutPreset/TileLayout" \
  Sources/SlopDeskWorkspaceModel/Domain/Tree/WorkspaceTreeOps.swift 'var ffiByte: UInt8' \
  rust/slopdesk-workspace/src/tree_ops.rs 'pub const fn index(self) -> u8'
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

# ── 16. slopdesk-probe: the metadata RPC's git, directory and session half ───────────────────────
# The NINTH contract. Same fork-per-question shape as §14 and §15, with one wrinkle neither of those
# has: two of the five subcommands answer in RAW BYTES, so their "nothing there" cannot be an empty
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

# The FRECENCY ranking and the JUMP it resolves — `rust/slopdesk-workspace`'s `frecency` and `jump`.
# One scorer rather than three sorts, because the folder rail, the open-quickly overlay, the store's
# own cap and `slopdesk jump` all order the same set and a second ordering would rank them apart.
SWIFT_FRECENCY=Sources/SlopDeskWorkspaceCore/Folders/FolderFrecency.swift
SWIFT_JUMP=Sources/SlopDeskCLICore/JumpResolver.swift
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
if ! spells 'pub fn shlex_quoted' rust/slopdesk-workspace/src/shell_quoting.rs > /dev/null; then
  fail "rust/slopdesk-workspace/src/shell_quoting.rs lost shlex_quoted — the paste's bare reading is the same rule"
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
if hit=$(spells 'sudoBasenames|caffeinateBasenames|privilegeBadge|agent == .needsPermission' "${SWIFT_BADGE}"); then
  fail "${hit} walks the badge ladder in Swift — slopdesk-agent::badge resolves it"
fi
if ! spells 'slopdesk_agent_tab_badge' "${SWIFT_BADGE}" > /dev/null; then
  fail "${SWIFT_BADGE} stopped asking the door — it is a face over the ladder, not a second one"
fi
swift_badges=$(sed -n '/^public enum TabBadgeKind/,/^}/p' "${SWIFT_BADGE}" | grep -cE '^    case ') || true
rust_badges=$(grep -oE 'pub const ALL: \[Self; [0-9]+\]' rust/slopdesk-agent/src/badge.rs | grep -oE '[0-9]+') || true
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
SWIFT_PASTE=Sources/SlopDeskWorkspaceCore/Terminal/PasteSafetyAnalyzer.swift
if hit=$(spells 'containsElevationToken|isSeparator|unicodeScalars' "${SWIFT_PASTE}"); then
  fail "${hit} classifies a paste in Swift again — slopdesk-terminal::paste owns the four dangers"
fi
for entry in 'slopdesk_paste_dangers' 'slopdesk_paste_should_warn'; do
  if ! spells "${entry}" "${SWIFT_PASTE}" > /dev/null; then
    fail "${SWIFT_PASTE} no longer asks ${entry} — the guard is one implementation"
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
# The two structs are gone and must stay gone: they were one type spelled twice, and a second one
# would immediately grow a second parse to fill it.
for revived in 'struct AndroidLogLine' 'struct SimulatorLogLine'; do
  if hit=$(spells "${revived}" Sources/SlopDeskDevicePanels/Android/*.swift \
    Sources/SlopDeskDevicePanels/Simulator/*.swift Sources/SlopDeskDevicePanels/Shared/*.swift \
    Sources/SlopDeskClientUI/Android/*.swift Sources/SlopDeskClientUI/Simulator/*.swift \
    Sources/SlopDeskClientUI/DevicePanel/*.swift); then
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
drop_dupes=$(spells '0\.46|0\.72|0\.26' $(repo_files 'Sources/SlopDeskClientUI/Pane/PaneDrop*.swift') 2> /dev/null || true)
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
  fail "a dwell distance grew back in Swift — rust/slopdesk-workspace/src/chrome.rs owns them"
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
  Sources/SlopDeskClientUI/Overlays/KeyboardCheatSheetView.swift; do
  if ! grep -q 'CheatSheetContent' "${half}"; then
    fail "${half} stopped rendering CheatSheetContent — the cheat sheet has two tables"
  fi
  if grep -q 'WorkspaceBindingRegistry' "${half}"; then
    fail "${half} reached past CheatSheetContent to the registry — the glyph gating lives in ONE place"
  fi
done
if grep -q 'KeyboardCheatSheetView' Sources/SlopDeskClientUI/Overlays/OverlayHostView.swift; then
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
  Sources/SlopDeskClientUI/Overlays/ToastStackView.swift; do
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
if grep -q 'ToastStackView(' Sources/SlopDeskClientUI/Overlays/OverlayHostView.swift; then
  fail "the shared overlay host mounts the toast column again — that mount claims every hit over the split"
fi
printf 'check-supervisor: one notification card, drawn twice and spelled once.\n'

# ── The shared overlay host presents modals and nothing else ──────────────────────────────────
# docs/56 stage D's dividend, and the reason it is a gate: an ALWAYS-MOUNTED full-bleed SwiftUI
# layer claims every hit inside its bounds over the AppKit split, and the only way to survive that
# is a hit-testing flag someone has to keep honest. Both ambient tenants are their own windows now —
# the toasts and the ⌃⇥ readout — so the host holds modals alone, and neither may come back. The
# switcher's SwiftUI half was deleted rather than kept: the phone has no modifier stream to open the
# gesture with, so a second half could never render.
# Comment lines are stripped first: the file's header is where the departure is RECORDED, and it has to
# be free to name what left without the gate reading its own history as a regression.
if sed -E 's#^[[:space:]]*//.*##' Sources/SlopDeskClientUI/Overlays/OverlayHostView.swift |
  grep -qE '(PaneSwitcherOverlay|allowsHitTesting)'; then
  fail "the shared overlay host grew an ambient layer again — an always-mounted host eats the split's clicks"
fi
if [[ -e Sources/SlopDeskClientUI/Overlays/PaneSwitcherOverlay.swift ]]; then
  fail "PaneSwitcherOverlay.swift is back — the ⌃⇥ readout is AppKit only (SlopDeskMacUI/Overlays/MacPaneSwitcher.swift)"
fi
for shared in PaneSwitcherRowsBuilder PaneSwitcherMetrics; do
  if ! grep -q "${shared}" Sources/SlopDeskMacUI/Overlays/MacPaneSwitcher.swift; then
    fail "MacPaneSwitcher stopped reading ${shared} — the readout's rows and measurements live below the view"
  fi
done
printf 'check-supervisor: the overlay host presents modals and nothing else.\n'

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
  Sources/SlopDeskClientUI/Overlays/PaletteView.swift; do
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
  Sources/SlopDeskClientUI/Overlays/PeekReplyOverlay.swift; do
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

# ── One global search, two frameworks ─────────────────────────────────────────────────────────
# docs/56 stage D's third MODAL surface. What the two halves must not re-derive is not copy this
# time so much as READING: `GlobalSearchPresentation.excerptSlices` cuts a hit's excerpt around a
# UTF-16 highlight range that can land inside a surrogate pair, and the rule for that case — degrade
# to a flat excerpt, never trap, never guess a run — has to be one rule or the half that re-wrote it
# indexes out of bounds on the first scrollback line containing an emoji.
for half in Sources/SlopDeskMacUI/Overlays/MacGlobalSearch.swift \
  Sources/SlopDeskClientUI/Overlays/GlobalSearchView.swift; do
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
if sed -E 's#^[[:space:]]*//.*##' Sources/SlopDeskClientUI/Pane/TerminalFindBar.swift |
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
  Sources/SlopDeskClientUI/Overlays/OpenQuicklyView.swift; do
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
  Sources/SlopDeskClientUI/Overlays/PaletteView.swift \
  Sources/SlopDeskClientUI/Overlays/OpenQuicklyView.swift; do
  if ! grep -q 'FuzzyMatcher.runs(' "${half}"; then
    fail "${half} stopped reading FuzzyMatcher.runs — a fifth spelling of one fzf mark"
  fi
done
# THE LEDGER IS GONE, which is what stage D was counting to. `draws` let the Mac drop the shared
# host's cards one at a time; with the last one moved it must not come back, and the host's card
# machinery is the phone's alone.
if sed -E 's#^[[:space:]]*//.*##' Sources/SlopDeskClientUI/Overlays/OverlayHostView.swift |
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
  Sources/SlopDeskClientUI/Overlays/OverlayHostView.swift; do
  if ! grep -q 'CloseConfirmationCopy' "${half}"; then
    fail "${half} stopped reading CloseConfirmationCopy — two dialogs, and the drift would be silent"
  fi
  if sed -E 's#^[[:space:]]*//.*##' "${half}" |
    grep -qE '"A process is still running|"This window has multiple tabs|Closing it will close the project'; then
    fail "${half} respells the close-confirmation copy — every line of it is CloseConfirmationCopy's"
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
if [[ -e Sources/SlopDeskClientUI/Chrome/SlateTabRow.swift ]]; then
  fail "SlateTabRow.swift is back — the navigator row is MacSidebarRowView (AppKit) or IOSSidebarLiveRow (phone)"
fi
if grep -rqE '(struct|final class) SlateTabRow\b' Sources/ 2> /dev/null; then
  fail "SlateTabRow is back under another path — one row per platform, both reading SidebarRowReading"
fi
# The SwiftUI navigator is the PHONE's now. Without the platform gate the Mac would build two.
if ! grep -q '#if os(iOS)' Sources/SlopDeskClientUI/Columns/NavigatorColumn.swift; then
  fail "NavigatorColumn stopped being iOS-only — the Mac's navigator is MacNavigatorColumn"
fi
for spelling in SidebarRowPresentation SidebarRowMenu; do
  if ! grep -q "${spelling}" Sources/SlopDeskClientUI/Columns/NavigatorColumn.swift; then
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
for half in Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift \
  Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift \
  Sources/SlopDeskClientUI/Columns/NavigatorColumn.swift; do
  # Comments stripped first — the headers NAME the sigils they no longer spell.
  if sed -E 's#^[[:space:]]*//.*##;s#^[[:space:]]*///.*##' "${half}" |
    grep -qE '"↑\\\(|"↓\\\(|"\+\\\(|"!\\\(|"\?\\\(|"~\\\(|"\$\\\('; then
    fail "${half} spells a git sigil — every one of them is SidebarGitLine.segments's"
  fi
done
# The ATTENTION ROLES are ranked once (`TabBadgeReading.rollup`), because a collapsed group's count
# has to pick a loudest hidden state and both halves must pick the same one.
if ! grep -rq 'TabBadgeReading' Sources/SlopDeskClientUI/App/StatusPresentation.swift; then
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
for gone in Sources/SlopDeskClientUI/Chrome/SlateTitlebar.swift \
  Sources/SlopDeskClientUI/Chrome/WorkspaceTabStrip.swift; do
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
  Sources/SlopDeskClientUI/Chrome/ConnectionPill.swift; do
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
for gone in Sources/SlopDeskClientUI/Chrome/PanelRail.swift \
  Sources/SlopDeskClientUI/DesignSystem/AndroidRobotMark.swift; do
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
  Sources/SlopDeskClientUI/Panel/PhonePanelSheet.swift; do
  if ! grep -q 'PanelTabs' "${half}"; then
    fail "${half} stopped reading PanelTabs — the panel's four tabs are ClientCore's, cut once"
  fi
done
# THE PHONE'S PANEL IS A LAYOUT, NOT A SECOND PANEL. Its bar is its own (a cover has no split item to
# hide, so it closes instead), but everything under the bar is the Mac's: the same four surfaces, the
# same shared `codeSidebarCollapsed` flag driving the presentation — which is what makes
# `revealCodeSidebar()` reach the phone at all — and the same drawn robot.
for reading in "Sources/SlopDeskClientUI/Panel/PhonePanelSheet.swift:CodePanelSurfaces(" \
  "Sources/SlopDeskClientUI/Panel/PhonePanelSheet.swift:AndroidMarkPath" \
  "Sources/SlopDeskClientUI/WorkspaceRootView.swift:codeSidebarCollapsed"; do
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
for surface in Sources/SlopDeskClientUI/Simulator/*.swift Sources/SlopDeskClientUI/Android/*.swift; do
  if grep -q '^#if os(macOS)' "${surface}" && ! grep -q '^#elseif os(iOS)' "${surface}"; then
    fail "${surface} is macOS-only again — both device panels draw on the phone too"
  fi
done
for stage in Sources/SlopDeskClientUI/Simulator/SimulatorScreenView.swift \
  Sources/SlopDeskClientUI/Android/AndroidScreenView.swift; do
  if ! grep -q 'UIViewRepresentable' "${stage}"; then
    fail "${stage} lost its UIKit half — the phone's device stage is a UIViewRepresentable"
  fi
done
# ONE VOCABULARY, TWO NUMBERINGS. A Mac reports a virtual key code and an iPad a USB HID usage; the
# NAMES they resolve to, and every rule about what to do with them, are cut once in the shared floor.
# A UI half that grew its own name table would be the same product implemented twice.
for domain in byHIDUsage hidFunctionalKeys; do
  if ! grep -rq "${domain}" Sources/SlopDeskDevicePanels/; then
    fail "the ${domain} table is gone — an iPad keyboard numbers its keys as HID usages"
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
# Three files now, and the split is the rule: the DECISIONS in `CodeSidebarFocusPolicy` (pure, and
# the only place a focus rule may be written), the POOL in `CodeSidebarWebViewPool` (projects and
# their warm pages — one law, with the Mac's keyboard machine walled off at the bottom), and the
# MOUNT in `CodeSidebarWebView` (a clipping container and a representable per platform).
for piece in \
  "Sources/SlopDeskClientUI/CodeSidebar/CodeSidebarWebView.swift:UIViewRepresentable" \
  "Sources/SlopDeskClientUI/CodeSidebar/CodeSidebarWebView.swift:NSViewRepresentable" \
  "Sources/SlopDeskClientUI/CodeSidebar/CodeSidebarWebViewPool.swift:func noteRemount"; do
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
  [[ "${file}" =~ CodeSidebar/CodeSidebarWebView(Pool)?\.swift$ ]] && continue
  if sed -E 's#^[[:space:]]*//.*##' "${file}" | grep -q 'CodeSidebarWKWebView'; then
    fail "${file} names CodeSidebarWKWebView — it is the Mac's responder seam, not an API"
  fi
done < <(grep -rl 'CodeSidebarWKWebView' Sources/ || true)
# The four code-panel files below carry NO WHOLE-FILE gate. `CodeSidebarProxy` and
# `CodeSidebarFontSchemeHandler` were gated for no reason at all — Network is Network and WebKit is
# WebKit — and `CodePanelSurfaces` was gated because of what it mounted, which has since crossed.
# A gate INSIDE one of them is fine and the pool has two (the AppKit/UIKit import, the keyboard
# machine); what is banned is the wrapper that makes the file compile to nothing on the phone, and
# that shape is exactly "the first line of code is `#if os(macOS)`".
for crossed in Sources/SlopDeskClientUI/CodeSidebar/CodePanelSurfaces.swift \
  Sources/SlopDeskClientUI/CodeSidebar/CodeSidebarWebViewPool.swift \
  Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarProxy.swift \
  Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarFontSchemeHandler.swift; do
  first=$(grep -vE '^[[:space:]]*(//.*)?$' "${crossed}" | head -n 1 || true)
  if [[ "${first}" == '#if os(macOS)' ]]; then
    fail "${crossed} is wrapped in a macOS gate again — the code panel is the phone's too"
  fi
done
# A focus RULE lives in the policy, which is pure and testable; the seam only calls it. The three
# spellings below are the ones that were inline before the split and would be inline again first.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
focus_rules=$(spells 'func shouldAcceptFocus|func isReservedAppChord|func evictionVictim' \
  $(repo_files 'Sources/SlopDeskClientUI/**/*.swift' | grep -v 'CodeSidebarFocusPolicy.swift') \
  2> /dev/null || true)
if [[ -n "${focus_rules}" ]]; then
  printf '%s\n' "${focus_rules}" >&2
  fail "a code-panel focus rule grew back outside CodeSidebarFocusPolicy — it is pure on purpose"
fi
printf 'check-supervisor: the code panel crosses; only its keyboard stayed behind.\n'

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
host_swift=Sources/SlopDeskClientUI/Pane/TerminalInputHost.swift
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
for door in slopdesk_settings_option_count slopdesk_settings_option_token slopdesk_settings_option_label \
  slopdesk_settings_option_caption slopdesk_settings_option_menu_label slopdesk_settings_density_token \
  slopdesk_settings_section_count slopdesk_settings_section_id slopdesk_settings_section_title \
  slopdesk_settings_section_symbol slopdesk_settings_section_is_mac_only slopdesk_settings_timing_label \
  slopdesk_settings_timing_symbol slopdesk_settings_ladder slopdesk_settings_ladder_preset_count \
  slopdesk_settings_ladder_preset_value slopdesk_settings_ladder_preset_label slopdesk_settings_ladder_readout; do
  if ! grep -qF "${door}" "${catalog_swift}"; then
    fail "${catalog_swift} stopped calling ${door} — an answer it holds itself is a table written twice"
  fi
  if ! grep -qF "${door}" rust/slopdesk-ffi/include/slopdesk_ffi.h; then
    fail "${door} is missing from slopdesk_ffi.h — Swift cannot reach a door the header does not name"
  fi
done
# And no settings VIEW may spell a choice's own words. A label typed into a card is the second table:
# it renders, it looks right, and it is unreachable from the pin that would have caught it.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
settings_words=$(spells 'SettingsOption\(\.|"Applies (now|on reconnect)"|"(Copy or paste|Left only|Right only)"' \
  $(repo_files 'Sources/SlopDeskClientUI/Settings/*.swift') $(repo_files 'Sources/SlopDeskMacUI/**/*.swift') \
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
for door in slopdesk_settings_row_count slopdesk_settings_row_key slopdesk_settings_row_label \
  slopdesk_settings_row_description slopdesk_settings_row_default_text slopdesk_settings_row_keywords \
  slopdesk_settings_row_target_section slopdesk_settings_row_bucket slopdesk_settings_row_is_inline_editable \
  slopdesk_settings_row_index slopdesk_settings_row_matches; do
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
row_labels=$(sed -n 's/^        label: "\(.*\)",$/\1/p' rust/slopdesk-workspace/src/settings_rows.rs)
if [[ -z "${row_labels}" ]]; then
  fail "no row labels parsed out of settings_rows.rs — the ratchet below would pass by reading nothing"
fi
# Comments are STRIPPED first, exactly as `spells()` does it: the note above `settingLabel` cites the
# two spellings that drifted, and a gate that cannot quote the bug it prevents is a gate nobody may
# document.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
settings_view_code=$(awk '{ line = $0; sub(/\/\/.*/, "", line); printf "%s:%d:%s\n", FILENAME, FNR, line }' \
  $(repo_files 'Sources/SlopDeskClientUI/Settings/*.swift') \
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

# ── A platform gate on a settings page is DATA ────────────────────────────────────────────────
# Which groups a page shows, in what order, and which platform each belongs to is
# `slopdesk_workspace::settings_layout`. `SettingsLayout.swift` is the near side.
layout_swift=Sources/SlopDeskClientCore/Settings/SettingsLayout.swift
if [[ ! -e "${layout_swift}" ]]; then
  fail "${layout_swift} is gone — a settings page would have to spell its own shape again (docs/56)"
fi
for door in slopdesk_settings_layout_group_count slopdesk_settings_layout_group_title \
  slopdesk_settings_layout_group_timing slopdesk_settings_layout_row_count \
  slopdesk_settings_layout_row_key slopdesk_settings_layout_row_subtitle \
  slopdesk_settings_layout_row_glyph slopdesk_settings_layout_row_bespoke_id \
  slopdesk_settings_layout_row_control slopdesk_settings_layout_row_control_argument; do
  if ! grep -qF "${door}" "${layout_swift}"; then
    fail "${layout_swift} stopped calling ${door} — a page shape it holds itself is a table written twice"
  fi
  if ! grep -qF "${door}" rust/slopdesk-ffi/include/slopdesk_ffi.h; then
    fail "${door} is missing from slopdesk_ffi.h — Swift cannot reach a door the header does not name"
  fi
done
# The point of the table is that a gate became a VALUE, so the gate must not grow back. Exactly one
# `#if os(` may remain across the settings pages per page that has not been ported yet, and the ONE
# in `SettingsControls.swift` — `SettingsLayout.Half.current` — is the shared target's single
# admission that it still renders both halves. It dies when `SlopDeskMacUI` takes Settings.
# Counted from the comment-stripped source: the note above the helper explains what it replaced by
# quoting `#if os(macOS)`, and a gate nobody may document is a gate nobody will understand.
half_gate=$(grep -c '^Sources/SlopDeskClientUI/Settings/SettingsControls.swift:[0-9]*:.*#if os(' \
  <<< "${settings_view_code}" || true)
if [[ "${half_gate}" -ne 1 ]]; then
  fail "SettingsControls.swift carries ${half_gate} platform gates — Half.current is meant to be the only one"
fi
if ! grep -q 'static var current' Sources/SlopDeskClientUI/Settings/SettingsControls.swift; then
  fail "SettingsLayout.Half.current is gone — a settings page has no way to say which half it is"
fi
# A ported page renders from the table, so it may not name a group header it draws.
layout_titles=$(sed -n 's/^        title: "\(.*\)",$/\1/p' rust/slopdesk-workspace/src/settings_layout.rs)
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

# ── One device-panel law, two device protocols ────────────────────────────────────────────────
# The simulator panel and the Android panel differ in almost everything and should — one rotates on
# the client and the other on the device, one sends touches in the fitted rect's space and the other
# in the video's own pixel grid, because `scrcpy` DROPS a mismatched pair. What they never differed
# in is the arithmetic: the aspect fit, the click mapping, the pinch pair, the safe-area margin and
# the regrip. That lives in `DevicePanelGeometry`, and the CoreMedia wrap in
# `DevicePanelSampleBuffer`; only `formatDescription` is genuinely per-panel (avcC record vs Annex-B).
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
panel_dupes=$(spells 'bounds.width / contentSize.width|CMBlockBufferCreateWithMemoryBlock|2\.0\.squareRoot' \
  $(repo_files 'Sources/SlopDeskClientUI/**/*.swift' 'Sources/SlopDeskDevicePanels/**/*.swift' |
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
# The same holds for what the panels DRAW. The empty stage, its caption, the empty-list notice and
# the loading-veil asymmetry are one design decision each, recorded in the singular in
# docs/DECISIONS.md and written down twice. The measured veil DELAYS stay per panel (400 ms vs
# 600 ms, two pieces of hardware). The console LEXER used to be pinned here too; both grammars are
# `slopdesk-devicelog` now, and the section above this one is what holds them there.
# The panels' own files must READ the shared laws rather than restate them. A positive check,
# because the veil and the notice are ordinary SwiftUI whose ingredients are used everywhere else.
declare -a panel_shares=(
  "Sources/SlopDeskClientUI/Android/AndroidStageView.swift:DevicePanelChrome.veil"
  "Sources/SlopDeskClientUI/Simulator/SimulatorStageView.swift:DevicePanelChrome.veil"
  "Sources/SlopDeskClientUI/Android/AndroidDeviceList.swift:DevicePanelChrome.notice"
  "Sources/SlopDeskClientUI/Simulator/SimulatorDeviceList.swift:DevicePanelChrome.notice"
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
# see ClientUI. Same call, different law.
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
opens=$(spells 'NSWorkspace.shared.open\(url\)|UIApplication.shared.open\(url\)' \
  $(repo_files 'Sources/SlopDeskClientUI/**/*.swift' | grep -v 'ExternalOpen.swift') 2> /dev/null || true)
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
  $(repo_files 'Sources/SlopDeskClientUI/**/*.swift' 'Sources/SlopDeskDevicePanels/**/*.swift' \
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
ui_targets=(SlopDeskClientUI SlopDeskMacUI SlopDeskPhoneUI)
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

# A PLATFORM GATE IN A PLATFORM TARGET means the file is in the wrong target. `SlopDeskMacUI` is the
# Mac's and nothing else builds it, so every `#if os(...)` in it is dead text that reads as a live
# rule. The ONE allowed gate is `SlopDeskPhoneUI`'s whole-file `#if os(iOS)`, which is how an
# iOS-only view declares itself to `swift build` (SwiftPM compiles every target on the host triple).
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
mac_gates=$(spells '#if os\(' \
  $(repo_files 'Sources/SlopDeskMacUI/*.swift' 'Sources/SlopDeskMacUI/**/*.swift') 2> /dev/null || true)
if [[ -n "${mac_gates}" ]]; then
  printf '%s\n' "${mac_gates}" >&2
  fail "a platform gate in the macOS UI target — the file is in the wrong target (docs/56 §3)"
fi
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
phone_gates=$(spells '#if (os\((macOS|watchOS|tvOS)\)|canImport\(AppKit\))' \
  $(repo_files 'Sources/SlopDeskPhoneUI/*.swift' 'Sources/SlopDeskPhoneUI/**/*.swift') 2> /dev/null || true)
if [[ -n "${phone_gates}" ]]; then
  printf '%s\n' "${phone_gates}" >&2
  fail "the phone UI target gates on a platform it never builds for (docs/56 §3)"
fi

# NEITHER HALF IMPORTS THE OTHER, and the draining floor never imports upward. `Package.swift`
# already makes the first two a link error; this catches the edit that would ADD the dependency
# there, which is the moment a shared view ancestor becomes possible.
declare -a ui_edges=(
  "Sources/SlopDeskMacUI:import SlopDeskPhoneUI"
  "Sources/SlopDeskPhoneUI:import SlopDeskMacUI"
  "Sources/SlopDeskClientUI:import SlopDeskMacUI"
  "Sources/SlopDeskClientUI:import SlopDeskPhoneUI"
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
    Sources/SlopDeskClientUI/WorkspaceRootView.swift; do
    if ! grep -qF "overlay.${hook} =" "${root}"; then
      fail "${root} stopped binding overlay.${hook} — an unbound hook is a palette row that lies"
    fi
  done
done
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
  $(repo_files 'Sources/SlopDeskClientUI/**/*.swift' 'Sources/SlopDeskWorkspaceCore/**/*.swift') \
  2> /dev/null || true)"
declare -a latch_shares=(
  "Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift:reflowDeadline.arm"
  "Sources/SlopDeskWorkspaceCore/Video/RemoteWindowModel.swift:reflowDeadline.arm"
  "Sources/SlopDeskDevicePanels/Android/AndroidSidebarModel.swift:noticeClear.arm"
  "Sources/SlopDeskDevicePanels/Simulator/SimulatorSidebarModel.swift:noticeClear.arm"
  "Sources/SlopDeskDevicePanels/Android/AndroidSidebarModel.swift:reattempt.arm"
  "Sources/SlopDeskClientUI/Pane/PaneDragCoordinator.swift:springLoadTask.arm"
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
# shellcheck disable=SC2046 # `$(repo_files …)` expands to a FILE LIST on purpose
while IFS= read -r file; do
  [[ -f "${file}" ]] || continue
  grep -q '\.sortedKeys' "${file}" || {
    printf '%s\n' "${file}" >&2
    fail "a sidecar encoder set outputFormatting without .sortedKeys — docs/22 §8 compares bytes"
  }
done <<< "$(grep -lF 'outputFormatting' $(repo_files 'Sources/**/*.swift') 2> /dev/null || true)"
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
# already attributed a scripts edit to `SlopDeskClientUITests` — those tests open `scripts/*.sh` off
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

printf 'check-supervisor: one deadline latch, one clipboard clip, one sidecar encoder, one channel tag, no dangling doc link, no doc citing a file that is gone, no gate that dies quietly, one meaning for the green-tree marker.\n'

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

printf 'check-supervisor: Swift and Rust agree — paths, protocol %s.%s, listeners (%s), frame tags, %s-byte cap, %s read chunk.\n' \
  "${swift_major}" "${swift_minor}" "$(echo "${swift_kinds}" | tr '\n' ' ' | sed 's/ $//')" "${super_cap}" "${swift_chunk}"
printf 'check-supervisor: screend agrees too — socket name, %s verbs, banner "%s", no Swift engine, ladder, manifest, boundary split or journal.\n' \
  "$(printf '%s\n' "${swift_screen_verbs}" | grep -c .)" "${swift_banner}"
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

printf 'check-supervisor: slopdesk-probe agrees too — %s subcommands both ways, empty is still an answer, no Swift porcelain, git or infocmp.\n' \
  "$(printf '%s\n' "${swift_probe_verbs}" | grep -c .)"

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

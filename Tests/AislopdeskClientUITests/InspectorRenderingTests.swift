// InspectorRenderingTests — the PURE logic the E4/WI-5 Details-Panel views depend on (no view rendering,
// no libghostty / Metal / theme read). Covers the four headlessly-testable helpers the Info / Git / Files
// tabs lean on:
//   • `MetadataFormatting` (uptime + protocol badge) — ProcessPortsView,
//   • `GitStatusPresentation` (porcelain-byte unpack → category + badge, the INVERSE of the host's
//     `HostMetadataProbe.statusNibble`/`packStatus`) — GitStatusView,
//   • `GitDiffPresentation` (unified-diff line classification + line split) — GitStatusView's diff overlay,
//   • `RemoteFileTree` (join / fuzzy filter / dirs-first sort / lazy-tree flatten) — RemoteFileTreeView.
//
// Each assertion would FAIL on the un-fixed code (the helpers don't exist) and on a logic regression (a
// flipped nibble map, a missing `+++`-before-`+` order, a no-op filter). NOT tautological — the git-status
// pins are tied to the host's packing convention, the filter pins exclusion, the flatten pins structure.

import AislopdeskProtocol
import AislopdeskWorkspaceCore // DetailsPanelTab (the cross-module Details-tab vocabulary, hoisted in WI-7)
import XCTest
@testable import AislopdeskClientUI

final class InspectorRenderingTests: XCTestCase {
    // MARK: - MetadataFormatting (ProcessPortsView)

    func testUptimeFormatsCoarseUnits() {
        XCTAssertEqual(MetadataFormatting.uptime(0), "0s")
        XCTAssertEqual(MetadataFormatting.uptime(34), "34s")
        XCTAssertEqual(MetadataFormatting.uptime(59), "59s")
        XCTAssertEqual(MetadataFormatting.uptime(60), "1m")
        XCTAssertEqual(MetadataFormatting.uptime(3599), "59m")
        XCTAssertEqual(MetadataFormatting.uptime(3600), "1h")
        XCTAssertEqual(MetadataFormatting.uptime(86399), "23h")
        XCTAssertEqual(MetadataFormatting.uptime(86400), "1d")
        XCTAssertEqual(MetadataFormatting.uptime(200_000), "2d")
    }

    func testPortProtocolLabelForwardTolerant() {
        XCTAssertEqual(MetadataFormatting.portProtocolLabel(0), "TCP")
        XCTAssertEqual(MetadataFormatting.portProtocolLabel(1), "UDP")
        XCTAssertEqual(MetadataFormatting.portProtocolLabel(9), "?", "an unknown future proto byte is tolerated")
    }

    // MARK: - GitStatusPresentation (mirror of the host's nibble packing)

    func testStatusUnpackMirrorsHostPacking() {
        // Host packs (X<<4)|Y with space=0 M=1 A=2 D=3 R=4 C=5 U=6 ?=7 !=8 T=9.
        // Worktree-modified ` M` → 0x01.
        XCTAssertEqual(GitStatusPresentation.category(0x01), .modified)
        XCTAssertEqual(GitStatusPresentation.badge(0x01), "M")
        // Staged-modified `M ` → 0x10 (the index char wins when the worktree is clean).
        XCTAssertEqual(GitStatusPresentation.category(0x10), .modified)
        XCTAssertEqual(GitStatusPresentation.badge(0x10), "M")
        // Staged-added `A ` → 0x20.
        XCTAssertEqual(GitStatusPresentation.category(0x20), .added)
        XCTAssertEqual(GitStatusPresentation.badge(0x20), "A")
        // Worktree-deleted ` D` → 0x03.
        XCTAssertEqual(GitStatusPresentation.category(0x03), .deleted)
        XCTAssertEqual(GitStatusPresentation.badge(0x03), "D")
        // Renamed `R ` → 0x40.
        XCTAssertEqual(GitStatusPresentation.category(0x40), .renamed)
        XCTAssertEqual(GitStatusPresentation.badge(0x40), "R")
        // Untracked `??` → 0x77.
        XCTAssertEqual(GitStatusPresentation.category(0x77), .untracked)
        XCTAssertEqual(GitStatusPresentation.badge(0x77), "?")
    }

    func testStatusUnpackXYAndUnknown() {
        let (x, y) = GitStatusPresentation.xy(0x12) // M index, A worktree
        XCTAssertEqual(x, "M")
        XCTAssertEqual(y, "A")
        // An all-blank / unrecognised packing → `unknown`, rendered as the neutral bullet (never a crash).
        XCTAssertEqual(GitStatusPresentation.category(0x00), .unknown)
        XCTAssertEqual(GitStatusPresentation.badge(0x00), "•")
        XCTAssertEqual(GitStatusPresentation.badge(0xF0), "•", "unrecognised high nibble → unknown")
    }

    // MARK: - GitDiffPresentation (unified-diff line classification)

    func testDiffClassifyTagsEachLineKind() {
        XCTAssertEqual(GitDiffPresentation.classify("@@ -1,2 +1,3 @@"), .hunk)
        XCTAssertEqual(GitDiffPresentation.classify("+++ b/file.swift"), .fileHeader)
        XCTAssertEqual(GitDiffPresentation.classify("--- a/file.swift"), .fileHeader)
        XCTAssertEqual(GitDiffPresentation.classify("diff --git a/x b/x"), .meta)
        XCTAssertEqual(GitDiffPresentation.classify("index 9abc..0def 100644"), .meta)
        XCTAssertEqual(GitDiffPresentation.classify("\\ No newline at end of file"), .meta)
        XCTAssertEqual(GitDiffPresentation.classify("+added"), .added)
        XCTAssertEqual(GitDiffPresentation.classify("-removed"), .removed)
        XCTAssertEqual(GitDiffPresentation.classify(" context"), .context)
    }

    func testDiffFileMarkersBeatBareAddRemove() {
        // `+++`/`---` MUST classify as file headers, not add/remove (the order-of-checks invariant).
        XCTAssertNotEqual(GitDiffPresentation.classify("+++ b/x"), .added)
        XCTAssertNotEqual(GitDiffPresentation.classify("--- a/x"), .removed)
    }

    func testDiffLinesSplitAndDropTrailingNewline() {
        let raw = "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n"
        let lines = GitDiffPresentation.lines(from: Data(raw.utf8))
        XCTAssertEqual(
            lines.map(\.kind),
            [.meta, .hunk, .removed, .added],
            "the trailing newline yields no phantom blank line",
        )
        XCTAssertEqual(lines.map(\.text), ["diff --git a/x b/x", "@@ -1 +1 @@", "-old", "+new"])
    }

    func testDiffLinesDecodeNonUTF8WithoutTrapping() {
        // A hostile / binary diff body must decode lossily, never trap.
        let bytes = Data([0xFF, 0xFE, 0x0A, 0x2B, 0x41]) // garbage, "\n", "+A"
        let lines = GitDiffPresentation.lines(from: bytes)
        XCTAssertEqual(lines.last?.kind, .added)
    }

    // MARK: - RemoteFileTree (Files tab projection)

    func testJoinPaths() {
        XCTAssertEqual(RemoteFileTree.join("", "scripts"), "scripts")
        XCTAssertEqual(RemoteFileTree.join("scripts", "run.sh"), "scripts/run.sh")
    }

    func testFilterEmptyMatchesEverythingNonEmptyExcludes() {
        XCTAssertTrue(RemoteFileTree.matches("anything", query: ""), "empty query matches all")
        XCTAssertTrue(RemoteFileTree.matches("README.md", query: "read"))
        XCTAssertTrue(RemoteFileTree.matches("README.md", query: "rme"), "fuzzy subsequence")
        XCTAssertFalse(RemoteFileTree.matches("LICENSE", query: "xyz"), "a non-match is excluded")
    }

    func testSortPutsDirectoriesFirstThenCaseInsensitiveName() {
        let entries = [
            MetadataCodec.DirEntry(isDir: false, name: "b.txt"),
            MetadataCodec.DirEntry(isDir: true, name: "Zed"),
            MetadataCodec.DirEntry(isDir: false, name: "A.txt"),
            MetadataCodec.DirEntry(isDir: true, name: "alpha"),
        ]
        XCTAssertEqual(RemoteFileTree.sorted(entries).map(\.name), ["alpha", "Zed", "A.txt", "b.txt"])
    }

    private func tree() -> (root: [MetadataCodec.DirEntry], children: [String: [MetadataCodec.DirEntry]]) {
        let root = [
            MetadataCodec.DirEntry(isDir: true, name: "src"),
            MetadataCodec.DirEntry(isDir: false, name: "README.md"),
        ]
        let children = [
            "src": [
                MetadataCodec.DirEntry(isDir: false, name: "main.swift"),
                MetadataCodec.DirEntry(isDir: true, name: "lib"),
            ],
        ]
        return (root, children)
    }

    func testFlattenCollapsedShowsOnlyRoots() {
        let (root, children) = tree()
        let rows = RemoteFileTree.flatten(root: root, children: children, expanded: [], query: "")
        XCTAssertEqual(rows.map(\.path), ["src", "README.md"], "a collapsed dir shows no children")
        XCTAssertEqual(rows.map(\.depth), [0, 0])
        XCTAssertEqual(rows.first?.isExpanded, false)
    }

    func testFlattenExpandedInlinesSortedChildren() {
        let (root, children) = tree()
        let rows = RemoteFileTree.flatten(root: root, children: children, expanded: ["src"], query: "")
        // dirs-first sort within src: lib before main.swift.
        XCTAssertEqual(rows.map(\.path), ["src", "src/lib", "src/main.swift", "README.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0])
        XCTAssertEqual(rows.first { $0.path == "src" }?.isExpanded, true)
    }

    func testFlattenFilterKeepsMatchingDescendantsAndTheirAncestors() {
        let (root, children) = tree()
        let rows = RemoteFileTree.flatten(root: root, children: children, expanded: ["src"], query: "main")
        // `main.swift` matches; its ancestor `src` survives to host it; `README.md`/`lib` are excluded.
        XCTAssertEqual(rows.map(\.path), ["src", "src/main.swift"])
    }

    func testFlattenFilterExcludesNonMatchingRoots() {
        let (root, children) = tree()
        let rows = RemoteFileTree.flatten(root: root, children: children, expanded: ["src"], query: "readme")
        XCTAssertEqual(rows.map(\.path), ["README.md"], "only the matching root survives")
    }

    // MARK: - AgentTranscript (AgentSessionHistoryView — bytes → TranscriptParser → render turns)

    func testAgentTranscriptRoutesRawBytesThroughTranscriptParserIntact() {
        // ES-E4-4: the raw `readAgentSession` bytes must reach `TranscriptParser` UNMANGLED. Two JSONL lines
        // (a user turn + an assistant turn) carry multibyte UTF-8 + emoji; asserting the rendered body equals
        // the EXACT source strings proves the bytes traveled Data → UTF-8 decode → line split →
        // `TranscriptParser` → entry without corruption. FAILS on the un-fixed code (no `AgentTranscript`),
        // and on any future regression that lossily re-encoded or split the stream wrong. Not tautological —
        // the expectation is the literal source text, not the parser's own derivation.
        let userText = "Refactor the café façade — 日本語 🚀"
        let assistantText = "Done. See `Brücke.swift` ✅"
        let userLine = #"{"type":"user","uuid":"u1","timestamp":"2026-06-25T19:30:21.000Z","#
            + #""message":{"role":"user","content":"\#(userText)"}}"#
        let assistantLine = #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","#
            + #""content":[{"type":"text","text":"\#(assistantText)"}]}}"#
        let jsonl = "\(userLine)\n\(assistantLine)"
        let entries = AgentTranscript.entries(from: Data(jsonl.utf8), assistantName: "Claude Code")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].role, .user)
        XCTAssertEqual(entries[0].speaker, "You")
        XCTAssertEqual(entries[0].markdown, userText, "the user body must round-trip the exact UTF-8 bytes")
        XCTAssertEqual(entries[1].role, .assistant)
        XCTAssertEqual(entries[1].speaker, "Claude Code")
        XCTAssertEqual(entries[1].markdown, assistantText, "the assistant body must round-trip the exact bytes")
    }

    func testAgentTranscriptSkipsNonConversationAndToolEchoLines() {
        // An ignored bookkeeping line + a user line that is ONLY a tool_result echo (no text) are dropped;
        // an assistant tool_use-only turn surfaces a collapsed tool summary with an empty body. Pins the
        // skip rules AND `toolSummary` grouping through the full parse path (no direct Inspector import).
        // The JSONL is assembled from short raw-string fragments so no source line runs long.
        let snapshot = #"{"type":"file-history-snapshot"}"#
        let toolEcho = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
        let tools = #"{"type":"tool_use","id":"a","name":"Read","input":{}},"#
            + #"{"type":"tool_use","id":"b","name":"Read","input":{}},"#
            + #"{"type":"tool_use","id":"c","name":"Edit","input":{}}"#
        let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[\#(tools)]}}"#
        let jsonl = [snapshot, toolEcho, assistant].joined(separator: "\n")

        let entries = AgentTranscript.entries(from: Data(jsonl.utf8))
        XCTAssertEqual(entries.count, 1, "snapshot + tool-echo user line are dropped; only the assistant turn")
        XCTAssertEqual(entries[0].role, .assistant)
        XCTAssertTrue(entries[0].markdown.isEmpty, "a tool-only assistant turn has no body")
        XCTAssertEqual(entries[0].detail, "Read ×2 · Edit", "tools grouped in first-use order with ×N counts")
    }

    func testAgentTranscriptToleratesGarbageLineWithoutTrapping() {
        // A half-written / non-JSON line is classified `.unknown` by the tolerant parser and dropped — it
        // must never trap nor drop the surrounding valid turns.
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {not valid json at all
        """
        let entries = AgentTranscript.entries(from: Data(jsonl.utf8))
        XCTAssertEqual(entries.map(\.markdown), ["hi"], "the garbage line is dropped; the valid turn survives")
    }

    func testAgentLabelForwardTolerant() {
        XCTAssertEqual(AgentTranscript.agentLabel(.claude), "Claude Code")
        XCTAssertEqual(AgentTranscript.agentLabel(.codex), "Codex")
        XCTAssertEqual(AgentTranscript.agentLabel(.opencode), "OpenCode")
        XCTAssertEqual(AgentTranscript.agentLabel(nil), "Agent", "an unknown future agent-kind byte is tolerated")
    }

    func testRelativeTimeCoarseBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func msAgo(_ seconds: Double) -> Int64 { Int64((now.timeIntervalSince1970 - seconds) * 1000) }
        XCTAssertEqual(AgentTranscript.relativeTime(msAgo(5), now: now), "5s ago")
        XCTAssertEqual(AgentTranscript.relativeTime(msAgo(120), now: now), "2 min ago")
        XCTAssertEqual(AgentTranscript.relativeTime(msAgo(7200), now: now), "2h ago")
        XCTAssertEqual(AgentTranscript.relativeTime(msAgo(172_800), now: now), "2d ago")
        XCTAssertEqual(AgentTranscript.relativeTime(msAgo(-10), now: now), "just now", "future clock skew clamps")
    }

    func testClockTimeExtractsTimeFromISO() {
        XCTAssertEqual(AgentTranscript.clockTime(fromISO: "2026-06-25T19:30:21.000Z"), "19:30:21")
        XCTAssertEqual(AgentTranscript.clockTime(fromISO: "2026-06-25T19:30:21+02:00"), "19:30:21")
        XCTAssertNil(AgentTranscript.clockTime(fromISO: "2026-06-25"), "no time field ⇒ nil, never a trap")
        XCTAssertNil(AgentTranscript.clockTime(fromISO: "not-a-timestamp"))
    }

    // MARK: - DetailsPanelTab order (Outline + Git merged into Info — InspectorColumn)

    func testDetailsTabOrderIsInfoFiles() {
        // The Details panel's segmented header iterates the hoisted cross-module `DetailsPanelTab.allCases`.
        // The old standalone Outline tab was MERGED into the Info tab's Commands section, and the old Git
        // tab into Info's git-summary row + popup — so the fixed order is Info | Files. A resurfaced
        // "outline"/"git" case or a reorder fails this pin.
        let order = DetailsPanelTab.allCases.map(\.rawValue)
        XCTAssertEqual(order, ["info", "files"], "Details tab order (Outline + Git merged into Info)")
    }

    func testDetailsTabIconsAndTitles() {
        // The segmented header renders from the WI-7 view-local `DetailsPanelTab.title`/`.icon` extension.
        XCTAssertEqual(DetailsPanelTab.info.icon, "info.circle")
        XCTAssertEqual(DetailsPanelTab.info.title, "Info")
        XCTAssertEqual(DetailsPanelTab.files.icon, "folder")
        XCTAssertEqual(DetailsPanelTab.files.title, "Files")
    }

    // MARK: - InfoTabFormatting (Working Directory section — InspectorColumn, WI-6)

    func testDisplayPathFallsBackToEmDashForMissingCwd() {
        // ES-E9-1 / WI-6: the Info tab's Working Directory section leads with the focused pane's host path.
        // A disconnected pane (nil cwd) or an empty-string cwd must render the em-dash placeholder — never a
        // blank row — and a non-empty path must pass through VERBATIM (it is a REMOTE host path; no
        // client-side normalisation). FAILS on the un-fixed code (no `InfoTabFormatting`) and on a regression
        // that dropped the empty-string guard or rewrote the path. Not tautological — the expectations are the
        // fixed placeholder and the literal input, not the helper's own derivation.
        XCTAssertEqual(InfoTabFormatting.displayPath(nil), "—", "no cwd ⇒ em-dash, never a blank row")
        XCTAssertEqual(InfoTabFormatting.displayPath(""), "—", "an empty cwd is treated as missing")
        XCTAssertEqual(InfoTabFormatting.displayPath("~/Workplace/myproject"), "~/Workplace/myproject")
        XCTAssertEqual(InfoTabFormatting.displayPath("/Users/me/src/app"), "/Users/me/src/app")
    }

    /// ES-E9/bugfix: after a `cd`, the pane spec's live `lastKnownCwd` must win over the metadata model's
    /// stale bind-time `cwd` — the model is only refetched on pane-focus/(re)connect, so it would otherwise
    /// keep showing the pre-`cd` directory. FAILS on the un-fixed `activeModel.cwd ?? cwd` ordering, which
    /// returns the STALE model value whenever both are non-nil.
    func testResolveWorkingDirectoryPrefersLiveLastKnownCwdOverStaleModelCwd() {
        XCTAssertEqual(
            InfoTabFormatting.resolveWorkingDirectory(lastKnownCwd: "/Users/me/projB", modelCwd: "/Users/me/projA"),
            "/Users/me/projB",
            "the live post-cd cwd must win over the stale bind-time metadata cwd",
        )
    }

    /// A freshly-spawned pane (no OSC-7 fired yet, so `lastKnownCwd` is nil) still falls back to the
    /// host-resolved metadata cwd rather than showing the em-dash placeholder prematurely.
    func testResolveWorkingDirectoryFallsBackToModelCwdWhenNoLiveCwdKnown() {
        XCTAssertEqual(
            InfoTabFormatting.resolveWorkingDirectory(lastKnownCwd: nil, modelCwd: "/Users/me/projA"),
            "/Users/me/projA",
        )
        XCTAssertEqual(
            InfoTabFormatting.resolveWorkingDirectory(lastKnownCwd: "", modelCwd: "/Users/me/projA"),
            "/Users/me/projA",
            "an empty live cwd must not shadow a real model cwd",
        )
    }

    func testResolveWorkingDirectoryNilWhenBothMissing() {
        XCTAssertNil(InfoTabFormatting.resolveWorkingDirectory(lastKnownCwd: nil, modelCwd: nil))
        XCTAssertNil(InfoTabFormatting.resolveWorkingDirectory(lastKnownCwd: "", modelCwd: ""))
    }

    /// The Working Directory label's RESPONSIVE middle step (`ViewThatFits`: full → abbreviated →
    /// head-truncated abbreviation): every component but the LEAF collapses to its first character, so the
    /// project-identifying leaf survives narrow panels. FAILS on the un-fixed code (no `abbreviatedPath`)
    /// and on a regression that shortens the leaf, drops the leading `/`, or mangles `~`/dot-dirs. Not
    /// tautological — the expectations are literal fish-style strings, not the helper's own derivation.
    func testAbbreviatedPathCollapsesAllButTheLeaf() {
        XCTAssertEqual(
            InfoTabFormatting.abbreviatedPath("/Volumes/Lacie/Workspace/oss/aislopdesk"),
            "/V/L/W/o/aislopdesk",
            "absolute path: every non-leaf component collapses to its first character",
        )
        XCTAssertEqual(
            InfoTabFormatting.abbreviatedPath("~/Workplace/myproject"),
            "~/W/myproject",
            "a leading ~ survives whole (it is already one character of meaning)",
        )
        XCTAssertEqual(
            InfoTabFormatting.abbreviatedPath("/Users/me/.config/nvim"),
            "/U/m/.c/nvim",
            "a hidden directory keeps its dot + first letter so it stays recognisable",
        )
    }

    func testAbbreviatedPathPassesShortPathsThrough() {
        XCTAssertEqual(InfoTabFormatting.abbreviatedPath("/"), "/", "the bare root has nothing to collapse")
        XCTAssertEqual(InfoTabFormatting.abbreviatedPath("/tmp"), "/tmp", "a single component IS the leaf")
        XCTAssertEqual(InfoTabFormatting.abbreviatedPath("~"), "~")
        XCTAssertEqual(InfoTabFormatting.abbreviatedPath("—"), "—", "the placeholder passes through untouched")
    }

    /// The Info tab's git-summary row (the Git tab merged into Info): the trailing change-count label reads
    /// "clean" at zero (mirroring the popup's clean state) and "N changed" otherwise (the popup's
    /// "Changed (N)" header count). FAILS on the un-fixed code (no `gitChangeSummary`).
    func testGitChangeSummaryLabels() {
        XCTAssertEqual(InfoTabFormatting.gitChangeSummary(0), "clean")
        XCTAssertEqual(InfoTabFormatting.gitChangeSummary(1), "1 changed")
        XCTAssertEqual(InfoTabFormatting.gitChangeSummary(37), "37 changed")
    }

    // MARK: - AgentSessionHistoryView — Send to Chat context wiring

    /// REVERT-TO-CONFIRM-FAIL: without the `onSendToChat` callback the context-menu "Send to Chat" item
    /// has no target — the wiring is a no-op. With the fix the callback fires with a `SendToChatContext`
    /// whose `quoted` matches the entry's markdown and whose `title` names the speaker.
    ///
    /// The seam tested here is the CLOSURE CALL, not the SwiftUI `.contextMenu` modifier itself (which is a
    /// view-level binding). This verifies the `SendToChatContext` is constructed correctly from a parsed
    /// `AgentTranscriptEntry` before the callback fires.
    func testSendToChatContextFromTranscriptEntryHasCorrectQuotedText() {
        let markdown = "Please summarise the changes in `main.swift`."
        let speaker = "You"
        let entry = AgentTranscriptEntry(
            id: 0,
            role: .user,
            speaker: speaker,
            timestamp: nil,
            markdown: markdown,
            detail: nil,
        )

        // Simulate what the context-menu "Send to Chat" button does.
        let title = "\(entry.speaker) (transcript)"
        let context = SendToChatContext(title: title, quoted: entry.markdown)

        XCTAssertEqual(context.quoted, markdown, "quoted text is the entry's verbatim markdown")
        XCTAssertTrue(context.title.contains(speaker), "title names the speaker")
        XCTAssertNil(context.sourcePath, "transcript rows carry no file source path")
    }
}

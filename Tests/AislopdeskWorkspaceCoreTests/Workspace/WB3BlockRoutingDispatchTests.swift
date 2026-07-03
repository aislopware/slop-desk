import XCTest
@testable import AislopdeskWorkspaceCore

/// WB3 — the BEHAVIORAL dispatch of the re-run-last / jump-to-failed actions through the production
/// ``WorkspaceBindingRegistry/route(_:to:)`` seam, observed on a ``RecordingTerminalPaneSession`` that
/// carries a REAL ``TerminalViewModel``. Unlike `TreeCommandRoutingTests`'
/// `testWB3BlockActionsRouteToStoreWithoutMutatingTree` (which drives a ``FakePaneSession`` whose
/// non-terminal model makes every block op a no-op, so it can only assert tree-immutability and is blind to
/// which store hook fires), these tests assert the ACTUAL effect:
///  - re-run sends the latest command's bytes through the input path,
///  - the spec-critical `.jumpPreviousFailed → forward:false` / `.jumpNextFailed → forward:true`
///    INVERSION lands the viewport on the NEWER vs OLDER failure (a swapped mapping would fail here).
///
/// HANG-SAFE: the recording session uses a headless ``RecordingSurfaceActions`` (no GhosttySurface /
/// VideoToolbox / Metal / SCStream) — the hang-safety rule holds.
@MainActor
final class WB3BlockRoutingDispatchTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store backed by the recording (terminal-model-carrying) session seam.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The active pane's recording session.
    private func activeSession(_ store: WorkspaceStore) throws -> RecordingTerminalPaneSession {
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        return try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
    }

    /// Seeds `blocks` into the active pane's model and returns its session.
    @discardableResult
    private func seedBlocks(_ store: WorkspaceStore, _ blocks: [CommandBlock]) throws -> RecordingTerminalPaneSession {
        let session = try activeSession(store)
        let model = try XCTUnwrap(session.terminalModel)
        for b in blocks {
            model.blocks.upsert(
                index: b.index, commandText: b.commandText, exitCode: b.exitCode,
                durationMS: b.durationMS, complete: b.complete, outputLen: b.outputLen,
                promptOrdinal: b.promptOrdinal,
            )
        }
        return session
    }

    /// A failed block. `ordinal` defaults to the index (the no-empty-prompt-cycles case); pass an
    /// explicit ordinal to model empty-Enter cycles between commands.
    private func failed(_ index: UInt32, ordinal: UInt32? = nil) -> CommandBlock {
        CommandBlock(
            index: index, commandText: "cmd\(index)", exitCode: 1, complete: true,
            promptOrdinal: ordinal ?? index,
        )
    }

    private func ok(_ index: UInt32, ordinal: UInt32? = nil) -> CommandBlock {
        CommandBlock(
            index: index, commandText: "cmd\(index)", exitCode: 0, complete: true,
            promptOrdinal: ordinal ?? index,
        )
    }

    // MARK: - Re-run last command

    /// `.reRunLastCommand` re-injects the LATEST block's command text (verbatim + 1 newline) through the
    /// pane's input path. Pins it uses `latest` (the last block), not the first.
    func testReRunLastCommandSendsLatestCommandBytes() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [
            CommandBlock(index: 0, commandText: "first", complete: true),
            CommandBlock(index: 1, commandText: "latest", complete: true),
        ])

        WorkspaceBindingRegistry.route(.reRunLastCommand, to: store)

        XCTAssertEqual(session.sentInput.count, 1, "re-run sent exactly one input payload")
        XCTAssertEqual(
            session.sentInput.first, Data("latest\n".utf8),
            "re-run injects the LATEST command's bytes (not the first), verbatim + one newline",
        )
    }

    /// `.reRunLastCommand` with an empty latest command is a true no-op at the store layer (the encoder
    /// returns nil) — nothing is sent.
    func testReRunEmptyLatestIsANoOp() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [CommandBlock(index: 0, commandText: "   ", complete: true)])

        WorkspaceBindingRegistry.route(.reRunLastCommand, to: store)

        XCTAssertTrue(session.sentInput.isEmpty, "an empty/whitespace latest command sends nothing")
    }

    /// `.reRunLastCommand` with NO blocks at all is a no-op (no latest).
    func testReRunWithNoBlocksIsANoOp() throws {
        let store = makeStore()
        let session = try activeSession(store)

        WorkspaceBindingRegistry.route(.reRunLastCommand, to: store)

        XCTAssertTrue(session.sentInput.isEmpty, "no blocks ⇒ no re-run")
    }

    // MARK: - Re-run an EXPLICIT command (E11 Open-Quickly Command-row "Re-Run in Current Pane")

    /// `reRunCommandInActivePane(_:)` re-injects an EXPLICIT command text (the picked Current Command row,
    /// not the latest block) verbatim + one newline through the pane's input path — the Open-Quickly
    /// Command-row "Re-Run in Current Pane" action. Pins it sends the PASSED text (`"git status"`), independent of the
    /// block list, and that a literal `"<Enter>"` substring is NOT parsed into a control byte (the verbatim
    /// `BlockReRunEncoder` invariant). FAILS if the action were wired to `reRunLastCommandInActivePane`
    /// (which would send the latest block "tail", not the picked row) or to a SendKeysParser path.
    func testReRunCommandInActivePaneSendsVerbatimBytes() throws {
        let store = makeStore()
        // Seed an UNRELATED latest block so a wrong wiring to `reRunLastCommand` would send "tail\n" instead.
        let session = try seedBlocks(store, [CommandBlock(index: 0, commandText: "tail", complete: true)])

        store.reRunCommandInActivePane("echo \"<Enter>\"")

        XCTAssertEqual(session.sentInput.count, 1, "exactly one input payload sent")
        XCTAssertEqual(
            session.sentInput.first, Data("echo \"<Enter>\"\n".utf8),
            "the PASSED command is re-injected verbatim + one newline (the literal <Enter> stays literal)",
        )
    }

    /// `reRunCommandInActivePane("")` (and a whitespace-only text) is a no-op — the encoder returns nil, so
    /// no bare newline is sent.
    func testReRunCommandInActivePaneEmptyTextIsANoOp() throws {
        let store = makeStore()
        let session = try activeSession(store)

        store.reRunCommandInActivePane("   ")

        XCTAssertTrue(session.sentInput.isEmpty, "an empty/whitespace command sends nothing")
    }

    // MARK: - Copy block output routing (Command Navigator per-row "Copy Output")

    /// `copyBlockOutputInActivePane(index:onResult:)` routes to the ACTIVE pane's terminal model's block-
    /// output request (wire type 15) for the given index, then resolves the completion from the host's
    /// reply with the VT-stripped plain text. Pins the store→model routing the navigator's per-row Copy
    /// affordance depends on (the view only owns the clipboard write). FAILS if the store requested a
    /// different index or dropped the reply.
    func testCopyBlockOutputInActivePaneRoutesToActiveModel() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [ok(3), ok(7)])
        let model = try XCTUnwrap(session.terminalModel)
        var requestedIndex: UInt32?
        model.requestBlockOutputSink = { requestedIndex = $0 }

        var result: String? = "unset"
        store.copyBlockOutputInActivePane(index: 7) { result = $0 }
        XCTAssertEqual(requestedIndex, 7, "the store routes the copy request to the active model for the given index")

        // Simulate the host's type-29 reply → the completion resolves with the sanitized output text.
        model.blocks.resolveOutput(index: 7, output: Data("built ok\n".utf8))
        XCTAssertEqual(result?.contains("built ok"), true, "the completion receives the sanitized block output")
    }

    /// An EMPTY host reply (block evicted / unavailable) resolves the copy completion as `nil` — a graceful
    /// no-op the navigator turns into "nothing copied" rather than a hang.
    func testCopyBlockOutputEmptyReplyResolvesNil() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [ok(1)])
        let model = try XCTUnwrap(session.terminalModel)
        model.requestBlockOutputSink = { _ in }

        var resolved = false
        var result: String? = "unset"
        store.copyBlockOutputInActivePane(index: 1) { result = $0
            resolved = true
        }
        model.blocks.resolveOutput(index: 1, output: Data()) // empty ⇒ unavailable

        XCTAssertTrue(resolved, "the completion always resolves (never hangs)")
        XCTAssertNil(result, "an empty reply resolves as unavailable (nil)")
    }

    // MARK: - Jump-to-failed direction inversion (the spec-critical mapping)

    /// THE direction guard. Blocks (index-ascending, so navigatorBlocks is newest-first 5,4,3,2,1):
    /// `[5 FAIL, 4 ok, 3 FAIL, 2 ok, 1 FAIL]`. With the cursor on block 3, `.jumpNextFailed` (forward:true,
    /// toward OLDER) must land on 1, and `.jumpPreviousFailed` (forward:false, toward NEWER) must land on 5.
    /// A swapped `forward:` mapping (or both true) lands the wrong way and FAILS this — pinning the
    /// `.jumpPreviousFailed → false` / `.jumpNextFailed → true` inversion the router documents.
    func testJumpNextVsPreviousFailedLandOnOlderVsNewer() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [failed(1), ok(2), failed(3), ok(4), failed(5)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)
        // Seat the cursor ON block 3 (a failure) so the search must ADVANCE past it in each direction.
        store.blockBookmarks.jumpCursor[session.id] = 3

        // navigatorBlocks newest-first: [5,4,3,2,1]. .jumpNextFailed = forward:true = toward OLDER =
        // block 1 (prompt ordinal 1) → anchor on the oldest prompt (no second jump: the anchor IS #1).
        WorkspaceBindingRegistry.route(.jumpNextFailed, to: store)
        XCTAssertEqual(store.blockBookmarks.jumpCursor[session.id], 1, "next-failed lands on the OLDER failure (1)")
        XCTAssertEqual(
            recorder.actions,
            ["scroll_to_bottom", "jump_to_prompt:-\(BlockJump.reAnchorDelta)"],
            "ordinal 1 = the anchor itself (oldest retained prompt) — no second jump",
        )

        recorder.resetActions()
        // From the cursor now on 1, .jumpPreviousFailed = forward:false = toward NEWER = block 3
        // (prompt ordinal 3) → anchor + step DOWN ordinal − 1 = 2 prompts.
        WorkspaceBindingRegistry.route(.jumpPreviousFailed, to: store)
        XCTAssertEqual(store.blockBookmarks.jumpCursor[session.id], 3, "prev-failed steps to the NEWER failure (3)")
        XCTAssertEqual(
            recorder.actions,
            ["scroll_to_bottom", "jump_to_prompt:-\(BlockJump.reAnchorDelta)", "jump_to_prompt:2"],
            "ordinal 3 = 2 prompts below the oldest-prompt anchor",
        )
    }

    /// `.jumpPreviousFailed` from the cursor on block 3 walks toward the NEWEST failure (5), not the oldest —
    /// a second, isolated pin of the inversion that does NOT depend on the next-failed step above.
    func testJumpPreviousFailedFromMiddleReachesNewest() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [failed(1), ok(2), failed(3), ok(4), failed(5)])
        store.blockBookmarks.jumpCursor[session.id] = 3

        WorkspaceBindingRegistry.route(.jumpPreviousFailed, to: store) // toward NEWER
        XCTAssertEqual(
            store.blockBookmarks.jumpCursor[session.id],
            5,
            "prev-failed from 3 reaches the newest failure 5",
        )
    }

    // MARK: - Bookmark seed wiring (model → store persistence)

    /// `seedBlockBookmarks` (run when a leaf materializes) wires the model's `onBookmarksChanged` to the
    /// store's `save` closure keyed by the session's per-session scope key, with the indices SORTED — and
    /// `load` seeds the model from persistence. Pins the model→store round-trip the store-glue composes
    /// (untested before: every prior store test routed through a non-terminal `FakePaneSession`).
    func testSeedBlockBookmarksWiresSaveAndLoad() throws {
        let store = makeStore()
        // Install the persistence seam BEFORE materializing a fresh pane, so seedBlockBookmarks wires it.
        var saved: [String: [UInt32]] = [:]
        store.blockBookmarks.load = { key in key == "preseeded" ? [7, 2] : [] }
        store.blockBookmarks.save = { key, indices in saved[key] = indices }

        // Split to materialize a NEW leaf → wireMaterializedLeaf → seedBlockBookmarks runs for it.
        store.splitActivePane(axis: .horizontal, kind: .terminal) // real terminal (route() now mints a chooser)
        let session = try activeSession(store)
        let model = try XCTUnwrap(session.terminalModel)

        // A toggle fires onBookmarksChanged → save(scopeKey, sortedIndices).
        model.blocks.toggleBookmark(index: 5)
        model.blocks.toggleBookmark(index: 1)
        XCTAssertEqual(saved[session.bookmarkScopeKey], [1, 5], "save persists the SORTED indices under the scope key")
        XCTAssertNil(saved["preseeded"], "save is keyed by the session scope key, not an arbitrary string")
    }

    /// `load` seeds the freshly-materialized model's bookmark set (the restore direction) WITHOUT firing
    /// `save` (a seed is not a user edit).
    func testSeedBlockBookmarksLoadsPersistedSet() throws {
        let store = makeStore()
        var saveCount = 0
        store.blockBookmarks.load = { _ in [3, 9] }
        store.blockBookmarks.save = { _, _ in saveCount += 1 }

        store.splitActivePane(axis: .horizontal, kind: .terminal) // real terminal (route() now mints a chooser)
        let session = try activeSession(store)
        let model = try XCTUnwrap(session.terminalModel)

        XCTAssertEqual(model.blocks.bookmarkedIndices, [3, 9], "the model is seeded from persistence on materialize")
        XCTAssertEqual(saveCount, 0, "seeding is the restore direction — it must NOT fire save")
    }

    /// Each materialized session mints its OWN per-session bookmark scope key, so distinct sessions never
    /// share a persisted star set — the property that makes a relaunch (a brand-new segmenter numbering
    /// blocks from 0) start with no stars instead of grafting a prior run's raw indices onto unrelated
    /// commands. (The stable PaneID would survive relaunch and re-key the same set — the bug this fixes.)
    func testEachSessionHasADistinctBookmarkScopeKey() throws {
        let store = makeStore()
        let first = try activeSession(store)
        store.splitActivePane(axis: .horizontal, kind: .terminal) // real terminal (route() now mints a chooser)
        let second = try activeSession(store)
        XCTAssertNotEqual(first.id, second.id, "two distinct panes")
        XCTAssertNotEqual(
            first.bookmarkScopeKey, second.bookmarkScopeKey,
            "each session's bookmark persistence key is distinct (per-session, not per-stable-pane-id)",
        )
    }

    // MARK: - BlockJump choreography (the shared re-anchor jump — Commands panel / navigator / jump-to-failed)

    /// ghostty parses the `jump_to_prompt` parameter as `i16` — an anchor delta outside that range fails
    /// the binding parse and silently no-ops (the bare-`scroll_to_bottom` regression seen on hardware).
    /// Pins the constant inside the parseable range while staying far above any real prompt count.
    func testReAnchorDeltaFitsGhosttyI16BindingParameter() {
        XCTAssertLessThanOrEqual(
            BlockJump.reAnchorDelta,
            Int(Int16.max) + 1,
            "-reAnchorDelta must parse as ghostty's i16 binding parameter",
        )
        XCTAssertGreaterThanOrEqual(
            BlockJump.reAnchorDelta,
            10000,
            "still far beyond any retained scrollback's prompt count",
        )
    }

    /// The choreography pin: ordinal 1 anchors only (the huge-negative jump already lands on prompt #1);
    /// ordinal k ≥ 2 adds a downward `k − 1` (the anchor row's own prompt is never counted by ghostty's
    /// downward iterator, so `k − 1` lands prompt #k exactly); ordinal 0 (unknown) emits NOTHING — a
    /// mid-stream-join block must not mis-land the viewport.
    func testBlockJumpOrdinalChoreography() {
        let recorder = RecordingSurfaceActions()
        BlockJump.toPromptOrdinal(1, using: recorder)
        XCTAssertEqual(recorder.actions, ["scroll_to_bottom", "jump_to_prompt:-\(BlockJump.reAnchorDelta)"])

        recorder.resetActions()
        BlockJump.toPromptOrdinal(5, using: recorder)
        XCTAssertEqual(
            recorder.actions,
            ["scroll_to_bottom", "jump_to_prompt:-\(BlockJump.reAnchorDelta)", "jump_to_prompt:4"],
        )

        recorder.resetActions()
        BlockJump.toPromptOrdinal(0, using: recorder)
        XCTAssertTrue(recorder.actions.isEmpty, "an unknown ordinal (0) must not move the viewport at all")
    }

    /// A prompt ordinal BEYOND ghostty's i16 binding-parameter range (`jump_to_prompt` is `i16`, max
    /// 32767) must NOT emit a single out-of-range step: a raw `jump_to_prompt:39999` fails the ACTION
    /// STRING PARSE and silently no-ops the whole binding, landing on the anchor (oldest prompt) instead of
    /// the target — the long-lived-detached-session bug (every Enter grows the ordinal). The downward
    /// `ordinal − 1` delta is instead SPLIT into in-range hops whose SUM equals the full delta, so
    /// consecutive hops compose to land the exact prompt. Pins: every emitted step parses as `i16` AND the
    /// steps sum to `ordinal − 1`. FAILS on the pre-fix single-step emission (`Int16("39999")` is nil).
    func testBlockJumpChunksStepBeyondI16Range() {
        let recorder = RecordingSurfaceActions()
        BlockJump.toPromptOrdinal(40000, using: recorder)

        let actions = recorder.actions
        XCTAssertGreaterThanOrEqual(actions.count, 3, "anchor pair + at least one step")
        XCTAssertEqual(actions[0], "scroll_to_bottom", "still anchors on scroll_to_bottom")
        XCTAssertEqual(
            actions[1],
            "jump_to_prompt:-\(BlockJump.reAnchorDelta)",
            "still re-anchors on the oldest prompt",
        )

        let steps: [Int] = Array(actions[2...]).map { action in
            let raw = action.split(separator: ":").last.map(String.init) ?? ""
            XCTAssertNotNil(Int16(raw), "every step (\(action)) must parse as ghostty's i16 binding parameter")
            return Int(raw) ?? 0
        }
        XCTAssertFalse(steps.isEmpty, "a beyond-i16 ordinal still emits downward steps")
        XCTAssertTrue(steps.allSatisfy { $0 > 0 }, "all steps are downward (positive)")
        XCTAssertEqual(steps.reduce(0, +), 39999, "the split hops sum to the full ordinal − 1 delta (40000 − 1)")
    }

    /// The exact-boundary case: ordinal `maxStep + 2` (step delta `maxStep + 1`) splits into `maxStep` then
    /// `1`; ordinal `maxStep + 1` (step delta `maxStep`) is still a SINGLE in-range hop. Pins the split
    /// threshold is `> maxStep`, not `>=`.
    func testBlockJumpSingleHopAtBoundaryTwoHopsJustBeyond() {
        let single = RecordingSurfaceActions()
        BlockJump.toPromptOrdinal(UInt32(BlockJump.maxStep + 1), using: single) // step = maxStep exactly
        XCTAssertEqual(
            Array(single.actions[2...]), ["jump_to_prompt:\(BlockJump.maxStep)"],
            "a step of exactly maxStep is one in-range hop",
        )

        let split = RecordingSurfaceActions()
        BlockJump.toPromptOrdinal(UInt32(BlockJump.maxStep + 2), using: split) // step = maxStep + 1
        XCTAssertEqual(
            Array(split.actions[2...]),
            ["jump_to_prompt:\(BlockJump.maxStep)", "jump_to_prompt:1"],
            "a step one past maxStep splits into maxStep + 1",
        )
    }

    // MARK: - E9: Jump to a specific Outline block (jumpToNavigatorBlockInActivePane)

    /// E9 (ES-E9-2): clicking a Commands row jumps the scrollback to that block via
    /// `jumpToNavigatorBlockInActivePane(index:)`, driven by the block's HOST-STAMPED prompt ordinal —
    /// NOT its position among the blocks. Seed ordinals ≠ indices (ordinal 2 was an empty-Enter cycle
    /// that produced no block): jumping to block index 2 (ordinal 3) must step `3 − 1 = 2` prompts below
    /// the anchor. A position-derived delta (index 2 of 3 blocks → newest-first pos 1 → `3 − 1 = 2`…
    /// with block 3 it would compute 1) or an index-as-ordinal read fails this pin.
    func testJumpToNavigatorBlockUsesHostStampedOrdinalNotPosition() throws {
        let store = makeStore()
        // Ordinals 1, 3, 4: an empty Enter consumed ordinal 2 between cmd1 and cmd2.
        let session = try seedBlocks(store, [ok(1, ordinal: 1), ok(2, ordinal: 3), ok(3, ordinal: 4)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)

        store.jumpToNavigatorBlockInActivePane(index: 2)

        XCTAssertEqual(
            recorder.actions,
            ["scroll_to_bottom", "jump_to_prompt:-\(BlockJump.reAnchorDelta)", "jump_to_prompt:2"],
            "block index 2 carries prompt ordinal 3 (an empty Enter consumed ordinal 2) → step 2 below "
                + "the anchor; a block-position delta would mis-land on the empty prompt",
        )
    }

    /// The OLDEST block (ordinal 1) needs NO second jump (the anchor lands on it); the NEWEST (ordinal 5)
    /// steps `5 − 1 = 4`. Pins both ends of the ordinal → delta mapping.
    func testJumpToNavigatorBlockHandlesOldestAndNewestEnds() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [ok(1), ok(2), ok(3), ok(4), ok(5)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)

        store.jumpToNavigatorBlockInActivePane(index: 1) // oldest → ordinal 1 → anchor only
        XCTAssertEqual(
            recorder.actions, ["scroll_to_bottom", "jump_to_prompt:-\(BlockJump.reAnchorDelta)"],
            "the oldest block IS the anchored oldest prompt — no second jump",
        )

        recorder.resetActions()
        store.jumpToNavigatorBlockInActivePane(index: 5) // newest → ordinal 5 → 5 − 1 = 4
        XCTAssertEqual(
            recorder.actions,
            ["scroll_to_bottom", "jump_to_prompt:-\(BlockJump.reAnchorDelta)", "jump_to_prompt:4"],
            "the newest block is 4 prompts below the oldest-prompt anchor",
        )
    }

    /// A block stamped with NO ordinal (0 — a mid-stream join) is a graceful no-op: the viewport must not
    /// move at all (a wrong landing is worse than none). FAILS if the ordinal-0 guard were dropped.
    func testJumpToNavigatorBlockWithUnknownOrdinalIsANoOp() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [ok(1, ordinal: 0)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)

        store.jumpToNavigatorBlockInActivePane(index: 1)

        XCTAssertTrue(recorder.actions.isEmpty, "an ordinal-less block emits no surface action (never mis-lands)")
    }

    /// An evicted / never-seen index is a graceful no-op — no surface action, no trap (the Outline can hold a
    /// row whose block has since rolled out of the navigator window). FAILS if the guard that requires the
    /// index to resolve to a position were dropped (it would emit a stray re-anchor or trap).
    func testJumpToNavigatorBlockUnknownIndexIsANoOp() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [ok(1), ok(2), ok(3)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)

        store.jumpToNavigatorBlockInActivePane(index: 99) // never-seen / evicted index

        XCTAssertTrue(recorder.actions.isEmpty, "an unknown/evicted index emits no surface action (never traps)")
    }

    /// Jump-to-failed with NO failures is a no-op (cursor untouched, no surface action).
    func testJumpFailedWithNoFailuresIsANoOp() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [ok(1), ok(2), ok(3)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)

        WorkspaceBindingRegistry.route(.jumpNextFailed, to: store)
        WorkspaceBindingRegistry.route(.jumpPreviousFailed, to: store)

        XCTAssertNil(store.blockBookmarks.jumpCursor[session.id], "no failures ⇒ cursor stays unset")
        XCTAssertTrue(recorder.actions.isEmpty, "no failures ⇒ no jump action emitted")
    }

    // MARK: - End-to-end vs a faithful ghostty scrollPrompt model (the real land-on-the-right-command pin)

    /// Replays the store's emitted libghostty actions for a jump to every block in `blocks` through
    /// ``GhosttyScrollPromptModel`` and asserts each landing: the target's prompt row sits at the
    /// viewport top (or the viewport pins to `.active` when the row is inside the active area — either
    /// way the row must be VISIBLE).
    private func assertJumpLands(
        blocks: [CommandBlock],
        prompts: [Bool],
        visibleRows: Int,
        commandPromptRows: [UInt32: Int],
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws {
        for index in commandPromptRows.keys.sorted() {
            let store = makeStore()
            let session = try seedBlocks(store, blocks)
            let recorder = try XCTUnwrap(session.surfaceRecorder)

            store.jumpToNavigatorBlockInActivePane(index: index)

            var model = GhosttyScrollPromptModel(prompts: prompts, visibleRows: visibleRows)
            model.apply(recorder.actions)

            let target = try XCTUnwrap(commandPromptRows[index])
            let activeTop = max(0, prompts.count - visibleRows)
            if target >= activeTop {
                // A prompt inside the active area: ghostty pins the viewport to `.active` (it can't scroll
                // DOWN into the active area) — the command is on screen, the correct landing.
                XCTAssertEqual(
                    model.viewportTop, activeTop,
                    "block \(index) (prompt row \(target)) is in the active area → viewport pins to active",
                    file: file, line: line,
                )
            } else {
                XCTAssertEqual(
                    model.viewportTop, target,
                    "block \(index)'s prompt (row \(target)) must sit at the viewport top after the jump",
                    file: file, line: line,
                )
            }
            XCTAssertTrue(
                target >= model.viewportTop && target < model.viewportTop + visibleRows,
                "block \(index)'s command prompt is visible after clicking its Commands row",
                file: file, line: line,
            )
        }
    }

    /// The FRESH-PANE case — the one every new terminal hits: the shell's FIRST prompt IS the oldest
    /// retained row (row 0), so ghostty's downward iterator (which starts at `viewport_top.down(1)` and
    /// never counts the top row's own prompt) skips prompt #1 for any `scroll_to_top`-anchored count.
    /// The old `scroll_to_top` + `jump_to_prompt:(total − pos)` landed EVERY jump one command too new
    /// here; the ordinal choreography's huge-negative anchor makes "top row = prompt #1" an invariant.
    /// FAILS on the pre-fix code.
    func testOutlineJumpLandsOnClickedCommandInFreshPane() throws {
        // rows: 0 prompt#1(cmd1) · 1 output · 2 prompt#2(cmd2) · 3 output · 4 prompt#3(cmd3) · 5 output
        //       · 6 live idle prompt(#4). visibleRows = 3 ⇒ active area = rows 4…6.
        let prompts = [true, false, true, false, true, false, true]
        try assertJumpLands(
            blocks: [ok(1), ok(2), ok(3)],
            prompts: prompts,
            visibleRows: 3,
            commandPromptRows: [1: 0, 2: 2, 3: 4],
        )
    }

    /// The EMPTY-ENTER case: a blockless prompt cycle (empty Enter / Ctrl-C — precmd re-fires `A`, the
    /// segmenter rightly discards the cycle) sits between cmd1 and cmd2, so ghostty has one more prompt
    /// row than there are blocks. A block-count-derived delta under-counts and lands on the EMPTY prompt;
    /// the host-stamped ordinals (1 and 3 — ordinal 2 was consumed by the empty cycle) land exactly.
    /// FAILS on the pre-fix code.
    func testOutlineJumpSkipsBlocklessEmptyEnterPrompts() throws {
        // rows: 0 banner · 1 prompt#1(cmd1) · 2 output · 3 prompt#2(EMPTY Enter) · 4 prompt#3(cmd2)
        //       · 5 output · 6 live idle prompt(#4). visibleRows = 3 ⇒ active area = rows 4…6.
        let prompts = [false, true, false, true, true, false, true]
        try assertJumpLands(
            blocks: [ok(1, ordinal: 1), ok(2, ordinal: 3)],
            prompts: prompts,
            visibleRows: 3,
            commandPromptRows: [1: 1, 2: 4],
        )
    }

    /// The VISIBLE-PROMPTS case (the old `scroll_to_bottom` + `-(pos+1)` bug's shape): the newest two
    /// command prompts + the live idle prompt are ON SCREEN (in the active area) with a non-prompt row 0.
    /// Kept from the previous pin so the ordinal choreography also covers the case the last fix targeted.
    func testOutlineJumpLandsOnClickedCommandAcrossVisiblePrompts() throws {
        // Buffer (0-indexed rows), true = a prompt row. Row 0 is command-output preamble. visibleRows = 4
        // ⇒ active area = rows 6…9, so block4(7), block5(8) and the live idle prompt(9) are ON SCREEN;
        // block1(1), block2(3), block3(5) are in the scrollback.
        let prompts = [false, true, false, true, false, true, false, true, true, true]
        try assertJumpLands(
            blocks: [ok(1), ok(2), ok(3), ok(4), ok(5)],
            prompts: prompts,
            visibleRows: 4,
            commandPromptRows: [1: 1, 2: 3, 3: 5, 4: 7, 5: 8],
        )
    }

    /// The EVERYTHING-VISIBLE case: the whole (short) buffer fits in the active area, so the anchor's
    /// huge negative finds no prompt above the active top and the viewport stays `.active` — every
    /// command is on screen, which is the correct landing (no wild scroll).
    func testOutlineJumpWithAllPromptsVisibleStaysActive() throws {
        // rows: 0 prompt#1 · 1 prompt#2(empty) · 2 prompt#3(cmd2) · 3 live idle. visibleRows = 5 > 4 rows.
        let prompts = [true, true, true, true]
        try assertJumpLands(
            blocks: [ok(1, ordinal: 1), ok(2, ordinal: 3)],
            prompts: prompts,
            visibleRows: 5,
            commandPromptRows: [1: 0, 2: 2],
        )
    }
}

/// A faithful, headless port of ghostty's `PageList.zig` `scrollPrompt` (+ `scroll_to_top`/`scroll_to_bottom`)
/// over a flat prompt-flag buffer — used ONLY to prove the store's emitted libghostty actions land the
/// viewport on the intended command prompt. Faithful on the three load-bearing behaviours (pinned
/// v1.3.1): the downward iterator starts at `viewport_top.down(1)` (the top row's own prompt is never
/// counted), the upward iterator starts at `up(1)`, and a delta LARGER than the available prompt count
/// moves to the LAST prompt found (ghostty keeps `prompt_pin` across the exhausted loop — the behaviour
/// the huge-negative re-anchor relies on). A landed prompt inside the active area keeps `.active`
/// (`pinIsActive`). It is NOT a re-implementation the product depends on; it mirrors the vendored ghostty
/// semantics so the test isn't tautological against the store's own choreography.
private struct GhosttyScrollPromptModel {
    let prompts: [Bool] // prompts[i] == true ⇒ row i is a `.prompt` row
    let visibleRows: Int
    var viewportTop = 0

    private var activeTop: Int { max(0, prompts.count - visibleRows) }

    /// Replays the recorded action strings (`scroll_to_top` / `scroll_to_bottom` / `jump_to_prompt:<delta>`).
    /// FAITHFUL to ghostty's binding-action parser: `jump_to_prompt` is declared `i16` (`Binding.zig`),
    /// so a delta outside −32768…32767 FAILS the parse and the whole action silently no-ops — exactly
    /// the hardware failure the first shipped anchor (−1_000_000) hit. Parsing into `Int16` here makes
    /// the end-to-end pins catch any out-of-range delta the store might emit.
    mutating func apply(_ actions: [String]) {
        for action in actions {
            switch action {
            case "scroll_to_top": viewportTop = 0
            case "scroll_to_bottom": viewportTop = activeTop
            default:
                if action.hasPrefix("jump_to_prompt:"),
                   let raw = action.split(separator: ":").last,
                   let delta = Int16(raw) { scrollPrompt(Int(delta)) }
            }
        }
    }

    /// The negative branch counts prompts from `viewportTop.up(1)` walking UP; the positive branch counts
    /// from `viewportTop.down(1)` walking DOWN. Ghostty keeps the LAST prompt found when the delta
    /// exceeds the count (`prompt_pin` survives the exhausted loop) — the viewport moves to it. A landed
    /// prompt inside the active area keeps `.active`.
    private mutating func scrollPrompt(_ delta: Int) {
        guard delta != 0 else { return }
        var remaining = abs(delta)
        var landed: Int?
        if delta < 0 {
            var row = viewportTop - 1
            while row >= 0 {
                if prompts[row] {
                    landed = row
                    remaining -= 1
                    if remaining == 0 { break }
                }
                row -= 1
            }
        } else {
            var row = viewportTop + 1
            while row < prompts.count {
                if prompts[row] {
                    landed = row
                    remaining -= 1
                    if remaining == 0 { break }
                }
                row += 1
            }
        }
        guard let p = landed else { return }
        viewportTop = p >= activeTop ? activeTop : p
    }
}

import AislopdeskTerminal
import Foundation

// MARK: - CommandBlock → PeekBlockLine (the P4 peek "recent output" shape)

/// ``CommandBlock`` already carries the typed command line + a short status label, so it satisfies the
/// pure ``PeekBlockLine`` shape ``PeekContent/recentLines(from:limit:)`` reads — letting the peek DTO be
/// built off the live ``TerminalBlockModel`` while the builder itself stays free of an `AislopdeskTerminal`
/// import (the P4 overlay's recent-lines text is then unit-tested with a stand-in).
extension CommandBlock: PeekBlockLine {}

// MARK: - TerminalModelProviding (the store↔live-session seam the block ops resolve through)

/// The tiny capability seam the WB2/WB3 active-pane block ops resolve through INSTEAD of an
/// `as? LivePaneSession` cast — so the store's block-routing glue (navigator / jump-to-block /
/// re-run-last / jump-to-failed / bookmark seed) is exercisable by a recording test double that carries a
/// REAL ``TerminalViewModel`` but never opens a socket. The production conformer is ``LivePaneSession``
/// (returns its `connection.terminalModel`); a headless test conformer returns a directly-built model.
///
/// `bookmarkScopeKey` is the per-SESSION persistence identity (NOT the stable pane id): a token minted
/// fresh each time the session is materialized, so a relaunch (a brand-new segmenter re-numbering blocks
/// from 0) starts with NO stars rather than re-applying a prior run's raw indices onto unrelated commands
/// (the cross-session mis-restore the persisted-by-pane-id wiring caused). Stable across a transport
/// reconnect within one launch (same session instance).
@MainActor
protocol TerminalModelProviding: AnyObject {
    /// The live terminal model the block ops drive, or `nil` for a non-terminal session (`.remoteGUI`).
    var terminalModel: TerminalViewModel? { get }

    /// The per-session key block bookmarks persist under (see the type doc). Distinct per materialization.
    var bookmarkScopeKey: String { get }
}

// MARK: - BlockBookmarkSeam (WB3 — the store's per-pane bookmark persistence + jump cursor)

/// The per-pane block-bookmark persistence seam plus the jump-to-failed cursor, bundled so the
/// ``WorkspaceStore`` holds ONE stored property for the whole WB3 surface (keeping its body under the lint
/// type-body ceiling). `load`/`save` are wired by the app to the ``PreferencesStore`` keyed by the
/// per-SESSION scope key (``TerminalModelProviding/bookmarkScopeKey`` — NOT the stable pane id, so a
/// relaunch with a fresh block-index space does not re-apply stale stars onto unrelated commands); left
/// `nil` bookmarks are in-memory only. `jumpCursor` maps a pane to the index its last jump-to-failed
/// landed on (`nil`/absent = start from the newest end).
public struct BlockBookmarkSeam {
    /// Loads the persisted bookmark indices for a session scope key (app → ``PreferencesStore``).
    /// `nil` ⇒ in-memory only.
    public var load: ((String) -> [UInt32])?
    /// Persists a session scope key's bookmark indices (app → ``PreferencesStore``). `nil` ⇒ in-memory only.
    public var save: ((String, [UInt32]) -> Void)?
    /// The per-pane jump-to-failed cursor (the block index the last jump landed on; absent = newest end).
    public var jumpCursor: [PaneID: UInt32] = [:]

    public init() {}
}

// MARK: - BlockJump (the ONE shared absolute re-anchor jump — navigator + store share it)

/// The single absolute "jump the viewport to navigator position N" implementation (WB2/WB3), so the
/// navigator's per-row jump and the store's jump-to-failed cannot drift on the delta math. It re-anchors
/// to the OLDEST row (`scroll_to_top`) then steps DOWN (positive delta) to the target prompt — the delta
/// math is ``BlockJump/jumpDelta(toTargetPos:totalBlocks:)``. Pure over the ``TerminalSurfaceActions``
/// seam; `nonisolated` so both call sites reach it.
enum BlockJump {
    /// The libghostty `jump_to_prompt` delta to land newest-first navigator position `pos` (0 = newest)
    /// AFTER the viewport has been re-anchored to the TOP (`scroll_to_top`), given `total` command blocks.
    ///
    /// ## Why re-anchor to the TOP, not the bottom
    /// libghostty's `scrollPrompt` (ghostty `PageList.zig`, pinned v1.3.1) counts prompts RELATIVE TO THE
    /// VIEWPORT TOP, not from a "bottom = 0" origin. For a NEGATIVE (upward) delta it starts its
    /// `PromptIterator` at `getTopLeft(.viewport).up(1)` — one row ABOVE the viewport top — and walks up.
    /// So after `scroll_to_bottom` (viewport = the active area) an upward jump counts ONLY prompts that
    /// scrolled off the top into the scrollback; every prompt still VISIBLE in the active area (the live
    /// idle prompt PLUS any short-command prompts) is skipped. A constant `-(pos + 1)` therefore overshoots
    /// by the number of on-screen prompts (or no-ops entirely when nothing sits above the active-area top),
    /// landing on an older command — the ghostty "Screen: jump back one prompt" test shows exactly this
    /// (jumping back from the active area lands on the scrollback prompt, never the visible one).
    ///
    /// Anchoring to the TOP removes the viewport dependency: after `scroll_to_top` the viewport top is the
    /// OLDEST retained row, so EVERY command prompt lies at or below it and a POSITIVE (downward) delta
    /// counts them oldest→newest, independent of how many are currently on screen. The command prompts in
    /// oldest→newest order are `133;A` marks #1…#`total`; newest-first position `pos` is the
    /// `(total − pos)`-th prompt from the top (`pos = 0` = newest = the `total`-th; `pos = total − 1` =
    /// oldest = the 1st). The trailing live idle prompt is mark #`total + 1`, so a delta of `total − pos`
    /// (always in `1…total`) never reaches it. If the target prompt is itself inside the active area,
    /// ghostty pins the viewport to `.active` (it cannot scroll DOWN into the active area) — the target is
    /// still on screen, which is the correct landing.
    ///
    /// The SINGLE source of the delta math: ``toNavigatorPosition(_:totalBlocks:using:)`` and the Command
    /// Navigator's per-row jump (``WorkspaceStore/jumpToNavigatorBlockInActivePane(index:)``, which the
    /// `CommandNavigatorView` row calls) both route through this so the two can't drift.
    nonisolated static func jumpDelta(toTargetPos pos: Int, totalBlocks total: Int) -> Int {
        total - pos
    }

    /// Re-anchors to the top then jumps `actions` DOWN to newest-first navigator position `pos` (0 = newest)
    /// among `total` command blocks. The delta is always ≥ 1 (`total − pos` for `pos` in `0…total − 1`), so
    /// a jump is always issued after the re-anchor.
    nonisolated static func toNavigatorPosition(
        _ pos: Int,
        totalBlocks total: Int,
        using actions: TerminalSurfaceActions,
    ) {
        actions.performBindingAction("scroll_to_top")
        let delta = jumpDelta(toTargetPos: pos, totalBlocks: total)
        if delta != 0 { actions.performBindingAction("jump_to_prompt:\(delta)") }
    }
}

// MARK: - WorkspaceStore × Command Blocks (WB2 — Warp-style per-command blocks)

/// The WB2/WB3 active-pane Block ops, split into their own extension so the (already large)
/// ``WorkspaceStore`` body stays under the lint ceiling. They mirror
/// ``WorkspaceStore/requestFindInActivePane()``: resolve the active pane's live terminal model (in
/// whichever live model is active), then route to its block hooks.
public extension WorkspaceStore {
    /// The active pane's id in WHICHEVER live model is active — the tree's active pane on the IDE shell, the
    /// canvas focus on the retained-but-dead path. `nil` for an empty shell. Shared by the block ops that
    /// need the id (the jump-to-failed CURSOR is keyed by it).
    internal var activePaneID: PaneID? {
        switch liveModel {
        case .tree: tree.activeSession?.activeTab?.activePane
        case .canvas: focusedPane
        }
    }

    /// The active pane's live terminal model in WHICHEVER live model is active (W5): the tree's active pane
    /// on the IDE shell, the canvas focus on the retained-but-dead path. `nil` for a non-terminal active
    /// pane (`.remoteGUI` / `.systemDialog`) or an empty shell. Shared by the WB2 block ops so the
    /// navigator / jump work on both paths — and by the E1 ``WorkspaceStore+FontScroll`` hooks (font/scroll
    /// resolve the same active terminal model), so it is `internal` (cross-file) rather than `private`.
    internal var activeTerminalModel: TerminalViewModel? {
        guard let activeID = activePaneID,
              let provider = handle(for: activeID) as? TerminalModelProviding else { return nil }
        return provider.terminalModel
    }

    /// Opens the Command Navigator (WB2/E10 WI-10: ⌃⌘O / the chrome chip / a menu item) over the active pane —
    /// routes to its ``TerminalViewModel/onRequestBlockNavigator`` (wired by `TerminalLeafView`, which TOGGLES
    /// its per-pane `CommandNavigatorView` overlay). A no-op for a non-terminal active pane or an empty shell.
    /// The navigator's recent-blocks list is the PURE ``TerminalBlockModel`` (unit-tested).
    func requestBlockNavigatorInActivePane() {
        activeTerminalModel?.onRequestBlockNavigator?()
    }

    /// P5b: TOGGLES modal keyboard COPY-MODE over the active pane (the ⌘⇧C chord / Pane-menu "Copy Mode" entry).
    /// Drives the MODEL as the single source of truth — ``TerminalViewModel/enterCopyMode()`` /
    /// ``TerminalViewModel/exitCopyMode()`` (which flip `isCopyMode` and fire `onRequestCopyMode` so the overlay
    /// `@State` syncs FROM the model, never an independent inverting toggle). A no-op for a non-terminal active
    /// pane or an empty shell. The mode's keyboard dispatch is the PURE ``TerminalViewModel/handleCopyModeKey(_:)``
    /// (unit-tested). Resolves the active terminal model so copy-mode arms only on the focused pane.
    func requestCopyModeInActivePane() {
        guard let model = activeTerminalModel else { return }
        if model.isCopyMode {
            model.exitCopyMode()
        } else {
            model.enterCopyMode()
        }
    }

    /// Whether the pane `id` is currently in copy-mode — drives the "COPY" badge in ``PaneStatusBar``. Reads
    /// the OBSERVABLE ``TerminalViewModel/copyModeBadgeActive`` twin (NOT the keyDown-read `@ObservationIgnored`
    /// `isCopyMode`) so the badge re-renders reactively. Resolves the LIVE terminal model so pane A's copy-mode
    /// never lights pane B's badge (mirrors ``agentStatus(for:)``). `false` for a non-terminal / no-live-model
    /// pane.
    func isCopyMode(for id: PaneID) -> Bool {
        (handle(for: id) as? TerminalModelProviding)?.terminalModel?.copyModeBadgeActive == true
    }

    /// Jumps the active pane's viewport to the previous (`delta < 0`) / next (`delta > 0`) shell prompt —
    /// WB2's ⌃⌘[ / ⌃⌘] (and the navigator's per-row jump). Routes to libghostty's `jump_to_prompt:<delta>`
    /// via the active surface's ``TerminalSurfaceActions`` seam (the same lever W14's jump-to-prompt uses).
    /// A no-op for a non-terminal pane, an empty shell, or a headless/placeholder surface (no seam).
    func jumpToBlockInActivePane(delta: Int) {
        guard let model = activeTerminalModel,
              let actions = model.surface as? TerminalSurfaceActions else { return }
        actions.performBindingAction("jump_to_prompt:\(delta)")
    }

    /// WB3 BOOKMARKS: seeds a freshly-materialized pane's ``TerminalBlockModel`` from persistence (keyed by
    /// the per-SESSION ``TerminalModelProviding/bookmarkScopeKey``, NOT the stable pane id — so a relaunch
    /// with a fresh block-index space starts with no stars instead of grafting stale indices onto unrelated
    /// commands) and wires its `onBookmarksChanged` to persist back on every toggle. A no-op for a
    /// non-terminal pane / when no persistence seam is wired (tests / previews keep bookmarks in-memory).
    /// Lives here (not in the main store body) so the store stays under the lint type-body ceiling.
    internal func seedBlockBookmarks(id _: PaneID, handle: any PaneSessionHandle) {
        guard let provider = handle as? TerminalModelProviding, let model = provider.terminalModel else { return }
        let scopeKey = provider.bookmarkScopeKey
        if let load = blockBookmarks.load { model.blocks.setBookmarks(load(scopeKey)) }
        if let save = blockBookmarks.save {
            model.blocks.onBookmarksChanged = { indices in save(scopeKey, Array(indices).sorted()) }
        }
    }

    // MARK: - WB3: Re-run last command

    /// Re-runs the active pane's LATEST captured command by re-injecting its text (verbatim, +1 newline)
    /// into the pane's shell via the normal input path (``TerminalViewModel/sendInput(_:)`` → wire type 3).
    /// A no-op if there is no terminal / no block / the command is empty (``BlockReRunEncoder`` returns
    /// `nil`). NOT gated on completion — re-running a still-running command's text is fine.
    func reRunLastCommandInActivePane() {
        guard let model = activeTerminalModel, let latest = model.blocks.latest,
              let bytes = BlockReRunEncoder.bytes(for: latest.commandText) else { return }
        model.sendInput(bytes)
    }

    /// Re-runs an EXPLICIT captured command `text` (the Open-Quickly **Current** filter's Command-row
    /// "Re-Run in Current Pane" action, E11 WI-6) by re-injecting it verbatim into the active pane's shell —
    /// the SAME ``BlockReRunEncoder`` verbatim-UTF-8 path ``reRunLastCommandInActivePane()`` uses (strip any
    /// trailing CR/LF, append exactly one `0x0A`; NEVER ``SendKeysParser``, so a literal `"<Enter>"` in the
    /// captured text can't be turned into a control byte — the injection-safety invariant). Distinct from
    /// the latest-block re-run only in that the caller names the command (a picked Current row, not the tail
    /// of the block list). A no-op when there is no live terminal pane or the command is empty/whitespace
    /// (the encoder returns `nil`). No wire change — funnels through ``TerminalViewModel/sendInput(_:)`` like
    /// ordinary keystrokes.
    func reRunCommandInActivePane(_ text: String) {
        guard let model = activeTerminalModel, let bytes = BlockReRunEncoder.bytes(for: text) else { return }
        model.sendInput(bytes)
    }

    // MARK: - WB3: Jump to previous / next FAILED block

    /// Jumps the active pane's viewport to the next (`forward`) / previous (`!forward`) FAILED block from
    /// the per-pane cursor (``WorkspaceStore/blockJumpCursor``), updating the cursor, via the SAME absolute
    /// re-anchor jump the navigator's per-row jump uses (``BlockJump``). Stops at the ends (no wrap). A
    /// no-op for a non-terminal pane / no failures / no surface seam.
    func jumpToFailedBlockInActivePane(forward: Bool) {
        guard let paneID = activePaneID, let model = activeTerminalModel,
              let actions = model.surface as? TerminalSurfaceActions else { return }
        let blocks = model.blocks.navigatorBlocks
        guard let target = BlockNavigation.adjacentFailed(
            in: blocks, fromIndex: blockBookmarks.jumpCursor[paneID], forward: forward,
        ), let pos = blocks.firstIndex(where: { $0.index == target.index }) else { return }
        blockBookmarks.jumpCursor[paneID] = target.index
        BlockJump.toNavigatorPosition(pos, totalBlocks: blocks.count, using: actions)
    }

    // MARK: - E9: Jump to a specific Outline block

    /// Jumps the active pane's viewport to the block with `index` — the Outline tab's per-row jump (E9), the
    /// ONE reuse of the shared absolute re-anchor jump (``BlockJump``) that the navigator's per-row jump +
    /// jump-to-failed also route through (so the delta math can't drift). Resolves the active terminal model
    /// + its ``TerminalSurfaceActions`` surface seam, finds `index`'s NEWEST-FIRST position in
    /// `navigatorBlocks`, and re-anchors there. A no-op for a non-terminal pane, an empty shell, a
    /// headless/placeholder surface (no seam), or an unknown / evicted `index` (never traps). Mirrors
    /// ``jumpToFailedBlockInActivePane(forward:)`` but addresses one explicit index (no cursor stepping).
    func jumpToNavigatorBlockInActivePane(index: UInt32) {
        guard let model = activeTerminalModel,
              let actions = model.surface as? TerminalSurfaceActions else { return }
        let blocks = model.blocks.navigatorBlocks
        guard let pos = blocks.firstIndex(where: { $0.index == index }) else { return }
        BlockJump.toNavigatorPosition(pos, totalBlocks: blocks.count, using: actions)
    }
}

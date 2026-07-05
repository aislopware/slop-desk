import Foundation
import os
import SlopDeskTerminal

// MARK: - CommandBlock → PeekBlockLine (the P4 peek "recent output" shape)

/// ``CommandBlock`` already carries the typed command line + a short status label, so it satisfies the
/// pure ``PeekBlockLine`` shape ``PeekContent/recentLines(from:limit:)`` reads — letting the peek DTO be
/// built off the live ``TerminalBlockModel`` while the builder itself stays free of an `SlopDeskTerminal`
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

/// The single absolute "jump the viewport to the block whose prompt ordinal is N" implementation
/// (WB2/WB3/E9), so the navigator's per-row jump and the store's jump-to-failed cannot drift on the
/// choreography. Pure over the ``TerminalSurfaceActions`` seam; `nonisolated` so both call sites reach it.
///
/// ## Why an ORDINAL, not a "position among the blocks"
/// libghostty's `scrollPrompt` (ghostty `PageList.zig`, pinned v1.3.1) counts `.prompt` ROWS — one per
/// OSC-133 `A` mark — which includes prompt cycles that never became a block (an empty Enter / Ctrl-C
/// runs precmd and re-fires `A` but the segmenter rightly discards the blockless cycle). A delta computed
/// from the block COUNT therefore under-counts by every such cycle and lands on an older command. The
/// host stamps each block with its ``CommandBlock/promptOrdinal`` (the 1-based `A`-cycle count at the
/// block's start) so the jump counts exactly what ghostty counts.
///
/// ## Why anchor with a HUGE NEGATIVE jump, not `scroll_to_top`
/// For a downward (positive) delta ghostty starts its `PromptIterator` at `viewport_top.down(1)` — the
/// prompt ON the viewport-top row itself is never counted. After `scroll_to_top` the top row may or may
/// not be a prompt row (in a fresh pane the shell's FIRST prompt IS row 0; after a banner or ring
/// eviction it is not), so a top-anchored count is off by one in the common fresh-pane case and the
/// client cannot know which case holds. A `jump_to_prompt:` with a negative delta LARGER than the prompt
/// count instead exhausts the upward iterator and ghostty moves the viewport to the LAST prompt found —
/// the OLDEST retained prompt row. That makes "the viewport top IS prompt row #1" an invariant, so a
/// downward delta of `k` deterministically lands prompt row #(k + 1): delta `ordinal − 1` lands the
/// block's own prompt row (no second jump for ordinal 1 — the anchor already landed on it). A target
/// inside the active area pins the viewport to `.active` (ghostty cannot scroll DOWN into it) — the
/// target is on screen, the correct landing. `scroll_to_bottom` first makes the anchor state
/// deterministic regardless of where the user had scrolled.
///
/// Degradation: if ghostty's scrollback RING has evicted the earliest prompts, the oldest RETAINED
/// prompt is no longer ordinal #1 and the landing shifts by the evicted count — the long-session edge;
/// every jump in a normal session lands exactly.
enum BlockJump {
    /// Larger than any real scrollback's prompt count — exhausts ghostty's upward `PromptIterator` so
    /// the viewport pins to the OLDEST retained prompt row (see the type doc).
    ///
    /// MUST fit ghostty's binding parameter type: `jump_to_prompt` is declared `i16` (`Binding.zig`,
    /// pinned v1.3.1), so any |delta| > 32768 fails the ACTION-STRING PARSE and the whole binding
    /// silently no-ops — the jump then degenerates to bare `scroll_to_bottom` (the first shipped value,
    /// 1_000_000, did exactly that on hardware). 32_000 is comfortably inside `i16` while still far
    /// beyond any retained scrollback's prompt count.
    nonisolated static let reAnchorDelta = 32000

    /// The largest single DOWNWARD `jump_to_prompt` step that fits ghostty's binding parameter.
    ///
    /// `jump_to_prompt` is declared `i16` (`Binding.zig`, pinned v1.3.1 — max 32767), so a single step
    /// whose delta exceeds that fails the ACTION-STRING PARSE and silently no-ops the WHOLE binding — the
    /// exact i16 trap the anchor delta hit in 84b2cf3. The step delta is `ordinal − 1`, which is unbounded
    /// (a long-lived detached session stamps ever-growing prompt ordinals — every Enter counts), so past
    /// ordinal 32768 the raw step would silently land on the anchor (oldest prompt) instead of the target.
    /// A step beyond this bound is therefore SPLIT into multiple in-range hops: each positive
    /// `jump_to_prompt` re-counts from the NEW viewport-top's `down(1)` (that row's own prompt is never
    /// re-counted), so consecutive hops COMPOSE to the full delta and land the exact prompt — saturation
    /// would land short, chunking lands true. 32000 matches the re-anchor magnitude and stays inside i16.
    nonisolated static let maxStep = 32000

    /// Anchors on the oldest retained prompt row, then jumps `actions` DOWN to 1-based prompt ordinal
    /// `ordinal`. `0` (unknown — a mid-stream join stamped no ordinal) is a graceful no-op: better no
    /// jump than a mis-landing. The `ordinal − 1` downward delta is emitted as one or more in-range hops
    /// (see ``maxStep``) so an ordinal beyond ghostty's i16 range still lands exactly instead of no-opping.
    nonisolated static func toPromptOrdinal(_ ordinal: UInt32, using actions: TerminalSurfaceActions) {
        guard ordinal >= 1 else {
            debugLog("jump SKIPPED: ordinal 0 (mid-stream join — host stamped no prompt ordinal)")
            return
        }
        let anchor1 = actions.performBindingAction("scroll_to_bottom")
        let anchor2 = actions.performBindingAction("jump_to_prompt:-\(reAnchorDelta)")
        var remaining = Int(ordinal) - 1
        var stepsOK = true
        var hops: [Int] = []
        while remaining > 0 {
            let hop = Swift.min(remaining, maxStep)
            hops.append(hop)
            if !actions.performBindingAction("jump_to_prompt:\(hop)") { stepsOK = false }
            remaining -= hop
        }
        // A `false` from a REAL surface (an out-of-range/rejected delta, or a headless/placeholder surface)
        // means the viewport did NOT move to the target. Surface it at DEFAULT log level — not only the
        // debug-gated trace — so a silently-failed navigator / Jump-to-Failed jump is diagnosable in the
        // field without setting SLOPDESK_BLOCKS_DEBUG. (The recording test surface always returns true.)
        if !anchor1 || !anchor2 || !stepsOK {
            log.error("command jump did not land (binding no-op): ordinal=\(ordinal, privacy: .public)")
        }
        debugLog(
            "jump ordinal=\(ordinal): scroll_to_bottom=\(anchor1) "
                + "anchor(-\(reAnchorDelta))=\(anchor2) steps=\(hops)=\(stepsOK)",
        )
    }

    /// Default-level diagnostics for a jump that failed to move the viewport (see ``toPromptOrdinal``).
    private nonisolated static let log = Logger(subsystem: "com.slopdesk.workspace", category: "blocks")

    /// stderr diagnostics for the jump choreography, gated by `SLOPDESK_BLOCKS_DEBUG == "1"`
    /// (default-OFF) — the launch-from-terminal debugging seam (`SLOPDESK_VIDEO_DEBUG` idiom).
    private nonisolated static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["SLOPDESK_BLOCKS_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[blocks] \(message)\n".utf8))
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

    /// Copies the active pane's captured output for block `index` — the Command Navigator's per-row
    /// "Copy Output" affordance — by routing to the active terminal model's
    /// ``TerminalViewModel/copyBlockOutput(index:onResult:)`` (wire type 15 → 29, VT-stripped to plain
    /// text). `onResult` receives the plain text on success or `nil` when there is no live terminal pane /
    /// the block was evicted / disconnected (the caller shows a brief "output unavailable" and NEVER hangs).
    /// The headless core owns no `NSPasteboard`, so the CALLER does the clipboard write — this is the SAME
    /// request path the terminal context menu's "Copy Command Output" uses (no wire change). Resolving the
    /// active model here (not passing one in) keeps the copy on the focused pane, mirroring the jump ops.
    func copyBlockOutputInActivePane(index: UInt32, onResult: @escaping (String?) -> Void) {
        guard let model = activeTerminalModel else {
            onResult(nil)
            return
        }
        model.copyBlockOutput(index: index, onResult: onResult)
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
        ) else { return }
        blockBookmarks.jumpCursor[paneID] = target.index
        BlockJump.toPromptOrdinal(target.promptOrdinal, using: actions)
    }

    // MARK: - E9: Jump to a specific Outline block

    /// Jumps the active pane's viewport to the block with `index` — the Commands-panel per-row jump
    /// (E9, now merged into the Info tab), the ONE reuse of the shared absolute re-anchor jump
    /// (``BlockJump``) that the navigator's per-row jump + jump-to-failed also route through (so the
    /// choreography can't drift). Resolves the active terminal model + its ``TerminalSurfaceActions``
    /// surface seam and jumps to the block's host-stamped ``CommandBlock/promptOrdinal``. A no-op for a
    /// non-terminal pane, an empty shell, a headless/placeholder surface (no seam), an unknown / evicted
    /// `index`, or an ordinal-less block (never traps, never mis-lands). Mirrors
    /// ``jumpToFailedBlockInActivePane(forward:)`` but addresses one explicit index (no cursor stepping).
    func jumpToNavigatorBlockInActivePane(index: UInt32) {
        guard let model = activeTerminalModel,
              let actions = model.surface as? TerminalSurfaceActions,
              let block = model.blocks.block(at: index) else { return }
        BlockJump.toPromptOrdinal(block.promptOrdinal, using: actions)
    }
}

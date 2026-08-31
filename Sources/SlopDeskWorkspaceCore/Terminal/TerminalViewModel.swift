import CSlopDeskFFI
import Foundation
import SlopDeskClaudeCode
import SlopDeskClient
import SlopDeskProtocol
import SlopDeskWorkspaceModel
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The per-pane OSC 9;4 PROGRESS mirror read by the tab badge resolver, macOS Dock aggregate, and
/// pane status strip. A pure value from the VALIDATED ``ProgressState`` + clamped percent; ``ProgressState/clear``
/// maps to the ABSENCE of progress (`nil`), not a case here. Lives next to ``TerminalViewModel`` (whose
/// observable `progress` holds it) so resolver / store / Dock share one vocabulary and can't drift.
public enum PaneProgress: Equatable, Sendable {
    /// OSC 9;4;3 — an indeterminate / busy spinner (no meaningful percent).
    case indeterminate
    /// OSC 9;4;1;<pct> — a DETERMINATE value (0…100), the taskbar-style percent readout.
    case determinate(percent: UInt8)
    /// OSC 9;4;2[;<pct>] — an ERROR (held red); `percent` is the value at which it failed.
    case error(percent: UInt8)

    /// Builds the per-pane mirror from a VALIDATED wire `(state, percent)`. ``ProgressState/clear`` returns
    /// `nil` (no indicator); every other state maps to its value. `percent` is already clamped 0…100 host-side
    /// (``ProgressOSCParser``); no float math here.
    public init?(state: ProgressState, percent: UInt8) {
        switch state {
        case .clear: return nil
        case .inProgress: self = .determinate(percent: percent)
        case .error: self = .error(percent: percent)
        case .indeterminate: self = .indeterminate
        }
    }

    /// Whether this is an ACTIVE running state (indeterminate spinner / determinate bar), not an error. Drives
    /// the ``TabBadgeResolver`` "running" tier; an error sits at the higher error tier, so this is `false` for
    /// ``error``.
    public var isRunning: Bool {
        switch self {
        case .indeterminate,
             .determinate: true
        case .error: false
        }
    }
}

/// The terminal screen's view-model: it consumes a ``SlopDeskClient``'s `output` byte stream +
/// `events` and projects connection / title / exit / byte-count state for the two imperative shells.
///
/// It is the bridge between the actor world (`SlopDeskClient`) and the UI: ``ConnectionViewModel``
/// owns a `Task` that calls ``observe(client:)``, which drains the output stream and folds it into
/// `@Observable` properties. Nothing here draws — the readers are the leaves' and the chrome's
/// `withObservationTracking` arms (`MacTerminalLeafView` / `TerminalLeafView` and the rollups above
/// them), each of which RE-ARMS from its own handler, since `withObservationTracking` fires exactly
/// once per arm. The terminal **pixels** are produced by the ``SlopDeskTerminal/TerminalSurface``
/// the view-model feeds (`TerminalSurfaceDriver` in the app target, or `nil` in the
/// headless/placeholder case) — the view-model never parses VT itself; `libghostty-vt` does.
///
/// `@MainActor` so it is safe to mutate from the shells and to drive a `@MainActor` surface — which
/// the surface must be, because a `libghostty-vt` handle is `!Send`/`!Sync` with no lock of its own;
/// `@Observable` so a tracked arm is woken by a change instead of polling.
@preconcurrency
@MainActor
@Observable
public final class TerminalViewModel {
    /// High-level connection lifecycle the UI surfaces (terminal screen + status chrome).
    public enum ConnectionStatus: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
        case disconnected(reason: String)
        case exited(code: Int32)

        public var label: String {
            switch self {
            case .idle: "idle"
            case .connecting: "connecting"
            case .connected: "connected"
            case .reconnecting: "reconnecting"
            case .disconnected: "disconnected"
            case let .exited(code): "exited(\(code))"
            }
        }

        /// True while we believe the byte pipeline is live.
        public var isLive: Bool { self == .connected }
    }

    /// Per-pane SHELL activity (OSC 133), ORTHOGONAL to ``ConnectionStatus``: a pane is `.connected` AND
    /// either `.idle` (at the prompt) or `.running` (a command executing). Separate from ``ConnectionStatus``
    /// so the connection colour (green) and the running cue (amber pulse) can both show at once.
    public enum ShellActivity: Sendable, Equatable { case idle
        case running
    }

    // MARK: Observable state

    /// The connection lifecycle (drives the status chrome + placeholder telemetry).
    public private(set) var connectionStatus: ConnectionStatus = .idle
    /// The window/terminal title (OSC 0/2), if the host sent one.
    public private(set) var title: String?
    /// Authoritative session id, learned on first connect / preserved across reconnects.
    public private(set) var sessionID: UUID?
    /// Total bytes of `output` delivered (build-status telemetry; not a render).
    public private(set) var bytesReceived: Int = 0
    /// Most recent resume point surfaced by a `.reconnected` event (diagnostics).
    public private(set) var lastResumeSeq: Int64 = 0
    /// Set when the remote rang the bell since the last clear (the view can flash).
    public private(set) var bellPending: Bool = false
    /// Shell activity (OSC 133): `.running` while a command executes, `.idle` at the prompt.
    /// Drives the pane's running indicator. Independent of ``connectionStatus``.
    public private(set) var shellActivity: ShellActivity = .idle
    /// The most recently FINISHED command (OSC 133;D): its exit code (nil if not reported) and the
    /// host-measured duration in ms. Read by the header/tooltip + the long-command notification trigger.
    /// `nil` until the first command completes.
    public private(set) var lastCommand: (exitCode: Int32?, durationMS: UInt32)?

    /// The per-pane OSC 9;4 PROGRESS mirror (wire type 32): `nil` when there is no active indicator
    /// (a `9;4;0` clear, or none ever reported), else the determinate / indeterminate / error state. OBSERVABLE
    /// so the pane status strip + macOS Dock aggregate update reactively. ``WorkspaceStore`` ALSO holds a
    /// per-pane mirror (`paneProgress`, same `.progress` event) feeding the sidebar tab badge + Dock rollup;
    /// this VM-local copy is the status-strip source. Set on a `.progress` event in ``handle(_:)`` (state
    /// validated at the client boundary), cleared on exit / drop / reconnect so a dead shell can't leave a
    /// stuck spinner.
    public private(set) var progress: PaneProgress?

    /// The per-pane Warp-style "Blocks" store: the host's `commandBlock` metadata (wire type 28)
    /// folded into an ordered, bounded `[CommandBlock]`. Drives the Command Navigator, sticky command header,
    /// and chrome status chip. Captured output is fetched on demand (``copyBlockOutput(index:onResult:)``).
    /// Observed so the navigator/header re-render as blocks land.
    public let blocks = TerminalBlockModel()

    /// TRUE from the instant a COMMITTED resize forwards a CHANGED grid to the host (cols/rows differ) until
    /// the host's reflow bytes land (next ``ingestPass``) — the "resized content has re-rendered" signal the
    /// pane resize-scrim waits on. Replaces a fixed settle TIMER, which on a slow link clears the scrim BEFORE
    /// the ~1 RTT reflow arrives and briefly reveals the stretched / stale frame. The FIRST grid delivery after
    /// a (re)connect does NOT arm it (the surface paints from scratch — no stale frame to bridge); a disconnect
    /// / exit / reconnect and a safety timeout all clear it so it can never stick. Observed by the pane
    /// container (``SlopDeskMacUI/MacPaneContainer`` / ``SlopDeskPhoneUI/PaneContainerView``)
    /// (OR-ed with its geometry resize signal: geometry STARTS the scrim, this HOLDS it until fresh pixels land).
    public private(set) var awaitingResizeReflow = false

    // MARK: Wiring

    /// The terminal renderer the model feeds inbound bytes to. `nil` in the headless / placeholder case;
    /// the app target sets it to a `TerminalSurfaceDriver`, which drives `libghostty-vt`.
    ///
    /// `@ObservationIgnored`: WIRING, not view state — like ``inputSink`` / ``resizeSink`` / ``onRequestFocus``.
    /// It MUST NOT be observation-tracked, and the reason is the READ-THEN-WRITE in ``attachSurface(_:)``: it
    /// compares (`self.surface !== surface`) and then assigns, from inside `TerminalSurfaceDriver.bind(to:)`
    /// — the renderer's own mount path. Tracked, that pair is a self-invalidating cycle: any arm that read
    /// `surface` would be woken by the write its own re-arm provoked.
    ///
    /// ⚠️ THE IMPERATIVE SHELLS DID NOT RETIRE THIS. The hazard was first written against SwiftUI, where the
    /// same attach ran inside an AttributeGraph update and the cycle was body → `updateNSView` → `attach` →
    /// read+write → invalidate → ∞, a main-thread pin that read as a multi-second beachball on a focus change
    /// or a reconnect. `withObservationTracking` registers dependencies the SAME way, so an arm that read this
    /// would re-fire on every attach exactly as a body did; only the SHAPE of the wasted work changed (one
    /// re-armed handler instead of a whole re-render). Ignoring removes the dependency outright.
    ///
    /// Nothing needs it reactive either way: no leaf reads `surface` — the renderer view owns its own surface,
    /// and this is only the feed target.
    @ObservationIgnored public weak var surface: (any TerminalSurface)?

    /// OUT path sink: the encoded keystroke/escape bytes libghostty-vt emits from the renderer's `key`/`text`
    /// events (`TerminalSurfaceDriver.onWrite`). ``ConnectionViewModel`` sets this on connect to forward to the live
    /// ``SlopDeskClient/sendInput(_:)`` and clears it on teardown; while `nil` (disconnected) keystrokes are
    /// dropped — no host to receive them. The renderer routes `onWrite` here via ``sendInput(_:)``, decoupling
    /// view-attach timing from connect timing (the closure reads the latest sink at call time).
    /// `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var inputSink: ((Data) -> Void)?

    /// OUT path sink for grid resizes (cols/rows) the renderer derives from layout (`TerminalSurfaceDriver.setGeometry`).
    /// Same lifecycle as ``inputSink``: set on connect to forward to
    /// ``SlopDeskClient/sendResize(cols:rows:pxWidth:pxHeight:)`` (→ host `TIOCSWINSZ`), cleared on teardown.
    /// Wiring it (on connect) FLUSHES the latest grid the renderer derived: the view's first layout pass
    /// measures a grid — BEFORE `connect()` wires this sink — so those early
    /// grids would otherwise be lost and the host PTY would stay at its 80×24 init size while the surface renders
    /// the real grid (the garbled-render / overlapping-glyph bug: zsh wraps at 80 cols, fzf draws at row 24,
    /// but the surface is a different size). `didSet` delivers the pending size the instant a sink appears, so
    /// the host always learns the real grid even when no further resize happens after connect.
    @ObservationIgnored public var resizeSink: ((UInt16, UInt16) -> Void)? {
        didSet {
            // A freshly-wired sink means a (re)connect: the host PTY is at 80×24 and must be told the real
            // grid even if unchanged since last connection — clear the dedup memory and force a fresh delivery.
            if resizeSink != nil { lastSentSize = nil }
            deliverResizeIfNeeded()
        }
    }

    /// The latest grid the renderer derived, recorded UNCONDITIONALLY (even while disconnected, when
    /// there is no sink yet) so it can be flushed the moment ``resizeSink`` is wired on connect.
    @ObservationIgnored private var pendingSize: (cols: UInt16, rows: UInt16)?

    /// Last grid size actually FORWARDED through the sink, so a duplicate resize is coalesced — a window
    /// resize, a scale change and a font change can each land a `setGeometry` for one settled grid, and
    /// `TerminalSurfaceDriver` only suppresses the pair it can see.
    /// Only updated on a genuine delivery — a resize attempted while disconnected (sink nil) must NOT poison
    /// this, or the dedup would later suppress the real send once the sink is wired.
    @ObservationIgnored private var lastSentSize: (cols: UInt16, rows: UInt16)?

    /// While true, grid resizes are RECORDED (`pendingSize`) but NOT forwarded — the gate the shell raises
    /// during an interactive sidebar/inspector-divider drag. Dragging live-resizes the content column every
    /// cell-step; for a REMOTE terminal each forward is a host PTY reflow + re-streamed redraw, so we hold
    /// them and flush the FINAL grid ONCE on release (the commit-on-release rule the pane divider follows).
    /// Default off.
    @ObservationIgnored private var resizeDeliverySuspended = false

    /// Click-to-focus hook (macOS). `MacTerminalRendererView` installs `mouseDown`, and it
    /// is the DEEPEST view in the pane, so it wins the hit-test and the click never reaches any focus handler
    /// an ancestor might install — a click would start a libghostty-vt selection but NOT focus the pane (no focus
    /// ring, keyboard stuck on the old pane). The renderer calls this at the TOP of `mouseDown`; the leaf wires
    /// it to `store.focus(paneID)` so the click ALSO transfers workspace focus. `@ObservationIgnored`: wiring,
    /// not view state. Nil for headless callers (no store), never invoked.
    @ObservationIgnored public var onRequestFocus: (() -> Void)?

    /// Pans the CANVAS by a (sign-adjusted) delta when an ⌥-scroll lands on this terminal. A plain scroll
    /// always goes to the pane's OWN scrollback — scroll follows the pointer, not focus, so a background
    /// pane can be read/compared without stealing focus — and ⌥ is the deliberate canvas-pan route
    /// (mirroring the GUI pane's ⌥ escape hatch). The renderer's `scrollWheel` calls this when ⌥ is held;
    /// the leaf wires it to the store's camera pan. `@ObservationIgnored`: wiring, not view state. Nil for
    /// headless/preview callers (never invoked).
    @ObservationIgnored public var onCanvasScroll: ((CGSize) -> Void)?

    /// Synchronized-input tap (tmux `synchronize-panes`). When set, every OUT chunk this pane sends (macOS
    /// surface keystrokes AND iOS input-bar submits both funnel through ``sendInput(_:)``) is also offered here
    /// so the store can MIRROR it into the tab's other panes. The store's closure decides whether sync is
    /// armed for the tab and which siblings receive it (and guards re-entry, so mirroring into a sibling does
    /// not loop back). Local delivery via ``inputSink`` is unchanged. `@ObservationIgnored`: wiring, not view
    /// state. Nil
    /// for headless/preview callers (never invoked).
    @ObservationIgnored public var syncInputTap: ((Data) -> Void)?

    /// The terminal right-click menu's "Split Right / Split Down" item — the renderer's `menu(for:)`
    /// calls this with the chosen axis; the leaf wires it to `store.splitPaneTree(paneID, …)`. `true` =
    /// horizontal (side-by-side), `false` = vertical (stacked). `@ObservationIgnored`: wiring, not view state.
    /// Nil for headless/preview callers (never invoked).
    @ObservationIgnored public var onContextMenuSplit: ((_ horizontal: Bool) -> Void)?

    /// The ⌘click / right-click "Open" action on a detected PATH — the file lives on the
    /// HOST Mac, so the renderer resolves ``LinkActionPolicy`` to ``LinkAction/openHost(_:)`` and fires this
    /// with the resolved absolute path; the leaf wires it to the host open RPC (the `openPath`
    /// ``MetadataVerb`` over the existing metadata channel). `nil` until the host performer lands, so
    /// open-on-host is a graceful no-op (copy / cd / URL still work). `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onRequestOpenHostPath: ((_ path: String) -> Void)?

    /// The ⌘click / Hint-to-Open / Jump-To "Open" action on a detected PATH — routed to the
    /// EMBEDDED VS Code workbench (``LinkAction/openCodeHost(_:)`` → the `openInCodeServer`
    /// ``MetadataVerb``), because the editor the user is looking at is the client's code panel, not
    /// the host's screen. `target` keeps the detector's `:line[:col]` suffix (code-server jumps to
    /// it). `nil` ⇒ a graceful no-op. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onRequestOpenCodeHostPath: ((_ target: String) -> Void)?

    /// The ⌘⇧click / right-click "Reveal in Finder" action on a detected PATH —
    /// host-side `activateFileViewerSelecting`, so the renderer fires this with the resolved absolute path
    /// and the leaf wires it to the host reveal RPC (`revealPath` ``MetadataVerb``). `nil` until
    /// the host performer lands ⇒ a graceful no-op. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onRequestRevealHostPath: ((_ path: String) -> Void)?

    /// ONE clipboard verb, asked for from OUTSIDE the renderer — the iPad's ⌘C / ⌘X / ⌘V / ⌘A.
    ///
    /// The verbs themselves are not new and are not duplicated here: the renderer already runs every
    /// ``TerminalContextMenu/Item`` for its long-press menu, paste-protection pre-check and all, and
    /// this hands that dispatcher one item. What is new is the CALLER. On macOS these four chords
    /// arrive as AppKit responder selectors (`copy:`/`cut:`/`paste:`/`selectAll:`) on the terminal
    /// view, which IS the window's first responder; on iOS the pane's first responder is
    /// `SlopDeskPhoneUI.TerminalInputHostView` — a zero-sized sibling — so the standard editing
    /// actions land on a view that owns no surface, and the renderer that owns the surface is not in
    /// the chain at all. Four chords a phone user has in every other app were therefore dead in the
    /// one pane the app exists for. This is the seam that closes that, and it stays a seam rather
    /// than a second implementation: the phone sends an ITEM, the renderer runs it.
    ///
    /// `nil` for headless/preview callers (never invoked). `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onRequestMenuItem: ((TerminalContextMenu.Item) -> Void)?

    /// The ⌘F / right-click "Find…" action — opens the find-in-terminal bar over THIS pane. The
    /// renderer's menu (and the `find:` responder selector) call it; the leaf's `TerminalPaneWiring`
    /// binds it to the pane's `TerminalFindBarModel` on attach and clears it on detach, so a torn-down
    /// leaf cannot drive a dead bar. `@ObservationIgnored`: wiring, not view state. Nil for headless
    /// callers.
    @ObservationIgnored public var onRequestFind: (() -> Void)?

    /// The ⌘G "Find Next" / ⇧⌘G "Find Previous" actions — advance / retreat the find bar's match
    /// over THIS pane (and OPEN the bar when closed). The leaf's `TerminalPaneWiring` binds these to the
    /// pane's `TerminalFindBarModel` (next()/previous() + the libghostty-vt `navigate_search:` highlight);
    /// the store reaches them via
    /// ``WorkspaceStore/requestFindNextInActivePane()`` / `requestFindPrevInActivePane()`, falling back to
    /// ``onRequestFind`` when unset so ⌘G still opens the bar. `@ObservationIgnored`: wiring, not view state.
    /// Nil for headless/preview callers (never invoked).
    @ObservationIgnored public var onRequestFindNext: (() -> Void)?
    @ObservationIgnored public var onRequestFindPrev: (() -> Void)?

    /// Fired ONCE per RECONNECT the instant the fresh-vs-resumed verdict resolves
    /// (``SlopDeskClient/SessionResumeOutcome``) — `.resumedSession` (same live shell reattached,
    /// scrollback/history intact) or `.freshShell` (fresh shell; the previous session ended). ``ConnectionViewModel``
    /// forwards it to the store, which surfaces a small transient toast so the user knows WHICH happened (a
    /// silent fresh shell otherwise loses context with no signal). Gated to a real reconnect
    /// (``markReconnecting``) — a first-ever connect / deliberate ``reset`` never notifies, so the toast is
    /// never a launch surprise. `@ObservationIgnored`: wiring, not view state; nil for headless/preview callers.
    @ObservationIgnored public var onResumeOutcomeResolved: ((SlopDeskClient.SessionResumeOutcome) -> Void)?

    /// Find + global search surface seams over the active ``TerminalSurfaceActions`` conformer: the
    /// scrollback mirror the find bar / global search scan, and the passthrough to the surface's own
    /// search bindings (`search:`/`navigate_search:`/`end_search`/`scroll_to_row`, which own the amber
    /// highlight + scroll-to-match). A headless / preview surface does NOT conform (hang-safety — never
    /// instantiated in a test) → `[]` / `false`. Wiring funcs (read `surface as? TerminalSurfaceActions`,
    /// the copy-mode pattern), NOT `@Observable` state.
    ///
    /// Each line carries the screen rows it occupies, so a caller that matched line N scrolls to
    /// `lines.row(forLine: N)` rather than estimating one — see ``TerminalScrollbackLine``.
    public func searchScrollbackLines() -> [TerminalScrollbackLine] {
        (surface as? TerminalSurfaceActions)?.scrollbackLines() ?? []
    }

    @discardableResult
    public func performSearchSurfaceAction(_ action: String) -> Bool {
        (surface as? TerminalSurfaceActions)?.performBindingAction(action) ?? false
    }

    /// Runs the ⌘F bar's query — all four modes — on the surface and answers the hit count.
    ///
    /// The one search door that is not a binding-action string, because the grammar carries a needle
    /// and this carries the three toggles beside it. `0` on a headless surface, which is the same
    /// nothing every other passthrough here degrades to. See
    /// ``TerminalSurfaceActions/find(_:caseSensitive:wholeWord:isRegex:)``.
    public func findInSurface(
        _ query: String,
        caseSensitive: Bool,
        wholeWord: Bool,
        isRegex: Bool,
    ) -> Int {
        (surface as? TerminalSurfaceActions)?
            .find(query, caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: isRegex) ?? 0
    }

    /// The surface's current hit as the one-based `(index, total)` the counter prints, or `nil`.
    public func surfaceFindPosition() -> (current: Int, total: Int)? {
        (surface as? TerminalSurfaceActions)?.findPosition()
    }

    /// Find bar close → return keyboard focus to the surface: `installTerminalRenderer()` wires this when it
    /// builds the host, so the pane's renderer view re-claims the window's first responder. Needed because closing the find bar
    /// tears down the focused query `TextField` WITHOUT any workspace-focus change — the surface's own reclaim
    /// paths (`isFocusedPane` didSet, mount, mouseDown, focus-follows-mouse) all gate on a focus TRANSITION or a
    /// click, none of which fire here, so the window would otherwise stay first responder and keystrokes go
    /// nowhere until the pane is clicked. `nil` for headless / preview callers (no renderer) →
    /// ``reclaimKeyboardFocus()`` is a no-op. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onReclaimKeyboardFocus: (() -> Void)?

    /// Ask the live surface to re-claim the keyboard first responder (the find bar just closed without a
    /// workspace-focus change). No-op on a headless / preview model (``onReclaimKeyboardFocus`` unset).
    public func reclaimKeyboardFocus() { onReclaimKeyboardFocus?() }

    /// The PURE keybinding interceptor (the override-aware single-chord table) the renderer view's
    /// `keyDown` consults BEFORE handing the press to the engine. The store wires it (in
    /// `wireMaterializedLeaf`) so a rebindable ⌘D/⌘⇧D split is owned by the shared table rather than a
    /// hard-coded split branch. `nil` for headless/preview callers (no store), where every press goes
    /// straight to the engine.
    /// `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var keyInterceptor: TerminalKeyInterceptor?

    /// Fired the instant an interactive resize ENDS — i.e. ``setResizeSuspended(false)`` flushes the
    /// settled grid to the host. The renderer wires it to RE-ARM its post-resize present burst.
    ///
    /// Why this is needed (the intermittent doesn't-re-render-after-the-drag-ends race): the renderer keeps the
    /// size-unconditional sync-present path alive for a bounded window (~400 ms) ANCHORED to its last
    /// `layout()`, so a late reflow frame / late host-redraw bytes get painted after the initial present ticks
    /// drain. But with the live-resize design the host `TIOCSWINSZ` is DEFERRED to release — so the host's
    /// SIGWINCH-driven redraw bytes arrive ~1 RTT AFTER release, possibly LATER than the layout-anchored burst
    /// (the final layout often even hits the renderer's same-size guard and arms no fresh burst). Once the burst
    /// expires, those bytes' only present is a one-shot `requestPresent`, which can drain before the reflowed
    /// grid has been rasterized → the pane stays blank/stale until the next content event.
    /// Re-arming the burst at the FLUSH moment (here) anchors the keep-alive window to the release, covering the
    /// RTT until the reflow bytes land and rasterize. `@ObservationIgnored`: wiring, not view state. Nil for
    /// headless/preview callers (never invoked).
    @ObservationIgnored public var onResizeSettled: (() -> Void)?

    // MARK: Copy-mode (modal keyboard scrollback navigation)

    /// TRUE while this pane is in modal keyboard COPY-MODE (tmux/zellij parity): every keystroke this pane's
    /// `keyDown` sees is routed through ``handleCopyModeKey(_:)`` (navigation / search / copy / exit) instead
    /// of forwarded to the shell. VIEW state, NOT persisted (mirrors `isFindPresented`): `@ObservationIgnored`
    /// because the keyDown intercept READS it from inside the renderer's own event path, which also WRITES
    /// it — so it must register no Observation dependency at all (the read-then-write cycle documented on
    /// ``surface``). The overlay reads the observable ``copyModeBadgeActive`` twin below instead.
    @ObservationIgnored public var isCopyMode = false {
        didSet { copyModeBadgeActive = isCopyMode }
    }

    /// OBSERVABLE mirror of ``isCopyMode`` for the mode badge. ``isCopyMode`` itself is
    /// `@ObservationIgnored` because the keyDown intercept reads it from inside the renderer's own event
    /// path, which also writes it (the self-invalidating cycle documented on ``surface``). The vi /
    /// copy-mode pill — `MacViModePill` on the Mac, `ViModePillView` on the phone — tracks THIS twin from
    /// its overlay's `withObservationTracking` arm instead, and gets a wake-up per real flip. Kept in
    /// lock-step by ``isCopyMode``'s `didSet`.
    public private(set) var copyModeBadgeActive = false

    /// The most recent clipboard-copy receipt — OBSERVABLE: the pane's transient `COPIED · N` chip
    /// Every pane-scoped copy path lands here via ``noteClipboardCopy(_:)``: the copy-mode `y`/Enter yank,
    /// the renderer's ⌘C / OSC-52 standard-clipboard write (via the surface's clipboard-write hook),
    /// and the navigator / hint-mode / Jump-To copy actions.
    ///
    /// ⚠️ The CHIP that renders this does not live in the pane any more (user-directed 2026-08-11). The
    /// state stays here — it is the pane's — but the mount is `IslandChipStack`, at the island's foot,
    /// reached through `WorkspaceStore.activePaneCopyReceipt()`, so a copy has ONE home wherever it starts.
    public private(set) var copyReceipt: CopyReceipt?

    /// Per-copy monotonic counter — gives each receipt a fresh identity so a rapid re-copy restarts
    /// the chip's dwell instead of expiring on the old timer. The dwell used to be a `.task(id:)` keyed
    /// on this counter; it is now a one-shot `Timer` in `MacIslandChipStack` / `IslandChipStackView`,
    /// restarted whenever the applied identity changes.
    ///
    /// ⚠️ THE MOUNT DOES NOT KEY ON THIS ALONE, and must not be "simplified" to. Two independent owners
    /// publish receipts — this pane model and `OverlayCoordinator`, each with its OWN counter — so two
    /// different copies can carry the same epoch, and a chip keyed on the number would inherit the dead
    /// one's nearly-elapsed timer: the exact bug the epoch exists to prevent, arriving by a new door. The
    /// chip therefore keys on the WHOLE ``CopyReceipt``; the epoch's job is only to keep two copies of
    /// the SAME text distinguishable, which the text alone cannot do.
    @ObservationIgnored private var copyReceiptEpoch = 0

    /// Records that `text` just landed on the clipboard: publishes a fresh ``CopyReceipt``, which IS the
    /// confirmation — the chip renders it and its epoch restarts the dwell. RECORD-only: the pasteboard
    /// write itself stays at the call site (libghostty-vt writes internally; ``copyToPasteboard`` for ours).
    /// Empty text is a no-op (nothing was copied ⇒ nothing to confirm).
    public func noteClipboardCopy(_ text: String) {
        guard !text.isEmpty else { return }
        copyReceiptEpoch += 1
        copyReceipt = CopyReceipt(text: text, epoch: copyReceiptEpoch)
    }

    /// Dismisses the copy receipt — called by the chip when its dwell elapses. Idempotent.
    public func clearCopyReceipt() {
        copyReceipt = nil
    }

    // MARK: Prompt-jump landed flash (the ⌘PageUp/⌘PageDown orientation cue)

    /// Bumped once per CONFIRMED prompt-jump landing — OBSERVABLE: the pane's flash overlay
    /// (`PromptJumpFlashOverlay`) paints a one-shot ~240ms accent fade over viewport row 0 (where
    /// libghostty-vt PINS the jumped-to prompt) on each bump. The two-step arm/settle below keeps it
    /// honest: it fires only when a jump actually MOVED the viewport to a pinned prompt, never when
    /// the jump was a no-op or landed in the ACTIVE area (bottom clamp — the prompt is then NOT at
    /// row 0, so the flash is suppressed: absent, never wrong).
    public private(set) var promptJumpFlashEpoch = 0

    /// The arm instant of an issued-but-unsettled prompt jump. libghostty-vt reports the resulting
    /// viewport move asynchronously (the renderer's scrollbar action on the next frame), so the jump
    /// call arms this and the FIRST scrollbar change inside ``promptJumpSettleWindow`` settles it.
    @ObservationIgnored private var promptJumpArmedAt: ContinuousClock.Instant?

    /// How long an armed jump waits for its scrollbar echo before it lapses. Generous versus a frame
    /// (~16ms) yet far below human re-action time, so an unrelated LATER scroll can never claim a
    /// stale arm. Internal + settable so tests can force the lapse deterministically.
    @ObservationIgnored var promptJumpSettleWindow: Duration = .milliseconds(400)

    /// Arms the landed flash — called by the store's `jumpToBlockInActivePane` right after the
    /// `jump_to_prompt:` binding action ran. Idempotent per jump (a re-arm just refreshes the window).
    public func notePromptJumpIssued() {
        promptJumpArmedAt = ContinuousClock().now
        Self.flashDebugLog("armed")
    }

    /// One viewport-scroll report from the renderer (the surface's scrollbar hook). Settles a pending
    /// jump: inside the window and NOT bottom-clamped ⇒ the prompt is pinned at viewport row 0 ⇒ flash.
    /// `atBottom` (viewport == active area) means libghostty-vt could not pin the prompt to the top, so
    /// the row is unknown ⇒ no flash. Always disarms — one jump, at most one flash.
    public func noteViewportScroll(atBottom: Bool) {
        // A viewport move (wheel scroll, host output) shifts where the copy-mode cursor sits on
        // screen — re-derive the overlay cell from fresh truth (hides it when scrolled away).
        syncCursorOverlay()
        guard let armedAt = promptJumpArmedAt else {
            Self.flashDebugLog("echo atBottom=\(atBottom) — unarmed, ignored")
            return
        }
        promptJumpArmedAt = nil
        let elapsed = ContinuousClock().now - armedAt
        guard elapsed < promptJumpSettleWindow, !atBottom else {
            Self.flashDebugLog("echo consumed arm — elapsed=\(elapsed) atBottom=\(atBottom): SUPPRESSED")
            return
        }
        promptJumpFlashEpoch += 1
        Self.flashDebugLog("SETTLED — epoch \(promptJumpFlashEpoch)")
    }

    /// stderr diagnostics for the landed-flash arm/settle chain, through ``DebugTrace/blocks``
    /// (`SLOPDESK_BLOCKS_DEBUG == "1"`, default-OFF) — the same launch-from-terminal debugging flag the
    /// `BlockJump` choreography uses, so one env var traces a jump end-to-end (issue → arm → scrollbar
    /// echo → settle/suppress → paint). The `[flash]` tag is shared with the overlay's paint end, which
    /// is why both go through the funnel rather than each spelling the gate and the tag itself.
    private static func flashDebugLog(_ message: @autoclosure () -> String) {
        DebugTrace.blocks.write("flash", message())
    }

    /// The pasteboard write, injected so ``handleCopyModeKey`` stays PURE of any framework
    /// (unit-testable without a pasteboard). Tests override with a capturing closure.
    /// `@ObservationIgnored`: wiring, not view state.
    ///
    /// Deliberately NOT platform-gated. It used to be `#if canImport(AppKit)` around the one line,
    /// which on the phone made this an EMPTY closure — and every caller then raised the "COPIED"
    /// receipt anyway (``noteClipboardCopy``), so a phone yank reported a copy that had reached no
    /// pasteboard at all. ``ClientPasteboard/write(_:)`` is the cross-platform door and always was;
    /// the gate was scope, never necessity.
    @ObservationIgnored public var copyToPasteboard: (String) -> Void = { text in
        ClientPasteboard.write(text)
    }

    // MARK: Vi/copy-mode repeat-count + visual-mode (pure, NSEvent-free)

    /// The three vi visual-selection modes plus `.none` (plain scrollback navigation). Drives
    /// the vi-mode pill label (``SlopDeskMacUI/MacViModePill`` / ``SlopDeskPhoneUI/ViModePillView``) AND
    /// switches the line-motion handler from scroll (`scroll_page_lines`)
    /// to selection-EXTEND (`adjust_selection:<dir>`). Public so the GUI overlay reads ``viVisualMode``.
    public enum VisualMode: Equatable, Sendable {
        case none
        case char
        case line
        case block

        /// The mode's own index, which is what `slopdesk_ws_vi_mode_words` speaks in.
        public var index: UInt8 {
            switch self {
            case .none: 0
            case .char: 1
            case .line: 2
            case .block: 3
            }
        }

        /// The label ACTUALLY drawn, with `.none`'s fallback folded in.
        ///
        /// The `?? "VI"` used to be spelled at the pill, which made the enum's own answer incomplete:
        /// four cases, three labels, and the fourth left to whoever drew it. Two renderers is what
        /// turns that into a defect rather than a shrug — see docs/56 §2, and the fold now lives in
        /// `slopdesk_workspace::vi_hints::VisualMode::pill_label` where neither renderer can undo it.
        ///
        /// Four words, read once per process: the pill re-renders on every keystroke in vi mode.
        public var pillLabelOrDefault: String { Self.pillLabels[Int(index)] ?? "" }

        /// The four labels, in four crossings, once per process. Keyed by index, which is contiguous
        /// from zero.
        private static let pillLabels: [Int: String] = Dictionary(
            uniqueKeysWithValues: [Self.none, .char, .line, .block].map { mode in
                let blob = wsAnswerBytes { out, cap in
                    Int(slopdesk_ws_vi_mode_words(mode.index, 0, false, out, cap))
                }
                return (Int(mode.index), wsRuns(blob, count: 2)[0])
            },
        )

        /// Whether a SELECTION is being extended, as opposed to plain scrollback navigation.
        ///
        /// Named rather than left as `!= .none` at the call sites, because the two things it gates are
        /// not obviously the same question: the pill's outline goes loud, and the line-motion handler
        /// switches from `scroll_page_lines` to `adjust_selection:<dir>`.
        public var isVisual: Bool { self != .none }
    }

    /// The PURE copy-mode vi state: the pending repeat-count digits + the active visual mode. Free of
    /// `@Observable`/`NSEvent` so ``handleCopyModeKey(_:)`` (driven from the renderer keyDown event path)
    /// mutates it without registering an Observation dependency — same rationale as ``isCopyMode`` being
    /// `@ObservationIgnored`. The observable ``viPendingCount``/``viVisualMode`` mirrors (tracked by the pill's
    /// arm) are kept in lock-step by ``syncViObservables()`` after every key.
    struct CopyModeState: Equatable {
        /// `nil` = no count pending; otherwise the accumulated decimal repeat-count (vim left-to-right).
        var pendingCount: Int?
        /// The active visual-selection mode (or `.none` for plain navigation).
        var visualMode: VisualMode = .none
        /// The vi CURSOR in SCREEN coordinates (the E17 ceiling lift) — `nil` until the surface's
        /// ``TerminalSelectionControl`` seam yields a viewport readback (headless / legacy surfaces
        /// stay cursor-less and keep the scroll-only behavior). Re-clamped against fresh
        /// `viewportInfo()` on every motion, never trusted across keystrokes.
        var cursor: TerminalScreenPoint?
        /// The visual-selection ANCHOR (set where the cursor stood when `v`/`V`/`⌃v` entered a
        /// visual mode). `nil` outside a cursor-driven visual selection.
        var anchor: TerminalScreenPoint?
        /// vim's curswant — the DESIRED column a vertical motion tries to land on, remembered from
        /// the last horizontal motion (`Int.max` = a sticky `$`, so `j` keeps hugging line ends).
        /// `nil` until the first motion establishes one; every vertical landing clamps it to the
        /// landed row's TEXT extent so the cursor follows the text, never the bare grid.
        var wantColumn: Int?

        /// Hard ceiling on an accumulated count so a key-repeat / paste flood can't overflow `Int` or ask for
        /// an absurd scroll. 9999 is far past any real scrollback motion; the digit append clamps to it.
        static let maxCount = 9999

        /// Appends one decimal digit (vim `5` then `0` → 50), clamped to ``maxCount``.
        mutating func appendDigit(_ digit: Int) {
            pendingCount = min((pendingCount ?? 0) * 10 + digit, Self.maxCount)
        }

        /// Reads-AND-clears the pending count, defaulting to 1 (a bare motion = one step). The clear is why a
        /// count applies to exactly the NEXT motion, then evaporates (vim's count semantics).
        mutating func consumeCount() -> Int {
            defer { pendingCount = nil }
            return pendingCount ?? 1
        }
    }

    /// The pure repeat-count + visual-mode state. `@ObservationIgnored`: the keyDown event path mutates it;
    /// the pill reads the observable mirrors below (the ``isCopyMode``/``copyModeBadgeActive`` twin idiom).
    @ObservationIgnored private var copyModeState = CopyModeState()

    /// OBSERVABLE mirror of the pending repeat-count for the vi-mode pill's LIVE digits (e.g. `5` shows while
    /// the user types `5` before a motion). `nil` when no count is pending. Kept in lock-step with
    /// ``copyModeState`` by ``syncViObservables()``.
    public private(set) var viPendingCount: Int?

    /// OBSERVABLE mirror of the active visual mode for the vi-mode pill label (`VISUAL` / `VISUAL LINE` /
    /// `VISUAL BLOCK`). `.none` outside a visual selection. Kept in lock-step by ``syncViObservables()``.
    public private(set) var viVisualMode: VisualMode = .none

    /// The copy-mode cursor cell in VIEWPORT coordinates (row 0 = top visible row) for the
    /// block-cursor overlay, or `nil` when there is no cursor / it is scrolled off-viewport (the
    /// overlay then draws nothing — absent, never wrong). Recomputed from a FRESH
    /// ``TerminalSelectionControl/viewportInfo()`` readback after every copy-mode key AND on each
    /// renderer scroll echo (``noteViewportScroll(atBottom:)``), so a wheel scroll during copy-mode
    /// moves/hides the drawn cursor in lock-step with libghostty-vt truth.
    public struct ViCursorCell: Equatable, Sendable {
        public let col: Int
        public let row: Int
        /// The drawn block's width in CELLS — 2 on a wide (CJK/fullwidth) glyph so the block wears
        /// the whole character, 1 otherwise.
        public let width: Int

        public init(col: Int, row: Int, width: Int = 1) {
            self.col = col
            self.row = row
            self.width = width
        }
    }

    /// OBSERVABLE cursor-overlay cell (see ``ViCursorCell``). Kept current by ``syncCursorOverlay()``.
    public private(set) var viCursorCell: ViCursorCell?

    /// Vi-mode key-hint bar visibility (the `⌘/` reference card). Observable so the GUI
    /// hint bar shows/hides; toggled per copy-mode session via ``toggleViKeyHints()`` and reset on enter/exit
    /// (off by default — hints show on demand only).
    public private(set) var showViKeyHints = false

    /// `?` find-backward hook: the copy-mode `?` key opens the SAME find bar as `/` but biased BACKWARD so
    /// `n`/`N` step against the search direction (wired to `TerminalFindBarModel.open(backward:)`).
    /// Falls back to ``onRequestFind`` when unset, so `?` still opens the bar before the backward bias is
    /// wired. `@ObservationIgnored`: wiring, not view state. Nil for headless/preview callers.
    @ObservationIgnored public var onRequestFindBackward: (() -> Void)?

    /// Toggles the vi key-hint bar (the `⌘/` contextual binding while in copy-mode) by flipping the
    /// observable ``showViKeyHints``, which is what both halves' hint bars are gated on.
    public func toggleViKeyHints() {
        showViKeyHints.toggle()
    }

    /// Mirrors the pure ``copyModeState`` into the observable ``viPendingCount``/``viVisualMode`` twins so the
    /// pill redraws. Each is written ONLY on a real change — a guarded write, so a key that moved neither
    /// value wakes no tracked arm. That matters MORE under the imperative shells than it did: an arm that
    /// fires re-arms, so an echo write costs a full re-registration on every keystroke of a repeat count.
    private func syncViObservables() {
        if viPendingCount != copyModeState.pendingCount { viPendingCount = copyModeState.pendingCount }
        if viVisualMode != copyModeState.visualMode { viVisualMode = copyModeState.visualMode }
    }

    /// Clears ALL vi state (pending count + visual mode + key hints) and syncs the observable mirrors. Called
    /// on ``enterCopyMode()`` and ``exitCopyMode()``, so a re-entry always starts clean — no stale count carries
    /// into the next session and the hint bar defaults back off.
    private func resetViState() {
        copyModeState = CopyModeState()
        showViKeyHints = false
        syncViObservables()
    }

    /// An abstract key the copy-mode dispatch consumes — deliberately FREE of `NSEvent` so
    /// ``handleCopyModeKey(_:)`` is unit-testable without a window server (the renderer's `CopyModeKey(event:)`
    /// initializer maps the real `NSEvent` at the single NSEvent-aware point, excluded from tests).
    public enum CopyModeKey: Equatable, Sendable {
        /// A character key with its control/shift modifier state (Command-combos are app shortcuts, never
        /// reach here). `g` lower vs `G` upper arrive as distinct `Character`s; `shift` is belt-and-braces.
        case char(Character, control: Bool, shift: Bool)
        case up
        case down
        case left
        case right
        case escape
        case enter
    }

    #if canImport(AppKit)
    /// Maps a real `NSEvent` to the abstract ``CopyModeKey`` — the ONLY NSEvent-touching code (called from the
    /// app-target renderer's `keyDown`). Excluded from the pure unit tests (they build `CopyModeKey` cases
    /// directly). Special keys (Esc / Return / ↑ / ↓) are recognised by their `NSEvent` key codes; any other
    /// key collapses to a `.char` carrying its first character + control/shift state (Command-combos are app
    /// shortcuts intercepted upstream, never reaching the surface keyDown).
    ///
    /// Its ONLY caller is the renderer view in `Sources/SlopDeskTerminal/`, which registers itself through
    /// `TerminalRendererFactory`. It used to be the fork's embedder, outside every `Package.swift` target,
    /// which is why this note warned that a grep read the method as dead — `swift build` compiles the
    /// caller now, so it does not.
    public static func makeCopyModeKey(event: NSEvent) -> CopyModeKey {
        let control = event.modifierFlags.contains(.control)
        let shift = event.modifierFlags.contains(.shift)
        // Special keys by key code (53 = Escape, 36 = Return, 76 = keypad Enter, 126 = ↑, 125 = ↓,
        // 123 = ←, 124 = →).
        switch event.keyCode {
        case 53: return .escape
        case 36,
             76: return .enter
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        default: break
        }
        // `charactersIgnoringModifiers` keeps the layout base (and Shift, so `G` vs `g` is distinguished),
        // but strips Control's C0 folding so Ctrl-D reads as `d` not U+0004. Fall back to a NUL on no char.
        let char = event.charactersIgnoringModifiers?.first ?? "\u{0}"
        return .char(char, control: control, shift: shift)
    }
    #endif

    /// The PHONE peer of ``makeCopyModeKey(event:)`` — one `UIKey`, already read into the
    /// framework-neutral ``PhoneKey/Press``, as the same abstract ``CopyModeKey``.
    ///
    /// Deliberately NOT gated on the iOS triple, and it takes a `Press` rather than a `UIKey` for the
    /// reason ``PhoneKey`` itself is un-gated: a mapping only the iOS build compiles is a mapping the
    /// macOS test runner never touches, and this whole path spent a release drawing its pill over a
    /// dispatch that had no caller.
    ///
    /// Which key is Escape / Enter / an arrow is ``PhoneKey/modalKey(_:)`` — one projection of the
    /// ONE HID table, on the far side of the door. What is left here is the same collapse the Mac's
    /// adapter ends on: everything else becomes a `.char` carrying the layout base plus ⌃/⇧, and the
    /// pure dispatch reads its meaning. Both adapters are three lines of platform identity over one
    /// vocabulary, which is the only shape that keeps the vocabulary singular.
    public static func makeCopyModeKey(_ press: PhoneKey.Press) -> CopyModeKey {
        switch PhoneKey.modalKey(press) {
        case .escape: .escape
        case .enter: .enter
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        // Backspace binds nothing in copy mode, so it takes the same road as a letter and the
        // dispatch's own `default` swallows it — the Mac's adapter reaches the identical answer, by
        // never naming its key code at all.
        default:
            .char(
                press.charactersIgnoringModifiers.first ?? "\u{0}",
                control: press.control,
                shift: press.shift,
            )
        }
    }

    /// Whether this pane is in a mode that reads keys as COMMANDS — Hint Mode or Copy Mode.
    ///
    /// The phone's responder asks this BEFORE it asks which of its two input paths a press takes:
    /// copy mode's vocabulary is mostly bare letters, and bare letters are exactly what
    /// ``PhoneKey/routesToKeyEncoding(_:)`` hands to the text-input proxy. Asked in the other order,
    /// `j` composes into the shell while the pill says VI.
    public var takesModalKeys: Bool { hintMode != nil || isCopyMode }

    /// Offers one phone press to whichever mode is armed, answering whether a mode took it.
    ///
    /// The layer ORDER is the Mac's, and for the Mac's reason (`MacTerminalRendererView.keyDown`): hint
    /// mode can be armed ON TOP of copy mode — copy-mode `f` is one of the ways in — so it is the
    /// topmost layer and is asked first. Asked second, copy mode would swallow every label letter
    /// and its Esc would tear down the bottom layer first.
    ///
    /// A ⌘ combination is never taken. On macOS the app's own dispatcher intercepts those before the
    /// surface ever sees them; on iOS every press reaches the responder, so the exemption has to be
    /// stated here or the palette chord would resolve as two hint letters.
    @discardableResult
    public func takeModalKey(_ press: PhoneKey.Press) -> Bool {
        guard !press.command else { return false }
        if hintMode != nil {
            handleHintKey(Self.makeHintKey(press))
            return true
        }
        guard isCopyMode else { return false }
        handleCopyModeKey(Self.makeCopyModeKey(press))
        return true
    }

    /// The PURE copy-mode dispatch: maps an abstract ``CopyModeKey`` to a navigation /
    /// repeat-count / visual-mode / search / copy / exit intent, driving the active surface's
    /// ``TerminalSurfaceActions`` seam (scroll/jump/search/adjust-selection bindings) or the find / copy / exit
    /// hooks. Everything else is SWALLOWED (consumed while armed → nothing leaks to the shell). No `NSEvent` /
    /// AppKit — fully unit-testable against a mock `TerminalSurfaceActions`.
    ///
    /// REPEAT-COUNT (vim parity): digits `1`–`9` (and `0` once a count is pending) accumulate into the pure
    /// ``copyModeState`` and show live in the pill (``viPendingCount``); the NEXT motion applies the count and
    /// clears it. The count SCALES a parameterized action (`scroll_page_lines:±count`, `jump_to_prompt:±count`)
    /// and REPEATS a directional one (`adjust_selection:<dir>` / `navigate_search:…` ×count, which take no
    /// magnitude). An absolute jump (`g`/`G`), a half-page (`⌃d`/`⌃u`), and a full-page (`⌃f`/`⌃b`) just
    /// consume/clear the count.
    ///
    /// CURSOR ENGINE (the E17 ceiling LIFT, DECISIONS.md 2026-07-14): when the surface conforms to
    /// ``TerminalSelectionControl`` (the fork's set-selection/viewport-info ABI), copy-mode holds a REAL vi
    /// cursor in SCREEN coordinates — `h/l/←/→` column motions, `0/^/$` line columns, `w/b/e` word motions
    /// (``ViLineMotion`` over the seam's row text), `j/k/↑/↓` cursor rows with viewport-follow scrolling, and
    /// the page/absolute jumps move cursor AND viewport. `v`/`V`/`⌃v` anchor AT the cursor and drive
    /// `setSelection` so libghostty-vt renders the selection natively; `o` swaps anchor↔cursor; `y`/Enter yanks
    /// the real range; `Y` yanks the cursor row. Every motion re-reads `viewportInfo()` FIRST (the anti-jitter
    /// rule: the cursor is client state, but every claim about where it sits derives from same-keystroke
    /// libghostty-vt truth, re-clamped — never a cached offset).
    ///
    /// LEGACY FALLBACK (seam absent — headless conformers, placeholder surfaces): the pre-lift behavior is
    /// kept verbatim — line motions scroll (`scroll_page_lines:±count`), visual modes EXTEND a mouse-anchored
    /// selection via `adjust_selection:<dir>`, the column/word motions are swallowed, and `y` copies the
    /// mouse-made selection / visible scrollback.
    ///
    /// Scroll-sign convention (Binding.zig): NEGATIVE = UP toward older scrollback, so `j`/↓ = `+1` (down),
    /// `k`/↑ = `-1` (up). `jump_to_prompt`/scroll actions are re-resolved every call (the seam reads live
    /// libghostty-vt truth — never cache a client line index, which drifts under host output).
    public func handleCopyModeKey(_ key: CopyModeKey) {
        let actions = surface as? TerminalSurfaceActions
        // Every path re-syncs the pill mirrors after mutating the pure ``copyModeState`` (digit append /
        // motion-consume / visual-mode flip) AND the cursor-overlay cell (fresh viewport readback), so the
        // live repeat-count + mode label + drawn cursor stay current.
        defer {
            syncViObservables()
            syncCursorOverlay()
        }
        // Plain (non-Control) nav/copy/exit keys match `control: false` so a Ctrl-<key> chord is a clean
        // no-op (swallowed via `default`) rather than silently aliasing onto a nav action — e.g. Ctrl-J must
        // not scroll, Ctrl-N must not navigate_search. Ctrl-D / Ctrl-U / Ctrl-V deliberately require
        // `control: true`.
        switch key {
        // Repeat-count digits (pure, client-side accumulation; shown live in the pill). `0` only EXTENDS an
        // existing count (10, 20…); a bare `0` is the line-start column motion below.
        case .char("0", control: false, _) where copyModeState.pendingCount != nil:
            copyModeState.appendDigit(0)
        case let .char(ch, control: false, _) where ch >= "1" && ch <= "9":
            copyModeState.appendDigit(ch.wholeNumberValue ?? 0)
        // Vertical line motions: cursor rows with viewport-follow (cursor path), else the count SCALES the
        // scroll / EXTENDS a mouse-anchored selection (legacy) — see ``applyLineMotion(_:sign:)``.
        case .char("j", control: false, _),
             .down:
            applyLineMotion(actions, sign: 1)
        case .char("k", control: false, _),
             .up:
            applyLineMotion(actions, sign: -1)
        // Column motions (cursor path only — without a cursor there is no column to move).
        case .char("h", control: false, _),
             .left:
            applyColumnMotion(sign: -1)
        case .char("l", control: false, _),
             .right:
            applyColumnMotion(sign: 1)
        // Line-edge motions follow the LOGICAL line (the soft-wrap chain): a long line the grid
        // wrapped over several display rows is ONE line, so `0`/`^` land on the chain's FIRST row
        // and `$` on the chain's LAST row's line end — never a wrap point.
        case .char("0", control: false, _):
            applyLineEdgeMotion(.start, actions: actions)
        case .char("^", control: false, _):
            applyLineEdgeMotion(.firstGlyph, actions: actions)
        case .char("$", control: false, _):
            applyLineEdgeMotion(.end, actions: actions)
        // Word motions (cursor path only): the count REPEATS the single step, which wraps across rows.
        case .char("w", control: false, _):
            applyWordMotion(.nextStart, actions: actions)
        case .char("b", control: false, _):
            applyWordMotion(.prevStart, actions: actions)
        case .char("e", control: false, _):
            applyWordMotion(.end, actions: actions)
        // Half-page: one half-viewport step (cursor + viewport on the cursor path); the count is
        // consumed/cleared, not scaled.
        case .char("d", control: true, _):
            applyPageMotion(actions, sign: 1, fraction: 0.5)
        case .char("u", control: true, _):
            applyPageMotion(actions, sign: -1, fraction: 0.5)
        // Full-page (vim ⌃f forward / ⌃b backward): a single viewport-page step; the count is consumed/cleared,
        // not scaled (parity with the half-page keys). `0.9` (one page minus a sliver of overlap context) is
        // the SAME "≈ a page" magnitude the PageDown/PageUp scroll hooks use (WorkspaceStore+FontScroll).
        // Sign convention (Binding.zig): positive = DOWN toward newer (⌃f), negative = UP toward older (⌃b).
        case .char("f", control: true, _):
            applyPageMotion(actions, sign: 1, fraction: 0.9)
        case .char("b", control: true, _):
            applyPageMotion(actions, sign: -1, fraction: 0.9)
        // Absolute top/bottom: a count is meaningless on an absolute jump → consumed/cleared.
        case .char("g", control: false, shift: false):
            applyAbsoluteJump(actions, toTop: true)
        case .char("g", control: false, shift: true),
             .char("G", control: false, _):
            applyAbsoluteJump(actions, toTop: false)
        // Prompt jump: the count SCALES the magnitude (`3]` → jump_to_prompt:3); on the cursor path the
        // cursor re-anchors to the landed viewport top (the prompt row libghostty-vt pinned).
        case .char("[", control: false, _):
            applyPromptJump(actions, sign: -1)
        case .char("]", control: false, _):
            applyPromptJump(actions, sign: 1)
        // Visual modes (v / V / ⌃v): anchor at the cursor and drive the native selection (cursor path), or
        // set/toggle the mode so motions EXTEND a mouse-anchored selection (legacy).
        case .char("v", control: false, shift: false):
            setVisualMode(.char)
        case .char("v", control: false, shift: true),
             .char("V", control: false, _):
            setVisualMode(.line)
        case .char("v", control: true, _):
            setVisualMode(.block)
        case .char("o", control: false, _):
            // Anchor-swap (vim `o`): swap anchor↔cursor so the free end changes (a real motion since the
            // ceiling lift; still a no-op without a cursor-driven visual selection). The pending count is
            // dropped (a count on a non-motion is meaningless).
            copyModeState.pendingCount = nil
            swapVisualEnds(actions)
        // Hint Mode (vi-mode spec §Action list: `f` enters Hint Mode for keyboard-driven link clicking) — a
        // separate visible-viewport label overlay, driven by the same ``beginHint(_:)`` seam the ⌘⇧J chord
        // uses. A count on a non-motion is meaningless, so it is dropped first; `beginHint(.open)` is itself a
        // clean no-op when there is no live surface / no hintable target (so `f` never enters an empty mode).
        // The renderer routes subsequent keys to ``handleHintKey(_:)`` while `hintMode` is armed.
        case .char("f", control: false, _):
            copyModeState.pendingCount = nil
            beginHint(.open)
        // Search (reuse the find bar, which drives the surface's own matcher — no second search impl).
        case .char("/", control: false, _):
            _ = copyModeState.consumeCount()
            onRequestFind?() // forward bias
        case .char("?", control: false, _):
            _ = copyModeState.consumeCount()
            (onRequestFindBackward ?? onRequestFind)?() // backward bias (falls back to the same bar)
        case .char("n", control: false, shift: false):
            let count = copyModeState.consumeCount()
            for _ in 0..<count { stepFindInSearchDirection(actions, reverse: false) }
        case .char("n", control: false, shift: true),
             .char("N", control: false, _):
            let count = copyModeState.consumeCount()
            for _ in 0..<count { stepFindInSearchDirection(actions, reverse: true) }
        // Yank: copies the live selection (a cursor-driven visual range IS the live libghostty-vt selection) /
        // the mouse-made selection / visible scrollback, then EXITS vi mode (spec).
        case .char("y", control: false, shift: false),
             .enter:
            _ = copyModeState.consumeCount()
            copyCurrentSelectionOrScrollback(actions)
            exitCopyMode()
        // Yank-line (vim `Y`): copies the cursor row's text (cursor path only), then exits.
        case .char("y", control: false, shift: true),
             .char("Y", control: false, _):
            _ = copyModeState.consumeCount()
            if yankCursorLine() {
                exitCopyMode()
            }
        case .char("q", control: false, _):
            exitCopyMode() // resets all vi state (count/visual/hints) via ``resetViState()``
        case .escape:
            // vim parity: Esc first collapses an active visual selection back to plain navigation
            // (clearing the native selection), and only then exits the mode.
            if copyModeState.visualMode != .none {
                setVisualMode(copyModeState.visualMode) // toggling the ACTIVE mode = off
            } else {
                exitCopyMode()
            }
        default:
            break // swallow every other key (consumed while in mode — nothing reaches the shell)
        }
    }

    /// vi `n` / `N` — step the find IN (`reverse: false`) or AGAINST (`reverse: true`) the find bar's current
    /// SEARCH DIRECTION. Routes through the SAME direction-aware seam as ⌘G / ⇧⌘G
    /// (``onRequestFindNext`` / ``onRequestFindPrev`` → the find bar's `next()` / `previous()`, biased on
    /// `searchBackward`), so after a copy-mode `?foo` the bar — not this handler — owns the concrete direction:
    /// `n` walks UP the buffer and `N` walks down (vim parity). Must NOT hardcode `navigate_search:next`, which
    /// always steps forward regardless of how the search was opened. Falls back to the engine's own forward/back
    /// nav ONLY when no find bar is wired (headless / preview), where there is no search direction to
    /// honor anyway.
    private func stepFindInSearchDirection(_ actions: TerminalSurfaceActions?, reverse: Bool) {
        if let hook = reverse ? onRequestFindPrev : onRequestFindNext {
            hook()
        } else if let wire = TerminalSearchSurfaceAction.navigate(forward: !reverse).wire {
            actions?.performBindingAction(wire)
        }
    }

    // MARK: vi cursor engine (the E17 ceiling lift — cursor path over ``TerminalSelectionControl``)

    /// The selection-control seam, when the live surface offers it (`nil` = headless / legacy → the
    /// pre-lift scroll-only behavior).
    private var selectionControl: TerminalSelectionControl? { surface as? TerminalSelectionControl }

    /// Fresh libghostty-vt truth for one cursor-path step, or `nil` → legacy. Re-read EVERY key (the
    /// anti-jitter rule) and sanity-gated so a degenerate readback can never divide/clamp into nonsense.
    private func cursorContext() -> (ctl: TerminalSelectionControl, info: TerminalViewportInfo)? {
        guard let ctl = selectionControl, let info = ctl.viewportInfo(),
              info.viewportRows > 0, info.cols > 0, info.totalRows > 0 else { return nil }
        return (ctl, info)
    }

    /// The current vi cursor re-clamped against `info`, seeding it on first use: entry lands on the
    /// TERMINAL cursor (tmux parity), pulled into the visible viewport if the user had scrolled away.
    private func seededCursor(_ info: TerminalViewportInfo) -> TerminalScreenPoint {
        if let cursor = copyModeState.cursor { return clamped(cursor, info) }
        var cursor = clamped(info.cursor, info)
        let top = info.viewportTopRow
        let bottom = top + info.viewportRows - 1
        cursor.row = min(max(cursor.row, top), bottom)
        return cursor
    }

    private func clamped(_ point: TerminalScreenPoint, _ info: TerminalViewportInfo) -> TerminalScreenPoint {
        TerminalScreenPoint(
            col: min(max(point.col, 0), info.cols - 1),
            row: min(max(point.row, 0), info.totalRows - 1),
        )
    }

    /// Lands a VERTICAL motion on its row's TEXT (vim's curswant rule): the cursor tries the
    /// remembered desired column (`Int.max` = a sticky `$`), clamped to the landed row's last text
    /// cell and snapped to a glyph start — so `j`/`k` follow the text's shape instead of floating
    /// through the grid's trailing padding, and a wide glyph is never straddled. A vertical motion
    /// with no remembered column adopts the current one first (vim seeds curswant lazily).
    private func settledOnRowText(
        _ cursor: TerminalScreenPoint,
        ctl: TerminalSelectionControl,
        info: TerminalViewportInfo,
    ) -> TerminalScreenPoint {
        var cursor = cursor
        if copyModeState.wantColumn == nil { copyModeState.wantColumn = cursor.col }
        let want = copyModeState.wantColumn ?? cursor.col
        let line = ctl.readScreenRow(cursor.row) ?? ""
        let extent = min(ViLineMotion.lastNonBlank(line) ?? 0, info.cols - 1)
        cursor.col = ViLineMotion.snapToCell(line, col: min(max(want, 0), extent))
        return cursor
    }

    /// The last SCREEN row that carries text — `G`'s landing. The active grid's unwritten/cleared
    /// tail rows are padding, not content (vim's `G` lands on the last LINE); the scan is bounded
    /// to one grid height because every history row above the active area was once written.
    private func lastTextRow(_ ctl: TerminalSelectionControl, info: TerminalViewportInfo) -> Int {
        var row = info.totalRows - 1
        let floor = max(0, info.totalRows - info.viewportRows)
        while row > floor, (ctl.readScreenRow(row) ?? "").isEmpty {
            row -= 1
        }
        return row
    }

    /// Scrolls just enough to bring the cursor into the viewport (`scroll_page_lines:±delta`) — the
    /// vi "viewport follows the cursor" rule. `info` is the PRE-motion readback; the overlay resync
    /// afterwards reads fresh truth.
    private func followViewport(
        _ cursor: TerminalScreenPoint,
        info: TerminalViewportInfo,
        actions: TerminalSurfaceActions?,
    ) {
        let top = info.viewportTopRow
        let bottom = top + info.viewportRows - 1
        let delta: Int =
            if cursor.row < top {
                cursor.row - top
            } else if cursor.row > bottom {
                cursor.row - bottom
            } else {
                0
            }
        guard delta != 0 else { return }
        actions?.performBindingAction(TerminalBindingAction.scrollLines(delta).wire)
    }

    /// Re-issues the native selection for the active cursor-driven visual mode after any cursor move
    /// (anchor→cursor; `.line` spans full rows; `.block` sets the rectangle flag). libghostty-vt renders
    /// it — never a client-drawn selection.
    private func refreshVisualSelection(_ ctl: TerminalSelectionControl, info: TerminalViewportInfo) {
        guard copyModeState.visualMode != .none,
              let anchor = copyModeState.anchor,
              let cursor = copyModeState.cursor else { return }
        switch copyModeState.visualMode {
        case .none:
            return
        case .char:
            ctl.setSelection(anchor: anchor, head: cursor, rectangle: false)
        case .line:
            // Line-visual spans LOGICAL lines: the ends widen to their soft-wrap chains, so `V` on
            // any display row of a wrapped long line selects the WHOLE line (vim/tmux semantics).
            let top = min(anchor.row, cursor.row)
            let bottom = max(anchor.row, cursor.row)
            let start = ctl.lineRange(top)?.lowerBound ?? top
            let end = ctl.lineRange(bottom)?.upperBound ?? bottom
            ctl.setSelection(
                anchor: TerminalScreenPoint(col: 0, row: start),
                head: TerminalScreenPoint(col: info.cols - 1, row: end),
                rectangle: false,
            )
        case .block:
            ctl.setSelection(anchor: anchor, head: cursor, rectangle: true)
        }
    }

    /// Applies a vertical line motion under the current repeat-count. CURSOR path: the cursor moves
    /// `±count` rows (clamped to the screen), the viewport follows, and an active visual selection
    /// re-issues. LEGACY: in a VISUAL mode it EXTENDS the mouse-anchored selection
    /// (`adjust_selection:<dir>` ×count — the directional action takes no magnitude), else it SCALES
    /// the scroll (one `scroll_page_lines:±count`). `sign` is +1 for down (`j`/↓), -1 for up (`k`/↑).
    private func applyLineMotion(_ actions: TerminalSurfaceActions?, sign: Int) {
        let count = copyModeState.consumeCount()
        if let (ctl, info) = cursorContext() {
            var cursor = seededCursor(info)
            cursor.row = min(max(cursor.row + sign * count, 0), info.totalRows - 1)
            cursor = settledOnRowText(cursor, ctl: ctl, info: info)
            copyModeState.cursor = cursor
            followViewport(cursor, info: info, actions: actions)
            refreshVisualSelection(ctl, info: info)
            return
        }
        if copyModeState.visualMode != .none {
            let edge: TerminalBindingAction.Edge = sign > 0 ? .down : .up
            let step = TerminalBindingAction.adjustSelection(edge).wire
            for _ in 0..<count { actions?.performBindingAction(step) }
        } else {
            actions?.performBindingAction(TerminalBindingAction.scrollLines(sign * count).wire)
        }
    }

    /// `h`/`l`/←/→ — the cursor moves `±count` GLYPHS within its row's TEXT (a wide glyph is one
    /// step; the motion clamps at the line's first/last text cell — vim: `h`/`l` never leave the
    /// row, and never wander the trailing padding). Cursor path only; without a cursor there is no
    /// column to move, so the key is swallowed.
    private func applyColumnMotion(sign: Int) {
        let count = copyModeState.consumeCount()
        guard let (ctl, info) = cursorContext() else { return }
        var cursor = seededCursor(info)
        let line = ctl.readScreenRow(cursor.row) ?? ""
        cursor.col = min(max(ViLineMotion.columnStep(line, from: cursor.col, by: sign * count), 0), info.cols - 1)
        copyModeState.cursor = cursor
        copyModeState.wantColumn = cursor.col
        refreshVisualSelection(ctl, info: info)
    }

    /// The three line-edge landings ``applyLineEdgeMotion(_:actions:)`` resolves over the logical line.
    private enum LineEdge {
        case start
        case firstGlyph
        case end
    }

    /// `0`/`^`/`$` — line-EDGE motions over the LOGICAL line (the seam's soft-wrap chain, vim/tmux
    /// semantics): `0`/`^` land on the chain's FIRST row (column 0 / first non-blank glyph), `$` on
    /// the chain's LAST row's last text cell — so on a soft-wrapped long line the cursor moves ROWS
    /// to the line's real edges, never a wrap point. `$` re-seeds sticky curswant (`Int.max`, vim's
    /// `$`-then-`j` hug-the-line-ends behavior); the viewport follows the landed row (a chain edge
    /// can sit off-screen). A seam without `lineRange` truth degrades to the display row (the
    /// honest single-row chain). Cursor path only.
    private func applyLineEdgeMotion(_ edge: LineEdge, actions: TerminalSurfaceActions?) {
        _ = copyModeState.consumeCount()
        guard let (ctl, info) = cursorContext() else { return }
        var cursor = seededCursor(info)
        let chain = ctl.lineRange(cursor.row) ?? cursor.row...cursor.row
        switch edge {
        case .start:
            cursor.row = chain.lowerBound
            cursor.col = ViLineMotion.lineStart
            copyModeState.wantColumn = cursor.col
        case .firstGlyph:
            cursor.row = chain.lowerBound
            cursor.col = ViLineMotion.firstNonBlank(ctl.readScreenRow(cursor.row) ?? "")
            copyModeState.wantColumn = cursor.col
        case .end:
            cursor.row = chain.upperBound
            let line = ctl.readScreenRow(cursor.row) ?? ""
            cursor.col = ViLineMotion.lastNonBlank(line) ?? ViLineMotion.lineStart
            copyModeState.wantColumn = Int.max
        }
        cursor.col = min(max(cursor.col, 0), info.cols - 1)
        copyModeState.cursor = cursor
        followViewport(cursor, info: info, actions: actions)
        refreshVisualSelection(ctl, info: info)
    }

    /// The three vi word motions ``applyWordMotion(_:actions:)`` steps.
    private enum WordMotion {
        case nextStart
        case prevStart
        case end
    }

    /// `w`/`b`/`e` — repeats the single word step `count` times (each step may wrap to the adjacent
    /// row), then the viewport follows the landed cursor. Cursor path only.
    private func applyWordMotion(_ motion: WordMotion, actions: TerminalSurfaceActions?) {
        let count = copyModeState.consumeCount()
        guard let (ctl, info) = cursorContext() else { return }
        var cursor = seededCursor(info)
        for _ in 0..<count {
            cursor = stepWord(motion, from: cursor, ctl: ctl, info: info)
        }
        copyModeState.cursor = cursor
        copyModeState.wantColumn = cursor.col // a word motion re-seeds curswant (vim)
        followViewport(cursor, info: info, actions: actions)
        refreshVisualSelection(ctl, info: info)
    }

    /// One vim word step over the seam's row text (``ViLineMotion``), wrapping to the adjacent row
    /// when the motion runs off the current one (a blank row is a landing, like vim's empty line).
    private func stepWord(
        _ motion: WordMotion,
        from cursor: TerminalScreenPoint,
        ctl: TerminalSelectionControl,
        info: TerminalViewportInfo,
    ) -> TerminalScreenPoint {
        var cursor = cursor
        let line = ctl.readScreenRow(cursor.row) ?? ""
        switch motion {
        case .nextStart:
            if let col = ViLineMotion.nextWordStart(line, from: cursor.col) {
                cursor.col = col
            } else if cursor.row + 1 < info.totalRows {
                cursor.row += 1
                cursor.col = ViLineMotion.firstNonBlank(ctl.readScreenRow(cursor.row) ?? "")
            }
        case .prevStart:
            if let col = ViLineMotion.prevWordStart(line, from: cursor.col) {
                cursor.col = col
            } else if cursor.row > 0 {
                cursor.row -= 1
                cursor.col = ViLineMotion.lastWordStart(ctl.readScreenRow(cursor.row) ?? "") ?? ViLineMotion.lineStart
            }
        case .end:
            if let col = ViLineMotion.wordEnd(line, from: cursor.col) {
                cursor.col = col
            } else if cursor.row + 1 < info.totalRows {
                cursor.row += 1
                let next = ctl.readScreenRow(cursor.row) ?? ""
                cursor.col = ViLineMotion.wordEnd(next, from: 0)
                    ?? ViLineMotion.lastNonBlank(next)
                    ?? ViLineMotion.lineStart
            }
        }
        cursor.col = min(max(cursor.col, 0), info.cols - 1)
        return cursor
    }

    /// `⌃d`/`⌃u` (fraction 0.5) and `⌃f`/`⌃b` (0.9 — the "≈ a page" magnitude the PageUp/PageDown
    /// hooks use). CURSOR path: viewport AND cursor move together by the same line delta (vim
    /// semantics), clamped, with fresh post-scroll truth for the selection/overlay. LEGACY: the
    /// original `scroll_page_fractional:±f`. The count is consumed/cleared, not scaled.
    private func applyPageMotion(_ actions: TerminalSurfaceActions?, sign: Int, fraction: Double) {
        _ = copyModeState.consumeCount()
        if let (ctl, info) = cursorContext() {
            let lines = Double(info.viewportRows) * fraction
            let magnitude = max(1, Int(lines.rounded(.down)))
            let delta = sign * magnitude
            actions?.performBindingAction(TerminalBindingAction.scrollLines(delta).wire)
            var cursor = seededCursor(info)
            cursor.row = min(max(cursor.row + delta, 0), info.totalRows - 1)
            cursor = settledOnRowText(cursor, ctl: ctl, info: info)
            copyModeState.cursor = cursor
            // Post-scroll truth: the residual follow only fires at the screen edges (where the
            // viewport clamped but the cursor kept moving, or vice versa).
            if let fresh = ctl.viewportInfo(), fresh.viewportRows > 0 {
                followViewport(cursor, info: fresh, actions: actions)
                refreshVisualSelection(ctl, info: fresh)
            }
            return
        }
        actions?.performBindingAction(TerminalBindingAction.scrollFraction(sign > 0 ? fraction : -fraction).wire)
    }

    /// `g`/`G` — absolute top/bottom: the viewport jumps via the native action; on the cursor path
    /// the cursor lands on the first / LAST TEXT row's first non-blank glyph (vim's `gg`/`G` — the
    /// active grid's blank tail rows are padding, never a landing).
    private func applyAbsoluteJump(_ actions: TerminalSurfaceActions?, toTop: Bool) {
        _ = copyModeState.consumeCount()
        actions?.performBindingAction((toTop ? TerminalBindingAction.scrollToTop : .scrollToBottom).wire)
        guard let (ctl, info) = cursorContext() else { return }
        var cursor = seededCursor(info)
        cursor.row = toTop ? 0 : lastTextRow(ctl, info: info)
        cursor.col = ViLineMotion.firstNonBlank(ctl.readScreenRow(cursor.row) ?? "")
        copyModeState.cursor = cursor
        copyModeState.wantColumn = cursor.col
        refreshVisualSelection(ctl, info: info)
    }

    /// `[`/`]` — the prompt jump keeps the native `jump_to_prompt:±count`; on the cursor path the
    /// cursor then re-anchors to the LANDED viewport top (the row libghostty-vt pinned the prompt to —
    /// the binding action mutates core synchronously, so the post-jump readback is already fresh),
    /// landing on the prompt row's first glyph (vim's line-jump column rule).
    private func applyPromptJump(_ actions: TerminalSurfaceActions?, sign: Int) {
        let count = copyModeState.consumeCount()
        actions?.performBindingAction(TerminalBindingAction.jumpToPrompt(sign * count).wire)
        guard let (ctl, info) = cursorContext() else { return }
        var cursor = seededCursor(info)
        cursor.row = info.viewportTopRow
        cursor.col = ViLineMotion.firstNonBlank(ctl.readScreenRow(cursor.row) ?? "")
        copyModeState.cursor = cursor
        copyModeState.wantColumn = cursor.col
        refreshVisualSelection(ctl, info: info)
    }

    /// vim `o` — swaps anchor↔cursor so subsequent motions grow the OTHER end of the selection; the
    /// viewport follows the (former) anchor. A no-op outside a cursor-driven visual selection.
    private func swapVisualEnds(_ actions: TerminalSurfaceActions?) {
        guard let (ctl, info) = cursorContext(),
              copyModeState.visualMode != .none,
              let anchor = copyModeState.anchor,
              let cursor = copyModeState.cursor else { return }
        copyModeState.anchor = cursor
        copyModeState.cursor = anchor
        copyModeState.wantColumn = anchor.col // the swapped-to end re-seeds curswant (vim)
        followViewport(anchor, info: info, actions: actions)
        refreshVisualSelection(ctl, info: info)
    }

    /// vim `Y` — copies the cursor's LOGICAL line (+ receipt): the soft-wrap chain's rows joined
    /// WITHOUT newlines (the wrap is a display artifact, not content — an interior chain row spans
    /// the full grid width, so plain concatenation reconstructs the real line). Returns whether
    /// anything was copied (blank row / no cursor path ⇒ `false`, and the mode stays put).
    private func yankCursorLine() -> Bool {
        guard let (ctl, info) = cursorContext() else { return false }
        let cursor = seededCursor(info)
        let chain = ctl.lineRange(cursor.row) ?? cursor.row...cursor.row
        let line = chain.compactMap { ctl.readScreenRow($0) }.joined()
        guard !line.isEmpty else { return false }
        copyToPasteboard(line)
        noteClipboardCopy(line)
        return true
    }

    /// Mirrors ``copyModeState``'s cursor into the observable ``viCursorCell`` overlay cell —
    /// VIEWPORT-relative, `nil` off-viewport — from a FRESH readback. Written only on a real change.
    private func syncCursorOverlay() {
        var cell: ViCursorCell?
        if isCopyMode, let cursor = copyModeState.cursor, let (ctl, info) = cursorContext() {
            let viewportRow = cursor.row - info.viewportTopRow
            if viewportRow >= 0, viewportRow < info.viewportRows, cursor.col >= 0, cursor.col < info.cols {
                // The block's width follows the glyph under it (a wide CJK/fullwidth char = 2 cells).
                let width = ViLineMotion.cellWidth(ctl.readScreenRow(cursor.row) ?? "", at: cursor.col)
                cell = ViCursorCell(col: cursor.col, row: viewportRow, width: min(width, info.cols - cursor.col))
            }
        }
        if viCursorCell != cell { viCursorCell = cell }
    }

    /// Sets (or toggles OFF) a visual-selection mode. Pressing the SAME mode key again returns to plain
    /// navigation (`.none`); a different mode key SWITCHES (vim parity: `V` from char-visual → line-visual).
    /// Entering/switching a visual mode drops any pending repeat-count. CURSOR path: entering anchors AT
    /// the cursor and issues the native selection; leaving clears both; switching re-issues under the new
    /// mode. LEGACY: the mode flag alone (motions then drive `adjust_selection`).
    private func setVisualMode(_ mode: VisualMode) {
        copyModeState.pendingCount = nil
        let previous = copyModeState.visualMode
        let next: VisualMode = (previous == mode) ? .none : mode
        copyModeState.visualMode = next
        guard let (ctl, info) = cursorContext() else { return }
        if next == .none {
            copyModeState.anchor = nil
            ctl.clearSelection()
            return
        }
        let cursor = seededCursor(info)
        copyModeState.cursor = cursor
        if previous == .none || copyModeState.anchor == nil {
            copyModeState.anchor = cursor
        }
        refreshVisualSelection(ctl, info: info)
    }

    /// Copies the libghostty-vt selection if one exists, else the visible scrollback text — then flashes the
    /// "copied" confirmation. Nothing to copy (no selection, empty scrollback) → no pasteboard write and no
    /// confirmation. Reads libghostty-vt truth only (never a client-guessed range).
    private func copyCurrentSelectionOrScrollback(_ actions: TerminalSurfaceActions?) {
        let text: String?
        if actions?.hasSelection() == true, let selection = actions?.readSelection(), !selection.isEmpty {
            text = selection
        } else {
            let lines = actions?.scrollbackLines().text ?? []
            text = lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        guard let payload = text, !payload.isEmpty else { return }
        copyToPasteboard(payload)
        noteClipboardCopy(payload)
    }

    /// Arms copy-mode (⌘⇧C / menu / store entry); the overlay follows the observable
    /// ``copyModeBadgeActive`` twin. A fresh session starts with NO pending count, plain navigation, and
    /// the hint bar off (``resetViState``).
    public func enterCopyMode() {
        guard !isCopyMode else { return }
        resetViState()
        isCopyMode = true
        // Seed the vi cursor at the terminal cursor (tmux parity) when the selection seam is live;
        // headless/legacy surfaces stay cursor-less (scroll-only navigation).
        if let (_, info) = cursorContext() {
            copyModeState.cursor = seededCursor(info)
        }
        syncCursorOverlay()
    }

    /// Exits copy-mode (the `q`/Esc keys, a `y`/Enter yank, or a programmatic dismiss) and clears all vi
    /// state (count/visual/hints). Idempotent — the overlay backs off with the observable twin, so a
    /// second call has nothing left to say.
    public func exitCopyMode() {
        guard isCopyMode else { return }
        // Clear OUR cursor-driven selection (never a mouse-made one — those have no anchor here).
        if copyModeState.anchor != nil {
            selectionControl?.clearSelection()
        }
        isCopyMode = false
        resetViState()
        syncCursorOverlay()
    }

    // MARK: Read-only mode (per-pane user-toggled input gate)

    /// TRUE while this pane is READ-ONLY: the single input ingress seam ``sendInput(_:)`` drops every
    /// outbound byte (keys / paste / IME commit / mouse-report / click-to-move / iOS input-bar /
    /// synchronized-input broadcast) and rings a (rate-limited) beep instead of forwarding it. Output
    /// ingest is UNTOUCHED — the host's video/bytes keep streaming; the pane is "view only".
    ///
    /// VIEW state, NOT persisted (the `isCopyMode` / `copyModeBadgeActive` twin pattern): `@ObservationIgnored`
    /// because the renderer's `keyDown` / mouse-report path READS this flag from inside the renderer's own
    /// event path, which also writes it (the self-invalidating cycle documented on ``surface``), so it must
    /// register no Observation dependency. The pill tracks the observable ``readOnlyBadgeActive`` mirror instead, kept in
    /// lock-step by this `didSet`, which ALSO fires ``onReadOnlyChanged`` so the pill `×`, the menu, and the
    /// command-palette term converge to one source of truth through the store.
    @ObservationIgnored public var isReadOnly = false {
        didSet {
            readOnlyBadgeActive = isReadOnly
            onReadOnlyChanged?(isReadOnly)
        }
    }

    /// OBSERVABLE mirror of ``isReadOnly`` for the `🔒 READ ONLY ×` pill. ``isReadOnly`` itself is
    /// `@ObservationIgnored` (the keyDown intercept reads it from the renderer's own read-then-write event
    /// path); the pill's `withObservationTracking` arm reads THIS twin instead and is woken per real flip.
    /// Kept in lock-step by ``isReadOnly``'s `didSet`.
    public private(set) var readOnlyBadgeActive = false

    /// The read-only transition hook: the store wires it (in `wireMaterializedLeaf`) so flipping ``isReadOnly``
    /// — by the pill `×`, the menu item, the palette term, OR a programmatic `setPaneReadOnly` — keeps
    /// `WorkspaceStore.paneReadOnly` in sync (the single source of truth the pill + sidebar lock indicator both
    /// read). `@ObservationIgnored`: wiring, not view state. Nil for headless / preview callers (never invoked).
    @ObservationIgnored public var onReadOnlyChanged: ((Bool) -> Void)?

    /// The injected blocked-input cue — what a READ-ONLY pane answers a keystroke with. Tests override with a
    /// counting closure (the ``copyToPasteboard`` idiom) so ``rateLimitedBeep`` is unit-testable without a
    /// real `NSSound` / Taptic Engine. `@ObservationIgnored`: wiring, not view state.
    ///
    /// The Mac rings the system beep. The phone taps, and the tap — not a sound — is the honest analogue:
    /// a Mac is a machine whose speaker is on, while a phone is usually SILENCED, so the audible half of a
    /// beep is exactly the half a phone throws away. A haptic is the same message on the channel a phone
    /// actually has: it survives the ring switch, it needs no audio session (which the terminal does not own
    /// and must not take from whatever is playing), and it is the platform's own "that did nothing" report.
    /// `.rigid` because the cue is a REFUSAL — a short hard tap, not the soft one a success uses.
    @ObservationIgnored public var beep: () -> Void = {
        #if canImport(AppKit)
        NSSound.beep()
        #elseif canImport(UIKit)
        // The only caller is ``rateLimitedBeep``, which is main-actor like the rest of this type; the
        // closure's own type cannot say so, which is what this states instead.
        MainActor.assumeIsolated { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        #endif
    }

    /// Minimum spacing between read-only blocked-input beeps. A mouse-report flood (every pointer motion event
    /// funnels through ``sendInput(_:)`` while read-only) would otherwise beep per event, so ``rateLimitedBeep``
    /// coalesces to one beep per window. Instance-settable so a test drives the throttle without real-time
    /// waits. `@ObservationIgnored`: tuning, not view state.
    @ObservationIgnored var readOnlyBeepInterval: Duration = .milliseconds(400)

    /// When the last read-only beep rang, so ``rateLimitedBeep`` can throttle a flood to one beep per
    /// ``readOnlyBeepInterval``. `@ObservationIgnored`: bookkeeping, not view state.
    @ObservationIgnored private var lastReadOnlyBeepAt: ContinuousClock.Instant?

    /// Rings the (injected) ``beep`` at most once per ``readOnlyBeepInterval`` — so a mouse-report or
    /// key-repeat flood blocked by read-only beeps once, not per event.
    private func rateLimitedBeep() {
        let now = ContinuousClock.now
        if let last = lastReadOnlyBeepAt, now - last < readOnlyBeepInterval { return }
        lastReadOnlyBeepAt = now
        beep()
    }

    /// Arms read-only mode (the pill / menu / palette / store entry). Idempotent — re-entering an
    /// already-read-only pane does not re-fire ``onReadOnlyChanged`` (the guard suppresses the redundant write,
    /// so the `didSet` only runs on a real transition).
    public func enterReadOnly() {
        guard !isReadOnly else { return }
        isReadOnly = true
    }

    /// Disarms read-only mode (the pill `×` / menu / palette / store entry). Idempotent — exiting an
    /// already-writable pane is a clean no-op (no redundant ``onReadOnlyChanged`` fire).
    public func exitReadOnly() {
        guard isReadOnly else { return }
        isReadOnly = false
    }

    /// Toggles read-only mode (the single `.toggleReadOnly` action / menu item).
    public func toggleReadOnly() {
        if isReadOnly { exitReadOnly() } else { enterReadOnly() }
    }

    // MARK: Secure input (auto password-prompt + manual secure keyboard entry)

    /// TRUE while the HOST shell is at a no-echo (hidden-password) prompt — the inverse of the host PTY's
    /// termios `ECHO` flag, signalled over wire type 31 (``WireMessage/inputEcho(enabled:)``) and routed here
    /// by ``ConnectionViewModel`` via ``handle(_:)``. The macOS leaf forwards it (``onHostEchoChanged``) to a
    /// ``SecureKeyboardEntryController`` that engages process-global `EnableSecureEventInput` so no other app
    /// can sniff the password keystrokes. `@ObservationIgnored` (the connection-layer fold sets it, the pill
    /// reads the observable ``secureInputActive`` mirror — the `isReadOnly`/`readOnlyBadgeActive` twin idiom).
    @ObservationIgnored public var hostNoEcho = false {
        didSet {
            guard hostNoEcho != oldValue else { return }
            refreshSecureInput()
            onHostEchoChanged?(hostNoEcho)
        }
    }

    /// The MANUAL Secure-Keyboard-Entry toggle (Edit ▸ Secure Keyboard Entry / the palette term): engages
    /// secure input regardless of the host echo state. Toggled by the store seam over the active pane
    /// (``WorkspaceStore/toggleSecureKeyboardEntryInActivePane()``); the macOS leaf forwards it
    /// (``onManualSecureInputChanged``) to the pane's ``SecureKeyboardEntryController``. `@ObservationIgnored`
    /// (the pill reads ``secureInputActive``, not this raw flag).
    @ObservationIgnored public var manualSecureInput = false {
        didSet {
            guard manualSecureInput != oldValue else { return }
            refreshSecureInput()
            onManualSecureInputChanged?(manualSecureInput)
        }
    }

    /// OBSERVABLE mirror that drives the `🛡 SECURE INPUT` pill: TRUE when secure input is active for this pane
    /// — either the AUTO path (the "Auto Secure Input" setting is on AND the host is at a no-echo prompt) or
    /// the MANUAL toggle. `@ObservationIgnored` `hostNoEcho`/`manualSecureInput` feed it; the pill's tracked
    /// arm reads THIS twin. Always `false` off macOS (secure input is macOS-only), so the
    /// shared cross-platform pill never lights on iOS. Kept in lock-step by ``refreshSecureInput()``.
    public private(set) var secureInputActive = false

    /// Fired when ``hostNoEcho`` flips (the host entered / left a no-echo password prompt). The macOS leaf
    /// wires it to ``SecureKeyboardEntryController/setHostNoEcho(_:)`` so the auto secure-input engages /
    /// disengages on the prompt edge. `@ObservationIgnored`: wiring, not view state. Nil for headless / iOS.
    @ObservationIgnored public var onHostEchoChanged: ((Bool) -> Void)?

    /// Fired when ``manualSecureInput`` flips (the Edit-menu / palette manual toggle). The macOS leaf wires it
    /// to ``SecureKeyboardEntryController/setManualOn(_:)``. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onManualSecureInputChanged: ((Bool) -> Void)?

    /// Recomputes the observable ``secureInputActive`` pill mirror from the raw inputs, writing it only on a
    /// real change — a guarded write, so a recompute that lands on the same verdict wakes no tracked arm (and
    /// therefore costs no re-arm). Mirrors the `SecureKeyboardEntryController`'s engage
    /// formula `(autoSecureInput && hostNoEcho) || manualOn` so the pill and the OS actuator agree; gated to
    /// `false` off macOS so the cross-platform pill never lights on iOS (secure input is macOS-only).
    private func refreshSecureInput() {
        #if os(macOS)
        let value = (SettingsKey.autoSecureInputEnabled && hostNoEcho) || manualSecureInput
        #else
        let value = false
        #endif
        if secureInputActive != value { secureInputActive = value }
    }

    /// Re-evaluates the `🛡 SECURE INPUT` pill mirror after a LIVE "Auto Secure Input" settings change.
    /// ``refreshSecureInput()`` reads the setting live but is only re-invoked from the
    /// `hostNoEcho` / `manualSecureInput` `didSet`s — never on a settings-toggle edge — so an engaged pill would
    /// otherwise linger (auto on + host no-echo) until the next echo edge even after the user turned the setting
    /// OFF. The leaf observes the `autoSecureInput` default and calls this (alongside the controller's
    /// ``SecureKeyboardEntryController/setAutoSecureInput(_:)``) so the pill and OS lock reconcile immediately —
    /// the "toggle is live" contract the Settings footer claims.
    public func reconcileSecureInputSetting() {
        refreshSecureInput()
    }

    /// Toggles MANUAL secure keyboard entry over this pane (the `.secureKeyboardEntry` action / Edit-menu item
    /// / palette term). Flips ``manualSecureInput``, whose `didSet` refreshes the pill mirror and fires
    /// ``onManualSecureInputChanged`` so the leaf's controller engages / disengages.
    public func toggleSecureKeyboardEntry() {
        manualSecureInput.toggle()
    }

    /// The "Command Navigator" toggle (⌃⌘O / the chrome chip / a menu item) — opens the searchable
    /// recent-blocks popover over THIS pane. `TerminalPaneWiring` binds it to a TOGGLE on the leaf's
    /// `CommandNavigatorChrome.isVisible` (the ``onRequestFind`` pattern), and the leaf's tracked arm is what
    /// mounts or drops the card off that flag. `@ObservationIgnored`: wiring, not view state. Nil for headless
    /// callers.
    @ObservationIgnored public var onRequestBlockNavigator: (() -> Void)?

    /// The OUT-path sink that fires a `requestBlockOutput(index)` (wire type 15) on the live client. Set by
    /// ``ConnectionViewModel`` on connect (forwards to ``SlopDeskClient/requestBlockOutput(index:)``), cleared
    /// on teardown; while `nil` (disconnected) a copy-output request resolves immediately as "unavailable"
    /// rather than hanging. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var requestBlockOutputSink: ((UInt32) -> Void)?

    // MARK: Link interaction (⌘-hold underline + full-path hover)

    /// TRUE while ⌘ is held over this pane's terminal (set by the macOS renderer's `flagsChanged`). Drives the
    /// link-highlight overlay (`MacLinkHighlightOverlay` / `LinkHighlightOverlayView`), which underlines every
    /// detected path/URL in the visible viewport. OBSERVABLE (a normal `@Observable` property, NOT
    /// `@ObservationIgnored`) so the overlay's tracked arm is woken on reveal / clear — and safely so, because
    /// it is WRITTEN from the renderer's `flagsChanged` handler and never READ back there, unlike
    /// ``isReadOnly``: no read means no dependency to invalidate, so none of the self-invalidating cycle
    /// documented on ``surface``. Always FALSE on iOS — no ⌘ modifier,
    /// so the overlay is inert there (the iOS affordance is tap-on-label / long-press, not ⌘-hold).
    public var linkHighlightActive = false

    /// A monotonic tick bumped whenever the LOCAL viewport scrolls (mouse-wheel / trackpad scrollback
    /// navigation) WITHOUT any new wire bytes — the signal the link-highlight overlay's arm tracks so its
    /// ⌘-hold underlines RE-DETECT against the post-scroll `viewportTextRows()` instead of clinging to the
    /// pre-scroll rows at fixed screen positions. libghostty-vt owns the viewport internally, so a local scrollback
    /// scroll bumps no ``bytesReceived`` (the only other viewport-change signal); the renderer's `scrollWheel` /
    /// pan handler calls ``noteViewportScrolled()`` after forwarding the delta. OBSERVABLE so the overlay's arm
    /// re-fires; the MAGNITUDE is never read (a pure change-signal), so a wrap is harmless. Inert on a pane
    /// with no ⌘-hold underline active.
    public private(set) var viewportRevision: Int = 0

    /// Bumps ``viewportRevision`` — called by the renderer AFTER forwarding a LOCAL scroll to libghostty-vt so the
    /// ⌘-hold link overlay re-detects against the moved viewport. `&+` wrap: a pure change-signal, never read
    /// for magnitude. WRITE-ONLY from the renderer's event handler — the renderer never reads it back, so
    /// there is no dependency for the write to invalidate and none of the cycle documented on ``surface``.
    public func noteViewportScrolled() { viewportRevision &+= 1 }

    /// The resolved absolute path (or raw text, when it cannot be resolved purely — a `~`-path, a bare URL) of
    /// the detected link the pointer is ⌘-hovering, or `nil` when not hovering one. Set by the macOS
    /// renderer's `mouseMoved`/`flagsChanged` hit-test; cleared on ⌘ release / pointer-exit / a move off any
    /// link. DORMANT SEAM: its only consumer was the per-pane status bar's full-path preview, removed with the
    /// status strip — the renderer still resolves it (cheaply, only while ⌘ is held over a terminal) so a future
    /// hover-preview can read it. Never set on iOS.
    public var hoveredLinkFullPath: String?

    /// The pane's last-known working directory (OSC 7 `pane/cwd`), mirrored here by the leaf so the
    /// AppKit renderer's ⌘-hover hit-test can resolve a RELATIVE detected path to absolute for the status-bar
    /// preview. WIRING, not view state (`@ObservationIgnored`): syncing it must never wake a tracked arm, and
    /// the two shells' link-highlight overlays (`MacLinkHighlightOverlay` / `LinkHighlightOverlayView`) take
    /// cwd as an init parameter the leaf re-pushes on change — only the renderer reads this.
    @ObservationIgnored public var linkCwd: String?

    // `hoveredLinkPath(rows:cwd:schemes:metrics:pointX:pointY:)` was here: the pure ⌘-hover hit-test,
    // and the SECOND spelling of the cell math the embedder's own `detectedLink(at:)` ran — which the
    // latter's doc comment admitted by naming this one as the thing it "mirrors". The math is
    // ``TerminalLinkHitTest`` now, once, answering with the LINK; the hover's path is
    // `resolvedAbsolute ?? raw` at the one call site that wants a path. Nothing here called this, and
    // the copy production ran was the one behind a `#if os(macOS)` no test could reach.

    // MARK: Hint Mode

    /// The armed Hint Mode intent (open / copy / reveal), or `nil` when not in hint mode. OBSERVABLE so the
    /// hint overlay (``SlopDeskMacUI/MacHintModeOverlay`` / ``SlopDeskPhoneUI/HintModeOverlayView``)
    /// reveals / clears reactively, and the renderer's `keyDown` reads it to ROUTE keys to
    /// ``handleHintKey(_:)`` instead of the PTY while it is non-nil. Always `nil` until ``beginHint(_:)`` arms it.
    public var hintMode: HintIntent?

    /// The label keys typed so far this hint session (0, 1, or 2 chars). OBSERVABLE so the overlay dims the
    /// non-matching labels as the user types the first letter. Reset on enter / exit.
    public var hintTyped = ""

    /// The detected hintable targets for the active session (assigned 1:1 with ``hintLabels`` by index), set
    /// once by ``beginHint(_:)`` and STABLE for the session (re-detecting per keystroke would re-shuffle the
    /// labels). `@ObservationIgnored` (wiring/snapshot data, read by the overlay alongside the observable
    /// `hintTyped`, which drives the re-render).
    @ObservationIgnored public private(set) var hintTargets: [HintTarget] = []

    /// The 2-letter Vimium labels assigned to ``hintTargets`` (same index). Set once by ``beginHint(_:)``.
    @ObservationIgnored public private(set) var hintLabels: [String] = []

    /// Fired when a hint label fully resolves (macOS key-resolve) or a label is tapped (iOS) — carries the
    /// chosen target + the active intent. The VIEW layer wires it (in ``TerminalLeafView``) to the platform
    /// actuation: open path → host RPC, open URL → client, copy → client pasteboard, reveal → host RPC. `nil`
    /// for headless / preview callers. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onHintConfirmed: ((HintTarget, HintIntent) -> Void)?

    /// Arm Hint Mode over the VISIBLE viewport for `intent` (⌘⇧J open / ⌘⇧Y copy / reveal). Reads the live
    /// surface's viewport rows (``TerminalViewportSnapshotting``), detects every hintable target
    /// (``HintLabelAssigner/targets(rows:cwd:schemes:patterns:maxScanColumns:)``), and assigns collision-free
    /// 2-letter labels. A NO-OP when there is no live surface (headless / placeholder), when the surface is on
    /// the ALT screen (don't fight a TUI), or when no target is found — so the chord never enters an empty mode.
    ///
    /// CEILING: a "Hint to copy" intent could in principle also scan SCROLLBACK, but a label can only be
    /// SHOWN over a visible cell, so all three intents scan the visible viewport here (a scrollback-copy
    /// refinement is deferred — DECISIONS).
    public func beginHint(_ intent: HintIntent) {
        guard !isAlternateScreen, let snapshot = surface as? TerminalViewportSnapshotting else { return }
        let targets = HintLabelAssigner.targets(
            rows: snapshot.viewportTextRows(),
            cwd: linkCwd,
            schemes: SettingsKey.linkSchemePolicy,
            patterns: SettingsKey.hintPatternList,
        )
        guard !targets.isEmpty else { return }
        let labels = HintLabelAssigner.labels(count: targets.count)
        // `labels` is bounded at alphabet² — keep only as many targets as got a label (never an unlabelled one).
        let count = min(targets.count, labels.count)
        hintTargets = Array(targets.prefix(count))
        hintLabels = Array(labels.prefix(count))
        hintTyped = ""
        hintMode = intent // observable flip LAST, so the overlay reads the ready targets/labels
    }

    /// An abstract Hint Mode key — the renderer maps an `NSEvent` to this via ``makeHintKey(event:)`` (the only
    /// NSEvent-aware point), keeping ``handleHintKey(_:)`` pure + unit-testable without a window server.
    public enum HintKey: Equatable, Sendable {
        /// A label character (case-insensitive; only `a`–`z` are meaningful).
        case character(Character)
        /// `Esc` — cancel the mode, no action.
        case escape
        /// `Backspace` — undo the last typed label letter.
        case delete
    }

    #if canImport(AppKit)
    /// Maps a real `NSEvent` to the abstract ``HintKey`` (the ONLY NSEvent-touching point, called from the
    /// app-target renderer's `keyDown` while ``hintMode`` is set). Excluded from the pure unit tests, which
    /// build `HintKey` cases directly. Special keys (Esc / Backspace) by key code; any other key collapses to
    /// its first character (Command-combos are app shortcuts intercepted upstream, never reaching here).
    public static func makeHintKey(event: NSEvent) -> HintKey {
        switch event.keyCode {
        case 53: return .escape // Escape
        case 51: return .delete // Backspace (Delete)
        default: break
        }
        let char = event.charactersIgnoringModifiers?.first ?? "\u{0}"
        return .character(char)
    }
    #endif

    /// The PHONE peer of ``makeHintKey(event:)`` — the same abstract ``HintKey`` off a
    /// ``PhoneKey/Press``. Un-gated for the reason ``makeCopyModeKey(_:)`` is: a mapping only the iOS
    /// triple compiles is a mapping no test on this runner can reach.
    ///
    /// Esc and Backspace come from ``PhoneKey/modalKey(_:)``, the one HID table; every other press —
    /// a label letter, and equally an arrow, which hint mode does not bind — collapses to its
    /// character, and ``handleHintKey(_:)`` ignores the ones that match no label.
    public static func makeHintKey(_ press: PhoneKey.Press) -> HintKey {
        switch PhoneKey.modalKey(press) {
        case .escape: .escape
        case .backspace: .delete
        default: .character(press.charactersIgnoringModifiers.first ?? "\u{0}")
        }
    }

    /// PURE Hint Mode dispatch: accumulate the typed label, dim via ``HintLabelAssigner/filter(typed:labels:)``,
    /// and fire ``onHintConfirmed`` the instant a 2-letter label fully matches (no Enter). `Esc` cancels;
    /// `Backspace` undoes a letter; a key that matches NO label is ignored (the typed prefix is kept), so a
    /// stray keystroke neither corrupts the prefix nor leaks to the shell. A no-op when not in hint mode.
    public func handleHintKey(_ key: HintKey) {
        guard let intent = hintMode else { return }
        switch key {
        case .escape:
            cancelHintMode()
        case .delete:
            if !hintTyped.isEmpty { hintTyped.removeLast() }
        case let .character(character):
            let candidate = hintTyped + String(character).lowercased()
            let result = HintLabelAssigner.filter(typed: candidate, labels: hintLabels)
            if let confirmed = result.confirmed, let index = hintLabels.firstIndex(of: confirmed) {
                let target = hintTargets[index]
                cancelHintMode()
                onHintConfirmed?(target, intent)
            } else if result.matched.isEmpty {
                return // a non-matching key: ignore it, keep the prefix (never accumulate junk / leak)
            } else {
                hintTyped = candidate
            }
        }
    }

    /// Resolve a target by a DIRECT tap (iOS soft-keyboard fallback — the labels are tappable when typing two
    /// keys is awkward; hint-mode spec). Fires the same ``onHintConfirmed`` path as a macOS key-resolve, then exits.
    public func confirmHintTarget(_ target: HintTarget) {
        guard let intent = hintMode else { return }
        cancelHintMode()
        onHintConfirmed?(target, intent)
    }

    /// Leave Hint Mode (Esc, an `×`/scrim tap, or after a resolve) — clears the mode + session state.
    public func cancelHintMode() {
        hintMode = nil
        hintTyped = ""
        hintTargets = []
        hintLabels = []
    }

    // MARK: Replay byte-ring (surface-rebuild survival)

    /// Bounded FIFO of the COMPLETE `output` chunks fed to the surface, kept so a REBUILT surface can be
    /// repainted from scratch. When a leaf comes down, ``detachSurface(_:)`` closes the live surface;
    /// on the next mount ``attachSurface(_:)`` receives a BRAND-NEW empty one. The *connection never dropped*,
    /// so the host does NOT re-send the scrollback — without this ring the prior screen would be lost. On
    /// attach of a different surface instance we replay it (see ``attachSurface(_:)``).
    ///
    /// ⚠️ THIS IS THE FALLBACK, NOT THE ORDINARY PATH, and the canvas keeps it that way ON PURPOSE. Replay is
    /// LOSSY (see LIMITATION below), so `PaneCanvasMounting.mountedTabs` holds every RETAINED session's tabs
    /// in the tree rather than unmounting the ones off screen: an ordinary tab switch must not reach this ring
    /// at all. What still does: a session evicted from the LRU retention set and switched back to (its leaves
    /// were torn down for real), a pane whose KIND flips so the container rebuilds the leaf, and a session
    /// swapped under a stable pane id. That list is the imperative canvas's, and it is SHORTER than the
    /// SwiftUI one this ring was first written for — where an off-screen tab dismantled the representable and
    /// every switch paid the lossy repaint.
    ///
    /// Each element is one whole wire `output` payload; eviction drops WHOLE oldest chunks (never splits a
    /// `Data`) so a replayed chunk is always a complete prefix-aligned slice the VT parser can consume.
    /// `@ObservationIgnored`: replay buffer, not view state — it is mutated per output chunk, so tracking it
    /// would wake every armed leaf at wire rate for a value none of them draws.
    ///
    /// LIMITATION: replay is a naive re-feed of the retained raw bytes, prefixed with a DECSTR soft reset. It
    /// restores the *main-screen* scrollback faithfully for the common case, but is NOT a true VT snapshot: if
    /// the oldest still-relevant state was EVICTED past `maxRingBytes`, or the retained window STRADDLES an
    /// escape sequence whose opening bytes were evicted, or the host had switched to the ALT screen (vim/less)
    /// at the ring boundary, the replayed frame can differ from the live screen until the next host output
    /// corrects it. The soft reset bounds the damage (cursor/SGR/charset back to defaults) but cannot
    /// reconstruct alt-screen contents the host never re-sends.
    @ObservationIgnored private var ring: [Data] = []
    /// Index-cursor deque head for `ring` (the `MuxChannelSession.fifoHead` / `FrameDecoder.compactConsumed`
    /// idiom). Ingest APPENDs only; eviction pops by advancing this cursor instead of `Array.removeFirst()` —
    /// which is an O(count) memmove per pop, and interactive typing delivers 10–30-byte chunks so the ring
    /// holds ~10k+ elements at steady state: every chunk would pay an O(ring.count) shift on the main actor
    /// (and a big post-idle chunk an O(n²) burst) strictly BEFORE `feedBatch` — the keystroke-echo path.
    /// ``compactRingIfNeeded()`` bulk-reclaims the consumed prefix (amortized O(1) per eviction). Evicted
    /// slots are overwritten with an empty `Data` at pop time so their bytes release immediately, exactly as
    /// `removeFirst()` did. Invariant: `0 <= ringStart <= ring.count`; the LIVE ring is `ring[ringStart...]`
    /// — every reader iterates that slice, and every site that clears/reassigns `ring` resets this to 0.
    @ObservationIgnored private var ringStart = 0
    /// Threshold for bulk-compacting the evicted `ring` prefix: only once the dead prefix is both
    /// non-trivial (≥ 64 slots) AND at least half the array does one `removeFirst(k)` memmove reclaim it —
    /// amortized O(1) per eviction, bounded slack.
    private static let ringCompactThresholdSlots = 64
    /// Running total of the LIVE ring's (`ring[ringStart...]`) byte count, kept incrementally so eviction is
    /// O(evicted) not O(n) per ingest.
    @ObservationIgnored private(set) var ringByteCount: Int = 0
    /// Soft cap on the replay ring; whole oldest chunks are evicted once exceeded. ~256 KB is a generous
    /// several-screens scrollback while staying small enough to replay synchronously.
    @ObservationIgnored var maxRingBytes: Int = 256 * 1024

    /// Set when a reconnect campaign begins (``markReconnecting``); consumed by the NEXT
    /// ``ingestOutput`` to wipe the dead session's screen before the fresh shell paints.
    ///
    /// A reconnect can land on EITHER a fresh host shell (PATH B/C — output restarts at seq 1; the wipe must
    /// fire or the new prompt grafts onto the dead session's still-resident framebuffer + scrollback) OR a
    /// PATH-A reattach of the SAME live shell (host-side detach, on unless "Resume on Recovery" is off — the host replays only the
    /// un-acked tail and never re-sends the surviving screen, so the wipe must NOT fire). Which one is only
    /// knowable from the first post-reconnect output seq (``SlopDeskClient/SessionResumeOutcome``), so the
    /// boundary ARMS this flag pessimistically and the output pump (``observe(client:)``) resolves it against
    /// the client's verdict strictly BEFORE the first post-reconnect batch is ingested — see
    /// ``awaitingResumeOutcome``. We cannot key the wipe off `connectionStatus` because the `.reconnected` EVENT
    /// (a separate stream) flips it to `.connected` and could race the first output; a flag consumed in the
    /// OUTPUT path is order-deterministic (both run on the main actor, the wipe happening inline immediately
    /// before the first fresh chunk is fed). `@ObservationIgnored`: control flag, not view state.
    @ObservationIgnored private var pendingFreshSessionReset = false

    /// Armed alongside ``pendingFreshSessionReset`` at a session boundary; tells the output pump the
    /// fresh-session wipe still needs its fresh-vs-resumed verdict. The pump resolves it from
    /// ``SlopDeskClient/sessionResumeOutcome`` at the first non-empty, current-epoch batch: `.resumedSession`
    /// DISARMS the wipe (warm PATH-A reattach — the screen survives and must not be erased), `.freshShell`
    /// leaves it armed for the ingest pass to consume, `.undetermined` (pre-reconnect leftovers) defers to a
    /// later batch. `@ObservationIgnored`: control flag.
    @ObservationIgnored private var awaitingResumeOutcome = false

    /// Whether the NEXT resolved resume verdict should fire ``onResumeOutcomeResolved``.
    /// Armed by ``markReconnecting`` (a genuine drop being retried), CLEARED by ``reset`` (a fresh connect
    /// target / deliberate reconnect), so the user-facing "reattached vs fresh shell" toast fires only after an
    /// UNEXPECTED reconnect — never on first launch, never on a self-initiated ⇧⌘R. One-shot: cleared the moment
    /// it fires so one reconnect yields exactly one toast. `@ObservationIgnored`: control flag.
    @ObservationIgnored private var resumeOutcomeNotifiable = false

    public init(surface: (any TerminalSurface)? = nil) {
        self.surface = surface
    }

    // MARK: OUT path (renderer → host)

    /// Routes terminal OUT bytes (keystrokes libghostty-vt encoded) to the live client. A no-op while disconnected
    /// (``inputSink`` is `nil`). Called on the main actor by the renderer's `TerminalSurfaceDriver.onWrite` bridge.
    public func sendInput(_ data: Data) {
        // READ-ONLY gate: this is the SINGLE outbound ingress seam — every key/paste/IME-commit/
        // mouse-report/click-to-move byte libghostty-vt encodes funnels here via `onWrite`, plus the iOS
        // input-bar submit, the Ctrl+C0 raw fast-path, and the synchronized-input broadcast. Dropping at the
        // top (before `inputSink`/`syncInputTap`, before any echo-probe / glitch-caret bookkeeping) blocks
        // EVERY input path with one check, so neither the local host nor the broadcast siblings see the bytes.
        // A blocked input rings the rate-limited beep once, not per byte. Output ingest (`ingestBatch`/
        // `ingestPass`) is intentionally NOT gated — read-only never blocks inbound.
        if isReadOnly {
            rateLimitedBeep()
            return
        }
        if Self.echoProbeEnabled { probeInputAt = ContinuousClock.now }
        if glitchCaretMode != .off { noteGlitchCaretSend(data) }
        inputSink?(data)
        // Synchronized input: offer the SAME bytes to the broadcast fan-out (no-op when disarmed). After the
        // local send so the source pane echoes first; the store skips the source and guards re-entry.
        syncInputTap?(data)
    }

    // MARK: Glitch caret (predictive-echo v1 — docs/12 §B → docs/17 §2.4, docs/31 #3)

    /// The WAN typing-latency masker, in its sanctioned CONSERVATIVE form: we never paint predicted text (no
    /// shadow VT parser — the desync class docs/17 rejects); we only show a dim "input received" caret nudge
    /// when a keystroke's echo has not arrived within ``glitchWindow``. Reconciliation is therefore trivial:
    /// ANY host output hides the caret (the real render is truth), and a hard ``glitchExpiry`` bounds
    /// non-echoing prompts (`stty -echo`, `read -s`).
    ///
    /// Arming gates (ALL must hold):
    /// - mode: `.forced`, or `.rttGated` with the EWMA RTT above ``glitchRTTOnMS`` (hysteresis: stays armed
    ///   until it falls below ``glitchRTTOffMS`` — the 3 s ping cadence makes the gate signal slow; don't flap
    ///   at the boundary);
    /// - `.connected`, and the tracker says `.shellPrompt` — alt-screen TUIs (Claude Code, vim) do their own
    ///   full-screen echo discipline; mosh disables prediction there too (docs/17 §2.4 point 2);
    /// - the send is EXACTLY one printable ASCII byte (0x20...0x7E). Backspace (0x7F) retires one pending
    ///   keystroke; anything else (CR, ESC sequences, multi-byte = paste / committed IME text — Vietnamese
    ///   Telex composes to multi-byte UTF-8) CLEARS all pending state (the mosh `become_tentative`/paste-reset
    ///   analogue, stricter): predicted columns would desync instantly, so we never guess.
    public enum GlitchCaretMode: Sendable, Equatable {
        case off
        /// `SLOPDESK_GLITCH_CARET=1` — armed only while the measured RTT warrants it.
        case rttGated
        /// `SLOPDESK_GLITCH_CARET=force` — RTT gate bypassed, zero glitch window
        /// (loopback rig render verification; echo would otherwise win the race).
        case forced
    }

    private static func glitchCaretModeFromEnv() -> GlitchCaretMode {
        switch ProcessInfo.processInfo.environment["SLOPDESK_GLITCH_CARET"] {
        case "force": .forced
        case let .some(value) where !value.isEmpty && value != "0": .rttGated
        default: .off
        }
    }

    /// Read from the env once per model; internal-settable so headless tests drive the gate matrix without
    /// process-environment games.
    @ObservationIgnored var glitchCaretMode: GlitchCaretMode = TerminalViewModel.glitchCaretModeFromEnv()

    /// Echo-wait before the caret shows (mosh GLITCH_THRESHOLD territory: 150–250 ms).
    @ObservationIgnored var glitchWindow: Duration = .milliseconds(175)
    /// Hard ceiling on a shown caret with no echo at all (non-echoing prompts).
    @ObservationIgnored var glitchExpiry: Duration = .milliseconds(1500)
    /// RTT hysteresis (EWMA from ping/pong, 3 s cadence): arm above on, disarm below off.
    static let glitchRTTOnMS: Double = 30
    static let glitchRTTOffMS: Double = 20

    /// TRUE while the dim caret overlay should draw (the ONE observable output of the whole feature —
    /// everything else is plain bookkeeping).
    public private(set) var glitchCaretVisible = false

    /// Keystrokes sent but not yet answered by ANY host output (positional, like the echo probe — conservative
    /// direction: any output clears, so the caret can only under-show, never over-show).
    @ObservationIgnored private var pendingEchoCount = 0
    @ObservationIgnored private var glitchTask: Task<Void, Never>?
    /// Hysteresis state of the RTT gate (`.rttGated` mode).
    @ObservationIgnored private var rttGateOpen = false
    /// Pane-local EWMA RTT mirror (folded from the `.rtt` event; diagnostics + gate).
    @ObservationIgnored public private(set) var paneLatencyMS: Double?
    /// Client-side `TerminalModeTracker` (DECSET/DECRST 1049/47/1047 + OSC-133) fed UNCONDITIONALLY in
    /// ``ingestPass`` — backs BOTH the glitch-caret alt-screen gate and the public ``isAlternateScreen``
    /// accessor the paste / backspace / scroll-past gates read. Its word-at-a-time skim makes a pass while
    /// every feature is off ONE scan for the next `ESC` — 0.172 µs over a 3 KiB chunk, measured (docs/55 §4c)
    /// — so tracking always keeps the alt-screen truth fresh even with the glitch caret disabled (its
    /// default).
    @ObservationIgnored private let modeTracker = TerminalModeTracker()

    /// TRUE while the host terminal is on the ALTERNATE screen — a full-screen TUI (vim, htop, less, a
    /// fullscreen Claude Code) owns the viewport. Derived from ``modeTracker`` (the real DECSET 1049/47/1047
    /// parse), NOT the coarse `shellActivity == .running` proxy — which is true for ANY foreground command
    /// (cat, a Python REPL, `npm install`), so using it as the alt-screen flag would over-suppress the
    /// paste-protection / backspace gates inside ordinary running commands. Those GUI gates read this so they
    /// suppress ONLY inside a true full-screen TUI.
    public var isAlternateScreen: Bool { modeTracker.mode == .altScreen }

    /// TRUE while the terminal sits at an EDITABLE shell prompt: connected, OSC-133 idle, and no
    /// full-screen program holding the alternate screen.
    ///
    /// The one derivation every prompt-gated feature reads — ⌘X's delete half
    /// (``CutSelectionPolicy``) and ⌘Z's readline undo (``PromptEditPolicy``), on both shells. It lives
    /// here because all three facts do, and because it was written out by hand at each call site until
    /// the second shell needed it: three ANDs is exactly the size of rule two copies agree on until one
    /// of them gains a term.
    public var isAtEditablePrompt: Bool {
        connectionStatus.isLive && shellActivity == .idle && !isAlternateScreen
    }

    /// The app's own command-line editor — `docs/68` §5.4, the half of the Warp-class terminal that is
    /// not blocks. One per pane, alive for the pane's whole life so the history survives every command.
    ///
    /// ⚠️ NOT `@Observable`, and deliberately: every edit arrives from a key event the renderer view is
    /// already handling, so the view that mutates it is the view that redraws. Publishing it would add a
    /// diff pass per keystroke to learn what the caller already knew.
    @ObservationIgnored public let commandPrompt = CommandPrompt()

    /// Whether the editor owns the keyboard for the NEXT press.
    ///
    /// Three terms, and each is a different kind of no. The setting is the user's
    /// (``SettingsKey/commandPromptEnabled`` — off means `readline` is the editor, as in every other
    /// terminal). ``isAtEditablePrompt`` is the shell's: mid-command or under a full-screen TUI the
    /// bytes belong to the program, and OSC-133 is what says which. Copy mode is the app's own modal
    /// layer and outranks both.
    ///
    /// A press is offered here BEFORE the input method, so this must not consult anything that changes
    /// mid-composition.
    public var commandPromptArmed: Bool {
        SettingsKey.commandPromptEnabled && isAtEditablePrompt && !takesModalKeys
    }

    /// Runs what the editor holds, if the document is closed.
    ///
    /// The line goes out through ``sendInput(_:)`` — the pane's ONE ordered OUT FIFO, the same one
    /// keystrokes and the input bar ride — and the shell echoes it, which is what opens the block. The
    /// editor is empty again and the command is in its history before this returns.
    ///
    /// `false` means the document was still open (a quote, a `$(`, a trailing `\`): the key added a
    /// line instead, and ``CommandPrompt/unterminated`` names what is holding it open.
    @discardableResult
    public func submitCommandPrompt() -> Bool {
        guard case let .run(command) = commandPrompt.submit() else { return false }
        var bytes = Data(command.utf8)
        bytes.append(0x0D) // CR — what a shell's line discipline reads as Enter.
        sendInput(bytes)
        return true
    }

    /// The OBSERVABLE twin of ``isAlternateScreen`` — the same truth, readable by an overlay that needs to
    /// be told when it changes. Same idiom as the ``isCopyMode``/``copyModeBadgeActive`` pair above,
    /// and here for the same reason: ``modeTracker`` is `@ObservationIgnored`, so reading
    /// ``isAlternateScreen`` inside a `withObservationTracking` closure registers **nothing**. Two overlay
    /// headers claimed it did.
    ///
    /// WHAT THAT COSTS, precisely, because it is not "the overlay never updates". A screen flip
    /// arrives WITH bytes, so an arm that also reads an ingest-driven property re-fires on the
    /// next chunk and looks correct. The miss is the quiet case: ⌘ held over a pane that flips to a
    /// full-screen TUI and then stops producing output leaves the link underlines drawn over vim —
    /// decoration positioned by a grid that no longer exists. A wrong mark, not a missing one, which
    /// is the failure this overlay family says it refuses.
    ///
    /// Mirrored from ``ingestPass`` rather than computed, because the tracker's own mode is only
    /// re-read there and at the two session-boundary resets.
    public private(set) var alternateScreenActive = false

    /// TRUE while the foreground program has bracketed-paste mode (DECSET `?2004h`) enabled — the real
    /// parse from the host output stream (the same bracketed state the engine's surface derives). The
    /// paste-protection pre-check reads this as `programAdvertisedBracketed`: with the "Paste Bracketed
    /// Safe" setting on, a program that frames the paste as an inert bracketed block does not trip the
    /// sheet, matching the engine's own `clipboard-paste-bracketed-safe` gate that the embedder preempts.
    public var isBracketedPasteActive: Bool { modeTracker.bracketedPasteActive }

    /// TRUE while the foreground program has DECCKM (application cursor keys, DECSET `?1h`) enabled —
    /// the real parse from the host output stream. The iOS hand-rolled key path reads this to emit SS3
    /// arrows (`ESC O A`) instead of CSI (`ESC [ A`) while a full-screen app has switched cursor-key
    /// mode (docs/29 backlog #6); macOS never consults it (the engine's surface owns DECCKM there).
    public var isCursorKeysApplication: Bool { modeTracker.cursorKeysApplication }

    private var glitchCaretArmed: Bool {
        guard connectionStatus == .connected, modeTracker.mode == .shellPrompt else { return false }
        switch glitchCaretMode {
        case .off: return false
        case .forced: return true
        case .rttGated: return rttGateOpen
        }
    }

    /// OUT-side classification (see the gate list above). Called per keystroke — cheap.
    private func noteGlitchCaretSend(_ data: Data) {
        guard glitchCaretArmed else {
            clearGlitchCaret()
            return
        }
        if data.count == 1, let byte = data.first {
            switch byte {
            case 0x20...0x7E:
                pendingEchoCount += 1
                if pendingEchoCount == 1 { armGlitchTimer() }
            case 0x7F:
                pendingEchoCount = max(0, pendingEchoCount - 1)
                if pendingEchoCount == 0 { clearGlitchCaret() }
            default:
                clearGlitchCaret() // CR, Ctrl-*, ESC — a state change we won't model
            }
        } else {
            clearGlitchCaret() // paste / IME / encoded escape sequence
        }
    }

    /// One timer per pending RUN, armed when the count goes 0→1 (the glitch window is measured from the OLDEST
    /// unanswered keystroke, as in mosh): show after ``glitchWindow`` if still unanswered, force-hide at
    /// ``glitchExpiry``.
    private func armGlitchTimer() {
        glitchTask?.cancel()
        let window = glitchWindow
        let expiry = glitchExpiry
        glitchTask = Task { [weak self] in
            // Weak across both sleeps — a parked timer must not extend the model's life.
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, (self?.pendingEchoCount ?? 0) > 0 else { return }
            self?.glitchCaretVisible = true
            try? await Task.sleep(for: expiry)
            guard !Task.isCancelled else { return }
            self?.clearGlitchCaret()
        }
    }

    /// Hides the caret and forgets all pending keystrokes. Idempotent and cheap (the observable flag is only
    /// written on a real change).
    private func clearGlitchCaret() {
        pendingEchoCount = 0
        glitchTask?.cancel()
        glitchTask = nil
        if glitchCaretVisible { glitchCaretVisible = false }
    }

    // MARK: Echo probe (rig instrumentation — docs/31 follow-up #4)

    /// `SLOPDESK_ECHO_PROBE=1`: print a keystroke→first-output-ingest latency line per echo to stderr, so
    /// `slopdesk-guigate macos --connect` (an idle pane + AUTOTYPE) emits real keystroke-feel numbers instead of
    /// pass/fail — the A/B harness for smoothness work. The measured span = wire out + host PTY round trip +
    /// wire back + client delivery up to the render feed (the user-feel path minus the final present tick).
    /// Rig-only: matching is positional (NEXT ingest after a send = the echo), correct for an idle interactive
    /// pane, meaningless under an output flood. Zero hot-path cost when off (one static-bool branch).
    private static let echoProbeEnabled =
        ProcessInfo.processInfo.environment["SLOPDESK_ECHO_PROBE"] != nil
    @ObservationIgnored private var probeInputAt: ContinuousClock.Instant?

    /// Mirrors a grid resize to the host (`TIOCSWINSZ`). A no-op while disconnected. Called on the main actor
    /// by the renderer's `TerminalSurfaceDriver.setGeometry` bridge. Coalesces consecutive duplicates (same cols/rows) so
    /// the engine's double-emit per layout pass forwards at most one resize.
    public func sendResize(cols: UInt16, rows: UInt16) {
        pendingSize = (cols, rows) // record the latest grid even if not connected yet
        deliverResizeIfNeeded()
    }

    /// Suspends/resumes forwarding grid resizes to the host (the interactive divider-drag gate). While
    /// suspended, `sendResize` keeps recording the latest grid but delivers nothing; resuming flushes the final
    /// grid ONCE. Idempotent — a redundant call does nothing (so begin/begin or end/end can't double-flush). The
    /// shell raises it on a sidebar/inspector-divider mouse-down and drops it on mouse-up.
    public func setResizeSuspended(_ suspended: Bool) {
        guard suspended != resizeDeliverySuspended else { return }
        resizeDeliverySuspended = suspended
        if !suspended {
            deliverResizeIfNeeded() // flush the grid the drag settled on
            // …then let the renderer re-anchor its present-burst to THIS release moment, so the host's
            // SIGWINCH redraw bytes (arriving ~1 RTT after the deferred flush above) are painted even
            // when the layout-anchored burst has already expired. See ``onResizeSettled``.
            onResizeSettled?()
        }
    }

    /// Forwards ``pendingSize`` to the host via ``resizeSink`` if it differs from the last delivered size.
    /// Called from ``sendResize`` (grid changed) AND from `resizeSink.didSet` (sink wired on connect) — so the
    /// host learns the real grid regardless of which happens first. A no-op while the sink is nil, leaving
    /// `lastSentSize` untouched so the dedup never suppresses the eventual first real send.
    private func deliverResizeIfNeeded() {
        guard !resizeDeliverySuspended else { return } // held for the interactive divider drag
        guard let sink = resizeSink, let sz = pendingSize else { return }
        let previous = lastSentSize
        if let last = previous, last.cols == sz.cols, last.rows == sz.rows { return }
        lastSentSize = sz
        sink(sz.cols, sz.rows)
        // A grid CHANGE from a KNOWN prior size means the host will reflow → hold the resize scrim until those
        // bytes land. The FIRST delivery after a (re)connect / `resendCurrentSize` / a freshly-wired sink all
        // reset `lastSentSize` to nil (previous == nil) and so do NOT arm it — the surface paints from scratch
        // there, with no stale frame to bridge. See ``awaitingResizeReflow``.
        if previous != nil { beginAwaitingReflow() }
    }

    /// Forces a re-delivery of the latest grid (``pendingSize``) to the sink, bypassing the dedup. Called right
    /// AFTER the client finishes connecting: a resize delivered to the OUT drain DURING the mux handshake makes
    /// `SlopDeskClient.sendResize` throw `invalidState("sendResize before connect")`, which the drain's `try?`
    /// silently swallows — yet `lastSentSize` was already recorded, so the dedup would block every later send
    /// and the host PTY would stay at its 80×24 init grid (the garbled-render / overlapping-glyph bug).
    /// Re-arming + re-delivering here sends the real grid once the host is ready to accept it.
    public func resendCurrentSize() {
        lastSentSize = nil
        deliverResizeIfNeeded()
    }

    // MARK: Resize-reflow scrim signal

    /// Belt-and-braces ceiling on ``awaitingResizeReflow``: if the host answers a committed grid change with NO
    /// output (a dead link, or a foreground app that ignores SIGWINCH), the scrim must still clear. Long enough
    /// not to pre-empt a slow-WAN reflow (so the scrim genuinely bridges to the fresh pixels), short enough that
    /// a no-reflow corner case does not linger a dim for seconds. Instance-settable so tests drive it without
    /// real-time waits.
    @ObservationIgnored var reflowScrimTimeout: Duration = .milliseconds(1200)
    @ObservationIgnored private let reflowDeadline = DeadlineLatch()

    /// Arms ``awaitingResizeReflow`` for a just-sent grid change and (re)starts the safety timeout.
    private func beginAwaitingReflow() {
        awaitingResizeReflow = true
        reflowDeadline.arm(after: reflowScrimTimeout) { [weak self] in self?.endAwaitingReflow() }
    }

    /// Clears ``awaitingResizeReflow`` (the reflow bytes landed, the link died, or the safety timeout fired) and
    /// cancels the pending timeout. Idempotent — the observable is only written on a real change, so the
    /// per-pass call from ``ingestPass`` is free once the flag is already down.
    private func endAwaitingReflow() {
        reflowDeadline.cancel()
        if awaitingResizeReflow { awaitingResizeReflow = false }
    }

    // MARK: Stream observation

    /// Drains the client's `output` byte stream ONLY, folding each chunk into observable state. Driven by
    /// ``ConnectionViewModel``'s `outputTask` — a `Task { @MainActor [weak self] in await self?.terminal
    /// .observe(client:) }` started on connect and cancelled on teardown, so the pump's lifetime is the
    /// CONNECTION's and not any view's. Returns when the output stream finishes (client closed / child exited).
    ///
    /// ### Single events consumer (the race this avoids)
    /// The view-model does **not** open its own `for await client.events` loop. Events are owned by the
    /// ``ConnectionViewModel`` (the single UI-layer events consumer), which folds the connect/drop signal into
    /// the chrome status AND forwards each event here via ``handle(_:)``. Two independent loops over the *same*
    /// event source would split the stream nondeterministically (output is safe because the model is its sole
    /// consumer).
    public func observe(client: SlopDeskClient) async {
        connectionStatus = .connecting
        for await _ in client.outputWakeups {
            // Epoch snapshot BEFORE the take, so a batch is tagged with the session it was taken FROM.
            // `markReconnecting()` (epoch bump + fresh-wipe arm) runs on this same MainActor and can interleave
            // while we are suspended in `takeOutputBatch()`. Reading `sessionEpoch` AFTER the take resumes (the
            // old code) tags the DEAD session's in-hand bytes with the NEW epoch — the ingestBatch guard then
            // passes them through and they consume the fresh-session wipe (painting stale output under the new
            // prompt). Capturing before means dead bytes carry the OLD epoch and ingestBatch drops them; the
            // fresh session's bytes arrive on a LATER wake, taken under the bumped epoch, and paint correctly.
            // (The inverse risk — a take returning NEW bytes under a stale snapshot — needs an entire network
            // reconnect to complete inside the sub-µs `takeOutputBatch` actor hop, which cannot happen.)
            let epoch = sessionEpoch
            let batch = await client.takeOutputBatch()
            await resolveResumeOutcomeIfNeeded(client: client, epoch: epoch, batchIsEmpty: batch.isEmpty)
            await ingestBatch(batch, epoch: epoch)
        }
        // FINAL DRAIN: a tail appended just before the wake stream finished (exit/close) has no wake left to
        // announce it — take it explicitly. ONLY on a natural finish: a CANCELLED observe (teardown/reconnect
        // replaced this pump) must NOT take — it would paint the dead session's tail into the freshly-reset
        // pane and credit those bytes to the wrong (new) transport.
        guard !Task.isCancelled else { return }
        let tailEpoch = sessionEpoch
        let tail = await client.takeOutputBatch()
        await resolveResumeOutcomeIfNeeded(client: client, epoch: tailEpoch, batchIsEmpty: tail.isEmpty)
        await ingestBatch(tail, epoch: tailEpoch)
    }

    /// Resolves the armed fresh-session wipe against the client's fresh-vs-resumed verdict
    /// (``SlopDeskClient/SessionResumeOutcome``), strictly BEFORE the batch in hand is ingested — the wipe
    /// decision rides the OUTPUT path so it can never race the first post-reconnect paint.
    ///
    /// Only a non-empty batch tagged with the CURRENT epoch may resolve (a dead session's in-hand batch is
    /// dropped by `ingestBatch` and must not decide the new session's wipe), and the epoch is re-checked after
    /// the cross-actor read (a newer boundary can interleave at the await). `.undetermined` — output delivered
    /// by the OLD link before the drop — defers resolution to a later (post-reconnect) batch. `.freshShell`
    /// keeps the wipe armed (the ingest pass consumes it as before); `.resumedSession` disarms it — a PATH-A
    /// reattach resumes the SAME shell byte-exactly and the host never re-sends the surviving screen, so wiping
    /// would erase it permanently (the "every network blip clears the terminal" bug).
    private func resolveResumeOutcomeIfNeeded(client: SlopDeskClient, epoch: Int, batchIsEmpty: Bool) async {
        guard awaitingResumeOutcome, !batchIsEmpty, epoch == sessionEpoch else { return }
        let outcome = await client.sessionResumeOutcome
        guard epoch == sessionEpoch else { return } // a newer session boundary interleaved at the hop
        switch outcome {
        case .resumedSession:
            awaitingResumeOutcome = false
            pendingFreshSessionReset = false
            notifyResumeOutcome(.resumedSession)
        case .freshShell:
            awaitingResumeOutcome = false // leave the armed wipe for the ingest pass to consume
            notifyResumeOutcome(.freshShell)
        case .undetermined:
            break // pre-reconnect leftovers — the verdict arrives with a later batch
        }
    }

    /// Surfaces the resolved fresh-vs-resumed verdict to the UI (via ``onResumeOutcomeResolved``)
    /// ONCE per reconnect. A no-op unless ``resumeOutcomeNotifiable`` is armed (only ``markReconnecting`` arms
    /// it; ``reset`` clears it), so a first-ever connect / deliberate ⇧⌘R never fires a toast. One-shot: disarm
    /// before firing so one reconnect yields exactly one notification.
    private func notifyResumeOutcome(_ outcome: SlopDeskClient.SessionResumeOutcome) {
        guard resumeOutcomeNotifiable else { return }
        resumeOutcomeNotifiable = false
        onResumeOutcomeResolved?(outcome)
    }

    /// Monotonic SESSION boundary counter, bumped by ``markReconnecting()`` and ``reset()``. The output pump
    /// snapshots it when it takes a batch and passes it to ``ingestBatch(_:epoch:)``, which re-checks before
    /// EVERY pass — so a batch taken from the DEAD session can never cross a reconnect boundary and paint (or
    /// consume the one-shot fresh-session wipe) after the boundary, however long the pump was parked at a
    /// suspension point in between.
    @ObservationIgnored private(set) var sessionEpoch = 0

    /// Max bytes fed to the surface per synchronous MainActor pass. Between passes the drain yields so input
    /// events, the renderer's display link, and the shells' woken observation handlers + their layout pass can
    /// interleave — a multi-MB backlog (cat of a big file) no longer monopolizes the main thread in one job.
    static let ingestByteBudget = 256 * 1024

    /// Folds a BATCH of `output` chunks in budget-bounded synchronous passes: each pass runs ring bookkeeping
    /// per chunk, then ONE `surface.feedBatch` (one renderer flush). `Task.yield()` only BETWEEN passes — never
    /// inside one (doc-18-§C: the surface's write/flush trio must not interleave with suspension).
    ///
    /// RENDER-SIDE BACKPRESSURE: before EVERY pass (including the first) the pump awaits
    /// ``FeedBackpressuring/feedBackpressure()`` when the surface conforms. With an asynchronous feed the
    /// mux's credit-at-consumption would otherwise decouple wire credit from parse progress — `takeOutputBatch` grants window credit the moment the pump TAKES bytes,
    /// so a flood would pile up un-parsed in the feed queue without bound. Parking here stops the take → stops
    /// the credit → the wire window holds the flood at the host, end-to-end. Synchronous surfaces (tests,
    /// headless) don't conform — no await.
    ///
    /// STALE-BATCH GUARDS: the backpressure park is a long suspension that lands exactly when
    /// floods (and therefore drops/reconnects) happen, so after EVERY await the batch must re-earn the right to
    /// paint: `Task.isCancelled` covers a replaced pump (teardown/reconnect cancelled it), and the `epoch` check
    /// covers a supervisor reconnect that does NOT cancel the pump — either way a dead session's in-hand bytes
    /// must not consume the new session's one-shot wipe or pollute the fresh replay ring.
    public func ingestBatch(_ chunks: [Data], epoch: Int? = nil) async {
        guard !chunks.isEmpty else { return }
        var i = 0
        while i < chunks.count {
            if let backpressured = surface as? any FeedBackpressuring {
                await backpressured.feedBackpressure()
                if Task.isCancelled { return }
            }
            if let epoch, epoch != sessionEpoch { return }
            var end = i
            var passBytes = 0
            repeat {
                passBytes += chunks[end].count
                end += 1
            } while end < chunks.count && passBytes < Self.ingestByteBudget
            ingestPass(chunks[i..<end])
            i = end
            if i < chunks.count {
                await Task.yield()
                // A teardown/reconnect cancelled this pump mid-batch: stop painting the dead session's
                // remaining passes (the new session's fresh-wipe ingest can interleave at the yield above —
                // later dead passes would land AFTER it).
                if Task.isCancelled { return }
                if let epoch, epoch != sessionEpoch { return }
            }
        }
    }

    /// Folds one `output` chunk (the single-chunk pass — the synchronous API for tests and direct feeders).
    public func ingestOutput(_ chunk: Data) {
        ingestPass([chunk])
    }

    /// One fully-synchronous ingest pass: feed the renderer + bump telemetry. The first byte flips
    /// `.connecting`/`.reconnecting` → `.connected` (we are receiving from the host).
    ///
    /// Order matters: every chunk is retained in the replay ring (evicting whole oldest chunks to stay under
    /// ``maxRingBytes``) BEFORE the batch is fed to the surface, so the ring is always a superset/peer of what
    /// the live surface has seen — a same-tick rebuild + replay reproduces the current screen. NO `await` may
    /// be introduced here (doc-18-§C).
    private func ingestPass(_ chunks: ArraySlice<Data>) {
        if Self.echoProbeEnabled, let sentAt = probeInputAt {
            probeInputAt = nil
            let elapsed = sentAt.duration(to: ContinuousClock.now).components
            let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            FileHandle.standardError.write(Data(String(format: "[echo-probe] key→ingest %.1fms\n", ms).utf8))
        }
        // Alt-screen tracking is fed UNCONDITIONALLY: the public `isAlternateScreen` accessor (read by the
        // paste / backspace / scroll-past gates) must be fresh even when the glitch caret is off (its default).
        // A ground-content chunk carries no `ESC` at all, so the tracker's word-at-a-time skim decides that in
        // ONE pass at a measured 18 GB/s and reaches the transition table for nothing.
        //
        // ONE crossing per chunk, and the `_ =` costs none of them: `consume` answers a COUNT, and the Swift
        // face reads a parked event only when that count is non-zero. Marks are OSC 133 boundaries — a handful
        // per COMMAND, not per chunk — so the discarded array is empty (and allocation-free) on the hot path,
        // and 4 extra crossings cost a measured 0.5% of the one call that produced them on the rare chunk that
        // brackets a command. It is the skim that this loop costs, not the boundary.
        for chunk in chunks {
            _ = modeTracker.consume(chunk)
        }
        // Publish the alt-screen truth to the observable twin. Assigned only on a CHANGE: this runs on
        // every ingest, and an unconditional write to an `@Observable` property wakes every reader on
        // every chunk of output — which is the whole terminal, continuously.
        let onAltScreen = modeTracker.mode == .altScreen
        if alternateScreenActive != onAltScreen { alternateScreenActive = onAltScreen }
        // Glitch caret (docs/31 #3): host output is ground truth — ANY ingest hides the caret (the whole
        // reconciliation policy: we never painted characters, so a "misprediction" can only be a caret shown
        // one output-gap too long).
        if glitchCaretMode != .off {
            clearGlitchCaret()
        }
        // FRESH-SESSION WIPE: the first output after a reconnect belongs to a brand-new host shell (the mux
        // path never resumes). Hard-reset the live surface and drop the dead session's replay ring BEFORE this
        // pass paints, so the user sees a clean shell instead of the old framebuffer with a new prompt grafted
        // on. Inline here (not on the `.reconnected` event) so the wipe is strictly ordered before the fresh
        // bytes — no cross-stream race.
        if pendingFreshSessionReset {
            pendingFreshSessionReset = false
            ring.removeAll()
            ringStart = 0
            ringByteCount = 0
            surface?.feed(Self.risHardReset)
        }
        if connectionStatus == .connecting || connectionStatus == .reconnecting {
            connectionStatus = .connected
        }

        // Retain WHOLE copies in the bounded replay ring, then evict whole oldest chunks until back under the
        // cap (never split a Data — a partial chunk could cut an escape sequence and corrupt the replay).
        // Per-wire-chunk granularity is deliberate: concatenating would memcpy and coarsen eviction.
        var passBytes = 0
        for chunk in chunks {
            passBytes += chunk.count
            ring.append(chunk)
            ringByteCount += chunk.count
            // Evict by ADVANCING the head cursor (O(1) per evicted chunk — `removeFirst()` would memmove the
            // whole tail on the main actor, right ahead of `feedBatch`). Overwriting the popped slot releases
            // its bytes immediately; the dead prefix is bulk-reclaimed below.
            while ringByteCount > maxRingBytes, ring.count - ringStart > 1 {
                ringByteCount -= ring[ringStart].count
                ring[ringStart] = Data()
                ringStart += 1
            }
            compactRingIfNeeded()
        }
        // ONE observable mutation per pass, not one per chunk: every write to an `@Observable` property wakes
        // every arm that read it, and a woken arm RE-ARMS — so the per-chunk spelling would charge each
        // reader a full re-registration for every wire payload in the backlog.
        bytesReceived += passBytes

        surface?.feedBatch(chunks)
        // Host output after a committed grid change = the reflow has landed and is rendering → release the
        // resize scrim. Idempotent + cheap when not awaiting (the common keystroke-echo case). Cleared on ANY
        // post-resize content, not only the SIGWINCH redraw — both repaint at the new grid, so either is a
        // faithful "the resized content has re-rendered". See ``awaitingResizeReflow``.
        if awaitingResizeReflow { endAwaitingReflow() }
    }

    /// Bulk-reclaims the evicted `ring` prefix once it is both non-trivial (≥ ``ringCompactThresholdSlots``)
    /// AND at least half the array — ONE `removeFirst(k)` memmove, amortized O(1) per eviction. The evicted
    /// slots hold empty `Data` (their bytes were released at pop time), so compaction only reclaims the
    /// array's slot storage.
    private func compactRingIfNeeded() {
        guard ringStart >= Self.ringCompactThresholdSlots, ringStart >= ring.count / 2 else { return }
        ring.removeFirst(ringStart)
        ringStart = 0
    }

    // MARK: Surface attach / detach (replay across rebuild)

    /// DECSTR — Soft Terminal Reset (`ESC [ ! p`). Prefixed to a replay so a freshly-built surface starts from
    /// a known state (default SGR/charset/origin-mode, cursor home) before the retained bytes repaint over it. A
    /// soft (not hard `ESC c`) reset preserves the scrollback the replayed bytes are about to redraw.
    private static let decstrSoftReset = Data([0x1B, 0x5B, 0x21, 0x70])

    /// RIS — Reset to Initial State (`ESC c`). A HARD reset: clears the screen + scrollback and returns the
    /// emulator to power-on defaults. Fed to the surface on a fresh-session reconnect so the dead session's
    /// framebuffer is gone before the new shell paints (unlike the soft reset used for replay, which
    /// deliberately preserves scrollback the replay is about to redraw).
    private static let risHardReset = Data([0x1B, 0x63])

    /// Attaches a renderer surface and, if this is a *different* instance than the one currently held and the
    /// replay ring is non-empty, REPLAYS the retained output so a rebuilt surface (see ``ring`` for the three
    /// paths that still rebuild one) shows the prior screen even though the host did not re-send it.
    ///
    /// Replay is fully synchronous (DECSTR soft reset, then every retained chunk in FIFO order) to honor the
    /// surface main-thread no-`await` contract ([18 §C] — `feed`/`refresh`/`draw` must not interleave with
    /// suspension). Attaching the SAME instance again does NOT replay — the bytes are already on screen and
    /// re-feeding would duplicate them. The caller, `TerminalSurfaceDriver.bind(to:)`, is deliberately
    /// idempotent and re-runs on every re-mount, so that guard is load-bearing rather than defensive.
    public func attachSurface(_ surface: any TerminalSurface) {
        let isDifferentInstance = (self.surface !== surface)
        self.surface = surface
        guard isDifferentInstance, ring.count > ringStart else { return }
        // One batch = one renderer flush for the whole replay (the view follows with its own requestPresent
        // burst on attach). Only the LIVE window (`ring[ringStart...]`) replays — slots below the head cursor
        // were evicted.
        surface.feedBatch(ArraySlice([Self.decstrSoftReset] + ring[ringStart...]))
    }

    /// Detaches the renderer surface — the leaf holding it came down (`teardown()`, or a `setLive` that swapped
    /// the session under a stable pane id). Drops the `weak` reference; the retained replay ring is KEPT so the
    /// next ``attachSurface(_:)`` can repaint.
    ///
    /// IDENTITY-GATED: only clears `self.surface` when `surface` IS the one we are currently feeding, because
    /// an OLDER surface can be closed AFTER a NEWER one already attached and became `self.surface`. A blind
    /// `self.surface = nil` there would stop feeding the LIVE (on-screen) surface — it then freezes on its
    /// initial replay while all new host output is silently dropped (the "renders the prompt then never
    /// repaints" bug, reproduced on a Mac Studio).
    ///
    /// ⚠️ THE GATE OUTLIVED THE FRAMEWORK THAT MOTIVATED IT. It was written when SwiftUI could build the
    /// terminal representable more than once for one pane (a sizing/identity pass), which is what made a stale
    /// duplicate ordinary. The imperative canvas builds one view per mount — but the ORDERING is still the
    /// renderer's to decide, not the model's: `TerminalSurfaceHosting.detachSurface()` passes the surface it is
    /// closing, and a view the factory built but nothing ever mounted makes NO call at all, precisely so it
    /// cannot reach the unconditional branch and nil out a live pane's surface. Deleting the gate would give
    /// the model an ordering guarantee no caller offers it.
    ///
    /// Called with no argument it clears unconditionally. That form has no production caller — it is the tests'
    /// spelling for "there is no surface any more, full stop".
    public func detachSurface(_ surface: (any TerminalSurface)? = nil) {
        if let surface {
            if self.surface === surface { self.surface = nil }
        } else {
            self.surface = nil
        }
    }

    /// Folds one `SlopDeskClient.Event` into observable state.
    public func handle(_ event: SlopDeskClient.Event) {
        switch event {
        case .retrying,
             .gaveUp,
             .log:
            // The reconnect ladder's own narration. It belongs to the CHROME — attempt counts, the
            // countdown and the log line are `ConnectionViewModel`'s to render — and the terminal
            // already learned everything it needs from the `.disconnected` that armed the campaign.
            break
        case let .title(text):
            // An EMPTY type-21 is the host's explicit RETIREMENT of a title an exiting agent owned,
            // never prompt-redraw noise: the host sniffer drops empty OSC 0/2 bodies (zsh/p10k emit
            // them mid-redraw), so the only way an empty title reaches this wire is because the host
            // meant it. Applying it drops the row back to its next rung (last command / cwd) instead
            // of showing a dead agent's `✳ <topic>` for the rest of the pane's life.
            // "Title — Shell Controlled" (default ON): when OFF, the client DROPS the OSC 0/2 title
            // update so a remote program cannot rewrite the tab/window title (the privilege gate).
            if SettingsKey.titleShellControlledEnabled { title = text }
        case .bell:
            bellPending = true
            // "Sound — Shell Controlled": a BEL rings the system beep (audio-only — no visual bell is
            // implemented). The pure ``BellPolicy`` gates it on the `soundShellControlled` toggle (default ON);
            // the injected ``beep`` seam actuates (so tests count without a real NSSound).
            if BellPolicy.shouldBeep(soundShellControlled: SettingsKey.soundShellControlledEnabled) {
                beep()
            }
        case let .commandStatus(status):
            switch status {
            case .running:
                shellActivity = .running
            case let .idle(exitCode, durationMS):
                shellActivity = .idle
                lastCommand = (exitCode, durationMS)
                // OSC 133;D ≡ the OSC 9;4;5 "remove" state. A program that drove a 9;4 bar/spinner and
                // finished WITHOUT an explicit 9;4;0 (or was killed mid-progress) must not leave a stuck
                // determinate/indeterminate badge — `ProgressOSCParser` DROPS state 5, so this completion edge
                // clears it. The store mirror is cleared on the same edge (handleCommandCompleted).
                progress = nil
                // "Sound on Error Exit": a non-zero exit beeps when enabled (default OFF; requires the
                // OSC-133 shell-integration mark that carries the exit code). Pure ``ErrorSoundPolicy`` → the
                // `soundOnErrorExit` toggle + a non-zero exit. Same `beep` seam.
                if ErrorSoundPolicy.shouldBeep(
                    exit: exitCode,
                    soundOnErrorEnabled: SettingsKey.soundOnErrorExitEnabled,
                ) {
                    beep()
                }
            }
        case .notification:
            // An explicit child notification (OSC 9 / OSC 777) is handled at the connection/store layer (it
            // posts a local UNUserNotification). The terminal model holds no state for it.
            break
        case .foregroundProcess,
             .claudeStatus:
            // Claude-Code detection signals (wire types 26/27) are folded into the pane's ClaudeStatusMachine
            // at the connection/store layer (→ WorkspaceStore.setAgentStatus). The terminal model holds no
            // state for them.
            break
        case .commandBlock,
             .blockOutput:
            // Warp-style Blocks (wire types 28/29): the metadata upsert + the output-request resolve both
            // fold into the per-pane block store, which drives the navigator / sticky header / chip.
            blocks.handle(event)
        case .metadataResponse:
            // Host metadata reply (wire type 30): correlated + decoded at the connection layer
            // (ConnectionViewModel folds it into the pane's MetadataRequestRegistry). The terminal model holds
            // no state for it.
            break
        case let .exit(code):
            connectionStatus = .exited(code: code)
            // The shell died mid-"command" (e.g. `exit` itself emits OSC 133;C but never a matching ;D), so the
            // running indicator would otherwise stay stuck on "running…" on a dead pane (HW-confirmed). Clear
            // it — a terminated shell runs nothing. (Mirrors `markReconnecting`, which clears this stale state
            // on a drop.)
            shellActivity = .idle
            progress = nil // a terminated shell reports no progress — never leave a stuck OSC 9;4 spinner
            clearGlitchCaret() // no host left to echo — drop the nudge immediately
            endAwaitingReflow() // a dead shell will not reflow — never leave the scrim hung
        case let .disconnected(reason):
            // A drop while we still want to be connected reads as "reconnecting" (the ReconnectManager is
            // retrying); the ConnectionViewModel owns the authoritative "user asked to disconnect" distinction.
            connectionStatus = .disconnected(reason: reason)
            // Same stale-OSC-133 guard as the exit/reconnect paths: a drop straddling a C→D pair would
            // otherwise pin the indicator on "running…" across the disconnect.
            shellActivity = .idle
            progress = nil // a dropped link's last OSC 9;4 is a lie for the reconnect — clear the indicator
            clearGlitchCaret()
            endAwaitingReflow() // a dropped link will not reflow — release the scrim
        case let .reconnected(sessionID, resumeFromSeq):
            self.sessionID = sessionID
            lastResumeSeq = resumeFromSeq
            connectionStatus = .connected
        case let .rtt(milliseconds):
            // ConnectionViewModel owns the badge's latencyMS; the pane-local mirror feeds the glitch caret's
            // hysteresis gate (docs/31 #3).
            paneLatencyMS = milliseconds
            if milliseconds > Self.glitchRTTOnMS {
                rttGateOpen = true
            } else if milliseconds < Self.glitchRTTOffMS {
                rttGateOpen = false
            }
        case let .inputEcho(enabled):
            // Secure input (wire type 31): the host signalled its PTY termios `ECHO` edge —
            // `enabled == false` means a no-echo password prompt is up. Fold into `hostNoEcho` (inverse); its
            // `didSet` refreshes the `secureInputActive` pill mirror and fires `onHostEchoChanged`, which the
            // macOS leaf forwards to the pane's `SecureKeyboardEntryController` to engage / disengage
            // process-global secure event input. Echo-on (the canonical default) clears it.
            hostNoEcho = !enabled
        case let .progress(state, percent):
            // OSC 9;4 PROGRESS (wire type 32): the host parsed the taskbar-style progress subtype out of
            // the OSC-9 stream, state validated at the client boundary. Fold into the observable `progress`
            // mirror — a `.clear` removes the indicator (`nil`), every other state sets the determinate /
            // indeterminate / error value the pane status strip + Dock read.
            progress = PaneProgress(state: state, percent: percent)
        case .cwd,
             .projectKey,
             .projectGitStatus,
             .agentSessionIntent:
            // All four are pane/project-METADATA edges the connection layer routes to the store
            // (`pane/cwd` / `pane/projectKey` / `projectGitSummary` / `paneAgentIntent`);
            // the terminal surface itself renders none of them.
            break
        }
    }

    // MARK: Blocks — copy-output flow

    /// How long to wait for a `blockOutput` reply before giving up (the belt-and-braces guard so the copy UI
    /// never spins forever if the host drops the type-29). The empty-reply path is the common case and resolves
    /// on its own — this only fires for a genuinely lost reply.
    static let blockOutputTimeout: Duration = .seconds(5)

    /// Requests block `index`'s captured output (wire type 15 → 29), then hands the result back through
    /// `onResult`: the VT-stripped PLAIN TEXT on success, or `nil` when the block was evicted / unavailable /
    /// there is no live connection (so the caller shows a brief "output unavailable" — NEVER hangs). The raw VT
    /// bytes are sanitised here (``BlockOutputSanitizer``) so the clipboard gets clean text.
    ///
    /// The wire request fires through ``requestBlockOutputSink`` (set on connect). While disconnected the sink
    /// is `nil`; ``TerminalBlockModel/requestOutput(index:send:completion:)`` still registers the pending
    /// request, so we resolve it immediately as unavailable rather than leaving it stranded.
    public func copyBlockOutput(index: UInt32, onResult: @escaping (String?) -> Void) {
        // Empty/nil reply == evicted/unknown → "output unavailable". Otherwise strip VT → plain text.
        requestBlockOutputBytes(index: index) { result in
            onResult(result.map { BlockOutputSanitizer.plainText(from: $0) })
        }
    }

    /// Requests block `index`'s RAW captured VT output bytes (wire type 15 → 29) — the colour-preserving
    /// sibling of ``copyBlockOutput(index:onResult:)`` for callers that render the SGR runs. `onResult` gets the
    /// raw bytes on success or `nil` when the block was evicted / unavailable / disconnected (so the caller
    /// shows a brief "output unavailable" and NEVER hangs). The clipboard path strips these bytes through
    /// ``BlockOutputSanitizer``; here they stay raw so the colours survive.
    public func requestBlockOutputBytes(index: UInt32, onResult: @escaping (Data?) -> Void) {
        // No live connection → resolve as unavailable without sending (the request would never get a reply).
        guard let sink = requestBlockOutputSink else {
            onResult(nil)
            return
        }
        let generation = blocks.requestOutput(
            index: index,
            send: { idx in sink(idx) },
            completion: { result in onResult(result) },
        )
        // Belt-and-braces timeout: if the host never replies, resolve the request as unavailable so the copy
        // UI's spinner can't spin forever. A no-op once the real reply resolves it. The captured `generation`
        // gates the timeout: a stale timer from a prior copy of the SAME block can't resolve a fresh copy
        // that opened a newer request after this one already resolved.
        Task { [weak self] in
            try? await Task.sleep(for: Self.blockOutputTimeout)
            self?.blocks.timeoutPending(index: index, generation: generation)
        }
    }

    /// Marks that the reconnect campaign has begun (the chrome shows "reconnecting" rather than a bare
    /// "disconnected"). Called by the ConnectionViewModel on a non-deliberate drop.
    public func markReconnecting() {
        connectionStatus = .reconnecting
        // A drop leaves a stale OSC 133 running state we can never get a matching `D` for (the C→D pair would
        // straddle the disconnect); clear to idle so the indicator does not stick "running" across a reconnect.
        shellActivity = .idle
        // The reconnect may bring a FRESH host shell (PATH B/C — the wipe must clear the dead session's
        // screen/scrollback before the new prompt paints) or REATTACH the same live shell (PATH A, detach
        // default-ON — the wipe must NOT erase the surviving screen). Arm the one-shot wipe pessimistically and
        // let the output pump resolve it against the client's ``SlopDeskClient/SessionResumeOutcome`` before the
        // first post-reconnect batch is ingested (see ``resolveResumeOutcomeIfNeeded(client:epoch:batchIsEmpty:)``).
        pendingFreshSessionReset = true
        awaitingResumeOutcome = true
        // A GENUINE drop being retried — arm the user-facing "reattached vs fresh shell"
        // toast so the resolved verdict surfaces once the first post-reconnect output lands.
        resumeOutcomeNotifiable = true
        sessionEpoch += 1 // in-hand batches taken from the dead session stop painting
        // The fresh shell re-segments its own blocks from index 0 — drop the dead session's blocks (and resolve
        // any in-flight copy-output request as unavailable) so the navigator/header don't show stale commands
        // grafted onto the new shell.
        blocks.reset()
        clearGlitchCaret() // keystrokes in flight died with the old session
        endAwaitingReflow() // the dead session's pending reflow is moot — release the scrim
        // The dead session's terminal MODE is a lie for the fresh shell (a drop inside vim leaves .altScreen
        // latched and would disarm the caret for the entire new session; a drop mid-DCS would swallow the new
        // session's markers).
        modeTracker.reset()
        // ...and the observable twin with it, or a drop taken inside vim leaves the mirror latched ON
        // for the whole new session — the reset that exists to stop exactly that for the tracker.
        alternateScreenActive = false
        // The dead session's no-echo (password-prompt) state is likewise a lie for the fresh shell, which
        // echoes by default — clear it so secure input does not stay latched across a reconnect (the leaf's
        // controller disengages on the resulting `onHostEchoChanged(false)`).
        hostNoEcho = false
        // The dead session's OSC 9;4 progress is likewise a lie for the fresh shell — clear the indicator so a
        // spinner/bar can't carry across a reconnect (the new shell re-reports its own progress, if any).
        progress = nil
    }

    /// Clears the pending-bell flag once the view has flashed.
    public func clearBell() {
        bellPending = false
    }

    /// Resets to idle (a fresh connect target). Keeps no stale title / byte count, and clears the replay ring —
    /// a fresh session must not repaint the previous session's scrollback.
    public func reset() {
        connectionStatus = .idle
        title = nil
        bytesReceived = 0
        bellPending = false
        shellActivity = .idle // a fresh session is idle until its first command runs
        lastCommand = nil
        blocks.reset() // a fresh session has no blocks — the navigator/header start empty
        lastResumeSeq = 0
        lastSentSize = nil // a fresh session must re-assert its grid size
        ring.removeAll() // stale scrollback must not survive into a new session
        ringStart = 0
        ringByteCount = 0
        // Arm the one-shot fresh-session wipe, like markReconnecting(). The surface is ALWAYS mounted
        // (TerminalScreenView is an overlay, never an if/else content swap), so a deliberate reconnect (⇧⌘R /
        // the recovery banner's Retry) of an exited/failed pane keeps the dead session's framebuffer on screen
        // — the new shell's prompt would graft onto the old screen. Arming the wipe makes the first fresh output
        // RIS-clear the surface first. Harmless on a first-ever connect (surface already empty), and the
        // deliberate path matches the transient-reconnect path — including the resume-outcome resolution (a
        // deliberate retry that lands on a PATH-A reattach must not wipe the surviving screen either).
        pendingFreshSessionReset = true
        awaitingResumeOutcome = true
        // A fresh connect target / deliberate reconnect (⇧⌘R) must NOT fire the "reattached
        // vs fresh shell" toast — that surface is for UNEXPECTED drops (``markReconnecting``) only, so disarm
        // the notification even though the wipe arms exactly like a reconnect.
        resumeOutcomeNotifiable = false
        sessionEpoch += 1
        clearGlitchCaret()
        endAwaitingReflow() // a fresh session has nothing pending to reflow
        modeTracker.reset() // same session-boundary truth as markReconnecting()
        alternateScreenActive = false // and the twin, for the same reason
        // A fresh connect target starts at a normal echoing prompt with no manual secure-entry — drop any stale
        // secure-input state so the pill / process-global lock never carry across a target change.
        hostNoEcho = false
        manualSecureInput = false
    }
}

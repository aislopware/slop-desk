import Foundation
import SlopDeskAgentDetect

/// One pane's screen-detection pipeline (the herdr port's pane layer): owns the resident
/// ``TerminalScreenModel`` + ``AgentOscTracker``, extracts herdr's detection text, runs the
/// manifest engine, and applies the temporal layer (startup grace, idle-scan skip, the
/// working→idle hold, the visible-blocker refresh heartbeat).
///
/// PURE against its inputs — the caller (the session's scan task) supplies the pending bytes,
/// pane size, foreground agent and clock; nothing here touches a PTY, a socket or a wall
/// clock, so the whole pipeline is unit-testable. Single-owner mutation: only the scan task
/// calls `scan`.
struct PaneScreenScanner {
    private var model: TerminalScreenModel?
    private var tracker = AgentOscTracker()
    private var hold = AgentDetectionHold()
    /// The last PUBLISHED detection (herdr's `previous` — held stable through a pending hold).
    private var lastPublished: AgentScreenDetection?
    private var lastPublishedAt: TimeInterval?
    private var lastAgent: AgentKind?
    private var agentSince: TimeInterval?
    private var lastScanSeq: UInt64 = 0
    /// TRUE between a ring REBUILD and the first output that lands on the rebuilt grid — while it
    /// stands, the engine's verdict is computed but never published.
    ///
    /// A rebuild re-feeds the RAW scrollback ring into a grid of the CURRENT size, and a resize is
    /// the reason a rebuild happens at all. Claude Code (like every inline TUI) dismisses its
    /// dialogs with RELATIVE motion — `CSI nA` + `CSI J` for a row count it measured at the OLD
    /// width — so replaying those bytes at the NEW width lands the erase in the wrong place and
    /// leaves the top of a long-dismissed permission dialog sitting in the visible rows. The engine
    /// reads that faithfully and calls the pane BLOCKED, which is how switching tabs conjured a
    /// "waiting for your input" banner for a pane sitting quietly at its prompt.
    ///
    /// The grid is only ever trustworthy again once the program has repainted at the new size — the
    /// SIGWINCH the resize already delivered (plus ``MuxChannelSession``'s redraw nudge) is what
    /// makes that arrive. So the reconstruction stays a WARM GUESS: good enough to feed, never good
    /// enough to publish. Nothing is lost by waiting — the last published verdict stands, and a
    /// resize changes what is on screen, not what the agent is doing.
    private var awaitingRepaintAfterRebuild = false

    /// Tracks whether the bytes fed so far end inside an OPEN synchronized update — see
    /// ``AgentSyncFrameTracker`` for why a mid-frame grid must never be reported.
    private var syncFrames = AgentSyncFrameTracker()

    /// The scan time at which the currently-open synchronized frame was first OBSERVED open
    /// (`nil` when no frame is open). Anchors ``syncFrameHoldCap``.
    private var syncFrameOpenSince: TimeInterval?

    /// ``AgentSyncFrameTracker/frameGeneration`` of the frame ``syncFrameOpenSince`` anchors.
    /// ⚠️ The cap is per FRAME, and a busy TUI opens a new one every few milliseconds — anchoring
    /// on "a frame was open last time too" would let one second of ordinary repainting retire the
    /// hold permanently, and every scan after that reads a torn grid. Held together they say what
    /// is meant: THIS frame has been open too long.
    private var syncFrameAnchorGeneration: UInt64?

    /// Ceiling on how long an open synchronized frame may suppress publishing. A frame is one
    /// repaint — milliseconds — so any frame still open a second later is a program that died
    /// mid-paint or a stream that lost its closer, and detection must not be frozen by it.
    /// (Terminal emulators bound the mode the same way, for the same reason.)
    static let syncFrameHoldCap: TimeInterval = 1.0

    struct Input {
        /// PTY output bytes accumulated since the last scan (empty when quiet).
        var pending: Data
        /// Non-nil = the model is stale (resize / overflow / first scan): rebuild the grid at
        /// `rows`×`cols` and replay these bytes (the scrollback ring — full-screen apps repaint,
        /// so a mid-ring start converges, the same property the `screen` verb relies on).
        var rebuildReplay: Data?
        var rows: Int
        var cols: Int
        /// The identified foreground agent, or `nil` (plain shell / unknown program).
        var agent: AgentKind?
        /// Monotonic content sequence — bumped per non-empty PTY chunk (the idle-scan skip).
        var contentSeq: UInt64
        var now: TimeInterval
    }

    struct Output: Equatable {
        /// A detection worth folding into the pane's status machine, or `nil`.
        var publish: AgentScreenDetection?
        /// Seconds until the next scan (tightens to 100 ms while an idle hold is pending).
        var nextInterval: TimeInterval
    }

    mutating func scan(_ input: Input) -> Output {
        // Agent change FIRST (herdr clear_retained): the previous process's OSC evidence is
        // dropped BEFORE this tick's bytes are fed, so a sequence spanning the change is
        // attributed to the NEW agent.
        let agentChanged = input.agent != lastAgent
        if agentChanged {
            lastAgent = input.agent
            tracker.clearRetained()
            agentSince = input.now
            lastPublished = nil
            lastPublishedAt = nil
            hold = AgentDetectionHold()
        }

        // Grid upkeep runs regardless of agent — the model must be warm when one appears.
        if let replay = input.rebuildReplay {
            var fresh = TerminalScreenModel(rows: input.rows, cols: input.cols)
            fresh.feed(replay)
            model = fresh
            tracker.observe(replay)
            // The frame parser is positional: a rebuild replays a DIFFERENT stream into a new
            // grid, so its old position describes bytes the model no longer holds.
            syncFrames.reset()
            syncFrames.observe(replay)
            // A reconstruction is not an observation — hold publishing until the program repaints
            // onto it (see `awaitingRepaintAfterRebuild`). The hold goes with it: a pending
            // working→idle confirmation was counting reads of a grid that no longer exists.
            awaitingRepaintAfterRebuild = true
            hold = AgentDetectionHold()
        } else if model == nil || model?.rows != input.rows || model?.cols != input.cols {
            // No replay supplied but the size drifted — restart empty; the next repaint fills it.
            model = TerminalScreenModel(rows: input.rows, cols: input.cols)
        }
        if !input.pending.isEmpty {
            model?.feed(input.pending)
            tracker.observe(input.pending)
            syncFrames.observe(input.pending)
        }
        // Anchor the open frame the first scan that sees THIS frame open; drop the anchor when it
        // closes, and re-arm when the generation moves (a different frame is a fresh deadline).
        if syncFrames.isFrameOpen {
            if syncFrameOpenSince == nil || syncFrameAnchorGeneration != syncFrames.frameGeneration {
                syncFrameOpenSince = input.now
                syncFrameAnchorGeneration = syncFrames.frameGeneration
            }
        } else {
            syncFrameOpenSince = nil
            syncFrameAnchorGeneration = nil
        }
        let seqUnchanged = input.contentSeq == lastScanSeq
        lastScanSeq = input.contentSeq
        // Output landing AFTER the rebuild is the repaint the guess was waiting for. The rebuild
        // tick itself never clears the flag: `markScreenModelDirty` drops the pending buffer, so the
        // bytes replayed there are the ring's, not the resized program's.
        if awaitingRepaintAfterRebuild, input.rebuildReplay == nil, !seqUnchanged {
            awaitingRepaintAfterRebuild = false
        }

        guard let agent = input.agent else {
            return Output(publish: nil, nextInterval: AgentDetectionHold.scanInterval)
        }
        // Startup grace: suppress detection while the TUI paints its splash.
        if let since = agentSince, input.now - since < AgentDetectionHold.startupGraceWindow {
            return Output(publish: nil, nextInterval: AgentDetectionHold.scanInterval)
        }
        // Idle-scan skip: a quiescent idle pane with no new bytes does no regex work.
        if lastPublished?.state == .idle, seqUnchanged, !hold.isHoldingIdle, !agentChanged {
            return Output(publish: nil, nextInterval: AgentDetectionHold.scanInterval)
        }
        // The rebuilt grid is a guess until the program repaints onto it — read it, never report it.
        if awaitingRepaintAfterRebuild {
            return Output(publish: nil, nextInterval: AgentDetectionHold.scanInterval)
        }
        // Mid-repaint the grid is HALF a frame: the program said so with mode 2026, and it erases
        // lines before it rewrites them. Wait for the closer rather than read a screen that shows
        // a dialog with its footer missing (``AgentSyncFrameTracker``). Recheck fast — the frame
        // closes in milliseconds — and never wait past the cap.
        if syncFrames.isFrameOpen, let since = syncFrameOpenSince,
           Double.minimum(input.now - since, Self.syncFrameHoldCap) < Self.syncFrameHoldCap
        {
            return Output(publish: nil, nextInterval: AgentDetectionHold.pendingIdleRecheck)
        }

        let screen = model?.snapshot().detectionText ?? ""
        let detection = AgentManifestCatalog.detect(
            agent: agent,
            input: AgentDetectionInput(
                screen: screen,
                oscTitle: tracker.latestTitle,
                oscProgress: tracker.latestProgress,
            ),
        )
        // A freeze rule (transcript viewer / model picker) publishes nothing — the machine
        // holds its previous status.
        if detection.skipStateUpdate {
            return Output(publish: nil, nextInterval: AgentDetectionHold.scanInterval)
        }
        let previous = lastPublished ?? AgentScreenDetection(state: .unknown)
        let publishNow = hold.decide(
            previous: previous,
            next: detection,
            agentChanged: agentChanged,
            processExited: false,
            lastRefresh: lastPublishedAt,
            now: input.now,
        )
        let interval = hold.isHoldingIdle
            ? AgentDetectionHold.pendingIdleRecheck
            : AgentDetectionHold.scanInterval
        guard publishNow else { return Output(publish: nil, nextInterval: interval) }
        lastPublished = detection
        lastPublishedAt = input.now
        return Output(publish: detection, nextInterval: interval)
    }
}

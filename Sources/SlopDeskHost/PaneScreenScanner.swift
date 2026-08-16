import Foundation
import SlopDeskAgentDetect
import SlopDeskScreen

/// One pane's screen-detection pipeline (the herdr port's pane layer): drives the pane's resident
/// grid in `slopdesk-screend` and applies the temporal layer (startup grace, idle-scan skip, the
/// working→idle hold, the visible-blocker refresh heartbeat, the cap on an open synchronized frame).
///
/// ## The screen tier is not in this process
/// The grid, the OSC tracker, the synchronized-frame parser and the manifest rule ladder all live
/// in `rust/slopdesk-screend`, and one `detect` verb (`src/detect.rs`) per tick drives all four. hostd used to
/// walk every PTY chunk four times for this — once across the socket for the grid, then again for
/// the OSC title, again for the frame parser, and once more for ~20 `NSRegularExpression`s over a
/// whole grid that had been shipped back as JSON. Now the bytes go one way and a verdict comes back.
///
/// The line between the two sides is not "hot code": **screend owns everything that reads the
/// BYTES, hostd owns everything that reads the CLOCK.** Every deadline below is a decision about
/// time, taken next to the scan timer that measures it, and the far side reports facts.
///
/// ## Absent screend costs this pane its screen tier, and nothing else
/// A failed exchange marks the grid stale (the next tick rebuilds it from the ring) and publishes
/// NOTHING — not idle, not the previous verdict. Hook and ctl `report` evidence is authoritative
/// anyway (`docs/50`) and never passes through here. Only the scan task calls ``scan(_:)``.
struct PaneScreenScanner {
    /// This pane's key in screend's registry. Distinct per scanner, never reused across panes.
    private let paneKey: String
    private let screen: ScreenClient
    /// TRUE until a fold has landed on a grid of the CURRENT size — the next request carries the
    /// reset flag. Set by a rebuild request, a geometry change, and any failed exchange.
    private var gridIsStale = true
    private var gridRows = 0
    private var gridCols = 0
    /// The last verdict screend answered for the CURRENT agent and the CURRENT screen, or `nil`
    /// when the ladder has not run against them.
    ///
    /// Reused verbatim on a tick that folds no bytes: the verdict is a pure function of (grid, OSC
    /// evidence, agent), so with none of the three changed there is nothing to ask. That is
    /// strictly less work than the Swift engine did — a quiescent WORKING pane re-ran the whole
    /// ladder every tick against a snapshot it had already cached.
    private var cachedDetection: AgentScreenDetection?
    private var hold = AgentDetectionHold()
    /// The last PUBLISHED detection (herdr's `previous` — held stable through a pending hold).
    private var lastPublished: AgentScreenDetection?
    private var lastPublishedAt: TimeInterval?
    private var lastAgent: AgentKind?
    private var agentSince: TimeInterval?
    private var lastScanSeq: UInt64 = 0
    /// TRUE between a ring REBUILD and the first output that lands on the rebuilt grid — while it
    /// stands, the ladder is not even asked to run.
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
    /// makes that arrive. So the reconstruction stays a WARM GUESS: good enough to fold, never good
    /// enough to publish. Nothing is lost by waiting — the last published verdict stands, and a
    /// resize changes what is on screen, not what the agent is doing.
    private var awaitingRepaintAfterRebuild = false

    /// Whether the bytes folded so far end inside an OPEN synchronized update, as screend last
    /// reported it (``ScreenDetection/frameOpen``). Carried between ticks because a tick that folds
    /// no bytes cannot have changed it.
    private var frameOpen = false
    private var frameGeneration: UInt64 = 0

    /// The scan time at which the currently-open synchronized frame was first OBSERVED open
    /// (`nil` when no frame is open). Anchors ``syncFrameHoldCap``.
    private var syncFrameOpenSince: TimeInterval?

    /// ``ScreenDetection/frameGeneration`` of the frame ``syncFrameOpenSince`` anchors.
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

    /// The key defaults to a fresh identity, which is all it has to be: screend's registry is a
    /// CACHE, not durable state — a key nobody holds is evicted, and a grid that goes missing is
    /// rebuilt from the pane's ring on the next tick. It deliberately does NOT reuse the pane id: a
    /// scanner's grid is private to the scanner, and two scanners sharing a key would fold one
    /// model two streams.
    init(paneKey: String = UUID().uuidString, screen: ScreenClient = .shared) {
        self.paneKey = paneKey
        self.screen = screen
    }

    /// Drops the pane's grid and trackers from screend. Called when the pane goes; best-effort,
    /// because screend evicts on its own when the table fills.
    func release() {
        screen.forget(pane: paneKey)
    }

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
        let agentChanged = input.agent != lastAgent
        if agentChanged {
            lastAgent = input.agent
            agentSince = input.now
            lastPublished = nil
            lastPublishedAt = nil
            cachedDetection = nil
            hold = AgentDetectionHold()
        }

        // Grid upkeep runs regardless of agent — the model must be warm when one appears.
        if input.rows != gridRows || input.cols != gridCols {
            // A VT grid cannot be reflowed, so a size change is not an adjustment, it is a
            // different grid. screend resets on a geometry change of its own accord; the flag is
            // what stops this side trusting the OLD verdict in the meantime.
            gridIsStale = true
            gridRows = input.rows
            gridCols = input.cols
        }
        if input.rebuildReplay != nil {
            gridIsStale = true
            // A reconstruction is not an observation — hold publishing until the program repaints
            // onto it (see `awaitingRepaintAfterRebuild`). The hold goes with it: a pending
            // working→idle confirmation was counting reads of a grid that no longer exists.
            awaitingRepaintAfterRebuild = true
            hold = AgentDetectionHold()
        }

        let seqUnchanged = input.contentSeq == lastScanSeq
        lastScanSeq = input.contentSeq
        // Output landing AFTER the rebuild is the repaint the guess was waiting for. The rebuild
        // tick itself never clears the flag: `markScreenModelDirty` drops the pending buffer, so the
        // bytes replayed there are the ring's, not the resized program's.
        if awaitingRepaintAfterRebuild, input.rebuildReplay == nil, !seqUnchanged {
            awaitingRepaintAfterRebuild = false
        }

        // The suppressions below all decide the same thing twice over: whether this tick's verdict
        // could be PUBLISHED. When it could not, the label goes over as empty and screend folds the
        // bytes without running the ladder — the grid and the trackers still advance, which is the
        // whole point of the upkeep, and no rule is evaluated for an answer nobody would read.
        let suppression = suppression(input, agentChanged: agentChanged, seqUnchanged: seqUnchanged)
        if !exchange(input, agentChanged: agentChanged, label: suppression == nil ? input.agent?.label ?? "" : "") {
            // A grid whose last fold was lost is behind the pane by an unknown amount, and a
            // detection read off a stale screen is how a dismissed dialog gets reported as a live
            // one. Publish NOTHING — not the fallback the empty screen would have produced.
            return Output(publish: nil, nextInterval: AgentDetectionHold.scanInterval)
        }
        anchorOpenFrame(now: input.now)

        if let suppression { return Output(publish: nil, nextInterval: suppression) }
        // Mid-repaint the grid is HALF a frame: the program said so with mode 2026, and it erases
        // lines before it rewrites them. Wait for the closer rather than read a screen that shows
        // a dialog with its footer missing. Recheck fast — the frame closes in milliseconds — and
        // never wait past the cap.
        if frameOpen, let since = syncFrameOpenSince,
           Double.minimum(input.now - since, Self.syncFrameHoldCap) < Self.syncFrameHoldCap
        {
            return Output(publish: nil, nextInterval: AgentDetectionHold.pendingIdleRecheck)
        }
        guard let detection = cachedDetection else {
            return Output(publish: nil, nextInterval: AgentDetectionHold.scanInterval)
        }
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

    /// The interval to answer with when this tick cannot publish, or `nil` when it can.
    private func suppression(_ input: Input, agentChanged: Bool, seqUnchanged: Bool) -> TimeInterval? {
        guard input.agent != nil else { return AgentDetectionHold.scanInterval }
        // Startup grace: suppress detection while the TUI paints its splash.
        if let since = agentSince, input.now - since < AgentDetectionHold.startupGraceWindow {
            return AgentDetectionHold.scanInterval
        }
        // Idle-scan skip: a quiescent idle pane with no new bytes asks no question.
        if lastPublished?.state == .idle, seqUnchanged, !hold.isHoldingIdle, !agentChanged {
            return AgentDetectionHold.scanInterval
        }
        // The rebuilt grid is a guess until the program repaints onto it — fold it, never read it.
        if awaitingRepaintAfterRebuild { return AgentDetectionHold.scanInterval }
        return nil
    }

    /// One screend `detect` verb, or none at all. Returns whether the pane's state is still
    /// trustworthy — `false` only when an exchange failed.
    ///
    /// A tick with nothing to fold and nothing new to ask skips the socket entirely: the grid, the
    /// OSC evidence and the agent are all unchanged, so ``cachedDetection`` is still the answer to
    /// the same question.
    private mutating func exchange(_ input: Input, agentChanged: Bool, label: String) -> Bool {
        var payload = input.rebuildReplay ?? Data()
        payload.append(input.pending)
        let mustFold = !payload.isEmpty || gridIsStale || agentChanged
        let mustAsk = !label.isEmpty && cachedDetection == nil
        guard mustFold || mustAsk else { return true }
        do {
            let verdict = try screen.detect(
                pane: paneKey,
                agent: label,
                raw: payload,
                rows: input.rows,
                cols: input.cols,
                reset: gridIsStale,
                rebuildReplay: input.rebuildReplay != nil,
                agentChanged: agentChanged,
            )
            gridIsStale = false
            frameOpen = verdict.frameOpen
            frameGeneration = verdict.frameGeneration
            cachedDetection = label.isEmpty ? nil : AgentScreenDetection(verdict)
            return true
        } catch {
            gridIsStale = true
            cachedDetection = nil
            return false
        }
    }

    /// Anchors the open frame the first scan that sees THIS frame open; drops the anchor when it
    /// closes, and re-arms when the generation moves (a different frame is a fresh deadline).
    private mutating func anchorOpenFrame(now: TimeInterval) {
        guard frameOpen else {
            syncFrameOpenSince = nil
            syncFrameAnchorGeneration = nil
            return
        }
        if syncFrameOpenSince == nil || syncFrameAnchorGeneration != frameGeneration {
            syncFrameOpenSince = now
            syncFrameAnchorGeneration = frameGeneration
        }
    }
}

extension AgentScreenDetection {
    /// The wire verdict in the terms the status machine speaks.
    ///
    /// An unrecognised state label decodes to `unknown` rather than throwing: the two ends ship
    /// together, so this cannot happen, and if it somehow did then "I do not know" is the honest
    /// answer and a thrown error would cost the pane its screen tier over a spelling.
    init(_ verdict: ScreenDetection) {
        self.init(
            state: AgentScreenState(rawValue: verdict.state) ?? .unknown,
            skipStateUpdate: verdict.skipStateUpdate,
            visibleIdle: verdict.visibleIdle,
            visibleBlocker: verdict.visibleBlocker,
            visibleWorking: verdict.visibleWorking,
            matchedRuleID: verdict.matchedRuleId,
            fallbackReason: verdict.fallbackReason,
        )
    }
}

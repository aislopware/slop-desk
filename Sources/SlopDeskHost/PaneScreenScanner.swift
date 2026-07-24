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
        } else if model == nil || model?.rows != input.rows || model?.cols != input.cols {
            // No replay supplied but the size drifted — restart empty; the next repaint fills it.
            model = TerminalScreenModel(rows: input.rows, cols: input.cols)
        }
        if !input.pending.isEmpty {
            model?.feed(input.pending)
            tracker.observe(input.pending)
        }
        let seqUnchanged = input.contentSeq == lastScanSeq
        lastScanSeq = input.contentSeq

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

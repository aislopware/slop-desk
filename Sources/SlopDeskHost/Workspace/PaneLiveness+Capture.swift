import SlopDeskWorkspaceModel

extension PaneLiveness {
    /// Reads one live pane's current facts off its ``MuxChannelSession``.
    ///
    /// The ONE place the host turns edge-published truths back into a value. Every accessor it
    /// touches is a latch the session already maintains — nothing here parses, probes or derives, so
    /// a capture is a handful of lock acquisitions and is cheap enough to run for every pane on a
    /// reconciler tick. (`foregroundProcess` in particular reads the WATCHER's latch rather than
    /// re-running `PTYForegroundProbe.foregroundName`, which is a syscall per pane.)
    ///
    /// - Parameter liveness: supplied by the caller, because the session cannot know it. Whether a
    ///   pane is attached, detached or dead is a fact about the SERVER's session maps, not about the
    ///   PTY — and getting it wrong renders a dead pane as fake-live.
    static func capture(from session: MuxChannelSession, liveness: PaneLivenessState) -> PaneLiveness {
        let (title, titleStampedAt) = session.titleAndStampForControl
        let commandStartedAt = session.commandStartedAtForControl
        let agent = session.agentPublishedStateForControl
        let size = session.pty.currentWindowSize()
        let progress = session.progressPairForControl
        // A dead pane keeps its last-known title as a LABEL but is never FRESH — rule 4 of §4.4.
        // The freshness verdict, not the two stamps, is what crosses the wire: the client's own
        // comparison depended on two in-memory dictionaries that reset on every app launch, which
        // is precisely why `nvim`'s title decayed back to `vi .`.
        let fresh = PaneTitleFreshness.isFresh(
            titleStampedAt: titleStampedAt,
            commandStartedAt: commandStartedAt,
            liveness: liveness,
        )
        return PaneLiveness(
            paneID: session.sessionID,
            liveness: liveness,
            // `nil` (never observed) and `""` (the agent retired the title it owned) stay distinct
            // all the way to the wire — an empty type-21 is this codebase's retirement signal.
            liveTitle: titleStampedAt == nil && title.isEmpty ? nil : title,
            titleFresh: fresh,
            cwd: session.cwdForControl,
            projectKey: session.projectKeyForControl,
            foregroundProcess: session.foregroundProcessForControl,
            runningCommand: session.runningCommandForControl,
            // State 0 is `ClaudeStatus.none` — a pane whose detector never saw an agent publishes no
            // agent record at all rather than a row of zeroes.
            agentState: agent.state == 0 && agent.kind == 0
                ? nil
                : AgentState(state: agent.state, kind: agent.kind),
            agentLabel: agent.label,
            agentIntent: agent.intent,
            progress: progress.map { Progress(state: $0.state, percent: $0.percent) },
            commandRunning: commandStartedAt != nil,
            lastExitCode: session.lastExitCodeForControl,
            lastDurationMS: session.lastDurationMSForControl,
            grid: size.map { Grid(cols: $0.cols, rows: $0.rows) },
            completionEpoch: session.completionEpochForControl,
            // Deliberately unstamped. The session keeps no last-activity latch, and the only place
            // to make one is the PTY read path — a wall-clock read per chunk, on the hot path, for a
            // field nothing reads yet. `0` is the record's own "never observed", so an absent stamp
            // is already expressible; it stays that way until something needs it.
            lastActivityMS: 0,
        )
    }
}

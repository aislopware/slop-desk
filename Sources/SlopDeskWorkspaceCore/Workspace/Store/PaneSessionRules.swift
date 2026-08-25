import CSlopDeskFFI
import SlopDeskAgentDetect

// MARK: - PaneSessionRules (what a live pane may do next)

/// Every DECISION a live pane session makes, as `slopdesk-workspace::pane_session` answers it.
///
/// ``LivePaneSession`` owns three things this file cannot: a terminal connection, the read-only
/// inspector socket beside it, and — for a desktop pane — a video window. What is left up there is
/// the OWNING: the handles, the `Task`s and the cancellation. What comes through here is what to do
/// with them, and every door is handed the facts it reads rather than the pane it reads them from.
///
/// Nothing here knows a ``PaneID``. A gate takes three booleans, the agent fold takes two bytes, and
/// the capture takes a count — so the same rules answer for a pane that is being torn down as for
/// one that has not connected yet.
public enum PaneSessionRules {
    // MARK: The agent signal fold

    /// What one folded status change does to the inspector's second channel.
    public enum InspectorEffect: UInt8, Sendable, Equatable {
        /// Neither edge: the channel stays exactly as it is.
        case nothing = 0
        /// A claude just appeared — open the read-only second channel.
        case open = 1
        /// The claude is gone — close the socket; the pane is a plain terminal again.
        case close = 2
    }

    /// What one type-27 frame leaves behind.
    public struct StatusFold: Sendable, Equatable {
        /// The status the pane holds AFTER the fold.
        public let status: ClaudeStatus
        /// Whether the status actually moved. `false` ⇒ write nothing: the near side's status is
        /// observed, and re-assigning an equal value re-renders every surface reading it for a frame
        /// that said nothing.
        public let changed: Bool
        /// What the move does to the second channel.
        public let effect: InspectorEffect
    }

    /// The fold of one wire type-27 `claudeStatus` frame into a pane's display state.
    ///
    /// The client is a PASSIVE display: the host owns the one status machine and this trusts its
    /// verdict verbatim. `detectable` is the pane's build-time fact — only a terminal has a PTY an
    /// agent could live in — and a pane that is not folds nothing at all. An unknown or future
    /// `wireState` degrades to no-agent rather than trapping.
    public static func fold(
        status current: ClaudeStatus,
        wireState: UInt8,
        detectable: Bool,
    ) -> StatusFold {
        let folded = slopdesk_ws_session_status_fold(
            detectable,
            UInt8(clamping: current.urgency),
            wireState,
        )
        return StatusFold(
            status: ClaudeStatus(urgency: Int(folded.urgency)),
            changed: folded.changed,
            effect: InspectorEffect(rawValue: folded.effect) ?? .nothing,
        )
    }

    /// Whether a wire type-26 frame NAMES a foreground process.
    ///
    /// An empty name is the ABSENCE of one rather than a process called nothing — the only judgement
    /// type 26 carries, since it is a display-only hint that may never touch the status. The name
    /// itself never crosses: it is a string this side already holds.
    public static func namesForegroundProcess(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            slopdesk_ws_session_names_foreground(buffer.baseAddress, buffer.count)
        }
    }

    // MARK: The inspector's second channel

    /// The three places the second channel is asked whether it may open.
    public enum InspectorGate: UInt8, Sendable, Equatable {
        /// The subscribe itself, called on appear and by both re-arms. Idempotent by this gate.
        case subscribe = 0
        /// The iOS foreground fan-out, which spawns a subscribe when the pane still holds an agent
        /// and the pause closed its client.
        case resume = 1
        /// The transport-reconnect re-arm (a wifi flap on macOS, where pause/resume never run). The
        /// stale client is torn down by the caller FIRST, so this gate does not read one.
        case reconnect = 2
    }

    /// Whether `gate` opens on these facts.
    ///
    /// Subscribe and resume are the same predicate, and naming them apart is the point: the resume
    /// path spawns a subscribe that re-tests the gate. The fourth line of the near side's subscribe
    /// — `let target, let client = makeInspector(target())` — is deliberately NOT here: it BUILDS
    /// the thing it tests for, which is a materialization rather than a gate.
    public static func allows(
        _ gate: InspectorGate,
        agentPresent: Bool,
        hasModel: Bool,
        hasClient: Bool,
    ) -> Bool {
        slopdesk_ws_session_inspector_gate(
            gate.rawValue,
            SlopDeskWsInspectorFacts(
                agent_present: agentPresent,
                has_model: hasModel,
                has_client: hasClient,
            ),
        )
    }

    // MARK: Video activation

    /// What one activation of a pane's video does.
    public enum VideoStep: UInt8, Sendable, Equatable {
        /// Nothing at all: not a video pane, or no model to act on.
        case ignore = 0
        /// Open the window, then mirror the descriptor the open produced.
        case open = 1
        /// Do not open — already open, or not configured — but MIRROR the descriptor as it stands.
        case mirror = 2
        /// Close the window and clear the flag.
        case close = 3
    }

    /// What a request to activate or deactivate this pane's video does.
    ///
    /// Deactivation is unconditional for a video pane with a model: closing an already-closed window
    /// is idempotent, and a deactivate that consulted the mirrored flag first would be trusting it to
    /// decide whether to release a UDP stack.
    public static func videoStep(
        isVideo: Bool,
        hasModel: Bool,
        isOpen: Bool,
        canOpen: Bool,
        active: Bool,
    ) -> VideoStep {
        let code = slopdesk_ws_session_video_step(
            SlopDeskWsVideoFacts(
                is_video: isVideo,
                has_model: hasModel,
                is_open: isOpen,
                can_open: canOpen,
            ),
            active,
        )
        return VideoStep(rawValue: code) ?? .ignore
    }

    /// Whether the foreground fan-out re-opens this pane's stream.
    ///
    /// Cap-safe without consulting the store: the latch is set on the way into background, so this
    /// re-opens AT MOST what was already streaming, and a set that satisfied the live-video cap
    /// cannot exceed it by being restored.
    public static func resumeReopensVideo(isVideo: Bool, wasActive: Bool) -> Bool {
        slopdesk_ws_session_resume_reopens_video(isVideo, wasActive)
    }

    /// Whether a pane closing for good must close a video window on the way out.
    ///
    /// The two facts are OR-ed rather than reduced to the mirrored flag: a window that opened without
    /// the flag ever being mirrored would otherwise leave its capture orchestrator running with
    /// nothing on screen to say so.
    public static func teardownClosesVideo(isActive: Bool, hasDescriptor: Bool) -> Bool {
        slopdesk_ws_session_teardown_closes_video(isActive, hasDescriptor)
    }

    /// Which shape of video model a pane spec asks for.
    public enum VideoMount: UInt8, Sendable, Equatable {
        /// One host WINDOW, by id — the automation seam only.
        case window = 0
        /// A whole display, by id, where `0` is the main one.
        case desktop = 1
    }

    /// Which model a video pane's spec mounts.
    ///
    /// The window shape is the narrow one and needs all three: a video block, no display named, and a
    /// real window id. A window id of `0` is no window, which is the platform's own convention for an
    /// unset one.
    public static func videoMount(
        hasVideoSpec: Bool,
        hasDisplayID: Bool,
        windowID: UInt32,
    ) -> VideoMount {
        let code = slopdesk_ws_session_video_mount(hasVideoSpec, hasDisplayID, windowID)
        return VideoMount(rawValue: code) ?? .desktop
    }

    // MARK: The scrollback capture tail

    /// Where a capture of the last `count` lines of `available` starts, or `nil` when it captures
    /// nothing.
    ///
    /// A non-positive count is refused rather than clamped; a count wider than the scrollback starts
    /// at the top, which is what taking a suffix means.
    public static func captureStart(lines count: Int, available: Int) -> Int? {
        let start = slopdesk_ws_session_capture_start(Int64(count), available)
        return start < 0 ? nil : start
    }
}

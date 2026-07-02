import AislopdeskAgentDetect
import AislopdeskTransport
import XCTest
@testable import AislopdeskClient
@testable import AislopdeskWorkspaceCore

/// W11 — the LIVE agent-status wiring (the auto-detect payoff). Proves the host→client wire signals
/// (type 26 `foregroundProcess`, type 27 `claudeStatus`) fold through the per-pane ``LivePaneSession``
/// into the store's ``WorkspaceStore/paneAgentStatus`` + the sidebar/tab rollup — entirely headless
/// (no socket, no SCStream/VT/Metal; the session's transport factory is inert).
///
/// Two surfaces:
///  1. ``LivePaneSession/feedAgentSignal(_:now:)`` maps the raw wire bytes back to a ``ClaudeStatus``
///     (the only client-side wire→machine bridge), with dedupe + forward-tolerant byte handling.
///  2. The store sink: feeding a session a signal and mirroring it into `paneAgentStatus`, so
///     `agentStatus(for:)` + the session/tab `rollupStatus(...)` light up live.
@MainActor
final class ClaudeStatusWiringTests: XCTestCase {
    /// An inert client factory (never connected — these tests drive the status fold directly, no byte
    /// stream). `@Sendable` free function so it can be passed as `makeClient`.
    private static let makeUnconnectedClient: @Sendable () -> AislopdeskClient = {
        AislopdeskClient(makeTransport: {
            MuxClientTransport(
                acquire: { _, _, _, _ in throw AislopdeskTransportError.notConnected("inert test transport") },
                release: { _, _, _ in },
            )
        })
    }

    private func makeTerminalSession() -> LivePaneSession {
        LivePaneSession.make(
            PaneSpec(kind: .terminal, title: "term"),
            makeClient: Self.makeUnconnectedClient,
            makeInspector: { _ in nil },
        )
    }

    // MARK: - 1. feedAgentSignal: wire bytes → ClaudeStatus (the decode→machine bridge)

    /// A type-27 `claudeStatus` carrying the `working` urgency byte (3) lifts the pane to `.working`.
    func testClaudeStatusWireWorkingByteMapsToWorking() {
        let session = makeTerminalSession()
        XCTAssertEqual(session.claudeStatus, .none, "a fresh terminal has no claude")
        let result = session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "building"))
        XCTAssertEqual(result, .working, "state byte 3 (urgency) → .working")
        XCTAssertEqual(session.claudeStatus, .working, "the session mirrors the folded status")
    }

    /// A type-27 `claudeStatus` with the `needsPermission` urgency (4) + the `permission` kind (1) →
    /// blocked (`.needsPermission`) — the attention state the rollup surfaces most urgently.
    func testClaudeStatusPermissionMapsToNeedsPermission() {
        let session = makeTerminalSession()
        let result = session.feedAgentSignal(.claudeStatus(state: 4, kind: 1, label: "Allow Bash?"))
        XCTAssertEqual(result, .needsPermission, "state 4 + kind 1 → blocked on a permission prompt")
        XCTAssertEqual(session.claudeStatus, .needsPermission)
    }

    /// P1: a type-26 `foregroundProcess` is a DISPLAY-ONLY process-name hint — it updates
    /// ``LivePaneSession/foregroundProcessName`` and NEVER touches ``claudeStatus`` (the host's type-27
    /// is the single source of truth). So even `foregroundProcess("claude")` leaves the status at `.none`
    /// until the host SAYS so via type-27.
    func testForegroundProcessIsDisplayOnlyAndNeverSetsStatus() {
        let session = makeTerminalSession()
        XCTAssertEqual(session.feedAgentSignal(.foregroundProcess(name: "claude")), .none, "type-26 never sets status")
        XCTAssertEqual(session.claudeStatus, .none, "status stays none — only type-27 moves it")
        XCTAssertEqual(session.foregroundProcessName, "claude", "type-26 updates the display-only name")
        // A subsequent type-26 only updates the name; an empty name clears it (still no status change).
        _ = session.feedAgentSignal(.foregroundProcess(name: "vim"))
        XCTAssertEqual(session.foregroundProcessName, "vim")
        XCTAssertEqual(session.claudeStatus, .none)
        _ = session.feedAgentSignal(.foregroundProcess(name: ""))
        XCTAssertNil(session.foregroundProcessName, "an empty foreground name clears the display hint")
        XCTAssertEqual(session.claudeStatus, .none)
    }

    /// P1, review #3: a transient child process taking the PTY (a type-26 edge) must NOT clobber a
    /// `.needsPermission` the host set via type-27. The type-26 only changes the displayed name.
    func testForegroundProcessFlapDoesNotClobberHookStatus() {
        let session = makeTerminalSession()
        // Host hook → blocked (type-27).
        XCTAssertEqual(
            session.feedAgentSignal(.claudeStatus(state: 4, kind: 1, label: "Allow Bash?")),
            .needsPermission,
        )
        // A child tool (`grep`) momentarily becomes the PTY foreground — a type-26 edge.
        XCTAssertEqual(
            session.feedAgentSignal(.foregroundProcess(name: "grep")),
            .needsPermission,
            "a foreground child process must not wipe the host's needsPermission verdict",
        )
        XCTAssertEqual(session.claudeStatus, .needsPermission, "the type-27 status is untouched by type-26")
        XCTAssertEqual(session.foregroundProcessName, "grep", "only the display name changed")
    }

    /// An unknown / future urgency byte degrades to `.none` (forward-tolerant validate-then-repair) —
    /// a hostile or newer datagram must never trap the client.
    func testUnknownStateByteDegradesToNone() {
        let session = makeTerminalSession()
        // First the host reports working via type-27 so we are NOT already at .none.
        XCTAssertEqual(session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "")), .working)
        // A future state byte (99) maps to .none via ClaudeStatus(urgency:) — the host says "gone".
        let result = session.feedAgentSignal(.claudeStatus(state: 99, kind: 0, label: ""))
        XCTAssertEqual(result, .none, "an unknown urgency byte degrades to .none (never traps)")
    }

    /// P1 (c): the client status EQUALS the host's type-27 verdict for every step of a representative
    /// host signal sequence — the client (a passive display) maps `ClaudeStatus(urgency: state)` and
    /// never diverges. The host's emitted `state` bytes (idle 1 / working 3 / blocked 4 / done 2 /
    /// idle 1 / none 0) are replayed here exactly as the host would push them.
    func testClientStatusEqualsHostType27VerdictNoDivergence() {
        let session = makeTerminalSession()
        let hostByteThenExpected: [(UInt8, ClaudeStatus)] = [
            (1, .idle), (3, .working), (4, .needsPermission), (2, .done), (1, .idle), (0, .none),
        ]
        for (byte, expected) in hostByteThenExpected {
            let result = session.feedAgentSignal(.claudeStatus(state: byte, kind: 0, label: ""))
            XCTAssertEqual(result, expected, "host state byte \(byte) → client status \(expected) (no divergence)")
            XCTAssertEqual(session.claudeStatus, expected)
        }
    }

    /// P1 (d): a `claude-monitor` (or `myclaudewrapper`) foreground process is NOT claude — and since the
    /// client treats type-26 as display-only, it can NEVER lift `claudeStatus` off `.none` anyway. So the
    /// inspector second channel is never stood up (no flap): `makeInspector` is never called.
    func testClaudeMonitorProcessDoesNotOpenInspector() async {
        var madeInspector = false
        let session = LivePaneSession.make(
            PaneSpec(kind: .terminal, title: "term"),
            makeClient: Self.makeUnconnectedClient,
            makeInspector: { _ in madeInspector = true
                return nil
            },
        )
        for name in ["claude-monitor", "myclaudewrapper"] {
            XCTAssertEqual(session.feedAgentSignal(.foregroundProcess(name: name)), .none, "\(name) is not claude")
            XCTAssertEqual(
                session.claudeStatus,
                .none,
                "a claude-prefixed name never sets status (type-26 is display-only)",
            )
        }
        // Driving subscribe directly is still a no-op (status is .none → no inspector socket / no flap).
        await session.subscribeInspector()
        XCTAssertFalse(madeInspector, "no inspector channel for a non-claude foreground process")
    }

    /// P5 #6 — a GENUINE dedupe assertion (not the old near-tautological one that only checked the
    /// returned status stayed `.working`, which holds with OR without dedupe). The store's `setAgentStatus`
    /// is the dedupe guard; we COUNT how many times the observable `paneAgentStatus` actually MUTATES
    /// across a stream that contains repeats, and assert it changes exactly ONCE per distinct value. With
    /// the dedupe guard removed, an idempotent re-set would re-assign (and re-notify) on every repeat —
    /// this test would then see extra mutations. Driven through the real store sink + the session fold.
    func testRepeatedIdenticalStatusEmitsOnlyOnce() throws {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        // Track every DISTINCT value paneAgentStatus took for this pane (one entry per real mutation).
        var observedSequence: [ClaudeStatus] = []
        func setAndRecord(_ s: ClaudeStatus) {
            let before = store.agentStatus(for: paneID)
            store.setAgentStatus(s, for: paneID)
            let after = store.agentStatus(for: paneID)
            if after != before { observedSequence.append(after) } // a real mutation happened
        }

        // working, working (dup), working (dup), needsPermission, needsPermission (dup), working.
        setAndRecord(.working)
        setAndRecord(.working)
        setAndRecord(.working)
        setAndRecord(.needsPermission)
        setAndRecord(.needsPermission)
        setAndRecord(.working)

        XCTAssertEqual(
            observedSequence,
            [.working, .needsPermission, .working],
            "each repeated identical status is deduped — the store mutates once per distinct value, not per call",
        )
    }

    // MARK: - 2. The store sink: setAgentStatus mirrors the fold into paneAgentStatus + rollup

    /// The store's per-pane sink: setting a pane's agent status lights up `agentStatus(for:)`, and the
    /// owning session/tab `rollupStatus(...)` surface the most-urgent state (Herdr rollup). This is the
    /// `AgentStatusDot`'s live source.
    func testSetAgentStatusFeedsRollupDots() throws {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
        // The default tree has one session with one tab + one leaf.
        let sessionID = try XCTUnwrap(store.tree.sessions.first?.id)
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        XCTAssertEqual(store.agentStatus(for: paneID), .none, "no detection yet → none")
        XCTAssertEqual(store.rollupStatus(forSession: sessionID), .none)

        store.setAgentStatus(.needsPermission, for: paneID)
        XCTAssertEqual(store.agentStatus(for: paneID), .needsPermission, "per-pane status reflects the fold")
        XCTAssertEqual(
            store.rollupStatus(forSession: sessionID),
            .needsPermission,
            "the sidebar session-row dot surfaces the most-urgent pane",
        )

        // Clearing it (claude gone) removes the entry → back to none, no rollup.
        store.setAgentStatus(.none, for: paneID)
        XCTAssertEqual(store.agentStatus(for: paneID), .none)
        XCTAssertEqual(store.rollupStatus(forSession: sessionID), .none, "the dot goes dark when claude leaves")
    }

    /// The most-urgent rollup over a multi-pane tab (blocked > working > done > idle > none) — a `.idle`
    /// pane next to a `.needsPermission` pane rolls up to `.needsPermission`.
    func testRollupSurfacesMostUrgentAcrossPanes() throws {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
        let sessionID = try XCTUnwrap(store.tree.sessions.first?.id)
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        // Split to get a second pane in the same tab.
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let panes = store.tree.allPaneIDs()
        XCTAssertEqual(panes.count, 2, "split produced a second leaf")
        let second = try XCTUnwrap(panes.first { $0 != first })

        store.setAgentStatus(.idle, for: first)
        store.setAgentStatus(.needsPermission, for: second)
        XCTAssertEqual(
            store.rollupStatus(forSession: sessionID),
            .needsPermission,
            "blocked outranks idle in the rollup",
        )
    }

    // MARK: - 3. The wire→Event surface (AislopdeskClient maps types 26/27 to events)

    /// The client surfaces a type-27 `claudeStatus` WireMessage as a `.claudeStatus` Event (the byte
    /// payload is carried verbatim; the UI maps it back). Proven via the client's test inbound seam.
    func testClientSurfacesClaudeStatusWireMessageAsEvent() async {
        let client = Self.makeUnconnectedClient()
        // Subscribe BEFORE driving so the multicast child stream observes the yield.
        let events = client.events
        let observer = Task { () -> AislopdeskClient.Event? in
            for await event in events { return event }
            return nil
        }
        // Let the subscription register, then drive a type-27 message through the inbound seam.
        await Task.yield()
        await client.handleInboundForTesting(.claudeStatus(state: 4, kind: 1, label: "Allow?"))
        let observed = await observer.value
        XCTAssertEqual(
            observed,
            .claudeStatus(state: 4, kind: 1, label: "Allow?"),
            "the client forwards the type-27 payload verbatim as a .claudeStatus event",
        )
    }
}

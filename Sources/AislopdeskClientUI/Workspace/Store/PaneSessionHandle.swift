import Foundation

// MARK: - The liveness handle (the table-of-liveness element)

/// One live pane session, abstracted to exactly what the store needs to **reconcile** the table
/// of liveness against the tree of intent (docs/22 §0, §1.1, §2.3).
///
/// This is the **test seam** the whole WF3 story turns on. It is deliberately *not* a protocol over
/// the concrete `AislopdeskClient` `actor` (which has no seam — docs/22 §0): it is a tiny protocol the
/// **store** depends on, so the store's session-lifecycle logic (materialize / teardown / scenePhase
/// fan-out / video cap) can be exercised with a `FakePaneSession` that never opens a socket. The
/// production conformer ``LivePaneSession`` wraps the proven per-session objects verbatim
/// (one `ConnectionViewModel` + `TerminalViewModel` + `InputBarModel`, plus an optional inspector
/// for `.claudeCode` or a `RemoteWindowModel` for `.remoteGUI`).
///
/// `@MainActor` because every conformer owns `@Observable` UI state bound on the main actor; `AnyObject`
/// because the registry stores it by reference (1:1 with a ``PaneID``, never copied, never shared).
/// `Identifiable` by ``PaneID`` so a handle drops straight into SwiftUI `ForEach` / identity diffing.
@preconcurrency
@MainActor
public protocol PaneSessionHandle: AnyObject, Identifiable {
    /// The pane this session backs. Stable for the session's lifetime and the join key into the
    /// store's registry — `id` here MUST equal the leaf's ``PaneID`` so `reconcile()`'s
    /// `registry.keys == allLeafIDs()` invariant holds.
    var id: PaneID { get }

    /// What this pane is. The store reads this to enforce the ``WorkspaceStore/liveVideoCap`` ceiling
    /// (only `.remoteGUI` handles count against it) without reaching into the concrete type.
    var kind: PaneKind { get }

    // MARK: Video activation gating (docs/22 §7)

    /// Whether the pane's shell is currently running a foreground command — the close-guard signal
    /// (⌘W on a busy shell asks before killing the session) and the pill's "running…" cue. `false`
    /// for kinds with no shell. Default implementation returns `false` so non-terminal conformers
    /// need not care.
    var isShellBusy: Bool { get }

    /// Whether this session is currently holding live video resources (the 2-UDP-socket /
    /// VTDecompression / CVDisplayLink stack). Always `false` for non-`.remoteGUI` kinds.
    ///
    /// This is the single hook the store reads to count concurrent live video panes against
    /// ``WorkspaceStore/liveVideoCap``. Activation itself is driven by the view layer's
    /// `.onAppear/.onDisappear` (decode only on-screen panes) via ``setVideoActive(_:)`` — the store
    /// only *reads* the flag to decide whether a newly-appearing video pane is allowed to activate.
    var isVideoActive: Bool { get }

    /// Requests this session activate (`true`) or deactivate (`false`) its live video stack. A no-op
    /// for non-`.remoteGUI` kinds. Idempotent. STORE-INTERNAL in practice: the view layer routes
    /// appear/disappear through ``WorkspaceStore/activateVideo(_:)`` / ``WorkspaceStore/deactivateVideo(_:)``
    /// so `liveVideoCap` is consulted — the store is the admit/evict authority against the cap. (It
    /// cannot be made fully private: it is part of this protocol and the store + pause/resume call it;
    /// but the view no longer calls it directly except on the no-store preview fallback.)
    func setVideoActive(_ active: Bool)

    // MARK: Lifecycle (the single fan-out points)

    /// iOS background: proactively pause the session. The single fan-out point — a conformer routes
    /// this to BOTH its connection AND its inspector channel (docs/22 §2.3, §4 fan-out). AWAITED by
    /// the store's `pauseAll()` `TaskGroup` before the app suspends.
    func pause() async

    /// iOS foreground: resume the session (connection byte-exact resume + inspector re-subscribe).
    func resume() async

    // MARK: Broadcast input (synchronize-panes)

    /// Types `text` into this session's shell input funnel (the broadcast / synchronized-input target
    /// primitive). A no-op for kinds with no text funnel (video panes) — see ``PaneKind/canReceiveText``.
    /// Default implementation does nothing so non-terminal conformers need not care; ``LivePaneSession``
    /// routes it to the per-pane `InputBarModel`, and test fakes record it.
    func sendText(_ text: String)

    /// Feeds a RAW byte sequence into this session's shell (the snippet / send-keys primitive — bytes may
    /// carry control codes the text path can't express). Not recorded for echo-dedup (no local pre-echo).
    /// A no-op for kinds with no text funnel. Default does nothing; ``LivePaneSession`` routes to the
    /// `InputBarModel`, test fakes record it.
    func sendBytes(_ bytes: [UInt8])

    // MARK: Terminal bell (attention signal)

    /// Whether the remote rang the terminal bell (BEL / `\a`) since it was last cleared — drives the
    /// pill + sidebar "attention" badge on an UNFOCUSED pane (a build finished / error rang while you
    /// were elsewhere). `false` for kinds with no terminal. Default implementation returns `false`.
    var bellPending: Bool { get }

    /// Clears the pending-bell flag (called when the pane is focused, so seeing it dismisses the badge).
    /// Default does nothing; ``LivePaneSession`` routes to the terminal model.
    func clearBell()

    /// Tear the session down for good (the pane is closing). Delegates to the proven
    /// `ConnectionViewModel` teardown order, closes the inspector channel, and stops any video stack.
    /// Called by `reconcile()` for every orphaned leaf id before it is dropped from the registry.
    func teardown() async
}

public extension PaneSessionHandle {
    /// Default: no shell, never busy. ``LivePaneSession`` overrides with the terminal's live
    /// `shellActivity`; test fakes override with a settable flag.
    var isShellBusy: Bool { false }

    /// Default: no text funnel (the video kinds). ``LivePaneSession`` overrides for terminal/Claude panes.
    func sendText(_: String) {}

    /// Default: no text funnel. ``LivePaneSession`` overrides for terminal/Claude panes.
    func sendBytes(_: [UInt8]) {}

    /// Default: no terminal, never rings. ``LivePaneSession`` overrides via its terminal model.
    var bellPending: Bool { false }

    /// Default: nothing to clear. ``LivePaneSession`` routes to the terminal model.
    func clearBell() {}
}

// MARK: - ID adoption (store-internal)

/// Lets `reconcile()` bind a freshly-materialized handle's identity to the **leaf's** ``PaneID``.
///
/// The public ``WorkspaceStore`` injection seam is `@MainActor (PaneSpec) -> any PaneSessionHandle`
/// — a ``PaneSpec`` carries no id (it is pure intent; identity lives on the tree's leaf). So a
/// just-built handle mints a placeholder id, and the store immediately calls ``adopt(id:)`` with the
/// real leaf id before keying the registry by it. This keeps the public seam id-free while still
/// guaranteeing the `reconcile()` invariant `registry.keys == allLeafIDs()` AND `handle.id == leafID`
/// (docs/22 §2.3, §11.2 the `.id(PaneID)` identity hazard). Internal on purpose: only the store calls
/// it, and only once, at materialization. The store no-ops gracefully if a handle does not adopt.
@MainActor
protocol PaneSessionIDAdopting: AnyObject {
    /// Re-points this handle's `id` at `id`. Called exactly once by `reconcile()` right after the
    /// handle is built and before it is registered.
    func adopt(id: PaneID)
}

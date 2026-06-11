import Foundation
@testable import AislopdeskClientUI

// MARK: - FakePaneSession (the store test double)

/// The test double the ``WorkspaceStore`` reconcile/fan-out/video-cap tests inject via the
/// `makeSession` seam (docs/22 §0, §8). It conforms to ``PaneSessionHandle`` EXACTLY and records the
/// lifecycle calls + their ordering so a test can assert reconcile correctness, teardown ordering,
/// and the scenePhase fan-out — **without ever constructing a `AislopdeskClient` or a `HostServer`**.
///
/// Built from a ``PaneSpec`` (mirroring `LivePaneSession.make`'s spec→session shape) so the store's
/// production and test factories are interchangeable. It also conforms to the store-internal
/// ``PaneSessionIDAdopting`` so `reconcile()` re-points its `id` at the leaf id, exactly as it does for
/// the live session — which is what lets the registry-key invariant be asserted.
@MainActor
@Observable
final class FakePaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    // MARK: Identity

    /// Placeholder until the store adopts the leaf id (see ``adopt(id:)``).
    private(set) var id: PaneID
    let kind: PaneKind

    /// The spec it was built from (so a test can assert kind/endpoint wiring).
    let spec: PaneSpec

    // MARK: Recorded lifecycle

    /// How many times ``pause()`` was called.
    private(set) var pauseCount = 0
    /// How many times ``resume()`` was called.
    private(set) var resumeCount = 0
    /// How many times ``teardown()`` was called.
    private(set) var teardownCount = 0

    /// A monotonically-appended log of every lifecycle event, in call order, for ordering assertions.
    enum Event: Equatable, Sendable { case pause, resume, teardown, adopt(PaneID), videoActive(Bool) }
    private(set) var events: [Event] = []

    // MARK: Video activation

    /// The video-activation flag the cap tests assert against (only meaningful for `.remoteGUI`).
    private(set) var isVideoActive: Bool = false

    // MARK: Teardown gate (default OFF)

    /// An OPT-IN blocking gate for `teardown()` (default `nil` ⇒ OFF, so every existing test is
    /// unchanged — teardown completes synchronously as before). When a test sets this gate, `teardown()`
    /// SUSPENDS on it before recording, which lets the same-tick-close+reopen video-cap test and the
    /// quiesce drain-loop test observe a teardown that is in-flight-but-not-finished (so the store's
    /// `tearingDownVideo` accounting and `quiesce()`'s fixpoint loop can be exercised deterministically).
    var teardownGate: FakeTeardownGate?

    /// Flips `true` the instant `teardown()` is entered (before suspending on the gate), so a test can
    /// wait for the body to be in flight without racing the suspension.
    private(set) var teardownEntered = false

    /// Mirrors ``LivePaneSession``: a `.remoteGUI` pane that was video-active before `pause()` is
    /// remembered so `resume()` re-activates it. Guarded to `.remoteGUI` so the unconditional-flip cap
    /// tests (which never call pause/resume) are unaffected.
    private var wasVideoActiveBeforePause = false

    // MARK: Init

    /// Builds a fake session from `spec` (the store-injected shape). Mints a placeholder id; the store
    /// adopts the leaf id during reconcile.
    init(_ spec: PaneSpec) {
        self.id = PaneID()
        self.kind = spec.kind
        self.spec = spec
    }

    // MARK: PaneSessionIDAdopting

    func adopt(id: PaneID) {
        self.id = id
        events.append(.adopt(id))
    }

    // MARK: PaneSessionHandle: video

    func setVideoActive(_ active: Bool) {
        // Match LivePaneSession: a no-op for non-video kinds.
        guard kind == .remoteGUI else { return }
        isVideoActive = active
        events.append(.videoActive(active))
    }

    // MARK: PaneSessionHandle: lifecycle

    func pause() async {
        pauseCount += 1
        events.append(.pause)
        // Mirror LivePaneSession: suspend live video and remember it for resume (.remoteGUI only).
        if isVideoActive {
            wasVideoActiveBeforePause = true
            isVideoActive = false
            events.append(.videoActive(false))
        }
    }

    func resume() async {
        resumeCount += 1
        events.append(.resume)
        // Mirror LivePaneSession: re-activate video that was active before pause (.remoteGUI only).
        if kind == .remoteGUI, wasVideoActiveBeforePause {
            wasVideoActiveBeforePause = false
            isVideoActive = true
            events.append(.videoActive(true))
        }
    }

    func teardown() async {
        teardownEntered = true
        // OPT-IN suspension: if a test installed a gate, park here until it releases — so the test can
        // observe the in-flight-teardown window the store's cap/quiesce accounting depends on. Default
        // (no gate) is an immediate pass-through, leaving every other test's timing unchanged.
        if let teardownGate {
            await teardownGate.wait()
        }
        teardownCount += 1
        events.append(.teardown)
    }
}

// MARK: - FakeTeardownGate (the opt-in controllable suspension point for teardown)

/// A main-actor gate that suspends every caller of ``wait()`` until ``release()`` is called once, after
/// which all current and future waiters proceed immediately. Mirrors the ScenePhase fan-out tests'
/// `ContinuationGate` but lives here so the video-cap and quiesce drain-loop suites can hold a
/// ``FakePaneSession/teardown()`` suspended and prove the store keeps counting an in-flight video
/// teardown against the cap (and that `quiesce()` awaits a task spawned mid-drain).
///
/// Main-actor isolated (no locks): the store, the sessions, and the tests all run on the main actor, so
/// the waiter bookkeeping is single-threaded by construction.
@MainActor
final class FakeTeardownGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    /// Number of callers currently parked in ``wait()`` (lets a test observe how many teardowns are
    /// suspended before releasing).
    var waiterCount: Int { continuations.count }

    /// Suspends until the gate is released. Returns immediately if already released.
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuations.append(cont)
        }
    }

    /// Opens the gate: resumes all parked waiters and lets future ``wait()`` calls pass through.
    func release() {
        isOpen = true
        let parked = continuations
        continuations.removeAll()
        for cont in parked { cont.resume() }
    }
}

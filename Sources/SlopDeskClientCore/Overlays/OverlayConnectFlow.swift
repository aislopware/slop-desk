// OverlayConnectFlow — the Connect form's in-flight attempt, owned once for both shells.
//
// The Connect sheet is a FORM, and a form's commit is a lifecycle rather than a call: fire
// ``AppConnection/connect()``, survive the await, and then decide — twice — whether the surface that
// started it is still the surface that should close. Both shells drew the same form and both typed the
// same ladder underneath it, down to the capture list, so the ladder is here and the two sheets are the
// buttons that call it.
//
// ⚠️ THE CLOSE IS DOUBLE-GUARDED, and neither guard subsumes the other.
//
//   1. THE TASK IS STORED AND CANCELLED. A fire-and-forget attempt outlives the sheet, and a slow
//      connect that finally resolves would dismiss a freshly REOPENED sheet mid-edit. Cancel and
//      teardown both kill it, and `Task.isCancelled` is re-asked after the await because cancellation
//      is cooperative — `connect()` may well have run to completion first.
//   2. THE GENERATION MUST STILL MATCH. ``OverlayCoordinator/connectGeneration`` is bumped by every
//      open and every close, so a completion that arrives against a stale one closes nothing. This is
//      what covers the window a cancelled Task cannot: the sheet was closed and reopened while the
//      await was in flight, which is a NEW presentation the old attempt has no business dismissing.
//
// WHAT IT DOES NOT DECIDE is whether a resolved attempt closes at all — that is
// ``ConnectPresentation/shouldCloseAfterConnect(status:)``, over the wire's own rule, so a `.failed`
// result leaves the sheet up with its reason inline on both platforms. This type is the plumbing under
// that decision, never a second copy of it.
//
// NO VIEW, NO FRAMEWORK. It touches nothing but the connection, the coordinator and `Task`, which is
// why it can live below the split at all.

import SlopDeskWorkspaceCore

/// The Connect form's one connect attempt: start it, cancel it, and never close a sheet it did not open.
@preconcurrency
@MainActor
public final class OverlayConnectFlow {
    private let connection: AppConnection
    private let coordinator: OverlayCoordinator
    /// The in-flight attempt. At most one — a second `start()` supersedes the first rather than racing it.
    private var task: Task<Void, Never>?

    public init(connection: AppConnection, coordinator: OverlayCoordinator) {
        self.connection = connection
        self.coordinator = coordinator
    }

    /// ⚠️ THE OWNER'S TEARDOWN IS ALSO A CANCELLATION. A sheet released with an attempt still running
    /// must not leave a completion pointed at a coordinator the user has moved on from.
    deinit {
        task?.cancel()
    }

    /// Validate-then-connect. A no-op unless the form parses — the confirm button is disabled then too,
    /// and `connect()` re-guards the parse internally, so nothing here force-unwraps.
    public func start() {
        guard connection.canConnect else { return }
        task?.cancel()
        let generation = coordinator.connectGeneration
        task = Task { [connection, coordinator] in
            await connection.connect()
            guard !Task.isCancelled else { return }
            guard ConnectPresentation.shouldCloseAfterConnect(status: connection.status) else { return }
            coordinator.closeConnect(ifCurrent: generation)
        }
    }

    /// Drops the in-flight attempt WITHOUT closing anything. The two dismissals want different halves:
    /// Cancel cancels and then flips the coordinator's flag, and a system-driven dismissal (the phone's
    /// swipe) cancels and lets the shell tell the coordinator in its own words.
    public func cancel() {
        task?.cancel()
        task = nil
    }
}

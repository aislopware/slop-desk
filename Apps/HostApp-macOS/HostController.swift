import Foundation
import Observation
import AislopdeskHost
import AislopdeskTransport

/// `@MainActor @Observable` start/stop wrapper over the in-process terminal ``HostServer``.
///
/// This is the in-process path (NOT a `aislopdesk-hostd` subprocess): `AislopdeskHost` is a clean
/// library product and `HostServer` has a fully app-usable public surface, so the menu-bar app
/// runs the SAME server the CLI runs — replicating the ~6 lines of `aislopdesk-hostd/main.swift`
/// (construct → `start()` → read back `boundPort()`; `stop()` on teardown) on a background
/// task driven by a Start/Stop toggle. The plain-shell `LaunchMode` is hard-coded (no
/// `--claude`); the inspector is out of MVP scope.
@MainActor
@Observable
final class HostController {
    /// The observable lifecycle state driving the popover UI.
    enum State: Equatable {
        case stopped
        case starting
        /// Running and bound to `port` (the OS-resolved port, in case `0` was requested).
        case running(port: UInt16)
        /// Tearing down: `stop()` was requested and the async drain (which releases the listener
        /// socket) is in flight (R16 HOSTVIEW-2). The UI stays BUSY here so a fast Stop→Start cannot
        /// race the old listener and self-collide with EADDRINUSE on the same port.
        case stopping
        case failed(String)
    }

    private(set) var state: State = .stopped

    /// Live count of distinct connected clients, fed by ``HostServer/onConnectionCountChanged``.
    /// `nil` means "running but the count is not being observed" → the UI shows "Listening".
    private(set) var clientCount: Int?

    /// The running server, retained across the actor while live; `nil` when stopped.
    private var server: HostServer?

    /// The single ordered consumer of the live client-count stream (R15 #5/#7). One loop applies
    /// counts in FIRING ORDER (no Task-per-event reordering) and drops any count from a server that
    /// is no longer the current one. Cancelled on stop/restart.
    private var countConsumerTask: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isBusy: Bool { state == .starting || state == .stopping }

    /// SF Symbol for the menu-bar status item. Red-tinted "missing-permission" affordance is
    /// applied at the view layer (research §C1); this just reflects the running state.
    var menuBarSymbol: String {
        switch state {
        case .running: return "bolt.horizontal.circle.fill"
        case .starting, .stopping: return "bolt.horizontal.circle"
        case .stopped: return "bolt.horizontal.circle"
        // A failed-to-start daemon must NOT look identical to a never-started one — a distinct error
        // glyph tells the operator the host is broken, not merely off.
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// Start the in-process terminal host on `port` (0 → OS-assigned; read back the real port).
    /// No-op unless currently stopped/failed.
    func start(port: UInt16) {
        switch state {
        case .running, .starting, .stopping:
            // Already running, or busy bringing up / tearing down — refuse. Refusing during `.stopping`
            // is what prevents a new listener binding the port while the old one is still being released
            // (R16 HOSTVIEW-2); the UI also keeps Start disabled across `.stopping` via `isBusy`.
            return
        case .stopped, .failed:
            break
        }
        state = .starting
        clientCount = 0

        let server = HostServer(port: port, launchMode: .shell)
        // Surface session lifecycle to this process's stderr (same shape as the CLI's logger),
        // so a `Console.app` / launch-from-Terminal run shows "mux connection … accepted".
        server.onLog = { message in
            FileHandle.standardError.write(Data("AislopdeskHost: \(message)\n".utf8))
        }
        // Live client count (R15 #5/#7). The hook fires off the main actor (from the server's
        // lock-guarded spawn/remove paths AND from a stopped server's drain), so it must hop to this
        // actor. Funnel every count through one AsyncStream consumed by a SINGLE MainActor loop:
        //  - ordering (#7): updates apply in firing order, not via a Task-per-event firehose whose
        //    MainActor hops can reorder a quick 1→2→1 burst into a transiently wrong value;
        //  - identity (#5): a count from a server that is no longer `self.server` is dropped, so an
        //    old server's stop()-time `0` can't clobber a freshly-started server's count (which also
        //    feeds `hasConnectedClients`, gating the Stop/Quit confirmation).
        let (countStream, countContinuation) = AsyncStream<Int>.makeStream()
        server.onConnectionCountChanged = { count in countContinuation.yield(count) }
        self.countConsumerTask?.cancel()
        self.countConsumerTask = Task { @MainActor [weak self] in
            for await count in countStream {
                guard let self, self.server === server else { continue }
                self.clientCount = count
            }
        }
        // Post-ready listener health (R15 #2): if the listener silently dies after binding (interface
        // drop / socket error), the host must NOT keep showing a healthy "running" badge while it
        // accepts nothing. Flip to `.failed` with the same operator-facing message — guarded by server
        // identity so a stale signal from a replaced server is ignored. Tear the dead server down first
        // (`stop()` returns to `.stopped`), THEN reflect the failure.
        // [weak server] as well as [weak self]: this closure is stored ON `server`
        // (`server.onListenerFailed`), so capturing `server` strongly would form a self-retain cycle
        // (server → onListenerFailed → server) that leaks one zombie HostServer per Start/Stop cycle
        // on the long-lived menu-bar host — the exact R5-rank-3 leak class. Weak both: a replaced or
        // deallocated server then fails the identity guard (or can't fire) and nothing leaks.
        server.onListenerFailed = { [weak self, weak server] err in
            Task { @MainActor in
                guard let self, let server, self.server === server else { return }
                self.stop()
                self.state = .failed(Self.describe(err, port: port))
            }
        }
        self.server = server

        Task {
            do {
                try await server.start()
                let bound = await server.boundPort() ?? port
                // Guard against a stop() that raced in while we were awaiting start().
                guard self.server === server else { return }
                self.state = .running(port: bound)
            } catch {
                guard self.server === server else { return }
                self.server = nil
                self.clientCount = nil
                self.state = .failed(Self.describe(error, port: port))
            }
        }
    }

    /// Stop the in-process host and return to `.stopped`. No-op when not running.
    func stop() {
        guard let server else { return }
        self.server = nil
        // R16 HOSTVIEW-2: go to `.stopping` (BUSY), not straight to `.stopped`. `server.stop()` is async
        // and only releases the bound listener socket near the end (transport.stop() → listener.cancel());
        // re-enabling Start before that completes lets a fast Stop→Start race the old listener and fail
        // with a spurious "Port already in use". Flip to `.stopped` only AFTER the drain — and only if a
        // newer start()/failure has not superseded us in the meantime.
        state = .stopping
        clientCount = nil
        // End the count consumer (R15 #5/#7): cancelling the task makes its `for await` return nil,
        // so no late drain-time `0` is applied after we leave `.running`.
        countConsumerTask?.cancel()
        countConsumerTask = nil
        Task { @MainActor [weak self] in
            await server.stop()
            guard let self else { return }
            if case .stopping = self.state { self.state = .stopped }
        }
    }

    /// A compact, user-facing error description (avoid dumping a giant Swift error). The listener-start
    /// failure surfaces as ``AislopdeskTransportError/listenerFailed(_:)`` (NOT an `NSPOSIXErrorDomain` NSError
    /// — the old `ns.code == 48` branch was therefore dead), and is overwhelmingly a port collision for a
    /// known port. Name the concrete port so the operator can fix it (change the port / kill the holder).
    static func describe(_ error: Error, port: UInt16) -> String {
        if case let .listenerFailed(detail)? = error as? AislopdeskTransportError {
            // Robust EADDRINUSE classification (R15 #6): the old `detail.contains("48")` fallback
            // misclassified any error whose text merely embedded the digits "48" (a port like 4843,
            // errno 148, a size like 1048576) as a port collision. Delegate to the transport's pure
            // classifier, which matches the errno only as a standalone token plus the "in use" phrase.
            if AislopdeskTransportError.listenerDetailIndicatesAddressInUse(detail) {
                return "Port \(port) is already in use"
            }
            return "Could not open port \(port)"
        }
        // Any other error: prefer a LocalizedError's clean line, else the system description.
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

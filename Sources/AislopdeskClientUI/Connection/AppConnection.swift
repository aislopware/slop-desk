import AislopdeskTransport
import Foundation

/// The ONE app-global connection (docs/31): the single host the whole app talks to, fronted by the
/// connect-gate. It owns the editable host/port form, the single ``ConnectionStatus`` the gate +
/// toolbar render, and the lifecycle that PINS the shared mux up (via ``ConnectionRegistry/pin(host:port:)``)
/// so the app is "connected" before any pane opens a channel and stays connected across closing the last
/// pane. Panes are pure channels on this connection; `.remoteGUI` panes are lanes on the same host's UDP
/// flow. The committed ``target`` is what every pane/video session reads for its host/ports.
///
/// Reconnect is app-level: while connected it polls the registry's liveness and, on a drop, reappears the
/// gate ("reconnecting…") and retries with backoff until it is back (or gives up to `.unreachable`, with a
/// manual Retry). The per-pane ``ConnectionViewModel`` still re-opens each channel on the rebuilt mux —
/// the two cooperate via the registry's dead-eviction single-flight, so the mux is rebuilt exactly once.
@preconcurrency
@MainActor
@Observable
public final class AppConnection {
    // MARK: Editable form fields (bound to the connect-gate)

    public var host: String
    public var port: String
    public var mediaPort: String
    public var cursorPort: String

    // MARK: Committed state

    /// The committed target every pane/video session reads (always valid). Seeded from the persisted
    /// ``Workspace/connection`` and re-committed on each successful ``connect()``.
    public private(set) var target: ConnectionTarget

    /// The single app-wide status the gate + toolbar render.
    public private(set) var status: ConnectionStatus = .disconnected

    /// Invoked when a target is committed (a successful connect) so the store can persist it into
    /// ``Workspace/connection``. Set by the store after construction (avoids an init cycle).
    public var onTargetCommitted: (@MainActor (ConnectionTarget) -> Void)?

    // MARK: Collaborators

    private let registry: ConnectionRegistry

    /// Monotonic connect-attempt counter (the ``ConnectionViewModel`` supersede-guard pattern): a
    /// teardown / second connect during a pin `await` supersedes us, so post-await status writes from a
    /// stale attempt are discarded.
    private var connectGeneration = 0
    /// True between a deliberate ``disconnect()`` and the next ``connect()`` so a trailing supervisor
    /// tick is not mis-read as a drop to reconnect.
    private var deliberatelyClosed = false
    /// The currently-pinned target, so a host change unpins the old endpoint before pinning the new, and
    /// `disconnect()`/`pause()` unpin the right one.
    private var pinnedTarget: ConnectionTarget?
    /// The liveness-watch / reconnect supervisor.
    private var superviseTask: Task<Void, Never>?

    /// Healthy-state liveness poll cadence + reconnect backoff ceiling (the ceiling lives on the
    /// presenter so the "attempt N of M" copy can never drift from the real campaign length).
    private static let healthyPoll: Duration = .seconds(2)
    private static var maxReconnectAttempts: Int { ConnectionPresenter.maxReconnectAttempts }

    // MARK: Recent hosts (the gate's MRU menu)

    /// Most-recent-first successful connect targets (deduped by host:port, capped at
    /// ``recentTargetsLimit``) — the gate's "recent hosts" menu. Loaded from `defaults` at init,
    /// re-saved on every successful connect.
    public private(set) var recentTargets: [ConnectionTarget] = []

    /// Where the MRU persists. Injectable so tests use a scratch suite; the app uses `.standard`.
    private let defaults: UserDefaults
    private static let recentTargetsKey = "connection.recentTargets"
    static let recentTargetsLimit = 5

    public init(
        registry: ConnectionRegistry,
        seed: ConnectionTarget = .default,
        defaults: UserDefaults = .standard,
    ) {
        self.registry = registry
        target = seed
        host = seed.host
        port = String(seed.port)
        mediaPort = String(seed.mediaPort)
        cursorPort = String(seed.cursorPort)
        self.defaults = defaults
        recentTargets = Self.loadRecentTargets(from: defaults)
    }

    /// The persisted MRU, or `[]` (a fresh install / undecodable blob — best-effort, never throws).
    static func loadRecentTargets(from defaults: UserDefaults) -> [ConnectionTarget] {
        guard let data = defaults.data(forKey: recentTargetsKey) else { return [] }
        return (try? JSONDecoder().decode([ConnectionTarget].self, from: data)) ?? []
    }

    /// Pure MRU push: dedupe by host:port (a re-connect with changed video ports REPLACES the entry —
    /// host:port is the identity, ports are settings), insert at the front, cap at `limit`.
    static func pushingRecent(
        _ target: ConnectionTarget,
        into list: [ConnectionTarget],
        limit: Int = AppConnection.recentTargetsLimit,
    ) -> [ConnectionTarget] {
        var out = list.filter { !($0.host == target.host && $0.port == target.port) }
        out.insert(target, at: 0)
        if out.count > limit { out.removeLast(out.count - limit) }
        return out
    }

    /// Records a SUCCESSFUL connect into the MRU (failures don't pollute the menu) and persists it.
    private func recordRecentTarget(_ t: ConnectionTarget) {
        recentTargets = Self.pushingRecent(t, into: recentTargets)
        if let data = try? JSONEncoder().encode(recentTargets) {
            defaults.set(data, forKey: Self.recentTargetsKey)
        }
    }

    /// Fills the form fields from a recent target (the gate's MRU menu pick). Form-only — the user
    /// still presses Connect.
    public func fillForm(from t: ConnectionTarget) {
        host = t.host
        port = String(t.port)
        mediaPort = String(t.mediaPort)
        cursorPort = String(t.cursorPort)
    }

    // MARK: Form validation (the gate's Connect button)

    /// The parsed target from the form, or `nil` if any field is invalid.
    private func parsedTarget() -> ConnectionTarget? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty,
              let p = UInt16(port.trimmingCharacters(in: .whitespaces)), p >= 1,
              let m = UInt16(mediaPort.trimmingCharacters(in: .whitespaces)), m >= 1,
              let c = UInt16(cursorPort.trimmingCharacters(in: .whitespaces)), c >= 1,
              m != c else { return nil }
        return ConnectionTarget(host: h, port: p, mediaPort: m, cursorPort: c)
    }

    /// Whether the form parses to a valid target (the Connect button's enabled state).
    public var canConnect: Bool { parsedTarget() != nil }

    /// Why Connect is disabled, or `nil` when enabled (`validationHint == nil` ⟺ `canConnect`).
    public var validationHint: String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a host" }
        if UInt16(port.trimmingCharacters(in: .whitespaces)).map({ $0 < 1 }) ?? true {
            return "Port must be a number from 1–65535"
        }
        let m = UInt16(mediaPort.trimmingCharacters(in: .whitespaces))
        let c = UInt16(cursorPort.trimmingCharacters(in: .whitespaces))
        if (m.map { $0 < 1 } ?? true) || (c.map { $0 < 1 } ?? true) {
            return "Video ports must be numbers from 1–65535"
        }
        if m == c { return "Media and cursor ports must differ" }
        return nil
    }

    // MARK: Lifecycle

    /// Connects to the host in the form: commits the target, PINS the shared mux, and starts the
    /// liveness/reconnect supervisor. `status` flips `.connecting` → `.connected` / `.failed`.
    public func connect() async {
        guard let t = parsedTarget() else { status = .failed("invalid host/port")
            return
        }
        status = .connecting
        deliberatelyClosed = false
        target = t
        onTargetCommitted?(t)
        connectGeneration &+= 1
        let gen = connectGeneration
        await establish(t, generation: gen, isRetry: false)
    }

    /// The shared establish path used by ``connect()`` and ``resume()``: unpin a stale endpoint, pin the
    /// new one, and (on success) start the supervisor. Guarded by `gen`/`deliberatelyClosed`.
    private func establish(_ t: ConnectionTarget, generation gen: Int, isRetry _: Bool) async {
        // Host changed since the last pin → release the old shared connection first.
        if let prev = pinnedTarget, prev.host != t.host || prev.port != t.port {
            await registry.unpin(host: prev.host, port: prev.port)
        }
        // Record the pin target BEFORE the (slow) build await — so a concurrent `disconnect()`/`pause()`
        // during the connect unpins THIS endpoint. The registry's `pin()` post-build check then tears the
        // just-built connection down instead of orphaning it: a Cancel mid-connect must not leak a socket
        // pair. (`pinnedTarget` thus means "the endpoint pinned OR being pinned".)
        pinnedTarget = t
        do {
            try await registry.pin(host: t.host, port: t.port)
            guard gen == connectGeneration, !deliberatelyClosed else { return }
            status = .connected
            recordRecentTarget(t)
            startSupervisor(t, generation: gen)
        } catch {
            guard gen == connectGeneration, !deliberatelyClosed else { return }
            status = .failed(Self.failureReason(for: error))
        }
    }

    /// A deliberate disconnect: stop the supervisor, unpin the shared mux, surface `.disconnected`. The
    /// per-pane channels are torn down separately by the store; if any still hold the mux it survives
    /// until they release (the registry refcount), but the app is no longer pinned.
    public func disconnect() async {
        deliberatelyClosed = true
        connectGeneration &+= 1 // supersede any in-flight establish/supervisor
        superviseTask?.cancel()
        superviseTask = nil
        if let prev = pinnedTarget {
            await registry.unpin(host: prev.host, port: prev.port)
            pinnedTarget = nil
        }
        status = .disconnected
    }

    /// Manual Retry from the gate (after `.failed`/`.unreachable`): re-run `connect()` with the form.
    public func retry() async { await connect() }

    /// Mark the app connected WITHOUT pinning a TCP mux — used ONLY by the video-only automation seam
    /// (`check-video.sh`): `aislopdesk-videohostd` serves UDP only and runs no TCP listener, so there is no mux
    /// to pin; a `.remoteGUI` pane rides the shared UDP flow independently. This dismisses the gate +
    /// mounts the canvas so that pane can open its UDP lane. Never used in the normal user flow (which
    /// always pins the terminal mux via ``connect()``).
    public func markConnectedForAutomation() {
        deliberatelyClosed = false
        status = .connected
    }

    /// iOS background: unpin so the shared mux closes (the OS kills an app that strands a background
    /// socket). The per-pane `pauseAll` pauses channels; `resume()` re-pins + the channels re-open.
    public func pause() async {
        guard !deliberatelyClosed, let prev = pinnedTarget else { return }
        connectGeneration &+= 1 // stop the supervisor cleanly without flipping `deliberatelyClosed`
        superviseTask?.cancel()
        superviseTask = nil
        await registry.unpin(host: prev.host, port: prev.port)
        pinnedTarget = nil
    }

    /// iOS foreground: re-establish the committed target (re-pins the mux) so channels can re-open.
    public func resume() async {
        guard !deliberatelyClosed else { return }
        connectGeneration &+= 1
        let gen = connectGeneration
        status = .connecting
        await establish(target, generation: gen, isRetry: true)
    }

    // MARK: Supervisor (liveness poll + auto-reconnect)

    /// Polls the registry's liveness while connected; on a drop, reappears `.reconnecting` and retries
    /// `pin` (which evicts the dead pooled connection and rebuilds) with capped backoff until it is back,
    /// or gives up to `.unreachable` (manual Retry then re-runs `connect()`).
    private func startSupervisor(_ t: ConnectionTarget, generation gen: Int) {
        superviseTask?.cancel()
        superviseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                guard gen == connectGeneration, !deliberatelyClosed else { return }
                let alive = await registry.isConnectionAlive(host: t.host, port: t.port)
                guard gen == connectGeneration, !deliberatelyClosed else { return }
                if alive {
                    attempt = 0
                    if status != .connected { status = .connected }
                    try? await Task.sleep(for: Self.healthyPoll)
                    continue
                }
                // Dropped → reconnect campaign.
                attempt += 1
                status = .reconnecting(attempt: attempt, nextRetry: nil)
                do {
                    try await registry.pin(host: t.host, port: t.port) // rebuilds via dead-eviction
                    guard gen == connectGeneration, !deliberatelyClosed else { return }
                    status = .connected // `pinnedTarget` is already `t` (set in establish, kept across reconnect)
                    attempt = 0
                } catch {
                    guard gen == connectGeneration, !deliberatelyClosed else { return }
                    if attempt >= Self.maxReconnectAttempts {
                        status = .unreachable
                        return // campaign exhausted; the gate's Retry re-runs connect()
                    }
                    // Linear-capped backoff (1…5s).
                    try? await Task.sleep(for: .seconds(min(Double(attempt), 5)))
                }
            }
        }
    }

    /// The user-facing `.failed` reason for a thrown error (humanized for `LocalizedError`, else the
    /// readable Swift payload) — same policy as ``ConnectionViewModel/failureReason(for:)``.
    static func failureReason(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

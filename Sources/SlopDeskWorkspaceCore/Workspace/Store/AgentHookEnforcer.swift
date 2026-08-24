// MARK: - The Claude Code hook enforcer (installed, not offered)

/// Puts the Claude Code agent-detection hooks on the host, without asking.
///
/// This used to be a settings card: a state machine behind an **Install Hooks** button, with a status
/// badge, a disabled state and a "Connect a session to manage hooks" note. Every one of those states
/// existed to describe a decision the user had no reason to make differently — agent detection is what
/// the app IS, and a build with the hooks uninstalled is a build with half its features dark. So the
/// button is gone and the answer is enforced: the hooks are installed on the first connection that can
/// carry the RPC, and re-checked on each one after.
///
/// **Claude Code only.** There is no codex/opencode equivalent. The hooks are the host-side
/// agent-detection hooks; this NEVER pauses an agent pending a slopdesk confirmation — it observes and
/// notifies, never gates approval.
///
/// **Injected async seams.** The two host round-trips are injected so the app wires them to the active
/// connection's first-pane ``MetadataClient`` (`installAgentHooks` / `agentHookStatus`), while a unit
/// test drives the whole thing with fakes and no live socket. The enforcer is global but
/// `MetadataClient` is one-per-pane, so the app resolves whichever pane carries a live channel; with no
/// connected pane the status seam yields `nil` and the pass simply does nothing, to be retried on the
/// next connection.
///
/// There is no `uninstall`. Nothing in the app removes the hooks any more — `slopdesk hooks uninstall`
/// on the HOST is where that decision lives, next to the file it edits.
import Foundation

@preconcurrency
@MainActor
@Observable
public final class AgentHookEnforcer {
    /// What one enforcement pass concluded. Recorded rather than rendered — nothing draws this; it is
    /// what a diagnostic reads and what the tests assert against.
    public enum Outcome: Equatable, Sendable {
        /// No pass has run yet.
        case unknown
        /// No connected pane backs the RPC. Nothing was attempted; the next connection retries.
        case unreachable
        /// The hooks were already installed and the host's listener is bound — the whole point.
        case active
        /// This pass installed them, and the follow-up probe found the listener bound.
        case installed
        /// The hooks are on disk but the host's hook LISTENER is not bound, so every hook exits
        /// silently. `make host-restart` binds it; nothing this side can do, and reporting it as
        /// success would be the same lie the old green check told.
        case inactive
        /// The install RPC was refused, or the probe after it still says not-installed.
        case failed
    }

    /// What the last pass concluded.
    public private(set) var outcome: Outcome = .unknown

    /// Installs the hooks on the host (wired to ``MetadataClient/installAgentHooks()``). `true` on host `.ok`.
    public typealias Install = @MainActor () async -> Bool
    /// Probes install state (wired to ``MetadataClient/agentHookStatus()``): the typed
    /// `[installed][listenerActive]` report, or `nil` when no connected pane backs the RPC.
    public typealias RefreshStatus = @MainActor () async -> MetadataClient.AgentHookStatusReport?

    private let installSeam: Install
    private let refreshStatusSeam: RefreshStatus
    /// Whether a pass is in flight — a second connection landing mid-install must not fire another.
    private var isRunning = false

    /// The default seams are inert (`false` / `nil`) so an unwired composition concludes
    /// ``Outcome/unreachable`` rather than crashing; the app overrides both with live RPCs.
    public init(
        install: @escaping Install = { false },
        refreshStatus: @escaping RefreshStatus = { nil },
    ) {
        installSeam = install
        refreshStatusSeam = refreshStatus
    }

    /// One enforcement pass: probe, and install if the probe says the hooks are not there.
    ///
    /// Called on every transition into connected, because "installed" is a fact about the HOST and the
    /// host on the other end of the second connection is not necessarily the one from the first. A pass
    /// already in flight swallows a re-entrant call rather than firing a second install.
    ///
    /// Installing is followed by a RE-PROBE, not by assuming success: a successful write proves only the
    /// `settings.json` merge, never that the host's hook listener bound. ``Outcome/inactive`` is the
    /// honest answer for that host, and it is deliberately not ``Outcome/failed`` — the install worked,
    /// the daemon needs restarting.
    public func enforce() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        switch await refreshStatusSeam() {
        case .none:
            outcome = .unreachable
        case let .some(report) where report.installed:
            outcome = report.listenerActive ? .active : .inactive
        case .some:
            guard await installSeam() else {
                outcome = .failed
                return
            }
            switch await refreshStatusSeam() {
            case let .some(report) where report.installed:
                outcome = report.listenerActive ? .installed : .inactive
            case .some:
                outcome = .failed
            case .none:
                outcome = .unreachable
            }
        }
    }
}

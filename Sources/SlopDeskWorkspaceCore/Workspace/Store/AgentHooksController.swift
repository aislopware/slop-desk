import Foundation

// MARK: - The Agents settings-card model (Claude Code only)

/// The `@MainActor @Observable` model behind the Agents settings card's **Install Hooks** row — the
/// install / uninstall / status state machine the card binds to. **Claude Code only**: there is no
/// codex/opencode equivalent here; the card renders one CLAUDE CODE section over this single controller.
/// The hooks it manages are the host-side agent-detection hooks; this NEVER pauses an agent pending a
/// slopdesk confirmation — it observes and notifies, never gates approval.
///
/// **Injected async seams.** The three host round-trips are injected so the app wires them to the active
/// connection's first-pane ``MetadataClient`` (`installAgentHooks` / `uninstallAgentHooks` /
/// `agentHookStatus`), while a unit test drives the whole state machine with fakes (no live socket). The
/// card is global but `MetadataClient` is one-per-pane, so the app resolves whichever pane carries a live
/// channel; with no connected pane the status seam yields `nil`, which lands the card on
/// ``InstallState/disconnected`` (a disabled card with a "Connect a session" note — NEVER a false
/// "Not Installed").
@preconcurrency
@MainActor
@Observable
public final class AgentHooksController {
    /// The card's install state — drives the title row's buttons + the status row + their disabled state.
    public enum InstallState: Equatable, Sendable {
        /// Not yet probed — the card renders neutrally until the first ``refresh()`` resolves (transient;
        /// the card fires `refresh()` on appear). Treated like ``disconnected`` for display.
        case unknown
        /// The host replied "not installed" — show the **Install** button + a gray "Not Installed" status.
        case notInstalled
        /// The host replied "installed AND the hook listener is bound" — show **Installed** (disabled) +
        /// **Uninstall** + a green "✓ Installed" status. Only this state earns the green check.
        case installed
        /// The hooks are written to `settings.json` but the host's hook LISTENER is not bound (hostd was
        /// launched without `SLOPDESK_AGENT_HOOKS=1`, or the bind failed) — every installed hook exits
        /// silently, so the integration is DEAD despite being installed. Shows a warning
        /// "Installed — inactive" badge + the hostd-restart instruction, never the false green check.
        case installedInactive
        /// An install / uninstall RPC is in flight — the buttons disable (the card shows progress).
        case working
        /// No connected pane backs the card (the status seam returned `nil`) — the buttons disable with a
        /// "Connect a session to manage hooks" note. NEVER a false "Not Installed".
        case disconnected
    }

    /// The live install state the card observes. Starts ``InstallState/unknown`` until the first probe.
    public private(set) var state: InstallState = .unknown

    /// Installs the hooks on the host (wired to ``MetadataClient/installAgentHooks()``). `true` on host `.ok`.
    public typealias Install = @MainActor () async -> Bool
    /// Uninstalls the hooks (wired to ``MetadataClient/uninstallAgentHooks()``). `true` on host `.ok`.
    public typealias Uninstall = @MainActor () async -> Bool
    /// Probes install state (wired to ``MetadataClient/agentHookStatus()``): the typed
    /// `[installed][listenerActive]` report, or `nil` when no connected pane backs the card / the reply
    /// dropped — which lands the card on ``InstallState/disconnected``.
    public typealias RefreshStatus = @MainActor () async -> MetadataClient.AgentHookStatusReport?

    private let installSeam: Install
    private let uninstallSeam: Uninstall
    private let refreshStatusSeam: RefreshStatus

    /// The default seams are inert (`false` / `nil`) so a preview / an unwired host renders the
    /// `.disconnected` card instead of crashing — the app overrides all three with live RPCs.
    public init(
        install: @escaping Install = { false },
        uninstall: @escaping Uninstall = { false },
        refreshStatus: @escaping RefreshStatus = { nil },
    ) {
        installSeam = install
        uninstallSeam = uninstall
        refreshStatusSeam = refreshStatus
    }

    // MARK: Derived view state

    /// Whether the hooks are installed on the host (drives "Installed"/"Uninstall" vs "Install" and the
    /// Agent-Behaviour toggles' enablement). TRUE for BOTH ``InstallState/installed`` and
    /// ``InstallState/installedInactive`` — the entries are on disk either way (behaviour preferences
    /// remain configurable; only the status badge distinguishes active from inactive).
    public var isInstalled: Bool { state == .installed || state == .installedInactive }
    /// Whether a write RPC is in flight (the card shows a spinner).
    public var isWorking: Bool { state == .working }
    /// Whether no connected pane backs the card (the card shows the "Connect a session" note).
    public var isDisconnected: Bool { state == .disconnected || state == .unknown }
    /// Whether the Install / Uninstall buttons are actionable — a known, connected state with no write in
    /// flight. `.working` disables during the RPC; `.disconnected` / `.unknown` disable until a pane connects.
    public var actionsEnabled: Bool {
        state == .installed || state == .installedInactive || state == .notInstalled
    }

    // MARK: Actions

    /// Re-probes the host install state — called on the card's appear (re-checked each open per spec, not
    /// cached forever). A `nil` reply (no connected pane / dropped) maps to ``InstallState/disconnected`` so
    /// the card never shows a false "Not Installed". A no-op while a write owns ``InstallState/working`` so a
    /// concurrent appear-probe can't clobber an in-flight install/uninstall.
    public func refresh() async {
        guard state != .working else { return }
        await applyProbe()
    }

    /// Installs the hooks: → ``InstallState/working``, fire the seam, then RE-PROBE — on success too, because
    /// a successful write proves only the `settings.json` merge, NOT that the host's hook listener is bound,
    /// so landing `.installed` directly would flash the false green check on a hostd launched without
    /// `SLOPDESK_AGENT_HOOKS=1`. The probe lands
    /// `.installed` / `.installedInactive` / `.disconnected` honestly (and a failure lands
    /// `.notInstalled` / `.disconnected` rather than a stuck `.working`). A no-op while a write is
    /// already in flight.
    public func install() async {
        guard state != .working else { return }
        state = .working
        _ = await installSeam()
        await applyProbe()
    }

    /// Uninstalls the hooks: → ``InstallState/working``, fire the seam, then ``InstallState/notInstalled`` on
    /// success or a re-probe on failure. A no-op while a write is already in flight.
    public func uninstall() async {
        guard state != .working else { return }
        state = .working
        if await uninstallSeam() {
            state = .notInstalled
        } else {
            await applyProbe()
        }
    }

    /// Fires the status seam and folds the typed report into ``state``: installed + listener bound →
    /// `.installed` (the ONLY green); installed with the listener unbound → `.installedInactive` (the
    /// hostd-restart warning); not installed → `.notInstalled`; `nil` → `.disconnected`. Bypasses the
    /// ``refresh()`` `.working` guard so the install/uninstall paths (which OWN the `.working` state)
    /// can re-resolve honestly.
    private func applyProbe() async {
        switch await refreshStatusSeam() {
        case let .some(report) where report.installed:
            state = report.listenerActive ? .installed : .installedInactive
        case .some:
            state = .notInstalled
        case .none:
            state = .disconnected
        }
    }
}

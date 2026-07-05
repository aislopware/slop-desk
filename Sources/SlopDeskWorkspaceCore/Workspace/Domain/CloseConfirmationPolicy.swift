import Foundation

// MARK: - CloseConfirmationPolicy (close-confirmation policy)

/// When a tab / pane / window close must be GATED behind a confirmation prompt
/// (`docs/ui-shell/spec/user-interface__window-tab-split.md`; the raw values are
/// `process` / `always` / `multiple_tabs`).
///
/// - ``process``: confirm only when a child PROCESS is still running in the closing unit (the long-standing
///   slopdesk busy-shell guard — ``PaneSessionHandle/isShellBusy``). The default, byte-identical to the
///   pre-E3 behaviour (a close parked behind a confirmation iff a command was mid-flight).
/// - ``always``: confirm on every close.
/// - ``multipleTabs``: confirm only when the unit being closed holds more than one tab (`multiple_tabs`
///   — closing a window with several tabs would lose them, so it asks; a single-tab window closes silently).
///
/// PURE: the decision is the static ``shouldConfirm(_:isBusy:tabCount:)`` truth table, unit-tested apart
/// from the store. `String`-raw + `CaseIterable` so it bridges to `Defaults` (see `SettingsKey`) and a
/// future Shell-settings picker can enumerate it. ``init(rawValue:)`` is validate-then-repair (an unknown
/// stored string falls back to ``process`` — never traps on hostile persisted config).
public enum CloseConfirmationPolicy: String, Codable, Sendable, CaseIterable {
    case process
    case always
    /// Raw value is the `multiple_tabs` config string (so the persisted setting round-trips with the
    /// value a future Shell-settings row writes).
    case multipleTabs = "multiple_tabs"

    /// Decodes the stored close-confirmation config string. Validate-then-repair: a recognized raw value
    /// maps to its case; anything else (a stale / hostile persisted string) repairs to ``process`` rather
    /// than trapping. A non-failable initializer that still satisfies the `RawRepresentable` requirement
    /// (so the `Defaults.PreferRawRepresentable` bridge keeps working) — it simply never returns `nil`.
    public init(rawValue: String) {
        switch rawValue {
        case "process": self = .process
        case "always": self = .always
        case "multiple_tabs": self = .multipleTabs
        default: self = .process
        }
    }

    /// Whether a close governed by `policy` must park behind a confirmation prompt, given whether the closing
    /// unit is BUSY (a child process is running) and how many TABS it holds:
    ///
    /// - ``process`` → `isBusy` (confirm only when a command is mid-flight).
    /// - ``always`` → `true` (confirm every time).
    /// - ``multipleTabs`` → `tabCount > 1` (confirm only when closing would drop more than one tab).
    ///
    /// PURE — the whole policy decision in one place, so the store wiring (and the macOS window-close gate)
    /// share one source of truth that ``CloseConfirmationPolicyTests`` pins as a truth table.
    public static func shouldConfirm(_ policy: Self, isBusy: Bool, tabCount: Int) -> Bool {
        switch policy {
        case .process: isBusy
        case .always: true
        case .multipleTabs: tabCount > 1
        }
    }
}

// MARK: - CloseScope (which close affordance is asking)

/// Which close affordance is consulting the policy — so the store can pick the right configured policy
/// (``SettingsKey/closeConfirmTab`` for a pane/tab close, ``SettingsKey/closeConfirmWindow`` for a window
/// close) and the right BUSY / tab-count inputs for ``CloseConfirmationPolicy/shouldConfirm(_:isBusy:tabCount:)``.
public enum CloseScope: Sendable, Equatable, CaseIterable {
    /// A single pane (a tiled leaf) is being closed.
    case pane
    /// A whole tab is being closed.
    case tab
    /// The window — mapped to the active ``Session`` (see `docs/DECISIONS.md`) — is being closed.
    case window
}

import Foundation

// MARK: - Terminal-rooted external-drop ingress

/// The `WorkspaceStore` entry point the external-drag actuator (the ``PaneDropReceiver``) calls to
/// land a dropped folder/file in a FRESH terminal — a new tab (the New-Tab zone) or a side split
/// (Split-Left / Split-Right) — and then point that terminal at the dropped path.
///
/// It lives OUT of the view layer precisely so the
/// `cd`-actuation is unit-testable at the store level against the `FakePaneSession` sink
/// (`OpenTerminalRootedStoreTests`), exactly like the cwd-inheritance ``setLastKnownCwd(_:for:)`` /
/// `deferInheritedCwd` deferred send is.
///
/// REUSES the existing actuators verbatim — ``newTab(kind:)`` / ``splitActivePane(axis:kind:leading:)`` mint
/// the new terminal (so the drop inherits new-tab-position + cwd-inheritance), and
/// ``LinkActionPolicy/changeDirectoryCommandLine(_:)`` builds the `cd` line (a dropped FILE cd's to its
/// PARENT; a folder cd's directly). The line is sent VERBATIM as `Data(utf8)` through the new pane's session
/// handle — NEVER `SendKeysParser` (cd is verbatim UTF-8) — and is DEFERRED past the store's own 1400 ms
/// launch-grace inheritance `cd` so the dropped path is the LAST `cd` and wins the final cwd.
public extension WorkspaceStore {
    /// Opens a terminal rooted at `path` and points it there.
    ///
    /// - `split == false` → a new TAB (the New-Tab drop zone; reuses ``newTab(kind:)``).
    /// - `split == true` → splits the active pane along `axis` (`leading` = left/top — Split-Left/Up vs
    ///   Split-Right/Down; reuses ``splitActivePane(axis:kind:leading:)``). `axis` defaults to `.horizontal`
    ///   (the external-drop Split-Left/Right zones); the Open-Quickly folder "Split Right / Down" actions pass
    ///   `.vertical` for Split-Down.
    ///
    /// Then schedules a deferred `cd '<path>' 2>/dev/null || cd '<parent>'\n` into the freshly-minted pane.
    /// The dropped path is HOST-resolved (the destination terminal runs on the remote host, not this device —
    /// the receiver layers an advisory toast on top); the parent fallback matches a dropped FILE landing in
    /// its containing folder. A no-op
    /// when no new pane materializes (e.g. a split with no active pane). `launchGrace` is parameterized so a
    /// test injects `0` ms to observe the send without the 1.5 s wall-clock wait; production defers PAST the
    /// 1400 ms inheritance `cd` (`> deferInheritedCwd`'s grace) so the drop wins the final cwd.
    func openTerminalRooted(
        at path: String,
        split: Bool,
        leading: Bool,
        axis: SplitAxis = .horizontal,
        launchGrace: Duration = .milliseconds(1500),
    ) {
        if split {
            splitActivePane(axis: axis, kind: .terminal, leading: leading)
        } else {
            newTab(kind: .terminal)
        }
        guard let target = tree.activeSession?.activeTab?.activePane else { return }
        let bytes = Array(LinkActionPolicy.changeDirectoryCommandLine(path).utf8)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: launchGrace)
            self?.handle(for: target)?.sendBytes(bytes)
        }
    }
}

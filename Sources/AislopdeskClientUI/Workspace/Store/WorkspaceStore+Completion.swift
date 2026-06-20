import Foundation

// MARK: - Background-pane command-completion awareness (B3 — badge + focus-gated notify)

/// The B3 "a command finished while you were elsewhere" logic, factored out of ``WorkspaceStore`` so the
/// class body stays under the type-body-length ceiling (like the WB2/WB3 block ops in
/// `WorkspaceStore+Blocks.swift`). The stored state (`panePendingCompletion`, `isAppActive`,
/// `onLongCommandNotify`) lives on the class — `@Observable` synthesises on it; only the methods are here.
///
/// The badge (✓/✗) is set ONLY for an UNFOCUSED pane and cleared the instant it gains focus / the app
/// returns active. The long-command desktop notification is fired through the thin `onLongCommandNotify`
/// sink under the SAME focus gate (so a foreground long command does not spam) — `UNUserNotificationCenter`
/// never enters the store, keeping this whole path headless-testable.
public extension WorkspaceStore {
    /// The pending-completion badge for `id` (`nil` when none).
    func pendingCompletion(for id: PaneID) -> PaneCompletionBadge? {
        panePendingCompletion[id]
    }

    /// Sets the per-pane completion badge. Idempotent (a no-op when unchanged so it never churns the
    /// views); `nil` removes the key. Mirrors ``setAgentStatus(_:for:)``.
    func setCompletionBadge(_ badge: PaneCompletionBadge?, for id: PaneID) {
        guard panePendingCompletion[id] != badge else { return }
        if let badge { panePendingCompletion[id] = badge } else { panePendingCompletion.removeValue(forKey: id) }
    }

    /// The rolled-up completion badge over every leaf of session `sessionID` — `.failure` dominates
    /// `.success` (a failure is the more urgent thing to surface); `nil` when no leaf carries one. The
    /// sidebar session-row badge. Mirrors ``rollupStatus(forSession:)``.
    func rollupPendingCompletion(forSession sessionID: SessionID) -> PaneCompletionBadge? {
        guard let session = tree.sessions.first(where: { $0.id == sessionID }) else { return nil }
        return Self.rollupCompletion(session.allPaneIDs().map { panePendingCompletion[$0] })
    }

    /// The rolled-up completion badge over every leaf of tab `tabID` (the tab-pill badge). `.failure`
    /// dominates `.success`. Mirrors ``rollupStatus(forTab:)``.
    func rollupPendingCompletion(forTab tabID: TabID) -> PaneCompletionBadge? {
        for session in tree.sessions {
            if let tab = session.tabs.first(where: { $0.id == tabID }) {
                return Self.rollupCompletion(tab.allPaneIDs().map { panePendingCompletion[$0] })
            }
        }
        return nil
    }

    /// `.failure` if any leaf failed, else `.success` if any succeeded, else `nil`. Pure helper.
    internal static func rollupCompletion(_ badges: [PaneCompletionBadge?]) -> PaneCompletionBadge? {
        var sawSuccess = false
        for badge in badges {
            switch badge {
            case .failure: return .failure
            case .success: sawSuccess = true
            case nil: break
            }
        }
        return sawSuccess ? .success : nil
    }

    /// Folds a finished command (OSC 133;D `.idle`, wire type 23) for pane `id`: updates the
    /// background-completion badge (unfocused only) and fires the focus-gated long-command notification.
    /// The notify decision lives HERE (not in ``ConnectionViewModel``) so the focus gate applies — the
    /// store knows which leaf is active. `paneTitle` is the live pane title (notification content).
    func handleCommandCompleted(id: PaneID, exitCode: Int32?, durationMS: UInt32, paneTitle: String) {
        let focused = isPaneFocused(id)
        let threshold = CommandNotificationPolicy.longRunningThresholdMS
        let badge = BackgroundCompletionPolicy.badge(
            exitCode: exitCode, durationMS: durationMS, isPaneFocused: focused, longThresholdMS: threshold,
        )
        if let badge { setCompletionBadge(badge, for: id) }
        if BackgroundCompletionPolicy.shouldNotify(
            durationMS: durationMS,
            isPaneFocused: focused,
            enabled: SettingsKey.longCommandNotificationsEnabled,
            longThresholdMS: threshold,
        ) {
            onLongCommandNotify?(id.raw.uuidString, paneTitle, exitCode, durationMS)
        }
    }

    /// Whether `id` is the focused leaf RIGHT NOW: the app is active AND `id` is the active session's
    /// active tab's active pane. Cross-platform (reads `tree.activePane`, NOT the iOS focus coordinator).
    internal func isPaneFocused(_ id: PaneID) -> Bool {
        isAppActive && id == tree.activeSession?.activeTab?.activePane
    }

    /// Clears the badge on whatever leaf is the active one (called when the app returns active via the
    /// `isAppActive` didSet, and after a focus change in `reconcileTree`). A no-op when there is no active
    /// leaf or it carries no badge.
    internal func clearActiveLeafCompletionBadge() {
        guard isAppActive, let active = tree.activeSession?.activeTab?.activePane else { return }
        setCompletionBadge(nil, for: active)
    }
}

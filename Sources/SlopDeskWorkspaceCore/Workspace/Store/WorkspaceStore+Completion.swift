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
    /// views); `nil` removes the key. Mirrors ``setAgentStatus(_:for:)``. `at` is the completion instant
    /// (injectable for tests) used to stamp the badge-flash decay clock.
    func setCompletionBadge(_ badge: PaneCompletionBadge?, for id: PaneID, at date: Date = Date()) {
        guard panePendingCompletion[id] != badge else { return }
        if let badge { panePendingCompletion[id] = badge } else { panePendingCompletion.removeValue(forKey: id) }
        // The NEEDS-ATTENTION `since` fallback: a real badge edge (set, not clear) stamps the pane — a
        // `.failure` (→ `.error` entry) never stamps `paneCompletedAt`, so its menu-row age reads this.
        if badge != nil { paneAttentionAt[id] = date }
        // Stamp the ephemeral `completedAt` that drives the checkmark→accent-dot decay: a fresh
        // `.success` records the instant (brief `.completed` flash, settling to `.finished`). Only the
        // positive `.success` edge stamps; a `.failure` (→ `.error`) or a clear leaves any prior stamp
        // (harmless — the resolver reads it only in the completed/finished branch, and reconcile prunes
        // it), so it never clobbers a coexisting agent `.done` stamp. Arm the one-shot that decays the
        // flash to the `.finished` dot — without it the rail never re-renders past the flash window.
        if badge == .success {
            paneCompletedAt[id] = date
            armCompletionFlashDecay()
        }
    }

    /// Arms the one-shot that decays a just-stamped clean completion from the brief
    /// ``TabBadgeKind/completed`` checkmark to the persistent ``TabBadgeKind/finished`` dot. Called right
    /// after a POSITIVE completion edge (`.success` / agent ``ClaudeStatus/done``) stamps
    /// ``paneCompletedAt``; after ``completedFlashWindow`` it bumps ``completionFlashTick`` so the sidebar
    /// rail re-renders EXACTLY ONCE and recomputes ``completionFreshness(forPane:now:)`` — which, by then,
    /// reads the wall clock as past the window → ``TabBadgeResolver/CompletionFreshness/settled``. The
    /// tick is global (carries no pane id): by the time it fires, every still-fresh completion has settled,
    /// so one bump covers concurrent completions. `[weak self]` so a pending one-shot can't extend the
    /// store's lifetime past the window.
    internal func armCompletionFlashDecay() {
        flashDecayScheduler(Self.completedFlashWindow) { [weak self] in
            self?.completionFlashTick &+= 1
        }
    }

    /// The default ``flashDecayScheduler``: a real per-completion one-shot on the main run loop. A
    /// `@MainActor`-isolated `bump` is implicitly `Sendable`, so it hops onto the captured main-queue
    /// closure (which `assumeIsolated` runs back on the main actor). Lives in this extension (not the class
    /// body) so the closure literal stays off the `type_body_length` ledger.
    internal static let mainRunLoopFlashDecay: (TimeInterval, @escaping @MainActor () -> Void) -> Void
        = { delay, bump in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { bump() } }
        }

    /// Whether pane `id`'s clean completion (`.success` badge / agent `.done`) is still showing its brief
    /// ``TabBadgeKind/completed`` checkmark FLASH or has ``TabBadgeKind/finished`` SETTLED into the accent
    /// dot. The PURE freshness input ``TabBadgeResolver/badge(agent:completion:isBusy:foregroundProcess:completionFreshness:progress:)``
    /// switches on — computed HERE (the store owns the clock) by comparing the ephemeral
    /// ``WorkspaceStore/paneCompletedAt`` stamp against `now` (injectable for tests). No stamp ⇒
    /// ``TabBadgeResolver/CompletionFreshness/settled`` (show the persistent marker). Ordered compare —
    /// no bare `<` on a value that could be NaN (an interval here is finite, but keep the convention).
    func completionFreshness(
        forPane id: PaneID, now: Date = Date(),
    ) -> TabBadgeResolver.CompletionFreshness {
        guard let completedAt = paneCompletedAt[id] else { return .settled }
        let elapsed = now.timeIntervalSince(completedAt)
        return elapsed.isLess(than: Self.completedFlashWindow) ? .fresh : .settled
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
    /// background-completion badge (unfocused only), CLEARS any stuck OSC 9;4 progress (the `9;4;5`-equivalent),
    /// and fires the notification sink. The notify decision lives HERE (not in ``ConnectionViewModel``) so the
    /// store's focus/app-active state drives the pure ``NotificationPolicy`` — the per-command Notify on Error /
    /// Finish + Notify-While-Foreground gate (the PRIMARY authority, per-command + any duration), with the
    /// "Long-Command Completion" master as an ADDITIONAL path. `paneTitle` is the live pane title (notification
    /// content).
    func handleCommandCompleted(id: PaneID, exitCode: Int32?, durationMS: UInt32, paneTitle: String) {
        // The command is over — retire its busy-dot reveal clock (the dot itself already dropped with
        // the live busy bit; this just keeps the stamp map honest for the next start edge).
        paneCommandStartedAt.removeValue(forKey: id)
        let focused = isPaneFocused(id)
        let threshold = CommandNotificationPolicy.longRunningThresholdMS
        let badge = BackgroundCompletionPolicy.badge(
            exitCode: exitCode, durationMS: durationMS, isPaneFocused: focused, longThresholdMS: threshold,
        )
        if let badge { setCompletionBadge(badge, for: id) }
        // A finished command (OSC 133;D) clears any stuck OSC 9;4 badge on this pane — the documented
        // `9;4;5`-equivalent (a program that finished without an explicit `9;4;0`, or was killed mid-progress,
        // must not leave the rail showing a spinner over a completed command). Idempotent.
        handleProgress(nil, for: id)
        // The PER-COMMAND finish/error gate (E14/K9) is the PRIMARY authority. Route through the pure
        // ``NotificationPolicy`` — Notify on Error (non-zero exit) / Notify on Finish (clean exit) + the
        // Notify-While-Foreground tri-state — per-command, ANY exit code, ANY duration. This is DECOUPLED from
        // both the ~10s long-running floor AND slopdesk's own "Long-Command Completion" master: gating a short
        // failing `make` behind the long-running floor or the master toggle would silently drop it.
        let perCommand = NotificationPolicy.shouldDeliver(
            event: .commandFinish(exit: exitCode),
            appActive: isAppActive,
            sourcePaneFocused: focused,
            settings: SettingsKey.notificationSettings,
        )
        // slopdesk's own "Long-Command Completion" feature stays an ADDITIONAL/separate authority: a LONG
        // unfocused command still drives the completion cue (its master ON) even when the per-event toggles
        // are off. Either authority delivering fires the sink EXACTLY ONCE (no double-banner).
        let longCommand = BackgroundCompletionPolicy.shouldNotify(
            durationMS: durationMS,
            isPaneFocused: focused,
            enabled: SettingsKey.longCommandNotificationsEnabled,
            longThresholdMS: threshold,
        )
        if perCommand || longCommand {
            onLongCommandNotify?(id.raw.uuidString, paneTitle, exitCode, durationMS)
        }
    }

    /// Folds a command-START edge (OSC 133;C / `shellActivity`→`.running`, wire type 23 `.running`) for pane
    /// `id`: CLEARS any STALE completion badge so a new run resets the prior exit ✓/✗ before the spinner
    /// resolves. Without this, an unfocused pane that ran a failing command (→ red error triangle) and then
    /// starts a NEW command keeps showing the stale error triangle while the new command is actively running,
    /// instead of the running spinner (`progress-state.md` "current progress state"). Mirrors the focus/progress
    /// clear paths; idempotent (a no-op when there is no badge). Deliberately does NOT touch `paneProgress` — a
    /// fresh command re-emits its own OSC 9;4 if any.
    ///
    /// Also stamps ``WorkspaceStore/paneCommandStartedAt`` (the busy-dot reveal clock — the plain
    /// ``TabBadgeKind/commandBusy`` dot shows only once the command outlives the configured delay, so a
    /// fast `ls` never flashes the rail) and arms the one-shot that re-renders the rail at the
    /// reveal boundary — ``WorkspaceStore/paneShowsBusyDot(_:now:)`` reads the wall clock, not an
    /// `@Observable` dependency, so without the tick nothing would repaint the row when the delay elapses.
    /// `at` is injectable for deterministic tests.
    func handleCommandStarted(id: PaneID, at date: Date = Date()) {
        setCompletionBadge(nil, for: id)
        paneCommandStartedAt[id] = date
        flashDecayScheduler(SettingsKey.tabBadgeBusyDelaySecondsValue) { [weak self] in
            self?.completionFlashTick &+= 1
        }
    }

    /// Whether `id` is the focused leaf RIGHT NOW: `id` is the DETACHED pane whose satellite window is
    /// currently key (``keySatellitePaneID`` — checked FIRST since a detached pane is never a tab's
    /// active pane), else the app is active AND `id` is the active session's active tab's active pane.
    /// Cross-platform (reads `tree.activePane`, NOT the iOS focus coordinator).
    internal func isPaneFocused(_ id: PaneID) -> Bool {
        if let keySatellitePaneID, id == keySatellitePaneID { return true }
        return isAppActive && id == tree.activeSession?.activeTab?.activePane
    }

    /// Whether pane `id` is the focused leaf RIGHT NOW — the `sourcePaneFocused` input the macOS notifier's
    /// ``NotificationPolicy`` gate reads (E14/K9). A public wrapper over the B3 focus gate
    /// (``isPaneFocused(_:)``) so the app shell can supply the Notify-While-Foreground tri-state input
    /// without reaching into the store's internals.
    func isSourcePaneFocused(_ id: PaneID) -> Bool { isPaneFocused(id) }

    /// Whether the pane whose id string (`PaneID.raw.uuidString`) matches is the focused leaf — the
    /// `sourcePaneFocused` input for the notification sinks that carry only the pane-id STRING
    /// (``WorkspaceStore/onLongCommandNotify`` / ``WorkspaceStore/onAgentAttention``). `false` for an
    /// unparseable / unknown id (a closed pane).
    func isSourcePaneFocused(byIDString idString: String) -> Bool {
        guard let uuid = UUID(uuidString: idString) else { return false }
        return isPaneFocused(PaneID(raw: uuid))
    }

    /// Clears the badge on whatever leaf is the active one (called when the app returns active via the
    /// `isAppActive` didSet, and after a focus change in `reconcileTree`). A no-op when there is no active
    /// leaf or it carries no badge.
    internal func clearActiveLeafCompletionBadge() {
        guard isAppActive, let active = tree.activeSession?.activeTab?.activePane else { return }
        setCompletionBadge(nil, for: active)
    }
}

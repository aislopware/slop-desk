import Foundation

// MARK: - OSC 9;4 progress state (E14/K1 — per-pane tab-badge + Dock aggregate)

/// The E14 OSC 9;4 progress wiring in the store, factored out of ``WorkspaceStore`` so the class body stays
/// under the type-body-length ceiling (like `WorkspaceStore+Completion.swift`). The stored `paneProgress`
/// dict lives on the class (`@Observable` synthesises on it); only the methods are here.
///
/// The host parses the taskbar-style `OSC 9;4;<state>[;<pct>]` subtype out of the OSC-9 stream and forwards
/// each update on the CONTROL channel (wire type 32); the client validates the discriminant at its boundary
/// (``ProgressState/init(wire:)``) so only a known state reaches here as a ``PaneProgress``. This file is the
/// single per-pane store mirror the sidebar tab badge (via ``TabBadgeResolver`` → ``RailRowsBuilder``) and the
/// macOS Dock aggregate both read — headless, UN-free, no SwiftUI.
public extension WorkspaceStore {
    /// The current OSC 9;4 progress for pane `id` (`nil` when there is no active indicator).
    func progress(for id: PaneID) -> PaneProgress? {
        paneProgress[id]
    }

    /// Sets the per-pane OSC 9;4 progress mirror. Idempotent (a no-op when unchanged so it never churns the
    /// views); `nil` (a `9;4;0` clear) removes the key. Mirrors ``setCompletionBadge(_:for:)`` /
    /// ``setForegroundProcess(_:for:)``. On a genuine edge it bumps ``completionFlashTick`` — the E6 re-render
    /// seam the sidebar rail already observes — so the row recomputes its fused badge even when ONLY the
    /// progress changed (the badge reads `paneProgress` through the pure resolver, so the rail must repaint).
    func handleProgress(_ progress: PaneProgress?, for id: PaneID) {
        guard paneProgress[id] != progress else { return }
        if let progress { paneProgress[id] = progress } else { paneProgress.removeValue(forKey: id) }
        completionFlashTick &+= 1
    }

    /// The rolled-up OSC 9;4 progress over every leaf of session `sessionID` — the Dock aggregate source.
    /// **Error-dominant**: any leaf in `.error` makes the whole session read error (the most urgent thing to
    /// surface — the macOS Dock tile turns red on error); else any determinate value (the bar fills toward done, so the
    /// MAX percent across leaves); else any indeterminate spinner; else `nil`. Mirrors
    /// ``rollupPendingCompletion(forSession:)``.
    func rollupProgress(forSession sessionID: SessionID) -> PaneProgress? {
        guard let session = tree.sessions.first(where: { $0.id == sessionID }) else { return nil }
        return Self.aggregateProgress(session.allPaneIDs().map { paneProgress[$0] })
    }

    /// The rolled-up OSC 9;4 progress over every leaf of tab `tabID` (the tab-level aggregate). Error-dominant,
    /// same precedence as ``rollupProgress(forSession:)``. Mirrors ``rollupPendingCompletion(forTab:)``.
    func rollupProgress(forTab tabID: TabID) -> PaneProgress? {
        for session in tree.sessions {
            if let tab = session.tabs.first(where: { $0.id == tabID }) {
                return Self.aggregateProgress(tab.allPaneIDs().map { paneProgress[$0] })
            }
        }
        return nil
    }

    // MARK: - macOS Dock aggregate (E14/K5/K8 — process-global tile, every session)

    /// The cross-session OSC 9;4 progress rollup — the macOS Dock aggregate over EVERY live pane (not one
    /// session). Error-dominant with the same precedence as ``rollupProgress(forSession:)``: any `.error`
    /// leaf wins, else the MAX determinate percent, else any spinner, else `nil`. The Dock tile is
    /// process-global, so it rolls up the whole tree.
    func rollupProgressAcrossSessions() -> PaneProgress? {
        Self.aggregateProgress(paneProgress.values.map { $0 as PaneProgress? })
    }

    /// Whether ANY pane carries a `.failure` completion badge (a non-zero exit) — the OTHER half of the macOS
    /// Dock red-tint signal (the spec tints "when any session reports a non-zero exit OR OSC 9;4;2"); the
    /// `.error` PROGRESS half rides ``rollupProgressAcrossSessions()``.
    var anyFailureCompletion: Bool {
        panePendingCompletion.values.contains(.failure)
    }

    /// The resolved macOS Dock tile state (E14/K5/K8) — the SINGLE `@Observable`-derived value the macOS
    /// ``DockProgressController`` consumes. It reads ``paneProgress`` + ``panePendingCompletion`` (both
    /// `@Observable`), so a progress/completion EDGE re-renders the app shell, which re-applies the tile (and a
    /// last-session-end edge resolves to ``DockTileModel/inert`` → the controller CLEARS — the carryover "no
    /// stuck red tile" trap). The two macOS-only toggles are resolved fire-time (a toggle change applies on the
    /// next edge). The pure decision lives in ``DockTintPolicy/resolve(progressRollup:anyFailure:animateProgressEnabled:errorBadgeEnabled:)``.
    var dockTileModel: DockTileModel {
        DockTintPolicy.resolve(
            progressRollup: rollupProgressAcrossSessions(),
            anyFailure: anyFailureCompletion,
            animateProgressEnabled: SettingsKey.dockIconAnimateProgressEnabled,
            errorBadgeEnabled: SettingsKey.dockIconErrorBadgeEnabled,
        )
    }

    /// The K5/K8 Dock-click action: reveal the NEXT failing tab/pane — a pane in `.error` progress or carrying
    /// a `.failure` completion badge — cycling forward from the focused one, and ACKNOWLEDGE it (clear its
    /// error signals) so repeated clicks step through every failing tab and the red tint clears once the last
    /// is visited (clicking the Dock icon jumps to the next failing tab and clears the tint). A
    /// no-op when nothing is failing. Routes through the live-model focus path (tree vs canvas) like
    /// ``revealPane(byIDString:)``.
    func revealNextErrorPane() {
        let ordered = orderedErrorPaneIDs()
        guard !ordered.isEmpty else { return }
        let focused = tree.activeSession?.activeTab?.activePane
        let target: PaneID =
            if let focused, let idx = ordered.firstIndex(of: focused) {
                ordered[(idx + 1) % ordered.count] // cycle to the NEXT failing tab
            } else {
                ordered[0]
            }
        switch liveModel {
        case .tree: focusPaneTree(target)
        case .canvas: revealPane(target)
        }
        acknowledgeError(target)
    }

    /// Every leaf pane (in stable session → tab → pane order) currently signalling an error — a held `.error`
    /// progress state OR a `.failure` completion badge. The ordered domain ``revealNextErrorPane()`` cycles.
    private func orderedErrorPaneIDs() -> [PaneID] {
        var ordered: [PaneID] = []
        for session in tree.sessions {
            for tab in session.tabs {
                for id in tab.allPaneIDs() where isErrorPane(id) {
                    ordered.append(id)
                }
            }
        }
        return ordered
    }

    /// Whether pane `id` is in an error state for the Dock aggregate: a held `.error` progress OR a `.failure`
    /// completion badge (mirrors the ``anyFailureCompletion`` + error-rollup union the tint reads).
    private func isErrorPane(_ id: PaneID) -> Bool {
        if case .error = paneProgress[id] { return true }
        return panePendingCompletion[id] == .failure
    }

    /// Acknowledges (clears) pane `id`'s error signals so it drops out of the Dock aggregate — the "clicking
    /// clears the tint" half. Clears a held `.error` progress (via ``handleProgress(_:for:)``) and a `.failure`
    /// completion badge (via ``setCompletionBadge(_:for:)``); both bump the rail re-render seam, so the next
    /// ``dockTileModel`` read re-resolves the tile without the acknowledged pane.
    private func acknowledgeError(_ id: PaneID) {
        if case .error = paneProgress[id] { handleProgress(nil, for: id) }
        if panePendingCompletion[id] == .failure { setCompletionBadge(nil, for: id) }
    }

    /// Error-dominant aggregation over a set of per-leaf progress states (pure helper). Precedence:
    /// any `.error` → error (the first failing percent seen) > any `.determinate` → the MAX percent (closest
    /// to done) > any `.indeterminate` → spinner > `nil`. `Swift.max` on the integer percent is an ordered
    /// integer compare — no float math, no fused multiply (CLAUDE.md §2 is about float codec math; this is a
    /// `UInt8` aggregate).
    internal static func aggregateProgress(_ states: [PaneProgress?]) -> PaneProgress? {
        var errorPercent: UInt8?
        var determinatePercent: UInt8?
        var sawIndeterminate = false
        for state in states {
            switch state {
            case let .error(percent):
                if errorPercent == nil { errorPercent = percent } // first failing leaf wins the held percent
            case let .determinate(percent):
                determinatePercent = Swift.max(determinatePercent ?? 0, percent)
            case .indeterminate:
                sawIndeterminate = true
            case nil:
                break
            }
        }
        if let errorPercent { return .error(percent: errorPercent) }
        if let determinatePercent { return .determinate(percent: determinatePercent) }
        if sawIndeterminate { return .indeterminate }
        return nil
    }
}

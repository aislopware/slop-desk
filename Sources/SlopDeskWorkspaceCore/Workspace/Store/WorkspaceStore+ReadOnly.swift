import Foundation

// MARK: - WorkspaceStore × Read-only mode (E17 ES-E17-1 / WI-2)

/// The per-pane READ-ONLY ops, split into their own extension so the (already large) ``WorkspaceStore``
/// body stays under the lint ceiling. They mirror the WB2 active-pane ops
/// (``WorkspaceStore/requestCopyModeInActivePane()``): resolve the active pane's live ``TerminalViewModel``
/// (in whichever live model is active), flip its ``TerminalViewModel/isReadOnly`` input gate, AND record
/// the pane in the observable ``WorkspaceStore/paneReadOnly`` set — the SINGLE source of truth the
/// `🔒 READ ONLY ×` pill, the sidebar lock indicator, and ``isReadOnly(for:)`` all read.
///
/// CONVERGENCE. The model's ``TerminalViewModel/onReadOnlyChanged`` is wired (in
/// ``WorkspaceStore`` `wireMaterializedLeaf`) to update the SAME set, so a flip from ANY entry point — the
/// pill `×` (``setPaneReadOnly(_:_:)`` with `false`), the View-menu item / command-palette term
/// (``toggleReadOnlyInActivePane()``), or a programmatic model toggle — lands on one value. ``setPaneReadOnly``
/// ALSO writes the set DIRECTLY so the convergence holds even for a pane with no live terminal model wired
/// (a non-terminal `.remoteGUI` / `.systemDialog` pane, or a headless / test handle whose
/// `onReadOnlyChanged` the store never installed); the two writes are idempotent (the same value), so they
/// never fight, and the model mutators are guarded idempotent so the one level of re-entrancy through
/// `onReadOnlyChanged` terminates immediately.
public extension WorkspaceStore {
    /// The live ``TerminalViewModel`` for pane `id` (resolved through the ``TerminalModelProviding`` seam,
    /// the same one ``activeTerminalModel`` uses) — `nil` for a non-terminal pane (`.remoteGUI` /
    /// `.systemDialog`), a headless / fake handle, or an absent pane. Keyed by an explicit id (not the
    /// active pane) so the pill `×`, which carries its own ``PaneID``, can target exactly its pane.
    private func terminalModel(for id: PaneID) -> TerminalViewModel? {
        (handle(for: id) as? TerminalModelProviding)?.terminalModel
    }

    /// Whether pane `id` is currently READ-ONLY — the read the `🔒 READ ONLY ×` pill, the sidebar lock
    /// indicator, and the View-menu checkmark consult. Reads the convergent ``paneReadOnly`` set (the single
    /// source of truth), so it reflects a flip from ANY entry point regardless of whether a live model has
    /// echoed a value yet. `false` for any pane not in the set.
    func isReadOnly(for id: PaneID) -> Bool {
        paneReadOnly.contains(id)
    }

    /// Whether the ACTIVE pane is currently READ-ONLY — the read the command-palette "Read Only" ✓ gutter
    /// (``OverlayHostView/toggledState(for:store:)``) consults so the checkmark tracks the live input gate.
    /// Resolves the active pane id in whichever live model is active, then reads the convergent ``paneReadOnly``
    /// set (so it reflects a flip from ANY entry point). `false` for an empty shell (no active pane).
    func isActivePaneReadOnly() -> Bool {
        guard let id = activePaneID else { return false }
        return isReadOnly(for: id)
    }

    /// Whether the ACTIVE pane currently has SECURE keyboard entry engaged — the observable
    /// ``TerminalViewModel/secureInputActive`` mirror (the manual toggle OR the auto host-no-echo path). The
    /// command-palette "Secure Keyboard Entry" ✓ gutter reads this so the checkmark tracks the live state.
    /// `false` for a non-terminal active pane or an empty shell (no live terminal model).
    func isActivePaneSecureInputActive() -> Bool {
        activeTerminalModel?.secureInputActive ?? false
    }

    /// Sets pane `id`'s read-only state (the pill `×` → `false`, a programmatic set, or the toggle's
    /// resolved target). Drives the pane's live ``TerminalViewModel`` when present — its
    /// ``TerminalViewModel/isReadOnly`` `didSet` fires ``TerminalViewModel/onReadOnlyChanged`` → the wired
    /// closure mirrors into ``paneReadOnly`` — AND writes the set DIRECTLY so the convergence holds for a
    /// pane with no live model wired (the model path then writes the same value, idempotent). The model
    /// mutators (``TerminalViewModel/enterReadOnly()`` / ``exitReadOnly()``) are guarded idempotent, so the
    /// one level of re-entrancy through `onReadOnlyChanged` terminates without a loop.
    func setPaneReadOnly(_ id: PaneID, _ on: Bool) {
        if let model = terminalModel(for: id) {
            if on { model.enterReadOnly() } else { model.exitReadOnly() }
        }
        if on { paneReadOnly.insert(id) } else { paneReadOnly.remove(id) }
    }

    /// TOGGLES read-only over the ACTIVE pane (the `.toggleReadOnly` action / View-menu item / command-
    /// palette term). Resolves the active pane id in whichever live model is active (the tree's active pane
    /// on the IDE shell, the canvas focus on the retained-but-dead path); a graceful no-op for an empty
    /// shell (no active pane). The current state is read from the convergent ``paneReadOnly`` set so the
    /// toggle is correct even when no live model has echoed a value yet.
    func toggleReadOnlyInActivePane() {
        guard let id = activePaneID else { return }
        setPaneReadOnly(id, !paneReadOnly.contains(id))
    }

    /// TOGGLES the vi KEY-HINT BAR over the active pane (E17 ES-E17-2 / WI-5). The `⌘/` chord routes here ONLY
    /// while the active pane is in vi / copy-mode (``WorkspaceBindingRegistry`` `route` resolves the contextual
    /// branch — out of copy-mode, `⌘/` stays the global keyboard cheat sheet). Drives the MODEL as the single
    /// source of truth — ``TerminalViewModel/toggleViKeyHints()`` flips its observable
    /// ``TerminalViewModel/showViKeyHints`` (which the leaf's hint-bar gate reads) and fires
    /// `onRequestViKeyHints`. A graceful no-op for a non-terminal active pane or an empty shell (no live model).
    func toggleViKeyHintsInActivePane() {
        activeTerminalModel?.toggleViKeyHints()
    }

    /// TOGGLES MANUAL Secure Keyboard Entry over the ACTIVE pane (E17 ES-E17-4 / WI-7 — the
    /// `.secureKeyboardEntry` action / the Edit ▸ Secure Keyboard Entry menu item / the palette term). Flips the active
    /// terminal model's ``TerminalViewModel/manualSecureInput``, whose `didSet` refreshes the
    /// ``TerminalViewModel/secureInputActive`` pill mirror and fires `onManualSecureInputChanged` — the macOS
    /// leaf forwards that to the pane's ``SecureKeyboardEntryController`` to engage / disengage process-global
    /// secure event input. A graceful no-op for a non-terminal active pane or an empty shell (no live model).
    func toggleSecureKeyboardEntryInActivePane() {
        activeTerminalModel?.toggleSecureKeyboardEntry()
    }
}

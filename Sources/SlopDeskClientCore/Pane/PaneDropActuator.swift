// PaneDropActuator — what a committed external drop DOES, once the pure policy has decided which
// action it is.
//
// Split out of `PaneDropReceiver` when the client's presentation logic left the view target
// (docs/56). The receiver is framework-shaped — a SwiftUI `DropDelegate` on a Mac, an
// `NSDraggingDestination` under AppKit, a `UIDropInteractionDelegate` on a phone — but the four
// lines below it are not: they are the read-only halt, the focus-first ordering, and the four-way
// map from a resolved ``DropAction`` onto actuators that already exist (the verbatim PTY funnel, the
// store's terminal-rooted ingress, the host-open verb). It never carried a SwiftUI type even while
// it lived in the view target, which is exactly the "not a view, in a UI target by accident" shape
// docs/56 §3 names.
//
// Two of those lines are load-bearing and neither is obvious, so they are stated once here rather
// than re-derived per framework:
//
//   * READ-ONLY IS GATED TWICE. `PaneDropGate.acceptsDrag` suppresses the affordance so a read-only
//     pane never shows an overlay, and this actuator refuses again on commit. Belt-and-suspenders on
//     purpose: `injectText` → `sendInput` self-gates read-only (it rings and drops), but the
//     open-in-place `hostOpen` arm does NOT — it fires a host verb straight out of the pane's
//     callback — so a single defence upstream would leave one arm open.
//   * FOCUS COMES FIRST. `paneID` is the pane the cursor was dropped ONTO, and a drop never moves
//     focus by itself (a pane is focused on tap). The `splitInjectPath` arm goes through the
//     active-pane-reading ingress, so without focusing the dropped-on pane first a Split-Left/Right
//     or Open-In-Place drop onto a NON-focused sibling would split / replace the FOCUSED pane
//     instead — a split-brained actuation, since the inject and host-open arms already target the
//     dropped-on pane's own terminal model. `PaneDropActuatorTests` pins it on a two-pane tree.
//
// The `cd` itself is never built here: the canonical idiom lives in the store ingress
// (``LinkActionPolicy/changeDirectoryCommandLine(_:)``), so a drop and a ⌘-click cd the same way.

import Foundation // Data — the verbatim UTF-8 the inject arm hands the PTY funnel
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The commit half of the external-drop path: turn a resolved ``DropAction`` into concrete calls on
/// the store / the dropped-on pane's terminal / the overlay coordinator.
///
/// All `@MainActor` (every dependency is), and every member `static` so no framework's delegate has
/// to hold a non-`Sendable` `self` across the async classify that precedes the commit.
@MainActor
package enum PaneDropActuator {
    /// The WHOLE commit, from a read-off pasteboard bundle to the actuated action.
    ///
    /// The two shells' `performDrop` differ only in how they get a ``PaneDropProviderBundle`` out of
    /// their framework's drag session — after that line, the classify, the resolve and the actuate were
    /// character-identical on both, `Task { @MainActor }` and capture list included. So the bundle is
    /// the parameter and everything downstream of it is here.
    ///
    /// ⚠️ THE TERMINAL MODEL IS TAKEN, NOT RE-ASKED. It is read by the caller while the drop is still
    /// the current event; resolving it inside the task would read it one hop later, after a close or a
    /// pane swap could have moved it. The bundle carries its OWN authoritative copy of the payload for
    /// the same reason — see ``PaneDropProviderBundle``.
    @MainActor
    package static func commit(
        _ bundle: PaneDropProviderBundle,
        zone: DropZone,
        terminalModel: TerminalViewModel?,
        deps: PaneCanvasDeps,
        paneID: PaneID,
    ) {
        Task { @MainActor in
            guard let content = await bundle.classify(),
                  let action = DropActionResolver.resolve(zone: zone, content: content)
            else { return }
            actuate(
                action, store: deps.store, terminalModel: terminalModel,
                overlay: deps.overlay, paneID: paneID,
            )
        }
    }

    /// Carry out a resolved ``DropAction`` against the store / live terminal / overlay. The pure policy
    /// (``DropActionResolver``) decided WHAT; this turns it into the concrete call, reusing the existing
    /// actuators — no new engine — and layers the host-resolved advisory toast on the
    /// folder → New-Tab `cd`.
    ///
    /// - Parameters:
    ///   - action: the `(zone, content)` cell already resolved by ``DropActionResolver``.
    ///   - store: the workspace store the terminal-rooted arms drive.
    ///   - terminalModel: THIS (dropped-on) pane's live terminal model — `nil` for a chooser pane,
    ///     where read-only does not apply and the two terminal-only arms are simply no-ops.
    ///   - overlay: the coordinator the advisory toast is pushed into; `nil` outside the scene root
    ///     (tests / a static mirror), where it is a no-op.
    ///   - paneID: the pane the cursor was dropped onto — focused BEFORE anything is actuated.
    package static func actuate(
        _ action: DropAction,
        store: WorkspaceStore,
        terminalModel: TerminalViewModel?,
        overlay: OverlayCoordinator?,
        paneID: PaneID,
    ) {
        // READ-ONLY gate (parity with the paste halt): a read-only terminal pane is inert to drops — no
        // verbatim inject, no open-in-place host verb, no terminal-rooted tab/split. `terminalModel` is
        // nil for a chooser pane, where read-only doesn't apply, so those drops are unaffected.
        guard terminalModel?.isReadOnly != true else { return }
        store.focusPaneTree(paneID)
        switch action {
        case let .injectText(text):
            // VERBATIM UTF-8 into THIS focused pane's PTY (never `SendKeysParser`). `sendInput` self-gates
            // read-only (rings the beep + drops), so a read-only pane can't be written by a drop.
            terminalModel?.sendInput(Data(text.utf8))
        case let .newTabCd(folder):
            // A dropped folder opens a fresh terminal tab rooted there; the path is HOST-resolved, so advise.
            store.openTerminalRooted(at: folder, split: false, leading: false)
            overlay?.pushToast(cwdAdvisoryToast(for: folder))
        case let .splitInjectPath(path, leading):
            store.openTerminalRooted(at: path, split: true, leading: leading)
        case let .hostOpen(path):
            // Open-In-Place on the HOST — fire the SAME host-open verb (verb 9, `MetadataClient.openPath`)
            // the ⌘-click path uses; the pane's terminal leaf has already wired this callback (+ its
            // failure toast).
            terminalModel?.onRequestOpenHostPath?(path)
        }
    }

    /// The host-resolved advisory toast for a dropped folder → New-Tab `cd`: we are a REMOTE
    /// terminal, so the dropped path is resolved on the HOST and may not exist there — advise,
    /// never block. A fixed `id` de-dupes repeated drops to one toast (the warp `object_id` discipline).
    ///
    /// `package` rather than private so both drawing halves get the identical wording without either
    /// re-phrasing it: a copy string drifts silently, and this one names a REMOTE failure mode the
    /// user cannot otherwise see.
    package static func cwdAdvisoryToast(for path: String) -> Toast {
        Toast(
            id: "drop-cwd",
            flavor: .attention,
            title: "cd'd on host",
            body: "\(path) is resolved on the host; it may not exist there.",
            // No `paneKey`: the drop just FOCUSED the pane this advises about, so a jump door would land
            // where the user already is. Renders as a plain, non-interactive notice.
        )
    }
}

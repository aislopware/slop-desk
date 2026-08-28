// PaneDropReceiverView — the `UIDropInteraction` behind the external-drag overlay on a pane
// (docs/62 stage E.2; `docs/ui-shell/spec/user-interface__drag-and-drop.md`).
//
// The UIKit half of the deleted `PaneDropReceiver`. It owns the same four-step lifecycle, and every
// answer in it is still the floor's: the accept/decline gate and the hover verdict are
// ``PaneDropGate``, the item precedence is ``PaneDropProviderPolicy``, the loading loop is
// ``PaneDropProviderBundle``, the commit is ``PaneDropActuator``, the geometry is the shared
// ``PaneDropZoneLayout`` and the `(zone, content)` cell is ``DropActionResolver``. What is written here
// is the `UIDropSession`, which is precisely what docs/56 predicted would be left: "an
// `NSDraggingDestination` and a `UIDropInteractionDelegate` are the same five callbacks over a
// different event object".
//
// ⚠️ IT IS A CONTAINER, NOT AN OVERLAY — for a UIKit reason, not the AppKit one. AppKit had to wrap
// because it resolves a drag destination by walking UP the ancestor chain for a view registered for
// the pasteboard's types. UIKit hands the session to whichever view carries the `UIDropInteraction`,
// so no walk is involved — but an interaction only fires on a view with touches ENABLED, and a
// transparent interactive sheet over the pane would swallow every tap the terminal needs. Making the
// receiver the leaf's PARENT (``mount(_:)``) buys the drop without costing a touch: taps land on the
// content because it is a child, and the drop overlay above it is non-interactive. Same shape as the
// Mac, arrived at from the opposite direction.
//
// NO FLIP. `PaneDropZoneLayout` speaks pane-local, top-left origin, y down, and
// `session.location(in: self)` is already in that space — the AppKit half spends an `isFlipped`
// override to get there and says so; here there is nothing to say. draw == hit stays true across the
// receiver and the overlay for free.
//
// ⚠️ THE PROVIDERS ARE NOT COPIED OUT, AND THAT IS THE ONE PLACE THE TWO HALVES GENUINELY DIFFER.
// `MacPaneDropReceiver` must read its `NSDraggingInfo`'s pasteboard synchronously, because both are
// valid only for the length of the callback while the classify that reads them is `async`. A
// `UIDropSession`'s item providers are session-owned and outlive `performDrop` on purpose — loading
// them asynchronously from inside it is what the API is FOR — so the bundle below holds the providers
// directly and the commit's `Task` is safe without an eager copy.
//
// The `terminalModel` arrives as a CLOSURE rather than a value. The deleted SwiftUI receiver was a
// struct rebuilt on every `body` pass, so it always held the pane's current model; this view is built
// once and lives as long as the pane, across the moment a chooser pane goes live. A stored optional
// would have been captured at mount time and read `nil` forever after — the read-only halt and the
// verbatim inject would both have gone quiet.

#if os(iOS)
import Foundation
import SlopDeskClientCore // PaneDropGate / PaneDropProviderBundle / PaneDropActuator — every answer
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit
import UniformTypeIdentifiers

/// The pane's drop wrapper: the content, the drop overlay above it, and the five drop callbacks.
@MainActor
final class PaneDropReceiverView: UIView {
    /// THIS pane's id — the pane being dragged ONTO. On commit ``PaneDropActuator`` focuses it FIRST,
    /// so the active-pane-reading store ingress resolves to the dropped-on pane rather than whichever
    /// pane happened to be focused (a drop never moves focus on its own).
    private let paneID: PaneID
    /// The drag state the overlay renders from and these callbacks mutate.
    private let model: PaneDropOverlayModel
    /// The workspace store the terminal-rooted arms drive.
    private let store: WorkspaceStore
    /// THIS pane's live terminal model, read fresh on every use — see the header on why it is a
    /// closure. `nil` for a chooser pane, where read-only does not apply.
    private let terminalModel: () -> TerminalViewModel?
    /// The coordinator the host-resolved advisory toast is pushed into; `nil` outside the scene root.
    private let overlayCoordinator: OverlayCoordinator?

    private let dropOverlay: PaneDropOverlayView

    init(
        paneID: PaneID,
        model: PaneDropOverlayModel,
        store: WorkspaceStore,
        terminalModel: @escaping () -> TerminalViewModel?,
        overlayCoordinator: OverlayCoordinator?,
    ) {
        self.paneID = paneID
        self.model = model
        self.store = store
        self.terminalModel = terminalModel
        self.overlayCoordinator = overlayCoordinator
        dropOverlay = PaneDropOverlayView(model: model)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(dropOverlay)
        NSLayoutConstraint.activate([
            dropOverlay.topAnchor.constraint(equalTo: topAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            dropOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        addInteraction(UIDropInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Put the pane's content inside the receiver, UNDER the drop overlay. Edge-to-edge, so the
    /// receiver's bounds are the pane's rect exactly — which is what ``PaneDropOverlayView`` builds its
    /// layout from and what the hover below hit-tests against.
    func mount(_ content: UIView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(content, belowSubview: dropOverlay)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// The pane is closed for good — ends the overlay's tracking arm with it.
    func teardown() {
        dropOverlay.teardown()
    }

    /// The accepted types in UIKit's spelling, derived from the gate's one list rather than typed out
    /// again. ONE list, asked twice: ``canHandle`` and the hover both read it. Two lists is how a drag
    /// gets advertised as acceptable and then declined — an overlay that flickers once and never
    /// appears again.
    private static let acceptedIdentifiers = PaneDropGate.acceptedTypes.map(\.identifier)

    /// The hover verdict for wherever the finger is now, in ONE place so entry and update can never
    /// answer differently.
    private func hover(_ session: UIDropSession) -> DropZone? {
        let layout = PaneDropZoneLayout(size: bounds.size)
        let target = PaneDropGate.hoverZone(
            layout.zone(at: session.location(in: self)), allowedZones: model.allowedZones,
        )
        model.activeZone = target
        return target
    }
}

// MARK: - The five callbacks

extension PaneDropReceiverView: UIDropInteractionDelegate {
    /// Entry gate: accept the drag iff ``PaneDropGate/acceptsDrag(carriesSupportedType:isReadOnly:)``
    /// says so. UIKit's contribution is the ONE query the gate cannot make itself — whether the
    /// session carries one of the accepted types.
    func dropInteraction(_: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        PaneDropGate.acceptsDrag(
            carriesSupportedType: session.hasItemsConforming(toTypeIdentifiers: Self.acceptedIdentifiers),
            isReadOnly: terminalModel()?.isReadOnly,
        )
    }

    /// On entry, kick off the async classification the overlay's visibility is driven by.
    func dropInteraction(_: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        // Stamp this entry with a fresh generation the classify `Task` captures; a reset bumps it, so
        // a classify that resolves AFTER the reset is dropped as stale rather than re-activating the
        // overlay with no drag present (the strand-the-overlay race).
        let generation = model.beginClassification()
        let bundle = PaneDropProviderBundle(session: session)
        // `[model]` rather than an implicit `self`: the classify outlives this callback, and the drag
        // state is what it writes to — a `Task` holding the whole view for those milliseconds would
        // keep a pane's chrome alive past a close for no reason.
        Task { @MainActor [model] in
            model.applyClassified(await bundle.classify(), generation: generation)
        }
    }

    /// Every move: hit-test the finger against the SHARED layout and hand the hit to
    /// ``PaneDropGate/hoverZone(_:allowedZones:)``, which lights it only when the dragged content can
    /// act on it. `.forbidden` back is a gap or a disabled zone, and a release there never reaches
    /// `performDrop`.
    ///
    /// UIKit delivers this continuously while the session is inside the view, including when the
    /// finger stops dead — which is what closes the hole `MacPaneDropReceiver` needs
    /// `wantsPeriodicDraggingUpdates` for: the classification resolves a few milliseconds after entry,
    /// and until it does ``PaneDropOverlayModel/allowedZones`` is empty and every hover answers "none".
    func dropInteraction(
        _: UIDropInteraction, sessionDidUpdate session: UIDropSession,
    ) -> UIDropProposal {
        UIDropProposal(operation: hover(session) != nil ? .copy : .forbidden)
    }

    /// The finger left without dropping — clear the overlay.
    func dropInteraction(_: UIDropInteraction, sessionDidExit _: UIDropSession) {
        model.reset()
    }

    /// The session is over, however it ended. `reset()` is idempotent and the commit below already
    /// took everything it needs, so this is the belt to `sessionDidExit`'s braces: a cancel that
    /// skipped the exit callback would otherwise leave the overlay faded in over a pane with no drag
    /// on it.
    func dropInteraction(_: UIDropInteraction, sessionDidEnd _: UIDropSession) {
        model.reset()
    }

    /// Commit: resolve the `(active zone, content)` cell to a ``DropAction`` and actuate it. The
    /// overlay is cleared immediately and the payload is RE-loaded authoritatively rather than
    /// trusting the hover-time classification.
    func dropInteraction(_: UIDropInteraction, performDrop session: UIDropSession) {
        guard let zone = model.activeZone else {
            model.reset()
            return
        }
        let bundle = PaneDropProviderBundle(session: session)
        model.reset()
        // The terminal model is resolved NOW, while the drop is the current event — the same instant
        // the deleted half's struct was rebuilt with it. Everything else rides the capture list so the
        // commit never holds the view itself.
        let terminal = terminalModel()
        Task { @MainActor [store, overlayCoordinator, paneID] in
            guard let content = await bundle.classify(),
                  let action = DropActionResolver.resolve(zone: zone, content: content)
            else { return }
            PaneDropActuator.actuate(
                action, store: store, terminalModel: terminal,
                overlay: overlayCoordinator, paneID: paneID,
            )
        }
    }
}

// MARK: - The one part of this that is UIKit's

// THE ADAPTER IS THE WHOLE PLATFORM LAYER, and it is three lines. ``PaneDropProviderBundle`` — the
// load loop, the file → url → text precedence, the lazy text group and both `NSItemProvider`
// continuations — is `SlopDeskClientCore`'s, because an `NSItemProvider` is Foundation's object and
// not any framework's: a `DropInfo`, an `NSDraggingInfo` and a `UIDropSession` all reach the same one.
// What each framework genuinely owns is how you ASK it for the three groups, which is this.
private extension PaneDropProviderBundle {
    /// The three provider groups off a `UIDropSession`.
    ///
    /// The FILE group is the items conforming to `public.file-url`; the URL group is the wider
    /// `public.url`, which therefore ALSO sees a file drag's URL — and
    /// ``PaneDropProviderPolicy/webURLString(for:)`` is what discards it. That is the same
    /// double-exposure the deleted half's `.fileURL` / `.url` groups had, handled by the same policy;
    /// the precedence must not be re-decided here.
    init(session: UIDropSession) {
        self.init(
            fileProviders: session.slateProviders(conformingTo: .fileURL),
            urlProviders: session.slateProviders(conformingTo: .url),
            textProviders: session.slateProviders(conformingTo: .text),
        )
    }
}

private extension UIDropSession {
    /// The session's item providers that carry `type`. No copy-out and no load: a `UIDropSession`'s
    /// providers outlive the callback (see the file header), so the bundle can hold them and read them
    /// behind an `await`.
    func slateProviders(conformingTo type: UTType) -> [NSItemProvider] {
        items.map(\.itemProvider)
            .filter { $0.hasItemConformingToTypeIdentifier(type.identifier) }
    }
}
#endif

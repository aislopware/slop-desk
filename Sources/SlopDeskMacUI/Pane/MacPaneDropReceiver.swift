// MacPaneDropReceiver — the `NSDraggingDestination` behind the external-drag overlay on a pane
// (docs/56 wave R, batch R7; `docs/ui-shell/spec/user-interface__drag-and-drop.md`).
//
// The AppKit half of ``PaneDropReceiver``. It owns the same four-step lifecycle, and every answer in
// it is still the floor's: the accept/decline gate and the hover verdict are ``PaneDropGate``, the
// pasteboard precedence is ``PaneDropProviderPolicy``, the loading loop is ``PaneDropProviderBundle``,
// the commit is ``PaneDropActuator``, the geometry is the shared ``PaneDropZoneLayout`` and the
// `(zone, content)` cell is ``DropActionResolver``. What is written here is the `NSDraggingInfo`,
// which is precisely what docs/56 predicted would be left: "an `NSDraggingDestination` and a
// `UIDropInteractionDelegate` are the same five callbacks over a different event object".
//
// ⚠️ IT IS A CONTAINER, NOT AN OVERLAY, AND THAT IS FORCED BY APPKIT. SwiftUI can hang `.onDrop` on
// a view that hit-tests nothing; AppKit resolves a drag destination by hit-testing the window and
// then walking UP the ancestor chain for a view registered for one of the pasteboard's types. A
// transparent sheet over the pane would have to answer `hitTest` with itself to be found — and would
// then eat every click the terminal under it needs. So the receiver WRAPS the pane instead: the
// content goes inside it (``mount(_:)``), clicks reach the content because it is a child, and a drag
// over the content walks up one level and lands here. The drop OVERLAY it holds stays a decoration
// with `hitTest` → nil, exactly as ``MacPaneDropOverlay``'s header says.
//
// ⚠️ FLIPPED, for the same reason the overlay is: `PaneDropZoneLayout` speaks pane-local, top-left
// origin, y down. `convert(sender.draggingLocation, from: nil)` then lands in the coordinate space
// the layout hit-tests in with no second spelling of the flip, which is what keeps draw == hit true
// across the two views. Children are pinned by Auto Layout, which is flip-agnostic.
//
// ⚠️ THE PROVIDERS ARE COPIED OUT OF THE PASTEBOARD SYNCHRONOUSLY, and that is not incidental. An
// `NSDraggingInfo` and its pasteboard are only valid for the duration of the callback, while the
// classify that reads them is `async` and finishes after the callback returns. Reading the objects
// out on the spot and re-wrapping them as `NSItemProvider`s — the exact extraction
// ``PaneDropProviderBundle``'s header names for AppKit — is what makes the commit's `Task` safe to
// outlive the drag session. SwiftUI's `DropInfo.itemProviders` are system-owned and have no such
// window, so this is the one place the two halves genuinely do different work.
//
// The `terminalModel` arrives as a CLOSURE rather than a value. The SwiftUI receiver is a struct
// rebuilt on every `body` pass, so it always held the pane's current model; this view is built once
// and lives as long as the pane, across the moment a chooser pane goes live. A stored optional would
// have been captured at mount time and read `nil` forever after — the read-only halt and the
// verbatim inject would both have gone quiet.

import AppKit
import Foundation
import SlopDeskClientCore // PaneDropGate / PaneDropProviderBundle / PaneDropActuator — every answer
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UniformTypeIdentifiers

/// The pane's drop wrapper: the content, the drop overlay above it, and the five dragging callbacks.
@MainActor
final class MacPaneDropReceiver: NSView {
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

    private let dropOverlay: MacPaneDropOverlay

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
        dropOverlay = MacPaneDropOverlay(model: model)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(dropOverlay)
        NSLayoutConstraint.activate([
            dropOverlay.topAnchor.constraint(equalTo: topAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            dropOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // ONE list, asked twice: the registration and the validate query below both read
        // ``PaneDropGate/acceptedTypes``. Two lists is how a drag gets advertised as acceptable and
        // then declined — an overlay that flickers once and never appears again.
        registerForDraggedTypes(Self.draggedTypes)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// See the header: the zone layout's origin is top-left, and `draggingLocation` has to land in
    /// that space without a second flip being written anywhere.
    override var isFlipped: Bool { true }

    /// Put the pane's content inside the receiver, UNDER the drop overlay. Edge-to-edge, so the
    /// receiver's bounds are the pane's rect exactly — which is what ``MacPaneDropOverlay`` builds
    /// its layout from and what the hover below hit-tests against.
    func mount(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content, positioned: .below, relativeTo: dropOverlay)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// The accepted types in AppKit's spelling, derived from the gate's one list rather than typed
    /// out again.
    private static let draggedTypes: [NSPasteboard.PasteboardType] = PaneDropGate.acceptedTypes
        .map { NSPasteboard.PasteboardType($0.identifier) }

    // MARK: - The five callbacks

    /// Entry: accept the drag iff ``PaneDropGate/acceptsDrag(carriesSupportedType:isReadOnly:)`` says
    /// so, then kick off the async classification the overlay's visibility is driven by. AppKit's
    /// contribution is the ONE query the gate cannot make itself — whether the pasteboard carries one
    /// of the accepted types.
    ///
    /// Unlike the SwiftUI half these callbacks arrive already on the main actor (they are `NSView`
    /// overrides on a `@MainActor` class), so there is no `MainActor.assumeIsolated` hop anywhere in
    /// this file.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = PaneDropGate.acceptsDrag(
            carriesSupportedType: Self.carriesSupportedType(sender),
            isReadOnly: terminalModel()?.isReadOnly,
        )
        guard accepted else { return [] }
        // Stamp this entry with a fresh generation the classify `Task` captures; a reset bumps it, so
        // a classify that resolves AFTER the reset is dropped as stale rather than re-activating the
        // overlay with no drag present (the strand-the-overlay race).
        let generation = model.beginClassification()
        let bundle = PaneDropProviderBundle(dragging: sender)
        // `[model]` rather than an implicit `self`: the classify outlives this callback, and the drag
        // state is what it writes to — a `Task` holding the whole view for those milliseconds would
        // keep a pane's chrome alive past a close for no reason.
        Task { @MainActor [model] in
            await model.applyClassified(bundle.classify(), generation: generation)
        }
        return hover(sender)
    }

    /// Every move: hit-test the cursor against the SHARED layout and hand the hit to
    /// ``PaneDropGate/hoverZone(_:allowedZones:)``, which lights it only when the dragged content can
    /// act on it. `[]` back is the FORBIDDEN proposal — a gap, or a disabled zone — so a release
    /// there never reaches ``performDragOperation(_:)``.
    ///
    /// ⚠️ `wantsPeriodicDraggingUpdates` is left at its default `true` ON PURPOSE. The classification
    /// resolves a few milliseconds after entry, and until it does ``PaneDropOverlayModel/allowedZones``
    /// is empty and every hover answers "none". Without the periodic tick a drag that entered the
    /// pane and then stopped dead would sit over a lit overlay with no zone armed, and a release would
    /// commit nothing. SwiftUI's `dropUpdated` is delivered continuously and closes the same hole.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hover(sender)
    }

    /// The cursor left without dropping — clear the overlay.
    override func draggingExited(_: NSDraggingInfo?) {
        model.reset()
    }

    /// The session is over, however it ended. `reset()` is idempotent and the commit below already
    /// took everything it needs, so this is the belt to `draggingExited`'s braces: a cancel that
    /// skipped the exit callback would otherwise leave the overlay faded in over a pane with no drag
    /// on it.
    override func draggingEnded(_: NSDraggingInfo) {
        model.reset()
    }

    /// Commit: resolve the `(active zone, content)` cell to a ``DropAction`` and actuate it. The
    /// overlay is cleared immediately and the payload is RE-loaded authoritatively rather than
    /// trusting the hover-time classification.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let zone = model.activeZone else {
            model.reset()
            return false
        }
        // Read the pasteboard NOW — see the header. After this line nothing touches `sender`.
        let bundle = PaneDropProviderBundle(dragging: sender)
        model.reset()
        // The terminal model is resolved NOW, while the drop is the current event — the same instant
        // the SwiftUI half's struct was rebuilt with it. Everything else rides the capture list so
        // the commit never holds the view itself.
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
        return true
    }

    // MARK: - The two queries AppKit owns

    /// The hover verdict for wherever the cursor is now, in ONE place so entry and update can never
    /// answer differently.
    private func hover(_ sender: NSDraggingInfo) -> NSDragOperation {
        // `draggingLocation` is in the destination window's base space; `from: nil` is the conversion
        // into this view's — which is flipped, so the result is already the layout's coordinates.
        let point = convert(sender.draggingLocation, from: nil)
        let layout = PaneDropZoneLayout(size: bounds.size)
        let target = PaneDropGate.hoverZone(layout.zone(at: point), allowedZones: model.allowedZones)
        model.activeZone = target
        return target != nil ? .copy : []
    }

    /// Whether the drag carries one of ``PaneDropGate/acceptedTypes`` — AppKit's answer to the same
    /// question SwiftUI's `hasItemsConforming(to:)` answers.
    private static func carriesSupportedType(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadItem(
            withDataConformingToTypes: PaneDropGate.acceptedTypes.map(\.identifier),
        )
    }
}

// MARK: - The one part of this that is AppKit's

// THE ADAPTER IS THE WHOLE PLATFORM LAYER, and it is three lines. ``PaneDropProviderBundle`` — the
// load loop, the file → url → text precedence, the lazy text group and both `NSItemProvider`
// continuations — is `SlopDeskClientCore`'s, because an `NSItemProvider` is Foundation's object and
// not any framework's: a `DropInfo`, an `NSDraggingInfo` and a `UIDropSession` all reach the same
// one. What each framework genuinely owns is how you ASK it for the three groups, which is this.
private extension PaneDropProviderBundle {
    /// The three provider groups off an `NSDraggingInfo`.
    ///
    /// The FILE group is read with `.urlReadingFileURLsOnly`, so a web URL cannot arrive there; the
    /// URL group is read without it and therefore also sees a Finder drag's file URL, which
    /// ``PaneDropProviderPolicy/webURLString(for:)`` discards. That is the same double-exposure the
    /// SwiftUI half's `.fileURL` / `.url` groups have, and it is handled by the same policy — the
    /// precedence must not be re-decided here.
    init(dragging info: NSDraggingInfo) {
        let pasteboard = info.draggingPasteboard
        self.init(
            fileProviders: pasteboard.slateURLProviders(filesOnly: true),
            urlProviders: pasteboard.slateURLProviders(filesOnly: false),
            textProviders: pasteboard.slateTextProviders(),
        )
    }
}

// The Objective-C classes are the API's, not a preference: `readObjects(forClasses:options:)` takes
// `NSPasteboardReading` conformers and `NSItemProvider(object:)` takes an `NSItemProviderWriting`
// one, and neither value type conforms. Swift bridges what comes BACK to `URL` / `String`, which is
// why each read goes out through the value type and back through the class.
// swiftlint:disable legacy_objc_type
private extension NSPasteboard {
    /// The URL group, as `NSItemProvider`s. `filesOnly` is the FILE group's read; without it the same
    /// call is the URL group's, which also sees a Finder drag's file URL —
    /// ``PaneDropProviderPolicy/webURLString(for:)`` is what discards it, and that precedence is not
    /// re-decided here.
    ///
    /// `readObjects` is what makes the copy EAGER: the values leave the pasteboard inside the
    /// dragging callback rather than behind an `await` that resolves after the session is gone. An
    /// object that does not bridge is dropped rather than faulted on — validate-then-drop means a
    /// hostile or merely mistyped drag is the normal case, never a crash.
    func slateURLProviders(filesOnly: Bool) -> [NSItemProvider] {
        let options: [NSPasteboard.ReadingOptionKey: Any] =
            filesOnly ? [.urlReadingFileURLsOnly: true] : [:]
        let objects = readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            (object as? URL).map { NSItemProvider(object: $0 as NSURL) }
        }
    }

    /// The text group. Loaded last and only when the other two produced nothing — that decision is
    /// ``PaneDropProviderPolicy/needsTextLoad(files:urls:)``'s and lives inside `classify()`; this
    /// only hands over the providers.
    func slateTextProviders() -> [NSItemProvider] {
        let objects = readObjects(forClasses: [NSString.self], options: [:]) ?? []
        return objects.compactMap { object in
            (object as? String).map { NSItemProvider(object: $0 as NSString) }
        }
    }
}

// swiftlint:enable legacy_objc_type

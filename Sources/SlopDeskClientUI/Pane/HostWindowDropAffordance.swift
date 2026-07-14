// HostWindowDropAffordance — drag a HOST WINDOW ROW off the right rail and drop it onto the
// workspace. The Stage re-scope collapsed the old zone grammar (split / dock / new-tab): the split
// tree is terminal-only now, so a release ANYWHERE over the canvas commits the rail click's one verb —
// open the window in the STAGE (idempotent by windowID; an already-staged window just activates its
// tab). The hover preview is a whole-canvas wash + a cursor chip naming the window and the verb.
//
// Unlike the pane-move drag (a SwiftUI `DragGesture` confined to one hosting view's coordinate
// space), the rail and the canvas live in DIFFERENT NSSplitView columns / hosting views — so this
// rides AppKit drag-and-drop: the row vends an `NSItemProvider` typed ``HostWindowDragPayload/utType``
// and `SplitContainer` attaches a ``HostWindowDropReceiver``. NSItemProvider payloads are UNREADABLE
// during hover (macOS only exposes them on drop, asynchronously), so the row ALSO parks the payload
// in ``HostWindowDragSession`` — an in-process side channel the hover chip + the commit read
// synchronously. Trusting it is sound: only rail rows vend that UTType, and every drag re-parks the
// payload before it can hover. Commit-on-`performDrop` only; exactly ONE store op (the remote-app rule).

#if os(macOS)
import AppKit
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Payload + in-process side channel

/// What a rail-row drag carries — exactly ``WorkspaceStore/openWindowInStage(windowID:title:appName:)``'s
/// inputs plus the `bundleID` for the chip icon. In-app DnD only (never the wire — Codable is fine here).
struct HostWindowDragPayload: Codable, Equatable {
    let windowID: UInt32
    let title: String
    let appName: String
    let bundleID: String

    /// The pasteboard type rail drags travel as. Other apps don't know it, so a drag released over
    /// Finder / a terminal drops nothing — the payload is only meaningful inside SlopDesk.
    static let utType = UTType(exportedAs: "com.slopdesk.host-window")

    /// The label the chip + the opened pane lead with (the rail row's own precedence).
    var displayName: String { title.isEmpty ? appName : title }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

/// The in-process drag side channel: set by the row's drag source the instant a drag starts, read by
/// the overlay chip (hover-time — pasteboard data is sealed until drop) and the drop commit. A
/// cancelled drag leaves the payload parked; that is harmless — it is only ever read while a
/// ``HostWindowDragPayload/utType`` drag hovers the canvas, and every such drag re-parks first.
/// `isDragging` gates the drop catcher's hit-testability: TRUE only between `beginDraggingSession`
/// and the session's end callback, so at rest the catcher is invisible to every event.
@MainActor
final class HostWindowDragSession {
    static let shared = HostWindowDragSession()
    var payload: HostWindowDragPayload?
    var isDragging = false
}

// MARK: - Row drag source (AppKit — SwiftUI `.onDrag` never lifts here)

/// The rail row's DRAG SOURCE. NOT SwiftUI `.onDrag`: the row shell's tap gesture claims the
/// mouse-down before SwiftUI's drag interaction reaches its threshold, so `.onDrag` on (or around)
/// a `SlateListRow` never starts a session. This overlay owns the decision at the EVENT level
/// instead: left mouse-down enters a tracking loop — ≥4pt of
/// movement begins an `NSDraggingSession` (in-app only, `sourceOperationMaskFor` returns `[]`
/// outside the app); mouse-up first IS the row's click verb (`onAct`, ⌘ = duplicate). Right-clicks
/// and scroll are not intercepted (no overrides — they walk the responder chain to the SwiftUI
/// `.contextMenu` / scroll view beneath); hover + tooltip ride tracking areas, which ignore hitTest.
struct HostWindowRowDragSource: NSViewRepresentable {
    let payload: HostWindowDragPayload
    let onAct: (_ duplicate: Bool) -> Void
    /// Hover in/out — the overlay swallows the events SwiftUI `.onHover` rides, so it senses hover
    /// itself (tracking areas ignore hitTest) and the row styles off this instead.
    let onHover: (Bool) -> Void
    /// COMPACT-rail identity card (``HostWindowHoverCardPresenter``): non-nil arms the hover dwell,
    /// with this view as the card's anchor (the overlay IS the row's frame). The wide rail passes
    /// `nil` — its rows carry the title inline and keep the system `.help` tooltip instead.
    var hoverCardModel: (@MainActor () -> HostWindowHoverCardModel)?

    func makeNSView(context _: Context) -> DragView {
        let view = DragView()
        view.payload = payload
        view.onAct = onAct
        view.onHover = onHover
        view.hoverCardModel = hoverCardModel
        return view
    }

    func updateNSView(_ view: DragView, context _: Context) {
        view.payload = payload
        view.onAct = onAct
        view.onHover = onHover
        view.hoverCardModel = hoverCardModel
    }

    final class DragView: NSView, NSDraggingSource {
        var payload: HostWindowDragPayload?
        var onAct: ((_ duplicate: Bool) -> Void)?
        var onHover: ((Bool) -> Void)?
        var hoverCardModel: (@MainActor () -> HostWindowHoverCardModel)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil,
            ))
        }

        override func mouseEntered(with _: NSEvent) {
            onHover?(true)
            if let hoverCardModel {
                HostWindowHoverCardPresenter.shared.schedule(anchor: self, model: hoverCardModel)
            }
        }

        override func mouseExited(with _: NSEvent) {
            onHover?(false)
            HostWindowHoverCardPresenter.shared.dismiss(anchor: self)
        }

        /// A row torn down mid-hover (scroll recycle / feed removal / window close) never fires
        /// `mouseExited` — drop its pending/visible card on the way out.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { HostWindowHoverCardPresenter.shared.dismiss(anchor: self) }
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // The click IS the answer the card was previewing — clear it (and its dwell) now.
            HostWindowHoverCardPresenter.shared.dismiss(anchor: self)
            let start = event.locationInWindow
            // Standard AppKit click-vs-drag disambiguation loop (the divider idiom): consume
            // drag/up events until the 4pt threshold or release.
            while true {
                guard let next = window.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: .distantFuture, inMode: .eventTracking, dequeue: true,
                ) else { continue }
                if next.type == .leftMouseUp {
                    onAct?(next.modifierFlags.contains(.command) || event.modifierFlags.contains(.command))
                    return
                }
                let dx = next.locationInWindow.x - start.x
                let dy = next.locationInWindow.y - start.y
                if dx * dx + dy * dy >= 16 {
                    beginDrag(with: event)
                    return
                }
            }
        }

        private func beginDrag(with event: NSEvent) {
            guard let payload else { return }
            // The pointer conceptually leaves the row (the drag image takes over) — settle the
            // hover styling; a session end over the row re-enters via the tracking area.
            onHover?(false)
            // Park the side channel FIRST — the canvas overlay chip + the drop commit read it
            // synchronously (the pasteboard is sealed until drop), and `isDragging` arms the
            // drop catcher's hit-test window.
            HostWindowDragSession.shared.payload = payload
            HostWindowDragSession.shared.isDragging = true

            let item = NSPasteboardItem()
            item.setData(
                payload.encoded(),
                forType: NSPasteboard.PasteboardType(HostWindowDragPayload.utType.identifier),
            )
            let dragItem = NSDraggingItem(pasteboardWriter: item)
            let chip = ImageRenderer(content: HostWindowDragChip(payload: payload))
            chip.scale = window?.backingScaleFactor ?? 2
            let image = chip.nsImage ?? NSImage(size: NSSize(width: 1, height: 1))
            let origin = convert(event.locationInWindow, from: nil)
            dragItem.setDraggingFrame(
                NSRect(
                    x: origin.x - image.size.width / 2, y: origin.y - image.size.height / 2,
                    width: image.size.width, height: image.size.height,
                ),
                contents: image,
            )
            beginDraggingSession(with: [dragItem], event: event, source: self)
        }

        // MARK: NSDraggingSource

        func draggingSession(
            _: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext,
        ) -> NSDragOperation {
            // In-app only: a rail window means nothing to Finder / other apps.
            context == .withinApplication ? .copy : []
        }

        func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
            // Disarm the catcher whether the drop landed or the drag was cancelled.
            HostWindowDragSession.shared.isDragging = false
        }
    }
}

/// The drag-image chip — the row distilled to icon + name (rendered once at drag begin via
/// `ImageRenderer`; the icon resolves through the rail's own ladder).
struct HostWindowDragChip: View {
    let payload: HostWindowDragPayload

    var body: some View {
        HStack(spacing: 6) {
            if let icon = HostAppIconCache.shared.icon(forBundleID: payload.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemSymbol: .macwindow)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.icon)
            }
            Text(payload.displayName)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Slate.Surface.face)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
                ),
        )
    }
}

// MARK: - Zone + view-local drop state

/// View-local drop state (held by `SplitContainer`): the cursor location plus whether the dragged
/// window is ALREADY staged — the one bit the chip copy needs ("open" vs "show").
struct HostWindowDropDrag: Equatable {
    var location: CGPoint
    var alreadyStaged: Bool
}

// MARK: - Drop catcher (AppKit — SwiftUI `.onDrop` never engages for this drag)

/// The rail-drag DROP DESTINATION `SplitContainer` mounts over the whole canvas. NOT SwiftUI
/// `.onDrop`: SwiftUI's AppKit dragging-destination view registers only `public.data`/`public.item`
/// and AppKit matches `registeredDraggedTypes` by EXACT STRING, so a custom-typed pasteboard never
/// reaches the hosting view — and even advertised as `public.data` the internal routing never calls
/// `validateDrop`. This NSView registers for the custom type itself and implements
/// `NSDraggingDestination` directly — the destination mirror of the AppKit source.
///
/// Hit-testing: AppKit resolves the drag target via `hitTest` from the front, so this view sits
/// TOPMOST over the canvas but returns `nil` from `hitTest` UNLESS a rail drag is in flight
/// (``HostWindowDragSession/isDragging``) — at rest every click/scroll passes through to the panes.
/// `isFlipped` so converted drag locations are top-left-origin == the solver's leaf-rect space.
struct HostWindowDropCatcher: NSViewRepresentable {
    /// `false` on the static-mirror (ImageRenderer) path — never registers there.
    let enabled: Bool
    let onUpdate: (CGPoint) -> Void
    let onExit: () -> Void
    let onPerform: (CGPoint) -> Bool

    func makeNSView(context _: Context) -> CatcherView {
        let view = CatcherView()
        if enabled {
            view.registerForDraggedTypes(
                [NSPasteboard.PasteboardType(HostWindowDragPayload.utType.identifier)],
            )
        }
        view.onUpdate = onUpdate
        view.onExit = onExit
        view.onPerform = onPerform
        return view
    }

    func updateNSView(_ view: CatcherView, context _: Context) {
        view.onUpdate = onUpdate
        view.onExit = onExit
        view.onPerform = onPerform
    }

    final class CatcherView: NSView {
        var onUpdate: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?
        var onPerform: ((CGPoint) -> Bool)?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            HostWindowDragSession.shared.isDragging ? super.hitTest(point) : nil
        }

        private func location(_ sender: NSDraggingInfo) -> CGPoint {
            convert(sender.draggingLocation, from: nil)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onUpdate?(location(sender))
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            onUpdate?(location(sender))
            // Every point resolves to a zone (`.newTab` fallback) — a release anywhere acts.
            return .copy
        }

        override func draggingExited(_: NSDraggingInfo?) {
            onExit?()
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onPerform?(location(sender)) ?? false
        }
    }
}

// MARK: - Overlay

/// The drag overlay drawn ABOVE every pane while a rail drag hovers the canvas: the whole-canvas
/// wash (every point is the same landing — the Stage) plus a ghost chip pinned to the cursor naming
/// the window + the verb. Purely visual (`allowsHitTesting(false)` at the call site).
struct HostWindowDropOverlay: View {
    let drag: HostWindowDropDrag
    /// The whole compositor bound — the wash spans it.
    let container: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            PaneMoveOverlay.washPreview(container)
            chip
                .position(x: drag.location.x, y: drag.location.y)
        }
    }

    /// The cursor chip: the window's app icon (the rail row's resolution ladder) + "name — verb".
    private var chip: some View {
        let payload = HostWindowDragSession.shared.payload
        let inert = false
        return HStack(spacing: 6) {
            if let bundleID = payload?.bundleID,
               let icon = HostAppIconCache.shared.icon(forBundleID: bundleID)
            {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemSymbol: .macwindow)
                    .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
            }
            Text(Self.stageLabel(
                name: payload?.displayName ?? "window",
                alreadyStaged: drag.alreadyStaged,
            ))
            .font(.system(size: Slate.Typeface.base, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 240)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(inert ? Slate.Text.tertiary : Slate.Text.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Slate.Surface.face)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            inert ? Slate.Text.tertiary.opacity(0.4) : Slate.State.accent,
                            lineWidth: 1,
                        ),
                ),
        )
        .shadow(color: Slate.State.shadow, radius: 8, y: 2)
    }

    /// The chip copy — the ONE verb a release commits, led by the window's name: "open in Stage"
    /// for a fresh window, "show in Stage" for one already staged (the release activates its tab).
    static func stageLabel(name: String, alreadyStaged: Bool) -> String {
        alreadyStaged ? "\(name) — show in Stage" : "\(name) — open in Stage"
    }
}
#endif

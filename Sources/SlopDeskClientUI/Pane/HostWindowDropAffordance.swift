// HostWindowDropAffordance — drag a HOST WINDOW ROW off the right rail and drop it INTO the split
// canvas (docs/45 round 3, user request 2026-07-12). While the drag hovers the workspace, the SAME
// zone language as the pane-move affordance previews where the window will land:
//   • an EDGE band of a pane        → SPLIT: the window opens as a new column/row beside that pane;
//   • the container's outer gutter  → DOCK: a full-span column/row on that whole edge;
//   • anywhere else (a pane's centre, a divider gap) → NEW TAB (the rail click's verb).
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

/// What a rail-row drag carries — exactly ``WorkspaceStore/newRemoteWindowTab(windowID:title:appName:)``'s
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

/// The in-process drag side channel: set by the row's `onDrag` the instant a drag starts, read by the
/// overlay chip (hover-time — providers are sealed until drop) and the drop commit. A cancelled drag
/// leaves the payload parked; that is harmless — it is only ever read while a ``HostWindowDragPayload/utType``
/// drag hovers the canvas, and every such drag re-parks first.
@MainActor
final class HostWindowDragSession {
    static let shared = HostWindowDragSession()
    var payload: HostWindowDragPayload?
}

// MARK: - Zone + view-local drop state

/// The action a release at the cursor would commit — the insert-drag mirror of ``PaneDropZone``.
/// No `.swap` and no `.none`: there is no source pane to exchange, and every point of the canvas is
/// a valid landing (`.newTab` is the fallback verb, exactly what clicking the row does).
enum HostWindowDropZone: Equatable {
    case newTab
    /// Drop on an `edge` band of `target` → the window opens as a new column/row beside it.
    case resplit(target: PaneID, edge: PaneDropEdge)
    /// Drop in the container's outer gutter → a full-span column/row on that whole `edge`.
    case dock(edge: PaneDropEdge)
}

/// View-local drop state (held by `SplitContainer`): the cursor location + the resolved zone.
struct HostWindowDropDrag: Equatable {
    var location: CGPoint
    var zone: HostWindowDropZone
}

// MARK: - Drop delegate

/// The `DropDelegate` `SplitContainer` attaches for rail-window drags. `DropDelegate` is NOT a
/// `@MainActor` protocol, so this struct is nonisolated and reaches the container's `@MainActor`
/// state through `MainActor.assumeIsolated` (every callback is delivered on the main thread — the
/// ``PaneDropReceiver`` idiom). Locations are in the modified view's space == the solver's leaf-rect
/// space (`SplitContainer` attaches it to the compositor that owns those rects).
struct HostWindowDropReceiver: DropDelegate {
    /// `false` on the static-mirror (ImageRenderer) path — decline every drag there.
    let enabled: Bool
    let onUpdate: @MainActor (CGPoint) -> Void
    let onExit: @MainActor () -> Void
    let onPerform: @MainActor (CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [HostWindowDragPayload.utType])
    }

    func dropEntered(info: DropInfo) {
        let onUpdate = onUpdate
        let location = info.location
        MainActor.assumeIsolated { onUpdate(location) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let onUpdate = onUpdate
        let location = info.location
        MainActor.assumeIsolated { onUpdate(location) }
        // Every point resolves to a zone (`.newTab` fallback) — a release anywhere in the canvas acts.
        return DropProposal(operation: .copy)
    }

    func dropExited(info _: DropInfo) {
        let onExit = onExit
        MainActor.assumeIsolated { onExit() }
    }

    func performDrop(info: DropInfo) -> Bool {
        let onPerform = onPerform
        let location = info.location
        return MainActor.assumeIsolated { onPerform(location) }
    }
}

// MARK: - Overlay

/// The drag overlay drawn ABOVE every pane while a rail drag hovers the canvas: the zone-specific
/// landing preview (the pane-move visual language — slab+seam / dock rail / whole-canvas wash for
/// NEW TAB) plus a ghost chip pinned to the cursor naming the window + the verb. Purely visual
/// (`allowsHitTesting(false)` at the call site).
struct HostWindowDropOverlay: View {
    let drag: HostWindowDropDrag
    /// The ACTIVE tab's leaf rects (solver space), keyed by pane.
    let frames: [PaneID: CGRect]
    /// The whole compositor bound — the DOCK rail + NEW-TAB wash span it.
    let container: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            zonePreview
            chip
                .position(x: drag.location.x, y: drag.location.y)
        }
    }

    /// Distinct identity per zone so a zone change CROSS-FADES (the ``PaneMoveOverlay`` treatment)
    /// rather than morphing a slab's frame across the canvas.
    private var zoneKey: String {
        switch drag.zone {
        case .newTab: "newtab"
        case let .resplit(target, edge): "resplit-\(target)-\(edge.rawValue)"
        case let .dock(edge): "dock-\(edge.rawValue)"
        }
    }

    private var zonePreview: some View {
        zoneShape
            .id(zoneKey)
            .transition(.opacity)
    }

    @ViewBuilder
    private var zoneShape: some View {
        switch drag.zone {
        case .newTab:
            PaneMoveOverlay.washPreview(container)
        case let .resplit(target, edge):
            if let rect = frames[target] { PaneMoveOverlay.slabPreview(in: rect, edge: edge) }
        case let .dock(edge):
            PaneMoveOverlay.railPreview(in: container, edge: edge)
        }
    }

    /// The cursor chip: the window's app icon (the rail row's resolution ladder) + "name — verb".
    private var chip: some View {
        let payload = HostWindowDragSession.shared.payload
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
            Text(Self.zoneLabel(drag.zone, name: payload?.displayName ?? "window"))
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Slate.Text.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Slate.Surface.face)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Slate.State.accent, lineWidth: 1),
                ),
        )
        .shadow(color: Slate.State.shadow, radius: 8, y: 2)
    }

    /// The chip copy — the verb the release would commit, led by the window's name.
    static func zoneLabel(_ zone: HostWindowDropZone, name: String) -> String {
        switch zone {
        case .newTab: "\(name) — new tab"
        case let .resplit(_, edge): "\(name) — split \(edge.rawValue)"
        case let .dock(edge): "\(name) — dock \(edge.rawValue)"
        }
    }
}
#endif

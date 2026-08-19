// PaneDragChrome — the two DRAWINGS the cross-container pane drag needs, and nothing else.
//
// ``PaneDragCoordinator`` itself is in `SlopDeskClientCore` now: registering a rect provider,
// resolving a destination, arming a spring-load and steering a scroller are decisions and actuations,
// and three of its readers live in three different targets (docs/56 §3 — a UI target holds views
// only). What could not go down with it is what is in this file, and each half is blocked on a
// different thing.
//
// ``DropTargetFrameReader`` is an `NSViewRepresentable`, and it is ALSO the piece increment 41
// recorded as the reason this whole block could not simply ascend into `SlopDeskMacUI`: it reads the
// COMPOSITOR's rect, which differs from the hosting view's frame by the island moat, and by a
// differently-animating amount during a collapse. Until the canvas is AppKit or the moat leaves
// SwiftUI, the rect a drop target registers can only be read from inside the SwiftUI tree.
//
// ``PaneDragChipPanel`` is a borderless `NSPanel` carrying an `NSHostingView`, so it is a drawing by
// construction. It reaches the coordinator as a ``PaneDragChipSink`` — the coordinator decides WHEN
// the chip shows and WHAT it says (through the one ``PaneDropRegister``), and this half only puts
// that on screen. A platform with one window and no cursor leaves the sink nil rather than
// implementing an empty panel.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceModel
import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)

// MARK: - Screen-frame reader (drop-target registration)

/// Registers the decorated view's SCREEN frame with the drag coordinator under `key` — resolved lazily
/// through a weak `NSView` handle, so scrolling / layout never publishes anything. Mount it in a
/// `.background` (the view is hit-test transparent). The `.canvas` key doubles as the main-window
/// frame source (the tear-off boundary).
struct DropTargetFrameReader: NSViewRepresentable {
    let key: PaneDropTargetKey
    let coordinator: PaneDragCoordinator

    final class Coordinator {
        var registeredKey: PaneDropTargetKey?
        weak var drag: PaneDragCoordinator?
    }

    /// An `NSView` that never claims a hit — the reader must not shadow the SwiftUI content it backs.
    final class PassthroughView: NSView {
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        register(view, context: context)
        return view
    }

    func updateNSView(_ view: PassthroughView, context: Context) {
        // A reused row view can be re-keyed (LazyVStack recycling) — move the registration.
        guard context.coordinator.registeredKey != key else { return }
        if let old = context.coordinator.registeredKey { coordinator.unregister(old) }
        register(view, context: context)
    }

    static func dismantleNSView(_: PassthroughView, coordinator: Coordinator) {
        if let key = coordinator.registeredKey { coordinator.drag?.unregister(key) }
    }

    private func register(_ view: PassthroughView, context: Context) {
        context.coordinator.registeredKey = key
        context.coordinator.drag = coordinator
        coordinator.register(key) { [weak view] in
            guard let view, let window = view.window else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        if key == .canvas {
            coordinator.mainWindowFrame = { [weak view] in view?.window?.frame }
        }
    }
}

// MARK: - Cursor-following chip panel

/// A tiny borderless, non-activating, mouse-transparent panel that carries the drag's ghost chip once
/// the cursor leaves the content column (whose SwiftUI overlay clips at the hosting-view edge). Pure
/// AppKit positioning — `setFrameOrigin` per frame, the SwiftUI root swapped only on a destination
/// transition (the coordinator passes the label/mark it already resolved).
@MainActor
package final class PaneDragChipPanel: PaneDragChipSink {
    package init() {}

    private var panel: NSPanel?
    private var hosting: NSHostingView<PaneDragChipView>?
    private var lastContent: PaneDragChipView?

    /// Show/move the chip for this frame. Hidden over the canvas — the in-canvas overlay is the
    /// affordance there and a floating twin would double it.
    package func showChip(
        at screenPoint: CGPoint, drag: PaneDragCoordinator.Drag, label: String,
        mark: PaneDropRegister.Mark,
    ) {
        if case .canvas = drag.destination {
            hideChip()
            return
        }
        let content = PaneDragChipView(
            symbol: mark.symbol, label: label, cancels: drag.destination == .none,
        )
        let panel = ensurePanel()
        if lastContent != content {
            lastContent = content
            hosting?.rootView = content
            if let size = hosting?.fittingSize { panel.setContentSize(size) }
        }
        // The chip trails above-right of the pointer (screen coords are bottom-left origin).
        panel.setFrameOrigin(NSPoint(x: screenPoint.x + 14, y: screenPoint.y + 14))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    package func hideChip() {
        panel?.orderOut(nil)
        lastContent = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true,
        )
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false // the chip capsule draws its own
        created.ignoresMouseEvents = true
        created.level = .popUpMenu // above the workspace + satellites while the drag is live
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PaneDragChipView(symbol: .xmark, label: "", cancels: true))
        created.contentView = host
        hosting = host
        panel = created
        return created
    }
}

/// The floating chip's content — the same capsule voice as `PaneMoveOverlay`'s ghost chip (one drop
/// vocabulary across the canvas overlay and the cross-window panel).
struct PaneDragChipView: View, Equatable {
    let symbol: SFSymbol
    let label: String
    let cancels: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
            Text(label)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(cancels ? Slate.Text.tertiary : Slate.Text.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Slate.Surface.face)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            cancels ? Slate.Text.tertiary.opacity(0.4) : Slate.State.accent,
                            lineWidth: 1,
                        ),
                ),
        )
        .slateShadow(.ghost)
        .fixedSize()
        .padding(6) // keep the shadow inside the borderless panel's bounds
    }
}
#endif
#endif

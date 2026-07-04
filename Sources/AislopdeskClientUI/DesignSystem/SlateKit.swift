// SlateKit — small reusable chrome controls built on the polished `Slate` token layer (SlateDesign.swift).
// Two pieces:
//   • `PlateIconButton` — the hover-plate icon button: a borderless SF-Symbol button that grows a faint
//     rounded hover plate, 0.12s small-fade. Used by the titlebar chrome.
//   • `TitlebarHoverCatcher`: ONE tracking area over the whole titlebar strip
//     whose `hitTest` returns nil (so clicks/drag fall through to the window) but still reports hover by
//     geometry. Drives the titlebar chrome reveal without stealing the window-drag region.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A hover-plate icon button — a borderless SF-Symbol with a faint rounded hover plate (radius 6).
struct PlateIconButton: View {
    let symbol: SFSymbol
    var size: CGFloat = Slate.Metric.iconSize
    var plate: CGFloat = Slate.Metric.plate
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemSymbol: symbol)
                .font(.system(size: size))
                .foregroundStyle(Slate.Text.icon)
                .frame(width: plate, height: plate)
                .background(hovering ? Slate.State.hover : .clear, in: .rect(cornerRadius: Slate.Metric.radiusControl))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
    }
}

#if os(macOS)
/// A click-through NSView that reports hover over the whole titlebar strip by
/// geometry (its `hitTest` returns nil so window drag + clicks fall through to the views/window behind it).
struct TitlebarHoverCatcher: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = HoverNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? HoverNSView)?.onHover = onHover
    }

    final class HoverNSView: NSView {
        var onHover: ((Bool) -> Void)?

        override func hitTest(_: NSPoint) -> NSView? { nil } // click-through (window drag + buttons behind)

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
            ))
        }

        override func mouseEntered(with _: NSEvent) { onHover?(true) }
        override func mouseExited(with _: NSEvent) { onHover?(false) }
    }
}
#endif
#endif

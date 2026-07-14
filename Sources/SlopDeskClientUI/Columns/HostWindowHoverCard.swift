// HostWindowHoverCard — the COMPACT rail's identity layer. At 56pt the rows are icon-only, so the
// full identity (app · title · dimensions · staged tab) moves to a hover card floating BESIDE the
// rail — the fixed-narrow-rail + hover-card pattern (Discord's rail tooltips, Chrome/Safari tab
// hover cards): the rail itself never reflows, and width stays a sticky choice, never a hover
// transient.
//
// The card rides a NON-ACTIVATING borderless NSPanel attached as a CHILD window of the workspace
// window — never an NSPopover (a popover can take key status, which would steal keystrokes from the
// terminal the instant a dwell fires under a resting pointer). The panel ignores mouse events
// entirely: it is a label, not a target — pointer travel toward it exits the row and hides it.

#if os(macOS)
import AppKit
import SlopDeskWorkspaceCore
import SwiftUI

/// What the card says — resolved at dwell-fire (live-read from the feed at that moment; the card is
/// transient, so it never needs observation plumbing).
struct HostWindowHoverCardModel {
    let appName: String
    /// The window title (may be empty / equal to the app name — the card then skips the line).
    let title: String
    /// The instrument detail line (dimensions · display · visibility) — the wide row's tooltip content.
    let detail: String
    /// The staged tab's ordinal while the window is streaming, or `nil`.
    let streamedOrdinal: String?
}

/// Presents ONE card at a time. Dwell 0.45s before showing — the hover-card convention band
/// (libraries settle on ~0.7s; a glance utility earns a bit faster, and near-zero is the
/// accidental-trigger regime that made the auto-hiding Windows taskbar infamous). Hide is
/// IMMEDIATE on exit: the card sits outside the pointer's travel path and is never itself a target.
@MainActor
final class HostWindowHoverCardPresenter {
    static let shared = HostWindowHoverCardPresenter()

    static let dwell: TimeInterval = 0.45
    static let cardWidth: CGFloat = 260
    /// Gap between the row's leading edge and the card's trailing edge.
    private static let gap: CGFloat = 8

    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private weak var anchor: NSView?

    /// Arm the dwell for `anchor`'s row. The model closure runs at FIRE time so the card shows the
    /// feed's truth of that moment, not of hover-entry.
    func schedule(anchor: NSView, model: @escaping @MainActor () -> HostWindowHoverCardModel) {
        pending?.cancel()
        hide()
        self.anchor = anchor
        let work = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor, anchor.window != nil else { return }
            present(model(), beside: anchor)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: work)
    }

    /// Kill the dwell and the card. With an `anchor`, acts only if that row still owns the card —
    /// a stale exit (row A) can never tear down the card row B just scheduled.
    func dismiss(anchor: NSView? = nil) {
        if let anchor, anchor !== self.anchor { return }
        pending?.cancel()
        pending = nil
        hide()
    }

    private func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        anchor = nil
    }

    private func present(_ model: HostWindowHoverCardModel, beside anchor: NSView) {
        hide()
        guard let window = anchor.window else { return }
        let hosting = NSHostingView(rootView: HostWindowHoverCardView(model: model))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true,
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        // Child windows do NOT inherit the parent's pinned appearance — match it explicitly so the
        // card's theme tokens resolve against the same aqua/darkAqua the workspace is pinned to.
        panel.appearance = window.appearance
        panel.contentView = hosting
        // To the LEFT of the row, vertically centred on it, clamped to the visible screen.
        let rowOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var origin = NSPoint(
            x: rowOnScreen.minX - size.width - Self.gap,
            y: rowOnScreen.midY - size.height / 2,
        )
        if let visible = window.screen?.visibleFrame {
            origin.x = CGFloat.maximum(visible.minX, CGFloat.minimum(origin.x, visible.maxX - size.width))
            origin.y = CGFloat.maximum(visible.minY, CGFloat.minimum(origin.y, visible.maxY - size.height))
        }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
    }
}

/// The card body: app name in the instrument caps register, the full (untruncated up to 3 lines)
/// title in prose, then the instrument detail + staged lines. Identity inline, context in the card —
/// nothing critical lives ONLY here (the click verb and context menu never depend on it).
private struct HostWindowHoverCardView: View {
    let model: HostWindowHoverCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(model.appName.uppercased())
                .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                .tracking(Slate.Typeface.instrumentTracking)
                .foregroundStyle(Slate.State.header)
            if !model.title.isEmpty, model.title != model.appName {
                Text(model.title)
                    .font(.system(size: Slate.Typeface.body))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(3)
            }
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.secondary)
            }
            if let ordinal = model.streamedOrdinal {
                Text("STAGE · TAB \(ordinal)")
                    .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                    .tracking(Slate.Typeface.instrumentTracking)
                    .foregroundStyle(Slate.State.accent)
            }
        }
        .padding(Slate.Metric.space3)
        .frame(width: HostWindowHoverCardPresenter.cardWidth, alignment: .leading)
        .background(Slate.Surface.face, in: .rect(cornerRadius: Slate.Metric.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                .strokeBorder(Slate.Line.card, lineWidth: Slate.Metric.cardBorderWidth),
        )
    }
}
#endif

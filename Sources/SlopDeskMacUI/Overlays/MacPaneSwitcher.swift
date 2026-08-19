// MacPaneSwitcher — the ⌃⇥ switcher's face, as a WINDOW of its own.
//
// The third surface off the shared SwiftUI floor and the LAST ambient one (docs/56 stage D): with the
// toasts and this readout in their own panels, `OverlayHostView` holds nothing that is always mounted,
// so on the Mac it is a modal presenter and nothing else.
//
// It is a READOUT, not a control. The keyboard dispatcher owns the whole gesture — open, step, commit,
// cancel — and this has no buttons, no gestures and no state; its entire lifetime is the length of a
// held ⌃, often under 200ms. Three consequences, and the panel gets all three for free where the
// SwiftUI overlay had to arrange each one:
//
//   1. IT IGNORES THE MOUSE ENTIRELY (`ignoresMouseEvents`), so a click during the gesture reaches the
//      workspace beneath. The SwiftUI half spelled this `.allowsHitTesting(false)` and had to, because
//      the hosting view it lived in would otherwise have claimed every hit in the window.
//   2. IT NEVER TAKES THE KEYBOARD. Stealing focus mid-gesture would break the `flagsChanged` release
//      that COMMITS the switch — which is also why this was never a `.sheet`.
//   3. IT COSTS NOTHING AT REST. No window exists until the gesture opens one.
//
// A row is TWO REGISTERS stacked: the pane's identity, and under it the PLACE that identity lives in —
// its project, then the sub-path it strayed into. Beside them the ⌘-number in a KEYCAP, because that
// number is a key the reader can press right now and a bare glyph did not say so. Nothing here is
// coloured: the highlight is a lifted plate and a heavier title, the house rule that a readout marks
// importance with LIGHT and WEIGHT rather than hue (DECISIONS §git-line-two-registers).
//
// WHAT IT DOES NOT OWN is the content or the card's measurements: ``PaneSwitcherRowsBuilder`` builds
// the rows and ``PaneSwitcherMetrics`` sizes the card against the window, both in `SlopDeskClientCore`,
// exactly as they did when the view above them was SwiftUI. The phone never opens this gesture at all
// (there is no ⌃⇥ without a hardware modifier stream), so unlike the cheat sheet and the toasts this
// surface has ONE half rather than two — the SwiftUI original was deleted rather than kept as a view
// that could never render.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

// MARK: - The panel

/// The window the readout is drawn in: borderless, transparent, never key, and blind to the mouse.
final class MacPaneSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - The card

/// The switcher's card: the session's panes in most-recently-used order, the provisional highlight
/// marked, scrolling when there are more of them than the window is tall.
@MainActor
final class MacPaneSwitcherCardView: MacOverlayCardView {
    private let column = NSStackView()
    private let scroll = NSScrollView()
    /// The row views in ring order, so a step can move the plate and scroll to it without a rebuild.
    private var rows: [MacPaneSwitcherRowView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space3, left: Slate.Metric.space3,
            bottom: Slate.Metric.space3, right: Slate.Metric.space3,
        )
        column.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = column
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Pinned to the CLIP view's width, so the rows lay out at the card's width and the scroll
            // is vertical only — a document view free in both axes scrolls sideways instead.
            column.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Draws `model`, and answers the size the card wants — the width `PaneSwitcherMetrics` measured
    /// against the window, and the rows' own height up to the ceiling past which they scroll.
    func show(_ model: [PaneSwitcherRow], container: NSSize) -> NSSize {
        // The ring is FROZEN for the gesture's lifetime, so a re-show is a step: same rows, a moved
        // plate. Rebuilding them there would drop the scroll position the highlight is tracked in.
        if rows.count == model.count {
            for (row, value) in zip(rows, model) { row.show(value) }
        } else {
            for row in rows { column.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rows = model.map { value in
                let row = MacPaneSwitcherRowView()
                row.show(value)
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -Slate.Metric.space3 * 2)
                    .isActive = true
                return row
            }
        }
        let width = PaneSwitcherMetrics.width(container: container.width)
        column.layoutSubtreeIfNeeded()
        let ceiling = PaneSwitcherMetrics.maxHeight(container: container.height)
        // The card is only as tall as its rows until it hits that ceiling — a scroll view left to its
        // own devices would claim the whole allowance for four rows.
        let height = Swift.min(column.fittingSize.height, ceiling)
        revealHighlight(in: model)
        return NSSize(width: width, height: height)
    }

    /// Keeps the marked row on screen as ⇥ walks past the fold.
    private func revealHighlight(in model: [PaneSwitcherRow]) {
        guard let index = model.firstIndex(where: \.isHighlighted), rows.indices.contains(index) else {
            return
        }
        let row = rows[index]
        column.layoutSubtreeIfNeeded()
        row.scrollToVisible(row.bounds)
    }
}

// MARK: - One row

/// One candidate: what the pane is, where it lives, and the ⌘-key that reaches it directly.
@MainActor
final class MacPaneSwitcherRowView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let place = NSTextField(labelWithString: "")
    private var cap: MacKeycapView?
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusCard
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.cardBorderWidth

        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.isSelectable = false
        // Truncate the place from the HEAD: a deep path's LAST components are the ones that say where
        // the pane actually is.
        place.lineBreakMode = .byTruncatingHead
        place.maximumNumberOfLines = 1
        place.isSelectable = false
        for label in [title, place] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let text = NSStackView(views: [title, place])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Slate.Metric.space3
        stack.addArrangedSubview(text)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightRowStacked),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The PLACE line, built as one attributed run so its two halves flow and truncate together: the
    /// project a shade heavier, then the sub-path under it in the plain weight. WEIGHT rather than ink,
    /// because both halves are equally quiet next to the identity — what differs is which of them the
    /// eye should catch running down a column of rows.
    ///
    /// A pane with no project (a video pane, a shell whose cwd has not landed) shows its note alone
    /// rather than an empty lead-in; a pane with neither shows no second line at all.
    private static func placeText(_ row: PaneSwitcherRow) -> NSAttributedString? {
        let size = Slate.Typeface.footnote
        let ink = Slate.Native.Overlay.tertiary
        guard let project = row.project else {
            return row.note.map { .slateNerdAware($0, font: .systemFont(ofSize: size), color: ink) }
        }
        let head = NSAttributedString.slateNerdAware(
            project, font: .systemFont(ofSize: size, weight: .medium), color: ink,
        )
        guard let note = row.note else { return head }
        let spliced = NSMutableAttributedString(attributedString: head)
        spliced.append(.slateNerdAware(" › \(note)", font: .systemFont(ofSize: size), color: ink))
        return spliced
    }

    func show(_ row: PaneSwitcherRow) {
        title.attributedStringValue = .slateNerdAware(
            row.title,
            font: .systemFont(ofSize: Slate.Typeface.body, weight: row.isHighlighted ? .medium : .regular),
            color: row.isHighlighted ? Slate.Native.Overlay.primary : Slate.Native.Overlay.secondary,
        )
        if let place = Self.placeText(row) {
            self.place.attributedStringValue = place
            self.place.isHidden = false
        } else {
            place.isHidden = true
        }
        // Absent past ⌘9, where the chord does not exist (the app binds ⌘1–9 only) — an unpressable key
        // drawn on a row is a lie.
        if row.number <= PaneSwitcherRowsBuilder.highestShortcut {
            let label = "⌘\(row.number)"
            if let cap { cap.relabel(label, lit: row.isHighlighted) } else {
                let view = MacKeycapView(label: label)
                view.relabel(label, lit: row.isHighlighted)
                stack.addArrangedSubview(view)
                cap = view
            }
        } else {
            cap?.removeFromSuperview()
            cap = nil
        }
        highlighted = row.isHighlighted
        needsDisplay = true
    }

    /// Whether this row carries the provisional plate. Unselected costs NOTHING — no fill, no border,
    /// no reserved inset — so a list at rest is just text.
    private var highlighted = false

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = highlighted ? Slate.Native.Overlay.plate.cgColor : nil
            layer?.borderColor = highlighted ? Slate.Native.Overlay.hairline.cgColor : nil
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - The controller

/// The switcher's window: opened by the first step of a gesture, re-drawn by each one after it, and
/// torn down when the gesture commits or cancels.
@MainActor
final class MacPaneSwitcherController {
    private let panel: MacPaneSwitcherPanel
    private let card = MacPaneSwitcherCardView(frame: .zero)
    private weak var host: NSWindow?

    init(host: NSWindow) {
        self.host = host
        panel = MacPaneSwitcherPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false,
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The CARD casts the shadow, not the window.
        panel.hasShadow = false
        // ⚠️ THE READOUT IS BLIND TO THE MOUSE. The gesture lives entirely on the keyboard, and
        // swallowing a click here would strand a user who reached for the workspace behind it.
        panel.ignoresMouseEvents = true
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = card
    }

    /// Draws `rows` and orders the card in, centred on the workspace window.
    func show(_ rows: [PaneSwitcherRow]) {
        guard let host, !rows.isEmpty else {
            dismiss()
            return
        }
        let size = card.show(rows, container: host.frame.size)
        panel.setFrame(
            NSRect(
                x: host.frame.midX - size.width / 2,
                y: host.frame.midY - size.height / 2,
                width: Swift.max(size.width, 1),
                height: Swift.max(size.height, 1),
            ),
            display: true,
        )
        if panel.parent == nil { host.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    /// Orders the card out. Idempotent — the gesture can end in three ways and all of them land here.
    func dismiss() {
        host?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

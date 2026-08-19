// MacCheatSheetView — the ⌘/ keyboard reference sheet, in AppKit.
//
// The first macOS surface to leave the shared SwiftUI floor (docs/56 stage D), and it goes first
// because it is the whole overlay path with nothing else attached: summon, read, Esc or click away,
// and the keyboard comes back. It has no text field, no focus to manage and no state — its rows are
// the registry's own table — so what it proves is the PANEL, not the card.
//
// WHAT IT DOES NOT OWN is the content. The rows, the glyph gating and the column deal are
// ``CheatSheetContent`` in `SlopDeskClientCore`, over `slopdesk_cheat_sheet_columns` — so the phone's
// SwiftUI card and this one are the same table asked twice, and the layout is the only thing that
// differs. That is docs/56's rule at the scale of one surface: layout diverges, capability does not.
//
// TWO COLUMNS, packed as columns rather than as a grid. The table is long enough that one column
// turns a reference sheet into a scroll, and a reader looking up a chord wants to SEE the set. The
// balance is by rendered HEIGHT, which is what keeps a short category from floating halfway down the
// card beside a long one — see the rule's own note in `rust/slopdesk-workspace/src/cheat_sheet.rs`.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

/// The cheat sheet's card content. A view rather than a builder namespace, because AppKit's
/// target/action wants an object to send the Done button's click to and the card is the natural one.
@MainActor
final class MacCheatSheetView: NSView {
    /// The card's size. Wide enough for two columns of chord rows, tall enough that the four
    /// categories nearly fit without scrolling — the scroll is for a small screen, not for the
    /// resting case.
    static let cardSize = NSSize(width: 640, height: 560)

    /// How many columns the table is dealt into.
    private static let columnCount = 2

    private let onDone: () -> Void

    /// Builds the card. Esc and click-away are the panel's (``MacOverlayPanelController``); this only
    /// has to offer the visible verb.
    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize))

        let title = titleRow()
        let scroll = tableScrollView()
        for view in [title, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(equalTo: trailingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    @objc
    private func doneClicked() { onDone() }

    // MARK: - The title line

    /// The card's own title: a real title — the system face at `title`/semibold in the reading ink —
    /// with the Done button trailing it and no rule under it (the card has an edge already).
    private func titleRow() -> NSView {
        let title = Self.label(
            CheatSheetContent.title,
            font: .systemFont(ofSize: Slate.Typeface.title, weight: .semibold),
            color: Slate.Native.Overlay.primary,
        )
        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded

        let spacer = NSView()
        let row = NSStackView(views: [title, spacer, done])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space2
        row.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space4, left: Slate.Metric.space4,
            bottom: Slate.Metric.space3, right: Slate.Metric.space4,
        )
        // The spacer takes the slack, so the title stays left and Done stays right at any card width.
        title.setContentHuggingPriority(.required, for: .horizontal)
        done.setContentHuggingPriority(.required, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    // MARK: - The table

    private func tableScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let table = Self.columnsView()
        table.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        NSLayoutConstraint.activate([
            // Pinned to the CLIP view's width so the columns lay out at the card's width and the
            // scroll is vertical only — a document view free in both axes scrolls sideways instead
            // of wrapping.
            table.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            table.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            table.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return scroll
    }

    /// The two columns, side by side, each a run of sections.
    private static func columnsView() -> NSView {
        let dealt = CheatSheetContent.dealt(CheatSheetContent.sections, into: columnCount)
        let row = NSStackView(views: dealt.map(columnView))
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = Slate.Metric.space4
        row.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space2, left: Slate.Metric.space3,
            bottom: Slate.Metric.space4, right: Slate.Metric.space3,
        )
        return row
    }

    private static func columnView(_ sections: [CheatSheetSection]) -> NSView {
        let column = NSStackView(views: sections.map(sectionView))
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Slate.Metric.space3
        return column
    }

    /// One category: its caps heading, then its rows. No plate and no box — a card that is already a
    /// distinct object does not need internal boxes to say where a run begins; the air above does.
    private static func sectionView(_ section: CheatSheetSection) -> NSView {
        let heading = NSTextField(labelWithAttributedString: NSAttributedString(
            string: section.title.uppercased(),
            attributes: [
                .font: Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .medium),
                .foregroundColor: Slate.Native.Overlay.tertiary,
                // Wide enough to read as engraving, applied ONLY to an all-caps label.
                .kern: Slate.Typeface.instrumentTracking,
            ],
        ))
        heading.isSelectable = false

        let stack = NSStackView(views: [heading] + section.rows.map(rowView))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(Slate.Metric.space1, after: heading)
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: Slate.Metric.space2, bottom: 0, right: Slate.Metric.space2,
        )
        return stack
    }

    /// One binding: what it does, and the key that does it.
    private static func rowView(_ row: CheatSheetRow) -> NSView {
        let title = label(
            row.title,
            font: .systemFont(ofSize: Slate.Typeface.base),
            color: Slate.Native.Overlay.secondary,
        )
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [title, spacer]
        if let glyph = row.glyph { views.append(MacKeycapView(label: glyph)) }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Slate.Metric.space2
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: Slate.Metric.space2, bottom: 0, right: Slate.Metric.space2,
        )
        stack.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow).isActive = true
        return stack
    }

    // MARK: - Leaves

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        return field
    }
}

// MARK: - The keycap

/// A key the reader can press RIGHT NOW, drawn as a cap: a faint plate with a hairline edge.
///
/// A chord is ONE cap ("⇧⌘L"), not a cap per glyph — the modifiers are not separate keys to find,
/// they are one gesture, and splitting them into a row of little boxes reads as four things to do.
///
/// Set in the SYSTEM face, not the instrument one, and that is a rendering fact rather than a
/// preference: a chord's modifiers are symbol glyphs (⇧ ⌘ ⌥ ⌃) and a monospaced face advances them
/// by its cell rather than by the glyph, which smears "⇧⌘W" into one blur. macOS draws the same
/// glyphs in the same face in every menu, so this is also the register a reader already knows.
final class MacKeycapView: NSView {
    private let field: NSTextField
    /// Whether the row this cap sits on is the selected one — the cap brightens WITH its row rather
    /// than staying at one fixed weight, so the eye tracks a single object down the list.
    private var lit = false

    init(label: String) {
        field = NSTextField(labelWithString: label)
        field.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        field.isSelectable = false
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
        ])
        // The cap is laid out FIRST and the title takes what is left: in a row a flexible label will
        // happily eat the width its neighbour needed, and a shortcut with its key truncated off is
        // not a shortcut.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Re-cuts the cap for a row that changed — a switcher step moves the plate down the list, and the
    /// cap has to travel with it rather than being rebuilt under it.
    func relabel(_ label: String, lit: Bool) {
        field.stringValue = label
        self.lit = lit
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Overlay.plate.cgColor
            layer?.borderColor = Slate.Native.Overlay.hairline.cgColor
            field.textColor = lit ? Slate.Native.Overlay.secondary : Slate.Native.Overlay.tertiary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

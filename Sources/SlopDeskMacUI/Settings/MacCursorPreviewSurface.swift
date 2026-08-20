// MacCursorPreviewSurface — the Appearance → Cursor group, in AppKit.
//
// docs/56 stage D, increment 49. The group is `Platform::Both` — the gate that once made it macOS-only was
// struck when the phone was found to be losing the cursor colour, the text-under colour and the opacity
// outright, which is a CAPABILITY difference and not a drawing one. So there are two renderers, and every
// word, every prompt run and the caret's cell estimate come from `SettingsCursorSurface` in
// `SlopDeskClientCore`; the four caret silhouettes are drawn twice on purpose, because a silhouette is a
// drawing.
//
// THE STYLE ROW IS SEGMENTED, not a card grid, for the reason `MacSettingsRows` gives for every `.cards`
// row: art per option is a TOUCH affordance, and a mouse-driven window has a control for "pick one of a
// handful" that carries the system's own focus ring and keyboard traversal. That is also the ONE thing
// given up against the phone here: the four caret silhouettes appear once, in the live preview, rather than
// once per option. The phone shows them on its cards because it has no segmented control to show them on —
// and the preview redraws on every pick, so picking still SHOWS the answer, one beat later than a card grid
// would. Getting the art back needs `NSSegmentedControl.setImage(_:forSegment:)` over a rasterised
// `MacCursorCaretView`, which is a real option and not what a first crossing should spend its budget on.

import AppKit
import SlopDeskClientCore // SettingsCursorSurface, CursorColorHex — the answers both halves read
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore

/// The Cursor group's rows: the blurb, the live preview, two colour wells, the opacity slider, the style
/// segments and the blink menu.
@MainActor
final class MacCursorPreviewSurface: NSStackView {
    private let store: PreferencesStore
    private let preview: MacCursorPromptView

    init(store: PreferencesStore) {
        self.store = store
        preview = MacCursorPromptView(store: store)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space3
        translatesAutoresizingMaskIntoConstraints = false

        let blurb = macSettingsNote(SettingsCursorSurface.blurb, .secondary, style: .subheadline)
        addArrangedSubview(blurb)
        blurb.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        let rows = [
            colorRow(SettingsCursorSurface.colorLabel, \.cursorColor, fallback: \.foreground),
            colorRow(SettingsCursorSurface.textColorLabel, \.cursorTextColor, fallback: \.background),
            opacityRow(),
            styleRow(),
            blinkRow(),
        ]
        for row in rows {
            addArrangedSubview(row)
            // AFTER the add: a constraint between two views with no common ancestor yet raises at
            // activation time rather than waiting for one to appear.
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: The rows

    /// One colour well over a 6-hex `TerminalPreferences` field.
    ///
    /// An empty / malformed field reads as the theme's own colour (`fallback`), so the well shows the
    /// EFFECTIVE colour rather than black — picking is then a change from what is actually on screen.
    /// Writing goes through sRGB: `CursorColorHex` is where the format lives, and the well's colour is
    /// converted into that space first because a wide-gamut pick has no meaning in a six-digit string.
    private func colorRow(
        _ label: String,
        _ field: WritableKeyPath<TerminalPreferences, String>,
        fallback: KeyPath<TerminalPreferences, String>,
    ) -> NSView {
        let well = MacActionColorWell { [store] color in
            store.terminal[keyPath: field] = Self.hex(color)
        }
        well.color = Self.color(store.terminal[keyPath: field])
            ?? Self.color(store.terminal[keyPath: fallback])
            ?? Slate.Native.Text.primary
        return trailing(NSTextField(labelWithString: label), well)
    }

    private func opacityRow() -> NSView {
        let readout = NSTextField(labelWithString: Self.opacityText(store.terminal.cursorOpacity))
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        readout.textColor = Slate.Native.Text.secondary

        let slider = MacActionSlider { [store, preview] value in
            readout.stringValue = Self.opacityText(value)
            store.terminal.cursorOpacity = value
            preview.refresh()
        }
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = store.terminal.cursorOpacity

        let line = NSStackView(views: [readout, slider])
        line.orientation = .horizontal
        line.spacing = Slate.Metric.space2
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return trailing(NSTextField(labelWithString: SettingsCursorSurface.opacityLabel), line)
    }

    /// The four caret styles, each segment showing the silhouette it selects rather than only its name.
    private func styleRow() -> NSView {
        let options = SettingsCatalog.stringOptions(.cursorStyle)
        let segments = MacActionSegments(tokens: options.map(\.value)) { [store, preview] token in
            guard let style = TerminalPreferences.CursorStyle(rawValue: token) else { return }
            store.terminal.cursorStyle = style
            preview.refresh()
        }
        segments.segmentCount = options.count
        segments.trackingMode = .selectOne
        for (index, option) in options.enumerated() {
            segments.setLabel(option.label, forSegment: index)
            segments.setWidth(0, forSegment: index)
        }
        segments.selectToken(store.terminal.cursorStyle.rawValue)
        let title = NSTextField(labelWithString: SettingsLayout.label(for: AllSettingsCatalog.RenderKey.cursorStyle))
        return stacked(title, segments)
    }

    private func blinkRow() -> NSView {
        let options = SettingsCatalog.stringOptions(.cursorBlink)
        let popup = MacActionPopUp(tokens: options.map(\.value)) { [store, preview] token in
            guard let blink = TerminalPreferences.CursorBlink(rawValue: token) else { return }
            store.terminal.cursorBlink = blink
            preview.refresh()
        }
        for option in options { popup.addItem(withTitle: option.menuLabel) }
        popup.selectToken(store.terminal.cursorBlink.rawValue)
        return trailing(
            NSTextField(labelWithString: SettingsLayout.label(for: AllSettingsCatalog.RenderKey.cursorStyleBlink)),
            popup,
        )
    }

    // MARK: Shapes and conversions

    private func trailing(_ label: NSView, _ control: NSView) -> NSView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space3
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return row
    }

    private func stacked(_ label: NSView, _ control: NSView) -> NSView {
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space2
        return stack
    }

    private static func opacityText(_ value: Double) -> String { String(format: "%.2f", value) }

    /// A stored 6-hex string as a colour, or `nil` for the empty / malformed value that means "follow the
    /// theme".
    static func color(_ hex: String) -> NSColor? {
        guard let rgb = CursorColorHex.rgb(hex) else { return nil }
        return NSColor(
            srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1,
        )
    }

    /// A colour as the stored 6-hex string. A colour that resists sRGB conversion degrades to `""` —
    /// "Default" — rather than trapping, which is the same failure the SwiftUI half's `resolve(in:)`
    /// spelling takes.
    static func hex(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "" }
        return CursorColorHex.hex(
            r: Double(srgb.redComponent), g: Double(srgb.greenComponent), b: Double(srgb.blueComponent),
        )
    }
}

// MARK: - The live prompt

/// The `john@doe-pc$ git commit -m "│"` mock, on the inset card.
///
/// A single view rather than a stack of labels around a caret: the runs are monospaced and adjacent, and
/// an `NSStackView` of `NSTextField`s puts each one's own leading/trailing padding between characters that
/// are supposed to be touching.
@MainActor
final class MacCursorPromptView: NSView {
    private let store: PreferencesStore
    private let caret = MacCursorCaretView()

    init(store: PreferencesStore) {
        self.store = store
        super.init(frame: .zero)
        addSubview(caret)
        caret.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: cell().height + 2 * Slate.Metric.space2)
    }

    /// Re-read every cursor field and redraw. Cheap — this is one text draw and one caret — and it is the
    /// AppKit spelling of the SwiftUI half's automatic dependency tracking, which is the rule
    /// `MacSettingsPage` states for the whole page: a rebuild IS the update.
    func refresh() {
        caret.style = store.terminal.cursorStyle
        caret.ink = MacCursorPreviewSurface.color(store.terminal.cursorColor)
            ?? MacCursorPreviewSurface.color(store.terminal.foreground)
            ?? Slate.Native.Text.primary
        caret.alphaValue = CGFloat(store.terminal.cursorOpacity)
        caret.setBlinking(SettingsCursorSurface.previewBlinks(store.terminal.cursorBlink))
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let box = cell()
        let x = Slate.Metric.space3 + width(of: SettingsCursorSurface.promptBeforeCaret)
        caret.frame = NSRect(
            x: x, y: (bounds.height - box.height) / 2, width: box.width, height: box.height,
        )
    }

    /// The card and its runs, DRAWN rather than layer-configured.
    ///
    /// A layer-backed view with a `cornerRadius` + `borderColor` was the first draft and is wrong twice: a
    /// `CGColor` resolves ONCE, so the rim would keep its light-mode grey after a switch to dark, and
    /// `updateLayer()` is never called on a view that implements `draw(_:)` — which this must, for the
    /// prompt runs. One drawing pass, resolved against the live effective appearance, does both.
    override func draw(_: NSRect) {
        let plate = NSBezierPath(
            roundedRect: bounds.insetBy(dx: Slate.Metric.hairline / 2, dy: Slate.Metric.hairline / 2),
            xRadius: Slate.Metric.radiusCard,
            yRadius: Slate.Metric.radiusCard,
        )
        Slate.Native.Surface.chip.setFill()
        plate.fill()
        Slate.Native.Line.divider.setStroke()
        plate.lineWidth = Slate.Metric.hairline
        plate.stroke()

        let box = cell()
        var x = Slate.Metric.space3
        let baseline = (bounds.height - box.height) / 2
        for run in SettingsCursorSurface.promptBeforeCaret + [caretGap()]
            + SettingsCursorSurface.promptAfterCaret
        {
            let text = NSAttributedString(
                string: run.text,
                attributes: [.font: Self.face, .foregroundColor: run.ink.nativeInk],
            )
            text.draw(at: NSPoint(x: x, y: baseline))
            x += text.size().width
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// One cell's worth of blank where the caret sits, so the closing quote lands after it rather than
    /// under it. Spelled as a run so the layout above and the draw here measure the SAME string.
    private func caretGap() -> SettingsCursorPromptRun {
        SettingsCursorPromptRun(" ", .primary)
    }

    private func cell() -> NSSize {
        let box = SettingsCursorSurface.previewCell(em: Double(Self.face.pointSize))
        return NSSize(width: box.width, height: box.height)
    }

    private func width(of runs: [SettingsCursorPromptRun]) -> CGFloat {
        runs.reduce(0) { total, run in
            total + NSAttributedString(string: run.text, attributes: [.font: Self.face]).size().width
        }
    }

    /// The preview's face: the monospaced body rung. Read live rather than frozen at a literal, so the card
    /// tracks the system text-size setting the way every other row here does.
    private static var face: NSFont {
        .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
    }
}

// MARK: - The caret

/// The terminal caret in one of the four styles — this half's drawing of the silhouette
/// `SlopDeskPhoneUI/Settings/SettingsIllustrations.swift`'s `CursorCaret` draws in SwiftUI.
///
/// A drawing, drawn twice, is what docs/56 §3 asks for. What the two share is not the geometry but the
/// STYLE ENUM behind it, which is `TerminalPreferences.CursorStyle` and has exactly four cases.
@MainActor
final class MacCursorCaretView: NSView {
    var style: TerminalPreferences.CursorStyle = .block {
        didSet { needsDisplay = true }
    }

    var ink: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    /// The two THIN styles' thickness.
    private static let stroke: CGFloat = 2

    override func draw(_: NSRect) {
        ink.setFill()
        switch style {
        case .block:
            bounds.fill()
        case .blockHollow:
            ink.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: Slate.Metric.hairline / 2, dy: Slate.Metric.hairline / 2))
            path.lineWidth = Slate.Metric.hairline
            path.stroke()
        case .bar:
            NSRect(x: bounds.minX, y: bounds.minY, width: Self.stroke, height: bounds.height).fill()
        case .underline:
            NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: Self.stroke).fill()
        }
    }

    /// Start or stop the cosmetic blink.
    ///
    /// A `CABasicAnimation` on the layer's opacity rather than a timer: it runs on the render server, it
    /// stops when the view leaves the window without anything having to remember to invalidate a timer, and
    /// it takes the SAME rung the SwiftUI half animates on — `Slate.Motion.pulse`, autoreversing forever.
    /// The `alphaValue` the surface sets for cursor OPACITY is untouched; this animates the layer under it.
    func setBlinking(_ blinking: Bool) {
        wantsLayer = true
        layer?.removeAnimation(forKey: Self.blinkKey)
        guard blinking else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        // FROM the caret's own opacity, not from 1: `alphaValue` carries the reader's cursor-opacity
        // setting, and a blink that started at full would erase it for half of every cycle.
        fade.fromValue = alphaValue
        fade.toValue = 0
        fade.duration = Slate.Motion.pulse.duration
        fade.timingFunction = Slate.Motion.pulse.timingFunction
        fade.autoreverses = true
        fade.repeatCount = .infinity
        layer?.add(fade, forKey: Self.blinkKey)
    }

    private static let blinkKey = "slopdesk.cursor.blink"
}

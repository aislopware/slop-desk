// SettingsControls — the illustrated control vocabulary the Settings pages are built from.
//
// WHY: the Settings surface had exactly three control shapes — a `.menu` `Picker`, a `Toggle`, and a
// `TextField`/`Stepper`. Every choice therefore read as a word, never as a SHAPE: "Bar" vs "Block Hollow",
// "Left Option Only" vs "Both Option Keys", "Grid (cols × rows)" vs "Frame (pixels)" all look identical until
// you parse the prose. otty's settings pages (`docs/ui-shell/screenshots/cursor-style.png`,
// `font-setting.png`) instead show the thing being configured — a live caret in a prompt line, an "Aa"
// specimen per family — and the choice becomes recognisable rather than readable.
//
// This file adds the three shapes that were missing, and NOTHING that carries state of its own (every control
// is a pure function of a `Binding`, so the store stays the single owner):
//
//   * ``SettingsOptionCards`` — an illustrated radio GROUP: one card per option, each DRAWING its own choice
//     (`SettingsIllustrations`), the selected card ringed in the system accent.
//   * ``SettingsOptionMenuRow`` — the same pinned option LIST rendered as a native `.menu` `Picker`.
//   * ``SettingsSliderRow`` — a slider with PRESET stops (tap a stop to jump) and a monospaced readout, for
//     ranges where the useful values are a handful of magnitudes, not a continuum (scrollback depth: a
//     1000-step `Stepper` needed ~99 clicks to cross its own range).
//   * ``SettingsGlyphToggleRow`` — a toggle row with a leading glyph, so a 9-row group is scannable by icon
//     instead of being an undifferentiated wall of sentences.
//
// WHEN A CARD, WHEN A MENU. A card costs a whole grid row and asks the eye to compare pictures; it earns
// that only when the picture IS the difference — a caret silhouette, a tab column with the new row wedged in,
// a keyboard with the armed ⌥ lit, a miniature of a theme. Where the "illustration" was only an SF Symbol
// standing in for a word (Right-Click Action, On Launch, Close Confirmation), the card was a dropdown wearing
// picture frames: `nosign` and `doc.on.clipboard` say nothing "Ignore" and "Paste" don't, and the grid pushed
// the rest of the page down to say it. Those groups are ``SettingsOptionMenuRow``s now — same
// `SettingsOption` lists, same exhaustiveness pin, one row each.
//
// ONE CARD SIZE. Every card is `Slate.Metric.settingsCardWidth` wide over a `Slate.Metric.settingsCardArt`
// art band — theme swatches included. The grid used to be `.adaptive(minimum:)`, which STRETCHES its columns
// to fill the width: a 2-option group rendered two enormous cards while the theme gallery rendered seven
// small ones, so cards in the same window disagreed about how big a card is. Fixed columns WRAP instead of
// stretching, so a card is a card wherever it appears.
//
// SELECTION IS ONE SHAPE (the badge-saga lesson, `slopdesk-one-shape-status-circle`): a selected card is
// stated ONCE — accent border + accent wash + semibold label. No checkmark, no shimmer, no second marker.
//
// Colour + type come from ``SettingsInk`` / ``SettingsType`` (system semantics, not the terminal theme);
// geometry rides `Slate.Metric` (raw font/radius/height literals fail the `design-token-leaks` gate).

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

// MARK: - Which half is asking

extension SettingsLayout.Half {
    /// The half this target renders: `.phone`, always.
    ///
    /// A name rather than the literal at each of the eight pages, so a page asks the layout table for
    /// "my half" without typing which one. It was a platform gate while ONE target still drew both
    /// halves; `SlopDeskMacUI` names `.mac` outright at its own call site, and neither half carries a
    /// gate any more, which is the rule docs/56 §3 ratchets.
    static var current: Self { .phone }
}

/// The leading SF Symbol a schema row asks for, as this half's symbol type.
///
/// The NAME is the table's (`eye.slash`); resolving it to a drawable is the renderer's, which is why
/// this is here and not at the boundary — `SFSafeSymbols` is a Swift package, and a drawable is a
/// view-layer type no table can carry. A row that carries no glyph falls back to a neutral dot rather
/// than leaving a hole in the group's icon rail.
func glyph(_ row: SettingsLayout.Row) -> SFSymbol {
    row.control.glyphName.map(SFSymbol.init(rawValue:)) ?? .circle
}

extension SettingsLayout.Control {
    /// The glyph name this control carries, if it carries one.
    var glyphName: String? {
        switch self {
        case let .toggle(glyph): glyph
        case let .menu(_, glyph): glyph
        case let .text(glyph): glyph
        case .cards,
             .slider,
             .stepper,
             .note,
             .bespoke: nil
        }
    }
}

/// When a setting takes effect — surfaced as a chip so the deferred/live distinction is a DATA
/// attribute, not prose. The two cases and their words are ``SettingsCatalog/ApplyTiming``; only the
/// tint below is a view decision.
typealias ApplyTiming = SettingsCatalog.ApplyTiming

/// A small inline timing chip (symbol + label). The tint is resolved in the view body rather than on the
/// nonisolated `ApplyTiming` enum.
struct TimingChip: View {
    let timing: ApplyTiming
    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemName: timing.symbol)
            Text(timing.label)
        }
        .font(SettingsType.caption)
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch timing {
        case .live: SettingsInk.ok
        case .reconnect: SettingsInk.warn
        }
    }
}

/// A right-aligned timing chip used as a section footer so each section's apply timing is visible
/// inline. Lives beside ``settingsGroup(_:row:)``, which is what places it under every group.
func timingFooter(_ timing: ApplyTiming) -> some View {
    HStack {
        Spacer()
        TimingChip(timing: timing)
    }
}

/// One schema group as a form section: the header, the rows the asking half draws, and the chip that
/// says when an edit here takes effect.
///
/// A group that ``SettingsLayout/Group/drawsItsOwnHeader`` is placed BARE — it is a whole surface
/// (the font specimen, the live cursor preview) rather than a list of rows, so wrapping it would nest
/// a section inside a section and print a header it already drew.
///
/// The chip appears only where some row EDITS a setting. "Applies immediately" answers a question a
/// list of controls raises; under a surface that draws itself — the chord editor, the flat index, the
/// reserved Editor page's empty state — it either states nothing or contradicts what that surface says
/// about itself.
@ViewBuilder
func settingsGroup(
    _ group: SettingsLayout.Group,
    @ViewBuilder row: @escaping (SettingsLayout.Row) -> some View,
) -> some View {
    if group.drawsItsOwnHeader {
        ForEach(group.rows) { row($0) }
    } else {
        slateFormSection(group.title) {
            ForEach(group.rows) { row($0) }
            if group.editsASetting { timingFooter(group.timing) }
        }
    }
}

// MARK: - LineHeightChoice (a menu tag for the associated-value LineHeightMode)

/// A flat mirror of ``LineHeightMode``'s four cases, for a control that has to TAG its choices: the
/// model enum carries a `Double` on `.custom`, so it cannot be a tag itself.
///
/// The raw values are the catalog's tokens, which is what makes this readable from
/// `SettingsCatalog.options(.lineHeight, as:)` rather than from four inline `Text(…).tag(…)` children
/// — the shape that had let the four choices drift out of reach of any test.
enum LineHeightChoice: String, Hashable, Sendable {
    case `default`
    case compact
    case loose
    case custom
}

/// A ``SettingsLayout/Control/note`` row: prose belonging to the GROUP rather than to any setting,
/// set in the same gray as a row's subtitle so it reads as a footnote and not as a control that lost
/// its widget. The words are the row's subtitle, because a note has nothing else to say.
func settingsNote(_ row: SettingsLayout.Row) -> some View {
    Text(row.subtitle)
        .font(SettingsType.subtitle)
        .foregroundStyle(SettingsInk.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - The stepper, over an integer or a double

/// A schema stepper row: the row's own label, the value in the range's readout, and the range's ends
/// and granularity — none of the four typed here.
@ViewBuilder
func settingsStepper(_ row: SettingsLayout.Row, _ value: Binding<Int>) -> some View {
    if case let .stepper(range) = row.control {
        Stepper(
            "\(row.label): \(range.readout(value.wrappedValue))",
            value: value,
            in: range.range,
            step: range.step,
        )
    }
}

/// The same row over a field the model holds as a `Double` — the terminal font size, which the flat
/// index's raw editor may set to a fractional point value the clicks then move a whole point at a
/// time. Reading the `Double` back is what keeps a `13.5` from displaying as a number nothing holds.
@ViewBuilder
func settingsStepper(_ row: SettingsLayout.Row, _ value: Binding<Double>) -> some View {
    if case let .stepper(range) = row.control {
        Stepper(
            "\(row.label): \(range.readout(value.wrappedValue))",
            value: value,
            in: range.doubleRange,
            step: Double(range.step),
        )
    }
}

/// The bold-label / gray-subtext stack every settings row leads with.
///
/// Was `private` on three separate settings pages, byte for byte, which is exactly the duplication a
/// row's WORDS have now stopped being — the shape they are set in had no reason to stay behind.
func rowLabel(_ title: String, _ subtitle: String?) -> some View {
    VStack(alignment: .leading, spacing: Slate.Metric.space1) {
        Text(title)
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// ``rowLabel(_:_:)`` with the leading glyph that runs a group's icon rail through the row.
func glyphLabel(_ symbol: SFSymbol, _ title: String, _ subtitle: String?) -> some View {
    HStack(alignment: .top, spacing: Slate.Metric.space2) {
        Image(systemSymbol: symbol)
            .font(SettingsType.label)
            .foregroundStyle(SettingsInk.icon)
            .frame(width: Slate.Metric.iconSize)
            .padding(.top, Slate.Metric.space1 / 2)
        rowLabel(title, subtitle)
    }
}

// MARK: - What a row is CALLED

/// The label the setting `key` carries — read from the one row table
/// (`slopdesk_workspace::settings_rows`) rather than typed at the control.
///
/// A setting is named in two places: on the section page where it is set, and in the searchable
/// all-settings list. Those are the same words doing the same job, so they are one string. They were
/// two, and two was already visibly one too many — the same row was spelled "Hide Mouse While Typing"
/// in one place and "Hide Mouse When Typing" in the other, and "Long-Command Notification" against
/// "Long-Command Completion", with nothing anywhere that would notice.
///
/// The DESCRIPTION deliberately does NOT come from here, and that is not an oversight. A row in a flat
/// index of fifty-seven keys has to stand alone ("The UI density tier."); the same row under a THEME
/// header on the Appearance page has the header's context already and can say the useful thing instead
/// ("How much air each sidebar row gets."). Twenty-two of the thirty-one shared rows differ that way.
/// Two registers, two sentences, one name.
///
/// The LABEL reaches for the same distinction in the minority of rows where it needs to, which is why
/// this reads `pageLabel` rather than `label`: under a `Close Confirmation` header the row is
/// "Closing a tab", while the same row in a headerless list of fifty-seven keys has to say
/// "Close Confirmation · Tab" or name nothing. The boundary folds the fallback, so most rows return
/// the one string they have and no caller here knows which are which.
///
/// An unknown key answers with the key itself, which is visible on screen rather than silent — a
/// blank row label would look like a layout bug instead of a missing table entry.
///
/// Forwards to ``SettingsLayout/label(for:)`` since increment 49: the same lookup was typed out at three
/// call sites — here, the row table, and the Mac's cursor surface, which draws two settings a row table
/// does not describe and still has to call them what the table would have.
func settingLabel(_ key: String) -> String { SettingsLayout.label(for: key) }

// MARK: - SettingsOptionMenuRow (the same list, as a native dropdown)

/// A native `.menu` `Picker` row over a pinned ``SettingsOption`` list — the shape a choice takes when its
/// options differ by WORDS, not by picture. Title + optional subtitle lead; the dropdown trails.
struct SettingsOptionMenuRow<Value: Hashable & Sendable>: View {
    let title: String
    let subtitle: String?
    let options: [SettingsOption<Value>]
    @Binding var selection: Value

    init(
        _ title: String,
        subtitle: String? = nil,
        options: [SettingsOption<Value>],
        selection: Binding<Value>,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.options = options
        _selection = selection
    }

    var body: some View {
        LabeledContent {
            Picker("", selection: $selection) {
                ForEach(options) { option in
                    Text(option.menuLabel).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } label: {
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - The card's selection, readable by its art

extension EnvironmentValues {
    /// Whether the option card CURRENTLY BEING DRAWN is the selected one — injected by
    /// ``SettingsOptionCard`` around its art, so a diagram can join the selection statement (the caret tints
    /// to the accent) without every call site threading the comparison itself.
    @Entry var settingsOptionIsSelected: Bool = false
}

// MARK: - SettingsOptionCards (the illustrated radio group)

/// An illustrated radio group: a title + optional subtitle over a wrapping grid of option cards, each drawing
/// its own choice. The selected card carries the accent ring; tapping a card writes `selection`.
///
/// Laid out in FIXED-width columns that wrap: every card in Settings is the same size, whether its group has
/// two options or seven (see the file header — an adaptive grid stretched them apart).
struct SettingsOptionCards<Value: Hashable & Sendable, Illustration: View>: View {
    let title: String
    let subtitle: String?
    let options: [SettingsOption<Value>]
    @Binding var selection: Value
    /// The card art for one option. A closure over the OPTION (not a stored view per option) so each call site
    /// draws its own diagram family — a caret shape, a key row, a theme swatch — from one component.
    let illustration: (SettingsOption<Value>) -> Illustration

    init(
        _ title: String,
        subtitle: String? = nil,
        options: [SettingsOption<Value>],
        selection: Binding<Value>,
        @ViewBuilder illustration: @escaping (SettingsOption<Value>) -> Illustration,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.options = options
        _selection = selection
        self.illustration = illustration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Slate.Metric.space2) {
                ForEach(options) { option in
                    SettingsOptionCard(
                        option: option,
                        isSelected: option.value == selection,
                        select: { selection = option.value },
                    ) {
                        illustration(option)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One radio group to assistive tech, not N unrelated buttons.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// FIXED (not adaptive) columns: `.adaptive` stretches its columns to fill the row, which is what made a
    /// 2-option group's cards twice the size of the theme gallery's. `.flexible` bounded to the same min and
    /// max holds every card at exactly one width and wraps the overflow.
    private var columns: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: Slate.Metric.settingsCardWidth,
                maximum: Slate.Metric.settingsCardWidth,
            ),
            spacing: Slate.Metric.space2,
            alignment: .top,
        )]
    }
}

// MARK: - SettingsOptionCard (one card — owns only its hover state)

/// One card in a ``SettingsOptionCards`` group. Holds hover state (a card is the hover unit) and nothing else;
/// selection lives in the caller's binding.
private struct SettingsOptionCard<Value: Hashable & Sendable, Illustration: View>: View {
    let option: SettingsOption<Value>
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder let illustration: () -> Illustration

    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: Slate.Metric.space2) {
                illustration()
                    .environment(\.settingsOptionIsSelected, isSelected)
                    .frame(height: Slate.Metric.settingsCardArt)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 0) {
                    Text(option.label)
                        .font(SettingsType.subtitle.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(SettingsInk.primary)
                        .multilineTextAlignment(.center)
                    if let caption = option.caption, !caption.isEmpty {
                        Text(caption)
                            .font(SettingsType.caption)
                            .foregroundStyle(SettingsInk.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                // Push the label block to the TOP of whatever height the row settles on, so a captionless
                // card's art still lines up with its captioned neighbour's.
                Spacer(minLength: 0)
            }
            .padding(Slate.Metric.space2)
            // Fill the grid row in BOTH axes. A `LazyVGrid` row is as tall as its tallest item, and only
            // some options carry a caption (`auto` new-tab position does, `end` doesn't) — without this the
            // captioned card would draw a taller plate than the one beside it, which is the "one big one
            // small" the fixed column width was meant to end.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard, style: .continuous)
                    .fill(fill),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard, style: .continuous)
                    .strokeBorder(border, lineWidth: Slate.Metric.cardBorderWidth),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Slate.Anim.smallFade, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Selected ⇒ the accent wash; hovered ⇒ the hover plate; otherwise the inset surface. The selected state
    /// is stated by wash + ring + weight only (no extra marker).
    private var fill: Color {
        if isSelected { return SettingsInk.accentWash }
        return hovered ? SettingsInk.hover : SettingsInk.inset
    }

    private var border: Color {
        if isSelected { return SettingsInk.accent }
        return hovered ? SettingsInk.strongLine : SettingsInk.hairline
    }
}

// MARK: - SettingsSliderRow (slider + preset stops + readout)

/// A slider row for a range whose useful values are a few MAGNITUDES: the label + subtitle, the slider with a
/// monospaced readout, and tappable preset stops beneath. Used where a `Stepper`'s fixed increment made the
/// range impractical to cross (scrollback: 1 000 → 100 000 in 1 000-line clicks) or where the numbers alone
/// don't convey scale.
///
/// The presets are a LIST, not tick marks on the track: a stop is a real target you can hit exactly, which a
/// dragged continuous slider cannot promise.
struct SettingsSliderRow: View {
    let title: String
    let subtitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// The readout for the CURRENT value (e.g. `50 000 lines`, `1.25×`, `2.5s`) — passed in so each call site
    /// owns its unit and formatting.
    let readout: (Double) -> String
    /// Tappable stops: the label shown on the chip and the value it jumps to.
    let presets: [(label: String, value: Double)]

    init(
        _ title: String,
        subtitle: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        presets: [(label: String, value: Double)] = [],
        readout: @escaping (Double) -> String,
    ) {
        self.title = title
        self.subtitle = subtitle
        _value = value
        self.range = range
        self.step = step
        self.presets = presets
        self.readout = readout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    Text(title)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(SettingsType.subtitle)
                            .foregroundStyle(SettingsInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Slate.Metric.space2)
                Text(readout(value))
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.primary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
            if !presets.isEmpty {
                // TRAILING-aligned, because a `.grouped` `Form` puts the `Slider` in the row's content column
                // (it auto-labels bare controls) — so the track occupies the right half. HW review showed
                // left-aligned chips reading as a detached strip under a label they don't belong to; ending
                // them at the same right edge as the track groups the stops with the slider they move.
                HStack(spacing: Slate.Metric.space1) {
                    Spacer(minLength: 0)
                    ForEach(presets, id: \.label) { preset in
                        presetChip(preset)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One preset stop. Reads as ACTIVE when the live value is already at it (within half a step, so a
    /// float-stepped slider still lights the stop it landed on).
    private func presetChip(_ preset: (label: String, value: Double)) -> some View {
        let active = Swift.abs(value - preset.value) <= step / 2
        return Button {
            value = preset.value
        } label: {
            Text(preset.label)
                .font(SettingsType.caption)
                .monospacedDigit()
                .foregroundStyle(active ? SettingsInk.accent : SettingsInk.secondary)
                .padding(.horizontal, Slate.Metric.space2)
                .padding(.vertical, Slate.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                        .fill(active ? SettingsInk.accentWash : SettingsInk.inset),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                        .strokeBorder(
                            active ? SettingsInk.accent : SettingsInk.hairline,
                            lineWidth: Slate.Metric.hairline,
                        ),
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(preset.label)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - SettingsGlyphToggleRow (icon + title + subtext + switch)

/// A toggle row with a leading SF Symbol. The glyph is the SCANNING handle: the Notification group is nine
/// consecutive sentence-subtitled switches, and an icon column lets the eye find "sound" or "dock" without
/// reading all nine. Same binding contract as a bare `Toggle` — no behaviour change, only a handle.
struct SettingsGlyphToggleRow: View {
    let symbol: SFSymbol
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    init(_ symbol: SFSymbol, _ title: String, _ subtitle: String? = nil, isOn: Binding<Bool>) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: Slate.Metric.space2) {
                Image(systemSymbol: symbol)
                    .font(SettingsType.label)
                    .foregroundStyle(isOn ? SettingsInk.accent : SettingsInk.icon)
                    .frame(width: Slate.Metric.iconSize)
                    // Hold the glyph on the title's baseline row while the subtitle wraps below it.
                    .padding(.top, Slate.Metric.space1 / 2)
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    Text(title)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(SettingsType.subtitle)
                            .foregroundStyle(SettingsInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
#endif

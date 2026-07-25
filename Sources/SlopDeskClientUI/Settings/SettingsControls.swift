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
//   * ``SettingsOptionCards`` — an illustrated radio GROUP: one card per option, each drawing its own choice
//     (`SettingsIllustrations`), the selected card ringed in the theme accent. Replaces a `.menu` picker
//     wherever the option set is small AND visually distinguishable.
//   * ``SettingsSliderRow`` — a slider with PRESET stops (tap a stop to jump) and a monospaced readout, for
//     ranges where the useful values are a handful of magnitudes, not a continuum (scrollback depth: a
//     1000-step `Stepper` needed ~99 clicks to cross its own range).
//   * ``SettingsGlyphToggleRow`` — a toggle row with a leading glyph, so a 9-row group is scannable by icon
//     instead of being an undifferentiated wall of sentences.
//
// SELECTION IS ONE SHAPE (the badge-saga lesson, `slopdesk-one-shape-status-circle`): a selected card is
// stated ONCE — accent border + accent wash + semibold label. No checkmark, no shimmer, no second marker.
//
// CROSS-PLATFORM: pure SwiftUI, so the iOS settings sheet renders the same cards (no `#if os(macOS)` here).
// Slate.* tokens only (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

// MARK: - SettingsOption (the pure option descriptor)

/// One choice in a ``SettingsOptionCards`` group: the value it writes, its label, an optional one-line caption,
/// and — for the choices a diagram can't carry legibly — its glyph. Pure data: declaring the options as a LIST
/// (rather than inline `Text(…).tag(…)` children) is what lets a test pin the labels, captions, and order of a
/// section's choices without rendering it (`SettingsOptionCatalogTests`).
///
/// `symbol` is an `SFSymbol`, not a `String`: a mistyped symbol NAME renders as an invisible blank image, so
/// the type-safe spelling turns a silently-empty card into a build error.
/// `Sendable` (over a `Sendable` value) because the catalog holds these as top-level `static let` lists: pure,
/// immutable option data, reachable from any isolation without a `@MainActor` hop.
struct SettingsOption<Value: Hashable & Sendable>: Identifiable, Sendable {
    let value: Value
    let label: String
    /// A short qualifier under the label — where a card needs to be honest about a caveat ("same as End
    /// today", "saved, not yet active"). `nil` for the common case.
    let caption: String?
    /// The glyph for a symbol-art card. `nil` when the group draws its own diagram instead.
    let symbol: SFSymbol?

    var id: Value { value }

    init(_ value: Value, _ label: String, caption: String? = nil, symbol: SFSymbol? = nil) {
        self.value = value
        self.label = label
        self.caption = caption
        self.symbol = symbol
    }
}

// MARK: - The card's selection, readable by its art

extension EnvironmentValues {
    /// Whether the option card CURRENTLY BEING DRAWN is the selected one — injected by
    /// ``SettingsOptionCard`` around its art, so a diagram can join the selection statement (the caret and the
    /// symbol arts tint to the accent) without every call site threading the comparison itself.
    @Entry var settingsOptionIsSelected: Bool = false
}

// MARK: - SettingsOptionCards (the illustrated radio group)

/// An illustrated radio group: a title + optional subtitle over a wrapping grid of option cards, each drawing
/// its own choice. The selected card carries the accent ring; tapping a card writes `selection`.
///
/// Sized by an ADAPTIVE grid rather than a fixed column count, so the same call site reads as a pair of wide
/// cards for a 2-option enum and as a wrapping gallery for the 9 themes — with no per-site layout tuning.
struct SettingsOptionCards<Value: Hashable & Sendable, Illustration: View>: View {
    let title: String
    let subtitle: String?
    let options: [SettingsOption<Value>]
    @Binding var selection: Value
    /// The card art for one option. A closure over the OPTION (not a stored view per option) so each call site
    /// draws its own diagram family — a caret shape, a key row, a theme swatch — from one component.
    let illustration: (SettingsOption<Value>) -> Illustration
    /// The art band's height. Defaults to the one-diagram card rung; the theme gallery raises it because its
    /// art is a miniature terminal, not a single mark.
    let artHeight: CGFloat

    init(
        _ title: String,
        subtitle: String? = nil,
        options: [SettingsOption<Value>],
        selection: Binding<Value>,
        artHeight: CGFloat = Slate.Metric.settingsCardArt,
        @ViewBuilder illustration: @escaping (SettingsOption<Value>) -> Illustration,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.options = options
        _selection = selection
        self.artHeight = artHeight
        self.illustration = illustration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Slate.Metric.space2) {
                ForEach(options) { option in
                    SettingsOptionCard(
                        option: option,
                        isSelected: option.value == selection,
                        artHeight: artHeight,
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

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Slate.Metric.settingsCardWidth), spacing: Slate.Metric.space2)]
    }
}

extension SettingsOptionCards where Illustration == SettingsSymbolArt {
    /// The symbol-art group: every card draws its option's own ``SettingsOption/symbol``. For choices whose
    /// diagram would need more marks than a card can carry legibly (right-click actions, close-confirmation
    /// scopes, launch behaviour) — see ``SettingsSymbolArt``.
    init(
        _ title: String,
        subtitle: String? = nil,
        options: [SettingsOption<Value>],
        selection: Binding<Value>,
    ) {
        self.init(title, subtitle: subtitle, options: options, selection: selection) { option in
            SettingsSymbolArt(symbol: option.symbol ?? .questionmark)
        }
    }
}

// MARK: - SettingsOptionCard (one card — owns only its hover state)

/// One card in a ``SettingsOptionCards`` group. Holds hover state (a card is the hover unit) and nothing else;
/// selection lives in the caller's binding.
private struct SettingsOptionCard<Value: Hashable & Sendable, Illustration: View>: View {
    let option: SettingsOption<Value>
    let isSelected: Bool
    let artHeight: CGFloat
    let select: () -> Void
    @ViewBuilder let illustration: () -> Illustration

    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: Slate.Metric.space2) {
                illustration()
                    .environment(\.settingsOptionIsSelected, isSelected)
                    .frame(height: artHeight)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 0) {
                    Text(option.label)
                        .font(.system(size: Slate.Typeface.footnote, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Slate.Text.primary)
                        .multilineTextAlignment(.center)
                    if let caption = option.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: Slate.Typeface.small))
                            .foregroundStyle(Slate.Text.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(Slate.Metric.space2)
            .frame(maxWidth: .infinity)
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
        if isSelected { return Slate.State.accentMuted }
        return hovered ? Slate.State.hover : Slate.Surface.raised
    }

    private var border: Color {
        if isSelected { return Slate.State.accent }
        return hovered ? Slate.Line.active : Slate.Line.subtle
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
                            .font(.system(size: Slate.Typeface.footnote))
                            .foregroundStyle(Slate.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Slate.Metric.space2)
                Text(readout(value))
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.primary)
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
                .font(.system(size: Slate.Typeface.small))
                .monospacedDigit()
                .foregroundStyle(active ? Slate.State.accent : Slate.Text.secondary)
                .padding(.horizontal, Slate.Metric.space2)
                .padding(.vertical, Slate.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                        .fill(active ? Slate.State.accentMuted : Slate.Surface.raised),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                        .strokeBorder(
                            active ? Slate.State.accent : Slate.Line.subtle,
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
                    .font(.system(size: Slate.Typeface.base))
                    .foregroundStyle(isOn ? Slate.State.accent : Slate.Text.icon)
                    .frame(width: Slate.Metric.iconSize)
                    // Hold the glyph on the title's baseline row while the subtitle wraps below it.
                    .padding(.top, Slate.Metric.space1 / 2)
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    Text(title)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: Slate.Typeface.footnote))
                            .foregroundStyle(Slate.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
#endif

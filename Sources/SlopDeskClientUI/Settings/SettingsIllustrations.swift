// SettingsIllustrations — the card art: each Settings choice DRAWN rather than described.
//
// One view per choice family, all consumed by ``SettingsOptionCards`` as its `illustration` closure. The rule
// every diagram here follows: draw the STATE THE SETTING PRODUCES, not a decorative icon standing in for it.
// "Left Option Only" shows a key row with the left ⌥ lit; "After Current Tab" shows a tab column with the new
// row wedged under the active one; a theme shows a miniature of its own terminal. A reader who can't name the
// option can still recognise it.
//
// LEGIBLE-OR-ABSENT (`slopdesk-imagery-legible-or-absent-feedback`): at card size a diagram is ~40pt tall, so
// each one carries at most three marks. Anything that would need four is a symbol instead
// (``SettingsSymbolArt``) — a squinting-illegible diagram is worse than an honest glyph.
//
// GEOMETRY: the mark dimensions live in the private `Art` table below, NOT as inline literals — the diagrams
// share one visual beat (bar thickness, gap, dot size) so a row of cards reads as one system, and
// `scripts/check-ds-leaks.sh` keeps raw `.frame(height:)` numbers out of the view tree.
//
// Cross-platform (pure SwiftUI shapes — no AppKit), so the iOS settings sheet draws the same cards.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

// MARK: - Art (the shared diagram beat)

/// The mark dimensions every diagram in this file shares, so a row of cards has one rhythm.
private enum Art {
    /// A "line of text" bar's thickness — the atom most diagrams are built from.
    static let bar: CGFloat = 3
    /// A "row" (tab row, list row) in the stack diagrams.
    static let row: CGFloat = 7
    /// A palette / status dot.
    static let dot: CGFloat = 5
    /// A modifier-key cap in the keyboard diagram.
    static let cap: CGFloat = 11
    /// The gap between marks in a stack — tight enough that three rows still read as a group.
    static let gap: CGFloat = 3
    /// The mini window's title strip.
    static let titleStrip: CGFloat = 8
    /// A window-diagram frame's inset from the card art's edges, so the frame doesn't touch the card border.
    static let inset: CGFloat = 2
}

// MARK: - Colour from a palette hex (cross-platform)

extension Color {
    /// A colour from a bare 6-hex RGB string (a `SlateTheme.ansiPalette` entry / `terminal*Hex`), or `nil` when
    /// the string isn't 6 hex digits. Reuses the pure, unit-pinned ``CursorColorHex`` parser rather than adding
    /// a second hex path, and stays AppKit-free so the theme swatch draws on iOS too.
    init?(paletteHex hex: String) {
        guard let rgb = CursorColorHex.rgb(hex) else { return nil }
        self.init(
            .sRGB,
            red: Double(rgb.r) / 255,
            green: Double(rgb.g) / 255,
            blue: Double(rgb.b) / 255,
            opacity: 1,
        )
    }
}

// MARK: - CursorCaret (the shared caret shape)

/// The terminal caret in one of the four cursor styles — the ONE place the caret geometry lives, drawn by both
/// the Appearance → Cursor live preview (`CursorPreviewView`) and the cursor-style option cards. Sharing it is
/// the point: a card that drew its own approximation could disagree with the preview directly beneath it.
struct CursorCaret: View {
    let style: TerminalPreferences.CursorStyle
    let color: Color
    /// The monospace cell to fill. The preview passes its estimated cell; a card passes a diagram cell.
    let cell: CGSize
    /// The thickness of the two THIN styles (bar / underline).
    let stroke: CGFloat

    init(style: TerminalPreferences.CursorStyle, color: Color, cell: CGSize, stroke: CGFloat = 2) {
        self.style = style
        self.color = color
        self.cell = cell
        self.stroke = stroke
    }

    var body: some View {
        switch style {
        case .block:
            Rectangle().fill(color).frame(width: cell.width, height: cell.height)
        case .blockHollow:
            Rectangle()
                .strokeBorder(color, lineWidth: Slate.Metric.hairline)
                .frame(width: cell.width, height: cell.height)
        case .bar:
            Rectangle().fill(color).frame(width: stroke, height: cell.height)
                .frame(width: cell.width, height: cell.height, alignment: .leading)
        case .underline:
            Rectangle().fill(color).frame(width: cell.width, height: stroke)
                .frame(width: cell.width, height: cell.height, alignment: .bottom)
        }
    }
}

// MARK: - SettingsCaretArt (cursor-style card)

/// A cursor-style card: a two-glyph prompt fragment with the live caret after it, so the four styles are told
/// apart by silhouette (filled block / outlined block / thin bar / baseline rule) instead of by their names.
struct SettingsCaretArt: View {
    let style: TerminalPreferences.CursorStyle
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: Art.gap) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                    .fill(Slate.Text.tertiary)
                    .frame(width: Art.cap * 0.6, height: Art.bar * 3)
            }
            CursorCaret(
                style: style,
                color: color,
                cell: CGSize(width: Art.cap * 0.6, height: Art.bar * 3),
            )
        }
    }
}

// MARK: - SettingsTabPositionArt (new-tab-position card)

/// The sidebar tab COLUMN with the incoming tab drawn in the accent, at the slot the policy inserts it —
/// slopdesk is vertical-tabs-only, so the diagram is a column, never a top strip.
///
/// `auto` and `end` produce the SAME index today (`NewTabPosition.insertionIndex` returns `tabCount` for both),
/// so they draw the same append — the card's caption carries the distinction rather than a fictional diagram.
struct SettingsTabPositionArt: View {
    let position: NewTabPosition
    /// Which existing row is the ACTIVE tab — the anchor `afterCurrent` inserts below. Row 0 of 2.
    private let activeRow = 0

    var body: some View {
        VStack(spacing: Art.gap) {
            ForEach(rows.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                    .fill(fill(for: rows[index]))
                    .frame(height: Art.row)
                    .overlay(
                        RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                            .strokeBorder(stroke(for: rows[index]), lineWidth: Slate.Metric.hairline),
                    )
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
    }

    /// What each drawn row is: an existing tab, the active tab, or the incoming one.
    private enum Row { case existing, active, incoming }

    /// Two existing tabs (the first active) plus the incoming row at the policy's slot.
    private var rows: [Row] {
        var rows: [Row] = [.active, .existing]
        switch position {
        case .auto,
             .end:
            rows.append(.incoming)
        case .afterCurrent:
            rows.insert(.incoming, at: activeRow + 1)
        }
        return rows
    }

    private func fill(for row: Row) -> Color {
        switch row {
        case .existing: Slate.Line.subtle
        case .active: Slate.State.selected
        case .incoming: Slate.State.accent
        }
    }

    /// The ACTIVE row carries a visible outline. HW review caught that `State.selected` alone is a ~3% wash
    /// against `Line.subtle` at 7pt — indistinguishable, which cost "After current" its meaning (it read as
    /// "second row" rather than "after the CURRENT tab"). The outline is what makes the anchor legible.
    private func stroke(for row: Row) -> Color {
        switch row {
        case .existing: Slate.Line.subtle
        case .active: Slate.Line.active
        case .incoming: Slate.State.accent
        }
    }
}

// MARK: - SettingsDensityArt (density card)

/// The density tiers shown as what they change: how many rows fit and how much air each gets. Compact draws
/// more rows, tighter; comfortable draws fewer, looser — the actual trade being chosen.
struct SettingsDensityArt: View {
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? Art.gap / 2 : Art.gap * 1.5) {
            ForEach(0..<(compact ? 5 : 3), id: \.self) { _ in
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                    .fill(Slate.Text.tertiary)
                    .frame(height: Art.bar)
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
    }
}

// MARK: - SettingsOptionKeyArt (Option-as-Alt card)

/// The bottom modifier row with the ⌥ caps the setting arms drawn lit. Four options that read identically as
/// prose ("Off" / "Both Option Keys" / "Left Option Only" / "Right Option Only") become four distinct
/// silhouettes — which is the whole reason this control stopped being a dropdown.
struct SettingsOptionKeyArt: View {
    let mode: OptionAsAlt

    var body: some View {
        HStack(spacing: Art.gap / 2) {
            cap("⌃", lit: false)
            cap("⌥", lit: mode == .both || mode == .left)
            cap("⌘", lit: false)
            // The space bar — the anchor that makes the row read as a keyboard rather than four chips.
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                .fill(Slate.Line.subtle)
                .frame(width: Art.cap * 1.6, height: Art.cap)
            cap("⌘", lit: false)
            cap("⌥", lit: mode == .both || mode == .right)
        }
    }

    private func cap(_ glyph: String, lit: Bool) -> some View {
        Text(glyph)
            .font(.system(size: Slate.Typeface.small))
            .foregroundStyle(lit ? Slate.State.accent : Slate.Text.tertiary)
            .frame(width: Art.cap, height: Art.cap)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                    .fill(lit ? Slate.State.accentMuted : Slate.Surface.raised),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                    .strokeBorder(lit ? Slate.State.accent : Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
            )
    }
}

// MARK: - SettingsWindowArt (window-size + desktop-presentation cards)

/// A miniature window inside a screen bezel — the shared frame for the geometry choices. `content` draws what
/// distinguishes the mode (a grid of cells, dimension ticks, a ghost of the remembered frame).
struct SettingsWindowArt<Content: View>: View {
    /// Whether the window fills the screen (fullscreen / borderless) or floats inside it.
    let fills: Bool
    /// Whether the mini window keeps a title strip — the one visible difference between native fullscreen and
    /// a borderless cover.
    let titled: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            // The screen bezel — present in every card so "fills the screen" is a visible relationship.
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline)
            window
                .padding(fills ? 0 : Slate.Metric.space2)
        }
        .padding(Art.inset)
    }

    private var window: some View {
        VStack(spacing: 0) {
            if titled {
                HStack(spacing: Art.gap / 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Slate.Text.tertiary).frame(width: Art.dot / 2, height: Art.dot / 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Slate.Metric.space1)
                .frame(height: Art.titleStrip)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                .fill(Slate.Surface.face),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                .strokeBorder(Slate.Line.active, lineWidth: Slate.Metric.hairline),
        )
    }
}

/// The cell GRID a `window-size = grid` window is measured in (cols × rows), drawn as actual cells.
struct SettingsGridArt: View {
    var body: some View {
        VStack(spacing: Slate.Metric.hairline) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: Slate.Metric.hairline) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle().fill(Slate.Line.subtle)
                    }
                }
            }
        }
        .padding(Slate.Metric.space1)
    }
}

/// The pixel dimensions a `window-size = frame` window is measured in — a width rule and a height rule, the
/// two numbers the mode actually asks for.
struct SettingsPixelArt: View {
    var body: some View {
        VStack(spacing: Art.gap) {
            Rectangle().fill(Slate.State.accent).frame(height: Slate.Metric.hairline)
            HStack(spacing: Art.gap) {
                Rectangle().fill(Slate.State.accent).frame(width: Slate.Metric.hairline)
                Spacer(minLength: 0)
            }
        }
        .padding(Slate.Metric.space1)
    }
}

/// The remembered frame: a dashed ghost of the last size behind the window that restores into it.
struct SettingsRememberArt: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
            .strokeBorder(
                Slate.State.accent,
                style: StrokeStyle(lineWidth: Slate.Metric.hairline, dash: [2, 2]),
            )
            .padding(Slate.Metric.space1)
    }
}

// MARK: - SettingsThemeSwatch (theme-gallery card)

/// A theme as a MINIATURE OF ITSELF: its own background, a title strip, three code lines in its own ANSI
/// colours, its caret. otty's theme list settles for the name plus four dots (`theme-list.png`); a terminal
/// theme's real subject is how code looks in it, so the swatch shows code.
///
/// Every colour comes from the `SlateTheme` being previewed — NOT from `Slate.*` (which reads the ACTIVE
/// theme). A swatch that tinted itself with the active theme would render nine identical cards.
struct SettingsThemeSwatch: View {
    let theme: SlateTheme

    var body: some View {
        VStack(spacing: 0) {
            titleStrip
            codeLines
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
    }

    /// The chrome band — the theme's `ground` tone, the one luminance step that IS this design's structure
    /// (MERIDIAN L5), so a swatch shows the chrome/pane relationship as well as the palette.
    private var titleStrip: some View {
        HStack(spacing: Art.gap / 2) {
            ForEach(Array(dotColors.enumerated()), id: \.offset) { _, color in
                Circle().fill(color).frame(width: Art.dot / 2, height: Art.dot / 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Slate.Metric.space1)
        .frame(height: Art.titleStrip)
        .background(theme.ground)
    }

    /// Three "code lines": a prompt run, a mixed line, and a short line with the caret — each a bar in one of
    /// the theme's own ANSI colours.
    ///
    /// Bar widths are FRACTIONS of the measured container, not of a card-width constant. HW review caught why
    /// that matters: the System card packs TWO swatches side by side, so each gets half a card — with
    /// card-width-relative bars the second swatch's content overflowed and was clipped by its neighbour.
    /// Measuring means one swatch renders correctly at any width it's handed.
    private var codeLines: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(alignment: .leading, spacing: Art.gap) {
                line(fractions: [0.22, 0.34], colors: [ansi(2), ansi(4)], width: width)
                line(fractions: [0.16, 0.28, 0.2], colors: [ansi(5), theme.textPrimary, ansi(3)], width: width)
                HStack(spacing: Art.gap) {
                    bar(fraction: 0.12, color: ansi(1), width: width)
                    Rectangle()
                        .fill(caretColor)
                        .frame(width: Art.bar, height: Art.bar * 2)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(Slate.Metric.space1)
    }

    private func line(fractions: [CGFloat], colors: [Color], width: CGFloat) -> some View {
        HStack(spacing: Art.gap) {
            ForEach(Array(zip(fractions, colors).enumerated()), id: \.offset) { _, pair in
                bar(fraction: pair.0, color: pair.1, width: width)
            }
            Spacer(minLength: 0)
        }
    }

    private func bar(fraction: CGFloat, color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
            .fill(color)
            .frame(width: width * fraction, height: Art.bar)
    }

    /// The theme's own caret colour, falling back to its foreground (which is what `cursorHex == nil` means).
    private var caretColor: Color {
        Color(paletteHex: theme.cursorHex ?? theme.terminalForegroundHex) ?? theme.textPrimary
    }

    /// The terminal BACKGROUND (`terminalBackgroundHex`), which is what a user recognises a theme by — falling
    /// back to the chrome `face` when a theme ships an unparseable hex.
    private var background: Color {
        Color(paletteHex: theme.terminalBackgroundHex) ?? theme.face
    }

    /// The traffic-light trio, tinted from the theme's own red / yellow / green so even the chrome band carries
    /// the palette.
    private var dotColors: [Color] {
        [ansi(1), ansi(3), ansi(2)]
    }

    /// One ANSI slot as a colour, falling back to the theme's foreground for a short / malformed palette.
    private func ansi(_ index: Int) -> Color {
        guard theme.ansiPalette.indices.contains(index),
              let color = Color(paletteHex: theme.ansiPalette[index])
        else { return theme.textPrimary }
        return color
    }
}

// MARK: - SettingsSymbolArt (the honest fallback)

/// A centred SF Symbol, for choices whose diagram would need more marks than a 40pt card can carry legibly
/// (right-click actions, close-confirmation scopes, launch behaviour). Deliberately NOT the default — a symbol
/// names a choice, a diagram shows it — but better than an unreadable four-mark drawing.
struct SettingsSymbolArt: View {
    let symbol: SFSymbol

    /// Injected by the enclosing card: the SELECTED card's symbol draws in the accent, so the glyph joins the
    /// one selection statement instead of sitting inert inside it.
    @Environment(\.settingsOptionIsSelected) private var isSelected

    var body: some View {
        Image(systemSymbol: symbol)
            .font(.system(size: Slate.Typeface.display / 2))
            .foregroundStyle(isSelected ? Slate.State.accent : Slate.Text.icon)
            .symbolRenderingMode(.hierarchical)
    }
}
#endif

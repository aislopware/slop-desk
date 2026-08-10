// SettingsInk / SettingsType — the SYSTEM colour + type vocabulary the Settings surface is drawn in.
//
// WHY THIS EXISTS: Settings used to paint itself from `Slate.*`, i.e. from whatever seed the TERMINAL
// is wearing. That is right for the workspace — the pane, the rail and the chrome around them are one
// instrument, and the terminal's colour world is their subject. It is wrong for Settings.
// Settings is a stock `Settings` scene in a system-chromed window full of native `Form` / `Toggle` / `Picker` /
// `Stepper` controls: those draw themselves from the OS appearance and the system accent no matter what, so a
// theme-tinted label beside a system-blue switch reads as two apps in one window. A preferences window is
// OS chrome, not product surface — it should look like System Settings.
//
// So every ink here comes from AppKit/UIKit semantic colours (which already track light/dark, increased
// contrast, and the user's accent choice), and every font is a Dynamic-Type text style rather than a fixed
// point size. `Slate.Metric.*` (the 8pt grid, radii, the height ladder) is theme-free geometry and stays.
//
// NO EXCEPTIONS remain. The theme gallery and its `SettingsThemeSwatch` were the one surface allowed to
// paint from a `SlateTheme` — they went with the theme picker (ONE appearance, see `DESIGN.md`), and the
// dead swatch was removed on 2026-08-10. Settings is system semantics end to end; do not add a surface
// here that draws from `Slate.*`.

#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - SettingsInk (system semantic colours)

/// The Settings surface's colour vocabulary — one name per role, every one resolved from an OS semantic
/// colour so the page tracks the system appearance and accent instead of the terminal theme.
///
/// Nonisolated on purpose: unlike the `@MainActor` `Slate.*` accessors, nothing here has app state
/// behind it, so a header helper or a pure preview can use it off the main actor.
enum SettingsInk {
    // MARK: Text

    /// Row titles and primary body copy.
    static var primary: Color { .primary }
    /// Subtitles, captions, inline explanations — the gray second line under a title.
    static var secondary: Color { .secondary }
    /// The faintest legible ink: disabled values, "—" placeholders, section footnotes.
    static var tertiary: Color {
        #if canImport(AppKit)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }

    /// A leading glyph at rest. Same weight as ``secondary`` — an icon rail is a scanning aid, not emphasis.
    static var icon: Color { .secondary }

    // MARK: Selection / interaction

    /// The system accent — the SAME blue (or whatever the user picked in System Settings) the native
    /// `Toggle` and `Picker` in the next row are already using.
    static var accent: Color { .accentColor }
    /// The accent as a selection WASH behind a selected card. Low alpha so the label stays legible in both
    /// appearances.
    static var accentWash: Color { Color.accentColor.opacity(0.12) }
    /// The hover plate under a pointer-tracking card.
    static var hover: Color { Color.primary.opacity(0.06) }
    /// A selected-but-not-accented row plate.
    static var selected: Color { Color.primary.opacity(0.09) }

    // MARK: Lines

    /// A hairline border / separator.
    static var hairline: Color {
        #if canImport(AppKit)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }

    /// A hairline that must stay visible against a filled plate (the active row in a diagram) — the
    /// separator tone is ~3% and vanishes at diagram scale.
    static var strongLine: Color { Color.secondary.opacity(0.45) }

    // MARK: Surfaces

    /// An INSET control surface: the combobox field, a preview card, an option card at rest.
    static var inset: Color {
        #if canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// A floating panel's ground (the font-specimen popover).
    static var ground: Color {
        #if canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// The lit face inside a diagram's window frame.
    static var face: Color {
        #if canImport(AppKit)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    // MARK: Status

    /// Success / permitted / installed.
    static var ok: Color { .green }
    /// A caveat that is not yet a failure.
    static var warn: Color { .orange }
    /// Blocked / denied / failed.
    static var err: Color { .red }
    /// Neutral information.
    static var info: Color { .blue }
}

// MARK: - SettingsType (Dynamic-Type text styles)

/// The Settings surface's type scale, as system TEXT STYLES rather than point sizes — so the page follows the
/// OS text-size setting like every other preferences window, and so no call site has to name a number
/// (`scripts/check-ds-leaks.sh` bans raw `.font(.system(size: N))` for exactly that reason).
enum SettingsType {
    /// Row titles, field text, list values — the default reading size.
    static let body: Font = .body
    /// A slightly reduced label, for controls that sit inside a denser cluster.
    static let label: Font = .callout
    /// The gray second line under a row title, and inline explanations.
    static let subtitle: Font = .subheadline
    /// Footnotes, keycaps, card captions — the smallest legible rung.
    static let caption: Font = .caption
    /// A section header ("NOTIFICATION"), set in caps by ``SlateSettingsSectionHeader``.
    static let sectionHeader: Font = .caption
    /// A large placeholder glyph for an empty page.
    static let placeholderGlyph: Font = .largeTitle
    /// Monospaced body — config keys, paths, the raw-overrides editor, the cursor preview line.
    static let mono: Font = .system(.body, design: .monospaced)
    /// Monospaced at the subtitle rung — a config path that must not crowd its row.
    static let monoSubtitle: Font = .system(.subheadline, design: .monospaced)
}

// MARK: - SettingsMetric (the few places a real POINT SIZE is unavoidable)

/// The measurements a text STYLE cannot express. Two call sites need an actual number rather than a
/// `Font`: `Font.custom(_:size:)` (the "Aa" specimen, which must render in the family being previewed) and
/// the cursor preview's estimated monospace cell. Both read the LIVE resolved `.body` size so they track the
/// system text-size setting instead of freezing at a literal.
enum SettingsMetric {
    /// The point size the system currently resolves `.body` to.
    static var resolvedBodyPointSize: CGFloat {
        #if canImport(AppKit)
        NSFont.preferredFont(forTextStyle: .body).pointSize
        #elseif canImport(UIKit)
        UIFont.preferredFont(forTextStyle: .body).pointSize
        #else
        13
        #endif
    }
}
#endif

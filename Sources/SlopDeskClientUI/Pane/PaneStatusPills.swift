// PaneStatusPills — the pane's status chips, drawn. ONE view over ``PaneStatusPill``
// (`SlopDeskClientCore`), which says what each chip is CALLED, what VoiceOver reads, whether it carries
// an `×` and what kind of plate it stands on.
//
// It used to be three views. `ReadOnlyPill`, `SecureInputPill` and `SyncInputPill` were the same
// HStack — glyph, uppercase word, optional `×`, padding, rounded plate, chip shadow, combined a11y
// element — differing in a word, a symbol, two sentences of copy and a fill. Three copies of one shape
// is how the two `static var fillColor: Color` escape hatches ended up inconsistent (two pills had one,
// the third did not), and it is what an AppKit half would have had to reproduce three times.
//
// The design reference mock places these in a window TITLEBAR's top-right corner
// (`docs/ui-shell/screenshots/readonly-mode.png` and, later, `secure-input.png`). slopdesk has NO
// persistent titlebar — the window chrome is a hover-reveal strip and the pane is a flush, window-level
// surface — so the EQUIVALENT placement is the pane's top-trailing overlay region (the same place the
// ⌘F find bar floats).
//
// WHICH chips are up, and in what order, is ``PaneStatusPillPresentation/visible(_:)``'s — not this
// file's and not the leaf's. `Slate.*` tokens ONLY — raw font / radius / colour literals fail
// `scripts/check-ds-leaks.sh`. No libghostty / Metal / VideoToolbox is touched (CLAUDE.md rule #6):
// these are plain SwiftUI chips driven by the pane model's OBSERVABLE mirrors
// (``TerminalViewModel/readOnlyBadgeActive`` / ``copyModeBadgeActive``), never the
// `@ObservationIgnored` `isReadOnly`/`isCopyMode` flags the renderer's keyDown path reads.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SwiftUI

/// One pane status chip: `🔒 READ ONLY ×`, `🛡 SECURE INPUT`, or `⚠ SYNC INPUT ×`.
///
/// Faithful to `readonly-mode.png` and `secure-input.png`: the read-only chip is compact and SUBTLY
/// FILLED (it blends with the chrome rather than standing out) with a solid padlock and a primary-tone
/// label, then a LIGHTER `×`; the two mode chips are VIVID FILLED plates carrying a white glyph and a
/// white label, with no `×` on secure input.
///
/// `onDismiss` fires from the `×` and is ignored by a chip that has none. The leaf routes it: read-only
/// to ``TerminalViewModel/exitReadOnly()`` (whose `onReadOnlyChanged` hook converges the store's
/// `paneReadOnly` set, so the `×`, the View-menu item, the palette term and the sidebar lock all land on
/// one state) and sync input to ``WorkspaceStore/disarmSyncInput(for:)`` (which disarms the WHOLE tab,
/// so the chip leaves every sibling at once).
struct PaneStatusPillView: View {
    let pill: PaneStatusPill
    var onDismiss: () -> Void = {}

    @State private var closeHover = false

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemSymbol: glyph)
                .font(.system(size: Slate.Typeface.small, weight: glyphWeight))
                .foregroundStyle(ink)
            Text(pill.label)
                .font(.system(size: Slate.Typeface.footnote, weight: labelWeight))
                .tracking(Slate.Typeface.pillTracking)
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
            if let help = pill.dismissHelp { closeButton(help: help) }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(plate, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .overlay(hairline)
        // A small shadow lifts the chip off busy terminal output for legibility.
        .slateShadow(.chip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pill.accessibilityLabel)
        .accessibilityHint(pill.accessibilityHint)
    }

    // MARK: - This renderer's ink ladder

    /// The fixed tones, resolved. THREE LINES, one per named ink — the ``ToastPresentation`` idiom, and
    /// the reason ``PaneStatusPillFill`` is a kind rather than a `Color`: the two vivid tones are
    /// theme-INDEPENDENT on purpose (the shipped themes have `info == accent`, so a palette-derived
    /// security badge would be invisible against the accent — `secure-input.png` is the green-accent
    /// Paper theme yet the pill is the same royal blue), and only a NAME can say that.
    ///
    /// It is `static` and internal so the colour test reads the SAME source the view fills with: a
    /// regression that re-routed a fill through the theme accent fails the test that pins it against the
    /// fixed token.
    ///
    /// THIS TABLE CANNOT DESCEND, and the reason is the layering rather than a judgement call. It
    /// returns a `Color`, `Color` is `SlopDeskSlate`'s, and `SlopDeskSlate` sits ABOVE
    /// `SlopDeskClientCore` — a token pushed down to meet it would make the floor import the ladder
    /// standing on it. So the ink stays a NAME below (``PaneStatusPillInk``) and each renderer keeps
    /// its own four lines: this one to `Color`, the Mac's to `NSColor` off `Slate.Native.Status`.
    ///
    /// That is the ``ToastPresentation`` deal exactly, and it comes with the same obligation: the two
    /// halves are RATCHETED AS A PAIR in `scripts/check-supervisor.sh`, which reads the ink cases out
    /// of the shared enum and fails if either half stops naming one. A third ink added below is then
    /// red in both renderers until both resolve it, which is the only way a "one value, two views"
    /// split does not decay into one view that quietly knows about a role the other has never heard
    /// of.
    static func fillColor(_ ink: PaneStatusPillInk) -> Color {
        switch ink {
        case .security: Slate.Status.secureInput
        case .sync: Slate.Status.syncInput
        }
    }

    /// The chip's plate.
    private var plate: Color {
        switch pill.fill {
        case .chrome: Slate.Surface.raised
        case let .fixed(ink): Self.fillColor(ink)
        }
    }

    /// A chrome plate is DELINEATED by a hairline (it is only a shade off the chrome behind it); a vivid
    /// plate is not (the fill already is the boundary, and a border would only muddy it).
    @ViewBuilder private var hairline: some View {
        switch pill.fill {
        case .chrome:
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline)
        case .fixed:
            EmptyView()
        }
    }

    /// Label and glyph ink: the theme's primary tone on the chrome plate, white on a vivid one.
    private var ink: Color {
        switch pill.fill {
        case .chrome: Slate.Text.primary
        case .fixed: Slate.Text.onAccent
        }
    }

    /// The mark. A solid padlock for the lock (a theme-tinted SF Symbol, NOT the gold 🔒 emoji:
    /// `readonly-mode.png` shows a monochrome dark padlock matching the label weight, which the emoji
    /// can't honour); the lock-SHIELD for secure input, the macOS secure-input idiom; and the
    /// grouped-panes glyph for sync input — the same symbol the palette entry that armed it uses, so the
    /// chip and the command read as one feature.
    private var glyph: SFSymbol {
        switch pill {
        case .readOnly: .lockFill
        case .secureInput: .lockShieldFill
        case .syncInput: .rectangle3Group
        }
    }

    /// A vivid chip carries more weight than a chrome one — it is louder on purpose.
    private var glyphWeight: Font.Weight {
        switch pill.fill {
        case .chrome: .semibold
        case .fixed: .bold
        }
    }

    private var labelWeight: Font.Weight {
        switch pill.fill {
        case .chrome: .medium
        case .fixed: .semibold
        }
    }

    /// The `×` glyph's own ink: LIGHTER than the label on the chrome plate (per the screenshot), but
    /// full white on a vivid one, where a secondary tone would vanish.
    private var closeInk: Color {
        switch pill.fill {
        case .chrome: Slate.Text.secondary
        case .fixed: Slate.Text.onAccent
        }
    }

    // MARK: - The × plate

    /// The `×` close glyph, with the tab row's subtle hover plate. Fires ``onDismiss``.
    private func closeButton(help: String) -> some View {
        Button(action: onDismiss) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(closeInk)
                // ⚠️ 16×16 is UNNAMED and spelled four times across this directory (here, the vi pill's
                // `×`, the hint badge's `×`). It is a proposed `Slate.Metric.glyphPlate` rung.
                .frame(width: 16, height: 16)
                .background(
                    closeHover ? Slate.State.selected : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusSmall),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
        .slateHelp(help)
    }
}
#endif

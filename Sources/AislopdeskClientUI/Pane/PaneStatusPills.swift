// PaneStatusPills — the per-pane status pills that float in the pane's TOP-TRAILING overlay region (E17).
//
// The design reference mock places these in a window TITLEBAR's top-right corner
// (`docs/ui-shell/screenshots/readonly-mode.png` and, later, `secure-input.png`). aislopdesk has NO persistent
// titlebar — the window chrome is a hover-reveal strip and the pane is a flush, window-level surface — so the
// EQUIVALENT placement is the pane's top-trailing overlay region (the same place the ⌘F find bar floats). This
// file is the home for
// those pills: WI-3 ships ``ReadOnlyPill`` (the `🔒 READ ONLY ×` chip); WI-7 adds `SecureInputPill` beside it.
//
// `Slate.*` tokens ONLY — raw font / radius / colour literals fail `scripts/check-ds-leaks.sh`. No libghostty /
// Metal / VideoToolbox is touched (CLAUDE.md rule #6): these are plain SwiftUI chips driven by the pane model's
// OBSERVABLE mirrors (``TerminalViewModel/readOnlyBadgeActive`` / ``copyModeBadgeActive``), never the
// `@ObservationIgnored` `isReadOnly`/`isCopyMode` flags the renderer's keyDown path reads.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

/// The `🔒 READ ONLY ×` pill (E17 ES-E17-1 / WI-3) — shown in the pane's top-trailing overlay while the pane's
/// input gate is armed. Faithful to `readonly-mode.png`: a compact, SUBTLY-FILLED rounded chip (NOT a brightly
/// coloured badge — it blends with the chrome rather than standing out) carrying a solid padlock + the uppercase
/// `READ ONLY` label in the primary text tone, then a LIGHTER `×` close glyph.
///
/// Clicking `×` calls ``onDeactivate`` — ``TerminalLeafView`` wires it to the pane model's
/// ``TerminalViewModel/exitReadOnly()``, whose `onReadOnlyChanged` hook converges the store's `paneReadOnly`
/// set (the single source of truth the pill `×`, the View-menu item, the command-palette term, and the sidebar
/// lock indicator all read), so every entry point lands on one state.
///
/// Visibility is gated by the LEAF, not this view: `readOnlyBadgeActive && !copyModeBadgeActive` — vi / copy
/// mode temporarily hides the pill (its keybindings drive selection, not the shell, so the lock is not needed
/// while it is active), per the spec. The pill reappears when copy mode exits; the lock itself stays on.
struct ReadOnlyPill: View {
    /// Called when the user clicks `×` to release the lock — the leaf routes it to `exitReadOnly()` so the
    /// store's wired `onReadOnlyChanged` clears the convergent `paneReadOnly` set.
    let onDeactivate: () -> Void

    @State private var closeHover = false

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            // The solid padlock — a theme-tinted SF Symbol (NOT the gold 🔒 emoji): `readonly-mode.png` shows a
            // monochrome dark padlock matching the label weight, which the emoji can't honour.
            Image(systemSymbol: .lockFill)
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            Text("READ ONLY")
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .tracking(0.5) // the screenshot's small-caps / uppercase spacing
                .foregroundStyle(Slate.Text.primary)
                .lineLimit(1)
                .fixedSize()
            closeButton
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        // Subtly-filled chip: the inset-control surface + a hairline — distinct from, but not louder than, the
        // chrome behind it (the screenshot's "bordered or subtly filled chip rather than a brightly coloured
        // badge"). A small shadow lifts it off busy terminal output for legibility.
        .background(Slate.Surface.element, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
        .shadow(color: Slate.State.shadow, radius: 4, x: 0, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Read only")
        .accessibilityHint("Disable read-only mode to allow input again")
    }

    /// The `×` close glyph — LIGHTER than the label (per the screenshot), with the `SlateTabRow` close-button's
    /// subtle hover plate. Releases the lock via ``onDeactivate``.
    private var closeButton: some View {
        Button(action: onDeactivate) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.Text.secondary)
                .frame(width: 16, height: 16)
                .background(
                    closeHover ? Slate.State.selected : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusSmall),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
        .slateHelp("Disable read-only")
    }
}

/// The `🛡 SECURE INPUT` pill (E17 ES-E17-4 / WI-7) — shown in the pane's top-trailing overlay while macOS
/// Secure Keyboard Entry is active for the pane (the host is at a no-echo password prompt and Auto Secure
/// Input is on, OR the manual toggle is on) AND the secure-input INDICATOR setting is on. Faithful to
/// `secure-input.png`: a VIVID-BLUE FILLED pill in the FIXED security-blue `Slate.Status.secureInput`
/// (#2D6FE8) — a theme-INDEPENDENT token, NOT the theme-derived `Slate.Status.info`. The pill must stay a
/// constant royal-blue on every theme so it can never collapse into the theme accent: the shipped default
/// Monokai Pro seed has `info == accent == cyan`, which would make a theme-derived security badge invisible
/// against the accent (the screenshot is the green-accent Paper theme yet the pill is the same blue).
/// Carries a WHITE filled lock-shield + the uppercase `SECURE INPUT` label in white.
///
/// Unlike ``ReadOnlyPill`` there is no `×`: secure input is a SAFETY indicator the user does not dismiss with
/// a click (the auto path clears when the password prompt ends; the manual path clears via the Edit-menu /
/// palette toggle). Visibility is gated by the LEAF (`secureInputActive && indicator && !readOnly`) — it is
/// HIDDEN while read-only is on (no input path can fire there, so the secure-input cue is moot), mirroring
/// the spec's "those pills hide under read-only".
struct SecureInputPill: View {
    /// The pill's FIXED fill — the theme-INDEPENDENT security-blue `Slate.Status.secureInput` (#2D6FE8), NOT
    /// the theme-derived `Slate.Status.info`. Exposed as a single source so the view and its colour test read
    /// the SAME token (mirroring `ToastStackView.tint(for:)`): a regression that re-routed the fill back through
    /// the theme accent fails the test that pins this against the fixed token and asserts it ≠ the Monokai accent.
    static var fillColor: Color { Slate.Status.secureInput }

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            // The white lock-shield — `secure-input.png` shows a filled shield-with-lock, the macOS
            // secure-input idiom (NOT the plain padlock the read-only pill uses).
            Image(systemSymbol: .lockShieldFill)
                .font(.system(size: Slate.Typeface.small, weight: .bold))
                .foregroundStyle(.white)
            Text("SECURE INPUT")
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        // VIVID-BLUE FILLED chip in the FIXED security-blue (theme-INDEPENDENT, never the theme accent) — the
        // screenshot's bold royal-blue badge. A small shadow lifts it off busy terminal output.
        .background(Self.fillColor, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .shadow(color: Slate.State.shadow, radius: 4, x: 0, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Secure input")
        .accessibilityHint("Secure keyboard entry is active — other apps cannot read your keystrokes")
    }
}
#endif

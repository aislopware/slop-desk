import CSlopDeskFFI
import SlopDeskSlate

/// The design the renderer draws a block's furniture with, in Slate's own tokens.
///
/// ## Why this is a record and not a drawing
///
/// `rust/slopdesk-termrender/src/chrome.rs` fills the gutter, the divider, the collapse mark and the
/// scrollbar in the same pass as the glyphs. The two other ways to finish that chrome both went
/// wrong: an `AppKit`/`UIKit` layer over the Metal layer lags the present by a frame during a scroll,
/// and streaming rect instances back per frame is marshalling this tree has already measured and
/// rejected. What separates is not who draws but who DECIDES — and this file is the deciding.
///
/// ## Every token is an ON-GLASS one
///
/// This furniture is drawn INSIDE the terminal island, so it reads ``Slate/Native/Terminal`` and
/// never the semantic ``Slate/Native/Text``/``Slate/Status`` tiers: those are solved against the
/// cream ground and would invert on the glass. `DESIGN.md`'s island law also rules out a second
/// opaque tone in here — the divider is a LINE and the hover is a WASH, which is why neither is a
/// filled plate.
@MainActor
enum TerminalChromeAppearance {
    /// The record, resolved against whatever profile ``Slate/theme`` is currently publishing.
    ///
    /// Rebuilt on every settings generation rather than cached: the glass palette is the theme's, so
    /// a profile that ever changes changes this with it, and a cached copy would be the one part of
    /// the island still wearing the old one.
    static var current: SlopDeskTerminalChromeStyle {
        let glass = Slate.theme.glass
        return SlopDeskTerminalChromeStyle(
            // The block seam is the island's own edge tone, at the hairline every other rule in the
            // design is drawn at. A heavier line here would read as a border around each command,
            // which is the per-command card the island law refuses.
            divider: opaque(glass.edge),
            // At rest the gutter is the same edge tone as the divider — the bar SAYS where a block's
            // rows are and says nothing else. The block holding the cursor is the one exception,
            // and it is the accent because "still running" is the only state on this surface worth
            // spending hue on.
            gutter: opaque(glass.edge),
            gutter_active: opaque(glass.accent),
            // The pointer's wash, at the faint rung — the same dose ``Slate/State/accentMuted``
            // spends. A hover has to be findable without becoming a selection, and the next rung up
            // (``Slate/Opacity/wash``) is what a SELECTED thing wears.
            hover: translucent(glass.accent, Slate.Opacity.faint),
            // The collapse mark is metadata, not output, so it takes the quiet on-glass ink rather
            // than the cell foreground: a triangle in the same colour as the text beside it would
            // read as a character the command printed. Opaque, though — `ink2` IS the quiet tier,
            // and dimming text that is already the dim one lands near the 2.3:1 this design has
            // rejected once before. The scrollbar takes the dose instead, because a thumb is a
            // shape and a header is words.
            label: opaque(glass.ink2),
            // The one hue on a finished block, and it is the PROFILE's red (the ANSI slot behind
            // ``Slate/Native/Terminal/err``) rather than ``Slate/Status/err``: the system palette is
            // solved against the cream ground and lands out of family beside the glass. Spent only
            // on the `✗ <code>` — the duration next to it stays `label`, because a slow command is
            // not a failed one.
            status_err: opaque(Slate.theme.terminalErrHex),
            scrollbar: translucent(glass.ink2, Slate.Opacity.muted),
            divider_thickness: Double(Slate.Metric.hairline),
            // Wider than a hairline because it is a MARK and not a rule — at 1pt the resting gutter
            // is indistinguishable from the divider it meets at every block's corner.
            gutter_thickness: Double(Slate.Metric.dividerHoverWidth),
            scrollbar_thickness: Double(Slate.Metric.space1),
            scrollbar_min_height: Double(Slate.Metric.heightControl),
            scrollbar_inset: Double(Slate.Metric.space1),
        )
    }

    /// A 24-bit Slate hex as the door's `0xAARRGGBB`, fully opaque.
    private static func opaque(_ hex: UInt32) -> UInt32 { hex | 0xFF00_0000 }

    /// The same, at one of ``Slate/Opacity``'s rungs.
    ///
    /// Rounded rather than truncated so a rung lands on the byte nearest what it names — 0.6 is 153,
    /// not 152. Clamped because the door reads the high byte verbatim and an alpha that wrapped
    /// would show a transparent thing as opaque.
    private static func translucent(_ hex: UInt32, _ alpha: Double) -> UInt32 {
        let scaled = (alpha * 255).rounded()
        let byte = UInt32(Double.minimum(Double.maximum(scaled, 0), 255))
        return (hex & 0x00FF_FFFF) | (byte << 24)
    }
}

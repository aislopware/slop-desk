// LineHeightMultiplier — the shape of the control `Font → Line Height → Custom` opens.
//
// It is not a row of its own: it is what picking `custom` reveals, so it is conditioned on another
// setting's VALUE and each shell draws it inside its own page. What neither shell may own is the
// SHAPE — the settable range, the granularity, the readout and the two strings — and both did:
//
//   * the Mac's slider was CONTINUOUS, the phone's stepped at 0.05;
//   * `0.8`, `2.0`, `"%.2f×"`, `"Multiplier"` and the 76-character resize note were typed twice.
//
// The STEP is the correct half, and the readout is why. Line height renders as `%.2f×` on both
// halves, so a continuous drag that lands on 1.237 shows `1.24×` — a control whose readout does not
// name the value it stores. It is also the expensive setting on the page: every change re-measures
// the cell and reflows the terminal (the note below says so), which a per-pixel drag pays for once
// per pixel. A closed rung ladder is the app's default answer everywhere else (`Slate.Metric`,
// `Slate.Opacity`, `SettingsCatalog.Ladder`); a continuous multiplier was the exception nobody chose.
//
// ⚠️ Not a ``SettingsCatalog/Ladder`` case, because that table is `&'static` in
// `slopdesk_workspace::settings_catalog` and reached through `slopdesk_settings_ladder` — adding a
// rung there is a Rust change, and until one lands this leaf is the ONE place the shape is written.
// When it does, delete this file and give both call sites the `Ladder` case; do not leave both.

import Foundation

/// The custom line-height multiplier's control shape — one description, two renderers.
package enum LineHeightMultiplier {
    /// The settable range. Below 0.8 the glyphs collide, above 2.0 the rows read as double-spaced.
    package static let range: ClosedRange<Double> = 0.8...2.0

    /// The slider's granularity. Every landing is exactly representable in ``readout(_:)``, which is
    /// what stops the control naming a value it did not store.
    package static let step = 0.05

    /// What the value beside the slider reads as.
    package static func readout(_ value: Double) -> String { String(format: "%.2f×", value) }

    /// The control's own label, beside the slider.
    package static let label = "Multiplier"

    /// What changing it costs, said once. Both halves print it under the slider.
    package static let note = "Changing line height re-measures the cell and reflows the terminal (a resize)."

    /// Snaps a raw value onto the nearest rung and clamps it into ``range`` — the ONE place the step
    /// is applied, so an AppKit slider (which has no `step:`) lands where the SwiftUI one does.
    package static func snapped(_ value: Double) -> Double {
        let rungs = (value / step).rounded()
        let snapped = rungs * step
        return Double.minimum(Double.maximum(snapped, range.lowerBound), range.upperBound)
    }
}

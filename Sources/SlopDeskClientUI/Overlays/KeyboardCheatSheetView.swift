// KeyboardCheatSheetView — the ⌘/ keyboard cheat sheet, THE PHONE'S HALF: a native sheet holding one
// column of category runs, each row pairing the binding's title with its chord set in a KEYCAP.
//
// The Mac's half is an `NSPanel` (``SlopDeskMacUI/MacCheatSheetView``) and the two share no view
// ancestor — docs/56 stage D. What they share they share BELOW the view layer: ``CheatSheetContent``
// carries the rows, the glyph gating and the column deal, so neither half spells the table out and a
// displayed glyph can never drift from the chord the dispatcher actually fires.
//
// ONE COLUMN, and that is the divergence rather than an omission. The Mac's card is 640pt of paper
// summoned over a full workspace and can hold two columns side by side; a phone sheet is a narrow
// strip and an iPad's form sheet is barely wider, so a second column there would be two runs of
// truncated titles. `CheatSheetContent.dealt(_:into:)` takes the count, so asking for one is a real
// answer rather than a special case.
//
// A NATIVE SHEET, not the in-window paper card. The in-window presentation exists because a summoned
// card has to look like it belongs to the workspace it floats over; on a phone there is no workspace
// visible around it — the sheet IS the screen — and the platform's own sheet brings the grabber, the
// swipe-down dismissal and the safe-area insets that a hand-rolled card would have to re-earn.
//
// The keycap is the point of the row: this surface exists to teach keys, and a chord printed as loose
// secondary text is a fact about a key, where a cap is the key.
//
// SEAM discipline: the cheat sheet owns NO state — its rows are the pure content source and its only
// mutation is `closeCheatSheet()` (the Done button / the sheet's own dismissal). ⌘/ is NOT bound here:
// the store's `overlayKeyToggles` owns the chord and drives `cheatSheetVisible`.

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskSlate
import SwiftUI

struct KeyboardCheatSheetView: View {
    /// The single overlay reducer — read-only here (the data source is the static content); the view's
    /// only mutation is `closeCheatSheet()`.
    let coordinator: OverlayCoordinator

    /// The single source the rows render from, dealt into the one column a hand-held sheet has room
    /// for. Going through the deal rather than reading `sections` straight keeps ONE path to the
    /// table, so a section added to the registry cannot appear on one platform and not the other.
    private var sections: [CheatSheetSection] {
        CheatSheetContent.dealt(CheatSheetContent.sections, into: 1).first ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateCardTitle(CheatSheetContent.title) {
                Button("Done") { coordinator.closeCheatSheet() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Slate.Metric.space3) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            SlateCapsLabel(section.title)
                                .padding(.horizontal, Slate.Metric.space2)
                                .padding(.bottom, Slate.Metric.space1)
                            ForEach(section.rows) { row in
                                self.row(row)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.top, Slate.Metric.space2)
                .padding(.bottom, Slate.Metric.space4)
            }
        }
    }

    /// One binding: what it does, and the key that does it. No plate — nothing here is selected, and a
    /// resting row in this sheet is just its two facts.
    private func row(_ row: CheatSheetRow) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(row.title)
                .font(.system(size: Slate.Typeface.base))
                .foregroundStyle(SlateOverlayInk.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Slate.Metric.space2)
            if let glyph = row.glyph {
                SlateKeycap(label: glyph)
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightRow)
    }
}
#endif

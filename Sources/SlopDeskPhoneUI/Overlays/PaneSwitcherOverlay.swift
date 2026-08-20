// PaneSwitcherOverlay — THE PHONE's ⌃⇥ switcher: the Mac's readout, plus the controls a device with no
// modifier to release needs in order to finish the gesture.
//
// ⚠️ WHY THIS FILE IS BACK. The binding row that opens the gesture is `Platform::Both`
// (`rust/slopdesk-workspace/src/binding_rows.rs`, `pane.switcher`), and the palette carries the same row
// as its touch entry point — so the phone HAS opened this gesture all along. What it had was no card:
// `store.paneSwitcher` went non-nil, every pane receded behind ``PaneRecedeScrim`` (which reads that one
// flag through ``PaneFocusPolicy``), and nothing drew, stepped, committed or cancelled. A veiled
// workspace with no way out is not a missing feature, it is a soft lockup, and the earlier reading that
// justified deleting this half — "the phone has no modifier stream, so a second half could never render"
// — was about the OPENING chord, which was never the only way in.
//
// WHAT IT DOES NOT OWN. Every fact on the card is ``PaneSwitcherRowsBuilder``'s and
// ``PaneSwitcherMetrics``'s, exactly as the Mac's is: the rows and their two registers, the ⌘-number and
// the rung past which it stops existing, the width, the height the rows scroll at, the words, and — the
// one decision this half needed and the Mac did not — what a TAP means (``PaneSwitcherRowsBuilder/walk(to:in:)``).
// The Mac's card is `Sources/SlopDeskMacUI/Overlays/MacPaneSwitcher.swift`; no view type crosses between
// them (docs/56 §3), and nothing in this file re-derives a fact that one reads.
//
// THE THREE ANSWERS THIS HALF HAD TO GIVE, since a phone cannot release a ⌃:
//
//   1. COMMIT IS A TAP ON THE ROW. It routes through ``WorkspaceStore/commitPaneSwitcher()`` like every
//      other commit — the walk above is what carries the highlight there first, so the preview unwind
//      and the closed-pane refusal still happen exactly once, in the store.
//   2. A TAP ON THE BACKDROP CANCELS. Every other card in this family dismisses on a tap beside it
//      without acting (``OverlayHostView``'s floor closes the palette, Open Quickly, peek-reply and the
//      global search), and one member where the same gesture ACTS would be the family's worst kind of
//      surprise. The store agrees on its own terms: a forward open highlights the PREVIOUS pane, not the
//      one you are in, so committing a stray tap would teleport a reader out of the pane they were
//      reading — which is precisely why ``WorkspaceStore/commitPaneSwitcherOnModifierRelease()`` refuses
//      to commit a switcher nothing armed. Same argument, same answer.
//   3. STEPPING IS A BUTTON. ⇥ needs a hardware keyboard, and this app's rule for a chord-only
//      affordance on the phone is a TAP FALLBACK — the same move ``OpenQuicklyView``'s per-row `⌘K`
//      ellipsis makes. ⇥ moves the card's one highlight rather than acting on a row, so its fallback
//      lives on the card's title bar rather than on a row. No swipe: this family's floor is built out
//      of real `Button`s on purpose (see ``SlateClickTarget``), and a gesture recogniser here would be
//      a vocabulary of one.
//
// ⌨️ THE HARDWARE KEYBOARD'S PATH IS NOT THIS FILE'S, AND FOR A WHILE IT DID NOT EXIST. An earlier
// revision of this header claimed ⌃⇥ on an iPad "reaches the focused terminal's interceptor, resolves to
// `.paneSwitcher` and steps the store — that is what already works". It did not. `pane.switcher` is
// `chord: nil` in ``WorkspaceBindingRegistry`` on purpose (one row cannot mean open/step/commit, and a
// ⌃-only chord has no place in a table whose §5 invariant is "every chord carries ⌘ or ⌥"), so ⌃⇥ resolved
// to nothing, fell through to the key encoder and typed a literal `0x09` into the shell — while Esc,
// Return and the arrows walked past this card into the PTY behind it, because this card takes no keyboard
// focus and nothing else was asking.
//
// It is `TerminalInputHost.takesPaneSwitcherKey` that claims those keys now, one rung above the pane's own
// copy/hint mode, exactly as the Mac's `WorkspaceKeyDispatcher.consumePaneSwitcher` claims them above its
// chord table. WHICH verb a press is is ``PhoneKey/paneSwitcherKey(_:isOpen:)``. The card still takes no
// keyboard focus and still cannot take one away; what changed is that the responder that HAS focus now
// knows this card is up. Nothing here touches ``WorkspaceStore/commitPaneSwitcherOnModifierRelease()``,
// which stays the Mac's commit and the iPad's the day a modifier stream reaches it — the responder opens
// an UNARMED walk precisely because UIKit delivers no press for a bare modifier, so there is no ⌃ release
// to commit on.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

struct PaneSwitcherOverlay: View {
    /// The live store — the rows are resolved off it, and all three endings of the gesture are its own
    /// verbs. This view adds none.
    let store: WorkspaceStore
    /// The live gesture, unwrapped by the presenter so this layer exists only while the walk does.
    let switcher: PaneSwitcher

    var body: some View {
        // The container is the WINDOW (this layer is a full-bleed overlay on the root), which is what
        // both measurements are taken against — the same relationship the Mac's panel has to its host
        // window.
        GeometryReader { proxy in
            ZStack {
                // A `Button`, not a tap gesture — see ``SlateClickTarget``. It CANCELS (note 2 above).
                SlateClickTarget { cancel() }
                card(container: proxy.size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The rows, rebuilt on every step because the store's ring is the source. The ring itself is frozen
    /// for the gesture, so a step moves the plate rather than reordering anything.
    private var rows: [PaneSwitcherRow] {
        PaneSwitcherRowsBuilder.rows(for: switcher, store: store)
    }

    // MARK: - The card

    private func card(container: CGSize) -> some View {
        let model = rows
        return VStack(alignment: .leading, spacing: 0) {
            SlateCardTitle(PaneSwitcherCopy.title) { stepControls }
            list(model, container: container)
        }
        .frame(maxWidth: PaneSwitcherMetrics.compactWidth(container: container.width))
        .slatePaperCard()
        // The card must never run out of a small window; this is the margin it keeps.
        .padding(Slate.Metric.space4)
    }

    /// The rows, or the honest empty line when the ring outlived its panes.
    ///
    /// The list is given an EXACT height (``PaneSwitcherMetrics/listHeight(rows:rowHeight:container:)``)
    /// rather than a `maxHeight`, because a `ScrollView` claims every point it is offered — see that
    /// function for the two-row card that stood 70% of the screen tall. The card's own bottom margin
    /// therefore rides OUTSIDE the scroll view: inside it the content would exceed that exact frame by
    /// exactly the margin, and a card with nothing to scroll would scroll.
    @ViewBuilder
    private func list(_ model: [PaneSwitcherRow], container: CGSize) -> some View {
        if model.isEmpty {
            SlateNoResultsLine(message: PaneSwitcherCopy.noPanes, ink: SlateOverlayInk.tertiary)
                .padding(.bottom, Slate.Metric.space3)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model) { row($0) }
                    }
                }
                .frame(height: PaneSwitcherMetrics.listHeight(
                    rows: model.count, rowHeight: Slate.Metric.heightRowStacked,
                    container: container.height,
                ))
                .padding(.bottom, Slate.Metric.space3)
                // Keeps the marked row on screen as the walk passes the fold — the same job the Mac's
                // `revealHighlight` does, driven off the store's own index so a step from ANY source
                // (⌃⇥, the step buttons) scrolls the same way.
                .onChange(of: switcher.highlightIndex) { _, _ in
                    guard let id = model.first(where: \.isHighlighted)?.id else { return }
                    withAnimation(Slate.Anim.smallFade) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    // MARK: - One row

    /// One candidate: what the pane is, where it lives, and the ⌘-key that reaches it directly.
    ///
    /// Nothing here is coloured — the highlight is a lifted plate and a heavier title, the house rule
    /// that a readout marks importance with LIGHT and WEIGHT rather than hue.
    private func row(_ model: PaneSwitcherRow) -> some View {
        HStack(spacing: Slate.Metric.space3) {
            VStack(alignment: .leading, spacing: 0) {
                Text.nerdAware(model.title, size: Slate.Typeface.body)
                    .font(.system(
                        size: Slate.Typeface.body, weight: model.isHighlighted ? .medium : .regular,
                    ))
                    .foregroundStyle(
                        model.isHighlighted ? SlateOverlayInk.primary : SlateOverlayInk.secondary,
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let place = placeLine(model) {
                    place
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(SlateOverlayInk.tertiary)
                        .lineLimit(1)
                        // Truncate the place from the HEAD: a deep path's LAST components are the ones
                        // that say where the pane actually is.
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: Slate.Metric.space2)
            // Absent past ⌘9, where the chord does not exist (the app binds ⌘1–9 only) — an unpressable
            // key drawn on a row is a lie.
            if model.number <= PaneSwitcherRowsBuilder.highestShortcut {
                SlateKeycap(label: "⌘\(model.number)", lit: model.isHighlighted)
            }
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: Slate.Metric.heightRowStacked)
        .frame(maxWidth: .infinity, alignment: .leading)
        .slateSelectionPlate(model.isHighlighted)
        // The plate keeps its own inset from the card's edge, and the row's text lands where the
        // palette's and Open Quickly's does — one list anatomy across the family's cards.
        .padding(.horizontal, Slate.Metric.space2)
        .contentShape(Rectangle())
        // The click is the row itself (WRAPPED, not overlaid), the family's own row idiom.
        .slateRowButton { commit(model) }
        .id(model.id)
    }

    /// The PLACE line, spliced into ONE `Text` so its two halves flow and truncate together: the project
    /// a shade heavier, then the sub-path under it in the plain weight. WEIGHT rather than ink, because
    /// both halves are equally quiet next to the identity — what differs is which of them the eye should
    /// catch running down a column of rows.
    ///
    /// A pane with no project (a video pane, a shell whose cwd has not landed) shows its note alone
    /// rather than an empty lead-in; a pane with neither draws no second line at all.
    private func placeLine(_ model: PaneSwitcherRow) -> Text? {
        let size = Slate.Typeface.footnote
        guard let project = model.project else {
            return model.note.map { Text.nerdAware($0, size: size) }
        }
        let head = Text.nerdAware(project, size: size).fontWeight(.medium)
        guard let note = model.note else { return head }
        return .spliced([head, Text.nerdAware("\(PaneSwitcherCopy.placeSeparator)\(note)", size: size)])
    }

    // MARK: - The step controls

    /// ⇥ and ⇧⇥, for a reader with no keyboard to press them on.
    ///
    /// The SAME control the in-pane find bar steps its matches with (``SlatePlateButton``, `.chevronUp` /
    /// `.chevronDown`) — which is not a coincidence to be resisted but the whole point: "walk the mark to
    /// the next one" is one verb in this app and it already has a shape. Chevrons rather than keycaps: a
    /// cap says "press this key", and on a phone that key is not there — the same honesty the row's own
    /// ⌘-number keeps when it disappears past ⌘9. UP moves the mark up the list and DOWN moves it down,
    /// so the reader is told where the mark GOES rather than which way an invisible frozen ring runs.
    ///
    /// The tint is the overlay family's neutral ink rather than the control's workspace default: this is
    /// a card floating over coloured work, and ``SlateOverlayInk`` is why nothing on it wears the
    /// profile's greys.
    private var stepControls: some View {
        HStack(spacing: Slate.Metric.space1) {
            SlatePlateButton(
                symbol: .chevronUp, help: PaneSwitcherCopy.stepBackward, tint: SlateOverlayInk.secondary,
            ) {
                step(forward: false)
            }
            SlatePlateButton(
                symbol: .chevronDown, help: PaneSwitcherCopy.stepForward, tint: SlateOverlayInk.secondary,
            ) {
                step(forward: true)
            }
        }
    }

    // MARK: - The gesture's three endings

    /// Move the highlight one step. ``WorkspaceStore/openOrStepPaneSwitcher(forward:armedByModifier:)``
    /// STEPS an open switcher and ignores the arming flag while doing so, so a phone step cannot disarm
    /// a gesture a held modifier opened.
    private func step(forward: Bool) {
        // A tap that lands after the gesture already ended must do NOTHING. Without this guard the same
        // call would OPEN a fresh switcher — and the commit below would then land on a pane the reader
        // never aimed at.
        guard store.paneSwitcher != nil else { return }
        store.openOrStepPaneSwitcher(forward: forward, armedByModifier: false)
    }

    /// Walk the highlight onto the tapped row, then commit through the store's ONE commit door. HOW FAR
    /// and WHICH WAY is ``PaneSwitcherRowsBuilder/walk(to:in:)``'s; a `nil` walk means the ring no longer
    /// holds that pane, which is a no-op rather than a guess.
    ///
    /// The walk is measured against the LIVE gesture rather than the one this body rendered from: a ⌃⇥
    /// can arrive between the draw and the tap, and a walk counted off a stale highlight would land the
    /// commit that many rows past the one under the finger. A gesture that ended in the same gap leaves
    /// nothing to walk, and the tap does nothing — never opening a fresh switcher to commit.
    private func commit(_ model: PaneSwitcherRow) {
        guard let live = store.paneSwitcher,
              let walk = PaneSwitcherRowsBuilder.walk(to: model.id, in: live)
        else { return }
        for _ in 0..<walk.steps {
            store.openOrStepPaneSwitcher(forward: walk.forward, armedByModifier: false)
        }
        store.commitPaneSwitcher()
    }

    /// Abandon the walk, leaving the active pane — and any pane the preview walked through — untouched.
    private func cancel() {
        store.cancelPaneSwitcher()
    }
}
#endif

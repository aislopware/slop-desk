// InstrumentChip — the transient notice value + the ONE capsule both notice chips wear, plus the
// on-glass instrument shell the divider's live readout still uses.
//
// The copy receipt proved the shape: a high-frequency or invisible action gets a small fade-only chip —
// never a toast card (icon + X + body reads as spam and can occlude the prompt line). That is unchanged.
// What changed (2026-08-11) is the MATERIAL: the chip used to be drawn on the glass in the instrument
// caps register and was measured at 1.63 : 1 plate / 2.19 : 1 label, unfixable inside a 3.56 : 1 band.
// It is now PAPER in the floating family's voice — see ``SlatePaperCapsule`` for the whole argument.
//
// Two pieces, one idea each — the third, ``ChipNotice``, went to `SlopDeskClientCore` with the rest
// of the client's presentation logic (docs/56): the wording of a cue is not a drawing decision.
//   * ``NoticeCapsule`` — the ONE rendered form, so `CopyReceiptChip` and `NoticeChip` can never drift
//     apart in type, ink, spacing or surface.
//   * ``InstrumentChipShell`` — what is LEFT of the old on-glass treatment: the divider's ratio readout
//     alone. It did not move because it is not a notification (see its own note).
//
// `Slate.*` tokens only (the ds-leaks ratchet).

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskSlate
import SwiftUI

// MARK: - NoticeKeycap (a chord INSIDE a running sentence)

/// The chord as a pressable object: the system face, semibold, on ``SlateOverlayInk/plate`` behind a
/// hairline at the small corner — ``SlateKeycap``'s voice, sized to a TEXT LINE instead of to a 24pt
/// control row.
///
/// ⚠️ It is not `SlateKeycap` itself, and the reason is dimensional. That cap is built for a LIST ROW —
/// ``Slate/Metric/heightControl`` tall, so a column of shortcuts in the palette aligns — and dropping it in
/// here inflates the capsule to ~40pt, at which point the chip stops being a chip. Two things are shared
/// deliberately and two diverge deliberately: the FACE and the PLATE are the same (a key is a key
/// everywhere, and never mono — `DESIGN.md`), while the height follows the line and the ink goes up a rung.
///
/// The ink is ``SlateOverlayInk/primary``, above the words on either side of it, because in this sentence
/// the chord IS the answer — the label frames it and the verb after it only says what pressing does. It is
/// also why a notice carrying a cap drops the `·`: the cap is already a boundary object, and a dot beside
/// it is a second separator doing the first one's job.
struct NoticeKeycap: View {
    let chord: String

    var body: some View {
        Text(chord)
            .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
            .foregroundStyle(SlateOverlayInk.primary)
            .padding(.horizontal, Slate.Metric.space1)
            .background(SlateOverlayInk.plate, in: .rect(cornerRadius: Slate.Metric.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .strokeBorder(SlateOverlayInk.hairline, lineWidth: Slate.Metric.hairline)
            }
    }
}

// MARK: - NoticeCapsule (the ONE rendered form of a transient notice)

/// `label · detail` on the floating family's paper capsule — the single view behind BOTH notice chips, so
/// the copy receipt and every `ChipNotice` can never drift apart.
///
/// HIERARCHY IS SIZE AND WEIGHT IN ONE VOICE, never ink alone. The old chip set both halves at the same
/// size, in the same face, at the same weight, and asked COLOUR to carry the whole distinction — which is
/// how a label at 2.19 : 1 could read as "designed" rather than as broken. The rest of the app had already
/// left that behind (``SlateCardTitle``, the notification card's headline); this chip is the last place
/// that had not had the pass.
///
/// The DETAIL is the dominant half, and that is the same call in every notice this family carries: the
/// count is what answers "did I get the whole thing?", the chord is what answers "how do I undo that?",
/// the breadcrumb is what answers "where am I now?". The label is the frame around the answer, so it takes
/// the quieter rung — quiet, at 6.99 : 1, rather than illegible at 2.19.
struct NoticeCapsule: View {
    /// The event, sentence case ("Copied", "Tab closed") — the frame around the answer.
    let label: String
    /// The chord being offered, drawn as a ``NoticeKeycap``; `nil` ⇒ no key to press.
    var keycap: String?
    /// The answer itself ("1,204 characters"), or — when a `keycap` carries the answer — the verb that
    /// completes the sentence around it ("reopens"). Empty ⇒ the label stands alone.
    let detail: String
    /// The full one-string form for VoiceOver (the value type's own `accessibilityText`).
    let accessibility: String

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Text(label)
                .font(.system(size: Slate.Typeface.base))
                .foregroundStyle(SlateOverlayInk.secondary)
            if let keycap {
                NoticeKeycap(chord: keycap)
            } else if !detail.isEmpty {
                // The dot appears ONLY without a cap — a keycap is its own boundary, so a dot beside one
                // is a second separator doing the first one's job.
                Text("·")
                    .font(.system(size: Slate.Typeface.base))
                    .foregroundStyle(SlateOverlayInk.tertiary)
            }
            if !detail.isEmpty {
                // With a cap the emphasis has already been spent ON the cap, so the trailing verb drops to
                // the label's rung and the sentence has ONE hero. Without one, the detail IS the answer.
                Text(detail)
                    .font(.system(
                        size: Slate.Typeface.base, weight: keycap == nil ? .semibold : .regular,
                    ))
                    .foregroundStyle(keycap == nil ? SlateOverlayInk.primary : SlateOverlayInk.secondary)
            }
        }
        .lineLimit(1)
        // The capsule is sized by its content and never by the column: a notice that stretched to a shared
        // width would announce how much it is NOT saying (the toast card's fixed width is the opposite
        // case — a stack of multi-line cards whose ragged edges would read as damage).
        .fixedSize()
        .slatePaperCapsule()
        .accessibilityLabel(accessibility)
    }
}

// MARK: - NoticeChip (the generic window-level chip view)

/// The generic twin of `CopyReceiptChip`: the shared capsule, fade-only, dwell keyed on the notice epoch.
/// Hit-transparent at the mount site (`IslandChipStack`).
struct NoticeChip: View {
    let notice: ChipNotice
    /// Called when the dwell elapses — the owner clears its notice, unmounting through the mount fade.
    let onExpire: () -> Void

    var body: some View {
        NoticeCapsule(
            label: notice.label, keycap: notice.keycap, detail: notice.detail,
            accessibility: notice.accessibilityText,
        )
        // Dwell timer, keyed on the notice epoch: a successor notice retargets the chip and restarts it.
        // A CANCELLED sleep must NOT expire — cancellation means a newer notice owns the chip or the chip
        // unmounted; calling `onExpire` then would kill the successor's dwell (the CopyReceiptChip rule).
        .task(id: notice.epoch) {
            guard await (try? Task.sleep(for: notice.dwell)) != nil else { return }
            onExpire()
        }
    }
}

// MARK: - InstrumentChipShell (the ONE shared chip treatment)

/// The on-glass instrument shell: instrument small/medium + tracking over a raised surface with a hairline
/// and the small lift shadow that keeps a plate legible over busy terminal output (the ReadOnlyPill
/// treatment).
///
/// ⚠️ ITS ONLY REMAINING MOUNT IS THE DIVIDER'S LIVE RATIO READOUT (`PaneDivider`), and that is deliberate.
/// The notice family left this shell for paper in 2026-08-11 because its band could not hold three legible
/// steps (``SlatePaperCapsule``); the ratio readout did not follow, because it is not a notification. It is
/// a live instrument readout under the pointer DURING a drag — feedback at the trigger, on the surface
/// being dragged, gone when the gesture ends — and it never faced the legibility problem the notices did:
/// its numbers are set in `Text.primary` (white on the plate, 9.16 : 1), not in the profile's comment ink.
/// A cream capsule blooming under the cursor mid-drag would also be exactly the glare the notices are
/// small and short-lived enough to avoid.
///
/// ⚠️ ON-GLASS VOCABULARY (``Slate/Terminal``), not the semantic chrome tiers — the rule for anything drawn
/// inside the island. The semantic set is pinned on the LIGHT side only (see ``Slate/Text``), so on the
/// glass it drew `#585751` ink on a `.quaternarySystemFill` plate over `#22212C`: a chip that was there but
/// unreadable (user-reported 2026-08-09). The glass keeps its profile palette under either OS appearance,
/// so its own ink/edge is the only set that cannot invert against it.
struct InstrumentChipShell: ViewModifier {
    let accessibility: String

    func body(content: Content) -> some View {
        content
            .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .medium))
            .tracking(Slate.Typeface.instrumentTracking)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .background(Slate.Terminal.raised, in: .rect(cornerRadius: Slate.Metric.radiusControl))
            // ⚠️ ``Slate/Terminal/rim``, NOT `edge`. `edge` and `raised` are the SAME profile tone
            // (the selection fill), so this border used to be `#454158` drawn on a `#454158` plate —
            // literally invisible, which left `COPIED · N CHARS` and `TAB CLOSED · ⇧⌘T REOPENS`
            // floating unbounded over the terminal output (user-reported 2026-08-10). The rim is the
            // plate lifted toward the profile's ink: on a DARK surface a border must be LIGHTER than
            // what it bounds, the mirror of the light side's rule.
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                    .strokeBorder(Slate.Terminal.rim, lineWidth: Slate.Metric.hairline),
            )
            .slateShadow(.chip, color: Slate.State.overlayShadow)
            .accessibilityLabel(accessibility)
    }
}
#endif

// ClipboardConfirmCard — THE PHONE's approve/deny surface for the three clipboard questions.
//
// The Mac draws the same three questions as one `NSAlert` (``SlopDeskMacUI/PasteProtectionSheet``); this
// is the phone's renderer of the same answer. What the halves share is ``ClipboardConfirmPresentation``
// — the heading, the affirmative button's word, the bullets-or-reason branch and the defused preview, all
// of them `slopdesk_terminal::paste`'s — and the LAYOUT is the only divergence: an alert's single
// informative string over there, a card with the dangers as rows and the payload on its own plate here.
//
// ⚠️ WHY THIS FILE EXISTS AT ALL. Until it did, the phone half of the embedder auto-approved an unsafe
// paste AND an OSC-52 clipboard READ, and silently DROPPED an OSC-52 write it had been told to ask about
// — three settings the phone showed in Settings ▸ Controls and did not honour, which is worse than not
// offering them: `clipboard-read = ask` read as Allow and `clipboard-write = ask` as Deny, on the same
// account, on the same mesh, depending only on which device you happened to pick up. Every one of the
// three is a user's decision now, on both halves.
//
// IT IS AN IN-WINDOW CARD, NOT A `.sheet`, and that is the one place this surface parts from the family's
// other summoned members deliberately rather than by inheritance. A sheet is presented by the SYSTEM's
// modal stack, and that stack silently declines a second presentation while one is up — Connect being
// open, or Settings, would have dropped the presentation on the floor with libghostty still holding the
// request, which is a hang rather than a wrong answer. This surface is not summoned by the user, it is
// RAISED BY A PROGRAM at a time nobody chose, so it may not depend on nothing else being up.
//
// THE FLOOR ABSORBS AND DOES NOT DISMISS. Every other card in the family floats on a dismiss floor,
// because a picker you summoned by accident should cost one tap to be rid of. A tap beside THIS card is
// not an answer to "may this program read your clipboard?", so it does nothing at all — the two buttons
// are the only exits, exactly as an `NSAlert` has no click-away either. The floor is still a real control
// so the terminal underneath cannot be reached and typed into while the question is up.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SwiftUI

struct ClipboardConfirmCard: View {
    /// The mailbox the libghostty embedder files into. A singleton by default because its writer is a C
    /// callback that holds a surface pointer and nothing else; injectable so a probe can drive it.
    let requests: ClipboardConfirmRequests

    init(requests: ClipboardConfirmRequests = .shared) {
        self.requests = requests
    }

    var body: some View {
        // Only the OLDEST unanswered question is on screen. A second arriving behind it waits rather
        // than replacing it — see ``ClipboardConfirmRequests`` for why replacing would be the same
        // deciding-for-the-user this surface exists to stop.
        ZStack {
            if let pending = requests.current {
                // A `Button` rather than a tap gesture, for the reason ``SlateClickTarget`` gives — but
                // with NO action: it is here to absorb the tap, not to answer with it.
                SlateClickTarget {}
                card(pending)
                    // The next question CROSSFADES rather than mutating the card in place: without the
                    // beat, heading, bullets and preview all change in one frame and it reads as the
                    // same question being edited rather than as the next one arriving. Same rule the
                    // peek card's advance follows.
                    .id(pending.id)
                    .transition(.opacity)
            }
        }
        // Always mounted (so an arriving question fades in rather than re-mounting the layer) and
        // therefore explicitly deaf while there is nothing to answer — the same discipline the toast
        // column keeps one overlay down.
        .allowsHitTesting(requests.current != nil)
        .animation(Slate.Anim.smallFade, value: requests.current?.id)
    }

    // MARK: - The card

    private func card(_ pending: ClipboardConfirmRequests.Pending) -> some View {
        let reading = pending.reading
        return VStack(alignment: .leading, spacing: 0) {
            SlateCardTitle(reading.title) {
                // The one hue on this card, and it is a status rather than decoration: the Mac's alert
                // is `.warning` styled, and this is that style said in the phone's vocabulary.
                Image(systemSymbol: .exclamationmarkTriangleFill)
                    .font(.system(size: Slate.Typeface.body))
                    .foregroundStyle(Slate.StatusInk.warn)
            }

            VStack(alignment: .leading, spacing: Slate.Metric.space3) {
                // Exactly one of these two draws — the shared reading empties the other, so this is a
                // rendering of that decision rather than a second copy of it.
                if !reading.dangers.isEmpty {
                    VStack(alignment: .leading, spacing: Slate.Metric.space2) {
                        ForEach(reading.dangers, id: \.self) { danger in
                            dangerRow(danger)
                        }
                    }
                } else if !reading.reason.isEmpty {
                    Text(reading.reason)
                        .font(.system(size: Slate.Typeface.body))
                        .foregroundStyle(SlateOverlayInk.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !reading.preview.isEmpty {
                    previewBlock(reading.preview)
                }
            }
            .padding(.horizontal, Slate.Metric.space4)
            .padding(.bottom, Slate.Metric.space4)

            // Esc denies and ↩ affirms through the buttons' native roles — the same two keys the Mac's
            // alert binds, for anyone driving an iPad from a hardware keyboard.
            SlateCardFooter(
                confirmTitle: reading.affirmative,
                onCancel: { requests.answer(pending.id, allow: false) },
                onConfirm: { requests.answer(pending.id, allow: true) },
            )
        }
        .frame(maxWidth: Slate.Metric.cardFormWidth)
        .slatePaperCard()
        // The card must never run out of a small window; this is the margin it keeps.
        .padding(Slate.Metric.space4)
    }

    /// One flagged danger. The bullet is ``ClipboardConfirmPresentation/bullet`` rather than a glyph
    /// typed here, so this list and the Mac's cannot come to look like different lists.
    private func dangerRow(_ danger: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space2) {
            Text(ClipboardConfirmPresentation.bullet)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(SlateOverlayInk.tertiary)
            Text(danger)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(SlateOverlayInk.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The payload, already defused by the shared reading (length-capped, control characters in caret
    /// notation) — so the escape being warned about cannot run inside the warning. Set in the instrument
    /// face because it is bytes rather than prose, on the sunk field plate because it is a quotation of
    /// something rather than something this card is saying, and scrolled because the cap is generous
    /// enough to outgrow a phone.
    private func previewBlock(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            SlateCapsLabel(ClipboardConfirmPresentation.previewCaption)
            ScrollView {
                Text(preview)
                    .font(Slate.Typeface.instrument(Slate.Typeface.body))
                    .foregroundStyle(SlateOverlayInk.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Slate.Metric.heightDrawer)
            .slateFieldPlate()
        }
    }
}
#endif

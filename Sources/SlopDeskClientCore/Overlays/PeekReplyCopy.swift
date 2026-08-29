// PeekReplyCopy — the three words on the peek card's CONTROLS, which no reading carries.
//
// The card's prose is already shared and already decided on the far side:
// ``SlopDeskWorkspaceModel/PeekReplyPresentation`` reads the header caption, the queue counter, the
// question block and the zero-state line out of `slopdesk_agent::readout` +
// `slopdesk_workspace::peek_reply`, because every one of those depends on something — a status, a
// queue position, whether the agent actually asked anything.
//
// These three do not. A field's placeholder, a send button's spoken name and the caps micro-label over
// the recent-output well are fixed strings belonging to CONTROLS rather than to a reading, so there was
// no record for them to travel in and each stayed where it was drawn — which meant each was typed once
// per shell (``SlopDeskMacUI/MacPeekReplyView``, ``SlopDeskPhoneUI/PhonePeekReplyCardView``). That is a
// translation bug that has already happened: the day one half is reworded the two platforms ship
// different copy for the same control and nothing notices, which is what `shared-vocabulary-ceiling`
// counts (`rust/slopdesk-invariants/src/rules/two_shells.rs`, docs/56 §3).
//
// THEY ARE HERE AND NOT WITH THE REST OF THE CARD'S WORDS because that file is one module down, in
// `SlopDeskWorkspaceModel`, and every string on it comes over the FFI boundary in one crossing. A
// constant with no decision in it has nothing to put on the far side, and adding it to that crossing
// would spend a wire slot to move a literal. What it needs is ONE speller, which is this — the same
// answer ``PanelChromeCopy`` gives for the right panel's two leftover sentences.
//
// ⚠️ "Done" IS NOT HERE, and its absence is deliberate. The card's dismiss button is the platform's own
// verb for the platform's own button — the class `two_shells.rs` names as "the bare system verbs, Done /
// Cancel / Close, which are deliberately NOT merged". A constant behind one of those buys an
// indirection and no agreement.

// Three `String`s and nothing else: this file imports nothing.

/// The peek card's control labels — the words a reading could never have carried.
package enum PeekReplyCopy {
    /// The reply field's placeholder. The ellipsis is the field saying the sentence continues INTO it,
    /// which is the same register the palette's query prompt uses.
    package static let replyPrompt = "Reply…"

    /// The send button's spoken name. The button is a paperplane glyph on both platforms and carries no
    /// title, so this is the ONLY form of it a screen reader can reach.
    package static let sendReply = "Send reply"

    /// The caps micro-label over the recent-output well — the card NAMING a region, in the instrument
    /// voice. One word, because the region below it is the pane's own tail and needs no explaining.
    package static let recentHeading = "Recent"
}

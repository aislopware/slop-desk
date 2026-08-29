// ClipboardConfirmCardView — THE PHONE's approve/deny surface for the three clipboard questions.
//
// The Mac draws the same three questions as one `NSAlert` (``SlopDeskMacUI/PasteProtectionSheet``); this
// is the phone's renderer of the same answer. What the halves share is ``ClipboardConfirmPresentation``
// — the heading, the affirmative button's word, the bullets-or-reason branch and the defused preview, all
// of them `slopdesk_terminal::paste`'s — and the LAYOUT is the only divergence: an alert's single
// informative string over there, a card with the dangers as rows and the payload on its own plate here.
//
// ⚠️ WHY THIS FILE EXISTS AT ALL. Without a reader on ``ClipboardConfirmRequests``, the phone half of the
// embedder files a question NOBODY CAN ANSWER: libghostty holds the request and the paste never
// completes, so a `clipboard-read = ask` profile hangs rather than asking. Before that reader existed at
// all the same three settings were silently mis-honoured — an unsafe paste and an OSC-52 READ
// auto-approved, an OSC-52 WRITE dropped — which is worse than not offering them: the same account on
// the same mesh answered differently depending on which device you picked up. Every one of the three is
// a user's decision now, on both halves.
//
// IT IS AN IN-WINDOW CARD, NOT A PRESENTATION, and that is the one place this surface parts from the
// family's other summoned members deliberately rather than by inheritance. UIKit's modal stack silently
// DECLINES a second `present()` while one is up — a console line, no error, no queue — so Connect being
// open, or the panel, or the cheat sheet, would have dropped the presentation on the floor with
// libghostty still holding the request. That is a hang rather than a wrong answer. This surface is not
// summoned by the user, it is RAISED BY A PROGRAM at a time nobody chose, so it may not depend on
// nothing else being up. It is the TOPMOST child of ``PhoneOverlayLayerView`` for the same reason.
//
// THE FLOOR ABSORBS AND DOES NOT DISMISS. Every other card in the family floats on a dismiss floor,
// because a picker you summoned by accident should cost one tap to be rid of. A tap beside THIS card is
// not an answer to "may this program read your clipboard?", so it does nothing at all — the two buttons
// are the only exits, exactly as an `NSAlert` has no click-away either. The floor is still a real control
// so the terminal underneath cannot be reached and typed into while the question is up.

#if os(iOS)
import QuartzCore
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import UIKit

/// The always-mounted host for the clipboard questions: a floor, at most one card, and the drain that
/// empties ``ClipboardConfirmRequests``.
///
/// ⚠️ ALWAYS MOUNTED, AND THEREFORE EXPLICITLY DEAF while there is nothing to answer. The SwiftUI half
/// spelled that `.allowsHitTesting(requests.current != nil)`; here it is
/// ``UIView/isUserInteractionEnabled``, which takes the whole subtree out of the hit-test walk and hands
/// every touch back to ``PhoneOverlayLayerView``'s passthrough. Mounting is kept so an arriving question
/// FADES IN rather than re-mounting the layer under it.
@MainActor
final class ClipboardConfirmCardView: UIView {
    /// Hand the keyboard back to the active pane once the last question is answered. Bound by the layer
    /// to ``WorkspaceStore/reclaimKeyboardFocusInActivePane()`` — see ``present(_:)`` for why this card
    /// takes the responder in the first place.
    var onDrained: (() -> Void)?

    /// The mailbox the libghostty embedder files into. A singleton by default because its writer is a C
    /// callback that holds a surface pointer and nothing else; injectable so a probe can drive it.
    private let requests: ClipboardConfirmRequests

    /// The absorbing floor. A real control with NO action: it is here to swallow the tap, not to answer
    /// with it. Kept for the life of the view — it costs one clear layer and it must never be the thing
    /// that is missing when a question arrives.
    private let floor: SlateClickTargetView

    /// The card on screen, if any, and the question it is asking. The id is what the reconcile compares:
    /// the SAME question must never be rebuilt (it would restart the fade under the user's finger) and a
    /// DIFFERENT one must always be, because a card mutated in place reads as the first question being
    /// edited rather than as the second one arriving.
    private var card: ClipboardConfirmCard?
    private var shownID: Int?

    init(requests: ClipboardConfirmRequests = .shared) {
        self.requests = requests
        floor = SlateClickTargetView {}
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false
        // Deaf until a question arrives. The first `follow()` writes the live value.
        isUserInteractionEnabled = false

        addSubview(floor)
        NSLayoutConstraint.activate(floor.slateEdges(of: self))
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ A QUESTION CAN ARRIVE BEFORE THIS VIEW IS IN A WINDOW, and that is not a corner case here: the
    /// mailbox's writer is a C callback holding a surface pointer, so an OSC-52 ask filed during the
    /// shell's own construction lands before the layer is mounted. `becomeFirstResponder()` SILENTLY
    /// FAILS off-window — no error, no retry — which would leave that one card's Esc and ↩ dead while
    /// every later card's worked. So the grab is re-attempted at the callback that means "you are now
    /// mountable", the same way ``SlateSearchBarView`` takes its opening focus.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        card?.takeKeyboard()
    }

    // MARK: - The drain

    /// THE ONE READER OF THE MAILBOX. ``ObservationFollow/arm(_:read:apply:)`` is the one spelling of
    /// the re-arm (docs/62 §3.1): the weak owner, the teardown guard and the reads-inside/work-outside
    /// split are all structural there, and the arming call takes the first reading — so there is no
    /// "drain once, then follow" for this view to get in the wrong order.
    private func follow() {
        ObservationFollow.arm(self) { card in
            // Only the OLDEST unanswered question is on screen. A second arriving behind it WAITS
            // rather than replacing it — see ``ClipboardConfirmRequests`` for why replacing would be
            // the same deciding-for-the-user this surface exists to stop.
            card.requests.current
        } apply: { card, pending in
            card.reconcile(pending)
        }
    }

    /// Bring the view into agreement with the mailbox's head. Idempotent for an unchanged head, which is
    /// what lets `follow()` call it on every arm.
    private func reconcile(_ pending: ClipboardConfirmRequests.Pending?) {
        // ⚠️ WRITTEN EVERY PASS, BEFORE THE CARD WORK. A view at `isUserInteractionEnabled == false`
        // takes no touches AT ALL, so the floor stops absorbing the moment this is stale — and a stale
        // `true` is worse: the layer would eat the whole screen with nothing drawn on it.
        isUserInteractionEnabled = pending != nil

        guard pending?.id != shownID else { return }
        shownID = pending?.id
        dismissCurrentCard()
        guard let pending else {
            // The mailbox is empty: the last question has been answered, so the keyboard goes back to
            // whatever the user was typing into.
            onDrained?()
            return
        }
        present(pending)
    }

    /// Fade the outgoing card out and take it off the tree when the fade lands.
    ///
    /// The removal is deferred rather than immediate because the two cards CROSSFADE: without the beat,
    /// heading, bullets and preview all change in one frame and it reads as the same question being
    /// edited. Same rule the peek card's advance follows.
    private func dismissCurrentCard() {
        guard let outgoing = card else { return }
        card = nil
        // Deaf on the way out, so a second tap during the fade cannot reach the buttons of a question
        // that has already been answered.
        outgoing.isUserInteractionEnabled = false
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { outgoing.removeFromSuperview() }
        }
        PaneFade.set(outgoing, shown: false, curve: Slate.Motion.smallFade)
        CATransaction.commit()
    }

    /// Build the card for `pending` and fade it in.
    ///
    /// ⚠️ THE ANSWER IS CAPTURED, NEVER RE-READ. Both closures carry `pending.id` rather than asking the
    /// mailbox for its head at tap time: by then the head may already be the NEXT question, and a
    /// double-tap during the crossfade would answer it with a decision the user made about the previous
    /// one. ``ClipboardConfirmRequests/answer(_:allow:)`` removes before it completes, so answering an
    /// id twice is a no-op rather than a second completion — but only if the id is the right one.
    ///
    /// ⚠️ AND IT TAKES THE RESPONDER, which is what puts ``SlateCardFooterView``'s Esc and ↩ on the
    /// chain. SwiftUI's `.cancelAction` / `.defaultAction` roles reached the window without focus;
    /// UIKit's `keyCommands` are dispatched from the FIRST RESPONDER upwards, so a footer nobody is
    /// focused on publishes chords nothing will ever deliver. Taking it also drops the software keyboard
    /// while the question is up, which is right for the same reason the Mac's alert is app-modal: the
    /// pane underneath is shielded and must not be typed into. ``onDrained`` gives it back.
    private func present(_ pending: ClipboardConfirmRequests.Pending) {
        let made = ClipboardConfirmCard(
            reading: pending.reading,
            onDeny: { [requests] in requests.answer(pending.id, allow: false) },
            onAllow: { [requests] in requests.answer(pending.id, allow: true) },
        )
        card = made
        addSubview(made)

        let wide = made.widthAnchor.constraint(equalToConstant: Slate.Metric.cardFormWidth)
        // Yields to the margins below on a narrow window, exactly as the Mac panel's own width does.
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            made.centerXAnchor.constraint(equalTo: centerXAnchor),
            made.centerYAnchor.constraint(equalTo: centerYAnchor),
            wide,
            made.widthAnchor.constraint(lessThanOrEqualToConstant: Slate.Metric.cardFormWidth),
            // The card must never run out of a small window; this is the margin it keeps.
            made.leadingAnchor.constraint(
                greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: Slate.Metric.space4,
            ),
            made.trailingAnchor.constraint(
                lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -Slate.Metric.space4,
            ),
            made.topAnchor.constraint(
                greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: Slate.Metric.space4,
            ),
            made.bottomAnchor.constraint(
                lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -Slate.Metric.space4,
            ),
        ])

        made.layer.opacity = 0
        PaneFade.set(made, shown: true, curve: Slate.Motion.smallFade)
        made.takeKeyboard()
    }
}

// MARK: - The card

/// One clipboard question, drawn. A value-shaped view: it is built for a reading and never mutated, so
/// the reconcile above is a swap rather than an edit.
@MainActor
final class ClipboardConfirmCard: UIView {
    private let footer: SlateCardFooterView

    init(
        reading: ClipboardConfirmPresentation,
        onDeny: @escaping () -> Void,
        onAllow: @escaping () -> Void,
    ) {
        footer = SlateCardFooterView(confirmTitle: reading.affirmative)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        SlatePaperCardSurface.apply(to: self)
        // VoiceOver may not wander out of a question it has to answer — the same containment the
        // system's own alert gets for free.
        accessibilityViewIsModal = true

        footer.onCancel = onDeny
        footer.onConfirm = onAllow

        // The one hue on this card, and it is a status rather than decoration: the Mac's alert is
        // `.warning` styled, and this is that style said in the phone's vocabulary.
        //
        // ⚠️ ``Slate/Native/StatusInk``, never the system `Status` FILL palette — this is a MARK on
        // paper, and the system's orange measures ~2.1 against the cream where the solved angle passes.
        let warning = UIImageView(image: UIImage(systemSymbol: .exclamationmarkTriangleFill))
        warning.translatesAutoresizingMaskIntoConstraints = false
        warning.tintColor = Slate.Native.StatusInk.warn
        warning.contentMode = .scaleAspectFit
        warning.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: Slate.Typeface.body,
        )
        warning.isAccessibilityElement = false

        let column = UIStackView(arrangedSubviews: [
            SlateCardTitleView(reading.title, trailing: warning),
            Self.body(reading),
            footer,
        ])
        column.axis = .vertical
        column.alignment = .fill
        // NO spacing and no rule between the regions: ``SlateCardTitleView`` and ``SlateCardFooterView``
        // carry the card's padding themselves, and a divider here is the stacked-boxes look the grouped
        // form left behind.
        column.spacing = 0
        addSubview(column)
        NSLayoutConstraint.activate(column.slateEdges(of: self))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The other half of ``SlatePaperCardSurface``'s contract: without a `shadowPath` Core Animation
        // rasterises the alpha channel of the whole layer tree on every composited frame, and this card
        // floats over LIVE terminal output.
        SlatePaperCardSurface.layoutShadow(of: self)
    }

    /// Put the footer's Esc / ↩ on the responder chain — see ``ClipboardConfirmCardView/present(_:)``.
    func takeKeyboard() { footer.becomeFirstResponder() }

    // MARK: - The body

    /// Everything between the title and the footer, on the card's own horizontal padding.
    private static func body(_ reading: ClipboardConfirmPresentation) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Slate.Metric.space3
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Exactly one of these two draws — the shared reading EMPTIES the other, so this is a rendering
        // of that decision rather than a second copy of it. An OSC-52 ask carries no payload to
        // classify, so it always lands on the reason.
        if !reading.dangers.isEmpty {
            let bullets = UIStackView(arrangedSubviews: reading.dangers.map(dangerRow))
            bullets.axis = .vertical
            bullets.alignment = .fill
            bullets.spacing = Slate.Metric.space2
            stack.addArrangedSubview(bullets)
        } else if !reading.reason.isEmpty {
            stack.addArrangedSubview(sentence(reading.reason))
        }

        if !reading.preview.isEmpty {
            stack.addArrangedSubview(previewBlock(reading.preview))
        }

        let host = UIView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(
                equalTo: host.leadingAnchor, constant: Slate.Metric.space4,
            ),
            stack.trailingAnchor.constraint(
                equalTo: host.trailingAnchor, constant: -Slate.Metric.space4,
            ),
            stack.bottomAnchor.constraint(
                equalTo: host.bottomAnchor, constant: -Slate.Metric.space4,
            ),
        ])
        return host
    }

    /// One flagged danger. The bullet is ``ClipboardConfirmPresentation/bullet`` rather than a glyph
    /// typed here, so this list and the Mac's cannot come to look like different lists.
    private static func dangerRow(_ danger: String) -> UIView {
        let dot = UILabel()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.text = ClipboardConfirmPresentation.bullet
        dot.font = .systemFont(ofSize: Slate.Typeface.body)
        dot.textColor = Slate.Native.Overlay.tertiary
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The bullet is punctuation for the line beside it, not a thing to land on.
        dot.isAccessibilityElement = false

        let row = UIStackView(arrangedSubviews: [dot, sentence(danger)])
        row.axis = .horizontal
        // The bullet sits on the FIRST line's baseline, not the wrapped block's centre — the same rule
        // ``SlateWarningRowView`` keeps for its triangle.
        row.alignment = .firstBaseline
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// A line of the card's prose: wrapping, never truncating. A danger cut off at the card's edge is a
    /// danger that did not arrive.
    private static func sentence(_ text: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: Slate.Typeface.body)
        label.textColor = Slate.Native.Overlay.primary
        label.numberOfLines = 0
        return label
    }

    /// The payload, already defused by the shared reading (length-capped, control characters in caret
    /// notation) — so the escape being warned about cannot run inside the warning. Set in the instrument
    /// face because it is bytes rather than prose, on the sunk field plate because it is a quotation of
    /// something rather than something this card is saying, and scrolled because the cap is generous
    /// enough to outgrow a phone.
    private static func previewBlock(_ preview: String) -> UIView {
        let text = UILabel()
        text.translatesAutoresizingMaskIntoConstraints = false
        text.text = preview
        text.font = Slate.Typeface.instrumentNative(Slate.Typeface.body)
        text.textColor = Slate.Native.Overlay.primary
        text.numberOfLines = 0

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = .clear
        scroll.addSubview(text)

        let plate = UIView()
        plate.translatesAutoresizingMaskIntoConstraints = false
        SlateFieldPlateSurface.apply(to: plate)
        plate.addSubview(scroll)

        // ⚠️ THE PLATE IS AS TALL AS ITS TEXT, CAPPED. A `UIScrollView` has no intrinsic size, so the
        // height has to be stated: an equality to the text at `defaultHigh` is what makes a one-line
        // preview a one-line plate, and the required cap is what stops a long one from pushing the
        // buttons off the screen. The cap breaks the equality rather than the layout.
        let natural = plate.heightAnchor.constraint(
            equalTo: text.heightAnchor, constant: SlateFieldPlateSurface.verticalInset * 2,
        )
        natural.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(
                equalTo: plate.topAnchor, constant: SlateFieldPlateSurface.verticalInset,
            ),
            scroll.bottomAnchor.constraint(
                equalTo: plate.bottomAnchor, constant: -SlateFieldPlateSurface.verticalInset,
            ),
            scroll.leadingAnchor.constraint(
                equalTo: plate.leadingAnchor, constant: SlateFieldPlateSurface.horizontalInset,
            ),
            scroll.trailingAnchor.constraint(
                equalTo: plate.trailingAnchor, constant: -SlateFieldPlateSurface.horizontalInset,
            ),
            // The content guide sets the SCROLLABLE extent; the frame guide sets the width the text
            // wraps at. Tying the two on width and leaving height free is what makes this scroll
            // vertically and only vertically.
            text.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            text.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            text.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            natural,
            plate.heightAnchor.constraint(lessThanOrEqualToConstant: Slate.Metric.heightDrawer),
        ])

        let block = UIStackView(arrangedSubviews: [
            SlateCapsLabelView(ClipboardConfirmPresentation.previewCaption), plate,
        ])
        block.axis = .vertical
        block.alignment = .fill
        block.spacing = Slate.Metric.space1
        block.translatesAutoresizingMaskIntoConstraints = false
        return block
    }
}
#endif

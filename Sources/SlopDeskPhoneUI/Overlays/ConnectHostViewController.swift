// ConnectHostViewController — the Connect-to-Host form, as the platform's own sheet (docs/62 stage F).
//
// The UIKit half of the deleted `ConnectHostView`, and the one overlay in this cluster that is NOT a card
// in ``PhoneOverlayLayerView``. Every other summoned surface is a picker you skim and dismiss in a second,
// so each is drawn in-window over the workspace it is about. This one is a FORM you fill in and commit,
// and a form is what a modal is for: the sheet owns the window, so no stray tap into the workspace drops
// it mid-edit, and the dismissal is the platform's (the grabber, the swipe, the safe-area insets) rather
// than a hand-rolled floor. The decision is the user's, taken 2026-08-08, and the Mac's half made the same
// call in AppKit (``SlopDeskMacUI/MacConnectSheet``).
//
// A THIN VIEW OVER ``AppConnection``, which already owns the editable host/port strings, the parse, the
// validation hint and the `connect()` lifecycle. Nothing here re-derives any of it: each field writes
// through on every keystroke so `canConnect` gates the Connect button live, and everything drawn is read
// back inside `withObservationTracking`, so a failed connect re-renders its own reason. What crossed into
// Rust is the WORDS and the one shared decision — ``ConnectForm`` and
// ``ConnectPresentation/shouldCloseAfterConnect(status:)`` — so the two shells cannot drift on either.
//
// ⚠️ THE SHEET DOES NOT TEAR ITSELF DOWN. Cancel, Esc and a successful connect all flip
// `coordinator.connectVisible`, and the shell reconciles the presentation off that flag — the same
// discipline the cheat sheet keeps, and the reason the flag and the sheet can never disagree. ``onDismiss``
// is the other direction, for the dismissals the SYSTEM performs (the swipe), which the coordinator would
// otherwise never hear about because `connectVisible` is `private(set)`.
//
// ⚠️ THE CHORDS ARE DECLARED HERE AND NOT ON THE FOOTER, even though ``SlateCardFooterView`` carries its
// own pair. `keyCommands` are dispatched from the FIRST RESPONDER upwards, and the responder while this
// form is up is the host field — whose chain runs field → its labelled wrapper → the column → this
// controller's view → THIS CONTROLLER. The footer is that field's SIBLING and is never on that path, so
// its copies of Esc / ↩ would never fire. Declared here they always do, and they still route to the same
// two actions the buttons call.
//
// ⚠️ NOTHING PRESENTS THIS YET, and that is a one-line seam in the shell rather than a gap here.
// ``WorkspaceRootViewController`` owns the phone's single presentation slot (UIKit DROPS a second
// `present()` while one is up — a console line, no error, no queue), so it already serialises the panel
// and the cheat sheet through `canStartPresentation`; Connect is a third case in exactly that shape.
// ⚠️ AND THE SAME CHANGE MUST DELETE ``PhoneOverlaySheet/connect``: that case exists only to CLOSE a flag
// with no surface behind it, so leaving it in place would slam this sheet shut in the frame it opened.
//
// The advanced disclosure stays folded: most people keep the default video ports, and a card that opens
// showing four fields asks four questions when it only has two.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class ConnectHostViewController: UIViewController {
    /// Called for a dismissal the SYSTEM performed — the swipe down. Bound by the shell to
    /// `overlay.closeConnect()`, which is the only writer of the coordinator's flag.
    var onDismiss: (() -> Void)?

    private let connection: AppConnection
    private let coordinator: OverlayCoordinator

    private let host = SlateLabeledFieldView(
        label: ConnectForm.hostLabel, prompt: ConnectForm.hostPrompt,
    )
    private let port = SlateLabeledFieldView(
        label: ConnectForm.portLabel, prompt: ConnectForm.portPrompt, mono: true,
    )
    private let mediaPort = SlateLabeledFieldView(
        label: ConnectForm.mediaPortLabel, prompt: ConnectForm.mediaPortPrompt, mono: true,
    )
    private let cursorPort = SlateLabeledFieldView(
        label: ConnectForm.cursorPortLabel, prompt: ConnectForm.cursorPortPrompt, mono: true,
    )

    /// The two video-port fields, folded away by default.
    private let advanced = UIStackView()
    private let chevron = UIImageView()
    private let footer = SlateCardFooterView(confirmTitle: ConnectForm.connectAction)

    /// The validation / failure line's slot. The ROW is rebuilt rather than re-worded, because
    /// ``SlateWarningRowView`` takes its text at `init` — one warning is one view, and swapping it is
    /// cheaper than teaching the shared component a mutable string it has no other caller for.
    private let warningSlot = UIStackView()
    /// What the slot currently says, so an unchanged reason does not rebuild the row (and re-announce
    /// itself to VoiceOver) on every unrelated keystroke.
    private var warningText: String?

    /// The in-flight connect Task. Stored so Cancel and teardown CANCEL it — a fire-and-forget one
    /// outlives the sheet and, when a slow connect finally resolves, dismisses a freshly REOPENED sheet
    /// mid-edit. Belt and braces with the ``OverlayCoordinator/connectGeneration`` guard below.
    private var connectTask: Task<Void, Never>?
    private var generation = 0

    init(connection: AppConnection, coordinator: OverlayCoordinator) {
        self.connection = connection
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    deinit {
        connectTask?.cancel()
    }

    // MARK: - The form

    override func viewDidLoad() {
        super.viewDidLoad()
        // The family's corner and rim, and no shadow — the presentation already casts one.
        SlateSheetSurface.apply(to: view)
        presentationController?.delegate = self

        // Host and port share ONE row — a port is five digits, and a five-digit field the full width of
        // the card asks a question the same size as "which machine?".
        port.widthAnchor.constraint(equalToConstant: Slate.Metric.portFieldWidth).isActive = true
        let headline = pair(host, port)

        // The two video ports are peers, so they share a row the way host/port do.
        advanced.axis = .horizontal
        advanced.alignment = .top
        advanced.distribution = .fillEqually
        advanced.spacing = Slate.Metric.space3
        advanced.translatesAutoresizingMaskIntoConstraints = false
        advanced.addArrangedSubview(mediaPort)
        advanced.addArrangedSubview(cursorPort)
        // ⚠️ HIDDEN, NOT REMOVED. A `UIStackView` gives an arranged subview's space back the moment it is
        // hidden, which is the animatable spelling of the SwiftUI `if` this replaced — and it keeps the
        // two fields alive, so a port typed, folded away and unfolded again is still there.
        advanced.isHidden = true

        warningSlot.axis = .vertical
        warningSlot.alignment = .fill
        warningSlot.translatesAutoresizingMaskIntoConstraints = false

        let body = UIStackView(arrangedSubviews: [headline, disclosure(), advanced, warningSlot])
        body.axis = .vertical
        body.alignment = .fill
        body.spacing = Slate.Metric.space3
        body.translatesAutoresizingMaskIntoConstraints = false

        footer.onCancel = { [weak self] in self?.runCancel() }
        footer.onConfirm = { [weak self] in self?.runConnect() }

        let column = UIStackView(arrangedSubviews: [SlateCardTitleView(ConnectForm.title), body, footer])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Slate.Metric.space4
        column.translatesAutoresizingMaskIntoConstraints = false
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space4, leading: Slate.Metric.space4,
            bottom: 0, trailing: Slate.Metric.space4,
        )
        view.addSubview(column)

        // ⚠️ THE BOTTOM IS AN INEQUALITY AGAINST THE KEYBOARD GUIDE, not against the safe area. This form
        // opens WITH the keyboard up (the host field takes it on appear), and a column pinned to the safe
        // area lays the footer out underneath it — the Connect button would be on screen and untappable.
        // `keyboardLayoutGuide` tracks the dismissed keyboard as the bottom safe-area edge, so the one
        // constraint covers both states.
        let lift = column.bottomAnchor.constraint(
            lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -Slate.Metric.space4,
        )
        lift.priority = .required
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            column.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            lift,
        ])

        // Every keystroke writes through, so `canConnect` and the validation hint answer about what is on
        // SCREEN rather than about what was last committed.
        host.onTextChange = { [connection] text in connection.host = text }
        port.onTextChange = { [connection] text in connection.port = text }
        mediaPort.onTextChange = { [connection] text in connection.mediaPort = text }
        cursorPort.onTextChange = { [connection] text in connection.cursorPort = text }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Seed the fields from the COMMITTED target — this card usually opens on the live host, and a
        // re-edit that started from an empty form would be a trap.
        connection.fillForm(from: connection.target)
        host.text = connection.host
        port.text = connection.port
        mediaPort.text = connection.mediaPort
        cursorPort.text = connection.cursorPort
        // The machine is the first thing anyone edits. Taken HERE rather than in `viewDidLoad`, where the
        // view is not yet in a window and `becomeFirstResponder()` fails silently.
        host.isTakingInput = true
        follow()
    }

    /// The disclosure over the two video ports. The WHOLE row is the target, the way a native disclosure
    /// row is — a hit area the width of two words is a miss waiting to happen.
    private func disclosure() -> UIView {
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = UIImage(systemSymbol: .chevronRight)
        chevron.tintColor = Slate.Native.Overlay.secondary
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: Slate.Typeface.small, weight: .semibold,
        )
        chevron.isAccessibilityElement = false

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = ConnectForm.videoPortsLabel
        label.font = .systemFont(ofSize: Slate.Typeface.base)
        label.textColor = Slate.Native.Overlay.secondary
        label.isAccessibilityElement = false

        let row = SlateRowButton { [weak self] in self?.toggleAdvanced() }
        row.addSubview(chevron)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(
                equalTo: chevron.trailingAnchor, constant: Slate.Metric.space1,
            ),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: Slate.Metric.heightRow),
        ])
        // Said as one thing, with the state in the TRAIT rather than in the words — VoiceOver speaks
        // "expanded" / "collapsed" itself, and a title that said it too would say it twice.
        row.isAccessibilityElement = true
        row.accessibilityLabel = ConnectForm.videoPortsLabel
        row.accessibilityTraits = .button
        return row
    }

    private func pair(_ leading: UIView, _ trailing: UIView) -> UIStackView {
        let row = UIStackView(arrangedSubviews: [leading, trailing])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Slate.Metric.space3
        row.translatesAutoresizingMaskIntoConstraints = false
        // The name field takes the slack; the five-digit one keeps its width.
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return row
    }

    // MARK: - The live read

    /// The one tracked read. ``withObservationTracking(_:onChange:)`` fires ONCE, so the re-arm IS the
    /// subscription and every tracked read has to happen INSIDE the closure. `onChange` runs inside the
    /// mutation, hence the hop; the generation counter drops an arm a later one has superseded.
    private func follow() {
        generation &+= 1
        let generation = generation

        var canConnect = false
        var hint: String?
        var status = ConnectionStatus.disconnected
        withObservationTracking {
            // ⚠️ ALL THREE ARE READ UNCONDITIONALLY, and the precedence is resolved afterwards. Deciding
            // inside the block — `if let hint { … }` — would SHORT-CIRCUIT past `status`, and the arm
            // would then hold no dependency on it: a connect that failed while the form parsed cleanly
            // would change a property nobody is watching, and its reason would never appear.
            canConnect = connection.canConnect
            hint = connection.validationHint
            status = connection.status
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        footer.confirmDisabled = !canConnect
        // The hint WINS over the failure: an unparseable form is a question about what is typed, and a
        // stale failure from the last attempt is not the answer to it. A failed connect leaves the sheet
        // up (see `runConnect`), so the reason is carried here — run through the presenter so it reads as
        // the actionable copy every other connection surface shows, never the raw transport dump.
        if let hint {
            show(warning: hint)
        } else if case let .failed(reason) = status {
            show(warning: ConnectionPresenter.friendlyFailure(reason))
        } else {
            show(warning: nil)
        }
    }

    private func show(warning text: String?) {
        guard text != warningText else { return }
        warningText = text
        for row in warningSlot.arrangedSubviews { row.removeFromSuperview() }
        guard let text else { return }
        warningSlot.addArrangedSubview(SlateWarningRowView(text: text))
    }

    // MARK: - Actions

    override var keyCommands: [UIKeyCommand]? {
        // See the file header: the footer's own pair never reaches the chain the host field starts.
        let confirm = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(runConnect))
        // Off the discoverability sheet — these are the system's own two meanings, and naming them there
        // reads as an app-specific chord the user has to learn.
        confirm.wantsPriorityOverSystemBehavior = false
        return [.slateCancel(action: #selector(runCancel)), confirm]
    }

    private func toggleAdvanced() {
        let folding = !advanced.isHidden
        chevron.image = UIImage(systemSymbol: folding ? .chevronRight : .chevronDown)
        // A `UIStackView` animates a hidden arranged subview's space away for free, so the fold is one
        // property inside the family's standard curve — no height constraint to drive by hand.
        let animator = OverlayMotion.animator(Slate.Motion.standard)
        animator.addAnimations { [advanced, view] in
            advanced.isHidden = folding
            view?.layoutIfNeeded()
        }
        animator.startAnimation()
    }

    /// Validate-then-connect: a no-op unless the form parses (the button is disabled then too), then fire
    /// the app's `connect()`. Never force-unwraps — `canConnect` gates here and `connect()` re-guards the
    /// parse internally. Only a SUCCESSFUL connect closes the sheet: a `.failed` result leaves it up with
    /// the real reason inline, because a dropped sheet whose reason is reachable only through the status
    /// pill is a silent failure. The close is DOUBLE-guarded — the Task is stored and cancelled on
    /// Cancel/teardown, AND the completion only closes if the coordinator's generation still matches the
    /// presentation this Task started under.
    @objc private func runConnect() {
        guard connection.canConnect else { return }
        connectTask?.cancel()
        let generation = coordinator.connectGeneration
        connectTask = Task { [connection, coordinator] in
            await connection.connect()
            guard !Task.isCancelled else { return }
            guard ConnectPresentation.shouldCloseAfterConnect(status: connection.status) else { return }
            coordinator.closeConnect(ifCurrent: generation)
        }
    }

    /// Cancel: kill the in-flight connect Task (its completion must never fire) and flip the flag. The
    /// shell's reconcile is what actually dismisses the sheet.
    @objc private func runCancel() {
        connectTask?.cancel()
        connectTask = nil
        coordinator.closeConnect()
    }
}

extension ConnectHostViewController: UIAdaptivePresentationControllerDelegate {
    /// The swipe. Fires only for a user-driven dismissal — a programmatic `dismiss(animated:)` does not
    /// call it, which is exactly the distinction the shell needs to avoid a re-entrant close.
    func presentationControllerDidDismiss(_: UIPresentationController) {
        connectTask?.cancel()
        connectTask = nil
        onDismiss?()
    }
}
#endif

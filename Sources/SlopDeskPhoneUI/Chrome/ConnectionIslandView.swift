// ConnectionIslandView — the link's surface on the PHONE, in UIKit: one bedless line in the navigation
// toolbar (docs/62 stage F).
//
//   mac-studio    12 ms                  ← who, and how far away
//   mac-studio    12 ms   ▤ 97%  ▨ 3.1G  ← …and what is about to stop the host working
//
// ONE LINE, because a navigation toolbar is one line. The Mac's island carries the machine's pulse under
// the identity on a second row; there is no second row here, so this half carries the pulse on its ALARM
// RUNGS ALONE — ``ConnectionReading/promotedRuns(_:)``. Half of the original argument still holds: a
// toolbar has room for "am I connected, and is it fast", and the ambient question of how hard the host is
// working at rest is the desktop's. The other half did not: a `critical` memory verdict, or a volume with
// nothing left on it, is not ambient — it is the reason the next build fails. So a calm host adds nothing
// to this row and an alarmed one grows exactly the runs that are alarmed, which is also what makes them
// worth a glance when they appear. The resting numbers keep their one home in the accessibility label.
//
// BEDLESS, and that is a mount fact rather than a taste: the Mac's island is cut out of a titlebar that
// is already a plate, and a toolbar has no ground for a bed to be cut out of.
//
// EVERY FIGURE IS ``ConnectionReading``'s, and nothing here decides one. Not the ping's text, not the
// status word, not which reading has earned a place on the row, not when digits climb the alarm ladder —
// those are one reading in `SlopDeskClientCore` over one classifier in Rust, and this file paints what it
// is handed. The two mounts differ in exactly ONE named place, ``ConnectionReading/ConnectionMount``:
// `.compact` stays silent in the beat before the first ping sample lands, where the Mac's `.bedded`
// reading falls back to the status word, because a connected island with an empty right edge reads as
// broken while a toolbar item that has not appeared yet reads as nothing at all. That is a layout ruling
// about two mounts, passed as an argument, rather than a second answer to what the link says.
//
// The ALARM'S PALETTE is ``Slate/Native/connectionAlarmInk(_:)`` and
// ``Slate/Native/connectionAlarmWeight(_:)`` — one switch each, on the design floor, and the reason there
// is a second channel at all is that a brightness step beside a hostname is easy to lose while a weight
// step is not.
//
// THE VISIBLE METRIC IS THE PING ALONE. Appending the stream's cadence and bitrate once made the trailing
// run long enough to truncate the hostname out of its own row — the identity lost to telemetry. They live
// in ``ConnectionReading/help(host:status:fps:kbps:pulse:)``, which is the hover text on the Mac and, on a
// device with no pointer to hover, is simply what VoiceOver reads. Tap → the Connect editor; a give-up
// state → Retry beside it.

#if os(iOS)
import SFSafeSymbols // the retry mark's name, spelled once and checked by the compiler
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

// MARK: - The island

@MainActor
final class ConnectionIslandView: UIView {
    private let store: WorkspaceStore
    private let connection: AppConnection
    private let onConnect: () -> Void

    /// Everything the row draws, resolved in one pass and compared as one value.
    ///
    /// A struct rather than eight stored properties, for the reason the Mac twin gives: the row is
    /// repainted from an observation wake that cannot say WHAT moved, so the only cheap way to avoid
    /// re-laying-out a toolbar item on every unrelated store mutation is to resolve the whole answer and
    /// ask whether it differs. `Equatable` is the entire mechanism.
    private struct Reading: Equatable {
        let host: String
        let led: ConnectionLed
        let detail: String?
        let detailIsMetric: Bool
        let runs: [ConnectionMetricRun]
        let retry: Bool
        /// Host, headline, and the stream numbers the visible row deliberately drops. Hover text on the
        /// other platform; the accessibility label on this one.
        let help: String
    }

    private var painted: Reading?
    private var follow: ObservationFollow?

    // The row, outermost in.
    private let row = UIStackView()
    private let link = ConnectionIslandLinkControl()
    private let identity = UIStackView()
    private let host = UILabel()
    private let detail = UILabel()
    private let pulse = UIStackView()
    private let retry = UIButton(type: .system)

    init(store: WorkspaceStore, connection: AppConnection, onConnect: @escaping () -> Void) {
        self.store = store
        self.connection = connection
        self.onConnect = onConnect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        arm()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Building

    /// The row is Auto Layout, which is docs/62 §3.3's split: the CANVAS places by solved frame because a
    /// solver already answered it, and chrome like this is exactly the case constraints were made for —
    /// a run of text whose width is its content's, inside a bar that will not say how much room there is
    /// until it has asked.
    private func build() {
        host.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        host.numberOfLines = 1
        host.lineBreakMode = .byTruncatingTail
        // THE ROW'S DESIGNATED TRUNCATOR. A long hostname gives way; the ping never does, because a
        // figure squeezed into an ellipsis has stopped being an instrument. Stated as a compression
        // priority rather than a fixed width, so a short host simply takes less room.
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)

        detail.numberOfLines = 1
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)

        pulse.axis = .horizontal
        pulse.alignment = .center
        // One gap, and the same one, between the ping and the pulse and inside the pulse. The Mac's
        // banded mount spends a wider step between its three GROUPS; there is nothing to group here,
        // because at rest the pulse is absent and the row is never three things that have to be told
        // apart. A wider step would only push an alarm further from the identity it belongs to.
        pulse.spacing = Slate.Metric.space2

        identity.axis = .horizontal
        identity.alignment = .center
        identity.spacing = Slate.Metric.space2
        identity.isUserInteractionEnabled = false
        identity.addArrangedSubview(host)
        identity.addArrangedSubview(detail)
        identity.addArrangedSubview(pulse)

        link.addSubview(identity)
        identity.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            identity.leadingAnchor.constraint(
                equalTo: link.leadingAnchor, constant: Slate.Metric.space2,
            ),
            identity.trailingAnchor.constraint(
                equalTo: link.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            identity.centerYAnchor.constraint(equalTo: link.centerYAnchor),
            link.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
        ])
        link.addTarget(self, action: #selector(openConnect), for: .touchUpInside)

        retry.setImage(
            UIImage(systemSymbol: .arrowClockwise).applyingSymbolConfiguration(
                UIImage.SymbolConfiguration(
                    font: .systemFont(ofSize: Slate.Typeface.footnote, weight: .semibold),
                ),
            ),
            for: .normal,
        )
        retry.addTarget(self, action: #selector(retryLink), for: .touchUpInside)
        NSLayoutConstraint.activate([
            retry.widthAnchor.constraint(equalToConstant: Slate.Metric.plate),
            retry.heightAnchor.constraint(equalToConstant: Slate.Metric.plate),
        ])

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space1
        row.addArrangedSubview(link)
        row.addArrangedSubview(retry)
        addSubview(row)
        NSLayoutConstraint.activate(row.slateEdges(of: self))

        // The whole row speaks as ONE element. Its parts are a hostname, a figure and two or three
        // glyph/number pairs — read out separately they are a list of fragments, and the label the
        // reading already builds is the same sentence a pointer user gets on hover.
        link.isAccessibilityElement = true
        link.accessibilityTraits = .button
    }

    // MARK: The live read

    /// ONE arm over the whole reading, and the resolve happens INSIDE it on purpose: `pingMS`, the pulse
    /// and the status are three separate observable reads, and arming one follow per figure would wake
    /// the row three times for a single poll that moved all three.
    ///
    /// The re-arm is ``ObservationFollow``'s rather than a hand-written generation counter — same idiom,
    /// one implementation, and it is what keeps this file from restating the `[weak self]` +
    /// `assumeIsolated` + re-arm dance docs/62 §3.1 describes.
    private func arm() {
        follow = ObservationFollow.arm(self, replacing: follow) { island in
            island.resolve()
        } apply: { island, next in
            island.paint(next)
        }
    }

    /// Read the link, once. Every call in here is a door: this method's whole job is to be the ONE place
    /// the observation tracker touches the connection, so the tracker's dependency set is a list rather
    /// than whatever the view happened to read while painting.
    private func resolve() -> Reading {
        let status = connection.status
        let ping = ConnectionTelemetry.pingMS(store)
        let slot = ConnectionReading.trailingDetail(status: status, pingMS: ping, mount: .compact)
        return Reading(
            host: connection.hostDisplayName ?? connection.target.host,
            led: ConnectionReading.ledState(status: status, pingMS: ping),
            detail: slot?.text,
            detailIsMetric: slot?.isMetric ?? false,
            runs: ConnectionReading.promotedRuns(connection.hostPulse),
            retry: ConnectionReading.showsRetry(status),
            help: ConnectionReading.help(
                host: connection.target.host,
                status: status,
                fps: ConnectionTelemetry.fps(store),
                kbps: ConnectionTelemetry.kbps(store),
                pulse: connection.hostPulse,
            ),
        )
    }

    // MARK: Painting

    /// Draw a resolved reading, and do nothing at all when it has not moved.
    ///
    /// The early return is what makes this affordable inside a toolbar: the tracker wakes on any of a
    /// dozen store mutations, most of which change none of the eight figures above, and a stack view
    /// re-laid-out sixty times a second inside a navigation bar is a visible cost rather than a
    /// theoretical one.
    private func paint(_ next: Reading) {
        guard next != painted else { return }
        let settling = painted?.led != next.led
        let pulseMoved = painted?.runs != next.runs
        painted = next

        host.text = next.host
        // The identity DIMS when the link is not up. State lives in the text rather than in a lamp of
        // its own, because the ping digits beside it are already carrying the health — a second indicator
        // would be the same fact said twice, and the two could disagree during a dial.
        host.textColor = next.led == .dim ? Slate.Native.Text.tertiary : Slate.Native.Text.secondary

        applyDetail(next)
        if pulseMoved { applyPulse(next.runs) }

        retry.isHidden = !next.retry
        retry.tintColor = Slate.Native.Text.secondary
        retry.accessibilityLabel = "Retry connecting to \(next.host)"
        link.accessibilityLabel = next.help

        // The needle curve, and only when the link's own state settled. A ping that ticked from 11 to 12
        // is not a moment; a dial completing is, and it is the one the handshake already orchestrates
        // everywhere else in the chrome.
        guard settling, window != nil else { return }
        UIView.animate(
            withDuration: Slate.Motion.needle.duration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
        ) { [weak self] in
            self?.layoutIfNeeded()
        }
    }

    /// The trailing slot: a METRIC is the instrument voice, a status WORD keeps the system face.
    ///
    /// Two faces for one slot because they are two kinds of thing. A ping is a reading off an instrument,
    /// and it shares that voice with the git lines and the shell labels — mono, so the digits do not
    /// re-flow as they change width. A status word is prose, and prose set in an instrument face reads as
    /// a machine transcript. Which one is in the slot is ``ConnectionReading``'s answer, arriving as
    /// `isMetric`; this only picks the face.
    private func applyDetail(_ next: Reading) {
        guard let text = next.detail else {
            detail.isHidden = true
            detail.text = nil
            return
        }
        detail.isHidden = false
        detail.text = text
        // A word that has already said "disconnected" gains nothing from being shouted, so only the
        // metric arm can climb — and the rule for when it climbs is the door's, not a threshold here.
        let alarm = ConnectionReading.detailAlarm(
            detail: (text: text, isMetric: next.detailIsMetric), led: next.led,
        )
        detail.font = next.detailIsMetric
            ? Slate.Typeface.instrumentNative(
                Slate.Typeface.small, weight: Slate.Native.connectionAlarmWeight(alarm),
            )
            : .systemFont(ofSize: Slate.Typeface.small)
        detail.textColor = Slate.Native.connectionAlarmInk(alarm)
    }

    /// The promoted runs, rebuilt only when the SET of them moved.
    ///
    /// Rebuilt rather than reconciled by key, which is the opposite of what the canvas does with its
    /// panes — and the difference is what the views hold. A pane owns a live surface that must survive;
    /// a run owns a glyph and four characters. There are at most three of them, they change only when an
    /// alarm crosses a rung, and a keyed reconcile here would be more machinery than the thing it
    /// preserves.
    private func applyPulse(_ runs: [ConnectionMetricRun]) {
        for view in pulse.arrangedSubviews {
            pulse.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for run in runs {
            pulse.addArrangedSubview(ConnectionIslandRunView(run: run))
        }
        pulse.isHidden = runs.isEmpty
    }

    // MARK: The two verbs

    @objc
    private func openConnect() {
        onConnect()
    }

    @objc
    private func retryLink() {
        // The connection's own retry, not a fresh dial: the supervisor is holding the campaign's attempt
        // count and a second entry point that bypassed it would race the one already running.
        Task { [connection] in await connection.retry() }
    }
}

// MARK: - The tappable identity

/// The link row as a control, with the chrome's own press plate under it.
///
/// A bare `UIControl` and not a `UIButton`, for the reason ``SlatePlateVerbButton`` states: a button's
/// own machinery dims its title and image on highlight, which would fight the plate fill that IS this
/// row's press feedback — two answers to one press, one of them the framework's default rather than this
/// app's. The row's content is a stack view laid over it with hit-testing off, so the whole plate is one
/// target rather than a hostname the finger has to find.
@MainActor
private final class ConnectionIslandLinkControl: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        layer.cornerRadius = Slate.Metric.radiusControl
        paintPlate()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(
                withDuration: Slate.Motion.smallFade.duration,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: { [weak self] in self?.paintPlate() },
            )
        }
    }

    /// The plate a press rises onto — the same faint system fill a row hover uses on the other platform,
    /// which is what makes a tap here read as the same gesture a cursor makes there.
    private func paintPlate() {
        backgroundColor = isHighlighted ? Slate.Native.State.hover : .clear
    }
}

// MARK: - One run of the machine's pulse

/// A mark and a number at ONE alarm.
///
/// One alarm across both, because a half-raised readout reads as a rendering bug rather than as a
/// warning: the glyph climbs with the digits or neither does. The mark sits a step above the digits so a
/// drawing built from strokes holds its silhouette beside type built from stems, and the SYMBOL itself is
/// the role's — ``ConnectionMetric/symbolName``, one floor down — so the two shells cannot name the same
/// number with different marks.
///
/// Silent to assistive technology on purpose: the island speaks the whole pulse as prose in its own
/// label, and a screen reader that also walked these would hear the same readings twice, the second time
/// as fragments.
@MainActor
private final class ConnectionIslandRunView: UIView {
    init(run: ConnectionMetricRun) {
        super.init(frame: .zero)
        let weight = Slate.Native.connectionAlarmWeight(run.alarm)
        let ink = Slate.Native.connectionAlarmInk(run.alarm)

        let mark = UIImageView(
            image: UIImage(
                systemName: run.metric.symbolName,
                withConfiguration: UIImage.SymbolConfiguration(
                    font: .systemFont(ofSize: Slate.Typeface.footnote, weight: weight),
                ),
            ),
        )
        mark.tintColor = ink

        let figure = UILabel()
        figure.text = run.value
        figure.font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: weight)
        figure.textColor = ink
        figure.numberOfLines = 1
        // Ideal width always, like the ping beside it: an alarm squeezed into an ellipsis is not an
        // alarm.
        figure.setContentCompressionResistancePriority(.required, for: .horizontal)

        let pair = UIStackView(arrangedSubviews: [mark, figure])
        pair.axis = .horizontal
        pair.alignment = .center
        pair.spacing = Slate.Metric.space1
        addSubview(pair)
        NSLayoutConstraint.activate(pair.slateEdges(of: self))
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }
}
#endif

// MacConnectionIsland — the link's status island, in AppKit, in both of the Mac's two layouts.
//
// ONE ISLAND on the keyless bed (``Slate/Native/ProjectTint/neutralBed`` — the host is not a project
// and must not borrow a project's identity hue), and it FOLLOWS THE TABS:
//   • TABS VERTICAL (navigator open) — `stacked`: the sidebar's FOOTER, two lines on the island's own
//     text rail, the last thing under the list.
//   • TABS HORIZONTAL (navigator collapsed) — `inline`: the same runs laid across the titlebar band,
//     one control tall, hugging their own width so the island anchors to the band's corner.
//
//   mac-studio               12 ms      ← the LINK: who, and how far away
//   ▣ 34%       ▤ 61%       ▨ 240G      ← the MACHINE: how hard it is working
//
// BOTH mac layouts land here in ONE commit deliberately: they are one component seen on two axes, and
// porting one of them would have left the other's identical ink ladder spelled a second time in
// SwiftUI — the duplicate implementation `CLAUDE.md` bans. The phone's compact mount (the link line
// alone, bedless, in a navigation toolbar) stays SwiftUI in ``ConnectionPill`` and is not a twin of
// this: it is the OTHER PLATFORM's surface, and the decision both read is ``ConnectionReading``.
//
// WHAT THIS FILE OWNS is drawing and events. Every WORD, every threshold and every alarm rung is
// ``ConnectionReading``'s, one floor down — including which readings may climb at all (the link on its
// round trip, memory on the kernel's pressure verdict, disk on an absolute byte floor; CPU never). The
// alarm's PALETTE is `SlopDeskSlate`'s (``Slate/Native/connectionAlarmInk(_:)`` /
// ``Slate/Native/connectionAlarmWeight(_:)``, docs/56 batch 3) — one shared switch, not this file's own.
// All this half adds is the symbol each metric role draws.
//
// The telemetry is read HERE, at leaf scope, and that is load-bearing: `ConnectionTelemetry.pingMS`
// walks the live pane sessions, so resolving it in the navigator's or the band's own refresh would
// make that refresh a dependent of every pane's ~1 Hz latency tick — re-running the sidebar's
// sectioning pass, or the strip's whole `Deal`, once a second for a number neither of them draws.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

@MainActor
final class MacConnectionIsland: NSView {
    /// Which of the Mac's two mounts this is — a PARAMETER rather than two views because the ink
    /// rules, the alarm ladder and the copy are identical across them; only the axis and the collar
    /// change.
    enum Layout: Equatable {
        /// The navigator's footer, under a VERTICAL tab list: two lines on the bed.
        case stacked
        /// The band, beside a HORIZONTAL tab strip: one line on the bed, one control tall.
        case inline
    }

    /// The live model. `nil` is the DETACHED island the snapshot rig mounts — a reading in, pixels
    /// out, no store to seed and no socket to open. Splitting the live read from the drawing is the
    /// same seam the SwiftUI island kept for the same reason: every ink state has to be photographable
    /// without arranging for a host to actually be in it.
    private let store: WorkspaceStore?
    private let connection: AppConnection?
    private let onConnect: () -> Void
    private let layout: Layout

    /// The bed — a child rather than this view's own layer, so the HOVER tint can sit BEHIND it. The
    /// bed is a low-alpha wash, so the tint composites up through it and the whole island lifts as one
    /// object; an overlay would instead grey the digits it is meant to make reachable.
    private let bed = NSView()
    private let host = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let link = NSStackView()
    private let pulse = NSStackView()
    private let lines = NSStackView()
    private let retry = NSButton()

    private var runs: [ConnectionMetric: MacMetricRun] = [:]
    /// The Retry affordance's reserved width — zero while it is absent, so a settled island does not
    /// hold a plate of empty band open beside it.
    private var retryWidth: NSLayoutConstraint?
    private var retryGap: NSLayoutConstraint?

    private var hovering = false
    private var tracking: NSTrackingArea?

    /// The last resolved reading, so a 1 Hz telemetry tick that changed nothing repaints nothing.
    private var painted: Reading?

    /// Everything the island draws, as one value — resolved off the live model by ``refresh()``, or
    /// handed straight in by the snapshot rig.
    struct Reading: Equatable {
        let host: String
        let led: ConnectionLed
        let detail: String?
        let detailIsMetric: Bool
        let metrics: [ConnectionMetricRun]
        /// The pulse as words, for the readers that get no glyph.
        let spoken: String
        let retry: Bool
        let help: String
    }

    init(
        store: WorkspaceStore, connection: AppConnection, onConnect: @escaping () -> Void,
        layout: Layout,
    ) {
        self.store = store
        self.connection = connection
        self.onConnect = onConnect
        self.layout = layout
        super.init(frame: .zero)
        build()
        refresh()
    }

    /// A DETACHED island — see ``store``.
    init(reading: Reading, layout: Layout) {
        store = nil
        connection = nil
        onConnect = {}
        self.layout = layout
        super.init(frame: .zero)
        build()
        painted = reading
        apply(reading)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Construction

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.islandRadiusCompact
        layer?.cornerCurve = .continuous

        bed.translatesAutoresizingMaskIntoConstraints = false
        bed.wantsLayer = true
        bed.layer?.cornerRadius = Slate.Metric.islandRadiusCompact
        bed.layer?.cornerCurve = .continuous
        addSubview(bed)

        // The hostname — the same register as the project header names (footnote medium, secondary),
        // dimming to tertiary while nothing is connected. The island's designated TRUNCATOR: a long
        // host gives way, the short metric never does.
        host.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        host.lineBreakMode = .byTruncatingTail
        host.maximumNumberOfLines = 1
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.maximumNumberOfLines = 1
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)

        pulse.orientation = .horizontal
        pulse.alignment = .centerY
        pulse.spacing = Slate.Metric.space2
        for metric in ConnectionMetric.allCases {
            let run = MacMetricRun(metric: metric)
            runs[metric] = run
            pulse.addArrangedSubview(run)
        }
        pulse.setAccessibilityElement(true)
        pulse.setAccessibilityRole(.staticText)

        lines.translatesAutoresizingMaskIntoConstraints = false
        switch layout {
        case .stacked:
            // The FOOTER form: the link over the pulse. Both lines SPREAD across the island's own
            // text rail — the same leading and trailing edges — so the two read as one block with a
            // shared measure rather than as two runs that happen to be stacked.
            link.orientation = .horizontal
            link.alignment = .centerY
            link.distribution = .equalSpacing
            link.addArrangedSubview(host)
            link.addArrangedSubview(detail)
            pulse.distribution = .equalSpacing
            lines.orientation = .vertical
            lines.alignment = .leading
            lines.spacing = 0
            lines.addArrangedSubview(link)
            lines.addArrangedSubview(pulse)
            // ⚠️ Both lines are pinned to the BLOCK's width EXPLICITLY, not left to the stack's
            // `alignment = .width`. `.equalSpacing` only reaches the two ends when the row it spends
            // is as wide as the block, and the alignment did not give it that: the first render came
            // out with BOTH runs of each line huddled at the trailing edge, so the hostname sat
            // against the ping and the cpu reading floated in from the left rail. The two lines are
            // one block with one measure, and that measure is now stated rather than inferred.
            link.widthAnchor.constraint(equalTo: lines.widthAnchor).isActive = true
            pulse.widthAnchor.constraint(equalTo: lines.widthAnchor).isActive = true
            // The link rides the CONTROL band, not the list's 32pt row band: the two lines are one
            // block and have to read as a pair, and a row band under a row band put ~17pt of air
            // between two lines that belong together.
            link.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl).isActive = true
        case .inline:
            // The BAND form: identity, link and pulse laid across one control-tall row. The gaps are
            // the grid's — a wide step between the three GROUPS (who / how far / how hard), the
            // narrow one inside the pulse, so the row parses without a separator drawn anywhere.
            lines.orientation = .horizontal
            lines.alignment = .centerY
            lines.spacing = Slate.Metric.space3
            lines.addArrangedSubview(host)
            lines.addArrangedSubview(detail)
            lines.addArrangedSubview(pulse)
            lines.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl).isActive = true
        }
        bed.addSubview(lines)

        retry.isBordered = false
        retry.bezelStyle = .inline
        retry.imagePosition = .imageOnly
        retry.title = ""
        retry.target = self
        retry.action = #selector(retryConnect)
        retry.isHidden = true
        retry.translatesAutoresizingMaskIntoConstraints = false
        addSubview(retry)

        layOut()
    }

    private func layOut() {
        // The bed's collar: the FOOTER's wears the sidebar's, the band's wears none — for the SAME
        // reason the horizontal tab strip's beds do not. Any collar at all makes it the one taller
        // object in a band where everything else is a plain control rung.
        let vertical = layout == .stacked ? Slate.Metric.space2 : 0
        let horizontal = layout == .stacked
            // `projectIslandInset + islandRail` is the 18pt rail the project rows above hold.
            ? Slate.Metric.projectIslandInset + Slate.Metric.islandRail
            : Slate.Metric.space2
        let gap = retry.leadingAnchor.constraint(equalTo: bed.trailingAnchor)
        let width = retry.widthAnchor.constraint(equalToConstant: 0)
        retryGap = gap
        retryWidth = width
        NSLayoutConstraint.activate([
            bed.topAnchor.constraint(equalTo: topAnchor),
            bed.bottomAnchor.constraint(equalTo: bottomAnchor),
            bed.leadingAnchor.constraint(equalTo: leadingAnchor),
            lines.topAnchor.constraint(equalTo: bed.topAnchor, constant: vertical),
            lines.bottomAnchor.constraint(equalTo: bed.bottomAnchor, constant: -vertical),
            lines.leadingAnchor.constraint(equalTo: bed.leadingAnchor, constant: horizontal),
            lines.trailingAnchor.constraint(equalTo: bed.trailingAnchor, constant: -horizontal),
            gap,
            width,
            retry.trailingAnchor.constraint(equalTo: trailingAnchor),
            retry.centerYAnchor.constraint(equalTo: centerYAnchor),
            retry.heightAnchor.constraint(equalToConstant: Slate.Metric.plate),
        ])
    }

    // MARK: The live read

    /// Re-resolve the whole island against the live connection + telemetry, re-arming for the next
    /// change. Every decision below the palette is ``ConnectionReading``'s.
    private func refresh() {
        // The DETACHED island has no model to follow — it was handed its one reading at `init`.
        guard let store, let connection else { return }
        ObservationFollow.arm(self) { _ in
            let status = connection.status
            let ping = ConnectionTelemetry.pingMS(store)
            let slot = ConnectionReading.trailingDetail(status: status, pingMS: ping, mount: .bedded)
            return Reading(
                host: connection.hostDisplayName ?? connection.target.host,
                led: ConnectionReading.ledState(status: status, pingMS: ping),
                detail: slot?.text,
                detailIsMetric: slot?.isMetric ?? false,
                metrics: ConnectionReading.metricRuns(connection.hostPulse),
                spoken: ConnectionReading.pulseSpoken(connection.hostPulse),
                retry: ConnectionReading.showsRetry(status),
                help: ConnectionReading.help(
                    host: connection.target.host, status: status,
                    fps: ConnectionTelemetry.fps(store), kbps: ConnectionTelemetry.kbps(store),
                    pulse: connection.hostPulse,
                ),
            )
        } apply: { island, next in
            guard next != island.painted else { return }
            // The inks brighten on the NEEDLE curve — the same orchestrated moment the handshake owns.
            let settling = island.painted?.led != next.led
            island.painted = next
            island.apply(next)
            guard settling else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Slate.Motion.needle.duration
                context.timingFunction = Slate.Motion.needle.timingFunction
                context.allowsImplicitAnimation = true
                island.layoutSubtreeIfNeeded()
            }
        }
    }

    /// Everything a reading decides that is not a colour: the words, which runs are present, and the
    /// Retry affordance's reserve. The inks themselves are ``paintInks()``'s, because a `CGColor` is
    /// flat and has to be re-resolved on every appearance change as well as on every reading.
    private func apply(_ reading: Reading) {
        toolTip = reading.help
        setAccessibilityLabel(reading.help)
        host.stringValue = reading.host
        detail.isHidden = reading.detail == nil
        if let text = reading.detail { detail.stringValue = text }

        // The pulse is ABSENT, not blanked, until a reading exists: an instrument showing "cpu —"
        // advertises breakage, while an island that grows a second line on connect just reports. A
        // host that could not read its volume drops the DISK run alone — one missing metric closes
        // its gap.
        let shown = Dictionary(uniqueKeysWithValues: reading.metrics.map { ($0.metric, $0) })
        for metric in ConnectionMetric.allCases {
            guard let run = runs[metric] else { continue }
            run.isHidden = shown[metric] == nil
            if let value = shown[metric] { run.apply(value) }
        }
        pulse.isHidden = reading.metrics.isEmpty
        pulse.setAccessibilityLabel(reading.spoken)

        retry.isHidden = !reading.retry
        retryWidth?.constant = reading.retry ? Slate.Metric.plate : 0
        retryGap?.constant = reading.retry ? Slate.Metric.space1 : 0
        if let connection {
            retry.toolTip = "Retry connecting to \(connection.target.host)"
            retry.setAccessibilityLabel(retry.toolTip)
        }

        needsDisplay = true
        updateLayer()
    }

    // MARK: Paint

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { paintInks() }
    }

    private func paintInks() {
        layer?.backgroundColor = hovering
            ? Slate.Native.State.hover.cgColor
            : NSColor.clear.cgColor
        bed.layer?.backgroundColor = Slate.Native.ProjectTint.neutralBed.cgColor
        host.textColor = painted?.led == .dim
            ? Slate.Native.Text.tertiary
            : Slate.Native.Text.secondary
        // A metric is INSTRUMENT mono — one metadata voice with the git lines and the shell labels; a
        // status WORD is prose and keeps the system face. The ping digits climb the alarm ladder as
        // the link degrades; a status word does not, because prose that has already said
        // "disconnected" gains nothing from being shouted.
        if let painted {
            let alarm = ConnectionReading.detailAlarm(
                detail: painted.detail.map { ($0, painted.detailIsMetric) }, led: painted.led,
            )
            detail.font = painted.detailIsMetric
                ? Slate.Typeface.instrumentNative(
                    Slate.Typeface.small, weight: Slate.Native.connectionAlarmWeight(alarm),
                )
                : .systemFont(ofSize: Slate.Typeface.small)
            detail.textColor = Slate.Native.connectionAlarmInk(alarm)
        }
        for run in runs.values { run.repaint() }
        retry.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry",
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(
                    paletteColors: [Slate.Native.Text.secondary],
                )),
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Hover + the click

    private func track() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        track()
    }

    override func mouseEntered(with _: NSEvent) { setHovering(true) }
    override func mouseExited(with _: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        needsDisplay = true
        updateLayer()
    }

    override func mouseDown(with _: NSEvent) { onConnect() }

    @objc
    private func retryConnect() {
        guard let connection else { return }
        Task { await connection.retry() }
    }
}

// MARK: - One reading

/// One drawn run of the machine's pulse: its mark, then its number, at ONE alarm — the glyph climbs
/// WITH the digits, because a half-raised readout reads as a rendering bug rather than a warning.
///
/// The mark sits a step above the digits (`footnote`) so a drawing built from strokes holds its
/// silhouette next to type built from stems, and the two are CENTRED on each other rather than
/// baselined: an `NSImageView` has no baseline of its own, and faking one for a symbol whose optical
/// centre is not its cap line buys nothing the eye can see at this size.
@MainActor
private final class MacMetricRun: NSView {
    private let metric: ConnectionMetric
    private let glyph = NSImageView()
    private let value = NSTextField(labelWithString: "")
    private var alarm: ConnectionAlarm = .quiet

    init(metric: ConnectionMetric) {
        self.metric = metric
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        value.setAccessibilityElement(false)
        value.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(value)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(
                equalTo: glyph.trailingAnchor, constant: Slate.Metric.space1,
            ),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalTo: value.heightAnchor),
        ])
        repaint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func apply(_ run: ConnectionMetricRun) {
        value.stringValue = run.value
        guard alarm != run.alarm else { return }
        alarm = run.alarm
        repaint()
    }

    func repaint() {
        let weight = Slate.Native.connectionAlarmWeight(alarm)
        let ink = Slate.Native.connectionAlarmInk(alarm)
        value.font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: weight)
        value.textColor = ink
        // Processor die, memory module, drive — the three differ in SILHOUETTE (a square pinned on
        // four edges, a wide module pinned on one, a slab with a spindle dot), which is the only
        // difference that survives at the island's size. The choice is the ROLE's, one floor down.
        glyph.image = NSImage(systemSymbolName: metric.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote, weight: weight)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink])),
            )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { repaint() }
    }
}

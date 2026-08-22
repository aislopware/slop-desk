// MacSidebarHeader — one project group's header, in AppKit.
//
// The top line of a project island: the FOLDER glyph, the group's NAME, and — while open — the live
// git line beneath it. While COLLAPSED the git line folds away and the hidden-row COUNT takes the
// trailing slot instead, wearing the strongest ATTENTION ink of the rows it hides, so folding a group
// never mutes a waiting agent.
//
// The dialect is not here: which sigils, in what order, at what weight, and what gets shed as the
// column narrows are all ``SidebarGitLine``'s (SlopDeskClientCore), and the palette is
// ``Slate/Native/gitInk(_:)``'s. What IS here is the one thing neither can answer — WHICH RUNG FITS,
// which needs a measured string against a real width.
//
// ⚠️ THE SHEDDING IS MEASURED, not guessed. The SwiftUI half asked `ViewThatFits` to walk five rungs
// and pick the first that fitted; AppKit has no such container, so the rungs are measured directly
// against the line's own width. That is not a downgrade — it is the same ladder resolved by the same
// question, and it is now deterministic enough to unit-pin.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

@MainActor
final class MacSidebarHeaderView: NSView {
    private let store: WorkspaceStore
    /// The group's display name — the basename, worktree-collision-qualified. The full path lives in
    /// the tooltip.
    private let title: String
    private let projectKey: String?
    /// The group's rows — read to fuse the hidden rows' badges into the collapsed count's roll-up ink,
    /// and to work out whether the FOCUSED pane lives in this group.
    private var rows: [RailRow]
    private var collapsed: Bool

    private let folder = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let git = MacGitLineView()
    private let count = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    /// Whether the FOCUSED pane lives in this group — the header's ink steps up for it.
    private var current = false

    var onToggle: () -> Void = {}

    init(store: WorkspaceStore, title: String, projectKey: String?, rows: [RailRow], collapsed: Bool) {
        self.store = store
        self.title = title
        self.projectKey = projectKey
        self.rows = rows
        self.collapsed = collapsed
        super.init(frame: .zero)
        build()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Construction

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        // The folder — the group is a PLACE, spoken in the header's own ink; the one pictogram the
        // monochrome rail keeps. It stays MONOCHROME even though the group has an identity hue: the
        // bed carries that colour, and tinting the glyph too would say the same thing twice.
        folder.imageScaling = .scaleNone
        folder.setAccessibilityElement(false)
        folder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(folder)

        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        git.translatesAutoresizingMaskIntoConstraints = false
        addSubview(git)

        count.font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .semibold)
        count.alignment = .right
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(count)

        // ONE chevron glyph rotating 0°↔90° (not a `.chevronDown` swap) so the toggle TURNS with the
        // group animation instead of teleporting between two symbols. It stands at the island's
        // TRAILING rail, out of the reading column: inside an island the group is already drawn — the
        // bed IS the grouping — so an arrow parked in the reading column restates a boundary the
        // surface has already stated.
        chevron.imageScaling = .scaleNone
        chevron.wantsLayer = true
        chevron.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        chevron.setAccessibilityElement(false)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            // `.medium`, not `.semibold` — a 1px-stroke glyph; semibold at this size reads a full
            // step chunkier.
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .medium,
            ))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        // Both rails are the island's, so the folder lands on the row titles' x and the chevron on
        // their trailing-slot x.
        let rail = Slate.Metric.islandRail
        NSLayoutConstraint.activate([
            // A bare header keeps the measured 24pt band; a git-lined one grows to fit its second
            // line, which the name/git stack's own bottom anchor drives.
            heightAnchor.constraint(greaterThanOrEqualToConstant: Slate.Metric.heightSectionHeader),
            folder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rail),
            // The folder sits on the NAME line (baseline-aligned); the git line hangs beneath.
            folder.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            name.leadingAnchor.constraint(equalTo: folder.trailingAnchor, constant: 6),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            git.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            git.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            git.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            git.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
            count.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            count.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -rail),
            chevron.centerYAnchor.constraint(equalTo: name.centerYAnchor),
        ])
    }

    // MARK: The live read

    /// Fold the group shut or open. The caller animates the island's own height; this turns the
    /// chevron in the same curve so the two read as one movement.
    func setCollapsed(_ value: Bool, animated: Bool) {
        guard collapsed != value else { return }
        collapsed = value
        turn(animated: animated)
        refresh()
    }

    func update(rows: [RailRow]) {
        self.rows = rows
        refresh()
    }

    /// Re-resolve the header's volatile chrome — the git summary, whose group holds focus, the
    /// collapsed count's roll-up — and re-arm for the next store tick. Leaf-scoped for the reason
    /// ``MacSidebarRowView/refresh()`` is: a git or status tick repaints this header, never the list.
    func refresh() {
        var summary: PaneGitSummary?
        var focused = false
        var rollup: AttentionRole?
        withObservationTracking {
            summary = projectKey.flatMap { store.projectGitSummary[$0] }
            focused = SidebarSections.holdsFocus(rows: rows, store: store)
            rollup = collapsed
                ? TabBadgeReading.rollup(
                    RailRowsBuilder.liveChrome(for: rows, store: store).map(\.badge),
                )
                : nil
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        current = focused
        toolTip = SidebarGitLine.tooltip(projectKey: projectKey, summary: summary)

        let ink = headerInk
        folder.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Typeface.small, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink])),
            )
        // `slateNerdAware` — a project folder named with a nerd-font glyph draws it from the bundled
        // symbols face instead of a notdef box.
        name.attributedStringValue = .slateNerdAware(
            title,
            font: .systemFont(ofSize: Slate.Typeface.footnote, weight: .semibold),
            color: ink,
        )
        git.summary = SidebarGitLine.detailSummary(collapsed: collapsed, summary: summary)
        git.isHidden = git.segments.isEmpty

        if let trailing = SidebarGitLine.trailingCount(collapsed: collapsed, count: rows.count) {
            count.stringValue = trailing
            count.textColor = rollup.map(Slate.Native.attentionInk) ?? Slate.Native.Text.tertiary
            count.isHidden = false
        } else {
            count.isHidden = true
        }
        chevron.contentTintColor = Slate.Native.State.header
    }

    /// WHICH project is open, said on the ink ladder the sidebar already has: the focused group's
    /// folder and name step up to the body ink; every other group stays on the quiet rung.
    ///
    /// Chosen over a second alpha on the bed, a hue edge, and dropping the other groups' colour
    /// altogether (user-directed 2026-08-08) — a step on a ladder that already exists spends no new
    /// vocabulary, and it cannot collide with the SELECTED ROW's dark chip standing inside the same
    /// island.
    private var headerInk: NSColor {
        current ? Slate.Native.Text.primary : Slate.Native.Text.secondary
    }

    private func turn(animated: Bool) {
        let angle = collapsed ? 0 : CGFloat.pi / 2
        guard animated else {
            chevron.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            return
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = collapsed ? CGFloat.pi / 2 : 0
        spin.toValue = angle
        spin.duration = Slate.Motion.standard.duration
        spin.timingFunction = Slate.Motion.standard.timingFunction
        chevron.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        chevron.layer?.add(spin, forKey: "turn")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The layer exists only once the view is in a window, so the resting rotation is applied
        // here rather than in `build()` — otherwise an already-collapsed group would open with its
        // chevron pointing the wrong way.
        turn(animated: false)
    }

    // MARK: Interaction

    override func mouseDown(with _: NSEvent) { onToggle() }

    override func menu(for _: NSEvent) -> NSMenu? {
        guard let projectKey else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Refresh Git Status", action: #selector(refreshGit), keyEquivalent: "")
        item.target = self
        item.representedObject = projectKey
        menu.addItem(item)
        return menu
    }

    @objc
    private func refreshGit(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        store.refreshGitSummary(forProject: key)
    }
}

// MARK: - The git line

/// The git line as it PAINTS, across the widths the sidebar's real column asks for.
///
/// Roomy: the whole dialect inline, branch then counts. Tight: the counts fold to
/// ``SidebarGitLine/compactStatus(_:shedding:)``'s bare sigils pinned flush to the trailing edge, one
/// cluster with no gaps so they read as a single readout rather than a second sentence. Presence is
/// what a sigil reports — `!` says there is uncommitted work at any width — so the NUMBERS retreat
/// to the tooltip first.
///
/// Narrower still, the branch and the readout compete for the same line, and the readout starts
/// SHEDDING down the dialect's ladder — one rung per candidate — rather than crowding the name into
/// a stub. The ladder is `slopdesk_workspace::git_line`'s, asked for by rung: this view says how much
/// room it has, never which role should go. Only when even the worktree core cannot buy the branch
/// enough room does the name truncate (tail: a long branch loses its end, which is the part that
/// repeats).
///
/// The whole ladder exists because one tail-truncating line took the counts down WITH the branch:
/// `feature/some-very-long-name…` spelled three more characters of a name you already know and ate the
/// readout you were actually watching.
@MainActor
final class MacGitLineView: NSView {
    /// The line's COUNTS — the one thing this view holds, and the one thing the dialect answers
    /// from. It used to hold the spelled segments and shed them itself; the ladder is Rust's now,
    /// and it folds from counts, so a view keeping only the written form would have to hand a
    /// half-answer back to be re-read. `nil` is a collapsed header or a directory with no repo.
    var summary: PaneGitSummary? {
        didSet {
            guard summary != oldValue else { return }
            segments = summary.map(SidebarGitLine.segments) ?? []
            // The ladder is `segments` MEASURED, so it dies with them and with nothing else.
            ladder = nil
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The whole line, written. Derived, never set: it is `summary` spelled.
    private(set) var segments: [GitSegment] = []

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measured()?.height ?? 0)
    }

    override func draw(_: NSRect) {
        guard let ladder = measured() else { return }
        guard let name = ladder.name else {
            ladder.inline.draw(in: bounds)
            return
        }
        // Rung 0 is the whole dialect inline. Every rung after it splits the line — branch left,
        // compact sigils pinned right — and sheds one more role from the readout. The branch is held
        // at its FULL width in every rung but the last, so a rung stops fitting exactly when the name
        // would start losing characters: that is the signal to shed one more sigil instead.
        if ladder.inlineWidth <= bounds.width {
            ladder.inline.draw(in: bounds)
            return
        }
        for rung in ladder.rungs {
            // The one gap the tight form keeps: the branch never touches the readout, however little
            // room is left for it.
            guard name.width + 4 + rung.width <= bounds.width else { continue }
            draw(name.text, rung.text)
            return
        }
        // The last rung's escape hatch — the worktree core stays whole and the NAME truncates.
        guard let last = ladder.rungs.last else { return }
        draw(name.text, last.text)
    }

    // MARK: The measured ladder

    /// One written form and the width it takes — a pair, because every reader of one reads the other
    /// and `NSAttributedString.size()` is a full text layout rather than a field.
    private struct Run {
        let text: NSAttributedString
        let width: CGFloat
    }

    /// Every form this line can be drawn in, MEASURED once. `name` is `nil` for a line with no
    /// status runs at all, which is the one shape that never sheds.
    private struct Ladder {
        let inline: NSAttributedString
        let inlineWidth: CGFloat
        let height: CGFloat
        let name: Run?
        /// The four shed rungs, in ladder order — empty when there is nothing to shed.
        let rungs: [Run]
    }

    /// ⚠️ MEMOIZED, and this is the whole reason the type exists. `draw(_:)` and
    /// `intrinsicContentSize` both used to BUILD their attributed strings and MEASURE them on every
    /// call, and both are called by AppKit — a repaint, a layout pass, every frame of a sidebar
    /// divider drag — while `summary` moves on a git poll, seconds apart. Measured in a scratch
    /// `swiftc -O` harness against this exact ladder (8 runs, a 24-character branch):
    /// `intrinsicContentSize` **17.1 µs**, the shedding `draw` **62 µs**, the roomy `draw` **20 µs**;
    /// building the ladder once costs **51 µs** and every read after it is **5 ns**. Six project
    /// islands re-measuring on one 60 fps drag frame is ~370 µs of a 16.6 ms budget, to answer a
    /// question whose inputs did not move.
    ///
    /// `nil` is a line with no segments, which draws nothing and claims no height.
    private func measured() -> Ladder? {
        if let ladder { return ladder }
        guard !segments.isEmpty else { return nil }
        let inline = Self.attributed(segments)
        let inlineSize = inline.size()
        // No status run at all ⇒ every segment IS the branch, so the inline form is the whole line
        // and there is nothing to shed. That is the one shape with no ladder above rung zero.
        guard segments.contains(where: { $0.ink != .branch }) else {
            let bare = Ladder(
                inline: inline, inlineWidth: inlineSize.width, height: inlineSize.height,
                name: nil, rungs: [],
            )
            ladder = bare
            return bare
        }
        let name = Self.attributed(segments.filter { $0.ink == .branch })
        let built = Ladder(
            inline: inline,
            inlineWidth: inlineSize.width,
            height: inlineSize.height,
            name: Run(text: name, width: name.size().width),
            rungs: (0...3).map { level in
                let text = Self.attributed(shed(to: level), separator: "")
                return Run(text: text, width: text.size().width)
            },
        )
        ladder = built
        return built
    }

    private var ladder: Ladder?

    /// The readout at one rung of the ladder, as bare sigils. One call rather than a shed followed
    /// by a compaction: the dialect folds both in the same crossing.
    private func shed(to level: Int) -> [GitSegment] {
        guard let summary else { return [] }
        return SidebarGitLine.compactStatus(summary, shedding: level)
    }

    private func draw(_ name: NSAttributedString, _ status: NSAttributedString) {
        let statusWidth = status.size().width
        status.draw(in: NSRect(
            x: bounds.maxX - statusWidth, y: 0, width: statusWidth, height: bounds.height,
        ))
        name.draw(in: NSRect(
            x: 0, y: 0, width: CGFloat.maximum(0, bounds.width - statusWidth - 4),
            height: bounds.height,
        ))
    }

    /// The painted runs: ONE attributed string, so the whole thing still truncates as a single line
    /// (a stack of labels would clip a whole run instead of the tail). The compact form passes an
    /// EMPTY separator — bare sigils cluster tighter than they space out.
    ///
    /// The line is DATA — the instrument mono, one register with the rows' process labels. But it is
    /// data with STATES, and rendering all of them in one flat grey made the counts that matter (a
    /// conflict, unpushed work) read exactly like the ones that don't. Each run wears its own ink and
    /// weight instead; the mono grid keeps the line from turning into confetti.
    static func attributed(_ segments: [GitSegment], separator: String = " ") -> NSAttributedString {
        let line = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (index, segment) in segments.enumerated() {
            line.append(NSAttributedString(
                string: index == 0 ? segment.text : separator + segment.text,
                attributes: [
                    .font: Slate.Typeface.instrumentNative(
                        Slate.Typeface.small, weight: weight(segment),
                    ),
                    .foregroundColor: Slate.Native.gitInk(segment.ink),
                    .paragraphStyle: paragraph,
                ],
            ))
        }
        return line
    }

    /// A run's three rungs, in the face's own units. The RUNG is the dialect's — it arrives on the
    /// segment — so this maps and never decides.
    private static func weight(_ segment: GitSegment) -> NSFont.Weight {
        switch segment.weight {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

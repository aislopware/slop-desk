// PhoneAndroidConsoleView — `logcat`, under the device.
//
// ``SlopDeskMacUI/MacAndroidConsoleView`` draws the same drawer in AppKit. The filter, the three empty
// sentences, the plain-text form a Copy hands over, the row menu and the severity→ink table all
// descended to ``AndroidPresentation`` — the last one because it is a scale, and a scale copied into a
// second framework is the drift nobody sees until two screens sit side by side.
//
// A DRAWER, not a tab, for the reason its simulator twin gives: the reason to read a device's log is
// to see what the thing on screen just did, and a console that replaces the screen breaks exactly
// that loop — tap, watch, read.
//
// THE FILTER IS CLIENT-SIDE and the LEVEL is not, which is the same split as the simulator console
// and for a sharper reason here: `logcat`'s filter spec is fixed at spawn, so a level change is a new
// child process, while a substring filter must NOT reconnect — narrowing the view is the one thing
// that has to keep the history it is narrowing.
//
// THE TAG COLUMN IS THE ANDROID DIFFERENCE. `logcat` carries the WHOLE system, not one process, so a
// quiet app's console is still hundreds of lines a minute of `ActivityManager`, `WindowManager` and
// the rest. The tag is what makes that navigable, so it is drawn as its own run and the filter
// searches it — "hide everything that is not mine" is the first thing anyone does with an Android log.
//
// ⚠️ ROWS, WHERE THE MAC DRAWS ONE TEXT VIEW. `MacAndroidConsoleView` puts the whole log into a single
// `NSTextView` with a hanging indent measured off logcat's 18-character stamp, and that is right there:
// AppKit's text system is one object for any number of lines and a Mac has the width for a real
// hanging indent. Here it is a `UICollectionViewDiffableDataSource`, which is docs/62 §3.4's ruling for
// this surface BY MEASUREMENT — 0.78 ms per derivation on a filter hit and 1.50 ms on a miss at
// ``AndroidSidebarModel/logCapacity`` = 600 rows, and logcat holds the ring AT its cap on any device
// that is doing anything.
//
// ⚠️ THE IDENTIFIER IS ``DeviceLogLine/id``, the model's own monotonic sequence number, and never the
// text: two identical lines a second apart are two rows, and a content-keyed snapshot would collapse
// them into one. The ring EVICTS, so a cell provider must tolerate an id whose line is already gone —
// it draws an empty row rather than reaching for an index (hazard 3).

#if os(iOS)
import Observation
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskDevicePanels
import SlopDeskSlate
import UIKit

@MainActor
final class PhoneAndroidConsoleView: UIView {
    private let model: AndroidSidebarModel

    /// Held by the VIEW, not the model: it filters what is drawn and nothing else, it must not survive
    /// a device switch, and putting display state in the model would make a keystroke here an
    /// observable write that redraws the device above.
    private var filter = ""
    private var isFollowing = true

    private let strip = UIView()
    private let level = UIButton(type: .system)
    private let field = UIView()
    private let line: SlateSearchLine
    private let clear: UIControl
    private let followPlate: SlatePlateIconButton
    /// Minted with a PLACEHOLDER layout: the list configuration is assembled in ``buildRows()``, which
    /// swaps the real one in before the first pass.
    private let rows = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
    private var source: UICollectionViewDiffableDataSource<Int, UInt64>?
    private let empty = UILabel()

    /// Named because the generic pair is the whole of the registration's opening line — spelled inline
    /// it leaves no room for the closure's parameters beside the brace.
    private typealias LogRegistration = UICollectionView.CellRegistration<PhoneAndroidLogCell, UInt64>

    /// The rows as last derived, by id. The cell provider's only source — see the header's note on
    /// eviction.
    private var lines: [UInt64: DeviceLogLine] = [:]
    /// The ids as last applied, in order. The gate that keeps an unrelated model write from re-applying
    /// an identical snapshot.
    private var drawn: [UInt64] = []

    /// ⚠️ Hazard 2's counter.
    private var generation = 0

    init(model: AndroidSidebarModel) {
        self.model = model
        line = SlateSearchLine(placeholder: AndroidPresentation.consoleFilterPlaceholder)
        followPlate = SlatePlateIconButton(symbol: AndroidPresentation.consoleFollowSymbol)
        // The key is minted WITH its action and the action is `self`'s, which phase 1 cannot read — so
        // it is built against a box phase 2 fills. ``PhoneSimulatorConsoleView``'s trampoline exactly.
        var clearAction: (() -> Void)?
        clear = PhoneDevicePanelChrome.clearKey(ink: PhoneAndroidInk.color(.icon)) { clearAction?() }
        super.init(frame: .zero)
        clearAction = { [weak self] in self?.setFilter("") }
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Slate.Native.Surface.field

        buildStrip()
        buildRows()

        empty.font = .systemFont(ofSize: Slate.Typeface.footnote)
        empty.textColor = PhoneAndroidInk.color(.tertiary)
        empty.textAlignment = .center
        empty.numberOfLines = 0
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)

        // The one rule above the drawer, and the only thing that separates it from the picture: the two
        // bands share the panel's ground (ONE ISLAND, law 1), so a tone change here would re-open the
        // two-surface split that retired on 2026-08-08.
        let rule = UIView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.backgroundColor = Slate.Native.Line.divider
        addSubview(rule)

        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),

            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: Slate.Metric.heightBar),

            rows.topAnchor.constraint(equalTo: strip.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),

            empty.centerYAnchor.constraint(equalTo: rows.centerYAnchor),
            empty.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Slate.Metric.space3,
            ),
            empty.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.space3,
            ),
        ])

        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Controls

    private func buildStrip() {
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.backgroundColor = Slate.Native.Surface.raised
        addSubview(strip)

        // The caps title, in the INSTRUMENT voice — `Logcat`, not "Console": the panel carries the
        // tool's own name because what it shows is the tool's own output, filter spec and all.
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .semibold)
        title.textColor = Slate.Native.State.header
        title.attributedText = NSAttributedString(
            string: AndroidPresentation.consoleTitle.uppercased(),
            attributes: [.kern: Slate.Typeface.instrumentTracking],
        )
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.accessibilityTraits = .header

        buildLevel()
        buildField()

        followPlate.active = isFollowing
        followPlate.slateHelp(AndroidPresentation.consoleFollowHelp(isFollowing: isFollowing))
        followPlate.addAction(UIAction { [weak self] _ in self?.toggleFollowing() }, for: .touchUpInside)

        let clearPlate = plate(
            AndroidPresentation.consoleClearSymbol, help: AndroidPresentation.consoleClearHelp,
        ) { [weak self] in self?.model.clearLog() }
        let hidePlate = plate(
            AndroidPresentation.consoleHideSymbol, help: AndroidPresentation.consoleHideHelp,
        ) { [weak self] in self?.model.toggleConsole() }
        let tray = SlatePlateTray([clearPlate, hidePlate])

        let run = UIStackView(arrangedSubviews: [title, level, field, followPlate, tray])
        run.translatesAutoresizingMaskIntoConstraints = false
        run.axis = .horizontal
        run.alignment = .center
        run.spacing = Slate.Metric.space2
        strip.addSubview(run)
        NSLayoutConstraint.activate([
            run.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: Slate.Metric.space2),
            run.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -Slate.Metric.space2),
            run.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
    }

    /// A plate whose action is a plain verb — minted here rather than at three call sites so the tray
    /// gets the type it insists on (`SlatePlateTray` takes plates, never `UIView`s, because handing it
    /// something that cannot relight itself is the mistake that class exists to prevent).
    private func plate(
        _ symbol: SFSymbol, help: String, action: @escaping () -> Void,
    ) -> SlatePlateIconButton {
        let plate = SlatePlateIconButton(symbol: symbol, action: action)
        plate.slateHelp(help)
        return plate
    }

    /// A MENU rather than a segmented control: the level list does not fit a drawer's width as
    /// segments, and the value is worth showing at rest.
    ///
    /// A bare `UIButton` with a text title, because the design system's menu plate
    /// (``slatePlateMenuButton``) is icon-only by construction — bending it to carry a word would be a
    /// change to that file for one call site. What IS taken from the system is the ROW
    /// (``slateMenuRow``), so no two menus in the app can disagree about what "checked" looks like.
    ///
    /// ⚠️ BUILT AT OPEN, through `UIDeferredMenuElement.uncached`: the check mark is on whichever level
    /// the model holds NOW, and a menu built once at mount would show the level that was current when
    /// the drawer opened.
    private func buildLevel() {
        level.translatesAutoresizingMaskIntoConstraints = false
        level.showsMenuAsPrimaryAction = true
        level.setContentCompressionResistancePriority(.required, for: .horizontal)
        level.slateHelp(AndroidPresentation.consoleLevelHelp)
        level.menu = UIMenu(title: "", children: [
            UIDeferredMenuElement.uncached { [weak self] complete in
                MainActor.assumeIsolated {
                    guard let self else { return complete([]) }
                    complete(AndroidLogLevel.allCases.map { level in
                        slateMenuRow(level.title, checked: level == model.logLevel) { [weak self] in
                            self?.model.setLogLevel(level)
                        }
                    })
                }
            },
        ])
        relabelLevel()
    }

    private func relabelLevel() {
        level.setAttributedTitle(
            NSAttributedString(
                string: model.logLevel.title,
                attributes: [
                    .font: UIFont.systemFont(ofSize: Slate.Typeface.small),
                    .foregroundColor: PhoneAndroidInk.color(.secondary),
                ],
            ),
            for: .normal,
        )
    }

    private func buildField() {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.slateChromeFieldPlate()

        line.onTextChange = { [weak self] text in
            guard let self else { return }
            filter = text
            revealClear()
            redraw()
        }
        clear.alpha = 0

        for view in [line, clear] { field.addSubview(view) }
        NSLayoutConstraint.activate([
            field.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            line.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: Slate.Metric.space2),
            line.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            line.trailingAnchor.constraint(equalTo: clear.leadingAnchor),
            clear.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            clear.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
    }

    /// ⚠️ THE FIELD AND THE STORED FILTER ARE WRITTEN TOGETHER. A programmatic `text =` does not fire
    /// `.editingChanged`, so a tag filter that only wrote the field would narrow nothing, and one that
    /// only wrote the property would leave the box showing the old query.
    private func setFilter(_ text: String) {
        filter = text
        line.text = text
        revealClear()
        redraw()
    }

    private func revealClear() {
        let wanted: CGFloat = filter.isEmpty ? 0 : 1
        guard clear.alpha != wanted else { return }
        UIView.animate(withDuration: Slate.Motion.smallFade.duration) { [weak self] in
            self?.clear.alpha = wanted
        }
    }

    private func toggleFollowing() {
        isFollowing.toggle()
        followPlate.active = isFollowing
        followPlate.slateHelp(AndroidPresentation.consoleFollowHelp(isFollowing: isFollowing))
        scrollToEnd()
    }

    // MARK: Rows

    private func buildRows() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.showsSeparators = false
        rows.setCollectionViewLayout(
            UICollectionViewCompositionalLayout.list(using: configuration), animated: false,
        )
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.backgroundColor = .clear
        rows.delegate = self
        addSubview(rows)

        let cell = LogRegistration { [weak self] cell, _, id in
            guard let self, let line = lines[id] else { return }
            cell.row().configure(line)
        }
        source = UICollectionViewDiffableDataSource<Int, UInt64>(collectionView: rows) { view, path, id in
            view.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
        }
    }

    // MARK: Following the model

    /// ⚠️ `withObservationTracking` fires ONCE per registration, so the callback re-arms by calling
    /// this again on the next main-queue turn. Three reads, all UNCONDITIONAL: a level that is only
    /// read when there are lines stops being observed the moment the log empties.
    private func follow() {
        generation &+= 1
        let generation = generation

        var all: [DeviceLogLine] = []
        var isStarted = false
        var level = AndroidLogLevel.info
        withObservationTracking {
            all = self.model.logLines
            isStarted = self.model.isLogStarted
            level = self.model.logLevel
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        relabelLevel()
        apply(all, isLogStarted: isStarted, level: level)
    }

    /// A filter keystroke, which changes what is DRAWN and nothing the model knows.
    private func redraw() {
        apply(model.logLines, isLogStarted: model.isLogStarted, level: model.logLevel)
    }

    /// ⚠️ ``AndroidPresentation/visible(_:filter:)`` is derived ONCE per pass and threaded through. The
    /// deleted half read it three times — an emptiness test, an animation key and the row list — and it
    /// is a case-insensitive substring test over every retained line: 0.78 ms on a hit and 1.50 ms on a
    /// miss at 600 rows, in a scratch `swiftc -O` harness.
    private func apply(_ all: [DeviceLogLine], isLogStarted: Bool, level: AndroidLogLevel) {
        let shown = AndroidPresentation.visible(all, filter: filter)

        empty.text = AndroidPresentation.consoleEmptyMessage(
            hasLines: !all.isEmpty, isLogStarted: isLogStarted, level: level, filter: filter,
        )
        UIView.animate(withDuration: Slate.Motion.smallFade.duration) { [weak self] in
            self?.empty.alpha = shown.isEmpty ? 1 : 0
        }

        let ids = shown.map(\.id)
        guard ids != drawn else { return }
        drawn = ids
        lines = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Int, UInt64>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        // UNANIMATED. A log is a river: a row arriving is not a state change to narrate, and an
        // insertion animation at logcat's rate is a console that shimmers instead of scrolling.
        source?.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.scrollToEnd()
        }
    }

    /// Scroll to the LAST row, and only while following.
    ///
    /// The deleted half scrolled to a hairline anchor placed after the last row rather than to the row
    /// itself, because a row can be several lines tall and `.bottom` on a tall row leaves its own TOP
    /// edge at the bottom of the view — which reads as a console one message behind. UIKit's
    /// `scrollToItem(at:at:animated:)` with `.bottom` puts the item's BOTTOM edge at the view's bottom,
    /// which is what the anchor was standing in for, so the anchor is gone rather than transliterated.
    private func scrollToEnd() {
        guard isFollowing, let last = drawn.indices.last else { return }
        rows.scrollToItem(at: IndexPath(item: last, section: 0), at: .bottom, animated: false)
    }
}

// MARK: - The row menu

extension PhoneAndroidConsoleView: UICollectionViewDelegate {
    /// WHICH verbs a log row offers is ``AndroidPresentation/menu(for:)``; the two Copy verbs run here
    /// because what "the console" means is this half's own filtered view, and the filter verb runs here
    /// because the field it writes into is view state by design.
    func collectionView(
        _: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let id = source?.itemIdentifier(for: indexPath),
              let line = lines[id]
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: AndroidPresentation.menu(for: line).map { verb in
                slateMenuRow(verb.title) { [weak self] in self?.run(verb, on: line) }
            })
        }
    }

    private func run(_ verb: AndroidLogVerb, on line: DeviceLogLine) {
        switch verb {
        case .copyLine:
            ClientPasteboard.write(AndroidPresentation.plain(line))
        case .copyConsole:
            ClientPasteboard.write(
                drawn.compactMap { lines[$0] }.map(AndroidPresentation.plain).joined(separator: "\n"),
            )
        case let .filterByTag(tag):
            setFilter(tag)
        }
    }
}

// MARK: - One row

/// A cell holding exactly one ``PhoneAndroidLogRow``, minted on first use and reconfigured after.
///
/// A DEDICATED CLASS rather than a bare `UICollectionViewCell` searched for its content: the pool is
/// keyed by class, so the type that comes back out is the type that went in, and the row is found by
/// reading one stored reference instead of scanning `contentView` on every configure.
@MainActor
private final class PhoneAndroidLogCell: UICollectionViewCell {
    private var mounted: PhoneAndroidLogRow?

    func row() -> PhoneAndroidLogRow {
        if let mounted { return mounted }
        let row = PhoneAndroidLogRow()
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Slate.Metric.space2,
            ),
            row.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Slate.Metric.hairline),
            row.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Slate.Metric.hairline,
            ),
        ])
        mounted = row
        return row
    }
}

/// The stamp, the tag and the message. MONOSPACED throughout: a log is columnar data, and a
/// proportional face destroys the one alignment that makes a wall of it scannable.
///
/// The tag rides ABOVE the message rather than beside it, which is the phone's one departure from the
/// Mac's single-text-view drawing: at a phone's width a leading tag column would leave a message four
/// characters wide, and the tag is the field a reader scans down.
@MainActor
private final class PhoneAndroidLogRow: UIView {
    private let time = UILabel()
    private let name = UILabel()
    private let message = UILabel()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let face = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .regular)
        for label in [time, name, message] {
            label.font = face
            label.numberOfLines = 0
        }
        time.textColor = PhoneAndroidInk.color(.tertiary)
        time.numberOfLines = 1
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        message.textColor = PhoneAndroidInk.color(.secondary)

        let words = UIStackView(arrangedSubviews: [name, message])
        words.axis = .vertical
        words.alignment = .fill
        words.spacing = 0

        let run = UIStackView(arrangedSubviews: [time, words])
        run.translatesAutoresizingMaskIntoConstraints = false
        run.axis = .horizontal
        // TOP, not centre: the stamp belongs to the row's first line, and a centred stamp beside a
        // four-line message floats in the middle of it.
        run.alignment = .top
        run.spacing = Slate.Metric.space1
        addSubview(run)
        NSLayoutConstraint.activate([
            run.leadingAnchor.constraint(equalTo: leadingAnchor),
            run.trailingAnchor.constraint(equalTo: trailingAnchor),
            run.topAnchor.constraint(equalTo: topAnchor),
            run.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func configure(_ line: DeviceLogLine) {
        time.text = line.time
        time.isHidden = line.time.isEmpty
        name.text = line.name
        name.isHidden = line.name.isEmpty
        // The tag's ink is the crate's severity scale — COLOUR ONLY FOR A FAILURE. A warning is a grey
        // too: logcat at warning level is dozens of lines a minute of framework noise, so tinting it
        // would spend the alarm colour on the state of nothing being wrong.
        name.textColor = PhoneAndroidInk.color(AndroidPresentation.logInk(line.severity))
        message.text = line.message
        isAccessibilityElement = true
        accessibilityLabel = line.plain
    }
}
#endif

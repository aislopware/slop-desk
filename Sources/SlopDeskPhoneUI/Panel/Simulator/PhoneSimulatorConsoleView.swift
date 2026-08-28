// PhoneSimulatorConsoleView — the device's unified log, under the device.
//
// A DRAWER, not a tab. The reason to read a simulator's log is to see what the thing on screen just
// did, and a console that replaces the screen breaks exactly that loop: tap, watch, read. It takes a
// fixed share of the column so the device above it stays big enough to drive.
//
// THE FILTER IS CLIENT-SIDE and deliberately so. The server takes a `--level` at subscribe time and
// nothing else, so a level change means a reconnect (the model does that); a substring filter must
// NOT, because narrowing the view is the one thing that has to keep the history it is narrowing.
//
// FOLLOW IS A LATCH, not an inferred scroll position. The usual shape — stick to the bottom until the
// reader scrolls away — needs a running opinion about the scroll offset, which goes wrong in exactly
// the burst conditions a console is for. An explicit latch is what Console.app and Xcode both offer,
// it is legible at rest, and it cannot disagree with reality.
//
// ⚠️ THE ROW IS TWO LINES HERE and one on the Mac, which draws its whole log as a single `NSTextView`
// with a hanging indent. That is the width talking: a process name and its message side by side need a
// column, and a phone has one column. The message goes UNDER its process name, and the drawer is a
// list of row views rather than one text view — which is also what makes each line its own Copy target.
//
// Every word, the three empty sentences and their ORDER, the plain-text join and the severity's ink are
// ``SimulatorPresentation/Console``'s — the ordering in particular, because "the filter hid them" and
// "nothing connected" are the two failures this drawer exists to tell apart, and a renderer asking them
// the other way round reports a narrowed console as a dead one.
//
// ⚠️ THE ITEM IDENTITY IS ``DeviceLogLine/id``, which the model assigns and never derives from the
// text. Two identical lines a second apart are two rows, and a content-hash identity would collapse
// them into one — under a diffable data source that is not a cosmetic loss, it is a `NSInternal…`
// duplicate-identifier trap at the first repeated line.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class PhoneSimulatorConsoleView: UIView, UICollectionViewDelegate {
    private let model: SimulatorSidebarModel

    /// Held by the VIEW, not the model: they filter what is drawn and nothing else, they must not
    /// survive a device switch, and putting display state in the model would make a keystroke here an
    /// observable write that redraws the device above.
    private var filter = ""
    private var isFollowing = true

    private let rule = UIView()
    private let strip = UIView()
    private let level = UIButton(type: .custom)
    private let search: SlateSearchLine
    private let clear: UIControl
    private let followPlate: SlatePlateIconButton
    private let collection: UICollectionView
    private var source: UICollectionViewDiffableDataSource<Int, UInt64>!
    private let empty = UILabel()

    /// The lines as last drawn, by identity — the diffable source deals in `UInt64`s and the cell, the
    /// Copy verb and the whole-console join all have to get back to a line from one.
    private var lines: [UInt64: DeviceLogLine] = [:]
    private var order: [UInt64] = []

    /// ⚠️ `[weak self]` stops the chain when the view dies; it does not SUPERSEDE a live arm. This
    /// follower is re-run by a keystroke as well as by an arriving line, so without the counter a typed
    /// filter would leave one extra chain per character, each re-arming on every log line.
    private var generation = 0

    init(model: SimulatorSidebarModel) {
        self.model = model
        search = SlateSearchLine(placeholder: SimulatorPresentation.Console.filterPlaceholder)
        var clearAction: (() -> Void)?
        clear = PhoneDevicePanelChrome.clearKey(ink: Slate.Native.Text.icon) { clearAction?() }
        // ONE GLYPH ACROSS THE LATCH — the crate ships the plate once and the two sentences beside it,
        // because a latched plate is already drawn as a lit key and swapping the arrow for a slashed
        // arrow would say "off" twice. So the symbol is read once here and only `active` and the help
        // string move afterwards.
        var toggle: (() -> Void)?
        followPlate = SlatePlateIconButton(
            symbol: SimulatorPresentation.Console.follow(isFollowing: true).symbol,
        ) { toggle?() }
        collection = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The ground — the drawer is part of the sunken panel, not a lit surface inside it (ONE ISLAND,
        // law 1). Its top edge is the hairline below, which is the whole reason the rule is drawn here
        // rather than left to a tone change: the drawer opens over the stage, so it needs an edge.
        backgroundColor = Slate.Native.Surface.field

        clearAction = { [weak self] in
            self?.search.text = ""
            self?.retype("")
        }
        search.onTextChange = { [weak self] text in self?.retype(text) }
        toggle = { [weak self] in self?.toggleFollow() }
        followPlate.active = isFollowing
        followPlate.slateHelp(SimulatorPresentation.Console.follow(isFollowing: isFollowing).help)

        buildStrip()
        buildCollection()
        refreshClear(animated: false)
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Controls

    /// The drawer's own head, one rung ABOVE the rows it sits on — `raised`, a translucent tint over the
    /// panel's cream rather than a tone borrowed from elsewhere. Clear and Hide ride one tray: both
    /// destroy what is on screen (one the history, one the drawer), which is the pairing worth making at
    /// a glance. Follow stays loose beside them because it LATCHES, and a lit key only reads as lit
    /// against the panel's own tone.
    private func buildStrip() {
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.backgroundColor = Slate.Native.Line.divider

        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.backgroundColor = Slate.Native.Surface.raised

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        // The INSTRUMENT voice (MERIDIAN L2) — mono plus wide tracking, the "engraved on the tool"
        // register. `UILabel` has no tracking property, so it is spelled as a per-string `.kern`.
        title.attributedText = NSAttributedString(
            string: SimulatorPresentation.Console.title,
            attributes: [
                .font: Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .semibold),
                .kern: Slate.Typeface.instrumentTracking,
                .foregroundColor: Slate.Native.State.header,
            ],
        )
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentHuggingPriority(.required, for: .horizontal)

        // A menu rather than a segmented control: five levels do not fit this width as segments, and
        // the value is worth showing at rest — which a menu label does and a segmented picker only does
        // by highlighting one of five things too small to read.
        level.titleLabel?.font = .systemFont(ofSize: Slate.Typeface.small)
        level.setTitleColor(Slate.Native.Text.secondary, for: .normal)
        level.showsMenuAsPrimaryAction = true
        level.setContentCompressionResistancePriority(.required, for: .horizontal)
        level.setContentHuggingPriority(.required, for: .horizontal)
        level.slateHelp(SimulatorPresentation.Console.levelHelp)

        let tray = SlatePlateTray([
            SlatePlateIconButton(symbol: SimulatorPresentation.Console.clear.symbol) { [model] in
                model.clearLog()
            },
            SlatePlateIconButton(symbol: SimulatorPresentation.Console.hide.symbol) { [model] in
                model.toggleConsole()
            },
        ])
        tray.arrangedSubviews.first?.slateHelp(SimulatorPresentation.Console.clear.help)
        tray.arrangedSubviews.last?.slateHelp(SimulatorPresentation.Console.hide.help)

        let plate = UIView()
        plate.translatesAutoresizingMaskIntoConstraints = false
        let field = UIStackView(arrangedSubviews: [search, clear])
        field.translatesAutoresizingMaskIntoConstraints = false
        field.axis = .horizontal
        field.alignment = .center
        field.spacing = Slate.Metric.space1
        plate.addSubview(field)
        plate.slateChromeFieldPlate()

        let run = UIStackView(arrangedSubviews: [title, level, plate, followPlate, tray])
        run.translatesAutoresizingMaskIntoConstraints = false
        run.axis = .horizontal
        run.alignment = .center
        run.spacing = Slate.Metric.space2

        strip.addSubview(run)
        addSubview(strip)
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
            run.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: Slate.Metric.space2),
            run.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -Slate.Metric.space2),
            run.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            plate.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            field.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: Slate.Metric.space2),
            field.trailingAnchor.constraint(
                equalTo: plate.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            field.topAnchor.constraint(equalTo: plate.topAnchor),
            field.bottomAnchor.constraint(equalTo: plate.bottomAnchor),
        ])
        // The rule sits ON TOP of the strip's own fill: the strip paints `raised` edge to edge and the
        // hairline is the drawer's boundary, not a gap in it.
        bringSubviewToFront(rule)
    }

    private func buildCollection() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        collection.setCollectionViewLayout(
            UICollectionViewCompositionalLayout.list(using: configuration), animated: false,
        )
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = .clear
        collection.delegate = self
        collection.allowsSelection = false
        collection.keyboardDismissMode = .onDrag
        collection.register(
            PhoneSimulatorLogRowCell.self,
            forCellWithReuseIdentifier: PhoneSimulatorLogRowCell.reuseIdentifier,
        )

        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.font = .systemFont(ofSize: Slate.Typeface.footnote)
        empty.textColor = Slate.Native.Text.tertiary
        empty.textAlignment = .center
        empty.numberOfLines = 0

        addSubview(collection)
        addSubview(empty)
        NSLayoutConstraint.activate([
            collection.topAnchor.constraint(equalTo: strip.bottomAnchor),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            empty.centerYAnchor.constraint(equalTo: collection.centerYAnchor),
        ])

        source = UICollectionViewDiffableDataSource<Int, UInt64>(
            collectionView: collection,
        ) { [weak self] view, indexPath, identity in
            guard let self, let line = lines[identity],
                  let cell = view.dequeueReusableCell(
                      withReuseIdentifier: PhoneSimulatorLogRowCell.reuseIdentifier, for: indexPath,
                  ) as? PhoneSimulatorLogRowCell
            else { return UICollectionViewCell() }
            cell.show(line)
            return cell
        }
    }

    // MARK: Observation

    /// ONE follower, because one thing is rebuilt: the rows. The level menu and the empty sentence are
    /// both derived from the same pass, so splitting them would be two wake-ups for one arriving line.
    private func follow() {
        generation &+= 1
        let generation = generation
        var shown: [DeviceLogLine] = []
        var hasLines = false
        var isStarted = false
        var chosen = SimulatorLogLevel.info
        withObservationTracking {
            let all = self.model.logLines
            hasLines = !all.isEmpty
            isStarted = self.model.isLogStarted
            chosen = self.model.logLevel
            shown = SimulatorPresentation.Console.visible(all, filter: self.filter)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }
        relevel(chosen)
        refill(shown, hasLines: hasLines, isStarted: isStarted, level: chosen)
    }

    /// The level's rows, rebuilt each pass so the check mark follows the model rather than a copy of it.
    /// Resolved by VALUE and never by index: a menu that maps a tapped position back into
    /// `allCases` is one reordering away from setting the wrong level.
    private func relevel(_ chosen: SimulatorLogLevel) {
        level.setTitle(chosen.title, for: .normal)
        level.menu = UIMenu(children: SimulatorLogLevel.allCases.map { option in
            // The check is the menu's own affordance for a chosen row; drawing the state any other way
            // would give one control two vocabularies.
            slateMenuRow(option.title, checked: option == chosen) { [model] in
                model.setLogLevel(option)
            }
        })
    }

    /// ⚠️ `visible` is derived ONCE per pass and threaded in. It was read three times in the deleted
    /// half — the emptiness test, the animation key and the `ForEach` — and it is a filter over EVERY
    /// retained line. Measured at `SimulatorSidebarModel.logCapacity` = 600 rows, the derivation cost
    /// 0.87 ms when the needle hit and 1.66 ms when it missed, and a miss is the state every keystroke
    /// passes through. The predicate is ``SimulatorPresentation/Console/visible(_:filter:)`` now and one
    /// derivation is 0.11–0.13 ms, but the single evaluation stays for the reason it was written: it is
    /// not a cache, it is the second and third evaluations deleted.
    private func refill(
        _ shown: [DeviceLogLine], hasLines: Bool, isStarted: Bool, level chosen: SimulatorLogLevel,
    ) {
        lines = [:]
        order = []
        for line in shown {
            lines[line.id] = line
            order.append(line.id)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, UInt64>()
        snapshot.appendSections([0])
        snapshot.appendItems(order, toSection: 0)
        // NEVER animated. A console at full tilt appends dozens of lines a second, and an animated
        // append is a drawer that spends its whole life mid-transition.
        source.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.scrollToBottom()
        }

        // Three states, three sentences, in
        // ``SimulatorPresentation/Console/empty(hasLines:isStarted:level:filter:)``'s order — a
        // non-empty history with nothing visible is the FILTER's doing and must be said first.
        empty.text = SimulatorPresentation.Console.empty(
            hasLines: hasLines, isStarted: isStarted, level: chosen, filter: filter,
        )
        // The waiting sentence and the log cross-fade rather than replace each other: the first line to
        // arrive after a subscribe swaps a centred sentence for a wall of mono text, and cut hard it
        // reads as the drawer being rebuilt. Keyed on EMPTINESS alone.
        let wanted: CGFloat = shown.isEmpty ? 1 : 0
        guard empty.alpha != wanted else { return }
        phoneSimulatorAnimate(Slate.Motion.smallFade) { [empty, collection] in
            empty.alpha = wanted
            collection.alpha = 1 - wanted
        }
    }

    private func scrollToBottom() {
        guard isFollowing, let last = order.indices.last else { return }
        // The LAST ROW, not a hairline anchor: a collection view scrolls an item to a stated edge, so
        // `.bottom` puts the row's own bottom at the drawer's — which is the thing the deleted half
        // needed a zero-height spacer to say inside a `ScrollViewReader`.
        collection.scrollToItem(
            at: IndexPath(item: last, section: 0), at: .bottom, animated: false,
        )
    }

    private func toggleFollow() {
        isFollowing.toggle()
        let reading = SimulatorPresentation.Console.follow(isFollowing: isFollowing)
        followPlate.active = isFollowing
        followPlate.slateHelp(reading.help)
        scrollToBottom()
    }

    private func retype(_ text: String) {
        guard text != filter else { return }
        let wasEmpty = filter.isEmpty
        filter = text
        if wasEmpty != text.isEmpty { refreshClear(animated: true) }
        // Re-derived immediately rather than waiting for the next line: a filter that only took effect
        // on the next arriving message would look broken on an idle device.
        follow()
    }

    private func refreshClear(animated: Bool) {
        let wanted: CGFloat = filter.isEmpty ? 0 : 1
        guard animated else {
            clear.alpha = wanted
            return
        }
        phoneSimulatorAnimate(Slate.Motion.smallFade) { [clear] in
            clear.alpha = wanted
        }
    }

    // MARK: Copy

    func collectionView(
        _: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let identity = source.itemIdentifier(for: indexPath),
              let line = lines[identity] else { return nil }
        // ⚠️ Only the STRINGS are captured, never `self` or the line: the menu outlives the gesture.
        let one = SimulatorPresentation.Console.plain(line)
        let all = order.compactMap { lines[$0] }
            .map(SimulatorPresentation.Console.plain).joined(separator: "\n")
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                slateMenuRow(SimulatorPresentation.Console.copyLine) {
                    ClientPasteboard.write(one)
                },
                slateMenuRow(SimulatorPresentation.Console.copyConsole) {
                    ClientPasteboard.write(all)
                },
            ])
        }
    }
}

// MARK: - One line

/// A log line: its time, and its message UNDER the process that emitted it.
///
/// MONOSPACED throughout — a log is columnar data, and a proportional face destroys the one alignment
/// that makes a wall of it scannable.
@MainActor
final class PhoneSimulatorLogRowCell: UICollectionViewCell {
    static let reuseIdentifier = "PhoneSimulatorLogRowCell"

    private let time = UILabel()
    private let name = UILabel()
    private let message = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let face = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .regular)
        for label in [time, name, message] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = face
            label.numberOfLines = 0
        }
        time.textColor = Slate.Native.Text.tertiary
        time.numberOfLines = 1
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        message.textColor = Slate.Native.Text.secondary

        let body = UIStackView(arrangedSubviews: [name, message])
        body.translatesAutoresizingMaskIntoConstraints = false
        body.axis = .vertical
        body.alignment = .leading
        body.spacing = 0

        let row = UIStackView(arrangedSubviews: [time, body])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Slate.Metric.space1

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
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(_ line: DeviceLogLine) {
        time.text = line.time
        time.isHidden = line.time.isEmpty
        name.text = line.name
        name.isHidden = line.name.isEmpty
        name.textColor = PhoneSimulatorInk.color(
            SimulatorPresentation.Console.ink(for: line.severity),
        )
        message.text = line.message
    }
}
#endif

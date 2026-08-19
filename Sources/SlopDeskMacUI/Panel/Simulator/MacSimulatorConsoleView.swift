// MacSimulatorConsoleView — the device's unified log, under the device, in AppKit (docs/56 stage D,
// increment 52a).
//
// A DRAWER, not a tab. The reason to read a simulator's log is to see what the thing on screen just
// did, and a console that replaces the screen breaks exactly that loop: tap, watch, read. It takes a
// fixed share of the column (`Slate.Metric.heightDrawer`) so the device above it stays big enough to
// drive, and the caller owns that height for the same reason the SwiftUI half does.
//
// THE FILTER IS CLIENT-SIDE and deliberately so. The server takes a `--level` at subscribe time and
// nothing else, so a level change means a reconnect (the model does that); a substring filter must NOT,
// because narrowing the view is the one thing that has to keep the history it is narrowing.
//
// FOLLOW IS A LATCH, not an inferred scroll position. The usual shape — stick to the bottom until the
// reader scrolls away — needs the scroll offset, and an inferred latch goes wrong in exactly the burst
// conditions a console is for. An explicit latch is what Console.app and Xcode both offer, it is
// legible at rest, and it cannot disagree with reality.
//
// ## ONE TEXT VIEW, not six hundred row views — the one place this drawing deliberately differs
//
// The phone draws a `LazyVStack` of row views. Here the rows are RUNS in a single `NSTextView`, and
// that is a measurement rather than a preference: the model keeps `SimulatorSidebarModel.logCapacity`
// (600) rows and a device under load fills them in under a minute, so the AppKit equivalent would be
// six hundred `NSView`s rebuilt on every ~50 ms server batch. A text view lays that out as text, which
// is what it is.
//
// What the swap costs is the two-line arrangement (the phone puts the message UNDER its process name),
// and what pays for it is a hanging indent: a wrapped message aligns under its own column, so the
// three fields still read as three columns. Everything else the row said is intact — the mono face
// (a log is columnar data, and a proportional face destroys the one alignment that makes a wall of it
// scannable), the three inks, the per-line Copy and the whole-console Copy.

import AppKit
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

@MainActor
final class MacSimulatorConsoleView: NSView {
    private let model: SimulatorSidebarModel

    /// Held by the VIEW, not the model: it filters what is drawn and nothing else, it must not survive
    /// a device switch, and putting display state in the model would make a keystroke here an
    /// observable write that redraws the device above.
    private var filter = ""
    private var isFollowing = true

    private let scroller = NSScrollView()
    private let text = MacSimulatorConsoleText()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let level = NSPopUpButton()
    private let followPlate: MacPlateIconButton

    init(model: SimulatorSidebarModel) {
        self.model = model
        followPlate = MacPlateIconButton(
            symbolName: SimulatorPresentation.Console.follow(isFollowing: true).symbolName,
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The GROUND — the drawer is part of the sunken panel, not a lit surface inside it (ONE ISLAND,
        // law 1). Its top edge is the hairline below, which is why the rule is drawn rather than left
        // to a tone change: the drawer opens over the stage, so it needs an edge of its own either way.
        layer?.backgroundColor = Slate.Native.Surface.field.cgColor

        let strip = buildStrip()
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Slate.Native.Line.divider.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        buildText()
        emptyLabel.font = .systemFont(ofSize: Slate.Typeface.footnote)
        emptyLabel.textColor = Slate.Native.Text.tertiary
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(strip)
        addSubview(rule)
        addSubview(scroller)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),

            strip.topAnchor.constraint(equalTo: rule.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: Slate.Metric.heightBar),

            scroller.topAnchor.constraint(equalTo: strip.bottomAnchor),
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroller.centerYAnchor),
            emptyLabel.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor, constant: -Slate.Metric.space3 * 2,
            ),
        ])
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: The head of the drawer

    /// The drawer's own head, one rung ABOVE the rows it sits on — `raised`, a translucent tint over
    /// the panel's cream rather than a tone borrowed from elsewhere, which is what separates the head
    /// from the log once both stand on the same ground.
    ///
    /// Clear and Hide ride ONE tray — both destroy what is on screen (one the history, one the drawer),
    /// which is the pairing worth making at a glance. Follow stays loose beside them because it
    /// LATCHES, and a lit key only reads as lit against the panel's own tone rather than inside a tray.
    private func buildStrip() -> NSView {
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.wantsLayer = true
        strip.layer?.backgroundColor = Slate.Native.Surface.raised.cgColor

        let title = macSimulatorCapsLabel(SimulatorPresentation.Console.title)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        buildLevelMenu()

        let search = MacSimulatorSearchPlate(
            placeholder: SimulatorPresentation.Console.filterPlaceholder,
        ) { [weak self] query in
            self?.filter = query
            self?.refill()
        }

        followPlate.active = isFollowing
        followPlate.toolTip = SimulatorPresentation.Console.follow(isFollowing: isFollowing).help
        followPlate.onClick = { [weak self] in self?.toggleFollow() }

        let clear = MacPlateIconButton(symbolName: SimulatorPresentation.Console.clear.symbolName)
        clear.toolTip = SimulatorPresentation.Console.clear.help
        clear.onClick = { [weak self] in self?.model.clearLog() }

        let hide = MacPlateIconButton(symbolName: SimulatorPresentation.Console.hide.symbolName)
        hide.toolTip = SimulatorPresentation.Console.hide.help
        hide.onClick = { [weak self] in self?.model.toggleConsole() }

        let row = NSStackView(views: [
            title, level, search, followPlate, MacSimulatorPlateTray([clear, hide]),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: Slate.Metric.space2),
            row.trailingAnchor.constraint(
                equalTo: strip.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            row.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
        return strip
    }

    /// A MENU rather than a segmented control: five levels do not fit a drawer's width as segments, and
    /// the value is worth showing at rest — which a menu label does and a segmented picker only does by
    /// highlighting one of five things too small to read.
    private func buildLevelMenu() {
        level.isBordered = false
        level.font = .systemFont(ofSize: Slate.Typeface.small)
        level.contentTintColor = Slate.Native.Text.secondary
        level.toolTip = SimulatorPresentation.Console.levelHelp
        level.target = self
        level.action = #selector(pickLevel)
        level.translatesAutoresizingMaskIntoConstraints = false
        level.setContentHuggingPriority(.required, for: .horizontal)
        for option in SimulatorLogLevel.allCases { level.addItem(withTitle: option.title) }
        level.selectItem(withTitle: model.logLevel.title)
    }

    /// Resolved to a LEVEL VALUE rather than to a menu index, the same rule `MacOnLaunchRadios` records
    /// for its picker: an index is right until the list gains a case, and the list here is the server's.
    @objc
    private func pickLevel() {
        guard let title = level.titleOfSelectedItem,
              let picked = SimulatorLogLevel.allCases.first(where: { $0.title == title })
        else { return }
        model.setLogLevel(picked)
    }

    private func toggleFollow() {
        isFollowing.toggle()
        followPlate.active = isFollowing
        followPlate.toolTip = SimulatorPresentation.Console.follow(isFollowing: isFollowing).help
        scrollToEnd()
    }

    // MARK: The log itself

    private func buildText() {
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(
            width: Slate.Metric.space2, height: Slate.Metric.space1,
        )
        text.textContainer?.widthTracksTextView = true
        text.onCopyConsole = { [weak self] in self?.copyConsole() }

        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.hasVerticalScroller = true
        scroller.drawsBackground = false
        scroller.documentView = text
    }

    /// The one observation: everything the drawer draws is read INSIDE the tracking block, and it
    /// re-arms itself on every read it took. A read left outside is a console that stops updating for
    /// one reason only, which is the failure mode that survives every test.
    private func follow() {
        var lines: [DeviceLogLine] = []
        var started = false
        var chosen = SimulatorLogLevel.info
        withObservationTracking {
            lines = self.model.logLines
            started = self.model.isLogStarted
            chosen = self.model.logLevel
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        rows = lines
        isStarted = started
        if level.titleOfSelectedItem != chosen.title { level.selectItem(withTitle: chosen.title) }
        refill()
    }

    private var rows: [DeviceLogLine] = []
    private var isStarted = false

    /// Case-insensitive substring over the whole row — process included, since "which process is
    /// spamming this" is as common a question as "where is my message".
    private var visible: [DeviceLogLine] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter {
            $0.message.localizedCaseInsensitiveContains(trimmed)
                || $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func refill() {
        let visible = visible
        emptyLabel.isHidden = !visible.isEmpty
        scroller.isHidden = visible.isEmpty
        guard !visible.isEmpty else {
            emptyLabel.stringValue = SimulatorPresentation.Console.empty(
                hasLines: !rows.isEmpty, isStarted: isStarted, level: model.logLevel, filter: filter,
            )
            text.load(rows: [], attributed: NSAttributedString())
            return
        }
        let (body, ranges) = render(visible)
        text.load(rows: ranges, attributed: body)
        scrollToEnd()
    }

    /// One paragraph per row: the time, the emitter, the message. A HANGING INDENT so a wrapped message
    /// aligns under its own column rather than under the timestamp — that indent is what buys the
    /// column reading the phone's two-line row gets from its stack.
    private func render(_ lines: [DeviceLogLine]) -> (NSAttributedString, [MacSimulatorConsoleRow]) {
        let font = Slate.Typeface.instrumentNative(Slate.Typeface.small)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // Measured off the face rather than guessed: the time field is 12 characters and the gap one,
        // so the continuation rail is thirteen advances of the mono face in use.
        paragraph.headIndent = font.maximumAdvancement.width * 13
        paragraph.paragraphSpacing = Slate.Metric.hairline

        let body = NSMutableAttributedString()
        var ranges: [MacSimulatorConsoleRow] = []
        for line in lines {
            let start = body.length
            append(body, line.time.isEmpty ? "" : line.time + " ", font, Slate.Native.Text.tertiary)
            append(
                body, line.name.isEmpty ? "" : line.name + " ", font,
                MacSimulatorInk.color(SimulatorPresentation.Console.ink(for: line.severity)),
            )
            append(body, line.message + "\n", font, Slate.Native.Text.secondary)
            body.addAttribute(
                .paragraphStyle, value: paragraph,
                range: NSRange(location: start, length: body.length - start),
            )
            ranges.append(MacSimulatorConsoleRow(
                range: NSRange(location: start, length: body.length - start), line: line,
            ))
        }
        return (body, ranges)
    }

    private func append(
        _ body: NSMutableAttributedString, _ words: String, _ font: NSFont, _ ink: NSColor,
    ) {
        guard !words.isEmpty else { return }
        body.append(NSAttributedString(
            string: words, attributes: [.font: font, .foregroundColor: ink],
        ))
    }

    /// The latch, honoured. Scrolled to the DOCUMENT's end rather than to the last row: a row can be
    /// several lines tall, and stopping at its top edge reads as a console one message behind.
    private func scrollToEnd() {
        guard isFollowing else { return }
        text.scrollToEndOfDocument(nil)
    }

    private func copyConsole() {
        ClientPasteboard.write(
            visible.map(SimulatorPresentation.Console.plain).joined(separator: "\n"),
        )
    }
}

/// One rendered row and the character range it occupies — what turns a right-click into a Copy Line.
struct MacSimulatorConsoleRow {
    let range: NSRange
    let line: DeviceLogLine
}

/// The log's text view: everything ordinary, plus the two Copy verbs the phone's row context menu has.
@MainActor
final class MacSimulatorConsoleText: NSTextView {
    private var rows: [MacSimulatorConsoleRow] = []
    var onCopyConsole: (() -> Void)?

    func load(rows: [MacSimulatorConsoleRow], attributed: NSAttributedString) {
        self.rows = rows
        textStorage?.setAttributedString(attributed)
    }

    /// Built per click rather than stored, and keyed on WHERE the click landed — "Copy Line" has to
    /// mean the line under the pointer, which is the one thing a menu built once cannot know.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let menu = NSMenu()
        if let row = rows.first(where: { NSLocationInRange(index, $0.range) }) {
            let item = NSMenuItem(
                title: SimulatorPresentation.Console.copyLine,
                action: #selector(copyLine), keyEquivalent: "",
            )
            item.target = self
            item.representedObject = SimulatorPresentation.Console.plain(row.line)
            menu.addItem(item)
        }
        let all = NSMenuItem(
            title: SimulatorPresentation.Console.copyConsole,
            action: #selector(copyEverything), keyEquivalent: "",
        )
        all.target = self
        menu.addItem(all)
        return menu
    }

    @objc
    private func copyLine(_ sender: NSMenuItem) {
        guard let words = sender.representedObject as? String else { return }
        ClientPasteboard.write(words)
    }

    @objc
    private func copyEverything() { onCopyConsole?() }
}

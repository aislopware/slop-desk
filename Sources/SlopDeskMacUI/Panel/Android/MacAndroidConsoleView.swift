// MacAndroidConsoleView — `logcat`, under the device, in AppKit (docs/56 stage D, increment 52b).
//
// The Mac's half of ``AndroidConsoleView``. The filter, the three empty sentences, the plain-text form
// a Copy hands over, the row menu and the severity→ink table are ``AndroidPresentation``'s and shared
// with the phone.
//
// A DRAWER, not a tab. The reason to read a device's log is to see what the thing on screen just did,
// and a console that replaces the screen breaks exactly that loop: tap, watch, read. It takes a fixed
// share of the column (`Slate.Metric.heightDrawer`) so the device above it stays big enough to drive,
// and the caller owns that height for the same reason the SwiftUI half does.
//
// THE FILTER IS CLIENT-SIDE and the LEVEL is not, which is a sharper split here than on the simulator
// panel: `logcat`'s filter spec is fixed at spawn, so a level change is a NEW CHILD PROCESS, while a
// substring filter must not reconnect — narrowing the view is the one thing that has to keep the
// history it is narrowing.
//
// THE TAG COLUMN IS THE ANDROID DIFFERENCE. `logcat` carries the WHOLE system, not one process, so a
// quiet app's console is still hundreds of lines a minute of `ActivityManager`, `WindowManager` and
// the rest. The tag is what makes that navigable, so it is drawn as its own run, the filter searches
// it, and a right-click on a row offers to filter BY it — the one filter action worth a menu slot,
// because typing a tag into the field is the step it removes.
//
// ## ONE TEXT VIEW, not six hundred row views — the one place this drawing deliberately differs
//
// The phone draws a `LazyVStack` of row views. Here the rows are RUNS in a single `NSTextView`, and
// that is a measurement rather than a preference: the model keeps `AndroidSidebarModel.logCapacity`
// (600) rows and a device under load fills them in well under a minute — faster than the simulator's,
// since `logcat` is the whole system — so the AppKit equivalent would be six hundred `NSView`s rebuilt
// on every server batch. A text view lays that out as text, which is what it is.
//
// What the swap costs is the two-line arrangement (the phone puts the message UNDER its tag), and what
// pays for it is a hanging indent: a wrapped message aligns under its own column, so the three fields
// still read as three columns. Everything else the row said is intact — the mono face (a log is
// columnar data, and a proportional face destroys the one alignment that makes a wall of it
// scannable), the three inks, and all three verbs of the row menu.

import AppKit
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

@MainActor
final class MacAndroidConsoleView: NSView {
    private let model: AndroidSidebarModel

    /// Held by the VIEW, not the model: it filters what is drawn and nothing else, it must not survive
    /// a device switch, and putting display state in the model would make a keystroke here an
    /// observable write that redraws the device above.
    private var filter = ""
    private var isFollowing = true

    private let scroller = NSScrollView()
    private let text = MacAndroidConsoleText()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let level = NSPopUpButton()
    private let followPlate: MacPlateIconButton
    private var search: MacDevicePanelSearchPlate?

    init(model: AndroidSidebarModel) {
        self.model = model
        followPlate = MacPlateIconButton(
            symbolName: AndroidPresentation.consoleFollowSymbol.rawValue,
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
        emptyLabel.textColor = MacAndroidInk.color(.tertiary)
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        }
    }

    // MARK: The head of the drawer

    /// The drawer's own head, one rung ABOVE the rows it sits on — `raised`, a translucent tint over
    /// the panel's cream rather than a tone borrowed from elsewhere, which is what separates the head
    /// from the log once both stand on the same ground.
    ///
    /// Clear and Hide ride ONE tray — both destroy what is on screen (one the history, one the drawer),
    /// which is the pairing worth making at a glance. Follow stays loose beside them because it
    /// LATCHES, and a lit key only reads as lit against the panel's own tone rather than inside a tray.
    private func buildStrip() -> NSView {
        let strip = MacAndroidStripBed()
        strip.translatesAutoresizingMaskIntoConstraints = false

        let title = macDevicePanelCapsLabel(AndroidPresentation.consoleTitle)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        buildLevelMenu()

        let search = MacDevicePanelSearchPlate(
            placeholder: AndroidPresentation.consoleFilterPlaceholder,
        ) { [weak self] query in
            self?.filter = query
            self?.refill()
        }
        self.search = search

        followPlate.active = isFollowing
        followPlate.toolTip = AndroidPresentation.consoleFollowHelp(isFollowing: isFollowing)
        followPlate.onClick = { [weak self] in self?.toggleFollow() }

        let clear = MacPlateIconButton(
            symbolName: AndroidPresentation.consoleClearSymbol.rawValue,
        )
        clear.toolTip = AndroidPresentation.consoleClearHelp
        clear.onClick = { [weak self] in self?.model.clearLog() }

        let hide = MacPlateIconButton(symbolName: AndroidPresentation.consoleHideSymbol.rawValue)
        hide.toolTip = AndroidPresentation.consoleHideHelp
        hide.onClick = { [weak self] in self?.model.toggleConsole() }

        let row = NSStackView(views: [
            title, level, search, followPlate, MacDevicePanelPlateTray([clear, hide]),
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

    /// A MENU rather than a segmented control: the level list does not fit a drawer's width as segments,
    /// and the value is worth showing at rest — which a menu label does and a segmented picker only does
    /// by highlighting one of several things too small to read. The count is androidd's, not a number
    /// this view may assume: it went from five to six the day the menu stopped keeping its own list.
    private func buildLevelMenu() {
        level.isBordered = false
        level.font = .systemFont(ofSize: Slate.Typeface.small)
        level.contentTintColor = MacAndroidInk.color(.secondary)
        level.toolTip = AndroidPresentation.consoleLevelHelp
        level.target = self
        level.action = #selector(pickLevel)
        level.translatesAutoresizingMaskIntoConstraints = false
        level.setContentHuggingPriority(.required, for: .horizontal)
        for option in AndroidLogLevel.allCases { level.addItem(withTitle: option.title) }
        level.selectItem(withTitle: model.logLevel.title)
    }

    /// Resolved to a LEVEL VALUE rather than to a menu index, the same rule `MacOnLaunchRadios` records
    /// for its picker: an index is right until the list gains a case, and this list is `logcat`'s.
    @objc
    private func pickLevel() {
        guard let title = level.titleOfSelectedItem,
              let picked = AndroidLogLevel.allCases.first(where: { $0.title == title })
        else { return }
        model.setLogLevel(picked)
    }

    private func toggleFollow() {
        isFollowing.toggle()
        followPlate.active = isFollowing
        followPlate.toolTip = AndroidPresentation.consoleFollowHelp(isFollowing: isFollowing)
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
        // The tag filter writes the FIELD rather than the private `filter`, so the plate's clear
        // affordance and its text agree with what is being filtered — a menu verb that filtered
        // silently would leave a console showing one tag with an empty search box.
        text.onFilterByTag = { [weak self] tag in self?.search?.setQuery(tag) }

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
        var chosen = AndroidLogLevel.info
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

    private var visible: [DeviceLogLine] {
        AndroidPresentation.visible(rows, filter: filter)
    }

    private func refill() {
        let visible = visible
        emptyLabel.isHidden = !visible.isEmpty
        scroller.isHidden = visible.isEmpty
        guard !visible.isEmpty else {
            emptyLabel.stringValue = AndroidPresentation.consoleEmptyMessage(
                hasLines: !rows.isEmpty, isLogStarted: isStarted,
                level: model.logLevel, filter: filter,
            )
            text.load(rows: [], attributed: NSAttributedString())
            return
        }
        let (body, ranges) = render(visible)
        text.load(rows: ranges, attributed: body)
        scrollToEnd()
    }

    /// One paragraph per row: the time, the tag, the message. A HANGING INDENT so a wrapped message
    /// aligns under its own column rather than under the timestamp — that indent is what buys the
    /// column reading the phone's two-line row gets from its stack.
    private func render(_ lines: [DeviceLogLine]) -> (NSAttributedString, [MacAndroidConsoleRow]) {
        let font = Slate.Typeface.instrumentNative(Slate.Typeface.small)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // Measured off the FACE rather than guessed: `logcat`'s time field is `MM-DD HH:MM:SS.mmm`,
        // eighteen characters, and the gap after it one — so the continuation rail is nineteen
        // advances of the mono face in use. (The simulator's is thirteen; its stamp is shorter.)
        paragraph.headIndent = font.maximumAdvancement.width * 19
        paragraph.paragraphSpacing = Slate.Metric.hairline

        let body = NSMutableAttributedString()
        var ranges: [MacAndroidConsoleRow] = []
        for line in lines {
            let start = body.length
            append(body, line.time.isEmpty ? "" : line.time + " ", font, MacAndroidInk.color(.tertiary))
            append(
                body, line.name.isEmpty ? "" : line.name + " ", font,
                MacAndroidInk.color(AndroidPresentation.logInk(line.severity)),
            )
            append(body, line.message + "\n", font, MacAndroidInk.color(.secondary))
            body.addAttribute(
                .paragraphStyle, value: paragraph,
                range: NSRange(location: start, length: body.length - start),
            )
            ranges.append(MacAndroidConsoleRow(
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
        ClientPasteboard.write(visible.map(AndroidPresentation.plain).joined(separator: "\n"))
    }
}

/// The drawer's head, as its own class only so its fill can follow the appearance — a `CALayer` holds
/// a FLAT `CGColor`, so a dynamic `NSColor` resolved once at build time is the light theme's tint
/// forever.
@MainActor
private final class MacAndroidStripBed: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Slate.Native.Surface.raised.cgColor
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.raised.cgColor
        }
    }
}

/// One rendered row and the character range it occupies — what turns a right-click into a Copy Line
/// or a Filter by Tag.
struct MacAndroidConsoleRow {
    let range: NSRange
    let line: DeviceLogLine
}

/// The log's text view: everything ordinary, plus the three verbs the phone's row context menu has.
@MainActor
final class MacAndroidConsoleText: NSTextView {
    private var rows: [MacAndroidConsoleRow] = []
    var onCopyConsole: (() -> Void)?
    var onFilterByTag: ((String) -> Void)?

    func load(rows: [MacAndroidConsoleRow], attributed: NSAttributedString) {
        self.rows = rows
        textStorage?.setAttributedString(attributed)
    }

    /// Built per click rather than stored, and keyed on WHERE the click landed — "Copy Line" and
    /// "Filter by ActivityManager" both have to mean the line under the pointer, which is the one
    /// thing a menu built once cannot know.
    ///
    /// The verb TABLE is ``AndroidPresentation/menu(for:)``'s, including whether the tag item appears
    /// at all: a menu whose length depends on the row is exactly the kind of rule that grows an extra
    /// case on one half and is silent until two screens sit side by side.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard let row = rows.first(where: { NSLocationInRange(index, $0.range) }) else { return nil }
        let menu = NSMenu()
        for verb in AndroidPresentation.menu(for: row.line) {
            let item = NSMenuItem(title: verb.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MacAndroidLogVerbBox(verb: verb, line: row.line)
            menu.addItem(item)
        }
        return menu
    }

    @objc
    private func run(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MacAndroidLogVerbBox else { return }
        switch box.verb {
        case .copyLine:
            ClientPasteboard.write(AndroidPresentation.plain(box.line))
        case .copyConsole:
            // The whole CONSOLE means what is on screen, which only the view that filtered it knows.
            onCopyConsole?()
        case let .filterByTag(tag):
            onFilterByTag?(tag)
        }
    }
}

/// A menu item's `representedObject` must be an `AnyObject`, and the verb is an enum with an
/// associated value — so it travels in a box rather than being flattened into a tag, which is the
/// alternative that loses the tag it carries.
@MainActor
private final class MacAndroidLogVerbBox {
    let verb: AndroidLogVerb
    let line: DeviceLogLine

    init(verb: AndroidLogVerb, line: DeviceLogLine) {
        self.verb = verb
        self.line = line
    }
}

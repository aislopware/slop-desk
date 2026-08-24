// OpenQuicklyPresentation — the near-side FACE of `slopdesk_workspace::open_quickly`.
//
// The seventh surface off the shared SwiftUI floor (docs/56 stage D) and the LAST modal one: the Mac
// draws it as an `NSPanel` (``SlopDeskMacUI/MacOpenQuicklyView``), the phone as a card inside
// ``OverlayHostView``. It is also the one with the most decision per pixel, because it is six
// sources, a ranked and sectioned list over them, a per-row verb, and a searchable ⌘K action table
// under every row — and every one of those is an answer rather than an arrangement.
//
// The sources and the ranking were already below the view before this file existed
// (``OpenQuicklyModel`` in `SlopDeskWorkspaceCore`, `slopdesk_workspace::search_rank`). What crossed
// is what used to sit INSIDE `OpenQuicklyView`:
//
//   * the card's measurements and its ⇞/⇟ stride;
//   * the flattening of sections into draw order — the header/row interleave and, with it, the
//     selectable index the keyboard counts by, which is the one thing a half that paired them itself
//     would get off by one the moment a section header appeared mid-list;
//   * the honest empty line, the footer's hints and the ↩ verb, which change per source;
//   * the per-row ⌘K ACTION TABLE, and the default action ↩ runs. Those are the largest piece and
//     the least layout-like of all: which verbs a folder row offers, that Reopen Tab addresses its
//     own LIFO index rather than popping the newest, that a Current command row gets the re-run pair
//     instead of the shared jump-to table. Written twice they would diverge on the first new verb.
//
// ⚠️ THE ROWS THEMSELVES NEVER CROSS. `displayEntries` sends section SIZES and gets the interleave
// back; `rowActions` sends a row's four facts and gets VERB CODES back. What a row IS — its id, its
// act's payload, the closure that fires it — stays in the caller's own storage, because a verb is a
// closure over this app's store and there is nothing to marshal about one.
//
// What each half keeps is the arrangement and the event shape: a `LazyVStack` and `KeyPress` on the
// phone, an `NSStackView` in a scroll view and a field editor's editing commands on the Mac.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The card's measurements

/// The picker's own dimensions.
///
/// Wider than the palette's sibling numbers on purpose (`open-quickly.png`): six filter pills across
/// the top and a trailing cwd + badge column on every row need the room, and a card that wrapped its
/// pill ring would read as two rows of chrome above one row of content.
///
/// All four cross BY VALUE in one call, because a caller that asked separately could pair one card's
/// width with another's action-sheet measure.
public enum OpenQuicklyMetrics {
    /// The card's fixed width. It does not track the window, for the palette's reason: a picker
    /// stretched across a full-screen workspace puts its badges a screen from its titles.
    public static let panelWidth: Double = metrics.panel_width
    /// The tallest the results viewport may be. Past this the list scrolls instead of the card
    /// growing.
    public static let resultsMaxHeight: Double = metrics.results_max_height
    /// The widest a row's trailing subtitle (a cwd, a project path) may be before it truncates. The
    /// title has the rest, because the title is what the user is reading down the list.
    public static let subtitleMaxWidth: Double = metrics.subtitle_max_width
    /// The ⌘K action sheet's width. Narrower than the card by design — it is a menu ABOUT one row,
    /// and one as wide as the card would read as a second list rather than as that row's verbs.
    public static let actionsWidth: Double = metrics.actions_width

    /// One ⇞/⇟ stride: the rows one full viewport shows.
    ///
    /// Derived from the SAME numbers that size the viewport, so re-tuning the card re-tunes the page
    /// rather than leaving a stride that no longer matches what the eye just skipped. The row height
    /// is the caller's because only the caller knows what it actually drew.
    public static func pageStride(rowHeight: Double) -> Int {
        slopdesk_ws_open_quickly_page_stride(rowHeight)
    }

    private static let metrics = slopdesk_ws_open_quickly_metrics()
}

// MARK: - The list, flattened into draw order

/// One line of the picker: a section header, or a row paired with the index the KEYBOARD knows it by.
///
/// The two indices differ, which is the whole reason this type exists — the drawn list interleaves
/// headers, while the selection counts only rows a user can land on.
public struct OpenQuicklyDisplayEntry: Identifiable, Sendable {
    public enum Kind: Sendable {
        case header(OpenQuicklyFilter)
        case row(OpenQuicklyItem, selectableIndex: Int)
    }

    public let kind: Kind

    public var id: String {
        switch kind {
        case let .header(filter): "header:\(filter.rawValue)"
        case let .row(item, _): item.id
        }
    }

    public init(kind: Kind) { self.kind = kind }
}

public enum OpenQuicklyPresentation {
    /// Flattens `sections` into draw order.
    ///
    /// Headers appear only under the ALL pill: on a specific pill the pill IS the label, and a header
    /// repeating it would be the same word twice in eight points of space. Only the SIZES cross — the
    /// items are re-paired here against the caller's own array, so a row never leaves this process.
    public static func displayEntries(
        _ sections: [OpenQuicklySection], filter: OpenQuicklyFilter,
    ) -> [OpenQuicklyDisplayEntry] {
        let sizes = sections.map(\.items.count)
        // One line per row plus at most one header per section — a ceiling the far side can never
        // exceed, so the answer always fits on the first ask.
        var lines = [SlopDeskWsPickerLine](
            repeating: SlopDeskWsPickerLine(is_header: false, section: 0, item: 0, selectable: 0),
            count: sizes.reduce(0, +) + sections.count,
        )
        let written = sizes.withUnsafeBufferPointer { lent in
            lines.withUnsafeMutableBufferPointer { out in
                slopdesk_ws_open_quickly_draw_order(
                    lent.baseAddress, lent.count, UInt8(filter.code), out.baseAddress, out.count,
                )
            }
        }
        return lines.prefix(written).compactMap { line -> OpenQuicklyDisplayEntry? in
            guard sections.indices.contains(line.section) else { return nil }
            let section = sections[line.section]
            if line.is_header { return OpenQuicklyDisplayEntry(kind: .header(section.filter)) }
            guard section.items.indices.contains(line.item) else { return nil }
            return OpenQuicklyDisplayEntry(
                kind: .row(section.items[line.item], selectableIndex: line.selectable),
            )
        }
    }

    /// The zero-state line for the active pill.
    ///
    /// Three answers, in the order that keeps each of them HONEST: a typed query that matched nothing
    /// says so about the query; an Agents fetch still in flight says it is loading rather than that
    /// there are none; anything else is the source's own empty message.
    public static func emptyMessage(
        query: String, filter: OpenQuicklyFilter, agentsLoading: Bool,
    ) -> String {
        let bytes = Array(query.utf8)
        let blob = bytes.withUnsafeBufferPointer { lent in
            wsAnswerBytes { out, cap in
                Int(slopdesk_ws_open_quickly_empty_message(
                    lent.baseAddress, lent.count, UInt8(filter.code), agentsLoading, out, cap,
                ))
            }
        }
        return wsRuns(blob, count: 1)[0]
    }

    /// The ↩ verb for the selected row, for the footer hint.
    ///
    /// It is the ROW's, not the picker's: ↩ on an opened pane switches to it, on a closed tab reopens
    /// it, on a folder changes directory, on an agent resumes a session. A footer that said "Open"
    /// for all four would be wrong three times.
    public static func defaultActionLabel(for kind: OpenQuicklyKind?) -> String {
        kind?.defaultActionLabel ?? noKindAction
    }

    /// The footer's two fixed hints. The third is ``defaultActionLabel(for:)``, which moves.
    public static var quickSelectHint: String { words[1] }
    public static var actionsHint: String { words[3] }
    /// The CAPS beside those two hints. They rode as literals at both call sites while the words next
    /// to them were already shared — which is the shape that lets a rebind change the key on one
    /// platform's footer and leave the other advertising the old one.
    public static var quickSelectGlyph: String { words[2] }
    public static var actionsGlyph: String { words[4] }
    /// The ⌘K sheet's own zero state, when its filter narrowed past every verb.
    public static var noActionsMessage: String { words[5] }
    /// The ⌘K sheet's filter placeholder, and the picker's own.
    public static var actionsPrompt: String { words[6] }
    public static var searchPrompt: String { words[7] }

    /// Maps an Open-Quickly kind back onto its Jump-To kind for a reconstructed ``JumpToItem``.
    ///
    /// Cosmetic — the shared `rowActions` keys only on the act and the title — so a kind that never
    /// reaches here reads as `.path` rather than as a case anyone has to keep in sync.
    public static func jumpToKind(_ kind: OpenQuicklyKind) -> JumpToItemKind { kind.jumpToKind }

    /// The eight fixed words, in ONE crossing, once per process.
    private static let words: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_open_quickly_words(out, cap)) },
        count: 8,
    )

    /// The ↩ verb for NO kind at all — its own door, because there is no kind byte to ask with.
    private static let noKindAction: String = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_open_quickly_default_action(out, cap)) },
        count: 1,
    )[0]
}

// MARK: - The ⌘-modified keys

/// What a ⌘-modified key means INSIDE the picker.
///
/// ⚠️ Picker-LOCAL, never globally registered: while the picker is up the app's `NSEvent` monitor
/// yields the whole keyboard to it, so ⌘W here picks a pill rather than closing the focused pane.
/// That yield is what makes this table safe to state at all.
///
/// Only the ⌘ table is shared. The arrows, ⇞/⇟, Home/End, Tab and ↩ are NOT, and deliberately: on the
/// phone they arrive as a `KeyPress`, on the Mac as a field editor's editing command (`moveUp:`,
/// `scrollPageDown:`, `insertNewline:`), and a shared enum over two event shapes that different
/// would be a translation layer pretending to be a decision.
public enum OpenQuicklyCommandChord: Equatable, Sendable {
    /// ⌘1–9: run the Nth visible row outright. Carries the 1-BASED digit, as typed.
    case quickPick(Int)
    /// ⌘K: open or close the selected row's action sheet.
    case toggleActions
    /// ⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J/⌘E: jump straight to a pill.
    case selectPill(OpenQuicklyFilter)
}

public extension OpenQuicklyPresentation {
    /// Reads one ⌘-modified character. `nil` ⇒ the picker does not claim it.
    ///
    /// The whole table is one byte: the kind in the high nibble, its payload in the low one. The
    /// digit branch is resolved FIRST on the far side because a pill chord is matched
    /// case-insensitively over letters and a digit could never be one.
    static func commandChord(_ character: Character) -> OpenQuicklyCommandChord? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1
        else { return nil }
        let code = slopdesk_ws_open_quickly_chord(scalar.value)
        switch code & 0xF0 {
        case 0x10: return .quickPick(Int(code & 0x0F))
        case 0x20: return .toggleActions
        case 0x30: return OpenQuicklyFilter(code: Int(code & 0x0F)).map { .selectPill($0) }
        default: return nil
        }
    }
}

// MARK: - The verbs

/// Every action a picker row can run: the one ↩ runs, and the table ⌘K opens.
///
/// It is one enum's worth of product decision, and the TABLE — which verbs a row offers, in which
/// order — is `slopdesk_workspace::open_quickly::row_actions`. What stays here is what a verb DOES,
/// because every entry actuates through ``LinkActionActuator`` or a store op, so a row opened from
/// the picker and the same target opened from a renderer link take exactly the same path.
///
/// `package` rather than `public`, because ``LinkActionActuator/RowAction`` is: a verb is a closure
/// over this app's own store, and nothing outside the package has one to hand it.
@MainActor
package enum OpenQuicklyActions {
    package typealias RowAction = LinkActionActuator.RowAction

    /// Runs a row's DEFAULT action — what ↩ and a click both do.
    ///
    /// ↩ on a Current LINK is an EXPLICIT open intent, resolved config-INDEPENDENTLY: the
    /// configurable ⌘-click gesture is about a click in a terminal, and a row the user selected and
    /// pressed Return on has already said what they meant.
    package static func runDefault(
        _ item: OpenQuicklyItem, store: WorkspaceStore, model: TerminalViewModel?,
    ) {
        switch item.act {
        case let .focusPane(id):
            store.jumpToPaneTree(id)
        case let .openFolder(path):
            // A folder's default is "change directory here" — verbatim into the focused pane. The
            // parent-if-file case is the policy's, though a frecent entry is always a directory.
            LinkActionActuator.actuate(.changeDirectoryPTY(path), model: model)
        case let .resumeAgent(sessionID, cwd):
            resumeAgent(sessionID: sessionID, cwd: cwd, model: model)
        case let .reopenRecentTab(index):
            // Reopens EXACTLY this row's tab by its carried LIFO index — row N reopens tab N, which
            // is NOT what `reopenLastClosedPane()` (⇧⌘T) does: that one pops the newest regardless
            // of which row the user aimed at.
            store.reopenClosedTab(at: index)
        case let .jumpTo(jumpAct):
            switch jumpAct {
            case let .block(index):
                store.jumpToNavigatorBlockInActivePane(index: index)
            case let .link(link):
                LinkActionActuator.actuate(
                    LinkActionPolicy.explicitOpenAction(link: link), model: model,
                )
            }
        }
    }

    /// The row's ⌘K action table, in table order.
    ///
    /// The far side answers a list of VERB CODES, or the single sentinel meaning "this row defers to
    /// the SHARED jump-to table" — which is not the same answer as offering nothing, and only one of
    /// the two draws a sheet. Each code is turned into its closure here, where the store is.
    package static func rowActions(
        for item: OpenQuicklyItem,
        store: WorkspaceStore,
        model: TerminalViewModel?,
        folders: FolderFrecencyStore?,
    ) -> [RowAction] {
        let blob = wsAnswerBytes { out, cap in
            Int(slopdesk_ws_open_quickly_row_actions(
                item.actCode,
                UInt8(item.kind.code),
                item.subtitle != nil,
                item.agentCwd?.isEmpty ?? true,
                folders != nil,
                out,
                cap,
            ))
        }
        guard blob.count >= 4 else { return [] }
        let count = Int(blob[0]) << 24 | Int(blob[1]) << 16 | Int(blob[2]) << 8 | Int(blob[3])
        let codes = Array(blob.dropFirst(4).prefix(count))
        if codes.count == 1, codes[0] == UInt8(SLOPDESK_WS_PICKER_SHARED_JUMP_TO) {
            return sharedJumpTo(for: item, store: store, model: model)
        }
        return codes.compactMap { verb(code: $0, item: item, store: store, model: model, folders: folders) }
    }

    /// The shared Jump-To table, reconstructed for a Current row that is not a command: a link opened
    /// from the picker and the same link opened from a renderer must take exactly one path.
    private static func sharedJumpTo(
        for item: OpenQuicklyItem, store: WorkspaceStore, model: TerminalViewModel?,
    ) -> [RowAction] {
        guard case let .jumpTo(jumpAct) = item.act else { return [] }
        return LinkActionActuator.rowActions(
            for: JumpToItem(
                id: item.id,
                kind: item.kind.jumpToKind,
                title: item.title,
                timestamp: item.timestamp,
                act: jumpAct,
            ),
            store: store,
            model: model,
        )
    }

    /// What one verb code DOES, over this row.
    ///
    /// A code whose payload the row does not carry answers `nil` rather than a dead control — the far
    /// side only offers a verb a row's own facts support, so this can only fire for a build older
    /// than the crate.
    private static func verb(
        code: UInt8,
        item: OpenQuicklyItem,
        store: WorkspaceStore,
        model: TerminalViewModel?,
        folders: FolderFrecencyStore?,
    ) -> RowAction? {
        // One family per helper: the fifteen codes in one `switch` is a single expression the
        // type-checker cannot solve, and the families are the row's own act cases anyway.
        let effect: (() -> Void)? = paneEffect(code, item, store, model)
            ?? folderEffect(code, item, store, model, folders)
            ?? agentEffect(code, item, model)
            ?? rowEffect(code, item, store)
        guard let effect else { return nil }
        return RowAction(title: OpenQuicklyVerbs.title(code), symbol: OpenQuicklyVerbs.symbol(code), run: effect)
    }

    /// The verbs a focused-pane row carries: its close, and the two over the cwd it prints.
    private static func paneEffect(
        _ code: UInt8, _ item: OpenQuicklyItem, _ store: WorkspaceStore, _ model: TerminalViewModel?,
    ) -> (() -> Void)? {
        switch code {
        case OpenQuicklyVerbs.closePane:
            // Close routes through the busy-shell / close-confirm path, so a dirty or busy pane still
            // prompts — a picker is not a way around the guard the pane itself puts up.
            guard case let .focusPane(id) = item.act else { return nil }
            return { store.requestClosePaneTree(id) }
        case OpenQuicklyVerbs.revealCwd:
            guard let cwd = item.subtitle else { return nil }
            return { LinkActionActuator.actuate(.revealHost(cwd), model: model) }
        case OpenQuicklyVerbs.copyCwdPath:
            guard let cwd = item.subtitle else { return nil }
            return { LinkActionActuator.copyToPasteboard(cwd) }
        default:
            return nil
        }
    }

    /// The six verbs over a folder row's path.
    private static func folderEffect(
        _ code: UInt8,
        _ item: OpenQuicklyItem,
        _ store: WorkspaceStore,
        _ model: TerminalViewModel?,
        _ folders: FolderFrecencyStore?,
    ) -> (() -> Void)? {
        guard case let .openFolder(path) = item.act else { return nil }
        switch code {
        case OpenQuicklyVerbs.splitRight,
             OpenQuicklyVerbs.splitDown:
            let axis: SplitAxis = code == OpenQuicklyVerbs.splitRight ? .horizontal : .vertical
            return { store.openTerminalRooted(at: path, split: true, leading: false, axis: axis) }
        case OpenQuicklyVerbs.changeDirectoryHere:
            return { LinkActionActuator.actuate(.changeDirectoryPTY(path), model: model) }
        case OpenQuicklyVerbs.revealInFinder:
            return { LinkActionActuator.actuate(.revealHost(path), model: model) }
        case OpenQuicklyVerbs.copyPath:
            return { LinkActionActuator.copyToPasteboard(path) }
        case OpenQuicklyVerbs.forgetFolder:
            return { folders?.forget(path: path) }
        default:
            return nil
        }
    }

    /// The three verbs over an agent row's session.
    private static func agentEffect(
        _ code: UInt8, _ item: OpenQuicklyItem, _ model: TerminalViewModel?,
    ) -> (() -> Void)? {
        guard case let .resumeAgent(sessionID, cwd) = item.act else { return nil }
        switch code {
        case OpenQuicklyVerbs.resumeSession:
            return { resumeAgent(sessionID: sessionID, cwd: cwd, model: model) }
        case OpenQuicklyVerbs.copyProjectPath:
            return { LinkActionActuator.copyToPasteboard(cwd) }
        case OpenQuicklyVerbs.copySessionID:
            return { LinkActionActuator.copyToPasteboard(sessionID) }
        default:
            return nil
        }
    }

    /// The verbs a closed-tab or command row carries.
    private static func rowEffect(
        _ code: UInt8, _ item: OpenQuicklyItem, _ store: WorkspaceStore,
    ) -> (() -> Void)? {
        switch code {
        case OpenQuicklyVerbs.reopenTab:
            guard case let .reopenRecentTab(index) = item.act else { return nil }
            return { store.reopenClosedTab(at: index) }
        case OpenQuicklyVerbs.reRunInCurrentPane:
            return { store.reRunCommandInActivePane(item.title) }
        case OpenQuicklyVerbs.copyCommand:
            return { LinkActionActuator.copyToPasteboard(item.title) }
        default:
            return nil
        }
    }

    /// Resume a Claude agent session in the focused pane: `cd` into its project (verbatim,
    /// parent-if-file) then `claude --resume <id>`. The agents are Claude-only by construction, so
    /// the resume verb is fixed. A no-op when no live terminal backs the focused pane.
    private static func resumeAgent(sessionID: String, cwd: String, model: TerminalViewModel?) {
        guard let model else { return }
        if !cwd.isEmpty {
            model.sendInput(Data(LinkActionPolicy.changeDirectoryCommandLine(cwd).utf8))
        }
        model.sendInput(Data("claude --resume \(sessionID)\n".utf8))
    }
}

/// The fifteen verbs' codes and their two readings.
///
/// The codes are named rather than spelled at each `case`, because a verb table switched on by bare
/// integers is the one place a renumber on the far side would compile and mean something else.
enum OpenQuicklyVerbs {
    static let closePane: UInt8 = 0
    static let revealCwd: UInt8 = 1
    static let copyCwdPath: UInt8 = 2
    static let splitRight: UInt8 = 3
    static let splitDown: UInt8 = 4
    static let changeDirectoryHere: UInt8 = 5
    static let revealInFinder: UInt8 = 6
    static let copyPath: UInt8 = 7
    static let forgetFolder: UInt8 = 8
    static let resumeSession: UInt8 = 9
    static let copyProjectPath: UInt8 = 10
    static let copySessionID: UInt8 = 11
    static let reopenTab: UInt8 = 12
    static let reRunInCurrentPane: UInt8 = 13
    static let copyCommand: UInt8 = 14

    static func title(_ code: UInt8) -> String { reading(code, offset: 0) }
    static func symbol(_ code: UInt8) -> String { reading(code, offset: 1) }

    private static func reading(_ code: UInt8, offset: Int) -> String {
        let index = Int(code) * 2 + offset
        return words.indices.contains(index) ? words[index] : ""
    }

    /// Every verb's title and silhouette, in ONE crossing, once per process — thirty runs for
    /// fifteen verbs.
    private static let words: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_open_quickly_verbs(out, cap)) },
        count: 30,
    )
}

extension OpenQuicklyItem {
    /// The act's own code — what fires, without its payload, which never crosses.
    var actCode: UInt8 {
        switch act {
        case .focusPane: 0
        case .openFolder: 1
        case .resumeAgent: 2
        case .reopenRecentTab: 3
        case .jumpTo: 4
        }
    }

    /// An agent row's project path, or `nil` for every other row. The far side asks whether it is
    /// EMPTY — an agent whose project is blank offers no Copy Project Path — and a non-agent row
    /// answers the same as a blank one because neither offers the verb.
    var agentCwd: String? {
        guard case let .resumeAgent(_, cwd) = act else { return nil }
        return cwd
    }
}

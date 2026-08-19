// OpenQuicklyPresentation — what the ⌘⇧O picker IS, for both of the halves that draw it.
//
// The seventh surface off the shared SwiftUI floor (docs/56 stage D) and the LAST modal one: the Mac
// draws it as an `NSPanel` (``SlopDeskMacUI/MacOpenQuicklyView``), the phone as a card inside
// ``OverlayHostView``. It is also the one with the most decision per pixel, because it is six
// sources, a ranked and sectioned list over them, a per-row verb, and a searchable ⌘K action table
// under every row — and every one of those is an answer rather than an arrangement.
//
// The sources and the ranking were already below the view before this file existed
// (``OpenQuicklyModel`` in `SlopDeskWorkspaceCore`, ``FuzzyMatcher`` here). What moves here is what
// used to sit INSIDE `OpenQuicklyView`:
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
// What each half keeps is the arrangement and the event shape: a `LazyVStack` and `KeyPress` on the
// phone, an `NSStackView` in a scroll view and a field editor's editing commands on the Mac.

import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The card's measurements

/// The picker's own dimensions.
///
/// Wider than the palette's sibling numbers on purpose (`open-quickly.png`): six filter pills across
/// the top and a trailing cwd + badge column on every row need the room, and a card that wrapped its
/// pill ring would read as two rows of chrome above one row of content.
public enum OpenQuicklyMetrics {
    /// The card's fixed width. It does not track the window, for the palette's reason: a picker
    /// stretched across a full-screen workspace puts its badges a screen from its titles.
    public static let panelWidth: Double = 640
    /// The tallest the results viewport may be. Past this the list scrolls instead of the card
    /// growing.
    public static let resultsMaxHeight: Double = 360
    /// The widest a row's trailing subtitle (a cwd, a project path) may be before it truncates. The
    /// title has the rest, because the title is what the user is reading down the list.
    public static let subtitleMaxWidth: Double = 240
    /// The ⌘K action sheet's width. Narrower than the card by design — it is a menu ABOUT one row,
    /// and one as wide as the card would read as a second list rather than as that row's verbs.
    public static let actionsWidth: Double = 240

    /// One ⇞/⇟ stride: the rows one full viewport shows.
    ///
    /// Derived from the SAME numbers that size the viewport, so re-tuning the card re-tunes the page
    /// rather than leaving a stride that no longer matches what the eye just skipped. The row height
    /// is the caller's because only the caller knows what it actually drew.
    public static func pageStride(rowHeight: Double) -> Int {
        guard rowHeight > 0 else { return 1 }
        return Swift.max(1, Int(resultsMaxHeight / rowHeight))
    }
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
    /// repeating it would be the same word twice in eight points of space.
    public static func displayEntries(
        _ sections: [OpenQuicklySection], filter: OpenQuicklyFilter,
    ) -> [OpenQuicklyDisplayEntry] {
        let showHeaders = filter == .all
        var out: [OpenQuicklyDisplayEntry] = []
        var index = 0
        for section in sections {
            if showHeaders, !section.items.isEmpty {
                out.append(OpenQuicklyDisplayEntry(kind: .header(section.filter)))
            }
            for item in section.items {
                out.append(OpenQuicklyDisplayEntry(kind: .row(item, selectableIndex: index)))
                index += 1
            }
        }
        return out
    }

    /// The zero-state line for the active pill.
    ///
    /// Three answers, in the order that keeps each of them HONEST: a typed query that matched nothing
    /// says so about the query; an Agents fetch still in flight says it is loading rather than that
    /// there are none; anything else is the source's own empty message.
    public static func emptyMessage(
        query: String, filter: OpenQuicklyFilter, agentsLoading: Bool,
    ) -> String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "No matches" }
        if filter == .agents, agentsLoading { return "Loading agents…" }
        return filter.emptyMessage
    }

    /// The ↩ verb for the selected row, for the footer hint.
    ///
    /// It is the ROW's, not the picker's: ↩ on an opened pane switches to it, on a closed tab reopens
    /// it, on a folder changes directory, on an agent resumes a session. A footer that said "Open"
    /// for all four would be wrong three times.
    public static func defaultActionLabel(for kind: OpenQuicklyKind?) -> String {
        switch kind {
        case .pane: "Switch to"
        case .recentTab: "Reopen"
        case .folder: "Change Directory"
        case .agent: "Resume"
        case .command,
             .prompt: "Jump to"
        case .path,
             .url,
             .fileURL,
             nil: "Open"
        }
    }

    /// The footer's two fixed hints. The third is ``defaultActionLabel(for:)``, which moves.
    public static let quickSelectHint = "Quick Select"
    public static let actionsHint = "Actions"
    /// The ⌘K sheet's own zero state, when its filter narrowed past every verb.
    public static let noActionsMessage = "No actions"
    /// The ⌘K sheet's filter placeholder, and the picker's own.
    public static let actionsPrompt = "Filter actions…"
    public static let searchPrompt = "Search tabs, windows…"

    /// Maps an Open-Quickly kind back onto its Jump-To kind for a reconstructed ``JumpToItem``.
    ///
    /// Cosmetic — the shared `rowActions` keys only on the act and the title — so a kind that never
    /// reaches here reads as `.path` rather than as a case anyone has to keep in sync.
    public static func jumpToKind(_ kind: OpenQuicklyKind) -> JumpToItemKind {
        switch kind {
        case .url: .url
        case .fileURL: .fileURL
        case .command: .command
        case .prompt: .prompt
        default: .path
        }
    }
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
    /// The digit branch comes FIRST because a pill chord is matched case-insensitively over letters
    /// and a digit could never be one — checking the pills first would only cost every ⌘1–9 a lookup.
    static func commandChord(_ character: Character) -> OpenQuicklyCommandChord? {
        if let digit = character.wholeNumberValue, (1...9).contains(digit) {
            return .quickPick(digit)
        }
        if character == "k" || character == "K" { return .toggleActions }
        let key = String(character).lowercased()
        if let pill = OpenQuicklyFilter.pickerPills.first(where: { $0.pickerChordKey == key }) {
            return .selectPill(pill)
        }
        return nil
    }
}

// MARK: - The verbs

/// Every action a picker row can run: the one ↩ runs, and the table ⌘K opens.
///
/// It is one enum's worth of product decision written in `RowAction`s, and it is here rather than in
/// either view because the two halves would otherwise each carry a copy — and a copy of a verb table
/// does not fail loudly when it drifts, it just offers one surface a verb the other does not have.
///
/// Every entry actuates through ``LinkActionActuator`` or a store op, so a row opened from the picker
/// and the same target opened from a renderer link take exactly the same path.
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
    /// Two omissions are DELIBERATE and pinned in `docs/DECISIONS.md` rather than being dead rows:
    /// "Move Tab to New Window" and "Open in New Window" are N/A in the single-window vertical-rail
    /// model, and "Re-Run in New Tab" waits on a defer-bytes-into-a-fresh-PTY store hook that does
    /// not exist. "Switch to Pane" is dropped for a different reason — ↩ already does it.
    package static func rowActions(
        for item: OpenQuicklyItem,
        store: WorkspaceStore,
        model: TerminalViewModel?,
        folders: FolderFrecencyStore?,
    ) -> [RowAction] {
        switch item.act {
        case let .jumpTo(jumpAct):
            // A Current COMMAND row gets the verbatim re-run pair, NOT the generic jump-to+copy the
            // shared Jump-To table returns: the row IS a command that already ran, and the thing you
            // want from one is to run it again. Prompt / path / url / file rows keep the shared table.
            if item.kind == .command {
                return [
                    RowAction(title: "Re-Run in Current Pane", symbol: "arrow.clockwise") {
                        store.reRunCommandInActivePane(item.title)
                    },
                    RowAction(title: "Copy Command", symbol: "doc.on.doc") {
                        LinkActionActuator.copyToPasteboard(item.title)
                    },
                ]
            }
            let jumpItem = JumpToItem(
                id: item.id,
                kind: OpenQuicklyPresentation.jumpToKind(item.kind),
                title: item.title,
                timestamp: item.timestamp,
                act: jumpAct,
            )
            return LinkActionActuator.rowActions(for: jumpItem, store: store, model: model)
        case let .focusPane(id):
            // Close routes through the busy-shell / close-confirm path, so a dirty or busy pane still
            // prompts — a picker is not a way around the guard the pane itself puts up.
            var actions = [RowAction(title: "Close Pane", symbol: "xmark") {
                store.requestClosePaneTree(id)
            }]
            if let cwd = item.subtitle {
                actions.append(RowAction(title: "Reveal CWD in Finder", symbol: "folder") {
                    LinkActionActuator.actuate(.revealHost(cwd), model: model)
                })
                actions.append(RowAction(title: "Copy CWD Path", symbol: "doc.on.doc") {
                    LinkActionActuator.copyToPasteboard(cwd)
                })
            }
            return actions
        case let .openFolder(path):
            return folderActions(path: path, store: store, model: model, folders: folders)
        case let .resumeAgent(sessionID, cwd):
            var actions = [RowAction(title: "Resume Session", symbol: "play") {
                resumeAgent(sessionID: sessionID, cwd: cwd, model: model)
            }]
            if !cwd.isEmpty {
                actions.append(RowAction(title: "Copy Project Path", symbol: "doc.on.doc") {
                    LinkActionActuator.copyToPasteboard(cwd)
                })
            }
            actions.append(RowAction(title: "Copy Session ID", symbol: "number") {
                LinkActionActuator.copyToPasteboard(sessionID)
            })
            return actions
        case let .reopenRecentTab(index):
            var actions = [RowAction(title: "Reopen Tab", symbol: "arrow.uturn.left") {
                store.reopenClosedTab(at: index)
            }]
            if let cwd = item.subtitle {
                actions.append(RowAction(title: "Copy CWD Path", symbol: "doc.on.doc") {
                    LinkActionActuator.copyToPasteboard(cwd)
                })
            }
            return actions
        }
    }

    /// The Folder table (`open-quickly.png`). **Split Right / Down** open a FRESH terminal split
    /// rooted at the folder — the same `openTerminalRooted` ingress the external folder-drop split
    /// zones use, with an `axis` so Split Down is vertical. **Forget This Folder** appears only when
    /// a frecency store backs the list, because without one there is nothing to forget it from.
    package static func folderActions(
        path: String,
        store: WorkspaceStore,
        model: TerminalViewModel?,
        folders: FolderFrecencyStore?,
    ) -> [RowAction] {
        var actions = [
            RowAction(title: "Split Right", symbol: "rectangle.split.2x1") {
                store.openTerminalRooted(at: path, split: true, leading: false, axis: .horizontal)
            },
            RowAction(title: "Split Down", symbol: "rectangle.split.1x2") {
                store.openTerminalRooted(at: path, split: true, leading: false, axis: .vertical)
            },
            RowAction(title: "Change Directory Here", symbol: "arrow.turn.down.right") {
                LinkActionActuator.actuate(.changeDirectoryPTY(path), model: model)
            },
            RowAction(title: "Reveal in Finder", symbol: "folder") {
                LinkActionActuator.actuate(.revealHost(path), model: model)
            },
            RowAction(title: "Copy Path", symbol: "doc.on.doc") {
                LinkActionActuator.copyToPasteboard(path)
            },
        ]
        if folders != nil {
            actions.append(RowAction(title: "Forget This Folder", symbol: "trash") {
                folders?.forget(path: path)
            })
        }
        return actions
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

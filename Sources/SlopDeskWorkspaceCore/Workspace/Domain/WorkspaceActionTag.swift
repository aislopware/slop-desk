import CSlopDeskFFI
import SlopDeskWorkspaceModel

// WorkspaceActionTag — the ONE site where a WorkspaceAction and its Rust tag are the same thing.
//
// `slopdesk_workspace::bindings::Action` names this same vocabulary, and the two are one enum typed
// in two languages — the sanctioned shape (`pane_kind.rs` is the precedent), not a second table.
// Which action a ROW runs is data and lives in Rust; which STORE OP an action reaches is a Swift
// `switch` and lives in `WorkspaceBindingRouting`. The tag is the join, and it is a POSITION: the
// discriminants on the Rust side are that enum's case order, and `lint-invariants` pins the two
// case lists equal in both directions, so nothing here is a name mapping anyone maintains.
//
// Every crossing goes through this file. A second `switch` on a raw tag anywhere else would be the
// drift the single site exists to prevent.

public extension WorkspaceAction {
    /// The tag this action crosses as — its case POSITION in the shared vocabulary.
    var tag: UInt16 {
        switch self {
        case .splitRight: 0
        case .splitDown: 1
        case .splitLeft: 2
        case .splitUp: 3
        case .closePane: 4
        case .renamePane: 5
        case .breakPaneToTab: 6
        case .detachPane: 7
        case .reattachAllPanes: 8
        case .movePaneLeft: 9
        case .movePaneRight: 10
        case .movePaneUp: 11
        case .movePaneDown: 12
        case .resizePaneLeft: 13
        case .resizePaneRight: 14
        case .resizePaneUp: 15
        case .resizePaneDown: 16
        case .balancePanes: 17
        case .cycleLayout: 18
        case .applyLayout: 19
        case .focusLeft: 20
        case .focusRight: 21
        case .focusUp: 22
        case .focusDown: 23
        case .cyclePaneNext: 24
        case .cyclePanePrev: 25
        case .toggleZoom: 26
        case .commandPalette: 27
        case .cheatSheet: 28
        case .find: 29
        case .findNext: 30
        case .findPrev: 31
        case .globalSearch: 32
        case .toggleCopyMode: 33
        case .toggleViKeyHints: 34
        case .toggleReadOnly: 35
        case .secureKeyboardEntry: 36
        case .releaseStuckInput: 37
        case .toggleViewportLock: 38
        case .fitViewportToPane: 39
        case .resetViewportZoom: 40
        case .pasteAsKeystrokes: 41
        case .toggleSidebar: 42
        case .toggleCodeSidebar: 43
        case .focusCodePanel: 44
        case .pinWindow: 45
        case .openQuickly: 46
        case .jumpTo: 47
        case .hintToOpen: 48
        case .hintToCopy: 49
        case .hintToReveal: 50
        case .scrollPageUp: 51
        case .scrollPageDown: 52
        case .scrollToTop: 53
        case .scrollToBottom: 54
        case .commandJumpPrev: 55
        case .commandJumpNext: 56
        case .increaseFontSize: 57
        case .decreaseFontSize: 58
        case .resetFontSize: 59
        case .commandNavigator: 60
        case .jumpPreviousBlock: 61
        case .jumpNextBlock: 62
        case .reRunLastCommand: 63
        case .jumpPreviousFailed: 64
        case .jumpNextFailed: 65
        case .newTab: 66
        case .newDesktopTab: 67
        case .nextTab: 68
        case .prevTab: 69
        case .selectPane: 70
        case .paneSwitcher: 71
        case .closeTab: 72
        case .closeWindow: 73
        case .reopenClosed: 74
        case .toggleSyncInput: 75
        case .jumpToAttention: 76
        case .peekAndReply: 77
        }
    }

    /// The action `tag` names, carrying `arg` where the case has a payload.
    ///
    /// `nil` for a tag this build does not know — a case the crate grew and this enum has not, which
    /// must not be guessed at. `.applyLayout` also answers `nil`: it is the one action with no
    /// binding row (the five named presets are menu/palette only), so nothing crossing a TABLE can
    /// be one, and a preset has no index in this vocabulary to reconstruct it from.
    init?(tag: UInt16, arg: Int32) {
        switch tag {
        case 0: self = .splitRight
        case 1: self = .splitDown
        case 2: self = .splitLeft
        case 3: self = .splitUp
        case 4: self = .closePane
        case 5: self = .renamePane
        case 6: self = .breakPaneToTab
        case 7: self = .detachPane
        case 8: self = .reattachAllPanes
        case 9: self = .movePaneLeft
        case 10: self = .movePaneRight
        case 11: self = .movePaneUp
        case 12: self = .movePaneDown
        case 13: self = .resizePaneLeft
        case 14: self = .resizePaneRight
        case 15: self = .resizePaneUp
        case 16: self = .resizePaneDown
        case 17: self = .balancePanes
        case 18: self = .cycleLayout
        case 20: self = .focusLeft
        case 21: self = .focusRight
        case 22: self = .focusUp
        case 23: self = .focusDown
        case 24: self = .cyclePaneNext
        case 25: self = .cyclePanePrev
        case 26: self = .toggleZoom
        case 27: self = .commandPalette
        case 28: self = .cheatSheet
        case 29: self = .find
        case 30: self = .findNext
        case 31: self = .findPrev
        case 32: self = .globalSearch
        case 33: self = .toggleCopyMode
        case 34: self = .toggleViKeyHints
        case 35: self = .toggleReadOnly
        case 36: self = .secureKeyboardEntry
        case 37: self = .releaseStuckInput
        case 38: self = .toggleViewportLock
        case 39: self = .fitViewportToPane
        case 40: self = .resetViewportZoom
        case 41: self = .pasteAsKeystrokes
        case 42: self = .toggleSidebar
        case 43: self = .toggleCodeSidebar
        case 44: self = .focusCodePanel
        case 45: self = .pinWindow
        case 46: self = .openQuickly
        case 47: self = .jumpTo
        case 48: self = .hintToOpen
        case 49: self = .hintToCopy
        case 50: self = .hintToReveal
        case 51: self = .scrollPageUp
        case 52: self = .scrollPageDown
        case 53: self = .scrollToTop
        case 54: self = .scrollToBottom
        case 55: self = .commandJumpPrev
        case 56: self = .commandJumpNext
        case 57: self = .increaseFontSize
        case 58: self = .decreaseFontSize
        case 59: self = .resetFontSize
        case 60: self = .commandNavigator
        case 61: self = .jumpPreviousBlock
        case 62: self = .jumpNextBlock
        case 63: self = .reRunLastCommand
        case 64: self = .jumpPreviousFailed
        case 65: self = .jumpNextFailed
        case 66: self = .newTab
        case 67: self = .newDesktopTab
        case 68: self = .nextTab
        case 69: self = .prevTab
        case 70: self = .selectPane(Int(arg))
        case 71: self = .paneSwitcher
        case 72: self = .closeTab
        case 73: self = .closeWindow
        case 74: self = .reopenClosed
        case 75: self = .toggleSyncInput
        case 76: self = .jumpToAttention
        case 77: self = .peekAndReply
        default: return nil
        }
    }

    /// Whether running this action requires an active pane — so the palette can omit it on an empty
    /// shell, and the menu can grey it out.
    ///
    /// The rule is `slopdesk_workspace::bindings::Action::requires_active_pane`, and it is asked per
    /// ACTION rather than per row because `.applyLayout` has no row and still has an answer.
    var requiresActivePane: Bool {
        slopdesk_ws_action_requires_active_pane(tag)
    }
}

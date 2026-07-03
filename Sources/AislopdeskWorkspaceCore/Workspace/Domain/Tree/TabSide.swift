import Foundation

// MARK: - TabSide (the terminal ⟂ remote-window workspace partition)

/// Which COLUMN of the split workspace a tab belongs to. The workspace is partitioned into two
/// independent regions — the LEFT (sidebar + content) is terminal-only, the RIGHT is the remote-window
/// (GUI video) area with its own tab set — and a tab's side is **derived from its panes**, never stored:
/// a tab whose panes are all video kinds is a `.gui` tab; everything else (terminal panes, choosers, a
/// legacy mixed tab) is `.terminal`. Deriving (rather than persisting a discriminator) means no schema
/// bump, and a chooser tab that resolves to "Remote window" migrates columns automatically the moment
/// its spec kind flips.
public enum TabSide: String, Sendable, Equatable, CaseIterable {
    /// The left column: PTY terminal tabs (and anything mixed/undecided — the safe default).
    case terminal
    /// The right column: remote-window (PATH 2 video) tabs.
    case gui
}

public extension PaneKind {
    /// The workspace side this pane kind anchors its tab to, or `nil` for a side-NEUTRAL kind (the
    /// transient `.chooser`, which must not drag a tab across columns while the user is still picking).
    var tabSide: TabSide? {
        switch self {
        case .terminal: .terminal
        case .remoteGUI,
             .systemDialog: .gui
        case .chooser: nil
        }
    }
}

public extension Session {
    /// The derived ``TabSide`` of `tab`: `.gui` iff it holds ≥ 1 video-kind pane and NO terminal pane
    /// (choosers are neutral). Any terminal pane — including a legacy mixed tab — anchors `.terminal`,
    /// so a tab never renders in the right column while it still owns a PTY. A chooser-only tab (the
    /// fresh ⌘T tab, still undecided) reads `.terminal` — it flips sides the moment the user picks.
    func side(ofTab tab: Tab) -> TabSide {
        var sawVideo = false
        for id in tab.allPaneIDs() {
            switch specs[id]?.kind.tabSide {
            case .terminal: return .terminal
            case .gui: sawVideo = true
            default: break
            }
        }
        return sawVideo ? .gui : .terminal
    }

    /// Whether `tab` is MIXED — it holds panes anchored to BOTH sides. Only a chooser resolution can
    /// mint one (`WorkspaceStore/choosePaneKind` splits a mixed tab apart immediately); a persisted
    /// legacy mixed tab renders `.terminal` (see ``side(ofTab:)``) but stays functional.
    func isMixedTab(_ tab: Tab) -> Bool {
        var sawTerminal = false, sawVideo = false
        for id in tab.allPaneIDs() {
            switch specs[id]?.kind.tabSide {
            case .terminal: sawTerminal = true
            case .gui: sawVideo = true
            default: break
            }
        }
        return sawTerminal && sawVideo
    }

    /// The indices (into ``tabs``) of the tabs on `side`, in tab-bar order — the basis for side-scoped
    /// tab numbering (⌘1…⌘9 count TERMINAL tabs only) and side-scoped next/prev cycling.
    func tabIndices(on side: TabSide) -> [Int] {
        tabs.indices.filter { self.side(ofTab: tabs[$0]) == side }
    }

    /// The tabs on `side`, in tab-bar order.
    func tabs(on side: TabSide) -> [Tab] {
        tabs.filter { self.side(ofTab: $0) == side }
    }
}

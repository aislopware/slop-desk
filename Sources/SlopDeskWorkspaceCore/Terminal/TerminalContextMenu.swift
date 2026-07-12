import Foundation

// MARK: - TerminalContextMenu (pure right-click menu model + enablement)

/// The PURE model behind the terminal right-click context menu (Ghostty/Warp parity):
/// the ordered item list and — the testable heart — each item's **enablement** for the current pane
/// state (copy needs a selection, paste needs clipboard text, splits need a connected pane). The GUI
/// `NSMenu` built in `GhosttyLayerBackedView.menu(for:)` is a thin renderer over this; routing each item
/// to libghostty (`copy_to_clipboard` / `paste_from_clipboard` / `select_all` / `clear_screen` binding
/// actions) and to the ``WorkspaceStore`` split/find ops is compile-only. Factoring enablement here keeps
/// it unit-testable with no view.
public enum TerminalContextMenu {
    /// One menu action. Raw `String` so the GUI can tag each `NSMenuItem.representedObject` and dispatch
    /// without a parallel switch, and so the cheat-sheet/tests reference stable ids.
    public enum Item: String, CaseIterable, Sendable, Equatable {
        case copy
        case cut // ⌘X — copies the selection and (at an editable prompt) deletes it; read-only → copy only
        case paste
        case pasteAsKeystrokes
        // The "Paste as…" submenu variants. These are NOT in the top-level
        // `items` list; they hang off the `pasteAsItems` submenu (see `pasteAsSubmenuTitle`).
        case pasteSelection // pastes the current selection instead of the clipboard (X11 middle-click)
        case pasteFileBase64 // base64-encodes a chosen file's bytes and types them
        case pasteEscaped // shell-escapes the clipboard so spaces/metachars land as literals
        case pasteBracketed // forces DEC bracketed-paste framing even if the program didn't ask
        case selectAll
        case clear
        case copyOutput // copy the latest command BLOCK's output (request type 15 → VT-strip → clipboard)
        case splitRight
        case splitDown
        case find

        /// The menu label (sentence case, matching the macOS HIG + the rest of the app's verbs).
        public var title: String {
            switch self {
            case .copy: "Copy"
            case .cut: "Cut"
            case .paste: "Paste"
            case .pasteAsKeystrokes: "Paste as Keystrokes"
            case .pasteSelection: "Paste Selection"
            case .pasteFileBase64: "Paste File Base64-Encoded…"
            case .pasteEscaped: "Paste Escaping Special Characters"
            case .pasteBracketed: "Bracketed Paste"
            case .selectAll: "Select All"
            case .clear: "Clear"
            case .copyOutput: "Copy Command Output"
            case .splitRight: "Split Right"
            case .splitDown: "Split Down"
            case .find: "Find…"
            }
        }

        /// SF Symbol for the menu row (matches the binding-registry glyph vocabulary).
        public var symbol: String {
            switch self {
            case .copy: "doc.on.doc"
            case .cut: "scissors"
            case .paste: "clipboard"
            case .pasteAsKeystrokes: "keyboard"
            case .pasteSelection: "text.cursor"
            case .pasteFileBase64: "doc.badge.plus"
            case .pasteEscaped: "textformat"
            case .pasteBracketed: "curlybraces"
            case .selectAll: "selection.pin.in.out"
            case .clear: "eraser"
            case .copyOutput: "text.alignleft"
            case .splitRight: "rectangle.split.2x1"
            case .splitDown: "rectangle.split.1x2"
            case .find: "magnifyingglass"
            }
        }

        /// Whether a thin SEPARATOR is drawn ABOVE this item, grouping clipboard / edit / blocks / split / find.
        public var separatorBefore: Bool {
            switch self {
            case .selectAll,
                 .copyOutput,
                 .splitRight,
                 .find: true
            default: false
            }
        }
    }

    /// The inputs that decide each item's enablement — a pure snapshot the view captures at right-click
    /// time (libghostty `has_selection`, the host pasteboard, and whether the pane's transport is live).
    public struct Context: Equatable, Sendable {
        /// The surface currently holds a text selection (`ghostty_surface_has_selection`).
        public var hasSelection: Bool
        /// The host pasteboard has a non-empty string (so Paste / Paste-as-Keystrokes have something to do).
        public var clipboardHasText: Bool
        /// The pane's PTY/transport is connected (splits/find are pointless on a dead pane — but they
        /// stay enabled here because they target the WORKSPACE, not the byte stream; only the byte-stream
        /// items gate on it). Kept for symmetry / future gating.
        public var paneConnected: Bool
        /// The pane has at least one completed command BLOCK whose output can be fetched (gates
        /// "Copy Command Output"). The request still tolerates an empty reply, but greying it out when there
        /// is no block at all is the honest affordance.
        public var hasCommandOutput: Bool

        public init(
            hasSelection: Bool,
            clipboardHasText: Bool,
            paneConnected: Bool = true,
            hasCommandOutput: Bool = false,
        ) {
            self.hasSelection = hasSelection
            self.clipboardHasText = clipboardHasText
            self.paneConnected = paneConnected
            self.hasCommandOutput = hasCommandOutput
        }
    }

    /// The TOP-LEVEL menu items in display order. Stable; the view renders separators from
    /// `Item.separatorBefore`. The "Paste as…" variants are deliberately EXCLUDED — they hang off the
    /// ``pasteAsItems`` submenu (the view inserts it directly below `paste`), so `items != Item.allCases`.
    public static let items: [Item] = [
        .copy, .cut, .paste, .pasteAsKeystrokes, .selectAll, .clear, .copyOutput,
        .splitRight, .splitDown, .find,
    ]

    /// The "Paste as…" submenu items, in display order (`spec/terminal-features__copy-and-paste`):
    /// Paste Selection · Paste File Base64-Encoded… · Paste Escaping Special Characters · Bracketed Paste.
    public static let pasteAsItems: [Item] = [
        .pasteSelection, .pasteFileBase64, .pasteEscaped, .pasteBracketed,
    ]

    /// The title of the "Paste as…" submenu (Edit ▸ Paste ▸ Paste as), referenced by the GUI renderer.
    public static let pasteAsSubmenuTitle = "Paste as…"

    // MARK: - Path / URL link items (right-click ON a detected link)

    /// A right-click context-menu item shown ONLY when the click lands on a detected path / URL span
    /// (`docs/ui-shell/spec/user-interface__files-and-links.md` §"Right-click Context Menu Items"). These are
    /// kept SEPARATE from the always-present ``Item`` set: the GUI prepends them (with a separator) above the
    /// standard copy/paste/split menu when ``TerminalLinkDetector`` finds a span under the cursor, and each
    /// routes through ``LinkActionPolicy/action(for:link:)`` carrying the ``DetectedLink`` the view stashed at
    /// build time. The raw `String` tags the `NSMenuItem.representedObject` (the cd item also gives the
    /// tests / cheat-sheet a stable id).
    ///
    /// Only a functional subset of link actions is offered — *Open With…* (host app enumeration) and
    /// *Open in [target app]* (a remote-file pane needs a file-transfer sub-protocol that does not exist yet;
    /// see the files-and-links mapping notes #2/#3) are deliberately omitted rather than shipped as dead
    /// controls (tracked in `docs/DECISIONS.md`).
    public enum LinkItem: String, CaseIterable, Sendable, Equatable {
        /// Open the path in its best HOST handler, or the URL on the client ("Open Link" / "Open").
        case open
        /// Copy the resolved absolute path (or the URL) to the CLIENT pasteboard.
        case copyPath
        /// Reveal the path in the HOST Finder (paths only — meaningless for a URL).
        case revealInFinder
        /// `cd` the focused terminal to the path via verbatim-UTF-8 PTY input (paths only).
        case changeDirectoryHere

        /// The menu label, kind-aware: *Open Link* / *Copy URL* for a URL, *Open* / *Copy Path* for a path.
        public func title(for kind: DetectedLinkKind) -> String {
            let isURL = kind == .url
            switch self {
            case .open: return isURL ? "Open Link" : "Open"
            case .copyPath: return isURL ? "Copy URL" : "Copy Path"
            case .revealInFinder: return "Reveal in Finder"
            case .changeDirectoryHere: return "Change Directory Here"
            }
        }

        /// SF Symbol for the row (matches the binding-registry glyph vocabulary).
        public var symbol: String {
            switch self {
            case .open: "arrow.up.forward.app"
            case .copyPath: "doc.on.doc"
            case .revealInFinder: "folder"
            case .changeDirectoryHere: "arrow.turn.down.right"
            }
        }
    }

    /// The ordered link items for a detected `kind`. A URL only offers Open + Copy URL (a URL has no
    /// Finder target and you cannot `cd` into one); every path-like kind — including `file://` and a
    /// `path:line:col` — offers the full Open / Copy Path / Reveal / Change-Directory set.
    public static func linkItems(for kind: DetectedLinkKind) -> [LinkItem] {
        if kind == .url {
            return [.open, .copyPath]
        }
        return [.open, .copyPath, .revealInFinder, .changeDirectoryHere]
    }

    /// Whether `item` is enabled for `context` — the testable enablement rule:
    /// - **Copy / Cut** need a live selection.
    /// - **Paste / Paste as Keystrokes** need non-empty clipboard text.
    /// - **Paste as…**: *Paste Selection* needs a selection; *Paste File Base64* is always live
    ///   (it picks its own file); *Paste Escaping* / *Bracketed Paste* need clipboard text.
    /// - **Copy Command Output** needs a completed command block to fetch.
    /// - **Select All / Clear / Split Right / Split Down / Find** are always available (Select-All/Clear
    ///   act on the surface regardless of selection; splits + find act on the workspace).
    public static func isEnabled(_ item: Item, context: Context) -> Bool {
        switch item {
        case .copy,
             // Cut needs a selection too: it always copies the run, and (only at an editable prompt) deletes
             // it — on read-only scrollback it degrades to a plain copy, so a selection is the precondition.
             .cut:
            context.hasSelection
        case .paste,
             .pasteAsKeystrokes:
            context.clipboardHasText
        case .pasteSelection:
            context.hasSelection
        case .pasteFileBase64:
            true
        case .pasteEscaped,
             .pasteBracketed:
            context.clipboardHasText
        case .copyOutput:
            context.hasCommandOutput
        case .selectAll,
             .clear,
             .splitRight,
             .splitDown,
             .find:
            true
        }
    }
}

// MARK: - TerminalContextMenu (the near-side FACE of `slopdesk_terminal::context_menu`)

import CSlopDeskFFI
import SlopDeskWorkspaceModel

/// The right-click context menu (Ghostty/Warp parity): the ordered item list and — the testable heart
/// — each item's **enablement** for the current pane state (copy needs a selection, paste needs
/// clipboard text, splits need a connected pane). The GUI `NSMenu` built in
/// `GhosttyLayerBackedView.menu(for:)` is a thin renderer over this; routing each item to libghostty
/// (`copy_to_clipboard` / `paste_from_clipboard` / `select_all` / `clear_screen` binding actions) and to
/// the ``WorkspaceStore`` split/find ops is compile-only.
///
/// THE ORDER CROSSES SEPARATELY FROM THE WORDS. A menu is built twice for two different reasons: once
/// when it is constructed, from a list of indices in display order, and once per item, for the title
/// and glyph that item wears. Folding them would resend every word on every right-click — so the order
/// is a handful of bytes and the words are read once per process into a `static let`.
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

        /// The item's own index — the far side's discriminant order, which is `allCases`.
        var index: UInt8 {
            UInt8(Self.allCases.firstIndex(of: self) ?? 0)
        }

        /// The item at `index`, or `nil` for a byte no item has.
        static func at(_ index: UInt8) -> Self? {
            allCases.indices.contains(Int(index)) ? allCases[Int(index)] : nil
        }

        /// The menu label (sentence case, matching the macOS HIG + the rest of the app's verbs).
        public var title: String { Self.words[self]?.title ?? "" }

        /// SF Symbol for the menu row (matches the binding-registry glyph vocabulary).
        public var symbol: String { Self.words[self]?.symbol ?? "" }

        /// Whether a thin SEPARATOR is drawn ABOVE this item, grouping clipboard / edit / blocks / split / find.
        ///
        /// A property of the ITEM, not of its position: the same item opens the same group wherever the
        /// list places it, which is what stops a reordering from silently moving a rule.
        public var separatorBefore: Bool { Self.words[self]?.separatorBefore ?? false }

        /// Every item's separator and two words, in fourteen crossings, once per process.
        private static let words: [Self: (separatorBefore: Bool, title: String, symbol: String)] = Dictionary(
            uniqueKeysWithValues: allCases.compactMap { item in
                let blob = wsAnswerBytes { out, cap in Int(slopdesk_term_menu_item(item.index, out, cap)) }
                guard let separator = blob.first else { return nil }
                let text = wsRuns(Array(blob.dropFirst()), count: 2)
                return (item, (separator == 1, text[0], text[1]))
            },
        )
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

        /// The four gates in one byte, low bit first — the order the door declares.
        var bits: UInt8 {
            var bits: UInt8 = 0
            if hasSelection { bits |= 1 << 0 }
            if clipboardHasText { bits |= 1 << 1 }
            if paneConnected { bits |= 1 << 2 }
            if hasCommandOutput { bits |= 1 << 3 }
            return bits
        }
    }

    /// The TOP-LEVEL menu items in display order. Stable; the view renders separators from
    /// `Item.separatorBefore`. The "Paste as…" variants are deliberately EXCLUDED — they hang off the
    /// ``pasteAsItems`` submenu (the view inserts it directly below `paste`), so `items != Item.allCases`.
    public static let items: [Item] = ordered(pasteAs: false)

    /// The "Paste as…" submenu items, in display order (`spec/terminal-features__copy-and-paste`):
    /// Paste Selection · Paste File Base64-Encoded… · Paste Escaping Special Characters · Bracketed Paste.
    public static let pasteAsItems: [Item] = ordered(pasteAs: true)

    /// One list, as one byte per item in display order.
    private static func ordered(pasteAs: Bool) -> [Item] {
        wsAnswerBytes { out, cap in Int(slopdesk_term_menu_items(pasteAs, out, cap)) }
            .compactMap(Item.at)
    }

    /// The title of the "Paste as…" submenu (Edit ▸ Paste ▸ Paste as), referenced by the GUI renderer.
    public static let pasteAsSubmenuTitle: String = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_term_menu_words(out, cap)) },
        count: 1,
    )[0]

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

        /// The verb's own index — the far side's discriminant order, which is `allCases`.
        var index: UInt8 {
            UInt8(Self.allCases.firstIndex(of: self) ?? 0)
        }

        static func at(_ index: UInt8) -> Self? {
            allCases.indices.contains(Int(index)) ? allCases[Int(index)] : nil
        }

        /// The menu label, kind-aware: *Open Link* / *Copy URL* for a URL, *Open* / *Copy Path* for a path.
        ///
        /// The kind crosses with the verb because the TITLE depends on it, which is exactly the drift a
        /// caller that asked for a title and then adjusted it would produce.
        public func title(for kind: DetectedLinkKind) -> String {
            TerminalContextMenu.linkWords(kind)[self]?.title ?? ""
        }

        /// SF Symbol for the row (matches the binding-registry glyph vocabulary).
        ///
        /// The glyph does not vary with the kind, so any kind answers it; the URL one is asked because
        /// every verb has a URL spelling and a path-only verb would otherwise have no answer at all.
        public var symbol: String {
            TerminalContextMenu.linkWords(.url)[self]?.symbol
                ?? TerminalContextMenu.linkWords(.absolutePath)[self]?.symbol
                ?? ""
        }
    }

    /// The ordered link items for a detected `kind`. A URL only offers Open + Copy URL (a URL has no
    /// Finder target and you cannot `cd` into one); every path-like kind — including `file://` and a
    /// `path:line:col` — offers the full Open / Copy Path / Reveal / Change-Directory set.
    ///
    /// `kind` is handed to the door as the same `SLOPDESK_LINK_KIND_*` code the detector answers with,
    /// so a caller that scanned a row passes the kind straight through without a second vocabulary.
    public static func linkItems(for kind: DetectedLinkKind) -> [LinkItem] {
        let code = TerminalLinkDetector.code(of: kind)
        return wsAnswerBytes { out, cap in Int(slopdesk_term_link_items(code, out, cap)) }
            .compactMap(LinkItem.at)
    }

    /// Every link verb's two words at one kind.
    ///
    /// Keyed by kind rather than read once, because the title is what varies with it — and the two
    /// shapes ("Open Link" against a URL, "Open" against a path) are the whole reason the kind crosses.
    private static func linkWords(_ kind: DetectedLinkKind) -> [LinkItem: (title: String, symbol: String)] {
        linkWordTables[kind] ?? [:]
    }

    /// Every kind's table, once per process. Six kinds and four verbs is twenty-four crossings paid at
    /// launch; a right-click builds the link menu twice — once for the titles, once for the glyphs —
    /// and a link-dense row can right-click the same kind repeatedly.
    private static let linkWordTables: [DetectedLinkKind: [LinkItem: (title: String, symbol: String)]] =
        Dictionary(uniqueKeysWithValues: DetectedLinkKind.allCases.map { kind in
            let code = TerminalLinkDetector.code(of: kind)
            let table = LinkItem.allCases.compactMap { item -> (LinkItem, (title: String, symbol: String))? in
                let blob = wsAnswerBytes { out, cap in Int(slopdesk_term_link_item(item.index, code, out, cap)) }
                guard !blob.isEmpty else { return nil }
                let text = wsRuns(blob, count: 2)
                return (item, (text[0], text[1]))
            }
            return (kind, Dictionary(uniqueKeysWithValues: table))
        })

    /// Whether `item` is enabled for `context` — the testable enablement rule:
    /// - **Copy / Cut** need a live selection.
    /// - **Paste / Paste as Keystrokes** need non-empty clipboard text.
    /// - **Paste as…**: *Paste Selection* needs a selection; *Paste File Base64* is always live
    ///   (it picks its own file); *Paste Escaping* / *Bracketed Paste* need clipboard text.
    /// - **Copy Command Output** needs a completed command block to fetch.
    /// - **Select All / Clear / Split Right / Split Down / Find** are always available (Select-All/Clear
    ///   act on the surface regardless of selection; splits + find act on the workspace).
    public static func isEnabled(_ item: Item, context: Context) -> Bool {
        slopdesk_term_menu_enabled(item.index, context.bits)
    }
}

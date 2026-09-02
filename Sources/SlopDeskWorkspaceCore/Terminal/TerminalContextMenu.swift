// MARK: - TerminalContextMenu (the near-side FACE of `slopdesk_terminal::context_menu`)

import CSlopDeskFFI
import SlopDeskWorkspaceModel

/// The right-click context menu (Ghostty/Warp parity): the ordered item list and — the testable heart
/// — each item's **enablement** for the current pane state (copy needs a selection, paste needs
/// clipboard text, splits need a connected pane). The GUI `NSMenu` built in
/// `MacTerminalRendererView.menu(for:)` is a thin renderer over this; routing each item to
/// libghostty-vt (`copy_to_clipboard` / `paste_from_clipboard` / `select_all` / `clear_screen` binding
/// actions) and to
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
    /// time (the surface's `has_selection`, the host pasteboard, and whether the pane's transport is live).
    public struct Context: Equatable, Sendable {
        /// The surface currently holds a text selection (`slopdesk_term_surface_selection_verb`).
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

    // MARK: - Block items (right-click ON a command block)

    /// A right-click item that acts on the ONE command block under the pointer — the Warp shape.
    ///
    /// Kept SEPARATE from ``Item`` for ``LinkItem``'s reason and one more. ``Item/copyOutput`` acts on the
    /// LATEST block because it is also the keyboard verb and a keystroke has no pointer; these act on the
    /// block the click landed in. Both stay: the pane-global one is the chord, this section is the aim.
    /// The raw `String` tags the `NSMenuItem.representedObject`, as everywhere else in this face.
    public enum BlockItem: String, CaseIterable, Sendable, Equatable {
        /// Copy the block's command LINE — the host-segmented text, never the rendered prompt.
        case copyCommand
        /// Copy the block's captured OUTPUT (wire type 15 → 29), fetched on demand.
        case copyOutput
        /// Re-inject the block's command line into the shell (``BlockReRunEncoder``, verbatim + one `\n`).
        case reRun
        /// Fold the block down to its prompt, or unfold it.
        case collapse
        /// Star the block, or un-star it.
        case bookmark

        /// The verb's own index — the far side's discriminant order, which is `allCases`.
        var index: UInt8 {
            UInt8(Self.allCases.firstIndex(of: self) ?? 0)
        }

        static func at(_ index: UInt8) -> Self? {
            allCases.indices.contains(Int(index)) ? allCases[Int(index)] : nil
        }

        /// The menu label, STATE-AWARE for the two verbs that toggle: *Collapse Block* against *Expand
        /// Block*, *Bookmark Block* against *Remove Bookmark*. One item each rather than a pair, so a
        /// menu cannot draw both halves of a toggle at once.
        public func title(for context: BlockContext) -> String {
            TerminalContextMenu.blockWords(context)[self]?.title ?? ""
        }

        /// SF Symbol for the row, state-aware for the same two (`star` against `star.slash`).
        public func symbol(for context: BlockContext) -> String {
            TerminalContextMenu.blockWords(context)[self]?.symbol ?? ""
        }

        /// Whether a thin SEPARATOR is drawn ABOVE this item, splitting what the block GIVES you from
        /// what it does to the block. Independent of state, so any context answers it.
        public var separatorBefore: Bool {
            TerminalContextMenu.blockWords(BlockContext())[self]?.separatorBefore ?? false
        }
    }

    /// What the pointer found under it, and what the pane will allow — the snapshot a right-click over a
    /// block takes. Built from ``TerminalRendererSurface/BlockTarget`` plus the pane's own two facts.
    public struct BlockContext: Equatable, Hashable, Sendable {
        /// The block matched a host RECORD, so its command line and its ring index are both known.
        public var joined: Bool
        /// That record's command has finished, so there is output to ask for.
        public var complete: Bool
        /// The block has prompt rows of its own, so folding it leaves something behind.
        public var foldable: Bool
        /// It is folded RIGHT NOW — the toggle's label reads off this.
        public var collapsed: Bool
        /// It is starred right now — likewise.
        public var bookmarked: Bool
        /// The pane's PTY/transport is live.
        public var paneConnected: Bool
        /// ⚠️ The pane holds the read-only LOCK, which no menu may write around: Re-Run writes to the
        /// pty, so it greys here as well as being refused at ``TerminalViewModel/sendInput(_:)``.
        public var readOnly: Bool

        public init(
            joined: Bool = false,
            complete: Bool = false,
            foldable: Bool = false,
            collapsed: Bool = false,
            bookmarked: Bool = false,
            paneConnected: Bool = false,
            readOnly: Bool = false,
        ) {
            self.joined = joined
            self.complete = complete
            self.foldable = foldable
            self.collapsed = collapsed
            self.bookmarked = bookmarked
            self.paneConnected = paneConnected
            self.readOnly = readOnly
        }

        /// The seven gates in one byte, low bit first — the order the door declares.
        var bits: UInt8 {
            var bits: UInt8 = 0
            if joined { bits |= 1 << 0 }
            if complete { bits |= 1 << 1 }
            if foldable { bits |= 1 << 2 }
            if collapsed { bits |= 1 << 3 }
            if bookmarked { bits |= 1 << 4 }
            if paneConnected { bits |= 1 << 5 }
            if readOnly { bits |= 1 << 6 }
            return bits
        }

        /// The two bits the WORDS vary with, which is what the word cache is keyed by — the other five
        /// change enablement only, and caching against them would be 128 tables for five answers.
        var wordKey: Self {
            Self(collapsed: collapsed, bookmarked: bookmarked)
        }
    }

    /// The block section's items, in display order. The renderer prepends the section, with a
    /// separator, when the click hit a block at all — which verbs EXIST never varies with the block,
    /// only which of them are live, so the rows cannot move under the pointer between two right-clicks.
    public static let blockItems: [BlockItem] = wsAnswerBytes { out, cap in
        Int(slopdesk_term_menu_block_items(out, cap))
    }.compactMap(BlockItem.at)

    /// Every block verb's separator and two words at one toggle state.
    private static func blockWords(
        _ context: BlockContext,
    ) -> [BlockItem: (separatorBefore: Bool, title: String, symbol: String)] {
        blockWordTables[context.wordKey] ?? [:]
    }

    /// The four toggle states' tables, once per process — twenty crossings paid at launch against a
    /// right-click that asks for every row's title and glyph each time it opens.
    private static let blockWordTables:
        [BlockContext: [BlockItem: (separatorBefore: Bool, title: String, symbol: String)]] =
        Dictionary(uniqueKeysWithValues: [false, true].flatMap { collapsed in
            [false, true].map { bookmarked -> (
                BlockContext, [BlockItem: (separatorBefore: Bool, title: String, symbol: String)],
            ) in
                let key = BlockContext(collapsed: collapsed, bookmarked: bookmarked)
                let table = BlockItem.allCases.compactMap { item -> (
                    BlockItem, (separatorBefore: Bool, title: String, symbol: String),
                )? in
                    let blob = wsAnswerBytes { out, cap in
                        Int(slopdesk_term_menu_block_item(item.index, key.bits, out, cap))
                    }
                    guard let separator = blob.first else { return nil }
                    let text = wsRuns(Array(blob.dropFirst()), count: 2)
                    return (item, (separator == 1, text[0], text[1]))
                }
                return (key, Dictionary(uniqueKeysWithValues: table))
            }
        })

    /// Whether `item` is live for `context` — the testable rule:
    /// - **Copy Command / Re-Run / Bookmark** need the JOIN (the clean command line and the ring index
    ///   are the host's record; the rows on screen carry the PS1 with them).
    /// - **Copy Output** needs the join AND a finished command.
    /// - **Re-Run** additionally needs a connected pane that is NOT read-only — it writes to the pty.
    /// - **Collapse** needs a foldable block; an orphan whose command scrolled off has nothing to fold to.
    public static func isEnabled(_ item: BlockItem, context: BlockContext) -> Bool {
        slopdesk_term_menu_block_enabled(item.index, context.bits)
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
        slopdesk_term_menu_enabled(item.index, context.bits)
    }
}

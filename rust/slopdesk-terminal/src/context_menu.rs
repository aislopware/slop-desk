//! The terminal right-click menu: the ordered item list, the words, and — the testable heart —
//! each item's ENABLEMENT for the current pane state.
//!
//! Copy needs a selection, paste needs clipboard text, the block copy needs a completed block. The
//! `NSMenu` the Mac builds is a thin renderer over this, and routing each item to the terminal
//! surface (`TerminalSurfaceDriver.run(_:)` — `surface?.selection(.all)` / `.clear`,
//! `ClientPasteboard`) and to the workspace's split and find ops is compile-only.
//!
//! ## The submenu is not in the menu
//!
//! [`ITEMS`] is deliberately NOT every [`Item`]: the four "Paste as…" variants hang off
//! [`PASTE_AS_ITEMS`], which the renderer inserts directly below Paste. A list derived from "every
//! case" would put all four in the top level the first time one was added.

use crate::link::DetectedLinkKind;

/// One menu action.
///
/// The order here is the FFI discriminant order and is deliberately not the display order, which is
/// [`ITEMS`] followed by [`PASTE_AS_ITEMS`].
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Item {
    /// Copy the selection.
    Copy,
    /// `⌘X` — copies the selection and, at an editable prompt, deletes it; on read-only scrollback
    /// it degrades to a plain copy.
    Cut,
    /// Paste the clipboard.
    Paste,
    /// Paste the clipboard as individual key events, for the field that refuses everything else.
    PasteAsKeystrokes,
    /// Paste the current SELECTION instead of the clipboard (the X11 middle-click).
    PasteSelection,
    /// Base64-encode a chosen file's bytes and type them.
    PasteFileBase64,
    /// Shell-escape the clipboard so spaces and metacharacters land as literals.
    PasteEscaped,
    /// Force DEC bracketed-paste framing even if the program did not ask.
    PasteBracketed,
    /// Select the whole surface.
    SelectAll,
    /// Clear the screen.
    Clear,
    /// Copy the latest command BLOCK's output.
    CopyOutput,
    /// Split the pane into a new column.
    SplitRight,
    /// Split the pane into a new row.
    SplitDown,
    /// Open the in-pane find bar.
    Find,
}

impl Item {
    /// Every item, in discriminant order.
    pub const ALL: [Self; 14] = [
        Self::Copy,
        Self::Cut,
        Self::Paste,
        Self::PasteAsKeystrokes,
        Self::PasteSelection,
        Self::PasteFileBase64,
        Self::PasteEscaped,
        Self::PasteBracketed,
        Self::SelectAll,
        Self::Clear,
        Self::CopyOutput,
        Self::SplitRight,
        Self::SplitDown,
        Self::Find,
    ];

    /// The item at `index` in [`ALL`](Self::ALL), or `None` past the end.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::Copy),
            1 => Some(Self::Cut),
            2 => Some(Self::Paste),
            3 => Some(Self::PasteAsKeystrokes),
            4 => Some(Self::PasteSelection),
            5 => Some(Self::PasteFileBase64),
            6 => Some(Self::PasteEscaped),
            7 => Some(Self::PasteBracketed),
            8 => Some(Self::SelectAll),
            9 => Some(Self::Clear),
            10 => Some(Self::CopyOutput),
            11 => Some(Self::SplitRight),
            12 => Some(Self::SplitDown),
            13 => Some(Self::Find),
            _ => None,
        }
    }

    /// This item's place in [`ALL`](Self::ALL) — the tag a rendered row carries back.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Copy => 0,
            Self::Cut => 1,
            Self::Paste => 2,
            Self::PasteAsKeystrokes => 3,
            Self::PasteSelection => 4,
            Self::PasteFileBase64 => 5,
            Self::PasteEscaped => 6,
            Self::PasteBracketed => 7,
            Self::SelectAll => 8,
            Self::Clear => 9,
            Self::CopyOutput => 10,
            Self::SplitRight => 11,
            Self::SplitDown => 12,
            Self::Find => 13,
        }
    }

    /// The menu label, sentence case, matching the platform guidelines and the rest of the app's
    /// verbs.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::Copy => "Copy",
            Self::Cut => "Cut",
            Self::Paste => "Paste",
            Self::PasteAsKeystrokes => "Paste as Keystrokes",
            Self::PasteSelection => "Paste Selection",
            Self::PasteFileBase64 => "Paste File Base64-Encoded…",
            Self::PasteEscaped => "Paste Escaping Special Characters",
            Self::PasteBracketed => "Bracketed Paste",
            Self::SelectAll => "Select All",
            Self::Clear => "Clear",
            Self::CopyOutput => "Copy Command Output",
            Self::SplitRight => "Split Right",
            Self::SplitDown => "Split Down",
            Self::Find => "Find…",
        }
    }

    /// The SF Symbol for the row, matching the binding registry's glyph vocabulary.
    #[must_use]
    pub const fn symbol(self) -> &'static str {
        match self {
            Self::Copy => "doc.on.doc",
            Self::Cut => "scissors",
            Self::Paste => "clipboard",
            Self::PasteAsKeystrokes => "keyboard",
            Self::PasteSelection => "text.cursor",
            Self::PasteFileBase64 => "doc.badge.plus",
            Self::PasteEscaped => "textformat",
            Self::PasteBracketed => "curlybraces",
            Self::SelectAll => "selection.pin.in.out",
            Self::Clear => "eraser",
            Self::CopyOutput => "text.alignleft",
            Self::SplitRight => "rectangle.split.2x1",
            Self::SplitDown => "rectangle.split.1x2",
            Self::Find => "magnifyingglass",
        }
    }

    /// Whether a thin SEPARATOR is drawn ABOVE this item, grouping clipboard / edit / blocks /
    /// split / find.
    #[must_use]
    pub const fn separator_before(self) -> bool {
        matches!(
            self,
            Self::SelectAll | Self::CopyOutput | Self::SplitRight | Self::Find
        )
    }

    /// Whether this item is enabled for `context`.
    ///
    /// - **Copy / Cut** need a live selection. Cut needs one too: it always copies the run and only
    ///   deletes it at an editable prompt, so a selection is the precondition either way.
    /// - **Paste / Paste as Keystrokes** need non-empty clipboard text.
    /// - **Paste as…**: *Paste Selection* needs a selection; *Paste File Base64* is always live (it
    ///   picks its own file); *Paste Escaping* and *Bracketed Paste* need clipboard text.
    /// - **Copy Command Output** needs a completed command block to fetch.
    /// - **Select All / Clear / Split Right / Split Down / Find** are always available — the first
    ///   two act on the surface regardless of selection, the last three on the workspace.
    #[must_use]
    pub const fn is_enabled(self, context: Context) -> bool {
        match self {
            Self::Copy | Self::Cut | Self::PasteSelection => context.has_selection,
            Self::Paste | Self::PasteAsKeystrokes | Self::PasteEscaped | Self::PasteBracketed => {
                context.clipboard_has_text
            },
            Self::CopyOutput => context.has_command_output,
            Self::PasteFileBase64
            | Self::SelectAll
            | Self::Clear
            | Self::SplitRight
            | Self::SplitDown
            | Self::Find => true,
        }
    }
}

/// The inputs that decide each item's enablement — a pure snapshot the view captures at right-click
/// time.
#[expect(
    clippy::struct_excessive_bools,
    reason = "this IS the snapshot a right-click takes: four independent facts about the pane, each gating \
              a different item. A bitset here would hide that; `bits` offers the packed form for the one \
              caller that needs it"
)]
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub struct Context {
    /// The surface currently holds a text selection.
    pub has_selection: bool,
    /// The host pasteboard has a non-empty string.
    pub clipboard_has_text: bool,
    /// The pane's PTY/transport is connected. Kept for symmetry: splits and find target the
    /// WORKSPACE rather than the byte stream, so only byte-stream items would ever gate on it.
    pub pane_connected: bool,
    /// The pane has at least one completed command BLOCK whose output can be fetched. The request
    /// tolerates an empty reply, but greying the item out when there is no block at all is the
    /// honest affordance.
    pub has_command_output: bool,
}

impl Context {
    /// The four gates read out of one byte, LOW BIT FIRST in declaration order.
    #[must_use]
    pub const fn from_bits(bits: u8) -> Self {
        Self {
            has_selection: bits & 1 != 0,
            clipboard_has_text: bits & 2 != 0,
            pane_connected: bits & 4 != 0,
            has_command_output: bits & 8 != 0,
        }
    }

    /// The inverse of [`from_bits`](Self::from_bits).
    #[must_use]
    pub const fn bits(self) -> u8 {
        let mut bits = 0_u8;
        if self.has_selection {
            bits |= 1;
        }
        if self.clipboard_has_text {
            bits |= 2;
        }
        if self.pane_connected {
            bits |= 4;
        }
        if self.has_command_output {
            bits |= 8;
        }
        bits
    }
}

/// The TOP-LEVEL menu items, in display order.
///
/// The renderer draws separators from [`Item::separator_before`]. The four "Paste as…" variants are
/// deliberately EXCLUDED — see the module header.
pub const ITEMS: [Item; 10] = [
    Item::Copy,
    Item::Cut,
    Item::Paste,
    Item::PasteAsKeystrokes,
    Item::SelectAll,
    Item::Clear,
    Item::CopyOutput,
    Item::SplitRight,
    Item::SplitDown,
    Item::Find,
];

/// The "Paste as…" submenu items, in display order.
pub const PASTE_AS_ITEMS: [Item; 4] = [
    Item::PasteSelection,
    Item::PasteFileBase64,
    Item::PasteEscaped,
    Item::PasteBracketed,
];

/// The title of the "Paste as…" submenu.
pub const PASTE_AS_SUBMENU_TITLE: &str = "Paste as…";

/// A right-click item shown ONLY when the click lands on a detected path or URL span.
///
/// Kept SEPARATE from [`Item`]: the renderer prepends these, with a separator, above the standard
/// menu when the link detector finds a span under the cursor, and each routes through the link
/// action policy carrying the detected link the view stashed at build time.
///
/// Only a functional subset of link actions is offered — *Open With…* (host app enumeration) and
/// *Open in [target app]* (a remote-file pane needs a file-transfer sub-protocol that does not
/// exist yet) are deliberately omitted rather than shipped as dead controls.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LinkItem {
    /// Open the path in its best HOST handler, or the URL on the client.
    Open,
    /// Copy the resolved absolute path, or the URL, to the CLIENT pasteboard.
    CopyPath,
    /// Reveal the path in the HOST Finder — paths only, meaningless for a URL.
    RevealInFinder,
    /// `cd` the focused terminal to the path via verbatim-UTF-8 PTY input — paths only.
    ChangeDirectoryHere,
}

impl LinkItem {
    /// Every link item, in discriminant order.
    pub const ALL: [Self; 4] = [
        Self::Open,
        Self::CopyPath,
        Self::RevealInFinder,
        Self::ChangeDirectoryHere,
    ];

    /// The link item at `index`, or `None` past the end.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::Open),
            1 => Some(Self::CopyPath),
            2 => Some(Self::RevealInFinder),
            3 => Some(Self::ChangeDirectoryHere),
            _ => None,
        }
    }

    /// This item's place in [`ALL`](Self::ALL).
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Open => 0,
            Self::CopyPath => 1,
            Self::RevealInFinder => 2,
            Self::ChangeDirectoryHere => 3,
        }
    }

    /// The menu label, KIND-AWARE: *Open Link* / *Copy URL* for a URL, *Open* / *Copy Path* for a
    /// path.
    #[must_use]
    pub const fn title(self, kind: DetectedLinkKind) -> &'static str {
        let is_url = matches!(kind, DetectedLinkKind::Url);
        match self {
            Self::Open => {
                if is_url {
                    "Open Link"
                } else {
                    "Open"
                }
            },
            Self::CopyPath => {
                if is_url {
                    "Copy URL"
                } else {
                    "Copy Path"
                }
            },
            Self::RevealInFinder => "Reveal in Finder",
            Self::ChangeDirectoryHere => "Change Directory Here",
        }
    }

    /// The SF Symbol for the row.
    #[must_use]
    pub const fn symbol(self) -> &'static str {
        match self {
            Self::Open => "arrow.up.forward.app",
            Self::CopyPath => "doc.on.doc",
            Self::RevealInFinder => "folder",
            Self::ChangeDirectoryHere => "arrow.turn.down.right",
        }
    }
}

/// The ordered link items for a detected `kind`.
///
/// A URL only offers Open and Copy URL — a URL has no Finder target and you cannot `cd` into one.
/// Every path-like kind, INCLUDING `file://` and a `path:line:col`, offers the full set.
#[must_use]
pub const fn link_items(kind: DetectedLinkKind) -> &'static [LinkItem] {
    match kind {
        DetectedLinkKind::Url => &[LinkItem::Open, LinkItem::CopyPath],
        _ => &LinkItem::ALL,
    }
}

#[cfg(test)]
mod tests {
    use super::{Context, ITEMS, Item, LinkItem, PASTE_AS_ITEMS, link_items};
    use crate::link::DetectedLinkKind;

    #[test]
    fn every_index_round_trips() {
        for (position, item) in Item::ALL.into_iter().enumerate() {
            assert_eq!(usize::from(item.index()), position);
            assert_eq!(Item::from_index(item.index()), Some(item));
        }
        assert_eq!(Item::from_index(14), None);
        for (position, item) in LinkItem::ALL.into_iter().enumerate() {
            assert_eq!(usize::from(item.index()), position);
            assert_eq!(LinkItem::from_index(item.index()), Some(item));
        }
        assert_eq!(LinkItem::from_index(4), None);
    }

    /// The top level is NOT every case, and the two lists together are.
    #[test]
    fn the_paste_as_variants_hang_off_the_submenu_rather_than_the_menu() {
        for item in PASTE_AS_ITEMS {
            assert!(!ITEMS.contains(&item), "{item:?} escaped into the top level");
        }
        let mut every: Vec<u8> = ITEMS.into_iter().chain(PASTE_AS_ITEMS).map(Item::index).collect();
        every.sort_unstable();
        assert_eq!(
            every,
            (0..14).collect::<Vec<u8>>(),
            "an item belongs to neither list"
        );
    }

    /// The four separators cut the menu into five groups, and they only fall in the top level.
    #[test]
    fn the_separators_group_the_top_level() {
        let cuts: Vec<Item> = ITEMS.into_iter().filter(|item| item.separator_before()).collect();
        assert_eq!(cuts, vec![
            Item::SelectAll,
            Item::CopyOutput,
            Item::SplitRight,
            Item::Find
        ]);
        assert!(
            !ITEMS.first().is_some_and(|item| item.separator_before()),
            "no leading rule",
        );
    }

    /// Every item says something and draws something — a blank row is a row nobody can read.
    #[test]
    fn every_item_carries_a_word_and_a_glyph() {
        for item in Item::ALL {
            assert!(!item.title().is_empty());
            assert!(!item.symbol().is_empty());
        }
        for item in LinkItem::ALL {
            assert!(!item.symbol().is_empty());
            assert!(!item.title(DetectedLinkKind::Url).is_empty());
            assert!(!item.title(DetectedLinkKind::AbsolutePath).is_empty());
        }
    }

    #[test]
    fn a_selection_is_the_precondition_for_both_halves_of_a_cut() {
        let empty = Context::default();
        let selected = Context {
            has_selection: true,
            ..empty
        };
        for item in [Item::Copy, Item::Cut, Item::PasteSelection] {
            assert!(!item.is_enabled(empty), "{item:?} enabled with no selection");
            assert!(item.is_enabled(selected));
        }
    }

    #[test]
    fn the_clipboard_items_wait_on_the_clipboard_and_the_file_paste_never_does() {
        let empty = Context::default();
        let filled = Context {
            clipboard_has_text: true,
            ..empty
        };
        for item in [
            Item::Paste,
            Item::PasteAsKeystrokes,
            Item::PasteEscaped,
            Item::PasteBracketed,
        ] {
            assert!(
                !item.is_enabled(empty),
                "{item:?} enabled with an empty clipboard"
            );
            assert!(item.is_enabled(filled));
        }
        assert!(
            Item::PasteFileBase64.is_enabled(empty),
            "it picks its own file, so nothing gates it",
        );
    }

    #[test]
    fn the_block_copy_waits_on_a_block_and_the_workspace_items_wait_on_nothing() {
        let empty = Context::default();
        assert!(!Item::CopyOutput.is_enabled(empty));
        assert!(Item::CopyOutput.is_enabled(Context {
            has_command_output: true,
            ..empty
        }));
        for item in [
            Item::SelectAll,
            Item::Clear,
            Item::SplitRight,
            Item::SplitDown,
            Item::Find,
        ] {
            assert!(
                item.is_enabled(empty),
                "{item:?} gated on something it does not need"
            );
        }
    }

    /// The transport bit gates NOTHING today, which is a claim worth failing on rather than a
    /// comment: splits and find target the workspace.
    #[test]
    fn the_transport_bit_changes_no_verdict() {
        for bits in 0..16_u8 {
            let context = Context::from_bits(bits);
            assert_eq!(context.bits(), bits);
            let flipped = Context {
                pane_connected: !context.pane_connected,
                ..context
            };
            for item in Item::ALL {
                assert_eq!(item.is_enabled(context), item.is_enabled(flipped), "{item:?}");
            }
        }
    }

    /// A URL has no Finder target and cannot be `cd`-ed into; everything path-like offers the lot.
    #[test]
    fn a_url_offers_two_items_and_every_path_kind_offers_four() {
        assert_eq!(link_items(DetectedLinkKind::Url), [
            LinkItem::Open,
            LinkItem::CopyPath
        ]);
        for kind in [
            DetectedLinkKind::AbsolutePath,
            DetectedLinkKind::TildePath,
            DetectedLinkKind::RelativePath,
            DetectedLinkKind::PathLineCol,
            DetectedLinkKind::FileUrl,
        ] {
            assert_eq!(link_items(kind), LinkItem::ALL, "{kind:?}");
        }
    }

    /// The two kind-aware labels differ, and only for the two items that name the thing.
    #[test]
    fn the_url_labels_name_a_link_where_the_path_labels_name_a_path() {
        assert_eq!(LinkItem::Open.title(DetectedLinkKind::Url), "Open Link");
        assert_eq!(LinkItem::Open.title(DetectedLinkKind::FileUrl), "Open");
        assert_eq!(LinkItem::CopyPath.title(DetectedLinkKind::Url), "Copy URL");
        assert_eq!(
            LinkItem::CopyPath.title(DetectedLinkKind::AbsolutePath),
            "Copy Path"
        );
        for kind in [DetectedLinkKind::Url, DetectedLinkKind::AbsolutePath] {
            assert_eq!(LinkItem::RevealInFinder.title(kind), "Reveal in Finder");
        }
    }
}

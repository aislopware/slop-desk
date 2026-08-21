//! Which UI half a KEYBINDING belongs to.
//!
//! ## The same defect as [`crate::palette_rows`], one surface further in
//!
//! The palette table closed three rows that were listed and inert. The registry those rows mirror
//! was left alone in that increment, deliberately, and it listed the same three verbs: *Detach Pane
//! into Window* on ⌥⌘P, *Reattach All Panes*, and *Pin Window*. The registry is not one surface —
//! it is the cheat sheet, the keybindings editor, the `ctl` verb list and the CHORD TABLE the
//! keyboard dispatcher resolves against. So on a phone, ⌥⌘P was swallowed by a binding that routed
//! to a macOS-only `#if` with nothing in the `#else`, and the keybindings editor offered to REBIND
//! a chord onto an action that half cannot perform.
//!
//! The chord table is the part that made this worse than a cosmetic row. A bound chord does not
//! reach the terminal: ⌥⌘P was taken away from the PTY to run nothing. Dropping the row drops the
//! chord, so the key falls through to the pane, which is what an unbound chord is supposed to do.
//!
//! ## Why a SECOND table and not one shared with the palette
//!
//! Because they are two id spaces over two vocabularies, and the overlap is partial in both
//! directions. The palette files verbs as `action.detachPane`; the registry files the same verb as
//! `pane.detach`, and it also carries ~45 rows with no palette entry at all (every focus move,
//! every resize nudge, every scroll jump) plus rows the palette has and the registry does not
//! (`action.connect`, `action.copyPath`). A table keyed by one spelling could not answer for the
//! other's rows, and a table keyed by both would be a join maintained by hand. Two tables, each
//! complete over its own id space, each pinned to its own Swift list by
//! `scripts/check-supervisor.sh` — that is what makes "a new verb must declare a platform" true on
//! both sides rather than true on whichever side someone remembered.
//!
//! ## The nine generated select-pane rows
//!
//! `WorkspaceBindingRegistry.selectPaneBindings` mints `pane.select.1`…`pane.select.9` from a loop;
//! only the collapsed representative (`pane.selectN`) is written out as a literal, and that is the
//! one this table declares. The nine are undeclared and therefore SHOWN — correct, because they are
//! `Both`, and the supervisor's id-set pin excludes that one generated family by name rather than
//! by silence.
//!
//! GOLDEN-SAFE: metadata only. Nothing here reads or writes a value or touches a wire codec.

use crate::settings_layout::Platform;

/// One binding row's platform.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BindingRow {
    /// The row id `WorkspaceBindingRegistry` files it under — `<noun>.<verb>`.
    pub id: &'static str,
    /// Which half lists it, and therefore which half BINDS its chord.
    pub platform: Platform,
}

/// One row.
const fn row(id: &'static str, platform: Platform) -> BindingRow {
    BindingRow { id, platform }
}

/// Every row the registry writes out, in registry order.
///
/// The `Mac` entries are the same features the palette's are, in this table's spelling: an
/// own-window satellite, a window level, the `AppKit` secure-input call and the window close.
/// Everything else is `Both`, including rows a phone reaches through a gesture rather than a chord
/// — docs/56 §3 is explicit that layout diverges and capability does not, and a row here is a
/// CAPABILITY even when the phone has no keyboard attached to fire it.
pub const ROWS: [BindingRow; 77] = [
    // Panes
    row("pane.splitRight", Platform::Both),
    row("pane.splitDown", Platform::Both),
    row("pane.splitLeft", Platform::Both),
    row("pane.splitUp", Platform::Both),
    row("pane.close", Platform::Both),
    row("pane.rename", Platform::Both),
    row("pane.breakToTab", Platform::Both),
    // The satellite pair — `action.detachPane` / `action.reattachAllPanes` in the palette's spelling.
    // `pane.detach` pops the active pane into its own `NSWindow`; a shell with no such window would
    // strand it out of every tab with nothing rendering it, which is why its ROUTING arm was a
    // macOS-only `#if` with an empty else and its chord (⌥⌘P) was taken from the PTY for nothing.
    // `pane.reattachAll` is the same feature read backwards: on a shell that cannot detach, the set
    // it folds back is always empty.
    row("pane.detach", Platform::Mac),
    row("pane.reattachAll", Platform::Mac),
    row("pane.moveLeft", Platform::Both),
    row("pane.moveRight", Platform::Both),
    row("pane.moveUp", Platform::Both),
    row("pane.moveDown", Platform::Both),
    row("pane.resizeLeft", Platform::Both),
    row("pane.resizeRight", Platform::Both),
    row("pane.resizeUp", Platform::Both),
    row("pane.resizeDown", Platform::Both),
    row("pane.balance", Platform::Both),
    row("pane.cycleLayout", Platform::Both),
    // Tabs
    row("tab.new", Platform::Both),
    row("tab.newDesktop", Platform::Both),
    row("tab.next", Platform::Both),
    row("tab.prev", Platform::Both),
    row("pane.switcher", Platform::Both),
    row("tab.close", Platform::Both),
    // ⌘⇧W, and the palette's `action.closeWindow`. Its routing arm is not an empty closure but a
    // FALLBACK — `WorkspaceStore.requestCloseWindow()`, which parks `pendingWindowClose` for the
    // Mac's `windowShouldClose` gate to resolve. The phone's close-confirmation alert reads the pane
    // and tab parks only, so on that half the chord either parked a flag nothing observes or cleared
    // it and returned. Dropping the row hands ⌘⇧W back to the pane.
    row("window.close", Platform::Mac),
    row("tab.reopenClosed", Platform::Both),
    row("tab.syncInput", Platform::Both),
    row("view.jumpToAttention", Platform::Both),
    row("view.peekReply", Platform::Both),
    // Focus
    row("focus.left", Platform::Both),
    row("focus.right", Platform::Both),
    row("focus.up", Platform::Both),
    row("focus.down", Platform::Both),
    row("focus.cycleNext", Platform::Both),
    row("focus.cyclePrev", Platform::Both),
    // View
    row("view.zoom", Platform::Both),
    row("view.palette", Platform::Both),
    row("view.cheatSheet", Platform::Both),
    row("view.find", Platform::Both),
    row("view.findNext", Platform::Both),
    row("view.findPrev", Platform::Both),
    row("view.globalSearch", Platform::Both),
    row("view.copyMode", Platform::Both),
    row("view.viKeyHints", Platform::Both),
    row("view.readOnly", Platform::Both),
    // `action.secureKeyboardEntry` in the palette's spelling. `EnableSecureEventInput` is `AppKit`'s
    // and process-global; `TerminalViewModel.refreshSecureInput()` is `let value = false` off macOS,
    // so on a phone this flipped a flag whose only listener is a `nil` closure and left the SECURE
    // INPUT pill dark. This row is chord-LESS, so what it cost the phone was not a key: it was a
    // cheat-sheet line and a keybindings editor offering to bind a chord onto it.
    row("view.secureKeyboardEntry", Platform::Mac),
    row("view.releaseStuckInput", Platform::Both),
    row("view.lockViewport", Platform::Both),
    row("view.fitViewportToPane", Platform::Both),
    row("view.resetViewportZoom", Platform::Both),
    row("view.pasteAsKeystrokes", Platform::Both),
    row("view.toggleSidebar", Platform::Both),
    row("view.toggleCodeSidebar", Platform::Both),
    row("focus.codePanel", Platform::Both),
    // A window LEVEL — `action.pinWindow` in the palette's spelling. A phone has one window and no
    // z-order among apps, so the routing closure no phone root binds stays nil and the row stays off
    // the phone's list rather than answering ⌃⌘T-shaped chords with nothing.
    row("view.pinWindow", Platform::Mac),
    row("view.commandNavigator", Platform::Both),
    row("view.jumpTo", Platform::Both),
    row("view.hintOpen", Platform::Both),
    row("view.hintCopy", Platform::Both),
    row("view.hintReveal", Platform::Both),
    row("view.jumpPreviousBlock", Platform::Both),
    row("view.jumpNextBlock", Platform::Both),
    row("view.reRunLastCommand", Platform::Both),
    row("view.jumpPreviousFailed", Platform::Both),
    row("view.jumpNextFailed", Platform::Both),
    row("view.scrollPageUp", Platform::Both),
    row("view.scrollPageDown", Platform::Both),
    row("view.scrollTop", Platform::Both),
    row("view.scrollBottom", Platform::Both),
    row("view.cmdJumpPrev", Platform::Both),
    row("view.cmdJumpNext", Platform::Both),
    row("view.fontIncrease", Platform::Both),
    row("view.fontDecrease", Platform::Both),
    row("view.fontReset", Platform::Both),
    row("view.openQuickly", Platform::Both),
    // The collapsed ⌘1…⌘9 representative. The nine generated `pane.select.N` ids are undeclared and
    // therefore shown — see the module note.
    row("pane.selectN", Platform::Both),
];

/// The row `id` is filed under, if this table declares one.
#[must_use]
fn row_at(id: &str) -> Option<BindingRow> {
    ROWS.iter().copied().find(|row| row.id == id)
}

/// Whether the half that identifies as `mac` lists `id` — and therefore binds its chord.
///
/// An id no row declares is SHOWN. Failing closed here would let a typo unbind a chord in silence,
/// which is a worse version of the defect this module exists to close;
/// `scripts/check-supervisor.sh` is what makes an undeclared id impossible in the first place.
#[must_use]
pub fn shown(id: &str, mac: bool) -> bool {
    row_at(id).is_none_or(|row| row.platform.shown_on(mac))
}

#[cfg(test)]
mod tests {
    use super::{ROWS, row_at, shown};
    use crate::palette_rows;
    use crate::settings_layout::Platform;

    #[test]
    fn every_id_is_declared_once_and_reads_as_a_registry_id() {
        let mut seen = std::collections::BTreeSet::new();
        for row in ROWS {
            assert!(seen.insert(row.id), "{} is declared twice", row.id);
            assert!(
                row.id
                    .split_once('.')
                    .is_some_and(|(noun, verb)| !noun.is_empty() && !verb.is_empty()),
                "{} is not a noun.verb registry id",
                row.id
            );
            assert!(
                !row.id.starts_with("action."),
                "{} is a PALETTE id — the two tables keep their own spellings",
                row.id
            );
        }
    }

    #[test]
    fn only_the_rows_with_an_appkit_backing_are_the_macs_alone() {
        let mac: Vec<&str> = ROWS
            .iter()
            .filter(|row| row.platform == Platform::Mac)
            .map(|row| row.id)
            .collect();
        assert_eq!(mac, vec![
            "pane.detach",
            "pane.reattachAll",
            "window.close",
            "view.secureKeyboardEntry",
            "view.pinWindow"
        ]);
        assert!(
            !ROWS.iter().any(|row| row.platform == Platform::Phone),
            "no binding is the phone's alone — a smaller screen is not a smaller product",
        );
    }

    /// The two tables spell the same three verbs differently and must still WITHHOLD the same
    /// three. A verb hidden from the palette but bound to a chord (or the reverse) is the drift
    /// that having two id spaces invites, and this is the only place both are in scope at once.
    #[test]
    fn the_two_tables_withhold_the_same_feature() {
        for (binding, verb) in [
            ("pane.detach", "action.detachPane"),
            ("pane.reattachAll", "action.reattachAllPanes"),
            ("window.close", "action.closeWindow"),
            ("view.secureKeyboardEntry", "action.secureKeyboardEntry"),
            ("view.pinWindow", "action.pinWindow"),
        ] {
            for mac in [true, false] {
                assert_eq!(
                    shown(binding, mac),
                    palette_rows::shown(verb, mac),
                    "{binding} and {verb} are one feature and disagreed for mac={mac}",
                );
            }
        }
    }

    #[test]
    fn a_mac_row_is_hidden_only_from_the_phone() {
        assert!(shown("pane.detach", true));
        assert!(!shown("pane.detach", false));
        assert!(shown("pane.close", true) && shown("pane.close", false));
    }

    #[test]
    fn the_generated_select_pane_slots_are_shown_by_falling_open() {
        assert!(row_at("pane.select.4").is_none());
        assert!(shown("pane.select.4", false));
        assert!(shown("nobody.declaredThis", false));
    }
}

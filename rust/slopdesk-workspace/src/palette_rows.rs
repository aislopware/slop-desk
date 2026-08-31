//! Which UI half a command-palette row belongs to.
//!
//! ## The defect this exists to make unrepresentable
//!
//! Every actuator on the palette's coordinator defaults to an empty closure, and every `.store`
//! row's run arm is free to be a `#if os(macOS)` with nothing in the `#else`. Both mean the same
//! thing at runtime and neither is visible from the row: **a row that is listed and inert looks
//! exactly like a row that ran and had nothing to do.** The phone's palette listed *Pin Window*
//! (whose hook no phone root binds), *Detach Pane into Window* (whose run body is `_ = store` on
//! iOS) and *Reattach All Panes* (which can never have anything to reattach on a shell that cannot
//! detach). Three rows that answered a keystroke by doing nothing, silently.
//!
//! An action that is ABSENT on a platform is fine. An action that is LISTED and inert is not — it
//! teaches the user that the palette lies, and it does it in the one surface whose whole job is to
//! tell them what the app can do. So the platform is a FIELD on the row, exactly as it is a field
//! on a settings group ([`crate::platform::Platform`], reused here rather than
//! respelled): the Mac's palette asks for the rows a Mac draws, the phone's asks for the phone's,
//! and neither carries a gate.
//!
//! ## What does NOT cross
//!
//! Everything else about a row. The title, the icon, the keywords, the category, the chord hint and
//! the run arm all stay in `ActionsPaletteSource` — they are strings the near side already owns and
//! a closure that cannot leave Swift. This table carries the one fact the near side kept getting
//! wrong, keyed by the id it already files each row under.
//!
//! ## Fail OPEN, and let the ratchet close it
//!
//! [`shown`] answers `true` for an id no row here declares. A typo must not delete a row from the
//! palette — that failure is silent in exactly the way this module exists to stop. What makes an
//! undeclared row impossible is `rust/slopdesk-invariants`, which pins the two id sets equal in
//! both directions.
//!
//! GOLDEN-SAFE: metadata only. Nothing here reads or writes a value or touches a wire codec.

use crate::platform::Platform;

/// One palette row's platform.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PaletteRow {
    /// The row id `ActionsPaletteSource` files it under — `action.<verb>`.
    pub id: &'static str,
    /// Which half lists it.
    pub platform: Platform,
}

/// One row.
const fn row(id: &'static str, platform: Platform) -> PaletteRow {
    PaletteRow { id, platform }
}

/// Every row in the verb catalog, in catalog order.
///
/// Each `Mac` entry is macOS-only because the BACKING is, and the backings are of three kinds: an
/// `NSWindow` an iOS shell has no second of, a window LEVEL it has no z-order for, and an `AppKit`
/// process-global call (`EnableSecureEventInput`) with no iOS form at all. Everything else is
/// `Both` — including the ones a phone reaches rarely, because docs/56 §3 is explicit that layout
/// diverges and capability does not.
pub const ROWS: [PaletteRow; 35] = [
    row("action.copyPath", Platform::Both),
    // The two host-routed siblings of Copy Path. They actuate on the HOST's Finder / Launch Services
    // (metadata verbs 10 and 9) — the cwd names a directory on the host Mac, not on whatever machine
    // is drawing the palette — so the phone reaches them exactly as the Mac does. Neither is an
    // `NSWorkspace` call on the near side, which is what would have made them the Mac's alone.
    row("action.revealCwd", Platform::Both),
    row("action.openCwd", Platform::Both),
    row("action.newTerminalTab", Platform::Both),
    row("action.newDesktopTab", Platform::Both),
    row("action.closeTab", Platform::Both),
    row("action.splitRight", Platform::Both),
    row("action.splitDown", Platform::Both),
    row("action.closePane", Platform::Both),
    row("action.toggleZoom", Platform::Both),
    row("action.renamePane", Platform::Both),
    // The satellite pair. `detachPane` pops the active pane into its own window; on a shell with no
    // such window it would strand the pane out of every tab with nothing rendering it, which is why
    // its run arm was a macOS-only `#if` with an empty else. `reattachAllPanes` is the same feature
    // read backwards — on a shell that cannot detach, the set it folds back is always empty.
    row("action.detachPane", Platform::Mac),
    row("action.reattachAllPanes", Platform::Mac),
    row("action.movePaneToNewTab", Platform::Both),
    row("action.reconnect", Platform::Both),
    row("action.toggleSidebar", Platform::Both),
    row("action.toggleCodeSidebar", Platform::Both),
    row("action.focusCodePanel", Platform::Both),
    row("action.toggleReadOnly", Platform::Both),
    // `EnableSecureEventInput` is AppKit's, process-global, and has no iOS form. The near side says
    // so outright — `TerminalViewModel.refreshSecureInput()` is `let value = false` off macOS — so on
    // a phone this verb flipped a flag whose only reader is a `nil` closure and left the SECURE INPUT
    // pill dark. Listed and inert, which is the row above's distinction from an absent action.
    row("action.secureKeyboardEntry", Platform::Mac),
    row("action.reopenClosed", Platform::Both),
    row("action.toggleSyncInput", Platform::Both),
    row("action.layoutEvenHorizontal", Platform::Both),
    row("action.layoutEvenVertical", Platform::Both),
    row("action.layoutMainVertical", Platform::Both),
    row("action.layoutMainHorizontal", Platform::Both),
    row("action.layoutTiled", Platform::Both),
    // Close Window is `NSWindow`'s too, and it is the one row here whose FALLBACK is what made it
    // inert rather than an empty closure. With no actuator the route lands on
    // `WorkspaceStore.requestCloseWindow()`, which parks `pendingWindowClose` — and the only reader
    // of that park is the Mac's `windowShouldClose` gate. The phone's alert answers the PANE and TAB
    // parks and has no arm for this one, so ⌘⇧W either parked a flag nothing could resolve or
    // cleared it and did nothing.
    row("action.closeWindow", Platform::Mac),
    row("action.increaseFontSize", Platform::Both),
    row("action.decreaseFontSize", Platform::Both),
    row("action.resetFontSize", Platform::Both),
    row("action.connect", Platform::Both),
    // A window LEVEL. A phone has one window and no z-order among apps, so the coordinator hook no
    // phone root binds stays unbound and the row stays off the phone's list.
    row("action.pinWindow", Platform::Mac),
    row("action.openSettings", Platform::Both),
    row("action.cheatSheet", Platform::Both),
];

/// The row `id` is filed under, if this table declares one.
#[must_use]
fn row_at(id: &str) -> Option<PaletteRow> {
    ROWS.iter().copied().find(|row| row.id == id)
}

/// Whether the half that identifies as `mac` lists `id`.
///
/// An id no row declares is SHOWN. See the module note: closing that hole is the supervisor's job,
/// because failing closed here would let a typo delete a row without a word.
#[must_use]
pub fn shown(id: &str, mac: bool) -> bool {
    row_at(id).is_none_or(|row| row.platform.shown_on(mac))
}

#[cfg(test)]
mod tests {
    use super::{ROWS, row_at, shown};
    use crate::platform::Platform;

    #[test]
    fn every_id_is_declared_once_and_reads_as_a_verb() {
        let mut seen = std::collections::BTreeSet::new();
        for row in ROWS {
            assert!(seen.insert(row.id), "{} is declared twice", row.id);
            assert!(
                row.id.starts_with("action."),
                "{} is not a palette verb id",
                row.id
            );
            assert!(
                row.id.len() > "action.".len(),
                "{} has no verb after its prefix",
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
            "action.detachPane",
            "action.reattachAllPanes",
            "action.secureKeyboardEntry",
            "action.closeWindow",
            "action.pinWindow"
        ],);
        assert!(
            !ROWS.iter().any(|row| row.platform == Platform::Phone),
            "no verb is the phone's alone — a smaller screen is not a smaller product",
        );
    }

    #[test]
    fn a_mac_row_is_hidden_only_from_the_phone() {
        assert!(shown("action.pinWindow", true));
        assert!(!shown("action.pinWindow", false));
        assert!(shown("action.copyPath", true) && shown("action.copyPath", false));
    }

    #[test]
    fn an_undeclared_id_is_shown_rather_than_swallowed() {
        assert!(row_at("action.nobodyDeclaredThis").is_none());
        assert!(shown("action.nobodyDeclaredThis", true));
        assert!(shown("action.nobodyDeclaredThis", false));
    }
}

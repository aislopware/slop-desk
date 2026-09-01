//! WHY the pane area is empty, and WHAT IT SAYS.
//!
//! A reading of the CONNECTION rather than a fact about either drawing: "connected but no tabs" and
//! "the link is down and the supervisor is redialing" are different sentences the user needs to
//! hear, and a canvas rewritten in `AppKit` must say the same four things the phone's `UIKit` one
//! does.
//!
//! ## Four strings, no colour
//!
//! The symbol is a NAME (not an image), the action is a LABEL (not a button) and the caption is a
//! sentence — so nothing here needs a design token, and there is nothing for a cross-renderer pin
//! to hold. Each half resolves the symbol name through its own image type and draws the same words.
//!
//! ## The failure caption is carried, not composed
//!
//! A failed connect prints the REAL reason rather than the generic not-connected copy, so a wrong
//! host or port reads as its own mistake. That reason is [`connection::headline`]'s — the same
//! sentence the gate card shows — and it arrives here already made rather than being re-worded, so
//! the empty pane and the gate card can never describe one failure two ways.
//!
//! [`connection::headline`]: crate::connection::headline

use crate::connection::StatusKind;

/// WHY the pane area is empty.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Cause {
    /// No host connected (fresh launch / disconnected) — the next action is the Connect editor.
    NeverConnected = 0,
    /// A host WAS reachable and the link is down — the supervisor is redialing on its own, so there
    /// is no action; the caption names the host being re-dialed.
    LinkDown = 1,
    /// Connected fine — just no open tabs; the next action mints one.
    NoTabs = 2,
    /// The last explicit connect attempt failed — the caption carries the real reason and the
    /// action reopens the Connect editor to correct it.
    ConnectFailed = 3,
}

impl Cause {
    /// This cause in the byte the boundary carries.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The cause a byte names. An unrecognised one reads as never-connected, which is the only
    /// reading that offers the Connect editor and blames nothing that did not happen.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        match byte {
            1 => Self::LinkDown,
            2 => Self::NoTabs,
            3 => Self::ConnectFailed,
            _ => Self::NeverConnected,
        }
    }

    /// The muted SF Symbol above the title. A NAME, so the two renderers resolve it through their
    /// own image type rather than sharing one they cannot both import.
    #[must_use]
    pub const fn symbol(self) -> &'static str {
        match self {
            Self::NeverConnected => "bolt.horizontal",
            Self::LinkDown => "wifi.exclamationmark",
            Self::NoTabs => "terminal",
            Self::ConnectFailed => "exclamationmark.triangle",
        }
    }

    /// The short headline. It names the ACTUAL reason ("Not Connected" vs "Connection Lost" vs "No
    /// Open Tabs") rather than one generic "No Session" for all four.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::NeverConnected => "Not Connected",
            Self::LinkDown => "Connection Lost",
            Self::NoTabs => "No Open Tabs",
            Self::ConnectFailed => "Connect Failed",
        }
    }

    /// The single next action's label, or `None` when the cause has none — link-down redials
    /// itself, and offering a button there would suggest the user must do something.
    #[must_use]
    pub const fn action(self) -> Option<&'static str> {
        match self {
            Self::NeverConnected | Self::ConnectFailed => Some("Connect to Host…"),
            Self::NoTabs => Some("New Tab"),
            Self::LinkDown => None,
        }
    }
}

/// Which cause a live connection reads as.
///
/// Connected ⇒ the only thing missing is a tab; an active redial ⇒ link-down (named host, no action
/// — the supervisor is already dialing); anything else (a fresh launch, the give-up states, a first
/// `connecting`) reads not-connected, whose action opens the Connect editor.
#[must_use]
pub const fn cause(status: StatusKind) -> Cause {
    match status {
        StatusKind::Connected => Cause::NoTabs,
        StatusKind::Reconnecting => Cause::LinkDown,
        StatusKind::Failed => Cause::ConnectFailed,
        StatusKind::Disconnected | StatusKind::Connecting | StatusKind::Unreachable => Cause::NeverConnected,
    }
}

/// The one-line cause under the title.
///
/// `host` is only read for a redial and `reason` only for a failure — each is the one thing that
/// reading needs, and neither is composed into the other.
#[must_use]
pub fn caption(cause: Cause, host: &str, reason: &str) -> String {
    match cause {
        Cause::NeverConnected => "Connect to a host to open a terminal.".to_owned(),
        Cause::LinkDown => format!("Reconnecting to {host}…"),
        Cause::NoTabs => "Open a tab to get started.".to_owned(),
        Cause::ConnectFailed => reason.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::{Cause, caption, cause};
    use crate::connection::StatusKind;

    #[test]
    fn only_a_live_link_reads_as_merely_having_no_tabs() {
        assert_eq!(cause(StatusKind::Connected), Cause::NoTabs);
        for status in [
            StatusKind::Disconnected,
            StatusKind::Connecting,
            StatusKind::Unreachable,
        ] {
            assert_eq!(
                cause(status),
                Cause::NeverConnected,
                "a give-up state is not a redial and must not promise one"
            );
        }
        assert_eq!(cause(StatusKind::Reconnecting), Cause::LinkDown);
        assert_eq!(cause(StatusKind::Failed), Cause::ConnectFailed);
    }

    /// The three tables verbatim. A typo'd SF Symbol name renders a BLANK glyph rather than a wrong
    /// one, so distinctness alone would let it through; the titles and the action labels are the
    /// wording a second renderer would otherwise re-type.
    #[test]
    fn the_three_tables_are_pinned_letter_for_letter() {
        assert_eq!(Cause::NeverConnected.symbol(), "bolt.horizontal");
        assert_eq!(Cause::LinkDown.symbol(), "wifi.exclamationmark");
        assert_eq!(Cause::NoTabs.symbol(), "terminal");
        assert_eq!(Cause::ConnectFailed.symbol(), "exclamationmark.triangle");

        assert_eq!(Cause::NeverConnected.title(), "Not Connected");
        assert_eq!(Cause::LinkDown.title(), "Connection Lost");
        assert_eq!(Cause::NoTabs.title(), "No Open Tabs");
        assert_eq!(Cause::ConnectFailed.title(), "Connect Failed");

        assert_eq!(Cause::NeverConnected.action(), Some("Connect to Host…"));
        assert_eq!(Cause::NoTabs.action(), Some("New Tab"));
        assert_eq!(Cause::ConnectFailed.action(), Some("Connect to Host…"));
    }

    #[test]
    fn a_redial_offers_no_button_and_every_other_cause_does() {
        assert_eq!(
            Cause::LinkDown.action(),
            None,
            "the supervisor is already dialing"
        );
        for cause in [Cause::NeverConnected, Cause::NoTabs, Cause::ConnectFailed] {
            assert!(cause.action().is_some());
        }
    }

    #[test]
    fn every_cause_names_its_own_symbol_and_its_own_title() {
        let all = [
            Cause::NeverConnected,
            Cause::LinkDown,
            Cause::NoTabs,
            Cause::ConnectFailed,
        ];
        let mut symbols: Vec<&str> = all.iter().map(|cause| cause.symbol()).collect();
        symbols.sort_unstable();
        symbols.dedup();
        assert_eq!(
            symbols.len(),
            all.len(),
            "the glyph is part of the distinction the copy makes"
        );
        let mut titles: Vec<&str> = all.iter().map(|cause| cause.title()).collect();
        titles.sort_unstable();
        titles.dedup();
        assert_eq!(
            titles.len(),
            all.len(),
            "four causes that read alike are one pretending to be four"
        );
    }

    #[test]
    fn the_host_is_named_only_where_it_is_being_redialled() {
        assert_eq!(
            caption(Cause::LinkDown, "mac-studio", ""),
            "Reconnecting to mac-studio…"
        );
        assert_eq!(
            caption(Cause::NoTabs, "mac-studio", ""),
            "Open a tab to get started."
        );
        assert_eq!(
            caption(Cause::NeverConnected, "mac-studio", ""),
            "Connect to a host to open a terminal."
        );
    }

    #[test]
    fn a_failure_prints_its_reason_verbatim_rather_than_the_generic_copy() {
        assert_eq!(
            caption(Cause::ConnectFailed, "mac-studio", "Connection refused"),
            "Connection refused"
        );
    }

    #[test]
    fn an_unknown_byte_reads_as_the_cause_that_blames_nothing() {
        assert_eq!(Cause::from_byte(0), Cause::NeverConnected);
        assert_eq!(Cause::from_byte(9), Cause::NeverConnected);
        for cause in [
            Cause::NeverConnected,
            Cause::LinkDown,
            Cause::NoTabs,
            Cause::ConnectFailed,
        ] {
            assert_eq!(Cause::from_byte(cause.as_byte()), cause, "the byte round-trips");
        }
    }
}

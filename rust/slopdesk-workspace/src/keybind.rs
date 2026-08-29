//! What a `keybind` line's ACTION NAME rebinds — the config vocabulary, resolved to a binding id.
//!
//! [`slopdesk_terminal::keybind`](../../slopdesk-terminal/src/keybind.rs) turns one config line
//! into a chord plus a named action; this is the other half, and the two are deliberately in
//! different crates. The grammar knows what a line LOOKS like. It does not know which actions
//! exist, because the actions are this crate's — [`crate::bindings`] declares the same family — and
//! a grammar that knew them would have to be rebuilt every time a binding was added.
//!
//! ## Validate then drop, on untrusted config text
//!
//! Every refusal answers `None`. An unknown name, a `goto_tab` argument that is not one of the nine
//! tabs, and the three libghostty-only responder actions all resolve to nothing, and the caller
//! drops the line. Nothing here can invent an id: the answers are the literals below, so a resolved
//! id always names a binding that exists.
//!
//! ## Why the responder actions are ABSENT rather than listed
//!
//! `copy_to_clipboard`, `paste_from_clipboard` and `select_all` are real config names that
//! libghostty's own responder handles. They have no workspace action at all, so there is no id to
//! answer with, and listing them mapped to some placeholder would put a binding in the registry
//! that fires nothing. They fall through the table the way an unknown name does, which is the same
//! answer for the same reason.

/// The nine per-digit pane bindings `goto_tab:N` names, `goto_tab:1` first.
///
/// The LIST is the bound. `⌘1`…`⌘9` is nine chords because there are nine of these rows — a tenth
/// digit is not a chord the platform delivers — so resolving by position means there is no separate
/// range to keep in step with the table it guards. [`crate::bindings`] writes only the collapsed
/// representative (`pane.selectN`) because these nine are minted from a loop on the near side.
const SELECT_PANE_BINDING_IDS: [&str; 9] = [
    "pane.select.1",
    "pane.select.2",
    "pane.select.3",
    "pane.select.4",
    "pane.select.5",
    "pane.select.6",
    "pane.select.7",
    "pane.select.8",
    "pane.select.9",
];

/// The bare (unparameterised) config names, each paired with the binding id it fires.
///
/// A slice rather than a map: sixteen rows scanned once per config line, against a hash that would
/// be built once per process and read the same sixteen times.
const CONFIG_NAME_BINDING_IDS: [(&str, &str); 16] = [
    // Panes
    ("new_tab", "tab.new"),
    ("split_right", "pane.splitRight"),
    ("split_left", "pane.splitLeft"),
    ("split_down", "pane.splitDown"),
    ("split_up", "pane.splitUp"),
    ("close_pane", "pane.close"),
    // Tabs
    ("reopen_closed", "tab.reopenClosed"),
    ("next_tab", "tab.next"),
    ("prev_tab", "tab.prev"),
    // Focus
    ("focus_left", "focus.left"),
    ("focus_right", "focus.right"),
    ("focus_up", "focus.up"),
    ("focus_down", "focus.down"),
    // View
    ("command_palette", "view.palette"),
    ("cheat_sheet", "view.cheatSheet"),
    ("find", "view.find"),
];

/// The binding id a config action name fires, or `None` when it names none.
///
/// `goto_tab` is the one name that reads its argument: a base-ten index into the nine per-digit
/// bindings, one-based because that is how a user counts tabs and how the chord is spelled. The
/// name stays Ghostty's even though what a ⌘-digit lands on in this app is a PANE — a config that
/// asks for the Nth thing gets the Nth thing this workspace counts.
///
/// Every other name is a bare action, and a stray argument on one is ignored rather than refused:
/// the action takes none, so an argument cannot change which one it is.
#[must_use]
pub fn binding_id_for_config_name(name: &str, arg: Option<&str>) -> Option<&'static str> {
    if name == "goto_tab" {
        // One-based, so `goto_tab:0` has no row to land on and neither does anything past the
        // ninth. Parsing as `usize` refuses a negative and a hostile run of digits before the
        // position is ever computed.
        let tab: usize = arg?.parse().ok()?;
        return SELECT_PANE_BINDING_IDS.get(tab.checked_sub(1)?).copied();
    }
    CONFIG_NAME_BINDING_IDS
        .iter()
        .find(|(config, _)| *config == name)
        .map(|(_, id)| *id)
}

#[cfg(test)]
mod tests {
    use super::{CONFIG_NAME_BINDING_IDS, SELECT_PANE_BINDING_IDS, binding_id_for_config_name};

    #[test]
    fn every_bare_name_resolves_to_the_id_beside_it() {
        for (name, id) in CONFIG_NAME_BINDING_IDS {
            assert_eq!(binding_id_for_config_name(name, None), Some(id));
        }
    }

    #[test]
    fn goto_tab_resolves_per_digit_and_refuses_everything_outside_the_nine() {
        for (index, id) in SELECT_PANE_BINDING_IDS.iter().enumerate() {
            let arg = (index + 1).to_string();
            assert_eq!(binding_id_for_config_name("goto_tab", Some(&arg)), Some(*id));
        }
        for arg in ["0", "10", "-1", "x", "", " 3 ", "99999999999999999999"] {
            assert_eq!(
                binding_id_for_config_name("goto_tab", Some(arg)),
                None,
                "goto_tab:{arg} names no binding"
            );
        }
        assert_eq!(
            binding_id_for_config_name("goto_tab", None),
            None,
            "goto_tab is not a bare name — it needs the digit to know which binding it is"
        );
    }

    #[test]
    fn a_stray_argument_on_a_bare_name_does_not_change_which_action_it_is() {
        assert_eq!(binding_id_for_config_name("new_tab", Some("7")), Some("tab.new"));
    }

    /// Every id this module can answer with must name a row the table declares — otherwise a
    /// config line resolves to a binding the registry has never heard of, and the rebind lands on
    /// nothing. The nine per-digit ids are the exception the table itself documents: they are
    /// minted from a loop on the near side, so only their collapsed representative is written out.
    #[test]
    fn every_id_this_module_answers_with_names_a_row_that_exists() {
        for (name, id) in CONFIG_NAME_BINDING_IDS {
            assert!(
                crate::bindings::ROWS.iter().any(|row| row.id == id),
                "{name} resolves to {id}, which no binding row declares",
            );
        }
        for id in SELECT_PANE_BINDING_IDS {
            let digit = id.strip_prefix("pane.select.");
            assert!(
                digit.is_some_and(|digit| ("1"..="9").contains(&digit)),
                "{id} is outside the nine per-digit ids the loop mints on the near side",
            );
        }
    }

    #[test]
    fn an_unknown_name_and_a_responder_only_action_both_answer_nothing() {
        assert_eq!(binding_id_for_config_name("frobnicate", None), None);
        assert_eq!(binding_id_for_config_name("", None), None);
        for name in ["copy_to_clipboard", "paste_from_clipboard", "select_all"] {
            assert_eq!(
                binding_id_for_config_name(name, None),
                None,
                "{name} is libghostty's responder's, and has no workspace action to name"
            );
        }
    }
}

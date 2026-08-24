//! # `slopdesk-workspace`
//!
//! The workspace document's DOMAIN rules that are ABOUT a surface, in safe Rust. Stage 12 of moving
//! `SlopDesk` off Swift (`docs/DECISIONS.md`), and the first one outside the video path.
//!
//! Three crates came out of this one, and what is left is what none of them wanted. The tree model
//! and its operations are [`slopdesk_tree`]; the Settings catalogue is
//! [`slopdesk-settings`](https://docs.rs/slopdesk-settings); the id, JSON and shell-word notations
//! are [`slopdesk_ids`]. What remains here is everything that puts a value in front of somebody:
//! the rails and their titles, the palette and the binding rows, the git line, the notification
//! policy, the phone keyboard, the workspace file, the templates that spawn panes.
//!
//! - [`rail_title`] — what a pane is CALLED, in the one precedence every surface that names one
//!   shares, and what its second line says once the surface has said the rest.
//! - [`rail_list`] — what happens to that pane once it is standing next to every other one:
//!   filtered, sectioned, ordered, and told apart from its namesakes.
//! - [`git_line`] — the project header's git dialect: which runs a line has, in what order, what
//!   each one means, and which of them give up their place when the column narrows.
//! - [`list_nav`] — where the highlight goes when an arrow, a page key, a Tab or a `⌘1–9` chord
//!   arrives over any of those lists.
//! - [`search_rank`] — the one ranking behind every search field, and why a title hit outranks a
//!   subtitle hit that scored higher.
//! - [`persist`] — the client's workspace file: the trees and their specs on disk, and the repairs
//!   that bring a hand-edited one back rather than trapping on it.
//! - [`listen`] — what port the HOST may bind, and how to tell a bind collision apart from a
//!   network that has not come up yet.
//! - [`notify`] — when the app is allowed to speak: the banner's two gates, the badge a background
//!   pane keeps, the two cues, and the bound on what a remote shell can ask for.
//! - [`send_keys`] — text with control tokens in it, turned into the bytes a PTY receives.
//! - [`keystroke_replay`] — a clipboard as the KEY EVENTS that type it, for the one field that
//!   refuses everything else, and the grapheme rule that keeps an accent from becoming its base
//!   letter in a password.
//! - [`connection`] — the link island's whole reading: which state the link is in, what each run
//!   says, which of them may climb, and what a raw transport failure means in words a person can
//!   act on.
//! - [`pane_drop`] — where a dragged PANE lands over another one, and the rectangles the preview
//!   draws to promise it, so the two UI halves cannot preview one drop and commit another.
//! - [`peek_reply`] — what the Peek & Reply card sends down another pane's PTY, and the transcript
//!   tail it shows above the field.
//! - [`phone_key`] — the other end of the same PTY: a live phone key press, split between the two
//!   input paths a touch device is forced to have, and encoded under the mode the far side set.
//! - [`secrets`] — the credential shapes, scanned for in anything a remote shell wrote.
//! - [`templates`] — the two things that spawn panes, and the bytes they type into them.
//! - [`workdir`] — where a freshly-opened pane starts, and why naming no directory is an answer.
//! - [`status_pill`] — the pane's status chips: which are up, in what order, and what each says.
//! - [`vi_hints`] — the copy-mode reference card's tables, its mode pill, and the width ladder it
//!   re-flows on.
//! - [`panel_tabs`] — the right panel's four tabs, and how many of them get to say their name.
//! - [`drop_register`] — the one vocabulary a pane drop is announced in, over both drop grammars.
//! - [`find_bar`] — what the in-pane find bar says, and the two rungs an INPUT DEVICE earns.
//! - [`global_search`] — the cross-tab results surface, and the excerpt cut that must degrade
//!   rather than trap.
//! - [`toast`] — the three events that raise a notification card, and what each one says.
//! - [`palette_card`] — how big the command palette is, and how far one page of it moves.
//!
//! ## Invariants
//!
//! * **No `unsafe`, enforced by `forbid(unsafe_code)`.**
//! * **Three outside dependencies, each a notation rather than a decision.** `regex` because a
//!   credential shape belongs written as one, `slopdesk-fuzzy` because a ranking that scored with a
//!   second matcher would order the same list two ways, and `unicode-segmentation` because where
//!   one grapheme cluster ends is the Unicode standard's answer and hand-rolling it would type an
//!   `e` where the clipboard said `é`. Everything else here is arithmetic and ordering, where
//!   reaching for a crate would be a sign a decision had leaked in.
//! * **Three inside ones, and they all point DOWN.** [`slopdesk_ids`], [`slopdesk_tree`] and
//!   `slopdesk-settings` know nothing about this crate, and an edge back from any of them is the
//!   layering inversion that carving them out removed.
//! * **Total functions over hostile input.** These rules used to run only on a client's main actor
//!   with trusted local input; through the workspace channel they now run against a network peer.
//!   Nothing here indexes, unwraps or panics — the lint table denies all three.

pub mod binding_rows;
pub mod binding_search;
pub mod cheat_sheet;
pub mod connection;
pub mod drop_action;
pub mod drop_register;
pub mod drop_zone;
pub mod find_bar;
pub mod frecency;
pub mod git_line;
pub mod global_search;
pub mod hid_virtual_key;
pub mod jump;
pub mod keybind;
pub mod keystroke_replay;
pub mod list_nav;
pub mod listen;
pub mod notify;
pub mod palette_card;
pub mod palette_rows;
pub mod pane_drop;
pub mod panel_tabs;
pub mod peek_reply;
pub mod persist;
pub mod phone_key;
pub mod rail_list;
pub mod rail_title;
pub mod search_rank;
pub mod secrets;
pub mod send_keys;
pub mod state_codec;
pub mod status_pill;
pub mod templates;
pub mod toast;
pub mod vi_hints;
pub mod window_size;
pub mod workdir;

pub use frecency::{FolderEntry, ReferenceSeconds};
pub use jump::JumpResolution;
pub use persist::{FileError, MAX_PANES, NO_REFUSAL, decode_file, encode_file, minted_ids_for};
pub use templates::{LaunchPreset, SessionTemplate, TemplateNode, TemplatePane};

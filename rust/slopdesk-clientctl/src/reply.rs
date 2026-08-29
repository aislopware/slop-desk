//! What the running client answered, and the NDJSON line that says so.
//!
//! The other half of [`crate::request`]. An executor is handed a [`crate::request::Op`], drives
//! whatever it drives, and describes the result as an [`Outcome`] — a list of windows, a resolved
//! path, a refusal. [`line`] turns that into the response line. Nothing between the socket and the
//! executor builds JSON, which is why the executor may be in another language without that language
//! growing a second opinion about the wire.
//!
//! ## Sorted keys, and why the `result` disappears when it is empty
//! `serde_json`'s object is a `BTreeMap`, so keys come out sorted — the same ordering Foundation's
//! `.sortedKeys` produced when this encoder was Swift, which is what lets the golden lines next
//! door be statements about BYTES. A success with nothing to report omits `result` entirely rather
//! than carrying `{}`, because that is the envelope the host ctl socket has always used and the CLI
//! reads both sockets with one decoder.

use serde_json::{Map, Value};
use slopdesk_agent::badge::TabBadge;
use slopdesk_agent::status::ClaudeStatus;

use crate::request::Refusal;
use crate::token_for_badge;

/// One window in a `windows` listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Window {
    /// The window's stable id.
    pub id: String,
    /// Its title, as the chrome shows it.
    pub title: String,
    /// How many tabs it holds.
    pub tab_count: i64,
    /// Whether it is the focused window. At most one is.
    pub focused: bool,
}

/// One tab in a `tabs` listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tab {
    /// The tab's stable id.
    pub id: String,
    /// The window it lives in.
    pub window_id: String,
    /// Its title.
    pub title: String,
    /// How many panes it holds.
    pub pane_count: i64,
    /// Whether it is the focused tab of the focused window.
    pub focused: bool,
    /// The badge it is currently wearing, or `None`. Written as its CANONICAL token, which is why
    /// the badge crosses as the type and not as a spelling the far side chose.
    pub badge: Option<TabBadge>,
}

/// One pane in a `panes` listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pane {
    /// The pane's stable id.
    pub id: String,
    /// The tab it lives in.
    pub tab_id: String,
    /// Its title.
    pub title: String,
    /// What kind of pane it is, in the chrome's own vocabulary.
    pub kind: String,
    /// Whether it is the focused pane.
    pub focused: bool,
    /// The last OSC-7 working directory the client cached, if any.
    pub cwd: Option<String>,
}

/// One font family in a `font-list`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Font {
    /// The family name.
    pub family: String,
    /// Whether every glyph advances the same width.
    pub monospace: bool,
    /// Whether it ships with the OS rather than being user-installed.
    pub system: bool,
}

/// One binding in a `keybind-list`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Keybind {
    /// The action's name.
    pub action: String,
    /// Its chord(s), already human-readable.
    pub keys: String,
}

/// What the running client answered.
///
/// Every variant is one verb's whole result, so an executor cannot half-answer: there is no
/// "success with no shape" to fall through to, and the one way to say no is [`Self::Refused`],
/// which carries a code from the closed vocabulary rather than a sentence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The verb landed and has nothing to report (`view`, `edit`, `pane-send-keys`).
    Done,
    /// A `windows` listing.
    Windows(Vec<Window>),
    /// A `tabs` listing.
    Tabs(Vec<Tab>),
    /// A `panes` listing.
    Panes(Vec<Pane>),
    /// A `font-list`.
    Fonts(Vec<Font>),
    /// A `keybind-list`.
    Keybinds(Vec<Keybind>),
    /// A `pane-capture`'s scrollback lines.
    Captured(Vec<String>),
    /// A `tab-badge` that landed, echoing the badge the tab now wears.
    Badge(TabBadge),
    /// A `jump` that resolved, and whether the `cd` was actually sent.
    Jumped {
        /// The resolved directory.
        path: String,
        /// `false` when `--no-cd` only printed it.
        changed: bool,
    },
    /// A `learn` or `ignore` that landed, echoing the path it acted on.
    Path(String),
    /// An `agent-status` reading.
    ///
    /// `seen` false is an id that resolves to NO pane, which `watch:claude` reads as exit 4. `seen`
    /// true with no `status` is the agent-startup window — the pane exists and has not reported —
    /// which keeps the watch polling. The two are different answers and a `Option<ClaudeStatus>`
    /// alone could not tell them apart.
    Agent {
        /// Whether the id resolved to a live pane at all.
        seen: bool,
        /// Its rolled-up status, absent through the startup window.
        status: Option<ClaudeStatus>,
    },
    /// The verb could not be served. The detail is the token a person mistyped, empty for the
    /// fifteen refusals that name none.
    Refused {
        /// Which refusal.
        refusal: Refusal,
        /// The token it names, if it names one.
        detail: String,
    },
}

/// The response line for one outcome, WITHOUT the trailing LF — the caller frames its own lines.
#[must_use]
pub fn line(id: &str, outcome: &Outcome) -> String {
    match *outcome {
        Outcome::Refused { refusal, ref detail } => refusal_line(id, refusal, detail),
        _ => success_line(id, result(outcome)),
    }
}

/// One refusal as a line. Public because a request that never reached an executor still answers
/// one, and the decoder is where those are worded.
#[must_use]
pub fn refusal_line(id: &str, refusal: Refusal, detail: &str) -> String {
    let mut root = Map::new();
    drop(root.insert("id".to_owned(), Value::from(id)));
    drop(root.insert("ok".to_owned(), Value::from(false)));
    drop(root.insert("error".to_owned(), Value::from(refusal.message(detail))));
    Value::Object(root).to_string()
}

/// A success envelope. `result` is OMITTED when empty rather than sent as `{}` — the shape the host
/// ctl socket uses, and the CLI reads both with one decoder.
fn success_line(id: &str, result: Map<String, Value>) -> String {
    let mut root = Map::new();
    drop(root.insert("id".to_owned(), Value::from(id)));
    drop(root.insert("ok".to_owned(), Value::from(true)));
    if !result.is_empty() {
        drop(root.insert("result".to_owned(), Value::Object(result)));
    }
    Value::Object(root).to_string()
}

/// The `result` object one outcome carries.
fn result(outcome: &Outcome) -> Map<String, Value> {
    let mut out = Map::new();
    match *outcome {
        // A refusal has no result; it is answered by `refusal_line` and never reaches here.
        Outcome::Done | Outcome::Refused { .. } => {},
        Outcome::Windows(ref items) => {
            drop(out.insert("windows".to_owned(), array(items, window)));
        },
        Outcome::Tabs(ref items) => {
            drop(out.insert("tabs".to_owned(), array(items, tab)));
        },
        Outcome::Panes(ref items) => {
            drop(out.insert("panes".to_owned(), array(items, pane)));
        },
        Outcome::Fonts(ref items) => {
            drop(out.insert("fonts".to_owned(), array(items, font)));
        },
        Outcome::Keybinds(ref items) => {
            drop(out.insert("keybinds".to_owned(), array(items, keybind)));
        },
        Outcome::Captured(ref lines) => {
            drop(out.insert(
                "lines".to_owned(),
                Value::Array(lines.iter().map(|text| Value::from(text.as_str())).collect()),
            ));
        },
        Outcome::Badge(kind) => {
            drop(out.insert("kind".to_owned(), Value::from(token_for_badge(kind))));
        },
        Outcome::Jumped { ref path, changed } => {
            drop(out.insert("path".to_owned(), Value::from(path.as_str())));
            drop(out.insert("changed".to_owned(), Value::from(changed)));
        },
        Outcome::Path(ref path) => {
            drop(out.insert("path".to_owned(), Value::from(path.as_str())));
        },
        Outcome::Agent { seen, status } => {
            drop(out.insert("seen".to_owned(), Value::from(seen)));
            if let Some(reading) = status {
                drop(out.insert("status".to_owned(), Value::from(reading.token())));
            }
        },
    }
    out
}

/// One listing, as an array of objects.
fn array<T>(items: &[T], row: fn(&T) -> Value) -> Value {
    Value::Array(items.iter().map(row).collect())
}

fn window(item: &Window) -> Value {
    let mut row = Map::new();
    drop(row.insert("id".to_owned(), Value::from(item.id.as_str())));
    drop(row.insert("title".to_owned(), Value::from(item.title.as_str())));
    drop(row.insert("tabCount".to_owned(), Value::from(item.tab_count)));
    drop(row.insert("focused".to_owned(), Value::from(item.focused)));
    Value::Object(row)
}

fn tab(item: &Tab) -> Value {
    let mut row = Map::new();
    drop(row.insert("id".to_owned(), Value::from(item.id.as_str())));
    drop(row.insert("windowId".to_owned(), Value::from(item.window_id.as_str())));
    drop(row.insert("title".to_owned(), Value::from(item.title.as_str())));
    drop(row.insert("paneCount".to_owned(), Value::from(item.pane_count)));
    drop(row.insert("focused".to_owned(), Value::from(item.focused)));
    if let Some(badge) = item.badge {
        drop(row.insert("badge".to_owned(), Value::from(token_for_badge(badge))));
    }
    Value::Object(row)
}

fn pane(item: &Pane) -> Value {
    let mut row = Map::new();
    drop(row.insert("id".to_owned(), Value::from(item.id.as_str())));
    drop(row.insert("tabId".to_owned(), Value::from(item.tab_id.as_str())));
    drop(row.insert("title".to_owned(), Value::from(item.title.as_str())));
    drop(row.insert("kind".to_owned(), Value::from(item.kind.as_str())));
    drop(row.insert("focused".to_owned(), Value::from(item.focused)));
    if let Some(ref cwd) = item.cwd {
        drop(row.insert("cwd".to_owned(), Value::from(cwd.as_str())));
    }
    Value::Object(row)
}

fn font(item: &Font) -> Value {
    let mut row = Map::new();
    drop(row.insert("family".to_owned(), Value::from(item.family.as_str())));
    drop(row.insert("monospace".to_owned(), Value::from(item.monospace)));
    drop(row.insert("system".to_owned(), Value::from(item.system)));
    Value::Object(row)
}

fn keybind(item: &Keybind) -> Value {
    let mut row = Map::new();
    drop(row.insert("action".to_owned(), Value::from(item.action.as_str())));
    drop(row.insert("keys".to_owned(), Value::from(item.keys.as_str())));
    Value::Object(row)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_agent::badge::TabBadge;
    use slopdesk_agent::status::ClaudeStatus;

    use super::{Font, Keybind, Outcome, Pane, Tab, Window, line};
    use crate::decode_response_line;
    use crate::request::Refusal;

    /// THE GOLDEN. Exact bytes, one per reply shape — the same reason the request goldens next door
    /// are literal: this wire's two ends ship on different clocks, and a renamed result key moves
    /// both in one commit and passes both suites green against the app the user launched this
    /// morning.
    #[test]
    fn a_every_reply_serialises_to_the_shape_the_wire_has_always_carried() {
        let cases: [(String, &str); 12] = [
            (line("1", &Outcome::Done), r#"{"id":"1","ok":true}"#),
            (
                line(
                    "1",
                    &Outcome::Windows(vec![Window {
                        id: "w1".to_owned(),
                        title: "Work".to_owned(),
                        tab_count: 2,
                        focused: true,
                    }]),
                ),
                r#"{"id":"1","ok":true,"result":{"windows":[{"focused":true,"id":"w1","tabCount":2,"title":"Work"}]}}"#,
            ),
            (
                line(
                    "1",
                    &Outcome::Tabs(vec![Tab {
                        id: "t1".to_owned(),
                        window_id: "w1".to_owned(),
                        title: "shell".to_owned(),
                        pane_count: 1,
                        focused: false,
                        badge: Some(TabBadge::Running),
                    }]),
                ),
                r#"{"id":"1","ok":true,"result":{"tabs":[{"badge":"running","focused":false,"id":"t1","paneCount":1,"title":"shell","windowId":"w1"}]}}"#,
            ),
            (
                line(
                    "1",
                    &Outcome::Panes(vec![Pane {
                        id: "p1".to_owned(),
                        tab_id: "t1".to_owned(),
                        title: "zsh".to_owned(),
                        kind: "terminal".to_owned(),
                        focused: true,
                        cwd: Some("/tmp".to_owned()),
                    }]),
                ),
                r#"{"id":"1","ok":true,"result":{"panes":[{"cwd":"/tmp","focused":true,"id":"p1","kind":"terminal","tabId":"t1","title":"zsh"}]}}"#,
            ),
            (
                line(
                    "1",
                    &Outcome::Fonts(vec![Font {
                        family: "Menlo".to_owned(),
                        monospace: true,
                        system: true,
                    }]),
                ),
                r#"{"id":"1","ok":true,"result":{"fonts":[{"family":"Menlo","monospace":true,"system":true}]}}"#,
            ),
            (
                line(
                    "1",
                    &Outcome::Keybinds(vec![Keybind {
                        action: "splitRight".to_owned(),
                        keys: "⌘D".to_owned(),
                    }]),
                ),
                r#"{"id":"1","ok":true,"result":{"keybinds":[{"action":"splitRight","keys":"⌘D"}]}}"#,
            ),
            (
                line("1", &Outcome::Captured(vec!["a".to_owned(), "b".to_owned()])),
                r#"{"id":"1","ok":true,"result":{"lines":["a","b"]}}"#,
            ),
            (
                line("1", &Outcome::Badge(TabBadge::Finished)),
                r#"{"id":"1","ok":true,"result":{"kind":"finished"}}"#,
            ),
            (
                line("1", &Outcome::Jumped {
                    path: "/tmp".to_owned(),
                    changed: true,
                }),
                r#"{"id":"1","ok":true,"result":{"changed":true,"path":"/tmp"}}"#,
            ),
            (
                line("1", &Outcome::Path("/tmp".to_owned())),
                r#"{"id":"1","ok":true,"result":{"path":"/tmp"}}"#,
            ),
            (
                line("1", &Outcome::Agent {
                    seen: true,
                    status: Some(ClaudeStatus::NeedsPermission),
                }),
                r#"{"id":"1","ok":true,"result":{"seen":true,"status":"needsPermission"}}"#,
            ),
            (
                line("1", &Outcome::Refused {
                    refusal: Refusal::PaneNotFound,
                    detail: String::new(),
                }),
                // Sorted keys put `error` first. That is what `.sortedKeys` produced when this
                // encoder was Swift, so it is what the shipped CLI has always parsed.
                r#"{"error":"pane not found","id":"1","ok":false}"#,
            ),
        ];
        for (built, expected) in cases {
            assert_eq!(built, expected);
        }
    }

    /// The optional halves are OMITTED rather than sent as null: the CLI reads `result["cwd"]` and
    /// a present null is not the same answer as an absent key.
    #[test]
    fn an_absent_optional_leaves_no_key_behind() {
        assert_eq!(
            line(
                "1",
                &Outcome::Tabs(vec![Tab {
                    id: "t1".to_owned(),
                    window_id: "w1".to_owned(),
                    title: String::new(),
                    pane_count: 0,
                    focused: false,
                    badge: None,
                }]),
            ),
            r#"{"id":"1","ok":true,"result":{"tabs":[{"focused":false,"id":"t1","paneCount":0,"title":"","windowId":"w1"}]}}"#,
            "a tab wearing no badge carries no badge key",
        );
        assert_eq!(
            line("1", &Outcome::Agent {
                seen: false,
                status: None,
            },),
            r#"{"id":"1","ok":true,"result":{"seen":false}}"#,
            "an id that resolved to no pane carries no status",
        );
    }

    /// An EMPTY listing is still a listing — `{"windows":[]}` and not an omitted result, because
    /// the CLI prints "no windows" from the empty array and would print an error from a missing
    /// key.
    #[test]
    fn an_empty_listing_is_an_empty_array_and_not_a_missing_key() {
        for (outcome, key) in [
            (Outcome::Windows(Vec::new()), "windows"),
            (Outcome::Tabs(Vec::new()), "tabs"),
            (Outcome::Panes(Vec::new()), "panes"),
            (Outcome::Fonts(Vec::new()), "fonts"),
            (Outcome::Keybinds(Vec::new()), "keybinds"),
            (Outcome::Captured(Vec::new()), "lines"),
        ] {
            let decoded = decode_response_line(&line("1", &outcome)).expect("a reply is an object");
            let result = decoded
                .get("result")
                .and_then(serde_json::Value::as_object)
                .expect("a listing always carries its result");
            assert_eq!(
                result
                    .get(key)
                    .and_then(serde_json::Value::as_array)
                    .map(Vec::len),
                Some(0),
                "{key}",
            );
        }
    }

    /// Every reply the CLI could receive decodes with the CLI's own reader — the round trip that
    /// stops this encoder and that decoder drifting into two opinions about one line.
    #[test]
    fn every_reply_decodes_with_the_readers_the_cli_uses() {
        for outcome in [
            Outcome::Done,
            Outcome::Badge(TabBadge::Error),
            Outcome::Path("/tmp".to_owned()),
            Outcome::Refused {
                refusal: Refusal::UnknownKey,
                detail: "f5".to_owned(),
            },
        ] {
            let decoded = decode_response_line(&line("7", &outcome)).expect("a reply is an object");
            assert_eq!(
                decoded.get("id").and_then(serde_json::Value::as_str),
                Some("7"),
                "the id is echoed",
            );
            assert!(decoded.contains_key("ok"));
        }
    }
}

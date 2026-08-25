//! The CLIENT control socket: its method vocabulary, its tokens, its NDJSON codec and one
//! parameter builder per verb.
//!
//! The runtime-control surface `slopdesk` drives the running client GUI over — windows/tabs/panes,
//! badges, jump/view/edit, font/keybind dumps, pane capture/send-keys, agent status. Same NDJSON
//! line protocol as the host ctl next door: a request is `{"id":…,"method":…,"params":{…}}` and a
//! response is `{"id":…,"ok":true,"result":{…}}` / `{"id":…,"ok":false,"error":"…"}`.
//!
//! There is no config verb here. Settings are the config FILE's, read by every process that wants
//! them; a socket that wrote one would be a second authoring surface for a value the user is
//! supposed to see in their own file.
//!
//! ## Why the bytes are pinned by a LITERAL and not only by a round-trip
//! This is the one wire in the tree whose two ends ship on different clocks. The app is
//! long-running and installed from a `.app`; the CLI arrives by `brew upgrade` and is typed
//! seconds later. A renamed method or a renamed param key moves both ends in one commit and passes
//! both suites green — against a peer that is still the version the user launched this morning.
//! `every_request_serialises_to_the_shape_the_wire_has_always_carried` is what sees that, the same
//! way `slopdesk-superwire`'s two goldens do for superd's batches.
//!
//! The far end is `ClientControlDispatcher`, which is Swift because it dispatches against the
//! `@Observable` workspace store. It reads its method names and its three token vocabularies out
//! of THIS module — `slopdesk-invariants`' "the client control socket has one vocabulary" holds
//! the two spellings together, since no compiler crosses that boundary.

use serde_json::{Map, Value};

/// A JSON object, in the one spelling this crate uses.
pub type Params = Map<String, Value>;

// ---------------------------------------------------------------------------------------------
// Method names
// ---------------------------------------------------------------------------------------------

/// List all windows.
pub const WINDOWS: &str = "windows";
/// List tabs (optionally scoped to a window).
pub const TABS: &str = "tabs";
/// List panes (optionally scoped to a tab).
pub const PANES: &str = "panes";
/// Set a tab status badge.
pub const TAB_BADGE: &str = "tab-badge";
/// Resolve a frecency-ranked jump target and `cd` the focused pane (or just print it).
pub const JUMP: &str = "jump";
/// Record a directory visit in the frecency database.
pub const LEARN: &str = "learn";
/// Remove a directory from the frecency database.
pub const IGNORE: &str = "ignore";
/// Open a read-only `view` shim (`less <path>` / `open <url>`) in a new split/tab/window.
pub const VIEW: &str = "view";
/// Open an editable `edit` shim (`$EDITOR <path>`) in a new split/tab/window.
pub const EDIT: &str = "edit";
/// Enumerate fonts.
pub const FONT_LIST: &str = "font-list";
/// Enumerate keybindings (optionally filtered by action substring).
pub const KEYBIND_LIST: &str = "keybind-list";
/// Capture the last N lines of a pane's scrollback.
pub const PANE_CAPTURE: &str = "pane-capture";
/// Send literal text + named keys to a pane (VERBATIM; named keys via the keycode path).
pub const PANE_SEND_KEYS: &str = "pane-send-keys";
/// Poll an agent session's rolled-up status (for `watch:claude`).
pub const AGENT_STATUS: &str = "agent-status";

/// Every recognised method — the dispatcher rejects anything outside this set.
pub const METHODS: &[&str] = &[
    WINDOWS,
    TABS,
    PANES,
    TAB_BADGE,
    JUMP,
    LEARN,
    IGNORE,
    VIEW,
    EDIT,
    FONT_LIST,
    KEYBIND_LIST,
    PANE_CAPTURE,
    PANE_SEND_KEYS,
    AGENT_STATUS,
];

// ---------------------------------------------------------------------------------------------
// Token vocabularies
// ---------------------------------------------------------------------------------------------

/// The badge tokens `tab badge --kind <token>` accepts.
///
/// `unread` has no distinct badge kind of its own — the far side maps it to `finished`, which is
/// literally the "unread output" marker. The privilege badges (`caffeinate`/`sudo`) and the two
/// command badges are foreground-process derived, so they are absent here: they can be LISTED but
/// never set.
pub const SETTABLE_BADGE_TOKENS: &[&str] = &[
    "running",
    "completed",
    "finished",
    "unread",
    "error",
    "awaiting-input",
];

/// Where a `view`/`edit` shim opens. The first entry is the default.
pub const PLACEMENTS: &[&str] = &["new-tab", "new-window", "left", "right", "top", "bottom"];

/// The default placement — `--new-tab`, and what an invocation naming no side gets.
pub const DEFAULT_PLACEMENT: &str = "new-tab";

/// `font list --system` / `--user`.
pub const FONT_SCOPES: &[&str] = &["system", "user"];

/// The `--kind` values, joined the way the usage error lists them.
#[must_use]
pub fn settable_badge_tokens() -> String {
    SETTABLE_BADGE_TOKENS.join("|")
}

// ---------------------------------------------------------------------------------------------
// Line protocol
// ---------------------------------------------------------------------------------------------

/// Encodes one request into an NDJSON line, WITHOUT the trailing LF — the caller appends it.
///
/// Keys come out sorted, because `serde_json`'s object is a `BTreeMap`; that is the same ordering
/// Foundation's `.sortedKeys` produced on the Swift side of this wire, which is what makes the
/// golden below a statement about the bytes rather than about one encoder's habits.
#[must_use]
pub fn encode_request_line(id: &str, method: &str, params: Params) -> String {
    let mut root = Map::new();
    drop(root.insert("id".to_owned(), Value::from(id)));
    drop(root.insert("method".to_owned(), Value::from(method)));
    drop(root.insert("params".to_owned(), Value::Object(params)));
    Value::Object(root).to_string()
}

/// Parses one NDJSON response line into an object, or `None` when it is not a JSON object.
///
/// Validate-then-drop: a malformed line and a bare JSON scalar both read as `None`, so a caller
/// cannot mistake a fragment of a broken response for a real answer.
#[must_use]
pub fn decode_response_line(line: &str) -> Option<Params> {
    match serde_json::from_str::<Value>(line) {
        Ok(Value::Object(map)) => Some(map),
        _ => None,
    }
}

// ---------------------------------------------------------------------------------------------
// Verb parameter builders
// ---------------------------------------------------------------------------------------------

/// `windows` — no params.
#[must_use]
pub fn windows_params() -> Params {
    Params::new()
}

/// `tabs` — optional `windowId` filter (omit to list every window's tabs).
#[must_use]
pub fn tabs_params(window_id: Option<&str>) -> Params {
    let mut params = Params::new();
    if let Some(id) = window_id {
        drop(params.insert("windowId".to_owned(), Value::from(id)));
    }
    params
}

/// `panes` — optional `tabId` filter (omit to list every tab's panes).
#[must_use]
pub fn panes_params(tab_id: Option<&str>) -> Params {
    let mut params = Params::new();
    if let Some(id) = tab_id {
        drop(params.insert("tabId".to_owned(), Value::from(id)));
    }
    params
}

/// `tab-badge` — set `kind` on a tab (default: the focused tab).
#[must_use]
pub fn tab_badge_params(kind: &str, tab_id: Option<&str>) -> Params {
    let mut params = Params::new();
    drop(params.insert("kind".to_owned(), Value::from(kind)));
    if let Some(id) = tab_id {
        drop(params.insert("tabId".to_owned(), Value::from(id)));
    }
    params
}

/// `jump` — optional `query`; `noCd` prints the resolved path without sending `cd`.
#[must_use]
pub fn jump_params(query: Option<&str>, no_cd: bool) -> Params {
    let mut params = Params::new();
    drop(params.insert("noCd".to_owned(), Value::from(no_cd)));
    if let Some(text) = query {
        drop(params.insert("query".to_owned(), Value::from(text)));
    }
    params
}

/// `learn` — optional `path` (omit to record the focused pane's cached OSC-7 cwd).
#[must_use]
pub fn learn_params(path: Option<&str>) -> Params {
    let mut params = Params::new();
    if let Some(text) = path {
        drop(params.insert("path".to_owned(), Value::from(text)));
    }
    params
}

/// `ignore` — the `path` to remove from the frecency database.
#[must_use]
pub fn ignore_params(path: &str) -> Params {
    let mut params = Params::new();
    drop(params.insert("path".to_owned(), Value::from(path)));
    params
}

/// `view` — `target` (path or URL) + a placement token.
#[must_use]
pub fn view_params(target: &str, placement: &str) -> Params {
    shim_params(target, placement)
}

/// `edit` — `target` (path or URL) + a placement token.
#[must_use]
pub fn edit_params(target: &str, placement: &str) -> Params {
    shim_params(target, placement)
}

/// The shape both shims share. One body, because `view` and `edit` differ only in the METHOD they
/// travel under — the far side reads the same two keys out of each.
fn shim_params(target: &str, placement: &str) -> Params {
    let mut params = Params::new();
    drop(params.insert("target".to_owned(), Value::from(target)));
    drop(params.insert("placement".to_owned(), Value::from(placement)));
    params
}

/// `font-list` — optional `monospace` filter, `family` substring, and `scope` token.
#[must_use]
pub fn font_list_params(monospace: bool, family: Option<&str>, scope: Option<&str>) -> Params {
    let mut params = Params::new();
    drop(params.insert("monospace".to_owned(), Value::from(monospace)));
    if let Some(text) = family {
        drop(params.insert("family".to_owned(), Value::from(text)));
    }
    if let Some(text) = scope {
        drop(params.insert("scope".to_owned(), Value::from(text)));
    }
    params
}

/// `keybind-list` — optional `action` substring filter.
#[must_use]
pub fn keybind_list_params(action: Option<&str>) -> Params {
    let mut params = Params::new();
    if let Some(text) = action {
        drop(params.insert("action".to_owned(), Value::from(text)));
    }
    params
}

/// `pane-capture` — optional `paneId` (default: the focused pane) + `lines` count.
#[must_use]
pub fn pane_capture_params(pane_id: Option<&str>, lines: i64) -> Params {
    let mut params = Params::new();
    drop(params.insert("lines".to_owned(), Value::from(lines)));
    if let Some(id) = pane_id {
        drop(params.insert("paneId".to_owned(), Value::from(id)));
    }
    params
}

/// `pane-send-keys` — optional `paneId` (default: the focused pane), literal `text`, and an
/// ordered list of named `keys`.
#[must_use]
pub fn pane_send_keys_params(pane_id: Option<&str>, text: &str, keys: &[String]) -> Params {
    let mut params = Params::new();
    drop(params.insert("text".to_owned(), Value::from(text)));
    drop(params.insert(
        "keys".to_owned(),
        Value::Array(keys.iter().map(|key| Value::from(key.as_str())).collect()),
    ));
    if let Some(id) = pane_id {
        drop(params.insert("paneId".to_owned(), Value::from(id)));
    }
    params
}

/// `agent-status` — poll the agent session identified by `id`.
#[must_use]
pub fn agent_status_params(id: &str) -> Params {
    let mut params = Params::new();
    drop(params.insert("id".to_owned(), Value::from(id)));
    params
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        AGENT_STATUS, DEFAULT_PLACEMENT, EDIT, FONT_LIST, FONT_SCOPES, IGNORE, JUMP, KEYBIND_LIST, LEARN,
        METHODS, PANE_CAPTURE, PANE_SEND_KEYS, PANES, PLACEMENTS, SETTABLE_BADGE_TOKENS, TAB_BADGE, TABS,
        VIEW, WINDOWS, agent_status_params, decode_response_line, edit_params, encode_request_line,
        font_list_params, ignore_params, jump_params, keybind_list_params, learn_params, pane_capture_params,
        pane_send_keys_params, panes_params, settable_badge_tokens, tab_badge_params, tabs_params,
        view_params, windows_params,
    };

    fn keys(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| (*item).to_owned()).collect()
    }

    /// THE GOLDEN. Exact bytes, one per method, with every optional field present — because the
    /// skew this catches is against an app the user launched before the CLI was upgraded, and no
    /// round-trip inside one build can see it.
    ///
    /// A line here that has to change is a WIRE CHANGE: the dispatcher must accept both spellings
    /// for a release before the old one goes.
    #[test]
    fn every_request_serialises_to_the_shape_the_wire_has_always_carried() {
        let cases: [(String, &str); 14] = [
            (
                encode_request_line("1", WINDOWS, windows_params()),
                r#"{"id":"1","method":"windows","params":{}}"#,
            ),
            (
                encode_request_line("1", TABS, tabs_params(Some("w1"))),
                r#"{"id":"1","method":"tabs","params":{"windowId":"w1"}}"#,
            ),
            (
                encode_request_line("1", PANES, panes_params(Some("t1"))),
                r#"{"id":"1","method":"panes","params":{"tabId":"t1"}}"#,
            ),
            (
                encode_request_line("1", TAB_BADGE, tab_badge_params("running", Some("t1"))),
                r#"{"id":"1","method":"tab-badge","params":{"kind":"running","tabId":"t1"}}"#,
            ),
            (
                encode_request_line("1", JUMP, jump_params(Some("proj"), true)),
                r#"{"id":"1","method":"jump","params":{"noCd":true,"query":"proj"}}"#,
            ),
            (
                encode_request_line("1", LEARN, learn_params(Some("/tmp"))),
                r#"{"id":"1","method":"learn","params":{"path":"/tmp"}}"#,
            ),
            (
                encode_request_line("1", IGNORE, ignore_params("/tmp")),
                r#"{"id":"1","method":"ignore","params":{"path":"/tmp"}}"#,
            ),
            (
                encode_request_line("1", VIEW, view_params("/tmp/a.txt", "right")),
                r#"{"id":"1","method":"view","params":{"placement":"right","target":"/tmp/a.txt"}}"#,
            ),
            (
                encode_request_line("1", EDIT, edit_params("/tmp/a.txt", DEFAULT_PLACEMENT)),
                r#"{"id":"1","method":"edit","params":{"placement":"new-tab","target":"/tmp/a.txt"}}"#,
            ),
            (
                encode_request_line("1", FONT_LIST, font_list_params(true, Some("Mono"), Some("user"))),
                r#"{"id":"1","method":"font-list","params":{"family":"Mono","monospace":true,"scope":"user"}}"#,
            ),
            (
                encode_request_line("1", KEYBIND_LIST, keybind_list_params(Some("split"))),
                r#"{"id":"1","method":"keybind-list","params":{"action":"split"}}"#,
            ),
            (
                encode_request_line("1", PANE_CAPTURE, pane_capture_params(Some("p1"), 100)),
                r#"{"id":"1","method":"pane-capture","params":{"lines":100,"paneId":"p1"}}"#,
            ),
            (
                encode_request_line(
                    "1",
                    PANE_SEND_KEYS,
                    pane_send_keys_params(Some("p1"), "ls -la", &keys(&["Enter"])),
                ),
                r#"{"id":"1","method":"pane-send-keys","params":{"keys":["Enter"],"paneId":"p1","text":"ls -la"}}"#,
            ),
            (
                encode_request_line("1", AGENT_STATUS, agent_status_params("s1")),
                r#"{"id":"1","method":"agent-status","params":{"id":"s1"}}"#,
            ),
        ];
        assert_eq!(cases.len(), METHODS.len(), "one golden line per method");
        for (built, expected) in cases {
            assert_eq!(built, expected);
        }
    }

    /// The optional halves, omitted rather than sent as null — the far side reads `params["x"]` and
    /// a present null is not the same question as an absent key.
    #[test]
    fn an_omitted_filter_leaves_no_key_behind() {
        assert_eq!(
            encode_request_line("1", TABS, tabs_params(None)),
            r#"{"id":"1","method":"tabs","params":{}}"#
        );
        assert_eq!(
            encode_request_line("1", PANES, panes_params(None)),
            r#"{"id":"1","method":"panes","params":{}}"#
        );
        assert_eq!(
            encode_request_line("1", LEARN, learn_params(None)),
            r#"{"id":"1","method":"learn","params":{}}"#
        );
        assert_eq!(
            encode_request_line("1", KEYBIND_LIST, keybind_list_params(None)),
            r#"{"id":"1","method":"keybind-list","params":{}}"#
        );
        // The three that always carry their switch, even at its default: the far side branches on
        // the VALUE, so an absent `noCd`/`monospace` would read as "no opinion" rather than "no".
        assert_eq!(
            encode_request_line("1", JUMP, jump_params(None, false)),
            r#"{"id":"1","method":"jump","params":{"noCd":false}}"#
        );
        assert_eq!(
            encode_request_line("1", FONT_LIST, font_list_params(false, None, None)),
            r#"{"id":"1","method":"font-list","params":{"monospace":false}}"#
        );
        assert_eq!(
            encode_request_line("1", PANE_SEND_KEYS, pane_send_keys_params(None, "", &[])),
            r#"{"id":"1","method":"pane-send-keys","params":{"keys":[],"text":""}}"#
        );
    }

    #[test]
    fn a_response_object_decodes_and_anything_else_drops() {
        let obj = decode_response_line(r#"{"id":"1","ok":true,"result":{"path":"/tmp"}}"#)
            .expect("a JSON object decodes");
        assert_eq!(obj.get("ok").and_then(serde_json::Value::as_bool), Some(true));

        assert!(decode_response_line("not json").is_none());
        // A bare scalar is valid JSON and is still not a response.
        assert!(decode_response_line("7").is_none());
        assert!(decode_response_line("[]").is_none());
        assert!(decode_response_line("").is_none());
    }

    #[test]
    fn the_token_vocabularies_are_closed_and_their_defaults_are_members() {
        assert!(PLACEMENTS.contains(&DEFAULT_PLACEMENT));
        assert_eq!(PLACEMENTS.len(), 6);
        assert_eq!(FONT_SCOPES, &["system", "user"]);
        assert_eq!(
            settable_badge_tokens(),
            "running|completed|finished|unread|error|awaiting-input"
        );
        assert_eq!(SETTABLE_BADGE_TOKENS.len(), 6);
        // No method may be spelled twice: the dispatcher's set would silently absorb the duplicate
        // and the count comparison in the golden would still pass.
        let unique: std::collections::BTreeSet<&&str> = METHODS.iter().collect();
        assert_eq!(unique.len(), METHODS.len());
    }
}

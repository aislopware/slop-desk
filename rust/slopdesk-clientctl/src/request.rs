//! The client control socket's SERVER half: what a request line decodes to, and what it refuses in.
//!
//! `slopdesk pane capture`, `slopdesk view`, `slopdesk tab badge` and eleven more arrive here as
//! one NDJSON line per request, written by a process the app did not launch and cannot vouch for.
//! The contract is the repo's untrusted-input one: every field is validated BEFORE it is used,
//! every count is bounded BEFORE anything allocates against it, and a hostile or truncated line
//! becomes an `ok:false` answer rather than a trap.
//!
//! ## Why the server half lives beside the request builders
//! Both ends of this socket are here now. The CLI builds a line with [`crate::encode_request_line`]
//! and one `*_params` builder; [`decode`] takes that line apart again. The two used to be a Rust
//! encoder and a Swift decoder that agreed by inspection — a `[String: Any]` walked one key at a
//! time in a language whose compiler could not see the builder. Co-located, the agreement is a
//! ROUND TRIP a test can run: build a request, decode it, and read back what was put in. The wire
//! is still pinned by the golden literals next door, because the skew that matters is against an
//! app the user launched before the CLI was upgraded and no round-trip inside one build can see it.
//!
//! ## A refusal is a CODE plus a detail, never a sentence built twice
//! Nineteen of the twenty refusals are a fixed string; five of them name a token the request
//! supplied. So a caller names the refusal and hands over the token it read, and the sentence is
//! assembled once — which is what keeps `invalid placement 'x'` from becoming
//! `invalid placement "x"` on one of the two ends that print it.

use serde_json::Value;
use slopdesk_agent::badge::TabBadge;

use crate::{FONT_SCOPES, PLACEMENTS, badge_for_token, index_of};

// ---------------------------------------------------------------------------------------------- //
// The bounds
// ---------------------------------------------------------------------------------------------- //

/// Max bytes in one request line, measured on the TRIMMED request — the same cap the host's own
/// control socket keeps.
///
/// The line is refused at this size before it is parsed, so a megabyte of hostile JSON costs a
/// length comparison rather than a parse.
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;

/// How many scrollback lines `pane-capture` reads when the request names no count.
pub const DEFAULT_CAPTURE_LINES: i64 = 100;

/// The ceiling on `pane-capture`'s count, so a hostile number cannot force an unbounded read.
///
/// Clamped rather than refused, unlike a non-positive count: asking for more scrollback than exists
/// is what `--lines 999999` MEANS, while asking for none of it is a request that cannot be served.
pub const MAX_CAPTURE_LINES: i64 = 100_000;

/// The `id` a refusal answers under when the line carried none to echo.
pub const UNKNOWN_ID: &str = "?";

// ---------------------------------------------------------------------------------------------- //
// The refusal vocabulary
// ---------------------------------------------------------------------------------------------- //

/// Every way the control socket says no.
///
/// One enum rather than twenty literals at their call sites, because these strings are a USER
/// INTERFACE: they are what `slopdesk` prints when a verb does not land, and the ones that name a
/// token are the ones a person reads to find their typo.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// The line is past [`MAX_REQUEST_BYTES`].
    TooLarge,
    /// The line is not a JSON object with a string `id` and `method`.
    Malformed,
    /// A method this build does not dispatch. Names the method.
    UnknownMethod,
    /// `tab-badge` with no `kind`.
    MissingBadgeKind,
    /// `tab-badge` with a `kind` no badge answers to. Names the token.
    InvalidBadgeKind,
    /// `tab-badge` naming a tab that is not there.
    TabNotFound,
    /// `jump` resolved to nothing.
    NoJumpTarget,
    /// `learn` with no path and no focused pane to take one from.
    NothingToLearn,
    /// `ignore` with no `path`, or an empty one.
    MissingPath,
    /// `ignore` on a path the frecency store would not drop.
    CouldNotIgnore,
    /// `view` / `edit` with no `target`, or an empty one.
    MissingTarget,
    /// `view` / `edit` with a `placement` no surface answers to. Names the token.
    InvalidPlacement,
    /// `view` / `edit` on a target that would not open.
    CouldNotOpen,
    /// `font-list` with a `scope` no font surface answers to. Names the token.
    InvalidScope,
    /// `pane-capture` with a `lines` that is not a positive integer.
    CaptureLines,
    /// A pane verb naming a pane that is not there.
    PaneNotFound,
    /// `pane-send-keys` with a `keys` that is not an array.
    KeysNotAnArray,
    /// `pane-send-keys` with neither text nor a named key to send.
    NothingToSend,
    /// `pane-send-keys` naming a key the table does not carry. Names the key.
    UnknownKey,
    /// `agent-status` with no `id`, or an empty one.
    MissingId,
}

impl Refusal {
    /// Every refusal, in discriminant order.
    pub const ALL: [Self; 20] = [
        Self::TooLarge,
        Self::Malformed,
        Self::UnknownMethod,
        Self::MissingBadgeKind,
        Self::InvalidBadgeKind,
        Self::TabNotFound,
        Self::NoJumpTarget,
        Self::NothingToLearn,
        Self::MissingPath,
        Self::CouldNotIgnore,
        Self::MissingTarget,
        Self::InvalidPlacement,
        Self::CouldNotOpen,
        Self::InvalidScope,
        Self::CaptureLines,
        Self::PaneNotFound,
        Self::KeysNotAnArray,
        Self::NothingToSend,
        Self::UnknownKey,
        Self::MissingId,
    ];

    /// Its discriminant, as it crosses. Numbered from `1`, so `0` is free to mean NO refusal —
    /// which is what the doors that answer "is this request acceptable" say when it is.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::TooLarge => 1,
            Self::Malformed => 2,
            Self::UnknownMethod => 3,
            Self::MissingBadgeKind => 4,
            Self::InvalidBadgeKind => 5,
            Self::TabNotFound => 6,
            Self::NoJumpTarget => 7,
            Self::NothingToLearn => 8,
            Self::MissingPath => 9,
            Self::CouldNotIgnore => 10,
            Self::MissingTarget => 11,
            Self::InvalidPlacement => 12,
            Self::CouldNotOpen => 13,
            Self::InvalidScope => 14,
            Self::CaptureLines => 15,
            Self::PaneNotFound => 16,
            Self::KeysNotAnArray => 17,
            Self::NothingToSend => 18,
            Self::UnknownKey => 19,
            Self::MissingId => 20,
        }
    }

    /// The refusal a discriminant names, or `None` — including for `0`, which is the absence of a
    /// refusal rather than one this build cannot name.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            1 => Some(Self::TooLarge),
            2 => Some(Self::Malformed),
            3 => Some(Self::UnknownMethod),
            4 => Some(Self::MissingBadgeKind),
            5 => Some(Self::InvalidBadgeKind),
            6 => Some(Self::TabNotFound),
            7 => Some(Self::NoJumpTarget),
            8 => Some(Self::NothingToLearn),
            9 => Some(Self::MissingPath),
            10 => Some(Self::CouldNotIgnore),
            11 => Some(Self::MissingTarget),
            12 => Some(Self::InvalidPlacement),
            13 => Some(Self::CouldNotOpen),
            14 => Some(Self::InvalidScope),
            15 => Some(Self::CaptureLines),
            16 => Some(Self::PaneNotFound),
            17 => Some(Self::KeysNotAnArray),
            18 => Some(Self::NothingToSend),
            19 => Some(Self::UnknownKey),
            20 => Some(Self::MissingId),
            _ => None,
        }
    }

    /// Whether this refusal NAMES a token the request supplied.
    ///
    /// The five that do are the five worth reading twice: they are what tells a person that
    /// `--placement split-lefft` was a typo rather than a verb the app never grew.
    #[must_use]
    pub const fn names_detail(self) -> bool {
        matches!(
            self,
            Self::UnknownMethod
                | Self::InvalidBadgeKind
                | Self::InvalidPlacement
                | Self::InvalidScope
                | Self::UnknownKey
        )
    }

    /// The sentence this refusal answers with, with `detail` filled in where one is named.
    ///
    /// A `detail` handed to a refusal that names none is IGNORED rather than appended: the caller
    /// that always passes what it read stays a one-liner, and no message grows a stray token.
    #[must_use]
    pub fn message(self, detail: &str) -> String {
        match self {
            Self::UnknownMethod => format!("unknown method: {detail}"),
            Self::InvalidBadgeKind => format!("invalid badge kind '{detail}'"),
            Self::InvalidPlacement => format!("invalid placement '{detail}'"),
            Self::InvalidScope => format!("invalid scope '{detail}'"),
            Self::UnknownKey => format!("unknown key: {detail}"),
            Self::TooLarge => "request too large".to_owned(),
            Self::Malformed => "malformed request".to_owned(),
            Self::MissingBadgeKind => "missing params.kind".to_owned(),
            Self::TabNotFound => "tab not found".to_owned(),
            Self::NoJumpTarget => "no jump target".to_owned(),
            Self::NothingToLearn => {
                "no directory to learn (give a path or focus a pane with a cwd)".to_owned()
            },
            Self::MissingPath => "missing params.path".to_owned(),
            Self::CouldNotIgnore => "could not ignore path".to_owned(),
            Self::MissingTarget => "missing params.target".to_owned(),
            Self::CouldNotOpen => "could not open target".to_owned(),
            Self::CaptureLines => "lines must be a positive integer".to_owned(),
            Self::PaneNotFound => "pane not found".to_owned(),
            Self::KeysNotAnArray => "keys must be an array of strings".to_owned(),
            Self::NothingToSend => "nothing to send (need text or keys)".to_owned(),
            Self::MissingId => "missing params.id".to_owned(),
        }
    }
}

// ---------------------------------------------------------------------------------------------- //
// The bounded payloads
// ---------------------------------------------------------------------------------------------- //

/// How many scrollback lines a `pane-capture` request asks for, or `None` for
/// [`Refusal::CaptureLines`].
///
/// `present` is whether the request carried a `lines` field at all and `is_integer` whether it was
/// one — a field carrying `"12"` or `1.5` is a refusal rather than a coercion, because a control
/// socket that guesses at types is one that reads `true` as 1. The three cases:
///
/// * absent ⇒ [`DEFAULT_CAPTURE_LINES`];
/// * present, an integer, positive ⇒ itself, clamped to [`MAX_CAPTURE_LINES`];
/// * anything else ⇒ refused.
#[must_use]
const fn capture_lines(present: bool, is_integer: bool, raw: i64) -> Option<i64> {
    if !present {
        return Some(DEFAULT_CAPTURE_LINES);
    }
    if !is_integer || raw <= 0 {
        return None;
    }
    if raw < MAX_CAPTURE_LINES {
        Some(raw)
    } else {
        Some(MAX_CAPTURE_LINES)
    }
}

// ---------------------------------------------------------------------------------------------- //
// What a request line decodes to
// ---------------------------------------------------------------------------------------------- //

/// One validated request, with every param already read, bounded and turned into the type it means.
///
/// The verbs that take no param carry none; the ones that do carry them PARSED — a placement is an
/// index into [`PLACEMENTS`], a badge kind is a [`TabBadge`], a capture count is already clamped.
/// So the executor is handed a request that cannot be malformed, which is the whole point of
/// splitting the decode out of it: there is no way to reach the running GUI with an unchecked
/// field.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    /// `windows` — list every window.
    Windows,
    /// `tabs` — list tabs, optionally scoped to one window.
    Tabs {
        /// The window to scope to, or `None` for every window.
        window_id: Option<String>,
    },
    /// `panes` — list panes, optionally scoped to one tab.
    Panes {
        /// The tab to scope to, or `None` for every tab.
        tab_id: Option<String>,
    },
    /// `tab-badge` — set a badge on a tab.
    TabBadge {
        /// The tab to mark, or `None` for the focused one.
        tab_id: Option<String>,
        /// The badge the request's token named. Already validated as SETTABLE.
        kind: TabBadge,
    },
    /// `jump` — resolve a frecency target and, unless `noCd`, `cd` the focused pane.
    Jump {
        /// What to rank against, or `None` for the `$HOME`↔last-jump toggle.
        query: Option<String>,
        /// Whether to send the `cd`. The request spells the negative (`noCd`); this is the verb.
        change_directory: bool,
    },
    /// `learn` — record a directory visit in the frecency database.
    Learn {
        /// The directory, or `None` for the focused pane's cached cwd.
        path: Option<String>,
    },
    /// `ignore` — drop a directory from the frecency database.
    Ignore {
        /// The directory. Already validated as present and non-empty.
        path: String,
    },
    /// `view` / `edit` — open a shim at a placement.
    Open {
        /// The path or URL. Already validated as present and non-empty.
        target: String,
        /// `true` for `edit` (`$EDITOR`), `false` for `view` (`less` / `open`).
        editable: bool,
        /// The placement's INDEX in [`PLACEMENTS`], defaulted to `0` when the request named none.
        placement: usize,
    },
    /// `font-list` — enumerate fonts.
    FontList {
        /// Whether to keep only monospaced families.
        monospace_only: bool,
        /// A family substring filter, or `None`.
        family: Option<String>,
        /// The scope's INDEX in [`FONT_SCOPES`], or `None` for both.
        scope: Option<usize>,
    },
    /// `keybind-list` — enumerate keybindings.
    KeybindList {
        /// An action-name substring filter, or `None`.
        action: Option<String>,
    },
    /// `pane-capture` — read the tail of a pane's scrollback.
    PaneCapture {
        /// The pane, or `None` for the focused one.
        pane_id: Option<String>,
        /// How many lines. Already positive and clamped to [`MAX_CAPTURE_LINES`].
        lines: i64,
    },
    /// `pane-send-keys` — send literal text and named keys to a pane.
    PaneSendKeys {
        /// The pane, or `None` for the focused one.
        pane_id: Option<String>,
        /// The literal text, sent VERBATIM. May be empty when `keys` is not.
        text: String,
        /// The named keys, in order. Non-string elements were dropped on the way in.
        keys: Vec<String>,
    },
    /// `agent-status` — poll one agent session's rolled-up status.
    AgentStatus {
        /// The session or pane id. Already validated as present and non-empty.
        id: String,
    },
}

impl Op {
    /// The verb's INDEX in [`crate::METHODS`], which is how it crosses to a face that dispatches on
    /// it. The order is the vocabulary's, so a face reading a byte and a CLI writing a name are
    /// naming one table rather than two.
    #[must_use]
    pub const fn verb(&self) -> u8 {
        match *self {
            Self::Windows => 0,
            Self::Tabs { .. } => 1,
            Self::Panes { .. } => 2,
            Self::TabBadge { .. } => 3,
            Self::Jump { .. } => 4,
            Self::Learn { .. } => 5,
            Self::Ignore { .. } => 6,
            // `view` and `edit` are two methods and one op: they differ in `editable` alone, which
            // is what the far side actually branches on.
            Self::Open { editable, .. } => {
                if editable {
                    8
                } else {
                    7
                }
            },
            Self::FontList { .. } => 9,
            Self::KeybindList { .. } => 10,
            Self::PaneCapture { .. } => 11,
            Self::PaneSendKeys { .. } => 12,
            Self::AgentStatus { .. } => 13,
        }
    }
}

/// What one raw request line turned out to be.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decoded {
    /// Blank or whitespace-only. There is nothing to respond TO — which is not the same as an error
    /// response, and is why the socket answers no line at all.
    Blank,
    /// The line cannot be served, and this is the reply to write.
    ///
    /// A whole reply rather than a code, because every refusal reachable from a decode is one the
    /// decoder can word completely: it knows the id to echo (or that there was none) and the token
    /// the caller mistyped. A caller that had to reassemble it would be the second sentence-builder
    /// this vocabulary exists to prevent.
    Refused(String),
    /// The line is a request. Run it and answer under `id`.
    Run {
        /// The request's `id`, echoed verbatim in the reply.
        id: String,
        /// The verb and its validated params.
        op: Op,
    },
}

/// Takes one raw request line apart: trim, bound, parse, validate.
///
/// Every rejection between here and [`Decoded::Run`] answers a complete reply line, so a server
/// loop is `match decode(line) { Blank => …, Refused(r) => write(r), Run{..} => execute }` and has
/// no third branch where it could invent a sentence of its own.
#[must_use]
pub fn decode(line: &str) -> Decoded {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Decoded::Blank;
    }
    if trimmed.len() > MAX_REQUEST_BYTES {
        return refuse(UNKNOWN_ID, Refusal::TooLarge, "");
    }
    let Ok(Value::Object(root)) = serde_json::from_str::<Value>(trimmed) else {
        return refuse(UNKNOWN_ID, Refusal::Malformed, "");
    };
    let (Some(id), Some(method)) = (text(root.get("id")), text(root.get("method"))) else {
        return refuse(UNKNOWN_ID, Refusal::Malformed, "");
    };
    let empty = serde_json::Map::new();
    let params = match root.get("params") {
        Some(Value::Object(map)) => map,
        // A `params` that is present and not an object is the same request as one that omitted it:
        // every field read below is optional-or-refused on its own terms, so the verb's own
        // vocabulary answers rather than a blanket malformed.
        _ => &empty,
    };
    match parse(&method, params) {
        Ok(op) => Decoded::Run { id, op },
        Err((refusal, detail)) => refuse(&id, refusal, &detail),
    }
}

/// One refusal, already a line.
fn refuse(id: &str, refusal: Refusal, detail: &str) -> Decoded {
    Decoded::Refused(crate::reply::refusal_line(id, refusal, detail))
}

/// The verb table. `Err` carries the refusal and the token it names, empty for the fifteen that
/// name none.
fn parse(method: &str, params: &crate::Params) -> Result<Op, (Refusal, String)> {
    match method {
        crate::WINDOWS => Ok(Op::Windows),
        crate::TABS => {
            Ok(Op::Tabs {
                window_id: text(params.get("windowId")),
            })
        },
        crate::PANES => {
            Ok(Op::Panes {
                tab_id: text(params.get("tabId")),
            })
        },
        crate::TAB_BADGE => parse_tab_badge(params),
        crate::JUMP => {
            Ok(Op::Jump {
                query: text(params.get("query")),
                // The request spells the NEGATIVE, because that is the flag a person types. A `noCd`
                // that is present and not a bool reads as absent, which is `false`, which is the
                // default `slopdesk jump` has always had.
                change_directory: !flag(params.get("noCd")),
            })
        },
        crate::LEARN => {
            Ok(Op::Learn {
                path: text(params.get("path")),
            })
        },
        crate::IGNORE => {
            nonempty(params.get("path"))
                .map(|path| Op::Ignore { path })
                .ok_or((Refusal::MissingPath, String::new()))
        },
        crate::VIEW => parse_open(params, false),
        crate::EDIT => parse_open(params, true),
        crate::FONT_LIST => parse_font_list(params),
        crate::KEYBIND_LIST => {
            Ok(Op::KeybindList {
                action: text(params.get("action")),
            })
        },
        crate::PANE_CAPTURE => parse_pane_capture(params),
        crate::PANE_SEND_KEYS => parse_send_keys(params),
        crate::AGENT_STATUS => {
            nonempty(params.get("id"))
                .map(|id| Op::AgentStatus { id })
                .ok_or((Refusal::MissingId, String::new()))
        },
        _ => Err((Refusal::UnknownMethod, method.to_owned())),
    }
}

fn parse_tab_badge(params: &crate::Params) -> Result<Op, (Refusal, String)> {
    let Some(token) = text(params.get("kind")) else {
        return Err((Refusal::MissingBadgeKind, String::new()));
    };
    let Some(kind) = badge_for_token(&token) else {
        return Err((Refusal::InvalidBadgeKind, token));
    };
    Ok(Op::TabBadge {
        tab_id: text(params.get("tabId")),
        kind,
    })
}

fn parse_open(params: &crate::Params, editable: bool) -> Result<Op, (Refusal, String)> {
    let Some(target) = nonempty(params.get("target")) else {
        return Err((Refusal::MissingTarget, String::new()));
    };
    let placement = match text(params.get("placement")) {
        Some(token) => {
            match index_of(PLACEMENTS, &token) {
                Some(index) => index,
                None => return Err((Refusal::InvalidPlacement, token)),
            }
        },
        // The first entry is the default, which is the same statement `DEFAULT_PLACEMENT` makes on
        // the builder side — one table, read from both ends.
        None => 0,
    };
    Ok(Op::Open {
        target,
        editable,
        placement,
    })
}

fn parse_font_list(params: &crate::Params) -> Result<Op, (Refusal, String)> {
    let scope = match text(params.get("scope")) {
        Some(token) => {
            match index_of(FONT_SCOPES, &token) {
                Some(index) => Some(index),
                None => return Err((Refusal::InvalidScope, token)),
            }
        },
        None => None,
    };
    Ok(Op::FontList {
        monospace_only: flag(params.get("monospace")),
        family: text(params.get("family")),
        scope,
    })
}

fn parse_pane_capture(params: &crate::Params) -> Result<Op, (Refusal, String)> {
    let raw = params.get("lines");
    let integer = raw.and_then(Value::as_i64);
    let Some(lines) = capture_lines(raw.is_some(), integer.is_some(), integer.unwrap_or(0)) else {
        return Err((Refusal::CaptureLines, String::new()));
    };
    Ok(Op::PaneCapture {
        pane_id: text(params.get("paneId")),
        lines,
    })
}

fn parse_send_keys(params: &crate::Params) -> Result<Op, (Refusal, String)> {
    let text_field = text(params.get("text")).unwrap_or_default();
    let raw = params.get("keys");
    let array = raw.and_then(Value::as_array);
    // Non-string elements are dropped as they are read rather than refusing the whole array: the
    // refusal that matters is a `keys` of the wrong TYPE, and an array of numbers is an array that
    // named no keys — which falls to `NothingToSend` below, because nothing was sendable.
    let keys: Vec<String> = array.map_or_else(Vec::new, |items| {
        items
            .iter()
            .filter_map(|item| item.as_str().map(str::to_owned))
            .collect()
    });
    // The order is load-bearing: a `keys` of the wrong TYPE is reported as such even when there is
    // text to send, because a request that half-arrived must not look like one that fully did.
    if raw.is_some() && array.is_none() {
        return Err((Refusal::KeysNotAnArray, String::new()));
    }
    if text_field.is_empty() && keys.is_empty() {
        return Err((Refusal::NothingToSend, String::new()));
    }
    Ok(Op::PaneSendKeys {
        pane_id: text(params.get("paneId")),
        text: text_field,
        keys,
    })
}

// ---------------------------------------------------------------------------------------------- //
// Reading one field
// ---------------------------------------------------------------------------------------------- //

/// A string field, or `None` for absent AND for present-but-not-a-string.
///
/// The two are one answer on purpose: a control socket that read `12` as `"12"` is one that
/// guesses, and every caller here treats an unreadable field as an unsupplied one — which is either
/// a documented default or its own refusal, never a coercion.
fn text(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_owned)
}

/// A string field that must not be empty. The refusal for `""` and for absent is the same one,
/// because a verb that needs a path cannot proceed with either.
fn nonempty(value: Option<&Value>) -> Option<String> {
    text(value).filter(|found| !found.is_empty())
}

/// A boolean field. Absent or not-a-bool is `false`, which is every flag's documented default.
fn flag(value: Option<&Value>) -> bool {
    value.and_then(Value::as_bool).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use slopdesk_agent::badge::TabBadge;

    use super::{DEFAULT_CAPTURE_LINES, Decoded, MAX_CAPTURE_LINES, MAX_REQUEST_BYTES, Op, Refusal, decode};
    use crate::{
        AGENT_STATUS, EDIT, FONT_LIST, IGNORE, JUMP, KEYBIND_LIST, LEARN, METHODS, PANE_CAPTURE,
        PANE_SEND_KEYS, PANES, TAB_BADGE, TABS, VIEW, WINDOWS, agent_status_params, edit_params,
        encode_request_line, font_list_params, ignore_params, jump_params, keybind_list_params, learn_params,
        pane_capture_params, pane_send_keys_params, panes_params, tab_badge_params, tabs_params, view_params,
        windows_params,
    };

    /// The op one line decodes to, or a panic naming what came back instead.
    fn op(line: &str) -> Op {
        match decode(line) {
            Decoded::Run { op, .. } => op,
            other => panic!("expected a request, got {other:?}"),
        }
    }

    /// The refusal SENTENCE one line answers with.
    fn said(line: &str) -> String {
        match decode(line) {
            Decoded::Refused(reply) => reply,
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    fn keys(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| (*item).to_owned()).collect()
    }

    // -- the round trip -------------------------------------------------------------------------

    /// THE ROUND TRIP, one line per method: what the CLI builds is what this decodes, field for
    /// field. This is the check the Swift dispatcher could not have — it walked a `[String: Any]`
    /// one key at a time, in a language whose compiler never saw the builder next door.
    #[test]
    fn a_every_verb_the_cli_builds_decodes_to_the_op_it_meant() {
        let cases: [(String, Op); 14] = [
            (encode_request_line("1", WINDOWS, windows_params()), Op::Windows),
            (
                encode_request_line("1", TABS, tabs_params(Some("w1"))),
                Op::Tabs {
                    window_id: Some("w1".to_owned()),
                },
            ),
            (
                encode_request_line("1", PANES, panes_params(Some("t1"))),
                Op::Panes {
                    tab_id: Some("t1".to_owned()),
                },
            ),
            (
                encode_request_line("1", TAB_BADGE, tab_badge_params("running", Some("t1"))),
                Op::TabBadge {
                    tab_id: Some("t1".to_owned()),
                    kind: TabBadge::Running,
                },
            ),
            (
                encode_request_line("1", JUMP, jump_params(Some("proj"), true)),
                Op::Jump {
                    query: Some("proj".to_owned()),
                    change_directory: false,
                },
            ),
            (
                encode_request_line("1", LEARN, learn_params(Some("/tmp"))),
                Op::Learn {
                    path: Some("/tmp".to_owned()),
                },
            ),
            (
                encode_request_line("1", IGNORE, ignore_params("/tmp")),
                Op::Ignore {
                    path: "/tmp".to_owned(),
                },
            ),
            (
                encode_request_line("1", VIEW, view_params("/tmp/a.txt", "right")),
                Op::Open {
                    target: "/tmp/a.txt".to_owned(),
                    editable: false,
                    placement: 3,
                },
            ),
            (
                encode_request_line("1", EDIT, edit_params("/tmp/a.txt", "new-tab")),
                Op::Open {
                    target: "/tmp/a.txt".to_owned(),
                    editable: true,
                    placement: 0,
                },
            ),
            (
                encode_request_line("1", FONT_LIST, font_list_params(true, Some("Mono"), Some("user"))),
                Op::FontList {
                    monospace_only: true,
                    family: Some("Mono".to_owned()),
                    scope: Some(1),
                },
            ),
            (
                encode_request_line("1", KEYBIND_LIST, keybind_list_params(Some("split"))),
                Op::KeybindList {
                    action: Some("split".to_owned()),
                },
            ),
            (
                encode_request_line("1", PANE_CAPTURE, pane_capture_params(Some("p1"), 100)),
                Op::PaneCapture {
                    pane_id: Some("p1".to_owned()),
                    lines: 100,
                },
            ),
            (
                encode_request_line(
                    "1",
                    PANE_SEND_KEYS,
                    pane_send_keys_params(Some("p1"), "ls -la", &keys(&["Enter"])),
                ),
                Op::PaneSendKeys {
                    pane_id: Some("p1".to_owned()),
                    text: "ls -la".to_owned(),
                    keys: keys(&["Enter"]),
                },
            ),
            (
                encode_request_line("1", AGENT_STATUS, agent_status_params("s1")),
                Op::AgentStatus { id: "s1".to_owned() },
            ),
        ];
        assert_eq!(cases.len(), METHODS.len(), "one round trip per method");
        for (line, expected) in cases {
            assert_eq!(op(&line), expected, "{line}");
        }
    }

    /// Every op reports the verb index its method sits at in the vocabulary — the byte a face
    /// dispatches on. `view`/`edit` are two methods over one op, and both indices are theirs.
    #[test]
    fn every_op_names_its_own_slot_in_the_method_table() {
        let seen = METHODS
            .iter()
            .enumerate()
            .map(|(slot, method)| {
                let params = if *method == TAB_BADGE {
                    tab_badge_params("running", None)
                } else if *method == IGNORE || *method == LEARN {
                    ignore_params("/tmp")
                } else if *method == VIEW || *method == EDIT {
                    view_params("/tmp", "new-tab")
                } else if *method == AGENT_STATUS {
                    agent_status_params("s1")
                } else if *method == PANE_SEND_KEYS {
                    pane_send_keys_params(None, "x", &[])
                } else {
                    windows_params()
                };
                let decoded = op(&encode_request_line("1", method, params));
                let index = u8::try_from(slot).unwrap_or(u8::MAX);
                assert_eq!(decoded.verb(), index, "{method}");
                decoded.verb()
            })
            .count();
        assert_eq!(seen, METHODS.len());
    }

    // -- the line guard -------------------------------------------------------------------------

    #[test]
    fn b_a_blank_line_is_nothing_to_respond_to() {
        for line in ["", " ", "\n", "\r\n", " \t \n"] {
            assert_eq!(decode(line), Decoded::Blank, "{line:?}");
        }
    }

    #[test]
    fn an_oversized_line_is_refused_before_it_is_parsed() {
        let line = "x".repeat(MAX_REQUEST_BYTES.saturating_add(1));
        assert!(said(&line).contains("request too large"));
        // The cap measures the TRIMMED request, so padding is not what refuses a line.
        let padded = format!("{}{}", " ".repeat(64), "{\"id\":\"1\",\"method\":\"windows\"}");
        assert!(matches!(decode(&padded), Decoded::Run { .. }));
    }

    #[test]
    fn a_line_that_is_not_a_request_object_is_malformed() {
        for line in [
            "not json",
            "7",
            "[]",
            r#"{"method":"windows"}"#,
            r#"{"id":"1"}"#,
            r#"{"id":7,"method":"windows"}"#,
            r#"{"id":"1","method":7}"#,
        ] {
            assert!(said(line).contains("malformed request"), "{line}");
        }
    }

    /// A refusal that could not read an `id` answers under `?`, and one that could echoes it — the
    /// CLI correlates on that field and an invented id would strand the request it belongs to.
    #[test]
    fn a_refusal_echoes_the_id_it_could_read() {
        assert!(said("not json").contains(r#""id":"?""#));
        assert!(
            said(r#"{"id":"abc","method":"nope"}"#).contains(r#""id":"abc""#),
            "a readable id is echoed",
        );
    }

    // -- the verb table -------------------------------------------------------------------------

    #[test]
    fn c_an_unknown_method_names_itself() {
        assert!(said(r#"{"id":"1","method":"teleport"}"#).contains("unknown method: teleport"));
    }

    #[test]
    fn an_absent_or_unreadable_params_is_the_verb_with_no_params() {
        for line in [
            r#"{"id":"1","method":"tabs"}"#,
            r#"{"id":"1","method":"tabs","params":null}"#,
            r#"{"id":"1","method":"tabs","params":[]}"#,
        ] {
            assert_eq!(op(line), Op::Tabs { window_id: None }, "{line}");
        }
    }

    /// A field of the wrong TYPE reads as absent rather than being coerced, so every verb lands on
    /// its documented default or its own refusal.
    #[test]
    fn a_field_of_the_wrong_type_is_not_guessed_at() {
        assert_eq!(
            op(r#"{"id":"1","method":"tabs","params":{"windowId":12}}"#),
            Op::Tabs { window_id: None },
        );
        assert_eq!(
            op(r#"{"id":"1","method":"jump","params":{"noCd":"yes"}}"#),
            Op::Jump {
                query: None,
                change_directory: true,
            },
            "an unreadable noCd is the default, which is to cd",
        );
    }

    #[test]
    fn a_badge_kind_must_be_present_and_settable() {
        assert!(said(r#"{"id":"1","method":"tab-badge","params":{}}"#).contains("missing params.kind"));
        assert!(
            said(r#"{"id":"1","method":"tab-badge","params":{"kind":"blue"}}"#)
                .contains("invalid badge kind 'blue'")
        );
        assert!(
            said(r#"{"id":"1","method":"tab-badge","params":{"kind":"caffeinate"}}"#)
                .contains("invalid badge kind 'caffeinate'"),
            "a LISTABLE-only badge may not be set",
        );
    }

    #[test]
    fn an_open_needs_a_target_and_a_placement_it_knows() {
        assert!(said(r#"{"id":"1","method":"view","params":{}}"#).contains("missing params.target"));
        assert!(
            said(r#"{"id":"1","method":"view","params":{"target":""}}"#).contains("missing params.target"),
            "an empty target is a missing one",
        );
        assert!(
            said(r#"{"id":"1","method":"edit","params":{"target":"/x","placement":"centre"}}"#)
                .contains("invalid placement 'centre'")
        );
    }

    #[test]
    fn a_font_scope_must_be_one_the_vocabulary_carries() {
        assert!(
            said(r#"{"id":"1","method":"font-list","params":{"scope":"ui"}}"#).contains("invalid scope 'ui'")
        );
        assert_eq!(
            op(r#"{"id":"1","method":"font-list","params":{}}"#),
            Op::FontList {
                monospace_only: false,
                family: None,
                scope: None,
            },
        );
    }

    #[test]
    fn a_capture_count_is_defaulted_clamped_or_refused() {
        let count = |params: &str| {
            match op(&format!(
                r#"{{"id":"1","method":"pane-capture","params":{params}}}"#
            )) {
                Op::PaneCapture { lines, .. } => lines,
                other => panic!("expected a capture, got {other:?}"),
            }
        };
        assert_eq!(count("{}"), DEFAULT_CAPTURE_LINES);
        assert_eq!(count(r#"{"lines":1}"#), 1);
        assert_eq!(
            count(&format!(r#"{{"lines":{}}}"#, i64::MAX)),
            MAX_CAPTURE_LINES,
            "a hostile number cannot force an unbounded read",
        );
        for hostile in [
            r#"{"lines":0}"#,
            r#"{"lines":-1}"#,
            r#"{"lines":"12"}"#,
            r#"{"lines":1.5}"#,
        ] {
            assert!(
                said(&format!(
                    r#"{{"id":"1","method":"pane-capture","params":{hostile}}}"#
                ))
                .contains("lines must be a positive integer"),
                "{hostile}",
            );
        }
    }

    #[test]
    fn send_keys_needs_something_to_send_and_an_array_to_send_it_in() {
        let line = |params: &str| format!(r#"{{"id":"1","method":"pane-send-keys","params":{params}}}"#);
        assert!(said(&line("{}")).contains("nothing to send (need text or keys)"));
        assert!(
            said(&line(r#"{"keys":[1,2]}"#)).contains("nothing to send"),
            "an array that named no keys sent nothing",
        );
        assert!(
            said(&line(r#"{"text":"ls","keys":"Enter"}"#)).contains("keys must be an array of strings"),
            "a half-arrived request must not look like one that fully arrived",
        );
        assert_eq!(
            op(&line(r#"{"text":"","keys":["Enter","x",7]}"#)),
            Op::PaneSendKeys {
                pane_id: None,
                text: String::new(),
                keys: keys(&["Enter", "x"]),
            },
            "non-string elements are dropped, not refused",
        );
    }

    #[test]
    fn the_two_verbs_that_need_a_non_empty_string_say_so() {
        assert!(said(r#"{"id":"1","method":"ignore","params":{}}"#).contains("missing params.path"));
        assert!(said(r#"{"id":"1","method":"ignore","params":{"path":""}}"#).contains("missing params.path"));
        assert!(said(r#"{"id":"1","method":"agent-status","params":{}}"#).contains("missing params.id"));
        assert!(
            said(r#"{"id":"1","method":"agent-status","params":{"id":""}}"#).contains("missing params.id")
        );
    }

    // -- the refusal vocabulary -----------------------------------------------------------------

    #[test]
    fn d_every_refusal_round_trips_through_its_code() {
        for refusal in Refusal::ALL {
            assert_eq!(Refusal::from_code(refusal.code()), Some(refusal));
        }
        let codes: Vec<u8> = Refusal::ALL.iter().map(|r| r.code()).collect();
        assert_eq!(codes, (1_u8..=20).collect::<Vec<u8>>());
        // `0` is the ABSENCE of a refusal, which is what an acceptance answers with.
        assert_eq!(Refusal::from_code(0), None);
        assert_eq!(Refusal::from_code(21), None);
        assert_eq!(Refusal::from_code(u8::MAX), None);
    }

    #[test]
    fn only_the_five_that_name_a_token_carry_one() {
        for refusal in Refusal::ALL {
            let spoken = refusal.message("zzz-token");
            assert!(!spoken.is_empty(), "{refusal:?}");
            assert_eq!(
                spoken.contains("zzz-token"),
                refusal.names_detail(),
                "{refusal:?}: {spoken}",
            );
        }
    }

    /// The exact sentences, because they are the user interface: a person reads them out of a
    /// terminal and searches for them.
    #[test]
    fn the_words_are_the_shipped_ones() {
        assert_eq!(Refusal::TooLarge.message(""), "request too large");
        assert_eq!(Refusal::Malformed.message(""), "malformed request");
        assert_eq!(Refusal::UnknownMethod.message("nope"), "unknown method: nope");
        assert_eq!(Refusal::MissingBadgeKind.message(""), "missing params.kind");
        assert_eq!(
            Refusal::InvalidBadgeKind.message("blue"),
            "invalid badge kind 'blue'"
        );
        assert_eq!(Refusal::TabNotFound.message(""), "tab not found");
        assert_eq!(Refusal::NoJumpTarget.message(""), "no jump target");
        assert_eq!(
            Refusal::NothingToLearn.message(""),
            "no directory to learn (give a path or focus a pane with a cwd)"
        );
        assert_eq!(Refusal::MissingPath.message(""), "missing params.path");
        assert_eq!(Refusal::CouldNotIgnore.message(""), "could not ignore path");
        assert_eq!(Refusal::MissingTarget.message(""), "missing params.target");
        assert_eq!(
            Refusal::InvalidPlacement.message("split-lefft"),
            "invalid placement 'split-lefft'"
        );
        assert_eq!(Refusal::CouldNotOpen.message(""), "could not open target");
        assert_eq!(Refusal::InvalidScope.message("ui"), "invalid scope 'ui'");
        assert_eq!(
            Refusal::CaptureLines.message(""),
            "lines must be a positive integer"
        );
        assert_eq!(Refusal::PaneNotFound.message(""), "pane not found");
        assert_eq!(
            Refusal::KeysNotAnArray.message(""),
            "keys must be an array of strings"
        );
        assert_eq!(
            Refusal::NothingToSend.message(""),
            "nothing to send (need text or keys)"
        );
        assert_eq!(Refusal::UnknownKey.message("f5"), "unknown key: f5");
        assert_eq!(Refusal::MissingId.message(""), "missing params.id");
    }
}

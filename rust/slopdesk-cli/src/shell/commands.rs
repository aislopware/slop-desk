//! One function per app-driving subcommand: parse its flags, call the verb, render the answer,
//! pick the exit code.
//!
//! Every one of them reaches the app through the [`Control`] trait rather than a socket, so a test
//! can drive a whole subcommand — including the status it would hand the shell — against a canned
//! response. That is the half of `main.swift` no test could reach.

use serde_json::Value;

use crate::args::OutputFormat;
use crate::clientctl::{self, Params};
use crate::formatting::{self, Row};
use crate::shell::{Control, Ctx, Failure, Io, Run, print};

/// The default `pane capture` depth — a screen and a bit, which is what somebody asking "what does
/// that pane say" almost always means.
const DEFAULT_CAPTURE_LINES: i64 = 100;

/// The rows under `key`, with anything that is not an object dropped.
fn rows_of(result: &Params, key: &str) -> Vec<Row> {
    result
        .get(key)
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_object().cloned())
                .collect()
        })
        .unwrap_or_default()
}

/// Calls a list verb and renders `result[key]` through `render`, honouring `--json` and
/// `--no-headers`.
pub(super) fn emit_list(
    ctl: &mut impl Control,
    io: &mut Io<'_>,
    ctx: &Ctx,
    method: &str,
    params: Params,
    key: &str,
    render: fn(&[Row], OutputFormat, bool) -> String,
) -> Run {
    let result = ctl.call(method, params)?;
    let rows = rows_of(&result, key);
    print(
        io.out,
        &render(&rows, ctx.invocation.format, ctx.invocation.no_headers),
    )?;
    print(io.out, "\n")?;
    Ok(0)
}

/// Renders a whole `result` object as one compact, key-sorted JSON line.
fn emit_json(io: &mut Io<'_>, result: &Params) -> Run {
    print(
        io.out,
        &formatting::render_json_text(&Value::Object(result.clone()).to_string()),
    )?;
    print(io.out, "\n")?;
    Ok(0)
}

/// The value of a flag that takes one, or the usage error naming it.
pub(super) fn value_after<'a>(
    rest: &'a [String],
    index: usize,
    verb: &str,
    flag: &str,
) -> Result<&'a str, Failure> {
    rest.get(index.saturating_add(1))
        .map(String::as_str)
        .ok_or_else(|| Failure::usage(format!("{verb}: {flag} requires a value")))
}

/// Refuses a trailing operand a verb takes none of.
pub(super) fn no_extras(rest: &[String], verb: &str) -> Result<(), Failure> {
    rest.first().map_or(Ok(()), |extra| {
        Err(Failure::usage(format!("{verb}: unexpected argument '{extra}'")))
    })
}

// ---------------------------------------------------------------------------------------------
// window / tab / pane
// ---------------------------------------------------------------------------------------------

/// `windows` / `window list`.
///
/// # Errors
/// A trailing operand, or anything the call failed with.
pub fn window_list(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    no_extras(rest, "windows")?;
    emit_list(
        ctl,
        io,
        ctx,
        clientctl::WINDOWS,
        clientctl::windows_params(),
        "windows",
        formatting::windows,
    )
}

/// `window <verb>`.
///
/// # Errors
/// A verb other than `list`, or anything the call failed with.
pub fn window(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    match rest.first().map(String::as_str) {
        None | Some("list") => window_list(ctl, io, rest.get(1..).unwrap_or_default(), ctx),
        Some(_) => {
            Err(Failure::usage(
                "window: only 'list' is available (new/close land in later work items)",
            ))
        },
    }
}

/// `tabs` / `tab list [--window <id>]`.
///
/// # Errors
/// An unknown argument, a dangling `--window`, or anything the call failed with.
pub fn tab_list(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let mut window_id: Option<&str> = None;
    let mut index = 0;
    while let Some(token) = rest.get(index) {
        match token.as_str() {
            "--window" => {
                window_id = Some(value_after(rest, index, "tab list", "--window")?);
                index = index.saturating_add(1);
            },
            other => {
                return Err(Failure::usage(format!("tab list: unknown argument '{other}'")));
            },
        }
        index = index.saturating_add(1);
    }
    emit_list(
        ctl,
        io,
        ctx,
        clientctl::TABS,
        clientctl::tabs_params(window_id),
        "tabs",
        formatting::tabs,
    )
}

/// `tab badge --kind <token> [--tab <id>]`.
///
/// # Errors
/// A missing or dangling flag, or anything the call failed with.
pub fn tab_badge(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let mut kind: Option<&str> = None;
    let mut tab_id: Option<&str> = None;
    let mut index = 0;
    while let Some(token) = rest.get(index) {
        match token.as_str() {
            "--kind" => {
                kind = Some(value_after(rest, index, "tab badge", "--kind")?);
                index = index.saturating_add(1);
            },
            "--tab" => {
                tab_id = Some(value_after(rest, index, "tab badge", "--tab")?);
                index = index.saturating_add(1);
            },
            other => return Err(Failure::usage(format!("tab badge: unknown flag '{other}'"))),
        }
        index = index.saturating_add(1);
    }
    let kind = kind.ok_or_else(|| {
        Failure::usage(format!(
            "tab badge: requires --kind <{}>",
            clientctl::settable_badge_tokens()
        ))
    })?;

    let result = ctl.call(clientctl::TAB_BADGE, clientctl::tab_badge_params(kind, tab_id))?;
    if ctx.invocation.format == OutputFormat::Json {
        return emit_json(io, &result);
    }
    // The app ECHOES the kind it settled on, which is not always the one asked for: `unread` is
    // spelled back as the badge it maps to. Printing the answer rather than the request is what
    // makes that visible.
    let settled = result.get("kind").and_then(Value::as_str).unwrap_or(kind);
    print(io.out, &format!("badge: {settled}\n"))?;
    Ok(0)
}

/// `tab <verb>`.
///
/// # Errors
/// A verb other than `list`/`badge`, or anything the call failed with.
pub fn tab(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let tail = rest.get(1..).unwrap_or_default();
    match rest.first().map(String::as_str) {
        None | Some("list") => tab_list(ctl, io, tail, ctx),
        Some("badge") => tab_badge(ctl, io, tail, ctx),
        Some(_) => Err(Failure::usage("tab: expected 'list' or 'badge'")),
    }
}

/// `panes` / `pane list [--tab <id>]`.
///
/// # Errors
/// An unknown argument, a dangling `--tab`, or anything the call failed with.
pub fn pane_list(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let mut tab_id: Option<&str> = None;
    let mut index = 0;
    while let Some(token) = rest.get(index) {
        match token.as_str() {
            "--tab" => {
                tab_id = Some(value_after(rest, index, "pane list", "--tab")?);
                index = index.saturating_add(1);
            },
            other => return Err(Failure::usage(format!("pane list: unknown argument '{other}'"))),
        }
        index = index.saturating_add(1);
    }
    emit_list(
        ctl,
        io,
        ctx,
        clientctl::PANES,
        clientctl::panes_params(tab_id),
        "panes",
        formatting::panes,
    )
}

/// `pane capture [--pane <id>] [--lines <n>]`.
///
/// # Errors
/// An unknown flag, a `--lines` that is not a positive integer, or anything the call failed with.
pub fn pane_capture(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let mut pane_id: Option<&str> = None;
    let mut lines = DEFAULT_CAPTURE_LINES;
    let mut index = 0;
    while let Some(token) = rest.get(index) {
        match token.as_str() {
            "--pane" => {
                pane_id = Some(value_after(rest, index, "pane capture", "--pane")?);
                index = index.saturating_add(1);
            },
            "--lines" => {
                let raw = value_after(rest, index, "pane capture", "--lines")?;
                lines = raw
                    .parse::<i64>()
                    .ok()
                    .filter(|count| *count > 0)
                    .ok_or_else(|| Failure::usage("pane capture: --lines must be a positive integer"))?;
                index = index.saturating_add(1);
            },
            other => return Err(Failure::usage(format!("pane capture: unknown flag '{other}'"))),
        }
        index = index.saturating_add(1);
    }

    let result = ctl.call(
        clientctl::PANE_CAPTURE,
        clientctl::pane_capture_params(pane_id, lines),
    )?;
    let captured: Vec<&str> = result
        .get("lines")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();

    if ctx.invocation.format == OutputFormat::Json {
        let array = Value::Array(captured.iter().map(|line| Value::from(*line)).collect());
        print(io.out, &formatting::render_json_text(&array.to_string()))?;
        print(io.out, "\n")?;
    } else if !captured.is_empty() {
        // Nothing at all for an empty capture, rather than a blank line: the caller is usually
        // piping this, and a lone newline is a row that was never on the screen.
        print(io.out, &captured.join("\n"))?;
        print(io.out, "\n")?;
    }
    Ok(0)
}

/// `pane send-keys [--pane <id>] [--] <text...> [key:<Name>...]`.
///
/// Tokens after `--` are operands: `key:<Name>` is a named key, everything else is literal text
/// joined by a space. The `--` is accepted rather than required — a caller who does not need it
/// should not have to type it — but everything after one is taken verbatim, which is what protects
/// literal text that starts with a dash.
///
/// # Errors
/// A dangling `--pane`, or nothing at all to send.
pub fn pane_send_keys(ctl: &mut impl Control, rest: &[String], _ctx: &Ctx) -> Run {
    let mut pane_id: Option<&str> = None;
    let mut operands: Vec<&str> = Vec::new();
    let mut after_separator = false;
    let mut index = 0;
    while let Some(token) = rest.get(index) {
        if after_separator {
            operands.push(token);
        } else if token == "--pane" {
            pane_id = Some(value_after(rest, index, "pane send-keys", "--pane")?);
            index = index.saturating_add(1);
        } else if token == "--" {
            after_separator = true;
        } else {
            operands.push(token);
        }
        index = index.saturating_add(1);
    }

    let mut text_parts: Vec<&str> = Vec::new();
    let mut keys: Vec<String> = Vec::new();
    for operand in operands {
        if let Some(name) = operand.strip_prefix("key:") {
            if !name.is_empty() {
                keys.push(name.to_owned());
            }
        } else {
            text_parts.push(operand);
        }
    }
    let text = text_parts.join(" ");
    if text.is_empty() && keys.is_empty() {
        return Err(Failure::usage("pane send-keys: nothing to send"));
    }
    drop(ctl.call(
        clientctl::PANE_SEND_KEYS,
        clientctl::pane_send_keys_params(pane_id, &text, &keys),
    )?);
    Ok(0) // silent on success
}

/// `pane <verb>`.
///
/// # Errors
/// A verb other than `list`/`capture`/`send-keys`, or anything the call failed with.
pub fn pane(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let tail = rest.get(1..).unwrap_or_default();
    match rest.first().map(String::as_str) {
        None | Some("list") => pane_list(ctl, io, tail, ctx),
        Some("capture") => pane_capture(ctl, io, tail, ctx),
        Some("send-keys") => pane_send_keys(ctl, tail, ctx),
        Some(_) => Err(Failure::usage("pane: expected 'list', 'capture', or 'send-keys'")),
    }
}

// ---------------------------------------------------------------------------------------------
// keybind
// ---------------------------------------------------------------------------------------------

/// `keybind list [--action <substring>]`.
///
/// # Errors
/// An unknown flag, a dangling `--action`, or anything the call failed with.
pub fn keybind_list(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let mut action: Option<&str> = None;
    let mut index = 0;
    while let Some(token) = rest.get(index) {
        match token.as_str() {
            "--action" => {
                action = Some(value_after(rest, index, "keybind list", "--action")?);
                index = index.saturating_add(1);
            },
            other => return Err(Failure::usage(format!("keybind list: unknown flag '{other}'"))),
        }
        index = index.saturating_add(1);
    }
    emit_list(
        ctl,
        io,
        ctx,
        clientctl::KEYBIND_LIST,
        clientctl::keybind_list_params(action),
        "keybinds",
        formatting::keybinds,
    )
}

/// `keybind <verb>`.
///
/// # Errors
/// A verb other than `list`, or anything the call failed with.
pub fn keybind(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    match rest.first().map(String::as_str) {
        Some("list") => keybind_list(ctl, io, rest.get(1..).unwrap_or_default(), ctx),
        _ => Err(Failure::usage("keybind: only 'list' is available")),
    }
}

// ---------------------------------------------------------------------------------------------
// jump / learn / ignore (frecency)
// ---------------------------------------------------------------------------------------------

/// `jump [query] [--no-cd]`.
///
/// The APP resolves it, because the frecency database is client-side; `--no-cd` prints the resolved
/// path instead of typing `cd` into the focused pane. No query toggles between `$HOME` and the last
/// jump source.
///
/// # Errors
/// An unknown flag, a second positional, or anything the call failed with.
pub fn jump(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let mut query: Option<&str> = None;
    let mut no_cd = false;
    for token in rest {
        match token.as_str() {
            "--no-cd" => no_cd = true,
            other if other.starts_with('-') => {
                return Err(Failure::usage(format!("jump: unknown flag '{other}'")));
            },
            other if query.is_none() => query = Some(other),
            other => return Err(Failure::usage(format!("jump: unexpected argument '{other}'"))),
        }
    }

    let result = ctl.call(clientctl::JUMP, clientctl::jump_params(query, no_cd))?;
    if ctx.invocation.format == OutputFormat::Json {
        return emit_json(io, &result);
    }
    // A committed `cd` is silent; anything else prints the path, so `cd "$(slopdesk jump --no-cd
    // proj)"` works from a shell the app cannot type into.
    if result.get("changed").and_then(Value::as_bool) != Some(true) {
        let path = result.get("path").and_then(Value::as_str).unwrap_or_default();
        print(io.out, &format!("{path}\n"))?;
    }
    Ok(0)
}

/// `learn [path]` — record a directory visit. No path records the focused pane's cached OSC-7 cwd.
///
/// # Errors
/// An unknown flag, a second positional, or anything the call failed with.
pub fn learn(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let path = one_positional(rest, "learn")?;
    let result = ctl.call(clientctl::LEARN, clientctl::learn_params(path))?;
    if ctx.invocation.format == OutputFormat::Json {
        return emit_json(io, &result);
    }
    if let Some(learned) = result.get("path").and_then(Value::as_str) {
        print(io.out, &format!("learned: {learned}\n"))?;
    }
    Ok(0)
}

/// `ignore <path>` — remove a directory from the frecency database.
///
/// # Errors
/// A missing path, an unknown flag, or anything the call failed with.
pub fn ignore(ctl: &mut impl Control, rest: &[String]) -> Run {
    let path = one_positional(rest, "ignore")?.ok_or_else(|| Failure::usage("ignore: requires a <path>"))?;
    drop(ctl.call(clientctl::IGNORE, clientctl::ignore_params(path))?);
    Ok(0) // silent on success
}

/// At most one positional operand, with any leading-dash token refused by name.
fn one_positional<'a>(rest: &'a [String], verb: &str) -> Result<Option<&'a str>, Failure> {
    let mut found: Option<&str> = None;
    for token in rest {
        if token.starts_with('-') {
            return Err(Failure::usage(format!("{verb}: unknown flag '{token}'")));
        }
        if found.is_some() {
            return Err(Failure::usage(format!("{verb}: unexpected argument '{token}'")));
        }
        found = Some(token);
    }
    Ok(found)
}

// ---------------------------------------------------------------------------------------------
// view / edit
// ---------------------------------------------------------------------------------------------

/// Parses a `view`/`edit` invocation into its target and placement token.
///
/// # Errors
/// An unknown flag, a missing target, or a second positional.
pub fn parse_shim_args<'a>(verb: &str, rest: &'a [String]) -> Result<(&'a str, &'a str), Failure> {
    let mut target: Option<&str> = None;
    let mut placement = clientctl::DEFAULT_PLACEMENT;
    for token in rest {
        // `--new-tab` → `new-tab`: the flag IS the token, which is what keeps the CLI's spelling
        // and the wire's one fact rather than two.
        if let Some(stripped) = token.strip_prefix("--")
            && let Some(known) = clientctl::PLACEMENTS.iter().find(|name| **name == stripped)
        {
            placement = known;
            continue;
        }
        if token.starts_with('-') {
            return Err(Failure::usage(format!("{verb}: unknown flag '{token}'")));
        }
        if target.is_some() {
            return Err(Failure::usage(format!("{verb}: unexpected argument '{token}'")));
        }
        target = Some(token);
    }
    let target = target
        .filter(|value| !value.is_empty())
        .ok_or_else(|| Failure::usage(format!("{verb}: requires a <path|url>")))?;
    Ok((target, placement))
}

/// `view <path|url> [placement]` — a READ-ONLY shim (`less <path>` / `open <url>`) in a new pane.
///
/// NOT a native local renderer: a slopdesk pane is a remote PTY, so the shim types the command into
/// a fresh split.
///
/// # Errors
/// Anything [`parse_shim_args`] or the call failed with.
pub fn view(ctl: &mut impl Control, rest: &[String]) -> Run {
    let (target, placement) = parse_shim_args("view", rest)?;
    drop(ctl.call(clientctl::VIEW, clientctl::view_params(target, placement))?);
    Ok(0) // silent on success
}

/// `edit <path|url> [placement]` — an EDITOR shim (`$EDITOR <path>`) in a new pane.
///
/// # Errors
/// Anything [`parse_shim_args`] or the call failed with.
pub fn edit(ctl: &mut impl Control, rest: &[String]) -> Run {
    let (target, placement) = parse_shim_args("edit", rest)?;
    drop(ctl.call(clientctl::EDIT, clientctl::edit_params(target, placement))?);
    Ok(0) // silent on success
}

#[cfg(test)]
pub(crate) mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]
    #![expect(
        clippy::redundant_pub_crate,
        reason = "`unreachable_pub` wants exactly this spelling on a helper the sibling test modules share; \
                  the two lints disagree and the rustc one wins"
    )]

    use serde_json::{Map, Value};

    use super::{
        edit, ignore, jump, learn, pane, pane_capture, pane_send_keys, tab, tab_badge, view, window,
        window_list,
    };
    use crate::args::{Invocation, OutputFormat};
    use crate::clientctl::Params;
    use crate::shell::{Control, Ctx, EXIT_USAGE, Environment, Failure, Io, Run};

    /// A canned far end that records what it was asked and answers what it was told to.
    pub(crate) struct Fake {
        /// Every `(method, params)` the subcommand sent, in order.
        pub sent: Vec<(String, Params)>,
        /// The `result` object to answer with.
        pub result: Params,
        /// The failure to answer with instead, if any.
        pub failure: Option<Failure>,
    }

    impl Fake {
        pub(crate) fn answering(json: &str) -> Self {
            Self {
                sent: Vec::new(),
                result: serde_json::from_str(json).expect("the fixture is a JSON object"),
                failure: None,
            }
        }

        pub(crate) fn empty() -> Self {
            Self::answering("{}")
        }
    }

    impl Control for Fake {
        fn call(&mut self, method: &str, params: Params) -> Result<Params, Failure> {
            self.sent.push((method.to_owned(), params));
            match &self.failure {
                Some(failure) => Err(failure.clone()),
                None => Ok(self.result.clone()),
            }
        }
    }

    pub(crate) fn ctx(format: OutputFormat) -> Ctx {
        Ctx {
            invocation: Invocation {
                format,
                ..Invocation::default()
            },
            environment: Environment::default(),
            program: "slopdesk".to_owned(),
        }
    }

    pub(crate) fn args(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| (*item).to_owned()).collect()
    }

    /// Runs a subcommand and hands back its code and everything it printed.
    pub(crate) fn drive(body: impl FnOnce(&mut Io<'_>) -> Run) -> (Run, String) {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = {
            let mut io = Io {
                out: &mut out,
                err: &mut err,
            };
            body(&mut io)
        };
        (code, String::from_utf8(out).expect("stdout is UTF-8"))
    }

    fn params_of(fake: &Fake) -> &Params {
        &fake.sent.first().expect("one request was sent").1
    }

    #[test]
    fn a_list_renders_a_table_by_default_and_json_under_the_flag() {
        let mut fake = Fake::answering(r#"{"windows":[{"id":"w1","title":"One"}]}"#);
        let (code, text) = drive(|io| window_list(&mut fake, io, &[], &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(0));
        assert!(text.contains("w1"), "{text}");
        assert_eq!(fake.sent.first().expect("sent").0, "windows");

        let mut fake = Fake::answering(r#"{"windows":[{"id":"w1","title":"One"}]}"#);
        let (code, json) = drive(|io| window_list(&mut fake, io, &[], &ctx(OutputFormat::Json)));
        assert_eq!(code, Ok(0));
        assert!(json.starts_with('['), "{json}");
        assert!(json.contains("\"id\":\"w1\""), "{json}");
    }

    /// A list method that answers no rows is an empty list, not a failure — no windows is a state.
    #[test]
    fn a_list_with_no_rows_prints_the_empty_shape_and_exits_zero() {
        let mut fake = Fake::empty();
        let (code, _) = drive(|io| window_list(&mut fake, io, &[], &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(0));
    }

    #[test]
    fn a_trailing_operand_on_a_list_is_a_usage_error() {
        let mut fake = Fake::empty();
        let (code, _) = drive(|io| window_list(&mut fake, io, &args(&["oops"]), &ctx(OutputFormat::Text)));
        assert_eq!(code.expect_err("refused").code, EXIT_USAGE);
        assert!(fake.sent.is_empty(), "nothing is dialled before the flags parse");
    }

    #[test]
    fn window_offers_only_list_and_says_where_the_rest_went() {
        let mut fake = Fake::empty();
        let (code, _) = drive(|io| window(&mut fake, io, &args(&["new"]), &ctx(OutputFormat::Text)));
        let failure = code.expect_err("refused");
        assert_eq!(failure.code, EXIT_USAGE);
        assert!(failure.message.contains("only 'list'"), "{failure:?}");
    }

    #[test]
    fn a_bare_noun_lists_the_way_the_plural_does() {
        let mut fake = Fake::answering(r#"{"tabs":[]}"#);
        let (code, _) = drive(|io| tab(&mut fake, io, &[], &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(0));
        assert_eq!(fake.sent.first().expect("sent").0, "tabs");

        let mut fake = Fake::answering(r#"{"panes":[]}"#);
        let (code, _) = drive(|io| pane(&mut fake, io, &[], &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(0));
        assert_eq!(fake.sent.first().expect("sent").0, "panes");
    }

    #[test]
    fn a_badge_prints_the_kind_the_app_settled_on_rather_than_the_one_asked_for() {
        let mut fake = Fake::answering(r#"{"kind":"finished"}"#);
        let (code, text) = drive(|io| {
            tab_badge(
                &mut fake,
                io,
                &args(&["--kind", "unread", "--tab", "t1"]),
                &ctx(OutputFormat::Text),
            )
        });
        assert_eq!(code, Ok(0));
        assert_eq!(text, "badge: finished\n");
        assert_eq!(
            params_of(&fake).get("kind").and_then(Value::as_str),
            Some("unread"),
            "the request still carries what the user typed"
        );
    }

    #[test]
    fn a_badge_with_no_kind_lists_the_tokens_it_would_have_taken() {
        let mut fake = Fake::empty();
        let (code, _) =
            drive(|io| tab_badge(&mut fake, io, &args(&["--tab", "t1"]), &ctx(OutputFormat::Text)));
        let failure = code.expect_err("refused");
        assert_eq!(failure.code, EXIT_USAGE);
        assert!(failure.message.contains("awaiting-input"), "{failure:?}");
    }

    #[test]
    fn a_capture_prints_lines_verbatim_and_nothing_at_all_when_there_are_none() {
        let mut fake = Fake::answering(r#"{"lines":["one","two"]}"#);
        let (code, text) = drive(|io| pane_capture(&mut fake, io, &[], &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(0));
        assert_eq!(text, "one\ntwo\n");
        assert_eq!(
            params_of(&fake).get("lines").and_then(Value::as_i64),
            Some(100),
            "the default depth is sent explicitly"
        );

        let mut fake = Fake::answering(r#"{"lines":[]}"#);
        let (code, text) = drive(|io| pane_capture(&mut fake, io, &[], &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(0));
        assert_eq!(
            text, "",
            "an empty capture prints no row that was never on screen"
        );
    }

    #[test]
    fn a_capture_depth_must_be_a_positive_integer() {
        for bad in [&["--lines", "0"], &["--lines", "-3"], &["--lines", "many"]] {
            let mut fake = Fake::empty();
            let (code, _) = drive(|io| pane_capture(&mut fake, io, &args(bad), &ctx(OutputFormat::Text)));
            assert_eq!(code.expect_err("refused").code, EXIT_USAGE, "{bad:?}");
        }
    }

    #[test]
    fn send_keys_splits_named_keys_from_literal_text_and_joins_the_text_with_spaces() {
        let mut fake = Fake::empty();
        let (code, _) = drive(|_| {
            pane_send_keys(
                &mut fake,
                &args(&["--pane", "p1", "--", "ls", "-la", "key:Enter"]),
                &ctx(OutputFormat::Text),
            )
        });
        assert_eq!(code, Ok(0));
        let params = params_of(&fake);
        assert_eq!(params.get("text").and_then(Value::as_str), Some("ls -la"));
        assert_eq!(
            params.get("keys").and_then(Value::as_array).map(Vec::len),
            Some(1)
        );
        assert_eq!(params.get("paneId").and_then(Value::as_str), Some("p1"));
    }

    /// A bare `key:` names no key, and a send with neither text nor keys is refused rather than
    /// sent as an empty write the app would have to interpret.
    #[test]
    fn send_keys_with_nothing_to_send_is_refused() {
        let mut fake = Fake::empty();
        let (code, _) = drive(|_| pane_send_keys(&mut fake, &args(&["key:"]), &ctx(OutputFormat::Text)));
        assert_eq!(code.expect_err("refused").code, EXIT_USAGE);
        assert!(fake.sent.is_empty());
    }

    #[test]
    fn jump_prints_the_path_only_when_the_app_did_not_commit_a_cd() {
        let mut fake = Fake::answering(r#"{"path":"/tmp/p","changed":true}"#);
        let (code, text) = drive(|io| jump(&mut fake, io, &[], &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(0));
        assert_eq!(text, "", "a committed cd is silent");

        let mut fake = Fake::answering(r#"{"path":"/tmp/p","changed":false}"#);
        let (code, text) = drive(|io| {
            jump(
                &mut fake,
                io,
                &args(&["proj", "--no-cd"]),
                &ctx(OutputFormat::Text),
            )
        });
        assert_eq!(code, Ok(0));
        assert_eq!(text, "/tmp/p\n");
        let params = params_of(&fake);
        assert_eq!(params.get("query").and_then(Value::as_str), Some("proj"));
        assert_eq!(params.get("noCd").and_then(Value::as_bool), Some(true));
    }

    #[test]
    fn learn_names_what_it_recorded_and_ignore_says_nothing_at_all() {
        let mut fake = Fake::answering(r#"{"path":"/tmp/p"}"#);
        let (code, text) = drive(|io| learn(&mut fake, io, &[], &ctx(OutputFormat::Text)));
        assert_eq!(code, Ok(0));
        assert_eq!(text, "learned: /tmp/p\n");

        let mut fake = Fake::empty();
        let (code, text) = drive(|_| ignore(&mut fake, &args(&["/tmp/p"])));
        assert_eq!(code, Ok(0));
        assert_eq!(text, "");

        let mut fake = Fake::empty();
        let (code, _) = drive(|_| ignore(&mut fake, &[]));
        assert_eq!(code.expect_err("refused").code, EXIT_USAGE);
    }

    #[test]
    fn a_shim_defaults_to_a_new_tab_and_takes_every_placement_the_wire_knows() {
        let mut fake = Fake::empty();
        drop(drive(|_| view(&mut fake, &args(&["/tmp/a.txt"]))));
        assert_eq!(
            params_of(&fake).get("placement").and_then(Value::as_str),
            Some("new-tab")
        );

        for token in crate::clientctl::PLACEMENTS {
            let mut fake = Fake::empty();
            let flag = format!("--{token}");
            let (code, _) = drive(|_| edit(&mut fake, &args(&["/tmp/a.txt", &flag])));
            assert_eq!(code, Ok(0), "{token}");
            assert_eq!(
                params_of(&fake).get("placement").and_then(Value::as_str),
                Some(*token)
            );
        }
    }

    #[test]
    fn a_shim_with_no_target_or_an_unknown_flag_is_a_usage_error() {
        let mut fake = Fake::empty();
        let (code, _) = drive(|_| view(&mut fake, &[]));
        assert_eq!(code.expect_err("refused").code, EXIT_USAGE);

        let mut fake = Fake::empty();
        let (code, _) = drive(|_| view(&mut fake, &args(&["/tmp/a", "--sideways"])));
        let failure = code.expect_err("refused");
        assert!(failure.message.contains("--sideways"), "{failure:?}");
    }

    /// A refusal from the app carries its own words and its own code, straight through.
    #[test]
    fn an_app_refusal_reaches_the_caller_unchanged() {
        let mut fake = Fake::empty();
        fake.failure = Some(Failure::plain("app error: no such pane"));
        let (code, _) = drive(|io| window_list(&mut fake, io, &[], &ctx(OutputFormat::Text)));
        let failure = code.expect_err("refused");
        assert_eq!(failure.code, 1);
        assert_eq!(failure.message, "app error: no such pane");
    }

    /// The `--json` form of a whole result object, which several verbs print straight through.
    #[test]
    fn the_json_form_of_a_result_object_is_compact_and_sorted() {
        let mut fake = Fake::answering(r#"{"path":"/tmp/p","changed":false}"#);
        let (code, text) = drive(|io| jump(&mut fake, io, &[], &ctx(OutputFormat::Json)));
        assert_eq!(code, Ok(0));
        assert_eq!(text, "{\"changed\":false,\"path\":\"/tmp/p\"}\n");
    }

    /// Every builder's optional half, exercised through the flag that fills it.
    #[test]
    fn a_scope_flag_reaches_the_request_and_its_absence_leaves_no_key() {
        let mut fake = Fake::answering(r#"{"tabs":[]}"#);
        drop(drive(|io| {
            tab(
                &mut fake,
                io,
                &args(&["list", "--window", "w1"]),
                &ctx(OutputFormat::Text),
            )
        }));
        assert_eq!(
            params_of(&fake).get("windowId").and_then(Value::as_str),
            Some("w1")
        );

        let mut fake = Fake::answering(r#"{"tabs":[]}"#);
        drop(drive(|io| tab(&mut fake, io, &[], &ctx(OutputFormat::Text))));
        assert_eq!(params_of(&fake).get("windowId"), None);
    }

    #[test]
    fn a_dangling_flag_names_itself_rather_than_reading_past_the_end() {
        for (verb, argv) in [
            ("tab list", vec!["list", "--window"]),
            ("tab badge", vec!["badge", "--kind"]),
        ] {
            let mut fake = Fake::empty();
            let (code, _) = drive(|io| tab(&mut fake, io, &args(&argv), &ctx(OutputFormat::Text)));
            let failure = code.expect_err("refused");
            assert!(failure.message.starts_with(verb), "{failure:?}");
            assert!(failure.message.contains("requires a value"), "{failure:?}");
        }
    }

    /// The `Params` type is what the fake records, so this pins that the fake sees objects rather
    /// than the encoded line — a test that asserted on bytes would be re-testing the golden.
    #[test]
    fn the_fake_records_parameter_objects() {
        let mut fake = Fake::empty();
        drop(fake.call("windows", Map::new()));
        assert_eq!(fake.sent.first().expect("sent").1, Map::new());
    }
}

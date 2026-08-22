//! What a click, a keystroke or a menu item DOES to a detected link.
//!
//! [`link`](crate::link) answers what a span IS; this answers what happens to it. The two are
//! deliberately separate — the detector runs per row per frame and knows nothing about settings,
//! while this runs once per gesture and reads two of them.
//!
//! ## Why it is one table and not one per actuator
//!
//! Four surfaces act on the same link: the ⌘click / ⌘⇧click renderer, the right-click context menu,
//! hint-to-open, and the jump-to row's ↩. Written per surface they drift, and the drift is
//! invisible — every actuator looks right on its own. So every surface resolves through [`action`],
//! and the table below is the whole rule:
//!
//! | target | click | ⌘click | ⌘⇧click |
//! | --- | --- | --- | --- |
//! | path | nothing | open in the code panel / copy / nothing | reveal in Finder / open with the default app |
//! | URL | nothing | open the URL / copy / nothing | copy |
//!
//! A bare click does NOTHING on purpose: it is an absence spelled out, so that "no accidental
//! opens" is a rule with a test rather than a case nobody wrote.
//!
//! ## Where each action actuates, which is half of what the answer says
//!
//! The file is on the HOST — the client never reads the disk — so opening, revealing and the code
//! panel are host round-trips, while a URL and the pasteboard are the client's. [`LinkAction`]
//! names that in each case, so an actuator routes without re-deriving intent.
//!
//! ## The two keyboard affordances are config-INDEPENDENT
//!
//! Hint-to-open (⌘⇧J) and the jump-to row's ↩ MEAN open. They resolve through [`LinkTrigger::Open`]
//! rather than through the ⌘click behaviour: wiring them to the configurable gesture would let
//! `link-cmd-click = copy` silently turn a key that says "open" into one that copies.

use slopdesk_ids::shell_quoting;

use crate::link::DetectedLinkKind;

/// What the user did to the link.
///
/// The three mouse gestures and the four menu items are one enum because they answer one question,
/// and a second enum would need a second table to map it back onto this one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkTrigger {
    /// A bare left-click, which does nothing.
    PlainClick,
    /// `⌘`click, resolved through [`LinkConfig::cmd_click`].
    CommandClick,
    /// `⌘⇧`click, resolved through [`LinkConfig::cmd_shift_click`].
    CommandShiftClick,
    /// An explicit OPEN — the context menu's item, hint-to-open, the jump-to row's `↩`. Never
    /// configurable.
    Open,
    /// The context menu's "Copy Path" / "Copy URL".
    CopyPath,
    /// The context menu's "Reveal in Finder".
    RevealInFinder,
    /// The context menu's "Change Directory Here".
    ChangeDirectory,
}

/// What a `⌘`click does — the `link-cmd-click` setting.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CmdClick {
    /// Open the path in the code panel, or the URL on the client.
    #[default]
    Open,
    /// Copy the path or the URL.
    Copy,
    /// Nothing at all.
    Nothing,
}

/// What a `⌘⇧`click does to a PATH — the `link-cmd-shift-click` setting.
///
/// A URL has no Finder target, so a `⌘⇧`click on one copies whatever this says.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CmdShiftClick {
    /// Reveal it in the host's Finder.
    #[default]
    RevealFinder,
    /// Open it with the host's default application for the type.
    OpenSystemDefault,
}

/// The two settings a gesture reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LinkConfig {
    /// What `⌘`click does.
    pub cmd_click: CmdClick,
    /// What `⌘⇧`click does to a path.
    pub cmd_shift_click: CmdShiftClick,
}

/// The link a gesture landed on, in the three fields the table reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LinkTarget<'a> {
    /// What the detector decided the span is.
    pub kind: DetectedLinkKind,
    /// The matched text, `:line:col` suffix included.
    pub raw: &'a str,
    /// The absolute path when it could be derived PURELY — `None` for a `~` path (needs the host's
    /// `$HOME`) or a plain URL.
    pub resolved_absolute: Option<&'a str>,
}

/// What to do, and WHERE it actuates.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkAction {
    /// Write the path or the URL to the CLIENT pasteboard.
    CopyPathClient(String),
    /// Type a `cd` line into the pane's PTY, verbatim.
    ChangeDirectoryPty(String),
    /// Ask the HOST to open the path in the embedded workbench — the editor the user is looking at
    /// is the client's code panel, not the host's screen. The target keeps its `:line[:col]`.
    OpenCodeHost(String),
    /// Ask the HOST to open the path with its own default handler.
    OpenHost(String),
    /// Ask the HOST to reveal the path in Finder.
    RevealHost(String),
    /// Open the URL on the CLIENT — a URL is host-agnostic.
    OpenUrlClient(String),
    /// Nothing happens.
    Nothing,
}

impl LinkTarget<'_> {
    /// Whether this is a URL rather than a filesystem path.
    ///
    /// A `file://` URL is a PATH here: its filesystem target is what open, reveal and copy act on.
    #[must_use]
    pub const fn is_url(&self) -> bool {
        matches!(self.kind, DetectedLinkKind::Url)
    }

    /// The best path string for a path action: the purely-resolved absolute path, else the matched
    /// text.
    ///
    /// The fallback is not a guess — a `~` path or an unresolved relative one goes to the host
    /// exactly as it was written, and the host expands and validates it. The client never reads the
    /// disk to answer this.
    #[must_use]
    pub fn effective_path(&self) -> &str {
        self.resolved_absolute.unwrap_or(self.raw)
    }

    /// The target for a code-panel open: the best path PLUS the `:line[:col]` the match carried.
    ///
    /// Resolving drops the suffix and the raw text keeps it, so the two are recombined here —
    /// code-server's CLI jumps to the line, and losing it would open the file at the top.
    #[must_use]
    pub fn code_open_target(&self) -> String {
        self.resolved_absolute.map_or_else(
            || self.raw.to_owned(),
            |resolved| {
                let mut target = String::with_capacity(resolved.len() + 8);
                target.push_str(resolved);
                target.push_str(line_col_suffix(self.raw));
                target
            },
        )
    }
}

/// What `trigger` does to `target` under `config`.
#[must_use]
pub fn action(trigger: LinkTrigger, target: LinkTarget<'_>, config: LinkConfig) -> LinkAction {
    match trigger {
        // Spelled out rather than left as a missing case: no accidental opens is a RULE.
        LinkTrigger::PlainClick => LinkAction::Nothing,
        LinkTrigger::CommandClick => {
            match config.cmd_click {
                CmdClick::Open => open(target),
                CmdClick::Copy => copy(target),
                CmdClick::Nothing => LinkAction::Nothing,
            }
        },
        LinkTrigger::CommandShiftClick => {
            if target.is_url() {
                // A URL has no Finder target, so the path-oriented setting cannot apply to it.
                return copy(target);
            }
            match config.cmd_shift_click {
                CmdShiftClick::RevealFinder => LinkAction::RevealHost(target.effective_path().to_owned()),
                CmdShiftClick::OpenSystemDefault => LinkAction::OpenHost(target.effective_path().to_owned()),
            }
        },
        LinkTrigger::Open => open(target),
        LinkTrigger::CopyPath => copy(target),
        // The menu offers neither for a URL; answering `Nothing` keeps the mapping total anyway.
        LinkTrigger::RevealInFinder | LinkTrigger::ChangeDirectory if target.is_url() => LinkAction::Nothing,
        LinkTrigger::RevealInFinder => LinkAction::RevealHost(target.effective_path().to_owned()),
        LinkTrigger::ChangeDirectory => LinkAction::ChangeDirectoryPty(target.effective_path().to_owned()),
    }
}

/// The shell line that points a PTY at `path`, falling back to its PARENT when `path` is a FILE.
///
/// A bare `cd '<file>'` fails with `cd: not a directory`, which is exactly the headline case — a
/// compiler's `path:line:col`, whose suffix the detector already stripped, leaving a file. So the
/// line tries the path and only then its directory. For a real directory the first `cd` succeeds
/// and the fallback never runs.
///
/// Both operands are single-quoted, so a space, a `$` or a `;` lands literally. Typed VERBATIM:
/// this string never goes through the key-token parser, where a `<` in a path would start a token.
#[must_use]
pub fn change_directory_command_line(path: &str) -> String {
    format!(
        "cd {} 2>/dev/null || cd {}\n",
        shell_quoting::single_quoted(path),
        shell_quoting::single_quoted(posix_parent(path)),
    )
}

/// POSIX `dirname`, computed purely: the path with its last component dropped.
///
/// A trailing slash is ignored (`/a/b/c/` → `/a/b`), a root-level entry's parent is `/`, a bare
/// name with no slash is `.`, and root stays root. No disk access — the answer is a fact about the
/// STRING.
#[must_use]
pub fn posix_parent(path: &str) -> &str {
    let bytes = path.as_bytes();
    let mut end = bytes.len();
    // Drop a trailing slash run, but never collapse root itself.
    while end > 1 && bytes.get(end - 1) == Some(&b'/') {
        end -= 1;
    }
    let trimmed = path.get(..end).unwrap_or(path);
    let Some(slash) = trimmed.rfind('/') else {
        return ".";
    };
    if slash == 0 {
        return "/";
    }
    trimmed.get(..slash).unwrap_or(trimmed)
}

/// The trailing `:line[:col]` of `text`, leading colon included, or `""`.
///
/// At most two colon-number runs, ASCII digits only — the same shape the detector's splitter
/// accepts, so the suffix it removed is the suffix this puts back. A "suffix" that consumes the
/// whole text has no path in front of it and is not one.
#[must_use]
pub fn line_col_suffix(text: &str) -> &str {
    let bytes = text.as_bytes();
    // Scanning bytes rather than characters is exact here and not an approximation: neither an ASCII
    // digit nor `:` can appear inside a multi-byte sequence, so every index this lands on is a
    // character boundary.
    let run_start = |end: usize| -> Option<usize> {
        let mut index = end;
        let mut saw_digit = false;
        while index > 0 && bytes.get(index - 1).is_some_and(u8::is_ascii_digit) {
            index -= 1;
            saw_digit = true;
        }
        (saw_digit && index > 0 && bytes.get(index - 1) == Some(&b':')).then(|| index - 1)
    };
    let Some(col_start) = run_start(bytes.len()) else {
        return "";
    };
    let start = run_start(col_start).unwrap_or(col_start);
    if start == 0 {
        return "";
    }
    text.get(start..).unwrap_or_default()
}

/// Opening: a URL on the client, a path in the code panel.
fn open(target: LinkTarget<'_>) -> LinkAction {
    if target.is_url() {
        LinkAction::OpenUrlClient(target.raw.to_owned())
    } else {
        LinkAction::OpenCodeHost(target.code_open_target())
    }
}

/// Copying: the URL as written, a path as resolved.
fn copy(target: LinkTarget<'_>) -> LinkAction {
    if target.is_url() {
        LinkAction::CopyPathClient(target.raw.to_owned())
    } else {
        LinkAction::CopyPathClient(target.effective_path().to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path<'a>(raw: &'a str, resolved: Option<&'static str>) -> LinkTarget<'a> {
        LinkTarget {
            kind: DetectedLinkKind::AbsolutePath,
            raw,
            resolved_absolute: resolved,
        }
    }

    fn url(raw: &str) -> LinkTarget<'_> {
        LinkTarget {
            kind: DetectedLinkKind::Url,
            raw,
            resolved_absolute: None,
        }
    }

    #[test]
    fn a_bare_click_never_opens_anything() {
        let config = LinkConfig::default();
        assert_eq!(
            action(
                LinkTrigger::PlainClick,
                path("/a/b.swift", Some("/a/b.swift")),
                config
            ),
            LinkAction::Nothing,
        );
        assert_eq!(
            action(LinkTrigger::PlainClick, url("https://example.com"), config),
            LinkAction::Nothing,
        );
    }

    #[test]
    fn command_click_follows_its_setting() {
        let target = path("/a/b.swift:12", Some("/a/b.swift"));
        let mut config = LinkConfig::default();
        assert_eq!(
            action(LinkTrigger::CommandClick, target, config),
            LinkAction::OpenCodeHost("/a/b.swift:12".to_owned()),
        );
        config.cmd_click = CmdClick::Copy;
        assert_eq!(
            action(LinkTrigger::CommandClick, target, config),
            LinkAction::CopyPathClient("/a/b.swift".to_owned()),
        );
        config.cmd_click = CmdClick::Nothing;
        assert_eq!(
            action(LinkTrigger::CommandClick, target, config),
            LinkAction::Nothing
        );
    }

    #[test]
    fn a_url_ignores_the_path_oriented_shift_setting() {
        let target = url("https://example.com");
        let mut config = LinkConfig::default();
        assert_eq!(
            action(LinkTrigger::CommandShiftClick, target, config),
            LinkAction::CopyPathClient("https://example.com".to_owned()),
        );
        config.cmd_shift_click = CmdShiftClick::OpenSystemDefault;
        assert_eq!(
            action(LinkTrigger::CommandShiftClick, target, config),
            LinkAction::CopyPathClient("https://example.com".to_owned()),
        );
    }

    #[test]
    fn shift_click_on_a_path_reveals_or_opens_on_the_host() {
        let target = path("~/notes.md", None);
        let mut config = LinkConfig::default();
        assert_eq!(
            action(LinkTrigger::CommandShiftClick, target, config),
            LinkAction::RevealHost("~/notes.md".to_owned()),
        );
        config.cmd_shift_click = CmdShiftClick::OpenSystemDefault;
        assert_eq!(
            action(LinkTrigger::CommandShiftClick, target, config),
            LinkAction::OpenHost("~/notes.md".to_owned()),
        );
    }

    #[test]
    fn an_explicit_open_ignores_every_setting() {
        let config = LinkConfig {
            cmd_click: CmdClick::Nothing,
            cmd_shift_click: CmdShiftClick::OpenSystemDefault,
        };
        assert_eq!(
            action(LinkTrigger::Open, path("/a/b.swift", Some("/a/b.swift")), config),
            LinkAction::OpenCodeHost("/a/b.swift".to_owned()),
        );
        assert_eq!(
            action(LinkTrigger::Open, url("https://example.com"), config),
            LinkAction::OpenUrlClient("https://example.com".to_owned()),
        );
    }

    #[test]
    fn the_menu_items_that_have_no_url_meaning_answer_nothing() {
        let config = LinkConfig::default();
        let target = url("https://example.com");
        assert_eq!(
            action(LinkTrigger::RevealInFinder, target, config),
            LinkAction::Nothing
        );
        assert_eq!(
            action(LinkTrigger::ChangeDirectory, target, config),
            LinkAction::Nothing
        );
        assert_eq!(
            action(LinkTrigger::ChangeDirectory, path("/a/b", Some("/a/b")), config),
            LinkAction::ChangeDirectoryPty("/a/b".to_owned()),
        );
    }

    #[test]
    fn the_code_target_puts_back_the_line_the_resolver_dropped() {
        assert_eq!(
            path("src/main.rs:12:5", Some("/repo/src/main.rs")).code_open_target(),
            "/repo/src/main.rs:12:5",
        );
        assert_eq!(path("~/a.rs:9", None).code_open_target(), "~/a.rs:9");
    }

    #[test]
    fn a_suffix_is_at_most_two_colon_runs_and_never_the_whole_text() {
        assert_eq!(line_col_suffix("a.swift:12:5"), ":12:5");
        assert_eq!(line_col_suffix("a.swift:12"), ":12");
        assert_eq!(line_col_suffix("a.swift"), "");
        assert_eq!(line_col_suffix(":12"), "");
        assert_eq!(line_col_suffix("a.swift:12:5:7"), ":5:7");
        assert_eq!(line_col_suffix("thư-mục/tệp.swift:3"), ":3");
    }

    #[test]
    fn the_parent_is_a_fact_about_the_string() {
        assert_eq!(posix_parent("/a/b/c"), "/a/b");
        assert_eq!(posix_parent("/a/b/c/"), "/a/b");
        assert_eq!(posix_parent("/a"), "/");
        assert_eq!(posix_parent("/"), "/");
        assert_eq!(posix_parent("file"), ".");
        assert_eq!(posix_parent(""), ".");
    }

    #[test]
    fn the_cd_line_tries_the_path_then_its_directory() {
        assert_eq!(
            change_directory_command_line("/a/b c/d.swift"),
            "cd '/a/b c/d.swift' 2>/dev/null || cd '/a/b c'\n",
        );
        assert_eq!(
            change_directory_command_line("/it's/here"),
            "cd '/it'\\''s/here' 2>/dev/null || cd '/it'\\''s'\n",
        );
    }
}

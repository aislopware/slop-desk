//! `--list`: what this host will share, in an order a person can read.
//!
//! The one-shot that answers a question and exits. It binds no socket and starts no stream, which
//! is why `main` runs it before anything with an effect — an operator asking what is capturable
//! must not have to take a port to find out.
//!
//! ## Two orders, and this is neither of the interesting ones
//! `slopdesk_video::window_list` decides the STREAMABLE order — what the picker offers a client,
//! on-screen first so the cap evicts the off-screen tail. That is a rule, it is pinned, and nothing
//! here touches it. What this module picks is a READING order for a terminal: owning app, then
//! window id, so the same machine prints the same list twice in a row.

use core::fmt;

/// One row of the listing: everything the format below needs, and nothing that holds a framework
/// object.
///
/// A value type on purpose. The framework query answers objects whose lifetime is the query's, and
/// a listing that borrowed them would keep the whole snapshot alive to print a line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    /// The `CGWindowID`.
    pub id: u32,
    /// The owning application's display name, or `None` when the window has no owner.
    pub app: Option<String>,
    /// The window's own title, or `None` when it has none.
    pub title: Option<String>,
    /// Width in points, rounded the way the Swift's `Int(_:)` truncated.
    pub width: i64,
    /// Height in points, same rule.
    pub height: i64,
}

/// How wide the app column is padded to, so the titles line up in a terminal.
const APP_COLUMN: usize = 22;

/// What an unowned window prints as. A window with no owning application is real — the window
/// server has a few — and a blank column would read as a formatting bug.
const NO_APP: &str = "?";

/// What a window with no usable title prints as.
///
/// EMPTY and ABSENT fold together here and only here: `slopdesk-apple-sck` keeps them apart because
/// they are different facts, and this is the presentation layer that decides they read the same.
const NO_TITLE: &str = "(untitled)";

impl fmt::Display for Row {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let app = self.app.as_deref().unwrap_or(NO_APP);
        let title = match self.title.as_deref() {
            Some(text) if !text.is_empty() => text,
            _ => NO_TITLE,
        };
        let size = format!("{}x{}", self.width, self.height);
        write!(f, "  id={:<8}  {app:<APP_COLUMN$}  {title}  [{size}]", self.id)
    }
}

/// Sorts `rows` into the reading order: owning app, then window id.
///
/// An unowned window sorts as if its app name were empty, which is what the Swift's
/// `?? ""` did — so the unowned ones lead rather than trailing, and that is deliberate: they are
/// the ones an operator is usually hunting for.
pub fn arrange(rows: &mut [Row]) {
    rows.sort_by(|left, right| {
        let left_app = left.app.as_deref().unwrap_or_default();
        let right_app = right.app.as_deref().unwrap_or_default();
        left_app.cmp(right_app).then(left.id.cmp(&right.id))
    });
}

/// The whole listing as the lines to print, header included.
///
/// Answers the empty case in full rather than leaving the caller to special-case it: an empty list
/// on this path is almost always a missing Screen-Recording grant or an SSH session, and saying so
/// is the difference between a two-second fix and an hour.
#[must_use]
pub fn render(mut rows: Vec<Row>) -> Vec<String> {
    if rows.is_empty() {
        return vec![
            "no shareable windows (grant Screen-Recording permission, and ensure a GUI session)".to_owned(),
        ];
    }
    arrange(&mut rows);
    let mut lines = Vec::with_capacity(rows.len() + 1);
    lines.push(format!("shareable windows ({}):", rows.len()));
    lines.extend(rows.iter().map(ToString::to_string));
    lines
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::expect_used,
        reason = "the rendered lines are asserted by position, which is what makes it a listing test, and a \
                  panic in a test is the failure report"
    )]

    use super::{Row, render};

    fn row(id: u32, app: Option<&str>, title: Option<&str>) -> Row {
        Row {
            id,
            app: app.map(ToOwned::to_owned),
            title: title.map(ToOwned::to_owned),
            width: 1440,
            height: 900,
        }
    }

    #[test]
    fn an_empty_host_says_why_rather_than_printing_a_header_over_nothing() {
        let lines = render(Vec::new());
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("Screen-Recording"));
    }

    #[test]
    fn the_reading_order_is_app_then_id() {
        let lines = render(vec![
            row(30, Some("Safari"), Some("b")),
            row(10, Some("Safari"), Some("a")),
            row(20, Some("Ghostty"), Some("c")),
        ]);
        assert_eq!(lines[0], "shareable windows (3):");
        assert!(lines[1].contains("id=20"), "Ghostty sorts before Safari");
        assert!(lines[2].contains("id=10"), "then Safari by ascending id");
        assert!(lines[3].contains("id=30"));
    }

    #[test]
    fn an_unowned_window_leads_and_prints_a_marker_rather_than_a_blank_column() {
        let lines = render(vec![row(10, Some("Ghostty"), Some("a")), row(9, None, Some("b"))]);
        assert!(lines[1].contains("id=9"), "an empty app name sorts first");
        assert!(lines[1].contains(" ?  "), "and prints as `?`, not as nothing");
    }

    #[test]
    fn an_empty_title_and_an_absent_one_read_the_same_here_and_only_here() {
        let lines = render(vec![
            row(10, Some("Ghostty"), Some("")),
            row(11, Some("Ghostty"), None),
        ]);
        assert!(lines[1].contains("(untitled)"));
        assert!(lines[2].contains("(untitled)"));
    }

    #[test]
    fn the_app_column_is_padded_so_the_titles_line_up() {
        let lines = render(vec![
            row(10, Some("Ghostty"), Some("a")),
            row(11, Some("X"), Some("b")),
        ]);
        let first = lines[1].find("  a  ").expect("the title is on the line");
        let second = lines[2].find("  b  ").expect("the title is on the line");
        assert_eq!(
            first, second,
            "two app names of different lengths must not shift the title"
        );
    }

    #[test]
    fn the_size_is_the_frame_in_points() {
        let lines = render(vec![row(10, Some("Ghostty"), Some("a"))]);
        assert!(lines[1].ends_with("[1440x900]"));
    }
}

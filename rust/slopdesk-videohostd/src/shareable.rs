//! The window-server query behind [`crate::list`], and the one place it happens.
//!
//! Split from the rendering deliberately. `ScreenCaptureKit` needs a real window server and a
//! Screen-Recording grant — it HANGS headlessly rather than failing — so nothing in this file can
//! be reached by a test. Everything that decides what the answer LOOKS like lives next door, where
//! a test can reach all of it. That split is the whole reason `list.rs` takes values.

use slopdesk_apple_sck::ShareableContent;

use crate::list::Row;

/// Every window this host will share, as the values a listing is built from.
///
/// Desktop windows are INCLUDED (`exclude_desktop_windows: false`) and off-screen ones are not
/// (`on_screen_windows_only: true`) — the pair the Swift asked with, and the pair a listing wants:
/// a person running `--list` is looking for something they can see.
///
/// An empty answer is not distinguished from a failed query, because the caller's response is the
/// same and [`crate::list::render`] already says what both usually mean.
///
/// ⚠️ Requires a window server and a Screen-Recording grant.
#[must_use]
pub fn rows() -> Vec<Row> {
    let Some(content) = ShareableContent::current(false, true) else {
        return Vec::new();
    };
    content
        .windows()
        .into_iter()
        .map(|window| {
            let frame = window.frame();
            #[expect(
                clippy::cast_possible_truncation,
                reason = "TRUNCATING is the rule: `Int(w.frame.width)` printed these numbers, and a listing \
                          that disagreed with the capture path's own arithmetic by a point would be a bug \
                          report nobody could reproduce"
            )]
            Row {
                id: window.id(),
                app: window.app_name(),
                title: window.title(),
                // Truncating, not rounding: `Int(w.frame.width)` is what printed these numbers, and
                // a listing that disagreed with the capture path's own arithmetic by a point would
                // be a bug report nobody could reproduce.
                width: frame.width() as i64,
                height: frame.height() as i64,
            }
        })
        .collect()
}

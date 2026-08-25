//! When a project's git line is re-probed, and which section header a reply is booked under.
//!
//! The sidebar prints one git line per PROJECT section — branch, ahead/behind, dirty count — and
//! the client keeps it fresh from three sources: a poll on the ~3 s snapshot edge, a probe fired by
//! a command completing or a `cd`, and the host's own FSEvents push. [`git_line`](crate::git_line)
//! decides what that line SAYS. This decides when it is asked for and where the answer lands.
//!
//! ## Two decisions, and they are not the same one
//!
//! **Cadence** ([`refresh_due`]) is about the clock: a project whose line was read a moment ago is
//! not read again, and how long "a moment" is depends on whether anybody is looking at that project
//! and whether the host is already pushing. Getting it wrong turns a snapshot cadence into a
//! `git status` poll — N panes × one subprocess spawn each × every three seconds.
//!
//! **Booking** ([`booking`], [`pushed_booking`]) is about identity: a reply carries the repo's
//! TOPLEVEL, and the section it must be filed under is that toplevel's normalized key — not
//! necessarily the key of the pane that asked. The two can differ for one bounded interval, and the
//! [`Booking::alias`] flag is what keeps the interim section's header correct across it.
//!
//! ## What is composed rather than re-spelled
//!
//! The section key a pane belongs to is [`slopdesk_tree::tab_ordering::project_key_of`]'s
//! precedence — host-pushed key, else the cwd, with a plugin-cache directory guarded out of both —
//! run through [`slopdesk_tree::tab_ordering::normalized_project_key`] so it equals the BUCKETING
//! key the rail already sorts by. Neither is re-written here; a second spelling of either is the
//! drift pair the one-implementation rule exists for.
//!
//! ## The two clocks stay outside
//!
//! Nothing here holds a `Date`. The caller has both — when it last fetched, when the last push
//! landed — and crosses the two ELAPSED intervals, exactly as [`pane_facts`](crate::pane_facts)
//! does. A rule that owned a clock could not be tested without one.

use slopdesk_tree::session::PaneSpec;
use slopdesk_tree::tab_ordering;

/// How long a BACKGROUND project's header line stays fresh before the snapshot edge may re-fetch
/// it, in seconds.
///
/// Long enough that the ~3 s snapshot cadence is never a git-status poll, short enough that every
/// visible section self-heals within a minute.
pub const STALE_WINDOW: f64 = 60.0;

/// The tighter window for the ACTIVE project — the section the focused pane sits in, in seconds.
///
/// The header the user is most likely acting on tracks external changes — an editor save, a commit
/// in another terminal — within seconds, and it is still only about four subprocess spawns per
/// window on the host.
pub const STALE_WINDOW_ACTIVE_PROJECT: f64 = 15.0;

/// The poll back-off while HOST PUSHES are fresh, in seconds.
///
/// The host's watcher already delivers event-driven updates, so the poll degrades to a slow safety
/// net — and re-arms itself the moment pushes stop arriving for this long.
pub const PUSH_GRACE_WINDOW: f64 = 300.0;

/// What the caller knows about one project's git line right now.
///
/// Every field is the caller's, and deliberately so: the in-flight set is a set of keys it owns,
/// the two intervals come off its clock, and whether this is the active project is a question about
/// a focus it holds.
#[derive(Clone, Copy, Debug)]
pub struct Freshness {
    /// Whether a probe for this project is already out. The de-dupe is BY PROJECT: N same-repo
    /// panes completing together collapse to one RPC, because `git status` output is repo-root
    /// relative and any pane in the project answers for all of them.
    pub in_flight: bool,
    /// Seconds since this project's line was last fetched, or `None` for a project with no line
    /// yet — the initial populate, which is always due.
    pub since_fetch: Option<f64>,
    /// Seconds since the last HOST PUSH for this project, or `None` if none has ever landed.
    pub since_push: Option<f64>,
    /// Whether this is the FOCUSED pane's project.
    pub active_project: bool,
}

/// Where a reply is filed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Booking {
    /// The section key the reading is the truth for.
    pub primary: String,
    /// Whether to ALSO file it under the caller's own fallback key.
    ///
    /// A flag rather than a second string, because the only value it could ever be is the fallback
    /// the caller passed in — sending it back would be handing somebody their own word.
    pub alias: bool,
}

/// The staleness window in force for a project, in seconds.
///
/// A fresh push wins over everything: the watcher is a better source than the poll, so while it is
/// live the poll's only job is to notice that it stopped. Otherwise the focused project's tighter
/// window wins, and a background project takes the long one.
#[must_use]
pub fn stale_window(since_push: Option<f64>, active_project: bool) -> f64 {
    if since_push.is_some_and(|elapsed| elapsed < PUSH_GRACE_WINDOW) {
        PUSH_GRACE_WINDOW
    } else if active_project {
        STALE_WINDOW_ACTIVE_PROJECT
    } else {
        STALE_WINDOW
    }
}

/// Whether the snapshot edge should re-fetch this project's git line.
///
/// Never while a probe is out — a second RPC would answer the same question the first one is
/// already answering. Always for a project with no line at all, which is the initial populate.
/// Otherwise once the line is older than [`stale_window`].
#[must_use]
pub fn refresh_due(freshness: Freshness) -> bool {
    if freshness.in_flight {
        return false;
    }
    let Some(since_fetch) = freshness.since_fetch else {
        return true;
    };
    since_fetch > stale_window(freshness.since_push, freshness.active_project)
}

/// A pane's SECTION key for git bookkeeping: the project-key precedence, normalized to the rail's
/// bucketing key. `None` for a pane with no section identity yet, which gets no git bookkeeping.
#[must_use]
pub fn section_key(host_key: Option<&str>, cwd: Option<&str>) -> Option<String> {
    let resolved = tab_ordering::project_key_of(host_key, cwd)?;
    tab_ordering::normalized_project_key(Some(resolved.as_str()))
}

/// A pane's HOST-PUSHED key alone, RAW — `None` while the pane is still on its cwd fallback.
///
/// Not normalized, because its readers compare it against the host's own word and use it as a
/// filesystem root; it is [`section_key`] that answers the bucketing question.
///
/// The same precedence with no cwd to fall back to, which is exactly what "the first leg alone"
/// means — spelling the guards again here would be the second copy.
#[must_use]
pub fn host_pushed_key(host_key: Option<&str>) -> Option<String> {
    tab_ordering::project_key_of(host_key, None)
}

/// The key a probe's reply may be ALIASED under, or `None` when it may not be aliased at all.
///
/// Only a pane still sectioned by its CWD is eligible. A host-pushed key can be stale across a
/// cross-repo `cd` that has not been re-pushed yet — nothing on the client invalidates it, and the
/// host re-pushes asynchronously — and booking the NEW repo's reply under the OLD repo's key would
/// overwrite an unrelated section's genuinely-correct header.
#[must_use]
pub fn alias_candidate(host_key: Option<&str>, cwd: Option<&str>) -> Option<String> {
    if host_pushed_key(host_key).is_some() {
        return None;
    }
    section_key(host_key, cwd)
}

/// Whether `fallback` is a STRICT subdirectory of section `key`.
///
/// The alias backstop. The alias must sit inside the toplevel's own subtree — a cwd-fallback subdir
/// of THIS repo — because any other relation means a stale or foreign key, and booking there would
/// poison an unrelated section's header.
///
/// Deliberately NOT [`store_seed::covers`](crate::store_seed::covers), which admits the equal case
/// and tolerates a key written with a trailing slash. This one is strict on both counts, and the
/// difference is observable at the filesystem root: `/` is the one normalized key that keeps a
/// trailing slash, and a section at `/` must not swallow every path on the machine as its own
/// subdirectory.
#[must_use]
pub fn aliases_under(key: &str, fallback: &str) -> bool {
    let mut prefix = key.to_owned();
    prefix.push('/');
    fallback != key && fallback.starts_with(&prefix)
}

/// Where a freshly-fetched reading is filed, or `None` to DROP the whole reading.
///
/// - A `toplevel` that looks like a plugin manager's cache directory is dropped entirely. The
///   reading was taken while the shell was transiently inside one, so its branch and its counts are
///   that plugin's repo, not the user's project — and half of it is not better than none of it. The
///   next completion edge re-probes at the settled directory.
/// - The primary key is the toplevel's normalized key, falling back to the probing pane's own
///   section key when the directory is not a repo at all. That fallback is what lets a no-repo
///   directory book its "clean, no repo" reading, so the cadence backs off for that section too
///   instead of re-probing it every three seconds forever.
/// - The alias fires when the probing pane is still sectioned by a cwd INSIDE the repo — the host's
///   key for it has not landed — so the interim section's header is already correct. Reconcile
///   prunes the alias once the section re-keys.
///
/// A BLANK `fallback` is read as no fallback. The only thing that ever reaches this argument is a
/// [`section_key`], which is either absent or non-empty, so the two cases coincide at every real
/// call — and they must, because a blank string and an absent one are the same `(ptr, len)` pair
/// once this rule is reached through the C door.
#[must_use]
pub fn booking(toplevel: &str, fallback: Option<&str>) -> Option<Booking> {
    if PaneSpec::looks_like_transient_plugin_cwd(toplevel) {
        return None;
    }
    let fallback = fallback.filter(|key| !key.is_empty());
    let primary = match tab_ordering::normalized_project_key(Some(toplevel)) {
        Some(key) => key,
        None => fallback?.to_owned(),
    };
    let alias = fallback.is_some_and(|key| aliases_under(&primary, key));
    Some(Booking { primary, alias })
}

/// Where a HOST-PUSHED reading is filed, or `None` to drop it.
///
/// The push carries a repo root the host resolved, so there is no fallback leg and no alias: the
/// watcher watches one repository and names it. The plugin-cache guard still stands — the host's
/// own resolver can race a plugin manager's `cd` exactly as a client-side probe can.
#[must_use]
pub fn pushed_booking(repo_root: &str) -> Option<String> {
    if PaneSpec::looks_like_transient_plugin_cwd(repo_root) {
        return None;
    }
    tab_ordering::normalized_project_key(Some(repo_root))
}

#[cfg(test)]
mod tests {
    use super::{
        Booking, Freshness, PUSH_GRACE_WINDOW, STALE_WINDOW, STALE_WINDOW_ACTIVE_PROJECT, alias_candidate,
        aliases_under, booking, host_pushed_key, pushed_booking, refresh_due, section_key, stale_window,
    };

    /// A project with no line at all is always due — that is the initial populate.
    #[test]
    fn a_project_with_no_line_is_always_due() {
        assert!(refresh_due(Freshness {
            in_flight: false,
            since_fetch: None,
            since_push: None,
            active_project: false,
        }));
    }

    /// A probe already out suppresses everything, including the initial populate.
    #[test]
    fn an_outstanding_probe_suppresses_the_edge() {
        assert!(!refresh_due(Freshness {
            in_flight: true,
            since_fetch: None,
            since_push: None,
            active_project: true,
        }));
    }

    /// Bit-exact equality, which is the only kind worth asserting about a window: these are
    /// constants crossing a boundary, not the result of any arithmetic that could round.
    fn same(left: f64, right: f64) -> bool {
        left.to_bits() == right.to_bits()
    }

    /// The three windows, each in the condition that selects it.
    #[test]
    fn the_window_ladder_picks_the_tightest_reason() {
        assert!(same(stale_window(None, false), STALE_WINDOW));
        assert!(same(stale_window(None, true), STALE_WINDOW_ACTIVE_PROJECT));
        assert!(same(stale_window(Some(1.0), true), PUSH_GRACE_WINDOW));
        assert!(same(stale_window(Some(1.0), false), PUSH_GRACE_WINDOW));
        assert!(
            same(
                stale_window(Some(PUSH_GRACE_WINDOW), true),
                STALE_WINDOW_ACTIVE_PROJECT
            ),
            "a push exactly at the grace boundary has expired",
        );
    }

    /// The comparison is STRICTLY older than the window — a line exactly at it stands.
    #[test]
    fn the_staleness_test_is_strict() {
        let at = |since_fetch| {
            refresh_due(Freshness {
                in_flight: false,
                since_fetch: Some(since_fetch),
                since_push: None,
                active_project: false,
            })
        };
        assert!(!at(STALE_WINDOW));
        assert!(at(STALE_WINDOW + 0.5));
        assert!(!at(0.0));
    }

    /// The active project re-fetches four times sooner than a background one.
    #[test]
    fn the_active_project_refetches_sooner() {
        let at = |active_project| {
            refresh_due(Freshness {
                in_flight: false,
                since_fetch: Some(20.0),
                since_push: None,
                active_project,
            })
        };
        assert!(at(true));
        assert!(!at(false));
    }

    /// The host-pushed key wins the precedence, and a plugin-cache reading loses it.
    #[test]
    fn the_section_key_follows_the_project_precedence() {
        assert_eq!(
            section_key(Some("/work/alpha"), Some("/work/alpha/src")),
            Some("/work/alpha".to_owned()),
        );
        assert_eq!(
            section_key(Some(""), Some("/work/alpha/src")),
            Some("/work/alpha/src".to_owned()),
            "an empty host key falls through to the cwd",
        );
        assert_eq!(
            section_key(
                Some("/cache/zsh-users---zsh-syntax-highlighting"),
                Some("/work/alpha")
            ),
            Some("/work/alpha".to_owned()),
            "a plugin-cache host key falls through to the cwd",
        );
        assert_eq!(section_key(None, Some("/cache/owner---repo")), None);
        assert_eq!(section_key(None, None), None);
    }

    /// The section key is NORMALIZED; the host-pushed key is raw.
    #[test]
    fn only_the_section_key_is_normalized() {
        assert_eq!(
            section_key(Some("/work/alpha/"), None),
            Some("/work/alpha".to_owned())
        );
        assert_eq!(
            host_pushed_key(Some("/work/alpha/")),
            Some("/work/alpha/".to_owned())
        );
        assert_eq!(host_pushed_key(None), None);
        assert_eq!(host_pushed_key(Some("")), None);
        assert_eq!(host_pushed_key(Some("/cache/owner---repo")), None);
    }

    /// Only a pane still on its cwd fallback offers an alias key.
    #[test]
    fn a_host_keyed_pane_offers_no_alias() {
        assert_eq!(
            alias_candidate(Some("/work/alpha"), Some("/work/alpha/src")),
            None
        );
        assert_eq!(
            alias_candidate(None, Some("/work/alpha/src")),
            Some("/work/alpha/src".to_owned()),
        );
    }

    /// A reading taken inside a plugin cache is dropped whole, never half-booked.
    #[test]
    fn a_plugin_cache_reading_is_dropped_whole() {
        assert_eq!(
            booking("/cache/zsh-users---zsh-autosuggestions", Some("/work/alpha")),
            None
        );
        assert_eq!(pushed_booking("/cache/owner---repo"), None);
    }

    /// A repo reply books under its toplevel, and aliases a cwd fallback inside that repo.
    #[test]
    fn a_reply_aliases_the_probing_panes_subdirectory() {
        assert_eq!(
            booking("/work/alpha", Some("/work/alpha/src")),
            Some(Booking {
                primary: "/work/alpha".to_owned(),
                alias: true
            }),
        );
        assert_eq!(
            booking("/work/alpha", Some("/work/alpha")),
            Some(Booking {
                primary: "/work/alpha".to_owned(),
                alias: false
            }),
            "the fallback IS the primary — one booking, not two",
        );
        assert_eq!(
            booking("/work/alpha", Some("/work/beta/src")),
            Some(Booking {
                primary: "/work/alpha".to_owned(),
                alias: false
            }),
            "a foreign key never rides along",
        );
        assert_eq!(
            booking("/work/alpha", None),
            Some(Booking {
                primary: "/work/alpha".to_owned(),
                alias: false
            }),
        );
    }

    /// A directory that is no repo at all books under the probing pane's own key.
    #[test]
    fn a_no_repo_reading_books_under_the_fallback() {
        assert_eq!(
            booking("", Some("/work/loose")),
            Some(Booking {
                primary: "/work/loose".to_owned(),
                alias: false
            }),
        );
        assert_eq!(booking("", None), None, "nothing to file it under");
        assert_eq!(booking("", Some("")), None);
    }

    /// The alias test is strict on both counts, and the filesystem root is the case that proves it.
    #[test]
    fn the_alias_test_is_a_strict_subtree() {
        assert!(aliases_under("/work/alpha", "/work/alpha/src"));
        assert!(!aliases_under("/work/alpha", "/work/alpha"));
        assert!(!aliases_under("/work/alpha", "/work/alphabet"));
        assert!(
            !aliases_under("/", "/work"),
            "a section at the root owns no subtree here"
        );
    }

    /// A push books under the repo root the host named, normalized.
    #[test]
    fn a_push_books_under_its_repo_root() {
        assert_eq!(pushed_booking("/work/alpha/"), Some("/work/alpha".to_owned()));
        assert_eq!(pushed_booking(""), None);
    }
}

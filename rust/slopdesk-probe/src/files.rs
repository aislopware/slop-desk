//! The `listDirectory`, `listAgentSessions` and `readAgentSession` verbs.
//!
//! Every path reaching these has already been CONFINED by the pure Swift builder against the pane's
//! cwd subtree — that check is the client-facing contract and it stays where the request is
//! decoded. What is here is the second layer: this program re-confines a session id to the known
//! roots itself ([`read_session`]), because a read that can be pointed anywhere is worth two checks
//! even when one of them is somebody else's job.

use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde_json::{Value, json};

use crate::run;

/// The directory-listing cap. A second backstop under the builder's own.
pub const MAX_DIR_ENTRIES: usize = 4096;

/// The session-list cap.
pub const MAX_SESSIONS: usize = 512;

/// One directory entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirEntry {
    /// Whether it is a directory.
    pub is_dir: bool,
    /// The leaf name, never a path.
    pub name: String,
}

/// One discovered agent session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    /// 0 = claude, 1 = codex, 2 = opencode — carried as a raw byte, forward-tolerantly.
    pub kind: u8,
    /// The absolute file path, which is also the id the client passes back to read it.
    pub id: String,
    /// A human-readable title. Always empty today; the field exists for a session viewer to fill.
    pub title: String,
    /// The project cwd the session belongs to.
    pub cwd: String,
    /// Last-modified milliseconds since the epoch. Newest first once sorted.
    pub mtime_ms: i64,
}

/// One level of `path`, sorted by name. `None` when it is not a directory — the verb's `.notFound`.
///
/// Sorted here rather than at the client because the sort is what makes a listing stable across two
/// requests, and `read_dir` order is whatever the filesystem felt like.
#[must_use]
pub fn list_directory(path: &Path) -> Option<Vec<DirEntry>> {
    if !path.is_dir() {
        return None;
    }
    let mut entries: Vec<DirEntry> = std::fs::read_dir(path)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| {
            DirEntry {
                // `is_dir` follows symlinks, which is what a person clicking a folder means by it.
                is_dir: entry.path().is_dir(),
                name: entry.file_name().to_string_lossy().into_owned(),
            }
        })
        .collect();
    entries.sort_by(|left, right| left.name.cmp(&right.name));
    entries.truncate(MAX_DIR_ENTRIES);
    Some(entries)
}

/// Claude Code's on-disk project-slug convention: every character that is not an ASCII letter or
/// digit becomes `-`, one dash per character, with no collapsing of runs.
///
/// Verified against a real `~/.claude/projects` listing — `/Users/me/.config/nvim` stores as
/// `-Users-me--config-nvim`, the leading `.` of `.config` becoming its OWN dash next to the `/`'s.
///
/// The unit is a UTF-16 code unit, not a character, because the producer is JavaScript and its
/// `replace(/[^a-zA-Z0-9]/g, '-')` runs per code unit. The Swift this replaces used Swift
/// Characters, i.e. grapheme clusters, so it produced ONE dash where Claude Code produces two for
/// any astral character and for a base+combining pair — and a slug that does not match is a project
/// whose sessions are silently undiscoverable. ASCII is identical either way, which is why the
/// divergence went unnoticed.
#[must_use]
pub fn claude_project_slug(project: &str) -> String {
    project
        .encode_utf16()
        .map(|unit| {
            let ascii = u8::try_from(unit).unwrap_or(0);
            if ascii.is_ascii_alphanumeric() {
                char::from(ascii)
            } else {
                '-'
            }
        })
        .collect()
}

/// The known agent-session roots under `home`.
///
/// `~/.codex/sessions` is listed for the READ path even though [`list_sessions`] does not enumerate
/// codex: auto-discovery is the deferred half of the Claude-first scope reduction, and an explicit
/// absolute codex id stays readable. The root is here BY DESIGN, not by oversight.
#[must_use]
pub fn session_roots(home: &str) -> Vec<PathBuf> {
    let home = PathBuf::from(home);
    vec![
        home.join(".claude/projects"),
        home.join(".codex/sessions"),
        home.join(".local/share/opencode/storage/session"),
    ]
}

/// The sessions discoverable for `project` — Claude Code and `OpenCode` only, newest first.
#[must_use]
pub fn list_sessions(home: &str, project: &str) -> Vec<Session> {
    let claude_dir = PathBuf::from(home)
        .join(".claude/projects")
        .join(claude_project_slug(project));
    let opencode_dir = PathBuf::from(home)
        .join(".local/share/opencode/storage/session")
        .join(project.replace('/', "-"));

    let mut sessions = scan(&claude_dir, 0, project, "jsonl");
    sessions.extend(scan(&opencode_dir, 2, project, "json"));
    sort_newest_first(&mut sessions);
    sessions
}

/// Orders a session list newest first, then caps it.
///
/// Split from [`list_sessions`] so the ordering is pinned without a filesystem whose mtimes a test
/// would have to forge. The cap is applied AFTER the sort on purpose: capping first would drop
/// sessions by `read_dir` order, which is to say arbitrarily, and the ones a person wants are the
/// recent ones.
pub fn sort_newest_first(sessions: &mut Vec<Session>) {
    // Keyed on the NEGATED time rather than a reversed comparator: `sort_by_key` is the shape
    // clippy asks for, and `Reverse` over an i64 says the same thing without a wrap to reason about.
    sessions.sort_by_key(|session| std::cmp::Reverse(session.mtime_ms));
    sessions.truncate(MAX_SESSIONS);
}

/// Enumerates `<dir>/*.<extension>` into sessions. A missing directory is an empty list, not an
/// error — a project nobody has run an agent in is the ordinary case.
fn scan(dir: &Path, kind: u8, project: &str, extension: &str) -> Vec<Session> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().is_some_and(|found| found == extension))
        .map(|entry| {
            let mtime_ms = entry
                .metadata()
                .ok()
                .and_then(|metadata| metadata.modified().ok())
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .and_then(|since| i64::try_from(since.as_millis()).ok())
                .unwrap_or(0);
            Session {
                kind,
                id: entry.path().to_string_lossy().into_owned(),
                title: String::new(),
                cwd: project.to_owned(),
                mtime_ms,
            }
        })
        .take(MAX_SESSIONS)
        .collect()
}

/// The transcript bytes for an absolute session `id`, confined to [`session_roots`].
///
/// The builder already rejected `..`; this is defence in depth, and it is the reason the id is
/// normalised first — a path that only *reads* as being under a root is not under it. The read is
/// bounded at the source like every other opaque answer.
#[must_use]
pub fn read_session(home: &str, id: &str) -> Option<Vec<u8>> {
    if !id.starts_with('/') {
        return None;
    }
    let path = normalise(Path::new(id));
    let within = session_roots(home)
        .iter()
        .any(|root| path.starts_with(root) && path != root.as_path());
    if !within {
        return None;
    }
    let bytes = std::fs::read(&path).ok()?;
    // One past the cap, so the builder's own trim still sees a truncation to report.
    let mut bytes = bytes;
    bytes.truncate(run::MAX_OPAQUE_READ_BYTES + 1);
    Some(bytes)
}

/// Resolves `.` and `..` lexically, without touching the filesystem.
///
/// Lexical on purpose: `canonicalize` would follow symlinks, and a session file reached through a
/// symlink out of a root is exactly what the confinement is for. It also fails for a path that does
/// not exist, which would turn a clean "not found" into a confinement decision made on an error.
fn normalise(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::ParentDir => {
                let _unused = out.pop();
            },
            std::path::Component::CurDir => {},
            other => out.push(other),
        }
    }
    out
}

/// The JSON a directory listing crosses as.
#[must_use]
pub fn directory_json(entries: &[DirEntry]) -> Value {
    json!({
        "entries": entries.iter().map(|entry| json!({
            "isDir": entry.is_dir,
            "name": entry.name,
        })).collect::<Vec<_>>(),
    })
}

/// The JSON a session list crosses as.
#[must_use]
pub fn sessions_json(sessions: &[Session]) -> Value {
    json!({
        "sessions": sessions.iter().map(|session| json!({
            "kind": session.kind,
            "id": session.id,
            "title": session.title,
            "cwd": session.cwd,
            "mtimeMS": session.mtime_ms,
        })).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(label: &str) -> Self {
            use std::sync::atomic::{AtomicU64, Ordering};
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("slopdesk-probe-{label}-{}-{unique}", std::process::id()));
            std::fs::create_dir_all(&path).expect("scratch dir");
            Self(path)
        }

        fn join(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }

        fn touch(&self, relative: &str, contents: &[u8]) -> PathBuf {
            let path = self.0.join(relative);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).expect("parent");
            }
            std::fs::write(&path, contents).expect("write");
            path
        }

        fn home(&self) -> String {
            self.0.to_string_lossy().into_owned()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _unused = std::fs::remove_dir_all(&self.0);
        }
    }

    // MARK: The slug

    #[test]
    fn the_slug_matches_the_listing_it_was_verified_against() {
        assert_eq!(
            claude_project_slug("/Users/me/.config/nvim"),
            "-Users-me--config-nvim",
        );
    }

    #[test]
    fn every_non_alphanumeric_gets_its_own_dash_with_no_collapsing() {
        assert_eq!(claude_project_slug("a//b"), "a--b");
        assert_eq!(claude_project_slug("a_b-c.d"), "a-b-c-d");
        assert_eq!(claude_project_slug("Abc123"), "Abc123");
        assert_eq!(claude_project_slug(""), "");
    }

    #[test]
    fn a_non_ascii_character_counts_the_way_the_producer_counts_it() {
        // One BMP scalar → one code unit → one dash.
        assert_eq!(claude_project_slug("é"), "-");
        // One astral scalar → a surrogate PAIR → TWO dashes, which is what Claude Code writes and
        // what the Swift grapheme-based version got wrong.
        assert_eq!(claude_project_slug("😀"), "--");
    }

    // MARK: Directory listing

    #[test]
    fn a_listing_is_sorted_and_marks_directories() {
        let scratch = Scratch::new("dir");
        let _unused = scratch.touch("zeta.txt", b"z");
        let _unused = scratch.touch("alpha.txt", b"a");
        std::fs::create_dir_all(scratch.join("middle")).unwrap();
        let entries = list_directory(&scratch.0).unwrap();
        assert_eq!(entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), [
            "alpha.txt",
            "middle",
            "zeta.txt"
        ],);
        assert_eq!(entries.iter().map(|e| e.is_dir).collect::<Vec<_>>(), [
            false, true, false
        ],);
    }

    #[test]
    fn a_file_or_a_missing_path_is_not_a_listing() {
        let scratch = Scratch::new("notdir");
        let file = scratch.touch("a.txt", b"a");
        assert!(list_directory(&file).is_none());
        assert!(list_directory(&scratch.join("absent")).is_none());
    }

    // MARK: Sessions

    #[test]
    fn both_agents_are_discovered_under_their_own_conventions() {
        let scratch = Scratch::new("sessions");
        let home = scratch.home();
        let slug = claude_project_slug("/work/repo");
        let claude = scratch.touch(&format!(".claude/projects/{slug}/a.jsonl"), b"{}");
        let opencode = scratch.touch(".local/share/opencode/storage/session/-work-repo/s.json", b"{}");
        let found = list_sessions(&home, "/work/repo");
        assert_eq!(found.len(), 2);
        let by_kind: Vec<(u8, &str)> = {
            let mut pairs: Vec<(u8, &str)> = found.iter().map(|s| (s.kind, s.id.as_str())).collect();
            pairs.sort_unstable();
            pairs
        };
        // 0 = claude, 2 = opencode — the raw bytes the client reads forward-tolerantly.
        assert_eq!(by_kind[0].0, 0);
        assert_eq!(by_kind[0].1, claude.to_string_lossy());
        assert_eq!(by_kind[1].0, 2);
        assert_eq!(by_kind[1].1, opencode.to_string_lossy());
        // The project cwd rides every row, so the client never has to re-derive it from the slug.
        assert!(found.iter().all(|s| s.cwd == "/work/repo"));
        assert!(found.iter().all(|s| s.title.is_empty()));
    }

    #[test]
    fn the_order_is_newest_first_and_the_cap_falls_on_the_oldest() {
        let session = |ms: i64| {
            Session {
                kind: 0,
                id: format!("s{ms}"),
                title: String::new(),
                cwd: "/p".to_owned(),
                mtime_ms: ms,
            }
        };
        let mut sessions = vec![session(10), session(30), session(20)];
        sort_newest_first(&mut sessions);
        assert_eq!(sessions.iter().map(|s| s.mtime_ms).collect::<Vec<_>>(), [
            30, 20, 10
        ],);

        // Capping AFTER the sort is what keeps the recent ones: a cap applied first would have kept
        // whichever the directory happened to yield.
        let cap = i64::try_from(MAX_SESSIONS).unwrap();
        let mut many: Vec<Session> = (0..(cap + 10)).map(session).collect();
        sort_newest_first(&mut many);
        assert_eq!(many.len(), MAX_SESSIONS);
        assert_eq!(many[0].mtime_ms, cap + 9);
        assert_eq!(many[MAX_SESSIONS - 1].mtime_ms, 10);
    }

    #[test]
    fn a_project_nobody_has_run_an_agent_in_is_an_empty_list() {
        let scratch = Scratch::new("nosessions");
        assert!(list_sessions(&scratch.home(), "/never/used").is_empty());
    }

    #[test]
    fn only_the_expected_extension_is_enumerated() {
        let scratch = Scratch::new("ext");
        let slug = claude_project_slug("/p");
        let _unused = scratch.touch(&format!(".claude/projects/{slug}/a.jsonl"), b"{}");
        let _unused = scratch.touch(&format!(".claude/projects/{slug}/notes.md"), b"x");
        let found = list_sessions(&scratch.home(), "/p");
        assert_eq!(found.len(), 1);
        assert!(found[0].id.ends_with("a.jsonl"));
    }

    // MARK: The confined read

    #[test]
    fn a_session_inside_a_root_reads_back() {
        let scratch = Scratch::new("read");
        let file = scratch.touch(".claude/projects/-p/s.jsonl", b"line\n");
        let bytes = read_session(&scratch.home(), &file.to_string_lossy()).unwrap();
        assert_eq!(bytes, b"line\n");
    }

    #[test]
    fn a_path_outside_every_root_is_refused() {
        let scratch = Scratch::new("outside");
        let file = scratch.touch("elsewhere/secret.txt", b"nope");
        assert!(read_session(&scratch.home(), &file.to_string_lossy()).is_none());
    }

    #[test]
    fn a_traversal_that_climbs_back_out_is_refused_after_normalising() {
        let scratch = Scratch::new("traverse");
        let _unused = scratch.touch("elsewhere/secret.txt", b"nope");
        let sneaky = format!("{}/.claude/projects/../../elsewhere/secret.txt", scratch.home());
        assert!(read_session(&scratch.home(), &sneaky).is_none());
    }

    #[test]
    fn a_relative_id_is_refused_outright() {
        let scratch = Scratch::new("relative");
        assert!(read_session(&scratch.home(), "s.jsonl").is_none());
        assert!(read_session(&scratch.home(), "").is_none());
    }

    #[test]
    fn a_root_itself_is_not_a_session() {
        let scratch = Scratch::new("root");
        std::fs::create_dir_all(scratch.join(".claude/projects")).unwrap();
        let root = scratch.join(".claude/projects");
        assert!(read_session(&scratch.home(), &root.to_string_lossy()).is_none());
    }

    #[test]
    fn the_codex_root_stays_readable_even_though_it_is_never_enumerated() {
        let scratch = Scratch::new("codex");
        let file = scratch.touch(".codex/sessions/2026/s.json", b"c");
        assert_eq!(
            read_session(&scratch.home(), &file.to_string_lossy()),
            Some(b"c".to_vec()),
        );
        // …but no codex session is ever auto-discovered.
        assert!(list_sessions(&scratch.home(), "/anything").is_empty());
    }
}

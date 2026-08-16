//! Watches the `subagents/` directory for `agent-<hash>.jsonl` files and tails each one.
//!
//! Native `claude` does **not** interleave subagent turns into the main session file, so tailing
//! only the main transcript loses all subagent content. The owning subagent id is the filename hash
//! — `agent-<hash>.jsonl` → `<hash>` — which is also what the `SubagentStop` signal's
//! `agent_transcript_path` reduces to, so a node linked by a hook and one discovered by this
//! watcher are the same node.
//!
//! Like the transcript tailer this POLLS (a directory listing diff, then a per-file tail) for
//! portability and testability. An `FSEvents` watch would be a strictly local optimisation behind
//! the same interface, and buys nothing at a per-turn event rate.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::line::TranscriptLine;
use crate::tailer::TranscriptTailer;

/// Watches one `subagents/` directory.
#[derive(Debug)]
pub struct SubagentWatcher {
    directory: PathBuf,
    /// Tailers already started, keyed by agent id, so a file is followed exactly once.
    ///
    /// A `BTreeMap` rather than a hash map because the poll iterates it, and iterating in a stable
    /// (id-sorted) order makes the emitted event order reproducible across runs — which is what
    /// makes a fixture test of two concurrent subagents assertable at all.
    tailers: BTreeMap<String, TranscriptTailer>,
}

impl SubagentWatcher {
    /// Watches `directory`. It need not exist — subagents are created lazily, and a session that
    /// spawns none never grows the directory at all.
    #[must_use]
    pub fn new(directory: impl AsRef<Path>) -> Self {
        Self {
            directory: directory.as_ref().to_path_buf(),
            tailers: BTreeMap::new(),
        }
    }

    /// Subagent files currently being followed.
    #[must_use]
    pub fn followed_count(&self) -> usize {
        self.tailers.len()
    }

    /// One poll: adopts any newly-appeared file, then returns `(agent_id, line)` for every line
    /// that appeared in any of them.
    pub fn poll(&mut self) -> Vec<(String, TranscriptLine)> {
        self.discover();
        let mut out = Vec::new();
        for (agent_id, tailer) in &mut self.tailers {
            for line in tailer.poll() {
                out.push((agent_id.clone(), line));
            }
        }
        out
    }

    /// Starts following any `agent-*.jsonl` not already tailed.
    fn discover(&mut self) {
        let Ok(entries) = fs::read_dir(&self.directory) else {
            return;
        };
        // Sorted, so a batch of files appearing between two polls is adopted in a stable order.
        let mut names: Vec<String> = entries
            .filter_map(Result::ok)
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|name| is_agent_transcript(name))
            .collect();
        names.sort_unstable();

        for name in names {
            let agent_id = agent_hash(&name);
            if self.tailers.contains_key(&agent_id) {
                continue;
            }
            self.tailers
                .insert(agent_id, TranscriptTailer::new(self.directory.join(&name)));
        }
    }
}

/// Whether `name` is a subagent transcript rather than its `.meta.json` sidecar.
///
/// The extension check goes through [`Path`] rather than a `str` suffix so a name whose case
/// differs is still judged by the same rule the filesystem would apply, which is what the lint is
/// guarding — Claude Code writes lowercase, but the daemon reads a directory, not a promise.
fn is_agent_transcript(name: &str) -> bool {
    name.starts_with("agent-")
        && Path::new(name)
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
}

/// `…/agent-<hash>.jsonl` → `<hash>`.
///
/// The `agent-<hash>.meta.json` sidecar is excluded upstream by the `.jsonl` suffix filter. A path
/// that reduces to nothing keeps its original text rather than becoming an empty id — an id that is
/// the empty string collides every subagent into one node, which is worse than an ugly one.
#[must_use]
pub fn agent_hash(path: &str) -> String {
    let file = Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(path);
    let stem = file.strip_suffix(".jsonl").unwrap_or(file);
    let hash = stem.strip_prefix("agent-").unwrap_or(stem);
    if hash.is_empty() {
        path.to_owned()
    } else {
        hash.to_owned()
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::fs::{self, OpenOptions};
    use std::io::Write as _;
    use std::path::PathBuf;

    use super::{SubagentWatcher, agent_hash};
    use crate::line::TranscriptLine;

    fn temp_dir(label: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "slopdesk-inspectord-sub-{label}-{}-{unique}",
            std::process::id()
        ));
        drop(fs::remove_dir_all(&dir));
        fs::create_dir_all(&dir).expect("creatable");
        dir
    }

    fn write_line(path: &PathBuf, uuid: &str, text: &str) {
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .expect("appendable");
        writeln!(
            file,
            "{}",
            serde_json::json!({"type": "user", "uuid": uuid, "message": text})
        )
        .expect("written");
    }

    #[test]
    fn the_agent_id_is_the_filename_hash() {
        assert_eq!(agent_hash("/x/subagents/agent-abc123.jsonl"), "abc123");
        assert_eq!(agent_hash("agent-abc123.jsonl"), "abc123");
        assert_eq!(agent_hash("plain.jsonl"), "plain");
        // Degenerate input keeps its text rather than collapsing every subagent into one empty id.
        assert_eq!(agent_hash("agent-.jsonl"), "agent-.jsonl");
        assert_eq!(agent_hash(""), "");
    }

    #[test]
    fn a_missing_directory_is_simply_quiet() {
        let mut watcher = SubagentWatcher::new("/nonexistent/slopdesk/subagents");
        assert!(watcher.poll().is_empty());
        assert_eq!(watcher.followed_count(), 0);
    }

    #[test]
    fn a_new_agent_file_is_adopted_and_its_lines_are_attributed() {
        let dir = temp_dir("adopt");
        let mut watcher = SubagentWatcher::new(&dir);
        assert!(watcher.poll().is_empty());

        write_line(&dir.join("agent-aaa.jsonl"), "u1", "from aaa");
        let batch = watcher.poll();
        assert_eq!(batch.len(), 1);
        assert_eq!(batch[0].0, "aaa");
        assert!(matches!(batch[0].1, TranscriptLine::User(_)));
        assert_eq!(watcher.followed_count(), 1);
    }

    #[test]
    fn two_agents_are_followed_independently_in_a_stable_order() {
        let dir = temp_dir("two");
        write_line(&dir.join("agent-bbb.jsonl"), "u1", "from bbb");
        write_line(&dir.join("agent-aaa.jsonl"), "u2", "from aaa");

        let mut watcher = SubagentWatcher::new(&dir);
        let ids: Vec<String> = watcher.poll().into_iter().map(|(id, _)| id).collect();
        assert_eq!(ids, vec!["aaa".to_owned(), "bbb".to_owned()]);
        assert_eq!(watcher.followed_count(), 2);
    }

    #[test]
    fn the_meta_sidecar_is_not_followed() {
        let dir = temp_dir("meta");
        fs::write(dir.join("agent-aaa.meta.json"), "{}").expect("written");
        let mut watcher = SubagentWatcher::new(&dir);
        assert!(watcher.poll().is_empty());
        assert_eq!(watcher.followed_count(), 0);
    }

    #[test]
    fn an_adopted_file_is_never_re_read_from_the_top() {
        let dir = temp_dir("resume");
        let path = dir.join("agent-aaa.jsonl");
        write_line(&path, "u1", "first");
        let mut watcher = SubagentWatcher::new(&dir);
        assert_eq!(watcher.poll().len(), 1);

        write_line(&path, "u2", "second");
        let batch = watcher.poll();
        assert_eq!(batch.len(), 1, "only the new line");
    }
}

//! Follows a Claude Code JSONL transcript as it grows, emitting each complete line exactly once.
//!
//! ## Poll the size, read the delta — not a vnode watch
//! Deliberate, and unchanged from the Swift original's reasoning:
//! - it is portable and DETERMINISTIC — the same code path everywhere, trivially testable against a
//!   temp file, with no `kqueue`/`FSEvents` difference to reason about;
//! - JSONL flushes happen per turn, so sub-second latency is ample — the low-latency path for a
//!   tool card was always the hook, never the tail;
//! - it cannot MISS a write (a vnode event coalesces multiple writes into one signal anyway, and
//!   the delta would still have to be read) and cannot DOUBLE-EMIT (the offset only ever advances
//!   past bytes already turned into complete lines).
//!
//! ## Truncation and rotation
//! Two independent defences, because the size check alone is not enough:
//! 1. the file is SMALLER than the last offset → it was truncated, so restart at 0 and drop the
//!    stale half-line;
//! 2. the file's `(dev, ino)` IDENTITY changed → the path now names a DIFFERENT file (`mv old
//!    old.1`, then a fresh one appears at `old`), so restart regardless of size. Without this, a
//!    rotation to a same-or-larger file reads from the stale offset into the new file and silently
//!    loses its prefix.
//!
//! Identity is read from the OPEN descriptor, so size and identity always describe the same file
//! even if it is rotated mid-poll.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use crate::accumulator::LineAccumulator;
use crate::line::TranscriptLine;
use crate::parser;

/// Maximum bytes read per poll. A larger backlog drains over successive polls rather than blocking
/// the engine thread on one enormous read.
pub const MAX_READ_PER_POLL: usize = 1024 * 1024;

/// A file's on-disk identity. The same path can name different files over time, and the same file
/// can be reached by different paths; `(dev, ino)` is what is actually stable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    device: u64,
    inode: u64,
}

/// Follows one transcript file.
#[derive(Debug)]
pub struct TranscriptTailer {
    path: PathBuf,
    max_read_per_poll: usize,
    /// Bytes already consumed into complete-or-pending lines.
    offset: u64,
    accumulator: LineAccumulator,
    /// The identity of the file last read; `None` until it first exists.
    identity: Option<FileIdentity>,
}

impl TranscriptTailer {
    /// Follows `path`. The file need not exist yet — a `SessionStart` can fire before Claude Code
    /// creates it, so a missing file is simply "nothing this poll", not an error.
    #[must_use]
    pub fn new(path: impl AsRef<Path>) -> Self {
        Self::with_read_cap(path, MAX_READ_PER_POLL)
    }

    /// Follows `path`, reading at most `max_read_per_poll` bytes per poll. The cap is injectable so
    /// a test can drive the multi-poll drain deterministically.
    #[must_use]
    pub fn with_read_cap(path: impl AsRef<Path>, max_read_per_poll: usize) -> Self {
        Self {
            path: path.as_ref().to_path_buf(),
            max_read_per_poll: max_read_per_poll.max(1),
            offset: 0,
            accumulator: LineAccumulator::default(),
            identity: None,
        }
    }

    /// The file being followed.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// One poll: the lines that appeared since the last call, parsed.
    pub fn poll(&mut self) -> Vec<TranscriptLine> {
        self.read_delta()
            .iter()
            .filter_map(|line| parser::parse(line))
            .collect()
    }

    /// Reads the bytes appended since the last call and returns the complete lines they produced.
    fn read_delta(&mut self) -> Vec<String> {
        let Ok(mut file) = File::open(&self.path) else {
            // Not created yet, or gone — try again next poll.
            return Vec::new();
        };

        if let Some(current) = Self::identity_of(&file) {
            if self.identity.is_some_and(|previous| previous != current) {
                // The path names a DIFFERENT file now: restart from the top and drop the stale
                // half-line, even though the new file may be the same size or larger.
                self.restart();
            }
            self.identity = Some(current);
        }

        let Ok(size) = file.seek(SeekFrom::End(0)) else {
            return Vec::new();
        };
        if size < self.offset {
            // Truncated, or rotated to something smaller.
            self.restart();
        }
        if size <= self.offset {
            return Vec::new();
        }

        if file.seek(SeekFrom::Start(self.offset)).is_err() {
            return Vec::new();
        }

        let want = usize::try_from(size - self.offset).unwrap_or(self.max_read_per_poll);
        let mut buffer = vec![0_u8; want.min(self.max_read_per_poll)];
        let Ok(read) = file.read(&mut buffer) else {
            return Vec::new();
        };
        if read == 0 {
            return Vec::new();
        }
        self.offset += read as u64;
        buffer.truncate(read);
        self.accumulator.append(&buffer)
    }

    /// Restarts at the top of the file, dropping the half-line held from the previous one.
    fn restart(&mut self) {
        self.offset = 0;
        self.accumulator.reset();
    }

    /// The `(dev, ino)` of an open file, or `None` if it cannot be stat'd.
    fn identity_of(file: &File) -> Option<FileIdentity> {
        file.metadata().ok().map(|meta| {
            FileIdentity {
                device: meta.dev(),
                inode: meta.ino(),
            }
        })
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::fs::{self, File, OpenOptions};
    use std::io::Write as _;
    use std::path::PathBuf;

    use super::TranscriptTailer;
    use crate::line::TranscriptLine;

    /// A unique temp directory for one test. `Date`/random are unavailable by policy in the
    /// workflow scripts, not here — but a monotonically-bumped counter plus the pid is enough, and
    /// is deterministic per process, which is nicer to debug than a random name.
    fn temp_dir(label: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "slopdesk-inspectord-{label}-{}-{unique}",
            std::process::id()
        ));
        drop(fs::remove_dir_all(&dir));
        fs::create_dir_all(&dir).expect("the temp dir is creatable");
        dir
    }

    fn append(path: &PathBuf, text: &str) {
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .expect("appendable");
        file.write_all(text.as_bytes()).expect("written");
    }

    fn user_line(uuid: &str, text: &str) -> String {
        format!(
            "{}\n",
            serde_json::json!({"type": "user", "uuid": uuid, "message": text})
        )
    }

    fn texts(lines: &[TranscriptLine]) -> Vec<String> {
        lines
            .iter()
            .filter_map(|line| {
                match line {
                    TranscriptLine::User(user) => user.text.clone(),
                    _ => None,
                }
            })
            .collect()
    }

    #[test]
    fn a_missing_file_is_not_an_error_and_is_picked_up_when_it_appears() {
        let dir = temp_dir("missing");
        let path = dir.join("session.jsonl");
        let mut tailer = TranscriptTailer::new(&path);
        assert!(tailer.poll().is_empty());

        append(&path, &user_line("u1", "hello"));
        assert_eq!(texts(&tailer.poll()), vec!["hello".to_owned()]);
    }

    #[test]
    fn every_line_is_emitted_exactly_once_across_polls() {
        let dir = temp_dir("once");
        let path = dir.join("session.jsonl");
        append(&path, &user_line("u1", "one"));

        let mut tailer = TranscriptTailer::new(&path);
        assert_eq!(texts(&tailer.poll()), vec!["one".to_owned()]);
        assert!(tailer.poll().is_empty(), "a quiet poll re-emits nothing");

        append(&path, &user_line("u2", "two"));
        assert_eq!(texts(&tailer.poll()), vec!["two".to_owned()]);
    }

    #[test]
    fn a_line_written_in_two_pieces_emits_once_whole() {
        let dir = temp_dir("partial");
        let path = dir.join("session.jsonl");
        let mut tailer = TranscriptTailer::new(&path);

        let full = user_line("u1", "complete");
        let split = full.len().div_euclid(2);
        append(&path, &full[..split]);
        assert!(tailer.poll().is_empty(), "the partial line is held back");
        append(&path, &full[split..]);
        assert_eq!(texts(&tailer.poll()), vec!["complete".to_owned()]);
    }

    #[test]
    fn truncation_restarts_from_the_top() {
        let dir = temp_dir("truncate");
        let path = dir.join("session.jsonl");
        append(&path, &user_line("u1", "before"));
        let mut tailer = TranscriptTailer::new(&path);
        assert_eq!(texts(&tailer.poll()).len(), 1);

        File::create(&path).expect("truncated");
        append(&path, &user_line("u2", "after"));
        assert_eq!(texts(&tailer.poll()), vec!["after".to_owned()]);
    }

    #[test]
    fn rotation_to_a_larger_file_is_caught_by_identity_not_size() {
        let dir = temp_dir("rotate");
        let path = dir.join("session.jsonl");
        append(&path, &user_line("u1", "old"));
        let mut tailer = TranscriptTailer::new(&path);
        assert_eq!(texts(&tailer.poll()), vec!["old".to_owned()]);

        // `mv` the old file away and put a BIGGER one at the same path. A size-only check reads from
        // the stale offset and loses the new file's prefix; the identity check restarts.
        fs::rename(&path, dir.join("session.jsonl.1")).expect("renamed");
        append(
            &path,
            &user_line("u2", "brand new and much longer than the old one"),
        );
        assert_eq!(texts(&tailer.poll()), vec![
            "brand new and much longer than the old one".to_owned()
        ]);
    }

    #[test]
    fn a_backlog_larger_than_the_read_cap_drains_over_successive_polls() {
        let dir = temp_dir("cap");
        let path = dir.join("session.jsonl");
        let mut written = String::new();
        for index in 0..40 {
            written.push_str(&user_line(&format!("u{index}"), &format!("line{index}")));
        }
        append(&path, &written);

        let mut tailer = TranscriptTailer::with_read_cap(&path, 64);
        let mut seen = Vec::new();
        for _ in 0..200 {
            let batch = texts(&tailer.poll());
            if batch.is_empty() && seen.len() == 40 {
                break;
            }
            seen.extend(batch);
        }
        assert_eq!(seen.len(), 40, "everything arrives, just over several polls");
        assert_eq!(seen[0], "line0");
        assert_eq!(seen[39], "line39");
    }

    #[test]
    fn an_unparseable_line_still_surfaces() {
        let dir = temp_dir("garbage");
        let path = dir.join("session.jsonl");
        append(&path, "{not json at all\n");
        let mut tailer = TranscriptTailer::new(&path);
        assert!(matches!(tailer.poll().as_slice(), [
            TranscriptLine::Unknown { .. }
        ]));
    }
}

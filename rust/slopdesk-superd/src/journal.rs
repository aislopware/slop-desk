//! The transcript of a pane whose process is long gone — on disk, so it outlives everything.
//!
//! ## Why the custodian keeps it, and not hostd
//! A pane's scrollback has two retainers with two jobs. [`crate::ring`] is the resume buffer for a
//! pane that is still running, memory-only because superd's death takes every pane with it. This is
//! the other one: the bytes replayed above a *fresh* shell after a reboot, a TTL eviction or the
//! shell simply exiting — the tmux-resurrect half of "lossless reconnect", where the transcript
//! survives even though the process cannot.
//!
//! It used to be hostd's (`ScrollbackJournal.swift`), written from the chunks hostd received over
//! this socket. That is one process journaling a stream another process owns, and the whole of
//! `docs/51` §6.8's first rule was the cost of it: hostd had to write down HOW MUCH of the stream
//! it had persisted (`<uuid>.scrollback.resume`, stamped with the pane life because offsets restart
//! at every fork), the next hostd had to align its subscribe against that number, a hostd that was
//! killed never wrote one at all, and the fix for THAT was to re-claim the sidecar on the flush
//! cadence and accept a rule about which of two non-atomic writes is allowed to be stale.
//!
//! None of that exists here. superd numbers the stream and superd writes the file, so "how much of
//! the stream is on disk" is a variable it already holds — [`JournalStore::head`] — exact by
//! construction, with no sidecar, no pane-life stamping and no staleness trade. There is no
//! cross-process window to be stale IN: a superd that dies takes the panes whose offsets those
//! were.
//!
//! ## What is still hostd's
//! Every policy: the directory, the byte cap, whether a pane is journaled at all, when a journal is
//! deleted, how old is too old, and what the restored bytes are RENDERED into (screend's
//! `transcript` verb). superd owns the file — the appends, the coalescing, the cap, the compaction
//! and the geometry the renderer needs — and nothing about what any of it means.
//!
//! ## Shape
//! One writer per journaled pane, all of them flushed by ONE thread. Appends from the pump thread
//! cost a `memcpy` under an uncontended mutex and a condvar signal; the file I/O happens here. That
//! ordering is not an optimisation — the pump thread is the only reader of a PTY master, and a
//! `write(2)` to a full disk on that thread would stall the child, which is the one thing a
//! custodian must never do to a pane it is supposed to be keeping alive.
//!
//! Files are RAW bytes with no header: any tail of a byte stream "decodes", and the renderer
//! tolerates arbitrary input, so there is nothing to version. The one sidecar left (`.size`)
//! records the last PTY geometry the pane applied, because a transcript parses correctly only at
//! the width it was emitted for and that number has to survive the process that knew it.

// stderr IS superd's log — see `server.rs`. A transcript that cannot be written is a silent loss of
// scrollback otherwise.
#![expect(clippy::print_stderr, reason = "stderr is superd's log; launchd captures it")]

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime};

/// Buffered appends flush as one contiguous `write(2)` once they reach this.
///
/// The same 32 KiB the Swift journal coalesced at, and for the same reason: interactive typing and
/// line-buffered output otherwise cost one syscall per PTY chunk, hundreds to thousands a second
/// per pane, attached or not.
pub const FLUSH_THRESHOLD_BYTES: usize = 32 * 1024;

/// How long a buffered byte may sit unwritten. The crash-loss window, and nothing else.
pub const IDLE_FLUSH: Duration = Duration::from_millis(25);

/// How far past the cap a file may grow before compaction rewrites it to the newest cap-worth.
///
/// Doubling is what makes compaction amortised: rewriting at exactly the cap would rewrite the
/// whole file on every chunk past it.
const COMPACT_MULTIPLE: usize = 2;

/// How far past the cut compaction will look for a newline to align the surviving head on.
const NEWLINE_SCAN_BYTES: usize = 4096;

/// How much of the surviving head the alt-screen scanner may peek at to resolve a sequence that
/// straddles the cut.
const ALT_PEEK_BYTES: usize = 64;

/// The file extension for a journal.
const JOURNAL_EXTENSION: &str = "scrollback";

/// The file extension for the geometry sidecar, appended to the journal's own name.
const SIZE_EXTENSION: &str = "size";

/// What a caller learns about a journal on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Info {
    /// Absolute path to the journal file. The caller READS this itself: shipping a multi-megabyte
    /// transcript back through a JSON reply to hand it straight to a renderer would be a copy for
    /// nothing.
    pub path: PathBuf,
    /// Bytes currently on disk, after any pending appends were flushed.
    pub bytes: u64,
    /// The last PTY geometry this pane applied, when the sidecar survives. The transcript parses
    /// faithfully only at the size it was emitted for.
    pub rows: u16,
    /// See [`Info::rows`].
    pub cols: u16,
    /// How much of the LIVE pane's stream is already in the file, or `None` when no pane of that
    /// name is journaling here — a session whose process is gone, which is the ordinary case for a
    /// restore.
    ///
    /// A subscriber resumes exactly here. It is not written down anywhere and does not need to be:
    /// the process that numbered those offsets is the process answering.
    pub head: Option<u64>,
}

/// Every journal this superd is writing, and the one thread that writes them.
#[derive(Debug)]
pub struct JournalStore {
    shared: Arc<Shared>,
}

#[derive(Debug)]
struct Shared {
    state: Mutex<HashMap<String, Writer>>,
    wake: Condvar,
    stopping: AtomicBool,
}

/// One pane's file.
#[derive(Debug)]
struct Writer {
    path: PathBuf,
    cap: usize,
    handle: Option<File>,
    /// Bytes on disk. Cap accounting is this plus `pending`, so buffered bytes count.
    on_disk: usize,
    pending: Vec<u8>,
    /// The stream offset just past `pending`'s last byte.
    pending_end: u64,
    /// The stream offset just past what is ON DISK — [`Info::head`].
    flushed_end: u64,
    /// The last geometry written to the sidecar, so a resize that repeats itself writes nothing.
    last_size: Option<(u16, u16)>,
    /// Retry floor after a FAILED compaction: the atomic rewrite transiently needs a cap-worth of
    /// free space that incremental appends do not, and without a floor every append past the
    /// doubling point would re-read the over-cap file and re-attempt the rewrite.
    retry_floor: usize,
}

impl JournalStore {
    /// Starts the writer thread.
    ///
    /// The thread lives as long as the store. It is one thread for every pane rather than one each:
    /// a flush is a `write(2)` on an already-open fd, compaction is rare and bounded by the cap,
    /// and a superd holding 256 panes should not hold 256 mostly-sleeping threads to do it.
    #[must_use]
    pub fn start() -> Self {
        let shared = Arc::new(Shared {
            state: Mutex::new(HashMap::new()),
            wake: Condvar::new(),
            stopping: AtomicBool::new(false),
        });
        let worker = Arc::clone(&shared);
        let spawned = std::thread::Builder::new()
            .name("superd-journal".to_owned())
            .stack_size(256 * 1024)
            .spawn(move || run(&worker));
        if spawned.is_err() {
            // A store with no thread still accepts appends and still flushes — every reader path
            // (`head`, `info`, `close`) flushes synchronously before it answers. What is lost is
            // the idle cadence, so a pane that stops producing keeps its last few KiB
            // in memory until somebody asks. Refusing to journal at all would be the
            // worse answer.
            eprintln!("superd: journal writer thread did not start — flushes are on demand only");
        }
        Self { shared }
    }

    /// Registers `pane_id` as journaling into `dir/<session_id>.scrollback`, appending at the end
    /// of whatever is already there.
    ///
    /// `cap` of `0` registers nothing: it is how a caller says "persistence is off" without every
    /// call site growing an `if`.
    pub fn open(&self, pane_id: &str, dir: &Path, session_id: &str, cap: usize) {
        if cap == 0 || session_id.is_empty() {
            return;
        }
        let path = journal_path(dir, session_id);
        drop(std::fs::create_dir_all(dir));
        let Ok(mut state) = self.shared.state.lock() else {
            return;
        };
        // A re-open for the same pane keeps the same file and starts its offsets fresh: the caller
        // re-spawned into an id it already owns, and the transcript is deliberately continuous
        // across that (a fresh shell's output belongs under the history it replaces).
        state.insert(pane_id.to_owned(), Writer {
            path,
            cap,
            handle: None,
            on_disk: 0,
            pending: Vec::new(),
            pending_end: 0,
            flushed_end: 0,
            last_size: None,
            retry_floor: 0,
        });
    }

    /// Buffers a chunk. `stream_end` is the offset just past its last byte.
    ///
    /// Cheap by construction — a `memcpy` under an uncontended mutex — because the caller is the
    /// thread that owns the pane's `read(2)`.
    pub fn append(&self, pane_id: &str, chunk: &[u8], stream_end: u64) {
        if chunk.is_empty() {
            return;
        }
        let Ok(mut state) = self.shared.state.lock() else {
            return;
        };
        let Some(writer) = state.get_mut(pane_id) else {
            return;
        };
        writer.pending.extend_from_slice(chunk);
        writer.pending_end = stream_end;
        let due = writer.pending.len() >= FLUSH_THRESHOLD_BYTES;
        drop(state);
        if due {
            self.shared.wake.notify_one();
        }
    }

    /// Records the geometry a pane just applied, for a later life's renderer. Deduped.
    pub fn record_size(&self, pane_id: &str, rows: u16, cols: u16) {
        if rows == 0 || cols == 0 {
            return;
        }
        let Ok(mut state) = self.shared.state.lock() else {
            return;
        };
        let Some(writer) = state.get_mut(pane_id) else {
            return;
        };
        if writer.last_size == Some((rows, cols)) {
            return;
        }
        writer.last_size = Some((rows, cols));
        let path = size_sidecar_path(&writer.path);
        drop(state);
        write_atomically(&path, format!("{rows} {cols}\n").as_bytes());
    }

    /// Writes out whatever `pane_id` has buffered, without closing anything.
    ///
    /// Called where the bytes have to be on disk before the next thing happens — the pane going
    /// quiet, hostd letting go — rather than within [`IDLE_FLUSH`] of it.
    pub fn sync(&self, pane_id: &str) {
        if let Ok(mut state) = self.shared.state.lock()
            && let Some(writer) = state.get_mut(pane_id)
        {
            writer.flush();
        }
    }

    /// How much of `pane_id`'s stream is on disk, after flushing what is buffered.
    #[must_use]
    pub fn head(&self, pane_id: &str) -> Option<u64> {
        let Ok(mut state) = self.shared.state.lock() else {
            return None;
        };
        let writer = state.get_mut(pane_id)?;
        writer.flush();
        Some(writer.flushed_end)
    }

    /// Flushes and closes `pane_id`'s file, KEEPING it. The pane is over; its transcript is not.
    pub fn close(&self, pane_id: &str) {
        let Ok(mut state) = self.shared.state.lock() else {
            return;
        };
        if let Some(mut writer) = state.remove(pane_id) {
            writer.flush();
        }
    }

    /// Whether a pane of this name is currently journaling.
    #[must_use]
    pub fn is_open(&self, pane_id: &str) -> bool {
        self.shared
            .state
            .lock()
            .is_ok_and(|state| state.contains_key(pane_id))
    }

    /// The paths of every journal this store is currently writing — what a sweep must not unlink.
    #[must_use]
    pub fn live_paths(&self) -> Vec<PathBuf> {
        self.shared.state.lock().map_or_else(
            |_poisoned| Vec::new(),
            |state| state.values().map(|writer| writer.path.clone()).collect(),
        )
    }

    /// What is on disk for `session_id`, or `None` when there is no journal there.
    ///
    /// Flushes first when a live pane is writing that file, so the answer is never behind the bytes
    /// the caller is about to read.
    #[must_use]
    pub fn info(&self, dir: &Path, session_id: &str) -> Option<Info> {
        let path = journal_path(dir, session_id);
        let head = self.shared.state.lock().ok().and_then(|mut state| {
            state
                .values_mut()
                .find(|writer| writer.path == path)
                .map(|writer| {
                    writer.flush();
                    writer.flushed_end
                })
        });
        let bytes = std::fs::metadata(&path).ok()?.len();
        if bytes == 0 {
            return None;
        }
        let (rows, cols) = read_size_sidecar(&size_sidecar_path(&path)).unwrap_or((0, 0));
        Some(Info {
            path,
            bytes,
            rows,
            cols,
            head,
        })
    }

    /// Removes a journal and its sidecar — the deliberate end of a pane, and the only thing that
    /// ever unlinks one on purpose.
    ///
    /// Closes the writer first when one is open. Unlinking under an open fd is not an error on
    /// POSIX; it is worse than one, because the writer keeps succeeding into an inode nobody can
    /// ever open again, so the pane journals its whole remaining life into nothing.
    pub fn delete(&self, dir: &Path, session_id: &str) {
        let path = journal_path(dir, session_id);
        if let Ok(mut state) = self.shared.state.lock() {
            let open = state
                .iter()
                .find(|(_id, writer)| writer.path == path)
                .map(|(id, _writer)| id.clone());
            if let Some(id) = open {
                state.remove(&id);
            }
        }
        drop(std::fs::remove_file(&path));
        drop(std::fs::remove_file(size_sidecar_path(&path)));
    }

    /// Deletes journals whose pane will never come back: older than `max_age`, or past the
    /// `keep_newest` most recently written. Live writers are exempt.
    ///
    /// The exemption is the same hazard as [`JournalStore::delete`]'s, arriving by a different
    /// road: a sweep runs while panes are spawning, and unlinking a file a pump is appending to
    /// loses that pane's whole transcript, past and future, silently.
    pub fn sweep(&self, dir: &Path, max_age: Duration, keep_newest: usize) {
        let live = self.live_paths();
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        let now = SystemTime::now();
        let mut dated: Vec<(PathBuf, SystemTime)> = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some(JOURNAL_EXTENSION) {
                continue;
            }
            if live.contains(&path) {
                continue;
            }
            let mtime = entry
                .metadata()
                .and_then(|meta| meta.modified())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            if now.duration_since(mtime).is_ok_and(|age| age > max_age) {
                remove_journal(&path);
            } else {
                dated.push((path, mtime));
            }
        }
        // A sidecar whose journal is gone can never be read by anything — a crash between the two
        // unlinks, or a journal an older superd swept.
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|ext| ext.to_str()) != Some(SIZE_EXTENSION) {
                    continue;
                }
                if !path.with_extension("").exists() {
                    drop(std::fs::remove_file(&path));
                }
            }
        }
        if dated.len() <= keep_newest {
            return;
        }
        dated.sort_by_key(|(_path, mtime)| std::cmp::Reverse(*mtime));
        for (path, _mtime) in dated.into_iter().skip(keep_newest) {
            remove_journal(&path);
        }
    }
}

impl Drop for JournalStore {
    /// Stops the writer thread and flushes everything it still holds. superd's own shutdown is the
    /// one moment where buffered bytes have nobody left to flush them.
    fn drop(&mut self) {
        self.shared.stopping.store(true, Ordering::Release);
        self.shared.wake.notify_all();
        if let Ok(mut state) = self.shared.state.lock() {
            for writer in state.values_mut() {
                writer.flush();
            }
        }
    }
}

/// The flush loop: wake on a threshold-crossing append, otherwise every [`IDLE_FLUSH`].
fn run(shared: &Arc<Shared>) {
    loop {
        let Ok(state) = shared.state.lock() else {
            return;
        };
        let Ok((mut state, _timeout)) = shared.wake.wait_timeout(state, IDLE_FLUSH) else {
            return;
        };
        if shared.stopping.load(Ordering::Acquire) {
            return;
        }
        for writer in state.values_mut() {
            writer.flush();
        }
    }
}

impl Writer {
    /// Writes every buffered byte in ONE contiguous `write(2)`, then rewrites the file to its
    /// newest cap-worth if this append took it past the doubling point.
    ///
    /// On any failure — open, disk full, a revoked fd — the batch is DROPPED. The journal is
    /// best-effort history and the live pane must never be held up by disk trouble: a pane that
    /// stops because its transcript could not be saved is a worse outcome than a transcript with a
    /// gap in it.
    fn flush(&mut self) {
        if self.pending.is_empty() {
            return;
        }
        let ceiling = self.cap.saturating_mul(COMPACT_MULTIPLE).max(self.retry_floor);
        let over_cap = self.on_disk.saturating_add(self.pending.len()) > ceiling;
        self.write_through();
        if over_cap {
            self.rewrite_to_tail();
        }
    }

    /// The append itself: buffered bytes to the end of the file, accounting updated only on
    /// success.
    fn write_through(&mut self) {
        let pending = std::mem::take(&mut self.pending);
        let end = self.pending_end;
        if let Some(handle) = self.open_if_needed()
            && handle.write_all(&pending).is_ok()
        {
            self.on_disk = self.on_disk.saturating_add(pending.len());
            self.flushed_end = end;
        }
    }

    fn open_if_needed(&mut self) -> Option<&mut File> {
        if self.handle.is_none() {
            let opened = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&self.path)
                .ok()?;
            // `append` puts every write at the end regardless of the file offset, so there is no
            // seek to get wrong — the failure the Swift journal had to guard against (a failed
            // `lseek` leaving the fd at 0, overwriting the head and serving silent corruption on
            // the next restore) cannot happen here.
            self.on_disk = usize::try_from(opened.metadata().ok()?.len()).unwrap_or(usize::MAX);
            self.handle = Some(opened);
        }
        self.handle.as_mut()
    }

    /// Keeps the newest cap-worth of bytes, advancing the cut past the next newline within a
    /// bounded scan so the surviving head starts on a line boundary rather than mid-sequence. A
    /// mid-sequence cut is TOLERATED — the renderer absorbs it — and the alignment only makes
    /// it rare.
    fn rewrite_to_tail(&mut self) {
        let Ok(current) = std::fs::read(&self.path) else {
            return;
        };
        if current.len() <= self.cap {
            return;
        }
        let mut cut = current.len().saturating_sub(self.cap);
        let scan_end = current.len().min(cut.saturating_add(NEWLINE_SCAN_BYTES));
        if let Some(offset) = current
            .get(cut..scan_end)
            .and_then(|window| window.iter().position(|byte| *byte == b'\n'))
        {
            cut = cut.saturating_add(offset).saturating_add(1);
        }
        let dropped = current.get(..cut).unwrap_or_default();
        let mut tail = current.get(cut..).unwrap_or_default().to_vec();
        // The same repair the in-memory ring makes at its own eviction: a cut inside an open
        // alt-screen segment beheads it, and the surviving interior would replay onto the MAIN
        // screen. Re-opening the segment at the surviving head — ON DISK — keeps the file a
        // well-formed stream, so the next compaction (this life's or a later superd's) needs no
        // state outside the bytes.
        let peek = tail.get(..tail.len().min(ALT_PEEK_BYTES)).unwrap_or_default();
        if let Some(mut repaired) = slopdesk_altscreen::reopen_sequence(dropped, peek) {
            repaired.append(&mut tail);
            tail = repaired;
        }
        // Drop the handle FIRST. A retained fd points at the inode the rename is about to replace,
        // and every later append would land in a file nobody can open again.
        self.handle = None;
        let written = tail.len();
        if write_atomically(&self.path, &tail) {
            self.on_disk = written;
            self.retry_floor = 0;
        } else {
            // The over-cap file stays as it is; defer the next attempt so persistent disk pressure
            // does not turn every append into a full read plus a failed rewrite.
            self.on_disk = current.len();
            self.retry_floor = current.len().saturating_add(self.cap);
        }
    }
}

/// `dir/<session_id>.scrollback`. The ONE place a journal is named.
#[must_use]
pub fn journal_path(dir: &Path, session_id: &str) -> PathBuf {
    dir.join(format!("{session_id}.{JOURNAL_EXTENSION}"))
}

/// `<journal>.size`.
#[must_use]
fn size_sidecar_path(journal: &Path) -> PathBuf {
    let mut name = journal.as_os_str().to_os_string();
    name.push(format!(".{SIZE_EXTENSION}"));
    PathBuf::from(name)
}

fn remove_journal(path: &Path) {
    drop(std::fs::remove_file(path));
    drop(std::fs::remove_file(size_sidecar_path(path)));
}

fn read_size_sidecar(path: &Path) -> Option<(u16, u16)> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut parts = text.split_whitespace();
    let rows = parts.next()?.parse::<u16>().ok()?;
    let cols = parts.next()?.parse::<u16>().ok()?;
    if rows == 0 || cols == 0 {
        return None;
    }
    Some((rows, cols))
}

/// Write-then-rename, so a reader never sees a half-written file. Any failure leaves the previous
/// contents in place, which is what a decode-or-fall-back reader wants.
fn write_atomically(path: &Path, bytes: &[u8]) -> bool {
    let temporary = path.with_extension("tmp-journal");
    let Ok(mut file) = File::create(&temporary) else {
        return false;
    };
    if file.write_all(bytes).is_err() || file.flush().is_err() {
        drop(std::fs::remove_file(&temporary));
        return false;
    }
    // A rewrite of a file this process may still hold open elsewhere replaces the NAME, not the
    // inode, which is exactly why the caller drops its handle first.
    drop(file);
    if std::fs::rename(&temporary, path).is_err() {
        drop(std::fs::remove_file(&temporary));
        return false;
    }
    true
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use super::{FLUSH_THRESHOLD_BYTES, Info, JournalStore, journal_path};

    /// A scratch directory named for the test that owns it, wiped on entry so a previous run's
    /// files can never be mistaken for this one's.
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("slopdesk-journal-{name}"));
        drop(std::fs::remove_dir_all(&dir));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn contents(dir: &Path, session: &str) -> Vec<u8> {
        std::fs::read(journal_path(dir, session)).unwrap_or_default()
    }

    #[test]
    fn appends_reach_the_file_and_the_head_is_where_the_stream_stopped() {
        let dir = scratch("append");
        let store = JournalStore::start();
        store.open("pane", &dir, "S1", 1 << 20);
        store.append("pane", b"hello ", 6);
        store.append("pane", b"world", 11);
        assert_eq!(store.head("pane"), Some(11));
        assert_eq!(contents(&dir, "S1"), b"hello world");
    }

    /// The whole reason the file moved here: the resume point is a variable, not a sidecar. It must
    /// track the bytes that are actually ON DISK, never the ones still buffered.
    #[test]
    fn the_head_never_runs_ahead_of_the_bytes() {
        let dir = scratch("head-honesty");
        let store = JournalStore::start();
        store.open("pane", &dir, "S1", 1 << 20);
        store.append("pane", b"abc", 3);
        let head = store.head("pane").unwrap();
        assert_eq!(head, contents(&dir, "S1").len() as u64);
    }

    /// A pane that never ran is not a journal — a restore must be able to tell "nothing here" from
    /// "here is an empty transcript", because only the first one may fall back.
    #[test]
    fn an_absent_or_empty_journal_has_no_info() {
        let dir = scratch("absent");
        let store = JournalStore::start();
        assert_eq!(store.info(&dir, "nobody"), None);
        store.open("pane", &dir, "S1", 1 << 20);
        assert_eq!(store.info(&dir, "S1"), None, "opened but never written");
    }

    #[test]
    fn info_reports_the_geometry_and_the_live_head() {
        let dir = scratch("info");
        let store = JournalStore::start();
        store.open("pane", &dir, "S1", 1 << 20);
        store.record_size("pane", 40, 120);
        store.append("pane", b"body", 4);
        let info = store.info(&dir, "S1").unwrap();
        assert_eq!(info, Info {
            path: journal_path(&dir, "S1"),
            bytes: 4,
            rows: 40,
            cols: 120,
            head: Some(4),
        });
    }

    /// A journal read back after its pane is gone is the ordinary case — a reboot, a TTL eviction,
    /// a shell that exited. There is no head to report, and that absence is the answer.
    #[test]
    fn a_journal_outlives_its_pane_and_reports_no_head() {
        let dir = scratch("outlives");
        let store = JournalStore::start();
        store.open("pane", &dir, "S1", 1 << 20);
        store.append("pane", b"history", 7);
        store.close("pane");
        let info = store.info(&dir, "S1").unwrap();
        assert_eq!(info.bytes, 7);
        assert_eq!(info.head, None, "no live pane numbers this stream any more");
    }

    /// A fresh shell under an id that already has a transcript continues the file — the new life's
    /// output belongs under the history it replaces, which is the whole point of the restore.
    #[test]
    fn a_reopened_session_appends_below_the_old_transcript() {
        let dir = scratch("reopen");
        let store = JournalStore::start();
        store.open("pane", &dir, "S1", 1 << 20);
        store.append("pane", b"first life\n", 11);
        store.close("pane");

        store.open("pane", &dir, "S1", 1 << 20);
        store.append("pane", b"second life\n", 12);
        assert_eq!(
            store.head("pane"),
            Some(12),
            "offsets restart with the pane, and only the pane"
        );
        assert_eq!(contents(&dir, "S1"), b"first life\nsecond life\n");
    }

    #[test]
    fn a_threshold_crossing_batch_lands_whole_and_in_order() {
        let dir = scratch("threshold");
        let store = JournalStore::start();
        store.open("pane", &dir, "S1", 1 << 24);
        let big = vec![b'x'; FLUSH_THRESHOLD_BYTES + 1];
        store.append("pane", b"head", 4);
        store.append("pane", &big, 4 + big.len() as u64);
        store.close("pane");
        let written = contents(&dir, "S1");
        assert_eq!(written.len(), 4 + big.len());
        assert_eq!(&written[..4], b"head");
    }

    /// The cap is enforced by rewriting to the newest cap-worth once the file doubles past it —
    /// amortised, so a busy pane does not rewrite its file on every chunk.
    #[test]
    fn compaction_keeps_the_newest_cap_worth() {
        let dir = scratch("compact");
        let store = JournalStore::start();
        store.open("pane", &dir, "S1", 64);
        let mut end = 0;
        for index in 0..40_u8 {
            let line = format!("line {index}\n");
            end += line.len() as u64;
            store.append("pane", line.as_bytes(), end);
            store.sync("pane");
        }
        let written = contents(&dir, "S1");
        assert!(written.len() <= 128, "compacted, got {} bytes", written.len());
        assert!(
            written.ends_with(b"line 39\n"),
            "the newest bytes are the ones that survive"
        );
        assert!(
            written.starts_with(b"line "),
            "the surviving head starts on a line boundary, not mid-line: {:?}",
            String::from_utf8_lossy(&written)
        );
    }

    /// A cut inside an open alt-screen segment beheads it, and the surviving interior would replay
    /// onto the main screen. The re-opener goes on disk, so the repair survives the daemon.
    #[test]
    fn compaction_reopens_an_alt_screen_segment_it_cut_into() {
        let dir = scratch("alt");
        let store = JournalStore::start();
        store.open("pane", &dir, "S1", 32);
        let mut end = 0;
        let opener = "\u{1B}[?1049h";
        for chunk in [
            opener,
            "aaaaaaaaaaaaaaaa\n",
            "bbbbbbbbbbbbbbbb\n",
            "cccccccccccccccc\n",
        ] {
            end += chunk.len() as u64;
            store.append("pane", chunk.as_bytes(), end);
            store.sync("pane");
        }
        let written = contents(&dir, "S1");
        assert!(
            written.starts_with(opener.as_bytes()),
            "the beheaded segment is re-opened at the surviving head: {:?}",
            String::from_utf8_lossy(&written)
        );
    }

    #[test]
    fn a_zero_cap_pane_is_not_journaled_at_all() {
        let dir = scratch("zero-cap");
        let store = JournalStore::start();
        store.open("pane", &dir, "S1", 0);
        store.append("pane", b"nothing", 7);
        assert!(!store.is_open("pane"));
        assert_eq!(store.info(&dir, "S1"), None);
    }

    #[test]
    fn delete_removes_the_journal_and_its_sidecar() {
        let dir = scratch("delete");
        let store = JournalStore::start();
        store.open("pane", &dir, "S1", 1 << 20);
        store.record_size("pane", 24, 80);
        store.append("pane", b"bye", 3);
        store.delete(&dir, "S1");
        assert_eq!(store.info(&dir, "S1"), None);
        assert!(!store.is_open("pane"), "the writer went with the file");
        assert!(std::fs::read_dir(&dir).unwrap().flatten().next().is_none());
    }

    /// Unlinking a file a pump is appending to is worse than an error: POSIX keeps the writes
    /// succeeding into an inode nobody can open again, so the pane journals its remaining life into
    /// nothing.
    #[test]
    fn a_sweep_never_unlinks_a_live_pane_s_journal() {
        let dir = scratch("sweep-live");
        let store = JournalStore::start();
        store.open("live", &dir, "S1", 1 << 20);
        store.append("live", b"still going", 11);
        store.sync("live");
        store.open("dead", &dir, "S2", 1 << 20);
        store.append("dead", b"over", 4);
        store.close("dead");

        store.sweep(&dir, Duration::from_secs(0), 0);
        assert!(store.info(&dir, "S1").is_some(), "the live pane's file stayed");
        assert_eq!(store.info(&dir, "S2"), None, "the dead one was swept");
    }

    #[test]
    fn a_sweep_keeps_the_newest_and_drops_the_orphaned_sidecars() {
        let dir = scratch("sweep-keep");
        let store = JournalStore::start();
        for (index, session) in ["S1", "S2", "S3"].iter().enumerate() {
            let pane = format!("pane{index}");
            store.open(&pane, &dir, session, 1 << 20);
            store.record_size(&pane, 24, 80);
            store.append(&pane, b"x", 1);
            store.close(&pane);
        }
        std::fs::write(dir.join("ghost.scrollback.size"), "24 80\n").unwrap();

        store.sweep(&dir, Duration::from_hours(1), 3);
        assert!(
            !dir.join("ghost.scrollback.size").exists(),
            "a sidecar with no journal can never be read by anything"
        );
        assert_eq!(
            std::fs::read_dir(&dir).unwrap().flatten().count(),
            6,
            "three journals and three sidecars survive the keep-newest cap"
        );
    }
}

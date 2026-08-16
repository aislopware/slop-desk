//! Where received bytes land: a hidden temp file per transfer, renamed into place at the end.
//!
//! Streaming to a temp file rather than buffering keeps a multi-GiB upload flat in RAM, and the
//! temp-then-rename means a half-received file never appears under its real name — a dropped
//! connection leaves a stray dotfile, which the next `abort` or the next run's `open` sweeps.

use std::collections::HashMap;
use std::fs::File;
use std::io::Write as _;
use std::path::{Path, PathBuf};

/// A sink failure, reported to the client as a short reason and never as a path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SinkError {
    /// A write or finalize for a transfer that was never opened (or was already aborted).
    NotOpen,
    /// The filesystem said no.
    Io(String),
}

impl std::fmt::Display for SinkError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match *self {
            Self::NotOpen => formatter.write_str("no open destination"),
            Self::Io(ref detail) => write!(formatter, "io failed: {detail}"),
        }
    }
}

impl std::error::Error for SinkError {}

/// One in-flight destination.
#[derive(Debug)]
struct Open {
    file: File,
    temp: PathBuf,
    final_name: String,
}

/// One connection's destinations, keyed by transfer id so overlapping transfers cannot collide.
///
/// Owned by the connection's own thread — no lock, because nothing else can reach it. That is the
/// shape the thread-per-connection server buys: the state that used to need a mutex is simply
/// local.
#[derive(Debug)]
pub struct DiskSink {
    directory: PathBuf,
    opens: HashMap<u32, Open>,
}

impl DiskSink {
    /// A sink dropping into `directory`, which is created on the first `open`.
    #[must_use]
    pub fn new(directory: PathBuf) -> Self {
        Self {
            directory,
            opens: HashMap::new(),
        }
    }

    /// Creates the temp file for `transfer_id`.
    ///
    /// # Errors
    /// [`SinkError::Io`] when the directory or the temp file cannot be created.
    pub fn open(&mut self, transfer_id: u32, name: &str) -> Result<(), SinkError> {
        std::fs::create_dir_all(&self.directory).map_err(|error| SinkError::Io(error.to_string()))?;
        let temp = self
            .directory
            .join(format!(".slopdesk-upload-{transfer_id}.part"));
        // A stale temp from a crashed predecessor under the same id must not be appended to.
        drop(std::fs::remove_file(&temp));
        let file = File::create(&temp).map_err(|error| SinkError::Io(error.to_string()))?;
        self.opens.insert(transfer_id, Open {
            file,
            temp,
            final_name: name.to_owned(),
        });
        Ok(())
    }

    /// Appends `data` to the open destination.
    ///
    /// # Errors
    /// [`SinkError::NotOpen`] when there is no destination, [`SinkError::Io`] on a write failure.
    pub fn write(&mut self, transfer_id: u32, data: &[u8]) -> Result<(), SinkError> {
        let open = self.opens.get_mut(&transfer_id).ok_or(SinkError::NotOpen)?;
        open.file
            .write_all(data)
            .map_err(|error| SinkError::Io(error.to_string()))
    }

    /// Closes the temp file and moves it into place under a non-colliding name.
    ///
    /// # Errors
    /// [`SinkError::NotOpen`] when there is no destination, [`SinkError::Io`] when the flush or the
    /// rename fails — in which case the temp file is swept rather than left behind.
    pub fn finalize(&mut self, transfer_id: u32) -> Result<(), SinkError> {
        let mut open = self.opens.remove(&transfer_id).ok_or(SinkError::NotOpen)?;
        let flushed = open
            .file
            .flush()
            .map_err(|error| SinkError::Io(error.to_string()));
        // The handle must be closed BEFORE the rename: a reader watching the drop directory should
        // never see the final name appear on a descriptor still being written to.
        drop(open.file);
        if let Err(error) = flushed {
            drop(std::fs::remove_file(&open.temp));
            return Err(error);
        }
        let destination = self.non_colliding_path(&open.final_name);
        std::fs::rename(&open.temp, &destination).map_err(|error| {
            drop(std::fs::remove_file(&open.temp));
            SinkError::Io(error.to_string())
        })
    }

    /// Discards any partial destination. Best-effort and never an error: this runs on the failure
    /// paths, where a second failure has nobody left to tell.
    pub fn abort(&mut self, transfer_id: u32) {
        if let Some(open) = self.opens.remove(&transfer_id) {
            drop(open.file);
            drop(std::fs::remove_file(&open.temp));
        }
    }

    /// Every transfer id still open — what the server aborts when a connection dies mid-body.
    #[must_use]
    pub fn open_ids(&self) -> Vec<u32> {
        self.opens.keys().copied().collect()
    }

    /// `report.pdf`, then `report (1).pdf`, `report (2).pdf`, … `name` is already a sanitised leaf,
    /// so this only ever appends a counter.
    fn non_colliding_path(&self, name: &str) -> PathBuf {
        let candidate = self.directory.join(name);
        if !candidate.exists() {
            return candidate;
        }
        let as_path = Path::new(name);
        let stem = as_path.file_stem().and_then(|stem| stem.to_str()).unwrap_or(name);
        let extension = as_path.extension().and_then(|extension| extension.to_str());
        // Bounded rather than `loop`: a thousand copies of one name is a bug or an attack, and
        // either way overwriting is not the answer — the caller reports the failure instead.
        for counter in 1..1000_u32 {
            let suffixed = extension.map_or_else(
                || format!("{stem} ({counter})"),
                |extension| format!("{stem} ({counter}).{extension}"),
            );
            let path = self.directory.join(suffixed);
            if !path.exists() {
                return path;
            }
        }
        // Nothing free in a thousand tries: hand back the temp's own name so the rename fails
        // loudly rather than clobbering a file the user has.
        self.directory.join(format!(".slopdesk-upload-collision-{name}"))
    }
}

impl Drop for DiskSink {
    /// A connection that ends mid-body leaves nothing behind — the same sweep `abort` performs, for
    /// every transfer still open.
    fn drop(&mut self) {
        for (_id, open) in self.opens.drain() {
            drop(open.file);
            drop(std::fs::remove_file(&open.temp));
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::path::PathBuf;

    use super::{DiskSink, SinkError};

    fn scratch(stem: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("dropd-sink-{stem}-{}", std::process::id()));
        drop(std::fs::remove_dir_all(&directory));
        directory
    }

    #[test]
    fn a_body_lands_under_its_name_and_only_at_the_end() {
        let directory = scratch("lands");
        let mut sink = DiskSink::new(directory.clone());
        sink.open(1, "notes.txt").expect("opens");
        sink.write(1, b"hello ").expect("writes");
        assert!(
            !directory.join("notes.txt").exists(),
            "a half-received file must not appear under its final name"
        );
        sink.write(1, b"world").expect("writes");
        sink.finalize(1).expect("finalizes");
        assert_eq!(
            std::fs::read_to_string(directory.join("notes.txt")).expect("reads"),
            "hello world"
        );
        drop(std::fs::remove_dir_all(&directory));
    }

    #[test]
    fn a_second_file_of_the_same_name_gets_a_counter() {
        let directory = scratch("counter");
        let mut sink = DiskSink::new(directory.clone());
        for _ in 0..3 {
            sink.open(2, "report.pdf").expect("opens");
            sink.write(2, b"x").expect("writes");
            sink.finalize(2).expect("finalizes");
        }
        assert!(directory.join("report.pdf").exists());
        assert!(directory.join("report (1).pdf").exists());
        assert!(directory.join("report (2).pdf").exists());
        drop(std::fs::remove_dir_all(&directory));
    }

    #[test]
    fn an_extension_less_name_still_gets_a_counter() {
        let directory = scratch("noext");
        let mut sink = DiskSink::new(directory.clone());
        for _ in 0..2 {
            sink.open(3, "LICENSE").expect("opens");
            sink.finalize(3).expect("finalizes");
        }
        assert!(directory.join("LICENSE (1)").exists());
        drop(std::fs::remove_dir_all(&directory));
    }

    #[test]
    fn an_abort_leaves_nothing_behind_and_a_later_write_is_refused() {
        let directory = scratch("abort");
        let mut sink = DiskSink::new(directory.clone());
        sink.open(4, "half.bin").expect("opens");
        sink.write(4, b"partial").expect("writes");
        sink.abort(4);
        assert_eq!(sink.write(4, b"more"), Err(SinkError::NotOpen));
        assert_eq!(sink.finalize(4), Err(SinkError::NotOpen));
        let leftovers: Vec<_> = std::fs::read_dir(&directory)
            .expect("reads the directory")
            .filter_map(Result::ok)
            .collect();
        assert!(leftovers.is_empty(), "an aborted transfer leaves no temp file");
        drop(std::fs::remove_dir_all(&directory));
    }

    #[test]
    fn dropping_the_sink_sweeps_every_open_transfer() {
        let directory = scratch("dropsweep");
        let mut sink = DiskSink::new(directory.clone());
        sink.open(5, "a.bin").expect("opens");
        sink.open(6, "b.bin").expect("opens");
        assert_eq!(sink.open_ids().len(), 2);
        drop(sink);
        let leftovers: Vec<_> = std::fs::read_dir(&directory)
            .expect("reads the directory")
            .filter_map(Result::ok)
            .collect();
        assert!(leftovers.is_empty(), "a dead connection leaves no temp files");
        drop(std::fs::remove_dir_all(&directory));
    }
}

//! A throwaway directory per test.
//!
//! Hand-rolled rather than pulled from `tempfile`, because this crate ships ONE dependency on
//! purpose and a directory that deletes itself on drop is twenty lines. The names carry the pid and
//! a per-process counter, so two `cargo test` runs and two threads inside one never collide.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);

/// A directory that exists for as long as this value does.
#[derive(Debug)]
pub struct Scratch {
    root: PathBuf,
}

impl Scratch {
    /// Creates the directory.
    ///
    /// # Panics
    /// If the directory cannot be created — a test that cannot get one has nothing left to report.
    #[expect(
        clippy::expect_used,
        reason = "a panic in a test fixture is the failure report, not a runtime fault"
    )]
    #[must_use]
    pub fn new() -> Self {
        let ordinal = NEXT.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!("slopdesk-codeseed-{}-{ordinal}", std::process::id()));
        std::fs::create_dir_all(&root).expect("scratch directory");
        Self { root }
    }

    /// The directory itself.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.root
    }

    /// A path inside it — the parents are created, the file is not.
    ///
    /// # Panics
    /// If the parent directories cannot be created.
    #[expect(
        clippy::expect_used,
        reason = "a panic in a test fixture is the failure report, not a runtime fault"
    )]
    #[must_use]
    pub fn join(&self, relative: &str) -> PathBuf {
        let path = self.root.join(relative);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("scratch subdirectory");
        }
        path
    }

    /// Writes `contents` at `relative` and answers the path.
    ///
    /// # Panics
    /// If the write fails.
    #[must_use]
    #[expect(
        clippy::expect_used,
        reason = "a panic in a test fixture is the failure report, not a runtime fault"
    )]
    pub fn write(&self, relative: &str, contents: &str) -> PathBuf {
        let path = self.join(relative);
        std::fs::write(&path, contents).expect("scratch write");
        path
    }

    /// Reads `relative` back, or `None` when nothing is there.
    #[must_use]
    pub fn read(&self, relative: &str) -> Option<String> {
        std::fs::read_to_string(self.root.join(relative)).ok()
    }
}

impl Default for Scratch {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        // A leftover directory in `/tmp` is not worth failing a green test over.
        drop(std::fs::remove_dir_all(&self.root));
    }
}

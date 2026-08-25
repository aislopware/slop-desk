//! Where a pin lands, and whether it is already there.
//!
//! Everything in this module is a function of a path and a string. It performs no I/O of its own —
//! the caller reads the stamp and hands the contents over — so the layout the provisioner commits
//! to is testable without a filesystem, and the `--check` half runs the SAME decision the
//! provisioning half does rather than a second reading of it.

use std::path::{Path, PathBuf};

use crate::lock::Pin;

/// The `.prefix/` tree a run reads and writes.
///
/// A value rather than four `const`s so a test can point the whole layout at a temporary directory
/// and assert what would be written, which is the one thing the shell version could not do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    /// `ThirdParty/tools/` — where the lock and `vendor/` live.
    pub tools: PathBuf,
}

impl Layout {
    /// The layout rooted at a `ThirdParty/tools` directory.
    #[must_use]
    pub fn new(tools: impl Into<PathBuf>) -> Self {
        Self { tools: tools.into() }
    }

    /// The pin file.
    #[must_use]
    pub fn lock(&self) -> PathBuf {
        self.tools.join("tools.lock")
    }

    /// The gitignored install root.
    #[must_use]
    pub fn prefix(&self) -> PathBuf {
        self.tools.join(".prefix")
    }

    /// Where the symlinks a locator searches live.
    #[must_use]
    pub fn bin(&self) -> PathBuf {
        self.prefix().join("bin")
    }

    /// The TRANSFER cache — archives live here only between download and extraction.
    #[must_use]
    pub fn cache(&self) -> PathBuf {
        self.prefix().join(".cache")
    }

    /// Committed dependencies, the ones that are never downloaded.
    #[must_use]
    pub fn vendor(&self) -> PathBuf {
        self.tools.join("vendor")
    }

    /// Where `pin` is unpacked. Versioned, so two versions sit side by side.
    #[must_use]
    pub fn target(&self, pin: &Pin) -> PathBuf {
        self.prefix().join(&pin.name).join(&pin.version)
    }

    /// The executable inside the unpacked tree.
    #[must_use]
    pub fn binary(&self, pin: &Pin) -> PathBuf {
        self.target(pin).join(&pin.binary)
    }

    /// The committed file a [`Kind::File`](crate::lock::Kind::File) pin verifies in place.
    #[must_use]
    pub fn vendored(&self, pin: &Pin) -> PathBuf {
        self.vendor().join(&pin.binary)
    }

    /// The record of what is installed, one file per pin.
    #[must_use]
    pub fn stamp(&self, pin: &Pin) -> PathBuf {
        self.prefix().join(".stamp").join(&pin.name)
    }

    /// The symlink a locator resolves.
    #[must_use]
    pub fn link(&self, pin: &Pin) -> PathBuf {
        self.bin().join(&pin.name)
    }

    /// Where the archive is staged between download and extraction.
    ///
    /// The URL's last segment is carried into the name so two pins that share a version cannot
    /// collide, and a segment that is empty or path-like degrades to the pin's own name rather than
    /// escaping the cache — a lock file is a human's text, and `..` in a URL tail must not become
    /// `..` in a path.
    #[must_use]
    pub fn archive(&self, pin: &Pin) -> PathBuf {
        let tail = pin
            .url
            .rsplit('/')
            .next()
            .filter(|segment| {
                !segment.is_empty() && !segment.contains(['/', '\\']) && *segment != ".." && *segment != "."
            })
            .unwrap_or(pin.name.as_str());
        self.cache().join(format!("{}-{}-{tail}", pin.name, pin.version))
    }

    /// The relative link target, so the whole checkout stays movable — an absolute one breaks the
    /// moment the tree is renamed, and this is exactly the tree people keep several copies of.
    #[must_use]
    pub fn link_target(pin: &Pin) -> PathBuf {
        Path::new("..")
            .join(&pin.name)
            .join(&pin.version)
            .join(&pin.binary)
    }
}

/// The line a stamp holds: the version and digest currently installed.
#[must_use]
pub fn stamp_contents(pin: &Pin) -> String {
    format!("{} {}", pin.version, pin.sha256)
}

/// Whether the installed copy of `pin` is the pinned one.
///
/// Two facts, and BOTH are load-bearing. The binary being present says something was installed; the
/// stamp matching says it was THIS version at THIS digest. A lock edit is exactly the case where
/// the bytes on disk look fine and are the old bytes, and the stamp is the only thing that can
/// tell.
#[must_use]
pub fn is_current(pin: &Pin, binary_exists: bool, stamp: Option<&str>) -> bool {
    binary_exists && stamp.is_some_and(|recorded| recorded.trim() == stamp_contents(pin))
}

/// Whether `pin` is one of the names the caller asked for. An empty request means all of them.
#[must_use]
pub fn is_wanted(pin: &Pin, wanted: &[String]) -> bool {
    wanted.is_empty() || wanted.iter().any(|name| name == &pin.name)
}

#[cfg(test)]
mod tests {

    use super::{Layout, is_current, is_wanted, stamp_contents};
    use crate::lock::{Kind, Pin};

    fn pin() -> Pin {
        Pin {
            name: "adb".to_owned(),
            version: "37.0.1".to_owned(),
            kind: Kind::Zip,
            binary: "adb".to_owned(),
            url: "https://example.invalid/dir/platform-tools.zip".to_owned(),
            sha256: "a".repeat(64),
        }
    }

    #[test]
    fn the_layout_is_versioned_so_two_versions_sit_side_by_side() {
        let layout = Layout::new("/t");
        let mut older = pin();
        older.version = "36.0.0".to_owned();
        assert_ne!(layout.target(&pin()), layout.target(&older));
        assert_eq!(layout.link(&pin()), layout.link(&older), "one link, two roots");
    }

    #[test]
    fn the_link_target_is_relative_so_the_checkout_stays_movable() {
        let target = Layout::link_target(&pin());
        assert!(target.is_relative());
        assert_eq!(target.to_string_lossy(), "../adb/37.0.1/adb");
    }

    #[test]
    fn the_archive_name_carries_the_urls_last_segment() {
        let layout = Layout::new("/t");
        assert!(
            layout
                .archive(&pin())
                .to_string_lossy()
                .ends_with("adb-37.0.1-platform-tools.zip")
        );
    }

    /// A lock file is a human's text. A URL that ends in nothing, or in a traversal, must not
    /// become a path that leaves the cache.
    #[test]
    fn a_url_tail_that_could_escape_the_cache_degrades_to_the_pin_name() {
        let layout = Layout::new("/t");
        for tail in ["", "..", "."] {
            let mut escaping = pin();
            escaping.url = format!("https://example.invalid/{tail}");
            let archive = layout.archive(&escaping);
            assert_eq!(
                archive.parent(),
                Some(layout.cache().as_path()),
                "{tail:?} stayed in the cache"
            );
            assert!(archive.to_string_lossy().ends_with("adb-37.0.1-adb"), "{tail:?}");
        }
    }

    #[test]
    fn a_missing_binary_is_never_current_however_good_the_stamp() {
        let stamp = stamp_contents(&pin());
        assert!(!is_current(&pin(), false, Some(&stamp)));
        assert!(is_current(&pin(), true, Some(&stamp)));
    }

    /// The lock-edit case: the bytes on disk look fine and are the OLD bytes.
    #[test]
    fn a_stale_stamp_is_not_current() {
        let mut bumped = pin();
        bumped.version = "38.0.0".to_owned();
        let old = stamp_contents(&pin());
        assert!(!is_current(&bumped, true, Some(&old)));

        let mut redigested = pin();
        redigested.sha256 = "b".repeat(64);
        assert!(!is_current(&redigested, true, Some(&old)));
    }

    #[test]
    fn an_absent_stamp_is_not_current() {
        assert!(!is_current(&pin(), true, None));
    }

    /// The shell wrote the stamp with `printf '%s %s'` — no newline. A stamp a human or an editor
    /// has added one to still names the same install.
    #[test]
    fn a_trailing_newline_in_a_stamp_does_not_force_a_re_download() {
        let stamp = format!("{}\n", stamp_contents(&pin()));
        assert!(is_current(&pin(), true, Some(&stamp)));
    }

    #[test]
    fn an_empty_request_wants_everything_and_a_named_one_wants_only_it() {
        assert!(is_wanted(&pin(), &[]));
        assert!(is_wanted(&pin(), &["adb".to_owned()]));
        assert!(!is_wanted(&pin(), &["code-server".to_owned()]));
        assert!(is_wanted(&pin(), &["code-server".to_owned(), "adb".to_owned()]));
    }
}

//! Unpacking an archive, with its single top-level directory stripped.
//!
//! Every pinned archive has exactly ONE top-level directory whose name carries the version, which
//! is redundant with the `<name>/<version>/` it is being extracted into — so it is stripped. That
//! is a claim about upstream, and the point of doing it in-process is that a future release which
//! flattens its tarball is REFUSED by name here rather than landing its files one level up and
//! failing the post-extract binary check with nothing to say about why.
//!
//! ## The traversal bar
//!
//! An archive is downloaded bytes, and a member path is attacker-controlled in exactly the way a
//! digest pin does not fix — a re-cut upstream release matches no pin, but a compromised one that
//! DOES match still carries whatever paths it likes. Every member is therefore resolved against the
//! target and refused if it leaves, absolute components and `..` alike, before a single byte is
//! written.

use std::fs::{self, File};
use std::io;
use std::path::{Component, Path, PathBuf};

use crate::lock::Kind;

/// Why an archive could not be unpacked.
#[derive(Debug)]
pub enum ExtractError {
    /// The archive did not hold exactly one top-level directory.
    Shape {
        /// The archive whose layout changed.
        archive: PathBuf,
        /// How many top-level entries it actually had.
        roots: usize,
    },
    /// A member path pointed outside the target.
    Escape {
        /// The archive that carried it.
        archive: PathBuf,
        /// The member path, as the archive spelled it.
        member: String,
    },
    /// The archive or the filesystem refused.
    Io {
        /// The file the refusal was about.
        path: PathBuf,
        /// What the filesystem said.
        cause: io::Error,
    },
    /// A `file` pin never reaches here.
    Unsupported(Kind),
}

impl core::fmt::Display for ExtractError {
    fn fmt(&self, out: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Shape { archive, roots } => {
                write!(
                    out,
                    "expected one top-level directory in {}, got {roots} — the upstream archive layout \
                     changed",
                    name_of(archive)
                )
            },
            Self::Escape { archive, member } => {
                write!(
                    out,
                    "{} holds a member that points outside the target: `{member}`",
                    name_of(archive)
                )
            },
            Self::Io { path, cause } => write!(out, "{}: {cause}", path.display()),
            Self::Unsupported(kind) => {
                write!(out, "`{}` is not an archive kind", kind.as_str())
            },
        }
    }
}

impl std::error::Error for ExtractError {}

/// The archive's own name, for a message a reader can match against the lock file.
fn name_of(path: &Path) -> String {
    path.file_name().map_or_else(
        || path.display().to_string(),
        |name| name.to_string_lossy().into_owned(),
    )
}

/// Unpacks `archive` into `target`, replacing whatever was there.
///
/// # Errors
/// [`ExtractError`], naming the archive rather than the decompressor.
pub fn extract_into(kind: Kind, archive: &Path, target: &Path) -> Result<(), ExtractError> {
    let io_at = |path: &Path| {
        let path = path.to_path_buf();
        move |cause| ExtractError::Io { path, cause }
    };
    // A replace, not a merge: an in-place unpack over a previous version leaves that version's
    // orphans behind, and a binary the new release dropped would still be found by a locator.
    if target.exists() {
        fs::remove_dir_all(target).map_err(io_at(target))?;
    }
    fs::create_dir_all(target).map_err(io_at(target))?;
    match kind {
        Kind::TarGz => untar_gz(archive, target),
        Kind::Zip => unzip(archive, target),
        // Neither arrives as an archive: a `file` pin is committed in place and a `git` pin is
        // cloned, so reaching this function with either is a routing bug, not a bad download.
        Kind::File | Kind::Git => Err(ExtractError::Unsupported(kind)),
    }?;
    unquarantine(target);
    Ok(())
}

/// The gzipped-tar half.
fn untar_gz(archive: &Path, target: &Path) -> Result<(), ExtractError> {
    let io_at = |path: &Path| {
        let path = path.to_path_buf();
        move |cause| ExtractError::Io { path, cause }
    };
    let file = File::open(archive).map_err(io_at(archive))?;
    let mut tar = tar::Archive::new(flate2::read::GzDecoder::new(io::BufReader::new(file)));
    tar.set_preserve_permissions(true);
    let mut roots = std::collections::BTreeSet::new();
    for entry in tar.entries().map_err(io_at(archive))? {
        let mut entry = entry.map_err(io_at(archive))?;
        let raw = entry.path().map_err(io_at(archive))?.into_owned();
        if let Some(root) = raw.components().next() {
            roots.insert(root.as_os_str().to_owned());
        }
        let Some(stripped) = strip_one(&raw) else {
            continue; // the root directory entry itself
        };
        let destination = safe_join(target, &stripped).ok_or_else(|| {
            ExtractError::Escape {
                archive: archive.to_path_buf(),
                member: raw.display().to_string(),
            }
        })?;
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(io_at(parent))?;
        }
        entry.unpack(&destination).map_err(io_at(&destination))?;
    }
    expect_one_root(archive, roots.len())
}

/// The zip half. `unzip` has no `--strip-components`, which is why the shell needed a staging
/// directory and a lift; stripping a member path costs nothing here.
fn unzip(archive: &Path, target: &Path) -> Result<(), ExtractError> {
    let io_at = |path: &Path| {
        let path = path.to_path_buf();
        move |cause| ExtractError::Io { path, cause }
    };
    let file = File::open(archive).map_err(io_at(archive))?;
    let mut zip = zip::ZipArchive::new(io::BufReader::new(file)).map_err(|cause| {
        ExtractError::Io {
            path: archive.to_path_buf(),
            cause: io::Error::other(cause),
        }
    })?;
    let mut roots = std::collections::BTreeSet::new();
    for index in 0..zip.len() {
        let mut member = zip.by_index(index).map_err(|cause| {
            ExtractError::Io {
                path: archive.to_path_buf(),
                cause: io::Error::other(cause),
            }
        })?;
        // `enclosed_name` is the crate's OWN traversal check; a member it refuses never becomes a
        // path here, and `safe_join` below is the second, independent one.
        let Some(raw) = member.enclosed_name() else {
            return Err(ExtractError::Escape {
                archive: archive.to_path_buf(),
                member: member.name().to_owned(),
            });
        };
        if let Some(root) = raw.components().next() {
            roots.insert(root.as_os_str().to_owned());
        }
        let Some(stripped) = strip_one(&raw) else {
            continue;
        };
        let destination = safe_join(target, &stripped).ok_or_else(|| {
            ExtractError::Escape {
                archive: archive.to_path_buf(),
                member: raw.display().to_string(),
            }
        })?;
        if member.is_dir() {
            fs::create_dir_all(&destination).map_err(io_at(&destination))?;
            continue;
        }
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(io_at(parent))?;
        }
        let mut out = File::create(&destination).map_err(io_at(&destination))?;
        io::copy(&mut member, &mut out).map_err(io_at(&destination))?;
        // The executable bit is the whole reason a locator's `-x` check passes, and zip carries it
        // in an attribute the copy above does not move.
        if let Some(mode) = member.unix_mode() {
            set_mode(&destination, mode).map_err(io_at(&destination))?;
        }
    }
    expect_one_root(archive, roots.len())
}

/// The single-root claim, checked once per archive.
fn expect_one_root(archive: &Path, roots: usize) -> Result<(), ExtractError> {
    if roots == 1 {
        Ok(())
    } else {
        Err(ExtractError::Shape {
            archive: archive.to_path_buf(),
            roots,
        })
    }
}

/// `path` with its first component dropped, or [`None`] when there is nothing left — which is the
/// root directory entry itself, and has nothing to unpack.
fn strip_one(path: &Path) -> Option<PathBuf> {
    let mut components = path.components();
    components.next()?;
    let rest: PathBuf = components.as_path().to_path_buf();
    (!rest.as_os_str().is_empty()).then_some(rest)
}

/// `root` joined with `relative`, or [`None`] if the result would leave `root`.
///
/// Purely lexical, and deliberately so: it is applied BEFORE anything is written, where a
/// canonicalising check would have to create the file first to ask about it. Every component must
/// be a plain name — a root, a prefix, or a `..` is refused outright rather than resolved.
fn safe_join(root: &Path, relative: &Path) -> Option<PathBuf> {
    let mut out = root.to_path_buf();
    for component in relative.components() {
        match component {
            Component::Normal(name) => out.push(name),
            Component::CurDir => {},
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    (out != root).then_some(out)
}

/// Sets a unix mode on an extracted file.
#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

/// Non-unix hosts carry no mode; the extraction is complete without one.
#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

/// Clears `com.apple.quarantine` off everything under `root`.
///
/// Belt-and-braces: this program's own downloads never carry the attribute, because
/// `LaunchServices` sets it and a socket does not. It is here for anyone who hand-drops a tarball
/// into the cache from a browser — Gatekeeper refusing to exec a panel's server surfaces as "not
/// found", which is a miserable thing to debug. Best-effort by design: a filesystem with no
/// extended attributes at all is not a provisioning failure.
fn unquarantine(root: &Path) {
    const QUARANTINE: &str = "com.apple.quarantine";
    let mut stack = vec![root.to_path_buf()];
    while let Some(path) = stack.pop() {
        drop(xattr::remove(&path, QUARANTINE));
        let Ok(entries) = fs::read_dir(&path) else {
            continue;
        };
        for entry in entries.flatten() {
            // Symlinks are not followed: a link into the tree would be walked twice, and one out of
            // it would take the sweep somewhere it was never asked about.
            if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                stack.push(entry.path());
            } else {
                drop(xattr::remove(entry.path(), QUARANTINE));
            }
        }
    }
}

#[cfg(test)]
mod tests {

    use std::path::{Path, PathBuf};

    use super::{safe_join, strip_one};

    #[test]
    fn the_single_top_level_directory_is_what_gets_stripped() {
        assert_eq!(
            strip_one(Path::new("platform-tools/adb")),
            Some(PathBuf::from("adb"))
        );
        assert_eq!(
            strip_one(Path::new("code-server-4.135.0/bin/code-server")),
            Some(PathBuf::from("bin/code-server"))
        );
    }

    #[test]
    fn the_root_entry_itself_has_nothing_left_to_unpack() {
        assert_eq!(strip_one(Path::new("platform-tools")), None);
        assert_eq!(strip_one(Path::new("platform-tools/")), None);
        assert_eq!(strip_one(Path::new("")), None);
    }

    /// A digest pin does not fix this: a compromised release that MATCHES its pin still carries
    /// whatever member paths it likes.
    #[test]
    fn a_member_that_leaves_the_target_is_refused() {
        let root = Path::new("/prefix/adb/37.0.1");
        assert_eq!(safe_join(root, Path::new("../../../etc/passwd")), None);
        assert_eq!(safe_join(root, Path::new("/etc/passwd")), None);
        assert_eq!(safe_join(root, Path::new("a/../../b")), None);
    }

    #[test]
    fn a_plain_member_lands_under_the_target() {
        let root = Path::new("/prefix/adb/37.0.1");
        assert_eq!(
            safe_join(root, Path::new("bin/code-server")),
            Some(PathBuf::from("/prefix/adb/37.0.1/bin/code-server"))
        );
        assert_eq!(
            safe_join(root, Path::new("./adb")),
            Some(PathBuf::from("/prefix/adb/37.0.1/adb"))
        );
    }

    #[test]
    fn a_member_that_resolves_to_the_target_itself_is_not_a_file() {
        let root = Path::new("/prefix/adb/37.0.1");
        assert_eq!(safe_join(root, Path::new("")), None);
        assert_eq!(safe_join(root, Path::new(".")), None);
    }
}

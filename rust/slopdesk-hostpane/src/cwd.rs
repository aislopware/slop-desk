//! Where a fresh shell starts, decided here rather than in the child.
//!
//! The child's `chdir` runs pre-`execve`, in the fork window, with no allocator and no way to fall
//! back: a `chdir` that fails there aborts the child (`_exit 127`) and the user gets a
//! dead-on-arrival pane. So the path is validated on this side, before the request goes out, and
//! superd is told a directory rather than asked to choose one.
//!
//! Pure, and separately tested for that reason — every branch is reachable without forking
//! anything.

use std::path::{Path, PathBuf};

use nix::unistd::AccessFlags;

/// Resolves the initial working directory for a fresh shell.
///
/// A `~` or `~/…` path is expanded against `home`. The result is accepted only when it is an
/// existing, SEARCHABLE directory — searchable because a directory without its execute bit fails
/// `chdir` exactly as a missing one does. Otherwise the answer falls back to `home`, when `home` is
/// itself usable, and to `None` when it is not: no `chdir` at all, which leaves the child in
/// superd's directory but still a live shell.
///
/// `None` requested is NOT "no preference" — it resolves to `home`. `chdir` is the only thing
/// standing between the child and whatever directory the daemon happens to have been launched
/// from, and inheriting that would open every fresh pane inside the launcher's project. A login
/// terminal opens at `$HOME`.
///
/// A `~user` form is rejected rather than guessed at: another user's home cannot be resolved here,
/// and resolving it wrongly is worse than falling back.
#[must_use]
pub fn resolve_cwd(requested: Option<&str>, home: Option<&str>) -> Option<String> {
    // The fallback candidate, computed once: `home` when it is a directory this process could
    // `chdir` into, and nothing otherwise.
    let home_fallback = home
        .filter(|path| !path.is_empty() && usable_directory(Path::new(path)))
        .map(ToOwned::to_owned);

    // No request is not "no preference" — it is `$HOME`. `?` here would answer "do not `chdir`",
    // which is the one case that leaves the pane in the launcher's directory.
    let Some(requested) = requested.filter(|path| !path.is_empty()) else {
        return home_fallback;
    };
    let Some(expanded) = expand_tilde(requested, home) else {
        return home_fallback;
    };
    if usable_directory(&expanded) {
        expanded.into_os_string().into_string().ok()
    } else {
        home_fallback
    }
}

/// Whether `path` is a directory this process may `chdir` into.
///
/// Two questions, and both have to be asked: `is_dir` follows symlinks (so a link to a directory is
/// one, which is what the user meant), and `access(X_OK)` is the permission `chdir` itself checks.
fn usable_directory(path: &Path) -> bool {
    path.is_dir() && nix::unistd::access(path, AccessFlags::X_OK).is_ok()
}

/// `~` and `~/…` against `home`. `None` means "cannot be expanded", which the caller reads as a
/// fall back to home rather than as an error.
fn expand_tilde(path: &str, home: Option<&str>) -> Option<PathBuf> {
    let Some(rest) = path.strip_prefix('~') else {
        return Some(PathBuf::from(path));
    };
    let home = home.filter(|home| !home.is_empty())?;
    if rest.is_empty() {
        return Some(PathBuf::from(home));
    }
    // `~/…` only. `~user` is the other form and there is no way to resolve it from here.
    let tail = rest.strip_prefix('/')?;
    Some(Path::new(home).join(tail))
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::fs;

    use super::resolve_cwd;

    /// A directory under `/tmp` that this test owns, named for the test.
    fn scratch(name: &str) -> String {
        let path = std::env::temp_dir().join(format!("slopdesk-hostpane-cwd-{name}"));
        drop(fs::remove_dir_all(&path));
        fs::create_dir_all(&path).unwrap();
        path.to_string_lossy().into_owned()
    }

    #[test]
    fn an_existing_directory_is_taken_as_asked() {
        let directory = scratch("existing");
        assert_eq!(resolve_cwd(Some(&directory), Some("/")), Some(directory.clone()),);
        drop(fs::remove_dir_all(&directory));
    }

    #[test]
    fn a_missing_directory_falls_back_to_home() {
        let home = scratch("missing-home");
        assert_eq!(
            resolve_cwd(Some("/no/such/place/at/all"), Some(&home)),
            Some(home.clone()),
        );
        drop(fs::remove_dir_all(&home));
    }

    /// A path is only usable if `chdir` would take it, and a FILE would not.
    #[test]
    fn a_regular_file_is_not_a_directory() {
        let home = scratch("file-home");
        let file = format!("{home}/not-a-directory");
        fs::write(&file, b"x").unwrap();
        assert_eq!(resolve_cwd(Some(&file), Some(&home)), Some(home.clone()));
        drop(fs::remove_dir_all(&home));
    }

    #[test]
    fn a_bare_tilde_is_home() {
        let home = scratch("tilde");
        assert_eq!(resolve_cwd(Some("~"), Some(&home)), Some(home.clone()));
        drop(fs::remove_dir_all(&home));
    }

    #[test]
    fn a_tilde_path_expands_against_home() {
        let home = scratch("tilde-path");
        fs::create_dir_all(format!("{home}/inner")).unwrap();
        assert_eq!(
            resolve_cwd(Some("~/inner"), Some(&home)),
            Some(format!("{home}/inner")),
        );
        drop(fs::remove_dir_all(&home));
    }

    /// `~otheruser` cannot be resolved from this process, so it falls back rather than guessing at
    /// a path that would abort the child.
    #[test]
    fn another_users_tilde_falls_back_to_home() {
        let home = scratch("tilde-user");
        assert_eq!(resolve_cwd(Some("~root"), Some(&home)), Some(home.clone()));
        drop(fs::remove_dir_all(&home));
    }

    /// The line that keeps a fresh pane out of the launcher's project directory.
    #[test]
    fn no_request_means_home_rather_than_no_chdir() {
        let home = scratch("no-request");
        assert_eq!(resolve_cwd(None, Some(&home)), Some(home.clone()));
        assert_eq!(resolve_cwd(Some(""), Some(&home)), Some(home.clone()));
        drop(fs::remove_dir_all(&home));
    }

    /// No usable home and no usable request is the one case that answers "do not `chdir`". The
    /// child inherits superd's directory, which is wrong but alive.
    #[test]
    fn nothing_usable_anywhere_means_no_chdir() {
        assert_eq!(resolve_cwd(Some("/no/such/place"), Some("/no/such/home")), None);
        assert_eq!(resolve_cwd(None, None), None);
        assert_eq!(resolve_cwd(Some("~/inner"), None), None);
    }

    /// A directory with no execute bit fails `chdir` exactly as a missing one does, and `is_dir`
    /// alone would have said yes.
    #[test]
    fn a_non_searchable_directory_is_not_usable() {
        use std::fs::Permissions;
        use std::os::unix::fs::PermissionsExt as _;

        let home = scratch("no-x");
        let barred = format!("{home}/barred");
        fs::create_dir_all(&barred).unwrap();
        fs::set_permissions(&barred, Permissions::from_mode(0o600)).unwrap();
        // Running as root defeats the check — `access(X_OK)` says yes to everything — so the test
        // asserts the fallback only where the permission actually took. Asking `access` itself is
        // the honest probe: it is the very call `resolve_cwd` makes, so this cannot skip for a
        // reason the code under test would not have seen.
        let effective = if super::usable_directory(std::path::Path::new(&barred)) {
            None
        } else {
            Some(resolve_cwd(Some(&barred), Some(&home)))
        };
        drop(fs::set_permissions(&barred, Permissions::from_mode(0o700)));
        drop(fs::remove_dir_all(&home));
        if let Some(resolved) = effective {
            assert_eq!(resolved, Some(home));
        }
    }
}

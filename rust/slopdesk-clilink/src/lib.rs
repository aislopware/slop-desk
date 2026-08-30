//! Installs the `slopdesk` command where the user's shell will already look for it.
//!
//! The app ships the command inside its own bundle, next to the executable, and a command nobody
//! can type is not a command. Linking it is the whole of this crate.
//!
//! ## Why it is not a first-launch question
//!
//! It used to be a card with a switch on it, and the switch escalated: `/usr/local/bin` is
//! root-owned, so turning it on raised an administrator prompt in a user's first two minutes with
//! the app. Two things were wrong with that. A password prompt is the most expensive question a
//! program can ask, and it was being spent on a convenience; and a card that can be dismissed is a
//! card most people dismiss, which left `slopdesk edit` — the command every doc example opens with
//! — not existing on most installs.
//!
//! So the link is made at launch, into a directory the user already owns. `~/.local/bin` is the XDG
//! user-binary location, is on `PATH` in every shell profile that has ever been generated for it,
//! and needs no privilege at all. Not `/usr/local/bin`, which needs one the app should never ask
//! for; not `/opt/homebrew/bin`, which belongs to a package manager that did not install this.
//!
//! ## Why it is Rust rather than the launch path that calls it
//!
//! It is an EFFECT on the filesystem, and every effect on the system is Rust's. What stays on the
//! near side is the one thing only the framework can answer — where this bundle's executable is —
//! and that is `Bundle.main`, not a path this crate could derive. So the shape is: the shell
//! resolves the source, this decides and does the rest.
//!
//! ## Every failure is silent, and one of them is a decision
//!
//! [`link`] answers whether the command is reachable afterwards and changes nothing else. An
//! unwritable home, a missing source, a `~/.local/bin` that is a regular file — each answers
//! [`Outcome::Failed`], because an app that refused to launch over a symlink would be trading the
//! product for a convenience.
//!
//! The one that is not merely a failure: a path that already holds a REGULAR FILE is left alone.
//! That is somebody else's `slopdesk`, or an earlier copy the user placed by hand, and replacing it
//! silently is the one outcome worse than not linking at all. A stale SYMLINK is replaced, because
//! a link this app made to a bundle that has since moved is this app's to correct.

use std::fs;
use std::path::{Path, PathBuf};

/// What [`link`] found, and what it did about it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// The link already pointed at `source`; nothing was touched.
    AlreadyLinked,
    /// The link was created, or re-aimed from somewhere stale.
    Linked,
    /// A regular file — not a link this app made — already sits at the destination, so it was left
    /// exactly as it was.
    Occupied,
    /// The link could not be made. The command is simply not on `PATH`; nothing else follows.
    Failed,
}

impl Outcome {
    /// Whether the command is reachable at the destination now.
    #[must_use]
    pub const fn is_linked(self) -> bool {
        matches!(self, Self::AlreadyLinked | Self::Linked)
    }
}

/// Where the link lands under `home`: `~/.local/bin/slopdesk`.
#[must_use]
pub fn destination(home: &Path) -> PathBuf {
    home.join(".local/bin/slopdesk")
}

/// Points `destination(home)` at `source`, and says what that took.
///
/// Idempotent: called on every launch, and a launch that changes nothing answers
/// [`Outcome::AlreadyLinked`] without touching the filesystem beyond one `readlink`.
#[must_use]
pub fn link(home: &Path, source: &Path) -> Outcome {
    if !is_executable_file(source) {
        return Outcome::Failed;
    }
    let destination = destination(home);
    match fs::read_link(&destination) {
        // Already ours and already right — the overwhelmingly common launch.
        Ok(existing) if existing == source => return Outcome::AlreadyLinked,
        // A link this app made to a bundle that has since moved. Ours to correct.
        Ok(_) => {
            if fs::remove_file(&destination).is_err() {
                return Outcome::Failed;
            }
        },
        // `read_link` fails on a regular file as well as on nothing at all, and the two are
        // opposite answers — so the existence check is what tells them apart.
        Err(_) if destination.symlink_metadata().is_ok() => return Outcome::Occupied,
        Err(_) => {},
    }
    let Some(parent) = destination.parent() else {
        return Outcome::Failed;
    };
    if fs::create_dir_all(parent).is_err() {
        return Outcome::Failed;
    }
    if std::os::unix::fs::symlink(source, &destination).is_err() {
        return Outcome::Failed;
    }
    if fs::read_link(&destination).is_ok_and(|made| made == source) {
        Outcome::Linked
    } else {
        Outcome::Failed
    }
}

/// Whether `path` is a regular file the current user may execute.
///
/// A bundle that shipped without the command — a partial build, a stripped archive — is a real
/// case, and it must answer "no command" rather than a link to nothing.
fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    fs::metadata(path).is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, and the tree is this module's own"
    )]

    use std::fs;
    use std::os::unix::fs::PermissionsExt as _;
    use std::path::{Path, PathBuf};

    use super::{Outcome, destination, link};

    /// A private tree per test: a `home` to link into and a `bundle` holding the command.
    struct Tree {
        root: PathBuf,
    }

    impl Tree {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!("slopdesk-clilink-{name}-{}", std::process::id()));
            drop(fs::remove_dir_all(&root));
            fs::create_dir_all(root.join("bundle")).expect("a temp tree");
            Self { root }
        }

        fn home(&self) -> PathBuf {
            self.root.join("home")
        }

        /// A file at `bundle/slopdesk` with the given executable bit.
        fn command(&self, executable: bool) -> PathBuf {
            let path = self.root.join("bundle/slopdesk");
            fs::write(&path, b"#!/bin/sh\n").expect("a command");
            let mode = if executable { 0o755 } else { 0o644 };
            fs::set_permissions(&path, fs::Permissions::from_mode(mode)).expect("its mode");
            path
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            drop(fs::remove_dir_all(&self.root));
        }
    }

    #[test]
    fn the_destination_is_the_xdg_user_bin() {
        assert_eq!(
            destination(Path::new("/Users/x")),
            PathBuf::from("/Users/x/.local/bin/slopdesk"),
            "not /usr/local/bin, which would need a privilege the app must never ask for"
        );
    }

    #[test]
    fn a_first_launch_makes_the_directory_and_the_link() {
        let tree = Tree::new("first");
        let source = tree.command(true);
        assert_eq!(link(&tree.home(), &source), Outcome::Linked);
        assert_eq!(fs::read_link(destination(&tree.home())).expect("a link"), source);
    }

    #[test]
    fn every_launch_after_the_first_touches_nothing() {
        let tree = Tree::new("idempotent");
        let source = tree.command(true);
        assert_eq!(link(&tree.home(), &source), Outcome::Linked);
        assert_eq!(link(&tree.home(), &source), Outcome::AlreadyLinked);
        assert_eq!(link(&tree.home(), &source), Outcome::AlreadyLinked);
    }

    #[test]
    fn a_link_aimed_at_a_bundle_that_moved_is_re_aimed() {
        let tree = Tree::new("stale");
        let source = tree.command(true);
        let destination = destination(&tree.home());
        fs::create_dir_all(destination.parent().expect("a parent")).expect("the bin dir");
        std::os::unix::fs::symlink("/nowhere/slopdesk", &destination).expect("a stale link");

        assert_eq!(link(&tree.home(), &source), Outcome::Linked);
        assert_eq!(fs::read_link(&destination).expect("a link"), source);
    }

    /// The one refusal that is a decision rather than a failure.
    #[test]
    fn somebody_elses_slopdesk_is_left_exactly_where_it_is() {
        let tree = Tree::new("occupied");
        let source = tree.command(true);
        let destination = destination(&tree.home());
        fs::create_dir_all(destination.parent().expect("a parent")).expect("the bin dir");
        fs::write(&destination, b"someone else's").expect("a real file");

        assert_eq!(link(&tree.home(), &source), Outcome::Occupied);
        assert_eq!(
            fs::read(&destination).expect("still there"),
            b"someone else's",
            "replacing it silently is the one outcome worse than not linking"
        );
    }

    #[test]
    fn a_bundle_with_no_runnable_command_in_it_links_nothing() {
        let tree = Tree::new("missing");
        assert_eq!(
            link(&tree.home(), &tree.root.join("bundle/absent")),
            Outcome::Failed
        );
        assert_eq!(
            link(&tree.home(), &tree.command(false)),
            Outcome::Failed,
            "a file with no executable bit is not a command"
        );
        assert!(!destination(&tree.home()).exists(), "and nothing was left behind");
    }

    #[test]
    fn only_the_two_linked_outcomes_report_a_reachable_command() {
        assert!(Outcome::Linked.is_linked());
        assert!(Outcome::AlreadyLinked.is_linked());
        assert!(!Outcome::Occupied.is_linked());
        assert!(!Outcome::Failed.is_linked());
    }
}

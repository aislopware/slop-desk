//! Materialises the pinned host-side runtime dependencies of the right panel.
//!
//! Every surface in the right panel stands on a third-party program that is NOT part of this repo's
//! build: the code panel runs `code-server`, the simulator panel runs `baguette serve`, the Android
//! panel runs `adb` and pushes `scrcpy-server`. `ThirdParty/tools/tools.lock` pins each by URL and
//! SHA-256; this crate turns that file into `.prefix/bin/<name>`.
//!
//! ## This is provisioning, not a runtime path
//!
//! `hostd` never downloads anything. It only ever LOOKS in `.prefix/bin`, and reports the surface
//! unavailable when a dependency is not there. That split is the point: a coding host must not
//! reach the network because someone opened a panel. This crate is the only thing in the tree that
//! opens a socket to the internet, and it runs from `make provision` and nowhere else.
//!
//! ## The shape
//!
//! Four modules, split by what they can be tested without. [`lock`] is a parser and [`plan`] is a
//! layout — both are pure and both are covered without touching a filesystem. [`fetch`] and
//! [`extract`] are the I/O, and each keeps its errors in the vocabulary of the PIN rather than of
//! the program that used to perform the step: a mismatch names the URL, a bad archive layout names
//! the archive.

pub mod extract;
pub mod fetch;
pub mod lock;
pub mod plan;

use std::fs;
use std::path::Path;

use lock::{Kind, Pin};
use plan::Layout;

/// What one run did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Tally {
    /// Downloaded and unpacked.
    pub installed: usize,
    /// Already at the pinned version and digest, or verified in place.
    pub current: usize,
    /// Absent, and `--check` said not to fetch it.
    pub missing: usize,
}

/// Whether a run may reach the network.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Provision what is not current.
    Provision,
    /// Report what is installed and download nothing.
    Check,
}

/// Anything that stops a run, already phrased for a terminal.
pub type Failure = String;

/// Runs every pin in `layout`'s lock that `wanted` names, printing progress to stdout.
///
/// # Errors
/// The first failure, phrased for a reader: a malformed lock line names its line, a digest mismatch
/// names the URL, a changed archive layout names the archive.
pub fn run(layout: &Layout, mode: Mode, wanted: &[String]) -> Result<Tally, Failure> {
    let lock_path = layout.lock();
    let text = fs::read_to_string(&lock_path).map_err(|cause| format!("{}: {cause}", lock_path.display()))?;
    let pins = lock::parse(&text).map_err(|error| error.to_string())?;

    for directory in [layout.bin(), layout.cache(), layout.prefix().join(".stamp")] {
        fs::create_dir_all(&directory).map_err(|cause| format!("{}: {cause}", directory.display()))?;
    }

    let mut tally = Tally::default();
    for pin in pins.iter().filter(|pin| plan::is_wanted(pin, wanted)) {
        println!("{} {}", pin.name, pin.version);
        match pin.kind {
            Kind::File => {
                verify_vendored(layout, pin)?;
                tally.current += 1;
            },
            Kind::TarGz | Kind::Zip => step(layout, pin, mode, &mut tally)?,
        }
    }
    Ok(tally)
}

/// One downloadable pin.
fn step(layout: &Layout, pin: &Pin, mode: Mode, tally: &mut Tally) -> Result<(), Failure> {
    let binary = layout.binary(pin);
    let stamp_path = layout.stamp(pin);
    let stamp = fs::read_to_string(&stamp_path).ok();
    if plan::is_current(pin, binary.exists(), stamp.as_deref()) {
        log(&format!("current  {}", relative(&binary, &layout.tools)));
        tally.current += 1;
        return relink(layout, pin);
    }
    if mode == Mode::Check {
        log("MISSING  (run without --check to provision)");
        tally.missing += 1;
        return Ok(());
    }

    let archive = layout.archive(pin);
    match fetch::fetch_verified(&pin.url, &pin.sha256, &archive).map_err(|error| error.to_string())? {
        fetch::Cached::Already => log(&format!("cached   {}", relative(&archive, &layout.tools))),
        fetch::Cached::Downloaded => log(&format!("fetched  {}", pin.url)),
    }

    let target = layout.target(pin);
    log(&format!("extract  {}", relative(&target, &layout.tools)));
    extract::extract_into(pin.kind, &archive, &target).map_err(|error| error.to_string())?;
    if !is_executable(&binary) {
        return Err(format!(
            "{} {} extracted but {} is not there or not executable — the upstream archive layout changed",
            pin.name, pin.version, pin.binary
        ));
    }

    fs::write(&stamp_path, plan::stamp_contents(pin))
        .map_err(|cause| format!("{}: {cause}", stamp_path.display()))?;
    // The cache is a TRANSFER cache, not a version store: drop the archive once its contents are
    // unpacked and checked. code-server's tarball alone is 206 MB, and this is a tree developers
    // keep several checkouts of — a re-provision can pay the download again.
    drop(fs::remove_file(&archive));
    tally.installed += 1;
    relink(layout, pin)
}

/// A `file` pin: committed in the repo, verified, never downloaded.
///
/// A checkout whose bytes do not match the pin is a corrupt checkout (or an LFS/filter mishap), and
/// pushing a mangled jar to a phone fails in a way that reads as a device problem. No symlink is
/// minted — a `file` pin is consumed from `vendor/` at the path the lock names, not through
/// `.prefix/bin`.
fn verify_vendored(layout: &Layout, pin: &Pin) -> Result<(), Failure> {
    let source = layout.vendored(pin);
    if !source.is_file() {
        return Err(format!(
            "{} is committed at vendor/{} but that file is missing",
            pin.name, pin.binary
        ));
    }
    let got = fetch::digest_of(&source).map_err(|error| error.to_string())?;
    if !got.eq_ignore_ascii_case(&pin.sha256) {
        return Err(format!(
            "vendor/{} does not match its pin\n  expected {}\n  got      {got}",
            pin.binary, pin.sha256
        ));
    }
    log(&format!("vendored (verified) vendor/{}", pin.binary));
    Ok(())
}

/// Points `.prefix/bin/<name>` at the pinned version, replacing whatever it pointed at.
fn relink(layout: &Layout, pin: &Pin) -> Result<(), Failure> {
    let link = layout.link(pin);
    // `symlink` refuses an existing path, and a version bump is exactly the case where one exists
    // and is wrong. Remove-then-create rather than a rename dance: the window is a developer's
    // machine mid-provision, not a live serving path.
    drop(fs::remove_file(&link));
    symlink(&Layout::link_target(pin), &link).map_err(|cause| format!("{}: {cause}", link.display()))
}

/// The relative symlink, so the whole checkout stays movable.
#[cfg(unix)]
fn symlink(target: &Path, link: &Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

/// Non-unix hosts do not run the panel; the link is not part of any path they take.
#[cfg(not(unix))]
fn symlink(_target: &Path, _link: &Path) -> std::io::Result<()> {
    Ok(())
}

/// Whether the extracted binary is one the host can actually exec.
#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    fs::metadata(path).is_ok_and(|data| data.is_file() && data.permissions().mode() & 0o111 != 0)
}

/// Elsewhere, presence is all the question there is.
#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

/// A path as the reader would type it, relative to `ThirdParty/tools/` when it lives under it.
fn relative(path: &Path, tools: &Path) -> String {
    path.strip_prefix(tools).unwrap_or(path).display().to_string()
}

/// One indented progress line, matching the shell's own two-space `log`.
fn log(message: &str) {
    println!("  {message}");
}

#[cfg(test)]
mod tests {

    use std::path::Path;

    use super::{Tally, relative};

    #[test]
    fn a_fresh_tally_counts_nothing() {
        assert_eq!(Tally::default(), Tally {
            installed: 0,
            current: 0,
            missing: 0
        });
    }

    #[test]
    fn a_path_under_tools_prints_relative_to_it() {
        let tools = Path::new("/repo/ThirdParty/tools");
        assert_eq!(
            relative(Path::new("/repo/ThirdParty/tools/.prefix/adb/37.0.1"), tools),
            ".prefix/adb/37.0.1"
        );
    }

    #[test]
    fn a_path_outside_tools_prints_itself() {
        let tools = Path::new("/repo/ThirdParty/tools");
        assert_eq!(relative(Path::new("/elsewhere/x"), tools), "/elsewhere/x");
    }
}

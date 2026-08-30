//! The linked port's producer: `ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework`, from
//! `rust/slopdesk-ffi`.
//!
//! ## Why this exists
//! The Swift clients are in-process consumers of logic that now lives in Rust, and a socket cannot
//! reach them: the iOS client cannot host a sidecar daemon at all, and the macOS ones are on the
//! terminal's hot output path. So the port ships as a linked library — `CLAUDE.md`'s "pick by
//! lifetime" rule — and this module is what produces it.
//!
//! ## Why the artifact is not committed
//! Measured 2026-08-15: 38 MB per slice, 110 MB for the three, rewritten by every Rust edit. That
//! is a git history nobody wants for a build output. `ThirdParty/ghostty/libghostty.xcframework` is
//! gitignored for the same reason and rebuilt by its own script; this follows that precedent. What
//! the app actually PAYS is far smaller, because an archive is not a binary: a probe calling one
//! plain door links to 439 KB after `-dead_strip`, and 1.61 MB once it calls
//! `slopdesk_ws_redact_secrets` and pulls `regex` in with it.
//!
//! ## Why it is cheap to run anyway
//! [`current_stamp`] hashes every input — the Rust sources of the shim and the crates it wraps, the
//! header, and this module. A second run with nothing changed exits in milliseconds, so wiring it
//! in front of `just build`/`test`/`check` costs nothing on a warm tree. [`Mode::Force`] skips the
//! check; [`Mode::Check`] reports staleness without building, which is what `just lint` uses.
//!
//! SLICES: arm64 only, matching the rest of the project (`docs/49` "arm64 only — a constraint, not
//! a default"): macos-arm64, ios-arm64, ios-arm64-simulator.
//!
//! ## What the port changed, and what it deliberately did not
//! The shell asked `comm` over sorted lists, spawned `find | sort | xargs shasum | shasum`, and
//! recursed through `Cargo.toml` with `grep -oE | sed`. Those are [`BTreeSet`] differences, a
//! [`Sha256`] fold and a `while let` over a worklist here, each with a test — which is the half the
//! shell never had, because its selection logic could not be exercised without building three
//! slices. Everything the shell did that a compiled program cannot do itself is unchanged and
//! deliberately so: the per-slice `CARGO_TARGET_DIR` (70 s serial, 25 s with a directory each), the
//! `nm --print-armap` read, the two-direction symbol bijection, the header nesting, and the stamp
//! written LAST.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use sha2::{Digest, Sha256};

use super::stamp;

/// The shim crate, whose path dependencies decide what the artifact is built from.
const SHIM: &str = "slopdesk-ffi";

/// The header every door is declared in.
const HEADER: &str = "rust/slopdesk-ffi/include/slopdesk_ffi.h";

/// Where the assembled framework and its stamp live.
const OUT_DIR: &str = "ThirdParty/slopdesk-ffi";

/// The three arm64 slices, in the order they are built and assembled.
const TARGETS: [&str; 3] = [
    "aarch64-apple-darwin",
    "aarch64-apple-ios",
    "aarch64-apple-ios-sim",
];

/// The slice that is allowed to carry the macOS-only doors.
const MACOS_SLICE: &str = "aarch64-apple-darwin";

/// The archive `cargo build` writes for each slice.
const LIB_NAME: &str = "libslopdesk_ffi.a";

/// This module's own source, and the entry point that picks the mode — the port's answer to the
/// shell's `${SELF}`.
///
/// This module decides which slices exist and which symbols they must carry, so editing it can
/// change the artifact without touching one line of Rust. Scoped to these two files rather than to
/// the whole `gates` tree on purpose: a stamp over every sibling gate would rebuild 110 MB of
/// xcframework whenever the golden gate's key set moved, which is a cost with no question behind
/// it.
const SELF_FILES: [&str; 2] = [
    "rust/slopdesk-devtools/src/gates/ffi.rs",
    "rust/slopdesk-devtools/src/bin/gate.rs",
];

/// What a run is being asked to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Build when the stamp disagrees, and say so when it does not.
    Build,
    /// Report staleness and build nothing. What `just lint` runs.
    Check,
    /// Build whatever the stamp says.
    Force,
}

/// Every `slopdesk_*` symbol the header declares, with the leading underscore a Mach-O archive
/// carries.
///
/// READ OUT OF THE HEADER rather than restated: the header is the promise, and a hand-kept list
/// beside it is a second list to forget. Function-pointer TYPEDEFS are not matched — `(*name)(`
/// puts a paren before the name, so only real declarations and their `name(` shape are picked up.
#[must_use]
pub fn declared_symbols(header: &str) -> BTreeSet<String> {
    door_names(header)
        .into_iter()
        .map(|name| format!("_{name}"))
        .collect()
}

/// The doors that exist on macOS ONLY, read out of the header's `MACOS-ONLY BEGIN/END` region.
///
/// One door is behind such a guard today — `slopdesk_git_status`, which links a vendored `libgit2`
/// no client can reach, since a phone RECEIVES the git status as a metadata reply. The bijection in
/// [`verdict`] is what keeps the three spellings of that fact in step: the `#if TARGET_OS_OSX`
/// here, the `cfg(target_os = "macos")` in `src/lib.rs`, and the target-gated dependency in
/// `Cargo.toml`. The symbol is REQUIRED on the macOS slice and REQUIRED ABSENT on the other two —
/// so a `cfg` that stops matching the header fails in whichever direction it drifted, rather than
/// shipping a phone archive with a C library in it or a macOS door Swift cannot link.
#[must_use]
pub fn macos_only_symbols(header: &str) -> BTreeSet<String> {
    let mut inside = false;
    let mut region = String::new();
    for line in header.lines() {
        if line.contains("MACOS-ONLY BEGIN") {
            inside = true;
        }
        if inside {
            region.push_str(line);
            region.push('\n');
        }
        if line.contains("MACOS-ONLY END") {
            inside = false;
        }
    }
    declared_symbols(&region)
}

/// Every `slopdesk_*` symbol an `nm --print-armap` dump names, with its leading underscore.
#[must_use]
pub fn exported_symbols(armap: &str) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    for (index, _) in armap.match_indices("_slopdesk_") {
        let rest = &armap[index..];
        let width = rest
            .char_indices()
            .take_while(|(offset, character)| {
                *offset == 0
                    || character.is_ascii_lowercase()
                    || character.is_ascii_digit()
                    || *character == '_'
            })
            .count();
        found.insert(rest[..width].to_owned());
    }
    found
}

/// The two directions of the header↔library bijection: declared-but-absent,
/// exported-but-undeclared.
///
/// The first direction is a link error waiting to happen — the header and `src/lib.rs` disagree,
/// which no compiler can notice because they are different languages. The second is quieter and
/// nothing asked it until the check that replaced this one's first draft: a `slopdesk_*` symbol the
/// library EXPORTS but the header never declares is a door with no handle. The port shipped, it
/// costs its bytes in a 37 MB archive, and no Swift line can reach it — invisible to both
/// compilers, since rustc sees a `pub extern "C"` item as used-by-definition and Swift never hears
/// of it. Measured when this was written: 784 declared, 784 exported, an exact bijection.
#[must_use]
pub fn verdict(exported: &BTreeSet<String>, declared: &BTreeSet<String>) -> (Vec<String>, Vec<String>) {
    let absent = declared.difference(exported).cloned().collect();
    let undeclared = exported.difference(declared).cloned().collect();
    (absent, undeclared)
}

/// The crates whose sources decide whether the artifact is stale: the shim and everything it wraps.
///
/// READ OUT OF THE CARGO GRAPH, for the reason [`declared_symbols`] is read out of the header — a
/// hand-kept list is a second list to forget, and forgetting THIS one does not fail loudly. It
/// calls a stale library fresh, which is the one failure mode `docs/55` says a linked port has and
/// a socket port does not. Transitive, because `slopdesk-video` reaches `slopdesk-gfsimd`: a NEON
/// edit under a crate nobody remembered to list is exactly the change that would ship against
/// yesterday's archive. `slopdesk-posix` is correctly absent — superd forks, and the shim does not
/// wrap it.
///
/// # Errors
/// When a declared path dependency has no `Cargo.toml`, which means the graph is broken, or when
/// the shim declares no path dependency at all — the shape a moved manifest leaves behind.
pub fn input_crates(root: &Path) -> Result<Vec<String>, String> {
    let mut collected: Vec<String> = Vec::new();
    let mut pending: Vec<String> = vec![SHIM.to_owned()];
    while let Some(crate_name) = pending.pop() {
        if collected.contains(&crate_name) {
            continue;
        }
        let manifest = root.join("rust").join(&crate_name).join("Cargo.toml");
        let text = fs::read_to_string(&manifest).map_err(|_| {
            format!("{crate_name} is a path dependency of the shim with no Cargo.toml — the graph is broken")
        })?;
        collected.push(crate_name);
        for dependency in path_dependencies(&text) {
            pending.push(dependency);
        }
    }
    if collected.len() < 2 {
        return Err("the shim declares no path dependencies — did Cargo.toml move?".to_owned());
    }
    collected.sort_unstable();
    collected.dedup();
    Ok(collected.into_iter().map(|name| format!("rust/{name}")).collect())
}

/// The sibling crates one manifest depends on by path.
#[must_use]
pub fn path_dependencies(manifest: &str) -> Vec<String> {
    let mut found = Vec::new();
    for line in manifest.lines() {
        let trimmed = line.trim_start();
        let Some((name, rest)) = trimmed.split_once('=') else {
            continue;
        };
        let name = name.trim();
        if name.is_empty()
            || !name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        {
            continue;
        }
        let rest = rest.trim_start();
        if !rest.starts_with('{') {
            continue;
        }
        let Some(after) = rest
            .split_once("path")
            .and_then(|(_, tail)| tail.trim_start().strip_prefix('='))
        else {
            continue;
        };
        let after = after.trim_start();
        let Some(value) = after.strip_prefix('"').and_then(|tail| tail.split('"').next()) else {
            continue;
        };
        if let Some(sibling) = value.strip_prefix("../")
            && !sibling.contains('/')
        {
            found.push(sibling.to_owned());
        }
    }
    found
}

/// Every input path the stamp consumes, repo-relative and sorted.
///
/// `target` is PRUNED by [`stamp::walk`] itself, and that is load-bearing rather than tidiness.
/// Build scripts write real `.rs` under
/// `target/<triple>/release/build/<crate>-<metadata-hash>/out/`, and the hash in that directory
/// name is cargo's, not ours. Unpruned, the stamp counted 12 such files across the shim's closure —
/// and since `cargo build --target aarch64-apple-ios` MINTS a fresh one for a triple it has not
/// built before, it changed AFTER the wanted stamp was read and BEFORE it was written. A clean
/// build therefore recorded a value the very next check disagreed with, so `just lint` announced
/// the artifact stale seconds after building it: an input-hash gate made to fire on its own output.
/// Sources only.
///
/// Until 2026-08-25 the pruning was a `retain` over the RESULTS, so the walk still read all 592 000
/// names under `rust/slopdesk-ffi/target` before throwing them away — 50 s on every `just ffi`,
/// `build`, `test` and `quick`, warm or cold, for an answer the stamp already had.
///
/// # Errors
/// When the crate graph cannot be read, or an input tree cannot be walked.
pub fn stamp_inputs(root: &Path) -> Result<Vec<String>, String> {
    let mut found: Vec<String> = Vec::new();
    for crate_path in input_crates(root)? {
        stamp::walk(root, &root.join(&crate_path), &mut found, &|path| {
            let name = path
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or_default();
            let extension = path
                .extension()
                .and_then(|value| value.to_str())
                .unwrap_or_default();
            name == "Cargo.toml" || name == "module.modulemap" || matches!(extension, "rs" | "h")
        })?;
    }
    for file in SELF_FILES {
        found.push(file.to_owned());
    }
    found.sort_unstable();
    found.dedup();
    Ok(found)
}

/// The digest of every input's contents AND name.
///
/// # Errors
/// When [`stamp_inputs`] cannot be built.
pub fn current_stamp(root: &Path) -> Result<String, String> {
    let mut outer = Sha256::new();
    for path in stamp_inputs(root)? {
        let bytes = fs::read(root.join(&path)).unwrap_or_default();
        let mut inner = Sha256::new();
        inner.update(&bytes);
        outer.update(format!("{:x}  {path}\n", inner.finalize()));
    }
    Ok(format!("{:x}", outer.finalize()))
}

/// Build, check or force the xcframework.
///
/// # Errors
/// When the artifact is stale under [`Mode::Check`], when a prerequisite tool or rust target is
/// missing, when a slice fails to compile, when the header and a slice disagree about a symbol, or
/// when `xcodebuild -create-xcframework` fails.
pub fn run(root: &Path, mode: Mode) -> Result<(), String> {
    let out_dir = root.join(OUT_DIR);
    let xcframework = out_dir.join("SlopDeskFFI.xcframework");
    let marker = out_dir.join("sources.sha256");
    let want = current_stamp(root)?;

    if mode != Mode::Force && xcframework.is_dir() && stamp::is_warm(&marker, &want) {
        println!("build-ffi: up to date ({})", xcframework.display());
        return Ok(());
    }
    if mode == Mode::Check {
        if !xcframework.is_dir() {
            return Err(
                "build-ffi: FAIL — SlopDeskFFI.xcframework has never been built — run 'just ffi'".to_owned(),
            );
        }
        return Err(
            "build-ffi: FAIL — SlopDeskFFI.xcframework is STALE: the Rust sources changed since it was \
             built. Run 'just ffi'. A stale artifact is the one failure mode a linked port has that a \
             socket does not — the Swift side would keep calling last week's logic with every test green."
                .to_owned(),
        );
    }

    preflight(root)?;
    let header = fs::read_to_string(root.join(HEADER)).map_err(|error| format!("{HEADER}: {error}"))?;
    let declared = declared_symbols(&header);
    if declared.is_empty() {
        return Err("build-ffi: FAIL — slopdesk_ffi.h declares nothing — did the header move?".to_owned());
    }
    let macos_only = macos_only_symbols(&header);

    let stage = stage_headers(root, &out_dir)?;
    build_slices(root)?;
    let archives = check_slices(root, &declared, &macos_only)?;
    assemble(root, &xcframework, &stage, &archives)?;
    let _ignored = fs::remove_dir_all(&stage);
    assert_nesting(&xcframework)?;

    // Stamped LAST, so an interrupted build leaves the artifact stale rather than falsely fresh.
    stamp::record(&marker, &want)?;
    println!(
        "build-ffi: assembled {} ({} slices)",
        xcframework.display(),
        TARGETS.len()
    );
    Ok(())
}

/// The tools and rust targets a build needs, named before ten minutes of it are spent.
fn preflight(root: &Path) -> Result<(), String> {
    for tool in ["cargo", "xcodebuild", "nm"] {
        if !crate::proc::on_path(tool) {
            return Err(format!(
                "build-ffi: FAIL — {tool} not found — the FFI slices are built from Rust with the full \
                 Xcode toolchain"
            ));
        }
    }
    let installed = crate::proc::ask("rustup", &["target", "list", "--installed"], root).unwrap_or_default();
    for target in TARGETS {
        if !installed.lines().any(|line| line.trim() == target) {
            return Err(format!(
                "build-ffi: FAIL — rust target {target} is not installed — run 'rustup target add {target}'"
            ));
        }
    }
    Ok(())
}

/// Stage the headers under a directory named after the MODULE, which is load-bearing.
///
/// `xcodebuild -create-xcframework -headers X` copies X's CONTENTS to each slice's `Headers/`, and
/// Xcode's `ProcessXCFramework` then copies that into `$BUILT_PRODUCTS_DIR/include/`. FLAT. Both
/// app targets also link `ThirdParty/ghostty/libghostty.xcframework`, whose `Headers/` likewise
/// holds a `module.modulemap` — so with both at their Headers root, two `ProcessXCFramework`
/// commands write the same `include/module.modulemap` and Xcode refuses the graph:
///
/// ```text
/// error: Multiple commands produce '…/Build/Products/Debug/include/module.modulemap'
/// ```
///
/// Neither app built, on either platform, from the moment this xcframework joined the graph.
/// Nothing caught it: `swift build` and `swift test` never process an xcframework this way, and the
/// two gates that DO build the apps (`slopdesk-guigate macos`, `slopdesk-gate ios`) are reachable
/// from no `just` target and no hook.
///
/// Nesting under `CSlopDeskFFI/` gives the copy a unique destination. `SwiftPM` still resolves the
/// module — it walks the whole Headers tree for a `module.modulemap` rather than only its root —
/// and the staging directory is built here rather than committed as
/// `rust/slopdesk-ffi/include/CSlopDeskFFI/`, because `include/` is a normal C include root for the
/// crate's own consumers and `#include "slopdesk_ffi.h"` should keep working there.
fn stage_headers(root: &Path, out_dir: &Path) -> Result<PathBuf, String> {
    let stage = out_dir.join(".headers");
    let nested = stage.join("CSlopDeskFFI");
    let _ignored = fs::remove_dir_all(&stage);
    fs::create_dir_all(&nested).map_err(|error| format!("{}: {error}", nested.display()))?;
    let include = root.join("rust/slopdesk-ffi/include");
    let entries = fs::read_dir(&include).map_err(|error| format!("{}: {error}", include.display()))?;
    for entry in entries {
        let path = entry
            .map_err(|error| format!("{}: {error}", include.display()))?
            .path();
        if path.is_file()
            && let Some(name) = path.file_name()
        {
            fs::copy(&path, nested.join(name)).map_err(|error| format!("{}: {error}", path.display()))?;
        }
    }
    if !nested.join("module.modulemap").is_file() {
        return Err(
            "build-ffi: FAIL — staged headers have no module.modulemap — Swift would not see CSlopDeskFFI \
             at all"
                .to_owned(),
        );
    }
    Ok(stage)
}

/// Where one slice's release artifacts live.
fn slice_dir(root: &Path, target: &str) -> PathBuf {
    root.join("rust/slopdesk-ffi/target/ffi").join(target)
}

/// The three slices, CONCURRENTLY, each into its own target directory.
///
/// The separate directories are the point, not the parallelism. Cargo takes an exclusive lock on a
/// target directory, so three `cargo build --target …` invocations sharing one merely queue behind
/// each other — measured on one edit to a wrapped crate: 70 s serial, 55 s backgrounded onto the
/// shared directory, 25 s with a directory each. The headroom exists because a release build of
/// this graph is mostly SERIAL: `lto = "fat"` is single-threaded, so one slice never occupies much
/// more than one of this machine's ten cores.
///
/// Every slice is JOINED before the first failure is reported, so a doomed run does not leave two
/// compilers racing the tree the next command is about to edit — which is what the shell's `wait`
/// on each known pid bought, and what a bare `wait` (zero however the jobs died) did not.
fn build_slices(root: &Path) -> Result<(), String> {
    let crate_dir = root.join("rust/slopdesk-ffi");
    let outcomes = std::thread::scope(|scope| {
        // Every handle is spawned BEFORE the first is joined — a lazy iterator would run the three
        // slices one after another, which is the serial 70 s this concurrency exists to avoid.
        let handles: Vec<_> = TARGETS
            .iter()
            .map(|target| {
                let crate_dir = crate_dir.clone();
                let slice = slice_dir(root, target);
                scope.spawn(move || {
                    println!("build-ffi: building {target}");
                    Command::new("cargo")
                        .args(["build", "--release", "--target", target, "--quiet"])
                        .current_dir(&crate_dir)
                        .env("CARGO_TARGET_DIR", &slice)
                        .output()
                        .map_err(|error| format!("cargo: {error}"))
                })
            })
            .collect();
        let mut joined = Vec::with_capacity(handles.len());
        for handle in handles {
            joined.push(
                handle
                    .join()
                    .unwrap_or_else(|_| Err("cargo: the slice thread panicked".to_owned())),
            );
        }
        joined
    });

    let mut failed: Vec<&str> = Vec::new();
    for (target, outcome) in TARGETS.iter().zip(outcomes) {
        match outcome {
            Ok(output) => {
                let noise = format!(
                    "{}{}",
                    String::from_utf8_lossy(&output.stdout),
                    String::from_utf8_lossy(&output.stderr)
                );
                if !noise.trim().is_empty() {
                    eprintln!("── {target} ──\n{noise}");
                }
                if !output.status.success() {
                    failed.push(target);
                }
            },
            Err(why) => {
                eprintln!("── {target} ──\n{why}");
                failed.push(target);
            },
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "build-ffi: FAIL — cargo build failed for {}",
            failed.join(" ")
        ))
    }
}

/// Every slice's archive, checked against the header in both directions.
///
/// `nm --print-armap`, not a plain `nm`: with `lto = "fat"` the archive members are LLVM bitcode
/// from RUSTC's LLVM, which Xcode's older `nm` refuses to parse ("Unknown attribute kind"), so a
/// plain read reports every symbol absent. The armap is the archive INDEX — what the linker
/// resolves against — which is both readable and the more exact question to ask.
fn check_slices(
    root: &Path,
    declared: &BTreeSet<String>,
    macos_only: &BTreeSet<String>,
) -> Result<Vec<PathBuf>, String> {
    let mut archives = Vec::new();
    for target in TARGETS {
        let archive = slice_dir(root, target)
            .join(target)
            .join("release")
            .join(LIB_NAME);
        if !archive.is_file() {
            return Err(format!(
                "build-ffi: FAIL — expected {} — did [lib] crate-type lose 'staticlib'?",
                archive.display()
            ));
        }
        let armap = read_armap(&archive)?;
        let exported = exported_symbols(&armap);
        if exported.is_empty() {
            return Err(format!(
                "build-ffi: FAIL — {target}: nm --print-armap named no slopdesk_* symbol at all. That is \
                 this check going blind, not a library with no doors — every declared symbol would read as \
                 absent."
            ));
        }

        // On a slice that is not macOS, a macOS-only door is not declared — and the OTHER direction
        // of the bijection then requires it to be absent from the library too, which is the half
        // that catches a `cfg` that stopped matching the header.
        let expected: BTreeSet<String> = if target == MACOS_SLICE {
            declared.clone()
        } else {
            declared.difference(macos_only).cloned().collect()
        };

        let (absent, undeclared) = verdict(&exported, &expected);
        if !absent.is_empty() {
            eprintln!("{}", absent.join("\n"));
            return Err(format!(
                "build-ffi: FAIL — {target}: slopdesk_ffi.h declares a symbol the library does not export — \
                 the header and src/lib.rs disagree"
            ));
        }
        if !undeclared.is_empty() {
            eprintln!("{}", undeclared.join("\n"));
            return Err(format!(
                "build-ffi: FAIL — {target}: the library exports a slopdesk_* symbol slopdesk_ffi.h never \
                 declares — a door Swift cannot open (docs/55)"
            ));
        }
        archives.push(archive);
    }
    Ok(archives)
}

/// `xcodebuild -create-xcframework` over the three checked slices.
fn assemble(root: &Path, xcframework: &Path, stage: &Path, archives: &[PathBuf]) -> Result<(), String> {
    if let Some(parent) = xcframework.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("{}: {error}", parent.display()))?;
    }
    let _ignored = fs::remove_dir_all(xcframework);
    let mut arguments: Vec<std::ffi::OsString> = vec!["-create-xcframework".into()];
    for archive in archives {
        arguments.push("-library".into());
        arguments.push(archive.as_os_str().to_owned());
        arguments.push("-headers".into());
        arguments.push(stage.as_os_str().to_owned());
    }
    arguments.push("-output".into());
    arguments.push(xcframework.as_os_str().to_owned());
    // The STATUS decides, not the output. `proc::ask` reads stdout as UTF-8 and answers `None` when
    // it is not, which would report a successful assembly as a failure.
    let status = Command::new("xcodebuild")
        .args(&arguments)
        .current_dir(root)
        .stdout(std::process::Stdio::null())
        .status()
        .map_err(|error| format!("build-ffi: FAIL — xcodebuild: {error}"))?;
    if !status.success() {
        return Err("build-ffi: FAIL — xcodebuild -create-xcframework failed".to_owned());
    }
    Ok(())
}

/// The nesting is the whole reason both apps build; assert it rather than trust the copy.
fn assert_nesting(xcframework: &Path) -> Result<(), String> {
    let entries = fs::read_dir(xcframework).map_err(|error| format!("{}: {error}", xcframework.display()))?;
    for entry in entries {
        let slice = entry
            .map_err(|error| format!("{}: {error}", xcframework.display()))?
            .path();
        let headers = slice.join("Headers");
        if !headers.is_dir() {
            continue;
        }
        if !headers.join("CSlopDeskFFI/module.modulemap").is_file() {
            return Err(format!(
                "build-ffi: FAIL — {} has no Headers/CSlopDeskFFI/module.modulemap",
                slice.display()
            ));
        }
        if headers.join("module.modulemap").is_file() {
            return Err(format!(
                "build-ffi: FAIL — {} has a modulemap at its Headers ROOT — it will collide with \
                 libghostty's in $BUILT_PRODUCTS_DIR/include and neither app will build",
                slice.display()
            ));
        }
    }
    Ok(())
}

/// One archive's symbol index, decoded LOSSILY.
///
/// Not `proc::ask`, and the difference is the whole check: with `lto = "fat"` the archive members
/// are LLVM bitcode, and `nm`'s dump of a 55 MB one is not valid UTF-8 end to end. A strict decode
/// answers `None`, `unwrap_or_default` turns that into the empty string, and every declared symbol
/// then reads as ABSENT — a gate that fails 784 times while proving nothing. The symbol NAMES are
/// ASCII, so replacing the undecodable bytes loses nothing this reads.
fn read_armap(archive: &Path) -> Result<String, String> {
    let output = Command::new("nm")
        .arg("--print-armap")
        .arg(archive)
        .output()
        .map_err(|error| format!("build-ffi: FAIL — nm: {error}"))?;
    // The STATUS is not the answer either. `nm` exits 1 on an archive holding a member with no
    // symbol table — which every LTO build of this shim has — while still printing the whole index
    // it was asked for. What decides that this read worked is the emptiness guard at the call site:
    // a dump naming no `slopdesk_*` at all is this check going blind, and it says so there.
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Every `slopdesk_*` name declared as a call shape in some C text.
fn door_names(text: &str) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    for (index, _) in text.match_indices("slopdesk_") {
        // A door NAME starts a word: `_slopdesk_` inside an armap line, or `xslopdesk_`, is not
        // one.
        if index > 0 {
            let previous = text[..index].chars().next_back().unwrap_or(' ');
            if previous.is_alphanumeric() || previous == '_' {
                continue;
            }
        }
        let rest = &text[index..];
        let width = rest
            .char_indices()
            .take_while(|(_, character)| {
                character.is_ascii_lowercase() || character.is_ascii_digit() || *character == '_'
            })
            .count();
        if rest[width..].starts_with('(') {
            found.insert(rest[..width].to_owned());
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::fs;

    use super::{
        declared_symbols, exported_symbols, input_crates, macos_only_symbols, path_dependencies, verdict,
    };

    fn set(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    /// The header is the promise, and a typedef is not a declaration.
    #[test]
    fn only_real_declarations_are_read_out_of_the_header() {
        let header = "\
size_t slopdesk_ws_min_weight(uint8_t *out, size_t cap);
typedef void (*slopdesk_callback_t)(void *context);
// slopdesk_prose_only is a comment, but it has no call shape.
bool slopdesk_agent_attention_completion(uint8_t before, uint8_t after);
";
        assert_eq!(
            declared_symbols(header),
            set(&["_slopdesk_ws_min_weight", "_slopdesk_agent_attention_completion"])
        );
    }

    /// The macOS-only region is a SUBSET, and the doors outside it are not in it.
    #[test]
    fn the_macos_region_holds_only_what_it_encloses() {
        let header = "\
size_t slopdesk_everywhere(uint8_t *out);
/* MACOS-ONLY BEGIN */
size_t slopdesk_git_status(const uint8_t *root, size_t len);
/* MACOS-ONLY END */
size_t slopdesk_also_everywhere(uint8_t *out);
";
        assert_eq!(macos_only_symbols(header), set(&["_slopdesk_git_status"]));
        assert!(declared_symbols(header).contains("_slopdesk_everywhere"));
    }

    /// A door renamed to a LONGER name is a different symbol, which the shell's `grep -c` could not
    /// say: `_slopdesk_ws_min` counted `_slopdesk_ws_min_leaf` and kept passing.
    #[test]
    fn a_longer_name_is_a_different_symbol() {
        let armap = "0x00 _slopdesk_ws_min_leaf\n0x08 _slopdesk_other\n";
        let exported = exported_symbols(armap);
        assert_eq!(exported, set(&["_slopdesk_ws_min_leaf", "_slopdesk_other"]));
        let (absent, _) = verdict(&exported, &set(&["_slopdesk_ws_min"]));
        assert_eq!(absent, vec!["_slopdesk_ws_min".to_owned()]);
    }

    /// Both directions, which is the whole point: a door with no handle is as much a finding as a
    /// declaration with no symbol.
    #[test]
    fn the_bijection_is_checked_both_ways() {
        let exported = set(&["_slopdesk_a", "_slopdesk_orphan"]);
        let declared = set(&["_slopdesk_a", "_slopdesk_missing"]);
        let (absent, undeclared) = verdict(&exported, &declared);
        assert_eq!(absent, vec!["_slopdesk_missing".to_owned()]);
        assert_eq!(undeclared, vec!["_slopdesk_orphan".to_owned()]);

        let exact = set(&["_slopdesk_a"]);
        assert_eq!(verdict(&exact, &exact), (Vec::new(), Vec::new()));
    }

    /// Only SIBLING path dependencies, and only from a table entry — a `[dependencies]` header or a
    /// registry version is not one.
    #[test]
    fn path_dependencies_are_the_sibling_crates_only() {
        let manifest = r#"
[dependencies]
slopdesk-video = { path = "../slopdesk-video" }
slopdesk-agent = { path = "../slopdesk-agent", features = ["badge"] }
serde = { version = "1", features = ["derive"] }
vendored = { path = "../../ThirdParty/thing" }
regex = "1"
"#;
        assert_eq!(path_dependencies(manifest), vec![
            "slopdesk-video",
            "slopdesk-agent"
        ]);
    }

    /// The closure is TRANSITIVE, which is the property that keeps a NEON edit two crates down from
    /// shipping against yesterday's archive.
    #[test]
    fn the_crate_closure_is_transitive() {
        let root = std::env::temp_dir().join(format!("slopdesk-ffi-graph-{}", std::process::id()));
        let _ignored = fs::remove_dir_all(&root);
        for (name, body) in [
            (
                "slopdesk-ffi",
                "slopdesk-video = { path = \"../slopdesk-video\" }\n",
            ),
            (
                "slopdesk-video",
                "slopdesk-gfsimd = { path = \"../slopdesk-gfsimd\" }\n",
            ),
            ("slopdesk-gfsimd", "\n"),
        ] {
            let dir = root.join("rust").join(name);
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("Cargo.toml"), format!("[dependencies]\n{body}")).unwrap();
        }
        let crates = input_crates(&root).unwrap();
        assert_eq!(crates, vec![
            "rust/slopdesk-ffi",
            "rust/slopdesk-gfsimd",
            "rust/slopdesk-video"
        ]);
        let _ignored = fs::remove_dir_all(&root);
    }

    /// A shim with no path dependency is a moved manifest, not an empty graph.
    #[test]
    fn a_shim_with_no_path_dependency_is_an_error() {
        let root = std::env::temp_dir().join(format!("slopdesk-ffi-lonely-{}", std::process::id()));
        let _ignored = fs::remove_dir_all(&root);
        let dir = root.join("rust/slopdesk-ffi");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("Cargo.toml"), "[dependencies]\nregex = \"1\"\n").unwrap();
        assert!(input_crates(&root).is_err());
        let _ignored = fs::remove_dir_all(&root);
    }
}

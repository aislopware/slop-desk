//! Upstream sync + parity gate for the herdr-ported detect engine (`rust/slopdesk-screend`).
//!
//! `scripts/herdr.pin` records the herdr commit the port is proven equivalent to. This advances
//! that proof to a newer upstream commit:
//!
//! 1. fetch upstream and show what changed under `src/detect` since the pin,
//! 2. check the target out and re-sync `rust/slopdesk-screend/manifests/*.toml` verbatim
//!    (`slopdesk-herdr manifests`, which fails loudly if the manifest SET changed),
//! 3. list `src/detect` `*.rs` changes — engine-code changes need a manual port, but even an unread
//!    one cannot slip through, because step 5 diffs the real binaries,
//! 4. build the herdr oracle (its vendored `libghostty-vt` needs the pinned Zig and the `xcrun` SDK
//!    shim from `ThirdParty/ghostty`) and slopdesk's own, `slopdesk-screend explain`,
//! 5. run `slopdesk-herdr differential` — ~10k generated screens through BOTH engines, field-level
//!    diff of the full evaluation traces,
//! 6. run the screend parity suite,
//! 7. with `--update-pin`, record the newly proven commit.
//!
//! ## What the port changed
//! Nothing about the sequence, which is the point — every step here is a tool this cannot be. What
//! it removes is the shell's `BUILD_ENV=()` array dance, which existed because bash 3.2 under
//! `set -u` treats an empty array's expansion as an unbound variable, and the ANSI escape codes
//! hand-written into every log line.

use std::collections::BTreeMap;
use std::path::Path;
use std::{env, fs};

use super::say;
use crate::proc;

/// A short sha, as every line of this tool prints one.
fn short(sha: &str) -> &str {
    &sha[..sha.len().min(12)]
}

/// Prove parity against an upstream commit, and optionally record it.
///
/// # Errors
/// When the checkout is missing or dirty, the pin is unreadable, a build fails, or the
/// differential finds a disagreement.
pub fn run(root: &Path, herdr_dir: &Path, target: &str, update_pin: bool) -> Result<(), String> {
    if !herdr_dir.join("src/detect").is_dir() {
        return Err(format!(
            "no herdr checkout at {} (set HERDR_DIR or: git clone https://github.com/ogulcancelik/herdr.git)",
            herdr_dir.display()
        ));
    }
    let pin_file = root.join("scripts/herdr.pin");
    let pin = fs::read_to_string(&pin_file)
        .map_err(|error| format!("missing {}: {error}", pin_file.display()))?
        .trim()
        .to_owned();
    if pin.is_empty() {
        return Err(format!("missing {}", pin_file.display()));
    }

    say("herdr-sync", "fetching upstream…");
    proc::run(
        "git",
        &["-C", &herdr_dir.to_string_lossy(), "fetch", "--quiet", "origin"],
        root,
    )?;
    let target_sha = proc::capture(
        "git",
        &[
            "-C",
            &herdr_dir.to_string_lossy(),
            "rev-parse",
            &format!("{target}^{{commit}}"),
        ],
        root,
    )?;

    say(
        "herdr-sync",
        &format!("pin {} → target {}", short(&pin), short(&target_sha)),
    );
    report_delta(root, herdr_dir, &pin, &target_sha)?;

    let dirty = proc::capture(
        "git",
        &[
            "-C",
            &herdr_dir.to_string_lossy(),
            "status",
            "--porcelain",
            "--",
            "src",
        ],
        root,
    )?;
    if !dirty.trim().is_empty() {
        return Err("herdr checkout has local src changes — clean it first".to_owned());
    }
    proc::run(
        "git",
        &[
            "-C",
            &herdr_dir.to_string_lossy(),
            "checkout",
            "--quiet",
            &target_sha,
        ],
        root,
    )?;

    say("herdr-sync", "building the operator tools (slopdesk-herdr)…");
    let devtools_dir = root.join("rust/slopdesk-devtools");
    proc::run("cargo", &["build", "--release"], &devtools_dir)?;
    let devtools = devtools_dir.join("target/release");

    say(
        "herdr-sync",
        "re-syncing rust/slopdesk-screend/manifests/*.toml from upstream…",
    );
    proc::run(
        &devtools.join("slopdesk-herdr").to_string_lossy(),
        &[
            "manifests",
            "--repo-root",
            &root.to_string_lossy(),
            "--herdr-dir",
            &herdr_dir.to_string_lossy(),
        ],
        root,
    )?;

    // An engine-code change is a NOTICE, never a failure: the differential below is what gates the
    // result, and stopping here would stop before the thing that proves anything.
    let changes = proc::ask(
        "git",
        &[
            "-C",
            &herdr_dir.to_string_lossy(),
            "diff",
            "--name-only",
            &pin,
            &target_sha,
            "--",
            "src/detect/*.rs",
            "src/detect/manifest/*.rs",
        ],
        root,
    )
    .unwrap_or_default();
    if !changes.trim().is_empty() {
        say(
            "herdr-sync",
            "ENGINE CODE changed upstream — review + port by hand into rust/slopdesk-screend/src,",
        );
        say("herdr-sync", "the differential below gates the result:");
        indent(&changes);
        say(
            "herdr-sync",
            &format!(
                "view with: git -C {} diff {} {} -- src/detect",
                herdr_dir.display(),
                short(&pin),
                short(&target_sha)
            ),
        );
    }

    say(
        "herdr-sync",
        "building herdr oracle (cargo, vendored libghostty-vt via Zig)…",
    );
    build_oracle(root, herdr_dir)?;

    say(
        "herdr-sync",
        "building the ported engine's oracle (slopdesk-screend explain)…",
    );
    proc::run(
        "cargo",
        &["build", "--release"],
        &root.join("rust/slopdesk-screend"),
    )?;

    say("herdr-sync", "running the differential parity harness…");
    proc::run(
        &devtools.join("slopdesk-herdr").to_string_lossy(),
        &[
            "differential",
            "--repo-root",
            &root.to_string_lossy(),
            "--herdr-dir",
            &herdr_dir.to_string_lossy(),
        ],
        root,
    )?;

    say("herdr-sync", "running the screend parity test suite…");
    proc::run("cargo", &["test"], &root.join("rust/slopdesk-screend"))?;

    if update_pin {
        fs::write(&pin_file, format!("{target_sha}\n"))
            .map_err(|error| format!("{}: {error}", pin_file.display()))?;
        say(
            "herdr-sync",
            &format!(
                "pin advanced to {} — commit scripts/herdr.pin with the sync",
                short(&target_sha)
            ),
        );
    } else {
        say(
            "herdr-sync",
            &format!(
                "parity proven against {} (pin unchanged; rerun with --update-pin to record it)",
                short(&target_sha)
            ),
        );
    }
    say(
        "herdr-sync",
        "done — the re-sync may have touched rust/slopdesk-screend/manifests; run make check before \
         committing",
    );
    Ok(())
}

/// Print what moved under `src/detect` between the pin and the target.
///
/// # Errors
/// When either `git` invocation fails.
fn report_delta(root: &Path, herdr_dir: &Path, pin: &str, target_sha: &str) -> Result<(), String> {
    if pin == target_sha {
        say(
            "herdr-sync",
            "already at the pinned commit — re-proving parity anyway",
        );
        return Ok(());
    }
    let checkout = herdr_dir.to_string_lossy().into_owned();
    say("herdr-sync", "src/detect changes since the pin:");
    indent(&proc::capture(
        "git",
        &[
            "-C",
            &checkout,
            "--no-pager",
            "log",
            "--oneline",
            &format!("{pin}..{target_sha}"),
            "--",
            "src/detect",
        ],
        root,
    )?);
    indent(&proc::capture(
        "git",
        &[
            "-C",
            &checkout,
            "--no-pager",
            "diff",
            "--stat",
            pin,
            target_sha,
            "--",
            "src/detect",
        ],
        root,
    )?);
    Ok(())
}

/// Build herdr's own binary, with the pinned Zig and the SDK shim on `PATH` when they are there.
///
/// # Errors
/// When the build fails.
fn build_oracle(root: &Path, herdr_dir: &Path) -> Result<(), String> {
    use std::process::Command;

    let zig = root.join("ThirdParty/ghostty/.toolchain/zig-aarch64-macos-0.15.2/zig");
    let shim = root.join("ThirdParty/ghostty/.work/bin");
    let mut overrides: BTreeMap<&str, String> = BTreeMap::new();
    if zig.is_file() {
        overrides.insert("ZIG", zig.display().to_string());
    }
    if shim.join("xcrun").is_file() {
        let path = env::var("PATH").unwrap_or_default();
        overrides.insert("PATH", format!("{}:{path}", shim.display()));
    } else {
        say(
            "herdr-sync",
            &format!(
                "warning: no xcrun SDK shim at {} — if the zig step fails with",
                shim.display()
            ),
        );
        say(
            "herdr-sync",
            "         undefined libSystem symbols, run ThirdParty/ghostty/build-libghostty.sh once",
        );
    }

    let mut command = Command::new("cargo");
    command
        .args(["build", "--release", "--bin", "herdr"])
        .current_dir(herdr_dir);
    for (key, value) in overrides {
        command.env(key, value);
    }
    let status = command.status().map_err(|error| format!("cargo: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "the herdr oracle build exited {}",
            status.code().unwrap_or(-1)
        ))
    }
}

/// Print a block indented, the way the shell's `sed 's/^/    /'` did.
fn indent(text: &str) {
    for line in text.lines() {
        println!("    {line}");
    }
}

#[cfg(test)]
mod tests {
    /// A sha prints short, and a short one is not sliced past its end.
    #[test]
    fn a_sha_prints_at_most_twelve_characters() {
        assert_eq!(super::short("0123456789abcdef0123"), "0123456789ab");
        assert_eq!(super::short("abc"), "abc");
        assert_eq!(super::short(""), "");
    }
}

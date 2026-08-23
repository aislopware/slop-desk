//! `slopdesk-swift-access` — raise `internal` declarations to `package` across a moved target.
//!
//!   slopdesk-swift-access [--dry-run] <path>…
//!
//! A path may be a file or a directory; a directory contributes every `.swift` under it. The
//! decision of what gets annotated, and why each exclusion is there, lives in
//! `slopdesk_devtools::access` — read that first. The compiler is the oracle either way: run
//! `swift build` after.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use slopdesk_devtools::access::{add_rawvalue_inits, transform};

/// The usage line, which is also the error for a call with no paths.
const USAGE: &str = "usage: slopdesk-swift-access [--dry-run] <path>…";

fn main() -> ExitCode {
    match run(&std::env::args().skip(1).collect::<Vec<String>>()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(complaint) => {
            eprintln!("{complaint}");
            ExitCode::FAILURE
        },
    }
}

/// Collect the files, rewrite each, and report the per-file counts.
fn run(arguments: &[String]) -> Result<(), String> {
    let mut dry_run = false;
    let mut roots: Vec<PathBuf> = Vec::new();
    for argument in arguments {
        match argument.as_str() {
            "--dry-run" => dry_run = true,
            other if other.starts_with("--") => {
                return Err(format!("unknown flag {other:?}\n{USAGE}"));
            },
            other => roots.push(PathBuf::from(other)),
        }
    }
    if roots.is_empty() {
        return Err(USAGE.to_owned());
    }

    let mut files: Vec<PathBuf> = Vec::new();
    for root in &roots {
        if root.is_dir() {
            let mut found = Vec::new();
            gather(root, &mut found)?;
            found.sort();
            files.extend(found);
        } else {
            files.push(root.clone());
        }
    }

    let mut total = 0;
    for file in &files {
        let original =
            fs::read_to_string(file).map_err(|error| format!("cannot read {}: {error}", file.display()))?;
        let (updated, mut raised) = transform(&original);
        let (updated, inits) = add_rawvalue_inits(&updated);
        raised += inits;
        if raised > 0 {
            if !dry_run {
                fs::write(file, &updated)
                    .map_err(|error| format!("cannot write {}: {error}", file.display()))?;
            }
            println!("{raised:5}  {}", file.display());
        }
        total += raised;
    }
    println!(
        "--- {total} declarations raised to `package` across {} files",
        files.len()
    );
    Ok(())
}

/// Every `.swift` under `directory`, depth first.
fn gather(directory: &Path, found: &mut Vec<PathBuf>) -> Result<(), String> {
    let entries =
        fs::read_dir(directory).map_err(|error| format!("cannot read {}: {error}", directory.display()))?;
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if path.is_dir() {
            gather(&path, found)?;
        } else if path.extension().is_some_and(|extension| extension == "swift") {
            found.push(path);
        }
    }
    Ok(())
}

//! Where the tree is, and where herdr's checkout is.
//!
//! A Python script knew the repo root from `__file__`; a compiled binary does not, because the
//! binary is in `target/` and may be run from anywhere. Three answers in order, each strictly more
//! trustworthy than the next fallback: what the caller said, what the working directory is inside,
//! and where the crate was compiled from.

use std::env;
use std::path::{Path, PathBuf};

/// The default herdr checkout, matching what `scripts/herdr-sync.sh` clones into.
#[must_use]
pub fn default_herdr_dir() -> PathBuf {
    let home = env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
    home.join(".cache/clio-repos/github.com--ogulcancelik--herdr")
}

/// The files that together mean "this is the slopdesk tree" and not some parent of it.
///
/// Two markers rather than one: a lone `Makefile` is the most common file in any ancestor
/// directory a developer might be sitting in, and `rust/slopdesk-screend` is not.
fn is_root(candidate: &Path) -> bool {
    candidate.join("Makefile").is_file() && candidate.join("rust/slopdesk-screend").is_dir()
}

/// The repository root, or an explanation of everywhere it was looked for.
///
/// # Errors
/// When no ancestor of the working directory is the tree and the compiled-in path is gone — which
/// is what a binary copied out of `target/` and run elsewhere looks like.
pub fn root(override_path: Option<&Path>) -> Result<PathBuf, String> {
    if let Some(given) = override_path {
        return if is_root(given) {
            Ok(given.to_path_buf())
        } else {
            Err(format!("--repo-root {} is not a slopdesk tree", given.display()))
        };
    }
    let here = env::current_dir().ok().and_then(|cwd| {
        cwd.ancestors()
            .find(|candidate| is_root(candidate))
            .map(Path::to_path_buf)
    });
    if let Some(found) = here {
        return Ok(found);
    }
    // `CARGO_MANIFEST_DIR` is `rust/slopdesk-devtools`, so the tree is two levels up. This is the
    // answer for a binary run from an absolute path with the working directory somewhere else.
    let compiled = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf);
    match compiled {
        Some(path) if is_root(&path) => Ok(path),
        _ => {
            Err(
                "not inside a slopdesk tree, and the path this binary was compiled from is gone — pass \
                 --repo-root"
                    .to_owned(),
            )
        },
    }
}

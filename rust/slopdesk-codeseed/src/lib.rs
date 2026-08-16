//! The code panel's workbench profile — settings, themes, the bridge extension, and the argv and
//! environment the code-server child launches with.
//!
//! ## What this program is, and what it is NOT
//! It owns the PROFILE. hostd keeps the SUPERVISION: the child's process handle, its readiness
//! probe, the port it announced, the prewarm at boot, the lock that serializes `ensure`. Those are
//! bookkeeping only the process holding the handle can do, and `ensure` sits on a ~1 Hz client poll
//! where forking anything would be the wrong shape.
//!
//! Everything here is a decision ABOUT files: what a settings file should say, whether the one on
//! disk is still the seed we wrote, which folders an old version left behind. None of it needs a
//! process handle, and all of it was easier to get wrong in a language without sum types.
//!
//! ## The seeder's one promise
//! **A seed is a nicety.** Every failure is a silent no-op: the workbench comes up unthemed rather
//! than not at all. No function here returns an error — each answers whether it CHANGED something,
//! and a run that could not read a directory reports the honest `false`. That promise is why the
//! panic lints in `Cargo.toml` are denials rather than warnings.

pub mod extensions;
pub mod json;
pub mod launch;
pub mod paths;
pub mod seed_history;
pub mod settings;

#[cfg(test)]
pub mod scratch;

use std::path::Path;

/// Seeds everything a fresh profile needs, in the order the ensure chain has always run it.
///
/// The RETIRED sweep precedes the live seed on purpose: a folder deleted after its replacement was
/// registered would leave the registry pointing, for one boot, at a directory that no longer
/// exists. Every step is independent — one returning `false` never stops the next, because the
/// steps repair different files and a profile half-seeded is still better than one not seeded.
///
/// Returns whether any step changed something.
#[must_use]
pub fn seed_profile(data_dir: &Path) -> bool {
    let extensions_dir = data_dir.join("extensions");
    let user = settings::seed_user_settings(&data_dir.join("User/settings.json"));
    let retired = extensions::remove_retired_extensions(&extensions_dir);
    let theme = extensions::seed_theme_extension(&extensions_dir);
    let bridge = extensions::seed_bridge_extension(&extensions_dir);
    user || retired || theme || bridge
}

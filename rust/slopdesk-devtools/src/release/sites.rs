//! The PRODUCT version, and the six places that carry it.
//!
//! The packager has a drift gate, but it can only compare the CLI's compiled-in version against
//! the version it was asked to build — it cannot see the other five sites, so
//! `CFBundleShortVersionString` sat a release behind twice without failing anything. This module is
//! the reason that cannot happen again: one version in, six writes, and a verification pass that
//! reads every site back off disk.
//!
//! ## The sixth site is generated AND committed
//! `Apps/*/Info.plist` is xcodegen's output from the spec's `info.properties`, and it is in git
//! because a clean checkout has to build without running xcodegen first. Editing the spec alone
//! leaves the plist stale, so the regeneration happens here rather than in a step someone
//! remembers.
//!
//! ## What is deliberately NOT here
//! `Apps/ClientApp-iOS/{project,project-video}.yml` and its `Info.plist`. There is no iOS release,
//! so its `0.1.0` is a spec version rather than a shipped one (`docs/49` §"No iOS client
//! release"). Recorded because the omission is indistinguishable from the bug this exists to
//! prevent — a site sitting a release behind — and the next reader would either "fix" it or, worse,
//! add iOS to the release train and inherit the same silence.

use std::fs;
use std::path::Path;

use regex::Regex;

use crate::proc;

/// A Swift constant carrying the product version: the file, and the assignment that anchors it.
///
/// Each anchor is the KEY, so the replacement cannot wander into some other quoted string in the
/// same file.
const SWIFT_SITES: [(&str, &str); 2] = [
    (
        "Sources/SlopDeskCLICore/CLIVersion.swift",
        "public static let version = ",
    ),
    (
        "Sources/SlopDeskHost/HostEnvironment.swift",
        "public static let buildVersion = ",
    ),
];

/// The xcodegen specs whose `info.properties` and build settings carry the version.
const SPECS: [&str; 2] = [
    "Apps/ClientApp-macOS/project.yml",
    "Apps/HostApp-macOS/project.yml",
];

/// The generated, committed plists — the two sites nobody edits and everybody reads.
const PLISTS: [&str; 2] = ["Apps/ClientApp-macOS/Info.plist", "Apps/HostApp-macOS/Info.plist"];

/// Every file the product version must read back from, in the order the cut stages them.
#[must_use]
pub fn all_sites() -> Vec<&'static str> {
    let mut sites: Vec<&'static str> = SWIFT_SITES.iter().map(|(file, _)| *file).collect();
    sites.extend(SPECS);
    sites.extend(PLISTS);
    sites
}

/// True when `version` is a semver with no leading `v`.
#[must_use]
pub fn is_semver(version: &str) -> bool {
    let core = version.split(['-', '+']).next().unwrap_or_default();
    let suffix = &version[core.len()..];
    let mut parts = core.split('.');
    let numeric = |part: Option<&str>| {
        part.is_some_and(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))
    };
    if !numeric(parts.next()) || !numeric(parts.next()) || !numeric(parts.next()) || parts.next().is_some() {
        return false;
    }
    if suffix.is_empty() {
        return true;
    }
    suffix.len() > 1
        && suffix[1..]
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

/// Write `version` into every site, regenerate the plists, and read all six back.
///
/// # Errors
/// When an anchor has moved, xcodegen is absent or fails, a site does not carry the version after
/// the write, or a version-shaped string that is not `version` survives in one of the six.
pub fn bump(root: &Path, version: &str) -> Result<(), String> {
    if !is_semver(version) {
        return Err(format!(
            "bump-version: not a semver without a leading v: {version}"
        ));
    }

    for (file, key) in SWIFT_SITES {
        let path = root.join(file);
        let text = fs::read_to_string(&path)
            .map_err(|_| format!("bump-version: missing {file} — has the constant moved?"))?;
        if !text.contains(key) {
            return Err(format!("bump-version: no `{key}` in {file} — the anchor moved"));
        }
        let pattern = Regex::new(&format!("{}\"[^\"]*\"", regex::escape(key)))
            .map_err(|error| format!("{file}: {error}"))?;
        let rewritten = pattern.replace(&text, format!("{key}\"{version}\"").as_str());
        fs::write(&path, rewritten.as_ref()).map_err(|error| format!("{file}: {error}"))?;
    }

    let short = Regex::new(r"(?m)^(\s*CFBundleShortVersionString:\s*)\x22[^\x22]*\x22")
        .map_err(|error| error.to_string())?;
    let marketing =
        Regex::new(r"(?m)^(\s*MARKETING_VERSION:\s*)\x22[^\x22]*\x22").map_err(|error| error.to_string())?;
    for spec in SPECS {
        let path = root.join(spec);
        let text = fs::read_to_string(&path).map_err(|_| format!("bump-version: missing {spec}"))?;
        let text = short.replace_all(&text, format!("${{1}}\"{version}\"").as_str());
        let text = marketing.replace_all(&text, format!("${{1}}\"{version}\"").as_str());
        fs::write(&path, text.as_ref()).map_err(|error| format!("{spec}: {error}"))?;
    }

    // Regenerate the committed plists from the specs just edited. xcodegen also rewrites the
    // gitignored `.xcodeproj`, which is fine — it is derived either way.
    if !proc::on_path("xcodegen") {
        return Err("bump-version: xcodegen not on PATH (brew install xcodegen)".to_owned());
    }
    for spec in SPECS {
        proc::run("xcodegen", &["generate", "--spec", spec, "--quiet"], root)?;
    }

    verify(root, version)
}

/// Read every site back off disk, then sweep for a version this write did not reach.
///
/// The check is on the FILES, not on this program's belief about what it wrote: a substitution
/// that silently matched nothing — an anchor that drifted, a spec key that got requoted — is
/// exactly the failure the whole module exists to prevent.
fn verify(root: &Path, version: &str) -> Result<(), String> {
    let mut failed = Vec::new();
    let mut stale = Vec::new();
    let version_shaped = Regex::new(r#""[0-9]+\.[0-9]+\.[0-9]+""#).map_err(|error| error.to_string())?;
    let wanted = format!("\"{version}\"");

    for file in all_sites() {
        let text =
            fs::read_to_string(root.join(file)).map_err(|error| format!("bump-version: {file}: {error}"))?;
        if text.contains(version) {
            println!("  ok   {file}");
        } else {
            eprintln!("  FAIL {file} — no {version} after the write");
            failed.push(file);
        }
        // Any OTHER version-shaped string left in these files is a site this does not know about,
        // or a stale one it failed to reach. Either way the next release inherits the drift.
        for (number, line) in text.lines().enumerate() {
            if version_shaped.is_match(line) && !line.contains(&wanted) {
                stale.push(format!("{file}:{}: {}", number + 1, line.trim()));
            }
        }
    }

    if !failed.is_empty() {
        return Err("bump-version: at least one site did not take the version".to_owned());
    }
    if !stale.is_empty() {
        eprintln!("bump-version: a version string that is not {version} survived:");
        for line in &stale {
            eprintln!("{line}");
        }
        return Err("bump-version: add the site to this program or fix the file".to_owned());
    }
    println!("bump-version: every site reads {version}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{all_sites, is_semver};

    #[test]
    fn the_six_sites_are_six() {
        let sites = all_sites();
        assert_eq!(sites.len(), 6, "{sites:?}");
    }

    #[test]
    fn a_semver_carries_no_leading_v_and_may_carry_a_suffix() {
        assert!(is_semver("0.2.3"));
        assert!(is_semver("10.0.0"));
        assert!(is_semver("0.2.3-rc.1"));
        assert!(is_semver("0.2.3+build.7"));
    }

    #[test]
    fn everything_else_is_not_a_semver() {
        for bad in [
            "v0.2.3", "0.2", "0.2.3.4", "0.2.x", "", "0.2.3-", "0.2.3 ", "-1.0.0",
        ] {
            assert!(!is_semver(bad), "accepted {bad:?}");
        }
    }
}

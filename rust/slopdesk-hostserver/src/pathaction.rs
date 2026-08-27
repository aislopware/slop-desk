//! The two side-effecting PATH verbs: open a host path in its default app, reveal it in Finder.
//!
//! `Sources/SlopDeskHost/HostPathActionPerformer.swift` is 97 lines of which four are `AppKit`. The
//! rest is a validator — expand a tilde, refuse a relative path, refuse a missing one — and it is
//! the part that matters: a caller reaching this performer has already been routed here by
//! [`slopdesk_muxsession::metadata_admission::performer`], so what is left to get wrong is what a
//! hostile argument does. The Swift's own header says this shim is "compiled + code-reviewed ONLY"
//! because `NSWorkspace` needs a window server; the split below is what makes the reviewed half
//! testable instead.
//!
//! ## No confinement, and that is not an oversight
//! The READ verbs (`gitDiff`, `listDirectory`, `readAgentSession`) are confined to the pane's cwd
//! subtree because they stream host file CONTENTS back over the wire. These two return a status
//! byte and an empty payload — no host bytes cross — so they accept any ABSOLUTE host path, which
//! is what makes ⌘-clicking a path outside the cwd work at all. The security boundary is the
//! `WireGuard` mesh, as everywhere else; the validation below is defensive, not a permission model.
//!
//! ## Where the two halves live
//! [`PathActions`] is the reducer and [`OpensPaths`] is the door. The production door is
//! [`Finder`], four lines over `slopdesk_apple_app`; every test drives a fake that records what it
//! was asked and answers what the test wants, including the arm where Launch Services declines.

use std::path::{Component, PathBuf};

use slopdesk_hostsession::{MetadataAnswer, MetadataPerformer, MetadataRequest};
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::metadata::MetadataVerb;

/// The host effects these two verbs actuate.
///
/// Two methods with different shapes, because the framework's are: an open REPORTS whether Launch
/// Services took it, a reveal does not — there is no "the Finder declined". Flattening them into
/// one `-> bool` would invent an answer for the reveal that the caller would then have to ignore.
pub trait OpensPaths: Send + Sync + core::fmt::Debug {
    /// Opens `path` in whichever application claims it. `false` when Launch Services declined.
    ///
    /// `path` arrives ABSOLUTE, standardised and known to exist — [`PathActions`] has already
    /// refused everything else.
    fn open(&self, path: &str) -> bool;

    /// Reveals `path` in the host's Finder, with the same guarantees about `path` as
    /// [`Self::open`].
    fn reveal(&self, path: &str);
}

/// The production door: the host's own Finder and Launch Services.
#[derive(Debug, Clone, Copy)]
pub struct Finder;

impl OpensPaths for Finder {
    fn open(&self, path: &str) -> bool {
        slopdesk_apple_app::open_path(path)
    }

    fn reveal(&self, path: &str) {
        slopdesk_apple_app::reveal_path(path);
    }
}

/// The performer for [`MetadataVerb::OpenPath`] and [`MetadataVerb::RevealPath`].
///
/// Holds `$HOME` because the tilde expansion needs it and because a performer that read the
/// environment per request would be untestable for the one case that matters — a `~` arriving from
/// a client whose home is not this machine's.
#[derive(Debug)]
pub struct PathActions<D> {
    door: D,
    home: String,
}

impl<D: OpensPaths> PathActions<D> {
    /// A performer over `door`, expanding `~` against `home`.
    pub const fn new(door: D, home: String) -> Self {
        Self { door, home }
    }

    /// A performer over `door`, taking `$HOME` from the environment.
    ///
    /// A missing `HOME` gives an EMPTY home, and [`Self::expand_tilde`] refuses every tilde against
    /// one — the honest answer for a daemon that cannot say where home is.
    #[must_use]
    pub fn from_environment(door: D) -> Self {
        Self::new(door, std::env::var("HOME").unwrap_or_default())
    }

    /// The verb's answer. See the module doc for what is validated and what deliberately is not.
    fn answer(&self, verb: MetadataVerb, argument: &str) -> MetadataStatus {
        let Some(path) = absolute_host_path(argument, &self.home) else {
            return MetadataStatus::Error;
        };
        if !std::fs::exists(&path).unwrap_or(false) {
            return MetadataStatus::NotFound;
        }
        match verb {
            MetadataVerb::OpenPath => {
                if self.door.open(&path) {
                    MetadataStatus::Ok
                } else {
                    MetadataStatus::Error
                }
            },
            MetadataVerb::RevealPath => {
                // Void by contract — the success condition is the existence check one line up, the
                // way the Swift's own comment says it is.
                self.door.reveal(&path);
                MetadataStatus::Ok
            },
            // Unreachable: the routing table sends only these two here. `error` rather than a
            // second opinion about who owns a verb — the same answer `HostMetadata` gives.
            _ => MetadataStatus::Error,
        }
    }
}

/// An argument as an absolute, standardised host path, or `None` when it is neither.
///
/// Three steps, in the Swift's order: expand a leading `~` against `home`, require the result to be
/// absolute, then normalise `.` and `..` away. The normalisation is LEXICAL and deliberately does
/// not resolve symlinks — the existence check that follows resolves them anyway, and a resolve here
/// would turn a path a person can read in a log into one they cannot.
///
/// Free rather than a method, and public, because [`crate::codeaction`] validates verb 19's target
/// with exactly this rule. The Swift had it twice — `HostPathActionPerformer.resolve` and
/// `HostCodeServerPerformer.openResponse`'s inline `expandingTildeInPath.standardizingPath` — and
/// the two had already drifted on `~user`, which one expanded and the other did not.
#[must_use]
pub fn absolute_host_path(argument: &str, home: &str) -> Option<String> {
    let expanded = expand_tilde(argument, home)?;
    if !expanded.starts_with('/') {
        return None;
    }
    let mut normalised = PathBuf::new();
    for part in PathBuf::from(&expanded).components() {
        match part {
            Component::CurDir => {},
            Component::ParentDir => {
                // A `..` above the root is the root, which is what `standardizingPath` answers and
                // what every filesystem resolves it to.
                let _above_root = normalised.pop();
            },
            other => normalised.push(other),
        }
    }
    Some(normalised.to_string_lossy().into_owned())
}

/// `~` and `~/…` against `home`; everything else verbatim. `None` when the argument needs a home
/// and the caller has none.
///
/// The EMPTY-home arm is not a formality. `format!("{}/{rest}", "")` is `/rest` — absolute, and
/// therefore a path the rest of [`absolute_host_path`] would happily accept — so a daemon launched
/// without `HOME` would silently reinterpret `~/Documents` as the ROOT's `Documents`. Refusing is
/// the only closed answer.
///
/// `~user` is NOT expanded, and the difference from `NSString.expandingTildeInPath` is deliberate:
/// resolving another user's home means a `getpwnam`, and a host path naming a second user's home is
/// not something any verb in this repository can produce. `~user` is refused here rather than
/// resolved, which is the closed answer.
fn expand_tilde(argument: &str, home: &str) -> Option<String> {
    let Some(rest) = argument.strip_prefix('~') else {
        return Some(argument.to_owned());
    };
    if home.is_empty() {
        return None;
    }
    match rest {
        "" => Some(home.to_owned()),
        _ => rest.strip_prefix('/').map(|tail| format!("{home}/{tail}")),
    }
}

impl<D: OpensPaths> MetadataPerformer for PathActions<D> {
    fn perform(&self, request: &MetadataRequest<'_>) -> MetadataAnswer {
        let status = match MetadataVerb::from_byte(request.verb) {
            Some(verb @ (MetadataVerb::OpenPath | MetadataVerb::RevealPath)) => {
                // A non-UTF-8 argument is a malformed request → error. Validate-then-drop, never a
                // trap: this path parses bytes a peer chose.
                core::str::from_utf8(request.payload)
                    .map_or(MetadataStatus::Error, |argument| self.answer(verb, argument))
            },
            _ => MetadataStatus::UnsupportedVerb,
        };
        MetadataAnswer {
            status: status.as_byte(),
            payload: Vec::new(),
        }
    }
}

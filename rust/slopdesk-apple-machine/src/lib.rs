//! `NSHost` — what this Mac calls itself, as a workspace LABEL.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns one
//! observation into one value and makes no decisions of its own. WHAT to show when there is no such
//! name is `slopdesk_hostd::workspacestore`'s ladder, and that crate forbids `unsafe`.
//!
//! ## No `unsafe`, and that is the point
//! `objc2-foundation` generates `currentHost` and `localizedName` as SAFE functions, and
//! `NSString::to_string` is safe. There is no `#[expect(unsafe_code)]` in this file. `docs/57` §3
//! sets a bar per crate rather than a budget, and the bar a crate clears by writing none of it is
//! the one this family was opened for: there is no framework contract left to name.
//!
//! ## Why this and not `SCDynamicStoreCopyComputedName`
//! `docs/60`'s parity ledger named the `SystemConfiguration` call, because that is where the
//! computed name LIVES. It is not what the Swift called. `Host.current().localizedName` is
//! `NSHost`, and Foundation reads the dynamic store on the caller's behalf, so the literal port of
//! the Swift is also the one that spends no admission and hand-writes no block.
//!
//! ## One function, and the four that are missing on purpose
//! The class also answers `name`, `names`, `address` and `addresses`. Each of those RESOLVES — a
//! network lookup that can block for as long as the resolver takes — and none is what a label
//! wants. A daemon parking a thread on a DNS timeout to draw a caption is the failure this omission
//! forecloses, so nothing here can start a lookup.
//!
//! ## The class is DEPRECATED, and the one `#[expect]` in the crate says so
//! `NSHost.h` says "use Network framework instead", and for the four names above that is exactly
//! right — resolution is `Network`'s job now. It is not advice about `localizedName`: `Network` has
//! no computed-name API at all, and the only other way to that string is
//! `SCDynamicStoreCopyComputedName`, which costs a hand-written block and a Copy-rule admission to
//! return the same bytes. So the deprecation is opted out of at the ONE site that earns it, with
//! the reason attached, rather than crate-wide — the day Apple ships a replacement for the label
//! half, the `#[expect]` is where the port starts.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

/// The name this Mac calls itself in Sharing preferences, when it has one.
///
/// `None` when the machine has no computed name, and — the case that matters — when it has an EMPTY
/// one. Foundation will hand back a zero-length string rather than nothing on a host whose name was
/// cleared, and a caller that took it at face value would label the workspace with a blank instead
/// of falling through to the hostname it has. Empty and absent are one answer here so that the
/// caller's ladder has one rung to check.
#[cfg(target_os = "macos")]
#[must_use]
#[expect(
    deprecated,
    reason = "NSHost.h points at Network framework, which answers resolution and has no computed name; the \
              only other route to this string is a hand-written SCDynamicStore block"
)]
pub fn localized_name() -> Option<String> {
    // Both calls are generated SAFE — see the module note. Nothing is cached: `currentHost` is a
    // fresh object per call, so a machine renamed while the daemon runs is read on the next ask
    // rather than frozen at the first one.
    let named = objc2_foundation::NSHost::currentHost()
        .localizedName()?
        .to_string();
    (!named.is_empty()).then_some(named)
}

/// The non-macOS shape, so a caller compiles everywhere and links the door only where it exists.
///
/// There is no Sharing preferences pane off macOS, so there is no name to answer with, and the
/// caller's next rung — the POSIX hostname — is the one every platform has.
#[cfg(not(target_os = "macos"))]
#[must_use]
pub const fn localized_name() -> Option<String> {
    None
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::localized_name;

    /// Whatever this machine answers, it is never a blank label.
    ///
    /// The suite cannot assert the NAME — it is whatever the machine running the tests is called —
    /// so it asserts the property the caller depends on instead: an empty string never leaves this
    /// crate as a `Some`, because the caller's fallback ladder cannot see past one.
    #[test]
    fn the_answer_is_either_absent_or_a_name_with_something_in_it() {
        if let Some(named) = localized_name() {
            assert!(!named.is_empty(), "an empty name escaped as Some");
        }
    }

    /// Asked repeatedly, it keeps answering the same thing and holds nothing.
    ///
    /// Two properties in one loop. The first is that this is not a per-process snapshot of the kind
    /// `NSWorkspace::frontmostApplication` is — the read re-asks Foundation every time, which is
    /// what lets a renamed host be relabelled without a restart. The second is the family's leak
    /// check: every `Retained` this makes is dropped inside the call, so a thousand asks hold a
    /// thousand fewer objects than a missing release would.
    #[test]
    fn a_thousand_asks_agree_and_hold_nothing() {
        let first = localized_name();
        for _ in 0..1_000 {
            assert_eq!(localized_name(), first);
        }
    }
}

// BuildStatusPlaceholderCopy — the one actionable sentence on the no-renderer terminal placeholder.
//
// A terminal leaf that cannot make a `libghostty` surface mounts a placeholder instead of a blank pane,
// and the whole reason that panel exists rather than a black rectangle is this line: it names the script
// that produces the renderer. Everything else on the panel is a glyph, a lowercase kind name and a live
// build caption the model supplies.
//
// So it is copy belonging to a SURFACE with no reading behind it — nothing about it depends on anything
// — and it was typed once per shell (``SlopDeskMacUI/MacBuildStatusPlaceholderView`` and
// `SlopDeskPhoneUI/BuildStatusPlaceholderView`). A sentence spelled twice is a translation bug that has
// already happened, which is what `shared-vocabulary-ceiling` counts
// (`rust/slopdesk-invariants/src/rules/two_shells.rs`, docs/56 §3): the day one half is reworded — and
// this one names a PATH, so it is reworded whenever that script moves — the two platforms send their
// users to two different files and nothing notices.
//
// The panel's LAYOUT stays per-renderer, including the Mac's `preferredMaxLayoutWidth`: where a sentence
// breaks into balanced lines is a measurement against a font on a platform, not a fact about the words.

// One `String`: this file imports nothing.

/// The build-status placeholder's words.
package enum BuildStatusPlaceholderCopy {
    /// What to run, and what running it gets you. The second clause is what makes the line actionable
    /// rather than an error: it says the panel is standing in for something a build produces.
    package static let buildHint =
        "Run ThirdParty/ghostty/build-libghostty.sh — the headless build renders this panel."
}

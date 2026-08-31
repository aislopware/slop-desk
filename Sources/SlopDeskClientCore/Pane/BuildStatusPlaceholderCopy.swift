// BuildStatusPlaceholderCopy — the one actionable sentence on the no-renderer terminal placeholder.
//
// A terminal leaf whose seam has no renderer registered mounts a placeholder instead of a blank pane,
// and the whole reason that panel exists rather than a black rectangle is this line: it names the call
// that registers one. Everything else on the panel is a glyph, a lowercase kind name and a live
// build caption the model supplies.
//
// ⚠️ This is NOT the panel a machine with no Metal device gets — that one is
// `TerminalRendererUnavailableHost`, and it says something else, because "this build has no renderer"
// and "this GPU refused" are two different facts with two different answers. The only way to see THIS
// panel is a build whose root never called `installTerminalRenderer()`, which is every headless test
// and no shipped app. It used to name the deleted fork's build script, back when the renderer was an
// xcframework an operator built by hand and wired in with `slopdesk-ops enable-renderer`;
// `swift build` compiles the renderer now, so there is no script left to run (docs/68).
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
    /// What is missing, and what supplies it. The second clause is what makes the line actionable
    /// rather than an error: it says the panel is standing in for something a caller must install.
    package static let buildHint =
        "No terminal renderer is registered — the app root calls installTerminalRenderer()."
}

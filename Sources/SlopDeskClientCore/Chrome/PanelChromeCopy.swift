// PanelChromeCopy — the right panel's own words, the ones no Rust reading carries.
//
// The four TABS get their label, their help and their accessibility hint from
// `slopdesk_workspace::panel_tabs` (``PanelTabReading``), and every empty state gets its two lines from
// `slopdesk_codepanel::surface` (``PanelEmptyState``). Two sentences were left over after both of those
// lifts, for the same reason each time: they belong to a CONTROL rather than to a reading — the trailing
// reload plate's help, and the label on the veil the workbench boots behind — so neither had a record to
// travel in and both stayed where they were drawn.
//
// Which meant each was typed once per shell. That is a translation bug that has already happened: the
// day one half is reworded the two platforms ship different copy for the same control and nothing
// notices, which is precisely what `shared-vocabulary-ceiling` counts
// (`rust/slopdesk-invariants/src/rules/two_shells.rs`, docs/56 §3). A phrase spelled in BOTH shells goes
// to `SlopDeskClientCore` and both shells read it from here.
//
// ⚠️ NOT A DUMPING GROUND FOR STRINGS. What is admitted here is copy with a twin in the other shell and
// no reading to ride in on. A sentence only one platform says stays in that platform's view — the two
// shells are asymmetric on purpose (the Mac spells menu-bar items with no phone surface at all) — and a
// sentence that IS part of a reading belongs in that reading's far side, in Rust, not in a constant
// beside it.

// ``PanelSurface`` is this target's own (`App/WorkspaceChromeState.swift`), and a `String` is the
// standard library's, so this file imports nothing.

package enum PanelChromeCopy {
    /// What the strip's trailing reload plate promises, per surface — `nil` where there is no plate.
    ///
    /// Desktop is announced-but-empty and has nothing to reload; the workbench answers even when the
    /// plate is hidden behind the open gate, because whether the plate SHOWS is the strip's question
    /// (it reads the mount) and what it would SAY is this one.
    package static func reloadHelp(for surface: PanelSurface) -> String? {
        switch surface {
        case .code: "Reload the workbench"
        case .simulators: "Reload the simulator list"
        case .android: "Reload the device list"
        case .desktop: nil
        }
    }

    /// The label on the veil the workbench boots behind, from load-start until the main-frame
    /// navigation settles. Without the veil the boot reads as black → WebKit's white canvas → workbench.
    package static let workbenchVeilLabel = "Opening workbench…"
}

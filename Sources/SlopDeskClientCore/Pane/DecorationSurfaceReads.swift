// DecorationSurfaceReads — what a decoration coincident with the terminal surface ASKS, once.
//
// Three overlays sit exactly on top of the cell grid and none of them draws content: the ⌘-hold link
// underline, the copy-mode block cursor and (next door, in `DecorationPromptFlash.swift`) the
// prompt-jump flash. Each is written twice — an `NSView` in `SlopDeskMacUI` and a `UIView` in
// `SlopDeskPhoneUI` — and the halves differ in exactly one thing: how the answer is PAINTED. A
// `CAShapeLayer` against an `NSBezierPath`, a `frame` against a `draw(_:)`.
//
// What is NOT different is the QUESTION. Both halves ask the same model for the same viewport
// snapshot, cast it to the same seam, hand it to the same pure geometry and compare against the same
// stored answer — and `no-cross-target-clone` counted that question as two seven-to-twelve-line
// windows per overlay (docs/56 §3, docs/62 stage I). Nothing in it is a framework spelling:
// `TerminalViewModel`, `SettingsKey`, `LinkUnderlineGeometry` and `ViCursorGeometry` are all one
// implementation already, and the duplicated lines were only the ORDER they are asked in.
//
// ⚠️ THE TRACKED READ IS PART OF THE QUESTION, WHICH IS WHY `track(_:)` IS HERE AND NOT AT THE CALL
// SITE. `Observation` registers a dependency on every property read while the tracking block runs,
// and it does not care whether the read happened inside the closure's own braces or inside a
// function the closure called. So a shared `track` is a shared DEPENDENCY SET — the half that grew a
// fourth signal cannot grow it in one shell only, which is the exact drift that made
// `LinkHighlightOverlayView`'s conditional bargain worth a paragraph in both headers.
//
// The one signal that stays at a call site is the phone's `ConfigRevision.shared.generation`: the
// Mac shell does not read it, and lifting it would quietly WIDEN the Mac's dependency set rather
// than de-duplicate anything. A read that only one half performs is not a clone.

import CoreGraphics
import SlopDeskTerminal
import SlopDeskWorkspaceCore

/// The ⌘-hold link underline's read.
@MainActor
package enum DecorationLinkUnderline {
    /// The tracked read, run INSIDE `ObservationFollow`'s tracking block.
    ///
    /// ⚠️ THE DEPENDENCY IS CONDITIONAL AND THAT IS THE POINT. The three arm signals are read on
    /// every arm, so the underlines reveal / clear the instant ⌘ is pressed or released. The two
    /// viewport-change signals are read ONLY inside the armed branch, so an idle pane does not
    /// re-detect once per ingest chunk while nobody is holding ⌘.
    ///
    /// BOTH viewport signals, not just the loud one: `bytesReceived` covers new streaming output and
    /// `viewportRevision` covers a LOCAL scrollback scroll, which moves the viewport without a single
    /// new wire byte. Observing only the first leaves the underlines stranded at their pre-scroll
    /// screen rows, over unrelated text.
    ///
    /// `alternateScreenActive` is the OBSERVABLE twin — not `isAlternateScreen`, which reads through
    /// an `@ObservationIgnored` tracker and would register no dependency at all. This is the one
    /// place the distinction bites: without the twin, a flip to a full-screen TUI under a held ⌘ only
    /// clears the underlines if MORE output happens to arrive.
    package static func track(_ model: TerminalViewModel) {
        if LinkUnderlineGeometry.isArmed(
            highlightActive: model.linkHighlightActive,
            detectionEnabled: SettingsKey.linkDetectionEnabled,
            isAlternateScreen: model.alternateScreenActive,
        ) {
            _ = model.bytesReceived
            _ = model.viewportRevision
        }
    }

    /// Every underline the live viewport wants, in the surface's top-left-origin space.
    ///
    /// Empty — an ABSENT underline, never a wrong one — when the gate is shut, or when the surface is
    /// a headless / placeholder one that conforms to no viewport seam and therefore has no metrics.
    ///
    /// `isAlternateScreen` here rather than the observable twin, because this is the WORK and not the
    /// dependency: it runs outside the tracking block, where the tracker-backed read is the accurate
    /// one and registering anything would be a mistake.
    package static func strokes(for model: TerminalViewModel, cwd: String?) -> [TerminalStroke] {
        guard LinkUnderlineGeometry.isArmed(
            highlightActive: model.linkHighlightActive,
            detectionEnabled: SettingsKey.linkDetectionEnabled,
            isAlternateScreen: model.isAlternateScreen,
        ),
            let snapshot = model.surface as? TerminalViewportSnapshotting,
            let metrics = snapshot.cellMetrics()
        else { return [] }
        return LinkUnderlineGeometry.strokes(
            links: TerminalLinkDetector.detect(
                rows: snapshot.viewportTextRows(),
                cwd: cwd,
                schemes: SettingsKey.linkSchemePolicy,
            ),
            metrics: metrics,
        )
    }
}

/// The copy-mode block cursor's read.
@MainActor
package enum DecorationViCursor {
    /// The tracked read: the copy-mode gate and the cell, and nothing else.
    ///
    /// The geometry read stays OUT of it deliberately — `cellMetrics()` is a libghostty readback
    /// rather than observable state, so tracking it would register nothing and cost a call per arm.
    package static func track(_ model: TerminalViewModel) -> (active: Bool, cell: TerminalViewModel.ViCursorCell?) {
        (active: model.copyModeBadgeActive, cell: model.viCursorCell)
    }

    /// The one cell the block wears, or `nil` when there is nothing honest to draw.
    package static func rect(for model: TerminalViewModel) -> CGRect? {
        ViCursorGeometry.rect(
            copyModeActive: model.copyModeBadgeActive,
            cell: model.viCursorCell,
            metrics: (model.surface as? TerminalViewportSnapshotting)?.cellMetrics(),
        )
    }
}

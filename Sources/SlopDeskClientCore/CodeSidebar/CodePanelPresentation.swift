// CodePanelPresentation — the near-side FACE of `slopdesk_codepanel::surface`.
//
// docs/56 stage D, increment 51, and the same lift increments 47 and 49 did for the checklist and the
// bespoke settings pages. The four surfaces had ONE renderer until the Mac drew them itself, so every
// word in them and every phase→surface answer had a single speller BY ACCIDENT. There are two
// renderers now, so the words and the folds moved down and are single-spelled ON PURPOSE — and once
// they were values rather than a `switch` in a body, they moved the rest of the way across.
//
// ## The three surfaces answer ONE layout
//
// The workbench and the two device surfaces are the same four-state question asked about three
// subjects, so they cross as the same `[u8 kind][u8 detail_is_command]` + three runs. A caller reads
// exactly as many runs as `kind` says it has, and the ones that do not apply are EMPTY rather than
// absent, which keeps the reader a straight line.
//
// ## What is NOT here
//
// **No ink, no metric, no font — and NOT because a token is out of reach.** ⚠️ This header used to
// say `SlopDeskSlate` "DEPENDS on this target, so a token read from here would be a cycle rather than
// a widening". The edge runs the other way: `Package.swift:475` lists `SlopDeskSlate` among
// `SlopDeskClientCore`'s dependencies, and `Package.swift:537-549` shows Slate's own dependencies as
// `SlopDeskWorkspaceModel`/`SlopDeskAgentDetect`/`SlopDeskFontFaces`/`SFSafeSymbols` with no edge
// back. `Pane/GuiLeafChromeLayout.swift` reads `Slate.Metric` from this target today. The real reason
// is about this FILE rather than about the package graph: a presentation answers WHAT a surface is,
// and an ink is a rendering of that answer — a surface names its own SILHOUETTE (an SF-Symbol name
// both halves ask for) and each renderer spells the dim. Keeping the rendering out is a choice this
// file makes, not a wall the build puts up, which matters because a wall needs no defending and a
// choice does.
//
// **No `.task`, no poll, no generation.** Those are the model's, and how a renderer keeps a loop alive
// across a mount is exactly the thing the two frameworks disagree about: SwiftUI cancels a `.task` on
// unmount, and AppKit's controller has to hold and cancel the `Task` itself. The two ANIMATION KEYS
// that decide which loop restarts when are shared, because getting that wrong is a stalled panel on
// one platform only — and they stay two doors, because the difference between them IS the rule.

import CSlopDeskFFI
import Foundation
import SlopDeskDevicePanels
import SlopDeskWorkspaceModel

// MARK: - The one empty-state shape the panel speaks in

/// A centred empty state: a dim glyph, one line naming the situation, one line about it.
///
/// One record for all seven of them (three "not installed", three "host unreachable", one announced
/// Desktop) because the panel has ONE empty-state voice and a renderer that took a title and a detail
/// as loose arguments is a renderer that can be given them in the other order.
package struct PanelEmptyState: Equatable, Sendable {
    /// The muted glyph, as an SF-Symbol name — each half maps the name onto its own image type.
    package let systemImage: String
    /// One line: what the situation IS.
    package let title: String
    /// One line under it: what to do, or where the thing went.
    package let detail: String
    /// Set the detail in the instrument face — it is a shell command to copy, not a sentence.
    package let detailIsCommand: Bool

    package init(systemImage: String, title: String, detail: String, detailIsCommand: Bool = false) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.detailIsCommand = detailIsCommand
    }
}

// MARK: - What the workbench surface is showing

/// The workbench surface's four situations, with the payload each one needs.
///
/// A renderer switches over this and nothing else — in particular it does NOT re-ask whether the root
/// is admitted, because the gate and the mount are the same decision seen twice and answering it in
/// two places is how a project boots an editor it was gated out of.
package enum CodePanelWorkbenchState: Equatable {
    /// The project has never been opened — offer the gate, mount nothing (``CodeOpenGateReading``).
    case gate(projectRoot: String)
    /// Mount the pooled workbench for this root at this URL.
    case workbench(projectRoot: String, url: URL)
    /// A spinner and a label. Both of these resolve on their own.
    case waiting(String)
    case empty(PanelEmptyState)
}

/// What a DEVICE surface is showing. `devices` is the only state with no words: the list and the stage
/// are the surface's own two depths, and which of the two is the model's `selection`, not a phase.
package enum DevicePanelSurfaceState: Equatable {
    case devices
    case waiting(String)
    case empty(PanelEmptyState)
}

/// The open gate's words — what a project shows before its first-ever workbench boot.
///
/// The DETAIL is the full root and the TITLE is its last component, which is the one place in the
/// panel where the longer string is the more useful one: the gate is precisely the moment of deciding
/// whether this is the project worth booting an editor for, and two same-named checkouts are told
/// apart only by the path above them.
package enum CodeOpenGateReading {
    package static var systemImage: String { CodePanelPresentation.words[1] }
    package static var openTitle: String { CodePanelPresentation.words[2] }

    /// The heading — the folder's own name, or the whole path when it has none to take.
    package static func title(projectRoot: String) -> String {
        let bytes = Array(projectRoot.utf8)
        let blob = bytes.withUnsafeBufferPointer { root in
            wsAnswerBytes { out, cap in
                Int(slopdesk_code_gate_title(root.baseAddress, root.count, out, cap))
            }
        }
        return wsRuns(blob, count: 1)[0]
    }
}

// MARK: - The folds

package enum CodePanelPresentation {
    /// The provisioning line, spelled ONCE for the three surfaces that can be missing a tool.
    ///
    /// The provision script, not `brew install`: the panel is written against the `code-server` version
    /// pinned in `ThirdParty/tools/tools.lock`, and the Homebrew formula froze at 4.112 — below the
    /// Code 1.121 floor this panel needs — before being deprecated outright. Sending someone to `brew`
    /// here hands them the broken one.
    package static var provisionCommand: String { words[0] }

    /// The panel's seven constants, in ONE crossing, once per process: the provision command, the
    /// gate's image and title, the two device toast ids, the two device fallback subjects.
    static let words: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_code_panel_words(out, cap)) },
        count: 7,
    )

    /// The announced-but-empty fourth surface. The TAB is real — selecting it parks the workbench and
    /// cancels the ensure poll — and only the content is a placeholder.
    ///
    /// It rides the SHARED layout even though it has no phase, so this side has one reader for all
    /// four surfaces rather than three and a special case.
    package static let desktop: PanelEmptyState = Surface(
        wsAnswerBytes { out, cap in Int(slopdesk_code_desktop_surface(out, cap)) },
    ).emptyState

    // MARK: The workbench

    /// What the workbench surface shows, from the poll phase and what the focus resolves to.
    ///
    /// The ORDER of the questions is the whole rule and it is not interchangeable — the gate first,
    /// because a project the user never opened must cost nothing at all (no ensure poll, no proxy
    /// bind, no webview; user-directed 2026-08-07), then the root, then the brief wait while the
    /// host's `projectKey` push is in flight, and only then the no-project placeholder. It is asked in
    /// exactly one place for that reason, and the four gates cross as the four arguments in that
    /// order.
    ///
    /// - Parameters:
    ///   - awaitingProjectKey: the focused pane has a SECTION identity (the cwd fallback) but no
    ///     host-pushed key yet. It is passed rather than derived because the two identities are the
    ///     store's, and only one of them may be ensured against.
    package static func workbench(
        phase: CodeSidebarPhase,
        activeProjectRoot: String?,
        openedProjects: Set<String>,
        awaitingProjectKey: Bool,
    ) -> CodePanelWorkbenchState {
        var readyIsThisRoot = false
        var mountURL: URL?
        if case let .ready(readyRoot, url) = phase, readyRoot == activeProjectRoot {
            readyIsThisRoot = true
            mountURL = url
        }
        let blob = wsAnswerBytes { out, cap in
            Int(slopdesk_code_workbench(
                phase.byte,
                activeProjectRoot != nil,
                activeProjectRoot.map(openedProjects.contains) ?? false,
                readyIsThisRoot,
                awaitingProjectKey,
                out, cap,
            ))
        }
        let surface = Surface(blob)
        switch surface.kind {
        case 0: return .gate(projectRoot: activeProjectRoot ?? "")
        case 1:
            // The mount answer and the URL are the same `.ready` read twice; a mount without one is
            // not reachable, and waiting is what a boot looks like from here anyway.
            guard let root = activeProjectRoot, let url = mountURL else {
                return .waiting(surface.label)
            }
            return .workbench(projectRoot: root, url: url)
        case 2: return .waiting(surface.label)
        default: return .empty(surface.emptyState)
        }
    }

    // MARK: The two device surfaces

    /// What the Simulators surface shows. Machine-scoped, so unlike the workbench it has no project to
    /// key on and no waiting-for-`projectKey` state: one ensure loop, one device list, one live stream.
    package static func simulators(_ phase: DevicePanelPhase) -> DevicePanelSurfaceState {
        deviceSurface(phase, android: false)
    }

    /// What the Android surface shows.
    ///
    /// `adb` is the one piece without which there is nothing to list. A missing `scrcpy-server` still
    /// lists and boots devices and reports itself when a mirror is asked for, which is where it can
    /// name itself against the action that wanted it — and it is committed to the repo now, so it is
    /// present in any checkout. The emulator is deliberately not provisioned (system images are
    /// gigabytes behind a licence accept), so a host that wants AVDs still needs its own SDK.
    package static func android(_ phase: DevicePanelPhase) -> DevicePanelSurfaceState {
        deviceSurface(phase, android: true)
    }

    /// One door for both, because the two differ in three strings and in nothing else — a second door
    /// would be a second place for the shared fold to drift.
    private static func deviceSurface(_ phase: DevicePanelPhase, android: Bool) -> DevicePanelSurfaceState {
        let blob = wsAnswerBytes { out, cap in
            Int(slopdesk_code_device_surface(phase.byte, android, out, cap))
        }
        let surface = Surface(blob)
        switch surface.kind {
        case 1: return .devices
        case 2: return .waiting(surface.label)
        default: return .empty(surface.emptyState)
        }
    }

    /// The shared delivery, cut back into its pieces.
    private struct Surface {
        let kind: UInt8
        /// The waiting label, or the empty state's title — the first run either way.
        let label: String
        private let systemImage: String
        private let detail: String
        private let detailIsCommand: Bool

        init(_ blob: [UInt8]) {
            let text = wsRuns(Array(blob.dropFirst(2)), count: 3)
            // A delivery too short to carry a kind is the empty state, which is the surface that
            // says what went wrong rather than the one that mounts an editor.
            kind = blob.first ?? 3
            detailIsCommand = blob.count > 1 && blob[1] == 1
            label = text[0]
            systemImage = text[1]
            detail = text[2]
        }

        var emptyState: PanelEmptyState {
            PanelEmptyState(
                systemImage: systemImage, title: label, detail: detail, detailIsCommand: detailIsCommand,
            )
        }
    }

    // MARK: The two identities a device surface animates and polls on

    /// WHICH of the four states is on screen, with the `.ready` payload deliberately dropped.
    ///
    /// A `.ready` service that respawns on a new port is the same surface and must not blink; server
    /// boot → devices is a real change of subject and cuts hard without an animation keyed on this.
    package static func phaseKey(_ phase: DevicePanelPhase) -> String {
        let blob = wsAnswerBytes { out, cap in Int(slopdesk_code_phase_key(phase.byte, out, cap)) }
        return wsRuns(blob, count: 1)[0]
    }

    /// The service's ADDRESS, or empty when there is not one.
    ///
    /// The device poll restarts on this rather than on the phase object, so a respawn on a new port
    /// re-dials and an identical re-render does not. It is a SECOND loop on purpose: folding it into
    /// the ensure loop would tie the list's refresh rate to the server-boot retry rate, and those two
    /// want opposite cadences.
    package static func readyKey(_ phase: DevicePanelPhase) -> String {
        var host = ""
        var port: UInt16 = 0
        if case let .ready(readyHost, readyPort) = phase {
            host = readyHost
            port = UInt16(truncatingIfNeeded: readyPort)
        }
        let bytes = Array(host.utf8)
        let blob = bytes.withUnsafeBufferPointer { borrowed in
            wsAnswerBytes { out, cap in
                Int(slopdesk_code_ready_key(phase.byte, borrowed.baseAddress, borrowed.count, port, out, cap))
            }
        }
        // The empty key is REAL here — it is what a non-ready phase answers — so §4's `0` maps to it
        // rather than to a missing answer.
        return blob.isEmpty ? "" : wsRuns(blob, count: 1)[0]
    }

    // MARK: What a device surface REPORTS, and where

    /// The Simulators surface's toast id. Its own, not shared with Android: the two surfaces can both
    /// have something to say about different devices, and one id would have one panel's report replace
    /// the other's.
    package static var simulatorToastID: String { words[3] }
    package static var androidToastID: String { words[4] }

    /// What the report is ABOUT when the selection has already been cleared — a verdict of "no longer
    /// running" sets the text and clears the selection in one write, and the card still has to say
    /// where it came from.
    package static var simulatorFallbackSubject: String { words[5] }
    package static var androidFallbackSubject: String { words[6] }

    // MARK: The one number the mount needs

    /// The web workbench title bar's laid-out height at zoom 1 (30px on Code 1.131).
    ///
    /// The workbench force-shows its title bar while the activity bar sits at "top" (seed v12 — the
    /// band must host the relocated accounts/manage actions), and the grid positions every part with
    /// inline absolute geometry, so a CSS `display: none` leaves a dead gap instead of reflowing. The
    /// clip is the clean cut: the webview is laid out TALLER than its container by exactly this much
    /// and shifted up, so the band renders above the clip line (user-directed 2026-08-03).
    ///
    /// It is NOT a CSS constant to grep: the workbench grid positions its parts with inline geometry,
    /// so the honest measurement is the laid-out box —
    /// `document.querySelector('#workbench\\.parts\\.titlebar').getBoundingClientRect().height`
    /// against a real workbench. It went 35 → 30 across Code 1.112 → 1.131; re-measure on every
    /// code-server bump, because being wrong here clips the editor tab row instead.
    package static let clippedTitleBarHeight = slopdesk_code_clipped_title_bar_height()
}

// MARK: - The phase byte both halves speak

private extension CodeSidebarPhase {
    /// `0` offline · `1` starting · `2` unavailable · `3` ready — the far side's own discriminant.
    var byte: UInt8 {
        switch self {
        case .offline: 0
        case .starting: 1
        case .unavailable: 2
        case .ready: 3
        }
    }
}

private extension DevicePanelPhase {
    /// The same four, in the same order: the two phases are one vocabulary asked about two subjects.
    var byte: UInt8 {
        switch self {
        case .offline: 0
        case .starting: 1
        case .unavailable: 2
        case .ready: 3
        }
    }
}

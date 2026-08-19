// CodePanelPresentation — what the RIGHT panel's four surfaces SAY, and which of them a phase picks.
//
// docs/56 stage D, increment 51, and the same lift increments 47 and 49 did for the checklist and the
// bespoke settings pages. The four surfaces had ONE renderer until the Mac drew them itself, so every
// word in them and every phase→surface answer had a single speller BY ACCIDENT. There are two
// renderers now, so the words and the folds moved down here and are single-spelled ON PURPOSE.
//
// ## Why this file, and not two
//
// The workbench's phase is `SlopDeskClientCore`'s (``CodeSidebarPhase``, beside the poll loop that
// drives it) and the two device surfaces' is `SlopDeskDevicePanels`' (``DevicePanelPhase``, beside
// theirs). One vocabulary spread over two targets would put the panel's empty-state RECORD in a third,
// and then the three would have to agree about a glyph name. So this target took the dependency — the
// direction was already legal (`SlopDeskDevicePanels` names no presentation type) and it buys the
// panel one home rather than three files that must not drift.
//
// It sits beside ``PanelTabReading`` for the same reason that file exists: the four surfaces are drawn
// twice, and what they say is not a fact about either drawing.
//
// ## What is NOT here
//
// **No ink, no metric, no font.** `SlopDeskSlate` DEPENDS on this target, so a token read from here
// would be a cycle rather than a widening — the residue increment 47 recorded and increment 49
// re-recorded. A surface names its own SILHOUETTE (an SF-Symbol name both halves ask for) and each
// renderer spells the dim.
//
// **No `.task`, no poll, no generation.** Those are the model's, and how a renderer keeps a loop alive
// across a mount is exactly the thing the two frameworks disagree about: SwiftUI cancels a `.task` on
// unmount, and AppKit's controller has to hold and cancel the `Task` itself. The DECISION — which key
// restarts which loop — is here, because getting that wrong is a stalled panel on one platform only.

import Foundation
import SlopDeskDevicePanels

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
    package static let systemImage = "folder"
    package static let openTitle = "Open Editor"

    /// The heading — the folder's own name.
    package static func title(projectRoot: String) -> String {
        URL(fileURLWithPath: projectRoot).lastPathComponent
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
    package static let provisionCommand = "bash ThirdParty/tools/provision.sh"

    /// The announced-but-empty fourth surface. The TAB is real — selecting it parks the workbench and
    /// cancels the ensure poll — and only the content is a placeholder.
    package static let desktop = PanelEmptyState(
        systemImage: "display",
        title: "Desktop",
        detail: "The host's window surface arrives here.",
    )

    // MARK: The workbench

    /// What the workbench surface shows, from the poll phase and what the focus resolves to.
    ///
    /// The ORDER of the three questions is the whole rule and it is not interchangeable. The gate comes
    /// first, because a project the user never opened must cost nothing at all — no ensure poll, no
    /// proxy bind, no webview (user-directed 2026-08-07). Then the root, then the brief wait while the
    /// host's `projectKey` push is in flight, and only then the no-project placeholder: rendering that
    /// placeholder during the push is a panel that says "no project" about a pane that has one.
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
        guard let root = activeProjectRoot else {
            return awaitingProjectKey
                ? .waiting("Resolving project…")
                : .empty(PanelEmptyState(
                    systemImage: "folder",
                    title: "No project in focus",
                    detail: "Focus a terminal pane to open its project here.",
                ))
        }
        guard openedProjects.contains(root) else { return .gate(projectRoot: root) }
        switch phase {
        case let .ready(readyRoot, url) where readyRoot == root:
            return .workbench(projectRoot: root, url: url)
        // ⚠️ A `.ready` carrying the PREVIOUS project is the render between a switch and its restarted
        // poll. Mounting from it opened the old project's folder for the new root and stuck there
        // (user-reported 2026-08-03; the pool re-loads on a host/port move only, never on the folder).
        // It waits, exactly like a boot, because that is what it is.
        case .ready,
             .starting:
            return .waiting("Starting code-server…")
        case .unavailable:
            return .empty(PanelEmptyState(
                systemImage: "shippingbox",
                title: "code-server not found on host",
                detail: provisionCommand,
                detailIsCommand: true,
            ))
        case .offline:
            return .empty(PanelEmptyState(
                systemImage: "bolt.slash",
                title: "Host unreachable",
                detail: "The editor opens once a pane is connected.",
            ))
        }
    }

    // MARK: The two device surfaces

    /// What the Simulators surface shows. Machine-scoped, so unlike the workbench it has no project to
    /// key on and no waiting-for-`projectKey` state: one ensure loop, one device list, one live stream.
    package static func simulators(_ phase: DevicePanelPhase) -> DevicePanelSurfaceState {
        devices(
            phase,
            starting: "Starting simulator server…",
            missingTool: PanelEmptyState(
                systemImage: "iphone.slash",
                title: "baguette not found on host",
                detail: provisionCommand,
                detailIsCommand: true,
            ),
            offlineDetail: "Simulators appear once a pane is connected.",
        )
    }

    /// What the Android surface shows.
    ///
    /// `adb` is the one piece without which there is nothing to list. A missing `scrcpy-server` still
    /// lists and boots devices and reports itself when a mirror is asked for, which is where it can
    /// name itself against the action that wanted it — and it is committed to the repo now, so it is
    /// present in any checkout. The emulator is deliberately not provisioned (system images are
    /// gigabytes behind a licence accept), so a host that wants AVDs still needs its own SDK.
    package static func android(_ phase: DevicePanelPhase) -> DevicePanelSurfaceState {
        devices(
            phase,
            starting: "Opening the Android bridge…",
            missingTool: PanelEmptyState(
                systemImage: "cable.connector.slash",
                title: "adb not found on host",
                detail: provisionCommand,
                detailIsCommand: true,
            ),
            offlineDetail: "Devices appear once a pane is connected.",
        )
    }

    /// The shape both device surfaces share. They differ in three strings and in nothing else, which is
    /// why the fold is written once and the strings are the arguments.
    private static func devices(
        _ phase: DevicePanelPhase,
        starting: String,
        missingTool: PanelEmptyState,
        offlineDetail: String,
    ) -> DevicePanelSurfaceState {
        switch phase {
        case .ready: .devices
        case .starting: .waiting(starting)
        case .unavailable: .empty(missingTool)
        case .offline: .empty(PanelEmptyState(
                systemImage: "bolt.slash",
                title: "Host unreachable",
                detail: offlineDetail,
            ))
        }
    }

    // MARK: The two identities a device surface animates and polls on

    /// WHICH of the four states is on screen, with the `.ready` payload deliberately dropped.
    ///
    /// A `.ready` service that respawns on a new port is the same surface and must not blink; server
    /// boot → devices is a real change of subject and cuts hard without an animation keyed on this.
    package static func phaseKey(_ phase: DevicePanelPhase) -> String {
        switch phase {
        case .ready: "ready"
        case .starting: "starting"
        case .unavailable: "unavailable"
        case .offline: "offline"
        }
    }

    /// The service's ADDRESS, or empty when there is not one.
    ///
    /// The device poll restarts on this rather than on the phase object, so a respawn on a new port
    /// re-dials and an identical re-render does not. It is a SECOND loop on purpose: folding it into
    /// the ensure loop would tie the list's refresh rate to the server-boot retry rate, and those two
    /// want opposite cadences.
    package static func readyKey(_ phase: DevicePanelPhase) -> String {
        guard case let .ready(host, port) = phase else { return "" }
        return "\(host):\(port)"
    }

    // MARK: What a device surface REPORTS, and where

    /// The Simulators surface's toast id. Its own, not shared with Android: the two surfaces can both
    /// have something to say about different devices, and one id would have one panel's report replace
    /// the other's.
    package static let simulatorToastID = "simulator"
    package static let androidToastID = "android"

    /// What the report is ABOUT when the selection has already been cleared — a verdict of "no longer
    /// running" sets the text and clears the selection in one write, and the card still has to say
    /// where it came from.
    package static let simulatorFallbackSubject = "Simulators"
    package static let androidFallbackSubject = "Android"

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
    /// code-server bump, because being wrong here clips the editor tab row instead. Here rather than at
    /// either mount because both halves clip the same overhang, and a number measured once that two
    /// files carry is a number that gets bumped in one of them.
    package static let clippedTitleBarHeight = 30.0
}

// GuiPaneReadout — everything the video pane SAYS, and the gates that decide whether it says it.
//
// `GuiLeafView` carried ~60 lines that named no view type at all: five telemetry rows and their three
// number formatters, the stall caption's ticking age, the placeholder's two words, the fps/bitrate
// choice tables with their `0 → "Auto"` rule and the bps↔Mbps conversion around them, fourteen
// control-bar tooltips, and five predicates. None of it had a single test, because none of it could be
// reached without instantiating a SwiftUI view over a Metal-hosting seam — which is exactly the
// hang-unsafe thing CLAUDE.md rule #6 forbids a test from doing. That is the whole argument: a
// formatter inside a view is a formatter nothing can check.
//
// TWO RULES ABOUT WHAT CROSSES:
//
// A COLOUR DOES NOT. `tint(_:)` returned a `Color`, and this layer sits below the token floor and draws
// nothing — so what crosses is the semantic (``GuiUploadTint``) and each framework looks up its own
// token. Only the BRANCH descends, which is the part that could ever be wrong.
//
// A SYMBOL DOES, AS A NAME. An SF Symbol name is data — the same shape `SlateEmptyState.symbol(for:)`
// already ships — so the phase→mark mapping lives here and the view spells `Image(systemName:)`.
//
// EVERY READING IS ABSENT, NEVER WRONG: a stat with no sample yet prints `—` rather than `0`, and a
// stall with no epoch prints `RECONNECTING` with no age rather than `· 0S`. A zero that means "no
// reading" is the one lie an instrument readout must not tell.

import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - Marks

/// Which tone an upload row's glyph wears. A semantic, not a colour — see the file header.
package enum GuiUploadTint: Equatable, Sendable {
    /// The resting icon tone: in flight, nothing to report yet.
    case icon
    /// The accent: settled, either way. Completion and failure share it because the GLYPH already says
    /// which — a second colour axis would be the same fact twice.
    case accent
}

// MARK: - The telemetry a readout reads

/// One sample of everything the five stat rows print — the host's announced cadence, the client's
/// own ~1 Hz and ~2 Hz measurements, and the latest hold.
///
/// Bundled as ONE value rather than passed as ten arguments because they are one sample: the rows
/// group them by WHAT IS MEASURED, not by which callback delivered them, and a caller that can hand
/// over half a sample would be a caller that can mix two.
///
/// EVERY FIELD IS OPTIONAL AND MEANS IT. `nil` is "no reading yet", which prints as `—`; a `0` here
/// is a measured zero, which is a completely different sentence.
package struct GuiStreamTelemetry: Equatable, Sendable {
    /// Host-announced stream cadence (fps) and the client-measured payload bitrate (kbps).
    package var streamFps: Int?
    package var streamKbps: Int?
    /// The ~2 Hz network mirror: received rate, pacer depth, FEC recoveries and unrecovered losses
    /// per second, the three latency legs, and the newest frame's hold.
    package var statsFps: Double?
    package var statsPacerDepth: Int?
    package var statsFecPerSec: Double?
    package var statsUnrecoveredPerSec: Double?
    package var statsRttMs: Double?
    package var statsEncodeMs: Double?
    package var statsDecodeMs: Double?
    package var statsHoldMs: Int?

    package init(
        streamFps: Int? = nil,
        streamKbps: Int? = nil,
        statsFps: Double? = nil,
        statsPacerDepth: Int? = nil,
        statsFecPerSec: Double? = nil,
        statsUnrecoveredPerSec: Double? = nil,
        statsRttMs: Double? = nil,
        statsEncodeMs: Double? = nil,
        statsDecodeMs: Double? = nil,
        statsHoldMs: Int? = nil,
    ) {
        self.streamFps = streamFps
        self.streamKbps = streamKbps
        self.statsFps = statsFps
        self.statsPacerDepth = statsPacerDepth
        self.statsFecPerSec = statsFecPerSec
        self.statsUnrecoveredPerSec = statsUnrecoveredPerSec
        self.statsRttMs = statsRttMs
        self.statsEncodeMs = statsEncodeMs
        self.statsDecodeMs = statsDecodeMs
        self.statsHoldMs = statsHoldMs
    }
}

// MARK: - The readout

/// What a video (PATH 2) pane's chrome says, and when it is up at all.
package enum GuiPaneReadout {
    // MARK: Stats rows

    /// The five telemetry rows, top-down, exactly as the in-pane readout stacks them.
    ///
    /// Grouped by WHAT IS BEING MEASURED rather than by where the number came from: what the host is
    /// sending, what this client is receiving, what the error correction is costing, where the latency
    /// sits, and how stale the newest frame is.
    package static func statRows(_ stats: GuiStreamTelemetry) -> [String] {
        [
            "\(stats.streamFps.map(String.init) ?? absent) FPS · \(mbpsLabel(kbps: stats.streamKbps)) MBPS",
            "RX \(stats.statsFps.map { String(format: "%.0f", $0) } ?? absent) FPS · "
                + "DEPTH \(stats.statsPacerDepth.map(String.init) ?? absent)",
            "FEC \(perSecLabel(stats.statsFecPerSec)) · LOST \(perSecLabel(stats.statsUnrecoveredPerSec))",
            "RTT \(msLabel(stats.statsRttMs)) · ENC \(msLabel(stats.statsEncodeMs)) · "
                + "DEC \(msLabel(stats.statsDecodeMs))",
            "HOLD \(stats.statsHoldMs.map(String.init) ?? absent) MS",
        ]
    }

    /// The em dash that stands for "no reading yet". One spelling, so a row cannot invent its own.
    package static let absent = "—"

    /// Mbps at the surface from kbps on the wire, one decimal. `—` until the first measurement lands.
    package static func mbpsLabel(kbps: Int?) -> String {
        guard let kbps else { return absent }
        return String(format: "%.1f", Double(kbps) / 1000.0)
    }

    /// A per-second rate, one decimal, with its unit attached — so an absent one still reads as a rate
    /// (`—/S`) rather than as a missing word.
    package static func perSecLabel(_ value: Double?) -> String {
        guard let value else { return absent + "/S" }
        return String(format: "%.1f/S", value)
    }

    /// A millisecond duration, one decimal. The unit lives in the row label, not here.
    package static func msLabel(_ value: Double?) -> String {
        guard let value else { return absent }
        return String(format: "%.1f", value)
    }

    // MARK: The stall caption

    /// The stall caption: `RECONNECTING` while the epoch is unknown, `RECONNECTING · 12S` once it is.
    ///
    /// The drained (desaturated) last frame already says "this is the past" — MERIDIAN L1, colour is
    /// live data — so the caption carries only what the material cannot: that recovery is running, and
    /// how OLD the frozen frame is. The age floors at 0 so a clock skew can never print a negative.
    package static func stallCaption(since: Date?, now: Date) -> String {
        guard let since else { return "RECONNECTING" }
        let age = max(0, Int(now.timeIntervalSince(since).rounded(.down)))
        return "RECONNECTING · \(age)S"
    }

    // MARK: The placeholder

    /// What the non-live placeholder says. The cap-gated state names its own cause — two live streams
    /// is a deliberate ceiling, so "paused" without the reason would read as a failure.
    package static func placeholderLabel(_ state: RemoteGUIDisplay) -> String {
        state == .gated ? "Video paused — too many live streams" : "desktop"
    }

    // MARK: Stream quality

    /// The offered fps caps. `0` is Auto — the host's own governor, unclamped.
    package static let fpsChoices = [0, 15, 30, 60]
    /// The offered bitrate ceilings in Mbps. `0` is Auto — ABR unclamped.
    package static let mbpsChoices = [0, 5, 10, 20, 50]

    /// An fps choice's label. `0` is not "0 fps", it is the absence of a cap.
    package static func fpsChoiceLabel(_ fps: Int) -> String {
        fps == 0 ? "Auto" : "\(fps)"
    }

    /// A bitrate choice's label, with its unit. Same `0 → Auto` rule.
    package static func mbpsChoiceLabel(_ mbps: Int) -> String {
        mbps == 0 ? "Auto" : "\(mbps) Mb"
    }

    /// Mbps at the surface, bps on the model and the wire. Integer division on purpose: the picker
    /// offers whole Mbps only, so a value that is not one is a value the picker cannot show.
    package static func mbps(fromBps bps: Int) -> Int { bps / 1_000_000 }

    /// The inverse. `0` stays `0`, which is Auto on both sides of the conversion.
    package static func bps(fromMbps mbps: Int) -> Int { mbps * 1_000_000 }

    // MARK: Gates

    /// Whether the `🔒 READ ONLY ×` pill mounts: the pane is read-only AND this is not the
    /// static-mirror snapshot path (an `ImageRenderer` capture renders no live chrome).
    ///
    /// Mirrors the terminal leaf's read-only gate minus the vi/copy-mode exclusion — a video pane has
    /// no copy mode to step aside for.
    package static func showsReadOnlyPill(staticMirror: Bool, isReadOnly: Bool) -> Bool {
        !staticMirror && isReadOnly
    }

    /// Whether the bottom CONTROL bar mounts — only while the LIVE surface is up and not on the
    /// static-mirror path. Its verbs (resize / lock / zoom) are meaningful only against a live stream,
    /// so the picker and cap-gated states show no footer.
    package static func showsControlBar(staticMirror: Bool, hasLiveDescriptor: Bool) -> Bool {
        !staticMirror && hasLiveDescriptor
    }

    /// Whether any LATCHED pane mode is engaged — the states whose accent tint the control bar carries
    /// as status lights, and which the COLLAPSED chip inherits so no latched mode is ever invisible.
    ///
    /// The stats readout is deliberately absent from this list: its own visibility is its status light.
    package static func hasLatchedMode(
        immersive: Bool,
        viewportLocked: Bool,
        audioEnabled: Bool,
        streamFpsCap: Int,
        streamBitrateCeilingBps: Int,
    ) -> Bool {
        immersive || viewportLocked || audioEnabled || streamFpsCap != 0 || streamBitrateCeilingBps != 0
    }

    /// Whether this is a LIVE desktop pane that accepts drag-drop uploads.
    ///
    /// The gesture is "drop onto the remote desktop", so a window/dialog pane is not a target: it has
    /// no desktop to drop onto, and lighting the border there would promise an upload that cannot
    /// happen.
    package static func isDesktopUploadTarget(
        staticMirror: Bool, kind: PaneKind?, hasLiveDescriptor: Bool,
    ) -> Bool {
        !staticMirror && kind == .desktop && hasLiveDescriptor
    }

    /// The video activation `.task` identity: re-run cap admission when THIS session changes (a mount),
    /// when a sibling frees a slot, OR when visibility flips — so a pane returning to screen re-requests
    /// its slot immediately instead of waiting for a remount that keep-all-mounted will never give it.
    package static func activationKey(
        paneHash: Int, promotionGeneration: Int, isVisible: Bool,
    ) -> String {
        "\(paneHash):\(promotionGeneration):\(isVisible ? 1 : 0)"
    }

    // MARK: Upload marks

    /// The upload row's glyph name: rising while it sends, a settled check on success, a warning
    /// triangle on failure. An SF Symbol NAME is data, so the mapping is here and the drawing is not.
    package static func uploadGlyph(_ phase: FileUploadProgress.Phase) -> String {
        switch phase {
        case .sending: "arrow.up.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// The upload row's tone. Settled either way takes the accent; the glyph carries which.
    package static func uploadTint(_ phase: FileUploadProgress.Phase) -> GuiUploadTint {
        switch phase {
        case .sending: .icon
        case .completed,
             .failed: .accent
        }
    }

    // MARK: Control-bar tooltips

    /// The fourteen control-bar tooltips, spelled once.
    ///
    /// They are copy, not chrome: each names what the verb DOES and, where one exists, the chord that
    /// does it too — so the bar teaches the keyboard instead of competing with it. A toggle's two
    /// states get two sentences, because "Immersive" alone does not say whether it is on.
    package enum Tooltip {
        package static let paste =
            "Paste local clipboard into the remote window as keystrokes (⌥⌘V)"
        package static let displaySwitcher = "Switch host display"
        package static let detach = "Detach into its own window (⌥⌘P)"
        package static let reattach = "Reattach as a pane"
        package static let fitToPane = "Fit window to pane"
        package static let zoomOut = "Zoom out"
        package static let actualSize = "Actual size (1× + re-anchor top-left)"
        package static let zoomIn = "Zoom in"
        package static let showStats = "Show stream stats"
        package static let hideStats = "Hide stream stats"
        package static let streamQuality = "Stream quality — fps cap / bitrate ceiling…"
        package static let muteAudio = "Mute host audio"
        package static let playAudio = "Play host audio in this pane"
        package static let privacyOff = "Show the host display + restore its input"
        package static let privacyOn = "Privacy: black the host display + block its keyboard/mouse"
        package static let immersiveOn =
            "Immersive on — system keys (⌘Tab, ⌘Q, ⌘Space…) go to the host · ⌃⌥⌘E exits"
        package static let immersiveOff =
            "Immersive — send system keys (⌘Tab, ⌘Q, ⌘Space…) to the host"
        package static let unlockViewport = "Unlock viewport (resume edge-pan) (⌥⌘L)"
        package static let lockViewport = "Lock viewport position (freeze edge-pan) (⌥⌘L)"
        package static let collapseControls = "Hide controls"
        package static let expandControls = "Window controls"
    }
}

// MARK: - The upload actuator

/// The drag-drop upload path: the gate, then the one call that runs it.
@MainActor
package enum GuiPaneUploads {
    /// Routes dropped file URLs to the dedicated PATH-4 uploader.
    ///
    /// - Returns: whether the drop was ACCEPTED. `false` for a non-desktop / non-streaming pane, or for
    ///   a model with no transfer endpoint yet — the OS then shows the reject cursor instead of
    ///   swallowing the drag into nothing.
    @discardableResult
    package static func handleDrop(
        _ urls: [URL], isUploadTarget: Bool, model: RemoteWindowModel?,
    ) -> Bool {
        guard isUploadTarget, let model, let endpoint = model.fileTransferTarget() else { return false }
        FileUploadCoordinator.upload(files: urls, host: endpoint.host, port: endpoint.port, into: model)
        return true
    }
}

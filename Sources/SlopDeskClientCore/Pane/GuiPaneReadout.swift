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
// THE FORMATTERS, THE CONVERSION AND THE MARKS ARE RUST NOW (`slopdesk_workspace::gui_readout`). What
// survived that move is the SHAPE of this face: the same signatures, the same names, the same call
// sites — every body below is one door call plus the byte a Swift enum crosses as. Nothing here
// decides anything, which is the test for whether the boundary landed in the right place.
//
// TWO RULES ABOUT WHAT CROSSES:
//
// A COLOUR DOES NOT. `tint(_:)` returned a `Color`, and this layer sits below the token floor and draws
// nothing — so what crosses is the semantic (``GuiUploadTint``) and each framework looks up its own
// token. Only the BRANCH descends, which is the part that could ever be wrong.
//
// A SYMBOL DOES, AS A NAME. An SF Symbol name is data — the same shape `SlateEmptyState.symbol(for:)`
// already ships — so the phase→mark mapping lives one floor down and the view spells
// `Image(systemName:)`.
//
// A CLOCK DOES NOT CROSS EITHER. ``GuiPaneReadout/stallCaption(since:now:)`` still takes two `Date`s,
// because that is what a view has; what it hands the door is the ELAPSED SECONDS between them. A rule
// that read the wall clock could not be asked about a chosen moment, which is half of what its own
// tests do.
//
// EVERY READING IS ABSENT, NEVER WRONG: a stat with no sample yet prints `—` rather than `0`, and a
// stall with no epoch prints `RECONNECTING` with no age rather than `· 0S`. A zero that means "no
// reading" is the one lie an instrument readout must not tell.
//
// THREE OF THE GATES BELOW USED TO TAKE A FOURTH INPUT THAT NO CALLER EVER SET. `showsControlBar`,
// `isDesktopUploadTarget` and `showsReadOnlyPill` each began `!staticMirror && …`, for a headless
// `ImageRenderer` snapshot path that reached them as a defaulted `SplitContainer` parameter threaded
// down through `PaneContainer`. Nothing in `Sources/`, `Apps/` or `ThirdParty/` ever passed `true` —
// the only `true` in the tree was in these gates' own tests, which is a branch kept alive by the
// suite that pinned it. Deleted whole in increment 56d, ratcheted by `slopdesk-invariants`. If a
// snapshot renderer is ever wanted again it gets ONE gate where the render starts, not a flag that
// every predicate under the canvas has to carry and every AppKit rewrite has to re-type.

import CSlopDeskFFI
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

// MARK: - Reading a door that always has something to say

/// One `(out, cap)` answer, read as the string it delivered.
///
/// Every door this file calls answers a non-empty string — a formatter has at least the em dash to
/// say, and a table has a word for the byte it could not name — so the `nil` arm is unreachable by
/// construction. It is `""` rather than a trap because a readout that somehow lost a formatter should
/// print nothing, not take the pane down with it.
private func guiAnswer(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String {
    wsAnswer(call) ?? ""
}

private extension GuiStreamTelemetry {
    /// The sample as the door takes it: ten values with ten presence flags beside them, laid out
    /// widest-first.
    ///
    /// A FLAG and not a sentinel, because `nil` and `0` are the two facts this whole file exists to
    /// keep apart — no number could have carried "nothing has measured this yet". The value beside a
    /// `false` flag is never read; it is zero so a debugger sees a zero.
    var ffiRecord: SlopDeskWsGuiTelemetry {
        SlopDeskWsGuiTelemetry(
            stats_fps: statsFps ?? 0,
            stats_fec_per_sec: statsFecPerSec ?? 0,
            stats_unrecovered_per_sec: statsUnrecoveredPerSec ?? 0,
            stats_rtt_ms: statsRttMs ?? 0,
            stats_encode_ms: statsEncodeMs ?? 0,
            stats_decode_ms: statsDecodeMs ?? 0,
            stream_fps: Int64(streamFps ?? 0),
            stream_kbps: Int64(streamKbps ?? 0),
            stats_pacer_depth: Int64(statsPacerDepth ?? 0),
            stats_hold_ms: Int64(statsHoldMs ?? 0),
            has_stats_fps: statsFps != nil,
            has_stats_fec_per_sec: statsFecPerSec != nil,
            has_stats_unrecovered_per_sec: statsUnrecoveredPerSec != nil,
            has_stats_rtt_ms: statsRttMs != nil,
            has_stats_encode_ms: statsEncodeMs != nil,
            has_stats_decode_ms: statsDecodeMs != nil,
            has_stream_fps: streamFps != nil,
            has_stream_kbps: streamKbps != nil,
            has_stats_pacer_depth: statsPacerDepth != nil,
            has_stats_hold_ms: statsHoldMs != nil,
        )
    }
}

/// The byte a display state crosses as — this enum's own declaration order, which the far side's
/// `Display` mirrors case for case.
private extension RemoteGUIDisplay {
    var ffiByte: UInt8 {
        switch self {
        case .live: 0
        case .entryForm: 1
        case .gated: 2
        }
    }
}

/// The byte an upload phase crosses as — this enum's own declaration order, mirrored by the far
/// side's `UploadPhase`.
private extension FileUploadProgress.Phase {
    var ffiByte: UInt8 {
        switch self {
        case .sending: 0
        case .completed: 1
        case .failed: 2
        }
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
    ///
    /// ONE crossing for all five, because the readout draws them together or not at all.
    package static func statRows(_ stats: GuiStreamTelemetry) -> [String] {
        let record = stats.ffiRecord
        return wsRuns(
            wsAnswerBytes { out, cap in Int(slopdesk_ws_gui_stat_rows(record, out, cap)) },
            count: 5,
        )
    }

    /// Mbps at the surface from kbps on the wire, one decimal. `—` until the first measurement lands.
    package static func mbpsLabel(kbps: Int?) -> String {
        guiAnswer { out, cap in
            Int(slopdesk_ws_gui_mbps_label(kbps != nil, Int64(kbps ?? 0), out, cap))
        }
    }

    /// A per-second rate, one decimal, with its unit attached — so an absent one still reads as a rate
    /// (`—/S`) rather than as a missing word.
    package static func perSecLabel(_ value: Double?) -> String {
        guiAnswer { out, cap in
            Int(slopdesk_ws_gui_per_sec_label(value != nil, value ?? 0, out, cap))
        }
    }

    /// A millisecond duration, one decimal. The unit lives in the row label, not here.
    package static func msLabel(_ value: Double?) -> String {
        guiAnswer { out, cap in Int(slopdesk_ws_gui_ms_label(value != nil, value ?? 0, out, cap)) }
    }

    // MARK: The stall caption

    /// The stall caption: `RECONNECTING` while the epoch is unknown, `RECONNECTING · 12S` once it is.
    ///
    /// The drained (desaturated) last frame already says "this is the past" — MERIDIAN L1, colour is
    /// live data — so the caption carries only what the material cannot: that recovery is running, and
    /// how OLD the frozen frame is. The age floors at 0 so a clock skew can never print a negative.
    ///
    /// Two `Date`s in, ELAPSED SECONDS across: the caller is the one with a clock, and the rule is
    /// asked about an interval so its own tests can pick the moment.
    package static func stallCaption(since: Date?, now: Date) -> String {
        let elapsed = since.map { now.timeIntervalSince($0) }
        return guiAnswer { out, cap in
            Int(slopdesk_ws_gui_stall_caption(elapsed != nil, elapsed ?? 0, out, cap))
        }
    }

    // MARK: The placeholder

    /// What the non-live placeholder says. The cap-gated state names its own cause — two live streams
    /// is a deliberate ceiling, so "paused" without the reason would read as a failure.
    package static func placeholderLabel(_ state: RemoteGUIDisplay) -> String {
        guiAnswer { out, cap in Int(slopdesk_ws_gui_placeholder_label(state.ffiByte, out, cap)) }
    }

    // MARK: Stream quality

    /// The offered fps caps. `0` is Auto — the host's own governor, unclamped.
    package static let fpsChoices = [0, 15, 30, 60]
    /// The offered bitrate ceilings in Mbps. `0` is Auto — ABR unclamped.
    package static let mbpsChoices = [0, 5, 10, 20, 50]

    /// An fps choice's label. `0` is not "0 fps", it is the absence of a cap.
    package static func fpsChoiceLabel(_ fps: Int) -> String {
        guiAnswer { out, cap in Int(slopdesk_ws_gui_fps_choice_label(Int64(fps), out, cap)) }
    }

    /// A bitrate choice's label, with its unit. Same `0 → Auto` rule.
    package static func mbpsChoiceLabel(_ mbps: Int) -> String {
        guiAnswer { out, cap in Int(slopdesk_ws_gui_mbps_choice_label(Int64(mbps), out, cap)) }
    }

    /// Mbps at the surface, bps on the model and the wire. Integer division on purpose: the picker
    /// offers whole Mbps only, so a value that is not one is a value the picker cannot show.
    package static func mbps(fromBps bps: Int) -> Int {
        Int(slopdesk_ws_gui_mbps_from_bps(Int64(bps)))
    }

    /// The inverse. `0` stays `0`, which is Auto on both sides of the conversion.
    package static func bps(fromMbps mbps: Int) -> Int {
        Int(slopdesk_ws_gui_bps_from_mbps(Int64(mbps)))
    }

    // MARK: Gates

    /// Whether the `🔒 READ ONLY ×` pill mounts: the pane is read-only.
    ///
    /// Mirrors the terminal leaf's read-only gate minus the vi/copy-mode exclusion — a video pane has
    /// no copy mode to step aside for. Kept as a NAMED gate rather than inlined at the one call site
    /// that reads it today: it is the question an AppKit canvas will ask next, and a pill that is a
    /// visual peer of the terminal's has to answer it the same way, once.
    package static func showsReadOnlyPill(isReadOnly: Bool) -> Bool {
        isReadOnly
    }

    /// Whether the bottom CONTROL bar mounts — only while the LIVE surface is up. Its verbs
    /// (resize / lock / zoom) are meaningful only against a live stream, so the picker and cap-gated
    /// states show no footer.
    package static func showsControlBar(hasLiveDescriptor: Bool) -> Bool {
        hasLiveDescriptor
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
        slopdesk_ws_gui_has_latched_mode(
            immersive, viewportLocked, audioEnabled,
            Int64(streamFpsCap), Int64(streamBitrateCeilingBps),
        )
    }

    /// Whether this is a LIVE desktop pane that accepts drag-drop uploads.
    ///
    /// The gesture is "drop onto the remote desktop", so a window/dialog pane is not a target: it has
    /// no desktop to drop onto, and lighting the border there would promise an upload that cannot
    /// happen.
    package static func isDesktopUploadTarget(kind: PaneKind?, hasLiveDescriptor: Bool) -> Bool {
        kind == .desktop && hasLiveDescriptor
    }

    /// The video activation `.task` identity: re-run cap admission when THIS session changes (a mount),
    /// when a sibling frees a slot, OR when visibility flips — so a pane returning to screen re-requests
    /// its slot immediately instead of waiting for a remount that keep-all-mounted will never give it.
    package static func activationKey(
        paneHash: Int, promotionGeneration: Int, isVisible: Bool,
    ) -> String {
        guiAnswer { out, cap in
            Int(slopdesk_ws_gui_activation_key(
                Int64(paneHash), Int64(promotionGeneration), isVisible, out, cap,
            ))
        }
    }

    // MARK: Upload marks

    /// The upload row's glyph name: rising while it sends, a settled check on success, a warning
    /// triangle on failure. An SF Symbol NAME is data, so the mapping is one floor down and the
    /// drawing is not.
    package static func uploadGlyph(_ phase: FileUploadProgress.Phase) -> String {
        guiAnswer { out, cap in Int(slopdesk_ws_gui_upload_glyph(phase.ffiByte, out, cap)) }
    }

    /// The upload row's tone. Settled either way takes the accent; the glyph carries which.
    package static func uploadTint(_ phase: FileUploadProgress.Phase) -> GuiUploadTint {
        slopdesk_ws_gui_upload_tint(phase.ffiByte) == 0 ? .icon : .accent
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

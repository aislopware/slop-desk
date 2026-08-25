import Foundation
import SlopDeskWorkspaceModel

// Per-pane `@MainActor @Observable` LOGIC for one PATH-2 video stream (a whole display for a
// `.desktop` pane; one host window on the automation seam): open/close, the latched pane modes,
// and paste-as-keystrokes. No SwiftUI usage (a rebuilt view binds to it).
//
// ── "THE LIVE VIDEO PANE" IS DELIBERATELY NOT A DOC LINK BELOW (docs/56 §3, the video carve) ──────
// Eighteen doc comments in this file describe a sink that "the live video pane publishes". They used
// to say `VideoWindowView` in DOUBLE backticks — a doc link — and it was never resolvable: this module depends on
// `SlopDeskVideoProtocol` and NOTHING in the video client, because the `VideoWindowFactory` seam
// exists precisely so the domain layer cannot name a VideoToolbox/Metal type. The double backticks
// were pointing at a symbol DocC could not see from here.
//
// The carve then made them actively misleading. `VideoWindowView` is now the PHONE half's type — the
// Mac's is `MacVideoWindowView` — so a link left as-is resolves to one platform while describing a
// contract both honour, and a doc link that resolves to the WRONG platform is worse than one that
// resolves to nothing. Every generic mention is therefore prose: it means the pane view of whichever
// half is mounted, and no half in particular.
//
// The ONE mention that is platform-specific — ``systemKeyInjector`` — says so at its own declaration,
// and it is the reason this note is worth reading rather than deleting.
@preconcurrency
@MainActor
@Observable
public final class RemoteWindowModel {
    // MARK: Target fields

    /// Which host-side window to stream (the automation seam's pre-bound id, as a string — the
    /// historical entry-field shape). Host/ports come from the app target. Unused for a display target.
    public var windowID: String
    public var title: String
    /// The owning app's name for a window-shaped target (empty for manual/display bindings).
    public var appName: String

    /// The store persists each committed endpoint into the pane's spec through this (wired at session
    /// materialization). Fired by ``open()``.
    public var onEndpointCommitted: ((VideoEndpoint) -> Void)?

    /// Resolves the app-global ``ConnectionTarget`` (host + UDP ports) at open-time so every video pane
    /// rides the one shared UDP flow at the app host (docs/31).
    private let target: @MainActor () -> ConnectionTarget

    /// FULL-DESKTOP TARGET (a `.desktop` pane): non-nil ⇒ this model streams a whole host display
    /// (`0` = the main display) instead of a window. ``open()`` then builds a display descriptor
    /// directly — no window id (a display target never goes stale the way CGWindowIDs do).
    /// Mutable only via ``switchDisplay(to:)`` (the desktop pane's display switcher) — every other
    /// consumer treats it as the fixed mint-time target.
    public private(set) var desktopDisplayID: UInt32?

    /// The opened window's descriptor (carries the full endpoint). `nil` ⇒ the placeholder is shown;
    /// non-nil ⇒ the live ``VideoWindowFactory`` view is shown.
    public private(set) var active: RemoteWindowDescriptor?

    /// A short human-readable reason the stream fell back to the placeholder (e.g. the host rejected
    /// the session — target gone / version skew). Cleared on a successful re-open.
    public private(set) var loadError: String?

    // MARK: Paste as Keystrokes (per-key CGEvent typing into secure fields)

    /// The live key-injection sink the video pane publishes (via
    /// ``RemotePaneContext/onKeyInjectorReady``) once its session exists, cleared (`nil`) on teardown.
    /// Each call drives the host's per-event input path (`InputInjector.postKey`, plain `CGEvent`) — CGEvent
    /// keys reach `sudo` / SecurityAgent password fields even under Secure Event Input. `(keyCode, down, shift)`.
    ///
    /// READ-ONLY GATE: on a read-only pane the SEAM binds a `nil` sink here (`GuiLeafView` →
    /// ``RemotePaneContext/videoLeaf(isActive:readOnly:...)``), so paste-as-keystrokes is inert
    /// (``canPasteKeystrokes`` `false`, ``pasteAsKeystrokes(_:)`` no-ops) WITHOUT any model→store coupling —
    /// the model never learns the read-only state; the seam withholds the sink.
    public var keyInjector: ((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?

    /// RESIZE (numeric popover): the live video pane publishes this once its session exists
    /// (cleared `nil` on teardown / when read-only). The "Resize…" popover calls it to request an ABSOLUTE
    /// host-window POINT size; `(width, height)`. `nil` ⇒ no live sink (no button).
    public var resizeInjector: ((_ width: Double, _ height: Double) -> Void)?

    /// Whether the resize control should be live: streaming AND a resize sink is wired (withheld while
    /// read-only). `GuiLeafView` gates the "Resize…" button on this.
    public var canResizeWindow: Bool { active != nil && resizeInjector != nil }

    /// The remote window's CURRENT POINT size, pushed by the live video pane on the first decoded frame and
    /// every host-/popover-driven resize (via ``noteWindowGeometry(currentW:currentH:maxW:maxH:)``). `nil`
    /// until the first frame; the "Resize…" popover pre-fills its width/height fields from it.
    public private(set) var windowPointSize: CGSize?
    /// The MAX resizable POINT size the host reported (its display bounds), pushed by the live video pane
    /// once the host's `displayMax` lands. `nil` until known — the popover then leaves its fields uncapped
    /// (the host still clamps server-side). The host's resize-to-display-origin makes this max reachable.
    public private(set) var windowMaxPointSize: CGSize?

    /// HOST-WINDOW RESIZE: the live view pushes the window's current + max resizable POINT sizes here.
    /// Current pre-fills the popover; max (once known) caps its fields. A zero/absent max leaves the max
    /// uncapped — and once known it persists (a later zero-max push never clears it).
    public func noteWindowGeometry(currentW: Double, currentH: Double, maxW: Double, maxH: Double) {
        let admitted = RemoteWindowRules.geometry(
            currentW: currentW, currentH: currentH, maxW: maxW, maxH: maxH,
        )
        if let current = admitted.current { windowPointSize = current }
        if let max = admitted.max { windowMaxPointSize = max }
    }

    /// The host-announced stream CADENCE (frames/sec), pushed by the live video pane on the initial cadence
    /// and every FPS-governor change. `nil` until the first lands. The sidebar's Connection section shows it
    /// as a per-pane "FPS" row (hidden for terminal panes). It is the host's negotiated encode rate — NOT a
    /// client-measured present throughput.
    public private(set) var streamFps: Int?

    /// Records the host-announced cadence. A non-positive value is ignored (a spurious zero never blanks the
    /// row — the last good reading stands). Only writes the observable on a real change.
    public func noteStreamFps(_ fps: Int) {
        guard RemoteWindowRules.admitsStreamFps(fps), streamFps != fps else { return }
        streamFps = fps
    }

    /// CONNECTION STATS: client-measured video PAYLOAD bitrate (kilobits/sec), pushed ~1 Hz by
    /// the live video pane. Unlike ``streamFps`` a ZERO is a real reading (idle-skip = nothing flows), so it
    /// is kept; only a negative (nonsense) value is dropped. `nil` until the first report lands.
    public private(set) var streamKbps: Int?

    /// Records one ~1 Hz bitrate reading. Only writes the observable on a real change.
    public func noteStreamKbps(_ kbps: Int) {
        guard RemoteWindowRules.admitsStreamKbps(kbps), streamKbps != kbps else { return }
        streamKbps = kbps
    }

    /// LIVE NETWORK STATS (client-local mirror, ~2 Hz): received frames/sec, FEC recoveries/sec,
    /// unrecovered losses/sec, the latest host-stamp hold (ms), and the pacer's live depth —
    /// pushed by the live video pane from the session's aggregated telemetry windows. `nil` until
    /// the first push lands. Like ``streamKbps``, ZEROS are real readings (an idle stream receives
    /// nothing), so they are kept.
    public private(set) var statsFps: Double?
    public private(set) var statsFecPerSec: Double?
    public private(set) var statsUnrecoveredPerSec: Double?
    public private(set) var statsHoldMs: Int?
    public private(set) var statsPacerDepth: Int?
    /// LATENCY AXES (the Parsec-grade HUD rows): host-reported smoothed RTT + encode-wall EWMA
    /// (wire type 27) and the client's decode-wall EWMA. Unlike the rate axes a ZERO here means
    /// "no reading yet" (old host / telemetry off / first window filling), so it maps to `nil`
    /// and the readout renders a dash — never a fake 0.0 ms.
    public private(set) var statsRttMs: Double?
    public private(set) var statsEncodeMs: Double?
    public private(set) var statsDecodeMs: Double?

    /// Records one ~2 Hz network-stats reading. A negative value on any axis is nonsense (rates and
    /// gauges are non-negative by construction) — the whole reading is dropped rather than mixing a
    /// good axis with garbage. Each observable is only written on a real change.
    public func noteNetworkStats(
        fps: Double, fecPerSec: Double, unrecoveredPerSec: Double, holdMs: Int, pacerDepth: Int,
        rttMs: Double = 0, encodeMs: Double = 0, decodeMs: Double = 0,
    ) {
        guard let reading = RemoteWindowRules.networkReading(
            fps: fps, fecPerSec: fecPerSec, unrecoveredPerSec: unrecoveredPerSec,
            holdMs: holdMs, pacerDepth: pacerDepth,
            rttMs: rttMs, encodeMs: encodeMs, decodeMs: decodeMs,
        ) else { return }
        if statsFps != reading.fps { statsFps = reading.fps }
        if statsFecPerSec != reading.fecPerSec { statsFecPerSec = reading.fecPerSec }
        if statsUnrecoveredPerSec != reading.unrecoveredPerSec {
            statsUnrecoveredPerSec = reading.unrecoveredPerSec
        }
        if statsHoldMs != reading.holdMs { statsHoldMs = reading.holdMs }
        if statsPacerDepth != reading.pacerDepth { statsPacerDepth = reading.pacerDepth }
        if statsRttMs != reading.rttMs { statsRttMs = reading.rttMs }
        if statsEncodeMs != reading.encodeMs { statsEncodeMs = reading.encodeMs }
        if statsDecodeMs != reading.decodeMs { statsDecodeMs = reading.decodeMs }
    }

    /// STREAM SETTINGS (fps cap / bitrate ceiling): the live video pane publishes this once its
    /// session exists (cleared `nil` on teardown; WITHHELD by the seam while read-only — it changes HOST
    /// encode behaviour, like ``resizeInjector``). `(fpsCap, bitrateCeilingBps)`, `0` = auto; the host
    /// clamps on apply and the session re-sends the request after every re-hello.
    ///
    /// Re-asserts a NON-AUTO ``streamFpsCap``/``streamBitrateCeilingBps`` on every publish (the
    /// ``audioInjector`` precedent): a detach/reattach re-binds the SAME model to a FRESH view whose new
    /// session — and so the host — starts at auto, so the model's remembered override must re-push. An
    /// all-auto model publishes nothing (the fresh session's default is already correct).
    public var streamSettingsInjector: ((_ fpsCap: Int, _ bitrateCeilingBps: Int) -> Void)? {
        didSet {
            if streamFpsCap != 0 || streamBitrateCeilingBps != 0, let inject = streamSettingsInjector {
                inject(streamFpsCap, streamBitrateCeilingBps)
            }
        }
    }

    /// Whether the stream-settings controls should be live: streaming AND a settings sink is wired
    /// (withheld while read-only).
    public var canAdjustStreamSettings: Bool { active != nil && streamSettingsInjector != nil }

    /// The last-requested stream-quality overrides (`0` = auto). The MODEL owns them (mirrors
    /// ``audioStreamEnabled``) so the footer selection survives a view remount (detach/reattach) —
    /// re-asserted into every freshly-published sink via ``streamSettingsInjector``'s `didSet`.
    public private(set) var streamFpsCap = 0
    public private(set) var streamBitrateCeilingBps = 0

    /// Request a live fps cap / bitrate ceiling (`0` = auto). Gated on ``canAdjustStreamSettings`` so an
    /// off-stream / read-only apply can't strand an override the session never saw — a graceful no-op,
    /// like the other video verbs. A same-values apply is dropped (the sink is absolute; nothing to say).
    public func applyStreamSettings(fpsCap: Int, bitrateCeilingBps: Int) {
        guard canAdjustStreamSettings,
              streamFpsCap != fpsCap || streamBitrateCeilingBps != bitrateCeilingBps else { return }
        streamFpsCap = fpsCap
        streamBitrateCeilingBps = bitrateCeilingBps
        streamSettingsInjector?(fpsCap, bitrateCeilingBps)
        notifyModesChanged()
    }

    /// HOST AUDIO (footer speaker toggle): the live video pane publishes this once its session
    /// exists (cleared `nil` on teardown; WITHHELD by the seam while read-only — it changes HOST capture
    /// behaviour, like ``streamSettingsInjector``). Absolute `enabled` — the session stores the wish and
    /// re-sends it after every re-hello.
    ///
    /// Re-asserts ``audioStreamEnabled`` on every publish: a detach/reattach re-binds the SAME model to a
    /// FRESH view whose new session (and so the host) starts with audio OFF, so the model — the toggle's
    /// source of truth — pushes the wish back down the new sink. The command is ABSOLUTE
    /// (enable/disable, never a toggle), so the re-assert is idempotent on a still-live session.
    public var audioInjector: ((_ enabled: Bool) -> Void)? {
        didSet {
            if audioStreamEnabled, let inject = audioInjector {
                inject(true)
            }
        }
    }

    /// Whether the footer speaker toggle is live: streaming AND an audio sink is wired (withheld while
    /// read-only).
    public var canToggleAudio: Bool { active != nil && audioInjector != nil }

    /// Whether host app audio is streaming into this pane (the speaker's status light). The MODEL owns
    /// the state (mirrors ``viewportLocked``) so the toggle survives a view remount; defaults OFF,
    /// matching every fresh session's host state.
    public private(set) var audioStreamEnabled = false

    /// Flip host-audio streaming through the published sink. Gated on ``canToggleAudio`` so an
    /// off-stream / read-only flip can't strand an ON state the session never saw — a graceful no-op,
    /// like the other video verbs. A same-value apply is a no-op (the sink is absolute; nothing to say).
    public func applyAudioEnabled(_ enabled: Bool) {
        guard canToggleAudio, audioStreamEnabled != enabled else { return }
        audioStreamEnabled = enabled
        audioInjector?(enabled)
        notifyModesChanged()
    }

    // MARK: Privacy blank (host display blackout — display sessions only)

    /// PRIVACY BLANK (footer shield toggle, DESKTOP panes only): the live video pane
    /// publishes this once its display session exists (cleared `nil` on teardown; WITHHELD while
    /// read-only — it changes HOST behaviour, like ``audioInjector``). Absolute `enabled`; the
    /// session stores the wish and re-sends it after every re-hello. Re-asserts ``privacyEnabled``
    /// on every publish (the ``audioInjector`` precedent — a re-mint resets the host OFF).
    public var privacyInjector: ((_ enabled: Bool) -> Void)? {
        didSet {
            if privacyEnabled, let inject = privacyInjector {
                inject(true)
            }
        }
    }

    /// Whether the footer privacy toggle is live: streaming AND a privacy sink is wired (withheld
    /// while read-only — the host blackout must never be driven from a locked pane).
    public var canTogglePrivacy: Bool { active != nil && privacyInjector != nil }

    /// Whether the host display is privacy-blanked for this session (the shield's status light). The
    /// MODEL owns the state so the toggle survives a view remount; defaults OFF, matching a fresh
    /// session's host state.
    public private(set) var privacyEnabled = false

    /// Flip the host privacy blank through the published sink. Gated on ``canTogglePrivacy``; a
    /// same-value apply is a no-op (the sink is absolute).
    public func applyPrivacyEnabled(_ enabled: Bool) {
        guard canTogglePrivacy, privacyEnabled != enabled else { return }
        privacyEnabled = enabled
        privacyInjector?(enabled)
        notifyModesChanged()
    }

    // MARK: File transfer (drag-drop upload over the dedicated PATH-4 connection)

    /// In-flight + just-settled drag-drop uploads for THIS desktop pane, driving the progress overlay.
    /// The app-layer coordinator (which owns the reliable-channel client) upserts each one as it
    /// advances and dismisses it a moment after it settles. Reset on ``close()`` — a re-bound window
    /// starts with no stray progress rows.
    public private(set) var activeUploads: [FileUploadProgress] = []

    /// The host + dedicated file-transfer port a drop should dial, or `nil` when the pane is not
    /// streaming (nothing to drop onto). Resolved from the app target — `filePort` is the terminal
    /// port `&+ 2`, the daemon's PATH-4 listener. Only desktop panes accept uploads (the gesture is
    /// "drop onto the remote desktop"); a window/dialog pane returns `nil`.
    public func fileTransferTarget() -> (host: String, port: UInt16)? {
        guard active != nil, desktopDisplayID != nil else { return nil }
        let t = target()
        return (t.host, t.filePort)
    }

    /// Inserts or updates an upload row (keyed by its stable id). The app coordinator calls this as the
    /// transfer progresses; the view renders ``activeUploads``.
    public func upsertUpload(_ progress: FileUploadProgress) {
        if let index = activeUploads.firstIndex(where: { $0.id == progress.id }) {
            activeUploads[index] = progress
        } else {
            activeUploads.append(progress)
        }
    }

    /// Removes a settled upload row (the coordinator calls this a moment after it completes/fails).
    public func dismissUpload(_ id: UUID) {
        activeUploads.removeAll { $0.id == id }
    }

    // MARK: Immersive wish (macOS system-key capture — the model-owned toggle state)

    /// IMMERSIVE (system keys → host): whether the user's immersive toggle is ON. The MODEL owns the
    /// wish (mirrors ``viewportLocked``/``audioStreamEnabled``) so a detach/reattach remount — which
    /// mints a fresh view whose per-view `SystemKeyCaptureController` starts disengaged — can re-engage
    /// the tap from this remembered state instead of silently dropping the toggle. The CGEventTap itself
    /// stays view-owned (`GuiLeafView`): only a mounted, focused, Accessibility-trusted view may
    /// actually swallow the keyboard; this flag is the intent, not the tap.
    ///
    /// Deliberately NOT reset by ``close()``: the tap survives a window close/re-pick as a SUSPENSION
    /// today (`canInjectSystemKeys` flips false → the view suspends, capture resumes when a stream is
    /// back), so the wish mirrors that lifecycle — unlike audio/lock, whose absolute re-assert into a
    /// re-bound window's fresh sink is exactly the hazard `close()`'s resets defuse.
    public private(set) var immersiveDesired = false

    /// Records the immersive toggle's state (the view calls this on a successful engage, on the manual
    /// toggle-off, and on the ⌃⌥⌘E escape chord — never on a plain unmount, which must keep the wish so
    /// the remounted view re-engages). Dedups so a redundant mirror-sync never spams the persistence sink.
    /// An EXPLICIT off also drops the fullscreen auto-arm (the escape hatch must win — the Moonlight
    /// lesson: capture with no in-stream off switch traps the user).
    public func setImmersiveDesired(_ on: Bool) {
        let commit = RemoteWindowRules.immersiveCommit(
            on: on, desired: immersiveDesired, fullscreenOverride: fullscreenImmersiveOverride,
        )
        if fullscreenImmersiveOverride != commit.fullscreenOverride {
            fullscreenImmersiveOverride = commit.fullscreenOverride
        }
        guard commit.notifies else { return }
        immersiveDesired = commit.desired
        notifyModesChanged()
    }

    /// FULLSCREEN AUTO-ARM (docs/DECISIONS.md 2026-07-22): while the pane's dedicated window is in
    /// native fullscreen, system-key capture is armed regardless of the LATCHED immersive toggle —
    /// the industry-converged pattern (fullscreen ⇒ the remote owns the keyboard). Never persisted
    /// (``currentModes`` reads only ``immersiveDesired``); exiting fullscreen returns capture to the
    /// latched value. Cleared by an explicit immersive-off (see ``setImmersiveDesired(_:)``).
    public private(set) var fullscreenImmersiveOverride = false

    /// The satellite window delegate's fullscreen report (via the handle seam).
    public func noteFullscreenPresentation(_ isFullscreen: Bool) {
        guard fullscreenImmersiveOverride != isFullscreen else { return }
        fullscreenImmersiveOverride = isFullscreen
    }

    /// The EFFECTIVE immersive wish the view engages on: the latched toggle OR the fullscreen
    /// auto-arm.
    public var immersiveEffective: Bool { immersiveDesired || fullscreenImmersiveOverride }

    // MARK: Latched-modes persistence (restart survival)

    /// Fired after every EXPLICIT user mode toggle (immersive / audio / viewport lock / stream
    /// overrides) with the full latched-mode snapshot — the store persists it into the pane's spec
    /// (wired at session materialization, like ``onEndpointCommitted``). `close()`'s runtime resets
    /// never fire this: an app-quit teardown must not wipe the persisted restart intent.
    public var onModesChanged: ((VideoPaneModes) -> Void)?

    /// The current latched-mode snapshot (what ``onModesChanged`` publishes / a restore seeds).
    public var currentModes: VideoPaneModes {
        VideoPaneModes(
            immersive: immersiveDesired,
            audioEnabled: audioStreamEnabled,
            viewportLocked: viewportLocked,
            fpsCap: streamFpsCap,
            bitrateCeilingBps: streamBitrateCeilingBps,
        )
    }

    private func notifyModesChanged() {
        onModesChanged?(currentModes)
    }

    /// RESTORE SEED: adopts a persisted mode snapshot as the model's starting wishes — set at session
    /// materialization (``LivePaneSession``), BEFORE any view exists, so the injector `didSet`
    /// re-asserts (audio / lock / stream overrides) and the view's immersive auto-engage push each wish
    /// into the first session exactly like a detach remount. Never fires ``onModesChanged`` (the spec
    /// already holds these values) and never touches a sink (none is published yet).
    public func seedModes(_ modes: VideoPaneModes) {
        immersiveDesired = modes.immersive
        audioStreamEnabled = modes.audioEnabled
        viewportLocked = modes.viewportLocked
        let caps = RemoteWindowRules.seededCaps(
            fpsCap: modes.fpsCap, bitrateCeilingBps: modes.bitrateCeilingBps,
        )
        streamFpsCap = caps.fpsCap
        streamBitrateCeilingBps = caps.bitrateCeilingBps
    }

    /// SYSTEM-KEY INJECTOR (immersive-capture plumbing): programmatic key events driven through the
    /// SAME wire path the pane's local keyDown/keyUp uses. `(keyCode, modifierFlags [raw platform
    /// flags], isDown)`. Cleared `nil` on teardown; WITHHELD by the seam while read-only — it sends
    /// host input, like ``keyInjector``.
    ///
    /// ⚠️ THE ONE SINK ONLY THE MAC HALF EVER PUBLISHES, and the only mention in this file that is not
    /// generic. `MacVideoWindowView` takes it; the phone's `VideoWindowView` does not accept the
    /// parameter at all. That is a platform floor, not an unfinished port: `modifierFlags` is a raw
    /// `NSEvent.ModifierFlags` bit pattern and its only producer is `SystemKeyCaptureController`'s
    /// `CGEventTap`, neither of which exists in the iOS SDK — which is why `PaneImmersiveCapture`
    /// already reports `isSupported == false` there and the phone footer draws no immersive chip.
    ///
    /// So ``canInjectSystemKeys`` is permanently `false` on the phone, BY CONSTRUCTION rather than by
    /// omission. Before the carve this read "published by `VideoWindowView`", which after the rename
    /// would have named the one half that never publishes it — the exact wrong-platform doc link the
    /// note at the top of this file exists to prevent. `slopdesk-invariants`'s Rule D (`rules::ui_split`) carries the same fact
    /// as its single named exception.
    public var systemKeyInjector: ((_ keyCode: UInt16, _ modifierFlags: UInt64, _ isDown: Bool) -> Void)?

    /// Whether programmatic system-key injection is possible right now: streaming AND a live sink is
    /// wired (withheld while read-only).
    public var canInjectSystemKeys: Bool { active != nil && systemKeyInjector != nil }

    /// STALL SCRIM: whether the stream is STALLED — the host went
    /// silent (no frame AND no 1 s host heartbeat) past the stall threshold, so the pane overlays a
    /// "Reconnecting…" scrim over the frozen last frame. Pushed by the live video pane on every flip (sticky
    /// through the client's self-heal rebuild — clears only when traffic actually resumes). Defaults `false`.
    public private(set) var isStreamStalled = false

    /// When the current stall was detected (`nil` while live) — drives the scrim's frame-age caption
    /// ("RECONNECTING · 12S"). Set/cleared together with ``isStreamStalled``.
    public private(set) var streamStalledAt: Date?

    /// Records a stall flip from the live view. Only writes the observable on a real change.
    public func noteStreamStalled(_ stalled: Bool) {
        guard isStreamStalled != stalled else { return }
        isStreamStalled = stalled
        streamStalledAt = stalled ? Date() : nil
    }

    /// Request an ABSOLUTE host-window POINT size from the "Resize…" popover (no-op when no sink is wired —
    /// not streaming or read-only). The host clamps to the window's achievable min/max and re-anchors at its
    /// display origin so an up-to-display-max size takes.
    public func resizeWindow(toWidth width: Double, height: Double) {
        resizeInjector?(width, height)
    }

    /// VIEWPORT CONTROLS (client-side zoom + pan-lock): the live video pane publishes this once its
    /// session exists (cleared `nil` on teardown). The bottom control bar zooms the actual-size video sublayer
    /// and freezes the edge-hover auto-pan. These are pure CLIENT compositor ops (never touch the host), so —
    /// UNLIKE ``resizeInjector`` — the sink is NOT withheld while read-only. The argument is a raw command byte
    /// (``ViewportCommand``); the `UInt8` keeps the app-target pane view decoupled from this module.
    ///
    /// Re-asserts ``viewportLocked`` on every publish: a detach/reattach re-binds the SAME model to a FRESH
    /// view (which always starts unlocked), so the model — the lock's source of truth — pushes the lock back
    /// down the new sink. The lock commands are ABSOLUTE (`lockOn`/`lockOff`) precisely so this re-assert is
    /// idempotent (a toggle would flip a still-mounted view's state on a redundant re-publish).
    public var viewportInjector: ((_ command: UInt8) -> Void)? {
        didSet {
            if viewportLocked, let inject = viewportInjector {
                inject(ViewportCommand.lockOn.rawValue)
            }
        }
    }

    /// Whether the footer viewport controls (zoom / lock) are live: streaming AND a viewport sink is wired.
    public var canControlViewport: Bool { active != nil && viewportInjector != nil }

    /// The client-viewport commands carried by ``viewportInjector`` as their raw `UInt8` (the structural-byte
    /// contract shared with the app-target pane view, which switches on the same values).
    public enum ViewportCommand: UInt8, Sendable {
        case zoomIn = 0
        case zoomOut = 1
        case reset = 2
        case lockOn = 3
        case lockOff = 4
        case fitToPane = 5
    }

    /// Drive one client-viewport ``ViewportCommand`` through the live ``viewportInjector`` (no-op when no sink).
    public func sendViewport(_ command: ViewportCommand) { viewportInjector?(command.rawValue) }

    /// "LOCK POSITION" — whether the edge-hover auto-pan is frozen. The MODEL owns this state (the footer
    /// lock icon, the ⌥⌘L chord, and the palette all read/flip ONE place); the view's freeze mirrors it via
    /// the absolute `lockOn`/`lockOff` commands, re-asserted on every sink publish (see ``viewportInjector``).
    public private(set) var viewportLocked = false

    /// Toggle the viewport position lock (the ⌥⌘L chord / footer lock button / palette verb). Gated on
    /// ``canControlViewport`` so an off-stream flip can't strand a lock the view never saw — a graceful
    /// no-op, like the other video verbs.
    public func toggleViewportLock() {
        guard canControlViewport else { return }
        viewportLocked.toggle()
        sendViewport(viewportLocked ? .lockOn : .lockOff)
        notifyModesChanged()
    }

    /// RELEASE STUCK INPUT (the manual escape hatch): a zero-arg closure the live video pane publishes
    /// once its session exists (via ``RemotePaneContext/onInputReleaseReady``; cleared `nil` on teardown,
    /// WITHHELD by the seam while read-only — it sends host input). Firing it synthesizes a key-UP for every
    /// held modifier + a mouse-UP for every button through the existing synthetic-release paths, clearing a
    /// modifier/button the host was left holding despite the automatic redundancy+dedup (e.g. every release
    /// datagram of a burst lost).
    public var inputReleaseInjector: (() -> Void)?

    /// Whether the palette's "Release Stuck Input" can act right now: streaming AND a live release sink
    /// is wired (withheld while read-only).
    public var canReleaseStuckInput: Bool { active != nil && inputReleaseInjector != nil }

    /// Fire the manual stuck-input release (no-op when no sink is wired — not streaming / read-only).
    public func releaseStuckInput() { inputReleaseInjector?() }

    /// Whether a paste-as-keystrokes is possible right now: streaming AND a live key sink is wired. A
    /// read-only pane has no sink (the seam withholds it, see ``keyInjector``), so this is `false` there.
    public var canPasteKeystrokes: Bool { active != nil && keyInjector != nil }

    /// The in-flight paste (cancelled if a new one starts or the pane tears down).
    private var pasteTask: Task<Void, Never>?
    /// Per-character pacing — slow enough that a secure field's focus/IME keeps up, fast enough to
    /// feel instant for a password. Injectable for deterministic tests (`.zero`).
    private let pasteInterval: Duration

    /// Transient "typed N, skipped M" result of the last paste — set only when some characters had NO
    /// US-QWERTY mapping (accents / emoji / non-Latin) and were dropped, so the user learns the paste was
    /// incomplete. Auto-clears after ``pasteFeedbackDuration``; `nil` when the last paste mapped cleanly. The
    /// payload is never stored.
    public struct PasteFeedback: Sendable, Equatable {
        public var typed: Int
        public var skipped: Int
    }

    public private(set) var pasteFeedback: PasteFeedback?
    @ObservationIgnored private var pasteFeedbackTask: Task<Void, Never>?
    private let pasteFeedbackDuration: Duration

    /// Replays `text` as individual key events over the live ``keyInjector`` (US-QWERTY; unmappable
    /// characters are skipped). Down+up per stroke, Shift folded into both edges, paced by
    /// ``pasteInterval``. NEVER logs the payload — it is frequently a password. No-op when no sink is
    /// wired or the text is empty. Returns the encode result so the caller can surface "skipped N".
    @discardableResult
    public func pasteAsKeystrokes(_ text: String) -> KeystrokeReplay.Encoded {
        let encoded = KeystrokeReplay.encode(text)
        // No sink → nothing was attempted, so nothing to report.
        guard keyInjector != nil else { return encoded }
        // Surface "typed N, skipped M" when characters were dropped — BEFORE the empty-strokes return, so
        // an ALL-unmappable paste (typed 0, skipped N) still tells the user nothing was sent.
        notePasteFeedback(typed: encoded.strokes.count, skipped: encoded.skipped)
        guard !encoded.strokes.isEmpty else { return encoded }
        pasteTask?.cancel()
        let interval = pasteInterval
        let strokes = encoded.strokes
        pasteTask = Task { @MainActor [weak self] in
            for stroke in strokes {
                if Task.isCancelled { return }
                // READ-ONLY GATE: re-read the LIVE sink each iteration, not a value captured at
                // spawn. If the seam clears `keyInjector` mid-paste (pane switched to read-only), the remaining
                // strokes are withheld — keystrokes stop reaching the host (incl. a secure field) the instant
                // the lock lands, not at the end of the paste.
                guard let injector = self?.keyInjector else { return }
                injector(stroke.keyCode, true, stroke.shift)
                injector(stroke.keyCode, false, stroke.shift)
                if interval > .zero { try? await Task.sleep(for: interval) }
            }
        }
        return encoded
    }

    /// Records the transient paste feedback when characters were dropped, and schedules its auto-clear.
    /// A CLEAN paste clears any STALE banner from a prior skipped paste rather than letting it time out.
    private func notePasteFeedback(typed: Int, skipped: Int) {
        guard skipped > 0 else { dismissPasteFeedback()
            return
        }
        pasteFeedback = PasteFeedback(typed: typed, skipped: skipped)
        pasteFeedbackTask?.cancel()
        let d = pasteFeedbackDuration
        pasteFeedbackTask = Task { @MainActor [weak self] in
            if d > .zero { try? await Task.sleep(for: d) }
            if !Task.isCancelled { self?.pasteFeedback = nil }
        }
    }

    /// Dismisses the paste feedback (tap-to-dismiss / a new clean paste need not wait out the timer).
    public func dismissPasteFeedback() {
        pasteFeedbackTask?.cancel()
        pasteFeedback = nil
    }

    @preconcurrency
    public init(
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
        windowID: String = "",
        title: String = "Remote window",
        appName: String = "",
        desktopDisplayID: UInt32? = nil,
        pasteInterval: Duration = .milliseconds(6),
        pasteFeedbackDuration: Duration = .seconds(5),
    ) {
        self.target = target
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.desktopDisplayID = desktopDisplayID
        self.pasteInterval = pasteInterval
        self.pasteFeedbackDuration = pasteFeedbackDuration
    }

    /// The entered window id, as ``RemoteWindowRules/parseWindowID(_:)`` reads it — Swift's own
    /// `UInt32(_:)` over Swift's own `CharacterSet.whitespaces`, spelled out one language over.
    var parsedWindowID: UInt32? { RemoteWindowRules.parseWindowID(windowID) }

    /// Whether the model can open. A DESKTOP target always can (the display id is fixed at init);
    /// a window target needs a valid entered window id (host + UDP ports come from the app target).
    public var canOpen: Bool { desktopDisplayID != nil || parsedWindowID != nil }

    /// Builds the descriptor from the app target (host + UDP ports) + the target (the fixed display
    /// for a desktop pane, else the entered window id) and marks it active (the panel then brings up
    /// the live video pane). No-op if a window target's id is invalid.
    public func open() {
        let t = target()
        loadError = nil
        if let did = desktopDisplayID {
            active = RemoteWindowDescriptor(
                title: title,
                windowID: 0,
                displayID: did,
                host: t.host,
                mediaPort: t.mediaPort,
                cursorPort: t.cursorPort,
            )
            onEndpointCommitted?(VideoEndpoint(windowID: 0, title: title, displayID: did))
            return
        }
        guard let wid = parsedWindowID else { return }
        let named = RemoteWindowRules.descriptorTitle(title, windowID: wid)
        active = RemoteWindowDescriptor(
            title: named,
            appName: appName,
            windowID: wid,
            host: t.host,
            mediaPort: t.mediaPort,
            cursorPort: t.cursorPort,
        )
        // PANE REBIND: persist the now-live binding (app+title travel with the id so a future
        // restore can re-resolve it). Fired on every open — a re-pick updates the spec too.
        onEndpointCommitted?(VideoEndpoint(windowID: wid, title: named, appName: appName))
    }

    // MARK: Resize-reflow scrim signal (generic with the terminal pane)

    /// TRUE from the instant this pane is resized until the host re-captures at the new size and the first
    /// SHARP frame renders — the video analogue of ``TerminalViewModel/awaitingResizeReflow``. The pane
    /// resize-scrim (``PaneContainer``) waits on it so the overlay BRIDGES the gap during which the Metal
    /// view shows the last frame STRETCHED/upscaled (blurry) before re-captured pixels arrive — instead of
    /// clearing on a fixed settle timer that uncovers the blur early. The live video pane drives it:
    /// ``noteResized()`` on a layout-size change (prompts the 1:1 host re-capture), ``noteRendered()`` on the
    /// first frame at the new native size. A safety timeout + ``close()`` clear it so it can never stick.
    /// (The live-video pane mount is deferred — see ``PaneContainer`` — so this seam is test-exercised today.)
    public private(set) var awaitingResizeReflow = false

    /// Belt-and-braces ceiling on ``awaitingResizeReflow`` (mirrors the terminal model): clears the scrim
    /// even if the host never re-captures (a frozen window, a dropped UDP flow). Instance-settable so
    /// tests drive it without real-time waits.
    @ObservationIgnored var reflowScrimTimeout: Duration = .milliseconds(1200)
    @ObservationIgnored private let reflowDeadline = DeadlineLatch()

    /// The pane was resized (a layout-size change that will prompt a host re-capture at the new native
    /// size) — arm the resize scrim until the first re-captured frame lands. (Re)starts the safety
    /// timeout. Idempotent-safe to call per layout pass during a live drag — each call just re-arms.
    public func noteResized() {
        awaitingResizeReflow = true
        reflowDeadline.arm(after: reflowScrimTimeout) { [weak self] in self?.endAwaitingReflow() }
    }

    /// The first frame at the new native size rendered (the host re-capture caught up) — release the
    /// resize scrim. Idempotent + cheap when not awaiting.
    public func noteRendered() { endAwaitingReflow() }

    /// Clears ``awaitingResizeReflow`` + cancels the safety timeout. Idempotent — the observable is only
    /// written when it actually changes.
    private func endAwaitingReflow() {
        reflowDeadline.cancel()
        if awaitingResizeReflow { awaitingResizeReflow = false }
    }

    /// TERMINAL REFUSAL: the host REJECTED the live session (`helloAck(accepted: false)` — the target is
    /// gone on the host / version mismatch, incl. the mux mint-failure refusal). The video pipeline has
    /// already torn itself down WITHOUT the bye path's auto-rebuild (a rebuild would re-hello the same
    /// doomed request forever), so the pane must not keep a dead black surface: drop ``active`` (the pane
    /// falls back to its placeholder) and record ``loadError``. No-op when nothing is active (a late/
    /// duplicate refusal after a user close must not stamp an error onto a fresh pane).
    public func noteSessionRejected() {
        guard active != nil else { return }
        let sentence = RemoteWindowRules.rejectionMessage(title: title)
        close()
        loadError = sentence
    }

    /// Closes the remote window (tears down the live view → its orchestrator `stop()`).
    public func close() {
        active = nil
        pasteTask?.cancel() // a torn-down pane must not keep injecting a paste-in-flight into the host
        endAwaitingReflow() // a closed window will not re-capture — never leave the scrim hung
        isStreamStalled = false // a closed pane shows the picker, not a stale "Reconnecting…" scrim
        audioStreamEnabled = false // the next session mints with audio OFF — keep the speaker honest
        privacyEnabled = false // the next session mints un-blanked — keep the shield honest
        activeUploads.removeAll() // a re-bound window starts with no stale drag-drop progress rows
        viewportLocked = false // ditto for the viewport lock — a freshly (re)bound window starts unlocked
        // Ditto for the stream overrides — without this a cap set on window A would re-assert itself
        // (via `streamSettingsInjector`'s didSet) onto an unrelated window B re-bound on the SAME model.
        // RUNTIME resets only: none of these fire `onModesChanged` — the persisted spec keeps the user's
        // last explicit toggles so a relaunch (whose teardown routes through here) still restores them.
        // `immersiveDesired` deliberately survives (see its doc — the tap itself outlives a close as a
        // suspension, so the wish must too).
        streamFpsCap = 0
        streamBitrateCeilingBps = 0
        // The titlebar/sidebar connection cluster (`ConnectionTelemetry`) reads these unconditionally — a
        // closed/re-bound pane must not keep showing the LAST session's cadence/bitrate/network numbers as
        // if it were still streaming.
        streamFps = nil
        streamKbps = nil
        statsFps = nil
        statsFecPerSec = nil
        statsUnrecoveredPerSec = nil
        statsHoldMs = nil
        statsPacerDepth = nil
        statsRttMs = nil
        statsEncodeMs = nil
        statsDecodeMs = nil
        windowPointSize = nil
        windowMaxPointSize = nil
        // Drop every published sink HERE — the model's own lifecycle, not the view's dismantle. The old
        // view's `deactivate()` deliberately publishes NOTHING (both halves — see the `deactivate()` on
        // `MacVideoWindowView` and on the phone's `VideoWindowView`, which agree here): during a
        // pane detach/reattach the SAME model is re-bound by a view in ANOTHER hosting root, and SwiftUI may
        // dismantle the old view AFTER the new one published fresh sinks — an unconditional nil-publish
        // there would silently kill the new surface's input. close() always precedes the re-open in store
        // order, so clearing here is race-free.
        keyInjector = nil
        resizeInjector = nil
        viewportInjector = nil
        inputReleaseInjector = nil
        streamSettingsInjector = nil
        audioInjector = nil
        privacyInjector = nil
        systemKeyInjector = nil
    }

    // MARK: Display switcher (desktop pane)

    /// The host's online displays, fetched by ``refreshDisplays()`` — the desktop pane's
    /// display-switcher menu. Empty until fetched / when discovery is unavailable.
    public private(set) var availableDisplays: [RemoteDisplaySummary] = []

    /// Queries the host's display list via the ``RemoteDisplayDiscovery`` seam (session-less, same
    /// transient-lane discipline as the window picker). Best-effort: no seam / timeout leaves the
    /// previous list standing. A no-op for a window-target pane (no display to switch).
    public func refreshDisplays() async {
        guard desktopDisplayID != nil, let query = RemoteDisplayDiscovery.shared else { return }
        let t = target()
        let displays = await query(t.host, t.mediaPort, t.cursorPort)
        guard !displays.isEmpty else { return }
        availableDisplays = displays
    }

    /// Re-targets a DESKTOP pane at another host display: tears the current session down and re-hellos
    /// at `displayID` (`open()` re-commits the endpoint, so the new target persists to the pane spec).
    /// No-op for a window-target pane or when already streaming that display.
    public func switchDisplay(to displayID: UInt32) {
        guard desktopDisplayID != nil, desktopDisplayID != displayID else { return }
        close()
        desktopDisplayID = displayID
        open()
    }
}

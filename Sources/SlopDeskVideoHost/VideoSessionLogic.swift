import Foundation
import SlopDeskVideoProtocol

// Pure, platform-free session logic for the host video orchestrator. NO
// ScreenCaptureKit / VideoToolbox / Network, so it's unit-testable in isolation.
// The actor in `SlopDeskVideoHostSession.swift` owns the live components and
// delegates every decision to these pure types.

/// Lifecycle state of a host video session.
public enum VideoSessionState: Equatable, Sendable {
    /// Sockets not yet bound; nothing flowing.
    case idle
    /// Sockets bound, awaiting the client `hello`.
    case listening
    /// `hello` accepted; capture/encode running, media flowing.
    case streaming
    /// `stop()` (or `bye`) ran; terminal.
    case stopped
}

/// The pure state machine driving a host video session. It validates the client
/// `hello`, decides the `helloAck`, and gates whether media may flow — with NO live
/// component. The actor advances it and acts on the returned ``Effect``s.
public struct VideoSessionStateMachine: Sendable {
    public private(set) var state: VideoSessionState = .idle

    /// Negotiated capture dimensions, set once the hello is accepted.
    public private(set) var captureWidth: UInt16 = 0
    public private(set) var captureHeight: UInt16 = 0
    /// The window (or, for a full-desktop session, the display) the accepted session is remoting.
    public private(set) var windowID: UInt32 = 0
    /// Whether the accepted session targets a whole DISPLAY (`helloDisplay`) rather than a window.
    /// Duplicate-hello re-acks match on (id, kind) so a window hello can never re-ack a display
    /// session; an in-session `resizeRequest` is rejected for a display target (the display never
    /// resizes — the client letterboxes).
    public private(set) var isDisplayTarget = false

    /// The monotonically increasing stream id handed to the client on accept (lets a
    /// reconnecting client distinguish a fresh session).
    private var nextStreamID: UInt32

    /// Whether this host encodes FULL-RANGE luma. Stamped into every accepted `helloAck` (and
    /// into the duplicate re-ack, which MUST echo the same value) so the client derives the
    /// decoder pixel-format + shader coefficients. A reject always sends `fullRange: false`;
    /// the default (false) keeps the stream in video-range.
    public let fullRange: Bool

    public init(nextStreamID: UInt32 = 1, fullRange: Bool = false) {
        self.nextStreamID = nextStreamID
        self.fullRange = fullRange
    }

    /// Side effects the actor must perform after a transition.
    public enum Effect: Equatable, Sendable {
        /// Send this control message back to the client.
        case sendControl(VideoControlMessage)
        /// Bring up capture + encode for `windowID` at the negotiated dimensions.
        case startCapture(windowID: UInt32, width: UInt16, height: UInt16)
        /// Tear down capture + encode.
        case stopCapture
        /// Re-size the LIVE capture/encode of the streaming window to the clamped
        /// dimensions for the request carrying `epoch`. The actor performs the AX
        /// resize + `SCStream.updateConfiguration` + encoder reconfigure and replies
        /// with `resizeAck`. Does NOT mint a new streamID — same session, only the
        /// capture geometry changes.
        case resizeCapture(width: UInt16, height: UInt16, epoch: UInt32)
        /// Apply the client's LIVE stream-settings overrides (wire `streamSettings`) to the running
        /// session: an encode fps CAP and a bitrate CEILING, `0` = auto (clear that override). The
        /// values ride RAW — the actor clamps on apply (``UserStreamSettingsPolicy``) and actuates
        /// through the same paths a governed fps step / ABR tick takes.
        case applyStreamSettings(fpsCap: UInt8, bitrateCeilingBps: UInt32)
        /// Apply the client's audio wish (wire `audioControl`) to the running session — the
        /// `applyStreamSettings` twin for the audio lane: ON opens the capture→encode→send gate
        /// for the host's app audio (media channel tag 6), OFF drops captured `.audio` buffers
        /// before encode (capture config never changes). Per-session HOST state, reset to OFF on
        /// `.startCapture`; the client re-sends its wish after every accepted (re-)hello.
        case applyAudioControl(enabled: Bool)
    }

    /// The highest resize epoch already APPLIED for the current streaming session, so a
    /// stale/duplicate `resizeRequest` (UDP may reorder/duplicate) is dropped. Reset
    /// implicitly per session via ``SizeNegotiation/isStaleEpoch(_:lastApplied:)``;
    /// 0 ⇒ none applied yet (the first request, epoch ≥ 1, always wins).
    public private(set) var lastResizeEpoch: UInt32 = 0

    /// `start()` was called: bind sockets, wait for the client hello.
    public mutating func start() -> [Effect] {
        guard state == .idle else { return [] }
        state = .listening
        return []
    }

    /// A control datagram arrived. Returns the effects (helloAck + startCapture on a
    /// valid hello; stopCapture on bye). An invalid/duplicate hello is rejected.
    ///
    /// - Parameters:
    ///   - message: the decoded control message.
    ///   - windowBoundsCG: the live window bounds to report in the ack (the SM just
    ///     forwards what the actor read from the geometry watcher).
    ///   - resolveCaptureSize: maps the client viewport → the capture size the host will
    ///     use (the actor clamps to the real window). `nil` rejects the session.
    ///   - resolveResizeSize: maps an in-session `resizeRequest`'s desired size (for the
    ///     streaming `windowID`) → the clamped capture size to adopt (the actor runs
    ///     ``SizeNegotiation/clamp(desired:min:max:)`` against the live window min/max).
    ///     `nil` rejects the resize (window gone / out of policy) so capture stays put.
    ///     Defaulted so hello/bye-only call sites need not supply it.
    public mutating func handleControl(
        _ message: VideoControlMessage,
        windowBoundsCG: VideoRect,
        resolveCaptureSize: (_ requestedWindowID: UInt32, _ viewport: VideoSize) -> (UInt16, UInt16)?,
        resolveResizeSize: (_ windowID: UInt32, _ desired: VideoSize) -> (UInt16, UInt16)? = { _, _ in nil },
        resolveDisplayCaptureSize: (_ requestedDisplayID: UInt32, _ viewport: VideoSize) -> (UInt16, UInt16)? =
            { _, _ in nil },
    ) -> [Effect] {
        switch message {
        case let .hello(version, requestedWindowID, viewport):
            return acceptHello(
                version: version, targetID: requestedWindowID, displayTarget: false,
                viewport: viewport, windowBoundsCG: windowBoundsCG, resolve: resolveCaptureSize,
            )
        case let .helloDisplay(version, requestedDisplayID, viewport):
            // The full-desktop sibling of `.hello`: same version check / duplicate re-ack / accept
            // shape, resolved through the DISPLAY closure (nil-by-default — a window session never
            // accepts a display hello).
            return acceptHello(
                version: version, targetID: requestedDisplayID, displayTarget: true,
                viewport: viewport, windowBoundsCG: windowBoundsCG, resolve: resolveDisplayCaptureSize,
            )
        case .bye:
            // A client bye re-arms the session so a fresh hello can reconnect WITHOUT a daemon
            // restart: return to .listening and stop capture only if it was streaming. The next
            // hello mints a fresh streamID + re-resolves capture size, so a re-accepted session is
            // fully re-initialised. (Local stop() — which also closes the UDP sockets — stays
            // terminal .stopped, NOT re-armable.)
            let wasStreaming = state == .streaming
            guard state == .streaming || state == .listening else { return [] }
            state = .listening
            return wasStreaming ? [.stopCapture] : []
        case let .resizeRequest(desired, epoch):
            // In-session resize: accept ONLY while streaming (listening/stopped has no live
            // capture to re-size). A stale/dup epoch (≤ last applied) is dropped so a UDP
            // reorder/retransmit can't shrink-then-grow out of order; a burst coalesces to
            // the highest-epoch (settled) request. A DISPLAY target never resizes (the client
            // letterboxes; its state machine doesn't send these — this is the defensive half).
            guard state == .streaming, !isDisplayTarget else { return [] }
            guard !SizeNegotiation.isStaleEpoch(epoch, lastApplied: lastResizeEpoch) else { return [] }
            // The closure clamps `desired` against the LIVE window (min/max) for the
            // session's `windowID`; `nil` ⇒ wrong/gone window or out-of-policy → reject
            // (capture stays put, epoch NOT advanced so a later valid request still wins).
            guard let (w, h) = resolveResizeSize(windowID, desired) else { return [] }
            lastResizeEpoch = epoch
            captureWidth = w
            captureHeight = h
            // Same session (same streamID, same window) — only the capture geometry
            // changes. The actor performs the live resize and sends the resizeAck.
            return [.resizeCapture(width: w, height: h, epoch: epoch)]
        case let .streamSettings(fpsCap, bitrateCeilingBps):
            // Live stream controls apply only to a STREAMING session (there is no capture/encoder
            // to actuate otherwise, and the client re-sends after every accepted hello, so a
            // pre-stream message is never load-bearing). Values ride raw — the ACTOR clamps on
            // apply (fps 5…120, bitrate 500 kbps…200 Mbps; 0 = restore auto).
            guard state == .streaming else { return [] }
            return [.applyStreamSettings(fpsCap: fpsCap, bitrateCeilingBps: bitrateCeilingBps)]
        case let .audioControl(enabled):
            // The `streamSettings` twin: only a STREAMING session has an audio lane to gate, and
            // the client re-sends its wish after every accepted hello, so a pre-stream message is
            // never load-bearing.
            guard state == .streaming else { return [] }
            return [.applyAudioControl(enabled: enabled)]
        case .helloAck,
             .resizeAck,
             .streamCadence:
            // Host never receives a helloAck/resizeAck/streamCadence (all host→client) — defensive no-op.
            return []
        case .keepalive,
             .focusWindow:
            // `keepalive` carries NO state-machine semantics — its only effect is the
            // transport-level `lastInbound` stamp the reaper reads. `focusWindow` is actioned at
            // the ACTOR level (``SlopDeskVideoHostSession/handleControl`` raises the captured
            // window) with no SM/capture-state effect. Both are no-ops here.
            return []
        case .listWindows,
             .windowList,
             .listSystemDialogs,
             .systemDialogList,
             .scrollOffset,
             .contentMask,
             .displayMax,
             .windowFeedSubscribe,
             .windowFeedSnapshot,
             .windowFeedCurrent,
             .appIconRequest,
             .blobChunk,
             .windowPreviewRequest,
             .listDisplays,
             .displayList:
            // Window-list, system-dialog-list, window-feed AND icon discovery are answered at the
            // DAEMON level (session-less, no capture mint) and never reach a session's state machine.
            // `windowList`/`systemDialogList`/`scrollOffset`/`contentMask`/`displayMax`/
            // `windowFeedSnapshot`/`windowFeedCurrent`/`blobChunk` are host→client and never arrive
            // at the host. No-op.
            return []
        }
    }

    /// The shared hello-accept path for BOTH target kinds (`.hello` = window, `.helloDisplay` =
    /// display): strict version check, duplicate re-ack while streaming (matched on id AND kind),
    /// resolve-or-reject, then accept with a fresh streamID + a `.startCapture` effect (the actor
    /// knows its own target — the effect's id is informational).
    private mutating func acceptHello(
        version: UInt16,
        targetID: UInt32,
        displayTarget: Bool,
        viewport: VideoSize,
        windowBoundsCG: VideoRect,
        resolve: (_ targetID: UInt32, _ viewport: VideoSize) -> (UInt16, UInt16)?,
    ) -> [Effect] {
        // Strict version check — no fallback (doc 20 §4 discipline).
        guard version == SlopDeskVideoProtocol.version else {
            return [rejectAck(windowBoundsCG: windowBoundsCG)]
        }
        // Only accept a hello while listening; ignore a duplicate once streaming
        // (idempotent — the client may retransmit the unreliable hello).
        guard state == .listening else {
            if state == .streaming, targetID == windowID, displayTarget == isDisplayTarget {
                // Re-ack an in-flight duplicate so a lost ack is recovered, but do
                // NOT restart capture.
                return [.sendControl(.helloAck(
                    accepted: true,
                    streamID: lastStreamID,
                    captureWidth: captureWidth,
                    captureHeight: captureHeight,
                    windowBoundsCG: windowBoundsCG,
                    fullRange: fullRange,
                ))]
            }
            return []
        }
        guard let (w, h) = resolve(targetID, viewport) else {
            return [rejectAck(windowBoundsCG: windowBoundsCG)]
        }
        let streamID = nextStreamID
        nextStreamID &+= 1
        lastStreamID = streamID
        captureWidth = w
        captureHeight = h
        windowID = targetID
        isDisplayTarget = displayTarget
        // Reset the resize epoch for the FRESH session. A reconnecting client mints
        // epochs from 1 again (its `ResizeDebounce` is per-connection); a stale
        // `lastResizeEpoch` from the PRIOR session (e.g. 7) would make every new epoch
        // look stale (≤ 7) and drop its first resizes. Re-arm to 0 so the new session's
        // first request (epoch ≥ 1) wins.
        lastResizeEpoch = 0
        state = .streaming
        return [
            .sendControl(.helloAck(
                accepted: true,
                streamID: streamID,
                captureWidth: w,
                captureHeight: h,
                windowBoundsCG: windowBoundsCG,
                fullRange: fullRange,
            )),
            .startCapture(windowID: targetID, width: w, height: h),
        ]
    }

    private func rejectAck(windowBoundsCG: VideoRect) -> Effect {
        .sendControl(.helloAck(
            accepted: false,
            streamID: 0,
            captureWidth: 0,
            captureHeight: 0,
            windowBoundsCG: windowBoundsCG,
            fullRange: false,
        ))
    }

    /// `stop()` was called locally.
    public mutating func stop() -> [Effect] {
        guard state != .stopped else { return [] }
        let wasStreaming = state == .streaming
        state = .stopped
        return wasStreaming ? [.stopCapture] : []
    }

    /// Whether media (video/geometry/cursor) is allowed to flow right now.
    public var mediaFlowing: Bool { state == .streaming }

    private var lastStreamID: UInt32 = 0
}

/// Pure host-side size negotiation for the in-session resize feature (the platform-free
/// mirror of the `resolveCaptureSize` clamp in `SlopDeskVideoHostSession`): turns a client
/// `resizeRequest`'s desired size into the UInt16 capture dimensions the host adopts,
/// clamped to the host's allowed `min`/`max` window size and rounded to a UInt16-safe int
/// that is NEVER zero (a zero-dimension SCStream/encoder config is invalid). No
/// ScreenCaptureKit / AX, so the clamp + epoch ordering are unit-testable in isolation.
public enum SizeNegotiation {
    /// Clamps `desired` into `[min, max]` per axis and rounds to a UInt16-safe, non-zero
    /// integer. Identity (within rounding) when `desired` is already inside the bounds.
    ///
    /// Mirrors the actor's hello clamp (`UInt16(max(1, min(Double(UInt16.max), v.rounded())))`)
    /// but bounded by the host's min/max policy rather than a single window size. The min is
    /// floored at 1 and the max ceilinged at `UInt16.max` so a degenerate (zero / out-of-range)
    /// policy can never yield 0 or overflow.
    public static func clamp(desired: VideoSize, min minSize: VideoSize, max maxSize: VideoSize) -> (UInt16, UInt16) {
        (
            clampAxis(desired.width, min: minSize.width, max: maxSize.width),
            clampAxis(desired.height, min: minSize.height, max: maxSize.height),
        )
    }

    private static func clampAxis(_ value: Double, min lo: Double, max hi: Double) -> UInt16 {
        // Floor the lower bound at 1 and ceiling the upper at UInt16.max, then order them
        // (a swapped/degenerate policy must still clamp into a valid window).
        let loC = Swift.max(1.0, Swift.min(lo.rounded(), Double(UInt16.max)))
        let hiC = Swift.max(1.0, Swift.min(hi.rounded(), Double(UInt16.max)))
        let lower = Swift.min(loC, hiC)
        let upper = Swift.max(loC, hiC)
        // NaN/non-finite desired collapses to the lower bound (never 0, never a trap).
        let v = value.isFinite ? value.rounded() : lower
        let clamped = Swift.min(Swift.max(v, lower), upper)
        return UInt16(clamped)
    }

    /// Whether `epoch` is stale relative to the last APPLIED epoch — a value `<=`
    /// `lastApplied` (a duplicate or out-of-order/older request) must be ignored so a UDP
    /// reorder/retransmit cannot un-settle the coalesced size. The first request of a
    /// session (any `epoch >= 1` against `lastApplied == 0`) is therefore NOT stale.
    public static func isStaleEpoch(_ epoch: UInt32, lastApplied: UInt32) -> Bool {
        epoch <= lastApplied
    }
}

/// Pure clamp + composition policy for the client's `streamSettings` overrides (wire type 25) —
/// the host-side half of the validate-then-drop contract: the DECODER rejects only malformed
/// length, and the semantics clamp HERE at apply time. Kept beside ``SizeNegotiation`` so the
/// clamps and the fps composition are unit-testable without a capturer/encoder.
public enum UserStreamSettingsPolicy {
    /// The host accepts a user fps cap only inside this band: below 5 the stream is a slideshow
    /// (and a hostile 1 fps request would starve recovery); above 120 exceeds every panel the
    /// client drives.
    public static let fpsCapRange = 5...120
    /// The host accepts a user bitrate ceiling only inside this band: below 500 kbps the encoder
    /// starves even at QP ceiling; 200 Mbps is past any realistic LAN provision.
    public static let bitrateCeilingRange = 500_000...200_000_000

    /// Maps the wire fps-cap byte to the applied override: `0` ⇒ `nil` (auto), else clamped into
    /// ``fpsCapRange``.
    public static func fpsCap(fromWire raw: UInt8) -> Int? {
        guard raw != 0 else { return nil }
        return Swift.min(fpsCapRange.upperBound, Swift.max(fpsCapRange.lowerBound, Int(raw)))
    }

    /// Maps the wire bitrate-ceiling field to the applied override: `0` ⇒ `nil` (auto), else
    /// clamped into ``bitrateCeilingRange``.
    public static func bitrateCeiling(fromWire raw: UInt32) -> Int? {
        guard raw != 0 else { return nil }
        return Swift.min(bitrateCeilingRange.upperBound, Swift.max(bitrateCeilingRange.lowerBound, Int(raw)))
    }

    /// The encode cadence actually in force: the governor's output (or the base fps when the
    /// governor is off) clamped by the user cap. `nil` cap ⇒ exactly `governed`, so with no
    /// override every actuation is byte-identical to today's.
    public static func effectiveFps(governed: Int, userCap: Int?) -> Int {
        guard let userCap else { return governed }
        return Swift.min(governed, userCap)
    }
}

/// Routes a datagram received on the input channel. Pure decision logic: parse the
/// ``InputEvent`` and decide whether it should be injected (and any reordering /
/// gating policy). Kept separate so the routing decision is testable without an
/// `InputInjector` (which posts real CGEvents).
public struct InputDatagramRouter: Sendable {
    public init() {}

    /// The decision for one received input datagram.
    public enum Decision: Equatable, Sendable {
        /// Inject this event. `raiseFirst` is true when the window must be raised +
        /// focused before posting (the first event of an interaction / any pointer
        /// button-down — doc 18 §A activate-then-control).
        case inject(InputEvent, raiseFirst: Bool)
        /// Drop a malformed/undecodable datagram (a corrupt single packet must never
        /// crash the receiver — same contract as the reassembler).
        case drop(reason: String)
        /// Ignore the datagram because the session is not streaming.
        case ignoreNotStreaming
    }

    /// Decides what to do with one raw input datagram.
    ///
    /// - Parameters:
    ///   - datagram: the raw input-channel bytes.
    ///   - mediaFlowing: whether the session is in `.streaming`.
    ///   - needsRaise: whether the next injected event should raise+focus first. The
    ///     caller (actor) tracks this: true on the first event, and re-armed after a
    ///     mouse-up so a fresh click sequence re-raises (a pointer button-down always
    ///     raises; pure moves/keys/scrolls/text do not, to avoid focus thrash).
    public func route(datagram: Data, mediaFlowing: Bool, needsRaise: Bool) -> Decision {
        guard mediaFlowing else { return .ignoreNotStreaming }
        let event: InputEvent
        do {
            event = try InputEvent.decode(datagram)
        } catch {
            return .drop(reason: "undecodable input datagram")
        }
        let raiseFirst = Self.raiseFirst(for: event, needsRaise: needsRaise)
        return .inject(event, raiseFirst: raiseFirst)
    }

    /// A pointer button-down always raises+focuses the target first (doc 18 §A); pure
    /// moves / scrolls / keys / text do not, to avoid yanking focus on every keystroke.
    public static func alwaysRaises(_ event: InputEvent) -> Bool {
        if case .mouseDown = event { return true }
        return false
    }

    /// After injecting `event`, whether the NEXT event should be forced to raise.
    /// A mouse-up ends an interaction, so the next event re-raises; otherwise the
    /// raise latch is cleared once any event has been injected.
    public static func rearmRaiseAfter(_ event: InputEvent) -> Bool {
        if case .mouseUp = event { return true }
        return false
    }

    /// Whether `event` is EXEMPT from the armed raise latch. A scroll is dispatched by the window
    /// server to the window UNDER THE CURSOR regardless of key focus, so it never needs the
    /// (expensive: ~6–10 synchronous AX IPC round-trips) re-raise — even when the post-click latch
    /// is armed by ``rearmRaiseAfter(_:)``. Without the exemption a click-a-pane-then-scroll gesture
    /// pays a full AX raise on that first scroll and the scroll feels delayed. A `mouseDown` still
    /// always raises (``alwaysRaises(_:)``); a key/text with the latch armed still raises (needs key
    /// focus). An exempt scroll does NOT satisfy `raiseFirst`, so the actor never clears the latch on
    /// it and a key arriving AFTER the scroll still re-raises.
    public static func latchExemptFromRaise(_ event: InputEvent) -> Bool {
        if case .scroll = event { return true }
        return false
    }

    /// The single pure rule the live consumer (``SlopDeskVideoHostSession`` `injectCoalesced`) and
    /// ``route(datagram:mediaFlowing:needsRaise:)`` share: should `event` raise+focus the target
    /// window before injection, given the current latch. A `mouseDown` always raises; otherwise the
    /// armed latch raises everything EXCEPT a latch-exempt scroll.
    public static func raiseFirst(for event: InputEvent, needsRaise: Bool) -> Bool {
        (needsRaise && !latchExemptFromRaise(event)) || alwaysRaises(event)
    }
}

/// Pure policy for the host's activate-then-control window raise. The injector's
/// `raiseTargetWindow()` runs ~6–10 SYNCHRONOUS cross-process Accessibility IPC calls (each capped
/// at the 0.25 s messaging timeout) that the input consumer AWAITS before the click is posted, so
/// paying the full chain on EVERY click of an already-frontmost window is the dominant felt input
/// latency. This decides, from a CHEAP non-AX frontmost-app read, whether the full AX raise is
/// actually needed. Pure ⇒ headlessly testable without AX/TCC.
public enum InputInjectorRaisePolicy {
    /// Whether to run the full AX raise chain. Skips it ONLY when the target app is ALREADY frontmost
    /// AND this is not the first interaction (the first interaction always raises, to set
    /// `kAXMainWindow`/`kAXFocusedWindow` so keystrokes land on the right window even when the app is
    /// already frontmost). Errs toward raising on any uncertainty — a `nil` frontmost read or a
    /// different frontmost app — so activate-then-control correctness is never weakened.
    public static func shouldRaise(frontmostPID: pid_t?, targetPID: pid_t, firstInteraction: Bool) -> Bool {
        if firstInteraction { return true }
        guard let frontmostPID else { return true } // unknown frontmost → raise to be safe
        return frontmostPID != targetPID
    }
}

/// Pure button-balance bookkeeping for input injection (testable WITHOUT CGEvents).
///
/// The ordered inbound consumer keeps a single interaction's down→drag→up in order, but cannot
/// conjure a `mouseUp` the wire DROPPED or a flaky gesture never sent. A target app that got a
/// `mouseDown` with no matching `mouseUp` stays stuck mid-selection, so the NEXT click lands inside
/// an already-started selection. This tracks which buttons are logically HELD so a fresh
/// `mouseDown` for an already-held button emits a synthetic release FIRST — a click never begins
/// inside a stuck selection. Only down/up mutate the held set; moves/drags/scroll/text pass
/// through. MODIFIER key edges get the same idempotence via ``heldModifierKeys`` — the client's
/// redundant modifier key-up burst collapses to one post; ordinary keys and Caps Lock pass through.
///
/// The held set is keyed on ``MouseButton`` (a `UInt8`-backed enum, left=0/right=1/other=2), the
/// SINGLE SOURCE OF TRUTH for the fold — only `mouseDown`/`mouseUp` mutate it. A value `struct`
/// (`Sendable, Equatable`): the lone live owner (``InputInjector``) serializes every `plan(for:)`
/// under its `balanceLock` and the golden-parity tests fold it on one thread, so the by-value held
/// set is never raced.
public struct InputButtonBalance: Sendable, Equatable {
    /// The logically-held buttons (keyed on ``MouseButton``; the golden-parity tests read
    /// `held.contains` / `held.isEmpty` / `held`).
    public private(set) var held: Set<MouseButton> = []
    /// The logically-held MODIFIER keys (keyed on the exact keyCode — left/right variants are
    /// distinct latched flags). The client sends a modifier key-UP redundantly (a lost release
    /// latches the modifier on the shared `hidSystemState` source until the user re-presses it); this
    /// set collapses that burst to ONE posted CGEvent, like `held` does for mouse ups. Only
    /// ``InputModifierKeys/heldModifierKeyCodes`` enter it — ordinary keys (auto-repeat as identical
    /// downs) and the Caps Lock toggle pass through verbatim.
    public private(set) var heldModifierKeys: Set<UInt16> = []
    public init() {}

    /// What to do before injecting `event`.
    public struct Plan: Equatable, Sendable {
        /// Emit a synthetic release of THIS button before the real event (`nil` ⇒ none). Set
        /// only when a `mouseDown` arrives for a button still marked held (a lost up).
        public var preRelease: MouseButton?
        /// SUPPRESS the event entirely — do NOT post it. Set for a `mouseUp` whose button is
        /// NOT held: a duplicate of the client's loss-resilient 3× `mouseUp` (the first up
        /// already released it) or an up with no matching down. Posting it would be a spurious
        /// extra `*MouseUp` into the target app (breaks the double-click coalescer / custom
        /// WebKit/Electron tracking). This makes the wire redundancy idempotent on the host:
        /// the FIRST up of the burst posts, the rest are dropped.
        public var suppress: Bool
        public init(preRelease: MouseButton? = nil, suppress: Bool = false) {
            self.preRelease = preRelease
            self.suppress = suppress
        }
    }

    /// Folds `event` into the held set and returns the injection plan. A `mouseDown` for an
    /// already-held button asks for a pre-release (then stays held — the fresh down owns it);
    /// a `mouseUp` for a HELD button releases it (post it); a `mouseUp` for a button NOT held
    /// is a redundant/duplicate up and is SUPPRESSED; everything else passes through.
    public mutating func plan(for event: InputEvent) -> Plan {
        switch event {
        case let .mouseDown(button, _, _, _, _):
            let stuck = held.contains(button)
            held.insert(button)
            return Plan(preRelease: stuck ? button : nil)
        case let .mouseUp(button, _, _, _, _):
            if held.remove(button) != nil {
                return Plan() // first up for a held button — release it
            }
            return Plan(suppress: true) // duplicate / orphan up — drop it (idempotent)
        case let .key(keyCode, down, _, _):
            // MODIFIER dedup: the client's redundant modifier key-up burst must post ONCE.
            // Ordinary keys (auto-repeat = identical downs) and Caps Lock (a toggle — state keyed on
            // down/up would desync from the host's actual Caps state) pass through untouched.
            guard InputModifierKeys.isHeldModifier(keyCode) else { return Plan() }
            if down {
                // A down for an already-down modifier (refocus resync vs a still-latched host flag)
                // is a no-op — the latched flag is already correct.
                return Plan(suppress: !heldModifierKeys.insert(keyCode).inserted)
            }
            if heldModifierKeys.remove(keyCode) != nil {
                return Plan() // first up for a held modifier — release it
            }
            return Plan(suppress: true) // duplicate / orphan modifier up — drop it (idempotent)
        case .mouseMove,
             .mouseDrag,
             .scroll,
             .text:
            return Plan()
        }
    }
}

/// Pure, order-preserving pointer-motion coalescer.
///
/// A remote pointer stream is ~99% motion: a real loopback trace carries 1664 `mouseMove` +
/// 163 `mouseDrag` against only 11 `mouseDown` (≈150:1). The host injects every event behind
/// synchronous WindowServer IPC (`CGWarpMouseCursorPosition` +
/// `CGAssociateMouseAndMouseCursorPosition` + `CGEvent.post`, three round-trips), so when the
/// serial inbound consumer falls behind a flood it replays every STALE intermediate position in
/// FIFO order — the cursor then crawls through old positions seconds behind the user.
///
/// This collapses each RUN of consecutive same-class motion events to its LATEST — the only
/// position that still matters (a hover/drag target is absolute) — while passing every button /
/// key / scroll / text event through UNCHANGED and NEVER reordering across one. Same latest-position
/// rule TigerVNC (`Viewport` deferred pointer flush) and noVNC (`_handleMouseMove` +
/// `_flushMouseMoveTimer`) use; here driven by drain-availability (the actor batch-drains the
/// inbound queue and coalesces what piled up) not a wall-clock timer, so it is SELF-REGULATING:
/// when the consumer keeps up the batches are size ~1 (no-op); only when it falls behind does a run
/// collapse, bounding the lag to ~one injection regardless of flood. Pure ⇒ headlessly unit-testable
/// beside ``InputButtonBalance`` / ``InputDatagramRouter`` (no CGEvent, no socket).
public struct InputMotionCoalescer: Sendable {
    /// A coalescible run key. Move/drag NEVER merge: a class change is a flush boundary, because a
    /// `.mouseDrag` carries a held button + clickState posted as `*MouseDragged` while a `.mouseMove`
    /// is a bare hover `*MouseMoved` — collapsing across the boundary would drop the transition the
    /// target app needs. SCROLL (only when `coalesceScroll`) is keyed by its phase signature so a
    /// `began`/`ended` singleton never merges into the `changed`/`momentum-continue` BULK run — only
    /// same-phase consecutive scroll events merge, by SUMMING their (additive) deltas.
    private enum RunKey: Equatable {
        case move
        case drag
        case scroll(phase: UInt8, momentum: UInt8, continuous: Bool)
    }

    private static func runKey(of event: InputEvent, coalesceScroll: Bool) -> RunKey? {
        switch event {
        case .mouseMove: .move
        case .mouseDrag: .drag
        case let .scroll(_, _, _, scrollPhase, momentumPhase, continuous, _):
            // A fast trackpad scroll + its OS momentum coast is a ~200/s flood; uncoalesced each
            // becomes one synchronous `CGEvent.post` → WindowServer saturation → SCStream capture
            // stalls (measured 61ms capture-gap / 1210ms send-gap → the reversal hitch).
            // Parsec/Sunshine (and macOS itself) downsample scroll to the refresh rate. When
            // enabled scroll is a coalescible class; OFF ⇒ `nil` ⇒ scroll stays a hard barrier.
            coalesceScroll
                ? .scroll(phase: scrollPhase, momentum: momentumPhase, continuous: continuous)
                : nil
        case .mouseDown,
             .mouseUp,
             .key,
             .text: nil
        }
    }

    /// Merge the current run's `pending` with the next same-key event. Move/drag keep the LATEST
    /// (absolute pointer position — older positions are superseded). Scroll SUMS dx/dy (scroll
    /// deltas are ADDITIVE, so summing preserves total travel) while keeping the newest cursor
    /// position + tag and the shared phase. This is the only safe scroll collapse: keep-latest
    /// would silently drop scrolled distance.
    private static func mergeRun(_ pending: InputEvent, _ next: InputEvent, key: RunKey) -> InputEvent {
        if case .scroll = key,
           case let .scroll(dx1, dy1, _, scrollPhase, momentumPhase, continuous, _) = pending,
           case let .scroll(dx2, dy2, norm2, _, _, _, tag2) = next
        {
            return .scroll(
                dx: dx1 + dx2,
                dy: dy1 + dy2,
                normalized: norm2,
                scrollPhase: scrollPhase,
                momentumPhase: momentumPhase,
                continuous: continuous,
                tag: tag2,
            )
        }
        return next // move/drag: keep the latest position
    }

    /// Collapse consecutive same-class motion runs in `batch` to their latest, preserving the
    /// relative order of every non-motion (barrier) event and of motion vs barriers.
    ///
    /// INVARIANT: a `.mouseDown`/`.mouseUp`/`.key`/`.scroll`/`.text` is a hard barrier — any
    /// buffered motion flushes BEFORE it, so a move that physically preceded a click is never
    /// emitted after the click. That keeps down→drag→up framing, ``InputButtonBalance``, and the
    /// stateless-drag contract intact (every down/up still reaches the injector exactly once, in
    /// order). `coalesceScroll` (default false ⇒ scroll stays a hard barrier) additionally
    /// collapses consecutive same-phase SCROLL runs by summing their deltas.
    public static func coalesce(_ batch: [InputEvent], coalesceScroll: Bool = false) -> [InputEvent] {
        guard batch.count > 1 else { return batch }
        var output: [InputEvent] = []
        output.reserveCapacity(batch.count)
        var pending: InputEvent? // the buffered (latest move/drag, or summed scroll) event in the run
        var pendingKey: RunKey? // its run key (nil ⇔ pending is nil)
        for event in batch {
            if let key = runKey(of: event, coalesceScroll: coalesceScroll) {
                if key == pendingKey, let p = pending {
                    pending = mergeRun(p, event, key: key) // same run: keep-latest (motion) or sum (scroll)
                } else {
                    if let p = pending { output.append(p) } // class/phase change: flush the old run
                    pending = event
                    pendingKey = key
                }
            } else {
                // Barrier: flush any buffered motion FIRST (order-preserving), then the barrier.
                if let p = pending { output.append(p)
                    pending = nil
                    pendingKey = nil
                }
                output.append(event)
            }
        }
        if let p = pending { output.append(p) } // trailing motion/scroll run
        return output
    }
}

/// Pure fold of the session actor's scroll-accumulating coalesced-inject pipeline (the stateful
/// half of `injectCoalesced`, extracted so its flush reachability is unit-testable).
///
/// Continuous-phase scroll deltas are SUMMED into a time-gated accumulator (held ACROSS runs) and
/// emitted ≤ once per `injectInterval`. Uncoalesced, the ~200/s `CGEvent` flood saturates the
/// WindowServer and stalls SCStream capture. A gesture boundary
/// (began/ended/wheel) or any non-scroll event flushes the accumulator FIRST, in order; a
/// trailing flush covers a run that ends mid-gesture. ``plan(run:now:)`` returns the exact
/// ordered events the actor must inject; the actor applies its raise latch per returned event,
/// so raise/button-balance semantics are untouched by the extraction. (`now` is sampled once per
/// run — runs fold in µs, far below the ms-scale gate, so per-event sampling is indistinguishable.)
public struct ScrollCoalescePlanner: Sendable {
    /// Only the high-frequency CONTINUOUS phases accumulate: `scrollPhase == changed(2)` (finger
    /// drag) or `momentumPhase == continue(2)` (inertial coast). began/ended/begin/end and
    /// discrete wheel (phase 0) are gesture boundaries — emitted immediately (after flushing any
    /// accumulator) so the gesture structure + total travel are exact.
    public static func isCoalescableScrollPhase(scrollPhase: UInt8, momentumPhase: UInt8) -> Bool {
        scrollPhase == 2 || momentumPhase == 2
    }

    private var accumDx: Double = 0
    private var accumDy: Double = 0
    /// Newest phase/normalized/tag template for the summed emit (`nil` ⇔ nothing accumulated).
    private var accumTemplate: InputEvent?
    private var lastInjectUptime: Double = 0
    private let injectInterval: Double
    private let coalesceScroll: Bool

    public init(injectInterval: Double, coalesceScroll: Bool) {
        self.injectInterval = injectInterval
        self.coalesceScroll = coalesceScroll
    }

    /// Whether a summed residual is currently held (drives the actor's idle-flush re-arm).
    public var hasPendingScroll: Bool { accumTemplate != nil }

    /// Folds one arrival-ordered `run` and returns the ordered events to inject NOW. Continuous
    /// scroll accumulates (emitted at most once per `injectInterval`); everything else passes
    /// through with any pending residual flushed FIRST (order-preserving).
    public mutating func plan(run: [InputEvent], now: Double) -> [InputEvent] {
        // NO empty-run early return: an empty run (a drain that carried only control/recovery
        // datagrams — e.g. the ~20/s netstats batches) must still reach the trailing flush below,
        // or a residual stranded by a LOST gesture-`ended` datagram waits for the next unrelated
        // input event.
        var out: [InputEvent] = []
        for event in InputMotionCoalescer.coalesce(run, coalesceScroll: coalesceScroll) {
            if coalesceScroll,
               case let .scroll(dx, dy, norm, scrollPhase, momentumPhase, continuous, tag) = event,
               Self.isCoalescableScrollPhase(scrollPhase: scrollPhase, momentumPhase: momentumPhase)
            {
                // PHASE-DOMAIN boundary: an on-glass changed(2) residual must never merge with a
                // momentum continue(2) delta — the summed emit carries ONE phase pair, so the
                // older domain's marker would be silently rewritten (on-glass travel replayed as
                // momentum). Unreachable in a complete gesture (ended/momentum-begin boundaries
                // flush between the domains); it exists for the DUAL-LOSS case where both those
                // datagrams drop on the fire-and-forget input channel. Flush like any boundary.
                if case let .scroll(_, _, _, heldPhase, heldMomentum, _, _) = accumTemplate,
                   heldPhase != scrollPhase || heldMomentum != momentumPhase
                {
                    appendPendingFlush(&out)
                }
                accumDx += dx
                accumDy += dy
                accumTemplate = .scroll(
                    dx: 0, dy: 0, normalized: norm,
                    scrollPhase: scrollPhase, momentumPhase: momentumPhase, continuous: continuous, tag: tag,
                )
                if now - lastInjectUptime >= injectInterval {
                    lastInjectUptime = now
                    appendPendingFlush(&out)
                }
                continue
            }
            // Gesture boundary / non-scroll: flush any accumulated scroll FIRST (order-preserving).
            appendPendingFlush(&out)
            out.append(event)
        }
        // Trailing flush: if continuous scroll ended this run without a boundary event, don't strand
        // the residual past the gate — but only flush when the gate has elapsed (else hold for the
        // next run to keep the ≤1/interval cap; the next scroll or a boundary will flush it).
        if accumTemplate != nil, now - lastInjectUptime >= injectInterval {
            lastInjectUptime = now
            appendPendingFlush(&out)
        }
        return out
    }

    /// Drops any pending residual WITHOUT emitting it (media teardown: a stale gesture tail must
    /// not leak into the next session).
    public mutating func clearPending() {
        accumDx = 0
        accumDy = 0
        accumTemplate = nil
    }

    /// Emits the accumulated (summed) scroll as one event, then clears the accumulator. No-op when
    /// nothing is buffered. Preserves total scroll travel (deltas are additive).
    private mutating func appendPendingFlush(_ out: inout [InputEvent]) {
        guard case let .scroll(_, _, norm, scrollPhase, momentumPhase, continuous, tag) = accumTemplate
        else { return }
        out.append(.scroll(
            dx: accumDx, dy: accumDy, normalized: norm,
            scrollPhase: scrollPhase, momentumPhase: momentumPhase, continuous: continuous, tag: tag,
        ))
        accumDx = 0
        accumDy = 0
        accumTemplate = nil
    }
}

/// Routes a datagram received on the DEDICATED recovery channel (client→host loss
/// recovery, doc 17 §3.6). Pure decision logic: decode the ``RecoveryMessage`` and
/// decide the host action. Kept separate from ``InputDatagramRouter`` because recovery
/// and input share neither a channel nor a wire grammar — `RecoveryMessage`'s leading
/// type bytes (1/2/3) overlap `InputEvent`'s, which is exactly why they must NOT share
/// the `.input` channel. Testable without an encoder/capturer.
public struct RecoveryDatagramRouter: Sendable {
    public init() {}

    /// The decision for one received recovery datagram.
    public enum Decision: Equatable, Sendable {
        /// Force an IDR keyframe on the next captured frame. This is the GUARANTEED-recovery
        /// escalation (`requestIDR`): a true keyframe unconditionally re-anchors a desynced client.
        /// Kept distinct from ``refreshLTR`` so the escalation can never degrade to an LTR refresh.
        /// Carries the client's decode frontier (`nil` ⇔ wire sentinel "nothing decoded yet") for
        /// the actor's delivery-keyed `RecoveryIDRPolicy`.
        case forceKeyframe(lastDecodedFrameID: UInt32?)
        /// The client requested an LTR refresh (`requestLTRRefresh`). The ACTOR decides at
        /// runtime — via ``LTRController/recoveryDecision(request:hasEnableLTR:)`` — whether to issue a
        /// cheap `ForceLTRRefresh` (only when `SLOPDESK_LTR` is on AND a token has been acknowledged: the
        /// ACKED-ONLY invariant) or fall back to a real IDR. With LTR off this folds to
        /// `requestKeyframe()`, i.e. requestLTRRefresh→IDR. Carries the client's decode frontier
        /// like ``forceKeyframe(lastDecodedFrameID:)`` — consumed ONLY by the `.idr` fallback path
        /// (an LTR refresh is never policy-gated).
        case refreshLTR(lastDecodedFrameID: UInt32?)
        /// A durable-receipt ack: the host may advance its retransmit/LTR-pin window.
        /// No live effect yet (no retransmit buffer); recorded for the docs/escalation.
        case ack(streamSeq: UInt32)
        /// Re-ship the cursor SHAPE bitmap for `shapeID` — a self-heal for a client that is missing
        /// it (its one-shot shape datagram was lost / over-MTU). The actor asks the
        /// ``CursorSampler`` to re-emit that shape on the cursor socket; the client cache
        /// re-insert is idempotent.
        case reshipCursorShape(shapeID: UInt16)
        /// A periodic client network-feedback report (loss/FEC counters + host-send-ts echo +
        /// client hold + jitter). The actor folds it into its ``NetworkEstimate`` and logs it;
        /// nothing changes stream behaviour off the back of it.
        case networkStats(NetworkStatsReport)
        /// NACK / selective ARQ: the client is missing specific DATA fragments of `frameID` and asks
        /// the host to retransmit them. The actor looks each up by `(frameID, fragIndex)` in its
        /// send-history ring and re-enqueues the original datagrams — cheaper than a recovery-IDR and
        /// it arrives inside the client's playout buffer. A ring miss (frame aged out) is a no-op; the
        /// client's Dropped→LTR-refresh path is still the fallback once the retransmit-grace expires.
        case retransmitFragments(frameID: UInt32, fragIndices: [UInt16])
        /// Drop a malformed/undecodable datagram (a corrupt single packet must never
        /// crash the receiver — same contract as the reassembler).
        case drop(reason: String)
        /// Ignore because the session is not streaming.
        case ignoreNotStreaming
    }

    /// Decides what to do with one raw recovery datagram.
    ///
    /// A non-streaming session ignores the datagram before any decode; an undecodable datagram
    /// drops (a corrupt single packet must never crash the receiver — same contract as the
    /// reassembler); otherwise the decoded ``RecoveryMessage`` maps to its ``Decision``. The
    /// guaranteed-recovery escalation (`requestIDR`) is ALWAYS a real `forceKeyframe` and can never
    /// degrade to an LTR refresh; the wire sentinel (``RecoveryMessage/noFrameDecodedSentinel``)
    /// maps to a clean `nil` decode frontier. Recovery rides its OWN channel — its leading type
    /// bytes (1/2/3) alias ``InputEvent``, so this must never be fed the input grammar.
    public func route(datagram: Data, mediaFlowing: Bool) -> Decision {
        guard mediaFlowing else { return .ignoreNotStreaming }
        let message: RecoveryMessage
        do {
            message = try RecoveryMessage.decode(datagram)
        } catch {
            return .drop(reason: "undecodable recovery datagram")
        }
        switch message {
        case let .requestIDR(lastDecoded):
            // The guaranteed-recovery escalation: ALWAYS a real IDR (a keyframe unconditionally
            // re-anchors a client that lost frames). Never an LTR refresh. The wire sentinel
            // ("nothing decoded yet") maps to nil here so the actor's policy gets a clean Optional.
            return .forceKeyframe(lastDecodedFrameID:
                lastDecoded == RecoveryMessage.noFrameDecodedSentinel ? nil : lastDecoded)
        case let .requestLTRRefresh(_, _, lastDecoded):
            // Defer the LTR-refresh-vs-IDR choice to the actor (it owns the runtime acked-token
            // state + the SLOPDESK_LTR gate). With LTR off the actor folds this to a real IDR.
            // Same sentinel→nil mapping as `.requestIDR`.
            return .refreshLTR(lastDecodedFrameID:
                lastDecoded == RecoveryMessage.noFrameDecodedSentinel ? nil : lastDecoded)
        case let .ack(streamSeq):
            return .ack(streamSeq: streamSeq)
        case let .requestCursorShape(shapeID):
            return .reshipCursorShape(shapeID: shapeID)
        case let .networkStats(report):
            return .networkStats(report)
        case let .requestFragments(frameID, fragIndices):
            // NACK / selective ARQ: the client is missing specific DATA fragments of `frameID`. The
            // actor looks each up by `(frameID, fragIndex)` in its send-history ring and re-enqueues
            // the originals; a ring miss is a no-op. NOT a forced keyframe — cheaper than a recovery-IDR.
            return .retransmitFragments(frameID: frameID, fragIndices: fragIndices)
        }
    }
}

/// Pure, host-clock-only network estimate folded from the client's periodic ``NetworkStatsReport``
/// (the network-feedback channel). NO wall-clock and NO I/O (timestamps are injected as parameters),
/// so the RTT / loss / OWD-gradient math is deterministic and headlessly unit-testable.
///
/// ⚠️ CLOCK-SKEW DISCIPLINE (the central trap): RTT is computed ENTIRELY in the host's own clock —
/// `(hostNow − latestHostSendTs) − clientHoldMs`, where `latestHostSendTs` is the host's OWN stamp
/// echoed back and `clientHoldMs` is a client-LOCAL relative delta. The two machine clocks are NEVER
/// subtracted from each other, so there is zero cross-machine offset in the result. The jitter term
/// is computed client-side from 2nd-order inter-arrival differences (also skew-immune) and only
/// FOLDED here.
public struct NetworkEstimate: Sendable, Equatable {
    /// EWMA-smoothed RTT (ms). 0 until the first valid sample folds.
    public private(set) var smoothedRTTMillis: Double = 0
    /// Windowed minimum RTT (ms) — the path's no-queue baseline. `.infinity` until the first sample.
    public private(set) var minRTTMillis: Double = .infinity
    /// EWMA loss rate in [0, 1] (unrecovered / framesReceived per report). For logging / telemetry
    /// trend only — the controller does NOT key its decrease on this (see ``lastLossSample``).
    public private(set) var lossRate: Double = 0
    /// RAW per-report loss fraction from the MOST RECENT fold (unrecovered / framesReceived), in [0, 1].
    /// Unlike ``lossRate`` (EWMA-damped, alpha 0.125) this is the INSTANTANEOUS sample, so a clean
    /// report reads 0 even while the EWMA tail of a prior spike is still decaying above threshold.
    /// ``LiveCongestionController`` keys its multiplicative decrease on THIS, so a single transient
    /// loss spike causes exactly ONE decrease — not a multi-report cascade driven by the slowly-decaying
    /// EWMA re-tripping the threshold on subsequent perfectly-clean reports.
    public private(set) var lastLossSample: Double = 0
    /// Whether the most recent OWD-jitter sample rose vs the previous (a congestion-onset hint).
    public private(set) var owdGradientRising: Bool = false
    /// The client trendline detector read OVERUSING on the most recent report — monotone delay
    /// growth over a full regression window, sustained past the adaptive threshold. THIS, not
    /// `owdGradientRising` (a 2-sample coin flip), is the gradient signal
    /// ``LiveCongestionController``'s early-cut path consumes.
    public private(set) var owdTrendOverusing = false
    /// The detector's modified trend (ms-of-delay per ms, ×scale ×gain) from the most recent report
    /// — logging/diagnostics only.
    public private(set) var owdTrendModified: Double = 0
    /// The RAW (un-smoothed) RTT sample of the MOST RECENT fold — the gradient cut's fresh LEVEL
    /// corroboration (the queue NOW, no EWMA lag, no streak). EXPLICITLY `nil` when that report's
    /// sample was rejected (freshness contract: corroboration may only use THIS report's evidence).
    public private(set) var lastRTTSampleMillis: Double?

    /// Last folded jitter sample (µs) for the rising-trend comparison.
    private var lastOWDJitterMicros: UInt32 = 0
    /// How many reports have been folded (warms up the gradient so the first sample doesn't spike).
    private var sampleCount: Int = 0

    public init() {}

    /// EWMA weight on a fresh RTT sample (0.125 → 7/8 history, RFC6298-style).
    public static let rttAlpha: Double = 0.125
    /// EWMA weight on a fresh loss sample.
    public static let lossAlpha: Double = 0.125
    /// Slow re-baseline factor for `minRTTMillis` so a transient low sample doesn't pin it forever
    /// (the baseline drifts up by this fraction of the gap each fold when the new sample is higher).
    public static let minRTTDecay: Double = 0.01
    /// RTT samples above this (ms) are implausible — dropped rather than poisoning the EWMA.
    public static let maxPlausibleRTTMillis = 60000

    /// PURE wrap-safe host-clock RTT (ms), or `nil` to REJECT the sample. Total over all `UInt32`
    /// inputs — the `Int32(bitPattern:)` subtraction cannot trap. Rejects when telemetry is off
    /// (`latestHostSendTs == 0`), the stamp is in the future (`elapsed < 0` — e.g. a stale stamp
    /// from a prior session after an actor re-create), the hold exceeds the elapsed (`rtt < 0`), or
    /// the result is implausibly large (`> maxPlausibleRTTMillis`).
    public static func computeRTTMillis(hostNowMs: UInt32, latestHostSendTs: UInt32, clientHoldMs: UInt32) -> Int? {
        guard latestHostSendTs != 0 else { return nil }
        // Wrap-aware delta, same trick as UInt32.distanceWrapped (FrameReassembler): a counter that
        // wrapped between stamp and now still yields the correct small positive elapsed.
        let elapsed = Int(Int32(bitPattern: hostNowMs &- latestHostSendTs))
        guard elapsed >= 0 else { return nil }
        let rtt = elapsed - Int(clientHoldMs)
        guard rtt >= 0, rtt <= maxPlausibleRTTMillis else { return nil }
        return rtt
    }

    /// Folds one report. `rttMillis == nil` (rejected by ``computeRTTMillis``) skips the RTT/min-RTT
    /// update but still folds loss + jitter (so disabling the RTT loop never blinds the rest).
    /// The trend params are DEFAULTED so a caller with no trend data (and the tests) folds
    /// unchanged — state 0 reads "normal" and the gradient fields stay inert.
    public mutating func fold(
        rttMillis: Int?,
        framesReceived: UInt32,
        unrecovered: UInt32,
        owdJitterMicros: UInt32,
        owdTrendState: UInt8 = 0,
        owdTrendModifiedMilli: Int32 = 0,
    ) {
        // Freshness contract (gradient corroboration): the raw sample is per-fold, nil on reject.
        lastRTTSampleMillis = rttMillis.map(Double.init)
        owdTrendOverusing = owdTrendState == 1
        owdTrendModified = Double(owdTrendModifiedMilli) / 1000
        if let rtt = rttMillis {
            let sample = Double(rtt)
            // keep mul+add separate — FMA breaks bit-exact parity
            smoothedRTTMillis = smoothedRTTMillis == 0 ? sample :
                (smoothedRTTMillis * (1 - Self.rttAlpha) + sample * Self.rttAlpha)
            if sample < minRTTMillis {
                minRTTMillis = sample
            } else if minRTTMillis.isFinite {
                // Slow re-baseline so a one-off low doesn't pin the baseline below the real path RTT.
                // keep mul+add separate — FMA breaks bit-exact parity
                minRTTMillis += (sample - minRTTMillis) * Self.minRTTDecay
            }
        }
        // Loss rate: guard divide-by-zero (a report with 0 frames received contributes a 0 sample).
        let lossSample = framesReceived > 0 ? Double(unrecovered) / Double(framesReceived) : 0
        lastLossSample = lossSample
        // keep mul+add separate — FMA breaks bit-exact parity
        lossRate = lossRate * (1 - Self.lossAlpha) + lossSample * Self.lossAlpha
        // OWD gradient: only meaningful after a short warmup (the first sample has no predecessor).
        if sampleCount >= 2 {
            owdGradientRising = owdJitterMicros > lastOWDJitterMicros
        }
        lastOWDJitterMicros = owdJitterMicros
        sampleCount += 1
    }
}

/// Pure decider for the static-window forced-IDR heartbeat. Holds the cadence anchors and answers:
/// "given the clock and what was last encoded, should the frameQueue timer re-encode the cached
/// buffer as a forced IDR right now?". No I/O — the caller owns the retained buffer, the timer, and
/// the encode. The methods are called only on the capture `frameQueue` (single-threaded), so the
/// single instance is never raced.
///
/// The policy is pure and headlessly unit-testable (injected `now`) while the side effects (retain,
/// timer, encode) stay thin in `WindowCapturer`. The capture path calls ``onCompleteFrame(now:)`` on
/// every real frame; the timer calls ``shouldReencode(now:forcedLatched:hasRetainedBuffer:)`` then
/// ``recordSynthetic(now:)`` when it fires.
///
/// A `final class`, not a value struct, so the cadence anchors mutate through the shared reference
/// held by ``WindowCapturer`` without rippling `let`→`var` through every call site.
/// `@unchecked Sendable` is sound because the single owner only touches it on `frameQueue` (and the
/// loopback/tests from one thread), so no two threads race the state. `Equatable` compares the four
/// observable anchors; used only by the golden-parity sanity test.
public final class StaticIDRDecider: @unchecked Sendable, Equatable {
    /// Heartbeat cadence (seconds). Mirrors `WindowCapturer.heartbeatIDRInterval` (1.0).
    public let heartbeat: TimeInterval
    /// Quiet window (seconds): suppress a synthetic re-encode if a REAL `.complete` frame
    /// was encoded within this window — a live screen drives IDRs through the normal path,
    /// so the timer must not double-emit. Default = heartbeat (one cadence).
    public let quietWindow: TimeInterval

    /// Uptime seconds of the last REAL `.complete`-frame encode (live path). 0 = none yet.
    public private(set) var lastCompleteEncode: TimeInterval = 0
    /// Uptime seconds of the last SYNTHETIC (timer-driven cached) re-encode. 0 = none yet.
    public private(set) var lastSyntheticEncode: TimeInterval = 0

    public init(heartbeat: TimeInterval, quietWindow: TimeInterval? = nil) {
        self.heartbeat = heartbeat
        self.quietWindow = quietWindow ?? heartbeat
    }

    /// The capture path encoded a REAL frame at `now`. Re-anchors the live clock so the
    /// timer stays quiet while the screen is live, and a heartbeat measures from the last
    /// real frame.
    public func onCompleteFrame(now: TimeInterval) {
        lastCompleteEncode = now
    }

    /// The timer fired a synthetic re-encode at `now`. Re-anchor the synthetic clock.
    public func recordSynthetic(now: TimeInterval) {
        lastSyntheticEncode = now
    }

    /// Decision for a frameQueue timer tick. PURE (no mutation).
    /// - `forcedLatched`: a client recovery/keyframe request is pending (drained by caller).
    /// - `hasRetainedBuffer`: a cached `.complete` pixel buffer exists to re-encode.
    /// Returns true iff the caller should re-encode the cached buffer as a forced IDR.
    public func shouldReencode(now: TimeInterval, forcedLatched: Bool, hasRetainedBuffer: Bool) -> Bool {
        // No cached pixels ⇒ nothing to re-encode (e.g. before the first ever .complete frame).
        guard hasRetainedBuffer else { return false }
        // A real frame within the quiet window ⇒ the live path is (or just was) driving the
        // stream; let it own the cadence, don't double-emit. (A recovery request while live is
        // already serviced faster by the live `.complete` latch drain — the timer is the
        // fallback only when the live path has gone quiet, so the quiet window gates forced too.)
        let sinceComplete = now - lastCompleteEncode
        if lastCompleteEncode != 0, sinceComplete < quietWindow { return false }
        // Recovery request always wins once the live path is quiet (latency-critical: a client
        // is frozen). Fire regardless of heartbeat phase.
        if forcedLatched { return true }
        // Otherwise: heartbeat — measured from the last SYNTHETIC emission ONLY. Anchoring on
        // `max(lastComplete, lastSynthetic)` would make the first crisp re-anchor after a scroll
        // wait a full heartbeat even though the quiet window had long passed (Parsec re-sharpens in
        // ~1 s). Synthetic-only fires the first crisp as soon as the quiet window clears (~1 s after
        // motion stops), while steady-state static cadence stays one `heartbeat` apart.
        if lastSyntheticEncode == 0 { return true } // armed, none emitted yet, quiet ⇒ fire now
        return (now - lastSyntheticEncode) >= heartbeat
    }

    /// Value-equal iff all four observable anchors match; used only by the golden-parity sanity
    /// test, never in live control flow.
    public static func == (lhs: StaticIDRDecider, rhs: StaticIDRDecider) -> Bool {
        lhs.heartbeat == rhs.heartbeat && lhs.quietWindow == rhs.quietWindow
            && lhs.lastCompleteEncode == rhs.lastCompleteEncode
            && lhs.lastSyntheticEncode == rhs.lastSyntheticEncode
    }
}

/// Packet-scheduling policy for the host send loop: turns an encoded frame +
/// per-stream messages into the ordered list of datagrams to put on each channel.
/// Pure (no socket) so the ordering is testable. The actor feeds encoder output and
/// geometry/cursor messages through this and sends the result.
public struct VideoSendScheduler: Sendable {
    /// One scheduled datagram: the channel it belongs on and its encoded bytes.
    public struct Outgoing: Equatable, Sendable {
        public let channel: VideoChannel
        public let bytes: Data
        public init(channel: VideoChannel, bytes: Data) {
            self.channel = channel
            self.bytes = bytes
        }
    }

    public init() {}

    /// Schedules one encoded frame: packetize → ordered video datagrams. Data
    /// fragments precede parity (the packetizer already emits them in that order), so
    /// a client on a lossless link can decode without waiting for parity (doc 17 §3.6).
    public func scheduleFrame(_ fragments: [FrameFragment]) -> [Outgoing] {
        fragments.map { Outgoing(channel: .video, bytes: $0.encode()) }
    }

    /// Send-path fast path: wrap already-finished wire datagrams (from ``VideoPacketizer/packetizeRaw``)
    /// as `.video` outgoings WITHOUT the parse/re-encode round-trip. Same `.video` channel + byte order
    /// as ``scheduleFrame``; the datagram bytes are byte-identical to `fragment.encode()` (unit-pinned).
    public func scheduleFrameRaw(_ datagrams: [Data]) -> [Outgoing] {
        datagrams.map { Outgoing(channel: .video, bytes: $0) }
    }

    /// Schedules a geometry update on the geometry channel.
    public func scheduleGeometry(_ message: WindowGeometryMessage) -> Outgoing {
        Outgoing(channel: .geometry, bytes: message.encode())
    }

    /// Schedules a cursor message (position or shape) on the dedicated cursor socket.
    public func scheduleCursor(_ message: CursorChannelMessage) -> Outgoing {
        Outgoing(channel: .cursor, bytes: message.encode())
    }

    /// Schedules a control message.
    public func scheduleControl(_ message: VideoControlMessage) -> Outgoing {
        Outgoing(channel: .control, bytes: message.encode())
    }
}

import CSlopDeskFFI
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
///
/// A face over `rust/slopdesk-ffi`'s `session_state`, which is the other end of the handshake
/// `client_session` already answers. The machine crosses BY VALUE — nine scalars, all of them read
/// on this side, owned by an actor field Swift copies on every `mutating` call — and a transition
/// commits only once its answer fits, so measuring is never a second transition (`docs/55` §4b).
public struct VideoSessionStateMachine: Sendable {
    private var machine: SlopDeskVideoSessionMachine

    public init(nextStreamID: UInt32 = 1, fullRange: Bool = false) {
        machine = slopdesk_video_session_new(nextStreamID, fullRange)
    }

    /// Lifecycle state.
    public var state: VideoSessionState {
        switch machine.state {
        case UInt32(SLOPDESK_VIDEO_SESSION_LISTENING): .listening
        case UInt32(SLOPDESK_VIDEO_SESSION_STREAMING): .streaming
        case UInt32(SLOPDESK_VIDEO_SESSION_STOPPED): .stopped
        default: .idle
        }
    }

    /// Negotiated capture width, set once the hello is accepted.
    public var captureWidth: UInt16 { machine.capture_width }
    /// Negotiated capture height.
    public var captureHeight: UInt16 { machine.capture_height }
    /// The window (or, for a full-desktop session, the display) the accepted session is remoting.
    public var windowID: UInt32 { machine.window_id }
    /// Whether the accepted session targets a whole DISPLAY (`helloDisplay`) rather than a window.
    /// Duplicate-hello re-acks match on (id, kind) so a window hello can never re-ack a display
    /// session; an in-session `resizeRequest` is rejected for a display target (the display never
    /// resizes — the client letterboxes).
    public var isDisplayTarget: Bool { machine.is_display_target }
    /// The highest resize epoch already APPLIED for the current streaming session, so a
    /// stale/duplicate `resizeRequest` (UDP may reorder/duplicate) is dropped. 0 ⇒ none applied
    /// yet (the first request, epoch ≥ 1, always wins).
    public var lastResizeEpoch: UInt32 { machine.last_resize_epoch }
    /// Whether this host encodes FULL-RANGE luma. Stamped into every accepted `helloAck` (and
    /// into the duplicate re-ack, which MUST echo the same value) so the client derives the
    /// decoder pixel-format + shader coefficients. A reject always sends `fullRange: false`.
    public var fullRange: Bool { machine.full_range }
    /// Whether media (video/geometry/cursor) is allowed to flow right now.
    public var mediaFlowing: Bool { slopdesk_video_session_media_flowing(machine) }

    /// Side effects the actor must perform after a transition.
    public enum Effect: Equatable, Sendable {
        /// Send these already-encoded control bytes back to the client. The datagram crosses
        /// instead of the typed message because putting it on the control channel is the only
        /// thing the actor does with one — and the ack is then minted by the crate that parsed
        /// the hello it answers.
        case sendControl(Data)
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
        /// Apply the client's privacy-blank wish (wire `privacyMode`) — the `applyAudioControl`
        /// twin for a DISPLAY session: ON blacks the streamed host display (zero gamma) + swallows
        /// local host input; OFF restores both. Per-session HOST state, reset to OFF on
        /// `.startCapture`; the client re-sends its wish after every accepted (re-)hello. Emitted
        /// ONLY for a display target (a window/dialog session has no whole-display to blank).
        case applyPrivacyMode(enabled: Bool)
    }

    /// `start()` was called: bind sockets, wait for the client hello. Produces no effects.
    @discardableResult
    public mutating func start() -> [Effect] {
        slopdesk_video_session_start(&machine)
        return []
    }

    /// `stop()` was called locally, which is terminal — unlike a client `bye`, a later hello finds
    /// a stopped machine.
    public mutating func stop() -> [Effect] {
        step { machine, effects, effectsCap, arena, arenaCap in
            slopdesk_video_session_stop(machine, effects, effectsCap, arena, arenaCap)
        }
    }

    /// A control datagram arrived. Returns the effects (helloAck + startCapture on a
    /// valid hello; stopCapture on bye). An invalid/duplicate hello is rejected.
    ///
    /// The three resolvers stay HERE because each reads live AppKit state the law must not see;
    /// what crosses is the ANSWER one of them gave. Exactly one can matter per message — the
    /// message's own variant decides which — so this resolves that one eagerly and the law reads
    /// `nil` as the rejection its closure spelled. Resolving before the version check does at most
    /// a pure size read more work on a hello that is about to be refused.
    ///
    /// - Parameters:
    ///   - message: the decoded control message.
    ///   - windowBoundsCG: the live window bounds to report in the ack (the SM just
    ///     forwards what the actor read from the geometry watcher).
    ///   - resolveCaptureSize: maps the client viewport → the capture size the host will
    ///     use (the actor clamps to the real window). `nil` rejects the session.
    ///   - resolveResizeSize: maps an in-session `resizeRequest`'s desired size (for the
    ///     streaming `windowID`) → the clamped capture size to adopt. `nil` rejects the resize
    ///     (window gone / out of policy) so capture stays put.
    ///   - resolveDisplayCaptureSize: the full-desktop sibling — defaulted to a refusal, so a
    ///     window session can never accept a display hello.
    public mutating func handleControl(
        _ message: VideoControlMessage,
        windowBoundsCG: VideoRect,
        resolveCaptureSize: (_ requestedWindowID: UInt32, _ viewport: VideoSize) -> (UInt16, UInt16)?,
        resolveResizeSize: (_ windowID: UInt32, _ desired: VideoSize) -> (UInt16, UInt16)? = { _, _ in nil },
        resolveDisplayCaptureSize: (_ requestedDisplayID: UInt32, _ viewport: VideoSize) -> (UInt16, UInt16)? =
            { _, _ in nil },
    ) -> [Effect] {
        var capture = SlopDeskResolvedSize()
        var resize = SlopDeskResolvedSize()
        var display = SlopDeskResolvedSize()
        switch message {
        case let .hello(_, requestedWindowID, viewport):
            capture = Self.answer(resolveCaptureSize(requestedWindowID, viewport))
        case let .helloDisplay(_, requestedDisplayID, viewport):
            display = Self.answer(resolveDisplayCaptureSize(requestedDisplayID, viewport))
        case let .resizeRequest(desired, _):
            resize = Self.answer(resolveResizeSize(windowID, desired))
        default:
            break
        }
        let datagram = [UInt8](message.encode())
        let bounds = SlopDeskVideoRect(
            x: windowBoundsCG.origin.x, y: windowBoundsCG.origin.y,
            width: windowBoundsCG.size.width, height: windowBoundsCG.size.height,
        )
        return datagram.withUnsafeBufferPointer { control in
            step { machine, effects, effectsCap, arena, arenaCap in
                slopdesk_video_session_control(
                    machine, control.baseAddress, control.count, bounds, capture, resize, display,
                    effects, effectsCap, arena, arenaCap,
                )
            }
        }
    }

    /// One resolver's answer, where `nil` is the rejection.
    private static func answer(_ size: (UInt16, UInt16)?) -> SlopDeskResolvedSize {
        guard let size else { return SlopDeskResolvedSize() }
        return SlopDeskResolvedSize(width: size.0, height: size.1, resolved: true)
    }

    /// Runs one transition twice — once to measure, once to fill. The door steps a COPY and writes
    /// the machine back only when the answer fits, so the measuring call is not a transition and
    /// the second one is not a repeat.
    private mutating func step(
        _ door: (
            UnsafeMutablePointer<SlopDeskVideoSessionMachine>,
            UnsafeMutablePointer<SlopDeskVideoSessionEffect>?, Int,
            UnsafeMutablePointer<UInt8>?, Int,
        ) -> SlopDeskVideoSessionShape,
    ) -> [Effect] {
        let shape = door(&machine, nil, 0, nil, 0)
        guard shape.effects > 0 else { return [] }
        var records = [SlopDeskVideoSessionEffect](
            repeating: SlopDeskVideoSessionEffect(), count: shape.effects,
        )
        var arena = [UInt8](repeating: 0, count: shape.arena)
        let written = records.withUnsafeMutableBufferPointer { room in
            arena.withUnsafeMutableBufferPointer { pool in
                door(&machine, room.baseAddress, room.count, pool.baseAddress, pool.count)
            }
        }
        guard written.effects == shape.effects, written.arena == shape.arena else { return [] }
        return records.map { Self.effect($0, arena: arena) }
    }

    /// One crossed record as the effect the actor performs.
    private static func effect(_ record: SlopDeskVideoSessionEffect, arena: [UInt8]) -> Effect {
        switch record.kind {
        case UInt32(SLOPDESK_SESSION_EFFECT_START_CAPTURE):
            .startCapture(windowID: record.window_id, width: record.width, height: record.height)
        case UInt32(SLOPDESK_SESSION_EFFECT_STOP_CAPTURE):
            .stopCapture
        case UInt32(SLOPDESK_SESSION_EFFECT_RESIZE_CAPTURE):
            .resizeCapture(width: record.width, height: record.height, epoch: record.epoch)
        case UInt32(SLOPDESK_SESSION_EFFECT_APPLY_STREAM_SETTINGS):
            .applyStreamSettings(fpsCap: UInt8(truncatingIfNeeded: record.first), bitrateCeilingBps: record.second)
        case UInt32(SLOPDESK_SESSION_EFFECT_APPLY_AUDIO_CONTROL):
            .applyAudioControl(enabled: record.enabled)
        case UInt32(SLOPDESK_SESSION_EFFECT_APPLY_PRIVACY_MODE):
            .applyPrivacyMode(enabled: record.enabled)
        default:
            .sendControl(Data(arena[Int(record.control.offset)..<Int(record.control.offset + record.control.length)]))
        }
    }
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
        let answer = slopdesk_video_session_clamp_capture(size(desired), size(minSize), size(maxSize))
        return (answer.width, answer.height)
    }

    /// Whether `epoch` is stale relative to the last APPLIED epoch — a value `<=`
    /// `lastApplied` (a duplicate or out-of-order/older request) must be ignored so a UDP
    /// reorder/retransmit cannot un-settle the coalesced size. The first request of a
    /// session (any `epoch >= 1` against `lastApplied == 0`) is therefore NOT stale.
    ///
    /// The same rule ``VideoSessionStateMachine`` applies inside its resize transition, asked
    /// directly — the actor needs the answer for a resize it is about to actuate.
    public static func isStaleEpoch(_ epoch: UInt32, lastApplied: UInt32) -> Bool {
        slopdesk_video_session_stale_epoch(epoch, lastApplied)
    }

    /// One size as it crosses.
    private static func size(_ value: VideoSize) -> SlopDeskVideoSize {
        SlopDeskVideoSize(width: value.width, height: value.height)
    }
}

/// Pure clamp + composition policy for the client's `streamSettings` overrides (wire type 25) —
/// the host-side half of the validate-then-drop contract: the DECODER rejects only malformed
/// length, and the semantics clamp HERE at apply time. Kept beside ``SizeNegotiation`` so the
/// clamps and the fps composition are unit-testable without a capturer/encoder.
///
/// A face over `session_state`, which owns both accepted bands — the fps cap's (below its floor the
/// stream is a slideshow and a hostile request would starve recovery; above its ceiling exceeds
/// every panel the client drives) and the bitrate ceiling's (below the floor the encoder starves at
/// its coarsest quantiser; above it is past any realistic provision). Nothing on this side reads a
/// band, only the clamped answer, so the numbers never cross.
public enum UserStreamSettingsPolicy {
    /// Maps the wire fps-cap byte to the applied override: `0` ⇒ `nil` (auto), else clamped into
    /// the accepted band.
    public static func fpsCap(fromWire raw: UInt8) -> Int? {
        var cap = Int64(0)
        guard slopdesk_video_fps_cap_from_wire(raw, &cap) else { return nil }
        return Int(cap)
    }

    /// Maps the wire bitrate-ceiling field to the applied override: `0` ⇒ `nil` (auto), else
    /// clamped into the accepted band.
    public static func bitrateCeiling(fromWire raw: UInt32) -> Int? {
        var ceiling = Int64(0)
        guard slopdesk_video_bitrate_ceiling_from_wire(raw, &ceiling) else { return nil }
        return Int(ceiling)
    }

    /// The encode cadence actually in force: the governor's output (or the base fps when the
    /// governor is off) clamped by the user cap. `nil` cap ⇒ exactly `governed`, so with no
    /// override every actuation is byte-identical to today's.
    public static func effectiveFps(governed: Int, userCap: Int?) -> Int {
        Int(slopdesk_video_effective_fps(Int64(governed), userCap != nil, Int64(userCap ?? 0)))
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
        flags(for: event, needsRaise: false) & SLOPDESK_INPUT_RAISE_ALWAYS != 0
    }

    /// After injecting `event`, whether the NEXT event should be forced to raise.
    /// A mouse-up ends an interaction, so the next event re-raises; otherwise the
    /// raise latch is cleared once any event has been injected.
    public static func rearmRaiseAfter(_ event: InputEvent) -> Bool {
        flags(for: event, needsRaise: false) & SLOPDESK_INPUT_RAISE_REARM != 0
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
        flags(for: event, needsRaise: false) & SLOPDESK_INPUT_RAISE_LATCH_EXEMPT != 0
    }

    /// The single rule the live consumer (``SlopDeskVideoHostSession`` `injectCoalesced`) and
    /// ``route(datagram:mediaFlowing:needsRaise:)`` share: should `event` raise+focus the target
    /// window before injection, given the current latch. A `mouseDown` always raises; otherwise the
    /// armed latch raises everything EXCEPT a latch-exempt scroll.
    public static func raiseFirst(for event: InputEvent, needsRaise: Bool) -> Bool {
        flags(for: event, needsRaise: needsRaise) & SLOPDESK_INPUT_RAISE_FIRST != 0
    }

    /// The whole raise reading of one event, in one crossing. The four public predicates are four
    /// bits of it, so they can never disagree about which arm they were shown.
    private static func flags(for event: InputEvent, needsRaise: Bool) -> UInt32 {
        slopdesk_input_raise_flags(event.wire, needsRaise)
    }
}

/// The FACE of `slopdesk-video`'s button and modifier ledger — twelve bits, carried by value.
///
/// The ordered inbound consumer keeps a single interaction's down→drag→up in order, but cannot
/// conjure a `mouseUp` the wire DROPPED or a flaky gesture never sent. A target app that got a
/// `mouseDown` with no matching `mouseUp` stays stuck mid-selection, so the NEXT click lands inside
/// an already-started selection. The far side tracks which buttons are logically HELD so a fresh
/// `mouseDown` for an already-held button emits a synthetic release FIRST — a click never begins
/// inside a stuck selection. MODIFIER key edges get the same idempotence: the client's redundant
/// modifier key-up burst collapses to one post; ordinary keys and Caps Lock pass through.
///
/// A value `struct` (`Sendable, Equatable`) because that is what its owners want — ``InputInjector``
/// serializes every `plan(for:)` under its `balanceLock`, the session CARRIES one across a
/// reconnect, and the tests fold one on a thread of their own. So the state crosses BY VALUE too:
/// both domains are fixed (three buttons, nine modifier keycodes), which makes the whole ledger a
/// pair of masks and a handle the wrong shape — a handle these owners copied would be two ledgers
/// by the second copy (`docs/55` §4b).
public struct InputButtonBalance: Sendable, Equatable {
    /// The ledger itself, as the far side keeps it.
    private var state = SlopDeskInputBalance()

    /// The logically-held buttons (the golden-parity tests read `held.contains` / `held.isEmpty`).
    public var held: Set<MouseButton> {
        Set(MouseButton.allCases.filter { state.buttons & (1 << $0.rawValue) != 0 })
    }

    /// The logically-held MODIFIER keys (keyed on the exact keyCode — left/right variants are
    /// distinct latched flags). The bit is the key's POSITION in
    /// ``InputModifierKeys/heldModifierKeyCodes``, which is the far side's own table, so this reads
    /// the same order it was written in.
    public var heldModifierKeys: Set<UInt16> {
        let codes = InputModifierKeys.heldModifierKeyCodes.sorted()
        return Set(codes.enumerated().filter { state.modifiers & (1 << $0.offset) != 0 }.map(\.element))
    }

    public init() {}

    /// Seeds the ledger from the record the far side keeps it in — what an injector's
    /// `balanceSnapshot` answered, on its way into the replacement injector's `init(balance:)`.
    public init(_ state: SlopDeskInputBalance) {
        self.state = state
    }

    /// The ledger as it crosses: twelve bits, by value. There is no handle for it and there should
    /// not be — a handle these owners COPIED would be two ledgers by the second copy (`docs/55` §4b).
    public var wire: SlopDeskInputBalance { state }

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

    /// Folds `event` into the ledger and returns its injection plan.
    public mutating func plan(for event: InputEvent) -> Plan {
        let answer = slopdesk_input_balance_plan(state, event.wire)
        state = answer.state
        return Plan(
            preRelease: answer.has_pre_release ? MouseButton(rawValue: answer.pre_release) : nil,
            suppress: answer.suppress,
        )
    }

    /// Two ledgers are equal when they hold the same twelve bits — the C record the far side hands
    /// back has no equality of its own, and there is nothing else in this value to compare.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.buttons == rhs.state.buttons && lhs.state.modifiers == rhs.state.modifiers
    }
}

/// The FACE of `slopdesk-video`'s motion coalescer — order-preserving, and deciding nothing.
///
/// A remote pointer stream is ~99% motion: a real loopback trace carries 1664 `mouseMove` +
/// 163 `mouseDrag` against only 11 `mouseDown` (≈150:1). The host injects every event behind
/// synchronous WindowServer IPC (`CGWarpMouseCursorPosition` +
/// `CGAssociateMouseAndMouseCursorPosition` + `CGEvent.post`, three round-trips), so when the
/// serial inbound consumer falls behind a flood it replays every STALE intermediate position in
/// FIFO order — the cursor then crawls through old positions seconds behind the user.
///
/// The rule lives on the far side and answers a PLAN: one slot per output event, naming WHICH
/// input it is built from and the deltas it carries. That is what lets it cross at all — a `.text`
/// event's string has no home in the flat record, and under a plan it never has to leave this side.
/// Every survivor is an event this array is already holding, so applying the plan is an index and,
/// for a merged scroll, the run's summed travel substituted in.
///
/// Driven by drain-availability (the actor batch-drains the inbound queue and coalesces what piled
/// up) not a wall-clock timer, so it is SELF-REGULATING: when the consumer keeps up the batches are
/// size ~1 (no-op); only when it falls behind does a run collapse, bounding the lag to ~one
/// injection regardless of flood.
public struct InputMotionCoalescer: Sendable {
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
        let records = batch.map(\.wire)
        // The plan is at most one slot per input, so the first lend always fits and this is one
        // call rather than the measure-then-fill pair a text door needs.
        var plan = [SlopDeskCoalescedSlot](repeating: SlopDeskCoalescedSlot(), count: batch.count)
        let count = records.withUnsafeBufferPointer { events in
            plan.withUnsafeMutableBufferPointer { room in
                slopdesk_input_coalesce_plan(
                    events.baseAddress, events.count, coalesceScroll, room.baseAddress, room.count,
                )
            }
        }
        var output: [InputEvent] = []
        output.reserveCapacity(count)
        for slot in plan.prefix(count) {
            let source = Int(slot.source)
            guard source < batch.count else { continue }
            output.append(apply(slot, to: batch[source]))
        }
        return output
    }

    /// The slot's event rebuilt: a scroll takes the run's SUMMED deltas — the one number this side
    /// cannot read off its own event — and everything else is itself, unchanged.
    private static func apply(_ slot: SlopDeskCoalescedSlot, to event: InputEvent) -> InputEvent {
        guard case let .scroll(_, _, normalized, scrollPhase, momentumPhase, continuous, tag) = event else {
            return event
        }
        return .scroll(
            dx: slot.dx, dy: slot.dy, normalized: normalized, scrollPhase: scrollPhase,
            momentumPhase: momentumPhase, continuous: continuous, tag: tag,
        )
    }
}

/// The FACE of `slopdesk-video`'s time-gated scroll accumulator (the stateful half of
/// `injectCoalesced`, kept apart so its flush reachability is unit-testable).
///
/// Continuous-phase scroll deltas are SUMMED into an accumulator held ACROSS runs and emitted
/// ≤ once per `injectInterval`. Uncoalesced, the ~200/s `CGEvent` flood saturates the WindowServer
/// and stalls SCStream capture. A gesture boundary (began/ended/wheel) or any non-scroll event
/// flushes the accumulator FIRST, in order; a trailing flush covers a run that ends mid-gesture.
/// ``plan(run:now:)`` returns the exact ordered events the actor must inject; the actor applies its
/// raise latch per returned event, so raise/button-balance semantics are untouched. (`now` is
/// sampled once per run — runs fold in µs, far below the ms-scale gate, so per-event sampling is
/// indistinguishable.)
///
/// The far side answers a PLAN, and for the same reason the coalescer does: a passed-through event
/// is NAMED, so this side keeps the `.text` payload that has no home in a flat record, while a
/// summed emit is the planner's own and is carried whole because a scroll is all scalars.
public struct ScrollCoalescePlanner: Sendable {
    /// The accumulator itself, as the far side keeps it. Held by value: this planner is an actor's
    /// field and a test's local, both of which COPY, and a handle they copied would be two
    /// accumulators by the second copy (`docs/55` §4b).
    private var state: SlopDeskScrollPlanner

    public init(injectInterval: Double, coalesceScroll: Bool) {
        state = slopdesk_scroll_planner_new(injectInterval, coalesceScroll)
    }

    /// Whether a summed residual is currently held (drives the actor's idle-flush re-arm).
    public var hasPendingScroll: Bool { state.has_template }

    /// Folds one arrival-ordered `run` and returns the ordered events to inject NOW. Continuous
    /// scroll accumulates (emitted at most once per `injectInterval`); everything else passes
    /// through with any pending residual flushed FIRST (order-preserving).
    ///
    /// NO empty-run early return: an empty run (a drain that carried only control/recovery
    /// datagrams — e.g. the ~20/s netstats batches) must still reach the trailing flush, or a
    /// residual stranded by a LOST gesture-`ended` datagram waits for the next unrelated input.
    public mutating func plan(run: [InputEvent], now: Double) -> [InputEvent] {
        let records = run.map(\.wire)
        // Every input can pass through, each can flush a residual before it, and one trailing flush
        // closes the run — so this always fits, and the door never has to be called twice.
        var planned = [SlopDeskPlannedEvent](
            repeating: SlopDeskPlannedEvent(), count: run.count * 2 + 2,
        )
        let count = records.withUnsafeBufferPointer { events in
            planned.withUnsafeMutableBufferPointer { room in
                slopdesk_scroll_planner_plan(
                    &state, events.baseAddress, events.count, now, room.baseAddress, room.count,
                )
            }
        }
        var out: [InputEvent] = []
        out.reserveCapacity(count)
        for slot in planned.prefix(count) {
            let source = Int(slot.source)
            if slot.has_source, source < run.count {
                out.append(run[source]) // the caller's own event, text payload and all
            } else if let summed = InputEvent(summedScroll: slot.event) {
                out.append(summed)
            }
        }
        return out
    }

    /// Drops any pending residual WITHOUT emitting it (media teardown: a stale gesture tail must
    /// not leak into the next session).
    public mutating func clearPending() {
        state = slopdesk_scroll_planner_clear(state)
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
    /// Every number the fold reads, exactly as it crosses. The whole record travels: the jitter
    /// sample and the fold count look like bookkeeping but ARE the rising-trend warmup, and a
    /// crossing that dropped them would read the first sample of every report as a rise.
    private var state: SlopDeskNetEstimate

    /// The record as the rate law reads it. Module-internal because the estimate and the controller
    /// are one crossing split in two — outside this module the estimate is only its named readings.
    var crossing: SlopDeskNetEstimate { state }

    public init() { state = slopdesk_net_estimate_new() }

    /// EWMA-smoothed RTT (ms). 0 until the first valid sample folds.
    public var smoothedRTTMillis: Double { state.smoothed_rtt_millis }
    /// Windowed minimum RTT (ms) — the path's no-queue baseline. `.infinity` until the first sample.
    public var minRTTMillis: Double { state.min_rtt_millis }
    /// EWMA loss rate in [0, 1] (unrecovered / framesReceived per report). For logging / telemetry
    /// trend only — the controller does NOT key its decrease on this (see ``lastLossSample``).
    public var lossRate: Double { state.loss_rate }
    /// RAW per-report loss fraction from the MOST RECENT fold (unrecovered / framesReceived), in [0, 1].
    /// Unlike ``lossRate`` (EWMA-damped, alpha 0.125) this is the INSTANTANEOUS sample, so a clean
    /// report reads 0 even while the EWMA tail of a prior spike is still decaying above threshold.
    /// ``LiveCongestionController`` keys its multiplicative decrease on THIS, so a single transient
    /// loss spike causes exactly ONE decrease — not a multi-report cascade driven by the slowly-decaying
    /// EWMA re-tripping the threshold on subsequent perfectly-clean reports.
    public var lastLossSample: Double { state.last_loss_sample }
    /// Whether the most recent OWD-jitter sample rose vs the previous (a congestion-onset hint).
    public var owdGradientRising: Bool { state.owd_gradient_rising }
    /// The client trendline detector read OVERUSING on the most recent report — monotone delay
    /// growth over a full regression window, sustained past the adaptive threshold. THIS, not
    /// `owdGradientRising` (a 2-sample coin flip), is the gradient signal
    /// ``LiveCongestionController``'s early-cut path consumes.
    public var owdTrendOverusing: Bool { state.owd_trend_overusing }
    /// The detector's modified trend (ms-of-delay per ms, ×scale ×gain) from the most recent report
    /// — logging/diagnostics only.
    public var owdTrendModified: Double { state.owd_trend_modified }
    /// The RAW (un-smoothed) RTT sample of the MOST RECENT fold — the gradient cut's fresh LEVEL
    /// corroboration (the queue NOW, no EWMA lag, no streak). EXPLICITLY `nil` when that report's
    /// sample was rejected (freshness contract: corroboration may only use THIS report's evidence).
    public var lastRTTSampleMillis: Double? {
        state.has_last_rtt_sample ? state.last_rtt_sample_millis : nil
    }

    /// PURE wrap-safe host-clock RTT (ms), or `nil` to REJECT the sample. Total over all `UInt32`
    /// inputs — the subtraction is wrap-aware, so a counter that rolled between the stamp and now
    /// still yields the right small positive elapsed. Rejects when telemetry is off, when the stamp
    /// is in the future (a stale stamp from a prior session after an actor re-create), when the hold
    /// exceeds the elapsed, or when the result is implausibly large.
    public static func computeRTTMillis(hostNowMs: UInt32, latestHostSendTs: UInt32, clientHoldMs: UInt32) -> Int? {
        var millis = Int64(0)
        guard slopdesk_net_estimate_rtt_millis(hostNowMs, latestHostSendTs, clientHoldMs, &millis)
        else { return nil }
        return Int(millis)
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
        state = slopdesk_net_estimate_fold(
            state, rttMillis != nil, Int64(rttMillis ?? 0), framesReceived, unrecovered,
            owdJitterMicros, owdTrendState, owdTrendModifiedMilli,
        )
    }

    /// Equality is over every folded number, as the synthesised one was — including the two the
    /// public surface does not show, because two estimates that agree on everything visible and
    /// disagree on the warmup will disagree on the next fold.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.smoothed_rtt_millis == rhs.state.smoothed_rtt_millis
            && lhs.state.min_rtt_millis == rhs.state.min_rtt_millis
            && lhs.state.loss_rate == rhs.state.loss_rate
            && lhs.state.last_loss_sample == rhs.state.last_loss_sample
            && lhs.state.owd_trend_modified == rhs.state.owd_trend_modified
            && lhs.lastRTTSampleMillis == rhs.lastRTTSampleMillis
            && lhs.state.owd_gradient_rising == rhs.state.owd_gradient_rising
            && lhs.state.owd_trend_overusing == rhs.state.owd_trend_overusing
            && lhs.state.last_owd_jitter_micros == rhs.state.last_owd_jitter_micros
            && lhs.state.sample_count == rhs.state.sample_count
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
    ///
    /// The rule is `slopdesk_video::recovery_routing::StaticIdrDecider`'s and is not spelled here:
    /// the quiet window that lets the live path own the cadence, the recovery request that wins once
    /// it is quiet, and the heartbeat measured from the last SYNTHETIC emission only. This class is
    /// the four anchors and the thread discipline; the four anchors are all the state there is, so
    /// they cross as scalars and nothing is owned across the call (`docs/55` §4).
    public func shouldReencode(now: TimeInterval, forcedLatched: Bool, hasRetainedBuffer: Bool) -> Bool {
        slopdesk_static_idr_should_reencode(
            heartbeat, quietWindow, lastCompleteEncode, lastSyntheticEncode,
            now, forcedLatched, hasRetainedBuffer,
        )
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

    /// Schedules one encoded frame: the finished wire datagrams from
    /// ``VideoPacketizer/packetizeRaw(frame:keyframe:crisp:hostSendTsMillis:fecTier:isLTR:ackedAnchored:interleave:)``
    /// become ordered `.video` outgoings. Data fragments precede parity (the packetizer emits them
    /// in that order), so a client on a lossless link decodes without waiting for parity (doc 17
    /// §3.6). Datagrams in, datagrams out — there is no parse/re-encode round-trip to pay for.
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

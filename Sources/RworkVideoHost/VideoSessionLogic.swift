import Foundation
import RworkVideoProtocol

// Pure, platform-free session logic for the host video orchestrator. NO
// ScreenCaptureKit / VideoToolbox / Network — exactly the discipline of
// RworkVideoProtocol, so this is unit-testable in isolation. The actor in
// `RworkVideoHostSession.swift` owns the live components and delegates every
// decision to these pure types.

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
    /// The window the accepted session is remoting.
    public private(set) var windowID: UInt32 = 0

    /// The monotonically increasing stream id handed to the client on accept (lets a
    /// reconnecting client distinguish a fresh session).
    private var nextStreamID: UInt32

    public init(nextStreamID: UInt32 = 1) {
        self.nextStreamID = nextStreamID
    }

    /// Side effects the actor must perform after a transition.
    public enum Effect: Equatable, Sendable {
        /// Send this control message back to the client.
        case sendControl(VideoControlMessage)
        /// Bring up capture + encode for `windowID` at the negotiated dimensions.
        case startCapture(windowID: UInt32, width: UInt16, height: UInt16)
        /// Tear down capture + encode.
        case stopCapture
    }

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
    ///   - windowBoundsCG: the live window bounds to report in the ack (the actor
    ///     reads these from the geometry watcher; the pure SM just forwards them).
    ///   - resolveCaptureSize: maps the client viewport → the capture size the host
    ///     will actually use (the actor clamps to the real window; in tests this is
    ///     an identity-ish closure). Returning `nil` rejects the session.
    public mutating func handleControl(
        _ message: VideoControlMessage,
        windowBoundsCG: VideoRect,
        resolveCaptureSize: (_ requestedWindowID: UInt32, _ viewport: VideoSize) -> (UInt16, UInt16)?
    ) -> [Effect] {
        switch message {
        case .hello(let version, let requestedWindowID, let viewport):
            // Strict version check — no fallback (doc 20 §4 discipline).
            guard version == RworkVideoProtocol.version else {
                return [.sendControl(.helloAck(accepted: false, streamID: 0, captureWidth: 0, captureHeight: 0, windowBoundsCG: windowBoundsCG))]
            }
            // Only accept a hello while listening; ignore a duplicate once streaming
            // (idempotent — the client may retransmit the unreliable hello).
            guard state == .listening else {
                if state == .streaming, requestedWindowID == windowID {
                    // Re-ack an in-flight duplicate so a lost ack is recovered, but do
                    // NOT restart capture.
                    return [.sendControl(.helloAck(accepted: true, streamID: lastStreamID, captureWidth: captureWidth, captureHeight: captureHeight, windowBoundsCG: windowBoundsCG))]
                }
                return []
            }
            guard let (w, h) = resolveCaptureSize(requestedWindowID, viewport) else {
                return [.sendControl(.helloAck(accepted: false, streamID: 0, captureWidth: 0, captureHeight: 0, windowBoundsCG: windowBoundsCG))]
            }
            let streamID = nextStreamID
            nextStreamID &+= 1
            lastStreamID = streamID
            captureWidth = w
            captureHeight = h
            windowID = requestedWindowID
            state = .streaming
            return [
                .sendControl(.helloAck(accepted: true, streamID: streamID, captureWidth: w, captureHeight: h, windowBoundsCG: windowBoundsCG)),
                .startCapture(windowID: requestedWindowID, width: w, height: h),
            ]
        case .bye:
            // A client bye re-arms the session so a fresh hello can reconnect
            // WITHOUT a daemon restart (#8). Return to .listening (re-armable) and
            // stop capture only if it was actually streaming. The accept path mints
            // a fresh streamID + re-resolves capture size on the next hello, so a
            // re-accepted session is fully re-initialised. (Local stop() — which also
            // closes the UDP sockets — stays terminal .stopped, NOT re-armable.)
            let wasStreaming = state == .streaming
            guard state == .streaming || state == .listening else { return [] }
            state = .listening
            return wasStreaming ? [.stopCapture] : []
        case .helloAck:
            // Host never receives a helloAck.
            return []
        }
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
        let raiseFirst = needsRaise || Self.alwaysRaises(event)
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
}

/// Pure button-balance bookkeeping for input injection (testable WITHOUT CGEvents).
///
/// The reorder fix (ordered inbound consumer) keeps a single interaction's down→drag→up in
/// order, but it cannot conjure a `mouseUp` that the wire DROPPED or a flaky gesture never
/// sent. A target app that received a `mouseDown` with no matching `mouseUp` stays stuck
/// mid-selection, so the NEXT click "đã bắt đầu selection rồi". This tracks which buttons are
/// logically HELD so a fresh `mouseDown` for an already-held button can emit a synthetic
/// release FIRST — guaranteeing a click never begins inside a stuck selection. Only
/// down/up mutate the held set; moves/drags/scroll/keys/text pass through unchanged.
public struct InputButtonBalance: Sendable, Equatable {
    public private(set) var held: Set<MouseButton> = []
    public init() {}

    /// What to do before injecting `event`.
    public struct Plan: Equatable, Sendable {
        /// Emit a synthetic release of THIS button before the real event (`nil` ⇒ none). Set
        /// only when a `mouseDown` arrives for a button still marked held (a lost up).
        public var preRelease: MouseButton?
        /// SUPPRESS the event entirely — do NOT post it. Set for a `mouseUp` whose button is
        /// NOT held: a duplicate of the client's loss-resilient 3× `mouseUp` (the first up
        /// already released the button) or an up with no matching down. Posting it would be a
        /// spurious extra `*MouseUp` into the target app (breaks the double-click coalescer /
        /// custom WebKit/Electron tracking). This is what makes the wire redundancy truly
        /// idempotent on the host: the FIRST up of the burst posts, the rest are dropped.
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
        case .mouseDown(let button, _, _, _, _):
            let stuck = held.contains(button)
            held.insert(button)
            return Plan(preRelease: stuck ? button : nil)
        case .mouseUp(let button, _, _, _, _):
            if held.remove(button) != nil {
                return Plan()                  // first up for a held button — release it
            }
            return Plan(suppress: true)        // duplicate / orphan up — drop it (idempotent)
        case .mouseMove, .mouseDrag, .scroll, .key, .text:
            return Plan()
        }
    }
}

/// Pure, order-preserving pointer-motion coalescer (the input-latency fix).
///
/// A remote pointer stream is ~99% motion: a real loopback trace was 1664 `mouseMove` +
/// 163 `mouseDrag` against only 11 `mouseDown` (≈150:1). The host injects every event
/// behind synchronous WindowServer IPC (`CGWarpMouseCursorPosition` +
/// `CGAssociateMouseAndMouseCursorPosition` + `CGEvent.post`, three round-trips), so when
/// the serial inbound consumer falls behind a flood it replays every STALE intermediate
/// position in FIFO order — the cursor visibly crawls through old positions seconds behind
/// the user ("delay vài giây").
///
/// This collapses each RUN of consecutive same-class motion events to its LATEST — the only
/// position that still matters, because a hover/drag target is absolute — while passing every
/// button / key / scroll / text event through UNCHANGED and NEVER reordering across one. It
/// is the same latest-position rule TigerVNC (`Viewport` deferred pointer flush) and noVNC
/// (`_handleMouseMove` + `_flushMouseMoveTimer`) use; here it is driven by drain-availability
/// (the actor batch-drains the inbound queue and coalesces what piled up) rather than a
/// wall-clock timer, so it is SELF-REGULATING: when the consumer keeps up the batches are
/// size ~1 and it is a no-op; only when it falls behind does a run collapse, bounding the lag
/// to roughly one injection regardless of flood. Pure ⇒ headlessly unit-testable beside
/// ``InputButtonBalance`` / ``InputDatagramRouter`` (no CGEvent, no socket).
public struct InputMotionCoalescer: Sendable {
    /// The two coalescible motion classes. A hover-run and a drag-run NEVER merge: a class
    /// change is a flush boundary, because a `.mouseDrag` carries a held button + clickState
    /// the host posts as `*MouseDragged`, while a `.mouseMove` is a bare hover `*MouseMoved` —
    /// collapsing across the boundary would drop the transition the target app needs.
    private enum MotionClass: Equatable { case move, drag }

    private static func motionClass(of event: InputEvent) -> MotionClass? {
        switch event {
        case .mouseMove: return .move
        case .mouseDrag: return .drag
        case .mouseDown, .mouseUp, .scroll, .key, .text: return nil
        }
    }

    /// Collapse consecutive same-class motion runs in `batch` to their latest, preserving the
    /// relative order of every non-motion (barrier) event and of motion vs barriers.
    ///
    /// INVARIANT (the correctness the ordered consumer won must not regress): a
    /// `.mouseDown`/`.mouseUp`/`.key`/`.scroll`/`.text` is a hard barrier — any buffered motion
    /// flushes BEFORE it, so a move that physically preceded a click is never emitted after the
    /// click. That keeps down→drag→up framing, ``InputButtonBalance``, and the stateless-drag
    /// contract intact (every down/up still reaches the injector exactly once, in order).
    public static func coalesce(_ batch: [InputEvent]) -> [InputEvent] {
        guard batch.count > 1 else { return batch }
        var output: [InputEvent] = []
        output.reserveCapacity(batch.count)
        var pending: InputEvent?          // the latest buffered motion event in the current run
        var pendingClass: MotionClass?    // its class (nil ⇔ pending is nil)
        for event in batch {
            if let cls = motionClass(of: event) {
                if cls == pendingClass {
                    pending = event                       // same run: keep only the latest
                } else {
                    if let p = pending { output.append(p) }   // class change: flush the old run
                    pending = event
                    pendingClass = cls
                }
            } else {
                // Barrier: flush any buffered motion FIRST (order-preserving), then the barrier.
                if let p = pending { output.append(p); pending = nil; pendingClass = nil }
                output.append(event)
            }
        }
        if let p = pending { output.append(p) }           // trailing motion run
        return output
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
        /// Force an IDR keyframe on the next captured frame (requestIDR, or — for now —
        /// an LTR refresh, which the host satisfies with a forced IDR until the LTR
        /// encode path lands: a forced IDR is always a correct, if heavier, refresh).
        case forceKeyframe
        /// A durable-receipt ack: the host may advance its retransmit/LTR-pin window.
        /// No live effect yet (no retransmit buffer); recorded for the docs/escalation.
        case ack(streamSeq: UInt32)
        /// Drop a malformed/undecodable datagram (a corrupt single packet must never
        /// crash the receiver — same contract as the reassembler).
        case drop(reason: String)
        /// Ignore because the session is not streaming.
        case ignoreNotStreaming
    }

    /// Decides what to do with one raw recovery datagram.
    public func route(datagram: Data, mediaFlowing: Bool) -> Decision {
        guard mediaFlowing else { return .ignoreNotStreaming }
        let message: RecoveryMessage
        do {
            message = try RecoveryMessage.decode(datagram)
        } catch {
            return .drop(reason: "undecodable recovery datagram")
        }
        switch message {
        case .requestIDR, .requestLTRRefresh:
            // Both map to a forced IDR for now: a keyframe unconditionally re-anchors a
            // client that lost frames. (The dedicated LTR-refresh encode is a future
            // optimisation; an IDR is the correct, no-fallback recovery.)
            return .forceKeyframe
        case .ack(let streamSeq):
            return .ack(streamSeq: streamSeq)
        }
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

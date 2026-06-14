import AislopdeskClaudeCode
import AislopdeskClient
import AislopdeskTerminal
import Foundation

/// The terminal screen's view-model: it consumes a ``AislopdeskClient``'s `output` byte stream +
/// `events` and projects connection / title / exit / byte-count state for the SwiftUI views.
///
/// It is the bridge between the actor world (`AislopdeskClient`) and the UI: a `.task` calls
/// ``observe(client:)`` which drains both streams and folds them into `@Observable`
/// properties SwiftUI tracks. The terminal **pixels** are produced by the
/// ``AislopdeskTerminal/TerminalSurface`` the view-model feeds (the libghostty `GhosttySurface` in
/// the app target, or `nil` in the headless/placeholder case) — the view-model never parses
/// VT itself (libghostty-only).
///
/// `@MainActor` so it is safe to mutate from SwiftUI and to drive a `@MainActor`
/// `GhosttySurface`; `@Observable` so the views update automatically.
@preconcurrency
@MainActor
@Observable
public final class TerminalViewModel {
    /// High-level connection lifecycle the UI surfaces (terminal screen + status chrome).
    public enum ConnectionStatus: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
        case disconnected(reason: String)
        case exited(code: Int32)

        public var label: String {
            switch self {
            case .idle: "idle"
            case .connecting: "connecting"
            case .connected: "connected"
            case .reconnecting: "reconnecting"
            case .disconnected: "disconnected"
            case let .exited(code): "exited(\(code))"
            }
        }

        /// True while we believe the byte pipeline is live.
        public var isLive: Bool { self == .connected }
    }

    /// Per-pane SHELL activity (OSC 133), ORTHOGONAL to ``ConnectionStatus``: a pane is
    /// `.connected` AND either `.idle` (at the prompt) or `.running` (a command is executing).
    /// Kept as a separate flag — not folded into ``ConnectionStatus`` — so the connection colour
    /// (green) and the running cue (amber pulse) can both show at once.
    public enum ShellActivity: Sendable, Equatable { case idle
        case running
    }

    // MARK: Observable state

    /// The connection lifecycle (drives the status chrome + placeholder telemetry).
    public private(set) var connectionStatus: ConnectionStatus = .idle
    /// The window/terminal title (OSC 0/2), if the host sent one.
    public private(set) var title: String?
    /// Authoritative session id, learned on first connect / preserved across reconnects.
    public private(set) var sessionID: UUID?
    /// Total bytes of `output` delivered (build-status telemetry; not a render).
    public private(set) var bytesReceived: Int = 0
    /// Most recent resume point surfaced by a `.reconnected` event (diagnostics).
    public private(set) var lastResumeSeq: Int64 = 0
    /// Set when the remote rang the bell since the last clear (the view can flash).
    public private(set) var bellPending: Bool = false
    /// Shell activity (OSC 133): `.running` while a command executes, `.idle` at the prompt.
    /// Drives the pane's running indicator. Independent of ``connectionStatus``.
    public private(set) var shellActivity: ShellActivity = .idle
    /// The most recently FINISHED command (OSC 133;D): its exit code (nil if not reported) and
    /// the host-measured duration in ms. Used by the header/tooltip + the long-command
    /// notification trigger. `nil` until the first command completes.
    public private(set) var lastCommand: (exitCode: Int32?, durationMS: UInt32)?

    // MARK: Wiring

    /// The terminal renderer the model feeds inbound bytes to. `nil` in the headless /
    /// placeholder case; the app target sets it to a libghostty ``GhosttySurface``.
    ///
    /// `@ObservationIgnored`: this is WIRING (the renderer the model feeds), not view state — exactly
    /// like ``inputSink`` / ``resizeSink`` / ``onRequestFocus``. It MUST NOT be observation-tracked.
    /// ``attachSurface(_:)`` both READS (`self.surface !== surface`) and WRITES (`self.surface =
    /// surface`) this property, and it is called from `GhosttyMetalLayerView.updateNSView` — i.e. from
    /// INSIDE a SwiftUI AttributeGraph update. If `surface` were tracked, that read would register the
    /// updating attribute as a dependency and the write would invalidate it, so SwiftUI would re-run
    /// the update → `updateNSView` → `attach` → `attachSurface` → read+write → invalidate → ∞: an
    /// infinite re-render loop that pins the main thread (a multi-second beachball "crash", seen when a
    /// focus change / reconnect triggers `updateNSView`). Ignoring it removes the dependency so the
    /// assignment is inert to the graph. No SwiftUI view body reads `surface`, so nothing needs it
    /// reactive (the renderer view owns its own surface; this is only the feed target).
    @ObservationIgnored public weak var surface: (any TerminalSurface)?

    /// OUT path sink: the encoded keystroke/escape bytes libghostty emits from the
    /// renderer's `key`/`text` events (`GhosttySurface.onWrite`). The ``ConnectionViewModel``
    /// sets this on connect to forward to the live ``AislopdeskClient/sendInput(_:)`` and clears
    /// it on teardown; while `nil` (disconnected) keystrokes are dropped — there is no host
    /// to receive them. The renderer routes `onWrite` here via ``sendInput(_:)``, so the
    /// view-attach timing and the connect timing are decoupled (whichever happens first, the
    /// closure reads the latest sink at call time). `@ObservationIgnored`: wiring, not view
    /// state — mutating it must not invalidate the SwiftUI views.
    @ObservationIgnored public var inputSink: ((Data) -> Void)?

    /// OUT path sink for grid resizes (cols/rows) the renderer derives from layout
    /// (`GhosttySurface.onResize`). Same lifecycle as ``inputSink``: set on connect to
    /// forward to ``AislopdeskClient/sendResize(cols:rows:pxWidth:pxHeight:)`` (→ host
    /// `TIOCSWINSZ`), cleared on teardown.
    /// Wiring it (on connect) FLUSHES the latest grid the renderer derived so far: libghostty's
    /// `resize_callback` fires during surface creation / initial layout — BEFORE `connect()` wires
    /// this sink — so those early grids would otherwise be lost and the host PTY would stay at its
    /// 80×24 init size while libghostty renders the real grid (the "render lộn xộn" / overlapping-
    /// glyph bug: zsh wraps at 80 cols, fzf draws at row 24, but the surface is a different size).
    /// `didSet` delivers the pending size the instant a sink appears, so the host always learns the
    /// real grid even when no further resize happens after connect.
    @ObservationIgnored public var resizeSink: ((UInt16, UInt16) -> Void)? {
        didSet {
            // A freshly-wired sink means a (re)connect: the host PTY is at its 80×24 init size and
            // must be told the real grid even if it has not changed since the last connection, so
            // clear the dedup memory and force a fresh delivery of the current grid.
            if resizeSink != nil { lastSentSize = nil }
            deliverResizeIfNeeded()
        }
    }

    /// The latest grid the renderer derived, recorded UNCONDITIONALLY (even while disconnected, when
    /// there is no sink yet) so it can be flushed the moment ``resizeSink`` is wired on connect.
    @ObservationIgnored private var pendingSize: (cols: UInt16, rows: UInt16)?

    /// Last grid size actually FORWARDED through the sink, so a duplicate resize (libghostty emits
    /// `onResize` both from `setSize` directly AND from its own `resize_callback` for the same layout
    /// pass) is coalesced and not sent twice. Only updated when a resize is genuinely delivered — a
    /// resize attempted while disconnected (sink nil) must NOT poison this, or the dedup would later
    /// suppress the real send once the sink is wired.
    @ObservationIgnored private var lastSentSize: (cols: UInt16, rows: UInt16)?

    /// Click-to-focus hook (macOS). The terminal NSView (`GhosttyLayerBackedView`) now installs
    /// `mouseDown`, which CONSUMES the click that the pane's `.onTapGesture { store.focus(id) }`
    /// used to receive — so a body click would start a libghostty selection but NOT make the pane
    /// the workspace-focused one (no focus ring, keyboard stuck on the old pane). The renderer calls
    /// this at the TOP of `mouseDown`; the leaf wires it to `store.focus(paneID)` so the click ALSO
    /// transfers workspace focus. `@ObservationIgnored`: wiring, not view state. Nil for headless /
    /// preview callers (no store), where it is simply never invoked.
    @ObservationIgnored public var onRequestFocus: (() -> Void)?

    /// Pans the CANVAS by a (sign-adjusted) delta when a scroll lands on this terminal while it is NOT the
    /// active pane — so scrolling over a background terminal navigates the canvas instead of being
    /// swallowed by libghostty's scrollback ("only the active pane swallows pointer"). The renderer's
    /// `scrollWheel` calls this when `!isFocusedPane`; the leaf wires it to the store's camera pan.
    /// `@ObservationIgnored`: wiring, not view state. Nil for headless/preview callers (never invoked).
    @ObservationIgnored public var onCanvasScroll: ((CGSize) -> Void)?

    /// Synchronized-input tap (tmux `synchronize-panes`). When set, every OUT chunk this pane sends —
    /// macOS surface keystrokes AND iOS input-bar submits both funnel through ``sendInput(_:)`` — is also
    /// offered here so the store can MIRROR it into the other broadcast panes. The store's closure is the
    /// authority on whether broadcast is armed and which siblings receive it (and guards its own re-entry,
    /// so mirroring into a sibling does not loop back). Local delivery via ``inputSink`` is unchanged.
    /// `@ObservationIgnored`: wiring, not view state. Nil for headless/preview callers (never invoked).
    @ObservationIgnored public var broadcastTap: ((Data) -> Void)?

    // MARK: Replay byte-ring (surface-rebuild survival)

    /// Bounded FIFO of the COMPLETE `output` chunks fed to the surface, kept so a
    /// REBUILT surface can be repainted from scratch. SwiftUI dismantles the terminal
    /// representable when its tab/pane goes off-screen (tab switch, compact carousel flip)
    /// → ``detachSurface()`` closes the live `GhosttySurface`; on re-appear ``attachSurface(_:)``
    /// receives a BRAND-NEW empty surface. The *connection never dropped*, so the host does NOT
    /// re-send the scrollback — without this ring the prior screen would be lost. On attach of a
    /// different surface instance we replay the ring (see ``attachSurface(_:)``).
    ///
    /// Each element is one whole wire `output` payload; eviction drops WHOLE oldest chunks
    /// (never splits a `Data`) so a replayed chunk is always a complete prefix-aligned slice the
    /// VT parser can consume. `@ObservationIgnored`: replay buffer, not view state — mutating it
    /// must not invalidate SwiftUI.
    ///
    /// LIMITATION: replay is a naive re-feed of the retained raw bytes, prefixed with a DECSTR
    /// soft reset. It restores the *main-screen* scrollback faithfully for the common case, but
    /// it is NOT a true VT snapshot: if the oldest still-relevant state was already EVICTED past
    /// `maxRingBytes`, or the retained window STRADDLES an escape sequence whose opening bytes
    /// were evicted, or the host had switched to the ALT screen (vim/less) at the ring boundary,
    /// the replayed frame can differ from the live screen until the next host output corrects it.
    /// The soft reset bounds the damage (cursor/SGR/charset back to defaults) but cannot
    /// reconstruct alt-screen contents the host never re-sends.
    @ObservationIgnored private var ring: [Data] = []
    /// Running total of `ring`'s byte count (sum of `chunk.count`), kept incrementally so
    /// eviction is O(evicted) not O(n) per ingest.
    @ObservationIgnored private(set) var ringByteCount: Int = 0
    /// Soft cap on the replay ring; whole oldest chunks are evicted once exceeded. ~256 KB is a
    /// generous several-screens scrollback while staying small enough to replay synchronously.
    @ObservationIgnored var maxRingBytes: Int = 256 * 1024

    /// Set when a reconnect campaign begins (``markReconnecting``); consumed by the NEXT
    /// ``ingestOutput`` to wipe the dead session's screen before the fresh shell paints.
    ///
    /// The mux transport has NO server-side resume — a real drop kills the host shell and the
    /// reconnect spawns a BRAND-NEW one whose output restarts at seq 1 (see `AislopdeskClient.connect`).
    /// Without this, the fresh shell's prompt is fed on top of the previous session's still-resident
    /// framebuffer + scrollback (the "old screen with a new prompt grafted on" artifact). We cannot
    /// key the wipe off `connectionStatus` because the `.reconnected` EVENT (a separate stream) flips
    /// it to `.connected` and could race the first output; a flag set on the reconnect boundary and
    /// consumed in the OUTPUT path is order-deterministic (both run on the main actor, and the wipe
    /// happens inline immediately before the first fresh chunk is fed). `@ObservationIgnored`: control
    /// flag, not view state.
    @ObservationIgnored private var pendingFreshSessionReset = false

    public init(surface: (any TerminalSurface)? = nil) {
        self.surface = surface
    }

    // MARK: OUT path (renderer → host)

    /// Routes terminal OUT bytes (keystrokes libghostty encoded) to the live client.
    /// A no-op while disconnected (``inputSink`` is `nil`). Called on the main actor by
    /// the renderer's `GhosttySurface.onWrite` bridge.
    public func sendInput(_ data: Data) {
        if Self.echoProbeEnabled { probeInputAt = ContinuousClock.now }
        if glitchCaretMode != .off { noteGlitchCaretSend(data) }
        inputSink?(data)
        // Synchronized input: offer the SAME bytes to the broadcast fan-out (no-op when disarmed). After
        // the local send so the source pane echoes first; the store skips the source and guards re-entry.
        broadcastTap?(data)
    }

    // MARK: Glitch caret (predictive-echo v1 — docs/12 §B → docs/17 §2.4, docs/31 #3)

    /// The WAN typing-latency masker, in its sanctioned CONSERVATIVE form: we never paint
    /// predicted text (no shadow VT parser — the desync class docs/17 rejects); we only
    /// show a dim "input received" caret nudge when a keystroke's echo has not arrived
    /// within ``glitchWindow``. Reconciliation is therefore trivial: ANY host output
    /// hides the caret (the real render is the truth), and a hard ``glitchExpiry``
    /// bounds non-echoing prompts (`stty -echo`, `read -s`).
    ///
    /// Arming gates (ALL must hold):
    /// - mode: `.forced`, or `.rttGated` with the EWMA RTT above ``glitchRTTOnMS``
    ///   (hysteresis: stays armed until it falls below ``glitchRTTOffMS`` — the 3 s
    ///   ping cadence makes the gate signal slow; don't flap at the boundary);
    /// - `.connected`, and the tracker says `.shellPrompt` — alt-screen TUIs (Claude
    ///   Code, vim) do their own full-screen echo discipline; mosh disables prediction
    ///   there too (docs/17 §2.4 point 2);
    /// - the send is EXACTLY one printable ASCII byte (0x20...0x7E). Backspace (0x7F)
    ///   retires one pending keystroke; anything else (CR, ESC sequences, multi-byte =
    ///   paste / committed IME text — Vietnamese Telex composes to multi-byte UTF-8)
    ///   CLEARS all pending state (the mosh `become_tentative`/paste-reset analogue,
    ///   stricter): predicted columns would desync instantly, so we never guess.
    public enum GlitchCaretMode: Sendable, Equatable {
        case off
        /// `AISLOPDESK_GLITCH_CARET=1` — armed only while the measured RTT warrants it.
        case rttGated
        /// `AISLOPDESK_GLITCH_CARET=force` — RTT gate bypassed, zero glitch window
        /// (loopback rig render verification; echo would otherwise win the race).
        case forced
    }

    private static func glitchCaretModeFromEnv() -> GlitchCaretMode {
        switch ProcessInfo.processInfo.environment["AISLOPDESK_GLITCH_CARET"] {
        case "force": .forced
        case let .some(value) where !value.isEmpty && value != "0": .rttGated
        default: .off
        }
    }

    /// Read from the env once per model; internal-settable so headless tests drive the
    /// gate matrix without process environment games.
    @ObservationIgnored var glitchCaretMode: GlitchCaretMode = TerminalViewModel.glitchCaretModeFromEnv()

    /// Echo-wait before the caret shows (mosh GLITCH_THRESHOLD territory: 150–250 ms).
    @ObservationIgnored var glitchWindow: Duration = .milliseconds(175)
    /// Hard ceiling on a shown caret with no echo at all (non-echoing prompts).
    @ObservationIgnored var glitchExpiry: Duration = .milliseconds(1500)
    /// RTT hysteresis (EWMA from ping/pong, 3 s cadence): arm above on, disarm below off.
    static let glitchRTTOnMS: Double = 30
    static let glitchRTTOffMS: Double = 20

    /// TRUE while the dim caret overlay should draw (the ONE observable output of the
    /// whole feature — everything else is plain bookkeeping).
    public private(set) var glitchCaretVisible = false

    /// Keystrokes sent but not yet answered by ANY host output (positional, like the
    /// echo probe — conservative direction: any output clears, so the caret can only
    /// under-show, never over-show).
    @ObservationIgnored private var pendingEchoCount = 0
    @ObservationIgnored private var glitchTask: Task<Void, Never>?
    /// Hysteresis state of the RTT gate (`.rttGated` mode).
    @ObservationIgnored private var rttGateOpen = false
    /// Pane-local EWMA RTT mirror (folded from the `.rtt` event; diagnostics + gate).
    @ObservationIgnored public private(set) var paneLatencyMS: Double?
    /// Alt-screen gate: a client-side `TerminalModeTracker` fed in ``ingestPass`` (only
    /// while the feature is on — it has a memchr skim fast path, but off means OFF).
    @ObservationIgnored private let glitchModeTracker = TerminalModeTracker()

    private var glitchCaretArmed: Bool {
        guard connectionStatus == .connected, glitchModeTracker.mode == .shellPrompt else { return false }
        switch glitchCaretMode {
        case .off: return false
        case .forced: return true
        case .rttGated: return rttGateOpen
        }
    }

    /// OUT-side classification (see the gate list above). Called per keystroke — cheap.
    private func noteGlitchCaretSend(_ data: Data) {
        guard glitchCaretArmed else {
            clearGlitchCaret()
            return
        }
        if data.count == 1, let byte = data.first {
            switch byte {
            case 0x20...0x7E:
                pendingEchoCount += 1
                if pendingEchoCount == 1 { armGlitchTimer() }
            case 0x7F:
                pendingEchoCount = max(0, pendingEchoCount - 1)
                if pendingEchoCount == 0 { clearGlitchCaret() }
            default:
                clearGlitchCaret() // CR, Ctrl-*, ESC — a state change we won't model
            }
        } else {
            clearGlitchCaret() // paste / IME / encoded escape sequence
        }
    }

    /// One timer per pending RUN, armed when the count goes 0→1 (the glitch window is
    /// measured from the OLDEST unanswered keystroke, as in mosh): show after
    /// ``glitchWindow`` if still unanswered, force-hide at ``glitchExpiry``.
    private func armGlitchTimer() {
        glitchTask?.cancel()
        let window = glitchWindow
        let expiry = glitchExpiry
        glitchTask = Task { [weak self] in
            // Weak across both sleeps — a parked timer must not extend the model's life.
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, (self?.pendingEchoCount ?? 0) > 0 else { return }
            self?.glitchCaretVisible = true
            try? await Task.sleep(for: expiry)
            guard !Task.isCancelled else { return }
            self?.clearGlitchCaret()
        }
    }

    /// Hides the caret and forgets all pending keystrokes. Idempotent and cheap (the
    /// observable flag is only written when it actually changes).
    private func clearGlitchCaret() {
        pendingEchoCount = 0
        glitchTask?.cancel()
        glitchTask = nil
        if glitchCaretVisible { glitchCaretVisible = false }
    }

    // MARK: Echo probe (rig instrumentation — docs/31 follow-up #4)

    /// `AISLOPDESK_ECHO_PROBE=1`: print a keystroke→first-output-ingest latency line per
    /// echo to stderr, so `check-macos.sh --connect` (an idle pane + AUTOTYPE) emits real
    /// keystroke-feel numbers instead of pass/fail — the A/B harness for smoothness work.
    /// The measured span = wire out + host PTY round trip + wire back + client delivery up
    /// to the render feed (the user-feel path minus the final present tick). Rig-only:
    /// matching is positional (NEXT ingest after a send = the echo), correct for an idle
    /// interactive pane, meaningless under an output flood. Zero hot-path cost when off
    /// (one static-bool branch).
    private static let echoProbeEnabled =
        ProcessInfo.processInfo.environment["AISLOPDESK_ECHO_PROBE"] != nil
    @ObservationIgnored private var probeInputAt: ContinuousClock.Instant?

    /// Mirrors a grid resize to the host (`TIOCSWINSZ`). A no-op while disconnected.
    /// Called on the main actor by the renderer's `GhosttySurface.onResize` bridge.
    /// Coalesces consecutive duplicates (same cols/rows) so libghostty's double-emit per
    /// layout pass forwards at most one resize.
    public func sendResize(cols: UInt16, rows: UInt16) {
        pendingSize = (cols, rows) // record the latest grid even if not connected yet
        deliverResizeIfNeeded()
    }

    /// Forwards ``pendingSize`` to the host via ``resizeSink`` if it differs from the last delivered
    /// size. Called from ``sendResize`` (grid changed) AND from `resizeSink.didSet` (sink wired on
    /// connect) — so the host learns the real grid regardless of which happens first. A no-op while
    /// the sink is nil, leaving `lastSentSize` untouched so the dedup never suppresses the eventual
    /// first real send.
    private func deliverResizeIfNeeded() {
        guard let sink = resizeSink, let sz = pendingSize else { return }
        if let last = lastSentSize, last.cols == sz.cols, last.rows == sz.rows { return }
        lastSentSize = sz
        sink(sz.cols, sz.rows)
    }

    /// Forces a re-delivery of the latest grid (``pendingSize``) to the sink, bypassing the dedup.
    /// Called right AFTER the client finishes connecting: a resize delivered to the OUT drain DURING
    /// the mux handshake makes `AislopdeskClient.sendResize` throw `invalidState("sendResize before
    /// connect")`, which the drain's `try?` silently swallows — yet `lastSentSize` was already
    /// recorded, so the dedup would block every later send and the host PTY would stay at its 80×24
    /// init grid (the "render lộn xộn" / overlapping-glyph bug). Re-arming + re-delivering here sends
    /// the real grid once the host is ready to accept it.
    public func resendCurrentSize() {
        lastSentSize = nil
        deliverResizeIfNeeded()
    }

    // MARK: Stream observation

    /// Drains the client's `output` byte stream ONLY, folding each chunk into observable
    /// state. Call from a SwiftUI `.task { await model.observe(client: client) }`; it returns
    /// when the output stream finishes (client closed / child exited).
    ///
    /// ### Single events consumer (the race this avoids)
    /// The view-model does **not** open its own `for await client.events` loop. Events are
    /// owned by the ``ConnectionViewModel`` (the single UI-layer events consumer), which folds
    /// the connect/drop signal into the chrome status AND forwards each event here via
    /// ``handle(_:)``. Two independent loops over the *same* event source would split the
    /// stream nondeterministically (output is safe because the model is its sole consumer).
    public func observe(client: AislopdeskClient) async {
        connectionStatus = .connecting
        for await _ in client.outputWakeups {
            // Epoch snapshot BEFORE the take, so a batch is tagged with the session it was taken FROM.
            // `markReconnecting()` (epoch bump + fresh-wipe arm) runs on this same MainActor and can
            // interleave while we are suspended in `takeOutputBatch()`. If we read `sessionEpoch` AFTER
            // the take resumes (the old code) the DEAD session's in-hand bytes get tagged with the NEW
            // epoch — the ingestBatch guard then passes them through and they consume the fresh-session
            // wipe (painting stale output under the new prompt). Capturing before means dead bytes carry
            // the OLD epoch and ingestBatch drops them; the fresh session's bytes arrive on a LATER wake,
            // taken under the bumped epoch, and paint correctly. (The inverse risk — a take that returns
            // NEW bytes under a stale snapshot — needs an entire network reconnect to complete inside the
            // sub-µs `takeOutputBatch` actor hop, which cannot happen.)
            let epoch = sessionEpoch
            let batch = await client.takeOutputBatch()
            await ingestBatch(batch, epoch: epoch)
        }
        // FINAL DRAIN: a tail appended just before the wake stream finished (exit/close)
        // has no wake left to announce it — take it explicitly. ONLY on a natural finish:
        // a CANCELLED observe (teardown/reconnect replaced this pump) must NOT take —
        // it would paint the dead session's tail into the freshly-reset pane and credit
        // those bytes to the wrong (new) transport (night-review finding).
        guard !Task.isCancelled else { return }
        let tailEpoch = sessionEpoch
        let tail = await client.takeOutputBatch()
        await ingestBatch(tail, epoch: tailEpoch)
    }

    /// Monotonic SESSION boundary counter, bumped by ``markReconnecting()`` and
    /// ``reset()``. The output pump snapshots it when it takes a batch and passes it to
    /// ``ingestBatch(_:epoch:)``, which re-checks before EVERY pass — so a batch taken
    /// from the DEAD session can never cross a reconnect boundary and paint (or consume
    /// the one-shot fresh-session wipe) after the boundary, no matter how long the pump
    /// was parked at a suspension point in between.
    @ObservationIgnored private(set) var sessionEpoch = 0

    /// Max bytes fed to the surface per synchronous MainActor pass. Between passes the
    /// drain yields so input events / the display link / SwiftUI interleave — a multi-MB
    /// backlog (cat of a big file) no longer monopolizes the main thread in one job.
    static let ingestByteBudget = 256 * 1024

    /// Folds a BATCH of `output` chunks in budget-bounded synchronous passes: each pass
    /// runs ring bookkeeping per chunk, then ONE `surface.feedBatch` (one renderer flush).
    /// `Task.yield()` only BETWEEN passes — never inside one (doc-18-§C: the surface's
    /// write/flush trio must not interleave with suspension).
    ///
    /// RENDER-SIDE BACKPRESSURE: before EVERY pass (including the first) the pump awaits
    /// ``FeedBackpressuring/feedBackpressure()`` when the surface conforms. With an
    /// asynchronous feed (GhosttySurface's serial feed queue, docs/31 #5) the mux's
    /// credit-at-consumption would otherwise decouple wire credit from parse progress —
    /// `takeOutputBatch` grants window credit the moment the pump TAKES bytes, so a
    /// flood would pile up un-parsed in the feed queue without bound. Parking here stops
    /// the take → stops the credit → the wire window holds the flood at the host,
    /// end-to-end. Synchronous surfaces (tests, headless) don't conform — no await.
    ///
    /// STALE-BATCH GUARDS (review round): the backpressure park is a long suspension
    /// that lands exactly when floods (and therefore drops/reconnects) happen, so after
    /// EVERY await the batch must re-earn the right to paint: `Task.isCancelled` covers
    /// a replaced pump (teardown/reconnect cancelled it), and the `epoch` check covers a
    /// supervisor reconnect that does NOT cancel the pump — either way a dead session's
    /// in-hand bytes must not consume the new session's one-shot wipe or pollute the
    /// fresh replay ring.
    public func ingestBatch(_ chunks: [Data], epoch: Int? = nil) async {
        guard !chunks.isEmpty else { return }
        var i = 0
        while i < chunks.count {
            if let backpressured = surface as? any FeedBackpressuring {
                await backpressured.feedBackpressure()
                if Task.isCancelled { return }
            }
            if let epoch, epoch != sessionEpoch { return }
            var end = i
            var passBytes = 0
            repeat {
                passBytes += chunks[end].count
                end += 1
            } while end < chunks.count && passBytes < Self.ingestByteBudget
            ingestPass(chunks[i..<end])
            i = end
            if i < chunks.count {
                await Task.yield()
                // A teardown/reconnect cancelled this pump mid-batch: stop painting the
                // dead session's remaining passes (the new session's fresh-wipe ingest can
                // interleave at the yield above — later dead passes would land AFTER it).
                if Task.isCancelled { return }
                if let epoch, epoch != sessionEpoch { return }
            }
        }
    }

    /// Folds one `output` chunk (the single-chunk pass — kept as the synchronous API for
    /// tests and direct feeders).
    public func ingestOutput(_ chunk: Data) {
        ingestPass([chunk])
    }

    /// One fully-synchronous ingest pass: feed the renderer + bump telemetry. The first
    /// byte flips `.connecting`/`.reconnecting` → `.connected` (we are receiving from the
    /// host).
    ///
    /// Order matters: every chunk is retained in the replay ring (evicting whole oldest
    /// chunks to stay under ``maxRingBytes``) BEFORE the batch is fed to the surface, so
    /// the ring is always a superset/peer of what the live surface has seen — a same-tick
    /// rebuild + replay reproduces the current screen. NO `await` may be introduced in
    /// here (doc-18-§C).
    private func ingestPass(_ chunks: ArraySlice<Data>) {
        if Self.echoProbeEnabled, let sentAt = probeInputAt {
            probeInputAt = nil
            let elapsed = sentAt.duration(to: ContinuousClock.now).components
            let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            FileHandle.standardError.write(Data(String(format: "[echo-probe] key→ingest %.1fms\n", ms).utf8))
        }
        // Glitch caret (docs/31 #3): host output is the ground truth — ANY ingest hides
        // the caret (the entire reconciliation policy: we never painted characters, so a
        // "misprediction" can only ever be a caret shown one output-gap too long). The
        // mode tracker keeps the alt-screen gate fresh (memchr skim — ground content is
        // one memchr per chunk). One enum compare when the feature is off.
        if glitchCaretMode != .off {
            for chunk in chunks { glitchModeTracker.consume(chunk) }
            clearGlitchCaret()
        }
        // FRESH-SESSION WIPE: the first output after a reconnect belongs to a brand-new host shell
        // (the mux path never resumes). Hard-reset the live surface and drop the dead session's
        // replay ring BEFORE this pass paints, so the user sees a clean shell instead of the old
        // framebuffer with a new prompt grafted on. Inline here (not on the `.reconnected` event) so
        // the wipe is strictly ordered before the fresh bytes — no cross-stream race.
        if pendingFreshSessionReset {
            pendingFreshSessionReset = false
            ring.removeAll()
            ringByteCount = 0
            surface?.feed(Self.risHardReset)
        }
        if connectionStatus == .connecting || connectionStatus == .reconnecting {
            connectionStatus = .connected
        }

        // Retain WHOLE copies in the bounded replay ring, then evict whole oldest chunks
        // until we are back under the cap (never split a Data — a partial chunk could cut
        // an escape sequence and corrupt the replay). Per-wire-chunk granularity is kept
        // deliberately: concatenating would memcpy and coarsen eviction.
        var passBytes = 0
        for chunk in chunks {
            passBytes += chunk.count
            ring.append(chunk)
            ringByteCount += chunk.count
            while ringByteCount > maxRingBytes, ring.count > 1 {
                ringByteCount -= ring.removeFirst().count
            }
        }
        // ONE observable mutation per pass (SwiftUI change tracking is not free per chunk).
        bytesReceived += passBytes

        surface?.feedBatch(chunks)
    }

    // MARK: Surface attach / detach (replay across rebuild)

    /// DECSTR — Soft Terminal Reset (`ESC [ ! p`). Prefixed to a replay so a freshly-built
    /// surface starts from a known state (default SGR/charset/origin-mode, cursor home) before
    /// the retained bytes repaint over it. A soft (not hard `ESC c`) reset preserves the
    /// scrollback the replayed bytes are about to redraw.
    private static let decstrSoftReset = Data([0x1B, 0x5B, 0x21, 0x70])

    /// RIS — Reset to Initial State (`ESC c`). A HARD reset: clears the screen + scrollback and
    /// returns the emulator to power-on defaults. Fed to the surface on a fresh-session reconnect so
    /// the dead session's framebuffer is gone before the new shell paints (unlike the soft reset used
    /// for replay, which deliberately preserves scrollback the replay is about to redraw).
    private static let risHardReset = Data([0x1B, 0x63])

    /// Attaches a renderer surface and, if this is a *different* instance than the one currently
    /// held and the replay ring is non-empty, REPLAYS the retained output so a rebuilt surface
    /// (tab switch / compact flip dismantled + recreated the representable) shows the prior
    /// screen even though the host did not re-send it.
    ///
    /// Replay is fully synchronous (DECSTR soft reset, then every retained chunk in FIFO order)
    /// to honor the surface main-thread no-`await` contract ([18 §C] — `feed`/`refresh`/`draw`
    /// must not be interleaved with suspension). Attaching the SAME instance again (idempotent
    /// SwiftUI `updateNSView`/`updateUIView` re-attach) does NOT replay — the bytes are already
    /// on screen; re-feeding would duplicate them.
    public func attachSurface(_ surface: any TerminalSurface) {
        let isDifferentInstance = (self.surface !== surface)
        self.surface = surface
        guard isDifferentInstance, !ring.isEmpty else { return }
        // One batch = one renderer flush for the whole replay (the view follows with its
        // own requestPresent burst on attach).
        surface.feedBatch(ArraySlice([Self.decstrSoftReset] + ring))
    }

    /// Detaches the renderer surface (the representable was dismantled). Drops the `weak`
    /// reference; the retained replay ring is KEPT so the next ``attachSurface(_:)`` can repaint.
    ///
    /// IDENTITY-GATED: only clears `self.surface` when `surface` IS the one we are currently feeding.
    /// SwiftUI can build the terminal representable more than once (a sizing/identity pass), so an
    /// OLDER surface can be dismantled AFTER a NEWER one already attached and became `self.surface`.
    /// A blind `self.surface = nil` there would stop feeding the LIVE (on-screen) surface — it then
    /// freezes on its initial replay while all new host output is silently dropped (the exact
    /// "renders the prompt then never repaints" bug, reproduced on a Mac Studio). Passing the
    /// detaching surface lets us clear ONLY when it matches. Called with no argument (legacy/tests)
    /// it clears unconditionally, preserving prior behavior.
    public func detachSurface(_ surface: (any TerminalSurface)? = nil) {
        if let surface {
            if self.surface === surface { self.surface = nil }
        } else {
            self.surface = nil
        }
    }

    /// Folds one `AislopdeskClient.Event` into observable state.
    public func handle(_ event: AislopdeskClient.Event) {
        switch event {
        case let .title(text):
            title = text
        case .bell:
            bellPending = true
        case let .commandStatus(status):
            switch status {
            case .running:
                shellActivity = .running
            case let .idle(exitCode, durationMS):
                shellActivity = .idle
                lastCommand = (exitCode, durationMS)
            }
        case .notification:
            // An explicit child notification (OSC 9 / OSC 777) is handled at the connection/store
            // layer (it posts a local UNUserNotification). The terminal model holds no state for it.
            break
        case let .exit(code):
            connectionStatus = .exited(code: code)
            // The shell died mid-"command" (e.g. `exit` itself emits OSC 133;C but never a
            // matching ;D), so the running indicator would otherwise stay stuck on "running…" on a
            // dead pane (HW-confirmed). Clear it — a terminated shell runs nothing. (Mirrors
            // `markReconnecting`, which already clears this stale state on a drop.)
            shellActivity = .idle
            clearGlitchCaret() // no host left to echo — drop the nudge immediately
        case let .disconnected(reason):
            // A drop while we still want to be connected reads as "reconnecting" (the
            // ReconnectManager is retrying); the ConnectionViewModel owns the authoritative
            // "user asked to disconnect" distinction.
            connectionStatus = .disconnected(reason: reason)
            // Same stale-OSC-133 guard as the exit/reconnect paths: a drop straddling a C→D pair
            // would otherwise pin the indicator on "running…" across the disconnect.
            shellActivity = .idle
            clearGlitchCaret()
        case let .reconnected(sessionID, resumeFromSeq):
            self.sessionID = sessionID
            lastResumeSeq = resumeFromSeq
            connectionStatus = .connected
        case let .rtt(milliseconds):
            // ConnectionViewModel owns the badge's latencyMS; the pane-local mirror feeds
            // the glitch caret's hysteresis gate (docs/31 #3).
            paneLatencyMS = milliseconds
            if milliseconds > Self.glitchRTTOnMS {
                rttGateOpen = true
            } else if milliseconds < Self.glitchRTTOffMS {
                rttGateOpen = false
            }
        }
    }

    /// Marks that the reconnect campaign has begun (the chrome shows "reconnecting" rather
    /// than a bare "disconnected"). Called by the ConnectionViewModel on a non-deliberate drop.
    public func markReconnecting() {
        connectionStatus = .reconnecting
        // A drop leaves a stale OSC 133 running state we can never get a matching `D` for
        // (the C→D pair would straddle the disconnect); clear to idle so the indicator does
        // not get stuck "running" across a reconnect.
        shellActivity = .idle
        // The reconnect will bring a FRESH host shell (no mux resume) — arm the one-shot wipe so the
        // next output clears the dead session's screen/scrollback before painting the new prompt.
        pendingFreshSessionReset = true
        sessionEpoch += 1 // in-hand batches taken from the dead session stop painting
        clearGlitchCaret() // keystrokes in flight died with the old session
        // The dead session's terminal MODE is a lie for the fresh shell (a drop inside
        // vim leaves .altScreen latched and would disarm the caret for the entire new
        // session; a drop mid-DCS would swallow the new session's markers).
        glitchModeTracker.reset()
    }

    /// Clears the pending-bell flag once the view has flashed.
    public func clearBell() {
        bellPending = false
    }

    /// Resets to idle (a fresh connect target). Keeps no stale title / byte count, and clears
    /// the replay ring — a fresh session must not repaint the previous session's scrollback.
    public func reset() {
        connectionStatus = .idle
        title = nil
        bytesReceived = 0
        bellPending = false
        shellActivity = .idle // a fresh session is idle until its first command runs
        lastCommand = nil
        lastResumeSeq = 0
        lastSentSize = nil // a fresh session must re-assert its grid size
        ring.removeAll() // stale scrollback must not survive into a new session
        ringByteCount = 0
        // Arm the one-shot fresh-session wipe, exactly like markReconnecting(). The surface is ALWAYS
        // mounted (TerminalScreenView is an overlay, never an if/else content swap), so a deliberate
        // reconnect (⇧⌘R / the recovery banner's Retry) of an exited/failed pane keeps the dead session's
        // framebuffer on screen — the new shell's prompt would graft onto the old screen. Arming the wipe
        // makes the first fresh output RIS-clear the surface first. Harmless on a first-ever connect (the
        // surface is already empty), and the deliberate path now matches the transient-reconnect path.
        pendingFreshSessionReset = true
        sessionEpoch += 1
        clearGlitchCaret()
        glitchModeTracker.reset() // same session-boundary truth as markReconnecting()
    }
}

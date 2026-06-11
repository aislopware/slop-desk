import Foundation
import AislopdeskClient
import AislopdeskTerminal

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
            case .idle: return "idle"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .reconnecting: return "reconnecting"
            case .disconnected: return "disconnected"
            case .exited(let code): return "exited(\(code))"
            }
        }

        /// True while we believe the byte pipeline is live.
        public var isLive: Bool { self == .connected }
    }

    /// Per-pane SHELL activity (OSC 133), ORTHOGONAL to ``ConnectionStatus``: a pane is
    /// `.connected` AND either `.idle` (at the prompt) or `.running` (a command is executing).
    /// Kept as a separate flag — not folded into ``ConnectionStatus`` — so the connection colour
    /// (green) and the running cue (amber pulse) can both show at once.
    public enum ShellActivity: Sendable, Equatable { case idle; case running }

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
        inputSink?(data)
    }

    /// Mirrors a grid resize to the host (`TIOCSWINSZ`). A no-op while disconnected.
    /// Called on the main actor by the renderer's `GhosttySurface.onResize` bridge.
    /// Coalesces consecutive duplicates (same cols/rows) so libghostty's double-emit per
    /// layout pass forwards at most one resize.
    public func sendResize(cols: UInt16, rows: UInt16) {
        pendingSize = (cols, rows)        // record the latest grid even if not connected yet
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
            await ingestBatch(client.takeOutputBatch())
        }
        // FINAL DRAIN: a tail appended just before the wake stream finished (exit/close)
        // has no wake left to announce it — take it explicitly.
        await ingestBatch(client.takeOutputBatch())
    }

    /// Max bytes fed to the surface per synchronous MainActor pass. Between passes the
    /// drain yields so input events / the display link / SwiftUI interleave — a multi-MB
    /// backlog (cat of a big file) no longer monopolizes the main thread in one job.
    static let ingestByteBudget = 256 * 1024

    /// Folds a BATCH of `output` chunks in budget-bounded synchronous passes: each pass
    /// runs ring bookkeeping per chunk, then ONE `surface.feedBatch` (one renderer flush).
    /// `Task.yield()` only BETWEEN passes — never inside one (doc-18-§C: the surface's
    /// write/flush trio must not interleave with suspension).
    public func ingestBatch(_ chunks: [Data]) async {
        guard !chunks.isEmpty else { return }
        var i = 0
        while i < chunks.count {
            var end = i
            var passBytes = 0
            repeat {
                passBytes += chunks[end].count
                end += 1
            } while end < chunks.count && passBytes < Self.ingestByteBudget
            ingestPass(chunks[i..<end])
            i = end
            if i < chunks.count { await Task.yield() }
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
        case let .exit(code):
            connectionStatus = .exited(code: code)
            // The shell died mid-"command" (e.g. `exit` itself emits OSC 133;C but never a
            // matching ;D), so the running indicator would otherwise stay stuck on "running…" on a
            // dead pane (HW-confirmed). Clear it — a terminated shell runs nothing. (Mirrors
            // `markReconnecting`, which already clears this stale state on a drop.)
            shellActivity = .idle
        case let .disconnected(reason):
            // A drop while we still want to be connected reads as "reconnecting" (the
            // ReconnectManager is retrying); the ConnectionViewModel owns the authoritative
            // "user asked to disconnect" distinction.
            connectionStatus = .disconnected(reason: reason)
            // Same stale-OSC-133 guard as the exit/reconnect paths: a drop straddling a C→D pair
            // would otherwise pin the indicator on "running…" across the disconnect.
            shellActivity = .idle
        case let .reconnected(sessionID, resumeFromSeq):
            self.sessionID = sessionID
            self.lastResumeSeq = resumeFromSeq
            connectionStatus = .connected
        case .rtt:
            // Folded by ConnectionViewModel (latencyMS) — no terminal-model state.
            break
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
        shellActivity = .idle  // a fresh session is idle until its first command runs
        lastCommand = nil
        lastResumeSeq = 0
        lastSentSize = nil   // a fresh session must re-assert its grid size
        ring.removeAll()     // stale scrollback must not survive into a new session
        ringByteCount = 0
        pendingFreshSessionReset = false  // deliberate connect already starts clean; no pending wipe
    }
}

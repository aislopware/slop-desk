#if os(macOS)
import AppKit
import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// The cursor side-channel's host end: a timer, one window-server query, and a Rust handle.
///
/// The host captures with the pointer turned OFF and streams it separately over a small UDP socket,
/// so pointer latency is one round trip rather than "one round trip plus an encode plus a decode"
/// (doc 17 §3.3). What this class owns is the ~120 Hz timer, the off-main mouse read, the one
/// `NSScreen` height the coordinate flip needs, and the hop to the main thread that `AppKit`
/// demands for a cursor read.
///
/// ## What used to be here
/// Four rules and two `AppKit` reads, tangled together in 389 lines that no test could reach: the
/// seed-driven refresh cadence, the Cocoa-to-CG position math, the content-keyed shape-id table,
/// and the render ladder that shrinks an over-budget cursor PNG until it fits one datagram. All
/// four are `slopdesk_video::cursor_sampling` now, with tests; the `NSCursor` read and the offscreen
/// PNG render are `slopdesk-apple-cursor`; the `dlsym`'d window-server cursor seed is
/// `slopdesk_posix::dynsym`. `slopdesk-ffi`'s `cursor_sampler` joins the three behind one handle.
///
/// ## Two threads, on purpose
/// The position sample runs OFF the main thread so a main-thread window raise — six to ten
/// synchronous accessibility round-trips — cannot freeze the pointer, while the shape read is
/// main-thread-ONLY because `AppKit` says so. The handle is the one in `slopdesk_ffi.h` written to
/// be called from both; it carries its own locks, so there is none here.
///
/// ## Datagrams, not values
/// Both handlers take already-encoded bytes. The session forwards them to the cursor socket
/// verbatim, so decoding a `CursorUpdate` here to re-encode it there would be a parse and a build
/// per sample, 120 times a second, for no reader.
public final class CursorSampler: @unchecked Sendable {
    /// Sample rate (doc 17 §3.3: "~120 Hz").
    public static let sampleHz: Double = 120

    /// Emits an encoded ``CursorUpdate`` for the side-channel socket to send (~120 Hz).
    public typealias UpdateHandler = @Sendable (Data) -> Void
    /// Emits an encoded ``CursorShapeMessage`` ONCE per newly-seen shape id, out of band, for the
    /// client to cache and composite (doc 17 §3.3).
    public typealias ShapeHandler = @Sendable (Data) -> Void

    private let updateHandler: UpdateHandler
    private let shapeHandler: ShapeHandler?
    private let handle: OpaquePointer
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "slopdesk.video.cursor", qos: .userInteractive)

    /// Opt-in stderr trace (`SLOPDESK_VIDEO_DEBUG=1`): logs each newly-minted shape so a hardware
    /// run can confirm distinct cursors (I-beam / hand / resize) are really detected and shipped.
    /// Fires only on a mint, which is a few dozen times a session.
    private static let debugStderr = ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_DEBUG"] != nil

    public init(windowBoundsCG: VideoRect, updateHandler: @escaping UpdateHandler, shapeHandler: ShapeHandler? = nil) {
        self.updateHandler = updateHandler
        self.shapeHandler = shapeHandler
        // Never null — there is no bounds rectangle the sampler can refuse, and a degenerate one
        // simply reports every pointer position as outside the window.
        guard let handle = slopdesk_cursor_sampler_new(
            windowBoundsCG.origin.x, windowBoundsCG.origin.y,
            windowBoundsCG.size.width, windowBoundsCG.size.height,
        ) else { preconditionFailure("the cursor sampler door answered null, which it never does") }
        self.handle = handle
    }

    deinit {
        timer?.cancel()
        slopdesk_cursor_sampler_free(handle)
    }

    /// Re-emits the already-shipped shape bytes for `shapeID`, for a client whose one-shot shipment
    /// was lost and which re-requested it over the recovery channel. A no-op for an id never minted
    /// — the cursor is NOT re-read, because that would answer whatever shape is displayed now
    /// rather than the one asked for.
    public func reshipShape(_ shapeID: UInt16) {
        guard let shapeHandler, let bytes = read({ out, cap in
            slopdesk_cursor_sampler_shape(handle, shapeID, out, cap)
        }) else { return }
        shapeHandler(bytes)
    }

    /// Updates the tracked window bounds (call from the geometry watcher).
    public func updateWindowBounds(_ bounds: VideoRect) {
        slopdesk_cursor_sampler_set_bounds(
            handle, bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
        )
    }

    /// Starts the ~120 Hz sampling timer. GUI-only.
    public func start() {
        // Prime the cached shape + screen height on main BEFORE the timer fires, so the first
        // emitted position already carries a shape id the client has been told about. Until this
        // lands the position door answers nothing at all.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refreshOnMain() }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Self.sampleHz)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One sampling tick, off the main thread. Emits the hot position every tick so the pointer
    /// never freezes during a main-thread window raise, and hops to main for a fresh shape only
    /// when the handle says the window server's cursor seed moved.
    private func tick() {
        emitPosition()
        guard slopdesk_cursor_sampler_should_refresh(handle) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refreshOnMain() }
        }
    }

    /// The hot path. `NSEvent.mouseLocation` is a window-server query that is safe off-main and is
    /// the ONLY thing read here; everything the position depends on besides it — the window bounds,
    /// the screen height, the current shape id and its hotspot — lives behind the handle.
    private func emitPosition() {
        let mouse = NSEvent.mouseLocation // global Cocoa points, bottom-left origin
        var datagram = Data(count: CursorUpdate.encodedSize)
        let written = datagram.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return slopdesk_cursor_sampler_position(handle, mouse.x, mouse.y, base, raw.count)
        }
        // 0 means the first main-thread refresh has not landed yet, which is the deliberate gate.
        guard written == datagram.count else { return }
        updateHandler(datagram)
    }

    /// The cold path, on the main actor: read the displayed cursor and the primary screen's height,
    /// and ship a bitmap the first time a distinct shape appears. During a window raise this is
    /// delayed — the main thread is busy — but the position path keeps flowing, so the pointer
    /// never freezes and only its shape briefly lags.
    @MainActor
    private func refreshOnMain() {
        // The Cocoa-to-CG flip is anchored to the PRIMARY display whatever screen the pointer is
        // on, so this is `screens.first` and not the pointer's own screen.
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let minted = slopdesk_cursor_sampler_refresh(handle, primaryHeight)
        if minted > 0, let shapeHandler,
           let bytes = read({ out, cap in slopdesk_cursor_sampler_answer(handle, out, cap) })
        {
            if Self.debugStderr {
                FileHandle.standardError.write(Data("[cursor] mint shapeBytes=\(bytes.count)\n".utf8))
            }
            shapeHandler(bytes)
        }
        // The client switches its local pointer on the NEXT update that carries the new id, so emit
        // one immediately on a change rather than letting the shape lag by up to a sampling tick.
        if slopdesk_cursor_sampler_take_id_change(handle) {
            queue.async { [weak self] in self?.emitPosition() }
        }
    }

    /// The `docs/55` §4 two-call read, for the two doors whose answer is a parked message of a size
    /// only the handle knows: ask for the length, then lend exactly that much. The second call
    /// cannot disagree with the first — neither door mutates anything — so one retry is the whole
    /// protocol.
    private func read(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> Data? {
        let needed = call(nil, 0)
        guard needed > 0 else { return nil }
        var out = Data(count: needed)
        let written = out.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return call(base, raw.count)
        }
        guard written == needed else { return nil }
        return out
    }
}
#endif

// MacMetalLayerBackedView — the Mac's whole input + viewport half for a remote desktop: an
// `NSView` whose hosted layer clips an oversized `CAMetalLayer` sublayer (docs/56 §3, the video carve).
//
// THE VIEWPORT MODEL IS THE MAC'S, NOT SHARED. The host sends the WHOLE window every frame; the
// renderer draws it at native resolution into a layer sized to the window's POINT size, added as a
// SUBLAYER of this view's clipping backing layer. The pane is a fixed viewport that PANS by
// translating that sublayer — a compositor move, no per-frame reshader. The phone's half crops UV
// instead, because its pane IS the viewport. Two models, and `ViewportZoom`'s doc comment records
// why their zoom ladders differ (0.25 floor here, 1× there).
//
// The rules this view actuates all live in `SlopDeskVideoClient`, most already in Rust:
// `ViewportZoom` (the ladder), `ViewportPan` (reachability + clamp), `BackgroundPointerPolicy`,
// `ScrollRoutePinner`, `PinchZoomKeyPlanner`, `PinchZeroPolicy`, `SwipePeelPlanner`,
// `ModifierLatchTracker`, `StreamSizeSnap`. Nothing decides anything here.

import AppKit
import CoreImage
import CSlopDeskFFI
import Foundation
import QuartzCore
import SlopDeskVideoClient
import SlopDeskVideoProtocol

/// A layer-backed `NSView` whose backing layer is a `CAMetalLayer`, with a cursor
/// overlay layer on top. It owns the client pipeline for its lifetime.
final class MacMetalLayerBackedView: NSView {
    let videoLayer = CAMetalLayer()
    private let pipeline = VideoWindowPipeline()

    /// Whether THIS pane is the canvas's active/focused pane. Only the active pane forwards
    /// pointer/scroll to the remote window; a non-active pane routes a scroll to ``onCanvasScroll`` (so
    /// scroll navigates the canvas) and ignores hover, matching the terminal pane's `isFocusedPane` rule.
    /// Set by `MacVideoLayerView` on every render (reactive to focus changes). On change it re-applies
    /// the local cursor — a pane losing focus must drop the host shape back to the arrow even if the
    /// pointer never moved.
    var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { applyLocalCursor()
                return
            }
            applyLocalCursor()
            if isActive {
                // FOCUS CLAIM (BUG-1): this pane became the workspace-focused pane WITHOUT a click inside the
                // surface (a tab switch / pane-focus keybinding). Panes stay mounted under keep-all-mounted, so
                // the view is never remounted and `viewDidMoveToWindow`'s mount-time claim can't re-fire — claim
                // the keyboard here so typing reaches the remote window instead of the previously focused
                // (possibly hidden) terminal. Mirrors the terminal pane's `isFocusedPane` false→true path.
                claimKeyboardFocus()
                // MODIFIER RESYNC (BUG-2): a modifier genuinely still held at refocus must be re-established
                // (its down `flagsChanged` was delivered to the OLD responder), else a chord starts a key short.
                resyncModifiersFromCurrentFlags()
                // REFOCUS SHAPE RESYNC: when this pane REGAINS focus with the pointer already inside (e.g.
                // the user clicked away to a terminal pane then tabbed/clicked back), the host cursor is
                // frozen at its last-forwarded spot — hover moves aren't forwarded while inactive — so the
                // remote SHAPE is stale (an I-beam sitting over a resize edge) until the user jiggles the
                // mouse. Warp the host cursor to the LIVE pointer now so the correct shape ships next tick.
                resyncPointerToHost()
            } else {
                // MODIFIER UNLATCH (BUG-2): a modifier forwarded as down whose release we will no longer see
                // (focus moved to another pane) would stay latched in the host's shared hidSystemState event
                // source, so a later plain scroll rides ⌘ (the remote page zooms). Release them now.
                releaseLatchedModifiers()
            }
        }
    }

    /// READ-ONLY INPUT GATE. `false` ⇒ this pane is read-only: every pointer/scroll/keycode relay
    /// to the host is suppressed (gated `isActive && inputEnabled`; a drag/up forward checks `inputEnabled`
    /// alone since it only follows a `mouseDown` that already passed the gate). A click still ACTIVATES the
    /// workspace pane but is not relayed and the host window is not raised. The paste-as-keystrokes sink is
    /// withheld by the seam (a `nil` `keyInjector`). Set by `MacVideoLayerView` on every render.
    var inputEnabled: Bool = true

    /// BACKGROUND POINTER (satellite windows): `true` ⇒ this surface keeps taking pointer input while
    /// its window is NOT key — hover/scroll/click/drag forward to the host and a click leaves the
    /// window un-activated (typing stays wherever the user is working; see
    /// ``BackgroundPointerPolicy``). Threaded from the `RemotePaneContext` seam — the leaf grants it
    /// only to a DETACHED pane, so canvas panes keep the click-to-activate rule. A flip rebuilds the
    /// tracking area: its activation scope (`.activeAlways` vs `.activeInKeyWindow`) is baked in at
    /// install. Set by `MacVideoLayerView` on every render.
    var backgroundPointer: Bool = false {
        didSet {
            guard backgroundPointer != oldValue else { return }
            updateTrackingAreas()
            // Flag flips OFF while the window is NOT key with the pointer parked inside: removing the
            // `.activeAlways` area synthesizes NO mouseExited, and the replacement `.activeInKeyWindow`
            // area is inert in a not-key window — so run mouseExited's cleanup here, or `pointerInside`
            // stays stale, an in-flight edge-pan keeps panning, and the host cursor shape stays frozen
            // over the pane. (The ON direction self-heals: adding an active area under the pointer
            // synthesizes mouseEntered.)
            if !backgroundPointer, window?.isKeyWindow != true, pointerInside {
                pointerInside = false
                stopEdgePan()
                NSCursor.arrow.set()
            }
        }
    }

    // ── CURSOR (Parsec model): the host streams its cursor SHAPE (cached bitmaps); the OS draws that
    //    shape on the LOCAL cursor at the INSTANT mouse position — zero added latency, and exactly ONE
    //    cursor because macOS does NOT composite the host's RTT-delayed POSITION overlay. While the
    //    pointer is inside an ACTIVE pane and the host cursor is visible we set the host's shape; in a
    //    `.fit` letterbox margin / host-hidden-cursor / a background pane we keep the plain arrow.
    //    `pointerInside` gates the work to when the pointer is actually over this view.
    private var pointerInside = false
    /// MODIFIER LATCH (BUG-2): which modifier keyCodes this view has forwarded to the host as "down" but not
    /// yet released. On focus loss (pane blur / FR resign / window-resign-key on ⌘-Tab away) we synthesize the
    /// missing key-ups so the host's shared hidSystemState source does not keep the modifier latched (which
    /// would make a later plain scroll a ⌘-scroll = zoom). Pure logic lives in ``ModifierLatchTracker``.
    private var modifierLatch = ModifierLatchTracker()
    /// Observer token for the current window's ``NSWindow/didResignKeyNotification`` — releases any latched
    /// modifiers when the window loses key (⌘-Tab away / clicking another app) while a modifier is held, since
    /// that path delivers NO release `flagsChanged` and does NOT call `resignFirstResponder` (the view stays
    /// first responder). Re-scoped to the live window on every `viewDidMoveToWindow` (mirrors the terminal pane).
    private var windowResignKeyObserver: NSObjectProtocol?
    /// Make this pane the active pane — called at the top of `mouseDown` (click-to-activate). Sets the
    /// *workspace* focus; the host window is raised separately via `pipeline.focusWindow()`.
    var onActivate: () -> Void = {}
    /// Pan the canvas by a (sign-adjusted) delta — called from `scrollWheel` on ⌥-scroll.
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    /// 1:1 PANE SNAP: ask the canvas pane to resize its video content from `current` to `target`
    /// points so the stream renders pixel-for-pixel. `nil` ⇒ standalone (no pane). Set by the
    /// representable BEFORE ``activate(connection:)`` — its nil-ness picks pane-follows-stream
    /// vs the legacy connect-time host-follow when the session's GUI hooks are built.
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    /// PASTE AS KEYSTROKES: the canvas publishes a key-injection sink through this (and `nil` on
    /// teardown), so the pane's "Paste as Keystrokes" can drive `pipeline.key(...)` — the same
    /// secure-input-aware key path the keyboard uses. Set by the representable before `activate`.
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?
    /// RESIZE (numeric popover): the canvas publishes a resize-drive sink through this (and `nil` on
    /// teardown), so the pane's "Resize…" popover can request an ABSOLUTE host-window POINT size.
    /// `(width, height)` in host points.
    var onResizeInjectorReady: ((((Double, Double) -> Void)?) -> Void)?
    /// HOST-WINDOW RESIZE: the canvas publishes a geometry SINK through this — the view pushes the window's
    /// current + max resizable POINT sizes whenever either changes so the "Resize…" popover pre-fills +
    /// caps its fields. `(curW, curH, maxW, maxH)`; a zero max = "not yet known". Set by the representable.
    var onWindowGeometryReady: ((Double, Double, Double, Double) -> Void)?
    /// CONNECTION STATS: the canvas publishes a cadence SINK through this — the view pushes the host-announced
    /// stream fps whenever the host's FPS governor announces a new value so the sidebar's Connection section
    /// shows a per-pane "FPS" row. Set by the representable.
    var onStreamCadenceReady: ((Int) -> Void)?
    /// CONNECTION STATS: the canvas publishes a bitrate SINK through this — the view pushes the ~1 Hz
    /// client-measured video PAYLOAD bitrate (kilobits/sec) for the titlebar's stream-weight complication.
    /// Set by the representable.
    var onStreamBitrateReady: ((Int) -> Void)?
    /// NETWORK-STATS MIRROR: the canvas publishes a stats SINK through this — the view pushes the ~2 Hz
    /// client-local aggregate `(fps, fecPerSec, unrecoveredPerSec, holdMs, pacerDepth)` for the pane's
    /// stats surface. Set by the representable.
    var onNetworkStatsReady: ((Double, Double, Double, Int, Int, Double, Double, Double) -> Void)?
    /// STREAM SETTINGS: the canvas publishes a settings-drive sink through this (and `nil` on teardown;
    /// the seam binds nil while read-only — host-affecting, like the resize sink). `(fpsCap,
    /// bitrateCeilingBps)`, 0 = auto. Set by the representable.
    var onStreamSettingsInjectorReady: ((((Int, Int) -> Void)?) -> Void)?
    /// HOST AUDIO: the canvas publishes an audio enable/disable sink through this (and `nil` on
    /// teardown; the seam binds nil while read-only — host-affecting, like the stream-settings
    /// sink). Absolute `enabled`. Set by the representable.
    var onAudioInjectorReady: ((((Bool) -> Void)?) -> Void)?
    /// PRIVACY BLANK: the canvas publishes the host-display-blank enable sink through this (and `nil`
    /// on teardown; the seam binds nil while read-only). Absolute `enabled`. Set by the representable.
    var onPrivacyInjectorReady: ((((Bool) -> Void)?) -> Void)?
    /// SYSTEM-KEY INJECTOR: the canvas publishes a programmatic key sink through this (and `nil` on
    /// teardown; the seam binds nil while read-only — host input, like the paste-keystrokes sink).
    /// `(keyCode, modifierFlags [raw NSEvent flags], isDown)`. Set by the representable.
    var onSystemKeyInjectorReady: ((((UInt16, UInt64, Bool) -> Void)?) -> Void)?
    /// STALL SCRIM: the canvas publishes a stall SINK through this — the view pushes the pipeline's stall
    /// flips (`true` ⇒ host silent past threshold, show "Reconnecting…"; `false` ⇒ traffic resumed) so the
    /// pane can overlay/clear its scrim. Set by the representable.
    var onStreamStallReady: ((Bool) -> Void)?
    /// TERMINAL REFUSAL: the canvas publishes a rejection SINK through this — the view fires it once
    /// after the host rejected the session (`helloAck(accepted: false)`), the pipeline having already
    /// torn down with NO auto-rebuild, so the pane model can fall back to the picker/error state.
    /// Set by the representable.
    var onSessionRejectedReady: (() -> Void)?
    /// VIEWPORT CONTROLS: the canvas publishes a client-viewport command sink through this (and `nil` on
    /// teardown), so the pane's bottom control bar drives zoom / pan-lock. The byte is `RemoteWindowModel.
    /// ViewportCommand` (0 zoom-in / 1 zoom-out / 2 reset / 3 lock-on / 4 lock-off / 5 fit-to-pane).
    /// Set by the representable.
    var onViewportInjectorReady: ((((UInt8) -> Void)?) -> Void)?
    /// RELEASE STUCK INPUT (C5): the canvas publishes a zero-arg release sink through this (and `nil` on
    /// teardown; the seam binds nil while read-only) — the palette's chord-less escape hatch fires it to
    /// synthesize a key-UP for every held modifier + a mouse-UP for every button. Set by the representable.
    var onInputReleaseReady: (((() -> Void)?) -> Void)?

    /// Hands the canvas a key-injection closure routed to THIS view's pipeline (Shift folded into the
    /// modifiers; `pipeline.key` no-ops until the session is up). Idempotent — safe to call on every
    /// render; the sink captures `self` weakly so a torn-down view injects nothing.
    func publishKeyInjector() {
        onKeyInjectorReady? { [weak self] keyCode, down, shift in
            self?.pipeline.key(keyCode: keyCode, down: down, modifiers: shift ? .shift : [])
        }
    }

    /// Hands the canvas a resize-drive closure routed to THIS view's pipeline: an ABSOLUTE host-window
    /// POINT size the session debounce-requests. `self` weak so a torn-down view resizes nothing.
    func publishResizeInjector() {
        onResizeInjectorReady? { [weak self] width, height in
            self?.pipeline.userResizeTo(width: width, height: height)
        }
    }

    /// Hands the canvas a stream-settings drive routed to THIS view's pipeline (fps cap / bitrate
    /// ceiling, 0 = auto; the session stores + re-sends after every re-hello). `self` weak so a
    /// torn-down view requests nothing. Idempotent — safe to call on every render.
    func publishStreamSettingsInjector() {
        onStreamSettingsInjectorReady? { [weak self] fpsCap, bitrateCeilingBps in
            self?.pipeline.updateStreamSettings(fpsCap: fpsCap, bitrateCeilingBps: bitrateCeilingBps)
        }
    }

    /// Hands the canvas an audio enable/disable drive routed to THIS view's pipeline (the session
    /// stores the wish and re-sends it after every re-hello). `self` weak so a torn-down view
    /// drives nothing. Idempotent — safe to call on every render.
    func publishAudioInjector() {
        onAudioInjectorReady? { [weak self] enabled in
            self?.pipeline.setAudioEnabled(enabled)
        }
    }

    /// Hands the canvas a privacy enable/disable drive routed to THIS view's pipeline (the session
    /// stores the wish and re-sends it after every re-hello). `self` weak so a torn-down view drives
    /// nothing. Idempotent — safe to call on every render.
    func publishPrivacyInjector() {
        onPrivacyInjectorReady? { [weak self] enabled in
            self?.pipeline.setPrivacyEnabled(enabled)
        }
    }

    /// Hands the canvas a programmatic key drive routed through the SAME `pipeline.key` path the
    /// local `keyDown`/`keyUp` overrides use, so an injected key is indistinguishable on the wire
    /// from a typed one. The raw flags are the caller's `NSEvent.ModifierFlags.rawValue` (UInt64 at
    /// the headless seam); the mapping to ``InputModifiers`` is the keyboard path's own
    /// ``modifiers(_:)``. `self` weak so a torn-down view injects nothing. Idempotent.
    func publishSystemKeyInjector() {
        onSystemKeyInjectorReady? { [weak self] keyCode, rawModifierFlags, isDown in
            let flags = NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: rawModifierFlags))
            self?.pipeline.key(keyCode: keyCode, down: isDown, modifiers: Self.modifiers(flags))
        }
    }

    /// Hands the canvas a client-viewport command closure routed to THIS view (zoom the compositor sublayer /
    /// freeze the edge-pan). `self` weak so a torn-down view does nothing. Idempotent.
    func publishViewportInjector() {
        onViewportInjectorReady? { [weak self] command in self?.handleViewportCommand(command) }
    }

    /// Hands the canvas the RELEASE STUCK INPUT closure (C5) routed to THIS view. `self` weak so a
    /// torn-down view releases nothing. Idempotent — safe to call on every render.
    func publishInputReleaseInjector() {
        onInputReleaseReady? { [weak self] in self?.releaseAllStuckInput() }
    }

    /// RELEASE STUCK INPUT (C5, the manual escape hatch): synthesize a key-UP for EVERY held-modifier
    /// keyCode (left/right ⌘⇧⌃⌥ + fn — not only the locally-latched ones; the point is a HOST stuck
    /// despite the automatic paths) plus a mouse-UP for every button, through the same send paths the
    /// automatic synthetic releases use. Each modifier key-up rides the loss-resilient redundant send
    /// (`keySendCount`) and each mouse-up the `redundantUpCount` burst; the host's `InputButtonBalance`
    /// suppresses whichever releases are no-ops there (an already-up modifier / button posts nothing),
    /// so firing this on a healthy session is harmless. The local latch is drained first so the
    /// client's own bookkeeping agrees that nothing is held. Read-only panes never reach here (the seam
    /// withholds the sink), but keep the `inputEnabled` gate as belt-and-braces.
    private func releaseAllStuckInput() {
        guard inputEnabled else { return }
        _ = modifierLatch.drainForRelease()
        for keyCode in InputModifierKeys.heldModifierKeyCodes.sorted() {
            pipeline.key(keyCode: keyCode, down: false, modifiers: [])
        }
        liftAllButtons()
    }

    /// A mouse-UP for every button, unconditionally. Its own method because ``deactivate()`` needs the
    /// same thing and a second copy of a three-line loop is how two teardown paths stop agreeing.
    ///
    /// LEDGER-FREE on purpose: this half tracks no held-button set, and does not need one, because the
    /// host suppresses a `MouseUp` for a button it is not holding — nothing is posted, so a blind lift
    /// on a healthy session is a no-op on the far side. The release POSITION is immaterial to
    /// un-sticking (the target app just ends its tracking); the pane centre keeps it inside the
    /// captured window. A ledger would buy only releasing at the last drag point, which is the thing
    /// that comment already rules immaterial.
    private func liftAllButtons() {
        let centre = VideoPoint(x: Double(bounds.midX), y: Double(bounds.midY))
        for button in [MouseButton.left, .right, .other] {
            pipeline.mouseUp(button, centre, 1, [])
        }
    }

    /// Apply one viewport command from the footer control bar (the `RemoteWindowModel.ViewportCommand` byte:
    /// 0 zoom-in / 1 zoom-out / 2 reset / 3 lock-on / 4 lock-off / 5 fit-to-pane). The lock commands are
    /// ABSOLUTE (not a toggle): the model owns the lock state and RE-ASSERTS it on every sink publish (a
    /// detach/reattach re-binds the same model to a fresh, unlocked view), so a redundant re-assert must be
    /// idempotent here.
    private func handleViewportCommand(_ command: UInt8) {
        // PAN LOCK gates every pan-moving command HERE, not only at the footer buttons: zoom
        // re-anchors `panOffset` and reset/fit re-anchor top-left, so any of them would silently
        // defeat a held lock — and palette/chord-originated commands reach this handler directly.
        // While locked, they no-op entirely; only the lock commands themselves still apply.
        switch command {
        case 0 where !panLocked: applyZoomStep(stepIn: true)
        case 1 where !panLocked: applyZoomStep(stepIn: false)
        case 2 where !panLocked: applyResetZoom() // 1× + re-anchor top-left
        case 3: // "lock position" ON (freeze edge-pan)
            panLocked = true
            stopEdgePan()
        case 4: // "lock position" OFF (resume edge-pan on the next hover)
            panLocked = false
        case 5 where !panLocked: applyFitToPane() // zoom so the whole window fits inside the pane
        default: break
        }
    }

    /// Step ``clientZoom`` one rung along ``ViewportZoom`` and re-anchor so the PANE CENTRE stays fixed
    /// across the zoom — you zoom toward the middle of what you're looking at. A no-op until the host
    /// window's point size is known (`streamPoints`). The ladder itself (bounds, step, unity snap) is
    /// ``ViewportZoom``'s; this keeps only the re-anchor, which needs the live pane geometry.
    private func applyZoomStep(stepIn: Bool) {
        guard let win = streamPoints, win.width > 1, win.height > 1 else { return }
        let oldZoom = clientZoom
        let newZoom = CGFloat(ViewportZoom.stepped(Double(oldZoom), stepIn: stepIn))
        guard newZoom != oldZoom else { return }
        // The displayed window size is native × zoom; keep the pane-centre texture fraction constant.
        let oldDisplayed = ViewportZoom.displayedSize(window: win, zoom: Double(oldZoom))
        let centreFracX = (panOffset.x + bounds.width / 2) / CGFloat(Double.maximum(oldDisplayed.width, 1))
        let centreFracY = (panOffset.y + bounds.height / 2) / CGFloat(Double.maximum(oldDisplayed.height, 1))
        clientZoom = newZoom
        let newDisplayed = ViewportZoom.displayedSize(window: win, zoom: Double(newZoom))
        panOffset.x = centreFracX * CGFloat(newDisplayed.width) - bounds.width / 2
        panOffset.y = centreFracY * CGFloat(newDisplayed.height) - bounds.height / 2
        needsLayout = true
        layoutVideoLayer() // clamps panOffset to the new overflow + republishes the input viewport
    }

    /// Bridge to the SwiftUI control overlay; the SwiftUI view owns it. Set by the
    /// representable before `activate`.
    weak var controls: MacVideoPaneControls?

    // ── ACTUAL-SIZE VIEWPORT (RealVNC-mobile). The host sends + the client decodes the WHOLE
    //    window every frame; the renderer draws the whole window at its native resolution into `videoLayer`,
    //    which is sized to the window's POINT size and added as a SUBLAYER of this view's clipping backing
    //    layer. The pane is a fixed viewport: we PAN by translating `videoLayer` (a compositor move — smooth,
    //    no per-frame reshader) instead of cropping the texture. Edge-hover drives the translation. The
    //    visible sub-rect is reported to the session as a `viewportCrop` so a pane click maps to the right
    //    host pixel. Window point size arrives via `onDecodedPointsChanged`.
    /// The host window's current POINT size. `nil` until the first decoded frame (then the layer is sized).
    private var streamPoints: VideoSize?
    /// HOST-WINDOW RESIZE: the host-reported MAX resizable POINT size (its display bounds). `nil` until the
    /// host's `displayMax` lands; the "Resize…" popover leaves its fields uncapped until then.
    private var displayMaxPoints: VideoSize?
    /// The viewport's top-left offset INTO the window, in WINDOW POINTS (top-left origin, +y down). `(0,0)`
    /// = the window's top-left corner (default). Clamped to `[0, max(0, window − pane)]`; pan moves it.
    private var panOffset: CGPoint = .zero
    /// Whether the user has explicitly PANNED (edge-pan). Until then the offset stays at the window top-left
    /// (the default anchor, not centred); the 1× reset clears it.
    private var viewportTouched = false
    /// CLIENT ZOOM factor (1.0 = actual-size, >1 zoomed-in, <1 minified), driven by the footer zoom controls.
    /// Pure COMPOSITOR scale: the video sublayer FRAME is scaled by this while the drawable stays at the
    /// native window pixel size (CA scales the native-res texture — no reshader, no host round-trip). Clamped
    /// to ``ViewportZoom``'s ladder; the 1× reset clears it. The decoded frame is native-res, so zoom-in magnifies
    /// (interpolated beyond native) and zoom-out minifies crisply.
    private var clientZoom: CGFloat = 1.0
    /// PAN LOCK ("lock position"): when true the edge-hover auto-pan is FROZEN — the viewport stays put even as
    /// the pointer nudges the pane edges. A MIRROR of ``RemoteWindowModel/viewportLocked`` (the source of
    /// truth behind the footer lock control + the ⌥⌘L chord), driven by the absolute `lockOn`/`lockOff`
    /// viewport commands so the model can re-assert it into a fresh view; clears the pan timer on engage.
    private var panLocked = false

    // ── EDGE-PAN (RealVNC-mobile): nudging the pointer into a pane edge auto-translates the video layer
    //    toward that edge so you can reach off-screen window content without a scroll gesture. Driven by a
    //    `.common`-mode timer (a default-mode timer would freeze during event tracking). Inert when the
    //    window fits inside the pane.
    private var edgePanTimer: Timer?
    private var edgePanVelocity: CGPoint = .zero
    /// Last pointer position in this view's coordinates (AppKit, origin bottom-left) — re-forwarded each
    /// edge-pan tick so the host cursor follows into the newly revealed region while the content scrolls.
    private var lastPointerView: CGPoint = .zero
    /// Pane-edge band width (points) within which the pointer triggers an auto-pan.
    private static let edgePanThreshold: CGFloat = 44
    /// Full-penetration pan speed (WINDOW POINTS per second) at the pane border.
    private static let edgePanPointsPerSec: Double = 1600

    // ── SWIPE-PEEL feedback (doc 05 §8): a local mirror of the HOST's swipe-nav recogniser gives
    //    the one piece of native swipe-back a key translation can't — something reacting WHILE
    //    the fingers are on the glass. The feedback is the edge chip + haptic ONLY: the streamed
    //    image never moves (v6 HW verdict — a remote pane is a window onto a whole desktop, so
    //    any translation of it reads as dragging the pane, not peeling a page). The host stays
    //    the sole authority on firing ⌘[/⌘].
    private var peelPlanner = SwipePeelPlanner()
    /// The host's swipe-nav operating point (cursor-socket type=3 push). `nil` until the first
    /// push — an old host never shows the overlay, so the affordance can't lie.
    private var peelStatus: SwipeNavStatusMessage?
    /// Rising-edge tracker for the commit haptic (tap once when "release now navigates" starts).
    private var peelChipCommitted = false
    /// Delayed clear of the confirm-pulse chip after a fire.
    private var peelConfirmClear: Task<Void, Never>?
    /// Per-gesture remote-vs-canvas routing pin (see ``ScrollRoutePinner``): an ⌥ press/release
    /// mid-gesture must not reroute the momentum tail.
    private var scrollRoutePinner = ScrollRoutePinner()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The video layer is an oversized SUBLAYER (sized to the whole remote window) of a CLIPPING backing
        // layer, so we can translate it for panning while the pane masks the overflow — making it the
        // backing layer directly would leave nothing to clip the overflow against.
        wantsLayer = true
        // MERIDIAN DRAIN: allow CI filters on the layer tree (the stall desaturation below). The flag alone
        // does not change the live compositing path — the expensive in-process render kicks in only while a
        // filter is actually ATTACHED, and we attach one only over a STALLED (frozen, no new presents) frame,
        // so the 60fps hot path never pays for it.
        layerUsesCoreImageFilters = true
        let host = CALayer()
        host.masksToBounds = true
        host.addSublayer(videoLayer)
        layer = host
    }

    /// MERIDIAN L1 — "colour is live data, grayscale is the past": while the stream is STALLED the frozen
    /// last frame drains to grayscale (slightly darkened), so the material itself says "this is the past"
    /// instead of a dim veil hiding it. Applied to `videoLayer` (the cursor overlay is its sublayer, so it
    /// drains with the surface — correct: the whole picture is stale). Removed the instant traffic resumes;
    /// sticky through the self-heal rebuild exactly like the stall latch that drives it.
    private func applyStallDrain(_ stalled: Bool) {
        if stalled {
            guard let drain = CIFilter(
                name: "CIColorControls",
                parameters: [kCIInputSaturationKey: 0.0, kCIInputBrightnessKey: -0.06],
            ) else { return }
            drain.name = "stallDrain"
            videoLayer.filters = [drain]
        } else {
            videoLayer.filters = nil
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func activate(connection: VideoWindowConnection?) {
        // 1:1 PANE SNAP — wire BEFORE pipeline.activate: the session decides pane-follows-stream
        // (snap) vs the legacy connect-time host-follow by whether this hook exists when the GUI
        // hooks are built. The closure reads the live `onStreamNativeSize`, so updateNSView
        // refreshing the seam closure stays picked up without re-activation.
        pipeline.onStreamNativePoints = onStreamNativeSize == nil ? nil : { [weak self] points in
            self?.adoptStreamNativePoints(points)
        }
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
        // Re-apply the local cursor when the host SWAPS shape, or when the host cursor enters/leaves the
        // captured window (visible flip) — so the pointer shape tracks the remote with no RTT lag.
        pipeline.onServerCursorVisibilityChanged = { [weak self] _ in self?.applyLocalCursor() }
        pipeline.onRemoteCursorChanged = { [weak self] in self?.applyLocalCursor() }
        // ACTUAL-SIZE VIEWPORT: learn the host window's point size, size the video layer to it, lay out.
        pipeline.onDecodedPointsChanged = { [weak self] points in
            guard let self else { return }
            streamPoints = points
            needsLayout = true
            layoutVideoLayer()
            publishWindowGeometry() // the popover's current-size pre-fill tracks the live window size
        }
        // HOST-WINDOW RESIZE: learn the captured window's display max so the "Resize…" popover caps its
        // fields at a size the remote can actually adopt.
        pipeline.onDisplayMaxChanged = { [weak self] points in
            guard let self else { return }
            displayMaxPoints = points
            publishWindowGeometry()
        }
        // SWIPE-PEEL: adopt the host's swipe-nav operating point (eligibility + recogniser knobs)
        // so the feedback mirror always predicts what the host will actually do.
        pipeline.onSwipeNavStatusChanged = { [weak self] status in self?.adoptSwipeNavStatus(status) }
        // CONNECTION STATS: forward the host-announced stream cadence to the model's FPS row (no-op if unbound).
        pipeline.onStreamCadenceChanged = { [weak self] fps in self?.onStreamCadenceReady?(fps) }
        pipeline.onStreamBitrateChanged = { [weak self] kbps in self?.onStreamBitrateReady?(kbps) }
        // NETWORK-STATS MIRROR: flatten the snapshot to primitives at the seam (the model side is
        // headless — it never imports this module's types). No-op if unbound.
        pipeline.onNetworkStatsChanged = { [weak self] snapshot in
            self?.onNetworkStatsReady?(
                snapshot.framesPerSecond,
                snapshot.fecRecoveredPerSecond,
                snapshot.unrecoveredPerSecond,
                snapshot.holdMillis,
                snapshot.pacerDepth,
                snapshot.rttMillis,
                snapshot.encodeMillis,
                snapshot.decodeMillis,
            )
        }
        // STALL: drain THIS surface to grayscale (MERIDIAN L1 — the material says "stale", see
        // `applyStallDrain`) and forward the flip to the pane model (→ the corner age caption; no-op if
        // unbound). The closure reads the live `onStreamStallReady`, so updateNSView refreshing the seam
        // closure is picked up.
        pipeline.onStreamStallChanged = { [weak self] stalled in
            self?.applyStallDrain(stalled)
            self?.onStreamStallReady?(stalled)
        }
        // TERMINAL REFUSAL: forward the host's rejection to the pane model (→ picker/error state; no-op
        // if unbound). The pipeline already tore itself down with NO auto-rebuild before firing. The
        // closure reads the live `onSessionRejectedReady`, so updateNSView refreshing the seam closure
        // is picked up.
        pipeline.onSessionRejected = { [weak self] in self?.onSessionRejectedReady?() }
        // Wire the SwiftUI overlay's buttons to THIS view's pipeline (live connection only). No fit/fill
        // toggle: the ACTUAL-SIZE viewport auto-drives content mode, so only the 1× reset wires.
        if connection != nil, let controls {
            controls.onResetZoom = { [weak self] in self?.applyResetZoom() }
            controls.mode = pipeline.contentMode
        }
    }

    /// HOST-WINDOW RESIZE: push the window's current + max resizable POINT sizes to the canvas (→ model)
    /// so the "Resize…" popover pre-fills its fields at the current size and caps them at the remote max.
    /// A zero max (display max not yet reported) tells the model to leave the field uncapped. No-op until
    /// the current size is known (first decoded frame) or when no canvas wired the sink.
    private func publishWindowGeometry() {
        guard let cur = streamPoints else { return }
        onWindowGeometryReady?(cur.width, cur.height, displayMaxPoints?.width ?? 0, displayMaxPoints?.height ?? 0)
    }

    func deactivate() {
        if pointerInside { NSCursor.arrow.set() } // restore the arrow before the pipeline tears down
        pointerInside = false
        abandonSwipePeel() // never strand a mid-gesture chip across a teardown
        // …nor a 60 Hz timer. `viewWillMove(toWindow: nil)` says the same thing and is not the whole
        // cover: `MacVideoSurfaceHost.detachSurface()` arrives here with no window change.
        stopEdgePan()
        // Forget the host's eligibility across a teardown: a remounted surface must stay dark
        // until the NEXT status push (≤2 s heartbeat) instead of trusting a stale operating
        // point from a possibly-restarted host (audit: stale-eligible window).
        peelStatus = nil
        // Deliberately NO nil-publish of the injector sinks here: `RemoteWindowModel.close()` clears its
        // own sinks (model lifecycle, always BEFORE a re-open in store order). During a pane
        // detach/reattach the SAME model is re-bound by a replacement view in ANOTHER hosting root, and
        // SwiftUI may dismantle THIS view AFTER that view already published fresh sinks — an
        // unconditional nil-publish here would silently kill the new surface's input.
        //
        // NEVER STRAND A BUTTON OR A MODIFIER ON THE HOST. Its event source is process-global, so a
        // left button left down by a pane dismantled mid-drag outlives the pane and every later click
        // arrives as a drag. This half used to release neither, and `viewWillMove(toWindow:)` is not
        // the cover it looks like: it fires only on a window CHANGE, covers modifiers only, and
        // `MacVideoSurfaceHost.detachSurface()` reaches here with no window change at all. The phone's
        // `deactivate()` has taken this bargain since it shipped; this is the same bargain, and it is
        // best-effort by nature — the outbound FIFO stops inside `pipeline.deactivate()` below.
        releaseLatchedModifiers()
        if inputEnabled { liftAllButtons() }
        pipeline.deactivate()
    }

    /// 1:1 PANE SNAP: the stream's decoded size changed (first frame, or the host re-captured
    /// after a window resize). The session already converted it to the HOST WINDOW's POINT size
    /// (`points`, = decoded pixels / the inferred host captureScale — NOT the client contentsScale,
    /// which halved the pane on a 1× capture). Rebase the session's resize debounce on it FIRST
    /// (so the snap-induced layout pass holds instead of echoing a `resizeRequest` back to the
    /// host — the snap is client-side only), then ask the canvas pane to adopt it. Skips the pane
    /// mutation for a sub-half-point delta (already at the native size; the rebase alone suffices).
    private func adoptStreamNativePoints(_ points: VideoSize) {
        guard let handler = onStreamNativeSize else { return }
        pipeline.adoptLayerSize(points)
        let current = VideoSize(width: Double(bounds.width), height: Double(bounds.height))
        guard StreamSizeSnap.shouldSnap(target: points, current: current) else { return }
        videoViewDbg(
            "1:1 snap → video \(Int(current.width))x\(Int(current.height)) → \(Int(points.width))x\(Int(points.height))pt (host window points)",
        )
        handler(
            CGSize(width: points.width, height: points.height),
            CGSize(width: current.width, height: current.height),
        )
    }

    // MARK: Local cursor (Parsec model — host shape on the instant local pointer)

    /// Sets the local OS cursor to the host's CURRENT shape while the pointer is inside an ACTIVE pane
    /// and the host cursor is visible there; otherwise the plain arrow. The OS draws it at the live mouse
    /// position so there's no RTT lag, and macOS composites no host-position overlay so there's no
    /// duplicate. No-op unless the pointer is over this view (so a shape swap elsewhere can't hijack the
    /// global cursor).
    private func applyLocalCursor() {
        guard pointerInside else { return }
        if BackgroundPointerPolicy.forwardsPointer(isActive: isActive, backgroundPointer: backgroundPointer),
           pipeline.isServerCursorVisible, let cursor = pipeline.currentRemoteCursor
        {
            cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Forward `winLoc` (window-space, as delivered by `NSEvent.locationInWindow`) to the host as a
    /// bare mouse-move so the host cursor WARPS to the client pointer — resyncing the remote cursor
    /// SHAPE without waiting for the next hover move. Gated exactly like `mouseMoved`.
    private func forwardPointer(atWindowLocation winLoc: NSPoint) {
        guard BackgroundPointerPolicy.forwardsPointer(isActive: isActive, backgroundPointer: backgroundPointer),
              inputEnabled else { return }
        let p = convert(winLoc, from: nil)
        pipeline.mouseMove(VideoPoint(x: Double(p.x), y: Double(bounds.height - p.y)))
    }

    /// Resync WITHOUT an event (a tab/keyboard refocus where the pointer is already inside and never
    /// moved): read the live pointer from the window and warp the host cursor to it, so a refocused
    /// pane doesn't sit on a stale host cursor shape until the user jiggles the mouse.
    private func resyncPointerToHost() {
        guard pointerInside, let window else { return }
        forwardPointer(atWindowLocation: window.mouseLocationOutsideOfEventStream)
    }

    /// FOCUS CLAIM (BUG-1): make this view first responder so the keyboard follows workspace focus. Deferred
    /// off the SwiftUI update/commit pass (a synchronous `makeFirstResponder` rebuilds the AppKit responder
    /// chain and stalls the main thread inside `updateNSView` on a tab/pane switch) and guarded so a pane that
    /// lost focus again before the hop, or is already first responder, is a no-op. Mirrors the terminal pane.
    private func claimKeyboardFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, isActive, let window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    /// MODIFIER UNLATCH (BUG-2): synthesize a host key-up for every modifier this view forwarded as down but
    /// whose release `flagsChanged` it will not see (focus moved away), clearing the host's latched flag so a
    /// subsequent scroll / mouse-move (which carry no explicit flags) is not treated as modifier-held. Idempotent
    /// — a no-op when nothing is latched. Uses an empty modifier mask so the emitted key-up itself clears cleanly.
    private func releaseLatchedModifiers() {
        for keyCode in modifierLatch.drainForRelease() {
            pipeline.key(keyCode: keyCode, down: false, modifiers: [])
        }
    }

    /// MODIFIER RESYNC (BUG-2): on regaining focus, re-establish any modifier that is STILL physically held —
    /// its down `flagsChanged` went to the previously focused responder, so without this the host would not
    /// know the modifier is down (a chord would start a key short). Reads the live global flags (there is no
    /// event on a keyboard/tab refocus). Gated exactly like the other relays (`isActive && inputEnabled`).
    private func resyncModifiersFromCurrentFlags() {
        guard isActive, inputEnabled else { return }
        let flags = NSEvent.modifierFlags
        let modifiers = Self.modifiers(flags)
        for keyCode in LocalInputPolicy.heldModifierKeyCodes(modifiers) where !modifierLatch.isDown(keyCode) {
            modifierLatch.note(keyCode: keyCode, down: true)
            pipeline.key(keyCode: keyCode, down: true, modifiers: modifiers)
        }
    }

    override func layout() {
        super.layout()
        layer?.masksToBounds = true // clip the oversized video sublayer to the pane
        layoutVideoLayer()
        // session.layerSize = the PANE point size (the input/cursor denominator). The DRAWABLE pixel size is
        // owned by `layoutVideoLayer()` (window-sized); the pipeline does not touch it.
        pipeline.layoutChanged(layerSize: VideoSize(width: Double(bounds.width), height: Double(bounds.height)))
    }

    /// ACTUAL-SIZE VIEWPORT: size + position the oversized video sublayer. It is sized to the remote
    /// window's POINT size (so the renderer draws the WHOLE window at native res into a window-sized
    /// drawable), and positioned so the visible pane shows the region at `panOffset` (top-left anchored by
    /// default). Pure compositor geometry — panning later just moves this layer, no reshader. Falls back to
    /// filling the pane until the window size is known.
    private func layoutVideoLayer() {
        // layer-HOSTING views (we assign `layer`) are NOT auto-promoted to the window's backing scale, so set
        // contentsScale from `backingScaleFactor` (never hardcode 2 — 1× externals/Sidecar); fall back to the
        // last good value so a window==nil teardown layout never drops to 1×.
        let scale = window?.backingScaleFactor ?? videoLayer.contentsScale
        layer?.contentsScale = scale
        videoLayer.contentsScale = scale
        // No implicit position/size animation — panning sets these directly each tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let win = streamPoints, win.width > 1, win.height > 1, bounds.width > 1, bounds.height > 1 else {
            // No stream geometry yet → fill the pane (the renderer aspect-fits the first frames).
            videoLayer.frame = bounds
            videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            return
        }
        // The DISPLAYED window size is the native point size × the client zoom (a compositor scale of the
        // sublayer FRAME); the drawable stays at the NATIVE pixel size below, so CA scales the native-res
        // texture — no reshader. `dw`/`dh` drive the frame; `win` drives the drawable.
        let displayed = ViewportZoom.displayedSize(window: win, zoom: Double(clientZoom))
        let dw = CGFloat(displayed.width), dh = CGFloat(displayed.height)
        // Clamp the pan offset to the overflow on each axis (0 when the zoomed window fits → top-left
        // anchored). Through `ViewportPan`, which `stepEdgePan` already clamps with — re-deriving
        // `displayed − pane` here is how the layer position and the edge-pan limit drift apart.
        let maxPan = ViewportPan.maxPanOffset(
            window: win,
            pane: VideoSize(width: Double(bounds.width), height: Double(bounds.height)),
            zoom: Double(clientZoom),
        )
        if !viewportTouched, clientZoom == 1 { panOffset = .zero } // only auto-anchor at the untouched 1× default
        panOffset.x = CGFloat(Double.minimum(Double.maximum(Double(panOffset.x), 0), maxPan.x))
        panOffset.y = CGFloat(Double.minimum(Double.maximum(Double(panOffset.y), 0), maxPan.y))
        // Position (parent layer is bottom-left origin): origin.x = −panOffset.x; origin.y places the window
        // TOP at the pane top and reveals lower content as panOffset.y grows (derived for y-down panOffset).
        videoLayer.frame = CGRect(x: -panOffset.x, y: bounds.height - dh + panOffset.y, width: dw, height: dh)
        videoLayer.drawableSize = CGSize(width: CGFloat(win.width) * scale, height: CGFloat(win.height) * scale)
        publishInputViewport()
    }

    /// Report the currently-visible texture sub-rect (UV) to the session so a pane click maps to the right
    /// host pixel. `origin = panOffset / window`, `size = pane / window` (size may exceed 1 when the window
    /// is smaller than the pane — `normalize` then clamps a click outside the window, which is correct).
    private func publishInputViewport() {
        guard let win = streamPoints, win.width > 1, win.height > 1 else { pipeline.setInputViewport(nil)
            return
        }
        // The visible sub-rect is reported in TEXTURE (native-window) fractions. With zoom the displayed window
        // is native × zoom, so divide the display-space pan offset / pane size by the DISPLAYED size `dw`/`dh`
        // (= native × zoom) — equivalent to dividing the texture-space offset by the native size.
        let displayed = ViewportZoom.displayedSize(window: win, zoom: Double(clientZoom))
        let dw = displayed.width, dh = displayed.height
        pipeline.setInputViewport(VideoRect(
            x: Double(panOffset.x) / dw,
            y: Double(panOffset.y) / dh,
            width: Double(bounds.width) / dw,
            height: Double(bounds.height) / dh,
        ))
        controls?.zoomed = viewportTouched || clientZoom != 1
    }

    /// Fires on window-attach and when the view moves between Retina/non-Retina displays.
    /// Re-syncs the hosted layer's scale and re-lays-out so the drawable is sized for the new
    /// backing scale (the initial scale is set in `layout()`; this keeps it correct across moves).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard window != nil else { return } // can fire with window==nil during teardown
        videoLayer.contentsScale = window?.backingScaleFactor ?? videoLayer.contentsScale
        needsLayout = true
    }

    // MARK: Local navigation (pan) — responder methods, never gesture recognizers

    // MARK: Pinch / smart-zoom → key translation (`SLOPDESK_PINCH_KEYS`, default ON; `=0` off)

    /// No public API can synthesise a real `magnify` gesture on the host, so the pinch is
    /// translated into the near-universal zoom key equivalents and rides the existing key path
    /// (no wire change; accumulation lives in the pure ``PinchZoomKeyPlanner``). The pane itself
    /// never zooms from a pinch — it is a fixed ACTUAL-SIZE viewport (footer zoom + edge-pan own
    /// local navigation), so the gesture's only meaning here is REMOTE zoom.
    private static let pinchKeysEnabled = EnvConfig.boolDefaultOn("SLOPDESK_PINCH_KEYS")
    /// The bound remote app's DISPLAY NAME (`RemoteWindowDescriptor.appName` — picker style,
    /// "Xcode"/"Google Chrome"); empty for a desktop pane or a legacy binding. Only consulted
    /// by the smart-zoom ⌘0 gate (``PinchZeroPolicy``) — everything else is app-agnostic.
    var targetAppName = ""
    /// ANSI key POSITIONS (HIToolbox `kVK_ANSI_*`), interpreted by the host layout like any
    /// forwarded keystroke.
    private static let keyEqual: UInt16 = 0x18 // kVK_ANSI_Equal → ⌘= zoom in
    private static let keyMinus: UInt16 = 0x1B // kVK_ANSI_Minus → ⌘− zoom out
    private static let keyZero: UInt16 = 0x1D // kVK_ANSI_0 → ⌘0 actual size
    private static let keyCommandModifier: UInt16 = 0x37 // kVK_Command — the chord bracket
    private static let keyRightCommandModifier: UInt16 = 0x36 // kVK_RightCommand — same latch
    private var pinchPlanner = PinchZoomKeyPlanner()

    /// Two-finger pinch → ⌘= / ⌘− steps on the HOST. Unlike scroll (which follows the pointer), a
    /// pinch is a zoom COMMAND: only the ACTIVE, writable pane forwards; an unfocused or read-only
    /// pane swallows the pinch (it must not perturb local geometry either).
    override func magnify(with event: NSEvent) {
        guard isActive, inputEnabled, Self.pinchKeysEnabled else { return }
        if event.phase.contains(.began) { pinchPlanner.begin() }
        let steps = pinchPlanner.ingest(magnification: Double(event.magnification))
        guard steps != 0 else { return }
        for _ in 0..<abs(steps) {
            sendHostChord(keyCode: steps > 0 ? Self.keyEqual : Self.keyMinus)
        }
    }

    /// Two-finger double-tap (smart zoom) → ⌘0 (actual size / reset zoom) on the HOST — the
    /// natural pairing with the pinch's ⌘= / ⌘− ladder. Skipped where ⌘0 is NOT a zoom reset
    /// (``PinchZeroPolicy`` — Xcode toggles its Navigator with it); ⌘=/⌘− stay ungated, they
    /// are the correct zoom chords in editors too.
    override func smartMagnify(with _: NSEvent) {
        guard isActive, inputEnabled, Self.pinchKeysEnabled else { return }
        guard PinchZeroPolicy.allowsReset(appName: targetAppName) else { return }
        sendHostChord(keyCode: Self.keyZero)
    }

    /// Emits one synthetic ⌘-chord as a BRACKETED sequence — real ⌘ key down, the letter pair
    /// flagged, the ⌘ release with EMPTY flags — never a bare flagged pair: the host posts
    /// forwarded keys onto the shared `.hidSystemState` source, where a flagged pair with no
    /// modifier release LATCHES ⌘ onto every later flag-less synthetic event (scrolls → browser
    /// zoom; probe-verified). Byte-shaped like a real user chord (`flagsChanged` forwards the
    /// modifier edges exactly this way).
    ///
    /// EXCEPT while the user PHYSICALLY holds ⌘ (either side — `modifierLatch` tracks the real
    /// edges): the host already has the real latch, and a synthetic ⌘-up would be consumed by the
    /// host's balance as the one legitimate release — the user's actual release later dedupes
    /// away, stranding the host un-⌘'d mid-hold. Ride the real modifier: letter pair only.
    private func sendHostChord(keyCode: UInt16) {
        let commandHeld = modifierLatch.isDown(Self.keyCommandModifier)
            || modifierLatch.isDown(Self.keyRightCommandModifier)
        if !commandHeld { pipeline.key(keyCode: Self.keyCommandModifier, down: true, modifiers: .command) }
        pipeline.key(keyCode: keyCode, down: true, modifiers: .command)
        pipeline.key(keyCode: keyCode, down: false, modifiers: .command)
        if !commandHeld { pipeline.key(keyCode: Self.keyCommandModifier, down: false, modifiers: []) }
    }

    /// 1× reset → restore actual-size zoom AND re-anchor the viewport to the window's TOP-LEFT.
    private func applyResetZoom() {
        viewportTouched = false
        clientZoom = 1
        panOffset = .zero
        stopEdgePan()
        needsLayout = true
        layoutVideoLayer()
    }

    /// FIT TO PANE → set the client zoom so the WHOLE remote window is visible inside the pane (the
    /// smaller of the per-axis pane/window ratios, bounded by the same ``ViewportZoom`` ladder as the zoom
    /// steps — but NOT unity-snapped, or a 0.97 fit would round to 1× and stop fitting) and re-anchor
    /// top-left. At the fitted zoom there is no overflow (both displayed axes ≤ the
    /// pane), so edge-pan goes inert on its own — except when the ``ViewportZoom/minimum`` floor clips a
    /// >4×-oversized window,
    /// where the top-left anchor still shows the most content the ladder allows. A no-op until the host
    /// window's point size is known (`streamPoints`).
    private func applyFitToPane() {
        guard let win = streamPoints, win.width > 1, win.height > 1,
              bounds.width > 1, bounds.height > 1 else { return }
        clientZoom = CGFloat(ViewportZoom.fitted(
            window: win,
            pane: VideoSize(width: Double(bounds.width), height: Double(bounds.height)),
        ))
        viewportTouched = false
        panOffset = .zero
        stopEdgePan()
        needsLayout = true
        layoutVideoLayer()
    }

    /// Whether there is window content beyond the pane to pan to (the window is larger than the pane on at
    /// least one axis). Gates edge-pan.
    private var isNavigable: Bool {
        guard let win = streamPoints else { return false }
        // The DISPLAYED window is native × clientZoom (see `layoutVideoLayer`), so the navigability gate must
        // key off the zoomed size — otherwise footer zoom-in overflow of a smaller-than-pane window reads as
        // "fits" and edge-pan (the only in-pane pan path) never arms.
        return ViewportPan.isNavigable(
            window: win,
            pane: VideoSize(width: Double(bounds.width), height: Double(bounds.height)),
            zoom: Double(clientZoom),
        )
    }

    // MARK: Edge-pan (translate the oversized video layer when the pointer hugs a pane edge)

    /// Recompute the edge-pan velocity from the pointer's distance to each edge and (re)arm/stop the
    /// drive timer. `p` is in this view's coordinates (AppKit, origin bottom-left). Inert when the window
    /// fits the pane.
    private func updateEdgePan(at p: CGPoint) {
        lastPointerView = p
        // PAN LOCK ("lock position"): the footer lock control freezes the viewport — no edge-hover auto-pan.
        guard !panLocked else { stopEdgePan()
            return
        }
        edgePanVelocity = computeEdgePanVelocity(at: p)
        if edgePanVelocity == .zero {
            stopEdgePan()
        } else if edgePanTimer == nil {
            // `.common` mode so the timer keeps firing during mouse-tracking / gesture runloop modes.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.stepEdgePan() }
            }
            RunLoop.main.add(timer, forMode: .common)
            edgePanTimer = timer
        }
    }

    private func stopEdgePan() {
        edgePanVelocity = .zero
        edgePanTimer?.invalidate()
        edgePanTimer = nil
    }

    /// Signed pan velocity (WINDOW POINTS/sec) for a pointer at `p`. Each axis ramps linearly from 0 at the
    /// band's inner edge to ``edgePanPointsPerSec`` at the pane border. Sign is in the `panOffset` basis
    /// (top-left, y-down): right edge → +x (reveal right); the view's BOTTOM (small AppKit y) → +y (reveal
    /// the window's bottom).
    private func computeEdgePanVelocity(at p: CGPoint) -> CGPoint {
        guard isNavigable, bounds.width > 1, bounds.height > 1 else { return .zero }
        let t = Self.edgePanThreshold
        let maxV = Self.edgePanPointsPerSec
        func ramp(_ depth: CGFloat) -> Double { min(max(Double(depth) / Double(t), 0), 1) * maxV }
        var v = CGPoint.zero
        if p.x < t { v.x = -ramp(t - p.x) } else if p.x > bounds.width - t { v.x = ramp(p.x - (bounds.width - t)) }
        if p.y < t { v.y = ramp(t - p.y) } else if p.y > bounds.height - t { v.y = -ramp(p.y - (bounds.height - t)) }
        return v
    }

    /// One 60 Hz edge-pan step: advance ``panOffset`` (window points) by `velocity · dt`, clamp to the
    /// overflow `[0, window − pane]`, re-lay-out the video layer (a compositor translate), and re-forward
    /// the (edge-pinned) pointer so the host cursor walks into the revealed region.
    private func stepEdgePan() {
        guard isNavigable, edgePanVelocity != .zero, let win = streamPoints else { stopEdgePan()
            return
        }
        let dt = 1.0 / 60.0
        // Clamp to the DISPLAYED (zoomed) overflow, matching `layoutVideoLayer`'s frame clamp — clamping to
        // the un-zoomed `win − pane` stopped panning partway and stranded the far edge of zoomed content.
        let maxPan = ViewportPan.maxPanOffset(
            window: win,
            pane: VideoSize(width: Double(bounds.width), height: Double(bounds.height)),
            zoom: Double(clientZoom),
        )
        let maxX = maxPan.x
        let maxY = maxPan.y
        let nx = min(max(Double(panOffset.x) + Double(edgePanVelocity.x) * dt, 0), maxX)
        let ny = min(max(Double(panOffset.y) + Double(edgePanVelocity.y) * dt, 0), maxY)
        let xDone = edgePanVelocity
            .x == 0 || (edgePanVelocity.x < 0 && nx <= 0) || (edgePanVelocity.x > 0 && nx >= maxX)
        let yDone = edgePanVelocity
            .y == 0 || (edgePanVelocity.y < 0 && ny <= 0) || (edgePanVelocity.y > 0 && ny >= maxY)
        panOffset = CGPoint(x: nx, y: ny)
        viewportTouched = true // explicit edge-pan → stop re-anchoring to top-left
        layoutVideoLayer() // compositor translate (smooth) + republish input viewport
        if BackgroundPointerPolicy.forwardsPointer(isActive: isActive, backgroundPointer: backgroundPointer),
           inputEnabled
        {
            pipeline.mouseMove(VideoPoint(x: Double(lastPointerView.x), y: Double(bounds.height - lastPointerView.y)))
        }
        if xDone, yDone { stopEdgePan() }
    }

    // MARK: Input forwarding (view space → normalised → host)

    private func viewPoint(_ event: NSEvent) -> VideoPoint {
        // Convert to this view's coordinates, then flip Y so origin is TOP-left (the
        // orientation the host window space + InputEventEncoder normalisation expect).
        let p = convert(event.locationInWindow, from: nil)
        return VideoPoint(x: Double(p.x), y: Double(bounds.height - p.y))
    }

    private func mods(_ event: NSEvent) -> InputModifiers { Self.modifiers(event.modifierFlags) }

    // Only the ACTIVE pane tracks hover (the "only the active pane swallows pointer" rule) — plus a
    // BACKGROUND-POINTER satellite, whose whole point is hover-following while another window holds
    // the keyboard. A non-active canvas pane still ignores hover so it never injects a stray remote
    // mouse-move; you must click it first.
    override func mouseMoved(with event: NSEvent) {
        guard BackgroundPointerPolicy.forwardsPointer(isActive: isActive, backgroundPointer: backgroundPointer)
        else { return }
        // Edge-pan is local view-nav (moves the zoomed crop) — runs even on a read-only pane; inert at 1×.
        updateEdgePan(at: convert(event.locationInWindow, from: nil))
        guard inputEnabled else { return } // read-only ⇒ no remote mouse-move
        pipeline.mouseMove(viewPoint(event))
    }

    // A drag (a button is HELD) is a DISTINCT NSView callback from a hover `mouseMoved`, so the
    // client KNOWS which button is down and forwards an explicit `.mouseDrag`; the host posts
    // the matching `*MouseDragged` STATELESSLY — no host-side held-button guess. NOT gated on
    // `isActive`: a drag only follows a `mouseDown` on THIS pane, which already activated it, so the
    // in-gesture frames must keep flowing even before SwiftUI re-renders `isActive` true.
    override func mouseDragged(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote drag
        pipeline.mouseDrag(.left, viewPoint(event), LocalInputPolicy.clampClickCount(event.clickCount), mods(event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote drag
        pipeline.mouseDrag(.right, viewPoint(event), LocalInputPolicy.clampClickCount(event.clickCount), mods(event))
    }

    // CLICK = ACTIVATE: a mouseDown makes this the active pane (`onActivate` → workspace focus) AND raises
    // the host window (`focusWindow`), THEN lands as a remote click — raising on hover instead would steal
    // the host window the moment the pointer merely crosses an unfocused pane. The activating click is
    // always forwarded so clicking a control in a background window just works.
    // BACKGROUND-POINTER exception: on a NOT-key satellite the click is delivered to the host with the
    // LOCAL window left un-activated — `preventWindowOrdering` cancels the ordering that
    // `shouldDelayWindowOrdering` deferred (the drag-from-a-background-window mechanism), and
    // `onActivate` is skipped so local (workspace + key-window + first-responder) focus stays wherever
    // the user is typing. The HOST-side raise (`focusWindow`) still runs: it never touches local focus,
    // and a window-scoped satellite needs raise-then-click for the positional click to land right.
    override func mouseDown(with event: NSEvent) {
        // BUG-1 probe: clicking is the reported freeze trigger. Correlate this line with `cursorAPPLY`/
        // `RENDER` gaps (client main-actor block from focus()) and `mediaRX` gaps (host capture hitch on
        // window-raise) to see which path stalls on a click.
        let backgroundClick = BackgroundPointerPolicy.backgroundClick(
            backgroundPointer: backgroundPointer, windowIsKey: window?.isKeyWindow == true,
        )
        videoViewDbg("click → \(backgroundClick ? "background" : "activate") isActive=\(isActive)")
        if backgroundClick {
            NSApp.preventWindowOrdering()
        } else {
            onActivate()
        }
        // READ-ONLY: a locked pane still ACTIVATES (workspace focus, above), but the click is NOT
        // relayed to the host and the host window is NOT raised — the pane is view-only.
        guard inputEnabled else { return }
        // Send the host window-raise ONLY when (re)activating an UNfocused pane — not on every click of
        // an already-active pane. The host raise is best-effort + costly (AX IPC); re-raising on each
        // click of the focused pane is wasted work (the host throttles redundant raises as a backstop).
        if !isActive { pipeline.focusWindow() }
        pipeline.mouseDown(.left, viewPoint(event), LocalInputPolicy.clampClickCount(event.clickCount), mods(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote click
        pipeline.mouseUp(.left, viewPoint(event), LocalInputPolicy.clampClickCount(event.clickCount), mods(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        // BACKGROUND-POINTER: a right-click never orders a window front on macOS, so only the local
        // activation is skipped — the context-click still reaches the host below.
        if !BackgroundPointerPolicy.backgroundClick(
            backgroundPointer: backgroundPointer, windowIsKey: window?.isKeyWindow == true,
        ) {
            onActivate()
        }
        guard inputEnabled else { return } // read-only ⇒ activate only, no remote relay
        if !isActive { pipeline.focusWindow() }
        pipeline.mouseDown(.right, viewPoint(event), LocalInputPolicy.clampClickCount(event.clickCount), mods(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote click
        pipeline.mouseUp(.right, viewPoint(event), LocalInputPolicy.clampClickCount(event.clickCount), mods(event))
    }

    /// Maps a finger-on-glass `NSEvent.phase` to its `CGScrollPhase` integer code so the host can set
    /// `kCGScrollWheelEventScrollPhase` verbatim.
    ///
    /// The MASK crosses, not a case index: AppKit's bits are already a wire-stable encoding, and
    /// turning them into an ordinal here would put back the table this asks in order not to keep.
    /// The two CoreGraphics fields encode the same three edges DIFFERENTLY — an end is `4` in the
    /// scroll field and `3` in the momentum one — and those ten numbers were spelled in four places
    /// across two languages, two of which read different sets of them. They are `client_gestures`'s
    /// now, and this is the phone's `TouchPointerPlan/scrollPhase(isFirst:isLast:)` asking the same
    /// table a trackpad question.
    static func cgScrollPhaseCode(_ phase: NSEvent.Phase) -> UInt8 {
        slopdesk_cg_scroll_phase_code(UInt32(truncatingIfNeeded: phase.rawValue))
    }

    /// Maps an inertial-coast `NSEvent.momentumPhase` to its `CGMomentumScrollPhase` integer code —
    /// a SEPARATE encoding from ``cgScrollPhaseCode(_:)``, which is why it is a separate door.
    static func cgMomentumPhaseCode(_ phase: NSEvent.Phase) -> UInt8 {
        slopdesk_cg_momentum_phase_code(UInt32(truncatingIfNeeded: phase.rawValue))
    }

    override func scrollWheel(with event: NSEvent) {
        // ACTUAL-SIZE viewport: a two-finger scroll FORWARDS to the remote (scrolls the editor) — it is NOT
        // hijacked to pan the viewport. Moving the viewport is the EDGE-PAN's job (hover-to-edge, RealVNC
        // model). So there is no local crop-pan branch here.
        //
        // SCROLL ROUTING — scroll follows the POINTER, not focus (the terminal pane's rule too):
        //   • plain scroll → forward to the REMOTE window under the pointer, focused or NOT, so a
        //     background editor can be scrolled/compared while focus (and typing) stays in the working
        //     pane. Forwarding is a UDP send — no `@Observable` mutation, so it never blocks the stream.
        //   • ⌥ held       → PAN THE CANVAS — the one deliberate pan-over-a-pane route. Routed through
        //     the debounced `onCanvasScroll` accumulator (NOT a per-step commitCamera), so it never
        //     blocks the stream either.
        // The choice is PINNED per gesture (`ScrollRoutePinner`): decided at began/mayBegin and held
        // through the momentum tail, so pressing/releasing ⌥ mid-gesture can't reroute the inertia into
        // the other destination. Phase-less wheel ticks keep the live per-event decision.
        // Natural-scroll sign matches `CanvasView.PanView` so a pane-pan feels identical to the bg pan.
        // READ-ONLY: a locked pane does NOT swallow the scroll into the remote window —
        // `inputEnabled == false` falls through to the canvas-pan branch (view-only, no host relay).
        // Deliberately a LIVE gate, never pinned: locking mid-gesture must stop host relay at once.
        let scrollPhase = Self.cgScrollPhaseCode(event.phase)
        let momentumPhase = Self.cgMomentumPhaseCode(event.momentumPhase)
        let routeRemote = scrollRoutePinner.route(
            liveRemote: !event.modifierFlags.contains(.option),
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase,
        )
        if routeRemote, inputEnabled {
            videoViewDbg("scroll → remote")
            // Forward the trackpad gesture state so the host can replay a native continuous/inertial
            // scroll (Began→Changed→Ended, then momentum Begin→Continue→End) instead of a phase-less
            // wheel tick. `event.phase` (finger-on-glass) and `event.momentumPhase` (coast) are
            // distinct and mutually exclusive; map each to its CoreGraphics integer code.
            pipeline.scroll(
                dx: Double(event.scrollingDeltaX),
                dy: Double(event.scrollingDeltaY),
                viewPoint: viewPoint(event),
                scrollPhase: scrollPhase,
                momentumPhase: momentumPhase,
                continuous: event.hasPreciseScrollingDeltas,
            )
            feedSwipePeel(event)
            return
        }
        // A scroll that no longer reaches the remote (focus flip / ⌥ pan / read-only) abandons
        // any mid-gesture peel — the host recogniser stops seeing this gesture too.
        abandonSwipePeel()
        let dx: CGFloat, dy: CGFloat
        if event.hasPreciseScrollingDeltas { dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        } else { dx = event.scrollingDeltaX * 10
            dy = event.scrollingDeltaY * 10
        }
        videoViewDbg("scroll → canvas pan d=(\(Int(-dx)),\(Int(-dy))) isActive=\(isActive)")
        onCanvasScroll(CGSize(width: -dx, height: -dy))
    }

    // MARK: Swipe-peel feedback (doc 05 §8)

    /// Adopts the host's swipe-nav status push. Eligibility flipping OFF mid-gesture retracts
    /// immediately (the host would ignore the fire), and so does the shown chip's direction
    /// going history-DEAD (the ~250 ms change-poll can land mid-gesture) — EXCEPT a confirming
    /// chip: a fired back-nav flips canGoBack itself within one poll, and cutting the 520 ms
    /// confirm hold on that push would erase the acknowledgement of the very fire that caused
    /// it. A knob change rebuilds the (idle) mirror so a host-side
    /// `SLOPDESK_SWIPE_NAV_TRAVEL`/`_SLOW` retune never desynchronises the feedback.
    private func adoptSwipeNavStatus(_ status: SwipeNavStatusMessage) {
        let previous = peelStatus
        peelStatus = status
        if !status.eligible {
            abandonSwipePeel()
        } else if let chip = controls?.swipePeel, !chip.confirming, !status.allowsChip(chip.direction) {
            abandonSwipePeel()
        }
        if previous?.fireTravel != status.fireTravel || previous?.slowTier != status.slowTier {
            peelPlanner = SwipePeelPlanner(
                fireTravel: Double(status.fireTravel), slowSwipe: status.slowTier,
            )
        }
    }

    /// Mirrors one forwarded scroll event into the peel planner and applies its verdict. Gated
    /// on the host saying the target app is eligible AT ALL — no push yet (old host) ⇒ nothing
    /// — then per-direction on the pushed history state (``SwipePeelPlanner/historyGated``):
    /// the planner still tracks the gesture (its state must mirror the host recogniser's), but
    /// a dead-direction chip never surfaces.
    private func feedSwipePeel(_ event: NSEvent) {
        guard let status = peelStatus, status.eligible else { return }
        let verdict = peelPlanner.ingest(
            dx: Double(event.scrollingDeltaX),
            dy: Double(event.scrollingDeltaY),
            scrollPhase: Self.cgScrollPhaseCode(event.phase),
            momentumPhase: Self.cgMomentumPhaseCode(event.momentumPhase),
            continuous: event.hasPreciseScrollingDeltas,
            now: event.timestamp,
        )
        applySwipePeel(SwipePeelPlanner.historyGated(verdict, status: status))
    }

    private func applySwipePeel(_ verdict: SwipePeelPlanner.Verdict) {
        switch verdict {
        case .idle:
            return
        case let .show(chip):
            peelConfirmClear?.cancel()
            peelConfirmClear = nil
            if chip.committed, !peelChipCommitted {
                // The moment the chip turns solid: "release now navigates".
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            peelChipCommitted = chip.committed
            if controls?.swipePeel != chip { controls?.swipePeel = chip }
        case let .commit(direction):
            peelChipCommitted = false
            controls?.swipePeel = SwipePeelChipState(
                direction: direction, progress: 1, committed: true, confirming: true,
            )
            peelConfirmClear?.cancel()
            peelConfirmClear = Task { [weak self] in
                // The chip's confirm pulse + DIM HOLD (see `MacSwipePeelChipView`) span the beat
                // where the host's ⌘[/⌘] lands and the post-navigation page streams in — the
                // only fire acknowledgement there is; this clear then fades the held chip out.
                try? await Task.sleep(nanoseconds: 520_000_000)
                guard !Task.isCancelled else { return }
                self?.controls?.swipePeel = nil
            }
        case .retract:
            peelChipCommitted = false
            // Two guards, both for the history gate's relabelled verdicts (a dead-direction
            // gesture converts EVERY qualifying event to `.retract`): a nil-over-nil assign
            // would re-fire the @Published pane invalidation ~80×/gesture for zero visible
            // change, and a CONFIRMING chip must keep its 520 ms hold — the planner resets
            // `showing` at commit, so the only live publish a `.retract` can coexist with is
            // the PREVIOUS gesture's confirm hold (double-back at history end), which the
            // pending clear task ends. A genuine same-gesture retract always finds a
            // non-confirming chip and clears it exactly once.
            if let chip = controls?.swipePeel, !chip.confirming {
                controls?.swipePeel = nil
            }
        }
    }

    /// Abandons any in-flight peel candidate (scroll rerouted, eligibility off, teardown): the
    /// planner resets and, if the chip was showing, it fades out.
    private func abandonSwipePeel() {
        applySwipePeel(peelPlanner.cancel())
    }

    // ALL keys (printable + special) go through the layout-level keycode `.key` path so the HOST's
    // keyboard layout + input method (e.g. OpenKey/xkey Telex) interpret and COMPOSE them server-side —
    // like Parsec/VNC/Screen-Sharing "scancode mode". A `.text` path that posts a virtualKey-0 CGEvent +
    // keyboardSetUnicodeString would be invisible to a keycode-driven IME composer (OpenKey reads only the
    // virtual keycode + shift/caps flag, never the Unicode string): the pre-baked glyph would ride through
    // and Vietnamese would never compose (`tieesng` inserted literally instead of composing). The real
    // keycode + flags let the host IME compose normally.
    //
    // Send ONLY `.key` per keypress — sending `.key` + `.text` together for the same keypress double-injects
    // one character per path. The `.text` / pipeline.text(...) / host `postText` plumbing stays (unused by
    // live typing) for future layout-independent input like paste.
    // WORKSPACE CHORDS over the video pane.
    //
    // A LOCAL workspace chord (⌘D/⌘T/…) MUST NOT leak to the remote host. That interception is UPSTREAM:
    // the app-level `WorkspaceKeyDispatcher` installs ONE
    // `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` at launch, firing BEFORE the first responder —
    // so a resolved chord is consumed (handler returns `nil`) and this `keyDown` is NEVER reached for
    // those. A bare key returns unchanged and lands here as normal typing.
    //
    // No thin pre-check is mirrored here (unlike the libghostty surface's) ON PURPOSE: `TerminalKeyInterceptor`
    // lives in `SlopDeskWorkspaceCore`, and `SlopDeskVideoClient` depends ONLY on `SlopDeskVideoProtocol`
    // (Package.swift) — importing WorkspaceCore here would invert the module graph (the HARD RULE keeps these
    // layers separated). That belt-and-suspenders exists because the libghostty surface is hosted INSIDE the
    // WorkspaceCore-importing app target and can reach the engine; this gated video surface cannot and need
    // not — the monitor already covers it. (Gated module: never instantiated in tests; verified by REVIEW.)
    override func keyDown(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no keycode forward
        pipeline.key(keyCode: event.keyCode, down: true, modifiers: mods(event))
    }

    override func keyUp(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no keycode forward
        pipeline.key(keyCode: event.keyCode, down: false, modifiers: mods(event))
    }

    // Modifier press/release. Without this, ⌘/⇧/⌃/⌥ are NEVER sent as discrete key events — they only
    // ride as per-event flags on key/mouse events. On the host `postKey` posts a CGEvent whose flags come
    // from those per-event mods, but the shared `CGEventSource(stateID:.hidSystemState)` LATCHES modifier
    // state: a ⌘ flag injected on (say) Delete with no matching modifier KEY-UP stays latched and corrupts
    // every later `.text` insertion (⌘+Delete then a stuck ⌘ turns the next Return into newline-with-⌘).
    // Emitting the real modifier key-up here posts a CGEvent that clears the latched flag. (`pipeline.key`
    // already carries keyCode+down+modifiers — no protocol change.)
    override func flagsChanged(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no modifier key-event forward
        let modifiers = mods(event)
        guard let down = LocalInputPolicy.modifierDown(keyCode: event.keyCode, modifiers: modifiers) else { return }
        // Track the edge (BUG-2) so a focus change that swallows the release can synthesize the key-up.
        modifierLatch.note(keyCode: event.keyCode, down: down)
        pipeline.key(keyCode: event.keyCode, down: down, modifiers: modifiers)
    }

    override var acceptsFirstResponder: Bool { true }

    /// BACKGROUND POINTER: the FIRST click on a not-key satellite must reach `mouseDown` — by default
    /// AppKit consumes it purely to activate the window, so the remote click would be lost.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { backgroundPointer }

    /// …and the window ordering that first click triggers is DELAYED (to mouseUp) so `mouseDown` can
    /// cancel it outright with `preventWindowOrdering` — the click then acts on the host with the
    /// local window left inactive, exactly like a drag lifted from a background Finder window.
    override func shouldDelayWindowOrdering(for _: NSEvent) -> Bool { backgroundPointer }

    /// AppKit only delivers `mouseMoved` when a tracking area requests it, and
    /// `acceptsFirstResponder` alone does NOT focus a bare layer-backed view inside a
    /// SwiftUI sheet — so without these two the cursor-follow + keyboard input paths are
    /// dead. Install/refresh a tracking area for the visible bounds, and grab first
    /// responder when the view enters a window.
    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        // BACKGROUND POINTER: a satellite surface keeps hover/cursor tracking alive while its window
        // is NOT key (`.activeAlways` — the window server still delivers tracking events to a
        // background window). Everywhere else `.activeInKeyWindow` stands: a background WORKSPACE
        // window must not start forwarding hover just because the pointer crosses it.
        let activation: NSTrackingArea.Options = backgroundPointer ? .activeAlways : .activeInKeyWindow
        let area = NSTrackingArea(
            // `.mouseEnteredAndExited` tracks whether the pointer is in the pane; `.cursorUpdate` makes
            // AppKit call `cursorUpdate(with:)` on each move so we re-assert the host's cursor shape.
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, activation, .inVisibleRect],
            owner: self, userInfo: nil,
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        applyLocalCursor()
        // Warp the host cursor to the entry point so its SHAPE resyncs immediately — a pointer that
        // enters an active pane and stops on a resize edge would otherwise hold the stale pre-focus
        // shape until the first hover move. Gated on active+writable inside `forwardPointer`.
        forwardPointer(atWindowLocation: event.locationInWindow)
    }

    override func mouseExited(with _: NSEvent) {
        pointerInside = false
        stopEdgePan() // pointer left the pane → stop auto-scrolling the crop
        NSCursor.arrow.set() // leaving the pane → restore the normal pointer
    }

    /// AppKit's per-move cursor callback while the pointer is in the pane: re-assert the host shape (or
    /// fall through to AppKit's default arrow) so a transient `.set()` from elsewhere can't win on a move.
    override func cursorUpdate(with event: NSEvent) {
        if BackgroundPointerPolicy.forwardsPointer(isActive: isActive, backgroundPointer: backgroundPointer),
           pipeline.isServerCursorVisible, let cursor = pipeline.currentRemoteCursor
        {
            cursor.set()
        } else {
            super.cursorUpdate(with: event) // AppKit already set the window's default (arrow) pre-callback
        }
    }

    /// FIRST-RESPONDER RESIGN (BUG-2): when a sibling pane grabs first responder (⌘T / any focus move that
    /// calls `makeFirstResponder`) while a modifier is physically held, its release `flagsChanged` is delivered
    /// to the NEW responder — never to us — so the host would keep the modifier latched (scroll → zoom). Release
    /// the latched modifiers here. (The other no-release path — the whole window resigning key on ⌘-Tab away,
    /// which does NOT call `resignFirstResponder` — is covered by the `didResignKeyNotification` observer below.)
    override func resignFirstResponder() -> Bool {
        releaseLatchedModifiers()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // BUG-2: re-scope the window-resign-key observer to the CURRENT window (removed first so a moved /
        // detached view never keeps a stale subscription). On ⌘-Tab away the window resigns key WITHOUT a
        // release `flagsChanged` or a `resignFirstResponder`, so this is the only signal to unlatch modifiers.
        if let token = windowResignKeyObserver {
            NotificationCenter.default.removeObserver(token)
            windowResignKeyObserver = nil
        }
        if let window {
            windowResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main,
            ) { [weak self] _ in
                // Already on the main queue (`queue: .main`); bridge to this @MainActor view.
                MainActor.assumeIsolated { self?.releaseLatchedModifiers() }
            }
        }
        // FOCUS-STEALING FIX: only grab first responder when THIS pane is the ACTIVE one and we are not
        // already the responder. An unconditional makeFirstResponder on every NSView mount let the
        // LAST-mounted video pane steal the keyboard regardless of workspace focus (and thrash the
        // responder on tab switches). Mirrors the terminal pane's `isFocusedPane` guard.
        guard isActive, let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    /// Restore the arrow when the view leaves its window (drag-out / pane close): a teardown that skipped
    /// `mouseExited` must not leave a stale host-shape cursor set.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { if pointerInside { NSCursor.arrow.set() }
            pointerInside = false
            stopEdgePan() // teardown — never leave a timer firing on a detached view
            // BUG-2: release any latched modifier + drop the resign-key observer before the view detaches, so
            // a torn-down pane never leaves the host with a stuck modifier or a stale window subscription.
            releaseLatchedModifiers()
            if let token = windowResignKeyObserver {
                NotificationCenter.default.removeObserver(token)
                windowResignKeyObserver = nil
            }
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> InputModifiers {
        var m: InputModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.capsLock) { m.insert(.capsLock) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }
}

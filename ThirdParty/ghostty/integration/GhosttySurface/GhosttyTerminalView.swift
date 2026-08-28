//
//  GhosttyTerminalView.swift
//  SlopDesk — the layer-hosting view for the ONLY terminal renderer (libghostty-only).
//
//  THE FILE NAME IS HISTORY. `GhosttyTerminalView` was the SwiftUI struct that used to wrap the
//  view below, and it is gone; `GhosttyLayerBackedView` is what this file is about. The PATH stays
//  because four other things pin it — `rust/slopdesk-invariants` (`ui_seams.rs` GHOSTTY_SEAM,
//  `phone_parity.rs` RENDERER), both `Apps/*/project.yml` source includes, and
//  `slopdesk-ops enable-renderer` — so renaming it is a change to those, not a tidy-up.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THIS FILE IS DELIBERATELY OUTSIDE THE DEFAULT `swift build` GRAPH.
//  ─────────────────────────────────────────────────────────────────────────────
//  It is the production `TerminalSurfaceHosting` conformer named in
//  `Sources/SlopDeskWorkspaceCore/Terminal/TerminalRendererSeam.swift` (the documented
//  extension point). Like its sibling `GhosttySurface.swift` (same directory) it is
//  NOT a member of any target in `/Package.swift`; it compiles only inside the
//  macOS/iOS GUI app target (WF-8) which (a) links `libghostty.xcframework` and
//  (b) imports the `CGhostty` clang module. A headless `swift build` / `swift test`
//  never sees it, so the core stays green with zero conditional-compilation hacks.
//
//  The WHOLE FILE is gated on `#if canImport(CGhostty)`. Until the xcframework lands
//  the `CGhostty` module does not exist, so this file compiles to NOTHING — it is
//  inert in every build available on this macOS-26.5 host. Its correctness is
//  verified by REVIEW against `GhosttySurface.swift` + `CGhostty/ghostty.h`, not by
//  compilation (see docs/21-HANDOFF.md "Activating the libghostty renderer").
//
//  ─────────────────────────────────────────────────────────────────────────────
//  API CORRECTNESS — every symbol this file relies on (so a reviewer can diff it)
//  ─────────────────────────────────────────────────────────────────────────────
//  From `GhosttySurface.swift` (the @MainActor Swift binding, same directory):
//    • init(app:platformView:cols:rows:contentScale:)   — line 120
//    • var onWrite: ((Data) -> Void)?                    — line 103  (OUT path)
//    • var onResize: ((UInt16, UInt16) -> Void)?         — line 198  (grid → host)
//    • func feed(_:)                                     — line 229  (IN path; model calls this)
//    • func setSize(cols:rows:)                          — line 252
//    • func setContentScale(_:)                          — line 272
//    • func key(_: ghostty_input_key_s) -> Bool          — line 300
//    • func text(_: String)                              — line 310
//    • func redraw()                                     — line 325
//    • func setFocus(_:)                                 — line 332
//    • func close()                                      — line 201
//  From `CGhostty/ghostty.h` (the C ABI), cited by header line:
//    • ghostty_init(uintptr_t, char**)                   — 1117  (process-wide, once)
//    • ghostty_config_new() / _finalize() / _free()      — 1123 / 1132 / 1124
//    • ghostty_runtime_config_s { userdata, wakeup_cb,
//        action_cb, read/confirm/write_clipboard_cb,
//        close_surface_cb, supports_selection_clipboard } — 1073
//    • ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t) — 1141
//    • ghostty_app_free(ghostty_app_t)                   — 1143
//    • ghostty_app_tick(ghostty_app_t)                   — 1144
//    • ghostty_app_t (void*) / ghostty_config_t (void*)  — 29 / 30
//    • ghostty_input_key_s { action, mods, consumed_mods,
//        keycode, text, unshifted_codepoint, composing }  — 322
//    • ghostty_input_action_e {RELEASE,PRESS,REPEAT}     — 120
//    • ghostty_input_mods_e {NONE,SHIFT,CTRL,ALT,SUPER,…}— 100
//
//  NOTE on the OUT path (keystrokes → host PTY stdin): the surface emits encoded
//  bytes via `onWrite`. This view routes them to `TerminalViewModel.sendInput(_:)`
//  (and grid resizes via `onResize` → `sendResize`). The model funnels them through
//  its `inputSink`/`resizeSink`, which the connection layer (`ConnectionViewModel`,
//  which holds the live `SlopDeskClient`) points at `SlopDeskClient.sendInput`/`sendResize`
//  on connect and clears on teardown. Going through the MODEL (not `model.surface
//  .onWrite` directly) decouples view-attach timing from connect timing — whichever
//  happens first, the sink is read at call time. NOW WIRED (was the remaining seam in
//  docs/21-HANDOFF.md).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THREADING (doc 18 §C — libghostty calls are main-thread-only)
//  ─────────────────────────────────────────────────────────────────────────────
//  `GhosttySurface` is `@MainActor`, and every door into the view below is an AppKit/UIKit
//  callback that arrives on the main thread — the seam's factory closure (`@MainActor` in its
//  TYPE), `viewDidMoveToWindow`/`didMoveToWindow`, `layout()`/`layoutSubviews()`, the responder
//  chain — so every surface call below is on main. We never `await` between
//  write_output → refresh → draw (the binding keeps that trio synchronous inside `feed`).
//

#if canImport(CGhostty)

import Observation         // withObservationTracking — the live terminal-config follow's one need
import QuartzCore          // CAMetalLayer
import SlopDeskTerminal       // TerminalSurface protocol
import SlopDeskWorkspaceCore  // TerminalSurfaceHosting, TerminalViewModel, TerminalRendererFactory (L0 home)
import SlopDeskClientCore     // ClipboardConfirmPresentation — what the clipboard asks, on BOTH halves
import CGhostty            // the clang module over ghostty.h (link "ghostty")

#if os(macOS)
import SlopDeskMacUI      // PasteProtectionSheet (the macOS paste-protection confirmation surface, E8 WI-4)
import AppKit
import Carbon              // TIS keyboard-layout id (IME input-source-switch guard; framework already linked)
#elseif os(iOS)
import UIKit
import UniformTypeIdentifiers  // UTType.item — the "Paste File Base64-Encoded…" document picker's content type
#endif

// MARK: - Process-wide libghostty app handle

#if os(macOS)
/// Maps a libghostty clipboard `location` to its NSPasteboard. `STANDARD` is the real system
/// clipboard; `SELECTION` is a PRIVATE pasteboard (mirrors upstream `NSPasteboard.ghostty(_:)`) so
/// libghostty's default-ON copy-on-select does NOT clobber the user's system clipboard on every
/// drag-select — only an explicit Cmd-C / `copy_to_clipboard` (STANDARD) touches `.general`.
@inline(__always) func slopdeskPasteboard(for location: ghostty_clipboard_e) -> NSPasteboard {
    location == GHOSTTY_CLIPBOARD_SELECTION
        ? NSPasteboard(name: NSPasteboard.Name("com.slopdesk.terminal.selection"))
        : .general
}
#endif

/// THE ONE PLATFORM SEAM IN THE CLIPBOARD GATES, and the only one there should ever be.
///
/// The three questions below — an unsafe paste, an OSC-52 READ, an OSC-52 WRITE — are the SAME question
/// on both platforms and are decided by the same shared reading (``ClipboardConfirmPresentation``). What
/// differs is only how a framework puts a question to a person: AppKit has a presenter you can CALL from
/// inside a C callback (`NSAlert.beginSheetModal(for:)`), SwiftUI has none, so the phone files the
/// question into ``ClipboardConfirmRequests`` and the mounted `ClipboardConfirmCard` drains it.
///
/// ⚠️ EVERY ARM OF THIS FUNCTION ENDS AT A HUMAN. It used to have a third arm that did not: iOS
/// auto-approved an unsafe paste and an OSC-52 read outright, and dropped an OSC-52 write it had been
/// told to ASK about — so `clipboard-read = ask` behaved as Allow and `clipboard-write = ask` as Deny on
/// a phone while both behaved correctly on the Mac, from the same settings page. `completion` runs
/// exactly once, on the main actor, and only ever with the user's own answer.
@MainActor
func slopdeskPresentClipboardConfirm(
    ask: PasteSafetyAnalyzer.Ask,
    preview: String,
    dangers: PasteSafetyAnalyzer.PasteDangers,
    completion: @escaping (Bool) -> Void,
) {
    #if os(macOS)
    PasteProtectionSheet.present(
        ask: ask,
        preview: preview,
        dangers: dangers,
        in: NSApp.keyWindow,
        completion: completion,
    )
    #else
    ClipboardConfirmRequests.shared.ask(
        ClipboardConfirmPresentation.reading(ask: ask, preview: preview, dangers: dangers),
        answer: completion,
    )
    #endif
}

/// E8 WI-4 (ES-E8-3): the embedder side of Paste Protection. Reached from
/// `confirm_read_clipboard_cb` for a PASTE that libghostty already deemed unsafe (paste-protection on,
/// not bracketed-safe). Decides — via the PURE, headless-tested ``PasteSafetyAnalyzer`` — whether to show
/// the confirmation sheet, then completes the pending clipboard request exactly once.
///
/// The decision uses this feature's OWN four-danger criteria (not libghostty's broader `isSafe`), so the sheet
/// appears only for a locally-classified danger even if libghostty's gate is more eager. On approve we
/// complete with the text + `confirmed: true` (`allow_unsafe`); on cancel we complete with EMPTY data,
/// which short-circuits `Surface.completeClipboardPaste` (`if (data.len == 0) return;`) so the request
/// frees cleanly with no paste and NO gate re-trip (the de-risked cancel contract — see the callback).
@MainActor
func slopdeskConfirmUnsafePaste(
    surface: GhosttySurface,
    text: String,
    state: UnsafeMutableRawPointer?
) {
    // Empty paste: nothing to warn about — terminate the request (mirrors libghostty's own len==0 guard).
    guard !text.isEmpty else {
        surface.completeClipboardRead(text, state: state, confirmed: true)
        return
    }

    // WI-5: the REAL alt-screen flag, sourced from the client `TerminalModeTracker` (via the model) through
    // the surface's `isAlternateScreen` hook, so this libghostty-initiated paste backstop skips the sheet
    // inside a full-screen TUI — agreeing with the ⌘V `requestPaste` path. Unset ⇒ primary screen.
    let isAlternateScreen = surface.isAlternateScreen?() ?? false
    let dangers = PasteSafetyAnalyzer.analyze(text)
    let shouldWarn = PasteSafetyAnalyzer.shouldWarn(
        text: text,
        // The LIVE "Paste Protection" toggle is authoritative — not a hardcoded `true`. libghostty's own
        // `clipboard-paste-protection` config gate (default on) is what ROUTES a `\n`/bracketed-end paste here,
        // but whether to WARN is decided here: with Paste Protection OFF this auto-approves (below), so a user
        // who disabled the feature is not warned. (The embedder pre-check `requestPaste` is the primary gate for
        // a ⌘V / menu paste; this stays the backstop for a libghostty-initiated paste, e.g. middle-click.)
        protectionOn: SettingsKey.pasteProtectionEnabled,
        bracketedSafe: false,               // bracketed-safe is already applied upstream; don't double-skip
        programAdvertisedBracketed: false,
        isAlternateScreen: isAlternateScreen
    )

    guard shouldWarn else {
        // No classified danger (or a skip rule applied) → approve without a dialog.
        surface.completeClipboardRead(text, state: state, confirmed: true)
        return
    }

    slopdeskPresentClipboardConfirm(
        ask: .unsafePaste,
        preview: text,
        dangers: dangers,
    ) { pasteAnyway in
        if pasteAnyway {
            surface.completeClipboardRead(text, state: state, confirmed: true)
        } else {
            // CANCEL contract: complete with EMPTY data (NOT the unsafe text + confirmed:false, which
            // would recurse). libghostty resolves an empty paste as a no-op and frees the request state.
            surface.completeClipboardRead("", state: state, confirmed: false)
        }
    }
}

/// E8 WI-6 (I11): the embedder side of the OSC-52 clipboard-READ access gate. Reached from
/// `confirm_read_clipboard_cb` for a `GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ` — a terminal program (vim,
/// tmux, an SSH session running inside the hosted PTY) asked to READ the system clipboard. It honours the
/// LIVE `clipboard-read` access setting (Allow / Ask / Deny, default Ask — the riskier direction),
/// reusing the paste-protection surface with the OSC-52 "Allow this program to read the clipboard?" copy
/// (``PasteSafetyAnalyzer/Ask/clipboardRead``).
///
/// RECURSION-SAFETY — the read contract differs from a paste's: `completeClipboardReadOSC52` checks
/// `clipboard_read == .ask and !confirmed` BEFORE any empty-data short-circuit (verified in ghostty-src
/// `src/Surface.zig`), so completing a READ with `confirmed: false` RE-TRIPS the ask gate → libghostty
/// re-invokes this callback → unbounded recursion → stack overflow. Every terminating completion here
/// therefore uses `confirmed: true`; a DENY / CANCEL passes EMPTY text (the pure
/// ``ClipboardAccess.silentClipboardRead(text:)`` "" outcome) — a well-formed but empty OSC-52 reply that
/// frees the request exactly once and never leaks the clipboard. ALLOW passes the real text.
@MainActor
func slopdeskConfirmClipboardRead(
    surface: GhosttySurface,
    text: String,
    state: UnsafeMutableRawPointer?,
    access: ClipboardAccess
) {
    // Allow / Deny resolve SILENTLY (no dialog): allow → the real clipboard text, deny → "" (empty reply,
    // no leak). A `nil` resolution means the access is `ask` → fall through to the confirmation sheet.
    if let resolved = access.silentClipboardRead(text: text) {
        surface.completeClipboardRead(resolved, state: state, confirmed: true)
        return
    }
    // Ask → surface the confirmation; the user's verdict maps to allow (text) / deny ("") — BOTH
    // confirmed:true so neither completion re-trips the read gate (the recursion hazard above).
    slopdeskPresentClipboardConfirm(
        ask: .clipboardRead,
        preview: text,
        dangers: [],
    ) { allow in
        surface.completeClipboardRead(allow ? text : "", state: state, confirmed: true)
    }
}

/// Performs the actual pasteboard WRITE libghostty requested (E8 WI-2, the clipboard-write actuation).
/// HONORS `location`: STANDARD = the system clipboard; SELECTION = the PRIVATE selection pasteboard (so a
/// copy-on-select drag never clobbers the user's real clipboard). iOS has no selection clipboard. Split out
/// of `write_clipboard_cb` so both the direct-write path and the post-confirm (clipboard-write = ask) path
/// share one site. Pasteboard is main-thread-only; every caller is on the main actor.
@MainActor func slopdeskWriteClipboard(_ text: String, location: ghostty_clipboard_e) {
    #if os(macOS)
    let pb = slopdeskPasteboard(for: location)
    pb.declareTypes([.string], owner: nil)
    pb.setString(text, forType: .string)
    #elseif os(iOS)
    if location != GHOSTTY_CLIPBOARD_SELECTION { UIPasteboard.general.string = text }
    #endif
}

/// Owns the single process-wide `ghostty_app_t`. libghostty is initialized once per
/// process (`ghostty_init`, header 1117) and one `app` handle is shared by every
/// surface (`ghostty_app_new`, header 1141). Surfaces are created from it
/// (`GhosttySurface.init(app:…)`). `@MainActor` because all libghostty calls are
/// main-thread-only (doc 18 §C).
@MainActor
final class GhosttyApp {
    /// Lazily-created shared handle. The GUI process keeps it alive for its lifetime,
    /// so surfaces created from it (held by the Metal views) never outlive it.
    static let shared = GhosttyApp()

    let app: ghostty_app_t

    // Coalescing state for `wakeup_cb`. `nonisolated` because `requestAppTick` is invoked from
    // libghostty's OFF-main libxev threads (`renderer`/`io`).
    nonisolated(unsafe) private static var tickScheduled = false
    nonisolated private static let tickLock = NSLock()

    /// Schedules AT MOST ONE pending `ghostty_app_tick` on the main thread, collapsing a burst of
    /// high-rate `wakeup_cb` signals. Without this, the external-backend libxev loops (which can
    /// busy-tick) fire `wakeup_cb` thousands of times/sec; one `DispatchQueue.main.async` per signal
    /// floods the main queue and STARVES the MainActor — SwiftUI stops updating and the async connect
    /// never runs (pane stuck at "idle" while CPU spins). Coalescing keeps the main thread free.
    nonisolated static func requestAppTick() {
        tickLock.lock()
        if tickScheduled { tickLock.unlock(); return }
        tickScheduled = true
        tickLock.unlock()
        DispatchQueue.main.async {
            tickLock.lock(); tickScheduled = false; tickLock.unlock()
            MainActor.assumeIsolated { ghostty_app_tick(GhosttyApp.shared.app) }
        }
    }

    /// The last `TerminalConfigBroadcaster.generation` we applied — so an idempotent re-publish of the
    /// same string is a no-op (we still apply when the generation bumps, even if the string is equal).
    private var lastAppliedConfigGeneration = 0

    /// W13: apply a NEW terminal-render config string LIVE to the running app (and thus every surface).
    /// Builds a fresh `ghostty_config_t`, loads the string, finalizes, and pushes it via
    /// `ghostty_app_update_config` (header 1153) which reflows all surfaces; each surface's resize_callback
    /// then fires `onResize`, so the host PTY grid tracks the new font metrics (the grid-mismatch fix). A
    /// no-op when the generation hasn't advanced past the last apply.
    ///
    /// Its ONE caller is ``followTerminalConfig()``, which is armed from `init` — NOT a SwiftUI modifier.
    /// See there for why it stopped being one.
    func applyTerminalConfig(_ configString: String, generation: Int) {
        guard generation != lastAppliedConfigGeneration else { return }
        lastAppliedConfigGeneration = generation
        let config = ghostty_config_new()
        if !configString.isEmpty {
            configString.withCString { cstr in
                ghostty_config_load_string(config, cstr, UInt(strlen(cstr)))
            }
        }
        ghostty_config_finalize(config)
        ghostty_app_update_config(app, config)
        ghostty_config_free(config)
    }

    private init() {
        #if os(macOS)
        // IME/NSTextInputClient side-effect guard (upstream AppDelegate.swift:207): once the
        // terminal view participates in text input, macOS "press and hold" would pop the
        // accent picker for a HELD letter key and SUPPRESS auto-repeat — wrong for a terminal
        // (holding `j` in vim must repeat). Registering the default (not `set`) keeps a user's
        // explicit `defaults write` override intact. Registered here — the one process-wide,
        // renderer-gated init that runs before any surface can take keyboard input.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
        #endif

        // 1. ghostty_init (header 1117): once per process, before any config/app.
        //    Signature is `int ghostty_init(uintptr_t, char**)` — argc/argv; we pass
        //    none (the embedder owns the CLI).
        _ = ghostty_init(0, nil)

        // 2. Config (header 1123 / 1132). Defaults are fine for the EXTERNAL backend;
        //    per-surface backend/callbacks are set in GhosttySurface, not here.
        //
        //    NOTE — we deliberately do NOT load the user's `~/.config/ghostty/config` here. Doing so
        //    (the obvious way to inherit their theme/palette/font) changes the FONT (e.g. `font-size`,
        //    `adjust-cell-height`), hence the cell size — but the host PTY then stays at the grid the
        //    surface was created with (default 80×24) instead of the real font-reflowed grid, so zsh
        //    wraps at the wrong column and fzf/Ctrl-R draw their UI at the wrong row (the reported
        //    "render lộn xộn"). Re-enabling theme/font inheritance requires ALSO making the host PTY
        //    track libghostty's real grid after the font reflow (and bundling ghostty's themes dir so
        //    NAMED themes like "Monokai Pro" resolve). Until that lands, keep the default config so the
        //    grid the GUI computes matches what libghostty renders. (The reported invisible
        //    zsh-autosuggestion was NOT a palette issue — it was the empty-HISTFILE shim bug, fixed in
        //    SlopDeskHost/ShellIntegration.swift.)
        let config = ghostty_config_new()
        // W13: apply the user's terminal-render prefs (font / theme / cursor / scrollback) BEFORE
        // finalize. `TerminalConfigBroadcaster` (set by the client's `PreferencesStore` on every
        // settings change, and at launch) holds the libghostty config string built by
        // `TerminalConfigBuilder`. Loading it here means a fresh surface starts with the user's font/
        // theme; a LATER change re-applies live via `GhosttyApp.applyTerminalConfig(_:)` →
        // `ghostty_app_update_config` (which reflows every surface, after which the view re-measures the
        // cell size and resizes the host PTY grid — fixing the documented grid-mismatch on a font reflow).
        let initialConfig = MainActor.assumeIsolated { TerminalConfigBroadcaster.shared.configString }
        if !initialConfig.isEmpty {
            initialConfig.withCString { cstr in
                ghostty_config_load_string(config, cstr, UInt(strlen(cstr)))
            }
        }
        ghostty_config_finalize(config)

        // 3. Runtime config (header 1073). The embedder must supply the callback set;
        //    for SlopDesk's external-backend viewer the surface's own write/resize
        //    callbacks carry the data path, so these app-level runtime callbacks are
        //    minimal no-ops (wakeup just ticks the app; clipboard/close are stubs the
        //    GUI coordinator can later enrich). All fields zero-initialized first.
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        // We provide a selection clipboard (Cmd-C populates it via copy_to_clipboard) — let libghostty
        // offer middle-click-paste / selection semantics (upstream App.swift sets this true).
        runtime.supports_selection_clipboard = true
        runtime.wakeup_cb = { _ in
            // libghostty asks to be ticked on its main loop. THIS IS A CROSS-THREAD SIGNAL by design
            // — on macOS it fires from libghostty's `renderer`/`io` libxev threads, NOT the main
            // actor. COALESCED via `requestAppTick`: those external-backend loops can fire this at a
            // very high rate, and scheduling a `ghostty_app_tick` per signal floods the main queue and
            // STARVES the MainActor (SwiftUI + the async connect → pane hung at "idle" while CPU spun).
            // (A bare `MainActor.assumeIsolated` here would TRAP off-main — the historical launch crash.)
            GhosttyApp.requestAppTick()
        }
        // action_cb returns whether the action was handled. The viewer handles none of the app-level
        // window/split/tab actions (SlopDesk's own canvas does the tiling) — EXCEPT
        // GHOSTTY_ACTION_OPEN_URL: libghostty owns OSC 8 hyperlink hit-testing + the click internally and
        // asks the embedder to OPEN the resolved URL (W14 #7). We hand it to the system opener (the
        // embedder's job upstream too) so a clicked OSC 8 link / hovered-URL click opens — no wire change,
        // no host-side OSC 8 parsing needed (see docs/DECISIONS.md). Everything else returns false.
        runtime.action_cb = { (_, target, action) -> Bool in
            // Match the C action tag by `==` (it imports as a RawRepresentable struct, not a Swift enum, so
            // it is not `switch`-case-able — same idiom as the clipboard-request comparison above).
            if action.tag == GHOSTTY_ACTION_OPEN_URL {
                let urlAction = action.action.open_url
                guard let cstr = urlAction.url else { return false }
                let urlString = String(cString: cstr)
                guard !urlString.isEmpty else { return false }
                // NSWorkspace/UIApplication open are main-thread; the action fires on the main loop tick.
                ghosttyOnMainActor {
                    #if os(macOS)
                    if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
                    #else
                    if let url = URL(string: urlString) { UIApplication.shared.open(url) }
                    #endif
                }
                return true
            } else if action.tag == GHOSTTY_ACTION_MOUSE_SHAPE {
                // E8 WI-9 (H14): OSC-22 pointer shape. A remote program's `OSC 22 ; <css-name> ST` arrives in
                // the CLIENT libghostty over the existing PATH-1 byte stream (no wire change); libghostty
                // resolves it and asks the embedder to set the pointer. Route the raw
                // `ghostty_action_mouse_shape_e` to the SURFACE it targets so THAT surface's macOS view maps it
                // (via the headless `PointerShapeMapping`) to an `NSCursor`. iOS leaves `onMouseShape` unset.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let cSurface = target.target.surface,
                      let ud = ghostty_surface_userdata(cSurface) else { return false }
                // Recover the wrapper IN-FRAME (libghostty is delivering an action ABOUT this surface, so it is
                // alive and strongly owned by its view); binding it to a Swift local retains it across the
                // main-actor hop. The raw shape is a value, copied here; `PointerShapeMapping` validate-then-
                // drops an unknown value (read defensively, never assuming a {0,1} enum layout).
                let surface = Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
                let rawShape = Int32(truncatingIfNeeded: action.action.mouse_shape.rawValue)
                ghosttyOnMainActor { surface.onMouseShape?(rawShape) }
                return true
            } else if action.tag == GHOSTTY_ACTION_MOUSE_VISIBILITY {
                // E8 (H9, ES-E8-6): mouse-hide-while-typing actuation. The `mouse-hide-while-typing = true`
                // config (default ON) only makes libghostty DECIDE to hide the pointer — it then
                // delegates the actual hide/show to the embedder via THIS action (`Surface.zig`
                // `hideMouse`/`showMouse` → `performAction(.mouse_visibility, .hidden/.visible)`). Without
                // this branch the action was dropped (`return false`) and the pointer never hid, so a
                // default-ON behavior silently did nothing. Mirror the MOUSE_SHAPE branch: recover the
                // target surface, resolve the raw `ghostty_action_mouse_visibility_e` via the headless,
                // {0,1}-guarded `MouseVisibilityMapping` (read defensively — never assume the enum layout),
                // hop to the main actor, and drive the pane's NSCursor through `onMouseVisibility`.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let cSurface = target.target.surface,
                      let ud = ghostty_surface_userdata(cSurface) else { return false }
                let surface = Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
                let rawVisibility = Int32(truncatingIfNeeded: action.action.mouse_visibility.rawValue)
                let visible = MouseVisibilityMapping.isVisible(forRawValue: rawVisibility)
                ghosttyOnMainActor { surface.onMouseVisibility?(visible) }
                return true
            } else if action.tag == GHOSTTY_ACTION_SCROLLBAR {
                // Viewport-scroll report (`terminal.Scrollbar`: total/offset/len screen rows), emitted by
                // libghostty's renderer whenever the viewport or scrollback geometry changes. Mirror the
                // MOUSE_SHAPE branch: recover the target surface, copy the three values (plain integers),
                // and forward on the main actor. The prompt-jump landed flash settles on this signal.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let cSurface = target.target.surface,
                      let ud = ghostty_surface_userdata(cSurface) else { return false }
                let surface = Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
                let bar = action.action.scrollbar
                let (offset, length, total) = (bar.offset, bar.len, bar.total)
                if ProcessInfo.processInfo.environment["SLOPDESK_BLOCKS_DEBUG"] == "1" {
                    // The SLOPDESK_BLOCKS_DEBUG jump trace's raw-signal end: proves the renderer's
                    // scrollbar action reaches the embedder at all (vs the settle chain dropping it).
                    FileHandle.standardError.write(
                        Data("[flash] scrollbar action offset=\(offset) len=\(length) total=\(total)\n".utf8),
                    )
                }
                ghosttyOnMainActor { surface.onScrollbarChange?(offset, length, total) }
                return true
            }
            return false
        }

        // Clipboard callbacks — modeled on upstream `Ghostty.App.swift:324-405`. The `userdata`
        // here is the SURFACE's userdata (libghostty passes it through), which slopdesk set to the
        // `GhosttySurface` in `GhosttySurface.init` (`config.userdata = passUnretained(self)`), so we
        // recover it via `Unmanaged<GhosttySurface>.fromOpaque(...).takeUnretainedValue()`. These fire
        // synchronously on the main thread from the surface's binding-action / OSC-52 path, so the
        // `@MainActor` `GhosttySurface` helpers are safe to call without a hop.

        // READ: libghostty wants the host pasteboard contents (paste / OSC-52 read). Read
        // NSPasteboard.general as a string and hand it straight back via the surface's
        // complete-request helper (upstream readClipboard, App.swift:324-338). No confirm dialog.
        //
        // THREADING: these clipboard callbacks fire SYNCHRONOUSLY on the MAIN thread — they originate
        // from the binding-action path (`@objc copy/paste`, main) and the OSC-52 `feed` path (main,
        // doc 18 §C) — exactly the main-thread assumption upstream's macOS App.swift makes. NSPasteboard
        // is itself main-thread-only. We use a SYNCHRONOUS `MainActor.assumeIsolated` (not the async
        // `ghosttyOnMainActor` hop) so the C `state` pointer is consumed in-frame without crossing an
        // actor boundary — matching upstream's direct synchronous handling.
        // v1.3.1 ABI: read_clipboard_cb returns Bool — `true` = "I am handling this request and
        // will complete it" (libghostty keeps `state` valid until `completeClipboardRead`); `false`
        // = "cannot start" (libghostty frees `state` itself). We ALWAYS complete the request
        // synchronously below (consuming `state`), so we MUST return `true`: returning `false` would
        // have libghostty free the already-consumed `state` → use-after-free.
        runtime.read_clipboard_cb = { (userdata, location, state) in
            guard let userdata else { return false }
            MainActor.assumeIsolated {
                let surface = Unmanaged<GhosttySurface>.fromOpaque(userdata).takeUnretainedValue()
                // HONOR `location`: STANDARD = the system clipboard; SELECTION = a SEPARATE clipboard.
                // libghostty's copy-on-select is ON by default, so a plain drag-select fires a SELECTION
                // write/read — routing that to the system clipboard would clobber the user's real
                // clipboard on every selection. Upstream maps SELECTION to a private pasteboard
                // (NSPasteboard.ghostty(_:)); we mirror that. iOS has no selection clipboard.
                #if os(macOS)
                let pb = slopdeskPasteboard(for: location)
                let live = pb.string(forType: .string) ?? ""
                #else
                let live = (location == GHOSTTY_CLIPBOARD_SELECTION) ? "" : (UIPasteboard.general.string ?? "")
                #endif
                // E8 WI-4 (ES-E8-3): if the embedder already ran the paste-protection sheet for THIS paste
                // and the user approved it, complete with `confirmed: true` (allow_unsafe) so libghostty pastes
                // without re-tripping its own (narrower) `isSafe` gate → no SECOND dialog. The flag is one-shot
                // and consumed here; every other read keeps `confirmed: false`, so the OSC-52 read access gate
                // (`clipboard-read = ask`) is never bypassed.
                //
                // TOCTOU fix: on an approved paste we return the REVIEWED SNAPSHOT captured at decide time,
                // NOT a fresh pasteboard read — a hosted-PTY OSC-52 write (or the user copying elsewhere while
                // the non-modal sheet was open) must not swap in unreviewed bytes under `allow_unsafe`.
                let (approved, reviewed) = surface.consumeApprovedPaste()
                let str = approved ? (reviewed ?? live) : live
                surface.completeClipboardRead(str, state: state, confirmed: approved)
            }
            return true
        }

        // CONFIRM-READ: libghostty reaches here when the access gate tripped on the FIRST completion —
        // an OSC-52 read (`clipboard-read = .ask`) or a paste of unsafe content
        // (`clipboard-paste-protection = true`). This is the embedder's APPROVE/DENY decision point; the
        // `request` arg distinguishes which gate fired.
        //
        // E8 WI-4 (ES-E8-3) — the OLD code blanket-AUTO-APPROVED everything (`confirmed: true`) because
        // there was no dialog. We now run the paste-protection sheet for an UNSAFE PASTE. The historical
        // crash warning still holds and is the WHOLE point of the de-risk: completing with `confirmed: false`
        // AND THE SAME UNSAFE DATA re-trips the gate → core re-invokes this callback → unbounded recursion →
        // stack overflow. The CANCEL path therefore does NOT re-complete the unsafe data — it completes with
        // EMPTY data, which hits libghostty's `if (data.len == 0) return;` short-circuit in
        // `Surface.completeClipboardPaste` (verified in ghostty-src `src/Surface.zig`): the request resolves
        // cleanly (apprt frees the request state in `embedded.zig:completeClipboardRequest`), nothing is
        // pasted, and the gate is NOT re-evaluated. "Paste Anyway" completes with the text + `confirmed: true`
        // (`allow_unsafe`), which pastes and frees the state. Either way the request terminates exactly once.
        //
        // E8 WI-6 (I11) — the `request` arg now ROUTES the decision: PASTE → the paste-protection sheet
        // (WI-4); OSC-52 READ → the `clipboard-read` access gate (Allow / Ask / Deny, default Ask) via
        // `slopdeskConfirmClipboardRead`. An OSC-52 WRITE never routes through this READ-confirm callback in
        // the pinned fork — a program WRITE goes via `write_clipboard_cb`, where `clipboard-write =
        // deny/ask/allow` is honoured: libghostty enforces `deny` (never calls the write callback) and
        // `allow` (calls with `confirm == false`), while `ask` is DELEGATED to that callback's `confirm` flag
        // (E8 WI-2 — `ClipboardWritePolicy` presents the write-confirm sheet there). So `clipboardWrite` is
        // honoured at `write_clipboard_cb`, not here. The trailing `else` therefore only guards an unexpected
        // / future request kind by terminating it once (auto-approve, matching the default `clipboard-read`).
        runtime.confirm_read_clipboard_cb = { (userdata, cString, state, request) in
            guard let userdata else { return }
            let str = cString.map { String(cString: $0) } ?? ""   // upstream uses String(cString:)
            MainActor.assumeIsolated {
                let surface = Unmanaged<GhosttySurface>.fromOpaque(userdata).takeUnretainedValue()
                // Match the C enum by `==` (it imports as a RawRepresentable struct, not a Swift enum, so it
                // is not `switch`-case-able); read it explicitly, never assuming a {0,1} layout.
                //
                // NO PLATFORM ARM HERE, and that is the point of the routing. The phone used to take an
                // `#else` that auto-approved BOTH questions — an unsafe paste and an OSC-52 read — while
                // Settings ▸ Controls showed it offering `clipboard-read = Ask`. Both halves route the
                // same two ways now, and the framework difference is confined to
                // ``slopdeskPresentClipboardConfirm``.
                if request == GHOSTTY_CLIPBOARD_REQUEST_PASTE {
                    slopdeskConfirmUnsafePaste(surface: surface, text: str, state: state)
                } else if request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ {
                    slopdeskConfirmClipboardRead(
                        surface: surface,
                        text: str,
                        state: state,
                        access: TerminalControls.from(config: .current).clipboardRead,
                    )
                } else {
                    surface.completeClipboardRead(str, state: state, confirmed: true)
                }
            }
        }

        // WRITE: libghostty (copy_to_clipboard / OSC-52 write) hands us a C array of
        // `ghostty_clipboard_content_s` { mime, data }. Write the text/plain entry to
        // NSPasteboard.general (upstream writeClipboard, App.swift:371-405). We model the STANDARD
        // clipboard only (the selection clipboard is virtual on macOS); ignore non-text mimes.
        runtime.write_clipboard_cb = { (userdata, location, content, len, confirm) in
            guard let content, len > 0 else { return }
            // Find the text/plain entry (mime == "text/plain"); fall back to the first entry's data.
            // Both pointers are NUL-terminated UTF-8 owned by libghostty — copied via String(cString:)
            // exactly like upstream `ClipboardContent.from(content:)` (GhosttyPackage.swift:298-308).
            var text: String?
            for i in 0..<Int(len) {
                let item = content[i]
                guard let dataPtr = item.data else { continue }
                let data = String(cString: dataPtr)
                let mime = item.mime.map { String(cString: $0) }
                if mime == "text/plain" { text = data; break }
                if text == nil { text = data }
            }
            guard let text else { return }
            // E8 WI-2 (I11): HONOR the libghostty `confirm` flag — the embedder side of `clipboard-write =
            // ask`. libghostty enforces `deny` (never calls this) and `allow` itself (calls with
            // `confirm == false`); `ask` is DELEGATED here with `confirm == true`, and the OLD code IGNORED
            // it and wrote unconditionally — so "Ask" silently behaved like "Allow" (any remote OSC-52 could
            // overwrite the system clipboard with no prompt). The PURE, headless-tested `ClipboardWritePolicy`
            // makes the decision; `confirm` already imports as a Swift `Bool` from C `bool` (no {0,1} byte to
            // re-read). Pasteboard is main-thread-only; this path is main (copy_to_clipboard / main feed).
            MainActor.assumeIsolated {
                // Recover the owning surface (same userdata contract as `confirm_read_clipboard_cb`) so a
                // landed STANDARD write can light the pane's `COPIED · N` chip via `onClipboardWrite`. The
                // SELECTION clipboard (copy-on-select drag → private pasteboard) stays chip-silent.
                let surface = userdata.map { Unmanaged<GhosttySurface>.fromOpaque($0).takeUnretainedValue() }
                let noteWrite = {
                    if location == GHOSTTY_CLIPBOARD_STANDARD { surface?.onClipboardWrite?(text) }
                }
                switch ClipboardWritePolicy.decide(confirmRequested: confirm, text: text) {
                case .drop:
                    return
                case .write:
                    slopdeskWriteClipboard(text, location: location)
                    noteWrite()
                case .confirm:
                    // `clipboard-write = ask`: present the "a program wants to set your clipboard"
                    // confirmation; write ONLY on approve, drop on cancel. Mirrors the OSC-52 READ-ask
                    // plumbing (WI-6).
                    //
                    // The phone used to take an `#else` here that DROPPED the write unpresented — the
                    // conservative choice while there was no surface to present, and still a decision
                    // made for the user: "Ask" behaved as Deny on the phone and as Ask on the Mac, from
                    // one settings row. There is a surface now, so there is no arm.
                    slopdeskPresentClipboardConfirm(
                        ask: .clipboardWrite,
                        preview: text,
                        dangers: [],
                    ) { allow in
                        if allow {
                            slopdeskWriteClipboard(text, location: location)
                            noteWrite()
                        }
                    }
                }
            }
        }

        runtime.close_surface_cb = { _, _ in }

        // 4. App (header 1141).
        self.app = ghostty_app_new(&runtime, config)

        // The config can be freed after app_new copies what it needs (header 1124).
        ghostty_config_free(config)

        // 5. W13 LIVE CONFIG: start following `TerminalConfigBroadcaster` HERE, in the one process-wide
        //    object that owns `ghostty_app_update_config`. See `followTerminalConfig` for why this is not
        //    (any longer) a SwiftUI `.onChange` on the renderer's `body`.
        followTerminalConfig()
    }

    /// W13, THE LIVE TERMINAL-CONFIG APPLY, AND THE ONE PLACE IT IS ARMED.
    ///
    /// This observation used to live in `GhosttyTerminalView.body` as
    /// `.onChange(of: TerminalConfigBroadcaster.shared.generation, initial: true)`, and it is the ONLY path
    /// from a Settings ▸ Terminal edit to a surface reflow: `PreferencesStore` rebuilds the libghostty
    /// config string, publishes it (bumping `generation`), and `ghostty_app_update_config` reflows +
    /// re-draws every surface — after which each surface's resize_callback fires `onResize` so the host PTY
    /// grid tracks the new font metrics. Nothing else calls it; nothing tests it (the apply needs a real
    /// libghostty app handle), so losing it is silent — the font just stops changing.
    ///
    /// It moved OFF the SwiftUI body because that body was not on every path to a surface: an AppKit canvas
    /// mounted `GhosttyLayerBackedView` through the seam's platform slot and never built the SwiftUI struct
    /// at all, so an observation living in that struct would have applied on the phone and silently not on
    /// the Mac. The struct is deleted now and there is one path, which does not put the observation back —
    /// a view's lifetime is the wrong lifetime for it either way. Here it is armed exactly once per
    /// process, by the object the apply is a method ON, and it covers every mount there will ever be.
    /// Lifetime is unchanged and needs none: `GhosttyApp.shared` is built lazily by the first surface,
    /// and until there is a surface there is no libghostty state to reflow — `init` loads whatever is
    /// published at that moment, and this follows every publish after it.
    ///
    /// ⚠️ `withObservationTracking` fires its `onChange` ONCE, and fires it on WILL-set — before the new
    /// `generation` is readable. So the callback hops one runloop (the new value is committed by then),
    /// applies, and RE-ARMS by calling this method again. Dropping the re-arm gives exactly one live
    /// config change per process, which looks like it works.
    private func followTerminalConfig() {
        withObservationTracking {
            _ = TerminalConfigBroadcaster.shared.generation
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    GhosttyApp.shared.applyPublishedTerminalConfig()
                    GhosttyApp.shared.followTerminalConfig()
                }
            }
        }
        // The `initial: true` half of the old `.onChange`. `init` already loaded the published string into
        // the config it built the app from, so this is usually a no-op — but `applyTerminalConfig` is
        // generation-guarded, not string-guarded, and a publish that lands between that read and here would
        // otherwise never be applied by anyone.
        applyPublishedTerminalConfig()
    }

    /// Apply whatever `TerminalConfigBroadcaster` currently holds. Split from ``followTerminalConfig`` so
    /// the arming and the applying are separately readable; generation-guarded inside, so calling it twice
    /// for one publish costs nothing.
    private func applyPublishedTerminalConfig() {
        applyTerminalConfig(
            TerminalConfigBroadcaster.shared.configString,
            generation: TerminalConfigBroadcaster.shared.generation,
        )
    }
}

// MARK: - What this file IS, now that the SwiftUI wrapper is gone

// The libghostty-backed terminal renderer is `GhosttyLayerBackedView` — one per platform, both
// below, both conforming to `TerminalSurfaceHosting`. A `public struct GhosttyTerminalView: View`
// used to sit here and wrap it through an `NSViewRepresentable`/`UIViewRepresentable`; it is
// deleted, along with both representables. The data flow it documented belongs to the view itself
// and is stated there, once per platform:
//
//  * **IN** (host PTY output → pixels): `TerminalViewModel.ingestOutput(_:)` already calls
//    `surface.feed(_:)`, so `attach(model:)` only has to hand the model its `GhosttySurface`
//    (`model.attachSurface(_:)`). (`feed` → `ghostty_surface_write_output` + refresh + draw.)
//  * **OUT** (keystrokes → host PTY stdin): the view forwards platform key/text events to
//    `surface.key(_:)` / `surface.text(_:)`; libghostty encodes them and emits the bytes via
//    `surface.onWrite`, which the connection layer bridges to `SlopDeskClient.sendInput`
//    (documented seam — see file header + doc 21). On the phone the key half is
//    `SlopDeskPhoneUI.TerminalInputHost`'s (doc 17 §2.5).
//  * **Resize**: `layout()` / `layoutSubviews()` converts the view's pixel size → cols/rows and
//    calls `surface.setSize(cols:rows:)`; the surface mirrors the grid to the host via
//    `surface.onResize`.
//  * **Render cadence**: libghostty drives its own draw from `feed`/`redraw`; the view presents on
//    a gated display-link tick and forces a `redraw()` on focus/occlusion/scale changes.
//
// ⚠️ **GUI-ONLY:** needs a real screen + the libghostty xcframework. Compiled + reviewed; not
// driven from tests.

// MARK: - The link snapshot, and the one hit-test both halves run

/// The viewport's detected links, cached, plus the gates that decide whether a point can be over one at
/// all. OUTSIDE the platform gate on purpose — this is the piece the phone was missing.
///
/// It lived as three private members of the macOS view (`detectedLinksCache`, `currentDetectedLinks()`,
/// `detectedLink(at:)`) inside the whole-file `#if os(macOS)` below, which is why the phone's long-press
/// menu could offer Copy and Paste but nothing about the path under the finger: the menu was already the
/// same `TerminalContextMenu` table, and the only thing on the Mac's side of the gate was the question
/// "what is this point on". Both `GhosttyLayerBackedView`s hold one of these now and ask it the same way;
/// the cell arithmetic itself is one floor down in the headless, tested
/// `SlopDeskWorkspaceCore.TerminalLinkHitTest`, which is where the mac view's copy of it went.
///
/// THE CACHE IS THE POINT OF THE TYPE. `viewportTextRows()` re-reads the whole visible grid row by row
/// through the C ABI (contending `renderer_state.mutex` with the off-main VT parse) and
/// `TerminalLinkDetector.detect` re-runs the scan; paying both on EVERY mouseMoved (60–120/s, main
/// thread) is what this removes. Keyed on the model's output generation (`bytesReceived`, bumped once per
/// ingest pass) + the local-scroll generation (`viewportRevision`) + the resolving cwd, so a hit-test
/// against an unchanged viewport is pure arithmetic. It must be ``invalidate()``d by anything that moves
/// the viewport WITHOUT bumping a key — a plain scroll on either platform — and by `detach()`, whose
/// snapshot belongs to a closing surface.
@MainActor
struct GhosttyLinkSnapshot {
    private var cache: (bytesReceived: Int, viewportRevision: Int, cwd: String?, links: [DetectedLink])?

    /// Nothing read yet. Spelled out because a `private` stored property makes the implicit memberwise
    /// initializer `private` too, and the two views that hold one of these are other types in this file.
    init() {}

    /// Drop the snapshot: the next hit-test re-reads the viewport.
    mutating func invalidate() { cache = nil }

    /// The detected links for the CURRENT viewport — served from the cache while its generation keys still
    /// match, else re-read and re-cached. The refresh deliberately KEEPS the per-row `viewportTextRows()`
    /// read (the soft-wrap grid-alignment fix), never the unwrapped whole-viewport one.
    mutating func links(model: TerminalViewModel?, surface: GhosttySurface?) -> [DetectedLink] {
        let bytes = model?.bytesReceived ?? 0
        let revision = model?.viewportRevision ?? 0
        let cwd = model?.linkCwd
        if let cache, cache.bytesReceived == bytes, cache.viewportRevision == revision, cache.cwd == cwd {
            return cache.links
        }
        let links = TerminalLinkDetector.detect(
            rows: surface?.viewportTextRows() ?? [],
            cwd: cwd,
            schemes: SettingsKey.linkSchemePolicy,
        )
        cache = (bytes, revision, cwd, links)
        return links
    }

    /// The ``DetectedLink`` under a top-left-origin surface POINT (points), or `nil` when link detection is
    /// off, the surface is a mouse-reporting TUI (alt screen — don't fight vim/tmux/htop), there is no live
    /// surface to measure, or the point is simply over no detected span.
    ///
    /// `slop` is how far off a span the point may be and still count: `0` for a pointer, which lands where
    /// it is aimed, and `TerminalTouchSelection.linkHitSlop` for a fingertip, which does not.
    mutating func link(
        at point: (x: Double, y: Double),
        model: TerminalViewModel?,
        surface: GhosttySurface?,
        slop: Double = 0,
    ) -> DetectedLink? {
        guard SettingsKey.linkDetectionEnabled,
              model?.isAlternateScreen == false,
              let metrics = surface?.cellMetrics()
        else { return nil }
        return TerminalLinkHitTest.link(
            in: links(model: model, surface: surface),
            metrics: metrics,
            pointX: CGFloat(point.x),
            pointY: CGFloat(point.y),
            slop: CGFloat(slop),
        )
    }
}

// MARK: - GhosttyLayerBackedView (the layer-hosting renderer view)

#if os(macOS)

/// A LAYER-HOSTING `NSView` for libghostty's macOS renderer.
///
/// CRITICAL — how libghostty presents on macOS (read from `renderer/Metal.zig`): libghostty
/// creates its OWN `IOSurfaceLayer` and installs it as THIS view's `layer` via the layer-HOSTING
/// pattern — `info.view.setProperty("layer", <IOSurfaceLayer>)` THEN `wantsLayer = true`. It does
/// NOT render into a `CAMetalLayer` / `nextDrawable`. Therefore this view must be a PLAIN,
/// initially layer-less `NSView` and must let libghostty own the `layer` slot.
///
/// A previous version force-installed its OWN `CAMetalLayer` (assigning `layer` + overriding
/// `makeBackingLayer`). That `CAMetalLayer` won the view's `layer` slot, so libghostty's
/// `IOSurfaceLayer` was never in the view hierarchy and never displayed — the terminal painted
/// BLANK even though `feed` delivered bytes and `draw_now` ticked (libghostty WAS rendering, into
/// an orphaned off-screen layer). Confirmed by a live Mac Studio repro + reading `Metal.zig`.
///
/// A `CADisplayLink` drives `ghostty_surface_draw_now` each display tick (see `renderDisplayLink`),
/// MIRRORING the iOS sibling, so the renderer thread flushes its lazily-rasterized glyphs. The
/// hosted layer's frame + contentsScale are sized in `layout()` (a layer-hosting view does not get
/// its hosted layer auto-resized to the view bounds).
final class GhosttyLayerBackedView: NSView {
    /// Strong owner of the surface. `TerminalViewModel.surface` is `weak`, so the view
    /// is the lifetime owner (the GUI owns it on main; `detach()`/`deinit` free it).
    private var surface: GhosttySurface?
    weak var model: TerminalViewModel?

    /// Whether THIS pane is the workspace's focused pane — seeded by the seam's factory at mount and
    /// re-pushed by ``TerminalSurfaceHosting/setPaneFocused(_:)``. Drives TWO things:
    /// (1) the keyboard FIRST RESPONDER (only the focused pane takes the keyboard); and (2) libghostty's
    /// render FOCUS — an unfocused pane is `setFocus(false)` so ghostty draws its HOLLOW, non-blinking cursor
    /// (focused = the solid block) exactly like ghostty's own split panes. Forwarding unfocus does NOT freeze
    /// the pane: new host output still presents via the content-driven `onContentChanged → requestPresent`
    /// path (focus-INDEPENDENT — `drawFrame` never early-returns on unfocus, it only stops ghostty's INTERNAL
    /// blink/auto-draw), so an unfocused split sibling keeps repainting — and now idles ghostty's render
    /// thread when unfocused (a CPU win). On a change to `true` the pane claims first responder; on `false`
    /// it does NOT resign the keyboard (a sibling claiming FR resigns it).
    var isFocusedPane: Bool = true {
        didSet {
            guard isFocusedPane != oldValue else { return }
            // Forward render focus → ghostty's hollow (unfocused) / solid (focused) cursor, COALESCED to the
            // next runloop (see `forwardRenderFocus`) so an in-runloop focus FLICKER can't strand the blink.
            // The coalesced forward also re-presents to flip the cursor style. Keyboard FR stays synchronous.
            forwardRenderFocus(isFocusedPane)
            applyKeyboardFocus()
        }
    }

    /// Render-focus last forwarded to libghostty / the value awaiting the next-runloop forward. Render focus
    /// is COALESCED (deferred one runloop hop, last-writer-wins, deduped against `lastForwardedFocus`) rather
    /// than forwarded synchronously. WHY: two render-focus messages — an unfocus then a refocus — landing in
    /// the SAME libghostty render-thread mailbox drain trip a cursor-blink race. The unfocus dispatches an
    /// ASYNC cancel of the blink timer; if the refocus is processed before that cancel completes, the
    /// refocus's `if (cursor_c.state() != .active)` guard skips re-showing the cursor, then the cancel lands
    /// and leaves `cursor_blink_visible = false` with a DEAD timer — so the focused pane's blinking cursor is
    /// stuck INVISIBLE until the next PTY byte resets it (`reset_cursor_blink`). A focus FLICKER —
    /// `isFocusedPane` false→true within one runloop (a tab switch, a popover open/close, the
    /// mouse-move focus policy, or `becomeFirstResponder` racing the canvas's own push) — is exactly that
    /// two-message pattern. Deferring the forward collapses an in-runloop flicker to a SINGLE net forward, so
    /// the unfocus + refocus never co-occur. A genuine cross-runloop refocus is unaffected (by then the
    /// cancel completed and libghostty's own focus handler re-shows the cursor + restarts the blink timer).
    private var lastForwardedFocus: Bool?
    private var pendingFocusForward: Bool?

    private func forwardRenderFocus(_ focused: Bool) {
        let alreadyScheduled = pendingFocusForward != nil
        pendingFocusForward = focused
        guard !alreadyScheduled else { return } // last-writer-wins: the scheduled hop reads the final value
        DispatchQueue.main.async { [weak self] in
            guard let self, let want = self.pendingFocusForward else { return }
            self.pendingFocusForward = nil
            guard self.lastForwardedFocus != want else { return } // net no-op flicker → never reaches ghostty
            self.lastForwardedFocus = want
            self.surface?.setFocus(want)
            // Re-present so the hollow⇄solid flip shows; a focus-GAIN gets a longer burst so the restarted
            // blink's first visible frame lands despite our gated present.
            self.requestPresent(want ? 6 : 3)
        }
    }

    /// Claims the keyboard first responder iff this is the focused pane and on-window. Never resigns here
    /// (the sibling that becomes focused makes ITSELF first responder, which resigns this one). Render focus
    /// is driven SEPARATELY by the `isFocusedPane` didSet (forwarded to `surface.setFocus`), not here.
    private func applyKeyboardFocus() {
        guard isFocusedPane else { return }
        // Defer off the caller's own commit pass: makeFirstResponder synchronously tears down + sets up
        // the AppKit responder chain (and draws the focus ring), which stalled the main thread when it ran
        // inside the canvas's focus push during a tab/session switch. One runloop hop makes the switch a
        // single CA commit; the keyboard first-responder transfer happens imperceptibly after.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFocusedPane,
                  let window = self.window,
                  window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    /// Drives libghostty's renderer thread via `ghostty_surface_draw_now`. GATED on `presentTicks`:
    /// it presents only when there is something new, NOT every display frame. An UNCONDITIONAL
    /// per-tick `draw_now` kept the renderer thread's `draw_now` mach-port permanently ready, so its
    /// libxev loop busy-spun in `kqueue.Loop.tick` at ~100% CPU — flooding the main thread and
    /// starving the async connect (pane stuck "idle"). Gating lets the loop block in `kevent()` when
    /// idle → CPU ~0. (Verified by profiling on a Mac Studio.)
    private var renderDisplayLink: CADisplayLink?

    /// Frames still owed to the renderer (set by `requestPresent`, drained by `renderTick`). Counts
    /// a few — not 1 — so the renderer thread's LAZY glyph rasterization flushes over the next ticks
    /// after new content arrives.
    private var presentTicks = 0

    /// Pending work items of the post-resize "settle present burst" (see `scheduleSettlePresentBurst`).
    /// Held so a CONTINUOUS drag coalesces to ONE burst: each new `layout()` cancels the prior array
    /// before scheduling, so only the LAST settle's burst survives. A FIXED, finite array → the burst
    /// is provably bounded and self-terminating (it never reschedules itself).
    private var settleItems: [DispatchWorkItem] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Do NOT set `wantsLayer`, assign a `layer`, or override `makeBackingLayer`: libghostty
        // installs its OWN `IOSurfaceLayer` as this view's layer (layer-hosting) during
        // `ghostty_surface_new` (in `attach`). Pre-installing a layer here fights that and the
        // terminal renders blank (the lesson of the orphaned-CAMetalLayer bug above).
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Ask for the next few display ticks to present (drain new content / flush lazy glyphs).
    ///
    /// SINGLE arming choke point: it also UN-PAUSES the display link (renderTick pauses it
    /// when the ticks drain), so an idle pane costs zero main-thread wakeups instead of a
    /// 60Hz no-op tick per pane forever. Every arming site (feed→onContentChanged, attach,
    /// layout, settle-burst items, viewDidMoveToWindow) is main-thread, so the un-pause is
    /// strictly ordered before the tick that must serve it; resume latency = next vsync,
    /// identical to the old gated no-op tick. Any future arming path MUST route through
    /// here or it will silently never present. Nil-safe for SLOPDESK_NO_TICK.
    func requestPresent(_ ticks: Int = 3) {
        if kRenderDebug { rdbg("requestPresent(\(ticks)) [was \(presentTicks)]") }
        presentTicks = max(presentTicks, ticks)
        renderDisplayLink?.isPaused = false
    }

    /// Post-resize REPAINT-RESIDUAL fix (idle-prompt-prefix-blank-after-resize).
    ///
    /// After a resize SETTLES, the host applies the coalesced `TIOCSWINSZ` → `SIGWINCH` → zsh and
    /// libghostty's IO thread reflows the local grid; the renderer thread rebuilds the cells and
    /// presents them via the ASYNC path (`drawFrame(false)` → `setSurface`), which is size-discarded
    /// if the rendered IOSurface no longer matches `layer.bounds × scale`. Meanwhile the only
    /// size-UNCONDITIONAL present — the gated `renderTick` → `setSurfaceSync` — has already drained its
    /// ≤3 `presentTicks` (within ~3 display frames), so it is asleep by the time (i) the renderer
    /// thread's reflow frame completes and (ii) zsh's redraw bytes arrive ~1 RTT later. Result: the
    /// idle editing-prompt prefix stays BLANK until the next content event re-arms a present.
    ///
    /// FIX: after the LAST layout, keep the sync-present path alive for a BOUNDED window by injecting a
    /// FIXED, finite series of `requestPresent` ticks spaced over ~400ms, so those late frames/bytes get
    /// painted, THEN it stops. Each new `layout()` cancels the prior burst first, so a long continuous
    /// drag coalesces to exactly ONE burst that starts only after the drag settles.
    ///
    /// PROVABLY BOUNDED / cannot busy-spin: the schedule is a HARD-CODED array (≤ `kSettleBurstMs.count`
    /// work items), each item does a single `requestPresent(2)` and NOTHING reschedules — after the last
    /// item fires, no further work is posted. `renderTick` keeps its `guard presentTicks > 0` gate
    /// untouched, so between/after the ≤2-tick bursts the renderer's libxev loop blocks in `kevent()`
    /// and CPU returns to ~0. Total extra work per settle ≤ `kSettleBurstMs.count × 2` presents.
    private static let kSettleBurstMs: [Int] = [50, 120, 200, 300, 400]

    private func scheduleSettlePresentBurst() {
        // Coalesce a continuous drag to ONE burst: drop any burst scheduled by an earlier layout pass
        // so only the LAST (settled) layout's burst runs.
        for item in settleItems { item.cancel() }
        settleItems.removeAll(keepingCapacity: true)
        for ms in Self.kSettleBurstMs {
            let item = DispatchWorkItem { [weak self] in self?.requestPresent(2) }
            settleItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
        }
    }

    /// libghostty installs its layer + spawns its renderer/io threads inside `ghostty_surface_new`,
    /// so the surface is created ONLY once the view is in a real window — never in the window the
    /// seam's factory hands one back from, which is nobody's yet (a surface built there would be a
    /// duplicate surface + thread set that busy-spins if the canvas never mounts it).
    /// Observer token for the current window's ``NSWindow/didResignKeyNotification`` — clears the ⌘-hold
    /// link underline when the window loses key (⌘-Tab away / clicking another app) while ⌘ is held, since
    /// that path delivers NO ⌘-release `flagsChanged` and does NOT call `resignFirstResponder` (the view
    /// stays first responder). Re-scoped to the live window on every `viewDidMoveToWindow`.
    private var windowResignKeyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-scope the window-resign-key observer to the CURRENT window (removed first so a moved/detached
        // view never keeps a stale subscription to a window it left).
        if let token = windowResignKeyObserver {
            NotificationCenter.default.removeObserver(token)
            windowResignKeyObserver = nil
        }
        if window != nil {
            if let model { attach(model: model) }
            startRenderTickIfNeeded()
            requestPresent(8)   // prime the initial glyph flush
            windowResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main,
            ) { [weak self] _ in
                // On the main queue already (`queue: .main`); `MainActor.assumeIsolated` bridges the
                // non-isolated notification block to this @MainActor view's `clearLinkHighlight()`.
                MainActor.assumeIsolated { self?.clearLinkHighlight() }
            }
            // Claim the keyboard ONLY if this is the workspace's focused pane. In a multi-pane split
            // every pane used to call `makeFirstResponder` on mount, so the LAST-mounted pane stole the
            // keyboard regardless of `store.focusedPane` (focus-stealing bug). Render focus now FOLLOWS the
            // workspace focus (`attach()` → `surface.setFocus(isFocusedPane)`): an unfocused pane shows
            // ghostty's hollow non-blinking cursor but STILL repaints output via the content-driven present
            // path (`onContentChanged → requestPresent`), so it never freezes. Deferred so the window is key.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isFocusedPane, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        } else {
            renderDisplayLink?.invalidate()   // off-window: stop ticking so a detached view never spins
            renderDisplayLink = nil
        }
    }

    /// Idempotent: builds the surface on first call (only when on-window), then attaches it to the
    /// model. `viewDidMoveToWindow` is its ONLY caller now that no representable re-runs an update
    /// pass, and it is still written to be safe called repeatedly — a view can leave and re-enter a
    /// window.
    func attach(model: TerminalViewModel) {
        self.model = model
        guard window != nil else { return }   // never spawn a surface for a view no window holds yet
        if surface == nil {
            let s = GhosttySurface(
                app: GhosttyApp.shared.app,
                platformView: Unmanaged.passUnretained(self).toOpaque(),
                cols: 80,
                rows: 24,
                contentScale: Double(window?.backingScaleFactor ?? 2.0)
            )
            // OUT path: encoded keystrokes → model input sink → live SlopDeskClient.sendInput.
            s.onWrite = { [weak model] (data: Data) in model?.sendInput(data) }
            // Grid changes (font reflow) → model resize sink → host TIOCSWINSZ.
            s.onResize = { [weak model] (cols: UInt16, rows: UInt16) in model?.sendResize(cols: cols, rows: rows) }
            // New inbound bytes were fed → ask the gated tick to present. This is the dirty signal
            // that REPLACES a free-running per-frame `draw_now` (the spin source). Without it the
            // gated tick would never present live output.
            s.onContentChanged = { [weak self] in self?.requestPresent() }
            // E8 WI-9 (H14): OSC-22 pointer shape → this pane's NSCursor (mapped headlessly, set thinly here).
            s.onMouseShape = { [weak self] raw in self?.applyPointerShape(rawShape: raw) }
            // E8 (H9): mouse-hide-while-typing → hide/show this pane's NSCursor (libghostty decides; we actuate).
            s.onMouseVisibility = { [weak self] visible in self?.applyMouseVisibility(visible) }
            // E8 (WI-5): the libghostty-initiated paste BACKSTOP (`slopdeskConfirmUnsafePaste`, reached via
            // middle-click) reads the REAL alt-screen flag through this hook so it suppresses inside a true
            // full-screen TUI — matching the ⌘V `requestPaste` path (no more hardcoded `false`).
            s.isAlternateScreen = { [weak model] in model?.isAlternateScreen ?? false }
            // A landed ⌘C / OSC-52 STANDARD-clipboard write → the pane's transient `COPIED · N` receipt
            // chip (libghostty owns the write; this is the only observation point that sees the text).
            s.onClipboardWrite = { [weak model] text in model?.noteClipboardCopy(text) }
            // Viewport-scroll echo → the prompt-jump landed-flash settle signal. `atBottom` = the
            // viewport is the ACTIVE area (offset+len reaches total — overflow-checked because the
            // values cross a C ABI), where a forward jump could NOT pin the prompt at row 0.
            s.onScrollbarChange = { [weak model] offset, length, total in
                let end = offset.addingReportingOverflow(length)
                let atBottom = end.overflow || end.partialValue >= total
                model?.noteViewportScroll(atBottom: atBottom)
            }
            self.surface = s
            // A BRAND-NEW surface must get its first real layout (setPixelSize) — drop the
            // same-size guard's cache so the next layout() pass applies unconditionally.
            lastAppliedLayout = nil
        }
        // attachSurface(_:) (not `model.surface = surface`) so the model REPLAYS its retained byte
        // ring into a rebuilt surface (tab switch / reshape). No-op replay when unchanged.
        if let surface { model.attachSurface(surface) }
        // Render focus FOLLOWS the workspace focus (not always-on): the focused pane gets the solid block
        // cursor, an unfocused split sibling ghostty's hollow non-blinking cursor. Unfocused panes still
        // repaint host output via the content-driven present path above, so this never freezes them; it
        // also lets ghostty idle an unfocused pane's render thread (CPU win). The `isFocusedPane` didSet
        // re-forwards this on every focus change (with a `requestPresent` to flip the cursor style at once).
        // Seed `lastForwardedFocus` so the coalesced `forwardRenderFocus` dedupes against the value set here.
        lastForwardedFocus = isFocusedPane
        surface?.setFocus(isFocusedPane)
        // Resize-END → RE-ANCHOR the settle present burst to the release moment. The host `TIOCSWINSZ`
        // is DEFERRED to release, so its SIGWINCH-driven redraw bytes land ~1 RTT AFTER the layout-
        // anchored burst (armed by the last `layout()`) may have already expired — and the final layout
        // often hits the same-size guard and arms no burst at all. Re-arming here keeps the size-
        // unconditional sync-present path alive across that RTT so the reflowed frame is painted (the
        // intermittent "kéo xong không re-render" race). Set on the MODEL each attach (it persists
        // across view rebuilds; a stale prior view's `[weak self]` closure no-ops once overwritten).
        model.onResizeSettled = { [weak self] in
            guard let self else { return }
            requestPresent(3)             // paint whatever already arrived this instant
            scheduleSettlePresentBurst()  // …and sustain the sync-present path ~400ms for the late bytes
        }
        // E5: the ⌘F find bar closing tears down the focused query field WITHOUT a workspace-focus change, so
        // none of the surface's own reclaim paths (the `isFocusedPane` didSet, mount, mouseDown, focus-follows-
        // mouse — all gated on a focus TRANSITION or a click) fire. `close()` calls `reclaimKeyboardFocus()`,
        // which invokes this so THIS pane re-takes the window's first responder (via the same deferred,
        // `isFocusedPane`-guarded `makeFirstResponder` the didSet uses). Re-set each attach; a stale prior
        // view's `[weak self]` closure no-ops once overwritten.
        model.onReclaimKeyboardFocus = { [weak self] in self?.applyKeyboardFocus() }
        requestPresent(8)   // flush whatever the replay just fed
    }

    private func startRenderTickIfNeeded() {
        guard renderDisplayLink == nil, window != nil,
              ProcessInfo.processInfo.environment["SLOPDESK_NO_TICK"] == nil else { return }
        let link = displayLink(target: self, selector: #selector(renderTick))
        link.add(to: .main, forMode: .common)
        renderDisplayLink = link
    }

    @objc private func renderTick() {
        // GATED present. Idle → return WITHOUT presenting, so the renderer thread's libxev loop
        // blocks in `kevent()` and CPU drops to ~0 (the cure for the 100% spin). After new content
        // (`requestPresent` from feed / attach-replay / layout) present for a few ticks so the
        // renderer thread's lazily-rasterized glyphs flush.
        //
        // Drive libghostty's IOSurfaceLayer `display` callback → `drawFrame(true)` → `present(sync)`
        // → `setSurfaceSync`, INSIDE a CA commit so the new contents ACTUALLY appear. This is the
        // SAME present path a window RESIZE uses (`needsDisplayOnBoundsChange`) — the only path
        // observed to update the screen on real hardware. `feed`'s `refresh` already rebuilt the cells
        // on the renderer thread, so the `drawFrame(true)` invoked here renders the FRESH frame. Runs
        // on the runloop (display-link tick); GATED on `presentTicks` so idle is a cheap no-op (no
        // 100%-CPU spin, no MainActor starvation). `displayIfNeeded()` forces the `display` synchronously
        // this tick rather than waiting for the next CA pass.
        guard presentTicks > 0 else {
            // Ticks drained → PAUSE the link entirely: an idle pane stops costing a 60Hz
            // main-thread wakeup. requestPresent (the single arming choke point) un-pauses.
            renderDisplayLink?.isPaused = true
            return
        }
        if kRenderDebug { rdbg("renderTick DISPLAY (ticks=\(presentTicks))") }
        presentTicks -= 1
        layer?.setNeedsDisplay()
        layer?.displayIfNeeded()
    }

    func detach() {
        renderDisplayLink?.invalidate()
        renderDisplayLink = nil
        lastAppliedLayout = nil   // a future re-attach must re-apply size unconditionally
        linkSnapshot.invalidate()  // the snapshot belongs to the closing surface's viewport
        // Cancel any pending settle-present burst so a torn-down view never fires `requestPresent`.
        for item in settleItems { item.cancel() }
        settleItems.removeAll(keepingCapacity: true)
        let detaching = surface
        surface = nil
        detaching?.close()
        // E8 WI-9 (H14): reset the OSC-22 pointer to arrow on teardown so a custom shape a program had set
        // can't outlive the surface into a re-attach (the hard "reset on exit" guard; the DEFAULT-shape path
        // covers the in-session case). Cheap and idempotent — invalidate so AppKit re-reads on the next event.
        pointerCursor = .arrow
        // E8 (H9): also unhide the pointer on teardown so a mouse-hide-while-typing hide can't outlive the
        // surface into a re-attach (cheap + idempotent; `setHiddenUntilMouseMoves(false)` cancels any pending
        // hide). `setHiddenUntilMouseMoves(true)` already auto-shows on the next move, so this is belt-and-braces.
        NSCursor.setHiddenUntilMouseMoves(false)
        window?.invalidateCursorRects(for: self)
        // Pass the detaching surface so the model clears its `surface` ONLY if this is the surface it
        // currently feeds. A stale duplicate view's detach must NOT nil the live (on-screen) surface
        // — that froze the visible terminal on its initial replay while new output was dropped.
        // A surface-LESS view (one built by the factory and never mounted) makes NO call at all:
        // `detachSurface(nil)` takes the unconditional else-branch and clears the LIVE pane's surface,
        // freezing the visible terminal until some unrelated pass re-attaches.
        if let detaching { model?.detachSurface(detaching) }
    }

    deinit {
        // @MainActor not available in deinit; the surface's own deinit frees the
        // ghostty_surface_t. We rely on detach() — reached through
        // ``TerminalSurfaceHosting/detachSurface()`` — as the explicit path.
        // The window-resign-key observer is NOT dropped here — a nonisolated deinit can't touch the
        // non-Sendable `(any NSObjectProtocol)?` token on this @MainActor view. It doesn't need to:
        // AppKit always calls `viewDidMoveToWindow` with a nil window BEFORE a view deallocates (a view
        // in a window is retained by it), and that teardown removes + nils the observer. So by deinit it
        // is already gone.
    }

    // MARK: Resize → grid

    /// The last (bounds.size, scale) actually APPLIED to a live surface+layer by `layout()`.
    /// Same-size AppKit layout passes (focus change, canvas reshuffle) early-out: with
    /// patch 0001, `surface.redraw()` is a FULL synchronous updateFrame+drawFrame on MAIN,
    /// and every layout also arms presentTicks + a 5-item settle burst (≤10 more sync
    /// presents) — a spurious same-size pass cost a main-thread render ×~13. Cached ONLY
    /// when surface != nil && layer != nil (before attach, the surface calls were no-ops —
    /// caching then would skip the first REAL layout and hit the renderer's zero-size guard
    /// → blank pane); invalidated in attach()/detach() so a rebuilt surface always gets its
    /// setPixelSize.
    private var lastAppliedLayout: (size: CGSize, scale: CGFloat)?

    /// P5b: the keyCode whose PRESS copy-mode consumed but whose RELEASE will arrive AFTER the mode flag has
    /// already cleared (the q/Esc/Enter exit key flips `isCopyMode` false synchronously inside keyDown, so the
    /// matching keyUp's `isCopyMode == true` guard is already false). Stamped in keyDown's copy-mode branch and
    /// swallowed ONCE by keyUp — otherwise a kitty `report_events` TUI would emit an orphan CSI-u release for
    /// the exit key (the exact failure the keyUp symmetry guard targets, which the flag check alone misses for
    /// the key that DID the exit). `nil` = nothing pending.
    private var copyModeConsumedReleaseKeyCode: UInt16?

    /// E10 WI-9: the Hint Mode analogue of ``copyModeConsumedReleaseKeyCode`` — the keyCode whose PRESS hint
    /// mode consumed but whose RELEASE arrives after the mode has already exited (the confirming second key
    /// flips `hintMode` to nil synchronously inside keyDown, so the matching keyUp's `hintMode != nil` guard is
    /// already false). Stamped in keyDown's hint branch and swallowed ONCE by keyUp. `nil` = nothing pending.
    private var hintConsumedReleaseKeyCode: UInt16?

    /// WS-B / B4: the keyCode whose PRESS the workspace interceptor SWALLOWED (a resolved chord) so the
    /// matching RELEASE is suppressed too.
    /// libghostty never saw the press, so without this its `keyUp` would encode an orphan CSI-u release under
    /// a kitty `report_events` TUI (the exact press/release-symmetry hazard the copy-mode + Ctrl+C0 branches
    /// already guard). Stamped in `keyDown` on swallow, cleared once by the matching `keyUp`. `nil` = nothing
    /// pending.
    private var workspaceConsumedReleaseKeyCode: UInt16?

    // MARK: IME (NSTextInputClient) state — ported from upstream `Ghostty.SurfaceView`
    // (SurfaceView_AppKit.swift). The conformance itself is the extension after this class.

    /// The IME's current marked (composing) text — the un-committed "vie" of Telex "việt", the
    /// romaji/kana of a Japanese conversion, or a pending dead-key accent. Mirrored to
    /// libghostty as the PREEDIT (`syncPreedit` → `surface.preedit`) so it renders at the
    /// cursor cell with the composing underline. Empty ⇔ no composition in progress.
    private var markedText = NSMutableAttributedString()

    /// Non-nil ONLY while `keyDown` is inside `interpretKeyEvents`: text the input context
    /// COMMITS via `insertText` during that window accumulates here so `keyDown` can send the
    /// composed result through the ghostty KEY path (with the event's keycode/mods) instead of
    /// a bare text write. `nil` means an `insertText` arrived OUTSIDE a keyDown (e.g. the user
    /// picked a candidate with the MOUSE in the IME window) → committed via `surface.text`.
    /// Upstream: `keyTextAccumulator` (SurfaceView_AppKit.swift:226).
    private var keyTextAccumulator: [String]?

    /// Timestamp of the last ⌘/⌃ key equivalent this view let flow through AppKit unhandled.
    /// Because the view is now an NSTextInputClient, AppKit's input context may redirect such
    /// an equivalent to `doCommand(by:)` BEFORE `keyDown` ever sees it (⌘. → "cancel:");
    /// `doCommand` re-sends the event and `unhandledKeyEquivalent` recognizes it by this
    /// timestamp on the second pass, routing it to `keyDown` for ghostty encoding. NSEvent has
    /// no reliable identity; the timestamp comparison (guarding the synthetic timestamp-0
    /// events) is upstream's proven workaround (`lastPerformKeyEvent`, SurfaceView_AppKit).
    private var lastPerformKeyEvent: TimeInterval?

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2.0
        // SAME-SIZE GUARD: skip the whole setPixelSize/redraw/settle-burst pipeline when
        // nothing changed. Deliberately does NOT touch settleItems on the skip path — a
        // prior real resize's ~400ms settle window still completes.
        if let last = lastAppliedLayout, last.size == bounds.size, last.scale == scale,
           surface != nil, layer != nil {
            return
        }
        // Pass ACTUAL pixel extent; libghostty derives the grid from its measured cell metrics, rounds
        // the surface to whole cells, and fires resize_callback → onResize (host TIOCSWINSZ).
        let pxW = UInt32(max(1, Int((bounds.width * scale).rounded())))
        let pxH = UInt32(max(1, Int((bounds.height * scale).rounded())))
        surface?.setContentScale(Double(scale))
        surface?.setPixelSize(widthPx: pxW, heightPx: pxH)
        // Size libghostty's HOSTED `IOSurfaceLayer` to the RAW VIEW BOUNDS (points) — NOT the
        // cell-rounded `renderedPixelSize` read-back. libghostty treats `layer.bounds × contentsScale`
        // as its SINGLE size-of-truth: `surfaceSize()` (renderer/Metal.zig) recomputes width/height
        // from it at the head of every `drawFrame`, and its async present's discard guard
        // (IOSurfaceLayer.zig) compares the rendered IOSurface against that same product. A
        // layer-hosting view does NOT auto-size its hosted layer, so the embedding must set it.
        //
        // RESIZE-CORRUPTION FIX ("vỡ"): sizing the layer to `renderedPixelSize/scale` made
        // layer.bounds a few px SMALLER than the view during a drag-resize, and each continuous
        // layout() wrote a DIFFERENT wrong size. The gated renderTick presents via the SYNC path
        // (`displayIfNeeded` → IOSurfaceLayer `display` → `setSurfaceSync`), which has NO size check,
        // so a frame rendered against the stale layer.bounds was shown unconditionally; with
        // contentsGravity = topLeft + clipsToBounds, the size-mismatched IOSurface anchored top-left
        // and the uncovered/over-extended edge tore (the "vỡ"). Pinning layer.bounds == view.bounds
        // makes drawFrame render an IOSurface that EXACTLY matches the layer, so the sync present lands
        // a correct frame and any late async frame from a prior size is correctly discarded. This
        // mirrors the iOS sublayer (sized to raw bounds, layoutSubviews) and upstream ghostty (which
        // never sets layer.frame). The initial-attach present still lands: bounds×scale == pxW/pxH that
        // was just handed to setPixelSize, so libghostty's IOSurface matches the layer on first frame
        // too (cell rounding only affects grid cols/rows, not screen.width/height = the raw input).
        if let hosted = layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = CGRect(origin: .zero, size: bounds.size)
            hosted.contentsScale = scale
            // FLAT PANE design: the terminal fills its leaf edge-to-edge with NO corner
            // radius — its surface is the same flat colour as the backdrop beneath, so a pane never reads
            // as a floating card. `masksToBounds` clips the libghostty Metal sublayer to the exact bounds
            // RECTANGLE (radius 0); contentsGravity stays .topLeft so the clip does not shift the surface.
            hosted.cornerRadius = 0
            hosted.masksToBounds = true
            CATransaction.commit()
        }
        rdbg("macOS layout bounds=\(Int(bounds.width))x\(Int(bounds.height)) scale=\(scale) px=\(pxW)x\(pxH) rendered=\(surface?.renderedPixelSize.map { "\($0.width)x\($0.height)" } ?? "nil")")
        surface?.redraw()
        requestPresent()   // a layout/resize changed the grid → present the reflowed frame
        // BOUNDED settle burst: keep the sync-present path alive for ~400ms after the LAST layout so a
        // late renderer-thread reflow frame / late host (zsh) redraw bytes get painted even though the
        // initial `requestPresent()` ticks drain within a few display frames. Finite + self-terminating
        // (see `scheduleSettlePresentBurst`); a continuous drag coalesces to one burst.
        scheduleSettlePresentBurst()
        // Cache ONLY a fully-applied pass (live surface + hosted layer) — see lastAppliedLayout.
        if surface != nil, layer != nil {
            lastAppliedLayout = (bounds.size, scale)
        }
    }

    // MARK: Input forwarding → libghostty encoder

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // E10 WI-9 HINT MODE: while a hint intent is armed (⌘⇧J open / ⌘⇧Y copy / reveal / copy-mode `f`),
        // every key drives label resolution (first letter dims, second confirms + runs the action; Esc
        // cancels; Backspace undoes) instead of the shell. Map the NSEvent → the abstract `HintKey` (the ONLY
        // NSEvent-aware point) and hand the PURE intent to the model; consume unconditionally so nothing leaks
        // to libghostty / the PTY. This branch MUST precede the copy-mode branch: hint mode can be armed ON TOP
        // of copy-mode (`f`, or a ⌘⇧J/⌘⇧Y chord while vi is up), and it is the topmost modal layer — checked
        // first, its label letters resolve and its Esc peels ONLY the hint layer (back to copy-mode); checked
        // second, copy-mode swallowed every label key and Esc tore down the WRONG (bottom) layer first. The
        // RELEASE-swallow stamp mirrors copy-mode's, so a kitty `report_events` TUI never sees an orphan CSI-u
        // release for a key the surface never sent a press for (the confirming second key exits hint mode
        // SYNCHRONOUSLY here, so its keyUp's `hintMode != nil` guard is already false).
        if model?.hintMode != nil {
            hintConsumedReleaseKeyCode = UInt16(event.keyCode)
            model?.handleHintKey(TerminalViewModel.makeHintKey(event: event))
            return
        }

        // P5b COPY-MODE: when this pane is armed, its keys drive scrollback navigation / search / copy /
        // exit instead of the shell. Map the NSEvent → the abstract key HERE (the only NSEvent-aware point)
        // and hand the PURE intent to the view model; consume unconditionally so nothing leaks to libghostty
        // / the PTY. All logic lives in `handleCopyModeKey` (compiled + tested under `swift build`).
        if model?.isCopyMode == true {
            // Stamp this keyCode so its RELEASE is swallowed even if the dispatch EXITS the mode (q/Esc/Enter
            // flip `isCopyMode` false synchronously here, so the matching keyUp's `isCopyMode == true` guard
            // would already be false and fall through to an orphan CSI-u release under a report_events TUI).
            copyModeConsumedReleaseKeyCode = UInt16(event.keyCode)
            model?.handleCopyModeKey(TerminalViewModel.makeCopyModeKey(event: event))
            return
        }

        // WS-B / B4·B5 — WORKSPACE KEYBINDING INTERCEPT (claimed BEFORE the Ctrl+C0 raw-byte branch below).
        // The app-level `WorkspaceKeyDispatcher` (B3) is the PRIMARY interceptor — its `.keyDown` monitor
        // fires before this responder — but when this focused libghostty surface handles the event in its own
        // `keyDown` (the monitor bypassed), this belt-and-suspenders pass keeps the rebindable workspace
        // chords working. ALL resolution lives in the pure, headless-tested `TerminalKeyInterceptor` (the
        // override-aware single-chord table); here we ONLY map the NSEvent → `KeyChord` and act on the
        // returned disposition. (The tmux-style prefix engine that once shared this pass is REMOVED —
        // DECISIONS.md 2026-07-22 — so ⌃B and every other bare/Ctrl key reaches the PTY untouched.)
        if let interceptor = model?.keyInterceptor,
           let chord = Self.workspaceChord(for: event)
        {
            switch interceptor.intercept(chord) {
            case .forward:
                break // not a workspace chord — fall through to the normal libghostty path below
            case .swallow:
                // Resolved: swallow the PRESS and remember to swallow its matching RELEASE,
                // so a kitty `report_events` TUI never sees an orphan CSI-u release for a key the surface
                // never sent a press for (the same symmetry the copy-mode / Ctrl+C0 branches enforce).
                workspaceConsumedReleaseKeyCode = UInt16(event.keyCode)
                return
            }
        }

        // CTRL+<key> → LEGACY C0 control byte (the universal-interrupt fix). The host shell (oh-my-zsh
        // / a plugin) enables the kitty keyboard protocol, which makes libghostty's encoder emit a
        // CSI-u ESCAPE for Ctrl-C/Z/D/… (e.g. `^[[3;5u`) instead of the raw control byte. A remote
        // FOREGROUND program that is NOT kitty-aware — a plain `sleep`/`cat`, or the shell between
        // prompts — never sees `0x03`, so Ctrl-C cannot interrupt it (HARDWARE-CONFIRMED broken). The
        // remote PTY is a SEPARATE process from this client terminal, so we cannot rely on the host
        // popping the protocol per-command. macOS already resolves Ctrl+<key> to its C0 control
        // character in `event.characters` (Ctrl-C → U+0003, Ctrl-[ → U+001B, Ctrl-Space → U+0000,
        // Ctrl-? → U+007F), so for a control-modified key that yields a single C0/DEL scalar we send
        // that raw byte directly — bypassing the kitty encoder — so interrupt/EOF/suspend + the C0
        // line-editing keys always reach the host. Plain + non-control keys still go through libghostty
        // unchanged (kitty stays available to the host for everything else). Cmd-combos are app
        // shortcuts and are NOT intercepted here.
        if event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.command),
           let chars = event.characters,
           chars.unicodeScalars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value < 0x20 || scalar.value == 0x7F {
            model?.sendInput(Data(chars.utf8))
            return
        }

        // WS-B / B5: the hard-coded cmd+D / cmd+⇧D split branch is GONE. libghostty's default keymap binds
        // those to new_split:right/down (dropped by the app action_cb), so the workspace must own them — but
        // string-matching `charactersIgnoringModifiers == "d"` here made the split UN-rebindable. The split
        // chords now flow through the `TerminalKeyInterceptor` above (its idle-single-chord path resolves
        // ⌘D/⌘⇧D against the override-aware `resolvedChordTable` and routes `.splitRight`/`.splitDown`), so a
        // user rebind takes effect and the live dispatcher owns the chord. Nothing to do here.

        // BACKSPACE-DELETES-SELECTION is GONE — setting, policy and this actuator. It was a 3-way
        // decision whose one interesting leg (`.deleteSelection`) could never fire a byte: the pinned
        // libghostty fork exposes no set-selection / cursor-geometry API, so `selectionEndsAtCursor` was
        // hard-coded `false`, `leadingDeleteCount` therefore always returned 0, and every leg fell through
        // to the same encoder path below. ON and OFF were indistinguishable by construction — a setting
        // that only wrote to disk. A plain Backspace deletes one character and (clear-on-typing) drops the
        // highlight, which is what it already did. Re-introduce the whole path together with the geometry
        // API, not before.

        // E8 WI-11 (I18): UNDO AT PROMPT. ⌘Z at an editable shell prompt emits the readline UNDO control byte
        // (Ctrl-_, 0x1F) so the remote shell's line editor rolls back the last prompt edit; ⌘⇧Z / ⌘Y (redo)
        // is a documented omit — there is no portable readline redo. The PURE, headless-tested
        // `PromptEditPolicy` makes the decision; this view only maps the NSEvent → the (undo, redo) intent and
        // sends the returned bytes. The prompt-zone gate is read LIVE from the model's public OSC-133 truth,
        // identical to the backspace block above: connected AND `shellActivity == .idle` (false while a TUI
        // owns the alternate screen → ⌘Z passes through to the program, which keeps its own undo). The setting
        // is read live off `Defaults` so a Settings toggle takes effect on the very next ⌘Z. We require ⌘ with
        // neither ⌃ nor ⌥ (those are other line-edit chords) and key off `charactersIgnoringModifiers` so the
        // chord is layout-aware. On a non-nil result we consume; otherwise (redo, or ⌘Z off the prompt) we
        // FALL THROUGH so the chord stays an app shortcut / program key.
        if SettingsKey.undoAtPromptEnabled,
           event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           let model,
           let baseChar = event.charactersIgnoringModifiers?.lowercased()
        {
            let hasShift = event.modifierFlags.contains(.shift)
            let isUndo = baseChar == "z" && !hasShift
            let isRedo = (baseChar == "z" && hasShift) || baseChar == "y"
            if isUndo || isRedo {
                let inPromptZone = model.connectionStatus.isLive
                    && model.shellActivity == .idle
                    && !model.isAlternateScreen
                if let bytes = PromptEditPolicy.bytes(forUndo: isUndo, redo: isRedo, inPromptZone: inPromptZone) {
                    model.sendInput(Data(bytes))
                    return
                }
                // redo (omitted) or ⌘Z off the prompt → fall through; no readline redo, no stray byte.
            }
        }

        // ── macos-option-as-alt TRANSLATION (upstream `SurfaceView_AppKit.keyDown`) ──
        // Ask libghostty which mods remain for CHARACTER translation on this surface: with
        // "Option as Alt" on (Settings → Controls → Keyboard), the claimed Option side is
        // REMOVED from the translation mods, so ⌥b re-translates to "b" (not "∫"), no ⌥-dead-key
        // composition starts, and the encoder — seeing Option NOT consumed — emits the Meta form
        // (ESC-prefix / CSI-u). Config off ⇒ identity ⇒ `translationEvent === event`, byte-identical
        // behaviour. Everything downstream (interpretKeyEvents, consumed mods, encoder text) uses
        // the TRANSLATION event; `mods`/keycode still come from the ORIGINAL event.
        let translationEvent = self.translationEvent(for: event)

        // ── IME / NSTextInputClient routing (upstream `SurfaceView_AppKit.keyDown`) ──
        // Every remaining key goes through the macOS INPUT CONTEXT FIRST so marked-text
        // composition (Vietnamese Telex, CJK conversion, ⌥-dead-keys) can begin/continue:
        // `interpretKeyEvents` drives our NSTextInputClient conformance (extension below) —
        // `setMarkedText` updates ghostty's preedit, `insertText` commits into
        // `keyTextAccumulator`, named keys land in the swallowed `doCommand`. The key EVENT
        // still reaches libghostty's encoder afterwards with the correct `composing` flag, so
        // kitty/DECCKM encoding stays ghostty-owned (DECISIONS: never hand-roll VT).
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Non-nil accumulator ⇔ "we are inside a keyDown" for insertText/setMarkedText.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Whether these events CLEARED an in-progress composition (needed for `composing` below).
        let markedTextBefore = markedText.length > 0

        // Some keystrokes are input-source SWITCHES (Kana/Eisu, the globe layout toggle) that
        // change the keyboard layout inside interpretKeyEvents; those must not ALSO type into
        // the terminal (upstream's keyboardIdBefore guard).
        let keyboardIdBefore: String? = markedTextBefore ? nil : Self.keyboardLayoutID

        // Inside a keyDown no performKeyEquivalent redispatch is pending (see doCommand);
        // interpretKeyEvents may fire doCommand and must not re-send the event into a loop.
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore && keyboardIdBefore != Self.keyboardLayoutID {
            return
        }

        // Publish/clear the preedit to libghostty (the composing underline at the cursor).
        // Order vs the key events below doesn't matter — preedit state flows ONLY through
        // this API (upstream syncPreedit).
        syncPreedit(clearIfNeeded: markedTextBefore)

        if let committed = keyTextAccumulator, !committed.isEmpty {
            // The input context COMMITTED text (insertText fired during interpretKeyEvents):
            // send the composed result. NEVER `composing` — this is composition OUTPUT
            // ("việt" after Telex `v i e e j t`, "é" after ⌥e e, a chosen CJK candidate).
            for text in committed {
                sendGhosttyKey(
                    action,
                    event: event,
                    translationMods: translationEvent.modifierFlags,
                    text: text,
                    composing: false,
                )
            }
        } else {
            // Nothing committed: a plain key, or a composition in flight. `composing` covers
            // BOTH marked-now and marked-before: a Backspace that only cancels/reshapes a
            // preedit must not ALSO encode a DEL to the PTY (upstream's Japanese-backspace
            // case — it clears the composing state, not the prior committed characters).
            // `KeyEventTextPolicy` (headless-tested) strips AppKit's function-key PUA
            // placeholders (arrows = U+F700… — upstream `ghosttyCharacters`) AND control-led
            // text (`\t`/`\r`/0x19): forwarding either makes ghostty's KITTY encoder emit the
            // wrong bytes — raw PUA garbage for arrows, or a modifier-stripped bare `\t`/`\r`
            // for Shift+Tab / Shift+Enter / ⌥Enter (`effectiveMods` subtracts consumed mods
            // whenever utf8 is non-empty). Text reads off the TRANSLATION event so an
            // option-as-alt ⌥b hands the encoder "b", not "∫".
            sendGhosttyKey(
                action,
                event: event,
                translationMods: translationEvent.modifierFlags,
                text: KeyEventTextPolicy.encoderText(for: translationEvent.characters),
                composing: markedText.length > 0 || markedTextBefore,
            )
        }
    }

    /// The event whose modifiers/characters drive INPUT-CONTEXT interpretation and encoder text —
    /// the original event with the option-as-alt-claimed Option side(s) stripped and its characters
    /// re-translated without them (upstream `SurfaceView_AppKit.keyDown`'s translation event).
    /// Identity (`=== event`) when nothing is stripped — REQUIRED, not an optimisation: AppKit's
    /// input-method machinery (Korean IME) relies on receiving the SAME object it was handed.
    private func translationEvent(for event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let translated = Self.eventModifierFlags(
            surface.keyTranslationMods(Self.ghosttyMods(event.modifierFlags)))
        // The raw event flags carry hidden device-dependent bits that matter for dead keys, so
        // never adopt the round-tripped set wholesale — copy only the four mod STATES onto the
        // original flags (upstream's exact-state loop).
        var mods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { mods.insert(flag) } else { mods.remove(flag) }
        }
        guard mods != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: mods,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: mods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode,
        ) ?? event
    }

    /// The ONE funnel into libghostty's key encoder (DECISIONS: never hand-roll VT).
    /// ghostty_input_key_s (header 322): action / mods / keycode / text /
    /// unshifted_codepoint / composing.
    private func sendGhosttyKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil,
        text: String?,
        composing: Bool,
    ) {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = Self.ghosttyMods(event.modifierFlags)
        // consumed_mods: the mods AppKit already "used up" producing the text. Upstream
        // (`ghosttyKeyEvent(_:translationMods:)`) reports the TRANSLATION mods minus control/command —
        // those never alter the produced character on a US/Latin layout, so libghostty must still see
        // them to encode Ctrl-/Cmd- combos. This stops Ghostty from double-applying Shift/Option (a
        // shifted `!` being re-shifted) in its encoder. `translationMods` (keyDown's option-as-alt
        // dance) has the claimed Option side already STRIPPED, so with "Option as Alt" on, Option is
        // NOT consumed and the encoder emits the Meta form; `nil` (keyUp) falls back to the event mods.
        key.consumed_mods = Self.ghosttyMods(
            (translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        key.keycode = UInt32(event.keyCode)
        // unshifted_codepoint: the character the key would produce with NO modifiers (header field).
        // `charactersIgnoringModifiers` STILL reflects Shift (it ignores Cmd/Ctrl/Opt but not Shift),
        // so a shifted `2` reported `@` here — wrong. `characters(byApplyingModifiers: [])` strips ALL
        // modifiers including Shift, giving the true base codepoint Ghostty keys its bindings on.
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first.map { $0.value } ?? 0
        key.composing = composing
        // `text` is a borrowed const char* for the keypress duration; bind the chars.
        if let text, !text.isEmpty {
            let copy = text
            copy.withCString { cstr in
                key.text = cstr
                _ = surface?.key(key)
            }
        } else {
            key.text = nil
            _ = surface?.key(key)
        }
    }

    /// Mirrors upstream `syncPreedit`: publish the marked text to libghostty as the PREEDIT
    /// (rendered at the cursor with the composing underline), or clear a finished one.
    /// `clearIfNeeded` is false only on the non-keyDown `setMarkedText` path, where an empty
    /// marked string never follows a live preedit.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        if markedText.length > 0 {
            surface?.preedit(markedText.string)
        } else if clearIfNeeded {
            surface?.preedit(nil)
        }
    }

    /// The current keyboard input source ID (upstream `Helpers/KeyboardLayout.swift` — Carbon
    /// TIS, already linked for libghostty). Used to detect that a keystroke was an
    /// input-source SWITCH inside interpretKeyEvents (see keyDown).
    private static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return unsafeBitCast(idPointer, to: CFString.self) as String
    }

    override func keyUp(with event: NSEvent) {
        // P5b COPY-MODE symmetry: keyDown CONSUMES every key while armed (routing it to copy-mode dispatch),
        // so libghostty never saw the PRESS — suppress the RELEASE too, or a kitty-`report_events` TUI would
        // emit an orphan CSI-u release after exit. Mirror the keyDown guard.
        if model?.isCopyMode == true { return }
        // …and the ONE exit key whose press copy-mode consumed but whose mode flag is now already cleared (q/Esc/
        // Enter exited synchronously in keyDown, so the guard above is false for THIS release). Swallow it once.
        if let pending = copyModeConsumedReleaseKeyCode, pending == UInt16(event.keyCode) {
            copyModeConsumedReleaseKeyCode = nil
            return
        }

        // E10 WI-9 HINT MODE symmetry: keyDown CONSUMES every key while a hint intent is armed (routing it to
        // `handleHintKey` — checked BEFORE copy-mode there; either armed-guard returning here keeps the same
        // suppression), so libghostty never saw the PRESS — suppress the RELEASE too. Mirror the keyDown
        // guard, plus the ONE exit key whose press hint mode consumed but whose mode flag is now already cleared
        // (the confirming second key / Esc exited synchronously in keyDown). Swallow it once.
        if model?.hintMode != nil { return }
        if let pending = hintConsumedReleaseKeyCode, pending == UInt16(event.keyCode) {
            hintConsumedReleaseKeyCode = nil
            return
        }

        // WS-B / B4 PRESS/RELEASE SYMMETRY: keyDown swallowed this key's PRESS via the workspace interceptor
        // (a resolved chord), so libghostty never saw it — suppress the
        // matching RELEASE once, or a kitty `report_events` TUI emits an orphan CSI-u release. Mirrors the
        // copy-mode pending-release guard above.
        if let pending = workspaceConsumedReleaseKeyCode, pending == UInt16(event.keyCode) {
            workspaceConsumedReleaseKeyCode = nil
            return
        }

        // PRESS/RELEASE SYMMETRY (R5 rank 7): keyDown SUPPRESSES the libghostty PRESS for a
        // Ctrl+<single C0/DEL> key (it sends the raw control byte directly, bypassing the kitty encoder),
        // so the surface never saw that PRESS. Its RELEASE must be suppressed symmetrically — otherwise,
        // when a remote TUI negotiates the kitty `report_events` progressive-enhancement flag, libghostty
        // would encode an ORPHAN CSI-u release sequence (a release with no matching press) and inject
        // stray bytes right after the intended Ctrl-C/Z/D byte. Mirror the exact keyDown Ctrl guard.
        if event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.command),
           let chars = event.characters,
           chars.unicodeScalars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value < 0x20 || scalar.value == 0x7F {
            return
        }

        // Same consumed-mods / unshifted-codepoint correctness as keyDown (see sendGhosttyKey);
        // a release carries no text and is never composing (upstream keyUp → bare keyAction).
        sendGhosttyKey(GHOSTTY_ACTION_RELEASE, event: event, text: nil, composing: false)
    }

    // MARK: Link highlight (E10 WI-5 — ⌘-hold underline + full-path hover)

    /// Track the ⌘ modifier so the ``LinkHighlightOverlay`` underlines every detected path/URL while ⌘ is held
    /// (ES-E10-1) and the ⌘-hovered link's full path is resolved into the now-dormant `hoveredLinkFullPath`
    /// seam (ES-E10-4 — its status-bar preview was removed). Releasing ⌘ clears both. macOS only — iOS has no
    /// ⌘ modifier, so `linkHighlightActive` is never set there and the
    /// overlay stays inert. Setting the OBSERVABLE model state from this NSEvent handler is safe — an
    /// AppKit event callback is not inside anyone's view-update pass, so it cannot trigger the
    /// infinite-render loop `surface` documents.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let model else { return }
        // ⌘ with ⌃ or ⌥ added is a CHORD in flight (⌃⌘[ / ⌃⌘] prompt-jump, ⌥⌘ workspace verbs), not a
        // link-reveal hold — underlining through those reads as the app changing modes mid-shortcut
        // (the reported bug: prompt-jumping with ⌘ still down kept every path underlined). ⇧ stays
        // allowed: ⌘⇧-click is a first-class link gesture (`linkCmdShiftClick`). Adding ⌃/⌥ mid-hold
        // clears the highlight; releasing them with ⌘ still down re-fires this handler and restores it.
        let commandHeld = event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.control)
            && !event.modifierFlags.contains(.option)
        if model.linkHighlightActive != commandHeld {
            model.linkHighlightActive = commandHeld
            // ⌘ just went down → drop the link-snapshot cache: `viewportRevision` only ticks while the
            // highlight is active, so a viewport move BETWEEN holds (copy-mode nav, jump-to-prompt) can
            // leave the generation keys matching a moved viewport. Each hold starts from a fresh read.
            // Only on the TRANSITION — a mid-hold ⇧ press (⌘⇧-click) must not evict a valid cache.
            if commandHeld { linkSnapshot.invalidate() }
        }
        if commandHeld {
            // ⌘ went down with a (possibly) stationary pointer: resolve the hover from the CURRENT location so
            // the full-path preview appears immediately, without waiting for the next pointer move.
            if let point = currentSurfacePoint() { updateLinkHover(at: point) }
        } else {
            clearLinkHover()
        }
    }

    /// E10 WI-5 (ES-E10-4): the ⌘-hover full-path preview. While ⌘ is held (`linkHighlightActive`), link
    /// detection is on, and the surface is NOT a mouse-reporting TUI (alt screen — don't fight vim/tmux/htop),
    /// hit-test the detected links in the VISIBLE viewport against the pointer cell and publish the resolved
    /// path to the now-dormant ``TerminalViewModel/hoveredLinkFullPath`` seam (its status-bar consumer was
    /// removed). A move off any link, a released ⌘, or a pointer-exit clears it.
    ///
    /// AUDIT FIX `cmd-hover-full-viewport-reread-per-mousemove`: routes through ``detectedLink(at:)`` — the
    /// SAME gates and the same pure, headless-tested ``TerminalLinkHitTest`` as the ⌘-click path, the
    /// right-click menu and the phone's long press, so the per-move cost against an unchanged viewport is
    /// ONLY the cell arithmetic over the cached ``GhosttyLinkSnapshot``, not a full `viewportTextRows()`
    /// re-read + re-detection per mouseMoved. The `resolvedAbsolute ?? raw` below is this seam's own reading
    /// of the link — it used to be a second FUNCTION returning a path, which is what made the hit-test two
    /// implementations. `point` is in the surface's top-left-origin POINT space (the
    /// `surfacePoint`/`cellMetrics` convention).
    private func updateLinkHover(at point: (x: Double, y: Double)) {
        guard let model else { return }
        guard model.linkHighlightActive else {
            clearLinkHover()
            return
        }
        // detectedLink(at:) applies the detection-toggle / alt-screen / metrics gates; any gate failing
        // yields nil, which clears the preview exactly like the old explicit guard did.
        let link = detectedLink(at: point)
        let path = link.map { $0.resolvedAbsolute ?? $0.raw }
        if model.hoveredLinkFullPath != path { model.hoveredLinkFullPath = path }
        setLinkHoverCursor(link != nil)
    }

    /// Drop BOTH ⌘-hover affordances — the resolved path seam and the pointing-hand cursor. The two are
    /// cleared together everywhere, so they cannot drift into "hand cursor over nothing".
    private func clearLinkHover() {
        if model?.hoveredLinkFullPath != nil { model?.hoveredLinkFullPath = nil }
        setLinkHoverCursor(false)
    }

    /// `true` while the pointer sits on a ⌘-hoverable link, which is what makes the pane show the
    /// POINTING HAND. Kept beside ``pointerCursor`` rather than folded into it: that one is a remote
    /// program's OSC-22 request and has to survive a hover unchanged, so the hand is a transient
    /// OVERRIDE the pane falls back off, not a new base shape.
    private var linkHoverActive = false

    /// Show / hide the pointing hand for a ⌘-hovered link.
    ///
    /// This used to be libghostty's job — its built-in regex link matcher asked for the pointer shape as
    /// part of highlighting the match. `link-url = false` retired that matcher (it was drawing a SECOND
    /// underline under the one ``LinkHighlightOverlay`` paints), and the cursor change left with it —
    /// user-reported 2026-08-09. It belongs here now for the same reason the underline and the ⌘click
    /// already do: SlopDesk owns link detection end to end, so it owns the whole affordance.
    ///
    /// Both halves are needed. The cursor RECT is what AppKit consults as the pointer keeps moving inside
    /// the pane; the immediate `.set()` is what updates a pointer that is STATIONARY, which is the common
    /// case here — ⌘ is usually pressed while already resting on the path.
    private func setLinkHoverCursor(_ active: Bool) {
        guard linkHoverActive != active else { return }
        linkHoverActive = active
        window?.invalidateCursorRects(for: self)
        (active ? NSCursor.pointingHand : pointerCursor).set()
    }

    /// The pointer's CURRENT position in the surface's top-left-origin POINT space, or `nil` when it is outside
    /// this view / off-window. Used by ``flagsChanged`` to resolve a ⌘-hover without waiting for a pointer move.
    /// Mirrors ``surfacePoint(_:)``'s y-flip (`frame.height - y`).
    private func currentSurfacePoint() -> (x: Double, y: Double)? {
        guard let window else { return nil }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else { return nil }
        return (Double(local.x), Double(frame.height - local.y))
    }

    // MARK: Link click + context menu dispatch (E10 WI-6 — ES-E10-2)

    /// A pending link click captured on `mouseDown` (the swallowed press) so the paired `mouseUp` can fire
    /// the resolved action — but only if the release ends on the SAME link. One-shot; cleared on every up.
    private var pendingLinkGesture: (link: DetectedLink, gesture: LinkGesture)?

    /// The detected link the LAST-built context menu targeted, stashed so ``linkMenuAction(_:)`` can resolve
    /// it (an `NSMenuItem.representedObject` carries only the item tag). A menu is modal-per-view, so one slot
    /// suffices.
    private var pendingMenuLink: DetectedLink?

    /// The link gesture for `flags`, or `nil` when this is not a link-owning click — link detection is off,
    /// the surface is a mouse-reporting TUI (alt screen — don't fight vim/tmux), or ⌘ is not held (a bare
    /// click does nothing, so we leave it to libghostty's selection).
    private func linkGesture(for flags: NSEvent.ModifierFlags) -> LinkGesture? {
        guard SettingsKey.linkDetectionEnabled, model?.isAlternateScreen == false else { return nil }
        guard flags.contains(.command) else { return nil }
        return flags.contains(.shift) ? .commandShiftClick : .commandClick
    }

    /// AUDIT FIX `cmd-hover-full-viewport-reread-per-mousemove`: the (viewport rows → detected links)
    /// snapshot every ⌘-hover / ⌘-click / menu hit-test reads, and the hit-test itself. Both are
    /// ``GhosttyLinkSnapshot`` now — outside the platform gate, because the phone's long-press menu asks
    /// the same question. Dropped outright by `scrollWheel` (a non-⌘ scroll bumps NO revision), by each
    /// ⌘-down (`flagsChanged` — a fresh hold starts from a fresh read), and by `detach()`.
    private var linkSnapshot = GhosttyLinkSnapshot()

    /// The ``DetectedLink`` under a top-left-origin surface POINT (points), or `nil` when the point is over
    /// no detected span / detection is off / there is no live surface. No `slop`: a pointer lands where it
    /// is aimed, so this half keeps the exact cell reading (the phone's half does not — see
    /// ``TerminalTouchSelection/linkHitSlop``).
    private func detectedLink(at point: (x: Double, y: Double)) -> DetectedLink? {
        linkSnapshot.link(at: point, model: model, surface: surface)
    }

    /// The live link config the policy reads (`link-cmd-click` / `link-cmd-shift-click`), resolved
    /// fire-time from Settings so a change applies to the next click with no re-wire.
    private func liveLinkConfig() -> LinkActionConfig {
        LinkActionConfig(cmdClick: SettingsKey.linkCmdClick, cmdShiftClick: SettingsKey.linkCmdShiftClick)
    }

    /// Dispatches a path/URL context-menu item (tagged by ``TerminalContextMenu/LinkItem`` rawValue) for the
    /// menu's stashed ``pendingMenuLink``, routing through the same pure ``LinkActionPolicy``. Unknown tags /
    /// a missing link are ignored (validate-then-drop).
    @objc private func linkMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let item = TerminalContextMenu.LinkItem(rawValue: raw),
              let link = pendingMenuLink else { return }
        LinkActionActuator.actuate(LinkActionPolicy.action(for: item, link: link), model: model)
    }

    // MARK: Mouse / scroll forwarding → libghostty
    //
    // Mirrors upstream `SurfaceView_AppKit.swift:860-1051`. libghostty owns ALL mouse semantics:
    // X10/1000/1002/1003 + SGR mouse-reporting (so a remote `vim`/`tmux`/`htop` gets click+drag+
    // hover+scroll), local TEXT SELECTION when the program is NOT reporting, and the position cursor.
    // We just translate each AppKit event into the C call with the right state/button/mods and the
    // flipped view-local POINT coordinate (libghostty applies contentScale itself — points, not pixels).

    /// View-local position of an event in POINTS, y-flipped so origin is top-left (this view is the
    /// default non-flipped AppKit coordinate space, so we mirror upstream's `frame.height - pos.y`).
    private func surfacePoint(_ event: NSEvent) -> (x: Double, y: Double) {
        let pos = convert(event.locationInWindow, from: nil)
        return (Double(pos.x), Double(frame.height - pos.y))
    }

    /// Pressure stage tracked across events so `mouseUp` can reset it to 0 (upstream `prevPressureStage`).
    private var prevPressureStage: Int = 0

    override func mouseDown(with event: NSEvent) {
        // FOCUS-ON-CLICK: claim the pane BEFORE forwarding to the surface. Installing `mouseDown`
        // CONSUMES the click that `PaneTreeView`'s `.onTapGesture { store.focus(id) }` used to see,
        // so we must reproduce that focus transfer here — both the workspace focus (chrome/keyboard
        // follow when the canvas pushes `setPaneFocused` back down) AND the immediate first
        // responder so typing works without waiting for that round trip. `applyKeyboardFocus`/this guard
        // are idempotent, so this does not fight the existing `isFocused` path (no double-focus).
        model?.onRequestFocus?()
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }

        // E10 WI-6 (ES-E10-2): a ⌘click / ⌘⇧click that lands ON a detected path/URL is OURS — swallow the
        // press so libghostty starts no selection, and fire the resolved action on the paired `mouseUp`
        // (only when the release ends on the SAME link, so a ⌘-drag-away cancels). A ⌘click that is NOT
        // over a detected link falls straight through to libghostty (e.g. its ⌘ rectangular-select). OSC 8
        // hyperlinks stay libghostty's own (GHOSTTY_ACTION_OPEN_URL) — this is only the regex detector path.
        if let gesture = linkGesture(for: event.modifierFlags),
           let link = detectedLink(at: surfacePoint(event)) {
            pendingLinkGesture = (link, gesture)
            return
        }
        pendingLinkGesture = nil

        let mods = Self.ghosttyMods(event.modifierFlags)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: mods)
    }

    override func mouseUp(with event: NSEvent) {
        // Always reset pressure when the mouse goes up (upstream SurfaceView_AppKit.swift:875/883).
        prevPressureStage = 0
        // E10 WI-6: complete a swallowed link ⌘click. The matching PRESS was never forwarded, so we must NOT
        // forward this RELEASE either (press/release stay balanced under mouse-reporting). Fire only when the
        // pointer is still over the SAME detected link (a genuine click, not a drag that wandered off).
        if let pending = pendingLinkGesture {
            pendingLinkGesture = nil
            if let up = detectedLink(at: surfacePoint(event)), up == pending.link {
                LinkActionActuator.actuate(
                    LinkActionPolicy.action(for: pending.gesture, link: pending.link, config: liveLinkConfig()),
                    model: model,
                )
            }
            return
        }
        let mods = Self.ghosttyMods(event.modifierFlags)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: mods)
        surface?.sendMousePressure(stage: 0, pressure: 0)
    }

    override func otherMouseDown(with event: NSEvent) {
        let mods = Self.ghosttyMods(event.modifierFlags)
        // AUDIT FIX `rightclick-paste-protection-hole`: a MIDDLE-click (button 2) pastes the SELECTION clipboard
        // via libghostty, which bypasses the broad paste-protection gate exactly like the right-click path.
        // When the pointer is NOT captured by a mouse-reporting program, intercept and route the selection
        // content through the SAME pre-check (`requestPasteFromSelection`). A CAPTURED middle-click (a TUI's own
        // mouse mode) belongs to the program — forward it untouched.
        if event.buttonNumber == 2, surface?.mouseCaptured == false {
            // PRESS consumed locally → withhold the paired RELEASE forward too (press/release balance).
            suppressedMiddleButtonPress = true
            requestPasteFromSelection()
            return
        }
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: Self.mouseButton(event.buttonNumber), mods: mods)
    }

    override func otherMouseUp(with event: NSEvent) {
        // If the matching middle PRESS was handled locally (the paste-protection interception) it was never
        // forwarded, so do NOT forward this RELEASE either — an unpaired middle release would inject a stray
        // report into a mouse-reporting TUI. Consume the one-shot flag.
        if event.buttonNumber == 2, suppressedMiddleButtonPress {
            suppressedMiddleButtonPress = false
            return
        }
        let mods = Self.ghosttyMods(event.modifierFlags)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: Self.mouseButton(event.buttonNumber), mods: mods)
    }

    /// Set when a `rightMouseDown` was handled LOCALLY (the ⌃-right context-menu override) and so was NOT
    /// forwarded to libghostty as a right-button PRESS. The matching `rightMouseUp` then suppresses the
    /// right-button RELEASE forward too, so under mouse-reporting (capture) a TUI never sees an UNPAIRED
    /// release report (the press it would pair with was swallowed locally). One-shot: consumed on the next
    /// `rightMouseUp`.
    private var suppressedRightButtonPress = false

    /// Set when a middle-button `otherMouseDown` was handled LOCALLY (the audit-fix paste-protection
    /// interception) and so was NOT forwarded to libghostty as a middle-button PRESS. The matching
    /// `otherMouseUp` then suppresses the middle-button RELEASE forward too, so a mouse-reporting TUI never
    /// sees an UNPAIRED release. One-shot: consumed on the next middle `otherMouseUp`.
    private var suppressedMiddleButtonPress = false

    override func rightMouseDown(with event: NSEvent) {
        let mods = Self.ghosttyMods(event.modifierFlags)

        // E8 WI-7 (H8): the ⌃-right-always-menu override. ⌃+right-click ALWAYS shows the native context
        // menu, regardless of the configured Right-Click Action. libghostty now OWNS the bare-right-click
        // dispatch (WI-2 emits `right-click-action`) but does NOT special-case the ⌃ modifier, so we must
        // intercept ⌃+right HERE — BEFORE forwarding the press — otherwise a `copy`/`paste`/… config would
        // FIRE on ⌃+right (and then the menu would also show). Defer straight to AppKit's `menu(for:)` path;
        // the menu's Copy enables on the genuine pre-click selection (never a word-select we injected).
        if event.modifierFlags.contains(.control) {
            // The PRESS is swallowed locally (never forwarded). Record it so the paired `rightMouseUp` also
            // withholds the RELEASE forward — otherwise a mouse-reporting TUI receives an UNPAIRED right-button
            // release report (press/release must stay balanced under capture).
            suppressedRightButtonPress = true
            super.rightMouseDown(with: event)
            return
        }

        // E8 WI-7 (H7): a BARE right-click is owned END-TO-END by libghostty via the `right-click-action`
        // config line (Context Menu / Copy / Paste / Copy or Paste / Ignore, set from the LIVE Settings by
        // WI-2). `sendMouseButton` returns true when the surface CONSUMED the press — either a mouse-reporting
        // program (vim/tmux/htop) turned it into an SGR report, OR libghostty performed the configured action
        // (copy/paste/copy-or-paste/ignore all consume). The ONE action that does NOT consume is Context Menu:
        // libghostty word-selects under the cursor and returns false so the apprt shows its menu — so on a
        // false return we fall through to AppKit's native `menu(for:)`.
        //
        // This deletes the old client-side effect switch (which read `hasSelection()` AFTER libghostty had
        // already word-selected at the click point, so Copy-or-Paste always saw a selection → always copied,
        // and Ignore/Paste left a stray highlight — the WI-7 right-click-action review finding).
        //
        // AUDIT FIX `rightclick-paste-protection-hole`: if the configured action resolves to a PASTE, intercept
        // it HERE (before forwarding) and route through `requestPaste()` so it runs the full four-danger
        // pre-check — libghostty's own `confirm_read_clipboard_cb` backstop only trips for a `\n` / bracketed-end
        // payload, so a single-line `sudo`, an ESC-laced control-char paste, or a bare-`\r` paste would otherwise
        // reach the shell with NO protection sheet. The PURE ``RightClickPasteInterceptPolicy`` gates on
        // `mouseCaptured` so a mouse-reporting TUI keeps its right-click (we never steal the program's input).
        if RightClickPasteInterceptPolicy.interceptsAsPaste(
            action: SettingsKey.rightClickAction,
            hasSelection: surface?.hasSelection() ?? false,
            mouseCaptured: surface?.mouseCaptured ?? false,
        ) {
            // The PRESS is consumed locally (never forwarded). Record it so the paired `rightMouseUp` withholds
            // the RELEASE forward too — press/release must stay balanced under mouse-reporting capture.
            suppressedRightButtonPress = true
            requestPaste()
            return
        }

        // A right-click Copy / Context-Menu / Ignore stays owned END-TO-END by libghostty. `sendMouseButton`
        // returns true when the surface CONSUMED the press (a mouse-reporting program turned it into an SGR
        // report, OR libghostty performed Copy/Ignore which consume); Context Menu returns false → fall through
        // to AppKit's native `menu(for:)`.
        if surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, mods: mods) == true { return }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        // If the matching PRESS was handled locally (⌃-right context-menu override) it was never forwarded to
        // libghostty, so do NOT forward this RELEASE either — forwarding it would inject an UNPAIRED
        // right-button release report into a mouse-reporting (capture) TUI. Defer to AppKit and consume the flag.
        if suppressedRightButtonPress {
            suppressedRightButtonPress = false
            super.rightMouseUp(with: event)
            return
        }
        let mods = Self.ghosttyMods(event.modifierFlags)
        if surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT, mods: mods) == true { return }
        super.rightMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        // The tracking area is rect-based and fires under a modal overlay card — while one is up,
        // pointer traffic must not reach the TUI (or steal focus) through the card. See
        // `TerminalPointerShield`; the drag variants funnel here, so they are shielded too.
        if TerminalPointerShield.isActive() { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let p = surfacePoint(event)
        surface?.sendMousePos(x: p.x, y: p.y, mods: mods)
        // E8 WI-8 (H6): a move WITHIN a still-unfocused pane (e.g. focus was taken by a keyboard nav while the
        // pointer sat here) also claims focus. The policy's `!isFocusedPane` short-circuit keeps this a cheap
        // no-op once focused, so the per-move call can't flicker the title bar.
        requestFocusFollowsMouseIfNeeded()
        // E10 WI-5 (ES-E10-4): refresh the ⌘-hover full-path preview (a no-op unless ⌘ is held — it gates on
        // `linkHighlightActive` internally, so a non-⌘ move costs one bool check).
        updateLinkHover(at: p)
    }

    // A drag is just a moved position to libghostty (it tracks the held button from the down/up pair);
    // upstream routes every *Dragged variant straight to mouseMoved (SurfaceView_AppKit.swift:998-1008).
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Shielded like `mouseMoved` — an enter under a modal card is not a hover on this pane.
        if TerminalPointerShield.isActive() { return }
        // Reset the cursor position on enter — lots of mouse-report logic depends on the position being
        // inside the viewport (upstream SurfaceView_AppKit.swift:936-952).
        let mods = Self.ghosttyMods(event.modifierFlags)
        let p = surfacePoint(event)
        surface?.sendMousePos(x: p.x, y: p.y, mods: mods)
        // E8 WI-8 (H6): crossing INTO an unfocused pane grabs the workspace focus when focus-follows-mouse
        // is on (the cross-pane relay libghostty's own key can't do — see `requestFocusFollowsMouseIfNeeded`).
        requestFocusFollowsMouseIfNeeded()
    }

    /// E8 WI-8 (H6, ES-E8-6): MOUSE-OVER-TO-FOCUS. When `focus-follows-mouse` (`focusFollowsMouse`) is
    /// on, hovering a pane focuses it — but ONLY across slopdesk's OWN panes: libghostty's native
    /// `focus-follows-mouse` only relays focus inside ghostty's internal split tree, and each slopdesk pane
    /// is a SEPARATE `GhosttySurface` the canvas tiles itself, so this cross-pane focus relay must be ours.
    ///
    /// The PURE, headless-tested ``FocusFollowsMousePolicy/shouldRequestFocus(focusFollowsMouse:isAlreadyFocused:)``
    /// makes the decision; this view is the thin actuator. The setting is read LIVE off `Defaults` (via
    /// ``SettingsKey/focusFollowsMouseEnabled``) so a Settings toggle takes effect on the very next hover — the
    /// same live-read idiom WI-7's `rightMouseDown` uses for `RightClickAction`.
    ///
    /// The `!isFocusedPane` short-circuit inside the policy is load-bearing: `mouseMoved` fires on EVERY pointer
    /// motion, so without it an already-focused pane would re-fire `onRequestFocus` on every move, thrashing the
    /// workspace focus and redrawing the title bar (the flicker the plan warns about). `onRequestFocus` is the
    /// SAME callback `mouseDown` uses, and the focus transfer is idempotent, so the two paths never fight.
    private func requestFocusFollowsMouseIfNeeded() {
        guard FocusFollowsMousePolicy.shouldRequestFocus(
            focusFollowsMouse: SettingsKey.focusFollowsMouseEnabled,
            isAlreadyFocused: isFocusedPane,
        ) else { return }
        model?.onRequestFocus?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // If a button is held the drag still delivers positions even past the edge, so don't send the
        // "left viewport" marker (upstream SurfaceView_AppKit.swift:955-972).
        if NSEvent.pressedMouseButtons != 0 { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        surface?.sendMousePos(x: -1, y: -1, mods: mods)   // negative = cursor left the viewport
        // E10 WI-5 (ES-E10-4): the pointer left the surface — drop any ⌘-hover full-path preview so the status
        // bar falls back to the resting cwd, and with it the pointing hand (the underline overlay stays until
        // ⌘ is actually released, because it marks every link in the viewport, not the hovered one).
        clearLinkHover()
    }

    override func scrollWheel(with event: NSEvent) {
        // Scroll follows the POINTER, not focus: a scroll on a NON-focused terminal scrolls ITS OWN
        // scrollback, so a background pane's output can be read/compared while focus (and typing)
        // stays in the working pane. ⌥-scroll is the deliberate canvas-pan route instead — same ⌥
        // escape hatch as the GUI pane, same natural-scroll sign as the background pan. The leaf
        // wires `onCanvasScroll` to the store camera pan; if it's not wired (headless/preview) the
        // ⌥ pan is simply dropped rather than mis-routed.
        if event.modifierFlags.contains(.option) {
            let dx: CGFloat, dy: CGFloat
            if event.hasPreciseScrollingDeltas { dx = event.scrollingDeltaX; dy = event.scrollingDeltaY }
            else { dx = event.scrollingDeltaX * 10; dy = event.scrollingDeltaY * 10 }
            model?.onCanvasScroll?(CGSize(width: -dx, height: -dy))
            return
        }
        // Build the packed scroll mods (Int32: bit0 = precision, bits1-3 = momentum), mirroring
        // upstream `Ghostty.Input.swift:438-465` (ScrollMods) + `SurfaceView_AppKit.swift:1010-1031`.
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // 2x feels right for trackpad/Magic-Mouse precision deltas (upstream's subjective tuning).
            x *= 2
            y *= 2
        }
        var packed: Int32 = 0
        if precision { packed |= 0b0000_0001 }                                   // bit0 = precision
        packed |= Int32(Self.scrollMomentum(event.momentumPhase)) << 1           // bits1-3 = momentum
        surface?.sendMouseScroll(deltaX: Double(x), deltaY: Double(y), mods: packed)
        // E10 WI-5: a LOCAL scrollback scroll moves the viewport with NO new wire bytes, so nudge the
        // observable viewport tick the ⌘-hold ``LinkHighlightOverlay`` depends on — else its underlines
        // would cling to pre-scroll screen rows over unrelated text until new output / ⌘ re-press.
        if model?.linkHighlightActive == true { model?.noteViewportScrolled() }
        // …and drop the link-snapshot cache UNCONDITIONALLY: a non-⌘ scroll bumps no generation key, so a
        // later ⌘-click / right-click-menu hit-test would otherwise resolve against the pre-scroll rows.
        linkSnapshot.invalidate()

        // The delta above is handed straight to libghostty, which OWNS the viewport: on the primary screen it
        // navigates scrollback (auto-snapping to the bottom on new output / typing, native), and in an
        // alt-screen mouse-mode TUI it is encoded as a mouse-scroll report — both handled internally.
        // `mouse-scroll-multiplier` rides the config passthrough, so the one knob that CAN reach the
        // viewport does.
        //
        // The Smooth-Scroll and Scroll-Past-First/Last SETTINGS are gone (2026-07-30). They were shipped
        // ahead of their renderer: the fork exposes no row-snap hook and no overscroll-margin API, so
        // `smoothScroll` OFF rendered exactly like ON and the scroll-past anchors (`ScrollPastPolicy`, now
        // deleted with them) computed a float nothing could draw. Add the settings back with the viewport
        // hook that actuates them, not before.
    }

    override func pressureChange(with event: NSEvent) {
        // Let Ghostty set up its pressure state first (upstream SurfaceView_AppKit.swift:1033-1039). We
        // do NOT implement force-click QuickLook (no remote selection lookup) — just forward the stage.
        surface?.sendMousePressure(stage: UInt32(event.stage), pressure: Double(event.pressure))
        prevPressureStage = event.stage
    }

    /// NSEvent.buttonNumber → libghostty mouse button (header 64-77). 0/1/2 = left/right/middle (handled
    /// by their dedicated overrides); 2+ here are the extra buttons. Mirrors the relevant cases of
    /// upstream `MouseButton(fromNSEventButtonNumber:)` (Ghostty.Input.swift:401-415).
    private static func mouseButton(_ buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_EIGHT   // back
        case 4: return GHOSTTY_MOUSE_NINE    // forward
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_FOUR
        case 8: return GHOSTTY_MOUSE_FIVE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    /// NSEvent.Phase momentum → the libghostty Momentum int (none=0…mayBegin=6), packed by
    /// `scrollWheel`. Mirrors `Ghostty.Input.Momentum(_ momentum: NSEvent.Phase)` and the enum at
    /// `Ghostty.Input.swift:481-489`.
    private static func scrollMomentum(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began:      return 1
        case .stationary: return 2
        case .changed:    return 3
        case .ended:      return 4
        case .cancelled:  return 5
        case .mayBegin:   return 6
        default:          return 0   // .none / unhandled
        }
    }

    // MARK: Tracking area (hover / motion reporting)

    /// Reinstall a tracking area covering the whole visible view so `mouseMoved`/`mouseEntered`/
    /// `mouseExited` fire — required for mouse-motion reporting (mode 1003) and libghostty hover.
    /// `.inVisibleRect` keeps it sized to bounds automatically; `.activeInKeyWindow` matches a
    /// terminal that only tracks while focused. Mirrors upstream's tracking-area setup.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,   // ignored with .inVisibleRect — AppKit keeps it pinned to the visible bounds
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    // MARK: OSC-22 pointer shape (E8 WI-9 / H14)

    /// The cursor a remote program last requested for THIS pane via OSC-22 (`GHOSTTY_ACTION_MOUSE_SHAPE`),
    /// resolved by the headless ``PointerShapeMapping``. Starts as — and is reset to — `.arrow`. AppKit asks
    /// for it back through ``resetCursorRects()``; ``applyPointerShape(rawShape:)`` updates it live.
    private var pointerCursor: NSCursor = .arrow

    /// AppKit invalidates and re-asks for a view's cursor regions on resize / key-window changes / our own
    /// ``NSWindow/invalidateCursorRects(for:)``. We claim the whole bounds for the libghostty-requested shape
    /// so a remote program's OSC-22 pointer change actually shows under the pointer as it moves over the pane.
    /// A ⌘-hovered link OUTRANKS the OSC-22 shape for the duration of the hover — link detection is gated
    /// off the alt screen, so the program that asked for a shape is not the one being pointed at.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: linkHoverActive ? .pointingHand : pointerCursor)
    }

    /// Apply an OSC-22 pointer shape libghostty resolved for this surface. `raw` is the C
    /// `ghostty_action_mouse_shape_e` value; ``PointerShapeMapping`` turns it into a ``PointerShapeToken`` or
    /// `nil` to KEEP the current cursor (shapes with no native `NSCursor` — upstream's "ignore" behaviour).
    /// `GHOSTTY_MOUSE_SHAPE_DEFAULT` resolves to `.arrow`, which is the "reset to arrow on default" the spec
    /// calls for — and the same path covers "reset on program exit" because a program leaving a custom shape
    /// (e.g. `btop`/`yazi` returning to the shell) re-emits the default shape.
    func applyPointerShape(rawShape raw: Int32) {
        guard let token = PointerShapeMapping.token(forRawValue: raw) else { return }
        let cursor = Self.nsCursor(for: token)
        guard cursor !== pointerCursor else { return }
        pointerCursor = cursor
        // Re-arm the bounds cursor rect so AppKit adopts the new shape as the pointer moves within the pane,
        // and `.set()` it now so a STATIONARY pointer updates immediately (an OSC-22 change is usually a
        // response to the pointer already sitting over the targeted cell, where no mouse-moved event follows).
        window?.invalidateCursorRects(for: self)
        // Do NOT stomp a live ⌘-hover: the hand is the transient override (see ``setLinkHoverCursor(_:)``),
        // so a shape arriving mid-hover updates the BASE and shows when the hover ends.
        if !linkHoverActive { cursor.set() }
    }

    // MARK: Mouse-hide-while-typing (E8 H9 / ES-E8-6)

    /// Actuate libghostty's mouse-hide-while-typing decision (H9). The `mouse-hide-while-typing = true`
    /// config (default ON) makes libghostty emit a `GHOSTTY_ACTION_MOUSE_VISIBILITY` action when the
    /// user types / when the pointer should reappear; the app-level `action_cb` resolves it through the
    /// headless ``MouseVisibilityMapping`` and forwards the `visible` Bool here. We mirror ghostty's macOS
    /// `setCursorVisibility` EXACTLY — `NSCursor.setHiddenUntilMouseMoves(!visible)` — which is the
    /// preferred actuation for this use case: it hides the pointer now and AUTO-shows it on the next mouse
    /// move (so we never have to balance hide/unhide counters, and a stuck-hidden cursor is impossible).
    func applyMouseVisibility(_ visible: Bool) {
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    /// The single ``PointerShapeToken`` → `NSCursor` switch — mirrors ghostty's macOS `CursorStyle.cursor`
    /// (`Helpers/Cursor.swift`), incl. the macOS-15 `columnResize`/`rowResize` directional cursors with the
    /// legacy `resize*` fallback. Lives in the view (the only place AppKit is available); the token itself is
    /// resolved headlessly so the OSC-22 table stays unit-testable.
    private static func nsCursor(for token: PointerShapeToken) -> NSCursor {
        switch token {
        case .arrow: return .arrow
        case .text: return .iBeam
        case .verticalText: return .iBeamCursorForVerticalLayout
        case .pointer: return .pointingHand
        case .grab: return .openHand
        case .grabbing: return .closedHand
        case .contextMenu: return .contextualMenu
        case .crosshair: return .crosshair
        case .notAllowed: return .operationNotAllowed
        case .resizeLeft:
            if #available(macOS 15.0, *) { return .columnResize(directions: .left) } else { return .resizeLeft }
        case .resizeRight:
            if #available(macOS 15.0, *) { return .columnResize(directions: .right) } else { return .resizeRight }
        case .resizeUp:
            if #available(macOS 15.0, *) { return .rowResize(directions: .up) } else { return .resizeUp }
        case .resizeDown:
            if #available(macOS 15.0, *) { return .rowResize(directions: .down) } else { return .resizeDown }
        case .resizeUpDown:
            if #available(macOS 15.0, *) { return .rowResize } else { return .resizeUpDown }
        case .resizeLeftRight:
            if #available(macOS 15.0, *) { return .columnResize } else { return .resizeLeftRight }
        }
    }

    // MARK: Clipboard responder selectors (Cmd-C / Cmd-X / Cmd-V / Cmd-A)
    //
    // The terminal keyDown deliberately does NOT intercept Cmd-combos (they are app shortcuts). The
    // standard Edit menu / Cmd-key path lands on these responder selectors; we route each to the
    // matching libghostty binding action so copy uses the selection, paste applies bracketed-paste
    // (DECSET 2004) itself — do NOT hand-roll paste bytes — and select-all spans the screen+scrollback.
    // Cut copies the selection and (at an editable prompt only) deletes it. The workspace command table
    // (Cmd-T/W/D/1-9/R/]/[ + Opt-Cmd-arrows + Cmd-K) does NOT bind C/X/V/A, so these never collide.

    // `copy`/`cut`/`paste` are responder-chain selectors NOT declared on NSResponder itself, so they are
    // plain `@objc` (no `override`); `selectAll(_:)` IS declared on NSResponder, so it MUST be
    // `override` — matching upstream `SurfaceView_AppKit.swift:1507/1515/1539`.
    @objc func copy(_ sender: Any?) {
        surface?.performBindingAction("copy_to_clipboard")
    }

    /// CUT (⌘X / Edit ▸ Cut, audit fix `cut-cmdx-not-wired`). Cut always copies the selection to the
    /// clipboard; if editable prompt text, also deletes it; on read-only, falls back to a plain copy. The
    /// PURE, headless-tested ``CutSelectionPolicy`` makes the 3-way decision; this view is the thin actuator.
    /// The copy half is the universally-correct `copy_to_clipboard` binding action; the delete half is subject
    /// to the SAME geometry ceiling as backspace-deletes-selection — against the pinned libghostty fork we
    /// cannot prove the selection ends at the cursor, so the DEL count degrades to 0 (copy-only) rather than
    /// risk deleting the WRONG characters (data loss). The seam lights up when a future libghostty geometry
    /// API can prove the trailing run.
    @objc func cut(_ sender: Any?) {
        performCut()
    }

    /// Shared Cut actuation for the ⌘X responder + the context-menu Cut item (audit fix `cut-cmdx-not-wired`).
    private func performCut() {
        guard let surface else { return }
        let action = CutSelectionPolicy.action(
            hasSelection: surface.hasSelection(),
            // REAL alt-screen flag (DECSET 1049/47/1047 via the client `TerminalModeTracker`) — a full-screen
            // program owns the screen ⇒ copy only, never inject deletes (the program's input).
            isAlternateScreen: model?.isAlternateScreen ?? false,
            // Editable prompt zone: connected AND OSC-133 `.idle` AND NOT on the alternate screen — the only
            // place DEL bytes faithfully erase the selected run (identical gate to the backspace block).
            isPromptZone: (model?.connectionStatus.isLive ?? false)
                && model?.shellActivity == .idle
                && !(model?.isAlternateScreen ?? false),
        )
        guard action != .none else { return }
        // Always copy the selection (the universally-correct half).
        surface.performBindingAction("copy_to_clipboard")
        guard action == .copyAndDelete else { return }
        // Delete half — GEOMETRY CEILING (same as backspace-deletes-selection): `selectionEndsAtCursor: false`
        // against the pinned fork ⇒ `deleteCount` returns 0, so we pre-send NOTHING and the cut degrades to
        // copy-only. Sending DEL bytes for a run that does NOT end at the cursor (a word selected mid-command)
        // would delete the wrong characters and silently corrupt the line.
        let count = CutSelectionPolicy.deleteCount(
            selection: surface.readSelection() ?? "",
            selectionEndsAtCursor: false,
        )
        if count > 0 { model?.sendInput(Data(repeating: 0x7F, count: count)) }
    }

    @objc func paste(_ sender: Any?) {
        requestPaste()
    }

    /// E8 WI-4 (ES-E8-3): the single embedder paste entry point for ⌘V / right-click-Paste / context-menu
    /// Paste. It runs the paste-protection pre-check BEFORE handing the bytes to libghostty, because
    /// libghostty's own `isSafe` gate is NARROWER than this pre-check's four dangers (it trips its
    /// `confirm_read_clipboard_cb` only for a `\n` / bracketed-end payload) — so a single-line `sudo`, an
    /// ESC-laced control-char paste, or a bare-`\r` paste would otherwise reach the shell SILENTLY. The PURE,
    /// headless-tested ``PastePrecheck`` makes the decision off the LIVE "Paste Protection" toggle and
    /// the OSC-133 shell-activity (a full-screen TUI owns the screen ⇒ `.running` ⇒ skip, the paste lands
    /// inertly). On a danger we present ``PasteProtectionSheet``; only on approve do we paste, with
    /// `allow_unsafe` (the one-shot `pasteApprovedOnce` flag) so libghostty's own gate is not re-tripped into
    /// a SECOND dialog. A safe payload (or protection off) pastes straight through libghostty, which still
    /// applies bracketed-paste framing.
    private func requestPaste() {
        requestPaste(clipboard: NSPasteboard.general.string(forType: .string) ?? "", bindingAction: "paste_from_clipboard")
    }

    /// E8 / audit fix `rightclick-paste-protection-hole`: a MIDDLE-CLICK paste (X11 primary-selection) reads
    /// the SELECTION clipboard, not the system one. Run the SAME pre-check over the selection content, then
    /// (on approve / safe) hand it to libghostty's `paste_from_selection` so it applies bracketed-paste
    /// framing. Empty selection → no-op.
    private func requestPasteFromSelection() {
        let selection = slopdeskPasteboard(for: GHOSTTY_CLIPBOARD_SELECTION).string(forType: .string) ?? ""
        guard !selection.isEmpty else { return }
        requestPaste(clipboard: selection, bindingAction: "paste_from_selection")
    }

    /// The shared paste entry point: run ``PastePrecheck`` over `clipboard` BEFORE handing it to
    /// libghostty's `bindingAction` (`paste_from_clipboard` for ⌘V / right-click / context-menu Paste,
    /// `paste_from_selection` for a middle-click). libghostty's own `isSafe` gate is narrower than this
    /// pre-check's four dangers, so a single-line `sudo`, an ESC-laced control-char paste, or a bare-`\r` paste would otherwise
    /// reach the shell SILENTLY for ANY libghostty-initiated paste path. On a danger we present
    /// ``PasteProtectionSheet`` and paste with `allow_unsafe` only on approve; a safe payload (or protection
    /// off) pastes straight through, which still applies bracketed-paste framing.
    private func requestPaste(clipboard: String, bindingAction: String) {
        guard let surface else { return }
        let decision = PastePrecheck.decide(
            clipboard: clipboard,
            protectionOn: SettingsKey.pasteProtectionEnabled,
            // REAL alt-screen flag, not the `.running` proxy: a single-line `sudo` pasted into a non-TUI
            // foreground command must STILL trip the sheet (the `.running` proxy wrongly skipped it).
            isAlternateScreen: model?.isAlternateScreen ?? false,
            // Bracketed-safe skip (matches libghostty's `clipboard-paste-bracketed-safe`, which this
            // pre-check preempts): the live setting AND the real DECSET `?2004h` state from the client
            // `TerminalModeTracker`. When both hold, the shell frames the paste inertly → no sheet.
            bracketedSafe: SettingsKey.pasteBracketedSafeEnabled,
            programAdvertisedBracketed: model?.isBracketedPasteActive ?? false,
        )
        switch decision {
        case .pasteDirect:
            surface.performBindingAction(bindingAction)   // libghostty applies bracketed-paste
        case let .confirm(dangers):
            PasteProtectionSheet.present(
                ask: .unsafePaste,
                preview: clipboard,
                dangers: dangers,
                in: window,
            ) { [weak self] pasteAnyway in
                guard pasteAnyway, let self, let surface = self.surface else { return }
                // Approved → paste with allow_unsafe (one-shot), consumed by `read_clipboard_cb`. Capture the
                // REVIEWED text so the read returns the exact snapshot the user approved (not a fresh — and
                // possibly swapped — pasteboard read). Both are cleared right after the SYNCHRONOUS
                // binding-action read so they can never leak into a later read.
                surface.pasteApprovedOnce = true
                surface.approvedPasteText = clipboard
                surface.performBindingAction(bindingAction)
                surface.pasteApprovedOnce = false
                surface.approvedPasteText = nil
            }
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        surface?.performBindingAction("select_all")
    }

    // MARK: Jump to prompt (W14 #6 — OSC 133 shell-integration, Ghostty/Warp signature)
    //
    // libghostty owns OSC 133 prompt marks (the same C/D sequences `HostOutputSniffer` reads host-side)
    // and exposes `jump_to_prompt:<delta>` as a binding action (negative = previous prompt, positive =
    // next). We surface it through the SAME `performBindingAction` lever the copy/paste path uses — so a
    // future menu item / chord binding routes straight to libghostty's prompt navigation with no
    // host/wire change. Compile-only (the real surface hangs headless); these are responder selectors a
    // command can target. `find:` is the responder twin of the right-click "Find…" / ⌘F.

    /// Jump the viewport to the PREVIOUS shell prompt (OSC 133 mark). libghostty `jump_to_prompt:-1`.
    @objc func jumpToPreviousPrompt(_ sender: Any?) {
        surface?.performBindingAction("jump_to_prompt:-1")
    }

    /// Jump the viewport to the NEXT shell prompt (OSC 133 mark). libghostty `jump_to_prompt:1`.
    @objc func jumpToNextPrompt(_ sender: Any?) {
        surface?.performBindingAction("jump_to_prompt:1")
    }

    /// Responder-chain twin of the right-click "Find…" — opens this pane's find bar (W14 #5).
    @objc func find(_ sender: Any?) {
        model?.onRequestFind?()
    }

    // MARK: Right-click context menu (W14 #10)
    //
    // A native `NSMenu` built from the PURE `TerminalContextMenu` model (item list + per-item enablement),
    // so copy/paste/select-all/clear route to libghostty binding actions, paste-as-keystrokes types the
    // pasteboard string, and split/find route to the store via the model callbacks. The enablement logic
    // (copy needs a selection, paste needs clipboard text) lives in the unit-tested `TerminalContextMenu`;
    // this view is the thin renderer. `rightMouseDown` already gives libghostty first refusal (it may turn
    // a right-click into a paste in mouse-reporting apps) — `menu(for:)` only fires when AppKit falls
    // through to the default menu path, so a TUI that wants the right-click still gets it.

    /// Builds the terminal context menu for `event`, with each item enabled per `TerminalContextMenu`.
    override func menu(for event: NSEvent) -> NSMenu? {
        let ctx = TerminalContextMenu.Context(
            hasSelection: surface?.hasSelection() ?? false,
            clipboardHasText: !(NSPasteboard.general.string(forType: .string)?.isEmpty ?? true),
            paneConnected: true,
            // WB2: "Copy Command Output" is enabled when this pane has at least one completed command block.
            hasCommandOutput: model?.blocks.latest?.complete ?? false,
        )
        let menu = NSMenu()
        // NSMenu defaults `autoenablesItems == true`, which RE-VALIDATES every item at display time and
        // enables any whose target responds to the action selector (all of them here) — clobbering the
        // per-item `isEnabled` set from the unit-tested `TerminalContextMenu.isEnabled`. Turn it off so the
        // manual enablement (copy-needs-selection, paste-needs-clipboard, hasCommandOutput, …) actually shows.
        menu.autoenablesItems = false

        // E10 WI-6 (ES-E10-2): if the right-click landed ON a detected path/URL, PREPEND its action items
        // (Open / Copy Path|URL / Reveal in Finder / Change Directory Here) above the standard terminal menu,
        // separated by a rule. Each routes through the pure `LinkActionPolicy` for the stashed `pendingMenuLink`.
        pendingMenuLink = detectedLink(at: surfacePoint(event))
        if let link = pendingMenuLink {
            for linkItem in TerminalContextMenu.linkItems(for: link.kind) {
                let item = NSMenuItem(
                    title: linkItem.title(for: link.kind), action: #selector(linkMenuAction(_:)), keyEquivalent: "",
                )
                item.target = self
                item.representedObject = linkItem.rawValue
                item.image = NSImage(systemSymbolName: linkItem.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        for item in TerminalContextMenu.items {
            if item.separatorBefore { menu.addItem(.separator()) }
            let menuItem = NSMenuItem(title: item.title, action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.rawValue
            menuItem.isEnabled = TerminalContextMenu.isEnabled(item, context: ctx)
            menu.addItem(menuItem)

            // E8 / ES-E8-4: the "Paste as…" submenu sits directly below Paste (Edit ▸ Paste ▸ Paste as).
            // Each variant is tagged + targeted like a top-level item, so it dispatches through the same
            // `contextMenuAction(_:)`; enablement comes from the same unit-tested `TerminalContextMenu` rule.
            if item == .paste {
                let pasteAsItem = NSMenuItem(
                    title: TerminalContextMenu.pasteAsSubmenuTitle, action: nil, keyEquivalent: "",
                )
                let submenu = NSMenu(title: TerminalContextMenu.pasteAsSubmenuTitle)
                submenu.autoenablesItems = false   // same reason as the parent menu — honour manual isEnabled
                for sub in TerminalContextMenu.pasteAsItems {
                    if sub.separatorBefore { submenu.addItem(.separator()) }
                    let subItem = NSMenuItem(
                        title: sub.title, action: #selector(contextMenuAction(_:)), keyEquivalent: "",
                    )
                    subItem.target = self
                    subItem.representedObject = sub.rawValue
                    subItem.isEnabled = TerminalContextMenu.isEnabled(sub, context: ctx)
                    submenu.addItem(subItem)
                }
                pasteAsItem.submenu = submenu
                menu.addItem(pasteAsItem)
            }
        }
        return menu
    }

    /// Dispatches a context-menu item (tagged by its `TerminalContextMenu.Item.rawValue`) to the matching
    /// libghostty binding action / model callback. Unknown tags are ignored (validate-then-drop).
    @objc private func contextMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let item = TerminalContextMenu.Item(rawValue: raw) else { return }
        switch item {
        case .copy: surface?.performBindingAction("copy_to_clipboard")
        case .cut: performCut()   // audit fix: copy the selection + (editable prompt only) delete it
        case .paste: requestPaste()   // ES-E8-3: paste-protection pre-check, then libghostty's bracketed paste
        case .pasteAsKeystrokes:
            // Type the pasteboard string as raw keystrokes (no bracketed-paste) — the "paste literally"
            // affordance for TUIs that swallow bracketed paste.
            if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty { surface?.text(s) }
        // E8 / ES-E8-4 — "Paste as…" variants. The three transforms are typed via the surface's `text(_:)`
        // path (PasteTransform is the unit-tested engine); the routing variants read a different source.
        case .pasteSelection:
            // X11 middle-click convention: type the current SELECTION rather than the clipboard.
            if let sel = surface?.readSelection(), !sel.isEmpty { surface?.text(sel) }
        case .pasteFileBase64:
            pasteFileAsBase64()
        case .pasteEscaped:
            if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
                surface?.text(PasteTransform.shellEscaped(s))
            }
        case .pasteBracketed:
            if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
                surface?.text(PasteTransform.bracketed(s))
            }
        case .selectAll: surface?.performBindingAction("select_all")
        case .clear: surface?.performBindingAction("clear_screen")
        case .copyOutput:
            // WB2: copy the LATEST completed command block's output. The model requests it (wire type 15),
            // strips VT control sequences, and (on a non-empty reply) puts plain text on the clipboard; an
            // empty/unavailable reply is a graceful no-op (the model resolves it — never hangs).
            if let index = model?.blocks.latest?.index {
                model?.copyBlockOutput(index: index) { text in
                    guard let text, !text.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        case .splitRight: model?.onContextMenuSplit?(true)
        case .splitDown: model?.onContextMenuSplit?(false)
        case .find: model?.onRequestFind?()
        }
    }

    /// E8 / ES-E8-4 "Paste File Base64-Encoded…": pick a single file, base64-encode its bytes, and type
    /// the result. Reads the bytes DEFENSIVELY — a cancelled panel, a missing URL, or an unreadable file is
    /// a silent no-op (never a crash). The encoding is the unit-tested `PasteTransform.base64`.
    private func pasteFileAsBase64() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bytes = try? Data(contentsOf: url) else { return }
        let encoded = PasteTransform.base64(ofFileBytes: bytes)
        if !encoded.isEmpty { surface?.text(encoded) }
    }

    /// Catch Cmd-C / Cmd-X / Cmd-V / Cmd-A DIRECTLY, regardless of whether an Edit menu is installed. Returning
    /// `true` marks the equivalent handled so it does not propagate to the menu / beep. Other Cmd-combos
    /// (the workspace shortcuts) are left to `super` so the command table still sees them — via
    /// `unhandledKeyEquivalent`, which also arms the NSTextInputClient doCommand redispatch (see there).
    ///
    /// **First-responder gate:** AppKit walks the *whole* view tree for `performKeyEquivalent`, not just the
    /// first responder. Without this guard a focused Search tabs / Find / Open Quickly field loses ⌘A/C/V/X
    /// (and font-size chords) to every live terminal surface — the classic "⌘A highlights the pane, not the
    /// search string" bug. Only THIS surface claims those chords when it actually owns the keyboard.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only the bare Cmd-<letter> (no shift/ctrl/opt) is the copy/paste/select-all chord; a shifted
        // or otherwise-modified Cmd combo is left to the workspace command table / remote app.
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.shift),
              let chars = event.charactersIgnoringModifiers else {
            return unhandledKeyEquivalent(event)
        }
        // Not the keyboard owner → leave the equivalent for the real first responder (NSTextField field
        // editor, find bar, etc.) / menu / other panes.
        guard window?.firstResponder === self else {
            return unhandledKeyEquivalent(event)
        }
        switch chars {
        case "c": copy(nil); return true
        case "x": cut(nil); return true   // audit fix `cut-cmdx-not-wired`: ⌘X copies (+prompt-zone delete)
        case "v": paste(nil); return true
        case "a": selectAll(nil); return true
        // Font sizing — the universal terminal chords (Terminal.app/iTerm/Ghostty): ⌘= grows, ⌘-
        // shrinks, ⌘0 resets. Routed to libghostty's font-size binding actions, which reflow the grid
        // (the resize path then propagates the new cols/rows to the host). None collide with the
        // workspace command table (Cmd-T/W/D/1-9/R/\[\ + Opt-Cmd-arrows + Cmd-K) — Cmd-0 is unbound
        // (tabs use Cmd-1…9). "=" is the no-shift form of the +/= key, matching macOS convention.
        // `increase/decrease_font_size` take a points DELTA parameter (Binding.zig:369/375 —
        // `increase_font_size: f32`), so the action string MUST carry `:1` (Ghostty's own default
        // step, Config.zig); a bare `increase_font_size` fails to parse and no-ops. `reset_font_size`
        // is parameterless.
        case "=": surface?.performBindingAction("increase_font_size:1"); return true
        case "-": surface?.performBindingAction("decrease_font_size:1"); return true
        case "0": surface?.performBindingAction("reset_font_size");      return true
        default:  return unhandledKeyEquivalent(event)
        }
    }

    /// The tail of `performKeyEquivalent` for every equivalent this view does NOT claim.
    /// Because the view is an NSTextInputClient, letting an unclaimed ⌘/⌃ equivalent flow
    /// through AppKit can end at the input context, which maps it to a `doCommand` selector
    /// (⌘. → "cancel:") WITHOUT ever calling `keyDown` — silently eating the key. Upstream's
    /// fix (`lastPerformKeyEvent`, SurfaceView_AppKit.swift): remember the event's timestamp
    /// on the FIRST pass and let AppKit try (menu items, the workspace command table, and any
    /// other responder all still win exactly as before); if `doCommand` receives that same
    /// event it re-sends it, and THIS second pass routes it to `keyDown` for ghostty encoding.
    private func unhandledKeyEquivalent(_ event: NSEvent) -> Bool {
        // Only real keyDown equivalents participate; synthetic events carry timestamp 0
        // (e.g. the "escape" AppKit fabricates for ⌘.) and must never be re-routed.
        guard event.type == .keyDown, event.timestamp != 0 else {
            return super.performKeyEquivalent(with: event)
        }
        // The redispatch marker is a FIRST-RESPONDER-ONLY device: it reroutes an equivalent nobody
        // claimed back into THIS surface as terminal input. While another view owns the keyboard
        // (the code panel's webview), arming it turned every chord the web page declined into
        // phantom terminal input — WebKit re-dispatches unhandled equivalents, the second pass
        // matched the marker, and libghostty's own `cmd+v = paste` binding pasted into the PTY
        // behind the editor the user was typing in (user-reported 2026-08-03).
        guard window?.firstResponder === self else {
            lastPerformKeyEvent = nil
            return super.performKeyEquivalent(with: event)
        }
        // Non-⌘/⌃ equivalents can't hit the input-context redirect; reset the marker.
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
            lastPerformKeyEvent = nil
            return super.performKeyEquivalent(with: event)
        }
        // Second pass of a doCommand-redispatched event: nothing else claimed it, so it is
        // terminal input — route to keyDown (which encodes via ghostty) and consume.
        if let lastPerformKeyEvent, lastPerformKeyEvent == event.timestamp {
            self.lastPerformKeyEvent = nil
            keyDown(with: event)
            return true
        }
        // First pass: arm the redispatch marker, then let the normal AppKit flow try.
        lastPerformKeyEvent = event.timestamp
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        // Coalesced (not a direct setFocus) so this keyboard fast-path can't pair with a just-forwarded
        // unfocus in the same render-thread drain — the cursor-blink race (see `forwardRenderFocus`).
        forwardRenderFocus(true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        // DO NOT touch libghostty render-focus here. Render focus is driven by `isFocusedPane` (the
        // WORKSPACE focus, set by the representable) — NOT by the AppKit responder chain — so when a sibling
        // becomes the workspace-focused pane THIS pane's `isFocusedPane` flips false and its didSet forwards
        // `setFocus(false)` (ghostty's hollow cursor). Dropping focus HERE instead would also unfocus the
        // surface when the whole window merely resigns key (⌘-Tab away), wrongly hollowing the active pane's
        // cursor. An unfocused pane still repaints via the content-driven present path, so it does NOT freeze
        // (a pane truly leaving the screen is `detach()`'d, which closes the surface).
        //
        // DO clear the ⌘-hold link underline, though. When a sibling pane grabs first responder (⌘T / any
        // focus move that calls `makeFirstResponder`), a ⌘ that is still physically held will NEVER deliver
        // its release `flagsChanged` to us, so `linkHighlightActive` (and the resolved hover path) would stay
        // set and the ``LinkHighlightOverlay`` would keep every detected path underlined until this pane is
        // re-focused and ⌘ is tapped again (the reported bug). Clearing it on resign fixes that. (The OTHER
        // no-release path — the whole window resigning key on ⌘-Tab away, which does NOT call
        // `resignFirstResponder` — is covered separately by the `didResignKeyNotification` observer in
        // `viewDidMoveToWindow`.) Mutating the `@Observable` model here is safe — a responder-chain callback
        // is not inside a view-update pass (same as `flagsChanged`).
        clearLinkHighlight()
        // IME (keyboard audit): CANCEL any in-flight composition when this pane loses first responder (a
        // pane-focus move / ⌘T / a click into a sibling). Without this the marked text + the ghostty preedit
        // stayed LIVE in the abandoned pane — a mid-Telex/Japanese composition stranded its underline there,
        // and the input method's staged keystrokes silently vanished or double-landed when focus returned.
        // `unmarkText()` clears the mirror and republishes the EMPTY preedit (`syncPreedit` →
        // `surface.preedit(nil)`); `discardMarkedText()` tells the input context to abandon its own staged
        // composition so nothing is re-delivered on refocus. Both are guarded/idempotent and neither commits
        // bytes to the PTY (`insertText` is not involved — the composition is dropped, not accepted).
        if hasMarkedText() {
            unmarkText()
            inputContext?.discardMarkedText()
        }
        return super.resignFirstResponder()
    }

    /// Clears the ⌘-hold link underline state (``TerminalViewModel/linkHighlightActive`` + the resolved
    /// ``TerminalViewModel/hoveredLinkFullPath``). Called whenever this pane can no longer receive the ⌘
    /// release `flagsChanged` — losing first responder (`resignFirstResponder`) or its window resigning key
    /// (⌘-Tab away). Idempotent + a no-op when nothing is highlighted; safe on the main actor, since every
    /// caller is an AppKit callback rather than a view-update pass.
    private func clearLinkHighlight() {
        guard let model else { return }
        if model.linkHighlightActive { model.linkHighlightActive = false }
        clearLinkHover()
    }

    /// Maps AppKit modifier flags → libghostty mods (header 100).
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift)    { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        // `ghostty_input_mods_e` is a PLAIN C enum (ghostty.h:99-111 — no
        // flag_enum/NS_OPTIONS attribute), so the Clang importer's `init?(rawValue:)`
        // is FAILABLE and only succeeds for declared enumerators. An OR-accumulated
        // value (e.g. SHIFT|CTRL = 3) is not an enumerator, so the labeled init would
        // return nil → both a type mismatch (optional vs. non-optional return) and a
        // runtime break. Use the importer's UNLABELED non-failable init over the raw
        // integer instead — matches upstream Ghostty.Input.swift `ghosttyMods`.
        return ghostty_input_mods_e(raw)
    }

    /// Maps libghostty mods → AppKit modifier flags (upstream `Ghostty.eventModifierFlags`) — the
    /// reverse of ``ghosttyMods(_:)``, used to read `ghostty_surface_key_translation_mods`' answer
    /// back into `NSEvent` space for the option-as-alt translation event. Side bits (left/right)
    /// collapse into the plain flag; the caller only copies the four mod STATES anyway.
    static func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        if mods.rawValue & GHOSTTY_MODS_CAPS.rawValue != 0 { flags.insert(.capsLock) }
        return flags
    }

    /// WS-B / B4: map an `NSEvent` keystroke to the framework-neutral `KeyChord` the `TerminalKeyInterceptor`
    /// keys on, or `nil` for a pure-modifier / non-chord key (which the caller then leaves to the normal
    /// libghostty path — never swallowed). This is the ONLY new logic the view layer carries, and it is a
    /// VERBATIM mirror of `KeyChordNormalizer.chord` in ClientUI (which `swift build` DOES type-check and
    /// `KeyChordNormalizerTests` pins) — duplicated, not shared, because `KeyChordNormalizer` lives in
    /// ClientUI and this gated file cannot import it. Keep the two in lock-step: named keys by keyCode FIRST
    /// (parity with the keybindings editor's `baseKey`), else a single printable `charactersIgnoringModifiers`
    /// (⌘/⌥/⌃-independent; ⇧ rides `modifiers`); reject whitespace / control scalars so a bare/Ctrl key still
    /// reports its printable base (⌃B → "b") and normal typing falls through.
    static func workspaceChord(for event: NSEvent) -> KeyChord? {
        var mods: KeyChord.Modifiers = []
        if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if event.modifierFlags.contains(.control) { mods.insert(.control) }
        if event.modifierFlags.contains(.option) { mods.insert(.option) }
        if event.modifierFlags.contains(.command) { mods.insert(.command) }

        switch event.keyCode {
        case 36, 76: return KeyChord(.return, mods) // Return / keypad Enter
        case 48: return KeyChord(.tab, mods)
        case 123: return KeyChord(.leftArrow, mods)
        case 124: return KeyChord(.rightArrow, mods)
        case 126: return KeyChord(.upArrow, mods)
        case 125: return KeyChord(.downArrow, mods)
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers, let first = chars.first, chars.count == 1 else {
            return nil
        }
        guard !first.isWhitespace, first.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return nil }
        return KeyChord(character: first, mods)
    }
}

// MARK: - NSTextInputClient (IME: Vietnamese Telex / CJK / dead-key composition)

/// Faithful port of upstream `Ghostty.SurfaceView: NSTextInputClient`
/// (SurfaceView_AppKit.swift:1810). Making the view a text-input client gives it an
/// `inputContext`, so `keyDown`'s `interpretKeyEvents` routes plain typing through the active
/// macOS input method: marked text lands in `setMarkedText` (mirrored to ghostty's preedit —
/// the composing underline at the cursor), commits land in `insertText` (funneled through the
/// ghostty key path via `keyTextAccumulator`), and `firstRect` anchors the candidate window at
/// the terminal cursor. Deviations from upstream, deliberate: `selectedRange` is empty (the
/// pinned fork exposes selection CONTENT but not grid OFFSETS, and no QuickLook consumer is
/// wired here) so `firstRect` always anchors at the IME point; `doCommand`'s scroll-selector
/// handling is omitted (scrolling is pane-owned here).
// The conformance is ISOLATED to the main actor (SE-0470): `NSTextInputClient` is not
// MainActor-annotated in the macOS 26 SDK, but AppKit only ever drives it from the main
// thread (the input context lives on the view's thread), so the isolated conformance is
// sound and keeps every method main-actor without `nonisolated` escape hatches.
extension GhosttyLayerBackedView: @MainActor NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        NSRange()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break // unknown payload type — leave the composition untouched (upstream logs & ignores)
        }

        // OUTSIDE a keyDown (accumulator nil — e.g. an input-source switch mid-composition
        // re-shapes the marked text), publish the preedit immediately; the keyDown path syncs
        // once after interpretKeyEvents instead (upstream:1848).
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // Upstream returns the current selection regardless of the (often bogus) requested
        // range — macOS lookup/Services probe this. String-only via the binding's selection read.
        guard range.length > 0, let selection = surface?.readSelection(), !selection.isEmpty else { return nil }
        return NSAttributedString(string: selection)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Anchor the IME candidate window at the terminal cursor: ghostty reports the cursor
        // cell's bottom-left in view-local TOP-LEFT-origin POINTS (Surface.zig `imePoint`
        // divides by the content scale) → flip to AppKit's bottom-left origin → window → screen.
        guard let ime = surface?.imePoint(), let window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }
        let viewRect = NSRect(x: ime.x, y: frame.size.height - ime.y, width: ime.width, height: ime.height)
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Must be associated with a real input event (upstream guard — filters programmatic calls).
        guard NSApp.currentEvent != nil else { return }

        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }

        // insertText ⇒ the composition COMMITTED — the preedit is over.
        unmarkText()

        // Inside keyDown's interpretKeyEvents: accumulate so keyDown sends the composed text
        // through the ghostty KEY path (correct keycode/mods + composing flags).
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // Outside keyDown (e.g. a candidate picked with the MOUSE in the IME window): commit
        // as plain text — `ghostty_surface_text` encodes + writes to the PTY.
        surface?.text(chars)
    }

    /// Two jobs (upstream:1993): (1) swallow the selectors `interpretKeyEvents` produces for
    /// named keys (arrows/Return/Backspace/Esc → `moveUp:`/`insertNewline:`/…) so NSResponder's
    /// unhandled-action NSBeep never fires — those keys are ENCODED in keyDown after
    /// interpretKeyEvents returns, via the ghostty key path, not here; (2) when AppKit's input
    /// context redirected a ⌘-equivalent here before keyDown could see it, re-send the event so
    /// `unhandledKeyEquivalent`'s second pass routes it to keyDown (see `lastPerformKeyEvent`).
    override func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
        // Deliberately NO `super.doCommand(by:)` — everything else is swallowed.
    }
}

// MARK: - The terminal pixel seam (docs/56 stage F, risk 2)

/// `GhosttyLayerBackedView` IS the terminal surface an AppKit canvas wants, so the seam is a conformance
/// and not a wrapper.
///
/// ⚠️ THIS USED TO BE "THE NATIVE HALF" OF TWO. The seam carried a second slot whose value was a SwiftUI
/// `AnyView` wrapping this same view in an `NSViewRepresentable`, and the three members below were that
/// representable's lifecycle re-spelled: `surfaceView` was `makeNSView`, `setPaneFocused` was what
/// `updateNSView` wrote, `detachSurface` was what `dismantleNSView` called. The one premise that kept the
/// SwiftUI slot alive — "the phone has no `NSView`, so iOS can only cross as a `View`" — died when the
/// phone moved to UIKit and gained a `UIView`, so the slot went and these three are simply the seam. What
/// the fold buys is not tidiness: the SwiftUI slot mounted an `NSHostingView` over the ONE surface that
/// must take every keystroke, and a hosting view claims the hit-test.
extension GhosttyLayerBackedView: TerminalSurfaceHosting {
    var surfaceView: NSView { self }

    func setPaneFocused(_ isFocused: Bool) { isFocusedPane = isFocused }

    func detachSurface() { detach() }
}

#elseif os(iOS)

/// A `UIView` whose `layerClass` is `CAMetalLayer`, owning the `GhosttySurface`.
///
/// Physical-key and IME text forwarding are NOT here, on purpose. A `CAMetalLayer` view answers no
/// key event; the pane's responder is `SlopDeskPhoneUI.TerminalInputHost`, mounted beside this one
/// by `TerminalLeafView` and holding first responder for the pane. It reads a `UIKey` into a
/// `PhoneKey.Press` and asks `SlopDeskWorkspaceCore.PhoneKey` — which of the two input paths the
/// press takes, the bytes it sends under the live cursor-key mode, the chord it makes for the shared
/// binding table — all of which is `slopdesk_workspace::phone_key`. This view hosts the Metal layer
/// and the surface, and nothing about input.
final class GhosttyLayerBackedView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private var surface: GhosttySurface?
    weak var model: TerminalViewModel?   // set by the representable; read by the window-gated attach
    /// Whether THIS pane is the workspace's focused pane — seeded by the seam's factory at mount and
    /// re-pushed by ``TerminalSurfaceHosting/setPaneFocused(_:)``. Drives libghostty's
    /// render FOCUS so an unfocused pane shows ghostty's hollow non-blinking cursor (focused = solid block),
    /// matching the macOS sibling. Forwarding unfocus does NOT freeze the pane — output still presents via
    /// the content-driven `onContentChanged → requestPresent` path; only ghostty's internal blink/auto-draw
    /// idles. (iOS keyboard focus is owned by `TerminalInputHost`, doc 17 §2.5 — only render-focus is here.)
    var isFocusedPane: Bool = true {
        didSet {
            guard isFocusedPane != oldValue else { return }
            forwardRenderFocus(isFocusedPane)
        }
    }

    /// Render-focus COALESCED to the next runloop (last-writer-wins, deduped) — parity with the macOS view.
    /// Collapses an in-runloop focus FLICKER (false→true) to a single net forward so an unfocus + refocus
    /// never hit libghostty's render-thread in one mailbox drain — the cursor-blink-cancel race that strands
    /// `cursor_blink_visible = false` with a dead blink timer (focused cursor stuck invisible). See the macOS
    /// `forwardRenderFocus` for the full mechanism.
    private var lastForwardedFocus: Bool?
    private var pendingFocusForward: Bool?

    private func forwardRenderFocus(_ focused: Bool) {
        let alreadyScheduled = pendingFocusForward != nil
        pendingFocusForward = focused
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let want = self.pendingFocusForward else { return }
            self.pendingFocusForward = nil
            guard self.lastForwardedFocus != want else { return }
            self.lastForwardedFocus = want
            self.surface?.setFocus(want)
            self.requestPresent(want ? 6 : 3)
        }
    }
    /// Drives libghostty's renderer thread each display tick via `ghostty_surface_draw_now`.
    /// REQUIRED for glyphs: libghostty rasterizes glyphs + rebuilds foreground cells lazily
    /// on its render thread; without a steady tick the synchronous `feed`-time draw can
    /// present a background-only frame (no text) and never self-correct.
    private var displayLink: CADisplayLink?

    /// presentTicks gating — the macOS design ported (the macOS side documented that an
    /// UNCONDITIONAL per-tick draw_now kept the renderer thread's mach-port permanently
    /// ready so its libxev loop busy-spun; on iOS the ungated 60Hz drawNow cost a
    /// cross-thread wakeup + mutex churn per pane per frame, forever, even fully idle).
    /// On the SIMULATOR the free-run is kept: patch 0001 records the renderer thread's
    /// libxev wakeup async "not pumped after the initial startup notify (observed on the
    /// iOS Simulator)" — the steady drawNow is what papers over that there.
    private var presentTicks = 0

    /// Single arming choke point (mirrors macOS `requestPresent`): content/gesture/layout
    /// changes arm a few ticks; `renderTick` drains them, then PAUSES the link (device),
    /// so an idle pane stops paying a permanent 60Hz main-runloop wakeup. Un-pausing HERE
    /// keeps every arming site correct by construction (any future path must route through
    /// this or it silently never presents). Nil-safe before the link exists; on the
    /// SIMULATOR the link free-runs and is never paused, so the un-pause is a no-op there.
    func requestPresent(_ ticks: Int = 3) {
        presentTicks = max(presentTicks, ticks)
        displayLink?.isPaused = false
    }

    // MARK: Pan-to-scroll (touch scrollback)
    //
    // PAN-TO-SCROLL — the iOS counterpart of the macOS `scrollWheel` override above
    // (lines ~775-790, HW-verified scroll-wheel → scrollback). The macOS renderer is an
    // `NSView` that receives `scrollWheel(with:)` for free; an iOS `UIView` gets NO scroll
    // events, so we install a `UIPanGestureRecognizer` and translate a finger drag into the
    // SAME `surface.sendMouseScroll(deltaX:deltaY:mods:)` call. libghostty then decides the
    // behavior: on the primary screen the delta navigates scrollback; in an alt-screen
    // mouse-mode TUI (vim/tmux/htop) it is encoded as a mouse-scroll report — both handled
    // internally, so NO gating is needed here (same as macOS `scrollWheel`).
    //
    // Strong ref so we can `removeGestureRecognizer` in `detach()` (UIView already retains
    // its recognizers, but holding it lets us detach symmetrically with the rest of teardown).
    private var panRecognizer: UIPanGestureRecognizer?

    /// Accumulated `translation(in:).y` consumed so far, so each `.changed` event yields the
    /// INCREMENTAL delta since the previous event (UIPanGestureRecognizer reports CUMULATIVE
    /// translation, not per-event). Mirrors macOS feeding small per-event `scrollingDeltaY`
    /// deltas to `sendMouseScroll` rather than one absolute value — keeps scrollback smooth.
    /// Reset to 0 on `.began` (a fresh gesture starts a fresh accumulation).
    private var lastPanTranslationY: CGFloat = 0

    // MARK: Tap-to-mouse-button (touch click for mouse-mode TUIs)
    //
    // TAP→MOUSE-BUTTON — the iOS counterpart of the macOS `mouseDown`/`mouseUp` overrides above
    // (lines ~699-719, HW-verified click → libghostty mouse semantics). The macOS renderer is an
    // `NSView` that receives `mouseDown(with:)`/`mouseUp(with:)` for free; an iOS `UIView` gets NO
    // click events, so we install a `UITapGestureRecognizer` and translate a finger tap into the
    // SAME position + press/release pair the macOS overrides emit, via
    // `surface.sendMousePos(x:y:mods:)` + `surface.sendMouseButton(state:button:mods:)`. libghostty
    // then decides the behavior off `mouse_captured`: in an alt-screen mouse-mode TUI (vim
    // `set mouse=a`, tmux, htop, lazygit, less) the tap is encoded as a click REPORT to the remote
    // program; at the bare shell (no mouse mode) it is a zero-length press+release at a cell that
    // libghostty positions/clears the selection with — harmless (no clipboard write, the selection
    // is zero-length). Either way libghostty owns the decision, so NO gating is needed here (same as
    // macOS `mouseDown`). This is the natural companion to the pan-to-scroll above.
    //
    // Strong ref so we can `removeGestureRecognizer` in `detach()` (UIView already retains its
    // recognizers, but holding it lets us detach symmetrically with the rest of teardown — mirrors
    // `panRecognizer`).
    private var tapRecognizer: UITapGestureRecognizer?

    /// Installs the pan-to-scroll recognizer on `self` (the renderer UIView). Idempotent —
    /// guarded so the idempotent `attach()` (re-run on every window entry) never stacks duplicate
    /// recognizers. The keyboard input bar (`TerminalInputHost`) is a
    /// SEPARATE sibling view the pane's leaf mounts beside this one, so the pan
    /// here cannot swallow its taps; and a `UIPanGestureRecognizer` only recognizes DRAGS, not
    /// taps, so a tap meant for focusing/keyboard passes straight through to other handlers.
    private func installPanToScrollIfNeeded() {
        guard panRecognizer == nil else { return }
        isUserInteractionEnabled = true   // a passive renderer may default this off
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePanToScroll(_:)))
        pan.maximumNumberOfTouches = 2    // 1- or 2-finger drag scrolls; matches a trackpad scroll
        // The pan YIELDS to a live selection drag (see `gestureRecognizerShouldBegin`): once the long
        // press has armed a selection, a finger moving across the grid EXTENDS that selection and must
        // not also scroll the viewport out from under it. A state flag rather than `require(toFail:)` on
        // purpose — making every scroll wait `TerminalTouchSelection.longPressDuration` for the press to
        // fail would put 0.4s of lag on this pane's most common gesture to buy an arbitration the flag
        // settles for free, and the two gestures are already disjoint in practice (a finger that has
        // travelled far enough to pan has cancelled the press long before it is recognized).
        pan.delegate = self
        addGestureRecognizer(pan)
        panRecognizer = pan
    }

    /// The packed `ghostty_input_scroll_mods_t` every touch-driven scroll on this view sends: bit0 =
    /// PRECISION (a finger is a high-precision device), momentum bits 0 (`.none` — no momentum phase is
    /// modelled). One constant so the pan-to-scroll and the selection-drag edge autoscroll below can never
    /// come to describe the same finger differently. Per `Ghostty.Input.swift:438-465` (upstream) and the
    /// macOS `scrollWheel` override above.
    private static let kPrecisionScrollMods: ghostty_input_scroll_mods_t = 0b0000_0001

    /// Translates a finger drag → libghostty scroll delta. Mirrors the macOS `scrollWheel`
    /// override (same file): build the packed `ghostty_input_scroll_mods_t` and feed small
    /// per-event `deltaY` values to `surface.sendMouseScroll`.
    ///
    /// SIGN CONVENTION (matched to the HW-verified macOS `scrollWheel`): on macOS, a positive
    /// `event.scrollingDeltaY` (natural scrolling: two fingers move DOWN) reveals OLDER lines.
    /// On iOS, `UIPanGestureRecognizer.translation(in:).y` is POSITIVE when the finger moves
    /// DOWN the screen (UIView top-left origin, +y downward). So the incremental DOWNWARD
    /// translation maps DIRECTLY to a POSITIVE `deltaY` with NO inversion — dragging the content
    /// DOWN reveals older scrollback, exactly as the macOS path. (COORDINATES: scroll needs only
    /// DELTAS, not a position, so the iOS top-left vs. AppKit bottom-left origin difference — which
    /// would require a y-flip for `mouse_pos` — is irrelevant here; no coordinate conversion.)
    @objc private func handlePanToScroll(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastPanTranslationY = 0
        case .changed:
            // Incremental translation since the last event = cumulative − consumed (UIPan reports
            // CUMULATIVE translation). Feeding the delta (not the absolute) keeps small per-event
            // values flowing to libghostty, matching macOS `scrollingDeltaY` cadence.
            let cumulative = gesture.translation(in: self).y
            let deltaY = cumulative - lastPanTranslationY
            lastPanTranslationY = cumulative
            guard deltaY != 0 else { return }
            // SET THE CURSOR POSITION FIRST. For LOCAL scrollback the position is irrelevant (scroll
            // needs only deltas), but when a TUI has enabled mouse reporting (vim `set mouse=a`, tmux,
            // htop) libghostty encodes the wheel as an SGR mouse report carrying the CELL UNDER THE
            // CURSOR — and it reuses the LAST `mouse_pos`. iOS has no hover/tracking-area motion, so
            // without this the embedded apprt's cursor_pos stays at its initial (-1,-1) and the
            // out-of-viewport guard SUPPRESSES the wheel report (scroll silently dropped in mouse-mode
            // TUIs). macOS avoids this only because `mouseMoved`/`mouseEntered` keep cursor_pos fresh.
            // iOS is TOP-LEFT origin → NO y-flip (matching `handleTap`, unlike the macOS `surfacePoint`).
            let p = gesture.location(in: self)
            surface?.sendMousePos(x: Double(p.x), y: Double(p.y), mods: GHOSTTY_MODS_NONE)
            // Packed scroll mods (Int32: bit0 = precision, bits1-3 = momentum) — see
            // `kPrecisionScrollMods`. A finger-driven pan carries no momentum phase here, which is fine
            // for v1 (a future round could map the end-velocity to a momentum phase).
            surface?.sendMouseScroll(deltaX: 0, deltaY: Double(deltaY), mods: Self.kPrecisionScrollMods)
            // Drop the link snapshot, exactly as the macOS `scrollWheel` does and for the same reason: a
            // local scrollback scroll moves the viewport while bumping NO generation key, so the next
            // long-press hit-test would otherwise ask the pre-scroll rows what is under the finger.
            linkSnapshot.invalidate()
            // With the gated tick, scrollback frames must ARM their own present — on iOS
            // the tick is the only present pump (no macOS-style backing-layer display path).
            requestPresent(2)
        default:
            // .ended / .cancelled / .failed: nothing to flush (no momentum modeled in v1). The next
            // .began resets `lastPanTranslationY`, so no stale accumulation leaks across gestures.
            break
        }
    }

    /// Installs the tap-to-mouse-button recognizer on `self` (the renderer UIView). Idempotent —
    /// guarded like `installPanToScrollIfNeeded` so the idempotent `attach()` (re-run on every window
    /// entry) never stacks duplicate recognizers.
    ///
    /// COEXISTS with the pan recognizer above: a `UITapGestureRecognizer` recognizes a DISCRETE tap
    /// while the `UIPanGestureRecognizer` recognizes a DRAG, so they do not contend — UIKit's default
    /// tap-vs-pan handling means a tap does not fire while a pan is in progress, and no explicit
    /// `require(toFail:)` relationship is needed. KEYBOARD FOCUS is NOT this gesture's job: on iOS the
    /// keyboard is raised by tapping the SEPARATE input-bar sibling view (`TerminalInputHost`, doc 17
    /// §2.5) below the renderer, so a renderer tap is PURELY a mouse event — we do NOT call
    /// `becomeFirstResponder`/touch keyboard state here (that would fight `TerminalInputHost`).
    private func installTapIfNeeded() {
        guard tapRecognizer == nil else { return }
        isUserInteractionEnabled = true   // a passive renderer may default this off
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.numberOfTouchesRequired = 1
        addGestureRecognizer(tap)
        tapRecognizer = tap
    }

    /// Translates a finger tap → a libghostty position + left-button press/release pair. Mirrors the
    /// macOS `mouseDown`/`mouseUp` overrides (same file, lines ~699-719): position the cursor, then
    /// send `GHOSTTY_MOUSE_PRESS` and `GHOSTTY_MOUSE_RELEASE` for `GHOSTTY_MOUSE_LEFT`. libghostty
    /// owns the meaning (selection clear at the shell, click report in a mouse-mode TUI) off
    /// `mouse_captured`, so there is no gating here — same as the macOS path.
    ///
    /// COORDINATES: `recognizer.location(in: self)` is view-local POINTS with a TOP-LEFT origin
    /// (+y downward). iOS is ALREADY top-left, so — UNLIKE the macOS `surfacePoint` path which does
    /// `frame.height - pos.y` because AppKit is bottom-left — we pass the y straight through with NO
    /// flip. libghostty applies `contentScale` itself (points, not pixels), matching `sendMousePos`.
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        // A tap that lands while a touch SELECTION is live (or in the same event cycle as the release that
        // ended one) is that gesture's own touch-up, not a click: UIKit does not guarantee a tap fails just
        // because the finger rested long enough for the long press to fire, and forwarding a press+release
        // here would make libghostty clear the selection the user just made and drop the edit menu with it.
        // `touchSelectionActive` outlives the release by one runloop turn precisely to cover that cycle.
        guard !touchSelectionActive else { return }
        // A tap OUTSIDE the selection clears it — which is the Mac's behaviour and libghostty's own: the
        // press below lands at a fresh cell with click-count 1, which drops the standing selection. All we
        // owe is taking the menu down with it, since the thing it was offered for is about to be gone.
        editMenuInteraction?.dismissMenu()
        // FOCUS-ON-TAP: this gesture recognizer consumes the body tap that the SwiftUI leaf used to
        // drive workspace focus (`PaneTreeView .onTapGesture { store.focus(id) }`), so transfer focus
        // here exactly as the macOS `mouseDown` does (line ~706). `onRequestFocus` is wired
        // platform-agnostically by `wireFocusOnClick` (PaneTreeView) and `store.focus(id)` is
        // idempotent. Without this, tapping an unfocused pane's terminal body on iPad-regular
        // multi-pane no longer focuses it. (Keyboard focus stays owned by the input bar.)
        model?.onRequestFocus?()
        let loc = recognizer.location(in: self)   // view-local POINTS, top-left origin — no y-flip
        surface?.sendMousePos(x: Double(loc.x), y: Double(loc.y), mods: GHOSTTY_MODS_NONE)
        _ = surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS,   button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
        _ = surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
        // With the gated tick, gesture-driven content (selection clear / click report
        // redraw) must ARM its own present — on iOS the tick is the only present pump.
        requestPresent(2)
    }

    // MARK: Long-press-to-select (touch text selection + the edit menu)
    //
    // LONG PRESS → SELECT — the iOS counterpart of the macOS `mouseDown`/`mouseDragged`/`mouseUp` drag
    // selection and the `menu(for:)` context menu above. It is the SAME triple of libghostty calls: a
    // PRESS at the cell under the finger opens a selection, `sendMousePos` while the button is held
    // extends its head, and the RELEASE leaves it standing. libghostty owns everything that follows —
    // the selection state, its native painting, the granularity, and `readSelection()` — exactly as on
    // the Mac, where the AppKit view also only forwards. What differs is the ARMING, because a touch is
    // ambiguous until it has lasted long enough to say what it is; the numbers that resolve that
    // ambiguity are `SlopDeskClientCore.TerminalTouchSelection`, not literals typed in here.
    //
    // GRANULARITY: this anchors at the CELL under the finger, not at the word around it. libghostty
    // exposes no word-select door — the fork's slim delta
    // (`ThirdParty/ghostty/slopdesk-libghostty-on-v1.3.1.patch`) adds `set_selection` / `clear_selection`
    // / `viewport_info` / `line_range` and no word range, and `ghostty_surface_mouse_button` carries no
    // click count — so a word snap here would have to re-walk the row's cells, which is a second copy of
    // the walk `slopdesk_terminal::vimotion` already owns (`SlopDeskWorkspaceCore.ViLineMotion`, whose
    // `prev_word_start`/`word_end` doors are exactly the two this wants; they are `internal` today). A
    // DOUBLE TAP should already word-select without any of that — libghostty counts clicks from the
    // press TIMINGS on its own side (which is how a double-CLICK word-selects on the Mac through the
    // same forward-only path) and the tap recognizer above forwards a real press/release pair per tap —
    // but that is upstream behaviour read off the source, not something measured on this half.
    private var longPressRecognizer: UILongPressGestureRecognizer?

    /// The system edit menu (iOS 16+; this app's floor is iOS 26 — `Apps/ClientApp-iOS/project.yml`).
    /// It renders the SAME `TerminalContextMenu` table the Mac's `NSMenu` renders, with the same
    /// per-item enablement, so the two menus cannot come to offer different things.
    private var editMenuInteraction: UIEditMenuInteraction?

    /// Whether a long-press selection is live — set when the press is RECOGNIZED and cleared one runloop
    /// turn AFTER it ends. The trailing turn is what `handleTap` reads: the tap that fires from the same
    /// touch-up must not be forwarded as a click (see there). It also gates the pan
    /// (`gestureRecognizerShouldBegin`) so a selection drag never scrolls the viewport as well.
    private var touchSelectionActive = false

    /// Whether a left-button PRESS was forwarded for the live gesture and is still unmatched. The
    /// press/release balance guard this whole file keeps: a RELEASE that was never opened by a PRESS
    /// injects an unpaired report into a mouse-reporting TUI.
    private var selectionPressForwarded = false

    /// Bumped on every recognized long press, so the deferred `touchSelectionActive` clear can tell
    /// whether it is still clearing its OWN gesture (a newer press must not be un-armed by an older
    /// gesture's trailing hop).
    private var selectionGeneration = 0

    /// The last touch point of the live selection drag, view-local POINTS. Re-sent from `renderTick`
    /// while the edge autoscroll runs, so the selection head re-resolves against the content that
    /// scrolled under a finger that is holding still.
    private var selectionDragPoint: CGPoint = .zero

    /// Points of scroll to feed per display tick while the selection drag sits in an edge band; `0` when
    /// the finger is in the middle and nothing should scroll. Decided by
    /// ``TerminalTouchSelection/autoScrollDelta(y:viewHeight:)``.
    private var selectionAutoScroll: Double = 0

    /// Installs the long-press selection recognizer and the edit-menu interaction. Idempotent, like the
    /// pan/tap installers above, so the idempotent `attach()` never stacks duplicates.
    private func installLongPressToSelectIfNeeded() {
        guard longPressRecognizer == nil else { return }
        isUserInteractionEnabled = true
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressToSelect(_:)))
        press.minimumPressDuration = TerminalTouchSelection.longPressDuration
        press.allowableMovement = CGFloat(TerminalTouchSelection.longPressAllowableMovement)
        press.numberOfTouchesRequired = 1
        addGestureRecognizer(press)
        longPressRecognizer = press
        if editMenuInteraction == nil {
            let interaction = UIEditMenuInteraction(delegate: self)
            addInteraction(interaction)
            editMenuInteraction = interaction
        }
    }

    /// Translates the long press + its drag into libghostty's press / move / release selection triple.
    ///
    /// COORDINATES: view-local POINTS with a TOP-LEFT origin, passed straight through with NO y-flip —
    /// iOS is already top-left, unlike the macOS `surfacePoint` path. libghostty applies `contentScale`
    /// and resolves the cell itself, so there is no grid arithmetic on this path.
    @objc private func handleLongPressToSelect(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            // Same focus transfer the tap and the macOS `mouseDown` do: a gesture that lands in this
            // pane's body claims the pane. Idempotent, so it does not fight the reactive path.
            model?.onRequestFocus?()
            editMenuInteraction?.dismissMenu()   // a second press replaces the first menu, never stacks it
            pendingMenuLink = nil   // the last menu's link dies with the last menu
            selectionGeneration += 1
            touchSelectionActive = true
            selectionPressForwarded = true
            selectionDragPoint = point
            selectionAutoScroll = 0
            surface?.sendMousePos(x: Double(point.x), y: Double(point.y), mods: GHOSTTY_MODS_NONE)
            _ = surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
            // The one thing a phone owes that a pointer does not: the moment a press stops being a click
            // and becomes a selection is invisible, so it is felt instead. The system selection haptic is
            // the same one a text view fires at its own selection start.
            UISelectionFeedbackGenerator().selectionChanged()
            requestPresent(2)
        case .changed:
            selectionDragPoint = point
            // Edge autoscroll is ARMED here and PUMPED by `renderTick`: a finger held still at the edge
            // produces no further `.changed` events, so the tick is the only thing that can keep the
            // viewport moving under it.
            selectionAutoScroll = TerminalTouchSelection.autoScrollDelta(
                y: Double(point.y),
                viewHeight: Double(bounds.height),
            )
            surface?.sendMousePos(x: Double(point.x), y: Double(point.y), mods: GHOSTTY_MODS_NONE)
            requestPresent(2)
        case .ended,
             .cancelled,
             .failed:
            selectionAutoScroll = 0
            // Balance: forward the RELEASE only when this gesture actually forwarded the PRESS.
            if selectionPressForwarded {
                selectionPressForwarded = false
                _ = surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
                requestPresent(2)
            }
            // A cancelled gesture (a system gesture took the touch) is not a request for a menu.
            if gesture.state == .ended,
               TerminalTouchSelection.presentsMenuOnRelease(mouseCaptured: surface?.mouseCaptured ?? false) {
                // What the menu is being offered ON, resolved at the RELEASE point — the point the menu
                // itself is anchored to, and the Mac's `menu(for:)` reads exactly the location its menu
                // opens at. For the common press-and-lift this is the point the finger landed on anyway;
                // for a drag it is where the user finished looking. Stashed like the Mac's
                // `pendingMenuLink` because a `UIAction` closure fires long after the point is gone.
                pendingMenuLink = linkSnapshot.link(
                    at: (Double(point.x), Double(point.y)),
                    model: model,
                    surface: surface,
                    slop: TerminalTouchSelection.linkHitSlop,
                )
                editMenuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            }
            // Hold the flag across the current event cycle so the tap that UIKit may deliver from this
            // same touch-up is suppressed (see `handleTap`), then release it — but only if no NEWER press
            // has armed in the meantime.
            let generation = selectionGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionGeneration == generation else { return }
                touchSelectionActive = false
            }
        default:
            break
        }
    }

    // MARK: The edit menu's items (the SAME table the Mac's `menu(for:)` renders)

    /// The viewport's detected links + the hit-test, shared with the macOS half (see
    /// ``GhosttyLinkSnapshot``). Invalidated by everything that moves the viewport without bumping a
    /// generation key — the pan, the selection drag's edge autoscroll — and by `detach()`.
    private var linkSnapshot = GhosttyLinkSnapshot()

    /// The detected link the CURRENT edit menu was offered on, resolved at the long press's release point
    /// and stashed for the `UIAction` closures that fire after it. The twin of the Mac's `pendingMenuLink`,
    /// and one slot suffices for the same reason: a menu is modal-per-view.
    private var pendingMenuLink: DetectedLink?

    /// The menu, built from the PURE ``TerminalContextMenu`` — same items, same order, same enablement
    /// rule, same SF Symbols. The Mac renders this table as an `NSMenu`; this renders it as a `UIMenu`.
    /// The system's `suggestedActions` are deliberately DROPPED: they are the responder chain's
    /// Copy/Paste over a `UITextInput` this view is not, and offering both would put two Copies with
    /// different meanings in one menu.
    ///
    /// A press that landed ON a detected path / URL PREPENDS that link's items — the same set from the
    /// same ``TerminalContextMenu/linkItems(for:)``, so the two halves cannot come to offer different
    /// things about a link either. The Mac separates them from the standard items with an `NSMenuItem`
    /// rule; here they are the first inline group, which is what UIKit draws a rule between. Layout
    /// differs, the offer does not.
    private func terminalMenuElements() -> [UIMenuElement] {
        let ctx = TerminalContextMenu.Context(
            hasSelection: surface?.hasSelection() ?? false,
            clipboardHasText: !(ClientPasteboard.text()?.isEmpty ?? true),
            paneConnected: true,
            // WB2: "Copy Command Output" is enabled when this pane has at least one completed block.
            hasCommandOutput: model?.blocks.latest?.complete ?? false,
        )
        // `Item.separatorBefore` opens a new GROUP; UIKit draws a group as an inline submenu, which is
        // the rule an `NSMenuItem.separator()` draws on the Mac. Same table, each framework's own rule.
        // Group 0 is the link items — EMPTY for a press over no link, and the `filter` at the end drops an
        // empty group, so there is no rule over nothing.
        var groups: [[UIMenuElement]] = [linkMenuActions(), []]
        for item in TerminalContextMenu.items {
            if item.separatorBefore { groups.append([]) }
            groups[groups.count - 1].append(menuAction(for: item, context: ctx))
            // The "Paste as…" submenu sits directly below Paste, exactly where the Mac's NSMenu puts it.
            if item == .paste {
                let variants = TerminalContextMenu.pasteAsItems.map { menuAction(for: $0, context: ctx) }
                groups[groups.count - 1].append(
                    UIMenu(
                        title: TerminalContextMenu.pasteAsSubmenuTitle,
                        image: UIImage(systemName: TerminalContextMenu.Item.paste.symbol),
                        children: variants,
                    ),
                )
            }
        }
        return groups.filter { !$0.isEmpty }.map { UIMenu(title: "", options: .displayInline, children: $0) }
    }

    /// One item as a `UIAction`, greyed by the SAME unit-tested rule the Mac greys by
    /// (`TerminalContextMenu.isEnabled`) rather than by anything this view knows.
    private func menuAction(for item: TerminalContextMenu.Item, context: TerminalContextMenu.Context) -> UIAction {
        let enabled = TerminalContextMenu.isEnabled(item, context: context)
        return UIAction(
            title: item.title,
            image: UIImage(systemName: item.symbol),
            attributes: enabled ? [] : .disabled,
        ) { [weak self] _ in
            self?.performContextMenuItem(item)
        }
    }

    /// The link items for the press's ``pendingMenuLink`` — Open / Copy Path (Copy URL) / Reveal in Finder /
    /// Change Directory Here for a path, Open Link / Copy URL for a URL — or NOTHING when the press landed
    /// on no link, which is most presses.
    ///
    /// Which items a kind offers is ``TerminalContextMenu/linkItems(for:)``'s answer and what each one DOES
    /// is ``LinkActionPolicy``'s, both pure and both already shared with the Mac; the actuation is
    /// ``LinkActionActuator``, which is now the one dispatch for a resolved ``LinkAction`` anywhere in the
    /// app. So the whole of this half's link feature is the hit-test above plus these labels.
    private func linkMenuActions() -> [UIMenuElement] {
        guard let link = pendingMenuLink else { return [] }
        return TerminalContextMenu.linkItems(for: link.kind).map { item in
            UIAction(
                title: item.title(for: link.kind),
                image: UIImage(systemName: item.symbol),
            ) { [weak self] _ in
                guard let self else { return }
                LinkActionActuator.actuate(LinkActionPolicy.action(for: item, link: link), model: model)
                // `cd` types into the grid and a copy draws the pane's copy chip; the others reach the host.
                // Arming a present unconditionally is cheaper than getting that list right.
                requestPresent(3)
            }
        }
    }

    /// Actuates a chosen item — the iOS twin of the macOS `contextMenuAction(_:)`. The two switches are
    /// the same shape over the same enum because the ACTUATION is what differs between the halves and
    /// nothing else: a binding action is a binding action, but a clipboard is `UIPasteboard` here and an
    /// `NSPasteboard` there, and a file is picked with a `UIDocumentPickerViewController` rather than an
    /// `NSOpenPanel`. The clipboard reads/writes go through ``ClientPasteboard`` — the one funnel that
    /// already knows which board to touch on each platform (and under XCTest).
    private func performContextMenuItem(_ item: TerminalContextMenu.Item) {
        switch item {
        case .copy: surface?.performBindingAction("copy_to_clipboard")
        case .cut: performCut()   // copy the selection + (editable prompt only) delete it
        case .paste: requestPaste()   // paste-protection pre-check, then libghostty's bracketed paste
        case .pasteAsKeystrokes:
            // Type the pasteboard string as raw keystrokes (no bracketed-paste) — the "paste literally"
            // affordance for TUIs that swallow bracketed paste.
            if let text = ClientPasteboard.text(), !text.isEmpty { surface?.text(text) }
        case .pasteSelection:
            // X11 middle-click convention: type the current SELECTION rather than the clipboard.
            if let selection = surface?.readSelection(), !selection.isEmpty { surface?.text(selection) }
        case .pasteFileBase64:
            pasteFileAsBase64()
        case .pasteEscaped:
            if let text = ClientPasteboard.text(), !text.isEmpty { surface?.text(PasteTransform.shellEscaped(text)) }
        case .pasteBracketed:
            if let text = ClientPasteboard.text(), !text.isEmpty { surface?.text(PasteTransform.bracketed(text)) }
        case .selectAll: surface?.performBindingAction("select_all")
        case .clear: surface?.performBindingAction("clear_screen")
        case .copyOutput:
            // WB2: copy the LATEST completed command block's output. The model requests it (wire type 15),
            // strips VT control sequences, and resolves an empty/unavailable reply as a graceful no-op.
            if let index = model?.blocks.latest?.index {
                model?.copyBlockOutput(index: index) { text in
                    guard let text, !text.isEmpty else { return }
                    ClientPasteboard.write(text)
                }
            }
        case .splitRight: model?.onContextMenuSplit?(true)
        case .splitDown: model?.onContextMenuSplit?(false)
        case .find: model?.onRequestFind?()
        }
        // Every arm above either repaints the grid (a cleared selection, a cleared screen, typed bytes)
        // or does not — arming a present unconditionally is cheaper than getting the list wrong, and on
        // iOS the gated tick is the only present pump.
        requestPresent(3)
    }

    /// Cut — the iOS twin of the macOS `performCut()`, over the SAME pure ``CutSelectionPolicy``: always
    /// copy the selection, and delete it only at an editable prompt. The delete half carries the same
    /// GEOMETRY CEILING as the Mac's (`selectionEndsAtCursor: false` against the pinned fork ⇒ a 0 DEL
    /// count ⇒ the cut degrades to copy-only) rather than risk deleting the wrong characters.
    private func performCut() {
        guard let surface else { return }
        let action = CutSelectionPolicy.action(
            hasSelection: surface.hasSelection(),
            isAlternateScreen: model?.isAlternateScreen ?? false,
            isPromptZone: (model?.connectionStatus.isLive ?? false)
                && model?.shellActivity == .idle
                && !(model?.isAlternateScreen ?? false),
        )
        guard action != .none else { return }
        surface.performBindingAction("copy_to_clipboard")
        guard action == .copyAndDelete else { return }
        let count = CutSelectionPolicy.deleteCount(
            selection: surface.readSelection() ?? "",
            selectionEndsAtCursor: false,
        )
        if count > 0 { model?.sendInput(Data(repeating: 0x7F, count: count)) }
    }

    /// Paste — the iOS twin of the macOS `requestPaste()`. It runs the paste-protection pre-check BEFORE
    /// handing the bytes to libghostty, because libghostty's own `isSafe` gate is NARROWER than this
    /// pre-check's four dangers: a single-line `sudo`, an ESC-laced control-char paste or a bare-`\r`
    /// paste would otherwise reach the shell silently. On a danger the question goes to the human through
    /// ``slopdeskPresentClipboardConfirm`` — the ONE platform seam in the clipboard gates, which on this
    /// half files into `ClipboardConfirmRequests` for the mounted card to drain. Only on approve do we
    /// paste, with the one-shot `allow_unsafe` flags so libghostty's own gate is not re-tripped into a
    /// SECOND dialog; a safe payload pastes straight through, still bracketed by libghostty.
    private func requestPaste() {
        guard let surface else { return }
        let clipboard = ClientPasteboard.text() ?? ""
        let decision = PastePrecheck.decide(
            clipboard: clipboard,
            protectionOn: SettingsKey.pasteProtectionEnabled,
            // The REAL alt-screen flag (DECSET 1049/47/1047 via the client `TerminalModeTracker`), not the
            // `.running` proxy: a single-line `sudo` pasted into a non-TUI foreground command must trip.
            isAlternateScreen: model?.isAlternateScreen ?? false,
            bracketedSafe: SettingsKey.pasteBracketedSafeEnabled,
            programAdvertisedBracketed: model?.isBracketedPasteActive ?? false,
        )
        switch decision {
        case .pasteDirect:
            surface.performBindingAction("paste_from_clipboard")   // libghostty applies bracketed-paste
        case let .confirm(dangers):
            slopdeskPresentClipboardConfirm(ask: .unsafePaste, preview: clipboard, dangers: dangers) { [weak self] pasteAnyway in
                guard pasteAnyway, let self, let surface = self.surface else { return }
                // Capture the REVIEWED text so the read returns the exact snapshot the user approved (not
                // a fresh — and possibly swapped — pasteboard read). Both flags are cleared right after
                // the SYNCHRONOUS binding-action read so they can never leak into a later one.
                surface.pasteApprovedOnce = true
                surface.approvedPasteText = clipboard
                surface.performBindingAction("paste_from_clipboard")
                surface.pasteApprovedOnce = false
                surface.approvedPasteText = nil
                requestPresent(3)
            }
        }
        requestPresent(3)
    }

    /// "Paste File Base64-Encoded…" — the iOS twin of the macOS `pasteFileAsBase64()`. Reads the bytes
    /// DEFENSIVELY (a cancelled picker, a missing URL or an unreadable file is a silent no-op, never a
    /// crash) and encodes them with the same unit-tested `PasteTransform.base64`. `asCopy: true` hands
    /// back a URL inside this app's own container, so there is no security-scoped resource to balance.
    private func pasteFileAsBase64() {
        guard let presenter = nearestViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    /// The nearest view controller up the responder chain — what UIKit needs to present anything from a
    /// view the canvas adds as a subview, which owns no controller of its own.
    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    // MARK: Keyboard-focus reclaim (the iOS half of `onReclaimKeyboardFocus`)

    /// Re-take the pane's keyboard after a surface that stole it closed (the ⌘F find bar, an overlay).
    ///
    /// The Mac calls `makeFirstResponder(self)` because on that half the renderer IS the key responder.
    /// Here it is not: the pane's responder is `SlopDeskPhoneUI.TerminalInputHostView`, a zero-sized
    /// sibling mounted beside this view by `TerminalLeafView` (doc 17 §2.5). It conforms to the PUBLIC
    /// ``PaneFocusCoordinator/FocusableInputHost``, which is how this view re-claims without importing
    /// the phone's UI target — and the search is deliberately the SMALLEST ancestor subtree that holds
    /// exactly ONE host, so on iPad-regular (several panes mounted at once) it can only ever find its
    /// own pane's, and an ambiguous level yields nothing rather than stealing another pane's keyboard.
    ///
    /// The RIGHT call is `PaneFocusCoordinator.reassertFocus(_:)` — a fresh generation, resign-before-
    /// become, the whole arbitration — but it is keyed by `PaneID`, and neither this view nor
    /// ``TerminalViewModel`` carries one. Binding it belongs where the pane's id and the store are both
    /// in hand (`SlopDeskClientCore/Pane/TerminalPaneWiring.swift`); this is the local re-claim until
    /// then, and it is a RE-take of a focus this pane already holds, so it crosses no other pane.
    private func reclaimPaneKeyboardFocus() {
        paneInputHost()?.becomeFocus()
    }

    private func paneInputHost() -> PaneFocusCoordinator.FocusableInputHost? {
        var ancestor: UIView? = superview
        while let view = ancestor {
            let hosts = Self.focusableInputHosts(in: view)
            if hosts.count > 1 { return nil }   // this level already spans other panes — never steal
            if let host = hosts.first { return host }
            ancestor = view.superview
        }
        return nil
    }

    private static func focusableInputHosts(in view: UIView) -> [PaneFocusCoordinator.FocusableInputHost] {
        var found: [PaneFocusCoordinator.FocusableInputHost] = []
        if let host = view as? PaneFocusCoordinator.FocusableInputHost { found.append(host) }
        for subview in view.subviews { found.append(contentsOf: focusableInputHosts(in: subview)) }
        return found
    }

    /// The surface is created ONLY once the view is in a real window — never in the window the seam's
    /// factory hands one back from, which is nobody's yet (mirrors the macOS `viewDidMoveToWindow`):
    /// `ghostty_surface_new` spawns libghostty's renderer/io threads, and a duplicate would also steal
    /// `model.surface` from the on-screen pane. Leaving the window invalidates the display link so a
    /// detached view never keeps a 60Hz main-runloop wakeup alive (`detachSurface()` is the explicit
    /// teardown, but a discarded view is not guaranteed to get one).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if let model { attach(model: model) }
            startRenderTickIfNeeded()
            requestPresent(8)   // prime the initial glyph flush
        } else {
            displayLink?.invalidate()   // off-window: stop ticking so a detached view never spins
            displayLink = nil
        }
    }

    /// Idempotent: builds the surface on first call (only when on-window), then attaches it to the
    /// model. `didMoveToWindow` is its ONLY caller now that no representable re-runs an update pass, and
    /// it stays safe to call repeatedly — a view can leave and re-enter a window.
    func attach(model: TerminalViewModel) {
        self.model = model
        // The EDITING VERBS, reachable from something other than a long press. `TerminalInputHost`
        // registers ⌘C/⌘X/⌘V/⌘A as key commands — it has to, because on this platform the pane's
        // first responder is a zero-sized sibling of this view, so AppKit's trick of the terminal
        // BEING the responder does not carry over and the four chords reached nothing at all. What it
        // must not do is implement them: everything about running one (the paste pre-check, cut's
        // editable-prompt policy, `select_all`) is already here, one switch, for the menu. So the
        // chord names a verb and this line is where the verb is actuated. Weak, and set before the
        // off-window return: a probe view never spawns a surface but its model still deserves a live
        // sink, and a torn-down view leaves a closure that answers nothing rather than a dangling one.
        model.onRequestMenuItem = { [weak self] item in self?.performContextMenuItem(item) }
        guard window != nil else { return }   // never spawn a surface for the off-window probe view
        installPanToScrollIfNeeded()
        installTapIfNeeded()
        installLongPressToSelectIfNeeded()
        if surface == nil {
            let scale = window?.screen.scale ?? UIScreen.main.scale
            let s = GhosttySurface(
                app: GhosttyApp.shared.app,
                platformView: Unmanaged.passUnretained(self).toOpaque(),
                cols: 80,
                rows: 24,
                contentScale: Double(scale)
            )
            // OUT path: libghostty-encoded keystrokes → model sink → live SlopDeskClient.
            // On iOS the physical-key/IME forwarding is owned by `TerminalInputHost`
            // (doc 17 §2.5), but routing onWrite here too is harmless+correct: it carries
            // whatever the surface itself encodes, and the model sink is the single funnel.
            s.onWrite = { [weak model] (data: Data) in
                model?.sendInput(data)
            }
            s.onResize = { [weak model] (cols: UInt16, rows: UInt16) in
                model?.sendResize(cols: cols, rows: rows)
            }
            // Dirty signal → gated tick (the macOS wiring, previously MISSING on iOS:
            // feed's content signal was dropped and only the free-running tick presented).
            s.onContentChanged = { [weak self] in self?.requestPresent() }
            // A landed Copy / OSC-52 STANDARD-clipboard write → the pane's transient `COPIED · N` receipt
            // chip, which the phone draws in its island (`SlopDeskPhoneUI/Pane/IslandChipStackView.swift`)
            // and which stayed dark on this half only because nothing observed the write. libghostty owns
            // the write; this is the one point that sees the text.
            s.onClipboardWrite = { [weak model] text in model?.noteClipboardCopy(text) }
            // The libghostty-INITIATED paste backstop (`slopdeskConfirmUnsafePaste`) reads the REAL
            // alt-screen flag through this hook, so it suppresses inside a true full-screen TUI exactly as
            // the menu's own `requestPaste` pre-check does. Unset, it read a hardcoded `false` here.
            s.isAlternateScreen = { [weak model] in model?.isAlternateScreen ?? false }
            // Viewport-scroll echo → the prompt-jump landed-flash SETTLE signal, byte-for-byte the
            // macOS binding above (`GHOSTTY_ACTION_SCROLLBAR` is a libghostty RENDERER signal, not an
            // AppKit event — the shared `action_cb` already delivers it on this half; only the closure
            // was missing). Without it `noteViewportScroll` had no caller on this platform at all: the
            // phone's Command Navigator ARMS a jump through the same cross-platform store verbs
            // (`WorkspaceStore+Blocks`), the 400ms settle window then lapsed in silence,
            // `promptJumpFlashEpoch` never moved, and `PromptJumpFlashOverlay` — mounted
            // unconditionally in `TerminalLeafView` — could not light. An overlay that renders on both
            // halves and is driven on one is the shape this file has now stopped twice.
            s.onScrollbarChange = { [weak model] offset, length, total in
                let end = offset.addingReportingOverflow(length)
                let atBottom = end.overflow || end.partialValue >= total
                model?.noteViewportScroll(atBottom: atBottom)
            }
            self.surface = s
            // A BRAND-NEW surface must get its first real layout — drop the same-size cache.
            lastAppliedLayout = nil
        }
        // attachSurface(_:) (not `model.surface = surface`) so the model REPLAYS its retained
        // byte-ring into a rebuilt surface — the iOS compact-carousel flip dismantles + rebuilds
        // the representable EMPTY while the connection (and host scrollback) is untouched. No-op
        // replay when the instance is unchanged.
        if let surface {
            model.attachSurface(surface)
        }
        // Render focus follows the workspace focus (not always-on): focused = solid block cursor, unfocused
        // = ghostty's hollow non-blinking cursor. Unfocused panes still repaint via the content-driven
        // present path, so this never freezes them (the didSet re-forwards on every focus change).
        // Seed `lastForwardedFocus` so the coalesced `forwardRenderFocus` dedupes against the value set here.
        lastForwardedFocus = isFocusedPane
        surface?.setFocus(isFocusedPane)
        // Resize-END → present the REFLOWED frame. The macOS sibling binds this at line ~1066 and this
        // half did not, so a pane resize could settle on an unpainted frame: the final layout pass often
        // hits the same-size guard and arms NO present at all, and libghostty's own reflow produces no
        // bytes, so nothing repainted until the next output byte arrived. Unlike the Mac this needs no
        // settle BURST — the macOS burst exists because its async present path is size-discarded, while
        // here `renderTick`'s `drawNow` is size-unconditional and the host's late SIGWINCH redraw bytes
        // arm their own present through `onContentChanged`. 8 ticks covers the renderer thread finishing
        // the reflow (~130ms), which is the one frame that has no other pump. Set on the MODEL each
        // attach; a stale prior view's `[weak self]` closure no-ops once overwritten.
        model.onResizeSettled = { [weak self] in self?.requestPresent(8) }
        // The find bar / an overlay closing tears down a focused field WITHOUT a workspace-focus change,
        // so none of the pane's own focus paths fire and the pane stays deaf. Its two live callers are
        // `SlopDeskPhoneUI/Overlays/PhoneOverlayCardHost.swift` and
        // `SlopDeskClientCore/Pane/TerminalFindBarModel.swift`, both of which reach `reclaimKeyboardFocus()`
        // on the model; on this half the responder is the input host beside us, not this view.
        model.onReclaimKeyboardFocus = { [weak self] in self?.reclaimPaneKeyboardFocus() }
        requestPresent(8)   // prime the initial glyph flush / flush the replay (mirrors macOS)
    }

    /// Starts the render-thread pacing tick (idempotent, window-gated — mirrors the macOS
    /// `startRenderTickIfNeeded`). 60 fps is plenty for a terminal; on device the tick is
    /// `presentTicks`-gated and pauses itself when drained, so idle costs nothing.
    private func startRenderTickIfNeeded() {
        guard displayLink == nil, window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(renderTick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func renderTick() {
        // EDGE AUTOSCROLL for a live selection drag. It is pumped HERE rather than from the gesture
        // because a finger held at the edge produces no further `.changed` events — the tick is the only
        // thing still running. Same call the pan-to-scroll uses, so libghostty decides what a scroll
        // means exactly as it does there; the `sendMousePos` after it re-resolves the selection head
        // against the content that just moved under a stationary finger. The `requestPresent` keeps the
        // link un-paused for as long as the drag holds an edge, and the drag ending zeroes the delta.
        if selectionAutoScroll != 0, let surface {
            surface.sendMouseScroll(deltaX: 0, deltaY: selectionAutoScroll, mods: Self.kPrecisionScrollMods)
            surface.sendMousePos(
                x: Double(selectionDragPoint.x),
                y: Double(selectionDragPoint.y),
                mods: GHOSTTY_MODS_NONE,
            )
            // Same reason as the pan: this scroll moves the viewport and bumps no generation key, and the
            // release that ends this very drag is what asks the snapshot which link the menu is for.
            linkSnapshot.invalidate()
            requestPresent(2)
        }
        #if targetEnvironment(simulator)
        // Simulator: keep the free-run — the renderer thread's libxev wakeup pump is
        // unreliable there (patch 0001 forensics) and the steady drawNow papers over it.
        surface?.drawNow()
        #else
        // Device: GATED. Idle ticks stop signalling the renderer thread (60Hz cross-thread
        // wakeup + mutex churn per pane, even fully idle). KEEP drawNow when armed — the
        // macOS setNeedsDisplay/displayIfNeeded present path does not exist on iOS (the
        // IOSurfaceLayer is an unwired SUBLAYER here).
        guard presentTicks > 0 else {
            // Ticks drained → PAUSE the link entirely (the macOS renderTick pattern): an idle
            // pane stops costing even the 60Hz main-runloop wakeup of a no-op tick.
            // `requestPresent` (the single arming choke point) un-pauses.
            displayLink?.isPaused = true
            return
        }
        presentTicks -= 1
        surface?.drawNow()
        #endif
    }

    func detach() {
        displayLink?.invalidate()
        displayLink = nil
        lastAppliedLayout = nil   // a future re-attach must re-apply size unconditionally
        // Remove the pan-to-scroll recognizer we installed (symmetric with `installPanToScrollIfNeeded`).
        if let pan = panRecognizer {
            removeGestureRecognizer(pan)
            panRecognizer = nil
        }
        // Remove the tap-to-mouse-button recognizer we installed (symmetric with `installTapIfNeeded`).
        if let tap = tapRecognizer {
            removeGestureRecognizer(tap)
            tapRecognizer = nil
        }
        // Remove the long-press selection recognizer + the edit-menu interaction (symmetric with
        // `installLongPressToSelectIfNeeded`), and drop the gesture's own state so a re-attached view can
        // never forward a RELEASE for a PRESS the previous life sent.
        if let press = longPressRecognizer {
            removeGestureRecognizer(press)
            longPressRecognizer = nil
        }
        if let interaction = editMenuInteraction {
            interaction.dismissMenu()
            removeInteraction(interaction)
            editMenuInteraction = nil
        }
        touchSelectionActive = false
        selectionPressForwarded = false
        selectionAutoScroll = 0
        pendingMenuLink = nil
        linkSnapshot.invalidate()   // the snapshot belongs to the closing surface's viewport
        let detaching = surface
        surface = nil
        detaching?.close()
        // Identity-gated detach (see the macOS sibling): a stale duplicate view's detach must not nil
        // the live surface the model is still feeding. A surface-LESS view (an off-window probe that
        // never attached) makes NO call at all — `detachSurface(nil)` takes the unconditional
        // else-branch and clears the LIVE pane's surface, freezing the visible terminal.
        if let detaching {
            model?.detachSurface(detaching)
            // The two sinks bound in `attach` come down under the SAME identity gate, one level further
            // on: `detachSurface` clears `model.surface` only when the surface it held was OURS, so a nil
            // surface here proves no newer view has taken this pane over and the closures are still this
            // view's to clear. Clearing them unconditionally would strand a LIVE pane deaf whenever the
            // canvas mounts the replacement before detaching us — the same stale-duplicate hazard the
            // gate above exists for. (Both are `[weak self]`, so one left standing is inert either way.)
            if model?.surface == nil {
                model?.onResizeSettled = nil
                model?.onReclaimKeyboardFocus = nil
            }
        }
    }

    /// The last (bounds.size, scale) actually APPLIED to a live surface — the iOS mirror of
    /// the macOS `lastAppliedLayout` same-size guard (see that doc comment). Invalidated on
    /// surface creation (`attach`) and `detach`.
    private var lastAppliedLayout: (size: CGSize, scale: CGFloat)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        // SAME-SIZE GUARD (mirrors macOS layout()): spurious same-size UIKit layout passes used
        // to pay sublayer re-framing + setPixelSize + a full synchronous redraw.
        if let last = lastAppliedLayout, last.size == bounds.size, last.scale == scale,
           surface != nil {
            return
        }
        metalLayer.contentsScale = scale
        // CRITICAL (iOS): libghostty renders into an `IOSurfaceLayer` it adds as a
        // SUBLAYER of this view's layer (`Metal.zig` `addSublayer:`) — and it NEVER sizes
        // that sublayer. UIKit does not auto-resize a manually-added sublayer, so it stays
        // 0×0; `drawFrame()` then reads `bounds × contentsScale == 0` and silently
        // early-returns (renderer/generic.zig zero-size guard) → blank screen, no error.
        // (macOS works because libghostty makes its layer the view's *backing* layer,
        // which AppKit auto-sizes.) Size every sublayer to our bounds + scale.
        //
        // FLAT PANE design (iOS): NO corner radius; `masksToBounds = true` clips the
        // Metal sublayer to the exact bounds RECTANGLE. Matches the macOS clip in
        // GhosttyLayerBackedView.layout().
        layer.cornerRadius = 0
        layer.masksToBounds = true
        layer.sublayers?.forEach { sub in
            sub.frame = bounds
            sub.contentsScale = scale
        }
        let pxW = UInt32(max(1, Int((bounds.width * scale).rounded())))
        let pxH = UInt32(max(1, Int((bounds.height * scale).rounded())))
        surface?.setContentScale(Double(scale))
        // Pass ACTUAL layer pixels; libghostty derives the grid + fires resize_callback.
        surface?.setPixelSize(widthPx: pxW, heightPx: pxH)
        surface?.redraw()
        // A real size change → present the reflowed frame (the gated tick needs arming).
        requestPresent(3)
        if surface != nil {
            lastAppliedLayout = (bounds.size, scale)
        }
    }
}

// MARK: - Gesture arbitration (the pan yields to a live selection)

extension GhosttyLayerBackedView: UIGestureRecognizerDelegate {
    /// The pan-to-scroll recognizer may NOT begin while a long-press selection is live: a finger moving
    /// across the grid then means "extend the selection", and scrolling the viewport under it as well
    /// would drag the selection head across content that is itself moving. Every other recognizer is
    /// untouched — this delegate answers only for the pan it is installed on.
    ///
    /// `override`, not a bare conformance: `UIView` already answers this one, and the answer it gives
    /// (`true`) is the one every OTHER recognizer on this view must keep getting.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panRecognizer else { return true }
        return !touchSelectionActive
    }
}

// MARK: - The edit menu

// `@preconcurrency`: unlike `UIDocumentPickerDelegate` below, this protocol is not annotated `@MainActor`
// in the SDK, so a plain conformance from a `UIView` (which is) is a concurrency error rather than a
// promise anyone has to keep. UIKit only ever calls it on the main thread.
extension GhosttyLayerBackedView: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement],
    ) -> UIMenu? {
        UIMenu(title: "", children: terminalMenuElements())
    }
}

// MARK: - "Paste File Base64-Encoded…"

extension GhosttyLayerBackedView: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // DEFENSIVE, like the macOS `NSOpenPanel` twin: no URL, or bytes that will not read, is a silent
        // no-op rather than a crash. The encoding is the unit-tested `PasteTransform.base64`.
        guard let url = urls.first, let bytes = try? Data(contentsOf: url) else { return }
        let encoded = PasteTransform.base64(ofFileBytes: bytes)
        guard !encoded.isEmpty else { return }
        surface?.text(encoded)
        requestPresent(3)
    }
}

// MARK: - The terminal pixel seam (docs/56 stage F, risk 2)

/// The phone's half of the seam, and the reason the seam has ONE slot instead of two.
///
/// The Mac's `GhosttyLayerBackedView` has conformed to ``TerminalSurfaceHosting`` since the seam grew its
/// platform slot; this one could not, because the seam's other slot was a SwiftUI `AnyView` and the stated
/// premise was that the phone had no view class to hand back — "iOS's ONLY shape". UIKit made that false
/// (docs/62): the phone's canvas is a view controller adding subviews, so a `UIView` is exactly what it
/// wants. Both platforms now cross the same way, through the same three members.
extension GhosttyLayerBackedView: TerminalSurfaceHosting {
    var surfaceView: UIView { self }

    func setPaneFocused(_ isFocused: Bool) { isFocusedPane = isFocused }

    func detachSurface() { detach() }
}

#endif  // os(macOS) / os(iOS)

// MARK: - The one registration site

/// Registers the production terminal renderer — ONE slot, one assignment, both platforms.
///
/// ⚠️ THIS USED TO REGISTER TWO SLOTS AND ARGUE FOR BOTH. `shared` handed back a SwiftUI `AnyView`
/// wrapping `GhosttyTerminalView`, `nativeShared` handed back this same `GhosttyLayerBackedView`, and the
/// installer existed so an app target could not register half of the pair. Both slots were justified by one
/// premise — the phone had no `NSView`, so iOS could only ever cross the seam as a `View` — and the phone's
/// move to UIKit (docs/62) falsified it: it has a `UIView`, and its canvas is a view controller that adds
/// subviews. So the SwiftUI slot, the struct behind it and both representables are deleted rather than kept
/// as a second way in. What the fold removes is not a wrapper type but a HOSTING VIEW over the one surface
/// that must take every keystroke — the hit-claim docs/56 stage D spent five increments getting off the
/// Mac, which the SwiftUI slot would have rebuilt verbatim on the phone.
///
/// The failure this installer guards has not changed, and is now impossible to half-do: REGISTERING
/// NOTHING. An unregistered seam ships the BUILD-STATUS placeholder where the terminal should be.
///
/// ⚠️ This file is compiled by NO `Package.swift` target — it joins the Xcode app target through
/// `slopdesk-ops enable-renderer macos` / `… ios`, and the whole file
/// is behind `#if canImport(CGhostty)`. A grep over `Sources/` and `Tests/` reads every symbol here as
/// dead, and none of it is (docs/56 stage F risk 2's corollary; increment 45b's lesson). The only callers
/// are `Apps/ClientApp-macOS/AppMain.swift` and `Apps/ClientApp-iOS/AppMain.swift`.
public enum GhosttyRendererSeam {
    /// Idempotent — safe to call more than once, and it must stay so: it is called from `main()` before the
    /// scene exists, which is the only ordering the seam guarantees.
    ///
    /// The closure hands the canvas the layer-hosting view itself (`GhosttyLayerBackedView`, an `NSView` on
    /// the Mac and a `UIView` on the phone, both ``TerminalSurfaceHosting``). There is no `#if` here: one
    /// spelling covers both platforms, which is the whole point of the fold.
    @MainActor
    public static func install() {
        TerminalRendererFactory.shared = { model, isFocused in
            let view = GhosttyLayerBackedView()
            // Do NOT create the surface here. `ghostty_surface_new` installs the IOSurfaceLayer and spawns
            // the renderer/io thread pair, so a view that is built and then never put in a window would
            // leave a second surface spinning. The surface is created lazily in
            // `viewDidMoveToWindow`/`didMoveToWindow`, so exactly one exists per pane.
            view.model = model
            // The pane's focus at MOUNT time; every later change arrives via `setPaneFocused(_:)`, since an
            // imperative canvas has no update pass to carry it.
            view.isFocusedPane = isFocused
            return view
        }
    }
}

#endif  // canImport(CGhostty)

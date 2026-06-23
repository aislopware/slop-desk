//
//  GhosttyTerminalView.swift
//  Aislopdesk — the SwiftUI host for the ONLY terminal renderer (libghostty-only).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THIS FILE IS DELIBERATELY OUTSIDE THE DEFAULT `swift build` GRAPH.
//  ─────────────────────────────────────────────────────────────────────────────
//  It is the production `TerminalRenderingView` conformer named in
//  `Sources/AislopdeskClientUI/Terminal/TerminalRenderingView.swift` (the documented
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
//  which holds the live `AislopdeskClient`) points at `AislopdeskClient.sendInput`/`sendResize`
//  on connect and clears on teardown. Going through the MODEL (not `model.surface
//  .onWrite` directly) decouples view-attach timing from connect timing — whichever
//  happens first, the sink is read at call time. NOW WIRED (was the remaining seam in
//  docs/21-HANDOFF.md).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THREADING (doc 18 §C — libghostty calls are main-thread-only)
//  ─────────────────────────────────────────────────────────────────────────────
//  `GhosttySurface` is `@MainActor`, and SwiftUI representable callbacks + the
//  Metal layer view run on the main thread, so every surface call below is on main.
//  We never `await` between write_output → refresh → draw (the binding keeps that
//  trio synchronous inside `feed`).
//

#if canImport(CGhostty)

import SwiftUI
import QuartzCore          // CAMetalLayer
import AislopdeskTerminal       // TerminalSurface protocol
import AislopdeskWorkspaceCore  // TerminalRenderingView, TerminalViewModel, TerminalRendererFactory (L0 home)
import CGhostty            // the clang module over ghostty.h (link "ghostty")

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Process-wide libghostty app handle

#if os(macOS)
/// Maps a libghostty clipboard `location` to its NSPasteboard. `STANDARD` is the real system
/// clipboard; `SELECTION` is a PRIVATE pasteboard (mirrors upstream `NSPasteboard.ghostty(_:)`) so
/// libghostty's default-ON copy-on-select does NOT clobber the user's system clipboard on every
/// drag-select — only an explicit Cmd-C / `copy_to_clipboard` (STANDARD) touches `.general`.
@inline(__always) func aislopdeskPasteboard(for location: ghostty_clipboard_e) -> NSPasteboard {
    location == GHOSTTY_CLIPBOARD_SELECTION
        ? NSPasteboard(name: NSPasteboard.Name("com.aislopdesk.terminal.selection"))
        : .general
}
#endif

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
    /// `ghostty_app_update_config` (header 1153) which reflows all surfaces. Called from the SwiftUI
    /// `.onChange(of: TerminalConfigBroadcaster.shared.generation)` seam in `GhosttyTerminalView`; the
    /// view then re-measures the cell size and resizes the host PTY grid (the grid-mismatch fix). A
    /// no-op when the generation hasn't advanced past the last apply.
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
        //    AislopdeskHost/ShellIntegration.swift.)
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
        //    for Aislopdesk's external-backend viewer the surface's own write/resize
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
        // window/split/tab actions (Aislopdesk does its OWN tiling at the SwiftUI layer) — EXCEPT
        // GHOSTTY_ACTION_OPEN_URL: libghostty owns OSC 8 hyperlink hit-testing + the click internally and
        // asks the embedder to OPEN the resolved URL (W14 #7). We hand it to the system opener (the
        // embedder's job upstream too) so a clicked OSC 8 link / hovered-URL click opens — no wire change,
        // no host-side OSC 8 parsing needed (see docs/DECISIONS.md). Everything else returns false.
        runtime.action_cb = { (_, _, action) -> Bool in
            guard action.tag == GHOSTTY_ACTION_OPEN_URL else { return false }
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
        }

        // Clipboard callbacks — modeled on upstream `Ghostty.App.swift:324-405`. The `userdata`
        // here is the SURFACE's userdata (libghostty passes it through), which aislopdesk set to the
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
                let pb = aislopdeskPasteboard(for: location)
                let str = pb.string(forType: .string) ?? ""
                #else
                let str = (location == GHOSTTY_CLIPBOARD_SELECTION) ? "" : (UIPasteboard.general.string ?? "")
                #endif
                surface.completeClipboardRead(str, state: state)
            }
            return true
        }

        // CONFIRM-READ: libghostty reaches here when the access gate tripped on the FIRST completion —
        // an OSC-52 read (`clipboard-read = .ask`) or a paste of unsafe content
        // (`clipboard-paste-protection = true`). This is the embedder's APPROVE/DENY decision point;
        // upstream posts a confirm-dialog Notification. aislopdesk has no dialog, so it AUTO-APPROVES by
        // completing with `confirmed: true`. This is REQUIRED: completing with `confirmed: false` here
        // would re-trip the same gate → core re-invokes this callback → unbounded synchronous recursion
        // → stack-overflow crash (host OSC-52 read / multi-line paste would crash the whole client).
        runtime.confirm_read_clipboard_cb = { (userdata, cString, state, _ /*request*/) in
            guard let userdata else { return }
            let str = cString.map { String(cString: $0) } ?? ""   // upstream uses String(cString:)
            MainActor.assumeIsolated {
                let surface = Unmanaged<GhosttySurface>.fromOpaque(userdata).takeUnretainedValue()
                surface.completeClipboardRead(str, state: state, confirmed: true)
            }
        }

        // WRITE: libghostty (copy_to_clipboard / OSC-52 write) hands us a C array of
        // `ghostty_clipboard_content_s` { mime, data }. Write the text/plain entry to
        // NSPasteboard.general (upstream writeClipboard, App.swift:371-405). We model the STANDARD
        // clipboard only (the selection clipboard is virtual on macOS); ignore non-text mimes.
        runtime.write_clipboard_cb = { (_ /*userdata*/, location, content, len, _ /*confirm*/) in
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
            // Pasteboard is main-thread-only; this path is main (copy_to_clipboard binding / main feed).
            // HONOR `location`: a SELECTION write (copy-on-select drag) goes to a PRIVATE pasteboard so
            // it never clobbers the user's real system clipboard; only an explicit STANDARD copy
            // (Cmd-C / copy_to_clipboard) writes the system clipboard. (iOS: no selection clipboard.)
            MainActor.assumeIsolated {
                #if os(macOS)
                let pb = aislopdeskPasteboard(for: location)
                pb.declareTypes([.string], owner: nil)
                pb.setString(text, forType: .string)
                #else
                if location != GHOSTTY_CLIPBOARD_SELECTION { UIPasteboard.general.string = text }
                #endif
            }
        }

        runtime.close_surface_cb = { _, _ in }

        // 4. App (header 1141).
        self.app = ghostty_app_new(&runtime, config)

        // The config can be freed after app_new copies what it needs (header 1124).
        ghostty_config_free(config)
    }
}

// MARK: - GhosttyTerminalView (the TerminalRenderingView conformer)

/// libghostty-backed terminal renderer — Aislopdesk's production `TerminalRenderingView`.
///
/// It hosts a Metal-backed platform view (`CAMetalLayer`) that owns a `GhosttySurface`
/// configured for the EXTERNAL backend. The data flow:
///
///  * **IN** (host PTY output → pixels): the `TerminalViewModel` already calls
///    `surface.feed(_:)` inside `ingestOutput(_:)`. This view just sets
///    `model.surface = <the GhosttySurface>` so the model's existing feed path lands
///    in libghostty. (`feed` → `ghostty_surface_write_output` + refresh + draw.)
///  * **OUT** (keystrokes → host PTY stdin): the view forwards platform key/text
///    events to `surface.key(_:)` / `surface.text(_:)`; libghostty encodes them and
///    emits the bytes via `surface.onWrite`, which the connection layer bridges to
///    `AislopdeskClient.sendInput` (documented seam — see file header + doc 21).
///  * **Resize**: layout changes convert the view's pixel size → cols/rows and call
///    `surface.setSize(cols:rows:)`; the surface mirrors the grid to the host via
///    `surface.onResize`.
///  * **Render cadence**: libghostty drives its own draw from `feed`/`redraw`; the
///    view forces a `redraw()` on focus/occlusion/scale changes.
///
/// ⚠️ **GUI-ONLY:** needs a real screen + the libghostty xcframework. COMPILED +
/// reviewed; not driven from tests (mirrors `VideoWindowView`). This is the view the
/// app injects via `TerminalRendererFactory.shared`.
public struct GhosttyTerminalView: TerminalRenderingView {
    private let model: TerminalViewModel
    /// The pane's workspace focus (active tab's `focusedPane`). Drives the macOS keyboard FIRST
    /// RESPONDER — only the focused pane takes the keyboard — WITHOUT gating render-liveness (every
    /// visible pane stays libghostty-focused so an unfocused split sibling keeps repainting its output).
    private let isFocused: Bool

    /// `TerminalRenderingView` conformance. Defaults `isFocused` to `true` (single-pane / preview).
    public init(model: TerminalViewModel) {
        self.model = model
        self.isFocused = true
    }

    /// The workspace-aware initializer the app factory uses, carrying the pane's focus.
    public init(model: TerminalViewModel, isFocused: Bool) {
        self.model = model
        self.isFocused = isFocused
    }

    public var body: some View {
        GhosttyMetalLayerView(model: model, isFocused: isFocused)
            .accessibilityLabel(Text("Terminal"))
            // W13: LIVE terminal-config apply. The client's `PreferencesStore` publishes a new libghostty
            // config string to `TerminalConfigBroadcaster` (bumping `generation`) on every Settings ▸
            // Terminal change. Push it app-wide (reflows every surface), then nudge the surface to
            // re-measure its cell size + resize the host PTY grid so a font reflow doesn't desync the grid.
            .onChange(of: TerminalConfigBroadcaster.shared.generation, initial: true) {
                // `ghostty_app_update_config` reflows + re-draws every surface; the surface's
                // resize_callback then fires onResize → the host PTY grid tracks the new font metrics.
                GhosttyApp.shared.applyTerminalConfig(
                    TerminalConfigBroadcaster.shared.configString,
                    generation: TerminalConfigBroadcaster.shared.generation,
                )
            }
    }
}

// MARK: - Platform representable + Metal-backed view

#if os(macOS)

/// `NSViewRepresentable` host backing the `CAMetalLayer` that owns the `GhosttySurface`.
struct GhosttyMetalLayerView: NSViewRepresentable {
    let model: TerminalViewModel
    /// The pane's workspace focus — drives the keyboard first responder (see ``GhosttyLayerBackedView``).
    var isFocused: Bool = true

    func makeNSView(context: Context) -> GhosttyLayerBackedView {
        let view = GhosttyLayerBackedView()
        // Do NOT create the surface here. SwiftUI builds the representable for an off-window
        // probe/sizing pass too; creating the libghostty surface in that throwaway view spawns a
        // SECOND set of renderer/io threads (the 100%-CPU spin) and a duplicate surface
        // (detach-clobber). Just remember the model — the surface is created lazily once the view
        // enters a real window (`viewDidMoveToWindow`), so EXACTLY ONE surface exists per pane.
        view.model = model
        view.isFocusedPane = isFocused
        return view
    }

    func updateNSView(_ nsView: GhosttyLayerBackedView, context: Context) {
        nsView.model = model
        // Attach only on-window (idempotent). The off-window probe view never reaches here with a
        // window set, so it never calls `ghostty_surface_new`.
        if nsView.window != nil { nsView.attach(model: model) }
        // Apply the workspace focus: only the focused pane takes the keyboard first responder. A focus
        // change (Cmd-arrow / palette / click→store.focus) re-renders this representable with the new
        // value, so focus follows workspace intent reactively — no pane steals the keyboard on mount.
        nsView.isFocusedPane = isFocused
    }

    static func dismantleNSView(_ nsView: GhosttyLayerBackedView, coordinator: ()) {
        nsView.detach()
    }
}

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

    /// Whether THIS pane is the workspace's focused pane (set by `GhosttyMetalLayerView`). Drives the
    /// keyboard FIRST RESPONDER only — render-focus (`surface.setFocus(true)`) is kept ON for every
    /// visible pane in `attach()` so an unfocused split sibling keeps repainting. On a change to `true`
    /// the pane claims first responder; on `false` it does NOT resign (a sibling claiming FR resigns it).
    var isFocusedPane: Bool = true {
        didSet { if isFocusedPane != oldValue { applyKeyboardFocus() } }
    }

    /// Claims the keyboard first responder iff this is the focused pane and on-window. Never resigns
    /// here (the sibling that becomes focused makes ITSELF first responder, which resigns this one) and
    /// never touches `surface.setFocus` (render-focus stays on for repaint — the multi-pane fix).
    private func applyKeyboardFocus() {
        guard isFocusedPane else { return }
        // Defer off the SwiftUI update/commit pass: makeFirstResponder synchronously tears down + sets up
        // the AppKit responder chain (and draws the focus ring), which stalls the main thread when it runs
        // inside updateNSView during a tab/session switch. One runloop hop makes the switch a single CA
        // commit; the keyboard first-responder transfer happens imperceptibly after.
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
    /// here or it will silently never present. Nil-safe for AISLOPDESK_NO_TICK.
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
    /// so the surface is created ONLY once the view is in a real window — never for SwiftUI's
    /// off-window probe pass (which would spawn a duplicate surface + thread set that busy-spins).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            if let model { attach(model: model) }
            startRenderTickIfNeeded()
            requestPresent(8)   // prime the initial glyph flush
            // Claim the keyboard ONLY if this is the workspace's focused pane. In a multi-pane split
            // every pane used to call `makeFirstResponder` on mount, so the LAST-mounted pane stole the
            // keyboard regardless of `store.focusedPane` (focus-stealing bug). Render-liveness is
            // SEPARATE: `attach()` keeps `surface.setFocus(true)` on every visible pane (an unfocused
            // libghostty surface idles its renderer and freezes — hardware-confirmed), so unfocused
            // split siblings still repaint; only the keyboard FR is gated. Deferred so the window is key.
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
    /// model. Safe to call repeatedly from `updateNSView` / `viewDidMoveToWindow`.
    func attach(model: TerminalViewModel) {
        self.model = model
        guard window != nil else { return }   // never spawn a surface for the off-window probe view
        if surface == nil {
            let s = GhosttySurface(
                app: GhosttyApp.shared.app,
                platformView: Unmanaged.passUnretained(self).toOpaque(),
                cols: 80,
                rows: 24,
                contentScale: Double(window?.backingScaleFactor ?? 2.0)
            )
            // OUT path: encoded keystrokes → model input sink → live AislopdeskClient.sendInput.
            s.onWrite = { [weak model] (data: Data) in model?.sendInput(data) }
            // Grid changes (font reflow) → model resize sink → host TIOCSWINSZ.
            s.onResize = { [weak model] (cols: UInt16, rows: UInt16) in model?.sendResize(cols: cols, rows: rows) }
            // New inbound bytes were fed → ask the gated tick to present. This is the dirty signal
            // that REPLACES a free-running per-frame `draw_now` (the spin source). Without it the
            // gated tick would never present live output.
            s.onContentChanged = { [weak self] in self?.requestPresent() }
            self.surface = s
            // A BRAND-NEW surface must get its first real layout (setPixelSize) — drop the
            // same-size guard's cache so the next layout() pass applies unconditionally.
            lastAppliedLayout = nil
        }
        // attachSurface(_:) (not `model.surface = surface`) so the model REPLAYS its retained byte
        // ring into a rebuilt surface (tab switch / reshape). No-op replay when unchanged.
        if let surface { model.attachSurface(surface) }
        surface?.setFocus(true)
        requestPresent(8)   // flush whatever the replay just fed
    }

    private func startRenderTickIfNeeded() {
        guard renderDisplayLink == nil, window != nil,
              ProcessInfo.processInfo.environment["AISLOPDESK_NO_TICK"] == nil else { return }
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
        // Cancel any pending settle-present burst so a torn-down view never fires `requestPresent`.
        for item in settleItems { item.cancel() }
        settleItems.removeAll(keepingCapacity: true)
        let detaching = surface
        surface = nil
        detaching?.close()
        // Pass the detaching surface so the model clears its `surface` ONLY if this is the surface it
        // currently feeds. A stale duplicate view's detach must NOT nil the live (on-screen) surface
        // — that froze the visible terminal on its initial replay while new output was dropped.
        model?.detachSurface(detaching)
    }

    deinit {
        // @MainActor not available in deinit; the surface's own deinit frees the
        // ghostty_surface_t. We rely on detach() (dismantleNSView) as the explicit path.
    }

    // MARK: Resize → grid

    /// The last (bounds.size, scale) actually APPLIED to a live surface+layer by `layout()`.
    /// Same-size SwiftUI/AppKit passes (focus re-render, canvas reshuffle) early-out: with
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
            // ROUNDED-CARD METAL CLIPPING: SwiftUI .clipShape on the NSViewRepresentable clips the
            // SwiftUI render tree but NOT this hosted IOSurfaceLayer (libghostty's Metal sublayer).
            // Setting cornerRadius + masksToBounds directly on the hosted layer is the only way to
            // round the actual terminal pixels — exactly how NSView/CALayer-backed views are clipped
            // at the system level. The radius matches AislopdeskTheme.Radius.pane (8pt); continuous
            // curve is approximated by the layer's own antialiasing (CALayer cornerCurve .continuous
            // is only available on iOS 13+ / macOS 10.15+; we check below for safety).
            //
            // contentsGravity stays .topLeft (already the default for this layer) so the clip does
            // not shift the rendered surface. masksToBounds is already likely false; explicit set.
            if #available(macOS 10.15, *) {
                hosted.cornerCurve = .continuous
            }
            hosted.cornerRadius = 8  // AislopdeskTheme.Radius.pane — imported from AislopdeskClientUI
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

        // Route every other key through libghostty's encoder (DECISIONS: never hand-roll VT).
        // ghostty_input_key_s (header 322): action / mods / keycode / text /
        // unshifted_codepoint / composing.
        var key = ghostty_input_key_s()
        key.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        key.mods = Self.ghosttyMods(event.modifierFlags)
        // consumed_mods: the mods AppKit already "used up" producing `event.characters`. Upstream
        // (NSEvent+Extension `consumedModifiers`) reports the layout-consumed set; we approximate it
        // as all mods EXCEPT control/command — those never alter the produced character on a US/Latin
        // layout, so libghostty must still see them to encode Ctrl-/Cmd- combos. This stops Ghostty
        // from double-applying Shift/Option (e.g. a shifted `!` being re-shifted) in its encoder.
        key.consumed_mods = Self.ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        key.keycode = UInt32(event.keyCode)
        // unshifted_codepoint: the character the key would produce with NO modifiers (header field).
        // `charactersIgnoringModifiers` STILL reflects Shift (it ignores Cmd/Ctrl/Opt but not Shift),
        // so a shifted `2` reported `@` here — wrong. `characters(byApplyingModifiers: [])` strips ALL
        // modifiers including Shift, giving the true base codepoint Ghostty keys its bindings on.
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first.map { $0.value } ?? 0
        key.composing = false
        // `text` is a borrowed const char* for the keypress duration; bind the chars.
        if let chars = event.characters, !chars.isEmpty {
            let copy = chars
            copy.withCString { cstr in
                key.text = cstr
                _ = surface?.key(key)
            }
        } else {
            key.text = nil
            _ = surface?.key(key)
        }
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

        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_RELEASE
        key.mods = Self.ghosttyMods(event.modifierFlags)
        // Same consumed-mods / unshifted-codepoint correctness as keyDown (see there for the why).
        key.consumed_mods = Self.ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first.map { $0.value } ?? 0
        key.composing = false
        key.text = nil
        _ = surface?.key(key)
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
        // follow via the reactive `isFocused` → `isFocusedPane` path) AND the immediate first
        // responder so typing works without waiting a SwiftUI render. `applyKeyboardFocus`/this guard
        // are idempotent, so this does not fight the existing `isFocused` path (no double-focus).
        model?.onRequestFocus?()
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }

        let mods = Self.ghosttyMods(event.modifierFlags)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: mods)
    }

    override func mouseUp(with event: NSEvent) {
        // Always reset pressure when the mouse goes up (upstream SurfaceView_AppKit.swift:875/883).
        prevPressureStage = 0
        let mods = Self.ghosttyMods(event.modifierFlags)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: mods)
        surface?.sendMousePressure(stage: 0, pressure: 0)
    }

    override func otherMouseDown(with event: NSEvent) {
        let mods = Self.ghosttyMods(event.modifierFlags)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: Self.mouseButton(event.buttonNumber), mods: mods)
    }

    override func otherMouseUp(with event: NSEvent) {
        let mods = Self.ghosttyMods(event.modifierFlags)
        surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: Self.mouseButton(event.buttonNumber), mods: mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        let mods = Self.ghosttyMods(event.modifierFlags)
        // libghostty returns whether it consumed the right-click (e.g. turned it into a paste). If not
        // consumed, fall through to the default (which would surface a context menu were one installed).
        if surface?.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, mods: mods) == true { return }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        let mods = Self.ghosttyMods(event.modifierFlags)
        if surface?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT, mods: mods) == true { return }
        super.rightMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let mods = Self.ghosttyMods(event.modifierFlags)
        let p = surfacePoint(event)
        surface?.sendMousePos(x: p.x, y: p.y, mods: mods)
    }

    // A drag is just a moved position to libghostty (it tracks the held button from the down/up pair);
    // upstream routes every *Dragged variant straight to mouseMoved (SurfaceView_AppKit.swift:998-1008).
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Reset the cursor position on enter — lots of mouse-report logic depends on the position being
        // inside the viewport (upstream SurfaceView_AppKit.swift:936-952).
        let mods = Self.ghosttyMods(event.modifierFlags)
        let p = surfacePoint(event)
        surface?.sendMousePos(x: p.x, y: p.y, mods: mods)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // If a button is held the drag still delivers positions even past the edge, so don't send the
        // "left viewport" marker (upstream SurfaceView_AppKit.swift:955-972).
        if NSEvent.pressedMouseButtons != 0 { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        surface?.sendMousePos(x: -1, y: -1, mods: mods)   // negative = cursor left the viewport
    }

    override func scrollWheel(with event: NSEvent) {
        // ONLY the active pane swallows scroll: a scroll on a NON-focused terminal pans the CANVAS
        // (matching the macOS background pan's natural-scroll sign) instead of being eaten by
        // libghostty's scrollback. The leaf wires `onCanvasScroll` to the store camera pan; if it's
        // not wired (headless/preview) the scroll is simply dropped rather than mis-routed.
        if !isFocusedPane {
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

    // MARK: Clipboard responder selectors (Cmd-C / Cmd-V / Cmd-A)
    //
    // The terminal keyDown deliberately does NOT intercept Cmd-combos (they are app shortcuts). The
    // standard Edit menu / Cmd-key path lands on these responder selectors; we route each to the
    // matching libghostty binding action so copy uses the selection, paste applies bracketed-paste
    // (DECSET 2004) itself — do NOT hand-roll paste bytes — and select-all spans the screen+scrollback.
    // The workspace command table (Cmd-T/W/D/1-9/R/]/[ + Opt-Cmd-arrows + Cmd-K) does NOT bind C/V/A,
    // so these never collide.

    // `copy`/`paste` are responder-chain selectors NOT declared on NSResponder itself, so they are
    // plain `@objc` (no `override`); `selectAll(_:)` IS declared on NSResponder, so it MUST be
    // `override` — matching upstream `SurfaceView_AppKit.swift:1507/1515/1539`.
    @objc func copy(_ sender: Any?) {
        surface?.performBindingAction("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        surface?.performBindingAction("paste_from_clipboard")   // libghostty applies bracketed-paste
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
        for item in TerminalContextMenu.items {
            if item.separatorBefore { menu.addItem(.separator()) }
            let menuItem = NSMenuItem(title: item.title, action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.rawValue
            menuItem.isEnabled = TerminalContextMenu.isEnabled(item, context: ctx)
            menu.addItem(menuItem)
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
        case .paste: surface?.performBindingAction("paste_from_clipboard")
        case .pasteAsKeystrokes:
            // Type the pasteboard string as raw keystrokes (no bracketed-paste) — the "paste literally"
            // affordance for TUIs that swallow bracketed paste.
            if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty { surface?.text(s) }
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

    /// Catch Cmd-C / Cmd-V / Cmd-A DIRECTLY, regardless of whether an Edit menu is installed. Returning
    /// `true` marks the equivalent handled so it does not propagate to the menu / beep. Other Cmd-combos
    /// (the workspace shortcuts) are left to `super` so the command table still sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only the bare Cmd-<letter> (no shift/ctrl/opt) is the copy/paste/select-all chord; a shifted
        // or otherwise-modified Cmd combo is left to the workspace command table / remote app.
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.shift),
              let chars = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        switch chars {
        case "c": copy(nil); return true
        case "v": paste(nil); return true
        case "a": selectAll(nil); return true
        // Font sizing — the universal terminal chords (Terminal.app/iTerm/Ghostty): ⌘= grows, ⌘-
        // shrinks, ⌘0 resets. Routed to libghostty's font-size binding actions, which reflow the grid
        // (the resize path then propagates the new cols/rows to the host). None collide with the
        // workspace command table (Cmd-T/W/D/1-9/R/]/[ + Opt-Cmd-arrows + Cmd-K) — Cmd-0 is unbound
        // (tabs use Cmd-1…9). "=" is the no-shift form of the +/= key, matching macOS convention.
        // `increase/decrease_font_size` take a points DELTA parameter (Binding.zig:369/375 —
        // `increase_font_size: f32`), so the action string MUST carry `:1` (Ghostty's own default
        // step, Config.zig); a bare `increase_font_size` fails to parse and no-ops. `reset_font_size`
        // is parameterless.
        case "=": surface?.performBindingAction("increase_font_size:1"); return true
        case "-": surface?.performBindingAction("decrease_font_size:1"); return true
        case "0": surface?.performBindingAction("reset_font_size");      return true
        default:  return super.performKeyEquivalent(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        surface?.setFocus(true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        // DO NOT drop libghostty render-focus here. Losing the KEYBOARD first responder to a sibling
        // pane must NOT idle this surface's renderer — an unfocused libghostty surface stops presenting
        // and FREEZES on its last frame (hardware-confirmed), which is exactly the multi-pane
        // "unfocused pane goes stale" bug. Render-focus is kept ON for every visible pane (set in
        // `attach()`); only the keyboard moves to the newly-focused pane. (A pane truly leaving the
        // screen is `detach()`'d, which closes the surface — so it never needs an unfocus here.)
        return super.resignFirstResponder()
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
}

#elseif os(iOS)

/// `UIViewRepresentable` host backing the `CAMetalLayer` that owns the `GhosttySurface`.
struct GhosttyMetalLayerView: UIViewRepresentable {
    let model: TerminalViewModel
    /// Signature parity with the macOS sibling. iOS keyboard focus is owned by `TerminalInputHost`
    /// (doc 17 §2.5), and every visible surface stays render-focused, so this is currently inert here.
    var isFocused: Bool = true

    func makeUIView(context: Context) -> GhosttyLayerBackedView {
        let view = GhosttyLayerBackedView()
        view.attach(model: model)
        return view
    }

    func updateUIView(_ uiView: GhosttyLayerBackedView, context: Context) {
        uiView.attach(model: model)
    }

    static func dismantleUIView(_ uiView: GhosttyLayerBackedView, coordinator: ()) {
        uiView.detach()
    }
}

/// A `UIView` whose `layerClass` is `CAMetalLayer`, owning the `GhosttySurface`.
///
/// Physical-key + IME text forwarding on iOS is handled by the existing UIKit
/// table-stakes host (`AislopdeskClientUI.TerminalInputHost` — doc 17 §2.5), which already
/// routes presses/IME to `AislopdeskClient.sendInput`. This view focuses on hosting the
/// Metal layer + surface; the input-host integration is the documented follow-up seam.
final class GhosttyLayerBackedView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private var surface: GhosttySurface?
    private weak var model: TerminalViewModel?
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
    /// changes arm a few ticks; `renderTick` drains them and goes idle.
    func requestPresent(_ ticks: Int = 3) {
        presentTicks = max(presentTicks, ticks)
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
    /// guarded so the idempotent `attach()` (called from both `makeUIView` and `updateUIView`)
    /// never stacks duplicate recognizers. The keyboard input bar (`TerminalInputHost`) is a
    /// SEPARATE sibling view in the iOS `terminalComposite` VStack (PaneLeafView), so the pan
    /// here cannot swallow its taps; and a `UIPanGestureRecognizer` only recognizes DRAGS, not
    /// taps, so a tap meant for focusing/keyboard passes straight through to other handlers.
    private func installPanToScrollIfNeeded() {
        guard panRecognizer == nil else { return }
        isUserInteractionEnabled = true   // a passive renderer may default this off
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePanToScroll(_:)))
        pan.maximumNumberOfTouches = 2    // 1- or 2-finger drag scrolls; matches a trackpad scroll
        addGestureRecognizer(pan)
        panRecognizer = pan
    }

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
            // Packed scroll mods (Int32: bit0 = precision, bits1-3 = momentum), per the macOS
            // override + `Ghostty.Input.swift:438-465`. Touch is HIGH-PRECISION → set bit0. A
            // finger-driven pan carries no momentum phase here → momentum bits = 0 (.none), which
            // is fine for v1 (a future round could map the end-velocity to a momentum phase).
            let packed: ghostty_input_scroll_mods_t = 0b0000_0001   // precision; momentum = none
            surface?.sendMouseScroll(deltaX: 0, deltaY: Double(deltaY), mods: packed)
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
    /// guarded like `installPanToScrollIfNeeded` so the idempotent `attach()` (called from both
    /// `makeUIView` and `updateUIView`) never stacks duplicate recognizers.
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

    func attach(model: TerminalViewModel) {
        self.model = model
        installPanToScrollIfNeeded()
        installTapIfNeeded()
        if surface == nil {
            let scale = window?.screen.scale ?? UIScreen.main.scale
            let s = GhosttySurface(
                app: GhosttyApp.shared.app,
                platformView: Unmanaged.passUnretained(self).toOpaque(),
                cols: 80,
                rows: 24,
                contentScale: Double(scale)
            )
            // OUT path: libghostty-encoded keystrokes → model sink → live AislopdeskClient.
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
        surface?.setFocus(true)
        requestPresent(8)   // prime the initial glyph flush / flush the replay (mirrors macOS)

        // Start the render-thread pacing tick (idempotent). 60 fps is plenty for a
        // terminal; libghostty coalesces (its updateFrame is dirty-gated, so idle ticks
        // are cheap no-ops).
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(renderTick))
            link.preferredFramesPerSecond = 60
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func renderTick() {
        #if targetEnvironment(simulator)
        // Simulator: keep the free-run — the renderer thread's libxev wakeup pump is
        // unreliable there (patch 0001 forensics) and the steady drawNow papers over it.
        surface?.drawNow()
        #else
        // Device: GATED. Idle ticks stop signalling the renderer thread (60Hz cross-thread
        // wakeup + mutex churn per pane, even fully idle). KEEP drawNow when armed — the
        // macOS setNeedsDisplay/displayIfNeeded present path does not exist on iOS (the
        // IOSurfaceLayer is an unwired SUBLAYER here).
        guard presentTicks > 0 else { return }
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
        let detaching = surface
        surface = nil
        detaching?.close()
        // Identity-gated detach (see the macOS sibling): a stale duplicate view's detach must not nil
        // the live surface the model is still feeding.
        model?.detachSurface(detaching)
    }

    /// The last (bounds.size, scale) actually APPLIED to a live surface — the iOS mirror of
    /// the macOS `lastAppliedLayout` same-size guard (see that doc comment). Invalidated on
    /// surface creation (`attach`) and `detach`.
    private var lastAppliedLayout: (size: CGSize, scale: CGFloat)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        // SAME-SIZE GUARD (mirrors macOS layout()): spurious same-size SwiftUI passes used
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
        // ROUNDED-CARD METAL CLIPPING (iOS): apply the same rounded-corner clip to the
        // hosting UIView's own layer so the Metal sublayer is masked. The sublayers are
        // sized to `bounds` above, and `masksToBounds = true` on THIS layer clips them all.
        // Matches the macOS hosted-layer clip in GhosttyLayerBackedView.layout().
        layer.cornerRadius = 8   // AislopdeskTheme.Radius.pane
        if #available(iOS 13.0, *) { layer.cornerCurve = .continuous }
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

#endif  // os(macOS) / os(iOS)

#endif  // canImport(CGhostty)

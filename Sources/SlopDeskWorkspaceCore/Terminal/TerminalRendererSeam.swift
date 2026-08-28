// TerminalRendererSeam — the seam between the client's canvas and the terminal pixels.
//
// PATH 1 streams raw VT bytes; *how* they become pixels is hidden behind this seam so the UI
// compiles and is testable WITHOUT libghostty. The production renderer is `GhosttyLayerBackedView`
// (`ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift`), a LAYER-HOSTING view
// libghostty installs its own `IOSurfaceLayer` into. It lives in the Xcode app target, which links
// `libghostty.xcframework` and imports the `CGhostty` clang module, so a headless `swift build`
// never sees it — hence a registered factory rather than a direct reference.
//
// ⚠️ THIS SEAM HAD TWO SHAPES AND NOW HAS ONE. `shared`/`make` used to hand back a SwiftUI
// `AnyView`, and `nativeShared`/`makeNative` handed back the `NSView` itself; the doc comment on the
// SwiftUI half called it "ADDITIVE, permanently" on the grounds that "the phone has no `NSView`, so
// iOS's leaf keeps crossing as a `View` over `UIViewRepresentable`". That premise died with the
// SwiftUI removal: the phone draws in UIKit now and has a `UIView`. So the two shapes folded into
// the one that was always the honest one — a canvas asks for the view it is about to add as a
// subview — and the "native" qualifier went with the fold, because it only ever meant "not SwiftUI"
// and there is no longer anything to distinguish it from.
//
// What the fold BUYS, and why it is not cosmetic: mounting the SwiftUI half put a hosting view
// between the canvas and the renderer — a full-bleed hosting layer over the ONE surface that must
// take every keystroke. That is the hit-claim docs/56 stage D spent five increments removing on the
// Mac, and it would have been rebuilt verbatim on the phone.
#if canImport(AppKit) || canImport(UIKit)

/// Injects the production terminal renderer when the app target provides one.
///
/// The cross-platform library cannot reference `GhosttyTerminalView` — naming it would force
/// libghostty into the headless `swift build`. Instead the Xcode app target sets ``shared`` at
/// launch and the canvas calls ``make(model:isFocused:)``. This is the documented extension point.
@preconcurrency
@MainActor
public final class TerminalRendererFactory {
    /// The app-registered factory (set once at launch). `nil` → no renderer: the headless build, the
    /// tests, and every build before the app target calls its installer.
    ///
    /// `isFocused` is the pane's workspace focus (the active tab's `focusedPane`) at MOUNT time. The
    /// production renderer uses it to drive the first responder from WORKSPACE INTENT — only the
    /// focused pane takes the keyboard — instead of every pane stealing it on mount (the multi-pane
    /// focus-stealing bug). It does NOT gate render-liveness: every visible pane stays render-focused,
    /// so an unfocused pane in a split keeps repainting its remote output. Every LATER change goes
    /// through ``TerminalSurfaceHosting/setPaneFocused(_:)``, because an imperative canvas has no
    /// `updateNSView`/`updateUIView` being re-run to carry it.
    ///
    /// `@MainActor` on the closure TYPE, not just at the call site: this builds and returns a
    /// ``PlatformView``, which is main-actor isolated, so the factory could not be written without it
    /// (the same reason ``RemoteWindowDiscovery/shared`` carries it).
    public static var shared: (@MainActor (TerminalViewModel, Bool) -> TerminalSurfaceHosting)?

    /// Builds the terminal surface host, or `nil` when no renderer was registered.
    ///
    /// `nil` rather than a placeholder view: the canvas is the only thing that knows where a
    /// build-status panel belongs in ITS layout, and a seam that returned one would be choosing.
    /// libghostty is the renderer (DECISIONS / doc 17) — there is no fallback VT emulator.
    public static func make(model: TerminalViewModel, isFocused: Bool) -> TerminalSurfaceHosting? {
        guard let factory = shared else { return nil }
        return factory(model, isFocused)
    }
}

/// What a canvas may ask of the terminal surface it just mounted.
///
/// The three members are the imperative spellings of what a representable used to get from its
/// lifecycle: `makeNSView` (the view itself), `updateNSView` (re-push the pane's focus) and
/// `dismantleNSView` (drop the surface). They are deliberately the WHOLE protocol — anything richer
/// would be the canvas reaching into the renderer, and the renderer is the one thing on this seam
/// neither UI target may name.
///
/// ⚠️ The only conformer is `GhosttyLayerBackedView`, in
/// `ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift` — a file NO
/// `Package.swift` target compiles (it joins the Xcode app target via
/// `slopdesk-ops enable-renderer macos`). A grep over `Sources/` and `Tests/` alone reads this
/// protocol as unimplemented, and it is not. Same trap as
/// ``TerminalViewModel/makeCopyModeKey(event:)``.
@preconcurrency
@MainActor
public protocol TerminalSurfaceHosting: AnyObject {
    /// The layer-hosting view to add as a subview. Add it, size it, and otherwise leave it alone: it
    /// owns its `layer` slot (libghostty installs an `IOSurfaceLayer` there) and sizes that layer in
    /// its own layout pass.
    var surfaceView: PlatformView { get }

    /// Re-push the pane's WORKSPACE focus. Drives the keyboard responder and libghostty's render
    /// focus (solid vs hollow cursor); it does NOT gate render-liveness, so an unfocused split
    /// sibling keeps repainting. Idempotent — the renderer dedupes and coalesces.
    func setPaneFocused(_ isFocused: Bool)

    /// Drop the libghostty surface. Removing the view from its superview is NOT enough: the surface
    /// owns renderer/io threads that must be torn down explicitly.
    func detachSurface()
}

/// The MODAL POINTER SHIELD — whether a modal overlay card (command palette / Open Quickly /
/// connect / cheat sheet / Peek & Reply) is floating over the workspace, read by the production
/// renderer's pointer-move handling before it forwards a position to libghostty.
///
/// The shield exists because an AppKit `NSTrackingArea` is RECT-based: it keeps firing no matter
/// what is composited above it, so with the palette open the terminal underneath kept feeding
/// cursor positions to a mouse-reporting TUI (hover highlights tracked the pointer THROUGH the
/// card) and focus-follows-mouse could steal the workspace focus mid-palette. Clicks never had
/// this problem — the card's dismiss floor takes them via ordinary hit-testing — so this closure
/// makes the pointer's hover traffic obey the same occlusion its clicks already do.
///
/// Same injection idiom as ``TerminalRendererFactory/shared``: the app root binds it once to the
/// live overlay coordinator's modal flag; the default (headless / tests) is never shielded. The
/// chrome columns gate the same flag through their own hit-testing — one flag, two event systems.
@preconcurrency
@MainActor
public enum TerminalPointerShield {
    /// Whether pointer traffic into the terminal is currently shielded by a modal overlay.
    public static var isActive: () -> Bool = { false }
}
#endif

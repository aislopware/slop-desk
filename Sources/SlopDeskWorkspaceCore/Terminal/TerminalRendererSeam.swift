// TerminalRendererSeam — the seam between the client's canvas and the terminal pixels.
//
// PATH 1 streams raw VT bytes; *how* they become pixels is hidden behind this seam so the UI
// compiles and is testable without a GPU. The production renderer lives in `Sources/SlopDeskTerminal/`
// now, a layer-hosting view that owns a `CAMetalLayer` Rust draws into (`docs/68`).
//
// ⚠️ THE SEAM SURVIVED ITS OWN REASON FOR EXISTING, and that is worth stating rather than letting
// the next reader assume it is vestigial. It used to be a factory because the conformer was OUTSIDE
// the SwiftPM graph: it linked a vendored `libghostty.xcframework` through the `CGhostty` clang
// module, joined the Xcode app through a spec entry, and naming it here would have dragged the fork
// into a headless `swift build`. That is all gone — `swift build` compiles the conformer today. What
// keeps the factory is the OTHER half of the argument, which never depended on the fork: the `nil`
// path is how every canvas test mounts a leaf with no renderer at all (`LeafSeamSlotTests`), and a
// canvas naming the view directly would create a Metal device under `swift test`.
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
import Foundation

/// Injects the production terminal renderer when the app target provides one.
///
/// The cross-platform library does not reference the renderer view — naming it would create a Metal
/// device in every canvas test. Instead `SlopDeskTerminal`'s installer sets ``shared`` at launch and
/// the canvas calls ``make(model:isFocused:)``. This is the documented extension point.
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
    /// `libghostty-vt` through `rust/slopdesk-vterm` is the engine and this repo's own renderer draws
    /// it (`docs/68`) — there is no second VT emulator to fall back to.
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
/// The conformer is in `Sources/SlopDeskTerminal/`, and `swift build` compiles it. That is new: it
/// used to live outside every `Package.swift` target, joining the Xcode app through an operator
/// script, so a grep over `Sources/` and `Tests/` read this protocol as unimplemented when it was
/// not. Nothing to warn about here any more — the trap moved out with the fork (`docs/68`).
@preconcurrency
@MainActor
public protocol TerminalSurfaceHosting: AnyObject {
    /// The layer-hosting view to add as a subview. Add it, size it, and otherwise leave it alone: it
    /// owns its `layer` slot (a `CAMetalLayer` the renderer draws into) and sizes that layer, and the
    /// drawable behind it, in its own layout pass.
    var surfaceView: PlatformView { get }

    /// The command prompt's band, to pin along the pane's BOTTOM edge with ``surfaceView`` filling
    /// what is left above it — `docs/68` §5.4.
    ///
    /// ⚠️ A SIBLING, NOT A SUBVIEW, and that is forced rather than chosen: ``surfaceView`` owns its
    /// `layer` slot outright (it is layer-HOSTING, not layer-backed), and AppKit does not promise a
    /// subview of one of those a layer of its own. So the grid gets smaller when the band appears —
    /// which is also the honest answer, since those rows genuinely are not the shell's any more.
    ///
    /// The band sizes ITSELF: it answers an `intrinsicContentSize` for what the editor currently
    /// holds and asks for a re-layout when that changes, so a host pins its three edges and gives it
    /// no height. `nil` where there is no prompt to draw — a headless build, or a host with no model
    /// yet.
    var promptView: PlatformView? { get }

    /// The band's content changed under an edit this host did not make — redraw and re-measure it.
    ///
    /// ⚠️ ONLY iOS CALLS IT, and the asymmetry is the responder's rather than the seam's. On macOS the
    /// renderer view IS the pane's first responder, so it edits the prompt itself and refreshes its
    /// own band through a private closure. On iOS the responder is `TerminalInputHostView`, a sibling
    /// of the pixels, and it can no more reach into a ``PlatformView`` the seam handed back than any
    /// other caller — so the redraw crosses here.
    func promptDidChange()

    /// Scroll the VIEWPORT by whole pages. Negative reveals OLDER output.
    ///
    /// Here for ``promptDidChange()``'s reason exactly: PageUp at an armed prompt reads the scrollback,
    /// which the editor does not own, and on iOS the key arrives at a view that is not the surface.
    func scrollPages(_ pages: Int)

    /// What an input method is COMPOSING — the underlined preedit run under the caret — with
    /// `selection` its own caret inside `text`, in UTF-16 offsets. An empty `text` withdraws it.
    ///
    /// Here for ``promptDidChange()``'s reason once more, and it is the same asymmetry: on macOS the
    /// renderer view is itself the `NSTextInputClient`, so it holds the composition and decides who
    /// draws it without leaving the file. On iOS the text client is `TerminalInputHostView`, a
    /// SIBLING of the pixels, and the two places a preedit can be drawn — the prompt band and the
    /// grid — are both behind this seam.
    ///
    /// ⚠️ THE HOST DOES NOT DECIDE WHICH ONE. It reports the composition and the conformer picks, so
    /// the band-or-grid fork is written once per platform rather than once per responder; two preedit
    /// runs on screen at the same time is what a host answering that question itself would look like.
    func setComposition(_ text: String, selection: NSRange)

    /// Where the caret is, and the view whose coordinates the rect is in.
    ///
    /// Two values because the answer moves between two views: while the editor owns the line the
    /// caret is in the BAND, and otherwise it is a cell on the grid. A candidate list hanging off the
    /// grid's stale cursor while the letters appear a band's height below is the most visible way a
    /// Telex session can look broken, and it is what returning only a rect would guarantee.
    ///
    /// `nil` where there is no caret to point at — a cursor scrolled off screen, or a host with no
    /// surface. The caller converts; UIKit places the candidate window itself.
    var caretAnchor: (view: PlatformView, rect: CGRect)? { get }

    /// Re-push the pane's WORKSPACE focus. Drives the keyboard responder and the renderer's cursor
    /// (solid vs hollow — `slopdesk_termrender::layout::cursor` forces `Hollow` when unfocused,
    /// whatever the shell asked for); it does NOT gate render-liveness, so an unfocused split sibling
    /// keeps repainting. Idempotent — the renderer dedupes and coalesces.
    func setPaneFocused(_ isFocused: Bool)

    /// Drop the surface. Removing the view from its superview is NOT enough: the host holds a
    /// `slopdesk-vterm` handle and a display link, and both outlive the view hierarchy unless said so.
    func detachSurface()
}

public extension TerminalSurfaceHosting {
    /// No band. The default because some hosts genuinely have none — a headless stub and the
    /// build-status placeholder — and a default is what keeps each of those from carrying a `nil` it
    /// would have to explain.
    var promptView: PlatformView? { nil }

    /// Nothing to redraw, which is true of every host that answered `nil` above.
    func promptDidChange() {}

    /// Nothing to scroll. A host with no surface has no viewport either.
    func scrollPages(_: Int) {}

    /// Nowhere to draw a preedit, which is true of every host that answered `nil` above.
    func setComposition(_: String, selection _: NSRange) {}

    /// No caret. A host with no pixels has no cell for one to sit in.
    var caretAnchor: (view: PlatformView, rect: CGRect)? { nil }
}

/// The MODAL POINTER SHIELD — whether a modal overlay card (command palette / Open Quickly /
/// connect / cheat sheet / Peek & Reply) is floating over the workspace, read by the production
/// renderer's pointer-move handling before it forwards a position to the engine.
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

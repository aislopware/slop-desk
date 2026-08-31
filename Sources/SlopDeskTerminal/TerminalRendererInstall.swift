// TerminalRendererInstall — the one call that makes the renderer exist.
//
// `TerminalRendererSeam.swift` explains why the seam is still a factory now that `swift build`
// compiles the conformer: its `nil` path is how every canvas test mounts a leaf with no renderer at
// all, and a canvas naming the view directly would create a Metal device under `swift test`. So the
// app tells the library there is a renderer, exactly once, and this is where that is said.
//
// It replaced `slopdesk-ops enable-renderer`: the registration used to live in an Xcode-only file
// the operator script wrote in, because the conformer was outside every SwiftPM target. Both
// `AppMain.swift`s call this instead.

#if canImport(AppKit) || canImport(UIKit)
import SlopDeskWorkspaceCore

/// Registers the production terminal renderer, and binds the pane sinks a live surface must own.
///
/// Idempotent — a second call replaces the factory with an identical one, which matters because the
/// two app targets each call it from their own launch path and neither knows about the other.
///
/// ## The three sinks, and why they are bound HERE rather than by the canvas
///
/// A pane's `onReclaimKeyboardFocus`, `onRequestMenuItem` and `onResizeSettled` are all questions
/// only a live surface can answer, and all three are `nil` on a headless model by design. Binding
/// them at the moment the surface is BUILT is what makes "there is a renderer" and "the renderer's
/// sinks are wired" the same event: a canvas that bound them separately could mount a surface whose
/// find bar could not give the keyboard back, and nothing would say so until someone pressed Escape.
/// `slopdesk-invariants`' `injected-sinks-are-bound` rule is the ratchet on exactly that.
@preconcurrency
@MainActor
public func installTerminalRenderer() {
    TerminalRendererFactory.shared = { model, isFocused in
        let host = makeRendererHost(model: model, isFocused: isFocused)
        bindSinks(of: model, to: host)
        return host
    }
}

/// Builds this platform's host, or the honest placeholder when no surface could be opened.
///
/// ⚠️ A machine that refuses a Metal device gets ``TerminalRendererUnavailableHost``, NOT a `nil`
/// factory result: `nil` means "no renderer was registered", which is the headless build, and a
/// canvas reads it as "put a build-status panel here". A GPU refusal is a different fact and the
/// user should see a different thing — a pane that says it cannot draw, in the place the terminal
/// would have been.
@MainActor
private func makeRendererHost(model: TerminalViewModel, isFocused: Bool) -> TerminalSurfaceHosting {
    #if canImport(AppKit)
    if let view = MacTerminalRendererView(model: model, isFocused: isFocused) {
        return view
    }
    #elseif canImport(UIKit) && !targetEnvironment(macCatalyst)
    if let view = PhoneTerminalRendererView(model: model, isFocused: isFocused) {
        return view
    }
    #endif
    return TerminalRendererUnavailableHost()
}

/// Binds the pane sinks that only a live surface can answer.
@MainActor
private func bindSinks(of model: TerminalViewModel, to host: TerminalSurfaceHosting) {
    // The find bar closed without a workspace-focus change, so nothing else will hand the keyboard
    // back: none of the surface's own reclaim paths (a focus transition, a mount, a click) fire on
    // that edge.
    model.onReclaimKeyboardFocus = { [weak host] in host?.setPaneFocused(true) }

    // ⌘C / ⌘X / ⌘A from outside the renderer — the iPad's chords, which land on the pane rather
    // than on the surface. The renderer runs the item; the phone only names it.
    model.onRequestMenuItem = { [weak host] item in
        (host as? TerminalMenuItemRunning)?.run(item)
    }

    // An interactive resize ENDED and the settled grid has just been flushed to the host. The
    // host's SIGWINCH redraw is ~1 RTT away, later than any burst anchored to the last layout, so
    // the surface re-arms its present keep-alive from HERE — the release — instead.
    model.onResizeSettled = { [weak host] in
        (host as? TerminalMenuItemRunning)?.requestPresentBurst()
    }
}

/// What a host must be able to do for the two sinks above.
///
/// A protocol rather than a cast to the concrete view because there are two concrete views and a
/// placeholder, and a seam that named one of them would not compile on the other platform.
@MainActor
protocol TerminalMenuItemRunning: AnyObject {
    /// Runs one context-menu / responder item. Answers whether it ran.
    @discardableResult
    func run(_ item: TerminalContextMenu.Item) -> Bool

    /// Re-arms the present keep-alive after a resize settles.
    func requestPresentBurst()
}

/// The host a machine that cannot open a surface gets.
///
/// It draws nothing and says so. `surfaceView` is a bare view rather than `nil` because the seam has
/// no `nil` to give — the canvas is adding a subview either way — and a view that is honestly empty
/// beats one that pretends to be a terminal.
@MainActor
final class TerminalRendererUnavailableHost: TerminalSurfaceHosting {
    let surfaceView = PlatformView(frame: .zero)

    func setPaneFocused(_: Bool) {}
    func detachSurface() {}
}
#endif

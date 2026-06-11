#if canImport(SwiftUI)
import SwiftUI
import AislopdeskTerminal

/// The **seam** between the SwiftUI client and the terminal pixels.
///
/// PATH 1 streams raw VT bytes; *how* they become pixels is hidden behind this protocol so
/// the cross-platform UI compiles and is testable **without** libghostty. There are exactly
/// two conformers:
///
/// 1. ``BuildStatusPlaceholderView`` — the no-framework case. It renders a clearly-labelled
///    BUILD-STATUS panel ("libghostty renderer not built — run
///    ThirdParty/ghostty/build-libghostty.sh"). It is **NOT** a substitute terminal renderer:
///    the libghostty-only policy (DECISIONS / doc 17) forbids any fallback VT engine, so the
///    placeholder shows build status, not emulated text.
///
/// 2. `GhosttyTerminalView` (the documented extension point) — the production renderer: a
///    Metal-hosted ``AislopdeskTerminal/TerminalSurface`` conformer wrapping the gated
///    `GhosttySurface` (`ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift`).
///    It lives in the **Xcode app target**, which links `libghostty.xcframework` and imports
///    the `CGhostty` clang module — so a headless `swift build` never sees it. See
///    ``TerminalRendererFactory`` for where the app injects it.
///
/// The view is given the ``TerminalViewModel`` so the production conformer can attach its
/// `GhosttySurface` to the model's surface feed; the placeholder just reads connection state.
public protocol TerminalRenderingView: View {
    init(model: TerminalViewModel)
}

/// The no-framework BUILD-STATUS placeholder (libghostty-only policy: not a fallback VT
/// renderer). Shown wherever the production `GhosttyTerminalView` has not been injected.
public struct BuildStatusPlaceholderView: TerminalRenderingView {
    private let model: TerminalViewModel

    public init(model: TerminalViewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text("libghostty renderer not built")
                    .font(.headline.monospaced())
                    .foregroundStyle(.green)
                Text("run ThirdParty/ghostty/build-libghostty.sh")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.7))
                    .textSelection(.enabled)
                Divider().frame(maxWidth: 280).overlay(.green.opacity(0.3))
                // Prove the byte pipeline is alive even without pixels: show how many bytes
                // the model has received. (This is build-status telemetry, NOT VT rendering.)
                Text("pipeline: \(model.connectionStatus.label) · \(model.bytesReceived) byte(s) received")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .multilineTextAlignment(.center)
        }
    }
}

/// Injects the production terminal renderer when the app target provides one.
///
/// The cross-platform library cannot reference `GhosttyTerminalView` (it would force linking
/// libghostty into the headless `swift build`). Instead the Xcode app target sets
/// ``shared`` at launch to a factory that builds its Metal-hosted `GhosttyTerminalView`; the
/// library calls ``make(model:)`` and falls back to the ``BuildStatusPlaceholderView`` when no
/// factory was registered. This is the documented extension point.
@MainActor
public final class TerminalRendererFactory {
    /// The app-registered factory (set once at launch). `nil` → use the placeholder.
    ///
    /// `isFocused` is the pane's workspace focus (the active tab's `focusedPane`). The production
    /// renderer uses it to drive the macOS first responder from WORKSPACE INTENT — only the focused
    /// pane takes the keyboard — instead of every pane stealing it on mount (the multi-pane
    /// focus-stealing bug). It does NOT gate render-liveness: every visible pane stays render-focused so
    /// an unfocused pane in a split keeps repainting its remote output.
    public static var shared: ((TerminalViewModel, Bool) -> AnyView)?

    /// Builds the terminal rendering view: the registered production renderer if present,
    /// else the BUILD-STATUS placeholder. `isFocused` reflects the pane's workspace focus.
    public static func make(model: TerminalViewModel, isFocused: Bool) -> AnyView {
        if let factory = shared {
            return factory(model, isFocused)
        }
        return AnyView(BuildStatusPlaceholderView(model: model))
    }
}
#endif

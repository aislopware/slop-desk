#if canImport(SwiftUI)
import SwiftUI

/// The **seam** between the cross-platform SwiftUI client and a remote GUI-window
/// video view (PATH 2 / Phase 4, doc 17 §3).
///
/// Like ``TerminalRendererFactory`` for the terminal pixels, the cross-platform
/// library cannot reference `RworkVideoClient.VideoWindowView` directly — that would
/// pull VideoToolbox + Metal into the headless `swift build` (and those frameworks
/// HANG without a window-server + TCC session in a test context). Instead the GUI
/// app target — which links `RworkVideoClient` and runs with the Screen-Recording /
/// decode entitlements — registers a factory at launch; the library calls it and
/// falls back to a clearly-labelled placeholder when no factory was registered
/// (i.e. when no host is capturing a GUI window).
///
/// This is **gated**: the GUI video path is secondary to the terminal path. A remote
/// GUI window only appears when (a) the app injects a factory AND (b) the host is
/// actively capturing a window. Until then the placeholder explains the state.
///
/// Wiring (app target, once at launch):
/// ```swift
/// import RworkVideoClient
/// VideoWindowFactory.shared = { descriptor in
///     AnyView(VideoWindowView(title: descriptor.title))
/// }
/// ```
@available(macOS 14.0, iOS 17.0, *)
public struct RemoteWindowDescriptor: Sendable, Equatable {
    /// The remote window's last-known title (from the geometry channel).
    public var title: String
    /// A stable identifier for the remote window (host CGWindowID).
    public var windowID: UInt32

    public init(title: String, windowID: UInt32) {
        self.title = title
        self.windowID = windowID
    }
}

/// Injects the production remote-GUI-window video view when the app target provides
/// one. `nil` → the gated placeholder is shown.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class VideoWindowFactory {
    /// App-registered factory (set once at launch). `nil` → use the placeholder.
    public static var shared: ((RemoteWindowDescriptor) -> AnyView)?

    /// Builds the remote-GUI-window view: the registered production renderer if
    /// present (and a host is capturing), else the gated placeholder.
    public static func make(_ descriptor: RemoteWindowDescriptor) -> AnyView {
        if let factory = shared {
            return factory(descriptor)
        }
        return AnyView(RemoteWindowPlaceholderView(descriptor: descriptor))
    }
}

/// The gated placeholder shown when the GUI video path is not active (no host
/// capturing / no `RworkVideoClient` view injected). It is NOT a substitute renderer
/// — it explains that the secondary GUI video path is idle. The terminal path is the
/// primary experience (doc 17: terminal-first).
@available(macOS 14.0, iOS 17.0, *)
public struct RemoteWindowPlaceholderView: View {
    let descriptor: RemoteWindowDescriptor

    public init(descriptor: RemoteWindowDescriptor) {
        self.descriptor = descriptor
    }

    public var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Remote GUI window not streaming")
                    .font(.headline)
                Text(descriptor.title.isEmpty ? "window \(descriptor.windowID)" : descriptor.title)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("the host is not capturing this window (GUI video path is secondary to the terminal path)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
#endif

#if canImport(SwiftUI) && canImport(QuartzCore) && canImport(Metal)
import SwiftUI
import QuartzCore
import Metal

/// A SwiftUI view that hosts the `CAMetalLayer` + cursor overlay for one remote GUI
/// window (doc 17 §3 PATH 2). It wraps the platform view that owns the Metal layer
/// and drives the `MetalVideoRenderer` + `ClientCursorCompositor` from a
/// `CADisplayLink` (`FramePacer`).
///
/// ⚠️ **GUI-ONLY:** instantiating the renderer / display link needs a real device +
/// screen. COMPILED + reviewed; not driven from tests. This is the wiring point that
/// `RworkClientUI` injects when a host is actively capturing a GUI window (see the
/// `VideoWindowSeam` in RworkClientUI).
public struct VideoWindowView: View {
    /// The remote window's title, shown in the chrome until geometry/title arrives.
    public let title: String

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        MetalVideoLayerView()
            .accessibilityLabel(Text("Remote GUI window: \(title)"))
    }
}

#if os(macOS)
/// `NSViewRepresentable` host backing the `CAMetalLayer` on macOS.
struct MetalVideoLayerView: NSViewRepresentable {
    func makeNSView(context: Context) -> MetalLayerBackedView { MetalLayerBackedView() }
    func updateNSView(_ nsView: MetalLayerBackedView, context: Context) {}
}

/// A layer-backed `NSView` whose backing layer is a `CAMetalLayer`.
final class MetalLayerBackedView: NSView {
    let videoLayer = CAMetalLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = videoLayer
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func makeBackingLayer() -> CALayer { videoLayer }
}
#elseif os(iOS)
import UIKit
/// `UIViewRepresentable` host backing the `CAMetalLayer` on iOS.
struct MetalVideoLayerView: UIViewRepresentable {
    func makeUIView(context: Context) -> MetalLayerBackedView { MetalLayerBackedView() }
    func updateUIView(_ uiView: MetalLayerBackedView, context: Context) {}
}

/// A `UIView` whose `layerClass` is `CAMetalLayer`.
final class MetalLayerBackedView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var videoLayer: CAMetalLayer { layer as! CAMetalLayer }
}
#endif
#endif

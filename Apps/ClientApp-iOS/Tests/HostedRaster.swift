// HostedRaster — the phone's ONE rasteriser, re-founded on `UIGraphicsImageRenderer` over an
// offscreen `UIWindow` (docs/62 stage C, §5.2).
//
// ⚠️ WHY THIS FILE EXISTS, AND WHY IT HAD TO LAND BEFORE THE FIRST UIKit TILE. Every phone-side pixel
// rig used to call `ImageRenderer(content:)` — SwiftUI's own rasteriser, which draws an UNAVAILABLE
// PLACEHOLDER wherever the tree holds a `UIViewRepresentable`, and then hands back a perfectly valid
// `UIImage` containing that empty box. A `XCTUnwrap(renderer.uiImage)` still passes. A PNG still gets
// written. The UIKit port turns every tile into a `UIView`, so on the first ported tile the whole
// harness would have started photographing nothing while staying green — the single most dangerous
// silent failure in the campaign (docs/62 §5.2), and the reason stage C owns the rig.
//
// The replacement photographs the LAYER TREE — the one representation every renderer actually
// produces, reached through `CALayer.render(in:)`.
//
// ⚠️ THIS FILE BRIEFLY CARRIED A SECOND OVERLOAD taking `some View`, for photographing hosted SwiftUI
// during a planned coexistence period. That period was cancelled the same day — all SwiftUI is being
// deleted from the tree, Mac and phone both — so the overload went with the tiles it would have
// photographed. It is worth recording what it cost to write, because the bug it hit is a property of
// this bundle and not of SwiftUI: mounting a controller as `rootViewController` on the SCENE-LESS
// `UIWindow` below photographs a fully transparent bitmap, silently, because a scene-less window
// never installs its root controller's view into the hierarchy at all. Anything mounted here has to
// be `addSubview`'d, which is what the surviving overload does.
//
// This mirrors the Mac's `Tests/SlopDeskMacUITests/MacChromeSnapshotRender.render(_:width:…)`, which
// has hosted its `NSView` marks in an offscreen `NSWindow` since the marks were AppKit. Two
// differences, both forced by the phone's bundle rather than chosen:
//
//   1. NO `makeKeyAndVisible`, and NO `drawHierarchy(in:afterScreenUpdates:)`. `ClientApp-iOSTests` is
//      a HOST-LESS logic bundle on purpose (`project.yml:143-145`: "it needs no app, no window server")
//      — there is no `UIApplication`, so the key-window dance traps and the render-server snapshot API
//      has no server to ask. `CALayer.render(in:)` is pure Core Animation and needs neither. The cost
//      is that a `UIVisualEffectView`'s backdrop does not rasterise, which is EXACTLY the limit
//      `ImageRenderer` already had (both toast rigs say so in their own headers), so no sheet loses
//      anything it used to show.
//   2. The window is still a `UIWindow` rather than a bare container view, because the appearance pin
//      has to live somewhere a whole subtree inherits: `overrideUserInterfaceStyle = .light` here is
//      the phone's spelling of the Mac rig's `NSAppearance(named: .aqua)`, and it is pinned for the
//      same reason — see that file's ⚠️. Every dynamic `Slate.Native.*` resolves against it.
//
// The rig proves ITSELF in `HostedRasterTests`, which samples real pixels back out of the bitmap.
// That suite runs on every `slopdesk-gate ios-tests`, so the failure §5.2 calls silent is now loud.

import UIKit
@testable import SlopDeskSlate

/// Photographs a `UIView` into a bitmap, at a chosen render scale.
@MainActor
enum HostedRaster {
    /// The ground every sheet stands on: the authored cream (`Slate/Surface/field`), NOT the semantic
    /// system backdrop. See `SlateSnapshotRender`'s ⚠️ — an ink judged against a ground it will never
    /// be drawn on is not judged at all.
    static var ground: UIColor { Slate.Native.Surface.field }

    /// Hosts `view` at `width` (and `height`, or its Auto Layout fitting height) and rasterises.
    ///
    /// `scale` is the RENDER scale, not a transform: at 1× a magnified tile would be a blown-up 14pt
    /// bitmap rather than the vector redrawn, which is the whole point of the zoomed strips the mark
    /// sheets lay out.
    ///
    /// `settle` spins the run loop before the shutter — needed only where a sheet photographs
    /// something whose first frame is scheduled rather than immediate (a spinner, an animated mark).
    /// Zero by default: the two toast rigs rasterise on every gate run and must not pay for it.
    static func image(
        _ view: UIView, width: CGFloat, height: CGFloat? = nil, scale: CGFloat = 2,
        background: UIColor? = nil, settle: TimeInterval = 0,
    ) -> UIImage {
        let window = makeWindow(size: CGSize(width: width, height: height ?? 1), background: background)
        view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: window.topAnchor),
            view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
        window.layoutIfNeeded()
        // Auto Layout has settled by here, so the intrinsic height is knowable; grow the window to it
        // when the caller did not name one, then lay out again on the final frame.
        if height == nil {
            let fitting = view.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel,
            )
            window.frame = CGRect(x: 0, y: 0, width: width, height: max(fitting.height, 1))
            window.layoutIfNeeded()
        }
        return photograph(window, scale: scale, settle: settle)
    }

    /// PNG bytes, or `nil` if the bitmap has no encodable backing — `image` always produces a drawn
    /// bitmap, so a `nil` here is a real regression and every caller fails on it.
    static func png(
        _ view: UIView, width: CGFloat, height: CGFloat? = nil, scale: CGFloat = 2,
        background: UIColor? = nil, settle: TimeInterval = 0,
    ) -> Data? {
        image(
            view, width: width, height: height, scale: scale, background: background, settle: settle,
        ).pngData()
    }

    // MARK: - The window and the shutter

    private static func makeWindow(size: CGSize, background: UIColor?) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        // ⚠️ `.light`, app-wide, matching ``SlateAppearancePin``: this app's ground is the cream and it
        // does not follow the OS. A harness that let the simulator's style through resolved every
        // dynamic `Slate.Native.Text.*` near-white and photographed white ink on cream.
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = background ?? ground
        // NOT `makeKeyAndVisible()` — see the header. A host-less bundle has no `UIApplication` to
        // make it key against, and the layer capture below needs neither key-ness nor visibility.
        window.isHidden = false
        return window
    }

    private static func photograph(_ window: UIWindow, scale: CGFloat, settle: TimeInterval) -> UIImage {
        pinContentsScale(window.layer, scale)
        // Commit the implicit transaction the layout above left open. `render(in:)` draws what the
        // layer tree HAS, not what it is about to have, and in a bundle with no run loop turning
        // between the mount and the shutter that is otherwise nothing.
        CATransaction.flush()
        if settle > 0 { RunLoop.current.run(until: Date().addingTimeInterval(settle)) }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = false
        let bounds = window.bounds
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
    }

    /// Raise the whole layer tree's backing resolution. A layer that was laid out before the scale was
    /// asked for keeps a 1× backing store and the capture comes back soft — the Mac rig walks the tree
    /// for the same reason (`MacChromeSnapshotRender.pinContentsScale`).
    private static func pinContentsScale(_ layer: CALayer, _ scale: CGFloat) {
        layer.contentsScale = scale
        layer.rasterizationScale = scale
        layer.setNeedsDisplay()
        layer.sublayers?.forEach { pinContentsScale($0, scale) }
    }
}

// MARK: - Reading pixels back

extension UIImage {
    /// The pixel at `point` in POINT space (the bitmap is `scale`× that), as straight 8-bit sRGB.
    ///
    /// Exists so a rig can assert it photographed something rather than a blank box — the whole reason
    /// the `ImageRenderer` era could go green while showing nothing.
    func slatePixel(atX x: CGFloat, y: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let cgImage else { return nil }
        let px = Int(x * scale), py = Int(y * scale)
        guard px >= 0, py >= 0, px < cgImage.width, py < cgImage.height else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        // Draw the whole image offset so the wanted pixel lands in the 1×1 context. A `CGContext` is
        // bottom-left-origin while a bitmap row index is top-down, which is the whole of the `y` term:
        // image row `py` sits at context `y = origin + height - py - 1`, and that must be 0.
        context.draw(
            cgImage,
            in: CGRect(
                x: CGFloat(-px), y: CGFloat(py + 1 - cgImage.height),
                width: CGFloat(cgImage.width), height: CGFloat(cgImage.height),
            ),
        )
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}

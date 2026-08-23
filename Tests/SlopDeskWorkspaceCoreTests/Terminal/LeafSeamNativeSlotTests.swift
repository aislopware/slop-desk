#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the ONE property of docs/56 stage F's `nativeShared` widening that a compiler cannot: that it is
/// **additive**.
///
/// Both leaf pixel seams now have two shapes — a SwiftUI `AnyView` and a platform `NSView` — and the
/// SwiftUI one is not legacy: the phone has no `NSView`, so `shared` is iOS's only shape and must survive
/// every AppKit increment. The failure this guards is not a crash, it is a deletion that looks like a
/// cleanup: fold `shared` into `nativeShared`, or make `makeNative` fall back to wrapping `shared` in an
/// `NSHostingView`, and the iOS build keeps compiling while the Mac quietly reacquires the full-bleed
/// hit-claim risk 2 exists to prevent.
///
/// What is NOT here, and cannot be: whether the registered factory actually renders anything. The only
/// conformer of either protocol lives in `ThirdParty/ghostty/integration/GhosttySurface/` and
/// `SlopDeskVideoClient`, neither reachable from a headless `swift build` — the embedder is not in any
/// `Package.swift` target at all. Those halves are verified by `slopdesk-ops enable-renderer macos` +
/// `xcodebuild`, by hand.
@MainActor
final class LeafSeamNativeSlotTests: XCTestCase {
    /// A stand-in surface: the seam promises an `NSView` and two pushes, and nothing about what is in it.
    private final class StubTerminalSurface: NSView, TerminalSurfaceHosting {
        /// The `isFocused` the FACTORY was called with, recorded on the stub rather than in a captured
        /// local so the escaping factory closure mutates a reference and never a `var` it captured.
        var mountFocus: Bool?
        var focusPushes: [Bool] = []
        var detachCount = 0
        var surfaceView: NSView { self }
        func setPaneFocused(_ isFocused: Bool) { focusPushes.append(isFocused) }
        func detachSurface() { detachCount += 1 }
    }

    private final class StubRemoteSurface: NSView, RemoteSurfaceHosting {
        /// The gates the FACTORY was called with (see ``StubTerminalSurface/mountFocus``).
        var mountGates: (isActive: Bool, inputEnabled: Bool, backgroundPointer: Bool)?
        var gatePushes: [(isActive: Bool, inputEnabled: Bool, backgroundPointer: Bool)] = []
        var detachCount = 0
        var surfaceView: NSView { self }
        func setPaneGates(isActive: Bool, inputEnabled: Bool, backgroundPointer: Bool) {
            gatePushes.append((isActive, inputEnabled, backgroundPointer))
        }

        func detachSurface() { detachCount += 1 }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            TerminalRendererFactory.shared = nil
            TerminalRendererFactory.nativeShared = nil
            VideoWindowFactory.shared = nil
            VideoWindowFactory.nativeShared = nil
        }
        super.tearDown()
    }

    /// The headless build registers neither shape, and `makeNative` says so by returning `nil` rather than
    /// by synthesizing a placeholder: an AppKit canvas that gets `nil` mounts the BUILD-STATUS view itself,
    /// exactly as the SwiftUI leaf does when `shared` is nil.
    func testNoFactoryRegisteredYieldsNoNativeSurface() {
        XCTAssertNil(TerminalRendererFactory.nativeShared)
        XCTAssertNil(VideoWindowFactory.nativeShared)
        XCTAssertNil(TerminalRendererFactory.makeNative(model: TerminalViewModel(), isFocused: true))
        XCTAssertNil(VideoWindowFactory.makeNative(RemoteWindowDescriptor(title: "w", windowID: 1)))
    }

    /// Registering the native shape leaves the SwiftUI shape alone, and vice versa. The two slots are
    /// independent on purpose — the app target registers both, and a canvas asks for the one it can draw.
    func testTheTwoShapesAreIndependentSlots() {
        TerminalRendererFactory.nativeShared = { _, _ in StubTerminalSurface() }
        XCTAssertNil(
            TerminalRendererFactory.shared,
            "registering the AppKit shape must not touch the SwiftUI shape — it is iOS's only one",
        )

        TerminalRendererFactory.shared = { _, _ in AnyView(EmptyView()) }
        XCTAssertNotNil(TerminalRendererFactory.nativeShared, "registering the SwiftUI shape must not clear the other")

        VideoWindowFactory.nativeShared = { _, _ in StubRemoteSurface() }
        XCTAssertNil(VideoWindowFactory.shared)
        VideoWindowFactory.shared = { _, _ in AnyView(EmptyView()) }
        XCTAssertNotNil(VideoWindowFactory.nativeShared)
    }

    /// `makeNative` hands back exactly what the factory built, and carries the mount-time focus through the
    /// factory's own argument rather than by pushing it afterwards — a canvas that had to push focus after
    /// mounting would flash an unfocused cursor on every pane it opens.
    func testTerminalNativeFactoryCarriesMountFocus() {
        let stub = StubTerminalSurface()
        TerminalRendererFactory.nativeShared = { _, isFocused in
            stub.mountFocus = isFocused
            return stub
        }

        let host = TerminalRendererFactory.makeNative(model: TerminalViewModel(), isFocused: false)
        XCTAssertIdentical(host?.surfaceView, stub)
        XCTAssertEqual(stub.mountFocus, false)
        XCTAssertEqual(stub.focusPushes, [], "mount focus rides the factory argument, not a follow-up push")

        host?.setPaneFocused(true)
        host?.detachSurface()
        XCTAssertEqual(stub.focusPushes, [true])
        XCTAssertEqual(stub.detachCount, 1)
    }

    /// The video half's per-render gates. SwiftUI re-evaluates the whole `RemotePaneContext` every pass; an
    /// AppKit canvas has no such pass, so the read-only LOCK reaches the host only if someone calls this.
    func testVideoNativeFactoryCarriesMountContextAndLaterGates() {
        let stub = StubRemoteSurface()
        VideoWindowFactory.nativeShared = { _, context in
            stub.mountGates = (context.isActive, context.inputEnabled, context.backgroundPointer)
            return stub
        }

        let context = RemotePaneContext.videoLeaf(
            isActive: true, readOnly: true, bindKeyInjector: { _ in },
        )
        let host = VideoWindowFactory.makeNative(
            RemoteWindowDescriptor(title: "w", windowID: 7), context: context,
        )
        XCTAssertIdentical(host?.surfaceView, stub)
        XCTAssertEqual(stub.mountGates?.isActive, true)
        XCTAssertEqual(stub.mountGates?.inputEnabled, false, "read-only ⇒ the mount-time input gate is already shut")

        host?.setPaneGates(isActive: false, inputEnabled: true, backgroundPointer: true)
        XCTAssertEqual(stub.gatePushes.count, 1)
        XCTAssertEqual(stub.gatePushes.first?.inputEnabled, true)
    }
}
#endif

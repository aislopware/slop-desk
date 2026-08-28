#if canImport(AppKit) || canImport(UIKit)
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins what the compiler cannot about the two leaf pixel seams: that an unregistered factory yields
/// `nil` rather than a synthesized placeholder, and that the MOUNT-time state rides the factory's own
/// argument instead of a follow-up push.
///
/// ⚠️ THIS FILE USED TO PIN THE OPPOSITE OF WHAT IT NOW PINS, and the reversal is the point. Each seam
/// had TWO slots — a SwiftUI `AnyView` one and a platform-view one — and this file's whole subject was
/// that they were **additive**: a test named `testTheTwoShapesAreIndependentSlots` asserted that
/// registering either left the other alone, and the doc comment warned that "the failure this guards
/// is not a crash, it is a deletion that looks like a cleanup: fold `shared` into `nativeShared` …
/// and the iOS build keeps compiling while the Mac quietly reacquires the full-bleed hit-claim".
///
/// That guard rested on one premise, stated in it: "the phone has no `NSView`, so `shared` is iOS's
/// only shape and must survive every AppKit increment". The phone draws in UIKit now and has a
/// `UIView`, so the premise is false and the fold it forbade became the correct move. The two slots
/// are one slot; the hit-claim it worried about is prevented by the SwiftUI slot not existing at all,
/// which is strictly stronger than a test asking callers not to use it.
///
/// The lesson worth keeping: a test that pins an ARRANGEMENT rather than a BEHAVIOUR expires when the
/// arrangement's premise does, and it expires silently — it kept passing right up until the premise
/// was checked by hand. The three tests below pin behaviour, which is why they survived the fold.
///
/// What is NOT here, and cannot be: whether a registered factory actually renders anything. The only
/// conformer of either protocol lives in `ThirdParty/ghostty/integration/GhosttySurface/` and
/// `SlopDeskVideoClient`, neither reachable from a headless `swift build` — the embedder is not in any
/// `Package.swift` target at all. Those halves are verified by `slopdesk-ops enable-renderer macos` +
/// `xcodebuild`, by hand.
@MainActor
final class LeafSeamSlotTests: XCTestCase {
    /// A stand-in surface: the seam promises a ``PlatformView`` and two pushes, and nothing about what
    /// is in it.
    private final class StubTerminalSurface: PlatformView, TerminalSurfaceHosting {
        /// The `isFocused` the FACTORY was called with, recorded on the stub rather than in a captured
        /// local so the escaping factory closure mutates a reference and never a `var` it captured.
        var mountFocus: Bool?
        var focusPushes: [Bool] = []
        var detachCount = 0
        var surfaceView: PlatformView { self }
        func setPaneFocused(_ isFocused: Bool) { focusPushes.append(isFocused) }
        func detachSurface() { detachCount += 1 }
    }

    private final class StubRemoteSurface: PlatformView, RemoteSurfaceHosting {
        /// The gates the FACTORY was called with (see ``StubTerminalSurface/mountFocus``).
        var mountGates: (isActive: Bool, inputEnabled: Bool, backgroundPointer: Bool)?
        var gatePushes: [(isActive: Bool, inputEnabled: Bool, backgroundPointer: Bool)] = []
        var detachCount = 0
        var surfaceView: PlatformView { self }
        func setPaneGates(isActive: Bool, inputEnabled: Bool, backgroundPointer: Bool) {
            gatePushes.append((isActive, inputEnabled, backgroundPointer))
        }

        func detachSurface() { detachCount += 1 }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            TerminalRendererFactory.shared = nil
            VideoWindowFactory.shared = nil
        }
        super.tearDown()
    }

    /// The headless build registers no factory, and `make` says so by returning `nil` rather than by
    /// synthesizing a placeholder: a canvas that gets `nil` mounts the BUILD-STATUS view itself,
    /// because the canvas is the only thing that knows where that belongs in its own layout.
    func testNoFactoryRegisteredYieldsNoSurface() {
        XCTAssertNil(TerminalRendererFactory.shared)
        XCTAssertNil(VideoWindowFactory.shared)
        XCTAssertNil(TerminalRendererFactory.make(model: TerminalViewModel(), isFocused: true))
        XCTAssertNil(VideoWindowFactory.make(RemoteWindowDescriptor(title: "w", windowID: 1)))
    }

    /// `make` hands back exactly what the factory built, and carries the mount-time focus through the
    /// factory's own argument rather than by pushing it afterwards — a canvas that had to push focus
    /// after mounting would flash an unfocused cursor on every pane it opens.
    func testTerminalFactoryCarriesMountFocus() {
        let stub = StubTerminalSurface()
        TerminalRendererFactory.shared = { _, isFocused in
            stub.mountFocus = isFocused
            return stub
        }

        let host = TerminalRendererFactory.make(model: TerminalViewModel(), isFocused: false)
        XCTAssertIdentical(host?.surfaceView, stub)
        XCTAssertEqual(stub.mountFocus, false)
        XCTAssertEqual(stub.focusPushes, [], "mount focus rides the factory argument, not a follow-up push")

        host?.setPaneFocused(true)
        host?.detachSurface()
        XCTAssertEqual(stub.focusPushes, [true])
        XCTAssertEqual(stub.detachCount, 1)
    }

    /// The video half's per-render gates. A representable's `update…` pass re-evaluated the whole
    /// `RemotePaneContext` every render; an imperative canvas has no such pass, so the read-only LOCK
    /// reaches the host only if someone calls this.
    func testVideoFactoryCarriesMountContextAndLaterGates() {
        let stub = StubRemoteSurface()
        VideoWindowFactory.shared = { _, context in
            stub.mountGates = (context.isActive, context.inputEnabled, context.backgroundPointer)
            return stub
        }

        let context = RemotePaneContext.videoLeaf(
            isActive: true, readOnly: true, bindKeyInjector: { _ in },
        )
        let host = VideoWindowFactory.make(
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

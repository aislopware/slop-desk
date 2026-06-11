import XCTest
@testable import AislopdeskClientUI

/// WF5 / docs/22 §7 — pins the `RemoteWindowPanel` Close-row migration: inside the workspace a
/// `.remoteGUI` leaf is wrapped in ``PaneChromeView`` whose header owns the per-pane close, so the
/// panel's inline Close row is redundant and ``RemoteWindowPanel/init(model:showCloseButton:)``
/// defaults `showCloseButton` to **false**. A standalone caller (sheet / preview) opts back in with
/// `showCloseButton: true`.
///
/// `RemoteWindowPanel` is a SwiftUI `View`; its Close-row *visibility* lives in `body` and cannot be
/// asserted without ViewInspector (not a dependency of this target). So per the plan this file pins
/// the two things that ARE deterministically testable, dependency-free:
///
/// 1. **Compile-time smoke** that BOTH initializer shapes exist and that `showCloseButton` has a
///    default — `RemoteWindowPanel(model:)` (the workspace/default form) and
///    `RemoteWindowPanel(model:showCloseButton:)` (the explicit form). If the migration dropped the
///    default-`false` parameter, or kept the old single-arg-only initializer, this file fails to
///    COMPILE — a stronger guarantee than a runtime assert.
/// 2. **Model-level regression** that the `RemoteWindowModel` `open()` / `close()` / `canOpen` /
///    `hasEndpoint` logic the panel binds to is UNCHANGED by the panel edit. The Close row's only
///    behavior is `model.close()`; we prove `close()` still clears `active` directly on the model
///    (no view needed) and that the open/endpoint contract still holds.
///
/// No video frameworks, no network, no `HostServer`, no `AislopdeskClient` — pure `@MainActor` logic that
/// mirrors the existing `RemoteWindowModelTests` style.
@MainActor
final class RemoteWindowCloseButtonTests: XCTestCase {

    // MARK: - Initializer shape (compile-time smoke)

    /// Both initializer forms must compile. The default-arg form proves `showCloseButton` has a
    /// default; if the default were removed this line would not compile. We construct the panel and
    /// assert it is non-`Optional` (a trivially-true runtime check whose real job is to FORCE the
    /// compiler to resolve the initializer overloads above).
    func testDefaultInitializerOmitsCloseButtonArgument() {
        let model = RemoteWindowModel(windowID: "1")
        // Default form — workspace usage. Must compile WITHOUT passing showCloseButton.
        let panel = RemoteWindowPanel(model: model)
        XCTAssertNotNil(panel as RemoteWindowPanel?,
                        "RemoteWindowPanel(model:) must exist with showCloseButton defaulting to false")
    }

    /// The explicit form (standalone callers that want the inline Close) must also compile, for both
    /// `true` and `false`. Constructing all three shapes pins the full initializer surface.
    func testExplicitInitializerAcceptsBothVisibilities() {
        let model = RemoteWindowModel(windowID: "1")
        let hidden = RemoteWindowPanel(model: model, showCloseButton: false)
        let shown = RemoteWindowPanel(model: model, showCloseButton: true)
        XCTAssertNotNil(hidden as RemoteWindowPanel?)
        XCTAssertNotNil(shown as RemoteWindowPanel?)
    }

    // MARK: - Model regression: the panel edit must not have changed model behavior

    /// The Close row's sole action is `model.close()`. Whether the row is drawn or hidden, the model
    /// `close()` contract must be identical: it clears `active` back to `nil` (form re-shown / live
    /// view torn down). Asserted directly on the model — no view, no ViewInspector.
    func testCloseRowActionStillClearsActive() {
        let model = RemoteWindowModel(windowID: "1")
        model.open()
        XCTAssertNotNil(model.active, "precondition: open() makes the panel show the live view")
        model.close()   // exactly what the Close row's button invokes
        XCTAssertNil(model.active, "close() must still clear active regardless of Close-row visibility")
    }

    /// Hiding the Close row must NOT touch the open / endpoint path the panel switches on
    /// (`model.active` non-nil ⇒ live `VideoWindowFactory.make` view; nil ⇒ entry form). Pins the
    /// unchanged `open()` → complete-endpoint descriptor contract the panel relies on.
    func testOpenStillProducesLiveEndpointDescriptor() {
        let model = RemoteWindowModel(
            target: { ConnectionTarget(host: "h.local", port: 7420, mediaPort: 9000, cursorPort: 9001) },
            windowID: "42", title: "Safari"
        )
        model.open()
        guard let d = model.active else { return XCTFail("open() should set active") }
        XCTAssertEqual(d.host, "h.local", "host comes from the app target")
        XCTAssertEqual(d.mediaPort, 9000)
        XCTAssertEqual(d.cursorPort, 9001)
        XCTAssertEqual(d.windowID, 42)
        XCTAssertTrue(d.hasEndpoint,
                      "descriptor still carries a live endpoint ⇒ panel takes the live factory path")
    }

    /// The `canOpen` gate (which drives the entry-form Open button) now requires only a valid window id —
    /// host + UDP ports come from the app-global target, not the per-pane form (docs/31).
    func testCanOpenGateRequiresWindowID() {
        let m = RemoteWindowModel()                 // empty windowID
        XCTAssertFalse(m.canOpen)
        m.windowID = "12345"
        XCTAssertTrue(m.canOpen, "a valid window id ⇒ can open")
        m.windowID = "nope"
        XCTAssertFalse(m.canOpen, "an unparseable window id cannot open")
    }

    /// A no-endpoint descriptor (preview / placeholder path) is still NOT live — the panel renders
    /// the gated placeholder for it. Pins `hasEndpoint` unchanged.
    func testTitleOnlyDescriptorStillHasNoEndpoint() {
        let d = RemoteWindowDescriptor(title: "x", windowID: 3)
        XCTAssertFalse(d.hasEndpoint, "no host ⇒ no live endpoint (chrome-only/placeholder path)")
    }
}

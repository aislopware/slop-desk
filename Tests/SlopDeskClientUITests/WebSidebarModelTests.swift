// WebSidebarModelTests — the Web panel's pure decisions: which surface an ensure round means, what
// URL the frontend is loaded from, what a typed address resolves to, and which page stays selected
// across a list round.
//
// Nothing here builds a web view or a socket (hang-safety). The parts that do are behind
// ``WebTargetControlling`` and in `WebInspectorWebView`, and the fake control below is what lets the
// action paths be exercised at all.

#if os(macOS)
import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class WebSidebarPhaseTests: XCTestCase {
    private func endpoint(_ state: MetadataCodec.ServiceState, port: UInt16) -> MetadataCodec.ServiceEndpoint {
        MetadataCodec.ServiceEndpoint(state: state, port: port)
    }

    func testAReadyEndpointBecomesAnAddress() {
        XCTAssertEqual(
            WebSidebarModel.phase(for: endpoint(.ready, port: 51000), host: "127.0.0.1"),
            .ready(host: "127.0.0.1", port: 51000),
        )
    }

    func testNoAnswerAtAllIsOfflineAndKeepsPolling() {
        XCTAssertEqual(WebSidebarModel.phase(for: nil, host: "h"), .offline)
    }

    func testAStartingHostIsNotAnErrorSurface() {
        XCTAssertEqual(WebSidebarModel.phase(for: endpoint(.starting, port: 0), host: "h"), .starting)
    }

    func testOnlyAMissingBrowserRendersTheInstallHint() {
        XCTAssertEqual(WebSidebarModel.phase(for: endpoint(.unavailable, port: 0), host: "h"), .unavailable)
    }

    func testAReadyEndpointWithNoUsableAddressDegradesRatherThanTraps() {
        XCTAssertEqual(WebSidebarModel.phase(for: endpoint(.ready, port: 0), host: "h"), .offline)
        XCTAssertEqual(WebSidebarModel.phase(for: endpoint(.ready, port: 51000), host: nil), .offline)
        XCTAssertEqual(WebSidebarModel.phase(for: endpoint(.ready, port: 51000), host: ""), .offline)
    }

    func testAnUnknownFutureStateKeepsPollingRatherThanClaimingNoBrowser() {
        let future = MetadataCodec.ServiceEndpoint(stateByte: 99, port: 0)
        XCTAssertEqual(WebSidebarModel.phase(for: future, host: "h"), .starting)
    }
}

@MainActor
final class WebFrontendURLTests: XCTestCase {
    func testTheFrontendIsServedByTheBrowserItself() {
        // Nothing of DevTools is vendored: the URL points at the browser's own copy, which is
        // therefore always the build that matches the protocol behind it.
        let url = WebSidebarModel.frontendURL(host: "127.0.0.1", port: 51000, targetID: "ABC123")
        XCTAssertEqual(url?.host, "127.0.0.1")
        XCTAssertEqual(url?.port, 51000)
        XCTAssertEqual(url?.path, "/devtools/inspector.html")
    }

    func testTheDebuggerQueryCarriesNoScheme() {
        // The frontend prepends `ws://` itself; a full URL in this query yields a frontend that
        // renders and never connects.
        let url = WebSidebarModel.frontendURL(host: "127.0.0.1", port: 51000, targetID: "ABC123")
        let query = URLComponents(url: XCTUnwrap2(url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "ws" }?.value
        XCTAssertEqual(query, "127.0.0.1:51000/devtools/page/ABC123")
    }

    func testAnIncompleteAddressYieldsNoURLRatherThanABrokenOne() {
        XCTAssertNil(WebSidebarModel.frontendURL(host: "", port: 51000, targetID: "A"))
        XCTAssertNil(WebSidebarModel.frontendURL(host: "127.0.0.1", port: 0, targetID: "A"))
        XCTAssertNil(WebSidebarModel.frontendURL(host: "127.0.0.1", port: 51000, targetID: ""))
    }

    /// `XCTUnwrap` is throwing; these assertions read better without a `try` on each line.
    private func XCTUnwrap2(_ url: URL?) -> URL {
        guard let url else {
            XCTFail("expected a URL")
            return URL(fileURLWithPath: "/")
        }
        return url
    }
}

@MainActor
final class WebAddressNormalisationTests: XCTestCase {
    func testAnAddressThatNamesItsSchemeIsTakenAsWritten() {
        XCTAssertEqual(WebSidebarModel.normalizedAddress("https://example.com"), "https://example.com")
        XCTAssertEqual(WebSidebarModel.normalizedAddress("http://example.com/x?y=1"), "http://example.com/x?y=1")
        // The addresses a person types deliberately, and which must not be rewritten.
        XCTAssertEqual(WebSidebarModel.normalizedAddress("about:blank"), "about:blank")
        XCTAssertEqual(WebSidebarModel.normalizedAddress("file:///tmp/index.html"), "file:///tmp/index.html")
        XCTAssertEqual(WebSidebarModel.normalizedAddress("chrome://version"), "chrome://version")
    }

    func testTheHostsOwnDevServerGetsPlainHTTP() {
        // The whole reason the browser runs on the host: `localhost` here is the HOST's localhost,
        // where the dev server is. An `https://` default would name a port nothing is serving.
        XCTAssertEqual(WebSidebarModel.normalizedAddress("localhost:5173"), "http://localhost:5173")
        XCTAssertEqual(WebSidebarModel.normalizedAddress("127.0.0.1:8080/app"), "http://127.0.0.1:8080/app")
        XCTAssertEqual(WebSidebarModel.normalizedAddress("app.localhost:3000"), "http://app.localhost:3000")
    }

    func testEverythingElseThatLooksLikeAHostGetsHTTPS() {
        XCTAssertEqual(WebSidebarModel.normalizedAddress("example.com"), "https://example.com")
        XCTAssertEqual(WebSidebarModel.normalizedAddress("example.com/path"), "https://example.com/path")
        XCTAssertEqual(
            WebSidebarModel.normalizedAddress("staging.example.com:8443"),
            "https://staging.example.com:8443",
        )
    }

    func testProseIsNotAnAddress() {
        // This is an address bar, not a search box: silently shipping what someone typed to a search
        // engine would send the contents of a private page's URL bar off the machine.
        XCTAssertNil(WebSidebarModel.normalizedAddress("how do i center a div"))
        XCTAssertNil(WebSidebarModel.normalizedAddress("localhost"))
        XCTAssertNil(WebSidebarModel.normalizedAddress(""))
        XCTAssertNil(WebSidebarModel.normalizedAddress("   "))
    }

    func testSurroundingWhitespaceIsForgiven() {
        XCTAssertEqual(WebSidebarModel.normalizedAddress("  example.com \n"), "https://example.com")
    }
}

@MainActor
final class WebTargetSelectionTests: XCTestCase {
    private func target(_ id: String, url: String = "about:blank") -> WebTarget {
        WebTarget(id: id, title: "", url: url)
    }

    func testAStillPresentSelectionSurvivesTheListRound() {
        // The list is re-read every couple of seconds; re-selecting each round would tear the
        // frontend down and rebuild it, taking the user's open panel and console history with it.
        XCTAssertEqual(
            WebSidebarModel.resolvedSelection(current: "B", targets: [target("A"), target("B")]), "B",
        )
    }

    func testAClosedPageFallsBackToTheFirstOne() {
        XCTAssertEqual(
            WebSidebarModel.resolvedSelection(current: "GONE", targets: [target("A"), target("B")]), "A",
        )
    }

    func testAFreshBrowserLandsSomewhere() {
        XCTAssertEqual(WebSidebarModel.resolvedSelection(current: nil, targets: [target("A")]), "A")
    }

    func testAnEmptyListSelectsNothing() {
        XCTAssertNil(WebSidebarModel.resolvedSelection(current: "A", targets: []))
    }

    func testATabIsNamedByWhateverItCanSay() {
        XCTAssertEqual(WebTarget(id: "1", title: "Docs", url: "https://x").displayName, "Docs")
        XCTAssertEqual(WebTarget(id: "1", title: "", url: "https://x").displayName, "https://x")
        XCTAssertEqual(WebTarget(id: "1", title: "", url: "about:blank").displayName, "Untitled")
    }
}

/// The action paths, against a fake browser.
@MainActor
final class WebSidebarActionTests: XCTestCase {
    /// Single-threaded by construction: every call is awaited from this `@MainActor` suite, so the
    /// state below needs no lock of its own.
    @MainActor
    private final class FakeControl: WebTargetControlling {
        private var stored: [WebTarget]
        private(set) var navigations: [(id: String, url: String)] = []
        private(set) var opened: [String] = []
        private(set) var closed: [String] = []
        private(set) var activated: [String] = []
        var refuses = false

        init(targets: [WebTarget]) { stored = targets }

        // The protocol is async; a fake that answers from memory has nothing to await, and dropping
        // `async` would not conform.
        // swiftlint:disable async_without_await
        func targets(host _: String, port _: UInt16) async -> [WebTarget] {
            stored
        }

        func navigate(host _: String, port _: UInt16, targetID: String, url: String) async -> Bool {
            if refuses { return false }
            navigations.append((targetID, url))
            stored = stored.map { $0.id == targetID ? WebTarget(id: $0.id, title: $0.title, url: url) : $0 }
            return true
        }

        func newTarget(host _: String, port _: UInt16, url: String) async -> WebTarget? {
            if refuses { return nil }
            opened.append(url)
            let target = WebTarget(id: "NEW\(opened.count)", title: "", url: url)
            stored.append(target)
            return target
        }

        func close(host _: String, port _: UInt16, targetID: String) async -> Bool {
            if refuses { return false }
            closed.append(targetID)
            stored.removeAll { $0.id == targetID }
            return true
        }

        func activate(host _: String, port _: UInt16, targetID: String) async -> Bool {
            if refuses { return false }
            activated.append(targetID)
            return true
        }
        // swiftlint:enable async_without_await
    }

    /// A model already at `.ready`, without going through the poll loop (which would need a host).
    private func readyModel(_ control: FakeControl) async -> WebSidebarModel {
        let model = WebSidebarModel(control: control)
        await model.poll(
            host: { "127.0.0.1" },
            ensure: { MetadataCodec.ServiceEndpoint(state: .ready, port: 51000) },
        )
        await model.refreshTargets()
        return model
    }

    func testTheFirstListRoundSelectsAPageAndFillsTheAddress() async {
        let control = FakeControl(targets: [WebTarget(id: "A", title: "", url: "https://example.com/")])
        let model = await readyModel(control)
        XCTAssertEqual(model.selection, "A")
        XCTAssertEqual(model.address, "https://example.com/")
        XCTAssertNotNil(model.frontendURL)
    }

    // A backgrounded page is not composited, so the frontend attached to it draws nothing and says
    // "The tab is inactive". Every path that moves the selection must front the page in the browser
    // too — the panel's selection and the browser's front tab are the SAME fact.
    func testEveryPathThatMovesTheSelectionFrontsThePageInTheBrowser() async {
        let control = FakeControl(targets: [
            WebTarget(id: "A", title: "", url: "https://a/"),
            WebTarget(id: "B", title: "", url: "https://b/"),
        ])
        let model = await readyModel(control)
        XCTAssertEqual(control.activated, ["A"], "the first list round fronts what it selects")

        await model.select("B")
        XCTAssertEqual(control.activated, ["A", "B"])

        await model.select("B")
        XCTAssertEqual(control.activated, ["A", "B"], "re-selecting the current page is not a switch")

        await model.openTab(url: "https://c/")
        XCTAssertEqual(control.activated, ["A", "B", "NEW1"])

        await model.closeTab("NEW1")
        XCTAssertEqual(control.activated.last, model.selection)
    }

    func testSubmittingNavigatesTheCURRENTPageRatherThanOpeningAnother() async {
        // A new target means a new frontend, which means the inspector session the user is in the
        // middle of is gone. Navigating in place is what makes this an address bar.
        let control = FakeControl(targets: [WebTarget(id: "A", title: "", url: "about:blank")])
        let model = await readyModel(control)
        model.address = "example.com"
        await model.submitAddress()

        XCTAssertEqual(control.navigations.map(\.url), ["https://example.com"])
        XCTAssertTrue(control.opened.isEmpty)
        XCTAssertEqual(model.selection, "A", "the frontend stays attached")
        XCTAssertNil(model.failure)
    }

    func testARefusedNavigationIsReported() async {
        let control = FakeControl(targets: [WebTarget(id: "A", title: "", url: "about:blank")])
        let model = await readyModel(control)
        control.refuses = true
        model.address = "example.com"
        await model.submitAddress()

        XCTAssertNotNil(model.failure)
    }

    func testSubmittingProseDoesNothingAtAll() async {
        let control = FakeControl(targets: [WebTarget(id: "A", title: "", url: "about:blank")])
        let model = await readyModel(control)
        model.address = "not a url"
        await model.submitAddress()

        XCTAssertTrue(control.navigations.isEmpty)
        XCTAssertEqual(model.address, "not a url", "what was typed is kept, not rewritten")
    }

    func testOpeningATabSelectsIt() async {
        let control = FakeControl(targets: [WebTarget(id: "A", title: "", url: "about:blank")])
        let model = await readyModel(control)
        await model.openTab()

        XCTAssertEqual(model.selection, "NEW1")
        XCTAssertEqual(control.opened, ["about:blank"])
    }

    func testClosingTheSelectedTabMovesToAnother() async {
        let control = FakeControl(targets: [
            WebTarget(id: "A", title: "", url: "https://a/"),
            WebTarget(id: "B", title: "", url: "https://b/"),
        ])
        let model = await readyModel(control)
        await model.select("A")
        await model.closeTab("A")

        XCTAssertEqual(control.closed, ["A"])
        XCTAssertEqual(model.selection, "B")
        XCTAssertEqual(model.address, "https://b/")
    }

    func testAPageThatNavigatesOnItsOwnUpdatesTheAddress() async {
        let control = FakeControl(targets: [WebTarget(id: "A", title: "", url: "https://a/")])
        let model = await readyModel(control)
        _ = await control.navigate(host: "", port: 0, targetID: "A", url: "https://a/next")
        await model.refreshTargets()

        XCTAssertEqual(model.address, "https://a/next")
    }

    func testTheAddressIsNotRewrittenUnderACursorMidURL() async {
        // The field is an input first and a readout second: a redirect landing while someone is
        // halfway through typing must not take what they wrote.
        let control = FakeControl(targets: [WebTarget(id: "A", title: "", url: "https://a/")])
        let model = await readyModel(control)
        model.beginEditingAddress()
        model.address = "example.co"
        _ = await control.navigate(host: "", port: 0, targetID: "A", url: "https://a/redirected")
        await model.refreshTargets()

        XCTAssertEqual(model.address, "example.co")
        model.endEditingAddress()
        await model.refreshTargets()
        XCTAssertEqual(model.address, "https://a/redirected")
    }
}

final class WebInspectorThemeSeedTests: XCTestCase {
    // Pins the ONE character of this seed that is not self-evident. DevTools reads its theme from
    // the kebab-case `ui-theme`; the older `uiTheme` is still writable and read by nobody, so a
    // regression to it leaves storage looking correct and the frontend coming up light — measured
    // against Chrome 150 (`docs/49`). Nothing here touches WebKit.
    func testTheThemeSeedNamesTheKeyDevToolsActuallyReads() {
        let source = WebInspectorWebViewPool.themeSeedSource
        XCTAssertTrue(source.contains("'ui-theme'"))
        XCTAssertFalse(source.contains("'uiTheme'"))
        XCTAssertTrue(source.contains("'\"dark\"'"))
        // A seed, not a policy: it must read before it writes.
        XCTAssertTrue(source.contains("if (!window.localStorage.getItem("))
    }
}
#endif

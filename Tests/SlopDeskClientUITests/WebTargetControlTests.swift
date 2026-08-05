// WebTargetControlTests — the browser wire's pure parts: what the panel asks for, and what it makes
// of the answers.
//
// The fixtures are Chrome's real shapes, captured 2026-08-05 against a running headless browser.
// Nothing here performs a request (hang-safety); the request path itself is covered by the host's
// `scripts/check-web.sh`, which drives a real browser through a real relay.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class WebTargetControlTests: XCTestCase {
    private let listFixture = """
    [ {
       "description": "",
       "id": "4F81CF6B6DBDD7A7ACFBEBBD255283B9",
       "title": "Chrome Web Store Payments",
       "type": "background_page",
       "url": "chrome-extension://nmmhkkegccagdldgiimedpiccmgmieda/_generated_background_page.html",
       "webSocketDebuggerUrl": "ws://127.0.0.1:55402/devtools/page/4F81CF6B6DBDD7A7ACFBEBBD255283B9"
    }, {
       "description": "",
       "id": "10D9B16CB51ECA1AF784A9E15B1674C2",
       "title": "Example Domain",
       "type": "page",
       "url": "https://example.com/",
       "webSocketDebuggerUrl": "ws://127.0.0.1:55402/devtools/page/10D9B16CB51ECA1AF784A9E15B1674C2"
    }, {
       "description": "",
       "id": "084F08A3B21D0542BFE9AC1BBDAB5DDF",
       "title": "",
       "type": "page",
       "url": "about:blank",
       "webSocketDebuggerUrl": "ws://127.0.0.1:55402/devtools/page/084F08A3B21D0542BFE9AC1BBDAB5DDF"
    } ]
    """

    func testOnlyPagesReachTheTabMenu() {
        // A real profile's list carries extension background pages and service workers. None of them
        // is a tab anyone opened, and the address bar cannot move any of them.
        let targets = WebTargetControl.decodeTargets(Data(listFixture.utf8))
        XCTAssertEqual(targets.map(\.id), ["10D9B16CB51ECA1AF784A9E15B1674C2", "084F08A3B21D0542BFE9AC1BBDAB5DDF"])
        XCTAssertEqual(targets.first?.title, "Example Domain")
        XCTAssertEqual(targets.first?.url, "https://example.com/")
    }

    func testAMalformedListIsEmptyRatherThanATrap() {
        XCTAssertTrue(WebTargetControl.decodeTargets(Data()).isEmpty)
        XCTAssertTrue(WebTargetControl.decodeTargets(Data("{}".utf8)).isEmpty)
        XCTAssertTrue(WebTargetControl.decodeTargets(Data("[{\"type\":\"page\"}]".utf8)).isEmpty)
    }

    func testANewTabIsDecodedFromTheSingleObjectItAnswersWith() {
        let fixture = """
        {
           "id": "10D9B16CB51ECA1AF784A9E15B1674C2",
           "title": "",
           "type": "page",
           "url": "https://example.com/"
        }
        """
        let target = WebTargetControl.decodeTarget(Data(fixture.utf8))
        XCTAssertEqual(target?.id, "10D9B16CB51ECA1AF784A9E15B1674C2")
        XCTAssertEqual(target?.url, "https://example.com/")
    }

    func testTheNavigateMessageIsWellFormedCDP() throws {
        let message = WebTargetControl.navigateMessage(url: "https://example.com/?q=a b&x=\"y\"")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
        )
        XCTAssertEqual(object["method"] as? String, "Page.navigate")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        // The URL survives quotes and spaces intact — the reason this is serialized rather than
        // interpolated into a string literal.
        XCTAssertEqual(params["url"] as? String, "https://example.com/?q=a b&x=\"y\"")
    }

    func testOnlyAResultCountsAsANavigation() {
        // Chrome answers a refusal with an `error` member on the same reply shape. Treating that as
        // success would leave the address bar claiming a page it never reached.
        XCTAssertTrue(WebTargetControl.isNavigateSuccess(.string(
            #"{"id":1,"result":{"frameId":"ABC","loaderId":"DEF","isDownload":false}}"#,
        )))
        XCTAssertFalse(WebTargetControl.isNavigateSuccess(.string(
            #"{"id":1,"error":{"code":-32000,"message":"Cannot navigate to invalid URL"}}"#,
        )))
        XCTAssertFalse(WebTargetControl.isNavigateSuccess(.string("not json")))
        XCTAssertFalse(WebTargetControl.isNavigateSuccess(.data(Data([0x00]))))
    }

    func testEndpointsAreBuiltOnlyFromACompleteAddress() {
        XCTAssertEqual(
            WebTargetControl.endpoint(host: "127.0.0.1", port: 51000, path: "/json/list")?.absoluteString,
            "http://127.0.0.1:51000/json/list",
        )
        XCTAssertNil(WebTargetControl.endpoint(host: "", port: 51000, path: "/json/list"))
        XCTAssertNil(WebTargetControl.endpoint(host: "127.0.0.1", port: 0, path: "/json/list"))
    }

    // The one CDP message that shapes the page. It is an EMULATION override rather than a window
    // resize because an override outranks the window and is the only thing that can displace an
    // override another session left behind — see `WebViewportFit`.
    func testTheFitMessageIsAnEmulationOverrideInWholePoints() throws {
        let text = WebTargetControl.deviceMetricsMessage(size: CGSize(width: 500.4, height: 2355.6))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "Emulation.setDeviceMetricsOverride")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["width"] as? Int, 500)
        XCTAssertEqual(params["height"] as? Int, 2355)
        // Zero means "keep the device's own density": the panel is choosing a shape, not a pixel
        // ratio, and pinning one would make text on a Retina client soft.
        XCTAssertEqual(params["deviceScaleFactor"] as? Int, 0)
        // A browser on the host being fitted to a column is not a phone being emulated.
        XCTAssertEqual(params["mobile"] as? Bool, false)
    }
}
#endif

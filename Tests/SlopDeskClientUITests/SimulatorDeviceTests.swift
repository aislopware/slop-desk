// SimulatorDeviceTests — pins the `/simulators.json` decode and the route table. The fixture is the
// envelope MEASURED off a live `baguette serve`.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class SimulatorDeviceTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    private var measuredEnvelope: Data {
        json("""
        {"running":[{"name":"iPhone 17 Pro","runtime":"iOS 26.5","state":"Booted",
        "udid":"01D1D359-3FC8-424F-B1B1-48A767B46273"}],
        "available":[{"name":"iPhone Air","runtime":"iOS 26.5","state":"Shutdown",
        "udid":"2B0FD506-4988-438A-A877-EAE5385AD6B8"}]}
        """)
    }

    func testTheTwoArraysFoldIntoOneListWithRunningFirst() {
        // The panel renders ONE list — a device does not change identity when it boots, and a list
        // that reorders under the cursor on every poll is the opposite of what someone who just
        // clicked Boot wants.
        let devices = SimulatorDevice.decodeList(measuredEnvelope)
        XCTAssertEqual(devices?.map(\.name), ["iPhone 17 Pro", "iPhone Air"])
        XCTAssertEqual(devices?.map(\.isBooted), [true, false])
        XCTAssertEqual(devices?.first?.runtime, "iOS 26.5")
        XCTAssertEqual(devices?.first?.udid, "01D1D359-3FC8-424F-B1B1-48A767B46273")
    }

    func testTheBootedFlagIsCaseInsensitive() {
        // It drives which affordance the row offers. Getting it wrong shows the button that does
        // nothing.
        let devices = SimulatorDevice.decodeList(json(#"{"running":[{"udid":"u","state":"BOOTED"}]}"#))
        XCTAssertEqual(devices?.first?.isBooted, true)
    }

    func testATransientStateIsCarriedRatherThanRejected() {
        // simctl also reports Booting / Shutting Down / Creating. A closed enum here would turn a
        // state the device passes through into a decode failure for the whole list.
        let devices = SimulatorDevice.decodeList(json(#"{"running":[{"udid":"u","state":"Booting"}]}"#))
        XCTAssertEqual(devices?.first?.state, "Booting")
        XCTAssertEqual(devices?.first?.isBooted, false)
    }

    func testOneMalformedDeviceCannotBlankTheList() {
        // Skipped, not fatal: the panel stays useful when the server grows a field or ships one bad
        // row.
        let devices = SimulatorDevice.decodeList(json("""
        {"available":[{"state":"Shutdown"},{"udid":"good","name":"Real"}]}
        """))
        XCTAssertEqual(devices?.map(\.udid), ["good"])
    }

    func testADeviceMissingItsNameFallsBackToItsIdentity() {
        // A row with no label is still actionable; dropping it would hide a real device.
        let devices = SimulatorDevice.decodeList(json(#"{"available":[{"udid":"abc"}]}"#))
        XCTAssertEqual(devices?.first?.name, "abc")
        XCTAssertEqual(devices?.first?.runtime, "")
    }

    func testOnlyANonObjectTopLevelIsRefused() {
        XCTAssertNil(SimulatorDevice.decodeList(json("[]")))
        XCTAssertNil(SimulatorDevice.decodeList(json("not json")))
        // An object with neither array is an empty device set, not a failure.
        XCTAssertEqual(SimulatorDevice.decodeList(json("{}")), [])
    }

    // MARK: The rendered list

    private func device(_ name: String, booted: Bool) -> SimulatorDevice {
        SimulatorDevice(
            udid: "udid-\(name)", name: name, runtime: "iOS 26.5",
            state: booted ? "Booted" : "Shutdown", isBooted: booted,
        )
    }

    func testRunningLeadsTheListAndEverythingElseFollowsItsFamilyInRankOrder() {
        let entries = SimulatorDeviceList.entries(for: [
            device("iPad Pro 13-inch (M5)", booted: false),
            device("iPhone 17 Pro", booted: true),
            device("iPhone Air", booted: false),
        ])
        XCTAssertEqual(entries.map(\.id), [
            "heading/Running",
            "Running/udid-iPhone 17 Pro",
            "heading/iPhone",
            "iPhone/udid-iPhone Air",
            "heading/iPad",
            "iPad/udid-iPad Pro 13-inch (M5)",
        ])
    }

    func testNothingRunningMeansNoRunningHeadingRatherThanAnEmptyOne() {
        let entries = SimulatorDeviceList.entries(for: [device("iPhone Air", booted: false)])
        XCTAssertEqual(entries.map(\.id), ["heading/iPhone", "iPhone/udid-iPhone Air"])
    }

    func testARowsIdentityChangesWhenItsDeviceChangesSection() {
        // The defect this pins, measured on hardware 2026-08-04: with a heading-plus-nested-`ForEach`
        // per group, two sibling `ForEach`es in one lazy stack shared an element id, and a device that
        // booted moved up into Running still drawing the grey glyph and the Boot button it had in its
        // family group — position followed the state, content did not. A section-qualified id makes
        // the move a remove and an insert, so the row is rebuilt from the device it now is.
        let idle = SimulatorDeviceList.entries(for: [device("iPhone 17", booted: false)])
        let running = SimulatorDeviceList.entries(for: [device("iPhone 17", booted: true)])
        XCTAssertNotEqual(idle.last?.id, running.last?.id)
        XCTAssertEqual(running.last?.id, "Running/udid-iPhone 17")
    }

    // MARK: Endpoints

    func testTheRouteTableMatchesTheServersOwn() {
        let host = "10.0.0.7"
        let port: UInt16 = 54593
        let udid = "01D1D359"
        XCTAssertEqual(
            SimulatorEndpoints.deviceList(host: host, port: port)?.absoluteString,
            "http://10.0.0.7:54593/simulators.json",
        )
        XCTAssertEqual(
            SimulatorEndpoints.boot(host: host, port: port, udid: udid)?.absoluteString,
            "http://10.0.0.7:54593/simulators/01D1D359/boot",
        )
        XCTAssertEqual(
            SimulatorEndpoints.shutdown(host: host, port: port, udid: udid)?.absoluteString,
            "http://10.0.0.7:54593/simulators/01D1D359/shutdown",
        )
        XCTAssertEqual(
            SimulatorEndpoints.definition(host: host, port: port, udid: udid)?.absoluteString,
            "http://10.0.0.7:54593/simulators/01D1D359/definition.json",
        )
        XCTAssertEqual(
            SimulatorEndpoints.statusBar(host: host, port: port, udid: udid)?.absoluteString,
            "http://10.0.0.7:54593/simulators/01D1D359/status-bar",
        )
        // One route, two methods: POST pins, DELETE restores live values. There is no separate
        // clear route to get wrong.
        XCTAssertEqual(
            SimulatorEndpoints.location(host: host, port: port, udid: udid)?.absoluteString,
            "http://10.0.0.7:54593/simulators/01D1D359/location",
        )
    }

    func testTheConsoleSocketPinsTheCompactStyleAndCarriesTheLevelAsAQueryItem() {
        // `style=compact` is not a preference: it is the one style whose line shape
        // `SimulatorLogLine` can split, and a server default of anything else would leave every row
        // unparsed. The level goes straight to the server's `log stream --level`.
        XCTAssertEqual(
            SimulatorEndpoints.logs(
                host: "10.0.0.7", port: 54593, udid: "01D1D359", level: "error",
            )?.absoluteString,
            "ws://10.0.0.7:54593/simulators/01D1D359/logs?level=error&style=compact",
        )
        XCTAssertNil(SimulatorEndpoints.logs(host: "10.0.0.7", port: 0, udid: "u", level: "info"))
    }

    func testTheSettingRoutesCarryTheirArgumentInTheQueryStringAsTheServerExpects() {
        let host = "10.0.0.7"
        let port: UInt16 = 54593
        let udid = "01D1D359"
        XCTAssertEqual(
            SimulatorEndpoints.orientation(
                host: host, port: port, udid: udid, value: "landscape-left",
            )?.absoluteString,
            "http://10.0.0.7:54593/simulators/01D1D359/orientation?value=landscape-left",
        )
        // The nonce is the server's own cache-buster: a capture must be of NOW, and a second one in
        // the same session is exactly the request a cache would answer from its copy of the first.
        XCTAssertEqual(
            SimulatorEndpoints.screenshot(host: host, port: port, udid: udid, nonce: 42)?.absoluteString,
            "http://10.0.0.7:54593/simulators/01D1D359/screenshot.jpg?t=42",
        )
    }

    func testAFileNameIsQueryEscapedRatherThanBreakingTheRoute() {
        // The body is the file, so the name rides the query string — where a space or an ampersand in
        // a build's name would otherwise truncate it or invent a second parameter.
        let url = SimulatorEndpoints.files(
            host: "h", port: 1, udid: "u", name: "My App&Co.ipa",
        )
        XCTAssertEqual(url?.absoluteString, "http://h:1/simulators/u/files?name=My%20App%26Co.ipa")
    }

    func testAServerSuppliedReferenceKeepsItsQueryInsteadOfBeingReEscaped() {
        // Bezel artwork comes back as `bezel.png?buttons=false`. Running that through the UDID
        // builder would escape the `?` into the path — the double-encoding trap, from the other side.
        XCTAssertEqual(
            SimulatorEndpoints.resolve(
                "/simulators/u/bezel.png?buttons=false", host: "h", port: 1,
            )?.absoluteString,
            "http://h:1/simulators/u/bezel.png?buttons=false",
        )
        XCTAssertNil(SimulatorEndpoints.resolve("/a.png", host: "", port: 1))
    }

    func testTheStreamURLAsksForLengthPrefixedNALsOnTheWebsocketScheme() {
        // `avcc` rather than Annex-B is what `CMVideoFormatDescription` wants; asking for the wrong
        // one costs a start-code rewrite per access unit on the hot path.
        XCTAssertEqual(
            SimulatorEndpoints.stream(host: "10.0.0.7", port: 54593, udid: "01D1D359")?.absoluteString,
            "ws://10.0.0.7:54593/simulators/01D1D359/stream?format=avcc&version=v2",
        )
    }

    func testADegenerateEndpointYieldsNoURLRatherThanOneThatFailsAtConnect() {
        // The phase machine reads that nil as "not ready", which is the truth.
        XCTAssertNil(SimulatorEndpoints.deviceList(host: "", port: 54593))
        XCTAssertNil(SimulatorEndpoints.deviceList(host: "10.0.0.7", port: 0))
        XCTAssertNil(SimulatorEndpoints.stream(host: "10.0.0.7", port: 0, udid: "u"))
    }

    func testAUDIDIsEscapedBeforeItBecomesAPathComponent() {
        // Hex-and-dashes today, so this escapes nothing in practice. It matters the day the server
        // accepts a device-set-relative name: an unescaped slash would address a different route.
        XCTAssertEqual(
            SimulatorEndpoints.boot(host: "h", port: 1, udid: "a/b")?.absoluteString,
            "http://h:1/simulators/a%2Fb/boot",
        )
        // …and a dash survives untouched, so the ordinary UDID reaches the server as itself.
        XCTAssertEqual(
            SimulatorEndpoints.boot(host: "h", port: 1, udid: "01D1-3FC8")?.absoluteString,
            "http://h:1/simulators/01D1-3FC8/boot",
        )
    }
}
#endif

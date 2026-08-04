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
            SimulatorEndpoints.chrome(host: host, port: port, udid: udid)?.absoluteString,
            "http://10.0.0.7:54593/simulators/01D1D359/chrome.json",
        )
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

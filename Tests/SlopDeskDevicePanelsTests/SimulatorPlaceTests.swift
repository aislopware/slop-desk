// SimulatorPlaceTests — the coordinate parse, which fails in the one direction that is invisible.
//
// A refused coordinate is a disabled button and nobody is confused. A coordinate parsed WRONG pins
// the device somewhere plausible, the panel reports success, and the only evidence is an app that
// thinks it is in the wrong hemisphere. Hence the range checks and the refusal to guess at a
// separator this file does not recognise.

#if os(macOS)
import CSlopDeskFFI
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskDevicePanels

final class SimulatorPlaceTests: XCTestCase {
    // MARK: Parsing

    func testTheCommaFormEveryMapAppCopiesIsAccepted() {
        // This is the paste the field exists for.
        XCTAssertEqual(
            SimulatorCoordinate.parse("37.334886, -122.008988"),
            SimulatorCoordinate(latitude: 37.334886, longitude: -122.008988),
        )
        XCTAssertEqual(
            SimulatorCoordinate.parse("37.334886,-122.008988"),
            SimulatorCoordinate(latitude: 37.334886, longitude: -122.008988),
        )
        // A bare space works too, and so does a paste that arrived with its own padding.
        XCTAssertEqual(
            SimulatorCoordinate.parse("  51.507351   -0.127758  "),
            SimulatorCoordinate(latitude: 51.507351, longitude: -0.127758),
        )
    }

    func testWholeDegreesAndTheOriginParse() {
        // Zero is a real position, and a guard written as a truthiness check would reject it.
        XCTAssertEqual(SimulatorCoordinate.parse("0, 0"), SimulatorCoordinate(latitude: 0, longitude: 0))
        XCTAssertEqual(SimulatorCoordinate.parse("35, 139"), SimulatorCoordinate(latitude: 35, longitude: 139))
    }

    func testAnOutOfRangeValueIsRefusedRatherThanClamped() {
        // Clamping would pin the device to a pole or a date line and call it the user's coordinate.
        XCTAssertNil(SimulatorCoordinate.parse("91, 0"))
        XCTAssertNil(SimulatorCoordinate.parse("-91, 0"))
        XCTAssertNil(SimulatorCoordinate.parse("0, 181"))
        XCTAssertNil(SimulatorCoordinate.parse("0, -181"))
        // …and the edges themselves are legal positions.
        XCTAssertNotNil(SimulatorCoordinate.parse("90, 180"))
        XCTAssertNotNil(SimulatorCoordinate.parse("-90, -180"))
    }

    func testAnythingThatIsNotExactlyTwoNumbersIsRefused() {
        XCTAssertNil(SimulatorCoordinate.parse(""))
        XCTAssertNil(SimulatorCoordinate.parse("37.334886"))
        XCTAssertNil(SimulatorCoordinate.parse("37.334886, -122.008988, 12"))
        XCTAssertNil(SimulatorCoordinate.parse("Apple Park"))
        // A degrees-minutes-seconds paste is a real thing to paste and is NOT this format. Refusing
        // it is right; silently reading the 37 and dropping the rest would not be.
        XCTAssertNil(SimulatorCoordinate.parse("37°20'05.6\"N 122°00'32.4\"W"))
    }

    // MARK: The wire and the readout

    /// The body is `slopdesk_sim_location_body`'s — the field names, the six decimals, and the fact
    /// that the rounding is the SAME call the readout beside it makes, so a pin and the figure the
    /// header echoes cannot disagree. Asserted here as the bytes that cross rather than as a
    /// dictionary, because a dictionary is what the panel no longer builds.
    func testTheBodyUsesTheServersFieldNamesAndStopsAtSixDecimals() {
        let body = String(decoding: wsAnswerBytes { out, cap in
            slopdesk_sim_location_body(37.3348861234, -122.0089881234, out, cap)
        }, as: UTF8.self)
        XCTAssertEqual(body, #"{"latitude":37.334886,"longitude":-122.008988}"#)
    }

    func testTheReadoutIsFixedWidthSoTheHeaderDoesNotReflowOnEveryPin() {
        // Six decimals always, padded rather than trimmed: a header figure that changes width as the
        // value changes makes the whole facts line jump.
        XCTAssertEqual(
            SimulatorCoordinate(latitude: 0, longitude: 0).readout, "0.000000, 0.000000",
        )
        XCTAssertEqual(
            SimulatorCoordinate(latitude: 37.334886, longitude: -122.008988).readout,
            "37.334886, -122.008988",
        )
    }

    func testAReadoutParsesBackIntoTheSamePosition() {
        // The round trip matters because the readout is what the header's Copy hands over, and the
        // obvious next thing anyone does with it is paste it into this same field.
        let original = SimulatorCoordinate(latitude: -33.868820, longitude: 151.209290)
        XCTAssertEqual(SimulatorCoordinate.parse(original.readout), original)
    }

    // MARK: The shortlist

    func testThePresetsAreDistinctAndSpanTheCasesTheListExistsFor() {
        let places = SimulatorPlace.all
        XCTAssertEqual(Set(places.map(\.id)).count, places.count)
        // The list is a bug-catching set, not a gazetteer: both hemispheres and both sides of the
        // prime meridian, so a sign error in someone's code shows up as a wrong place rather than as
        // a slightly wrong number.
        XCTAssertTrue(places.contains { $0.coordinate.latitude < 0 })
        XCTAssertTrue(places.contains { $0.coordinate.longitude < 0 })
        XCTAssertTrue(places.contains { $0.coordinate.longitude > 0 })
        // Every one of them is a position the server would accept.
        for place in places {
            XCTAssertEqual(SimulatorCoordinate.parse(place.coordinate.readout), place.coordinate)
        }
    }
}
#endif

// SimulatorPlace — simulated GPS: the coordinate parse and the shortlist of places worth one tap.
//
// Pure, and separate from the control client for the usual reason: what the server does with a
// coordinate is plumbing, but "is this string a coordinate" is the part that is wrong silently. A
// mis-parse pins the device somewhere plausible rather than failing, and nothing on screen says so.
//
// The server also accepts a `{waypoints:[…]}` route and a bearing/speed walk. Neither is offered
// here: both are motion over time, they want a map to draw the path on, and a sidebar column is not
// where anyone plots a route. A single pinned position is the case a coding tool actually has —
// "run the app as if it were in Tokyo" — and it is the whole of what this file models.

#if os(macOS)
import Foundation

/// A pinned position. Degrees, in the server's own field names.
package struct SimulatorCoordinate: Equatable {
    package var latitude: Double
    package var longitude: Double

    /// `37.334886, -122.008988` — the format every map app copies to the clipboard, which is where
    /// a coordinate typed into this field almost always comes from. A bare space separator works
    /// too; anything else is refused rather than guessed at.
    package static func parse(_ text: String) -> Self? {
        let parts = text
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2,
              let latitude = Double(parts[0]), let longitude = Double(parts[1]),
              (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        return Self(latitude: latitude, longitude: longitude)
    }

    /// The POST body. Six decimals is roughly a tenth of a metre — past that the digits describe
    /// nothing a simulator can act on, and they make the readout unreadable.
    package var body: [String: Double] {
        ["latitude": Self.rounded(latitude), "longitude": Self.rounded(longitude)]
    }

    /// What the panel echoes back after a successful send.
    package var readout: String {
        "\(Self.text(latitude)), \(Self.text(longitude))"
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    private static func text(_ value: Double) -> String {
        String(format: "%.6f", rounded(value))
    }
}

/// A named position, one tap away. Deliberately short: a picker of two hundred cities is a search
/// problem, and the point of the list is to cover the handful of cases — a home region, the two
/// hemispheres, a date line — that catch a location bug without anyone having to look a number up.
package struct SimulatorPlace: Identifiable, Equatable {
    package var name: String
    package var coordinate: SimulatorCoordinate

    package var id: String { name }

    package static let all: [Self] = [
        place("Apple Park", 37.334886, -122.008988),
        place("San Francisco", 37.774929, -122.419418),
        place("New York", 40.712776, -74.005974),
        place("London", 51.507351, -0.127758),
        place("Berlin", 52.520008, 13.404954),
        place("Ho Chi Minh City", 10.762622, 106.660172),
        place("Singapore", 1.352083, 103.819839),
        place("Tokyo", 35.689487, 139.691711),
        place("Sydney", -33.868820, 151.209290),
    ]

    private static func place(_ name: String, _ latitude: Double, _ longitude: Double) -> Self {
        Self(name: name, coordinate: SimulatorCoordinate(latitude: latitude, longitude: longitude))
    }
}
#endif

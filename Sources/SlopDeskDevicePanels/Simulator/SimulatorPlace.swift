// SimulatorPlace — simulated GPS, as `slopdesk_devicepanel::sim_place` rules it: the coordinate
// parse, the six-decimal round, the readout, and the shortlist of places worth one tap.
//
// All four are the crate's, and the parse is the reason. What the server does with a coordinate is
// plumbing, but "is this string a coordinate" is the part that is wrong SILENTLY. A refused
// coordinate is a disabled button and nobody is confused; a coordinate parsed WRONG pins the device
// somewhere plausible, the panel reports success, and the only evidence is an app that thinks it is
// in the wrong hemisphere. Hence the range checks and the refusal to guess at a separator the door
// does not recognise — and hence one speller for them, not one per renderer.
//
// The shortlist crosses as a table rather than being retyped here for the same reason it is short:
// it is a bug-catching set — a home region, both hemispheres, both sides of the prime meridian — and
// a number mistyped in one of two copies is exactly the bug it exists to catch.
//
// The server also accepts a `{waypoints:[…]}` route and a bearing/speed walk. Neither is offered
// here: both are motion over time, they want a map to draw the path on, and a sidebar column is not
// where anyone plots a route. A single pinned position is the case a coding tool actually has —
// "run the app as if it were in Tokyo" — and it is the whole of what this file models.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

/// A pinned position. Degrees, in the server's own field names.
package struct SimulatorCoordinate: Equatable {
    package var latitude: Double
    package var longitude: Double

    /// `37.334886, -122.008988` — the format every map app copies to the clipboard, which is where
    /// a coordinate typed into this field almost always comes from. A bare space separator works
    /// too; anything else is refused rather than guessed at.
    package static func parse(_ text: String) -> Self? {
        let delivery = devicePanelLend(text) { bytes, count in
            wsAnswerBytes { out, cap in slopdesk_sim_coordinate_parse(bytes, count, out, cap) }
        }
        // Two numbers and nothing else. A short delivery is a layout disagreement, not a position.
        guard delivery.count == 16 else { return nil }
        var blob = DevicePanelBlob(delivery)
        return Self(latitude: blob.number(), longitude: blob.number())
    }

    /// The POST body. Six decimals is roughly a tenth of a metre — past that the digits describe
    /// nothing a simulator can act on, and they make the readout unreadable.
    package var body: [String: Double] {
        [
            "latitude": slopdesk_sim_coordinate_round(latitude),
            "longitude": slopdesk_sim_coordinate_round(longitude),
        ]
    }

    /// What the panel echoes back after a successful send. Fixed width, so the header does not
    /// reflow on every pin.
    package var readout: String {
        wsAnswer { out, cap in
            slopdesk_sim_coordinate_readout(latitude, longitude, out, cap)
        } ?? ""
    }
}

/// A named position, one tap away.
package struct SimulatorPlace: Identifiable, Equatable {
    package var name: String
    package var coordinate: SimulatorCoordinate

    package var id: String { name }

    /// The shortlist, read once from the door that holds it.
    package static let all: [Self] = {
        var blob = DevicePanelBlob(wsAnswerBytes { out, cap in slopdesk_sim_places(out, cap) })
        let count = blob.count16()
        return (0..<count).map { _ in
            Self(
                name: blob.text(),
                coordinate: SimulatorCoordinate(
                    latitude: blob.number(), longitude: blob.number(),
                ),
            )
        }
    }()
}

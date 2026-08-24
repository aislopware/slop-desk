import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

// PaletteRowPlatform — the near side of which half lists a palette verb.
//
// The rule is `slopdesk_workspace::palette_rows`, and the reason it left Swift is a defect this file
// cannot reintroduce: every actuator on ``OverlayCoordinator`` defaults to an empty closure, and a
// `.store` row's run arm is free to be a `#if os(macOS)` with nothing in the `#else`. Both are
// invisible from the row, and both mean the same thing when the user hits Return — nothing happens.
// The phone's palette listed three such rows.
//
// ONE PLATFORM GATE, in ONE place, standing in for the three that were scattered through the catalog
// and its routing. `ActionsPaletteSource.catalog` is a `static let` built once per process, and a
// process is one slice, so the compiled slice IS the answer here — unlike ``SettingsLayout``, whose
// renderer passes its own identity because the Mac's tests ask what the PHONE would draw. The one
// `#if` below is the whole of it: nothing else in the palette branches on a platform any more.

/// Which half lists a palette verb.
package enum PaletteRowPlatform {
    /// The half this binary IS.
    ///
    /// The xcframework is built per slice, so this could have been answered by `cfg!` on the far
    /// side — but then the table could not be asked what the OTHER half lists, which is exactly what
    /// `PaletteRowPlatformTests` asks. So the flag crosses and the gate stays here, once.
    private static let isMac: Bool = {
        #if os(macOS)
        true
        #else
        false
        #endif
    }()

    /// Whether this half lists the row filed under `id`.
    ///
    /// An id the table does not declare is LISTED. A typo must not delete a row from the palette
    /// without a word — `rust/slopdesk-invariants` pins the two id sets equal in both directions,
    /// which is what makes an undeclared id impossible in the first place.
    package static func lists(_ id: String) -> Bool {
        lists(id, mac: isMac)
    }

    /// The same question asked of a named half — what a test uses to read the other side's list.
    package static func lists(_ id: String, mac: Bool) -> Bool {
        var id = id
        return id.withUTF8 { bytes in
            slopdesk_palette_row_shown(bytes.baseAddress, bytes.count, mac)
        }
    }

    /// Every id the table declares, in its own order. The parity test's half of the pin.
    package static var declaredIDs: [String] {
        (0..<slopdesk_palette_row_count()).compactMap { index in
            wsDelivered(capacity: idCapacity) { out, cap in
                slopdesk_palette_row_id(index, out, cap)
            }
        }
    }

    /// Comfortably past the longest verb id; the door reports a larger need and `wsDelivered` retries.
    private static let idCapacity = 64
}

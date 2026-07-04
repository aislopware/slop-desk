// SlateMonogram — the host-identity plate (MERIDIAN C2).
//
// TWO initials on a colour plate whose HUE derives deterministically from the identity string (FNV-1a 64
// → hue 0–359 in a fixed saturation/brightness band), so a host keeps its colour forever, on every client,
// with no stored state (Royal-TSX pattern). Connection status rides the plate's SATURATION — MERIDIAN L1
// (colour = live data, grayscale = the past) applied to identity: connected = full colour, anything else
// drains to grayscale at the SAME luminance (the stall-drain treatment). The plate IS the status — no
// second dot beside it (one dot = one meaning).

#if canImport(SwiftUI)
import SwiftUI

/// Pure identity → presentation maths, split from the view so it is unit-testable headlessly.
enum MonogramIdentity {
    /// TWO initials for an identity string: the first letters of the first two separator-split components
    /// ("mac-studio" → "MS", "herdr.local" → "HL"), or the first two characters of a single-component name
    /// ("macstudio" → "MA"). Uppercased; an empty/separator-only identity falls back to "?".
    ///
    /// An ALL-NUMERIC dotted identity (an IP literal) degenerates under the first-letters rule — every
    /// `192.168.*` host would read "11" — so the plate shows the LAST octet instead (last two digits at
    /// most): that is the part that actually distinguishes machines on one subnet. The hash HUE still
    /// covers the full string, so same-suffix hosts on different subnets stay different colours.
    static func initials(of identity: String) -> String {
        let parts = identity.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let first = parts.first else { return "?" }
        if parts.count >= 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return String((parts.last ?? first).suffix(2))
        }
        if parts.count >= 2, let a = first.first, let b = parts[1].first {
            return String([a, b]).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }

    /// The identity's hue in degrees (0..<360): FNV-1a 64 over the UTF-8 bytes, mod 360. Deterministic —
    /// computed fresh on every client, never stored — so the same host is the same colour everywhere.
    static func hue(of identity: String) -> Double {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Double(hash % 360)
    }
}

/// The identity plate: two initials in the instrument voice on the plate fill. The DEFAULT fill is the
/// identity hash-hue with `live` driving the saturation channel (connected = full colour, else grayscale
/// at the same luminance); a caller can override the fill with an explicit `tint` — the connection
/// cluster injects the network-health colour there (status IS the plate's colour in that mount).
struct SlateMonogram: View {
    let identity: String
    /// Whether the identity is CONNECTED — saturation on. Anything else (connecting / lost / never) drains.
    var live = true
    /// Explicit plate fill override (e.g. the cluster's network-health tint). `nil` ⇒ the identity
    /// hash-hue. The drained-gray offline treatment applies only to the default fill — an overriding
    /// caller picks its own offline colour (or passes `nil` to fall back here).
    var tint: Color?
    var size: CGFloat = Slate.Metric.monogram

    /// Fixed saturation/brightness band (≈ HSL 42%/62%): saturated enough to read as identity, muted
    /// enough that eight theme accents never fight it. Only the HUE is per-identity; only the SATURATION
    /// is state.
    private var plate: Color {
        tint ?? Color(
            hue: MonogramIdentity.hue(of: identity) / 360,
            saturation: live ? 0.41 : 0,
            brightness: 0.78,
        )
    }

    var body: some View {
        Text(MonogramIdentity.initials(of: identity))
            .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
            // A fixed dark ink — the plate's brightness band is constant across themes, so the ink never
            // routes through the theme (it must hold on the grayscale plate too).
            .foregroundStyle(.black.opacity(0.72))
            .frame(width: size, height: size)
            .background(plate, in: .rect(cornerRadius: Slate.Metric.radiusSmall))
            .accessibilityHidden(true) // decorative — the owning cluster carries the host/status label
    }
}

/// The WINDOWS-row identity plate (MERIDIAN C4): the LIVE stream thumbnail when one has been sampled,
/// else the identity monogram — "monogram yields to the live picture" (the Screens-5 lesson), and the
/// fallback IS the identity system, never a spinner. A STALLED stream keeps its last frame but drains
/// it to grayscale (MERIDIAN L1: colour = live data, grayscale = the past) — same law the pane's Metal
/// layer applies, spoken at row scale.
struct WindowIdentityPlate: View {
    /// The last sampled live-stream frame (`RemoteWindowModel.liveThumbnail`). `nil` ⇒ monogram.
    let image: CGImage?
    /// The identity behind the monogram fallback (the window's owning app name).
    let identity: String
    /// Whether the stream is LIVE right now (streaming and not stalled) — saturation on.
    var live = false

    /// Fixed leading-accessory footprint: wide enough to read as a picture, short enough for the
    /// `heightRow` 32pt single-line row.
    private static let plateSize = CGSize(width: 40, height: 26)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                .fill(Slate.Surface.raised)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.plateSize.width, height: Self.plateSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall))
                    .saturation(live ? 1 : 0) // stalled/closed stream = the past = grayscale (L1)
            } else {
                SlateMonogram(identity: identity, live: live)
            }
        }
        .frame(width: Self.plateSize.width, height: Self.plateSize.height)
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
        .accessibilityHidden(true) // decorative — the row carries the window's title/app text
    }
}
#endif

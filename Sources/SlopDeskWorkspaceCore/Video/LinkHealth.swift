import Foundation

// MARK: - Remote-GUI pane link-health indicator model (C7 improvement 1)

/// The PURE formatting + threshold model behind the remote-GUI pane footer's compact link-health indicator
/// (a coloured dot + an RTT label, tooltip with loss% / FEC-recovered counts). The client video session
/// already tracks RTT, a windowed loss fraction, and FEC-recovery counters; this maps one ``Sample`` of
/// those onto a display ``Grade`` (good / degraded / bad) + the label + tooltip strings. No view / session
/// here, so the thresholds + formatting are unit-tested headlessly and the footer stays a thin renderer.
public enum LinkHealth {
    /// The display grade — drives the dot colour (green / amber / red).
    public enum Grade: Equatable, Sendable {
        /// Low RTT, no sustained loss — a healthy link (green dot).
        case good
        /// Elevated RTT OR some sustained loss/PLC — degraded (amber dot).
        case degraded
        /// High RTT OR heavy sustained loss — bad (red dot).
        case bad
    }

    /// One window of the session's link counters.
    public struct Sample: Equatable, Sendable {
        /// Smoothed round-trip time (milliseconds). Negative / NaN is treated as 0 (unknown).
        public var rttMillis: Double
        /// Sustained loss fraction as a PERCENT (0…100) over the recent window (unrecovered + recovered
        /// losses relative to expected fragments) — the amber/red trigger.
        public var lossPct: Double
        /// FEC-recovered frames in the window (loss the codec silently repaired — shown in the tooltip so a
        /// green/amber dot with a non-zero recovered count reads as "loss, but handled").
        public var recovered: Int

        public init(rttMillis: Double, lossPct: Double, recovered: Int) {
            self.rttMillis = rttMillis
            self.lossPct = lossPct
            self.recovered = recovered
        }
    }

    // Thresholds — RTT in ms, loss in percent. Crossing EITHER axis grades up.
    public static let degradedRttMillis = 120.0
    public static let badRttMillis = 250.0
    public static let degradedLossPct = 2.0
    public static let badLossPct = 8.0

    /// Grades a sample: BAD if RTT ≥ ``badRttMillis`` or loss ≥ ``badLossPct``; DEGRADED if RTT ≥
    /// ``degradedRttMillis`` or loss ≥ ``degradedLossPct``; else GOOD. NaN/negative inputs read as 0 (good).
    public static func grade(_ sample: Sample) -> Grade {
        let rtt = sanitized(sample.rttMillis)
        let loss = sanitized(sample.lossPct)
        if rtt >= badRttMillis || loss >= badLossPct { return .bad }
        if rtt >= degradedRttMillis || loss >= degradedLossPct { return .degraded }
        return .good
    }

    /// The compact RTT label for the dot ("23ms", or "1.2s" once past a second). Rounds to the nearest ms;
    /// an unknown / non-positive RTT renders "—".
    public static func rttLabel(_ rttMillis: Double) -> String {
        let ms = sanitized(rttMillis)
        guard ms > 0 else { return "—" }
        if ms >= 1000 {
            return String(format: "%.1fs", ms / 1000)
        }
        return "\(Int(ms.rounded()))ms"
    }

    /// The hover tooltip: RTT + loss% + recovered-frame count, e.g. "RTT 23ms · loss 1.4% · recovered 12".
    public static func tooltip(_ sample: Sample) -> String {
        let loss = sanitized(sample.lossPct)
        return "RTT \(rttLabel(sample.rttMillis)) · loss \(String(format: "%.1f", loss))% "
            + "· recovered \(Swift.max(0, sample.recovered))"
    }

    /// Clamps NaN / negatives to 0 so a spurious reading never mis-grades or mis-formats.
    private static func sanitized(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}

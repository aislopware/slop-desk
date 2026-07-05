import Foundation

/// The semantic state of an OSC 9;4 taskbar-style progress indicator (E14/K1), shared host + client.
///
/// iTerm2 / ConEmu / winget emit `ESC ] 9 ; 4 ; <state> [ ; <pct> ] <terminator>` to drive a
/// per-window progress bar. The host parses that subtype out of the OSC-9 stream (it is NOT a
/// desktop notification — see ``WireMessage/progress(state:percent:)``) and forwards it as the
/// type-32 CONTROL message; both ends share THIS validated model.
///
/// The wire carries the RAW `UInt8` state (so the codec stays a faithful byte round-trip and the
/// golden vector is stable); the CLIENT re-validates an inbound byte through ``init(wire:)`` and
/// DROPS an unknown discriminant (the `MetadataVerb`/`MetadataStatus` forward-tolerant idiom).
public enum ProgressState: UInt8, Sendable, Equatable {
    /// OSC 9;4;0 — clear the indicator (the command finished its progress reporting).
    case clear = 0
    /// OSC 9;4;1;<pct> — a DETERMINATE progress value (the `percent` is meaningful).
    case inProgress = 1
    /// OSC 9;4;2[;<pct>] — an ERROR state (held red; the `percent` is the value at which it failed).
    case error = 2
    /// OSC 9;4;3 — an INDETERMINATE / busy spinner (no meaningful percent).
    case indeterminate = 3

    // States 4 (paused/warning) and 5 (finished + exit) are deliberately NOT carried here:
    //  - 4 is ignored (no determinate-paused render surface exists for it).
    //  - 5 (OSC 9;4;5;<exit>[;watch]) maps onto the EXISTING `commandStatus(.idle(exitCode:))` path
    //    (OSC-133-D), not a new progress state; the `watch` finish suffix is deferred to E20's watch
    //    command. See `docs/DECISIONS.md` "E14 progress + notifications + privilege parity".

    /// Validate-then-drop construction from a raw wire byte: a known discriminant (0/1/2/3) maps to
    /// its case; ANY other value (4/5/…/255) returns `nil` so the consumer DROPS the update rather
    /// than trusting a byte it does not understand. The decoder carries the raw byte verbatim
    /// (forward-tolerant); this is where the CLIENT clamps it.
    public init?(wire raw: UInt8) {
        self.init(rawValue: raw)
    }
}

/// The pure OSC 9;4 progress parser (E14/K1): turns the OSC-9 remainder AFTER the leading `9;`
/// (e.g. `"4;1;40"`, `"4;3"`, `"4;2;80"`, `"4;0"`) into a validated `(state, percent)`.
///
/// Validate-then-drop on hostile/garbled input: the `4;` progress prefix and the state digit are
/// validated (an unknown state → `nil`), the percent is CLAMPED to `0…100` (out-of-range is clamped,
/// never trusted), and ANY malformed shape (missing state, non-integer percent, too many fields,
/// empty) returns `nil` so the host emits NOTHING. Pure — no allocation beyond the split, no
/// force-unwrap, no float math (the percent is an integer; the one clamp uses ordered `min`/`max`).
public enum ProgressOSCParser {
    /// Parses the OSC-9 remainder after `9;`. Returns the validated `(state, percent)` or `nil` (drop).
    ///
    /// Accepts the canonical forms `"4;<state>"` (clear/indeterminate, no percent → 0) and
    /// `"4;<state>;<pct>"` (in-progress/error). Empty subsequences are KEPT in the split so `"4;"`
    /// (an empty state field) is caught as malformed rather than silently coalesced.
    public static func parse(_ body: some StringProtocol) -> (state: ProgressState, percent: UInt8)? {
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        // Canonical OSC 9;4 progress is exactly "4;<state>" (2 fields) or "4;<state>;<pct>" (3 fields);
        // a bare "4", an empty "4;", or extra trailing fields are not canonical → drop.
        guard fields.count == 2 || fields.count == 3, fields[0] == "4" else { return nil }
        // The state digit must be a valid wire discriminant (0/1/2/3); 4/5/9/… → drop (never trust).
        guard let rawState = UInt8(fields[1]), let state = ProgressState(wire: rawState) else { return nil }
        // Percent: absent (clear/indeterminate) → 0; present-but-not-an-integer → DROP the whole
        // update (a garbled percent is suspect); otherwise CLAMP to 0…100 with ordered min/max.
        var percent: UInt8 = 0
        if fields.count == 3 {
            guard let value = Int(fields[2]) else { return nil }
            percent = UInt8(min(max(value, 0), 100))
        }
        return (state, percent)
    }
}

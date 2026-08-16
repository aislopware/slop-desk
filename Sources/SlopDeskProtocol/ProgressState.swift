import CSlopDeskFFI

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

/// The OSC 9;4 progress parser — the Swift face of `rust/slopdesk-wire`'s `osc::parse_progress`.
/// Turns the OSC-9 remainder AFTER the leading `9;` (e.g. `"4;1;40"`, `"4;3"`, `"4;2;80"`, `"4;0"`)
/// into a validated `(state, percent)`.
///
/// The grammar is the crate's, and it is the SAME crate that builds these sequences for
/// `slopdesk watch` — so a spinner the wrapper prints and a spinner the host reads can never
/// disagree about what a field means.
///
/// Validate-then-drop on hostile/garbled input: an unknown state, a non-integer percent, a missing
/// field or an extra one all return `nil` so the host emits NOTHING. An out-of-range percent is
/// merely CLAMPED — an implausible number is not the same as a malformed one.
public enum ProgressOSCParser {
    /// Parses the OSC-9 remainder after `9;`. Returns the validated `(state, percent)` or `nil` (drop).
    public static func parse(_ body: some StringProtocol) -> (state: ProgressState, percent: UInt8)? {
        let bytes = Array(String(body).utf8)
        var raw: UInt8 = 0
        var percent: UInt8 = 0
        let known = bytes.withUnsafeBufferPointer { text in
            slopdesk_osc_parse_progress(text.baseAddress, text.count, &raw, &percent)
        }
        guard known, let state = ProgressState(wire: raw) else { return nil }
        return (state, percent)
    }
}

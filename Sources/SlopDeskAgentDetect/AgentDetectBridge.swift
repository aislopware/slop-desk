import CSlopDeskFFI
import Foundation

// The one place this module marshals for `rust/slopdesk-agent` (docs/55).
//
// Every rule in agent detection lives in that crate: the alias table, the wrapper set, the
// keystroke classes, the rollup order, the temporal hold and the 900-line status machine. What
// stays in Swift is the vocabulary — `AgentKind` and `ClaudeStatus` are case lists a `switch` in a
// view can read, and they carry no decisions. A signal never
// crosses as a signal any more: the pane detector calls the verb it means, one door per fold, so
// there is no `SlopDeskAgentSignal` to build here. That split is what makes
// "one implementation" true here rather than aspirational, and `rust/slopdesk-invariants` pins
// the discriminants below so a reordered Swift enum fails the build instead of quietly reporting
// `working` for `blocked`.

// MARK: Calling a pure entry point

/// Runs a `(bytes, len) -> Bool` predicate over a string.
///
/// The `withUnsafeBytes` scope IS the safety contract — the pointer is live for exactly the call
/// inside it — so nothing else goes in the closure.
func agentPredicate(_ text: String, _ call: (UnsafePointer<UInt8>?, Int) -> Bool) -> Bool {
    var bytes = Array(text.utf8)
    return bytes.withUnsafeMutableBufferPointer { buffer in
        call(buffer.baseAddress, buffer.count)
    }
}

/// Runs a `(bytes, len, out, cap) -> needed` transform and returns the answer as a `String`.
///
/// A first guess generous by an order of magnitude, and a retry that exists to be correct rather
/// than to be travelled (docs/55 §4).
func agentTransform(
    _ text: String,
    _ call: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, Int) -> Int,
) -> String {
    var bytes = Array(text.utf8)
    return bytes.withUnsafeMutableBufferPointer { input -> String in
        var out = [UInt8](repeating: 0, count: max(256, input.count + 32))
        var needed = out.withUnsafeMutableBufferPointer { buffer in
            call(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
        }
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            needed = out.withUnsafeMutableBufferPointer { buffer in
                call(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
            }
        }
        guard needed > 0, needed <= out.count else { return "" }
        // Failable rather than replacement-charactered: the crate only ever answers UTF-8 here, so a
        // decode failure is a boundary bug and must not be laundered into a plausible-looking name.
        return String(bytes: out[0..<needed], encoding: .utf8) ?? ""
    }
}

// MARK: The vocabularies, as the discriminants the crate agreed to

public extension ClaudeStatus {
    /// The CASE index — the crate's `ClaudeStatus::ALL` order, which is also `allCases`.
    ///
    /// Deliberately not ``urgency``: the rank is a rule and lives in Rust, so passing it here would
    /// be answering the question this byte exists to ask.
    ///
    /// Public because `watch:claude` asks the same door about the same five cases from another module,
    /// and a second spelling of these five bytes is exactly the drift the port removes.
    var ffiByte: UInt8 {
        switch self {
        case .none: 0
        case .idle: 1
        case .working: 2
        case .done: 3
        case .needsPermission: 4
        }
    }

    /// Whether `previous → next` mints one FINISHED TURN — `slopdesk-agent`'s
    /// `attention::mints_finished_turn`, which is where the rule and every case it turns on live.
    ///
    /// Beside ``ffiByte`` rather than at either caller: the host counts the turn (`pane/completionEpoch`)
    /// and a test reads the same answer back, and two spellings of "a turn ended" is an unread badge
    /// on one surface and not the other.
    static func mintsFinishedTurn(previous: Self, next: Self) -> Bool {
        slopdesk_agent_finished_turn(previous.ffiByte, next.ffiByte)
    }

    /// The inverse. Total, because an unknown byte from a newer library must degrade rather than trap.
    init(ffiByte: UInt8) {
        switch ffiByte {
        case 1: self = .idle
        case 2: self = .working
        case 3: self = .done
        case 4: self = .needsPermission
        default: self = .none
        }
    }
}

// `AgentScreenState` and `AgentScreenDetection` are not in this module at all any more, and
// `docs/60` F.9 is why. Each had a compact `repr(C)` twin here — a state byte, and the five fields
// the temporal layer compares — because the SWIFT host folded a screend verdict and handed it back
// to `slopdesk-agent` across the boundary. hostd is Rust and LINKS the crate, so it passes
// `AgentScreenDetection` itself.
//
// That left the Swift enums with no reader, and the rule below is what decides they go rather than
// stay: a view `switch`es on an agent's KIND and its STATUS, never on a screen verdict, so the
// vocabulary the client speaks was always the two files beside this one. A case list nothing reads
// is a second implementation waiting for its first caller.
//
// `AgentDetectionHold` went the same way, and with it `slopdesk_agent_hold_constant`. It was six
// numbers a Swift test named so it would not type them twice; `rust/slopdesk-hostsession` reads them
// as constants now, and a door with no caller is a claim about this side that nothing checks.

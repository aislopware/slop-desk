import CSlopDeskFFI
import Foundation

// The one place this module marshals for `rust/slopdesk-agent` (docs/55).
//
// Every rule in agent detection lives in that crate: the alias table, the wrapper set, the
// keystroke classes, the rollup order, the temporal hold and the 900-line status machine. What
// stays in Swift is the vocabulary — `AgentKind`, `ClaudeStatus`, `AgentScreenDetection` and
// friends are case lists a `switch` in a view can read, and they carry no decisions. A signal never
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

extension AgentScreenState {
    var ffiByte: UInt8 {
        switch self {
        case .idle: 0
        case .working: 1
        case .blocked: 2
        case .unknown: 3
        }
    }
}

public extension AgentScreenDetection {
    /// The compact form the temporal layer compares — the rule id and fallback reason are absent
    /// because `hold` reads neither, and neither does the state machine below it. Public because the
    /// host's pane detector folds a verdict through the same struct, and a second spelling of these
    /// five fields is exactly the drift the port removes.
    var ffiDetection: SlopDeskAgentDetection {
        SlopDeskAgentDetection(
            state: state.ffiByte,
            skip_state_update: skipStateUpdate,
            visible_idle: visibleIdle,
            visible_blocker: visibleBlocker,
            visible_working: visibleWorking,
        )
    }
}

import CSlopDeskFFI
import Foundation

// The one place this module marshals for `rust/slopdesk-agent` (docs/55).
//
// Every rule in agent detection lives in that crate: the alias table, the wrapper set, the
// keystroke classes, the rollup order, the temporal hold and the 900-line status machine. What
// stays in Swift is the vocabulary — `AgentKind`, `ClaudeStatus`, `ClaudeSignal` and friends are
// case lists a `switch` in a view can read, and they carry no decisions. That split is what makes
// "one implementation" true here rather than aspirational, and `scripts/check-supervisor.sh` pins
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

extension AgentScreenDetection {
    /// The compact form the temporal layer compares — the rule id and fallback reason are absent
    /// because `hold` reads neither.
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

extension ClaudeHookEvent.NotificationKind {
    var ffiByte: UInt8 {
        switch self {
        case .permission: 0
        case .waitingForInput: 1
        case .other: 2
        }
    }
}

// MARK: Building a signal

/// Accumulates a signal's optional strings into ONE buffer, handing back `(offset, len, present)`
/// spans into it.
///
/// Six separate `(ptr, len)` pairs would mean six nested `withUnsafeBytes` per call. One buffer
/// means one pointer, one lifetime, one scope — and the crate bounds-checks every span, because a
/// hook body is untrusted input.
private struct SignalStrings {
    private(set) var bytes: [UInt8] = []

    static let absent = SlopDeskAgentSpan(offset: 0, len: 0, present: false)

    /// `nil` stays absent; a present-but-empty string is a span of length 0, which the crate tells
    /// apart from absent (an empty session id is not an unattributed event).
    mutating func span(_ text: String?) -> SlopDeskAgentSpan {
        guard let text else { return Self.absent }
        let offset = bytes.count
        bytes.append(contentsOf: text.utf8)
        return SlopDeskAgentSpan(offset: offset, len: bytes.count - offset, present: true)
    }
}

/// A signal with every slot empty. Each case fills in only the two or three it owns; the crate reads
/// nothing else, which is what keeps this from being one initialiser per case.
private func blankSignal() -> SlopDeskAgentSignal {
    SlopDeskAgentSignal(
        kind: 4,
        hook: 0,
        notification: 0,
        status: 0,
        present: false,
        screen: SlopDeskAgentDetection(
            state: AgentScreenState.unknown.ffiByte,
            skip_state_update: false,
            visible_idle: false,
            visible_blocker: false,
            visible_working: false,
        ),
        session_id: SignalStrings.absent,
        tool: SignalStrings.absent,
        tool_use_id: SignalStrings.absent,
        label: SignalStrings.absent,
        matched_rule_id: SignalStrings.absent,
        fallback_reason: SignalStrings.absent,
        strings: nil,
        strings_len: 0,
    )
}

/// Fills in the hook slots and returns the crate's `hook` discriminant.
private func encodeHook(
    _ event: ClaudeHookEvent,
    into signal: inout SlopDeskAgentSignal,
    strings: inout SignalStrings,
) {
    signal.kind = 0
    switch event {
    case let .sessionStart(sessionID):
        signal.hook = 0
        signal.session_id = strings.span(sessionID)
    case let .userPromptSubmit(sessionID):
        signal.hook = 1
        signal.session_id = strings.span(sessionID)
    case let .preToolUse(sessionID, tool, toolUseID):
        signal.hook = 2
        signal.session_id = strings.span(sessionID)
        signal.tool = strings.span(tool)
        signal.tool_use_id = strings.span(toolUseID)
    case let .postToolUse(sessionID, tool, toolUseID):
        signal.hook = 3
        signal.session_id = strings.span(sessionID)
        signal.tool = strings.span(tool)
        signal.tool_use_id = strings.span(toolUseID)
    case let .notification(kind, label, toolUseID, sessionID):
        signal.hook = 4
        signal.notification = kind.ffiByte
        signal.label = strings.span(label)
        signal.tool_use_id = strings.span(toolUseID)
        signal.session_id = strings.span(sessionID)
    case let .stop(sessionID, label):
        signal.hook = 5
        signal.session_id = strings.span(sessionID)
        signal.label = strings.span(label)
    case let .subagentStop(agentID):
        // The crate reads a subagent's id out of the session slot: one agent id per event, and no
        // second slot that could disagree with it.
        signal.hook = 6
        signal.session_id = strings.span(agentID)
    case let .interrupted(sessionID):
        signal.hook = 7
        signal.session_id = strings.span(sessionID)
    case let .sessionEnd(sessionID):
        signal.hook = 8
        signal.session_id = strings.span(sessionID)
    case let .preCompact(sessionID):
        signal.hook = 9
        signal.session_id = strings.span(sessionID)
    }
}

/// Encodes a signal and calls `body` with a pointer to it, live for exactly that call.
func withAgentSignal<T>(_ signal: ClaudeSignal, _ body: (UnsafePointer<SlopDeskAgentSignal>) -> T) -> T {
    var encoded = blankSignal()
    var strings = SignalStrings()

    switch signal {
    case let .hook(event):
        encodeHook(event, into: &encoded, strings: &strings)
    case let .processPresent(present):
        encoded.kind = 1
        encoded.present = present
    case let .manifestVerdict(status):
        encoded.kind = 2
        encoded.status = status.ffiByte
    case let .oscTitle(title):
        // The title shares the label slot: both are "the one piece of text this signal carries".
        encoded.kind = 3
        encoded.label = strings.span(title)
    case .tick:
        encoded.kind = 4
    case let .screen(detection):
        encoded.kind = 5
        encoded.screen = detection.ffiDetection
        encoded.matched_rule_id = strings.span(detection.matchedRuleID)
        encoded.fallback_reason = strings.span(detection.fallbackReason)
    case .userInput:
        encoded.kind = 6
    }

    var blob = strings.bytes
    return blob.withUnsafeMutableBufferPointer { buffer -> T in
        encoded.strings = UnsafePointer(buffer.baseAddress)
        encoded.strings_len = buffer.count
        return withUnsafePointer(to: &encoded, body)
    }
}

/// Encodes JUST the hook half of a signal — what ``ClaudeStatusMachine/accepts(_:)`` asks about.
func withAgentHookSignal<T>(
    _ event: ClaudeHookEvent,
    _ body: (UnsafePointer<SlopDeskAgentSignal>) -> T,
) -> T {
    withAgentSignal(.hook(event), body)
}

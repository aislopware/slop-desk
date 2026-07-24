import Foundation

/// Passive OSC capture for the detection engine (herdr `AgentOscStateTracker` +
/// `OscStreamCollector`, ported 1:1): retains the latest OSC 0/2 title and the latest OSC 9
/// payload (the part after `9;`, e.g. `"4;0;"`) from the raw PTY output stream. Chunk-split
/// sequences reassemble across `observe` calls; bodies cap at 4096 bytes (overflow discards
/// the sequence); titles sanitize to 256 non-control chars. Nothing here affects rendering.
public struct AgentOscTracker: Sendable, Equatable {
    /// Bound on one OSC body (herdr `MAX_BODY_BYTES`).
    static let maxBodyBytes = 4096
    /// Retained-string cap in characters (herdr `AGENT_OSC_MAX_CHARS`).
    static let maxChars = 256

    private enum State: Equatable {
        case ground
        case escape
        case body
        case bodyEscape
        case ignoringString
        case ignoringStringEscape
        case discarding
        case discardingEscape
    }

    private var state: State = .ground
    private var body: [UInt8] = []

    /// Last non-empty OSC 0/2 title, or `""`. An explicit empty title clears it.
    public private(set) var latestTitle = ""
    /// Last OSC 9 payload after the `9;`, sanitized, or `""` when none seen.
    public private(set) var latestProgress = ""

    public init() {}

    /// Drops the retained title/progress so a new foreground agent cannot inherit OSC
    /// evidence from the previous process. In-flight parse state is kept — a sequence
    /// spanning the change finalizes normally, attributed to the new agent.
    public mutating func clearRetained() {
        latestTitle = ""
        latestProgress = ""
    }

    public mutating func observe(_ bytes: Data) {
        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
            case .escape:
                switch byte {
                case UInt8(ascii: "]"):
                    body.removeAll(keepingCapacity: true)
                    state = .body
                case 0x1B:
                    state = .escape
                case UInt8(ascii: "P"),
                     UInt8(ascii: "X"),
                     UInt8(ascii: "^"),
                     UInt8(ascii: "_"):
                    state = .ignoringString
                default:
                    state = .ground
                }
            case .body:
                switch byte {
                case 0x07: finish()
                case 0x1B: state = .bodyEscape
                default: push(byte)
                }
            case .bodyEscape:
                switch byte {
                case UInt8(ascii: "\\"):
                    finish()
                case 0x07:
                    push(0x1B)
                    if state == .body { finish() } else { state = .ground }
                case 0x1B:
                    push(0x1B)
                    if state == .body { state = .bodyEscape }
                    else if state == .discarding { state = .discardingEscape }
                default:
                    push(0x1B)
                    if state == .body { push(byte) }
                }
            case .ignoringString:
                if byte == 0x1B { state = .ignoringStringEscape }
            case .ignoringStringEscape:
                if byte == UInt8(ascii: "\\") { state = .ground }
                else if byte != 0x1B { state = .ignoringString }
            case .discarding:
                if byte == 0x07 { state = .ground }
                else if byte == 0x1B { state = .discardingEscape }
            case .discardingEscape:
                if byte == UInt8(ascii: "\\") { state = .ground }
                else if byte != 0x1B { state = .discarding }
            }
        }
    }

    private mutating func push(_ byte: UInt8) {
        body.append(byte)
        if body.count > Self.maxBodyBytes {
            body.removeAll(keepingCapacity: true)
            state = .discarding
        } else {
            state = .body
        }
    }

    private mutating func finish() {
        defer {
            body.removeAll(keepingCapacity: true)
            state = .ground
        }
        // Split at the first ';' → (command, payload); no ';' → not an agent OSC.
        guard let sep = body.firstIndex(of: UInt8(ascii: ";")) else { return }
        let command = body[..<sep]
        let payload = Array(body[(sep + 1)...])
        if command.elementsEqual([UInt8(ascii: "0")]) || command.elementsEqual([UInt8(ascii: "2")]) {
            let title = Self.sanitize(payload)
            if !title.isEmpty {
                latestTitle = title
            } else {
                latestTitle = ""
            }
        } else if command.elementsEqual([UInt8(ascii: "9")]) {
            latestProgress = Self.sanitize(payload)
        }
    }

    /// Lossy-UTF-8 decode, control chars dropped, capped at `maxChars` characters.
    static func sanitize(_ payload: [UInt8]) -> String {
        // Lossy on purpose (upstream `from_utf8_lossy` parity): invalid bytes become U+FFFD —
        // a failable decode would drop the whole title over one bad byte.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: payload, as: UTF8.self)
        var out = ""
        var taken = 0
        for ch in text where !ch.isControlCharacter {
            out.append(ch)
            taken += 1
            if taken >= maxChars { break }
        }
        return out
    }
}

private extension Character {
    /// Rust `char::is_control` — the Unicode Cc category.
    var isControlCharacter: Bool {
        unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
    }
}

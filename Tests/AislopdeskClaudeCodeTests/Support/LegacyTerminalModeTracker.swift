import AislopdeskClaudeCode
import Foundation

/// VERBATIM copy of `TerminalModeTracker` as it stood BEFORE the memchr fast path
/// (2026-06-12, docs/31 follow-up #6) — the naive `for byte in bytes { step(byte) }`
/// consume loop over the identical 7-state transition table.
///
/// Kept ONLY as the differential test oracle (the same discipline as
/// `Tests/AislopdeskHostTests/Support/HostTitleBellSniffer.swift` et al. for the fused
/// `HostOutputSniffer`): `TerminalModeTrackerFastPathTests` feeds both machines the same
/// streams under the same chunkings and asserts identical events + final mode. Do not
/// "fix" or modernize this file — its value is being frozen.
final class LegacyTerminalModeTracker {
    private(set) var mode: TerminalMode = .shellPrompt

    init() {}

    // MARK: Parser state

    private enum State {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
        case stringConsume
        case stringConsumeEscape
    }

    private var state: State = .ground
    private var csiBuffer: [UInt8] = []
    private var oscBuffer: [UInt8] = []

    private static let csiCap = 64
    private static let oscCap = 256

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let leftBracket: UInt8 = 0x5B // '['
    private static let rightBracket: UInt8 = 0x5D // ']'
    private static let backslash: UInt8 = 0x5C // '\'
    private static let dcs: UInt8 = 0x50 // 'P'
    private static let sos: UInt8 = 0x58 // 'X'
    private static let pm: UInt8 = 0x5E // '^'
    private static let apc: UInt8 = 0x5F // '_'

    // MARK: Consume — the pre-fast-path naive loop, verbatim

    @discardableResult
    func consume(_ bytes: Data) -> [TerminalModeEvent] {
        var events: [TerminalModeEvent] = []
        for byte in bytes {
            step(byte, into: &events)
        }
        return events
    }

    @discardableResult
    func consume(_ bytes: [UInt8]) -> [TerminalModeEvent] {
        consume(Data(bytes))
    }

    // MARK: State machine (verbatim)

    private func step(_ byte: UInt8, into events: inout [TerminalModeEvent]) {
        switch state {
        case .ground:
            if byte == Self.esc { state = .escape }

        case .escape:
            switch byte {
            case Self.leftBracket:
                state = .csi
                csiBuffer.removeAll(keepingCapacity: true)
            case Self.rightBracket:
                state = .osc
                oscBuffer.removeAll(keepingCapacity: true)
            case Self.dcs,
                 Self.sos,
                 Self.pm,
                 Self.apc:
                state = .stringConsume
            case Self.esc:
                state = .escape
            default:
                state = .ground
            }

        case .csi:
            if (0x40...0x7E).contains(byte) {
                csiBuffer.append(byte)
                handleCSI(csiBuffer, into: &events)
                state = .ground
            } else {
                csiBuffer.append(byte)
                if csiBuffer.count > Self.csiCap {
                    state = .ground
                }
            }

        case .osc:
            switch byte {
            case Self.bel:
                handleOSC(oscBuffer, into: &events)
                state = .ground
            case Self.esc:
                state = .oscEscape
            default:
                oscBuffer.append(byte)
                if oscBuffer.count > Self.oscCap {
                    state = .ground
                }
            }

        case .oscEscape:
            if byte == Self.backslash {
                handleOSC(oscBuffer, into: &events)
                state = .ground
            } else {
                handleOSC(oscBuffer, into: &events)
                state = .escape
                step(byte, into: &events)
            }

        case .stringConsume:
            switch byte {
            case Self.bel:
                state = .ground
            case Self.esc:
                state = .stringConsumeEscape
            default:
                break
            }

        case .stringConsumeEscape:
            switch byte {
            case Self.backslash:
                state = .ground
            case Self.esc:
                state = .stringConsumeEscape
            default:
                state = .stringConsume
            }
        }
    }

    private func handleCSI(_ buffer: [UInt8], into events: inout [TerminalModeEvent]) {
        guard let final = buffer.last, final == 0x68 || final == 0x6C else { return } // 'h'/'l'
        guard buffer.first == 0x3F else { return } // '?'

        let paramBytes = buffer.dropFirst().dropLast()
        let params = (String(bytes: paramBytes, encoding: .utf8) ?? "")
            .split(separator: ";", omittingEmptySubsequences: true)
            .compactMap { Int($0) }

        let isSet = (final == 0x68) // 'h'
        for param in params where param == 1049 || param == 47 || param == 1047 {
            if isSet {
                if mode != .altScreen {
                    mode = .altScreen
                    events.append(.enteredAltScreen)
                }
            } else {
                if mode != .shellPrompt {
                    mode = .shellPrompt
                    events.append(.exitedAltScreen)
                }
            }
            return
        }
    }

    private func handleOSC(_ buffer: [UInt8], into events: inout [TerminalModeEvent]) {
        let payload = String(bytes: buffer, encoding: .utf8) ?? ""
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 2, fields[0] == "133" else { return }

        switch fields[1] {
        case "A": events.append(.promptStart)
        case "B": events.append(.commandStart)
        case "C": events.append(.commandStarted)
        case "D":
            var exit: Int?
            if fields.count >= 3 {
                let raw = fields[2].split(separator: "=").first.map(String.init) ?? String(fields[2])
                exit = Int(raw)
            }
            events.append(.commandFinished(exitCode: exit))
        default:
            break
        }
    }
}

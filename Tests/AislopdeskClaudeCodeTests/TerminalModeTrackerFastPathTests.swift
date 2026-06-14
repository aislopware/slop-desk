import Foundation
import XCTest
@testable import AislopdeskClaudeCode

/// Pins the memchr fast path of ``TerminalModeTracker`` (docs/31 follow-up #6) to the
/// per-byte transition table — the same two-oracle discipline used for the fused
/// `HostOutputSniffer`:
///
/// 1. **Chunking-invariance oracle** (PERMANENT): feeding a stream whole exercises the
///    fast path; feeding it one byte at a time BYPASSES memchr entirely (every chunk is
///    a single step). Equal events + equal final mode across chunkings pins the fast
///    path to the table for every adversarial stream below.
/// 2. **Differential oracle vs the frozen pre-fast-path copy**
///    (`Support/LegacyTerminalModeTracker.swift`): hand-written cases + seeded
///    byte-alphabet fuzz + seeded token fuzz, each under whole / random / per-byte
///    chunkings, must produce identical events and final mode.
final class TerminalModeTrackerFastPathTests: XCTestCase {
    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"
    private let ST = "\u{1B}\\"

    // MARK: Deterministic PRNG (SplitMix64) — reproducible fuzz failures

    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func next(upTo n: Int) -> Int {
            precondition(n > 0)
            return Int(next() % UInt64(n))
        }
    }

    // MARK: Runners

    /// Feeds `chunks` to a fresh tracker; returns (events, final mode).
    private func run(_ chunks: [[UInt8]]) -> ([TerminalModeEvent], TerminalMode) {
        let t = TerminalModeTracker()
        var out: [TerminalModeEvent] = []
        for chunk in chunks { out += t.consume(chunk) }
        return (out, t.mode)
    }

    /// Feeds `chunks` to a fresh LEGACY tracker; returns (events, final mode).
    private func runLegacy(_ chunks: [[UInt8]]) -> ([TerminalModeEvent], TerminalMode) {
        let t = LegacyTerminalModeTracker()
        var out: [TerminalModeEvent] = []
        for chunk in chunks { out += t.consume(chunk) }
        return (out, t.mode)
    }

    private func chunked(_ bytes: [UInt8], size: Int) -> [[UInt8]] {
        precondition(size > 0)
        var chunks: [[UInt8]] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + size, bytes.count)
            chunks.append(Array(bytes[i..<end]))
            i = end
        }
        return chunks
    }

    /// Asserts new == legacy for one chunking, comparing events AND final mode.
    private func assertDifferential(
        _ chunks: [[UInt8]],
        _ label: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        let (newEvents, newMode) = run(chunks)
        let (oldEvents, oldMode) = runLegacy(chunks)
        XCTAssertEqual(newEvents, oldEvents, "events diverged — \(label())", file: file, line: line)
        XCTAssertEqual(newMode, oldMode, "final mode diverged — \(label())", file: file, line: line)
    }

    // MARK: The adversarial stream list

    /// Streams chosen to hit every fast-path edge: ground skim (ESC-only interest, BEL
    /// ignored), stringConsume skim (ESC + bounded BEL), cap-overflow mid-sequence drops
    /// back into the skimmed ground, stray-ESC OSC re-entry, escape-dense worst cases for
    /// the bounded-BEL O(n²) guard, and partial tails left hanging across calls.
    private var adversarialStreams: [(name: String, bytes: [UInt8])] {
        var streams: [(String, [UInt8])] = []

        // Pure content — the fast path skips the whole chunk in one memchr.
        streams.append(("plain text", Array("hello world, no escapes at all\n".utf8)))
        // Ground BELs: the tracker IGNORES ground BEL (unlike the sniffer) — must not trip anything.
        streams.append(("ground BELs", Array("a\(BEL)b\(BEL)\(BEL)c".utf8)))
        // BEL immediately before an ESC (bounded-BEL edge: zero-length scan windows).
        streams.append(("BEL abutting ESC", Array("\(BEL)\(ESC)[?1049h\(BEL)".utf8)))
        // The tracked markers, both terminators.
        streams.append(("alt enter/exit", Array("\(ESC)[?1049htui\(ESC)[?1049l".utf8)))
        streams.append(("legacy 47/1047", Array("\(ESC)[?47hx\(ESC)[?47l\(ESC)[?1047hy\(ESC)[?1047l".utf8)))
        streams.append((
            "osc133 cycle BEL",
            Array("\(ESC)]133;A\(BEL)$ \(ESC)]133;B\(BEL)ls\n\(ESC)]133;C\(BEL)out\n\(ESC)]133;D;0\(BEL)".utf8),
        ))
        streams.append(("osc133 cycle ST", Array("\(ESC)]133;A\(ST)$ \(ESC)]133;C\(ST)\(ESC)]133;D;42\(ST)".utf8)))
        // Stray ESC ends an OSC and introduces the next sequence (the .oscEscape re-entry).
        streams.append(("stray-ESC osc then csi", Array("\(ESC)]133".utf8) + Array("\(ESC)[?1049h".utf8)))
        streams.append(("stray-ESC osc then osc", Array("\(ESC)]133;A".utf8) + Array("\(ESC)]133;B\(BEL)".utf8)))
        streams.append(("ESC ESC backslash", Array("\(ESC)]133;A\(ESC)\(ESC)\\".utf8)))
        // Over-cap OSC: drops to .ground MID-payload (documented quirk) — the rest of the
        // payload is then skimmed as ground; a later real marker must still fire.
        streams.append((
            "over-cap OSC",
            Array("\(ESC)]999;\(String(repeating: "x", count: 1000))\(BEL)\(ESC)[?1049h".utf8),
        ))
        // Over-cap OSC whose tail CONTAINS escape-looking bytes once reparsed as ground.
        streams.append((
            "over-cap OSC esc tail",
            Array("\(ESC)]999;\(String(repeating: "y", count: 300))\(ESC)[?1049h\(BEL)".utf8),
        ))
        // Over-cap CSI (>64 params) drops to ground mid-sequence.
        streams.append(("over-cap CSI", Array("\(ESC)[\(String(repeating: "1;", count: 40))h\(ESC)[?1049h".utf8)))
        // String sequences: embedded spoofs swallowed; BEL terminates; lone ESC stays inside.
        for (name, intro) in [("DCS", "P"), ("SOS", "X"), ("PM", "^"), ("APC", "_")] {
            streams.append(("\(name) spoof ST", Array("\(ESC)\(intro)junk\(ESC)[?1049h\(ST)\(ESC)[?1049h".utf8)))
            streams.append(("\(name) spoof BEL", Array("\(ESC)\(intro)body\(BEL)\(ESC)]133;A\(BEL)".utf8)))
        }
        // Lone ESC inside a string body (stringConsumeEscape → back to stringConsume).
        streams.append(("string lone ESC", Array("\(ESC)Pab\(ESC)cd\(ST)\(ESC)[?1049h".utf8)))
        // ESC ESC inside a string body (stringConsumeEscape stays on ESC, ST still works).
        streams.append(("string ESC ESC ST", Array("\(ESC)Pab\(ESC)\(ESC)\\\(ESC)]133;C\(BEL)".utf8)))
        // BELs inside a string body region the skim must hand to step() (terminator), with
        // more BELs after (ground — ignored).
        streams.append(("string BEL storm", Array("\(ESC)P\(BEL)\(BEL)\(ESC)P x\(BEL)\(ESC)[?47h".utf8)))
        // Escape-dense worst case for the bounded scans (every byte is ESC).
        streams.append(("all ESC", [UInt8](repeating: 0x1B, count: 257)))
        // Alternating ESC/BEL — adversarial for both memchrs at once.
        streams.append(("ESC BEL alternating", (0..<128).map { $0.isMultiple(of: 2) ? 0x1B : 0x07 }))
        // High-bit / invalid UTF-8 around a marker.
        var highBit: [UInt8] = Array("café 🚀 ".utf8)
        highBit += [0xFF, 0x80, 0xC0]
        highBit += Array("\(ESC)[?1049h".utf8) + Array("日本語".utf8)
        streams.append(("high-bit bytes", highBit))
        // Partial tails left hanging at end of stream (state must carry to nothing cleanly).
        streams.append(("dangling ESC", Array("text\(ESC)".utf8)))
        streams.append(("dangling CSI", Array("text\(ESC)[?10".utf8)))
        streams.append(("dangling OSC", Array("text\(ESC)]133;".utf8)))
        streams.append(("dangling string", Array("text\(ESC)Pbody".utf8)))
        streams.append(("empty", []))
        return streams.map { (name: $0.0, bytes: $0.1) }
    }

    // MARK: 1. Chunking-invariance oracle (permanent)

    /// Whole-chunk (fast path) vs one-byte-at-a-time (memchr bypassed) vs sizes 2/3/7/64
    /// must agree on events AND final mode for every adversarial stream.
    func testChunkingInvarianceOracle() {
        for stream in adversarialStreams {
            let (expectedEvents, expectedMode) = run([stream.bytes])
            guard !stream.bytes.isEmpty else {
                XCTAssertEqual(expectedEvents, [], "empty stream emitted — \(stream.name)")
                continue
            }
            for size in [1, 2, 3, 7, 64] {
                let (events, mode) = run(chunked(stream.bytes, size: size))
                XCTAssertEqual(events, expectedEvents, "\(stream.name): chunk size \(size) diverged")
                XCTAssertEqual(mode, expectedMode, "\(stream.name): final mode at chunk size \(size) diverged")
            }
        }
    }

    // MARK: 2. Differential vs the frozen legacy tracker

    func testDifferentialOnAdversarialStreams() {
        for stream in adversarialStreams {
            assertDifferential([stream.bytes], "\(stream.name) [whole]")
            guard !stream.bytes.isEmpty else { continue }
            assertDifferential(stream.bytes.map { [$0] }, "\(stream.name) [byte-at-a-time]")
            for size in [2, 3, 7, 64] {
                assertDifferential(chunked(stream.bytes, size: size), "\(stream.name) [size \(size)]")
            }
        }
    }

    /// Seeded byte-alphabet fuzz over the grammar-relevant bytes, whole + random
    /// chunkings + per-byte, differential vs legacy.
    func testSeededFuzzDifferential() {
        let alphabet: [UInt8] = [
            0x1B, 0x07,
            UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "\\"), UInt8(ascii: ";"),
            UInt8(ascii: "?"), UInt8(ascii: "h"), UInt8(ascii: "l"),
            UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"),
            UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "4"), UInt8(ascii: "7"), UInt8(ascii: "9"),
            UInt8(ascii: "A"), UInt8(ascii: "B"), UInt8(ascii: "C"), UInt8(ascii: "D"),
            UInt8(ascii: "a"),
        ]
        var rng = SplitMix64(seed: 0x5EED_2026_0612_0006)
        for iteration in 0..<10000 {
            let length = rng.next(upTo: 33) // 0..32
            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            for _ in 0..<length { bytes.append(alphabet[rng.next(upTo: alphabet.count)]) }

            assertDifferential([bytes], "fuzz #\(iteration) whole bytes=\(bytes)")
            if bytes.isEmpty { continue }
            for round in 0..<2 {
                var chunks: [[UInt8]] = []
                var i = 0
                while i < bytes.count {
                    let end = min(i + 1 + rng.next(upTo: 7), bytes.count)
                    chunks.append(Array(bytes[i..<end]))
                    i = end
                }
                assertDifferential(chunks, "fuzz #\(iteration) chunking \(round) bytes=\(bytes)")
            }
            assertDifferential(bytes.map { [$0] }, "fuzz #\(iteration) byte-at-a-time bytes=\(bytes)")
        }
    }

    /// Token-level fuzz: meaningful fragments so full markers + cap overflows + spoofs
    /// actually assemble often (byte fuzz rarely completes a marker by chance).
    func testSeededTokenFuzzDifferential() {
        let tokens: [String] = [
            "\u{1B}[?1049h", "\u{1B}[?1049l", "\u{1B}[?47h", "\u{1B}[?1047l",
            "\u{1B}[?10", "49h", "\u{1B}[", "?1049;2004h", "\u{1B}[2J",
            "\u{1B}]133;A\u{07}", "\u{1B}]133;B\u{07}", "\u{1B}]133;C\u{07}",
            "\u{1B}]133;D;0\u{07}", "\u{1B}]133;D\u{1B}\\", "\u{1B}]133;",
            "\u{1B}]0;title\u{07}", "\u{1B}]", "133;D;1",
            "\u{1B}P", "\u{1B}X", "\u{1B}^", "\u{1B}_", "\u{1B}\\", "\u{1B}", "\u{07}",
            "plain", String(repeating: "x", count: 300),
        ]
        var rng = SplitMix64(seed: 0x5EED_2026_0612_0007)
        for iteration in 0..<2000 {
            var stream = ""
            for _ in 0..<(1 + rng.next(upTo: 8)) {
                stream += tokens[rng.next(upTo: tokens.count)]
            }
            let bytes = Array(stream.utf8)
            assertDifferential([bytes], "token fuzz #\(iteration) whole bytes=\(bytes)")
            var chunks: [[UInt8]] = []
            var i = 0
            while i < bytes.count {
                let end = min(i + 1 + rng.next(upTo: 5), bytes.count)
                chunks.append(Array(bytes[i..<end]))
                i = end
            }
            assertDifferential(chunks, "token fuzz #\(iteration) chunked bytes=\(bytes)")
            assertDifferential(bytes.map { [$0] }, "token fuzz #\(iteration) byte-at-a-time bytes=\(bytes)")
        }
    }

    /// Mode state must carry across consume() calls identically in both machines (the
    /// fuzz above uses fresh trackers per chunking; this pins long-lived instances).
    func testLongLivedInstanceStateCarryDifferential() {
        let new = TerminalModeTracker()
        let old = LegacyTerminalModeTracker()
        var rng = SplitMix64(seed: 0x5EED_2026_0612_0008)
        let fragments: [[UInt8]] = adversarialStreams.map(\.bytes)
        for iteration in 0..<2000 {
            let fragment = fragments[rng.next(upTo: fragments.count)]
            let newEvents = new.consume(fragment)
            let oldEvents = old.consume(fragment)
            XCTAssertEqual(newEvents, oldEvents, "iteration \(iteration) events diverged")
            XCTAssertEqual(new.mode, old.mode, "iteration \(iteration) mode diverged")
        }
    }
}

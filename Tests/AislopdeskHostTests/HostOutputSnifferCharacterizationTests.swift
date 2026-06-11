import XCTest
import Foundation
import AislopdeskProtocol
@testable import AislopdeskHost

/// CHARACTERIZATION tests for the FUSED ``HostOutputSniffer`` against the two sniffers it
/// replaces (``HostTitleBellSniffer`` + ``HostCommandStatusSniffer``).
///
/// ## The differential oracle
/// Every stream is fed, identically chunked, to all THREE machines. The fused sniffer's
/// output FILTERED BY TYPE must equal each old sniffer's output:
///
///   - `titleBellOnly(fused)  == old title sniffer output`
///   - `commandOnly(fused)    == old command sniffer output`
///
/// We compare per-type FILTERED subsequences, NOT whole arrays: the fused machine emits
/// cross-type messages in byte order (deliberately byte-faithful), whereas the old pair
/// emitted all title/bell messages before all command messages per chunk.
///
/// ## Chunking discipline
/// Every hand-written case runs WHOLE, split at interior chunk boundaries (every boundary
/// for streams <= 1 KiB; for the multi-KiB cap-boundary cases a windowed set of cuts that
/// brackets every divergence frontier — payload start, the 256 cmd-cap trip, the 4096
/// title-cap trip, the terminator — plus edges and a coarse stride; a full 1..<n sweep over
/// ~4 KiB x 3 machines is O(n^2) and follows the existing precedent in
/// `testOverlongOSCBoundedSplitConsistent`), AND one byte at a time.
///
/// NOTE: this file dies together with the OLD sniffers after the production swap. The
/// PERMANENT chunking-invariance oracle lives in `HostOutputSnifferTests.swift`.
final class HostOutputSnifferCharacterizationTests: XCTestCase {

    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"
    private let ST = "\u{1B}\\" // ESC \

    // MARK: Test clock (shared by the old cmd sniffer and the fused sniffer)

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSinceReferenceDate: 0)
        func date() -> Date { lock.lock(); defer { lock.unlock() }; return now }
        func advance(_ seconds: TimeInterval) { lock.lock(); now = now.addingTimeInterval(seconds); lock.unlock() }
    }

    // MARK: Deterministic PRNG (SplitMix64) — seeded fuzz, reproducible failures

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

    // MARK: Type filters

    private func titleBellOnly(_ messages: [WireMessage]) -> [WireMessage] {
        messages.filter {
            switch $0 {
            case .title, .bell: return true
            default: return false
            }
        }
    }

    private func commandOnly(_ messages: [WireMessage]) -> [WireMessage] {
        messages.filter {
            if case .commandStatus = $0 { return true }
            return false
        }
    }

    // MARK: Differential runner

    /// Feeds `chunks` to fresh instances of all three machines (the old cmd sniffer and the
    /// fused sniffer SHARE one clock) and asserts the per-type filtered equality.
    private func assertDifferential(
        _ chunks: [[UInt8]],
        _ label: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let clock = TestClock()
        let title = HostTitleBellSniffer()
        let cmd = HostCommandStatusSniffer(clock: clock.date)
        let fused = HostOutputSniffer(clock: clock.date)
        var titleOut: [WireMessage] = []
        var cmdOut: [WireMessage] = []
        var fusedOut: [WireMessage] = []
        for chunk in chunks {
            titleOut += title.observe(chunk)
            cmdOut += cmd.observe(chunk)
            fusedOut += fused.observe(chunk)
        }
        XCTAssertEqual(titleBellOnly(fusedOut), titleOut,
                       "title/bell filtered output diverged — \(label())", file: file, line: line)
        XCTAssertEqual(commandOnly(fusedOut), cmdOut,
                       "commandStatus filtered output diverged — \(label())", file: file, line: line)
    }

    /// Splits `bytes` into two chunks at `cut`.
    private func twoChunks(_ bytes: [UInt8], cut: Int) -> [[UInt8]] {
        [Array(bytes[0..<cut]), Array(bytes[cut...])]
    }

    /// One chunk per byte (also bypasses any fast path in the fused machine).
    private func byteAtATime(_ bytes: [UInt8]) -> [[UInt8]] {
        bytes.map { [$0] }
    }

    /// The interior cut positions to exercise. For short streams: EVERY interior boundary.
    /// For multi-KiB streams: edges + a band of +-16 around every `hot` offset (the
    /// divergence frontiers the caller computed for this stream) + a coarse stride —
    /// a full sweep over ~4 KiB streams x 3 machines is O(n^2) (existing-test precedent:
    /// `testOverlongOSCBoundedSplitConsistent` uses representative sizes for the same reason).
    private func interiorCuts(count: Int, hot: [Int] = []) -> [Int] {
        guard count > 1 else { return [] }
        if count <= 1024 { return Array(1..<count) }
        var cuts = Set<Int>()
        for edge in 1...16 {
            cuts.insert(edge)
            cuts.insert(count - edge)
        }
        for center in hot {
            for delta in -16...16 {
                let cut = center + delta
                if cut >= 1 && cut < count { cuts.insert(cut) }
            }
        }
        var s = 17
        while s < count { cuts.insert(s); s += 257 }
        return cuts.sorted()
    }

    /// Runs the full chunking discipline for one stream: whole, every selected interior
    /// two-chunk split, and one byte at a time.
    private func assertDifferentialAllChunkings(
        _ bytes: [UInt8],
        hot: [Int] = [],
        _ label: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertDifferential([bytes], "\(label()) [whole]", file: file, line: line)
        for cut in interiorCuts(count: bytes.count, hot: hot) {
            assertDifferential(twoChunks(bytes, cut: cut), "\(label()) [cut \(cut)]", file: file, line: line)
        }
        assertDifferential(byteAtATime(bytes), "\(label()) [byte-at-a-time]", file: file, line: line)
    }

    /// Fresh fused sniffer fed the whole stream — for hand-written expected-value asserts.
    private func fusedWhole(_ bytes: [UInt8]) -> [WireMessage] {
        HostOutputSniffer(clock: { Date(timeIntervalSinceReferenceDate: 0) }).observe(bytes)
    }

    // MARK: Divergence 2 — oscCap 4096 (title) vs 256 (cmd): payload-length boundaries

    /// `0;<pad>` titles at total OSC payload lengths 255/256/257/4095/4096/4097, BEL- and
    /// ST-terminated. The title cap is 4096: <=4096 emits, 4097 is discarded. The old cmd
    /// machine flips into oscDiscard above 256 — the differential proves that internal state
    /// divergence is emission-invisible.
    func testTitlePayloadLengthBoundaries() {
        for length in [255, 256, 257, 4095, 4096, 4097] {
            let pad = String(repeating: "x", count: length - 2) // "0;" + pad == `length` bytes
            for (termName, term) in [("BEL", BEL), ("ST", ST)] {
                let bytes = Array("\(ESC)]0;\(pad)\(term)".utf8)
                let expected: [WireMessage] = length <= 4096 ? [.title(pad)] : []
                XCTAssertEqual(fusedWhole(bytes), expected, "title L=\(length) \(termName)")
                // Hot offsets: payload start (2), cmd-cap trip (2+257), title-cap trip
                // (2+4097), terminator.
                let hot = [2, 2 + 257, 2 + 4097, bytes.count - 2]
                assertDifferentialAllChunkings(bytes, hot: hot, "title L=\(length) \(termName)")
            }
        }
    }

    /// `133;D;0;<pad>` payloads (preceded by a `133;C` so the D is live) at the same length
    /// boundaries. The cmd cap is 256: <=256 emits `.idle`, >=257 is ignored. In the fused
    /// machine lengths 257..4096 DO reach finishOSC (title cap) — the EXACT-PARITY guard
    /// must drop them.
    func testCommandPayloadLengthBoundaries() {
        let cPrefix = Array("\(ESC)]133;C\(BEL)".utf8) // 8 bytes → .running
        for length in [255, 256, 257, 4095, 4096, 4097] {
            let pad = String(repeating: "x", count: length - 8) // "133;D;0;" + pad == `length`
            for (termName, term) in [("BEL", BEL), ("ST", ST)] {
                let bytes = cPrefix + Array("\(ESC)]133;D;0;\(pad)\(term)".utf8)
                var expected: [WireMessage] = [.commandStatus(.running)]
                if length <= 256 {
                    expected.append(.commandStatus(.idle(exitCode: 0, durationMS: 0)))
                }
                XCTAssertEqual(fusedWhole(bytes), expected, "cmd L=\(length) \(termName)")
                // Hot offsets: C terminator (7), D payload start (10), cmd-cap trip
                // (10+257), title-cap trip (10+4097), terminator.
                let hot = [7, 10, 10 + 257, 10 + 4097, bytes.count - 2]
                assertDifferentialAllChunkings(bytes, hot: hot, "cmd L=\(length) \(termName)")
            }
        }
    }

    // MARK: BEL- vs ST-terminated (small canonical forms)

    func testBELAndSTTerminatedTitlesAndMarks() {
        for (name, stream) in [
            ("title BEL", "\(ESC)]2;hello\(BEL)"),
            ("title ST", "\(ESC)]2;hello\(ST)"),
            ("133;C BEL", "\(ESC)]133;C\(BEL)"),
            ("133;C ST", "\(ESC)]133;C\(ST)"),
        ] {
            assertDifferentialAllChunkings(Array(stream.utf8), name)
        }
        XCTAssertEqual(fusedWhole(Array("\(ESC)]2;hello\(ST)".utf8)), [.title("hello")])
        XCTAssertEqual(fusedWhole(Array("\(ESC)]133;C\(ST)".utf8)), [.commandStatus(.running)])
    }

    // MARK: ESC-ESC

    func testDoubleESCSequences() {
        // ESC ESC ] 2;x BEL — the second ESC re-classifies; the OSC still parses.
        let escEscOSC = Array("\(ESC)\(ESC)]2;x\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(escEscOSC), [.title("x")])
        assertDifferentialAllChunkings(escEscOSC, "ESC ESC ]2;x BEL")

        // ESC ]2;x ESC ESC \ — oscEscape sees a second ESC (not `\`): the OSC ends (title
        // fires), the `\` is a lone nF-escape final.
        let oscEscEsc = Array("\(ESC)]2;x\(ESC)\(ESC)\\".utf8)
        XCTAssertEqual(fusedWhole(oscEscEsc), [.title("x")])
        assertDifferentialAllChunkings(oscEscEsc, "ESC]2;x ESC ESC backslash")

        // Same shape through the 133 path.
        let cmdEscEsc = Array("\(ESC)]133;C\(ESC)\(ESC)\\".utf8)
        XCTAssertEqual(fusedWhole(cmdEscEsc), [.commandStatus(.running)])
        assertDifferentialAllChunkings(cmdEscEsc, "ESC]133;C ESC ESC backslash")
    }

    // MARK: stray ESC ending an OSC, immediately followed by another OSC

    func testStrayESCEndsOSCThenNextOSCParses() {
        // Title flavor: the stray ESC fires the first title AND introduces the second OSC.
        let titles = Array("\(ESC)]0;abc".utf8) + Array("\(ESC)]2;real\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(titles), [.title("abc"), .title("real")])
        assertDifferentialAllChunkings(titles, "stray-ESC title then title")

        // Cmd flavor: stray ESC fires the C, the following D emits idle.
        let marks = Array("\(ESC)]133;C".utf8) + Array("\(ESC)]133;D;0\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(marks),
                       [.commandStatus(.running), .commandStatus(.idle(exitCode: 0, durationMS: 0))])
        assertDifferentialAllChunkings(marks, "stray-ESC C then D")

        // Cross flavor: a title OSC ended by the stray ESC of a 133 mark.
        let cross = Array("\(ESC)]2;t".utf8) + Array("\(ESC)]133;C\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(cross), [.title("t"), .commandStatus(.running)])
        assertDifferentialAllChunkings(cross, "stray-ESC title then C")
    }

    // MARK: DCS/SOS/PM/APC string bodies must swallow embedded spoofs (NO emission)

    func testStringSequencesSwallowEmbeddedSpoofs() {
        for (name, intro) in [("DCS", "P"), ("SOS", "X"), ("PM", "^"), ("APC", "_")] {
            // Body embeds `ESC]2;spoof BEL` — the BEL terminates the STRING (in this grammar
            // BEL ends DCS/SOS/PM/APC too), and nothing was emitted for the embedded OSC.
            let titleSpoof = Array("\(ESC)\(intro)\(ESC)]2;spoof\(BEL)".utf8)
            XCTAssertEqual(fusedWhole(titleSpoof), [], "\(name) title spoof emitted")
            assertDifferentialAllChunkings(titleSpoof, "\(name) embedded title spoof")

            // Body embeds `ESC]133;C BEL` — likewise swallowed.
            let cmdSpoof = Array("\(ESC)\(intro)\(ESC)]133;C\(BEL)".utf8)
            XCTAssertEqual(fusedWhole(cmdSpoof), [], "\(name) cmd spoof emitted")
            assertDifferentialAllChunkings(cmdSpoof, "\(name) embedded cmd spoof")

            // ST-terminated string with the spoof fully inside, then a REAL title — resync.
            let stBody = Array("\(ESC)\(intro)junk\(ESC)]2;spoof".utf8) + Array("\(ESC)\\".utf8)
                + Array("\(ESC)]2;real\(BEL)".utf8)
            XCTAssertEqual(fusedWhole(stBody), [.title("real")], "\(name) ST resync")
            assertDifferentialAllChunkings(stBody, "\(name) ST body then real title")
        }
    }

    // MARK: ground BEL adjacent to an OSC terminator BEL

    func testGroundBELAdjacentToOSCTerminatorBEL() {
        // Terminator BEL immediately followed by a real bell.
        let after = Array("\(ESC)]0;t\(BEL)\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(after), [.title("t"), .bell])
        assertDifferentialAllChunkings(after, "OSC BEL then ground BEL")

        // Real bell immediately before an OSC whose terminator is a BEL.
        let before = Array("\(BEL)\(ESC)]0;t\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(before), [.bell, .title("t")])
        assertDifferentialAllChunkings(before, "ground BEL then OSC BEL")

        // Same around a 133 mark.
        let cmd = Array("\(BEL)\(ESC)]133;C\(BEL)\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(cmd), [.bell, .commandStatus(.running), .bell])
        assertDifferentialAllChunkings(cmd, "ground BELs around 133;C")
    }

    // MARK: title containing ';' (first-';' split only)

    func testTitleWithSemicolons() {
        let bytes = Array("\(ESC)]0;a;b;c\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(bytes), [.title("a;b;c")])
        assertDifferentialAllChunkings(bytes, "title with semicolons")
    }

    // MARK: `133` with no ';' / leading-empty-Ps `;x`

    func testMalformedPsPayloads() {
        let bare133 = Array("\(ESC)]133\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(bare133), [])
        assertDifferentialAllChunkings(bare133, "bare 133, no semicolon")

        let leadingEmpty = Array("\(ESC)];x\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(leadingEmpty), [])
        assertDifferentialAllChunkings(leadingEmpty, "leading-empty Ps ;x")

        // `1330;C` — Ps is "1330", NOT "133".
        let ps1330 = Array("\(ESC)]1330;C\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(ps1330), [])
        assertDifferentialAllChunkings(ps1330, "Ps 1330")
    }

    // MARK: first-prompt phantom `D;0` with no preceding C

    func testFirstPromptPhantomDIsIgnored() {
        let bytes = Array("\(ESC)]133;D;0\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(bytes), [])
        assertDifferentialAllChunkings(bytes, "phantom D;0 without C")

        // And a D after the phantom-D + a real C still measures from the REAL C.
        let cycle = Array("\(ESC)]133;D;0\(BEL)\(ESC)]133;C\(BEL)\(ESC)]133;D;7\(BEL)".utf8)
        XCTAssertEqual(fusedWhole(cycle),
                       [.commandStatus(.running), .commandStatus(.idle(exitCode: 7, durationMS: 0))])
        assertDifferentialAllChunkings(cycle, "phantom D, then C→D")
    }

    // MARK: C→D duration via the injected clock (advance BETWEEN the marks)

    func testCToDDurationViaInjectedClock() {
        let cBytes = Array("\(ESC)]133;C\(BEL)".utf8)
        let dBytes = Array("\(ESC)]133;D;3\(BEL)".utf8)

        // For every chunk size of each mark, the duration must be identical (the clock is
        // read when the mark COMPLETES, so chunking inside a mark cannot change it).
        for size in 1...cBytes.count {
            let clock = TestClock()
            let cmd = HostCommandStatusSniffer(clock: clock.date)
            let fused = HostOutputSniffer(clock: clock.date)
            var cmdOut: [WireMessage] = []
            var fusedOut: [WireMessage] = []
            func feed(_ bytes: [UInt8]) {
                var i = 0
                while i < bytes.count {
                    let end = min(i + size, bytes.count)
                    let chunk = Array(bytes[i..<end])
                    cmdOut += cmd.observe(chunk)
                    fusedOut += fused.observe(chunk)
                    i = end
                }
            }
            feed(cBytes)
            clock.advance(12)
            feed(dBytes)
            let expected: [WireMessage] = [
                .commandStatus(.running),
                .commandStatus(.idle(exitCode: 3, durationMS: 12_000)),
            ]
            XCTAssertEqual(commandOnly(fusedOut), cmdOut, "chunk size \(size)")
            XCTAssertEqual(fusedOut, expected, "chunk size \(size)")
        }
    }

    // MARK: lastTitle dedup parity

    func testTitleDedupParity() {
        let bytes = Array((
            "\(ESC)]0;same\(BEL)"
            + "\(ESC)]2;same\(BEL)"     // deduped
            + "\(ESC)]133;C\(BEL)"      // a mark between the dupes must not break dedup
            + "\(ESC)]0;same\(BEL)"     // still deduped
            + "\(ESC)]0;other\(BEL)"
        ).utf8)
        XCTAssertEqual(fusedWhole(bytes), [.title("same"), .commandStatus(.running), .title("other")])
        assertDifferentialAllChunkings(bytes, "dedup across an interleaved mark")
    }

    // MARK: interleaved cross-type stream (byte-faithful ordering, filtered parity)

    func testInterleavedCrossTypeStream() {
        let bytes = Array((
            "welcome\n"
            + "\(ESC)]0;Claude Code\(BEL)"
            + "\(ESC)]133;A\(BEL)"
            + "$ make\n"
            + "\(ESC)]133;C\(BEL)"
            + "\(BEL)building\(ESC)[2J"
            + "\(ESC)]2;make — repo\(ST)"
            + "\(ESC)]133;D;2\(BEL)"
            + "\(BEL)"
        ).utf8)
        let expected: [WireMessage] = [
            .title("Claude Code"),
            .commandStatus(.running),
            .bell,
            .title("make — repo"),
            .commandStatus(.idle(exitCode: 2, durationMS: 0)),
            .bell,
        ]
        XCTAssertEqual(fusedWhole(bytes), expected) // byte-faithful cross-type ORDER
        assertDifferentialAllChunkings(bytes, "interleaved real-world stream")
    }

    // MARK: seeded-PRNG differential fuzz

    /// ~10k short random streams over the divergence-relevant alphabet, each run whole and
    /// under random chunkings, differential-checked against the two old sniffers.
    func testSeededFuzzDifferential() {
        let alphabet: [UInt8] = [
            0x1B, 0x07,
            UInt8(ascii: "]"), UInt8(ascii: "\\"), UInt8(ascii: ";"),
            UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"),
            UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "3"),
            UInt8(ascii: "C"), UInt8(ascii: "D"),
            UInt8(ascii: "a"),
        ]
        var rng = SplitMix64(seed: 0x5EED_2026_0612_0001)
        for iteration in 0..<10_000 {
            let length = rng.next(upTo: 33) // 0..32
            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            for _ in 0..<length { bytes.append(alphabet[rng.next(upTo: alphabet.count)]) }

            assertDifferential([bytes], "fuzz #\(iteration) whole bytes=\(bytes)")
            if bytes.isEmpty { continue }
            // Two random chunkings + strict one-byte-at-a-time.
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
            assertDifferential(byteAtATime(bytes), "fuzz #\(iteration) byte-at-a-time bytes=\(bytes)")
        }
    }

    /// Token-level fuzz: random concatenations of MEANINGFUL fragments so emissions (titles,
    /// bells, C/D marks, string bodies) actually fire often — the byte-alphabet fuzz above
    /// rarely assembles a full mark by chance.
    func testSeededTokenFuzzDifferential() {
        let tokens: [String] = [
            "\u{1B}]", "0;", "2;", "133;", "133;C", "133;D;0", "C", "D", ";",
            "\u{07}", "\u{1B}\\", "\u{1B}", "\u{1B}P", "\u{1B}X", "\u{1B}^", "\u{1B}_",
            "a", "spoof", "\u{1B}]2;t\u{07}", "\u{1B}]133;C\u{07}", "\u{1B}]133;D;1\u{07}",
        ]
        var rng = SplitMix64(seed: 0x5EED_2026_0612_0002)
        for iteration in 0..<2_000 {
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
            assertDifferential(byteAtATime(bytes), "token fuzz #\(iteration) byte-at-a-time bytes=\(bytes)")
        }
    }
}

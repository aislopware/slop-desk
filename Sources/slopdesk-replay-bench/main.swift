// Snapshot-replay composer benchmark.
//
// Times `TerminalReplaySnapshot.compose(raw:rows:cols:)` — the whole cold-reattach
// state-transfer render (screen-model feed + input-mode scan + render) — over synthetic
// churn shaped like the workloads that actually fill the ReplayBuffer ring:
//   - build/test log lines with SGR color runs (swift test / prek output),
//   - `\r`-overprint progress bars (the compaction-heavy shape),
//   - prompt redraw clusters (OSC 133 + DECSCUSR + SGR-heavy prompt).
//
// Deterministic (seeded LCG, no Date/random in the stream) so runs are comparable.
// `swift run -c release slopdesk-replay-bench [mib...]` — default sizes 4, 16, 64 MiB.

import Foundation
import SlopDeskHost

struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

func makeChurn(bytes target: Int) -> Data {
    var rng = LCG(state: 0x5EED)
    var out = Data()
    out.reserveCapacity(target + 4096)
    let words = ["Compiling", "Testing", "Building", "Linking", "Planning", "Write"]
    let files = ["MuxChannelSession.swift", "ReplayBuffer.swift", "HostServer.swift", "TerminalScreenModel.swift"]
    while out.count < target {
        switch rng.below(10) {
        case 0..<5: // build/test log line with a color run
            let w = words[rng.below(words.count)]
            let f = files[rng.below(files.count)]
            let n = rng.below(9000)
            out.append(Data("\u{1B}[1m[\(n)/9000]\u{1B}[0m \(w) SlopDeskHost \(f)\r\n".utf8))
        case 5..<8: // \r-overprint progress bar (repainted many times)
            let repaints = 20 + rng.below(60)
            for i in 0..<repaints {
                let pct = min(100, i * 100 / repaints)
                let bar = String(repeating: "=", count: pct / 4)
                out.append(Data("\r\u{1B}[K\u{1B}[32m[\(bar)>\u{1B}[0m] \(pct)% (\(rng.below(100_000)) / 100000)".utf8))
            }
            out.append(Data("\r\n".utf8))
        default: // prompt redraw cluster: OSC 133 marks + DECSCUSR + SGR-heavy prompt
            let prompt = "\u{1B}]133;A\u{7}\u{1B}[5 q\u{1B}[1;36m~/oss/slop-desk\u{1B}[0m "
                + "\u{1B}[35mmain\u{1B}[0m ❯ \u{1B}]133;B\u{7}git push\r\n"
                + "\u{1B}[0 q\u{1B}]133;C\u{7}"
            out.append(Data(prompt.utf8))
        }
    }
    return out
}

let args = CommandLine.arguments.dropFirst().compactMap { Int($0) }
let sizesMiB = args.isEmpty ? [4, 16, 64] : args

print("compose bench — rows=45 cols=170 (typical pane), churn=synthetic build/test stream")
for mib in sizesMiB {
    let input = makeChurn(bytes: mib * 1024 * 1024)
    // Warm-up pass at the smallest size only once keeps the run short; steady-state numbers
    // here are dominated by the per-byte model feed, not allocation warm-up.
    let start = ContinuousClock.now
    let rendered = TerminalReplaySnapshot.compose(raw: input, rows: 45, cols: 170)
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    let mbps = Double(input.count) / 1024 / 1024 / seconds
    print(String(
        format: "  %3d MiB in  %7.3f s   (%6.1f MiB/s)  -> rendered %d bytes",
        mib, seconds, mbps, rendered.count,
    ))
}

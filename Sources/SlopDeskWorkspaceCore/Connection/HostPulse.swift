import Foundation
import SlopDeskProtocol

/// The DISPLAYED host pulse — what the sidebar footer's second line actually says, which is not
/// quite what the last `hostVitals` sample said.
///
/// The rail has no animation by design (docs/DECISIONS.md, the badge saga): nothing there moves
/// unless the movement carries meaning. A raw CPU percent polled every few seconds fails that test —
/// it twitches 31 → 29 → 33 on an idle machine and the eye is pulled to the corner for nothing. So a
/// new sample only DISPLACES the shown value once it differs by ``deadband`` points; below that the
/// row holds still. The reading stays honest (no smoothing, no lag — the shown number is always a
/// number the host actually reported), it just refuses to redraw for noise.
///
/// Pressure is exempt: a level change is a state change, never noise, and takes effect immediately.
public struct HostPulse: Equatable, Sendable {
    /// All-core CPU busy percent as displayed (`0...100`).
    public var cpuPercent: Int
    /// Memory-in-use percent as displayed (`0...100`).
    public var memoryPercent: Int
    /// The kernel's memory-pressure verdict — the ink classifier for the memory metric.
    public var memoryPressure: MetadataCodec.MemoryPressure
    /// Free space in MiB on the host's work volume; `nil` ⇒ the host could not read it and the
    /// metric is omitted rather than guessed. No deadband: the metric is rendered COARSELY (two
    /// significant figures at most), and a format that only names round numbers is its own
    /// deadband — a build churning a few hundred MiB never changes the run.
    public var diskFreeMiB: UInt32?

    public init(
        cpuPercent: Int, memoryPercent: Int, memoryPressure: MetadataCodec.MemoryPressure,
        diskFreeMiB: UInt32? = nil,
    ) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.memoryPressure = memoryPressure
        self.diskFreeMiB = diskFreeMiB
    }

    /// The points a metric must move before the row redraws. Three is the smallest step that clears
    /// idle jitter on a real machine while still tracking a genuine climb within one poll of it.
    public static let deadband = 3

    /// Folds a fresh sample into the shown value: each metric keeps its displayed number until the
    /// sample is at least ``deadband`` points away, then snaps to the sample exactly (never to a
    /// midpoint — the row must always show a percent the host really reported). The first sample is
    /// shown as-is; pressure always takes the new level.
    public static func settled(previous: Self?, sample: MetadataCodec.HostVitals) -> Self {
        let cpu = Int(sample.cpuPercent)
        let memory = Int(sample.memoryPercent)
        guard let previous else {
            return Self(
                cpuPercent: cpu, memoryPercent: memory, memoryPressure: sample.memoryPressure,
                diskFreeMiB: sample.diskFreeMiB,
            )
        }
        return Self(
            cpuPercent: held(shown: previous.cpuPercent, sample: cpu),
            memoryPercent: held(shown: previous.memoryPercent, sample: memory),
            memoryPressure: sample.memoryPressure,
            diskFreeMiB: sample.diskFreeMiB,
        )
    }

    private static func held(shown: Int, sample: Int) -> Int {
        abs(sample - shown) >= deadband ? sample : shown
    }
}

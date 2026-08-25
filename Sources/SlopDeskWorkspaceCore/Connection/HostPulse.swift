import CSlopDeskFFI
import SlopDeskProtocol

/// The DISPLAYED host pulse — what the sidebar footer's second line actually says, which is not
/// quite what the last `hostVitals` sample said.
///
/// A face over `slopdesk_workspace::connection`. The rail has no animation by design (docs/DECISIONS.md,
/// the badge saga): nothing there moves unless the movement carries meaning, and a raw CPU percent
/// polled every few seconds fails that test. The deadband that holds it still is the crate's —
/// `slopdesk_connection_pulse_settled` — beside the classifiers that decide how loud each of these
/// numbers is allowed to be, because the two are one reading and a percent held here while the alarm
/// was scored there would be an island disagreeing with itself.
public struct HostPulse: Equatable, Sendable {
    /// All-core CPU busy percent as displayed (`0...100`).
    public var cpuPercent: Int
    /// Memory-in-use percent as displayed (`0...100`).
    public var memoryPercent: Int
    /// The kernel's memory-pressure verdict — the ink classifier for the memory metric.
    public var memoryPressure: MetadataCodec.MemoryPressure
    /// Free space in MiB on the host's work volume; `nil` ⇒ the host could not read it and the
    /// metric is omitted rather than guessed.
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

    /// Folds a fresh sample into the shown value: each metric keeps its displayed number until the
    /// sample has moved far enough to be worth a redraw, then snaps to the sample exactly. The first
    /// sample is shown as-is; pressure and free disk always take the new reading.
    public static func settled(previous: Self?, sample: MetadataCodec.HostVitals) -> Self {
        let arriving = Self(
            cpuPercent: Int(sample.cpuPercent),
            memoryPercent: Int(sample.memoryPercent),
            memoryPressure: sample.memoryPressure,
            diskFreeMiB: sample.diskFreeMiB,
        )
        let held = slopdesk_connection_pulse_settled(
            previous != nil, (previous ?? arriving).crossing, arriving.crossing,
        )
        return Self(
            cpuPercent: Int(held.cpu_percent),
            memoryPercent: Int(held.memory_percent),
            // Pressure and disk cross untouched, so they are read back from the SAMPLE's own types
            // rather than re-derived from the bytes that carried them.
            memoryPressure: arriving.memoryPressure,
            diskFreeMiB: held.has_disk ? held.disk_free_mib : nil,
        )
    }

    /// This pulse in the boundary's shape. `diskFreeMiB`'s absence becomes a presence FLAG rather
    /// than a sentinel, because zero free bytes is the loudest real reading there is.
    ///
    /// It sits on the value rather than beside either caller: the island's readout and the deadband
    /// that decides what the island is READING both pack it, and two packings would let one of them
    /// pass a disk figure the other called absent.
    package var crossing: SlopDeskHostPulse {
        SlopDeskHostPulse(
            cpu_percent: UInt32(max(0, cpuPercent)),
            memory_percent: UInt32(max(0, memoryPercent)),
            memory_pressure: memoryPressure.rawValue,
            disk_free_mib: diskFreeMiB ?? 0,
            has_disk: diskFreeMiB != nil,
        )
    }
}

import Foundation
import SlopDeskProtocol

/// The host machine's PULSE sampler — the `hostVitals` verb's engine (CPU busy %, memory in use %,
/// kernel memory-pressure level). Process-wide singleton because the reading is host-global while the
/// metadata probe is per-pane: ``MuxChannelSession/serveMetadata`` builds a fresh
/// ``HostMetadataProbe`` per request, so the CPU baseline has to outlive it. Lock-protected — two
/// panes' metadata queues can race.
///
/// **CPU is a DELTA, so the first answer is silence.** Mach hands out cumulative tick counters, not a
/// rate; a percent only exists between two snapshots. The first request therefore banks the baseline
/// and returns `nil` (the verb replies `.error`, the client asks again next poll). Two further guards
/// keep the number honest rather than merely present:
///
/// - **Stale baseline → discard.** A snapshot older than ``maxBaselineAge`` spans a gap the client
///   spent disconnected/asleep; averaging over it would report a machine that no longer exists. Rebank
///   and stay silent for one poll.
/// - **Too-fresh baseline → repeat the last answer.** Under ``minWindow`` the tick delta is mostly
///   quantization noise, so a second caller arriving right behind the first gets the cached reading
///   and the baseline does NOT move (otherwise two clients polling in lockstep would starve each
///   other's window down to nothing).
///
/// Memory needs no window — it is an instantaneous count.
///
/// Every syscall is checked (`KERN_SUCCESS`, exact struct size) and degrades to `nil`/`.normal`; the
/// sampler never traps, never force-unwraps, and never blocks (no sleeping to manufacture a window).
final class HostVitalsSampler: @unchecked Sendable {
    /// The production singleton (one machine → one baseline).
    static let shared = HostVitalsSampler()

    /// Older than this, a baseline describes a different situation — rebank instead of averaging
    /// across the gap. Comfortably above the client's ~4 s poll so a normal cadence never trips it.
    static let maxBaselineAge: Duration = .seconds(30)
    /// Below this, the tick delta is noise — answer from the cache and keep the baseline.
    static let minWindow: Duration = .seconds(1)

    /// Mach's four aggregate CPU tick counters (all cores summed), as `HOST_CPU_LOAD_INFO` reports
    /// them. `natural_t` (32-bit) counters that DO wrap — the delta math below is deliberately
    /// wrapping, never a difference of widened values.
    struct CPUTicks: Equatable, Sendable {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private struct Baseline {
        var ticks: CPUTicks
        var taken: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var baseline: Baseline?
    /// The last percent actually computed — what a too-fresh repeat call gets.
    private var cached: MetadataCodec.HostVitals?

    // MARK: - Pure math (no syscall — these are what the unit tests drive)

    /// The busy percent between two tick snapshots: `100 - idle/total`, rounded, clamped `0...100`.
    /// `nil` when the window carries no ticks at all (identical snapshots — nothing to divide by).
    ///
    /// Deltas use WRAPPING subtraction (`&-`) because the counters are 32-bit and roll over on a
    /// long-lived host; a widened subtraction would report a nonsense spike for one poll at wrap.
    static func busyPercent(previous: CPUTicks, current: CPUTicks) -> UInt8? {
        let user = UInt64(current.user &- previous.user)
        let system = UInt64(current.system &- previous.system)
        let idle = UInt64(current.idle &- previous.idle)
        let nice = UInt64(current.nice &- previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        let busy = total - idle
        // Integer round-half-up: (busy * 100 + total/2) / total. Kept in integers so the percent the
        // client renders is exactly the percent the host computed.
        let percent = (busy * 100 + total / 2) / total
        return UInt8(min(percent, 100))
    }

    /// Physical memory in use as a percent of installed RAM, rounded, clamped `0...100`. `0` when the
    /// machine reports no RAM (an impossible reading that must not divide by zero).
    static func memoryPercent(usedBytes: UInt64, totalBytes: UInt64) -> UInt8 {
        guard totalBytes > 0 else { return 0 }
        let percent = (min(usedBytes, totalBytes) * 100 + totalBytes / 2) / totalBytes
        return UInt8(min(percent, 100))
    }

    /// Maps the kernel's `kern.memorystatus_vm_pressure_level` (a SPARSE bitmask-flavoured ladder:
    /// 1 normal, 2 warn, 4 critical) onto ``MetadataCodec/MemoryPressure``. Anything else — an
    /// unreadable sysctl, a future level — reads `.normal`: an alarm this build cannot justify is
    /// worse than no alarm.
    static func pressure(sysctlLevel: Int32) -> MetadataCodec.MemoryPressure {
        switch sysctlLevel {
        case 2: .warn
        case 4: .critical
        default: .normal
        }
    }

    // MARK: - Stateful core (readings injected — still no syscall)

    /// Folds one set of readings into a vitals answer, applying the baseline / staleness / cache
    /// rules described in the type doc. `nil` = no reading to publish yet.
    func vitals(
        cpuTicks: CPUTicks,
        memoryPercent: UInt8,
        pressure: MetadataCodec.MemoryPressure,
        now: ContinuousClock.Instant,
    ) -> MetadataCodec.HostVitals? {
        lock.lock()
        defer { lock.unlock() }
        guard let previous = baseline else {
            baseline = Baseline(ticks: cpuTicks, taken: now)
            return nil
        }
        let age = previous.taken.duration(to: now)
        if age > Self.maxBaselineAge {
            // The gap swallowed the window — rebank, stay silent, and drop the stale cache so the
            // next answer is a fresh measurement rather than a number from before the gap.
            baseline = Baseline(ticks: cpuTicks, taken: now)
            cached = nil
            return nil
        }
        if age < Self.minWindow {
            // Too soon to re-measure. The memory half IS instantaneous, so refresh it on the cached
            // CPU percent rather than handing back a wholly frozen row.
            guard let cached else { return nil }
            let refreshed = MetadataCodec.HostVitals(
                cpuPercent: cached.cpuPercent,
                memoryPercent: memoryPercent,
                pressure: pressure,
            )
            self.cached = refreshed
            return refreshed
        }
        guard let cpu = Self.busyPercent(previous: previous.ticks, current: cpuTicks) else {
            // A window with zero ticks (a stopped clock, never seen in practice): keep the baseline
            // so the NEXT poll measures across a longer window instead of resetting forever.
            return cached
        }
        baseline = Baseline(ticks: cpuTicks, taken: now)
        let vitals = MetadataCodec.HostVitals(
            cpuPercent: cpu, memoryPercent: memoryPercent, pressure: pressure,
        )
        cached = vitals
        return vitals
    }

    /// Drops the baseline + cache (test seam; production keeps one sampler for the process life).
    func reset() {
        lock.lock()
        baseline = nil
        cached = nil
        lock.unlock()
    }

    // MARK: - The real readings (macOS syscalls; compiled + reviewed only, never unit-tested)

    /// The production entry point: read the machine's counters and fold them through ``vitals``.
    /// `nil` on a first call (baseline priming) or a refused syscall.
    func sample() -> MetadataCodec.HostVitals? {
        #if os(macOS)
        guard let ticks = Self.readCPUTicks() else { return nil }
        return vitals(
            cpuTicks: ticks,
            memoryPercent: Self.readMemoryPercent(),
            pressure: Self.readPressure(),
            now: ContinuousClock.now,
        )
        #else
        nil
        #endif
    }

    #if os(macOS)
    /// One send right for the process (`mach_host_self()` hands out a fresh right per call — taking
    /// one and keeping it avoids leaking a port on every poll).
    private static let hostPort: mach_port_t = mach_host_self()

    /// `HOST_CPU_LOAD_INFO`: the four aggregate tick counters. `nil` on any non-`KERN_SUCCESS`.
    private static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size,
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundw in
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, reboundw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3,
        )
    }

    /// `HOST_VM_INFO64` folded into the Activity Monitor "Memory Used" definition: wired +
    /// app-internal (minus purgeable) + compressed, over the installed RAM. The file cache is
    /// deliberately EXCLUDED — macOS parks every free page in it, so counting it would pin the
    /// readout near 100% on a perfectly healthy machine. `0` on a refused syscall (the pressure level
    /// still carries the real signal).
    private static func readMemoryPercent() -> UInt8 {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size,
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(hostPort, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // `host_page_size` rather than the `vm_kernel_page_size` global — the counts above are in VM
        // pages, and a C global var is not concurrency-safe to read under strict concurrency.
        var pageSizeBytes: vm_size_t = 0
        guard host_page_size(hostPort, &pageSizeBytes) == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(pageSizeBytes)
        let interned = UInt64(info.internal_page_count)
        let purgeable = UInt64(info.purgeable_count)
        // Saturating: purgeable is a SUBSET of internal, but a torn read must not underflow.
        let app = interned > purgeable ? interned - purgeable : 0
        let pages = app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return memoryPercent(
            usedBytes: pages * pageSize,
            totalBytes: Foundation.ProcessInfo.processInfo.physicalMemory,
        )
    }

    /// `kern.memorystatus_vm_pressure_level` — the kernel's own verdict. Unreadable → `.normal`.
    private static func readPressure() -> MetadataCodec.MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        guard result == 0, size == MemoryLayout<Int32>.size else { return .normal }
        return pressure(sysctlLevel: level)
    }
    #endif
}

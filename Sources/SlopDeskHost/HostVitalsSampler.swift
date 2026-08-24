import CSlopDeskFFI
import Foundation
import SlopDeskProtocol

/// The host machine's PULSE sampler — the `hostVitals` verb's engine (CPU busy %, memory in use %,
/// kernel memory-pressure level, free space on the home volume).
///
/// A face over `slopdesk-panecensus`'s `vitals`, which owns every rule and every reading: the
/// baseline discipline (a CPU percent is a DELTA, so the first poll banks a snapshot and answers
/// nothing), the staleness and minimum-window guards, the Activity-Monitor memory definition, the
/// `statfs` saturation, and the four Mach/`sysctl` calls themselves (through `slopdesk-posix`).
/// What stays here is the two things Rust must not hold: the process-wide singleton, and the lock
/// that serialises the two panes' metadata queues that can race for it.
///
/// The sampler is a HANDLE rather than a value because the baseline has to outlive the request —
/// hostd builds a fresh ``HostMetadataProbe`` per request while the reading is host-global. The
/// three handle obligations of docs/55 §4 are met here: exactly one `free` per `new` (in `deinit`),
/// no overlapping calls (the `NSLock`), and nothing allocated on one side and freed on the other.
///
/// The clock crosses as a parameter, which keeps the window rules testable in Rust without
/// sleeping. It must be a CONTINUOUS clock and not a suspending one: the staleness guard exists for
/// the slept Mac, and `DispatchTime`/`SuspendingClock` stop while the machine is asleep, so an
/// overnight gap would read as seconds old, the guard would never fire, and the first reading after
/// wake would average a CPU percent across the sleep boundary instead of rebanking.
final class HostVitalsSampler: @unchecked Sendable {
    /// The production singleton (one machine → one baseline).
    static let shared = HostVitalsSampler()

    private let lock = NSLock()
    private let handle: OpaquePointer
    /// The zero the crossed nanosecond count is measured from. Only DIFFERENCES matter to the far
    /// side, so any fixed origin does; taking one at init keeps the number small.
    private let origin = ContinuousClock.now

    init() {
        // Rust returns null only if the allocation failed, and it aborts on allocation failure
        // before it could — so this is unreachable rather than unhandled.
        guard let handle = slopdesk_host_vitals_new() else {
            preconditionFailure("slopdesk_host_vitals_new returned null")
        }
        self.handle = handle
    }

    deinit {
        slopdesk_host_vitals_free(handle)
    }

    /// Reads the machine and folds one vitals answer. `nil` on a first call (baseline priming), on a
    /// refused syscall, or across a window the module's own rules will not average over — the verb
    /// replies `.error` and the client asks again on its next poll.
    func sample() -> MetadataCodec.HostVitals? {
        let home = Array(NSHomeDirectory().utf8)
        let elapsed = origin.duration(to: ContinuousClock.now)
        let now = UInt64(elapsed.components.seconds) * 1_000_000_000
            + UInt64(elapsed.components.attoseconds / 1_000_000_000)
        var out = SlopDeskHostVitals()
        lock.lock()
        let answered = home.withUnsafeBufferPointer { path in
            slopdesk_host_vitals_sample(handle, path.baseAddress, path.count, now, &out)
        }
        lock.unlock()
        guard answered else { return nil }
        return MetadataCodec.HostVitals(
            cpuPercent: out.cpu_percent,
            memoryPercent: out.memory_percent,
            pressureByte: out.pressure_byte,
            diskFreeMiB: out.disk_free_present ? out.disk_free_mib : nil,
        )
    }

    /// Drops the baseline + cache (test seam; production keeps one sampler for the process life).
    func reset() {
        lock.lock()
        slopdesk_host_vitals_reset(handle)
        lock.unlock()
    }
}

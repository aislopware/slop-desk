//! The host machine's PULSE — the `hostVitals` verb's engine (docs/45, wire verb 17).
//!
//! [`slopdesk_posix::hoststats`] reads the counters; this decides what they MEAN. The split is the
//! usual one: a syscall's safety obligation is local and lives where it can be discharged, and
//! "how old may a baseline be before averaging across it is a lie" is a product question that
//! belongs where a test can reach it.
//!
//! ## CPU is a DELTA, so the first answer is silence
//! Mach hands out cumulative tick counters, not a rate; a percent only exists between two
//! snapshots. The first fold therefore BANKS a baseline and returns `None` — the verb replies
//! `.error` and the client asks again on its next poll. Two further guards keep the number honest
//! rather than merely present:
//!
//! - **Stale baseline → discard.** A snapshot older than [`MAX_BASELINE_AGE_NANOS`] spans a gap the
//!   client spent disconnected or the machine spent asleep; averaging over it would describe a
//!   machine that no longer exists. Rebank, drop the cache, and stay silent for one poll.
//! - **Too-fresh baseline → repeat the last CPU percent.** Under [`MIN_WINDOW_NANOS`] the tick
//!   delta is mostly quantization noise, and the baseline does NOT move — otherwise two clients
//!   polling in lockstep would starve each other's window down to nothing. The memory and disk
//!   halves ARE instantaneous, so they refresh on top of the cached CPU number rather than handing
//!   back a wholly frozen row.
//!
//! ## Everything is integer arithmetic
//! The percent the client renders is exactly the percent the host computed — no float ever touches
//! it, so there is no rounding mode to disagree about across the wire, and no `a * b + c` for the
//! repo's bit-exactness rule to have an opinion on.
//!
//! ## No clock
//! [`Sampler::fold`] takes `now_nanos`. The whole state machine is therefore reproducible from a
//! transcript, which is the same bargain `slopdesk-agent` makes for detection.

use slopdesk_posix::hoststats::{self, CpuTicks};
use slopdesk_wire::metadata::codec::{DISK_FREE_UNKNOWN, HostVitals, MemoryPressure};

/// Older than this, a baseline describes a different situation. Comfortably above the client's ~4 s
/// poll, so a normal cadence never trips it.
pub const MAX_BASELINE_AGE_NANOS: u64 = 30_000_000_000;

/// Below this, the tick delta is noise: answer from the cache and keep the baseline.
pub const MIN_WINDOW_NANOS: u64 = 1_000_000_000;

/// The largest free-space figure that can be REPORTED, one below the wire's unreadable sentinel.
///
/// Saturating here rather than at the encoder is what keeps a colossal — or garbage — reading from
/// landing exactly ON [`DISK_FREE_UNKNOWN`] and blanking the metric on a machine that has plenty of
/// room.
pub const MAX_DISK_FREE_MIB: u32 = DISK_FREE_UNKNOWN - 1;

/// The busy percent between two tick snapshots: `100 - idle/total`, rounded half up, clamped
/// `0..=100`. `None` when the window carries no ticks at all — identical snapshots, nothing to
/// divide by.
///
/// Deltas use WRAPPING subtraction because `natural_t` is 32 bits and rolls over on a long-lived
/// host; a widened subtraction would report a nonsense spike for exactly one poll at the wrap.
#[must_use]
#[expect(
    clippy::integer_division,
    reason = "the truncation IS the rounding rule, stated one line above the division: a percent the client \
              renders must be the exact integer the host computed, and a float would introduce a rounding \
              mode the two sides could disagree about"
)]
#[expect(
    clippy::cast_possible_truncation,
    reason = "`percent` is clamped to 100 on the line that casts it, so the `u8` is proven"
)]
pub const fn busy_percent(previous: CpuTicks, current: CpuTicks) -> Option<u8> {
    let user = current.user.wrapping_sub(previous.user) as u64;
    let system = current.system.wrapping_sub(previous.system) as u64;
    let idle = current.idle.wrapping_sub(previous.idle) as u64;
    let nice = current.nice.wrapping_sub(previous.nice) as u64;
    let total = user + system + idle + nice;
    if total == 0 {
        return None;
    }
    let busy = total - idle;
    // Integer round-half-up: `(busy * 100 + total / 2) / total`.
    let percent = (busy * 100 + total / 2) / total;
    Some(if percent > 100 { 100 } else { percent as u8 })
}

/// Physical memory in use as a percent of installed RAM, rounded half up, clamped `0..=100`. `0`
/// when the machine reports no RAM — an impossible reading that must not divide by zero.
#[must_use]
#[expect(
    clippy::integer_division,
    clippy::cast_possible_truncation,
    reason = "same two obligations as `busy_percent`: the division IS the rounding rule, and the clamp to \
              100 sits on the line that casts"
)]
pub const fn memory_percent(used_bytes: u64, total_bytes: u64) -> u8 {
    if total_bytes == 0 {
        return 0;
    }
    let used = if used_bytes < total_bytes {
        used_bytes
    } else {
        total_bytes
    };
    let percent = (used * 100 + total_bytes / 2) / total_bytes;
    if percent > 100 { 100 } else { percent as u8 }
}

/// Free space in MiB from a `statfs` pair, saturating at [`MAX_DISK_FREE_MIB`]. `None` for a
/// nonsense block size, which would otherwise multiply out to a meaningless figure.
#[must_use]
#[expect(
    clippy::integer_division,
    reason = "bytes to MiB is a shift by twenty, written as the division that names the unit"
)]
#[expect(
    clippy::cast_possible_truncation,
    reason = "`capped` is clamped to `MAX_DISK_FREE_MIB`, itself a `u32`, on the line before"
)]
pub const fn free_mib(blocks_available: u64, block_size: u64) -> Option<u32> {
    if block_size == 0 {
        return None;
    }
    // Checked multiply: a torn or garbage `statfs` pair must saturate, not trap.
    let mib = match blocks_available.checked_mul(block_size) {
        Some(bytes) => bytes / (1024 * 1024),
        None => u64::MAX,
    };
    let capped = if mib > MAX_DISK_FREE_MIB as u64 {
        MAX_DISK_FREE_MIB as u64
    } else {
        mib
    };
    Some(capped as u32)
}

/// Maps the kernel's `kern.memorystatus_vm_pressure_level` — a SPARSE, bitmask-flavoured ladder
/// (1 normal, 2 warn, 4 critical) — onto the wire's level.
///
/// Anything else, including an unreadable sysctl and a future rung, reads
/// [`MemoryPressure::Normal`]: an alarm this build cannot justify is worse than no alarm.
#[must_use]
pub const fn pressure(sysctl_level: i32) -> MemoryPressure {
    match sysctl_level {
        2 => MemoryPressure::Warn,
        4 => MemoryPressure::Critical,
        _ => MemoryPressure::Normal,
    }
}

/// The CPU baseline and the last published reading — the only state a vitals answer needs.
///
/// One per machine, not one per pane: the metadata probe is rebuilt per request while the reading
/// is host-global, so the baseline has to outlive it. Holding it here rather than in a `static` is
/// what lets a test drive twenty polls in a row without a clock.
#[derive(Debug, Clone, Copy, Default)]
pub struct Sampler {
    baseline: Option<(CpuTicks, u64)>,
    cached: Option<HostVitals>,
}

impl Sampler {
    /// A sampler with no baseline — its first fold banks one and answers `None`.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            baseline: None,
            cached: None,
        }
    }

    /// Drops the baseline and the cache. A seam for tests and for a host that has just woken; a
    /// production sampler otherwise lives as long as the process.
    pub const fn reset(&mut self) {
        self.baseline = None;
        self.cached = None;
    }

    /// Folds one set of readings into a vitals answer under the rules the module doc states.
    /// `None` means there is nothing to publish yet.
    pub const fn fold(
        &mut self,
        ticks: CpuTicks,
        memory_percent: u8,
        pressure: MemoryPressure,
        disk_free_mib: Option<u32>,
        now_nanos: u64,
    ) -> Option<HostVitals> {
        let Some((previous_ticks, taken)) = self.baseline else {
            self.baseline = Some((ticks, now_nanos));
            return None;
        };
        // Saturating: a `now` that went backwards is a caller bug, and reading it as a zero-length
        // window (answer from the cache, keep the baseline) is the harmless response to one.
        let age = now_nanos.saturating_sub(taken);
        if age > MAX_BASELINE_AGE_NANOS {
            // The gap swallowed the window. Rebank, stay silent, and drop the stale cache so the
            // next answer is a fresh measurement rather than a number from before the gap.
            self.baseline = Some((ticks, now_nanos));
            self.cached = None;
            return None;
        }
        if age < MIN_WINDOW_NANOS {
            let Some(cached) = self.cached else {
                return None;
            };
            let refreshed = HostVitals {
                cpu_percent: cached.cpu_percent,
                memory_percent,
                pressure_byte: pressure.as_byte(),
                disk_free_mib,
            };
            self.cached = Some(refreshed);
            return Some(refreshed);
        }
        let Some(cpu_percent) = busy_percent(previous_ticks, ticks) else {
            // A window with zero ticks — a stopped clock, never seen in practice. Keep the baseline
            // so the NEXT poll measures across a LONGER window instead of resetting forever.
            return self.cached;
        };
        self.baseline = Some((ticks, now_nanos));
        let vitals = HostVitals {
            cpu_percent,
            memory_percent,
            pressure_byte: pressure.as_byte(),
            disk_free_mib,
        };
        self.cached = Some(vitals);
        Some(vitals)
    }

    /// Reads the machine and folds — the production entry point. `None` on a first call (baseline
    /// priming), a refused `HOST_CPU_LOAD_INFO`, or one of the silences above.
    ///
    /// `home` is the path whose VOLUME the free-space figure describes: on a modern Mac `/` is a
    /// read-only system snapshot whose free space is a different and useless number, while the Data
    /// volume is where repos, build products and container images actually go.
    pub fn sample(&mut self, home: &str, now_nanos: u64) -> Option<HostVitals> {
        let ticks = hoststats::cpu_ticks()?;
        self.fold(
            ticks,
            read_memory_percent(),
            pressure(hoststats::memory_pressure_level().unwrap_or(1)),
            read_disk_free_mib(home),
            now_nanos,
        )
    }
}

/// Physical memory in use, folded into the Activity Monitor "Memory Used" definition: wired +
/// app-internal (minus purgeable) + compressed, over installed RAM.
///
/// The file cache is deliberately EXCLUDED — macOS parks every otherwise-free page in it, so
/// counting it would pin the readout near 100% on a perfectly healthy machine and say nothing. `0`
/// on a refused syscall; the pressure level still carries the real signal.
#[must_use]
pub fn read_memory_percent() -> u8 {
    let Some(pages) = hoststats::vm_pages() else {
        return 0;
    };
    let Some(installed) = hoststats::physical_memory_bytes() else {
        return 0;
    };
    // Saturating: purgeable is a SUBSET of internal, but a torn read must not underflow.
    let app = pages.internal.saturating_sub(pages.purgeable);
    let used_pages = app.saturating_add(pages.wired).saturating_add(pages.compressed);
    memory_percent(used_pages.saturating_mul(pages.page_size), installed)
}

/// Free MiB on the volume holding `path`, or `None` when `statfs` refused — the client then simply
/// omits the metric.
#[must_use]
pub fn read_disk_free_mib(path: &str) -> Option<u32> {
    let space = hoststats::volume_space(path)?;
    free_mib(space.blocks_available, space.block_size)
}

#[cfg(test)]
#[expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
mod tests {
    use slopdesk_posix::hoststats::CpuTicks;
    use slopdesk_wire::metadata::codec::{DISK_FREE_UNKNOWN, MemoryPressure};

    use super::{
        MAX_BASELINE_AGE_NANOS, MAX_DISK_FREE_MIB, MIN_WINDOW_NANOS, Sampler, busy_percent, free_mib,
        memory_percent, pressure, read_disk_free_mib, read_memory_percent,
    };

    const fn ticks(user: u32, system: u32, idle: u32, nice: u32) -> CpuTicks {
        CpuTicks {
            user,
            system,
            idle,
            nice,
        }
    }

    #[test]
    fn busy_is_everything_that_was_not_idle() {
        let previous = ticks(100, 50, 850, 0);
        let current = ticks(130, 70, 1050, 0);
        // 30 user + 20 system + 200 idle = 250 total, 50 busy → 20%.
        assert_eq!(busy_percent(previous, current), Some(20));
    }

    #[test]
    fn busy_rounds_half_up_and_clamps_at_both_ends() {
        let base = ticks(0, 0, 0, 0);
        assert_eq!(
            busy_percent(base, ticks(1, 0, 999, 0)),
            Some(0),
            "0.1% rounds down"
        );
        assert_eq!(busy_percent(base, ticks(5, 0, 995, 0)), Some(1), "0.5% rounds up");
        assert_eq!(busy_percent(base, ticks(0, 0, 400, 0)), Some(0));
        assert_eq!(busy_percent(base, ticks(400, 0, 0, 0)), Some(100));
    }

    #[test]
    fn identical_snapshots_are_no_reading_at_all() {
        let same = ticks(9, 9, 9, 9);
        assert_eq!(busy_percent(same, same), None);
    }

    #[test]
    fn a_counter_that_wrapped_is_still_a_small_delta() {
        let previous = ticks(u32::MAX - 10, 0, u32::MAX - 30, 0);
        let current = ticks(9, 0, 9, 0);
        // 20 user + 40 idle = 60 total, 20 busy → 33.33 → 33.
        assert_eq!(
            busy_percent(previous, current),
            Some(33),
            "a wrap is a delta of twenty ticks, not of four billion"
        );
    }

    #[test]
    fn memory_rounds_half_up_and_never_divides_by_zero() {
        assert_eq!(memory_percent(32, 64), 50);
        assert_eq!(memory_percent(5, 8), 63, "62.5 rounds up");
        assert_eq!(memory_percent(99, 64), 100, "clamped, never over 100");
        assert_eq!(memory_percent(1, 0), 0, "no divide by a machine with no RAM");
    }

    #[test]
    fn free_space_saturates_below_the_unreadable_sentinel() {
        assert_eq!(free_mib(256, 4096), Some(1));
        assert_eq!(free_mib(62_914_560, 4096), Some(245_760));
        assert_eq!(free_mib(255, 4096), Some(0), "a full disk is 0, not unknown");
        assert_eq!(free_mib(100, 0), None, "no multiply by a zero block");
        let huge = free_mib(u64::MAX, 4096);
        assert_eq!(huge, Some(MAX_DISK_FREE_MIB));
        assert_ne!(
            huge,
            Some(DISK_FREE_UNKNOWN),
            "a colossal reading must never read as unreadable"
        );
    }

    #[test]
    fn the_pressure_ladder_is_sparse_and_unknown_rungs_are_quiet() {
        assert_eq!(pressure(1), MemoryPressure::Normal);
        assert_eq!(pressure(2), MemoryPressure::Warn);
        assert_eq!(pressure(4), MemoryPressure::Critical);
        assert_eq!(pressure(0), MemoryPressure::Normal);
        assert_eq!(pressure(3), MemoryPressure::Normal);
        assert_eq!(pressure(8), MemoryPressure::Normal);
        assert_eq!(pressure(-1), MemoryPressure::Normal);
    }

    fn fold_at(sampler: &mut Sampler, ticks: CpuTicks, now: u64) -> Option<u8> {
        sampler
            .fold(ticks, 40, MemoryPressure::Normal, Some(1), now)
            .map(|vitals| vitals.cpu_percent)
    }

    #[test]
    fn the_first_fold_banks_a_baseline_and_says_nothing() {
        let mut sampler = Sampler::new();
        assert_eq!(fold_at(&mut sampler, ticks(0, 0, 0, 0), 0), None);
        assert_eq!(
            fold_at(&mut sampler, ticks(50, 0, 50, 0), 2 * MIN_WINDOW_NANOS),
            Some(50),
            "the second fold has a window to measure across"
        );
    }

    #[test]
    fn a_gap_longer_than_the_max_age_rebanks_and_forgets() {
        let mut sampler = Sampler::new();
        assert_eq!(fold_at(&mut sampler, ticks(0, 0, 0, 0), 0), None);
        let measured = 2 * MIN_WINDOW_NANOS;
        assert_eq!(fold_at(&mut sampler, ticks(50, 0, 50, 0), measured), Some(50));
        let after_gap = measured + MAX_BASELINE_AGE_NANOS + 1;
        assert_eq!(
            fold_at(&mut sampler, ticks(60, 0, 9000, 0), after_gap),
            None,
            "the gap is not a window, and the cache from before it is not an answer"
        );
        assert_eq!(
            fold_at(
                &mut sampler,
                ticks(160, 0, 9100, 0),
                after_gap + 2 * MIN_WINDOW_NANOS
            ),
            Some(50),
            "and the next poll measures fresh"
        );
    }

    #[test]
    fn a_too_fresh_poll_repeats_the_cpu_and_refreshes_the_rest() {
        let mut sampler = Sampler::new();
        assert_eq!(fold_at(&mut sampler, ticks(0, 0, 0, 0), 0), None);
        let measured = 2 * MIN_WINDOW_NANOS;
        assert_eq!(fold_at(&mut sampler, ticks(50, 0, 50, 0), measured), Some(50));
        let refreshed = sampler
            .fold(
                ticks(9999, 0, 0, 0),
                77,
                MemoryPressure::Critical,
                None,
                measured + 1,
            )
            .expect("a cached CPU percent is still an answer");
        assert_eq!(refreshed.cpu_percent, 50, "the CPU number is the cached one");
        assert_eq!(
            refreshed.memory_percent, 77,
            "memory is instantaneous and refreshes"
        );
        assert_eq!(refreshed.memory_pressure(), MemoryPressure::Critical);
        assert_eq!(refreshed.disk_free_mib, None);
        assert_eq!(
            fold_at(
                &mut sampler,
                ticks(9999, 0, 9999, 0),
                measured + 2 * MIN_WINDOW_NANOS
            ),
            Some(50),
            "the baseline did NOT move, so this window is measured from the 50/50 snapshot"
        );
    }

    #[test]
    fn a_too_fresh_poll_before_any_reading_has_nothing_to_repeat() {
        let mut sampler = Sampler::new();
        assert_eq!(fold_at(&mut sampler, ticks(0, 0, 0, 0), 0), None);
        assert_eq!(fold_at(&mut sampler, ticks(1, 0, 1, 0), 1), None, "no cache yet");
    }

    #[test]
    fn a_stopped_clock_keeps_the_baseline_and_repeats_the_last_answer() {
        let mut sampler = Sampler::new();
        let same = ticks(7, 7, 7, 7);
        assert_eq!(fold_at(&mut sampler, same, 0), None);
        let measured = 2 * MIN_WINDOW_NANOS;
        assert_eq!(fold_at(&mut sampler, ticks(57, 7, 57, 7), measured), Some(50));
        assert_eq!(
            fold_at(&mut sampler, ticks(57, 7, 57, 7), measured + 2 * MIN_WINDOW_NANOS),
            Some(50),
            "no ticks passed, so the previous answer stands"
        );
    }

    #[test]
    fn a_reset_sampler_primes_again() {
        let mut sampler = Sampler::new();
        assert_eq!(fold_at(&mut sampler, ticks(0, 0, 0, 0), 0), None);
        assert_eq!(
            fold_at(&mut sampler, ticks(50, 0, 50, 0), 2 * MIN_WINDOW_NANOS),
            Some(50)
        );
        sampler.reset();
        assert_eq!(
            fold_at(&mut sampler, ticks(99, 0, 99, 0), 10 * MIN_WINDOW_NANOS),
            None
        );
    }

    #[test]
    fn the_real_readings_are_in_range_and_the_first_poll_is_silent() {
        assert!(
            read_memory_percent() > 0,
            "the process running this test is itself using memory"
        );
        assert!(read_memory_percent() <= 100);
        assert!(read_disk_free_mib("/").is_some(), "the boot volume is mounted");
        assert_eq!(read_disk_free_mib("/no/such/volume"), None);

        let mut sampler = Sampler::new();
        assert!(
            sampler.sample("/", 0).is_none(),
            "the first poll banks a baseline"
        );
        // NOT "and the second poll answers". `now_nanos` is the caller's clock and the tick
        // counters are the machine's; two calls a microsecond apart advance no ticks however far
        // the argument jumps, so a real second poll here lands on the stopped-clock branch. What
        // that branch does is pinned by `a_stopped_clock_keeps_the_baseline_and_repeats_the_last_answer`
        // over injected snapshots, which is where a rule about time belongs.
        assert!(
            sampler.sample("/", 2 * MIN_WINDOW_NANOS).is_none(),
            "no ticks have passed, so there is still nothing to publish"
        );
    }
}

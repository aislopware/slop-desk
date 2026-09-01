//! The machine's own counters — Mach host statistics, the kernel's pressure level, and a `statfs`.
//!
//! Four readings, each a syscall `std` and `nix` have no wrapper for, each returning plain numbers.
//! Nothing here decides anything: what a percent MEANS, what a stale baseline is worth, and which
//! pressure level is an alarm are all questions about a product, and by this crate's admission test
//! they belong to the caller. `slopdesk_probe::vitals` is that caller.
//!
//! Every function is total: a refused call is `None`, never a panic and never a partly-read struct.

#![cfg(target_os = "macos")]

use core::mem;

/// Mach's four aggregate CPU tick counters, all cores summed, as `HOST_CPU_LOAD_INFO` reports them.
///
/// `u32` because that is what `natural_t` is, and they DO wrap on a long-lived host. Keeping the
/// native width here rather than widening on the way out is deliberate: the wrap is a fact about
/// the counter, and a caller that widened before subtracting would report a nonsense spike for one
/// poll every time the machine crossed it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CpuTicks {
    /// Ticks spent in user mode.
    pub user: u32,
    /// Ticks spent in the kernel.
    pub system: u32,
    /// Ticks spent idle.
    pub idle: u32,
    /// Ticks spent at reduced priority.
    pub nice: u32,
}

/// The physical-memory page counts one `HOST_VM_INFO64` reading carries, and the page size they are
/// counted in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct VmPages {
    /// Pages wired down by the kernel.
    pub wired: u64,
    /// Pages an application owns, purgeable ones included.
    pub internal: u64,
    /// The purgeable SUBSET of `internal`.
    pub purgeable: u64,
    /// Pages held by the memory compressor.
    pub compressed: u64,
    /// Bytes per page — `sysconf(_SC_PAGESIZE)`, which on Darwin is the host page size the counts
    /// above are expressed in.
    pub page_size: u64,
}

/// Blocks free to a non-root process on one volume, and the block size.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct VolumeSpace {
    /// `f_bavail` — free to a NON-root process, which is what a daemon can actually use.
    pub blocks_available: u64,
    /// `f_bsize`.
    pub block_size: u64,
}

/// How many `integer_t` words of a `HOST_VM_INFO64` fill [`vm_pages`] actually needs.
///
/// NOT `HOST_VM_INFO64_COUNT`. That constant is `size_of::<vm_statistics64>() / 4` for libc's
/// struct, which carries every field the flavour has EVER had; a running kernel fills only the
/// revision it knows — 62 words of libc's 104 on macOS 15. Demanding the whole struct would make
/// the reading `None` forever on a perfectly healthy machine, which is the same shape of bug
/// [`crate::dynsym`]'s doc describes. What the four fields read actually need is that the fill
/// reached the LAST of them, and `offset_of!` states that without anyone maintaining a number.
const VM_NEEDED_WORDS: usize = {
    let bytes = mem::offset_of!(libc::vm_statistics64, internal_page_count) + size_of::<libc::natural_t>();
    // Round up: a partial trailing word is not a field the kernel wrote.
    bytes.div_ceil(size_of::<libc::integer_t>())
};

/// The process's one Mach host port.
///
/// `mach_host_self` mints a fresh send right per call, so taking one and keeping it is the
/// difference between a port leak per poll and none. The value is a plain integer name, so a
/// `OnceLock` over it is sound and needs no destructor: the right lives as long as the process,
/// which is exactly how long this crate intends to hold it.
///
/// It stays a `OnceLock` and NOT a `LazyLock` — tried 2026-09-02, reverted. The two `#[expect]`s
/// below sit on the `get_or_init` STATEMENT, and a `LazyLock` moves the call into the static's
/// initialiser, where a statement attribute cannot reach it: the `unsafe` lands outside the
/// exemption and both expectations read as unfulfilled.
fn host_port() -> libc::mach_port_t {
    use std::sync::OnceLock;
    static PORT: OnceLock<libc::mach_port_t> = OnceLock::new();
    #[expect(
        unsafe_code,
        reason = "`mach_host_self` has no wrapper in std or nix; it takes no arguments and cannot fail"
    )]
    #[expect(
        deprecated,
        reason = "libc points the whole mach surface at the `mach2` crate, but the two other calls here — \
                  `host_statistics` and `host_statistics64` — are NOT deprecated and take libc's own struct \
                  layouts. Taking `mach_host_self` from a second bindings crate would mean two definitions \
                  of `mach_port_t` and two of every flavour constant, which is a worse hazard than one \
                  deprecated symbol that still resolves to the same `libSystem` export it always did."
    )]
    // SAFETY: no arguments, no pointers. The call returns a send right this process then owns for
    // its lifetime; leaking exactly one is the intent.
    *PORT.get_or_init(|| unsafe { libc::mach_host_self() })
}

/// `host_statistics(HOST_CPU_LOAD_INFO)` — the four aggregate tick counters.
///
/// `None` on any non-`KERN_SUCCESS`, or on a kernel that filled fewer words than the flavour
/// declares: a partly-filled struct is a reading nobody can interpret, not a small error.
#[must_use]
#[expect(
    unsafe_code,
    reason = "`host_statistics` has no wrapper in std or nix, and its out-parameter is a raw `integer_t` \
              array whose length it also writes"
)]
pub fn cpu_ticks() -> Option<CpuTicks> {
    // SAFETY: `host_cpu_load_info` is an array of `natural_t` and nothing else, so all-zero is a
    // valid inhabitant — the kernel overwrites it whole a line later, and zeroing rather than
    // leaving it uninitialised is what makes the short-fill branch below readable rather than UB.
    let mut info: libc::host_cpu_load_info = unsafe { mem::zeroed() };
    let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
    // SAFETY: `info` is one live, fully-initialised `host_cpu_load_info` owned by this frame, and
    // `HOST_CPU_LOAD_INFO_COUNT` is the flavour's own word count for exactly that struct, so the
    // kernel writes at most `size_of::<host_cpu_load_info>()` bytes into it. `count` is a live
    // `mach_msg_type_number_t` the call may overwrite with what it actually wrote. Neither pointer
    // outlives the call.
    let result = unsafe {
        libc::host_statistics(
            host_port(),
            libc::HOST_CPU_LOAD_INFO,
            std::ptr::from_mut(&mut info).cast::<libc::integer_t>(),
            &raw mut count,
        )
    };
    if result != 0 || count < libc::HOST_CPU_LOAD_INFO_COUNT {
        return None;
    }
    Some(CpuTicks {
        user: *info.cpu_ticks.first()?,
        system: *info.cpu_ticks.get(1)?,
        idle: *info.cpu_ticks.get(2)?,
        nice: *info.cpu_ticks.get(3)?,
    })
}

/// `host_statistics64(HOST_VM_INFO64)` plus the page size, as the counts a memory percent is
/// computed from. `None` on any non-`KERN_SUCCESS`, a short fill, or a nonsense page size.
#[must_use]
#[expect(
    unsafe_code,
    reason = "`host_statistics64` has no wrapper in std or nix, and its out-parameter is a raw `integer_t` \
              array whose length it also writes"
)]
pub fn vm_pages() -> Option<VmPages> {
    // SAFETY: `vm_statistics64` is `natural_t`/`u64` counters and nothing else, so all-zero is a
    // valid inhabitant, for the reason `cpu_ticks` states.
    let mut info: libc::vm_statistics64 = unsafe { mem::zeroed() };
    let mut count = libc::HOST_VM_INFO64_COUNT;
    // SAFETY: identical obligation to `cpu_ticks`, for this flavour's own struct and word count:
    // `info` is one live, fully-initialised `vm_statistics64` this frame owns, `count` is a live
    // cell the call may rewrite, and neither pointer outlives the call.
    let result = unsafe {
        libc::host_statistics64(
            host_port(),
            libc::HOST_VM_INFO64,
            std::ptr::from_mut(&mut info).cast::<libc::integer_t>(),
            &raw mut count,
        )
    };
    if result != 0 || usize::try_from(count).unwrap_or(0) < VM_NEEDED_WORDS {
        return None;
    }
    // `sysconf(_SC_PAGESIZE)` rather than the `vm_kernel_page_size` global: it is a function call
    // with no aliasing question, and on Darwin it reports the same host page size the counters
    // above are expressed in.
    #[expect(
        unsafe_code,
        reason = "`sysconf` takes no pointer and has no wrapper in std for this name"
    )]
    // SAFETY: an integer in, an integer out, no pointers at all.
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    let page_size = u64::try_from(page_size).ok().filter(|size| *size > 0)?;
    Some(VmPages {
        wired: u64::from(info.wire_count),
        internal: u64::from(info.internal_page_count),
        purgeable: u64::from(info.purgeable_count),
        compressed: u64::from(info.compressor_page_count),
        page_size,
    })
}

/// The machine's installed RAM in bytes — `sysctl hw.memsize`. `None` when the name is unreadable
/// or answers in an unexpected width.
#[must_use]
pub fn physical_memory_bytes() -> Option<u64> {
    sysctl_scalar::<u64>("hw.memsize\0")
}

/// `kern.memorystatus_vm_pressure_level` — the kernel's own verdict, RAW. A SPARSE ladder
/// (1 normal, 2 warn, 4 critical) whose meaning is the caller's to assign. `None` when unreadable.
#[must_use]
pub fn memory_pressure_level() -> Option<i32> {
    sysctl_scalar::<i32>("kern.memorystatus_vm_pressure_level\0")
}

/// The CPU's marketing name — `sysctl machdep.cpu.brand_string`, e.g. `Apple M2 Max`.
///
/// `None` when the name is unreadable or answers something that is not UTF-8. Every caller here
/// treats that as the permissive fallback rather than as a failure: the string is used to place a
/// chip on a ladder of framebuffer limits, and refusing to act because a `sysctl` did not answer
/// would be a worse trade than acting on the ladder's most generous rung.
///
/// Two calls rather than one guess at a length: the first asks how many bytes the kernel will
/// write, the second lends exactly that many.
#[must_use]
#[expect(
    unsafe_code,
    reason = "`sysctlbyname` has no wrapper in std or nix for a variable-length read by name"
)]
pub fn cpu_brand() -> Option<String> {
    const NAME: &str = "machdep.cpu.brand_string\0";
    let mut size: usize = 0;
    // SAFETY: `NAME` is a NUL-terminated Rust literal, so its pointer is a valid C string. The
    // output pointer is NULL, which is how this call is asked for the LENGTH alone and is the one
    // case where it writes nothing through it; `size` names a live local that outlives the call.
    let sized = unsafe {
        libc::sysctlbyname(
            NAME.as_ptr().cast::<libc::c_char>(),
            std::ptr::null_mut(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if sized != 0 || size == 0 {
        return None;
    }
    let mut buffer = vec![0u8; size];
    // SAFETY: same C string. `buffer` is `size` initialised bytes this frame owns, and `size` is
    // what the call reads before writing — so it cannot write past the allocation. Neither cell
    // escapes, and the bytes are read afterwards only by safe code.
    let read = unsafe {
        libc::sysctlbyname(
            NAME.as_ptr().cast::<libc::c_char>(),
            buffer.as_mut_ptr().cast::<libc::c_void>(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 {
        return None;
    }
    // The kernel writes a C string into the buffer it sized, so the trailing NUL is inside it.
    buffer.truncate(size);
    let text = buffer
        .split(|byte| *byte == 0)
        .next()
        .and_then(|bytes| std::str::from_utf8(bytes).ok())?;
    Some(text.to_owned())
}

/// One `sysctlbyname` reading a scalar of exactly `T`'s width.
///
/// `name` must end in a NUL — every caller in this module is a literal that does, and taking the
/// bytes rather than a `CStr` keeps the call sites readable without an allocation per poll.
#[expect(
    unsafe_code,
    reason = "`sysctlbyname` has no wrapper in std or nix for a scalar read by name"
)]
fn sysctl_scalar<T: Copy + Default>(name: &str) -> Option<T> {
    let mut value = T::default();
    let mut size = size_of::<T>();
    // SAFETY: `name` is a NUL-terminated Rust literal, so its pointer is a valid C string for the
    // call. `value` is one live `T` this frame owns and `size` says so, which is the contract
    // `sysctlbyname` reads before writing; both cells are live for the call and neither escapes.
    // The new-value pair is null/0, which is how the call is told this is a READ.
    let result = unsafe {
        libc::sysctlbyname(
            name.as_ptr().cast::<libc::c_char>(),
            std::ptr::from_mut(&mut value).cast::<libc::c_void>(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    (result == 0 && size == size_of::<T>()).then_some(value)
}

/// `statfs` on the volume holding `path`. `None` on a refused call.
///
/// The caller passes `$HOME`, not `/`: on a modern Mac `/` is a read-only system snapshot whose
/// free space is a different and useless number, while the Data volume is where repos, build
/// products and container images actually go.
#[must_use]
#[expect(
    unsafe_code,
    reason = "`statfs` on Darwin has no wrapper in nix that reports `f_bavail` for a path"
)]
pub fn volume_space(path: &str) -> Option<VolumeSpace> {
    let cpath = std::ffi::CString::new(path).ok()?;
    let mut stats = mem::MaybeUninit::<libc::statfs>::uninit();
    // SAFETY: `cpath` is a NUL-terminated C string live for the call, and `stats` is one live,
    // correctly-aligned `statfs` allocation this frame owns. On a 0 return the kernel has
    // initialised the whole struct, which is the only path that reads it.
    let result = unsafe { libc::statfs(cpath.as_ptr(), stats.as_mut_ptr()) };
    if result != 0 {
        return None;
    }
    // SAFETY: `statfs` returned 0, so the struct is fully initialised.
    let stats = unsafe { stats.assume_init() };
    Some(VolumeSpace {
        blocks_available: stats.f_bavail,
        block_size: u64::from(stats.f_bsize),
    })
}

#[cfg(test)]
#[expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
mod tests {
    use super::{cpu_ticks, memory_pressure_level, physical_memory_bytes, vm_pages, volume_space};

    #[test]
    fn the_cpu_counters_read_and_advance() {
        let first = cpu_ticks().expect("HOST_CPU_LOAD_INFO is readable on any Mac");
        let total =
            u64::from(first.user) + u64::from(first.system) + u64::from(first.idle) + u64::from(first.nice);
        assert!(total > 0, "a running machine has spent ticks somewhere");
    }

    #[test]
    fn the_port_is_taken_once_and_reused() {
        // Not a leak test — it is the observable consequence of one: a thousand reads through the
        // cached right keep working, where a thousand fresh `mach_host_self` rights would exhaust
        // the port table on a constrained host.
        for _ in 0..1000 {
            assert!(cpu_ticks().is_some());
        }
    }

    #[test]
    fn the_memory_counters_are_internally_consistent() {
        let pages = vm_pages().expect("HOST_VM_INFO64 is readable on any Mac");
        assert!(pages.page_size >= 4096, "a Darwin page is at least 4 KiB");
        assert!(
            pages.purgeable <= pages.internal,
            "purgeable pages are a subset of internal ones"
        );
        let installed = physical_memory_bytes().expect("hw.memsize is readable on any Mac");
        let used = (pages.wired + pages.internal + pages.compressed) * pages.page_size;
        assert!(
            used <= installed * 2,
            "used memory is the same order as installed"
        );
    }

    #[test]
    fn the_pressure_level_is_one_of_the_kernels_own() {
        let level = memory_pressure_level().expect("the sysctl exists on any Mac");
        assert!(
            matches!(level, 1 | 2 | 4),
            "the ladder is sparse and these are its rungs, got {level}"
        );
    }

    #[test]
    fn a_real_volume_answers_and_a_nonexistent_one_does_not() {
        let space = volume_space("/").expect("the boot volume is always mounted");
        assert!(space.block_size > 0);
        assert!(volume_space("/no/such/volume/anywhere").is_none());
        assert!(volume_space("has\0an interior nul").is_none());
    }
}

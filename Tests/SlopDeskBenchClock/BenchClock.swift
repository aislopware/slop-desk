import Foundation

/// The clock the ceiling benches measure with.
///
/// Every bench in the tree asserts the same kind of thing — "this has not regressed by an order of
/// magnitude" — and every one of them used to measure it with `DispatchTime`, which is WALL CLOCK.
/// `just quick` runs thousands of tests across every core at once, so a timed loop that loses its
/// slice to another target reads as a tenfold regression, fails, and costs a full re-run of the
/// suite to disprove. That happened four times in one sitting.
///
/// `CLOCK_THREAD_CPUTIME_ID` counts only the cycles this thread was actually given, so a bench
/// sharing the machine measures the same number it measures alone. Contention stops being noise in
/// the answer and becomes what it is: time the thread was not running.
///
/// The best of three passes on top of that is for the effects CPU time still sees — a page fault, a
/// GC-shaped allocator pause, a migration between cores with cold caches. Three passes over the same
/// total iteration count cost nothing extra, and the fastest is the honest estimate of what the work
/// costs when nothing is in its way.
///
/// One implementation, in one place, because four copies of a timing rule drift into four ceilings
/// that mean four different things.
public enum BenchClock {
    /// How many passes the total iteration count is split into.
    private static let passes = 3

    /// Iterations of warm-up (codegen, allocator caches) before the timed passes, capped so a short
    /// bench does not spend its whole budget warming.
    private static let maxWarmup = 1000

    /// Nanoseconds of THREAD CPU time per iteration, as the best of ``passes``.
    public static func nsPerOp(_ iterations: Int, _ block: () -> Void) -> Double {
        for _ in 0..<min(iterations, maxWarmup) { block() }
        let per = max(iterations / passes, 1)
        var best = Double.infinity
        for _ in 0..<passes {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            for _ in 0..<per { block() }
            let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            best = Double.minimum(best, Double(end - start) / Double(per))
        }
        return best
    }

    /// Microseconds of THREAD CPU time per iteration, as the best of ``passes``.
    public static func usPerOp(_ iterations: Int, _ block: () -> Void) -> Double {
        nsPerOp(iterations, block) / 1000.0
    }
}

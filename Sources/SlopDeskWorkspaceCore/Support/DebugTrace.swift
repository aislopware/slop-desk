import Foundation

/// One opt-in stderr trail, gated by one `SLOPDESK_*_DEBUG` variable.
///
/// The idiom was written out at each of its sites — the block choreography, the prompt-jump flash,
/// the workspace-intent refusals — as the same three lines: read the environment, compare to `"1"`,
/// write a `\n`-terminated line to `FileHandle.standardError`. They differed in nothing but the tag,
/// and they differed in one thing that matters: two of them read the environment on EVERY call. That
/// is a syscall per gesture on a path that runs per gesture, which is exactly why the third one had
/// already hoisted the read into a `static let`. Resolving it once here settles that for all of them
/// — an environment variable cannot change under a running process, so there is nothing to re-read.
///
/// stderr rather than `OSLog` on purpose, and both are in use side by side: `Logger` is the durable
/// signposted record, this is the one a developer running the app from a terminal can actually SEE
/// (an `OSLog` `.debug` line is not persisted, and reaching it means Console.app and a filter).
///
/// It lives here rather than a level lower because its two homes are the workspace store and the
/// client's views, and ClientUI already depends on this target. The VIDEO host's `SLOPDESK_AUDIO_DEBUG`
/// / `SLOPDESK_VIDEO_DEBUG` tracers are deliberately NOT folded in: `SlopDeskVideoHost` depends on
/// neither this target nor anything that could carry this down to it, and inventing a shared leaf to
/// hold six lines would cost more than it saves.
public struct DebugTrace: Sendable {
    /// `SLOPDESK_BLOCKS_DEBUG` — the jump choreography end to end: issue → arm → scrollbar echo →
    /// settle → paint. One flag, both ends, which is the point of it being one flag.
    public static let blocks = Self("SLOPDESK_BLOCKS_DEBUG")

    /// `SLOPDESK_WORKSPACE_DEBUG` — why a workspace intent was dropped. Loud by design: a mutator
    /// that compiles, runs, changes nothing and logs nothing is indistinguishable from a UI that
    /// ignored the gesture, and there is no string to grep for.
    public static let workspace = Self("SLOPDESK_WORKSPACE_DEBUG")

    /// Whether the gate was set to `"1"` when this trace was first resolved.
    public let isOn: Bool

    /// Resolves `gate` once. Prefer one of the shared `static let`s — a fresh instance per call site
    /// would re-read the environment, which is the cost this type exists to remove.
    public init(_ gate: String) {
        isOn = ProcessInfo.processInfo.environment[gate] == "1"
    }

    /// Writes one line to stderr when the gate is on, and does nothing at all when it is not.
    ///
    /// `@autoclosure` so an interpolated message costs nothing in production: the string is not built
    /// unless the gate is open.
    public func write(_ line: @autoclosure () -> String) {
        guard isOn else { return }
        FileHandle.standardError.write(Data((line() + "\n").utf8))
    }

    /// ``write(_:)`` with a `[tag]` prefix, for a gate that carries more than one voice — one flag
    /// turns the whole choreography on, and the tag says which end printed.
    public func write(_ tag: String, _ message: @autoclosure () -> String) {
        write("[\(tag)] \(message())")
    }
}

import Foundation

/// The encoder every JSON sidecar this target writes is built from.
///
/// Four stores spelled it out — the workspace file, the device preferences, the workspace cache, the
/// folder frecency — and each one carried its own half of the reason in a comment. Both halves are
/// load-bearing and neither is obvious from the line:
///
/// - **`.sortedKeys` is a CONTRACT, not tidiness.** `docs/22` §8's round-trip tests compare BYTES.
///   Swift's default dictionary/`CodingKeys` order is not stable across runs, so an encoder that
///   omits this turns a passing test into one that fails on a Tuesday.
/// - **`.prettyPrinted` is for the human.** These files are hand-inspected when a workspace comes
///   back wrong, and `git diff` on a one-line JSON blob says only that the line changed.
///
/// A fifth store that copied three lines and dropped `.sortedKeys` would still write a perfectly
/// good file — and would only be found by whichever round-trip test happened to be watching.
///
/// It stays inside this target rather than moving to a leaf below it. Three other targets write
/// sidecars of their own (`HostLaunchRecord`, `WindowParkingSidecar`, `EnvBridge`), but they hold
/// ONE encoder each, so there is nothing duplicated to remove — only a dependency edge to add, in
/// three graphs whose narrowness is deliberate. `check-supervisor` pins the rule for all of them
/// instead: whoever writes a sidecar sorts its keys.
///
/// `WorkspaceStateFile` was a fourth until its rule moved to `rust/slopdesk-wire`. It holds no
/// encoder at all now — the file's bytes come back through `slopdesk_ws_state_file_encode`, and the
/// sorted keys are a property of the `BTreeMap` the crate writes from rather than a flag anyone
/// passes.
enum SidecarJSON {
    /// A `JSONEncoder` for an on-disk sidecar: sorted keys, pretty-printed.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

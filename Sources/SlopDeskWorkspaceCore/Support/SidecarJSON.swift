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
/// three graphs whose narrowness is deliberate. `slopdesk-invariants` pins the rule for all of them
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

    /// `<Application Support>/SlopDesk/<name>` — where a sidecar this target owns lives.
    ///
    /// The SAME four stores that spelled the encoder out spelled this out too, in four
    /// byte-identical eight-line bodies differing only in the filename. Both halves of the reason
    /// are the same as the encoder's, and neither is obvious from the line:
    ///
    /// - **The container name is `slopdesk-hostlaunch`'s `CONTAINER_NAME`.** A fifth store that
    ///   typed a different string would still write a perfectly good file, into a directory the
    ///   daemons do not read.
    /// - **The temp-directory fallback is not a fallback to nothing.** Application Support fails to
    ///   resolve only in sandboxed edge cases, and every file this answers for is re-creatable — a
    ///   fresh workspace, a fresh preference set, a re-learned frecency — so a throwaway location
    ///   beats a `nil` every caller would have to branch on.
    ///
    /// `SLOPDESK_APP_SUPPORT_DIR` is deliberately NOT read here, unlike
    /// ``EnvBridge/defaultSidecarURL(fileManager:)`` one target over. That variable exists so an
    /// automation run cannot inherit the developer's state, and this target answers the same
    /// question a different way: `ClientComposition` hands every one of these stores a `nil` handle
    /// under automation, so there is nothing to redirect. Reading it here would give the client a
    /// second, quieter redirect on top of the one that already works.
    static func appSupportURL(named name: String, using fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("SlopDesk", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}

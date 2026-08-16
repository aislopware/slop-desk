import Foundation

/// Where this tree's OWN Rust service binaries live — `slopdesk-screend`, `slopdesk-dropd`,
/// `slopdesk-androidd`, `slopdesk-inspectord`.
///
/// ## Why they are not found the way `code-server` is
/// `HostServiceProcess.locate` searches the vendored prefix, then `PATH`, then Homebrew, because a
/// panel backend is somebody else's program that the operator may reasonably have installed. These
/// are OURS: they ship with this checkout, they speak a wire pinned to it, and a same-named binary
/// on a `PATH` should never become one. So the search is the installed copy and the build tree, and
/// nothing else.
///
/// The build-tree half is a WALK rather than a fixed depth, and that is the one detail worth
/// stating: SwiftPM's `.build/debug` is a symlink to `.build/<triple>/debug`, so a binary found next
/// to the test bundle sits one level deeper than `swift run`'s. A fixed count silently resolves to
/// nothing for one of them, and "no binary" is a passthrough or an unavailable service that no
/// assertion notices.
public enum RustServicePaths {
    /// Levels walked up from the running executable before giving up. A build tree is a handful of
    /// levels deep, and an unbounded walk from an executable somewhere else entirely would stat its
    /// way to `/` for nothing.
    private static let walkLimit = 6

    /// The installed copy of `name`, out of the build tree so a `cargo clean` cannot strand a
    /// running host.
    public static func installed(_ name: String, home: String) -> String {
        home + "/Library/Application Support/SlopDesk/bin/" + name
    }

    /// Locates `name`: the override variable, then the installed copy, then the crate's cargo target
    /// directories found by walking up from `executable`. `nil` when this machine has none.
    public static func locate(
        _ name: String,
        crate: String,
        overrideVariable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        executable: URL? = Bundle.main.executableURL,
    ) -> String? {
        if let override = environment[overrideVariable], !override.isEmpty { return override }
        if let home = environment["HOME"] {
            let candidate = installed(name, home: home)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        guard var directory = executable?.deletingLastPathComponent() else { return nil }
        for _ in 0..<walkLimit {
            for profile in ["release", "debug"] {
                let candidate = directory
                    .appendingPathComponent("rust/\(crate)/target/\(profile)/\(name)").path
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// Locates a ROOT-workspace binary: the override variable, then the directory the running
    /// executable is in. `nil` when neither answers.
    ///
    /// Separate from ``locate(_:crate:overrideVariable:environment:fileManager:executable:)`` because
    /// a root-workspace crate's cargo target directory is `rust/target/`, not the per-crate one that
    /// walk searches — there is nothing for it to find. `make build` stages these beside hostd, so a
    /// dev run and an installed bundle resolve the same way.
    ///
    /// No `isExecutableFile` check, deliberately, and this is the difference the two callers agreed
    /// on: the path is handed to a spawn that will fail with its own message either way, and probing
    /// first would answer `nil` for a binary that exists but is momentarily being replaced by a
    /// build. It was `slopdesk-probe`'s and `slopdesk-agenthooks`'s, spelled twice.
    public static func locateBeside(
        _ name: String,
        overrideVariable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
    ) -> String? {
        if let override = environment[overrideVariable], !override.isEmpty { return override }
        return executableURL?.deletingLastPathComponent().appendingPathComponent(name).path
    }
}

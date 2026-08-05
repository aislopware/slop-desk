// WebBrowserToolchain — where the host's Chrome lives, and which Chromes count.
//
// Unlike `code-server` and `baguette`, a browser is not a `PATH` binary on macOS: it is an app
// bundle, and the executable inside it is what accepts `--remote-debugging-port`. So this locator
// walks bundle paths first and only then falls back to `PATH` names (a Linux-shaped install, or a
// developer who symlinked one).
//
// Any Blink browser serves the SAME DevTools frontend from its debugging port, so the fallbacks are
// real fallbacks rather than a wish-list — the panel works identically against Chromium, Brave or
// Edge. Chrome leads because it is the browser the pages under test are written for.

import Foundation

/// Locates the Chrome-family executable the Web panel drives.
enum WebBrowserToolchain {
    /// Names an executable explicitly; SET-but-not-executable resolves to `nil` rather than falling
    /// through to the search (``HostServiceProcess/locate(_:overrideVariable:environment:fileManager:)``'s
    /// rule — an operator who named a binary meant that one).
    static let overrideVariable = "SLOPDESK_WEB_BROWSER_BIN"

    /// App-bundle executables, most-preferred first. Each is tried under `/Applications` and then
    /// under the user's own `~/Applications` (where a per-user install lands).
    static let bundleExecutables = [
        "Google Chrome.app/Contents/MacOS/Google Chrome",
        "Chromium.app/Contents/MacOS/Chromium",
        "Brave Browser.app/Contents/MacOS/Brave Browser",
        "Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
    ]

    /// `PATH` names, tried after the bundles.
    static let pathExecutables = ["google-chrome", "chromium", "chrome"]

    /// The browser to drive, or `nil` when the host has none (→ `.unavailable`, and the panel shows
    /// its install hint instead of failing).
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
    ) -> String? {
        if let override = environment[overrideVariable], !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        var pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        pathDirectories.append(contentsOf: HostServiceProcess.homebrewBinDirectories)
        return resolve(
            applicationDirectories: applicationDirectories(environment: environment),
            pathDirectories: pathDirectories, fileManager: fileManager,
        )
    }

    /// The search itself, over directories the caller names — bundles first, then `PATH`. Split out
    /// so a test can point it at a temp tree instead of at whatever browsers this machine happens to
    /// have installed.
    static func resolve(
        applicationDirectories: [String], pathDirectories: [String], fileManager: FileManager = .default,
    ) -> String? {
        for directory in applicationDirectories {
            for executable in bundleExecutables {
                let candidate = directory + "/" + executable
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for directory in pathDirectories {
            for name in pathExecutables {
                let candidate = directory + "/" + name
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// The bundle version of the located executable, e.g. `151.0.7922.76`.
    ///
    /// Read from the app bundle's own `Info.plist` rather than by running the binary with
    /// `--version`: the launch path must not wait on a second browser process, and the plist is a
    /// file read that cannot hang. `nil` for a `PATH`-installed binary, which has no bundle — see
    /// ``WebBrowserManager/launchArguments(profileDirectory:browserVersion:)`` for what is given up
    /// in that case.
    static func version(ofExecutable binary: String, fileManager: FileManager = .default) -> String? {
        guard let plist = infoPlistPath(forExecutable: binary),
              let data = fileManager.contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let entries = object as? [String: Any],
              let version = entries["CFBundleShortVersionString"] as? String, !version.isEmpty
        else { return nil }
        return version
    }

    /// `<…>.app/Contents/MacOS/<executable>` → `<…>.app/Contents/Info.plist`. Pure; `nil` for any
    /// path that is not shaped like a bundle executable.
    static func infoPlistPath(forExecutable binary: String) -> String? {
        var components = binary.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3, components.removeLast().isEmpty == false,
              components.removeLast() == "MacOS", components.last == "Contents"
        else { return nil }
        return components.joined(separator: "/") + "/Info.plist"
    }

    /// `/Applications` plus the user's own. The user's comes from `$HOME` IN THE ENVIRONMENT, never
    /// `NSHomeDirectory()`/`homeDirectoryForCurrentUser` — ``CodeServerManager``'s rule: both of
    /// those resolve through directory services and are blind to a `HOME` an operator overrode.
    static func applicationDirectories(environment: [String: String]) -> [String] {
        var directories = ["/Applications"]
        if let home = environment["HOME"], home.hasPrefix("/") {
            directories.append(home + "/Applications")
        }
        return directories
    }
}

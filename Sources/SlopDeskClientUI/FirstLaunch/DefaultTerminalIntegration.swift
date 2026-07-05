// E20 WI-9 (ES-E20-4) — the macOS "Set as Default Terminal" integration (LOCAL OS handler only).
//
// First-launch step 2 (`spec/getting-started__first-launch.md` §2) has two integration points:
//   1. The SYSTEM default — register the app as the OS handler for terminal URL schemes (`ssh://`, `man://`,
//      `telnet://`) and shell-script content types (`.command`/`.sh`/`.tool`). This IS implementable on the
//      LOCAL client Mac and lives here (the modern non-deprecated `NSWorkspace.setDefaultApplication` API).
//   2. "Set as Default Terminal for Common Apps" — rewriting VS Code / Cursor / … per-app external-terminal
//      config. For a REMOTE-host editor this needs a host-side agent and CANNOT map 1:1 (E20 carry-over §4 /
//      DECISIONS "no dead UI"), so the first-launch card honestly-DISABLES it with a documented note rather
//      than ship a dead button. There is therefore deliberately NO `configureCommonApps()` method here.
//
// ## Compiled-only / `#if os(macOS)`
// Touches LaunchServices + opens System Settings; compiled + code-reviewed only, never unit-tested (no real
// LaunchServices mutation in a test). iOS has no user-facing default-terminal concept, so the whole file is
// macOS-only and the iOS first-launch omits the Default-Terminal step (see `FirstLaunchModel.steps(for:)`).

#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers

/// LOCAL "Set as Default Terminal" actions (first-launch step 2 system-default). `@MainActor` because it reads
/// `Bundle.main` + drives `NSWorkspace`; the registrations are best-effort and independent.
@preconcurrency
@MainActor
public enum DefaultTerminalIntegration {
    /// The terminal URL schemes the app registers as the LOCAL default handler for. `ssh` is the primary one
    /// the `isDefaultTerminal()` probe checks. (A remote `ssh://` open routes into an slopdesk remote pane —
    /// the product decision flagged in the spec mapping notes; the registration itself is a local OS concern.)
    public static let urlSchemes = ["ssh", "telnet", "man"]

    /// The shell-script content types the app registers for (the `.command`/`.sh`/`.tool` double-click /
    /// `open script.sh` path). Resolved leniently — a UTType that the SDK does not vend is skipped.
    static var scriptContentTypes: [UTType] {
        var types: [UTType] = [.shellScript]
        for ext in ["command", "tool"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    /// Register the running app as the LOCAL default handler for the terminal URL schemes + shell-script
    /// content types. Best-effort: each registration is independent; returns `true` if EVERY registration
    /// succeeded (a partial failure still leaves the succeeded ones in place). Uses the modern
    /// `NSWorkspace.setDefaultApplication` (macOS 12+) — NOT the deprecated `LSSetDefaultHandlerForURLScheme`.
    @discardableResult
    public static func setAsDefaultTerminal() async -> Bool {
        let appURL = Bundle.main.bundleURL
        var allOK = true
        for scheme in urlSchemes {
            let ok = await setDefault(appURL: appURL, scheme: scheme)
            allOK = allOK && ok
        }
        for type in scriptContentTypes {
            let ok = await setDefault(appURL: appURL, contentType: type)
            allOK = allOK && ok
        }
        return allOK
    }

    /// Whether the running app is already the default handler for the primary `ssh` scheme (drives the card's
    /// "Set" vs "Default" state). Compares the resolved handler app to our own bundle URL.
    public static func isDefaultTerminal() -> Bool {
        guard let probe = URL(string: "ssh://example.invalid") else { return false }
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
    }

    // MARK: - System Settings deep-links (the "Open System Settings" buttons)

    /// Open System Settings → Keyboard → Keyboard Shortcuts → Services (the Finder Integration row — where
    /// the "Open in SlopDesk" Services item is enabled / rebound). Best-effort deep-link.
    public static func openFinderServicesSettings() {
        open("x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")
    }

    /// Open System Settings → Privacy & Security → Full Disk Access (the Full Disk Access row).
    public static func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    // MARK: - Internals

    /// Register `appURL` as the default for `scheme`, awaiting the async completion. `true` on no error.
    private static func setDefault(appURL: URL, scheme: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// Register `appURL` as the default for `contentType`, awaiting the async completion. `true` on no error.
    private static func setDefault(appURL: URL, contentType: UTType) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: contentType) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
#endif

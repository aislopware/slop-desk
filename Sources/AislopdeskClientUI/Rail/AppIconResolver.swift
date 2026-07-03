// AppIconResolver — resolves a HOST app's icon from its bundle identifier against the LOCAL machine's
// installed apps (`NSWorkspace` — both ends are Macs, so the app usually exists client-side). The sidebar's
// Windows rows use it so an open remote-window tab reads as the real app (Xcode's hammer, Safari's compass),
// not a generic symbol. Survivor of the deleted window dock (2026-07-04) — the lookup + cache are unchanged.

#if os(macOS)
import AppKit

/// Cached per bundleID (misses too — a lookup walks LaunchServices). `nil` ⇒ the caller keeps its
/// SF-symbol fallback.
@MainActor
enum AppIconResolver {
    private static var cache: [String: NSImage?] = [:]

    static func icon(bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        var resolved: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            resolved = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache[bundleID] = resolved
        return resolved
    }
}
#endif

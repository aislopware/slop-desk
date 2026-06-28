import Foundation

// MARK: - PortablePaths (recipe-cwd template ⇄ absolute path)

/// The pure path-template layer for **portable recipe working directories**.
///
/// When a recipe is saved with "Make paths portable" enabled, each pane's absolute `cwd` has its longest
/// matching base prefix replaced with a template token (`{{current_folder}}` / `{{home_folder}}` /
/// `{{recipe_location}}`) so the recipe opens correctly on a different checkout / machine; on open the
/// token is re-expanded back to a concrete absolute path. ``portabilize(_:home:currentFolder:recipeLocation:)``
/// runs at SAVE, ``resolve(_:home:currentFolder:recipeLocation:)`` at OPEN.
///
/// **This is the RECIPE-cwd domain, NOT the snippet domain** — it is deliberately NOT routed through
/// ``SnippetExpander`` (whose `{{x}}` are user-prompt slots). The three tokens here are a fixed, closed set
/// resolved from injected directory strings; an unrelated `{{x}}` in a cwd is left verbatim.
///
/// Pure + total + deterministic: no `FileManager`, no `Date`, never traps. Wire posture: 100% client-side,
/// nothing here touches the wire / golden corpus.
public enum PortablePaths {
    /// `{{current_folder}}` — the directory the recipe opens in (the active pane's cwd at open time).
    public static let currentFolderToken = "{{current_folder}}"
    /// `{{home_folder}}` — the user's home directory (`~`).
    public static let homeToken = "{{home_folder}}"
    /// `{{recipe_location}}` — the folder containing the `.ottyrecipe` file on disk.
    public static let recipeLocationToken = "{{recipe_location}}"

    // MARK: Save — portabilize

    /// Replace the LONGEST matching base prefix of the absolute path `absPath` with its template token.
    ///
    /// Candidate bases (most-specific first, so a tie in matched length keeps the higher-priority token):
    /// `currentFolder` → `{{current_folder}}`, `recipeLocation` → `{{recipe_location}}`, `home` →
    /// `{{home_folder}}`. **Longest matched prefix wins** so a path under both `home` *and* a deeper
    /// `currentFolder` portabilizes against `currentFolder`. Matching is on path BOUNDARIES (a base
    /// `/Users/me` matches `/Users/me` and `/Users/me/x`, never `/Users/menlo`). An empty base never
    /// matches; if no base matches, `absPath` is returned unchanged.
    public static func portabilize(
        _ absPath: String,
        home: String,
        currentFolder: String,
        recipeLocation: String,
    ) -> String {
        let candidates: [(prefix: String, token: String)] = [
            (currentFolder, currentFolderToken),
            (recipeLocation, recipeLocationToken),
            (home, homeToken),
        ]
        var best: (length: Int, token: String, remainder: String)?
        for candidate in candidates {
            guard let remainder = remainder(of: absPath, under: candidate.prefix) else { continue }
            let length = normalized(candidate.prefix).count
            // Longest matched prefix wins; on a tie keep the earlier (higher-priority) candidate.
            if let current = best, length <= current.length { continue }
            best = (length, candidate.token, remainder)
        }
        guard let best else { return absPath }
        return best.token + best.remainder
    }

    // MARK: Open — resolve

    /// Re-expand a portable cwd template back to a concrete absolute path by substituting each known token
    /// with its injected directory. A string with no token is returned unchanged; an unrelated `{{x}}` is
    /// left verbatim (only the three closed tokens are substituted). The tokens are distinct, so the
    /// substitution order is irrelevant.
    public static func resolve(
        _ template: String,
        home: String,
        currentFolder: String,
        recipeLocation: String,
    ) -> String {
        var out = template
        out = out.replacingOccurrences(of: currentFolderToken, with: currentFolder)
        out = out.replacingOccurrences(of: recipeLocationToken, with: recipeLocation)
        out = out.replacingOccurrences(of: homeToken, with: home)
        return out
    }

    // MARK: Prefix matching (pure, boundary-aware)

    /// The portion of `path` after the base `prefix`, or `nil` when `prefix` is not a path-boundary prefix
    /// of `path`. `""` (an empty base) never matches. An exact match returns `""`; a child match returns the
    /// suffix INCLUDING its leading `/` (so `remainder("/a/b", under: "/a") == "/b"`).
    static func remainder(of path: String, under rawPrefix: String) -> String? {
        let prefix = normalized(rawPrefix)
        guard !prefix.isEmpty else { return nil }
        if path == prefix { return "" }
        if path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count))
        }
        return nil
    }

    /// `p` with any trailing `/` stripped (but a lone root `/` preserved), so a base recorded with or
    /// without a trailing slash matches identically.
    static func normalized(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

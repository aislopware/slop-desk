import Foundation

/// E15 (WI-4) — the themes-folder engine: locates `~/.config/aislopdesk/themes/`, scans its `.ottytheme`
/// files into validated ``ThemeDocument``s (resolving `inherits` + de-duplicating colliding slugs), and
/// serialises a document back to `.ottytheme` TOML for write-back / duplicate.
///
/// WHY the client, macOS-only (E15 decision #1): aislopdesk renders the terminal on the HOST but resolves the
/// theme + chrome on the CLIENT, so custom themes live on the client at `~/.config/aislopdesk/themes/` (the
/// otty `~/.config/otty/themes/` analog). iOS has no `~/.config`, so the filesystem entry points are
/// `#if os(macOS)`; the pure serialiser + slug helpers stay cross-platform (iOS still renders built-in
/// themes). The directory layout follows ``KeybindConfigLoader`` exactly (XDG-aware, `$HOME/.config` base).
///
/// VALIDATE-THEN-DROP: a missing folder, an unreadable file, or a malformed `.ottytheme` is never fatal — the
/// scan simply skips it and returns whatever parsed cleanly (``ThemeTOMLParser`` already drops invalid
/// documents). No force-unwrap, no trap.
///
/// GOLDEN-SAFETY: custom themes are pure client chrome. Nothing here reaches `EnvConfig` / the sidecar / the
/// wire — a scanned ``ThemeDocument`` only feeds the chrome (`OttyTheme`) and the terminal palette
/// (`TerminalConfigBuilder` overrides), exactly the appearance-prefs invariant.
public enum ThemeLibrary {
    /// The custom-themes directory: `$XDG_CONFIG_HOME/aislopdesk/themes/` (or `$HOME/.config/aislopdesk/themes/`).
    /// `nil` when neither base can be resolved. Pure path arithmetic — it touches no filesystem, so it is
    /// available cross-platform even though only macOS scans it.
    public static func themesDirectoryURL(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL?
    {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else if let home = environment["HOME"], !home.isEmpty {
            base = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config", isDirectory: true)
        } else {
            return nil
        }
        return base
            .appendingPathComponent("aislopdesk", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
    }

    // MARK: - Slug collision (pure, cross-platform)

    /// A slug not already in `existing`: returns `base` when free, else appends `-1`, `-2`, … until unique. An
    /// empty `base` falls back to `theme`. Deterministic and total.
    public static func uniqueSlug(_ base: String, existing: Set<String>) -> String {
        let seed = base.isEmpty ? "theme" : base
        if !existing.contains(seed) { return seed }
        var suffix = 1
        while true {
            let candidate = "\(seed)-\(suffix)"
            if !existing.contains(candidate) { return candidate }
            suffix += 1
        }
    }

    /// Assign each document a slug unique within the set, preserving order — the first document keeps its
    /// derived slug, later collisions get `-1` / `-2`. (otty resolves duplicate theme names this way.)
    static func resolveCollisions(_ documents: [ThemeDocument]) -> [ThemeDocument] {
        var used = Set<String>()
        var out: [ThemeDocument] = []
        out.reserveCapacity(documents.count)
        for original in documents {
            var document = original
            let unique = uniqueSlug(document.slug, existing: used)
            document.slug = unique
            used.insert(unique)
            out.append(document)
        }
        return out
    }

    // MARK: - Serialisation (pure, cross-platform)

    /// Serialise `document` to `.ottytheme` TOML. The output round-trips through ``ThemeTOMLParser/parse(_:fallbackName:resolveParent:)``
    /// back to an equal document (the write-back / duplicate guarantee). Colours are emitted `"#RRGGBB"`
    /// (case preserved), `none` as the literal token; only present optional fields produce a line/section.
    public static func serialize(_ document: ThemeDocument) -> String {
        var out = ""
        func line(_ text: String) { out += text + "\n" }

        line("[meta]")
        line("name = \(quoted(document.displayName))")
        line("mode = \"\(document.mode.rawValue)\"")
        line("")

        line("[terminal]")
        line("foreground = \(colorLiteral(document.foreground))")
        line("background = \(colorLiteral(document.background))")
        line("palette = [")
        for (offset, colour) in document.palette.enumerated() {
            let comma = offset == document.palette.count - 1 ? "" : ","
            line("  \(colorLiteral(colour))\(comma)")
        }
        line("]")
        if let cursor = document.cursor { line("cursor = \(colorLiteral(cursor))") }
        if let cursorText = document.cursorText { line("cursor-text = \(colorLiteral(cursorText))") }
        if let selection = document.selectionBackground { line("selection-background = \(colorLiteral(selection))") }

        if document.accent != nil || document.fontMono != nil || document.fontUI != nil
            || document.fontSize != nil || document.adjustCellHeight != nil
        {
            line("")
            line("[token]")
            if let accent = document.accent { line("accent = \(colorLiteral(accent))") }
            if let fontMono = document.fontMono { line("font-mono = \(stringArrayLiteral(fontMono))") }
            if let fontUI = document.fontUI { line("font-ui = \(stringArrayLiteral(fontUI))") }
            if let fontSize = document.fontSize { line("font-size = \(formatNumber(fontSize))") }
            if let cellHeight = document.adjustCellHeight { line("adjust-cell-height = \(quoted(cellHeight))") }
        }

        appendChromeSection(&out, name: "window", background: document.window)
        appendChromeSection(&out, name: "sidebar", background: document.sidebar)
        appendChromeSection(&out, name: "titlebar", background: document.titlebar)
        appendChromeSection(&out, name: "tab", background: document.tab)
        appendChromeSection(&out, name: "panel", background: document.panel)

        if document.radius != nil || document.shadow != nil || document.border != nil
            || document.padding != nil || document.margin != nil
        {
            line("")
            line("[container]")
            if let radius = document.radius { line("radius = \(formatNumber(radius))") }
            if let shadow = document.shadow { line("shadow = \(quoted(shadow))") }
            if let border = document.border { line("border = \(quoted(border))") }
            if let padding = document.padding { line("padding = \(numberArrayLiteral(padding))") }
            if let margin = document.margin { line("margin = \(numberArrayLiteral(margin))") }
        }

        return out
    }

    private static func appendChromeSection(_ out: inout String, name: String, background: String?) {
        guard let background else { return }
        out += "\n[\(name)]\nbackground = \(colorLiteral(background))\n"
    }

    private static func colorLiteral(_ colour: String) -> String {
        colour == "none" ? "\"none\"" : "\"#\(colour)\""
    }

    private static func quoted(_ raw: String) -> String {
        var escaped = ""
        for char in raw {
            if char == "\\" || char == "\"" { escaped.append("\\") }
            escaped.append(char)
        }
        return "\"\(escaped)\""
    }

    private static func stringArrayLiteral(_ values: [String]) -> String {
        "[" + values.map(quoted).joined(separator: ", ") + "]"
    }

    private static func numberArrayLiteral(_ values: [Double]) -> String {
        "[" + values.map(formatNumber).joined(separator: ", ") + "]"
    }

    /// Integral values print without a decimal (`13.0` → `13`); fractional values keep theirs. Integrality is
    /// detected with NaN-faithful ORDERED comparisons (never a bare float `==`), mirroring the parser.
    private static func formatNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        let fraction = value - rounded
        if fraction >= 0, fraction <= 0, value < 1e15, value > -1e15 {
            return String(Int(rounded))
        }
        return String(value)
    }

    #if os(macOS)
    /// The result of importing / writing a theme file.
    public struct WriteResult: Equatable, Sendable {
        /// The written file's URL.
        public var url: URL
        /// The (possibly collision-suffixed) slug the file was written under.
        public var slug: String

        public init(url: URL, slug: String) {
            self.url = url
            self.slug = slug
        }
    }

    /// Scan the custom-themes directory, returning every well-formed ``ThemeDocument`` (deduplicated slugs).
    /// A missing / unreadable directory yields `[]`. `builtins` are made available to `inherits` resolution
    /// (a custom theme may inherit from a shipped one) but are NOT themselves returned.
    public static func scan(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        builtins: [ThemeDocument] = [],
    ) -> [ThemeDocument] {
        guard let directory = themesDirectoryURL(environment: environment) else { return [] }
        return scan(directory: directory, builtins: builtins)
    }

    /// Scan a specific directory (the testable core of ``scan(environment:builtins:)``). Reads every
    /// `.ottytheme` file, resolves `inherits` (standalone themes first, then a fixpoint over the dependants),
    /// drops malformed files, and assigns collision-free slugs in a deterministic (file-name) order.
    public static func scan(directory: URL, builtins: [ThemeDocument] = []) -> [ThemeDocument] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        ) else { return [] }

        var raws: [(name: String, text: String)] = []
        for url in entries where url.pathExtension.lowercased() == "ottytheme" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            raws.append((url.deletingPathExtension().lastPathComponent, text))
        }
        raws.sort { $0.name < $1.name } // deterministic scan order

        var resolved: [ThemeDocument] = []

        // Phase 1: standalone themes (no `inherits`) — they form the base lookup for dependants.
        var dependants: [(name: String, text: String, parent: String)] = []
        for raw in raws {
            if let parent = ThemeTOMLParser.inheritsName(raw.text) {
                dependants.append((raw.name, raw.text, parent))
            } else if let document = ThemeTOMLParser.parse(raw.text, fallbackName: raw.name) {
                resolved.append(document)
            }
        }

        // Phase 2: dependants whose parent is available — fixpoint until no further progress.
        var progressing = true
        while progressing, !dependants.isEmpty {
            progressing = false
            let lookup = makeLookup(builtins + resolved)
            var stillPending: [(name: String, text: String, parent: String)] = []
            for dependant in dependants {
                guard lookup(dependant.parent) != nil else {
                    stillPending.append(dependant) // parent not resolved yet — retry next pass
                    continue
                }
                if let document = ThemeTOMLParser.parse(
                    dependant.text, fallbackName: dependant.name, resolveParent: lookup,
                ) {
                    resolved.append(document)
                }
                progressing = true // parent present → consumed (resolved or dropped), made progress
            }
            dependants = stillPending
        }

        // Phase 3: leftover dependants whose parent never resolved — accept any that stand on their own.
        for dependant in dependants {
            if let document = ThemeTOMLParser.parse(dependant.text, fallbackName: dependant.name) {
                resolved.append(document)
            }
        }

        // The library is the slug authority ACROSS the folder: derive each slug from the display name (the
        // `[meta] name`, which itself falls back to the file's base name) so two distinct files whose names
        // slug to the same value get deduplicated. (The parser keeps the file-name slug for a single file's
        // standalone identity; the folder-wide de-collision is this layer's job.)
        let slugged = resolved.map { document -> ThemeDocument in
            var copy = document
            copy.slug = ThemeDocument.slug(from: document.displayName)
            return copy
        }
        return resolveCollisions(slugged)
    }

    /// Serialise `document` to `<directory>/<slug>.ottytheme`, creating the directory if needed. Returns the
    /// written URL + slug. The caller is responsible for choosing a collision-free slug (see
    /// ``uniqueSlug(_:existing:)`` / ``scan(directory:builtins:)``).
    @discardableResult
    public static func write(_ document: ThemeDocument, to directory: URL) throws -> WriteResult {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(document.slug).ottytheme", isDirectory: false)
        try serialize(document).write(to: url, atomically: true, encoding: .utf8)
        return WriteResult(url: url, slug: document.slug)
    }

    // MARK: - Import (read a third-party / `.ottytheme` file → write a slug-unique `.ottytheme`)

    /// Why an import can fail. Each case is a clean, surfaceable reason — never a crash on a hostile file.
    public enum ImportError: Error, Equatable, Sendable {
        /// The file at the given URL could not be read.
        case unreadable
        /// `format` was `nil` and the content/extension matched no supported importer.
        case unknownFormat
        /// The file read fine but converted to no valid theme (validate-then-drop: bad/short palette, missing
        /// foreground/background, malformed plist, …).
        case malformed
        /// No themes directory could be resolved (neither `into:` nor `$XDG_CONFIG_HOME`/`$HOME` available).
        case directoryUnavailable
    }

    /// Import a theme file: read it, convert it (``ThemeImporters`` — `format` explicit, or auto-detected from
    /// extension + content sniff), pick a slug unique within the themes directory (and the supplied built-in
    /// slugs), and write the resulting `.ottytheme`. Returns where it landed + the final slug. This is otty's
    /// "Import Theme…" / Finder-drop flow — the slug-collision rule (`-1`, `-2`) matches otty's.
    ///
    /// - Parameters:
    ///   - url: the source file (`.ottytheme` / `.itermcolors` / `.conf` / `.toml` / Ghostty config).
    ///   - format: the explicit import format (the dropdown picks one); `nil` auto-detects.
    ///   - directory: the destination themes folder; defaults to ``themesDirectoryURL(environment:)``.
    ///   - builtinSlugs: shipped-theme slugs the import must not collide with (so an imported "monokai-classic"
    ///     becomes "monokai-classic-1" rather than shadowing a built-in).
    @discardableResult
    public static func importFile(
        at url: URL,
        format: ThemeImporters.Format? = nil,
        into directory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        builtinSlugs: Set<String> = [],
    ) throws -> WriteResult {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }

        let resolvedFormat: ThemeImporters.Format
        if let format {
            resolvedFormat = format
        } else {
            let sniff = String(data: data, encoding: .utf8) ?? ""
            guard let detected = ThemeImporters.detectFormat(pathExtension: url.pathExtension, contents: sniff)
            else { throw ImportError.unknownFormat }
            resolvedFormat = detected
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        guard let document = ThemeImporters.parse(data, format: resolvedFormat, fallbackName: baseName) else {
            throw ImportError.malformed
        }

        let targetDirectory: URL
        if let directory {
            targetDirectory = directory
        } else if let resolved = themesDirectoryURL(environment: environment) {
            targetDirectory = resolved
        } else {
            throw ImportError.directoryUnavailable
        }

        var existing = builtinSlugs
        for existingDocument in scan(directory: targetDirectory) { existing.insert(existingDocument.slug) }

        var stamped = document
        stamped.slug = uniqueSlug(document.slug, existing: existing)
        return try write(stamped, to: targetDirectory)
    }

    /// Build an `inherits`-name → document lookup keyed by both display name and slug (and their slugged
    /// form), so a file may write `inherits = "Monokai Pro"` or `inherits = "monokai-pro"`.
    private static func makeLookup(_ documents: [ThemeDocument]) -> (String) -> ThemeDocument? {
        var index: [String: ThemeDocument] = [:]
        for document in documents {
            index[document.displayName] = document
            index[document.slug] = document
        }
        return { key in index[key] ?? index[ThemeDocument.slug(from: key)] }
    }
    #endif
}

import Foundation

// MARK: - RecipeLibrary (the `.ottyrecipe` folder + trust-store file engine)

/// E16 (WI-8) — the recipes-folder + trust-store engine: locates `~/.config/aislopdesk/recipes/`, scans its
/// `.ottyrecipe` files into validated ``Recipe``s, serialises a ``Recipe`` back out, and reads / writes the
/// trust-on-first-use store (`~/Library/Application Support/Aislopdesk/trusted_recipes.json`). It mirrors
/// ``ThemeLibrary`` exactly (XDG-aware `$HOME/.config` base, validate-then-drop scan, slug de-collision) but
/// for the recipe domain — the pure codec (``RecipeTOMLCodec``) + trust value (``RecipeTrustStore``) sit
/// below it, and the store glue (``WorkspaceStore`` `+Recipes`) sits above.
///
/// **WHY the client (E16 decision, mirroring themes):** a recipe is pure client state — it restores a window
/// layout + replays commands the CLIENT injects; nothing here reaches the host / wire / golden corpus. So
/// recipes live on the client at `~/.config/aislopdesk/recipes/` (the otty `~/.config/otty/recipes/` analog).
///
/// **VALIDATE-THEN-DROP (CLAUDE.md §3):** a missing folder, an unreadable file, or a malformed `.ottyrecipe`
/// is never fatal — ``scan(directory:)`` simply skips it (``RecipeTOMLCodec/parse(_:)`` already drops invalid
/// documents) and ``loadTrust(url:)`` decode-fails to the empty trust set. No force-unwrap, no trap.
///
/// **Headless-safe:** the directory math is pure and the file IO takes EXPLICIT URLs, so a test drives it
/// against a temp dir (no app container, no NSWindow). Cross-platform Foundation (no `#if os` needed in the
/// core); the iOS document-picker import path is the app-side glue (WI-10), not this engine.
public enum RecipeLibrary {
    /// The `.ottyrecipe` filename extension (lowercase; the scan matches case-insensitively).
    public static let fileExtension = "ottyrecipe"

    // MARK: - Directory math (pure, cross-platform)

    /// The recipes directory: `$XDG_CONFIG_HOME/aislopdesk/recipes/` (or `$HOME/.config/aislopdesk/recipes/`).
    /// `nil` when neither base can be resolved. Pure path arithmetic — touches no filesystem (mirrors
    /// ``ThemeLibrary/themesDirectoryURL(environment:)``).
    public static func recipesDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> URL? {
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
            .appendingPathComponent("recipes", isDirectory: true)
    }

    /// The trust-store file: `$HOME/Library/Application Support/Aislopdesk/trusted_recipes.json`. `nil` when
    /// `$HOME` is unavailable. Pure path arithmetic. This is the macOS layout (the trust store is local app
    /// state, NOT user-editable config like the recipes folder); the iOS container path is supplied by the
    /// app-side glue (WI-10).
    public static func trustStoreURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> URL? {
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Aislopdesk", isDirectory: true)
            .appendingPathComponent("trusted_recipes.json", isDirectory: false)
    }

    // MARK: - Values

    /// One scanned recipe file: its on-disk URL, the raw bytes (for the trust checksum), and the parsed
    /// ``Recipe`` (`nil` when the file failed validation — kept for the open picker to grey it honestly).
    public struct RecipeFile: Equatable, Sendable {
        /// The `.ottyrecipe` file's URL.
        public var url: URL
        /// The raw file bytes — the input to ``RecipeTrustStore/sha256Hex(_:)`` (so the open path hashes the
        /// EXACT bytes on disk, not a re-emit).
        public var bytes: [UInt8]
        /// The parsed recipe, or `nil` for a malformed file (validate-then-drop — surfaced, never crashed on).
        public var recipe: Recipe?

        public init(url: URL, bytes: [UInt8], recipe: Recipe?) {
            self.url = url
            self.bytes = bytes
            self.recipe = recipe
        }
    }

    /// The result of writing a recipe: where it landed + the exact bytes written (the trust-checksum input,
    /// so a self-saved recipe is recorded trusted by the SAME bytes a later open will hash).
    public struct WriteResult: Equatable, Sendable {
        public var url: URL
        public var bytes: [UInt8]

        public init(url: URL, bytes: [UInt8]) {
            self.url = url
            self.bytes = bytes
        }
    }

    // MARK: - Slug (pure, cross-platform)

    /// A filesystem-safe slug for a recipe display `name`: lowercased, non-alphanumerics collapsed to `-`,
    /// trimmed; empty input falls back to `recipe`. Deterministic + total (mirrors otty's recipe filenames).
    public static func slugify(_ name: String) -> String {
        var out = ""
        var lastDash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "recipe" : trimmed
    }

    /// A slug not already in `existing`: returns `base` when free, else appends `-1`, `-2`, … until unique
    /// (mirrors ``ThemeLibrary/uniqueSlug(_:existing:)``). Deterministic + total.
    public static func uniqueSlug(_ base: String, existing: Set<String>) -> String {
        let seed = base.isEmpty ? "recipe" : base
        if !existing.contains(seed) { return seed }
        var suffix = 1
        while true {
            let candidate = "\(seed)-\(suffix)"
            if !existing.contains(candidate) { return candidate }
            suffix += 1
        }
    }

    // MARK: - File IO

    /// Read one `.ottyrecipe` file: returns its raw bytes + the parsed ``Recipe`` (`nil` recipe on a
    /// malformed file). `nil` only when the file itself is UNREADABLE (missing / no permission). Never traps.
    public static func read(url: URL) -> RecipeFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        // Non-UTF-8 bytes parse to nil (validate-then-drop) — never a lossy decode of a hostile file.
        let recipe = String(bytes: bytes, encoding: .utf8).flatMap(RecipeTOMLCodec.parse)
        return RecipeFile(url: url, bytes: bytes, recipe: recipe)
    }

    /// Scan `directory` for `.ottyrecipe` files, returning every readable one (parsed or not) in a
    /// deterministic file-name order. A missing / unreadable directory yields `[]` (validate-then-drop).
    public static func scan(directory: URL) -> [RecipeFile] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        ) else { return [] }
        var files: [RecipeFile] = []
        for url in entries where url.pathExtension.lowercased() == fileExtension {
            if let file = read(url: url) { files.append(file) }
        }
        files.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        return files
    }

    /// The set of slugs (file basenames) already present in `directory` — feeds ``uniqueSlug(_:existing:)``
    /// so a re-save under a colliding name lands as `<slug>-1` instead of overwriting.
    public static func existingSlugs(in directory: URL) -> Set<String> {
        Set(scan(directory: directory).map { $0.url.deletingPathExtension().lastPathComponent })
    }

    /// Serialise `recipe` to `<directory>/<slug>.ottyrecipe`, creating the directory if needed. Returns the
    /// written URL + the exact bytes (the trust-checksum input). The caller picks a collision-free `slug`
    /// (see ``uniqueSlug(_:existing:)`` / ``existingSlugs(in:)``).
    @discardableResult
    public static func write(_ recipe: Recipe, to directory: URL, slug: String) throws -> WriteResult {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(slug).\(fileExtension)", isDirectory: false)
        let text = RecipeTOMLCodec.emit(recipe)
        let data = Data(text.utf8)
        try data.write(to: url, options: [.atomic])
        return WriteResult(url: url, bytes: [UInt8](data))
    }

    // MARK: - Trust store IO

    /// Load the trust store from `url`, returning ``RecipeTrustStore/empty`` on a missing / unreadable /
    /// corrupt / schema-mismatched file (``RecipeTrustStore/decode(from:)`` enforces the no-backcompat
    /// decode-fail-to-default). Never traps.
    public static func loadTrust(url: URL) -> RecipeTrustStore {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return RecipeTrustStore.decode(from: data)
    }

    /// Persist `store` to `url` (creating the parent directory), as deterministic sorted-key JSON. A `nil`
    /// encode (never expected for this value shape) is a silent no-op rather than a trap.
    public static func saveTrust(_ store: RecipeTrustStore, to url: URL) throws {
        guard let data = store.encoded() else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try data.write(to: url, options: [.atomic])
    }
}

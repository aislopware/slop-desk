import Foundation

// MARK: - Recipe domain (the in-memory shape of a `.ottyrecipe`)

/// A **recipe** is a portable snapshot of repeatable work — a window's tabs + split panes + working
/// directories and, optionally, the exact commands to replay on open. It serialises to a plain-TOML
/// `.ottyrecipe` file via ``RecipeTOMLCodec`` and is otherwise a pure, headless value type (no I/O, no
/// view, no store) — the file engine (`RecipeLibrary`) and the store glue (`WorkspaceStore+Recipes`) sit
/// above it.
///
/// **Wire posture:** recipes are 100% client-side — nothing here touches the wire / golden corpus. The only
/// numeric is the per-pane ``RecipePane/size`` fraction, clamped with NaN-faithful ORDERED `Double.minimum`
/// /`Double.maximum` (never a bare `<`/`>` ternary, never `addingProduct`/`fma`).
public struct Recipe: Codable, Sendable, Equatable {
    /// Human-readable recipe name (shown in Settings → Recipes, the palette, and the File → Recipe menu).
    public var name: String
    /// Recipe format version. Defaults to ``currentVersion``; a future bump lets the parser migrate.
    public var version: Int
    /// What the recipe captures / replays: a single tab, a whole window, or commands-only.
    public var scope: RecipeScope
    /// The captured window layout (tabs → panes). Empty for a commands-only recipe.
    public var window: RecipeWindow

    /// The `version` an E16 save writes (and the default the parser assumes when the key is absent).
    public static let currentVersion = 1

    public init(
        name: String,
        version: Int = currentVersion,
        scope: RecipeScope,
        window: RecipeWindow = RecipeWindow(),
    ) {
        self.name = name
        self.version = version
        self.scope = scope
        self.window = window
    }
}

// MARK: - RecipeScope (`scope = "tab" | "window" | "commands"`)

/// What a recipe saves / replays. The raw values are the on-disk `scope` tokens; an unknown token makes the
/// whole file DROP (`RecipeTOMLCodec.parse → nil`) — validate-then-drop on untrusted disk input.
public enum RecipeScope: String, Codable, Sendable, Equatable, CaseIterable {
    /// The focused tab only, with its split panes.
    case tab
    /// Every tab in the window.
    case window
    /// Commands only — replayed into the focused pane, no new tabs/windows.
    case commands
}

// MARK: - RecipeSplit (`split = "right" | "left" | "up" | "down"`)

/// The direction a pane splits relative to the PREVIOUS pane in its tab. Optional per pane (the first pane
/// of a tab has no split). An unknown / wrong-typed token DROPS just this field (the pane survives) — a
/// pane with no recorded split is restored as a sibling, not a hard parse failure.
public enum RecipeSplit: String, Codable, Sendable, Equatable, CaseIterable {
    case right
    case left
    case up
    case down
}

// MARK: - RecipeWindow / RecipeTab

/// A window's ordered tabs. Empty for a commands-only recipe.
public struct RecipeWindow: Codable, Sendable, Equatable {
    public var tabs: [RecipeTab]

    public init(tabs: [RecipeTab] = []) {
        self.tabs = tabs
    }
}

/// A tab: a display title plus its ordered panes (DFS order of the split tree at save time).
public struct RecipeTab: Codable, Sendable, Equatable {
    public var title: String
    public var panes: [RecipePane]

    public init(title: String = "", panes: [RecipePane] = []) {
        self.title = title
        self.panes = panes
    }
}

// MARK: - RecipePane

/// One pane in a tab: a working directory, the commands to replay, and its position relative to the
/// previous pane (``split`` direction + ``size`` fraction).
///
/// All four are optional/empty so a Layout-Only recipe (no commands) and a first pane (no split/size) are
/// both representable. ``size`` is the parent fraction `0.0…1.0`; the parser clamps any out-of-range / NaN
/// value through ``clampSize(_:)``.
public struct RecipePane: Codable, Sendable, Equatable {
    /// Working directory at open time. May carry portable templates (`{{current_folder}}` / `{{home_folder}}`
    /// /`{{recipe_location}}`) — resolved on the client side at open, NOT here. `nil` = inherit the default.
    public var cwd: String?
    /// Commands to replay sequentially on open (Include-Commands). Empty for a Layout-Only pane.
    public var commands: [String]
    /// Split direction relative to the previous pane. `nil` for the first pane of a tab.
    public var split: RecipeSplit?
    /// Fraction of the parent container `0.0…1.0`. `nil` = use the default even split.
    public var size: Double?

    public init(
        cwd: String? = nil,
        commands: [String] = [],
        split: RecipeSplit? = nil,
        size: Double? = nil,
    ) {
        self.cwd = cwd
        self.commands = commands
        self.split = split
        self.size = size
    }

    /// Clamp a raw pane `size` fraction into the inclusive `0…1` range.
    ///
    /// Uses NaN-faithful ORDERED `Double.maximum`/`Double.minimum` (CLAUDE.md §2), NEVER a bare `<`/`>`
    /// ternary (wrong NaN behaviour) and NEVER `addingProduct`/`fma`. `Double.maximum(0, x)` returns the
    /// OTHER operand when `x` is NaN, so a hostile `size = nan` resolves to `0.0`, and `±inf` resolve to
    /// `0.0` / `1.0` — total, trap-free over any untrusted `Double`.
    public static func clampSize(_ raw: Double) -> Double {
        Double.minimum(1.0, Double.maximum(0.0, raw))
    }
}

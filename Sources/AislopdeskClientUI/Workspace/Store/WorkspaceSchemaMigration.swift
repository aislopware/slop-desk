import Foundation

// MARK: - Workspace schema migration (single-user: NO backward-compat path)

/// The version-aware seam between a decoded ``Workspace`` value and the shape this build understands
/// (docs/22 §6). `WorkspacePersistence.load()` decodes the raw JSON into a `Workspace` and asks this
/// enum to bring it up to ``Workspace/currentSchemaVersion``.
///
/// ### Single-user → no migration path (docs/31)
/// Aislopdesk has exactly one user and no released persisted format, so there is deliberately NO
/// backward-compatibility migration: an older on-disk shape simply fails to decode (or migrates to
/// `nil` here) and `load()` resets to ``Workspace/defaultWorkspace()`` (preserving the old file aside
/// as a `.corrupt` sidecar). The function is kept as a thin, total seam so the load path stays
/// uniform and a *future* version is detected (not crashed on).
///
/// ### Contract
/// `migrate(_:from:to:)` is a TOTAL, pure function — no IO, no force-unwrap, no throw:
/// - `from == to` → identity (the current-version fast path).
/// - `from != to` → `nil` (there are no upgrade steps; the caller resets to default). This covers both
///   an older shape (no step to climb) and a future version this build cannot interpret.
enum WorkspaceSchemaMigration {
    /// Brings `workspace` from schema version `from` up to `to`, or returns `nil` when it cannot be
    /// understood. Pure and total — see the type doc.
    static func migrate(
        _ workspace: Workspace,
        from: Int,
        to: Int = Workspace.currentSchemaVersion,
    ) -> Workspace? {
        // Same version: identity (preserves every field bit-for-bit). Any other version has no upgrade
        // step (single-user, no backward-compat) → nil so the caller falls back to the default.
        from == to ? workspace : nil
    }
}

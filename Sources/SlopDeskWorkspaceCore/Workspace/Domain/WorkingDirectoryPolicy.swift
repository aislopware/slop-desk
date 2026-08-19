import CSlopDeskFFI
import Foundation

// MARK: - WorkingDirectoryPolicy (`working-directory` / inherit-cwd policy)

/// How a freshly-opened pane (new window / new tab / new split) chooses its initial working directory — the
/// per-context `working-directory` config
/// (`spec/user-interface__window-tab-split.md`, values a path / `home` / `inherit`).
///
/// - ``inherit``: start in the **active pane's** last-known cwd ("Same as Current Tab"). The source cwd
///   is the shell-reported OSC 7 cwd, with the host `cwd` RPC as a command-completion fallback.
/// - ``home``: start in the shell's login directory. Resolves to a **`nil`** cwd — "this pane names no
///   directory", NOT "leave the child wherever it lands". The host turns that into `$HOME`
///   (`PTYProcess.resolveCwd`); it must, because the child is `fork`/`execve`d rather than logged in, so
///   without an explicit `chdir` it would silently inherit the DAEMON's cwd — whatever directory `hostd`
///   happened to be launched from. Still no visible `cd` is typed — see ``resolve(activePaneCwd:)``.
/// - ``path``: start in a fixed absolute path the user configured.
///
/// The rule — the two keywords, the trim, the repair, and which string a new pane's cwd comes from —
/// is `slopdesk_workspace::workdir`. This enum is the near side's vocabulary and the marshalling.
public enum WorkingDirectoryPolicy: Sendable, Equatable {
    /// Same cwd as the active pane (`inherit`).
    case inherit
    /// The shell's login directory — resolves to `nil` (no redundant `cd`); `home` / empty.
    case home
    /// A fixed absolute path (any non-`inherit`/non-`home` config value).
    case path(String)

    /// Decodes the stored `working-directory` config string. The door answers the kind and writes the
    /// trimmed path back, so a config file with a stray newline still names the directory its author
    /// meant. Never traps.
    public init(rawConfig: String) {
        var rawConfig = rawConfig
        var path = [UInt8](repeating: 0, count: rawConfig.utf8.count)
        var needed = 0
        let kind = rawConfig.withUTF8 { raw in
            path.withUnsafeMutableBufferPointer { out in
                slopdesk_ws_workdir_parse(raw.baseAddress, raw.count, out.baseAddress, out.count, &needed)
            }
        }
        switch kind {
        case Self.inheritKind: self = .inherit
        case Self.pathKind:
            let bytes = Array(path.prefix(max(0, needed)))
            self = String(bytes: bytes, encoding: .utf8).map { .path($0) } ?? .home
        default: self = .home
        }
    }

    /// The stored config string for this policy (the inverse of ``init(rawConfig:)``). The keywords come
    /// from the crate that reads them; a path is its own config string.
    public var rawConfig: String {
        if case let .path(path) = self { return path }
        var keyword = [UInt8](repeating: 0, count: Self.keywordCapacity)
        let written = keyword.withUnsafeMutableBufferPointer { out in
            slopdesk_ws_workdir_keyword(ffiKind, out.baseAddress, out.count)
        }
        return String(bytes: keyword.prefix(max(0, written)), encoding: .utf8) ?? ""
    }

    /// Resolves the initial cwd for a new pane, given the active pane's last-known cwd. `nil` means
    /// "send no `cd`" — which ``inherit`` also answers when the active pane has no known cwd yet,
    /// because inheriting an unknown directory is inheriting nothing.
    public func resolve(activePaneCwd: String?) -> String? {
        switch slopdesk_ws_workdir_source(ffiKind, activePaneCwd != nil) {
        case Self.configuredPathSource:
            if case let .path(path) = self { return path }
            return nil
        case Self.activePaneCwdSource: return activePaneCwd
        default: return nil
        }
    }

    /// The payload-free kind the doors speak.
    private var ffiKind: UInt8 {
        switch self {
        case .inherit: Self.inheritKind
        case .home: Self.homeKind
        case .path: Self.pathKind
        }
    }

    private static let inheritKind: UInt8 = 0
    private static let homeKind: UInt8 = 1
    private static let pathKind: UInt8 = 2
    private static let configuredPathSource: UInt8 = 1
    private static let activePaneCwdSource: UInt8 = 2
    /// Both keywords are shorter than this; the door reports a longer answer rather than writing one.
    private static let keywordCapacity = 16
}

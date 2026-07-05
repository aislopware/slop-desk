import XCTest
@testable import SlopDeskWorkspaceCore

/// E10 WI-6 (ES-E10-2): the pure link gesture/menu → action mapping. These pin the "Click Actions"
/// table (`docs/ui-shell/spec/user-interface__files-and-links.md`): a plain click does nothing; ⌘click opens
/// (host for a path, client for a URL) / copies / nothing per `link-cmd-click`; ⌘⇧click reveals-in-Finder or
/// opens-default (paths) but COPIES a URL; and the right-click items route through the same logic. Each
/// assertion is revert-to-confirm-fail — it fails on a policy that opens on a plain click, routes a path open
/// to the client, copies the wrong text, or offers reveal/cd for a URL.
final class LinkActionPolicyTests: XCTestCase {
    // MARK: - Fixtures (one DetectedLink per kind; columns are immaterial to the policy)

    private func link(_ kind: DetectedLinkKind, raw: String, resolved: String?) -> DetectedLink {
        DetectedLink(row: 0, colStart: 0, colEnd: raw.count, kind: kind, raw: raw, resolvedAbsolute: resolved)
    }

    private var absolute: DetectedLink { link(.absolutePath, raw: "/usr/local/bin", resolved: "/usr/local/bin") }
    /// Tilde path: the detector cannot resolve `~` purely, so `resolvedAbsolute` is nil and the policy must
    /// fall back to the RAW text (the host expands `~`).
    private var tilde: DetectedLink { link(.tildePath, raw: "~/project/file.swift", resolved: nil) }
    private var relative: DetectedLink { link(.relativePath, raw: "./src/lib.rs", resolved: "/home/me/src/lib.rs") }
    /// `path:line:col`: the resolved path DROPS the suffix (the detector's contract), so an open/cd acts on
    /// the bare file.
    private var pathLineCol: DetectedLink {
        link(.pathLineCol, raw: "src/lib.rs:42:5", resolved: "/home/me/src/lib.rs")
    }

    private var url: DetectedLink { link(.url, raw: "https://example.com/x", resolved: nil) }
    private var mailto: DetectedLink { link(.url, raw: "mailto:dev@example.com", resolved: nil) }
    private var fileURL: DetectedLink { link(.fileURL, raw: "file:///a/b.txt", resolved: "/a/b.txt") }

    private var pathKinds: [DetectedLink] { [absolute, tilde, relative, pathLineCol, fileURL] }

    private func config(_ cmd: LinkCmdClick, _ shift: LinkCmdShiftClick) -> LinkActionConfig {
        LinkActionConfig(cmdClick: cmd, cmdShiftClick: shift)
    }

    /// Assert a gesture resolves to `expected` for `link` under `cfg`.
    private func assertGesture(
        _ gesture: LinkGesture,
        _ link: DetectedLink,
        _ cfg: LinkActionConfig,
        _ expected: LinkAction,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        let actual = LinkActionPolicy.action(for: gesture, link: link, config: cfg)
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    /// Assert a context-menu item resolves to `expected` for `link`.
    private func assertMenu(
        _ item: TerminalContextMenu.LinkItem,
        _ link: DetectedLink,
        _ expected: LinkAction,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(LinkActionPolicy.action(for: item, link: link), expected, file: file, line: line)
    }

    // MARK: - Plain click: always nothing (prevents accidental opens)

    func testPlainClickIsAlwaysNothing() {
        for cmd in LinkCmdClick.allCases {
            for shift in LinkCmdShiftClick.allCases {
                let cfg = config(cmd, shift)
                for fixture in pathKinds + [url, mailto] {
                    assertGesture(.plainClick, fixture, cfg, .nothing, "plain click on \(fixture.kind) must do nothing")
                }
            }
        }
    }

    // MARK: - ⌘click — open

    func testCommandClickOpen_PathRoutesToHost() {
        let cfg = config(.open, .revealFinder)
        assertGesture(.commandClick, absolute, cfg, .openHost("/usr/local/bin"))
        assertGesture(.commandClick, relative, cfg, .openHost("/home/me/src/lib.rs"))
        assertGesture(.commandClick, pathLineCol, cfg, .openHost("/home/me/src/lib.rs"))
        assertGesture(.commandClick, fileURL, cfg, .openHost("/a/b.txt"))
        // Tilde: unresolved → the RAW `~`-path is handed to the host (which expands it).
        assertGesture(.commandClick, tilde, cfg, .openHost("~/project/file.swift"))
    }

    func testCommandClickOpen_URLRoutesToClient() {
        let cfg = config(.open, .revealFinder)
        assertGesture(.commandClick, url, cfg, .openURLClient("https://example.com/x"))
        assertGesture(.commandClick, mailto, cfg, .openURLClient("mailto:dev@example.com"))
    }

    // MARK: - ⌘click — copy

    func testCommandClickCopy_PathCopiesResolved_URLCopiesRaw() {
        let cfg = config(.copy, .revealFinder)
        assertGesture(.commandClick, absolute, cfg, .copyPathClient("/usr/local/bin"))
        assertGesture(.commandClick, pathLineCol, cfg, .copyPathClient("/home/me/src/lib.rs"))
        // Tilde copy falls back to raw (no pure resolution).
        assertGesture(.commandClick, tilde, cfg, .copyPathClient("~/project/file.swift"))
        assertGesture(.commandClick, url, cfg, .copyPathClient("https://example.com/x"))
    }

    // MARK: - ⌘click — nothing

    func testCommandClickNothing_DisablesEveryKind() {
        let cfg = config(.nothing, .revealFinder)
        for fixture in pathKinds + [url, mailto] {
            assertGesture(.commandClick, fixture, cfg, .nothing)
        }
    }

    // MARK: - ⌘⇧click — reveal / open-default for paths, COPY for URLs

    func testCommandShiftClick_RevealFinder_PathRevealsOnHost() {
        let cfg = config(.open, .revealFinder)
        assertGesture(.commandShiftClick, absolute, cfg, .revealHost("/usr/local/bin"))
        assertGesture(.commandShiftClick, fileURL, cfg, .revealHost("/a/b.txt"))
        assertGesture(.commandShiftClick, tilde, cfg, .revealHost("~/project/file.swift"))
    }

    func testCommandShiftClick_OpenSystemDefault_PathOpensOnHost() {
        let cfg = config(.open, .openSystemDefault)
        assertGesture(.commandShiftClick, absolute, cfg, .openHost("/usr/local/bin"))
        assertGesture(.commandShiftClick, relative, cfg, .openHost("/home/me/src/lib.rs"))
    }

    /// The non-obvious rule: ⌘⇧click on a URL has no Finder target, so it COPIES the URL — regardless of
    /// the (path-oriented) `link-cmd-shift-click` setting.
    func testCommandShiftClick_URLAlwaysCopies() {
        for shift in LinkCmdShiftClick.allCases {
            let cfg = config(.open, shift)
            assertGesture(.commandShiftClick, url, cfg, .copyPathClient("https://example.com/x"))
            assertGesture(.commandShiftClick, mailto, cfg, .copyPathClient("mailto:dev@example.com"))
        }
    }

    // MARK: - Right-click menu items → action

    func testMenuOpen_PathHost_URLClient() {
        assertMenu(.open, absolute, .openHost("/usr/local/bin"))
        assertMenu(.open, url, .openURLClient("https://example.com/x"))
    }

    func testMenuCopyPath_ResolvedForPath_RawForURL() {
        assertMenu(.copyPath, pathLineCol, .copyPathClient("/home/me/src/lib.rs"))
        assertMenu(.copyPath, url, .copyPathClient("https://example.com/x"))
    }

    func testMenuReveal_PathOnly() {
        assertMenu(.revealInFinder, absolute, .revealHost("/usr/local/bin"))
        // Defensive: a URL never offers Reveal (see linkItems), so the policy returns nothing.
        assertMenu(.revealInFinder, url, .nothing)
    }

    func testMenuChangeDirectory_PathToPTY_NotForURL() {
        assertMenu(.changeDirectoryHere, relative, .changeDirectoryPTY("/home/me/src/lib.rs"))
        assertMenu(.changeDirectoryHere, url, .nothing)
    }

    // MARK: - Menu composition + labels (TerminalContextMenu link items)

    func testLinkItemsForKind() {
        XCTAssertEqual(TerminalContextMenu.linkItems(for: .url), [.open, .copyPath])
        let pathSet: [TerminalContextMenu.LinkItem] = [
            .open, .copyPath, .revealInFinder, .changeDirectoryHere,
        ]
        for kind in [DetectedLinkKind.absolutePath, .tildePath, .relativePath, .pathLineCol, .fileURL] {
            XCTAssertEqual(TerminalContextMenu.linkItems(for: kind), pathSet, "kind \(kind) offers full menu")
        }
    }

    func testLinkItemTitlesAreKindAware() {
        XCTAssertEqual(TerminalContextMenu.LinkItem.open.title(for: .url), "Open Link")
        XCTAssertEqual(TerminalContextMenu.LinkItem.open.title(for: .absolutePath), "Open")
        XCTAssertEqual(TerminalContextMenu.LinkItem.copyPath.title(for: .url), "Copy URL")
        XCTAssertEqual(TerminalContextMenu.LinkItem.copyPath.title(for: .absolutePath), "Copy Path")
        XCTAssertEqual(TerminalContextMenu.LinkItem.revealInFinder.title(for: .absolutePath), "Reveal in Finder")
        XCTAssertEqual(
            TerminalContextMenu.LinkItem.changeDirectoryHere.title(for: .absolutePath), "Change Directory Here",
        )
    }

    // MARK: - effectivePath fallback

    func testEffectivePathPrefersResolvedElseRaw() {
        XCTAssertEqual(LinkActionPolicy.effectivePath(absolute), "/usr/local/bin")
        XCTAssertEqual(LinkActionPolicy.effectivePath(tilde), "~/project/file.swift") // nil resolved → raw
        XCTAssertEqual(LinkActionPolicy.effectivePath(fileURL), "/a/b.txt")
    }

    func testConfigDefaultMatchesSlate() {
        XCTAssertEqual(LinkActionConfig.default.cmdClick, .open)
        XCTAssertEqual(LinkActionConfig.default.cmdShiftClick, .revealFinder)
    }

    // MARK: - Explicit open intent (⌘⇧J Hint-to-Open, Jump-To ↩) ignores `link-cmd-click` (review finding 4)

    /// The EXPLICIT open affordances (Hint-to-Open, Jump-To ↩) must OPEN regardless of `link-cmd-click` — that
    /// setting governs only the MOUSE ⌘click gesture. Revert-to-confirm-fail: it fails on the old actuators
    /// that resolved the explicit open via `.commandClick` + config, which under `.copy`/`.nothing` returned
    /// `.copyPathClient`/`.nothing` (a silent copy / no-op). Proven here by contrasting the two policy entries.
    func testExplicitOpenIntentIgnoresCmdClickConfig() {
        for cmd in LinkCmdClick.allCases {
            let cfg = config(cmd, .revealFinder)
            for path in pathKinds {
                let expected = LinkAction.openHost(LinkActionPolicy.effectivePath(path))
                XCTAssertEqual(
                    LinkActionPolicy.explicitOpenAction(link: path), expected,
                    "explicit open on \(path.kind) must open on the host under link-cmd-click=\(cmd)",
                )
            }
            for u in [url, mailto] {
                XCTAssertEqual(LinkActionPolicy.explicitOpenAction(link: u), .openURLClient(u.raw))
            }
            // The divergence the bug rode on: the configurable gesture would copy / no-op under these settings,
            // but the explicit-open entry does not.
            if cmd == .copy {
                XCTAssertEqual(
                    LinkActionPolicy.action(for: .commandClick, link: absolute, config: cfg),
                    .copyPathClient("/usr/local/bin"),
                )
            } else if cmd == .nothing {
                XCTAssertEqual(LinkActionPolicy.action(for: .commandClick, link: absolute, config: cfg), .nothing)
            }
        }
    }

    // MARK: - "Change Directory Here" → parent folder for a FILE (review finding 1)

    func testPosixParentDropsLastComponent() {
        XCTAssertEqual(LinkActionPolicy.posixParent("/a/b/c"), "/a/b")
        XCTAssertEqual(LinkActionPolicy.posixParent("/a/b/c/"), "/a/b") // trailing slash ignored
        XCTAssertEqual(LinkActionPolicy.posixParent("/a"), "/") // root-level entry → root
        XCTAssertEqual(LinkActionPolicy.posixParent("file"), ".") // no slash → current dir
        XCTAssertEqual(LinkActionPolicy.posixParent("/"), "/") // root stays root
    }

    /// A FILE path (the headline `path:line:col` case resolves to a file once the suffix is stripped) must emit
    /// a cd line that FALLS BACK to the parent folder, so the shell never errors `cd: not a directory`.
    /// Revert-to-confirm-fail: fails on the old bare `cd '<file>'\n` idiom.
    func testChangeDirectoryCommandLineFallsBackToParentForFile() {
        XCTAssertEqual(
            LinkActionPolicy.changeDirectoryCommandLine("/home/me/src/lib.rs"),
            "cd '/home/me/src/lib.rs' 2>/dev/null || cd '/home/me/src'\n",
        )
    }

    /// A plain DIRECTORY link still cds into the path itself (it is the first, succeeding operand). Single
    /// quotes in the path are safely escaped in BOTH operands.
    func testChangeDirectoryCommandLineUsesPathForDirectoryAndEscapesQuotes() {
        XCTAssertEqual(
            LinkActionPolicy.changeDirectoryCommandLine("/usr/local/bin"),
            "cd '/usr/local/bin' 2>/dev/null || cd '/usr/local'\n",
        )
        XCTAssertEqual(
            LinkActionPolicy.changeDirectoryCommandLine("/a/it's/x"),
            "cd '/a/it'\\''s/x' 2>/dev/null || cd '/a/it'\\''s'\n",
        )
    }
}

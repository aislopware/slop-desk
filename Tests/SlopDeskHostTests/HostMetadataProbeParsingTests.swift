#if os(macOS)
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The PURE `String → struct` parsers that feed the Details panel's Info-ports + Git data:
/// `parseLsof`, `parseBranchHeader`, `parseStatusLine`, `packStatus`, `statusNibble`. They take NO syscall
/// (no subprocess / PTY / proc query), so the hang-safety rule does NOT apply — they are unit-tested here
/// directly (the surrounding `HostMetadataProbe` I/O paths stay compiled-and-reviewed only).
///
/// Each assertion is written to FAIL on a regressed parser (revert-to-confirm-fail on each guard) and none
/// is tautological: every expected value is an INDEPENDENT literal of the documented porcelain / `lsof -F`
/// convention, never derived from the function under test.
///
/// `#if os(macOS)` — `HostMetadataProbe` is macOS-only (it spawns `git`/`lsof`); the parsers live inside it.
final class HostMetadataProbeParsingTests: XCTestCase {
    // MARK: - parseBranchHeader (porcelain v1 `-b` header, AFTER the `## ` prefix)

    /// `main...origin/main [ahead 2, behind 1]` → branch=main, ahead=2, behind=1.
    func testBranchHeaderAheadBehind() {
        var branch = ""
        var ahead: Int32 = 0
        var behind: Int32 = 0
        HostMetadataProbe.parseBranchHeader(
            "main...origin/main [ahead 2, behind 1]"[...], branch: &branch, ahead: &ahead, behind: &behind,
        )
        XCTAssertEqual(branch, "main")
        XCTAssertEqual(ahead, 2)
        XCTAssertEqual(behind, 1)
    }

    /// A bare `main` (no upstream, no bracket) → branch=main, ahead/behind stay at the 0 default.
    func testBranchHeaderBareBranch() {
        var branch = ""
        var ahead: Int32 = 0
        var behind: Int32 = 0
        HostMetadataProbe.parseBranchHeader("main"[...], branch: &branch, ahead: &ahead, behind: &behind)
        XCTAssertEqual(branch, "main")
        XCTAssertEqual(ahead, 0)
        XCTAssertEqual(behind, 0)
    }

    /// Detached `HEAD (no branch)` → empty branch (the `hasPrefix("HEAD")` collapse), 0/0.
    func testBranchHeaderDetached() {
        var branch = "stale"
        var ahead: Int32 = 0
        var behind: Int32 = 0
        HostMetadataProbe.parseBranchHeader("HEAD (no branch)"[...], branch: &branch, ahead: &ahead, behind: &behind)
        XCTAssertEqual(branch, "", "a detached HEAD must collapse to an empty branch name")
        XCTAssertEqual(ahead, 0)
        XCTAssertEqual(behind, 0)
    }

    /// `feature...origin/feature [ahead 5]` → only `ahead` is set; `behind` stays 0 (no `behind ` token).
    func testBranchHeaderAheadOnly() {
        var branch = ""
        var ahead: Int32 = 0
        var behind: Int32 = 0
        HostMetadataProbe.parseBranchHeader(
            "feature...origin/feature [ahead 5]"[...], branch: &branch, ahead: &ahead, behind: &behind,
        )
        XCTAssertEqual(branch, "feature")
        XCTAssertEqual(ahead, 5)
        XCTAssertEqual(behind, 0)
    }

    /// A garbage count `[ahead x]` falls back to 0 via the `Int32(...) ?? 0` guard (never a trap).
    func testBranchHeaderGarbageCountFallsBackToZero() {
        var branch = ""
        var ahead: Int32 = 99
        var behind: Int32 = 0
        HostMetadataProbe.parseBranchHeader(
            "main...origin/main [ahead x]"[...], branch: &branch, ahead: &ahead, behind: &behind,
        )
        XCTAssertEqual(branch, "main")
        XCTAssertEqual(ahead, 0, "an unparseable ahead count must fall back to 0, overwriting the sentinel")
        XCTAssertEqual(behind, 0)
    }

    // MARK: - claudeProjectSlug (Claude Code's on-disk project-dir encoding)

    /// Claude Code dashes EVERY non-alphanumeric char, not just `/` — verified against a real
    /// `~/.claude/projects` listing where `/Users/me/.config/nvim` stores as `-Users-me--config-nvim`
    /// (the `.` gets its own dash, distinct from the adjacent `/`'s dash — no run-collapsing).
    func testClaudeProjectSlugDashesEveryNonAlphanumericChar() {
        XCTAssertEqual(
            HostMetadataProbe.claudeProjectSlug("/Users/me/.config/nvim"), "-Users-me--config-nvim",
            "a dotted path segment must slug to a SEPARATE dash per non-alphanumeric char",
        )
        XCTAssertEqual(HostMetadataProbe.claudeProjectSlug("/Users/me/my_app"), "-Users-me-my-app")
        XCTAssertEqual(HostMetadataProbe.claudeProjectSlug("/Users/me/proj"), "-Users-me-proj")
    }

    // MARK: - parseStatusLine (porcelain v1 `XY <path>`; rename keeps the NEW path)

    /// `MM f` (staged + worktree modified) → packed `0x11`, path `f`.
    func testStatusLineStagedAndWorktreeModified() {
        let change = HostMetadataProbe.parseStatusLine("MM f"[...])
        XCTAssertEqual(change?.statusCode, 0x11)
        XCTAssertEqual(change?.path, "f")
    }

    /// `?? new.txt` (untracked) → packed `0x77`, path `new.txt`.
    func testStatusLineUntracked() {
        let change = HostMetadataProbe.parseStatusLine("?? new.txt"[...])
        XCTAssertEqual(change?.statusCode, 0x77)
        XCTAssertEqual(change?.path, "new.txt")
    }

    /// `R  old -> new` (rename) → the ` -> ` split keeps the NEW path; X nibble = R (`0x4` high nibble).
    func testStatusLineRenameKeepsNewPath() {
        let change = HostMetadataProbe.parseStatusLine("R  old -> new"[...])
        XCTAssertEqual(change?.path, "new", "a rename row must keep the new path (what the worktree now holds)")
        // R in the index column (X), space in the worktree column (Y) → 0x40.
        XCTAssertEqual(change?.statusCode, 0x40)
        XCTAssertEqual((change?.statusCode ?? 0) >> 4, 0x4, "the renamed category lives in the X (index) nibble")
    }

    /// `A  added` (staged add) → X nibble = A (`0x2` high nibble), path `added`.
    func testStatusLineStagedAdd() {
        let change = HostMetadataProbe.parseStatusLine("A  added"[...])
        XCTAssertEqual(change?.statusCode, 0x20)
        XCTAssertEqual(change?.path, "added")
    }

    /// A too-short line (`" M"`, len < 3) is DROPPED (validate-then-drop, never a trap).
    func testStatusLineTooShortIsDropped() {
        XCTAssertNil(HostMetadataProbe.parseStatusLine(" M"[...]))
    }

    /// An `XY` pair with no path (len == 3 but the path slice is empty) is DROPPED.
    func testStatusLineEmptyPathIsDropped() {
        XCTAssertNil(HostMetadataProbe.parseStatusLine("MM "[...]))
    }

    // MARK: - packStatus / statusNibble (host packing; pinned to the client INVERSE)

    /// The documented porcelain-char → nibble convention (space=0 M=1 A=2 D=3 R=4 C=5 U=6 ?=7 !=8 T=9).
    /// These are INDEPENDENT literals of the spec — not read back from `statusNibble`.
    private static let convention: [(char: Character, nibble: UInt8)] = [
        (" ", 0), ("M", 1), ("A", 2), ("D", 3), ("R", 4),
        ("C", 5), ("U", 6), ("?", 7), ("!", 8), ("T", 9),
    ]

    /// The documented inverse table (nibble → porcelain char) any CLIENT-side unpacking must follow.
    /// `packStatus`/`statusNibble` and this table must stay mutual inverses or host + client drift.
    private static func clientStatusChar(_ nibble: UInt8) -> Character {
        switch nibble {
        case 0: " "
        case 1: "M"
        case 2: "A"
        case 3: "D"
        case 4: "R"
        case 5: "C"
        case 6: "U"
        case 7: "?"
        case 8: "!"
        case 9: "T"
        default: " "
        }
    }

    /// `statusNibble` maps each convention char to its documented nibble; an unknown char → 15.
    func testStatusNibbleConvention() {
        for (char, nibble) in Self.convention {
            XCTAssertEqual(HostMetadataProbe.statusNibble(char), nibble, "statusNibble(\(char)) should be \(nibble)")
        }
        XCTAssertEqual(HostMetadataProbe.statusNibble("Z"), 15, "an unrecognised char must map to the 15 sentinel")
    }

    /// `packStatus` packs X into the high nibble and Y into the low nibble, against LITERAL expected bytes.
    func testPackStatusExplicitBytes() {
        XCTAssertEqual(HostMetadataProbe.packStatus("M", "M"), 0x11)
        XCTAssertEqual(HostMetadataProbe.packStatus("?", "?"), 0x77)
        XCTAssertEqual(HostMetadataProbe.packStatus("R", " "), 0x40)
        XCTAssertEqual(HostMetadataProbe.packStatus("A", " "), 0x20)
        XCTAssertEqual(HostMetadataProbe.packStatus(" ", "M"), 0x01, "X in the HIGH nibble, Y in the LOW nibble")
        XCTAssertEqual(HostMetadataProbe.packStatus("Z", "Z"), 0xFF, "unknown chars pack as 0xF in each nibble")
    }

    /// The host packing round-trips through the documented inverse: for every (X, Y) over the convention,
    /// `clientStatusChar(packed >> 4) == X` and `clientStatusChar(packed & 0x0F) == Y`. This pins the
    /// packing against the convention WITHOUT importing any UI module.
    func testPackStatusIsInverseOfClientUnpacking() {
        for (x, _) in Self.convention {
            for (y, _) in Self.convention {
                let packed = HostMetadataProbe.packStatus(x, y)
                XCTAssertEqual(Self.clientStatusChar(packed >> 4), x, "high nibble must unpack to X=\(x)")
                XCTAssertEqual(Self.clientStatusChar(packed & 0x0F), y, "low nibble must unpack to Y=\(y)")
            }
        }
    }

    // MARK: - parseLsof (`-F cn` field output; port after the LAST colon; malformed → drop)

    /// A `c<cmd>` command line then several `n<addr>` lines: each well-formed address yields one port (the
    /// integer after the LAST `:`, so IPv6 `[::1]:443` resolves to 443), malformed lines are SKIPPED, and
    /// the current command name is carried onto every port.
    func testLsofParsesAddressesAndSkipsMalformed() {
        let output = """
        cnode
        n*:8080
        n127.0.0.1:80
        n[::1]:443
        nfoo
        n*:notaport
        """
        let ports = HostMetadataProbe.parseLsof(output, proto: .tcp)
        // Three well-formed addresses; the two malformed lines (`nfoo` no colon, `n*:notaport` non-numeric)
        // are dropped — count == 3 proves the validate-then-drop, not 5.
        XCTAssertEqual(ports.count, 3)
        XCTAssertEqual(
            ports[0],
            MetadataCodec.PortInfo(port: 8080, proto: MetadataCodec.PortProtocol.tcp.rawValue, procName: "node"),
        )
        XCTAssertEqual(ports[1].port, 80)
        XCTAssertEqual(ports[2].port, 443, "the port is the integer after the LAST colon (IPv6-safe)")
        XCTAssertTrue(ports.allSatisfy { $0.procName == "node" }, "the active `c` command name carries onto every port")
    }

    /// The `proto` argument is carried onto each parsed `PortInfo` (here `.udp` → raw byte 1).
    func testLsofCarriesProtocol() {
        let ports = HostMetadataProbe.parseLsof("cnode\nn*:9000", proto: .udp)
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].proto, MetadataCodec.PortProtocol.udp.rawValue)
        XCTAssertEqual(ports[0].port, 9000)
    }

    /// A `n<addr>` with no preceding `c<cmd>` still yields a port, with an empty command name (no trap).
    func testLsofAddressWithoutCommandHasEmptyName() {
        let ports = HostMetadataProbe.parseLsof("n*:5000", proto: .tcp)
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].port, 5000)
        XCTAssertEqual(ports[0].procName, "")
    }

    // MARK: - opaqueBudgetExceeded (the PURE byte-budget predicate behind the bounded reads)

    /// The source-side opaque-read budget (`readAgentSession` / `gitDiff` drain loop) is bounded at the
    /// builder's 15 MiB opaque cap: exactly `cap` bytes is WITHIN budget (false), `cap + 1` EXCEEDS it
    /// (true) so the drain stops one byte past the cap and `cappedOpaque()` trims an already-bounded tail.
    /// The cap value is the INDEPENDENT ``MetadataResponseBuilder/defaultMaxOpaquePayloadBytes`` source of
    /// truth that the probe's private `maxOpaqueReadBytes` mirrors — so this also pins the two in lockstep
    /// (a drift makes the boundary miss). Pure: no `Process` / `FileHandle` spun (the hang-safety rule).
    func testOpaqueBudgetBoundary() {
        let cap = MetadataResponseBuilder.defaultMaxOpaquePayloadBytes
        XCTAssertFalse(HostMetadataProbe.opaqueBudgetExceeded(0), "an empty capture is within budget")
        XCTAssertFalse(HostMetadataProbe.opaqueBudgetExceeded(cap), "exactly the cap is within budget (no trim)")
        XCTAssertTrue(
            HostMetadataProbe.opaqueBudgetExceeded(cap + 1),
            "cap + 1 exceeds the budget so the drain stops and the builder trims an already-bounded tail",
        )
    }

    // MARK: - resolveGitDiff (subdir-relativity + staged-base resolution; PURE via an injected git runner)

    /// A fake `git` runner that maps an exact argv → captured stdout bytes, modelling a real repo's diff
    /// output INDEPENDENTLY of the resolver (every expected diff body is a literal). An unmatched argv → nil
    /// (a spawn miss / empty result), so the resolver's base ordering + toplevel rooting are exercised
    /// without spinning a real `Process` (the hang-safety rule). The recorder also captures every argv so a
    /// test can assert WHICH `-C <root>` the diff ran under.
    private final class FakeGitRunner {
        var replies: [[String]: Data]
        private(set) var calls: [[String]] = []
        init(_ replies: [[String]: Data]) { self.replies = replies }
        func run(_ args: [String]) -> Data? {
            calls.append(args)
            return replies[args]
        }
    }

    /// The pane cwd is a SUBDIR (`/repo/docs`) while the modified file is REPO-ROOT
    /// relative (`README.md`). `rev-parse --show-toplevel` resolves `/repo`, and the diff MUST run rooted at
    /// `/repo`, not `/repo/docs` — a root-relative pathspec under the subdir matches nothing. The fake only
    /// answers a diff for `-C /repo`; if the diff regresses to running `git -C <cwd> diff -- file`, the
    /// `-C /repo/docs` argv has no reply → empty, so this assertion FAILS (revert-to-confirm-fail).
    func testResolveGitDiffRunsAtRepoToplevelNotSubdirCwd() {
        let body = Data("diff --git a/README.md b/README.md\n@@ -1 +1 @@\n-old\n+new\n".utf8)
        let runner = FakeGitRunner([
            ["-C", "/repo/docs", "rev-parse", "--show-toplevel"]: Data("/repo\n".utf8),
            ["-C", "/repo", "diff", "HEAD", "--", "README.md"]: body,
        ])
        let result = HostMetadataProbe.resolveGitDiff(cwd: "/repo/docs", file: "README.md", run: runner.run)
        XCTAssertEqual(result, body, "a subdir cwd must diff the root-relative file at the repo toplevel")
        XCTAssertTrue(
            runner.calls.contains(["-C", "/repo", "diff", "HEAD", "--", "README.md"]),
            "the diff must be rooted at the toplevel /repo, never the subdir cwd /repo/docs",
        )
        XCTAssertFalse(
            runner.calls.contains { $0.contains("/repo/docs") && $0.contains("diff") },
            "no diff invocation may be rooted at the subdir cwd",
        )
    }

    /// A STAGED/index-only file — `git diff` (unstaged) is EMPTY but `git diff HEAD`
    /// shows the combined change. The fake returns empty for the plain unstaged base and the staged body for
    /// `diff HEAD`; the resolver returns the HEAD body. Running ONLY `git diff -- file` (no
    /// HEAD/--cached) would come back empty, so this FAILS if the resolver drops the HEAD base.
    func testResolveGitDiffShowsStagedChangeViaHeadBase() {
        let staged = Data("diff --git a/staged.txt b/staged.txt\n@@ -0,0 +1 @@\n+line\n".utf8)
        let runner = FakeGitRunner([
            ["-C", "/repo", "rev-parse", "--show-toplevel"]: Data("/repo\n".utf8),
            // The plain unstaged diff is empty for an index-only change.
            ["-C", "/repo", "diff", "--", "staged.txt"]: Data(),
            ["-C", "/repo", "diff", "HEAD", "--", "staged.txt"]: staged,
        ])
        let result = HostMetadataProbe.resolveGitDiff(cwd: "/repo", file: "staged.txt", run: runner.run)
        XCTAssertEqual(result, staged, "a staged-only change must surface via the `diff HEAD` combined base")
    }

    /// The no-HEAD repo (a freshly `git init`+`git add`, no commit yet): `diff HEAD` errors (nil) and the
    /// plain `diff` is empty, but the staged add lives in the index — `diff --cached` shows it. Proves the
    /// resolver falls THROUGH the bases to `--cached` and that a nil base does not short-circuit the chain.
    func testResolveGitDiffFallsThroughToCachedBase() {
        let cached = Data("diff --git a/new.txt b/new.txt\n@@ -0,0 +1 @@\n+hello\n".utf8)
        let runner = FakeGitRunner([
            ["-C", "/repo", "rev-parse", "--show-toplevel"]: Data("/repo\n".utf8),
            // `diff HEAD` ERRORS in a no-HEAD repo → no reply (run returns nil); the plain worktree diff is empty.
            ["-C", "/repo", "diff", "--", "new.txt"]: Data(),
            ["-C", "/repo", "diff", "--cached", "--", "new.txt"]: cached,
        ])
        let result = HostMetadataProbe.resolveGitDiff(cwd: "/repo", file: "new.txt", run: runner.run)
        XCTAssertEqual(result, cached, "with no HEAD and an empty worktree diff, the staged add shows via --cached")
    }

    /// When the toplevel can't be resolved (non-repo / git missing → empty `rev-parse`), the resolver falls
    /// back to rooting the diff at the pane `cwd` itself (best-effort), never dropping the diff entirely.
    func testResolveGitDiffFallsBackToCwdWhenNoToplevel() {
        let body = Data("diff body\n".utf8)
        let runner = FakeGitRunner([
            ["-C", "/loose", "rev-parse", "--show-toplevel"]: Data(), // empty → no toplevel
            ["-C", "/loose", "diff", "HEAD", "--", "f.txt"]: body,
        ])
        let result = HostMetadataProbe.resolveGitDiff(cwd: "/loose", file: "f.txt", run: runner.run)
        XCTAssertEqual(result, body, "an unresolvable toplevel falls back to rooting the diff at the pane cwd")
    }

    /// The argument PLAN is rooted at the given repoRoot for EVERY base and offers the three documented
    /// bases in order (HEAD → worktree → --cached). Independent literals of git's documented flags, not read
    /// back from the function — a regression that drops the staged base or re-roots at a cwd fails here.
    func testGitDiffArgumentPlanBasesAndRoot() {
        let plan = HostMetadataProbe.gitDiffArgumentPlan(repoRoot: "/r", file: "a/b.txt")
        XCTAssertEqual(plan, [
            ["-C", "/r", "diff", "HEAD", "--", "a/b.txt"],
            ["-C", "/r", "diff", "--", "a/b.txt"],
            ["-C", "/r", "diff", "--cached", "--", "a/b.txt"],
        ])
        XCTAssertTrue(plan.allSatisfy { $0[0] == "-C" && $0[1] == "/r" }, "every base must be rooted at repoRoot")
        XCTAssertTrue(plan.contains { $0.contains("--cached") }, "a staged base must be present")
    }
}
#endif

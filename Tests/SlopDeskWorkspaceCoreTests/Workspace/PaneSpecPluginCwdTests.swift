import SlopDeskWorkspaceModel
import XCTest

/// ``PaneSpec``'s two cwd faces — the MARSHALLING, which is the only part of them that is Swift.
///
/// What counts as a plugin manager's transient cache directory, and what a directory's display leaf
/// is, are `slopdesk-workspace`'s `PaneSpec::looks_like_transient_plugin_cwd` and
/// `PaneSpec::cwd_display_name`, tested there beside the `tab_ordering` rules that read them.
/// Re-asserting those matrices here would be the cross-language mirror fixture the
/// one-implementation rule bans — and it is exactly what let the two copies exist at once.
///
/// What is left is real: the UTF-8 hand-off, and `cwdDisplayName`'s `0`-means-`nil` reading, which
/// is a Swift decision about a §4 answer rather than a rule about paths.
final class PaneSpecPluginCwdTests: XCTestCase {
    /// The classifier is reachable and answers both ways across the boundary — the zinit
    /// `owner---repo` flattening in, a real project path out.
    func testTheClassifierDoorIsWired() {
        XCTAssertTrue(
            PaneSpec.looksLikeTransientPluginCwd(
                "/Users/me/.local/share/zinit/plugins/zsh-users---zsh-autosuggestions",
            ),
        )
        XCTAssertFalse(PaneSpec.looksLikeTransientPluginCwd("/Volumes/Lacie/Workspace/oss/slop-desk"))
    }

    /// An empty path crosses as a zero-length buffer, which the door must read as a path rather than
    /// as a null — the one shape the `withUnsafeBufferPointer` hand-off can get wrong.
    func testAnEmptyPathCrossesAsAPathAndIsNotTransient() {
        XCTAssertFalse(PaneSpec.looksLikeTransientPluginCwd(""))
    }

    /// A name comes back whole and byte-exact, including non-ASCII, so the leaf a sidebar row shows
    /// is not re-encoded on the way out.
    func testTheDisplayNameComesBackWhole() {
        XCTAssertEqual(PaneSpec.cwdDisplayName("/a/b/repo"), "repo")
        XCTAssertEqual(PaneSpec.cwdDisplayName("/a/b/thư-mục"), "thư-mục")
        XCTAssertEqual(PaneSpec.cwdDisplayName("/"), "/")
    }

    /// Zero bytes back means "no name to show", not "the call failed" — the reading the Swift side
    /// owns, since a §4 door uses the same `0` for a caller that expects output.
    func testNoNameToShowIsNilRatherThanEmpty() {
        XCTAssertNil(PaneSpec.cwdDisplayName(nil))
        XCTAssertNil(PaneSpec.cwdDisplayName(""))
        XCTAssertNil(PaneSpec.cwdDisplayName("   "))
    }
}

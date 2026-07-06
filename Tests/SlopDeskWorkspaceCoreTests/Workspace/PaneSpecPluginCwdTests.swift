import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins `PaneSpec.looksLikeTransientPluginCwd` — the classifier that keeps a plugin manager's TRANSIENT
/// turbo-`cd` cache dir out of `lastKnownCwd` (the "cwd sometimes becomes zsh-users---zsh-autosuggestions"
/// bug). The `---` signature is zinit's `user/repo → user---repo` flattening; a real project path never
/// carries a triple-dash component, so the drop stays tight.
final class PaneSpecPluginCwdTests: XCTestCase {
    func testFlattenedPluginDirsAreTransient() {
        for path in [
            "/Users/me/.local/share/zinit/plugins/zsh-users---zsh-autosuggestions",
            "/Users/me/.local/share/zinit/plugins/MichaelAquilina---zsh-you-should-use",
            "/opt/zinit/plugins/owner---repo",
        ] {
            XCTAssertTrue(PaneSpec.looksLikeTransientPluginCwd(path), "\(path) is a plugin cache dir")
        }
    }

    func testRealProjectPathsAreNotTransient() {
        for path in [
            "/Volumes/Lacie/Workspace/oss/slop-desk",
            "/Users/me/project",
            "/",
            "/Users/me/dash-named/my-repo", // single dashes are fine
            "/Users/me/a--b", // a double-dash component is NOT the flatten signature
            "",
        ] {
            XCTAssertFalse(PaneSpec.looksLikeTransientPluginCwd(path), "\(path) is a real cwd")
        }
    }
}

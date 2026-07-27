import XCTest
@testable import SlopDeskWorkspaceCore

/// The shape every store-driving test in this suite holds: a workspace document that is LIVE, in
/// process, before a single mutator runs.
///
/// ``WorkspaceChannelClient/send(intent:args:now:)`` refuses anything that is not `.live`, and `.live`
/// is published only from inside the async `start()` run loop — which no synchronous store mutator can
/// wait for. A store whose layout comes from the document and whose channel is not live answers every
/// one of those mutators with a silent no-op: the calls compile, the layout does not move, and nothing
/// is logged to grep for.
///
/// Stated here as one invariant rather than left implicit in each file that remembered the line.
@MainActor
final class WorkspaceStoreLoopbackSeamTests: XCTestCase {
    /// One `attachLoopbackWorkspaceDocument()` leaves the three facts an intent needs: a channel to
    /// send through, `.live` so the send is not refused, and a topology so the optimistic patch has
    /// something to be computed against.
    func testAttachingTheLoopbackLeavesTheStoreHoldingALiveDocument() throws {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0.spec) })

        store.attachLoopbackWorkspaceDocument()

        let channel = try XCTUnwrap(store.workspaceChannel, "there is no channel to send an intent on")
        guard case .live = channel.state else {
            XCTFail("the channel is \(channel.state); `send(intent:)` refuses everything but `.live`")
            return
        }
        XCTAssertNotNil(
            store.workspaceMirror.topology,
            "a nil topology makes `stageIntent` return nil, and every call built on it a silent no-op",
        )
    }
}

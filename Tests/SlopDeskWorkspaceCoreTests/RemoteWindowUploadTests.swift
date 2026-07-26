import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// PATH-4 file-transfer progress: the pure ``FileUploadProgress`` value + the model's upload row
/// bookkeeping (upsert-by-id / dismiss / reset-on-close / endpoint derivation). No networking.
@MainActor
final class RemoteWindowUploadTests: XCTestCase {
    private let target = ConnectionTarget(host: "h.local", port: 7420, mediaPort: 9000, cursorPort: 9001)

    func testFilePortIsTerminalPlusTwo() {
        XCTAssertEqual(target.filePort, 7422)
        XCTAssertEqual(ConnectionTarget(port: 6000).filePort, 6002)
    }

    func testFractionInFlight() {
        let p = FileUploadProgress(id: UUID(), name: "a", sentBytes: 25, totalBytes: 100)
        XCTAssertEqual(p.fraction, 0.25, accuracy: 0.0001)
        XCTAssertFalse(p.isSettled)
    }

    func testFractionCompletedReadsFullEvenWithUnknownSize() {
        let p = FileUploadProgress(id: UUID(), name: "a", sentBytes: 0, totalBytes: 0, phase: .completed)
        XCTAssertEqual(p.fraction, 1)
        XCTAssertTrue(p.isSettled)
    }

    func testFractionUnknownSizeInFlightReadsEmpty() {
        let p = FileUploadProgress(id: UUID(), name: "a", sentBytes: 10, totalBytes: 0)
        XCTAssertEqual(p.fraction, 0)
    }

    func testUpsertInsertsThenUpdatesInPlace() {
        let m = RemoteWindowModel(target: { self.target }, title: "Desktop", desktopDisplayID: 0)
        let id = UUID()
        m.upsertUpload(FileUploadProgress(id: id, name: "big.bin", sentBytes: 0, totalBytes: 100))
        XCTAssertEqual(m.activeUploads.count, 1)

        m.upsertUpload(FileUploadProgress(id: id, name: "big.bin", sentBytes: 50, totalBytes: 100))
        XCTAssertEqual(m.activeUploads.count, 1, "same id updates in place, not appends")
        XCTAssertEqual(m.activeUploads.first?.sentBytes, 50)
    }

    func testUpsertKeepsDistinctIds() {
        let m = RemoteWindowModel(target: { self.target }, title: "Desktop", desktopDisplayID: 0)
        m.upsertUpload(FileUploadProgress(id: UUID(), name: "a"))
        m.upsertUpload(FileUploadProgress(id: UUID(), name: "b"))
        XCTAssertEqual(m.activeUploads.count, 2)
    }

    func testDismissRemovesRow() {
        let m = RemoteWindowModel(target: { self.target }, title: "Desktop", desktopDisplayID: 0)
        let id = UUID()
        m.upsertUpload(FileUploadProgress(id: id, name: "a"))
        m.dismissUpload(id)
        XCTAssertTrue(m.activeUploads.isEmpty)
    }

    func testCloseClearsUploads() {
        let m = RemoteWindowModel(target: { self.target }, title: "Desktop", desktopDisplayID: 0)
        m.upsertUpload(FileUploadProgress(id: UUID(), name: "a"))
        m.close()
        XCTAssertTrue(m.activeUploads.isEmpty)
    }

    func testFileTransferTargetNilBeforeStreaming() {
        let m = RemoteWindowModel(target: { self.target }, title: "Desktop", desktopDisplayID: 0)
        // Not opened yet → no active descriptor → no drop endpoint.
        XCTAssertNil(m.fileTransferTarget())
    }

    func testFileTransferTargetResolvesWhenDesktopStreaming() {
        let m = RemoteWindowModel(target: { self.target }, title: "Desktop", desktopDisplayID: 0)
        m.open()
        let endpoint = m.fileTransferTarget()
        XCTAssertEqual(endpoint?.host, "h.local")
        XCTAssertEqual(endpoint?.port, 7422)
    }

    func testFileTransferTargetNilForWindowPane() {
        // A window (non-desktop) pane is not a drop target even when streaming.
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.open()
        XCTAssertNil(m.fileTransferTarget())
    }
}

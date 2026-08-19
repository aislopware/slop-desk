import Foundation
import SlopDeskFileTransfer
import SlopDeskWorkspaceCore

/// Bridges a desktop-pane file drop to the dedicated PATH-4 ``FileTransferClient`` and feeds progress
/// back into the pane's ``RemoteWindowModel``. App-layer glue (it imports the Network-backed transfer
/// client, which the headless ``SlopDeskWorkspaceCore`` deliberately does not).
///
/// Each drop mints a fresh UUID per file so re-drops never collide; the client emits index-scoped
/// events, which map back to those UUIDs by position. A settled row lingers briefly (so the user sees
/// the ✓ / ✗) then dismisses.
///
/// ## The SCOPE is why this is one implementation and not two
///
/// A URL dropped on iOS arrives SECURITY-SCOPED: it names a file the app may read only between
/// `startAccessingSecurityScopedResource()` and its stop, and the upload's read spans the whole
/// transfer rather than one call. A dropped Finder URL on an unsandboxed Mac needs no such grant, and
/// the API says so by ANSWERING `false` — which is what lets the scope be taken unconditionally here
/// instead of behind a platform gate. Balance the stop against that answer, never against the
/// platform: an unbalanced stop on macOS is as wrong as a missing start on iOS.
///
/// It belongs here rather than in ``FileTransferClient`` because the scope is a property of where the
/// URL CAME FROM — a drop — and the transfer client is handed URLs by callers that did not drop
/// anything. It belongs here rather than in the view because the grant has to outlive the drop
/// callback, and this is what owns the Task that outlives it.
@MainActor
package enum FileUploadCoordinator {
    /// How long a settled upload row stays before it dismisses.
    private static let settledLinger: Duration = .seconds(2.5)

    /// Starts uploading `files` to `host:port`, upserting progress into `model` as it advances.
    package static func upload(files: [URL], host: String, port: UInt16, into model: RemoteWindowModel) {
        let items = files.map { (id: UUID(), url: $0) }
        guard !items.isEmpty else { return }

        // Seed a row per file so the overlay appears immediately, before the first byte moves.
        for item in items {
            model.upsertUpload(FileUploadProgress(id: item.id, name: item.url.lastPathComponent))
        }

        let ids = items.map(\.id)
        let names = items.map(\.url.lastPathComponent)

        // The Task holds `model` for the upload's duration (a pane closed mid-transfer still lands
        // its file on the host). Each event is AWAITED onto the main actor, so rows apply strictly
        // in emission order — progress never runs backwards and a stale progress can never stomp a
        // completed row — and every event has been applied by the time the upload returns.
        let urls = items.map(\.url)
        Task {
            // Taken BEFORE the first read and dropped after the last one — the grant covers the whole
            // transfer, not the callback that started it.
            let granted = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { for url in granted { url.stopAccessingSecurityScopedResource() } }
            let client = FileTransferClient()
            await client.upload(files: urls, host: host, port: port) { @MainActor event in
                apply(event, ids: ids, names: names, into: model)
            }
        }
    }

    private static func apply(_ event: FileUploadEvent, ids: [UUID], names: [String], into model: RemoteWindowModel) {
        func rowID(_ index: UInt32) -> UUID? {
            let i = Int(index)
            return ids.indices.contains(i) ? ids[i] : nil
        }
        func rowName(_ index: UInt32) -> String {
            let i = Int(index)
            return names.indices.contains(i) ? names[i] : "file"
        }

        switch event {
        case let .started(id, name, totalBytes):
            guard let uuid = rowID(id) else { return }
            model.upsertUpload(FileUploadProgress(id: uuid, name: name, sentBytes: 0, totalBytes: totalBytes))
        case let .progress(id, sentBytes, totalBytes):
            guard let uuid = rowID(id) else { return }
            model.upsertUpload(FileUploadProgress(
                id: uuid, name: rowName(id), sentBytes: sentBytes, totalBytes: totalBytes, phase: .sending,
            ))
        case let .completed(id):
            guard let uuid = rowID(id) else { return }
            model.upsertUpload(FileUploadProgress(id: uuid, name: rowName(id), phase: .completed))
            scheduleDismiss(uuid, in: model)
        case let .failed(id, reason):
            guard let uuid = rowID(id) else { return }
            model.upsertUpload(FileUploadProgress(id: uuid, name: rowName(id), phase: .failed, reason: reason))
            scheduleDismiss(uuid, in: model)
        }
    }

    private static func scheduleDismiss(_ id: UUID, in model: RemoteWindowModel) {
        Task { @MainActor [weak model] in
            try? await Task.sleep(for: settledLinger)
            model?.dismissUpload(id)
        }
    }
}

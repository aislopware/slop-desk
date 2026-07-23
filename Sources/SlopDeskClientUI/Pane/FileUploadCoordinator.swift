#if canImport(SwiftUI)
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
@MainActor
enum FileUploadCoordinator {
    /// How long a settled upload row stays before it dismisses.
    private static let settledLinger: Duration = .seconds(2.5)

    /// Starts uploading `files` to `host:port`, upserting progress into `model` as it advances.
    static func upload(files: [URL], host: String, port: UInt16, into model: RemoteWindowModel) {
        let items = files.map { (id: UUID(), url: $0) }
        guard !items.isEmpty else { return }

        // Seed a row per file so the overlay appears immediately, before the first byte moves.
        for item in items {
            model.upsertUpload(FileUploadProgress(id: item.id, name: item.url.lastPathComponent))
        }

        let ids = items.map(\.id)
        let names = items.map(\.url.lastPathComponent)

        // The outer Task holds `model` for the upload's duration; each event hops to the main actor with
        // a WEAK ref so a pane closed mid-transfer is not kept alive by trailing progress events.
        Task {
            let client = FileTransferClient()
            await client.upload(files: items.map(\.url), host: host, port: port) { event in
                Task { @MainActor [weak model] in
                    guard let model else { return }
                    apply(event, ids: ids, names: names, into: model)
                }
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
#endif

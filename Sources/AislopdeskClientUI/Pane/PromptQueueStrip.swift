// PromptQueueStrip — the otty "Prompt Queue" chip strip (E12 / WI-5). Sits just ABOVE the Composer and
// shows one chip per pending prompt; hidden entirely when the queue is empty (`queue.isEmpty`).
//
// Anatomy matches `queue.png`: a full-width light strip holding rounded chip pills, each `[ text  🗑 ]`,
// left-aligned with comfortable padding. A chip is:
//   • TAP        → edit  (pops the prompt back into the Composer — ``ComposerModel/editChip(id:)``)
//   • 🗑 button   → remove (drops it from the queue without running — ``ComposerModel/removeChip(id:)``)
//   • DRAG       → reorder (drop onto another chip — ``ComposerModel/moveChip(from:to:)``)
//
// All mutations route through the durable per-pane ``ComposerModel`` (which owns the pure
// ``AislopdeskClaudeCode/PromptQueueModel``), so the GUI and the headless `PromptQueueModelTests` /
// `ComposerModelTests` drive the same queue logic. No send side-effect here — chips dispatch later, one per
// idle, through the model's send sink.

#if canImport(SwiftUI)
import AislopdeskClaudeCode
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct PromptQueueStrip: View {
    /// The durable per-pane Composer model — `promptQueue.items` is the chip source; the verbs mutate it.
    let composer: ComposerModel

    // Platform hit-target sizing — iOS uses larger finger targets (the queue mapping note).
    #if os(iOS)
    private let chipHeight: CGFloat = 34
    private let trashSize: CGFloat = 15
    #else
    private let chipHeight: CGFloat = 26
    private let trashSize: CGFloat = 11
    #endif

    var body: some View {
        // Hidden when empty (otty: "not visible when the queue is empty"). Read `items` so the strip
        // re-renders on every enqueue / dispatch / reorder.
        let items = composer.promptQueue.items
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Otty.Metric.space2) {
                    ForEach(items) { item in
                        chip(item)
                    }
                }
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.vertical, Otty.Metric.space2)
            }
            .background(Otty.Surface.element)
            .overlay(alignment: .top) {
                Rectangle().fill(Otty.Line.divider).frame(height: Otty.Metric.hairline)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// One queue chip — `[ text  🗑 ]`. Tap edits, 🗑 removes, drag-onto-another-chip reorders.
    private func chip(_ item: PromptQueueItem) -> some View {
        HStack(spacing: Otty.Metric.space1) {
            // Tap-to-edit: the whole label is the edit hit-target (separate Button from the 🗑 below).
            Button {
                composer.editChip(id: item.id)
            } label: {
                Text(item.text)
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Edit in Composer")

            Button {
                composer.removeChip(id: item.id)
            } label: {
                Image(systemSymbol: .trash)
                    .font(.system(size: trashSize, weight: .medium))
                    .foregroundStyle(Otty.Text.icon)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Remove from queue")
        }
        .padding(.horizontal, Otty.Metric.space2)
        .frame(height: chipHeight)
        .background(Otty.Surface.selectedCard, in: RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                .strokeBorder(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
        )
        // Drag-to-reorder: carry the chip's stable id; dropping onto another chip moves it there.
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { payload, _ in
            reorder(droppedID: payload.first, onto: item.id)
        }
    }

    /// Resolve the dropped chip's id + the target chip's id to queue indices and reorder. A missing /
    /// unknown / same-slot id is a silent no-op (validate-then-degrade — a stale drag payload can't trap).
    private func reorder(droppedID: String?, onto targetID: PromptQueueItem.ID) -> Bool {
        let items = composer.promptQueue.items
        guard let droppedID,
              let sourceUUID = UUID(uuidString: droppedID),
              let source = items.firstIndex(where: { $0.id == sourceUUID }),
              let destination = items.firstIndex(where: { $0.id == targetID }),
              source != destination
        else { return false }
        composer.moveChip(from: source, to: destination)
        return true
    }
}
#endif

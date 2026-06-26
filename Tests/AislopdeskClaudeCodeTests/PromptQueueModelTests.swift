import Foundation
import XCTest
@testable import AislopdeskClaudeCode

/// E12 WI-1 — pure prompt-queue contract (headless, no UI, no send side-effects).
final class PromptQueueModelTests: XCTestCase {
    private let CR: UInt8 = 0x0D

    // MARK: Enqueue — multi-line split, trim, drop blanks, preserve order

    func testEnqueueSplitsMultilineDraftTrimsAndDropsBlankLines() {
        var queue = PromptQueueModel()
        queue.enqueue("a\n\nb\n c ")
        XCTAssertEqual(queue.items.map(\.text), ["a", "b", "c"])
    }

    func testEnqueueSingleLineYieldsOneItem() {
        var queue = PromptQueueModel()
        queue.enqueue("build the release")
        XCTAssertEqual(queue.items.map(\.text), ["build the release"])
    }

    func testEnqueueOfOnlyBlankLinesAddsNothing() {
        var queue = PromptQueueModel()
        queue.enqueue("   \n\n\t\n  ")
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.items.count, 0)
    }

    func testEnqueueHandlesCRLFAndLoneCRSeparators() {
        var queue = PromptQueueModel()
        queue.enqueue("one\r\ntwo\rthree")
        XCTAssertEqual(queue.items.map(\.text), ["one", "two", "three"])
    }

    func testEnqueueAppendsPreservingOrderAcrossCalls() {
        var queue = PromptQueueModel()
        queue.enqueue("first")
        queue.enqueue("second\nthird")
        XCTAssertEqual(queue.items.map(\.text), ["first", "second", "third"])
    }

    func testEnqueueReturnsIdsOfAppendedItemsInOrder() {
        var queue = PromptQueueModel()
        let ids = queue.enqueue("x\ny")
        XCTAssertEqual(ids, queue.items.map(\.id))
        XCTAssertEqual(ids.count, 2)
    }

    // MARK: isEmpty toggles for strip visibility

    func testIsEmptyTogglesWithContent() {
        var queue = PromptQueueModel()
        XCTAssertTrue(queue.isEmpty)
        queue.enqueue("a")
        XCTAssertFalse(queue.isEmpty)
        _ = queue.dispatchNext()
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: Reorder

    func testMoveReordersToFinalIndex() {
        var queue = PromptQueueModel()
        queue.enqueue("a\nb\nc")
        queue.move(from: 0, to: 2)
        XCTAssertEqual(queue.items.map(\.text), ["b", "c", "a"])
        queue.move(from: 2, to: 0)
        XCTAssertEqual(queue.items.map(\.text), ["a", "b", "c"])
    }

    func testMoveOutOfRangeIsNoOp() {
        var queue = PromptQueueModel()
        queue.enqueue("a\nb")
        queue.move(from: 5, to: 0) // source invalid
        XCTAssertEqual(queue.items.map(\.text), ["a", "b"])
        queue.move(from: 0, to: 99) // destination clamps to last
        XCTAssertEqual(queue.items.map(\.text), ["b", "a"])
    }

    // MARK: Remove by id

    func testRemoveItemDeletesByIdOnly() {
        var queue = PromptQueueModel()
        queue.enqueue("a\nb\nc")
        let middle = queue.items[1].id
        queue.removeItem(id: middle)
        XCTAssertEqual(queue.items.map(\.text), ["a", "c"])
    }

    func testRemoveUnknownIdIsNoOp() {
        var queue = PromptQueueModel()
        queue.enqueue("a")
        queue.removeItem(id: UUID())
        XCTAssertEqual(queue.items.map(\.text), ["a"])
    }

    // MARK: Edit-pop (take)

    func testTakeReturnsAndRemovesItem() {
        var queue = PromptQueueModel()
        queue.enqueue("a\nb\nc")
        let target = queue.items[1]
        let popped = queue.take(id: target.id)
        XCTAssertEqual(popped, "b")
        XCTAssertEqual(queue.items.map(\.text), ["a", "c"])
    }

    func testTakeUnknownIdReturnsNilAndDoesNotMutate() {
        var queue = PromptQueueModel()
        queue.enqueue("a\nb")
        XCTAssertNil(queue.take(id: UUID()))
        XCTAssertEqual(queue.items.map(\.text), ["a", "b"])
    }

    // MARK: Dispatch — head bytes (UTF-8 + CR), FIFO, nil when empty

    func testDispatchNextReturnsHeadBytesUTF8PlusCRAndPops() {
        var queue = PromptQueueModel()
        queue.enqueue("a\nb")
        let bytes = queue.dispatchNext()
        XCTAssertEqual(bytes.map { Array($0) }, Array("a".utf8) + [CR])
        XCTAssertEqual(queue.items.map(\.text), ["b"])
    }

    func testDispatchNextIsFIFOAcrossCalls() {
        var queue = PromptQueueModel()
        queue.enqueue("one\ntwo")
        XCTAssertEqual(queue.dispatchNext().map { Array($0) }, Array("one".utf8) + [CR])
        XCTAssertEqual(queue.dispatchNext().map { Array($0) }, Array("two".utf8) + [CR])
    }

    func testDispatchNextReturnsNilWhenEmpty() {
        var queue = PromptQueueModel()
        XCTAssertNil(queue.dispatchNext())
        queue.enqueue("only")
        _ = queue.dispatchNext()
        XCTAssertNil(queue.dispatchNext())
    }

    func testDispatchPreservesMultibyteUTF8ThenCR() {
        var queue = PromptQueueModel()
        queue.enqueue("café — 修复")
        let bytes = queue.dispatchNext()
        XCTAssertEqual(bytes.map { Array($0) }, Array("café — 修复".utf8) + [CR])
    }
}

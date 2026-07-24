import XCTest
@testable import SlopDeskAgentDetect

final class TOMLSubsetParserTests: XCTestCase {
    func testScalarsArraysAndTableArrays() throws {
        let root = try TOMLSubsetParser.parse(#"""
        id = "claude"          # trailing comment
        version = '2026.07.13.1'
        min_engine_version = 2
        flag = true
        aliases = ["claude-code"]

        [[rules]]
        id = "r1"
        regex = ['^[\x{2800}-\x{28FF}] ']
        any = [
          { contains = ["ctrl+o", "to toggle"] },
          { contains = ["a#b"], any = [{ contains = ["nested"] }] },
        ]
        """#)
        XCTAssertEqual(root["id"], .string("claude"))
        XCTAssertEqual(root["version"], .string("2026.07.13.1"))
        XCTAssertEqual(root["min_engine_version"], .integer(2))
        XCTAssertEqual(root["flag"], .boolean(true))
        XCTAssertEqual(root["aliases"], .array([.string("claude-code")]))
        let rules = try XCTUnwrap(root["rules"]?.arrayValue)
        XCTAssertEqual(rules.count, 1)
        let rule = try XCTUnwrap(rules[0].tableValue)
        // The literal string preserves the backslash escapes verbatim.
        XCTAssertEqual(rule["regex"], .array([.string(#"^[\x{2800}-\x{28FF}] "#)]))
        let any = try XCTUnwrap(rule["any"]?.arrayValue)
        XCTAssertEqual(any.count, 2)
        XCTAssertEqual(any[0].tableValue?["contains"], .array([.string("ctrl+o"), .string("to toggle")]))
        // '#' inside a string is not a comment.
        XCTAssertEqual(any[1].tableValue?["contains"], .array([.string("a#b")]))
    }

    func testBasicStringEscapes() throws {
        let root = try TOMLSubsetParser.parse(#"s = "a\"b\\c\nd✳""#)
        XCTAssertEqual(root["s"], .string("a\"b\\c\nd✳"))
    }

    func testMalformedInputsThrow() {
        XCTAssertThrowsError(try TOMLSubsetParser.parse("just text"))
        XCTAssertThrowsError(try TOMLSubsetParser.parse("a = \"unterminated"))
        XCTAssertThrowsError(try TOMLSubsetParser.parse("a = [1, 2"))
        XCTAssertThrowsError(try TOMLSubsetParser.parse("a = 1.5"))
        XCTAssertThrowsError(try TOMLSubsetParser.parse("[table]\na = 1"))
        XCTAssertThrowsError(try TOMLSubsetParser.parse("a = 1\na = 2"))
    }

    func testAllBundledManifestTOMLsRoundTripThroughTheParser() throws {
        for (agent, toml) in BundledAgentManifests.all {
            let root = try TOMLSubsetParser.parse(toml)
            XCTAssertNotNil(root["id"]?.stringValue, agent.label)
            XCTAssertFalse(root["rules"]?.arrayValue?.isEmpty ?? true, agent.label)
        }
    }
}

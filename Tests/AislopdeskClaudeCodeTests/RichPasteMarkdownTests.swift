import XCTest
@testable import AislopdeskClaudeCode

/// E12 WI-2 — pure HTML→Markdown rich-paste converter (headless, no AppKit/UIKit).
///
/// Every assertion pins an exact expected string (never the converter's own derivation), and
/// the hostile-input cases pin "no crash + degrade", honouring the validate-then-degrade rule.
final class RichPasteMarkdownTests: XCTestCase {
    private func md(_ html: String) -> String { RichPasteMarkdown.markdown(fromHTML: html) }

    // MARK: Headings

    func testH1BecomesHash() {
        XCTAssertEqual(md("<h1>Title</h1>"), "# Title")
    }

    func testHeadingLevelsMapToHashCount() {
        XCTAssertEqual(md("<h2>Two</h2>"), "## Two")
        XCTAssertEqual(md("<h3>Three</h3>"), "### Three")
        XCTAssertEqual(md("<h6>Six</h6>"), "###### Six")
    }

    func testHeadingThenParagraphHasBlankLineBetween() {
        XCTAssertEqual(md("<h1>Title</h1><p>Body text here.</p>"), "# Title\n\nBody text here.")
    }

    // MARK: Bold / italic / inline code

    func testStrongAndBBecomeDoubleStar() {
        XCTAssertEqual(md("<strong>bold</strong>"), "**bold**")
        XCTAssertEqual(md("<b>bold</b>"), "**bold**")
    }

    func testEmAndIBecomeSingleStar() {
        XCTAssertEqual(md("<em>it</em>"), "*it*")
        XCTAssertEqual(md("<i>it</i>"), "*it*")
    }

    func testInlineCodeBecomesBacktick() {
        XCTAssertEqual(md("<code>x = 1</code>"), "`x = 1`")
    }

    func testInlineFormattingPreservesSurroundingSpaces() {
        XCTAssertEqual(md("a <strong>b</strong> c"), "a **b** c")
    }

    // MARK: Links + images

    func testAnchorBecomesMarkdownLink() {
        XCTAssertEqual(md("<a href=\"https://example.com\">site</a>"), "[site](https://example.com)")
    }

    func testAnchorWithoutHrefDegradesToText() {
        XCTAssertEqual(md("<a>bare</a>"), "bare")
    }

    func testAnchorHrefEntityIsDecoded() {
        XCTAssertEqual(
            md("<a href=\"https://x.com?a=1&amp;b=2\">link</a>"),
            "[link](https://x.com?a=1&b=2)",
        )
    }

    func testImageBecomesMarkdownImageRef() {
        XCTAssertEqual(md("<img src=\"pic.png\" alt=\"cat\">"), "![cat](pic.png)")
    }

    func testImageWithoutSrcIsDropped() {
        XCTAssertEqual(md("<img alt=\"nope\">"), "")
    }

    // MARK: Lists

    func testUnorderedListBecomesDashItems() {
        XCTAssertEqual(md("<ul><li>a</li><li>b</li></ul>"), "- a\n- b")
    }

    func testOrderedListBecomesNumberedItems() {
        XCTAssertEqual(md("<ol><li>first</li><li>second</li></ol>"), "1. first\n2. second")
    }

    func testSingleOrderedItemIsOneDotPrefix() {
        XCTAssertEqual(md("<ol><li>only</li></ol>"), "1. only")
    }

    func testNestedListIsIndentedByTwoSpaces() {
        XCTAssertEqual(md("<ul><li>a<ul><li>b</li></ul></li></ul>"), "- a\n  - b")
    }

    // MARK: Paragraphs / line breaks / preformatted

    func testParagraphsAreBlankLineSeparated() {
        XCTAssertEqual(
            md("<p>First paragraph.</p><p>Second paragraph.</p>"),
            "First paragraph.\n\nSecond paragraph.",
        )
    }

    func testBrBecomesSingleNewline() {
        XCTAssertEqual(md("line one<br>line two"), "line one\nline two")
    }

    func testPreBecomesFencedCodeBlockPreservingWhitespace() {
        XCTAssertEqual(
            md("<pre><code>let x = 1\nlet y = 2</code></pre>"),
            "```\nlet x = 1\nlet y = 2\n```",
        )
    }

    func testWhitespaceIsCollapsedOutsidePre() {
        XCTAssertEqual(md("<p>line\n   with   spaces</p>"), "line with spaces")
    }

    // MARK: Entities

    func testNamedEntitiesDecode() {
        XCTAssertEqual(md("<p>Tom &amp; Jerry &lt;3</p>"), "Tom & Jerry <3")
    }

    func testNumericEntitiesDecode() {
        XCTAssertEqual(md("<p>It&#39;s &#x2764; ok</p>"), "It's \u{2764} ok")
    }

    func testBareAmpersandIsLeftLiteral() {
        XCTAssertEqual(md("<p>a & b</p>"), "a & b")
    }

    // MARK: Realistic browser fragment (head matter stripped)

    func testBrowserFragmentStripsMetaAndStyle() {
        let html = "<meta charset=\"utf-8\"><style>p{color:red}</style>" +
            "<p>Hello <strong>world</strong></p>"
        XCTAssertEqual(md(html), "Hello **world**")
    }

    func testCommentsAreStripped() {
        XCTAssertEqual(md("<p>before<!-- hidden -->after</p>"), "beforeafter")
    }

    // MARK: Validate-then-degrade — hostile / empty input never crashes

    func testEmptyInputYieldsEmptyString() {
        XCTAssertEqual(md(""), "")
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(md("just some plain text"), "just some plain text")
    }

    func testStrayAngleBracketsDoNotCrashAndPassThrough() {
        XCTAssertEqual(md("<<>>"), "<<>>")
    }

    func testUnterminatedTagAtEOFIsDropped() {
        XCTAssertEqual(md("text <span"), "text")
    }

    func testUnclosedInlineTagDegradesWithoutCrash() {
        // Unbalanced markers are tolerated (degrade, not crash).
        XCTAssertEqual(md("<b>bold"), "**bold")
    }

    func testMalformedHrefIsDecodedDefensively() {
        // A missing closing quote reads to the end of the attribute span; no trap.
        XCTAssertNoThrow(md("<a href=\"unclosed>text</a>"))
    }

    func testBogusEntityIsLeftLiteral() {
        XCTAssertEqual(md("<p>5 &nope; 6 &#xZZ; 7</p>"), "5 &nope; 6 &#xZZ; 7")
    }

    func testDeeplyMismatchedNestingDoesNotCrash() {
        XCTAssertNoThrow(md("<ul><ol><li>x</ul></ol></li><p></strong>"))
    }
}

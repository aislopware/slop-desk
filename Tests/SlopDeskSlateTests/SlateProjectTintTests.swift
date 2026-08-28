import XCTest
@testable import SlopDeskSlate

/// `Slate.ProjectTint` — the per-project identity bed. Pins the three properties the feature exists
/// for and had no test for at all before this suite: the seed is the project's NAME (not its
/// address), the deal is launch-stable, and no two islands standing next to each other are dealt one
/// colour. Pure arithmetic — no view, no `Color` comparison, no surface.
final class SlateProjectTintTests: XCTestCase {
    // MARK: - The seed is the basename

    /// The published FNV-1a-64 known-answer vector, so a future refactor of the hash cannot silently
    /// re-deal every project on the machine. `FNV-1a64("a") == 0xAF63DC4C8601EC8C`.
    func testHashMatchesTheFNV1aKnownAnswerVector() {
        XCTAssertEqual(Slate.ProjectTint.hash("a"), 0xAF63_DC4C_8601_EC8C)
    }

    /// The identity travels with the project, not with where it is checked out. This is the whole
    /// point of seeding from the basename: the same repo cloned to a different parent, or moved one
    /// directory up, keeps its colour.
    func testSameProjectAtDifferentPathsIsDealtTheSameSeed() {
        let seeds = [
            "/Volumes/Lacie/Workspace/oss/slop-desk",
            "/Users/someone/code/slop-desk",
            "/Users/someone/code/slop-desk/",
        ].map(Slate.ProjectTint.seed(for:))
        XCTAssertEqual(Set(seeds), ["slop-desk"], "the basename is the seed; trailing slashes are not")
    }

    /// A case-insensitive volume hands us whichever spelling the shell used, and NFC/NFD differ by
    /// filesystem — neither may change a project's colour.
    func testSeedFoldsCaseAndNormalisesUnicode() {
        XCTAssertEqual(Slate.ProjectTint.seed(for: "/a/MyApp"), Slate.ProjectTint.seed(for: "/a/myapp"))
        let composed = "/a/caf\u{00E9}" // café, NFC
        let decomposed = "/a/cafe\u{0301}" // café, NFD
        XCTAssertEqual(Slate.ProjectTint.seed(for: composed), Slate.ProjectTint.seed(for: decomposed))
    }

    /// Degenerate keys resolve rather than trap — a bed is decoration and must never be a crash site.
    func testDegenerateKeysStillDealASeed() {
        XCTAssertEqual(Slate.ProjectTint.seed(for: "/"), "")
        XCTAssertEqual(Slate.ProjectTint.seed(for: ""), "")
        XCTAssertEqual(Slate.ProjectTint.seed(for: "bare-name"), "bare-name")
    }

    // MARK: - Stability

    /// Two deals of the same run agree, and a project's index does not depend on the run being fresh.
    /// (`hashValue` would fail this across processes; FNV-1a is why it cannot.)
    func testDealIsDeterministic() {
        let keys: [String?] = ["/a/alpha", "/b/beta", nil, "/c/gamma", "/d/delta"]
        XCTAssertEqual(Slate.ProjectTint.Deal(keys: keys).indices, Slate.ProjectTint.Deal(keys: keys).indices)
    }

    /// With no collision, the repair is INERT: every group keeps exactly the index its own basename
    /// hashes to. The repair may only ever fire on a genuine neighbour clash.
    func testNonCollidingRunKeepsEveryPureHashIndex() {
        let count = Slate.ProjectTint.registerCount
        // Build a run whose consecutive preferred indices already differ, then assert nothing moved.
        var keys: [String] = []
        var previous: Int?
        var candidate = 0
        while keys.count < 8 {
            let key = "/w/project-\(candidate)"
            candidate += 1
            let index = Slate.ProjectTint.index(of: key, count: count)
            if index == previous { continue }
            keys.append(key)
            previous = index
        }
        let deal = Slate.ProjectTint.Deal(keys: keys.map { Optional($0) })
        XCTAssertEqual(deal.indices, keys.map { Slate.ProjectTint.index(of: $0, count: count) })
    }

    // MARK: - The adjacency guarantee

    /// The load-bearing property: NO two islands that touch may wear one colour. Swept over a large
    /// generated corpus — with five entries a pure hash collides on ~1 adjacent pair in 5, so a
    /// broken repair fails this immediately rather than subtly.
    func testNoTwoAdjacentIslandsShareAnIndex() {
        var generator = SystemRandomNumberGenerator()
        for run in 0..<400 {
            let length = 2 + Int.random(in: 0...10, using: &generator)
            // Draw from a SMALL pool of basenames so exact-duplicate neighbours occur too, which is
            // the hardest case: two panes rooted in two different checkouts both called `api`.
            let keys: [String?] = (0..<length).map { _ in
                let pick = Int.random(in: 0...6, using: &generator)
                return pick == 6 ? nil : "/run\(run)/name\(pick)"
            }
            let indices = Slate.ProjectTint.Deal(keys: keys).indices
            for position in 1..<indices.count {
                guard let here = indices[position], let above = indices[position - 1] else { continue }
                XCTAssertNotEqual(
                    here, above,
                    "islands \(position - 1)/\(position) of \(keys) share bed \(here)",
                )
            }
        }
    }

    /// Two ADJACENT groups with the identical basename — the case a pure hash can never separate —
    /// are dealt apart. This is what the user sees when the same repo is open from two checkouts.
    func testIdenticalBasenamesSideBySideAreDealtApart() {
        let deal = Slate.ProjectTint.Deal(keys: ["/one/api", "/two/api", "/three/api"])
        XCTAssertNotEqual(deal.indices[0], deal.indices[1])
        XCTAssertNotEqual(deal.indices[1], deal.indices[2])
    }

    /// A keyless section takes the neutral bed AND constrains nothing after it — the neutral is
    /// ΔE2000 ≥ 7.21 from every register entry, so a keyed group below it can never be mistaken for
    /// it, and forcing the next group to move would re-deal colours for no visual gain.
    func testKeylessSectionsAreNeutralAndDoNotConstrainWhatFollows() {
        let key = "/w/solo"
        let pure = Slate.ProjectTint.index(of: key, count: Slate.ProjectTint.registerCount)
        let deal = Slate.ProjectTint.Deal(keys: [nil, key])
        XCTAssertNil(deal.indices[0], "the keyless bucket has no identity to spend")
        XCTAssertEqual(deal.indices[1], pure, "a group under the Other bucket keeps its own hash")
    }

    // MARK: - Register integrity

    /// The count the arithmetic uses must equal the count of colours that exist, and it must stay
    /// PRIME: the repair's stride is drawn from 1…count-1 and relies on being coprime with the
    /// count, so a single probe can never land back where it started.
    @MainActor
    func testRegisterCountMatchesTheRegisterAndIsPrime() {
        XCTAssertEqual(Slate.ProjectTint.registerCount, Slate.ProjectTint.registerHexes.count)
        let count = Slate.ProjectTint.registerCount
        XCTAssertTrue(count > 2 && !(2..<count).contains { count.isMultiple(of: $0) }, "\(count) must be prime")
    }

    /// Every index the deal can emit indexes a real register entry — the repair's modular walk must
    /// never run off the end.
    func testEveryDealtIndexIsInRange() {
        let keys: [String?] = (0..<500).map { "/w/p\($0)" }
        for case let index? in Slate.ProjectTint.Deal(keys: keys).indices {
            XCTAssertTrue((0..<Slate.ProjectTint.registerCount).contains(index))
        }
    }
}

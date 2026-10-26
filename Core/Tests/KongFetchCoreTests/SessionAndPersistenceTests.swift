import XCTest
@testable import KongFetchCore
import KongFetchTestSupport

final class SessionAndPersistenceTests: XCTestCase {
    private var root = ""
    private var index: NameIndex!

    override func setUpWithError() throws {
        root = try SyntheticTree.temporaryDirectory("session")
        try SyntheticTree.create(at: root, files: 2000, seed: 11)
        index = NameIndex.build(roots: [root], rules: .standard(home: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func scores(_ hits: [SearchHit]) -> [Int32: Int] {
        var result: [Int32: Int] = [:]
        for hit in hits { result[hit.id] = hit.score }
        return result
    }

    /// Typing letter by letter must give the same results as searching from scratch.
    func testNarrowingGivesSameResultsAsFullSearch() {
        let typed: [[[String]]] = [
            ["c", "co", "con", "cont", "contr", "contract"].map { [$0] },
            ["h", "he", "het", "heto", "hetong"].map { [$0] },
            [["re"], ["rep"], ["rep", "2"], ["rep", "20"], ["rep", "202"], ["rep", "2024"]],
            [["合"], ["合同"], ["合同", "fi"], ["合同", "final"]],
            [["le"], ["lec"], ["lect"], ["lt"]],
        ]
        for precision in MatchPrecision.allCases {
            for sequence in typed {
                let session = SearchSession(index: index)
                for words in sequence {
                    let narrowed = scores(session.search(words, precision: precision))
                    let full = scores(index.search(words, precision: precision))
                    XCTAssertEqual(narrowed, full, "\(precision) \(words)")
                }
            }
        }
    }

    func testNarrowingIsUsedOnlyWhenSafe() {
        let session = SearchSession(index: index)
        _ = session.search(["r"])
        _ = session.search(["re"])
        XCTAssertFalse(session.lastSearchNarrowed, "1-character words cannot be narrowed")
        _ = session.search(["rep"])
        XCTAssertTrue(session.lastSearchNarrowed)
        _ = session.search(["rep", "2024"])
        XCTAssertTrue(session.lastSearchNarrowed)
        _ = session.search(["rap"])
        XCTAssertFalse(session.lastSearchNarrowed)
        _ = session.search(["rap"], precision: .exactName)
        _ = session.search(["rapid"], precision: .exactName)
        XCTAssertFalse(session.lastSearchNarrowed)
    }

    func testSessionDropsResultsAfterIndexChanges() throws {
        let session = SearchSession(index: index)
        _ = session.search(["zzq"])
        try makeTree(root, ["zzqx 新文件.txt"])
        index.apply([IndexChange(path: root + "/zzqx 新文件.txt")])
        let hits = session.search(["zzqx"])
        XCTAssertFalse(session.lastSearchNarrowed)
        XCTAssertEqual(hits.count, 1)
    }

    func testSaveAndLoadRoundTrip() throws {
        index.lastEventID = 123_456_789
        index.eventDatabaseUUID = "TEST-UUID"
        // Leave some deleted entries so saving has to compact.
        let some = index.liveEntryIDs().prefix(50)
        for id in some where !index.isDeleted(id) { index.removeSubtree(id) }
        let file = URL(fileURLWithPath: root + "-index.kfidx")
        defer { try? FileManager.default.removeItem(at: file) }
        let before = index.allEntries()
        try index.save(to: file)
        let loaded = try NameIndex.load(from: file)

        assertSameEntries(loaded.allEntries(), before)
        XCTAssertEqual(loaded.roots, index.roots)
        XCTAssertEqual(loaded.rules, index.rules)
        XCTAssertEqual(loaded.lastEventID, 123_456_789)
        XCTAssertEqual(loaded.eventDatabaseUUID, "TEST-UUID")
        XCTAssertEqual(loaded.entryCount, index.entryCount)
        XCTAssertEqual(loaded.directoryCount, index.directoryCount)
        for words in [["合同"], ["hetong"], ["report", "2024"], ["kc"], ["课程资料"]] {
            for precision in MatchPrecision.allCases {
                XCTAssertEqual(scores(loaded.search(words, precision: precision)), scores(index.search(words, precision: precision)), "\(words) \(precision)")
            }
        }
        // A loaded index keeps working incrementally.
        try makeTree(root, ["加载后新增.txt"])
        loaded.apply([IndexChange(path: root + "/加载后新增.txt")])
        XCTAssertEqual(loaded.search(["加载后"]).count, 1)
    }

    func testCorruptFilesAreRejected() throws {
        let file = URL(fileURLWithPath: root + "-bad.kfidx")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not an index".utf8).write(to: file)
        XCTAssertThrowsError(try NameIndex.load(from: file))
        try index.save(to: file)
        let data = try Data(contentsOf: file)
        try data.prefix(data.count / 2).write(to: file)
        XCTAssertThrowsError(try NameIndex.load(from: file))
    }
}

import XCTest
@testable import KongFetchCore
import KongFetchLegacy32
import KongFetchTestSupport

/// The new engine must score every file exactly as 3.2 does, for every query and
/// precision. 3.2's code is in KongFetchLegacy32, copied verbatim.
final class MatchingParityTests: XCTestCase {
    private static var root = ""
    private static var index: NameIndex!

    static let edgeNames = [
        "Résumé Final.pdf", "ＦＵＬＬ ＷＩＤＴＨ.txt", "archive.tar.gz", "重庆火锅.jpg", "银行流水 2024.xlsx", "a.",
        "no_extension", "Mixed 中文 Name.docx", "emoji 🎉 party.txt", "Ünïcödé.md", "readme", "README.md", "read me.md",
        "合同", "合同.pdf", "长沙之行.mov", "Café.pdf", "cafe\u{301} decomposed.txt", "x.y.z", "UPPER.PDF",
        "report-final_v2 (copy).docx", "音乐会.mp3", "朝阳区地图.png", "1234.txt", "a b c.txt", ".hidden note.md",
        "行长讲话.docx", "重新整理.txt", "Ｒｅｐｏｒｔ全角.pdf", "ab", "ba", "aab.txt",
    ]

    static let queries: [[String]] = [
        ["合同"], ["hetong"], ["ht"], ["report"], ["rpt"], ["readme"], ["read", "me"], ["READ"], ["年度", "报告"], ["ndbg"],
        ["lunyu"], ["a"], ["pdf"], ["resume"], ["café"], ["cafe"], ["full"], ["ｆｕｌｌ"], ["chongqing"], ["cq"], ["yinhang"],
        ["hangzhang"], ["chongxin"], ["changsha"], ["zhaoyang"], ["yinyue"], ["2024"], ["边界"], ["sub dir"], ["subdir"],
        ["cases"], ["docs"], ["Documents"], ["课程资料"], ["kc"], ["tar.gz"], ["a b c"], ["emoji"], ["🎉"],
        ["final", "report"], ["fnl"], ["x.y"], ["1234"], ["13"], ["zz"], ["meeting", "2025"], ["学生", "名单"], ["ab"],
        ["build"], ["lib"], ["teaching", "讲稿"], ["Ｒｅｐｏｒｔ"], ["re"],
    ]

    override class func setUp() {
        super.setUp()
        root = try! SyntheticTree.temporaryDirectory("parity")
        try! SyntheticTree.create(at: root, files: 1500, seed: 7)
        let edgeFolder = root + "/边界 Cases/Sub Dir"
        try! FileManager.default.createDirectory(atPath: edgeFolder, withIntermediateDirectories: true)
        for name in edgeNames { FileManager.default.createFile(atPath: edgeFolder + "/" + name, contents: nil) }
        index = NameIndex.build(roots: [root], rules: ExclusionRules(includeHidden: true))
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    func testIndexContainsTheEdgeCaseFiles() {
        let paths = Set(Self.index.allEntries().keys.map { ($0 as NSString).lastPathComponent })
        for name in Self.edgeNames {
            XCTAssertTrue(paths.contains(name) || paths.contains(name.precomposedStringWithCanonicalMapping) || paths.contains(name.decomposedStringWithCanonicalMapping), name)
        }
    }

    func testScoresMatch32ForEveryEntryQueryAndPrecision() {
        let ids = Self.index.liveEntryIDs()
        let urls = ids.map { URL(fileURLWithPath: Self.index.path(of: $0)) }
        var mismatches: [String] = []
        var compared = 0
        for precision in MatchPrecision.allCases {
            let legacy = Legacy32Precision(rawValue: precision.rawValue)!
            for words in Self.queries {
                var actual: [Int32: Int] = [:]
                for hit in Self.index.search(words, precision: precision) { actual[hit.id] = hit.score }
                for (k, id) in ids.enumerated() {
                    let expected = legacy.score(urls[k], words: words)
                    compared += 1
                    if expected != actual[id] {
                        mismatches.append("\(precision) \(words) \(urls[k].lastPathComponent) in \(urls[k].deletingLastPathComponent().lastPathComponent): 3.2=\(expected.map { String($0) } ?? "nil") new=\(actual[id].map { String($0) } ?? "nil")")
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 100_000)
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) of \(compared) differ. First ones:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }

    func testStringMatcherAgreesWith32FuzzyScore() {
        let texts = Self.edgeNames + SyntheticTree.chineseWords + SyntheticTree.englishWords + ["/Users/kong/Documents/课程资料/2024", "Read-Me_final.TXT"]
        let words = ["re", "rm", "readme", "合同", "a", "ｒｅ", "café", "doc", "kc", "2024", "zz", "rdme", "fnl", "资料"]
        for text in texts {
            for word in words {
                XCTAssertEqual(NameMatcher.fuzzyScore(text, word), fuzzyScore(text, word), "\(text) / \(word)")
            }
        }
    }

    func testPinyinFormsMatch32() {
        for name in Self.edgeNames + SyntheticTree.chineseWords {
            XCTAssertEqual(Pinyin.forms(name), pinyinForms(name), name)
        }
    }
}

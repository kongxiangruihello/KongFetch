import XCTest
@testable import KongFetchCore
@testable import KongFetchLegacy32
import KongFetchTestSupport

/// The search-box syntax must behave exactly like 3.2's AdvancedSearchQuery.
final class QueryParityTests: XCTestCase {
    static let inputs = [
        "合同", "ext:pdf \"年度合同\" -草稿", "\"今天\"", "最近7天的PDF 合同 -草稿", "ext:pdf \"annual contract\" -draft",
        "合同 -草稿", "-草稿", "ext:../pdf", "ext:pdf,png -ext:png", "\"a*b?\"", "\"ext:pdf\"", "ext:\"PDF\"", "lele",
        "-ext:pdf", "ext:pdf", "pdf 合同", "文档 报告", "\"pdf\" 合同", "图片", "大于10MB 视频", "最近一周的 PDF", "昨天的文档",
        "标签:工作 合同", "#重要 report", "tag:work", "\"未闭合 引号", "ext:", "ext:pdf，docx", "-\"草 稿\"", "report \\\"quoted\\\"",
        "“中文引号” 测试", "近3周", "最近一个月 合同 ext:docx", "a -b -c ext:txt|md", "今天的 PDF", "小于 1.5 GB", "FOLDER 课程",
        "ext:.PDF", "  多个   空格  ", "-", "\"\"", "ext:p d f",
    ]

    func testParsingMatches32() {
        for input in Self.inputs {
            let new = SearchQuery(input)
            let old = AdvancedSearchQuery(input, fallback: .all)
            XCTAssertEqual(new.words, old.words, input)
            XCTAssertEqual(new.phrases, old.phrases, input)
            XCTAssertEqual(new.excluded, old.excluded, input)
            XCTAssertEqual(new.excludedPhrases, old.excludedPhrases, input)
            XCTAssertEqual(new.extensions, old.extensions, input)
            XCTAssertEqual(new.excludedExtensions, old.excludedExtensions, input)
            XCTAssertEqual(new.notes, old.notes, input)
            XCTAssertEqual(new.valid, old.valid, input)
            XCTAssertEqual(new.filter.rawValue, old.filter.rawValue, input)
            XCTAssertEqual(new.natural.text, old.natural.text, input)
            XCTAssertEqual(new.natural.days, old.natural.days, input)
            XCTAssertEqual(new.natural.yesterday, old.natural.yesterday, input)
            XCTAssertEqual(new.natural.minimum, old.natural.minimum, input)
            XCTAssertEqual(new.natural.maximum, old.natural.maximum, input)
            XCTAssertEqual(new.natural.tag, old.natural.tag, input)
            XCTAssertEqual(new.natural.descriptions, old.natural.descriptions, input)
            XCTAssertEqual(new.descriptions, old.descriptions, input)
            XCTAssertEqual(new.hasConstraints, old.hasConstraints, input)
            XCTAssertEqual(new.textWithoutFilters, old.textWithoutFilters, input)
            XCTAssertEqual(new.positiveText, old.positiveText32, input)
        }
    }

    func testFallbackFilterMatches32() {
        for (raw, filter) in KindFilter.allCases.enumerated() {
            let old = AdvancedSearchQuery("合同", fallback: FileFilter(rawValue: raw)!)
            XCTAssertEqual(SearchQuery("合同", fallback: filter).filter.rawValue, old.filter.rawValue)
        }
    }

    func testIndexScoresMatch32ForQueries() throws {
        let root = try SyntheticTree.temporaryDirectory("query")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try SyntheticTree.create(at: root, files: 1200, seed: 5)
        try makeTree(root, ["年度合同/年度合同.pdf", "年度合同/年度合同 草稿.pdf", "其他/annual contract.PDF", "其他/annual contract draft.pdf",
                            "其他/a*b? 奇怪.txt", "其他/ext:pdf 名字.md", "边界/sub dir/合同.docx", "pdfs/"])
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        let ids = index.liveEntryIDs()
        let urls = ids.map { URL(fileURLWithPath: index.path(of: $0)) }
        let queries = ["ext:pdf 合同", "ext:pdf \"年度合同\" -草稿", "\"report\" -final", "-ext:pdf,docx report", "合同 -草稿", "-草稿",
                       "ext:pdf", "\"课程\"", "pdf 合同", "\"2024\" lecture", "ext:md,txt", "-ext:jpg 照片", "\"sub dir\"", "-\"边界\"",
                       "\"annual contract\" -draft", "\"a*b?\"", "\"ext:pdf\"", "-ext:pdf", "最近一周的 PDF", "ext:../pdf", "\"未闭合",
                       "hetong -ext:pdf", "\"合同\" \"年度\"", "文件夹 课程"]
        var mismatches: [String] = []
        for precision in MatchPrecision.allCases {
            let oldPrecision = Legacy32Precision(rawValue: precision.rawValue)!
            for text in queries {
                let query = SearchQuery(text)
                let old = AdvancedSearchQuery(text, fallback: .all)
                var actual: [Int32: Int] = [:]
                for hit in index.search(query, precision: precision) { actual[hit.id] = hit.score }
                for (k, id) in ids.enumerated() {
                    let expected = old.filenameScore(urls[k], precision: oldPrecision)
                    if expected != actual[id] {
                        mismatches.append("\(precision) [\(text)] \(urls[k].path.dropFirst(root.count)): 3.2=\(expected.map { String($0) } ?? "nil") new=\(actual[id].map { String($0) } ?? "nil")")
                    }
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) differ. First ones:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }

    func testMetadataFiltersMatch32() throws {
        let root = try SyntheticTree.temporaryDirectory("metadata")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileManager = FileManager.default
        let now = Date()
        func file(_ name: String, bytes: Int = 0, daysAgo: Double = 0, tags: [String] = []) throws -> String {
            let path = root + "/" + name
            try fileManager.createDirectory(atPath: Paths.parent(path), withIntermediateDirectories: true)
            fileManager.createFile(atPath: path, contents: Data(count: bytes))
            try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: path)
            if !tags.isEmpty { try (URL(fileURLWithPath: path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
            return path
        }
        let paths = [
            try file("今天的合同.pdf"), try file("上周报告.pdf", daysAgo: 6), try file("去年资料.pdf", daysAgo: 400),
            try file("昨天笔记.txt", daysAgo: 1), try file("大视频.mov", bytes: 12_000_000), try file("小图片.png", bytes: 2_000),
            try file("工作计划.docx", tags: ["工作"]), try file("重要 report.md", tags: ["重要"]), try file("音乐.mp3"),
        ]
        try fileManager.createDirectory(atPath: root + "/课程文件夹", withIntermediateDirectories: true)
        let all = paths + [root + "/课程文件夹"]
        let queries = ["最近一周的 PDF", "今天的 PDF", "昨天", "大于10MB 视频", "小于 1MB", "图片", "文档", "音频", "文件夹", "标签:工作",
                       "#重要", "tag:不存在", "pdf", "最近30天", "folder", "近2周 文档", "超过 0.001 MB"]
        for text in queries {
            let query = SearchQuery(text)
            let old = AdvancedSearchQuery(text, fallback: .all)
            for path in all {
                let entry = Entry(URL(fileURLWithPath: path))
                let expected = old.filter.accepts(entry) && old.natural.accepts(entry, now: now)
                XCTAssertEqual(query.acceptsMetadata(EntryMetadata.read(path: path), now: now), expected, "\(text) \((path as NSString).lastPathComponent)")
            }
        }
    }

    func testQueryWithoutWordsListsFilteredEntries() throws {
        let root = try SyntheticTree.temporaryDirectory("nowords")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeTree(root, ["a.pdf", "b.PDF", "c.txt", "folder/d.pdf"])
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        let names = Set(index.search(SearchQuery("ext:pdf")).map { index.name(of: $0.id) })
        XCTAssertEqual(names, ["a.pdf", "b.PDF", "d.pdf"])
        XCTAssertTrue(index.search(SearchQuery("ext:../pdf")).isEmpty, "invalid queries match nothing")
    }
}

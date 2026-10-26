import XCTest
@testable import KongFetchCore
import KongFetchTestSupport

final class IndexBehaviorTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = try SyntheticTree.temporaryDirectory("behavior")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private let sampleTree = [
        "课程/build/讲义.pdf", "课程/Library/书目.docx", "Library/Caches/cache.db", "node_modules/pkg/index.js",
        ".hidden/secret.txt", ".DS_Store", "工具/Demo.app/Contents/Info.plist", "工具/普通.folder/内容.txt", "readme.md",
    ]

    /// 3.2 skipped any folder called `build` or `Library`; that was a source of
    /// missing results. Now only the exact ~/Library path is excluded.
    func testStandardRulesKeepUserFoldersNamedBuildOrLibrary() throws {
        try makeTree(root, sampleTree)
        try FileManager.default.createSymbolicLink(atPath: root + "/捷径", withDestinationPath: root + "/课程")
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        let entries = index.allEntries()
        let names = relativeNames(entries, root: root)

        XCTAssertTrue(names.contains("课程/build/讲义.pdf"))
        XCTAssertTrue(names.contains("课程/Library/书目.docx"))
        XCTAssertFalse(names.contains("Library"), "exact ~/Library is excluded")
        XCTAssertFalse(names.contains("Library/Caches/cache.db"))
        XCTAssertFalse(names.contains { $0.hasPrefix("node_modules") })
        XCTAssertFalse(names.contains { $0.hasPrefix(".") })
        XCTAssertEqual(entries[root + "/工具/Demo.app"], .package)
        XCTAssertFalse(names.contains("工具/Demo.app/Contents"), "package contents are not indexed")
        XCTAssertTrue(names.contains("工具/普通.folder/内容.txt"), "a folder with a dot is not a package")
        XCTAssertEqual(entries[root + "/捷径"], .symlink)
        XCTAssertFalse(names.contains("捷径/build"), "symlinks are not followed")
    }

    func testLegacyRulesReproduce32Misses() throws {
        try makeTree(root, sampleTree)
        let names = relativeNames(NameIndex.build(roots: [root], rules: .legacy32).allEntries(), root: root)
        XCTAssertFalse(names.contains("课程/build/讲义.pdf"))
        XCTAssertFalse(names.contains("课程/Library/书目.docx"))
        XCTAssertTrue(names.contains("readme.md"))
    }

    func testHiddenAndPackageContentsCanBeIncluded() throws {
        try makeTree(root, sampleTree)
        let rules = ExclusionRules(excludedPaths: [], excludedNames: [], includeHidden: true, indexPackageContents: true)
        let names = relativeNames(NameIndex.build(roots: [root], rules: rules).allEntries(), root: root)
        XCTAssertTrue(names.contains(".hidden/secret.txt"))
        XCTAssertTrue(names.contains("工具/Demo.app/Contents/Info.plist"))
        XCTAssertTrue(names.contains("node_modules/pkg/index.js"))
    }

    func testOverlappingRootsAreMerged() throws {
        try makeTree(root, ["a/b/c.txt"])
        let index = NameIndex.build(roots: [root + "/a", root, root + "/"], rules: .standard(home: root))
        XCTAssertEqual(index.roots, [root])
        XCTAssertEqual(index.entryCount, 3)
    }

    func testSearchFindsAndRanks() throws {
        try makeTree(root, ["合同.pdf", "资料/年度合同汇总.xlsx", "资料/other.txt", "hetong-notes.md"])
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        let names = index.ranked(index.search(["合同"])).map { index.name(of: $0.id) }
        XCTAssertEqual(names, ["合同.pdf", "年度合同汇总.xlsx"])
        let pinyin = Set(index.search(["hetong"]).map { index.name(of: $0.id) })
        XCTAssertEqual(pinyin, ["合同.pdf", "年度合同汇总.xlsx", "hetong-notes.md"])
        XCTAssertTrue(index.search([]).isEmpty)
    }

    // MARK: Incremental updates

    func testIncrementalUpdatesForCommonChanges() throws {
        try makeTree(root, ["文档/a.txt", "文档/旧名称/深层/b.txt", "照片/c.jpg"])
        let rules = ExclusionRules.standard(home: root)
        let index = NameIndex.build(roots: [root], rules: rules)
        let fileManager = FileManager.default

        try makeTree(root, ["文档/新文件.md"])
        var summary = index.apply([IndexChange(path: root + "/文档/新文件.md")])
        XCTAssertEqual(summary.added, 1)

        try fileManager.moveItem(atPath: root + "/文档/旧名称", toPath: root + "/文档/新名称")
        summary = index.apply([IndexChange(path: root + "/文档/旧名称"), IndexChange(path: root + "/文档/新名称")])
        XCTAssertEqual(summary.removed, 3)
        XCTAssertEqual(summary.added, 3)
        XCTAssertNotNil(index.id(forPath: root + "/文档/新名称/深层/b.txt"))
        XCTAssertNil(index.id(forPath: root + "/文档/旧名称/深层/b.txt"))

        try fileManager.removeItem(atPath: root + "/照片")
        index.apply([IndexChange(path: root + "/照片")])

        // A new folder nested two levels below anything indexed.
        try makeTree(root, ["新项目/子目录/文件.txt"])
        index.apply([IndexChange(path: root + "/新项目/子目录/文件.txt")])

        assertSameEntries(index.allEntries(), NameIndex.build(roots: [root], rules: rules).allEntries())
        XCTAssertEqual(Set(index.search(["文件"]).map { index.name(of: $0.id) }), ["新文件.md", "文件.txt"])
    }

    func testRescanSubtreeAndRootContentsDeleted() throws {
        try makeTree(root, ["a/b/c.txt", "a/d.txt"])
        let rules = ExclusionRules.standard(home: root)
        let index = NameIndex.build(roots: [root], rules: rules)
        // Changes FSEvents could not describe one by one.
        try makeTree(root, ["a/b/new1.txt", "a/b/e/new2.txt"])
        try FileManager.default.removeItem(atPath: root + "/a/d.txt")
        let summary = index.apply([IndexChange(path: root + "/a", rescanSubtree: true)])
        XCTAssertEqual(summary.foldersRescanned, 1)
        assertSameEntries(index.allEntries(), NameIndex.build(roots: [root], rules: rules).allEntries())

        try FileManager.default.removeItem(atPath: root + "/a")
        index.apply([IndexChange(path: root, rescanSubtree: true)])
        XCTAssertEqual(index.entryCount, 0)
    }

    func testChangesOutsideRootsAndExcludedFoldersAreIgnored() throws {
        try makeTree(root, ["Library/x.txt", "keep.txt"])
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        let generation = index.generation
        try makeTree(root, ["Library/y.txt"])
        let summary = index.apply([IndexChange(path: root + "/Library/y.txt"), IndexChange(path: "/somewhere/else.txt")])
        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(index.generation, generation)
    }

    /// 200 random edits, each followed by `apply`; the index must always equal a fresh build.
    func testRandomEditsKeepIndexEqualToFreshBuild() throws {
        try SyntheticTree.create(at: root, files: 400, seed: 3)
        let rules = ExclusionRules.standard(home: root)
        let index = NameIndex.build(roots: [root], rules: rules)
        var random = SeededRandom(seed: 99)
        let fileManager = FileManager.default

        for step in 0..<200 {
            let entries = index.allEntries()
            let files = entries.filter { $0.value.isEmpty }.map(\.key).sorted()
            let folders = entries.filter { $0.value.contains(.directory) }.map(\.key).sorted()
            let allFolders = [root] + folders
            var changed: [String] = []
            switch random.below(7) {
            case 0:
                let path = random.pick(allFolders) + "/new \(step).txt"
                fileManager.createFile(atPath: path, contents: nil)
                changed = [path]
            case 1:
                let folder = random.pick(allFolders) + "/新建文件夹 \(step)"
                try makeTree(folder, ["inner/深层 \(step).md", "浅层.txt"])
                changed = [folder]
            case 2:
                guard !files.isEmpty else { continue }
                let path = random.pick(files)
                try fileManager.removeItem(atPath: path)
                changed = [path]
            case 3:
                guard !folders.isEmpty else { continue }
                let folder = random.pick(folders)
                try fileManager.removeItem(atPath: folder)
                changed = [folder]
            case 4:
                guard !files.isEmpty else { continue }
                let path = random.pick(files)
                let target = Paths.join(Paths.parent(path), "改名 \(step) " + (path as NSString).lastPathComponent)
                try fileManager.moveItem(atPath: path, toPath: target)
                changed = [path, target]
            case 5:
                guard !folders.isEmpty else { continue }
                let folder = random.pick(folders)
                let destinations = allFolders.filter { !Paths.isWithin($0, folder) }
                guard !destinations.isEmpty else { continue }
                let target = random.pick(destinations) + "/moved \(step)"
                try fileManager.moveItem(atPath: folder, toPath: target)
                changed = [folder, target]
            default:
                guard !files.isEmpty else { continue }
                let path = random.pick(files)
                try fileManager.removeItem(atPath: path)
                try makeTree(path, ["child.txt"])
                changed = [path]
            }
            index.apply(changed.map { IndexChange(path: $0) })
            if step % 25 == 24 {
                assertSameEntries(index.allEntries(), NameIndex.build(roots: [root], rules: rules).allEntries(), "after step \(step)")
            }
        }
        index.compact()
        assertSameEntries(index.allEntries(), NameIndex.build(roots: [root], rules: rules).allEntries(), "after compact")
        XCTAssertFalse(index.search(["深层"]).isEmpty)
    }
}

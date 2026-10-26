import Foundation

/// Deterministic random numbers (SplitMix64), so every run builds the same tree.
public struct SeededRandom {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }

    public mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }

    public mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

/// Builds a realistic folder tree (Chinese and English names, nested folders,
/// folders named `build`/`Library`, hidden files, node_modules, packages).
public enum SyntheticTree {
    public static let chineseWords = ["合同", "年度报告", "讲稿", "论语", "思想史", "课程", "会议纪要", "草稿", "发票", "照片",
                                      "重庆", "音乐", "银行", "长沙", "学生名单", "期末考试", "教案", "申报书", "明清", "读书笔记"]
    public static let englishWords = ["report", "readme", "invoice", "draft", "final", "lecture", "notes", "budget", "photo", "scan",
                                      "project", "meeting", "contract", "summary", "backup", "export", "design", "plan", "thesis", "syllabus"]
    public static let extensions = ["pdf", "docx", "txt", "md", "jpg", "png", "xlsx", "pptx", "zip", "mov", "swift", "json"]
    public static let folderWords = ["Documents", "课程资料", "Projects", "研究", "Archive", "2024", "2025", "讲义", "Photos", "Downloads",
                                     "build", "Library", "src", "data", "备份", "学生作业", "Teaching", "论文", "Notes", "Misc"]

    public struct Summary {
        public var files = 0
        public var folders = 0
    }

    /// Creates about `files` files under `root` (which must exist).
    @discardableResult
    public static func create(at root: String, files: Int, seed: UInt64 = 42) throws -> Summary {
        var random = SeededRandom(seed: seed)
        var summary = Summary()
        var folders: [String] = [root]
        var created = Set<String>([root])
        let fileManager = FileManager.default

        func makeFolder(_ path: String) throws {
            if created.insert(path).inserted {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
                summary.folders += 1
                folders.append(path)
            }
        }

        func touch(_ path: String) {
            let fd = open(path, O_CREAT | O_WRONLY, 0o644)
            if fd >= 0 {
                close(fd)
                summary.files += 1
            }
        }

        let folderTarget = max(4, files / 12)
        while folders.count < folderTarget {
            let parent = random.pick(folders)
            let depth = parent.split(separator: "/").count - root.split(separator: "/").count
            if depth >= 6 { continue }
            var name = random.pick(folderWords)
            if random.chance(40) {
                let pool = random.chance(50) ? chineseWords : englishWords
                name += "-" + random.pick(pool)
            }
            try makeFolder(parent + "/" + name)
        }

        var i = 0
        while summary.files < files {
            let folder = random.pick(folders)
            let firstPool = random.chance(55) ? chineseWords : englishWords
            let first = random.pick(firstPool)
            let secondPool = random.chance(50) ? chineseWords : englishWords
            let second = random.pick(secondPool)
            let hasYear = random.chance(30)
            let year = hasYear ? " \(2018 + random.below(8))" : ""
            let separator = random.pick(["", " ", "_", "-"])
            let ext = random.pick(extensions)
            touch("\(folder)/\(first)\(separator)\(second)\(year)_\(i).\(ext)")
            i += 1
        }

        // Things the exclusion rules must handle.
        for _ in 0..<max(1, files / 2000) {
            let folder = random.pick(folders)
            try makeFolder(folder + "/node_modules/pkg")
            touch(folder + "/node_modules/pkg/index.js")
            touch(folder + "/.DS_Store")
            try makeFolder(folder + "/.cache")
            touch(folder + "/.cache/blob")
        }
        return summary
    }

    /// A fresh empty directory under the system temporary folder (canonical path).
    public static func temporaryDirectory(_ label: String) throws -> String {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("kongfetch-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        guard let resolved = realpath(base, nil) else { return base }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

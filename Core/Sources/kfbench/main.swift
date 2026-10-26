import Foundation
import KongFetchCore
import KongFetchLegacy32
import KongFetchTestSupport

// kfbench synth <folder> [files]   create a synthetic tree (default 300000 files)
// kfbench new <root>               measure KongFetchCore
// kfbench legacy <root>            measure the 3.2 code on the same tree
// Run with `swift run -c release kfbench ...`; run `new` and `legacy` as separate
// processes so their memory figures do not mix.

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func milliseconds<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

func report(_ key: String, _ value: Any) { print("\(key)\t\(value)") }

func format(_ value: Double) -> String { String(format: "%.1f", value) }

let queries: [[String]] = [["合同"], ["hetong"], ["ht"], ["report"], ["rpt"], ["readme"], ["年度", "报告"], ["lunyu"],
                           ["2024"], ["a"], ["课程资料"], ["final", "report"]]
let typing: [[String]] = ["co", "con", "cont", "contr", "contra", "contrac", "contract"].map { [$0] }

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: kfbench synth <folder> [files] | kfbench new <root> | kfbench legacy <root>")
    exit(2)
}
let command = arguments[1]
let root = Paths.canonical(arguments[2])

switch command {
case "synth":
    let files = arguments.count > 3 ? Int(arguments[3]) ?? 300_000 : 300_000
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let (summary, time) = try milliseconds { try SyntheticTree.create(at: root, files: files, seed: 2026) }
    report("synth.files", summary.files)
    report("synth.folders", summary.folders)
    report("synth.ms", format(time))

case "new":
    // Same exclusions as 3.2 so both sides index the same entries.
    let base = footprintMB()
    let (index, buildTime) = milliseconds { NameIndex.build(roots: [root], rules: .legacy32) }
    report("new.build.ms", format(buildTime))
    report("new.entries", index.entryCount)
    report("new.folders", index.directoryCount)
    report("new.memory.mb", format(footprintMB() - base))

    let file = URL(fileURLWithPath: NSTemporaryDirectory() + "kfbench-\(getpid()).kfidx")
    let (_, saveTime) = try milliseconds { try index.save(to: file) }
    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    let (loaded, loadTime) = try milliseconds { try NameIndex.load(from: file) }
    try? FileManager.default.removeItem(at: file)
    report("new.save.ms", format(saveTime))
    report("new.file.mb", format(Double(size) / 1_048_576))
    report("new.load.ms", format(loadTime))
    report("new.loaded.entries", loaded.entryCount)

    for precision in MatchPrecision.allCases {
        for words in queries {
            var times: [Double] = []
            var hits = 0
            for _ in 0..<5 {
                let (result, time) = milliseconds { index.search(words, precision: precision) }
                times.append(time)
                hits = result.count
            }
            report("new.query.\(precision).\(words.joined(separator: "+"))", "\(format(median(times))) ms, \(hits) hits")
        }
    }
    let session = SearchSession(index: index)
    let (_, typedWithSession) = milliseconds { for words in typing { _ = session.search(words) } }
    let (_, typedWithout) = milliseconds { for words in typing { _ = index.search(words) } }
    report("new.typing.session.ms", format(typedWithSession))
    report("new.typing.full.ms", format(typedWithout))

    let standard = NameIndex.build(roots: [root], rules: .standard(home: root))
    report("new.standardRules.entries", standard.entryCount)

case "legacy":
    let base = footprintMB()
    let (catalog, scanTime) = milliseconds {
        scanNames([URL(fileURLWithPath: root)], excluding: [], cancelled: { false })
    }
    report("legacy.build.ms", format(scanTime))
    report("legacy.entries", catalog.urls.count)
    report("legacy.memory.mb", format(footprintMB() - base))

    // 3.2 stored the catalog as JSON: StoredCatalog(version, roots, paths, ...).
    struct Stored: Codable { let version: Int; let roots: [String]; let paths: [String] }
    let file = URL(fileURLWithPath: NSTemporaryDirectory() + "kfbench-\(getpid()).json")
    let (_, saveTime) = try milliseconds {
        try JSONEncoder().encode(Stored(version: 1, roots: [root], paths: catalog.urls.map(\.path))).write(to: file, options: .atomic)
    }
    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    let (restored, loadTime) = try milliseconds {
        try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file)).paths.map { URL(fileURLWithPath: $0) }
    }
    try? FileManager.default.removeItem(at: file)
    report("legacy.save.ms", format(saveTime))
    report("legacy.file.mb", format(Double(size) / 1_048_576))
    report("legacy.load.ms", format(loadTime))
    report("legacy.loaded.entries", restored.count)

    // Scoring only (3.2 additionally built an Entry with resource values per match),
    // so these figures flatter 3.2.
    for precision in [Legacy32Precision.fuzzyName, .withPath] {
        for words in queries {
            let (hits, time) = milliseconds { catalog.urls.reduce(0) { $0 + (precision.score($1, words: words) == nil ? 0 : 1) } }
            report("legacy.query.\(precision).\(words.joined(separator: "+"))", "\(format(time)) ms, \(hits) hits")
        }
    }
    let (_, typed) = milliseconds {
        for words in typing { _ = catalog.urls.reduce(0) { $0 + (Legacy32Precision.fuzzyName.score($1, words: words) == nil ? 0 : 1) } }
    }
    report("legacy.typing.full.ms", format(typed))

default:
    print("unknown command \(command)")
    exit(2)
}

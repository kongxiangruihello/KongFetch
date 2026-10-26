import XCTest
@testable import KongFetchCore
import KongFetchTestSupport

/// Creates files and folders below `root`; a trailing "/" makes a folder.
func makeTree(_ root: String, _ items: [String]) throws {
    let fileManager = FileManager.default
    for item in items {
        let path = root + "/" + item
        if item.hasSuffix("/") {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        } else {
            try fileManager.createDirectory(atPath: Paths.parent(path), withIntermediateDirectories: true)
            XCTAssertTrue(fileManager.createFile(atPath: path, contents: nil), path)
        }
    }
}

/// Compares two index snapshots and reports the differing paths.
func assertSameEntries(_ actual: [String: EntryFlags], _ expected: [String: EntryFlags], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard actual != expected else { return }
    let missing = Set(expected.keys).subtracting(actual.keys).sorted()
    let extra = Set(actual.keys).subtracting(expected.keys).sorted()
    let wrongKind = Set(actual.keys).intersection(expected.keys).filter { actual[$0] != expected[$0] }.sorted()
    XCTFail("\(message) missing \(missing.count): \(missing.prefix(5)); extra \(extra.count): \(extra.prefix(5)); wrong kind: \(wrongKind.prefix(5))", file: file, line: line)
}

func relativeNames(_ entries: [String: EntryFlags], root: String) -> Set<String> {
    Set(entries.keys.map { String($0.dropFirst(root.count + 1)) })
}

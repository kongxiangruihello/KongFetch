#if canImport(CoreServices)
import XCTest
@testable import KongFetchCore
import KongFetchTestSupport

/// Uses real FSEvents, so these tests take a few seconds.
final class WatcherTests: XCTestCase {
    private var root = ""
    private let queue = DispatchQueue(label: "kongfetch.watcher-tests")

    override func setUpWithError() throws {
        root = try SyntheticTree.temporaryDirectory("watch")
        try makeTree(root, ["已有/a.txt", "已有/待删除.txt", "其他/b.md"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func testLiveEventsKeepIndexCurrent() throws {
        let rules = ExclusionRules.standard(home: root)
        let index = NameIndex.build(roots: [root], rules: rules)
        let target = root + "/已有/实时新增.txt"
        let seen = expectation(description: "new file indexed")
        seen.assertForOverFulfill = false
        let watcher = FileChangeWatcher(paths: [root], latency: 0.1, queue: queue) { batch in
            index.apply(batch.changes, eventID: batch.lastEventID)
            if index.id(forPath: target) != nil { seen.fulfill() }
        }
        XCTAssertTrue(watcher.start())
        Thread.sleep(forTimeInterval: 0.3)
        try makeTree(root, ["已有/实时新增.txt"])
        wait(for: [seen], timeout: 10)
        watcher.stop()
        queue.sync {
            XCTAssertGreaterThan(index.lastEventID, 0)
            assertSameEntries(index.allEntries(), NameIndex.build(roots: [root], rules: rules).allEntries())
        }
    }

    /// The point of saving `lastEventID`: changes made while KongFetch was not
    /// running are replayed on the next start, with no full rescan.
    func testResumeReplaysChangesMadeWhileNotWatching() throws {
        let rules = ExclusionRules.standard(home: root)
        let index = NameIndex.build(roots: [root], rules: rules)
        let since = FileChangeWatcher.currentEventID

        try makeTree(root, ["离线新增/深层/c.txt", "已有/离线文件.md"])
        try FileManager.default.removeItem(atPath: root + "/已有/待删除.txt")
        try FileManager.default.moveItem(atPath: root + "/其他", toPath: root + "/其他-改名")
        Thread.sleep(forTimeInterval: 1.5) // let FSEvents record the events

        let replayed = expectation(description: "history replayed")
        replayed.assertForOverFulfill = false
        let watcher = FileChangeWatcher(paths: [root], since: since, latency: 0.1, queue: queue) { batch in
            index.apply(batch.changes, eventID: batch.lastEventID)
            if batch.historyDone { replayed.fulfill() }
        }
        XCTAssertTrue(watcher.start())
        wait(for: [replayed], timeout: 15)
        watcher.stop()
        queue.sync {
            XCTAssertGreaterThan(index.lastEventID, since)
            assertSameEntries(index.allEntries(), NameIndex.build(roots: [root], rules: rules).allEntries(), "after replay")
        }
    }

    func testEventDatabaseIdentityIsAvailable() {
        XCTAssertNotNil(FileChangeWatcher.eventDatabaseUUID(forPath: root))
    }
}
#endif

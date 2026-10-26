import Foundation

public struct EntryFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let directory = EntryFlags(rawValue: 1 << 0)
    public static let package = EntryFlags(rawValue: 1 << 1)
    public static let symlink = EntryFlags(rawValue: 1 << 2)
    public static let root = EntryFlags(rawValue: 1 << 3)
    public static let deleted = EntryFlags(rawValue: 1 << 4)
    /// The folded name is pure ASCII (fast scoring path).
    public static let asciiName = EntryFlags(rawValue: 1 << 5)

    /// The flags that describe what kind of item an entry is.
    public static let kindMask: EntryFlags = [.directory, .package, .symlink]
}

public struct SearchHit: Hashable, Sendable {
    public let id: Int32
    public let score: Int
}

/// A changed path reported by FSEvents (or a test).
public struct IndexChange: Hashable, Sendable {
    public var path: String
    /// FSEvents asked for a full rescan below `path` (dropped events, MustScanSubDirs).
    public var rescanSubtree: Bool

    public init(path: String, rescanSubtree: Bool = false) {
        self.path = path
        self.rescanSubtree = rescanSubtree
    }
}

public struct UpdateSummary: Equatable, Sendable {
    public var added = 0
    public var removed = 0
    public var foldersResynced = 0
    public var foldersRescanned = 0
}

public struct BuildProgress: Sendable {
    public var entries: Int
    public var currentFolder: String
}

/// In-memory index of file and folder names under a set of roots.
///
/// Storage is columnar: every name lives in one shared byte array (`ByteColumn`),
/// with parallel arrays for parent, flags and the precomputed search keys
/// (folded name, extension boundary, pinyin). Search scans these arrays on all
/// cores without creating per-file objects. Not thread-safe: mutate and search
/// from one queue (search itself fans out internally).
public final class NameIndex {
    public internal(set) var roots: [String]
    public internal(set) var rules: ExclusionRules
    /// Last FSEvents event already reflected in the index; resume from here.
    public var lastEventID: UInt64 = 0
    /// FSEvents database identity for the roots' volume; a different value means
    /// the event history was reset and the index must be rebuilt.
    public var eventDatabaseUUID: String?
    public internal(set) var updated = Date()
    /// False when a build was cancelled before all roots were scanned.
    public internal(set) var isComplete = true
    /// Increases on every change; search sessions use it to drop stale results.
    public internal(set) var generation = 0
    public internal(set) var unreadableCount = 0
    public internal(set) var unreadableSamples: [String] = []

    // Columns, indexed by entry id.
    var names = ByteColumn()
    var folded = ByteColumn()
    var pinyinFull = ByteColumn()
    var pinyinInitials = ByteColumn()
    var stemLengths: [UInt16] = []
    var parents: [Int32] = []
    var flags: [UInt8] = []
    var deletedCount = 0
    /// Folded names, pinyin and stem lengths exist for every entry.
    var derivedReady = false

    // Folder tables, rebuilt from the columns after loading or compacting.
    var directoryPaths: [Int32: String] = [:]
    var directoryIDs: [String: Int32] = [:]
    var children: [Int32: [Int32]] = [:]
    var foldedDirectoryPaths: [Int32: [UInt8]] = [:]
    var rootIDs: [Int32] = []

    init(roots: [String], rules: ExclusionRules) {
        self.roots = roots
        self.rules = rules
    }

    // MARK: - Building

    /// Scans `roots` and returns a complete index (or a partial one if cancelled).
    public static func build(
        roots rawRoots: [String],
        rules: ExclusionRules = .standard(),
        progress: ((BuildProgress) -> Void)? = nil,
        throttle: (() -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> NameIndex {
        var seen = Set<String>()
        var canonicalRoots: [String] = []
        for root in rawRoots.map(Paths.canonical) where seen.insert(root).inserted { canonicalRoots.append(root) }
        // A root inside another root would index the same files twice.
        canonicalRoots = canonicalRoots.filter { root in !canonicalRoots.contains { $0 != root && Paths.isWithin(root, $0) } }

        let index = NameIndex(roots: canonicalRoots, rules: rules)
        let compiled = rules.compiled()
        for root in canonicalRoots where !compiled.paths.contains(root) {
            let id = index.appendEntry(name: root, parent: -1, flags: [.directory, .root], deriveInline: false)
            if !index.scanSubtree(of: id, rules: compiled, progress: progress, throttle: throttle, isCancelled: isCancelled) {
                index.isComplete = false
                break
            }
        }
        index.computeDerivedColumns()
        index.updated = Date()
        return index
    }

    /// Depth-first scan below an indexed folder. Returns false if cancelled.
    @discardableResult
    func scanSubtree(
        of startID: Int32,
        rules: CompiledExclusions,
        progress: ((BuildProgress) -> Void)? = nil,
        throttle: (() -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> Bool {
        var stack: [Int32] = [startID]
        var lastReported = flags.count
        while let directoryID = stack.popLast() {
            if isCancelled() { return false }
            throttle?()
            guard let path = directoryPaths[directoryID] else { continue }
            guard let items = DirectoryReader.children(of: path) else {
                noteUnreadable(path)
                continue
            }
            for item in items {
                let childPath = Paths.join(path, item.name)
                if rules.skips(name: item.name, path: childPath) { continue }
                let kind = Self.classify(item, path: childPath, rules: rules)
                let id = appendEntry(name: item.name, parent: directoryID, flags: kind, deriveInline: derivedReady)
                if kind.contains(.directory) { stack.append(id) }
            }
            if let progress, flags.count - lastReported >= 8192 {
                lastReported = flags.count
                progress(BuildProgress(entries: flags.count - deletedCount, currentFolder: path))
            }
        }
        return true
    }

    static func classify(_ item: DirectoryChild, path: String, rules: CompiledExclusions) -> EntryFlags {
        switch item.kind {
        case .file: return []
        case .symlink: return [.symlink]
        case .directory:
            if DirectoryReader.isPackage(name: item.name, path: path) {
                return rules.indexPackageContents ? [.directory, .package] : [.package]
            }
            return [.directory]
        }
    }

    private func noteUnreadable(_ path: String) {
        unreadableCount += 1
        if unreadableSamples.count < 20 { unreadableSamples.append(path) }
    }

    @discardableResult
    func appendEntry(name: String, parent: Int32, flags kind: EntryFlags, deriveInline: Bool) -> Int32 {
        let id = Int32(flags.count)
        names.append(name)
        parents.append(parent)
        flags.append(kind.rawValue)
        if kind.contains(.directory) || kind.contains(.root) {
            let path = parent < 0 ? name : Paths.join(directoryPaths[parent] ?? "", name)
            directoryPaths[id] = path
            directoryIDs[path] = id
            children[id] = []
            if kind.contains(.root) { rootIDs.append(id) }
        }
        if parent >= 0 { children[parent, default: []].append(id) }
        if deriveInline { appendDerived(for: id) }
        return id
    }

    // MARK: - Derived search keys

    struct Derived {
        var folded: String
        var stemLength: UInt16
        var pinyinFull: String
        var pinyinInitials: String
        var ascii: Bool
    }

    /// Search keys for one name: folded name, folded length of the name without
    /// extension (3.2 compares both against the whole query), and pinyin forms.
    static func derive(name: String, isRoot: Bool) -> Derived {
        let foldedName = SearchText.fold(name)
        let foldedCount = foldedName.utf8.count
        var stemLength = foldedCount
        var stem = name
        if !isRoot {
            stem = (name as NSString).deletingPathExtension
            let nameBytes = name.utf8.count, stemBytes = stem.utf8.count
            if stemBytes < nameBytes {
                let suffix = name.utf8.suffix(nameBytes - stemBytes)
                // Folding never changes the length of ASCII, so an ASCII extension
                // can be subtracted instead of folding the stem a second time.
                stemLength = suffix.allSatisfy({ $0 < 0x80 }) ? foldedCount - suffix.count : SearchText.fold(stem).utf8.count
            }
        }
        let forms = isRoot ? [] : Pinyin.forms(stem)
        return Derived(
            folded: foldedName,
            stemLength: UInt16(clamping: max(0, stemLength)),
            pinyinFull: forms.first ?? "",
            pinyinInitials: forms.count > 1 ? forms[1] : "",
            ascii: foldedName.utf8.allSatisfy { $0 < 0x80 }
        )
    }

    private func appendDerived(for id: Int32) {
        let i = Int(id)
        let derived = Self.derive(name: names.string(at: i), isRoot: flags[i] & EntryFlags.root.rawValue != 0)
        folded.append(derived.folded)
        pinyinFull.append(derived.pinyinFull)
        pinyinInitials.append(derived.pinyinInitials)
        stemLengths.append(derived.stemLength)
        if derived.ascii { flags[i] |= EntryFlags.asciiName.rawValue }
        if flags[i] & (EntryFlags.directory.rawValue | EntryFlags.root.rawValue) != 0 {
            foldedDirectoryPaths[id] = foldedDirectoryPath(for: id)
        }
    }

    private func foldedDirectoryPath(for id: Int32) -> [UInt8] {
        let i = Int(id)
        let own = folded.byteArray(at: i)
        let parent = parents[i]
        guard parent >= 0, let base = foldedDirectoryPaths[parent] else { return own }
        return base == [0x2F] ? base + own : base + [0x2F] + own
    }

    /// Computes the search keys for all entries on all cores (pinyin
    /// transliteration is the slow part, so it is kept out of the disk scan).
    func computeDerivedColumns() {
        final class Chunk {
            var folded = ByteColumn()
            var full = ByteColumn()
            var initials = ByteColumn()
            var stems: [UInt16] = []
            var ascii: [Bool] = []
        }
        let total = flags.count
        let chunkSize = 4096
        let chunkCount = max(1, (total + chunkSize - 1) / chunkSize)
        let chunks = (0..<chunkCount).map { _ in Chunk() }
        let nameSnapshot = names
        let flagSnapshot = flags
        DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
            let chunk = chunks[c]
            let start = c * chunkSize, end = min(total, start + chunkSize)
            guard start < end else { return }
            for i in start..<end {
                let d = NameIndex.derive(name: nameSnapshot.string(at: i), isRoot: flagSnapshot[i] & EntryFlags.root.rawValue != 0)
                chunk.folded.append(d.folded)
                chunk.full.append(d.pinyinFull)
                chunk.initials.append(d.pinyinInitials)
                chunk.stems.append(d.stemLength)
                chunk.ascii.append(d.ascii)
            }
        }
        folded = ByteColumn()
        pinyinFull = ByteColumn()
        pinyinInitials = ByteColumn()
        stemLengths = []
        stemLengths.reserveCapacity(total)
        var i = 0
        for chunk in chunks {
            folded.append(contentsOf: chunk.folded)
            pinyinFull.append(contentsOf: chunk.full)
            pinyinInitials.append(contentsOf: chunk.initials)
            stemLengths.append(contentsOf: chunk.stems)
            for ascii in chunk.ascii {
                if ascii { flags[i] |= EntryFlags.asciiName.rawValue }
                i += 1
            }
        }
        derivedReady = true
        rebuildFoldedDirectoryPaths()
    }

    func rebuildFoldedDirectoryPaths() {
        foldedDirectoryPaths = [:]
        let folderMask = EntryFlags.directory.rawValue | EntryFlags.root.rawValue
        for i in 0..<flags.count where flags[i] & folderMask != 0 && flags[i] & EntryFlags.deleted.rawValue == 0 {
            foldedDirectoryPaths[Int32(i)] = foldedDirectoryPath(for: Int32(i))
        }
    }

    /// Rebuilds folder paths, child lists and root ids from the columns.
    /// Relies on parents always having smaller ids than their children.
    func rebuildDirectoryTables() {
        directoryPaths = [:]
        directoryIDs = [:]
        children = [:]
        rootIDs = []
        for i in 0..<flags.count {
            let flag = flags[i]
            if flag & EntryFlags.deleted.rawValue != 0 { continue }
            let id = Int32(i)
            let parent = parents[i]
            if parent >= 0 { children[parent, default: []].append(id) }
            if flag & (EntryFlags.directory.rawValue | EntryFlags.root.rawValue) != 0 {
                let name = names.string(at: i)
                let path = parent < 0 ? name : Paths.join(directoryPaths[parent] ?? "", name)
                directoryPaths[id] = path
                directoryIDs[path] = id
                if children[id] == nil { children[id] = [] }
                if flag & EntryFlags.root.rawValue != 0 { rootIDs.append(id) }
            }
        }
        rebuildFoldedDirectoryPaths()
    }

    // MARK: - Reading

    /// Files and folders in the index, not counting the roots.
    public var entryCount: Int { flags.count - deletedCount - rootIDs.count }
    public var directoryCount: Int { directoryPaths.count - rootIDs.count }

    public func name(of id: Int32) -> String { names.string(at: Int(id)) }

    public func flags(of id: Int32) -> EntryFlags { EntryFlags(rawValue: flags[Int(id)]) }

    public func path(of id: Int32) -> String {
        let i = Int(id)
        let parent = parents[i]
        if parent < 0 { return names.string(at: i) }
        return Paths.join(directoryPaths[parent] ?? "", names.string(at: i))
    }

    /// Every live entry (roots excluded) with its kind; used by tests and diagnostics.
    public func allEntries() -> [String: EntryFlags] {
        var result: [String: EntryFlags] = [:]
        result.reserveCapacity(entryCount)
        for i in 0..<flags.count {
            let flag = EntryFlags(rawValue: flags[i])
            if flag.contains(.deleted) || flag.contains(.root) { continue }
            result[path(of: Int32(i))] = flag.intersection(.kindMask)
        }
        return result
    }

    /// Ids of every live entry (roots excluded), in index order.
    public func liveEntryIDs() -> [Int32] {
        let skip = EntryFlags.deleted.rawValue | EntryFlags.root.rawValue
        return (0..<flags.count).compactMap { flags[$0] & skip == 0 ? Int32($0) : nil }
    }

    public func id(forPath rawPath: String) -> Int32? {
        let path = Paths.canonical(rawPath)
        if let id = directoryIDs[path] { return id }
        guard let parent = directoryIDs[Paths.parent(path)] else { return nil }
        let name = (path as NSString).lastPathComponent
        return children[parent]?.first { names.string(at: Int($0)) == name }
    }

    // MARK: - Search

    /// All entries matching every word, scored exactly as 3.2 scores them for the
    /// given precision. Pass `candidates` to search only a previous result set.
    public func search(_ rawWords: [String], precision: MatchPrecision = .fuzzyName, within candidates: [Int32]? = nil) -> [SearchHit] {
        let words = rawWords.filter { !$0.isEmpty }
        guard !words.isEmpty, derivedReady else { return [] }
        let prepared = words.map(PreparedWord.init)
        let gates = prepared.map(\.gate)
        let phrase = PreparedWord(words.joined(separator: " "))
        let buffers = QueryBuffers(prepared.map(\.bytes) + [phrase.bytes])
        let wordCount = words.count
        let total = candidates?.count ?? flags.count
        guard total > 0 else { return [] }
        let chunkSize = 8192
        let chunkCount = (total + chunkSize - 1) / chunkSize
        var partial = [[SearchHit]](repeating: [], count: chunkCount)
        let folderPaths = foldedDirectoryPaths
        let skipMask = EntryFlags.deleted.rawValue | EntryFlags.root.rawValue
        let asciiBit = EntryFlags.asciiName.rawValue
        let exactScore = 2000 * wordCount
        let candidateList = candidates ?? []
        let useCandidates = candidates != nil

        withExtendedLifetime(buffers) {
            folded.withView { nameView in
            pinyinFull.withView { fullView in
            pinyinInitials.withView { initialsView in
            parents.withUnsafeBufferPointer { parentPointer in
            flags.withUnsafeBufferPointer { flagPointer in
            stemLengths.withUnsafeBufferPointer { stemPointer in
            candidateList.withUnsafeBufferPointer { candidatePointer in
            partial.withUnsafeMutableBufferPointer { output in
                let phraseBytes = buffers.buffer(wordCount)
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    var hits: [SearchHit] = []
                    // Folder-path scores are the same for all files in a folder, and
                    // entries of one folder are contiguous, so remember the last one.
                    var memoParent: Int32 = -2
                    var memoDone = [Bool](repeating: false, count: wordCount)
                    var memoScore = [Int?](repeating: nil, count: wordCount)
                    var parentBytes: [UInt8] = []
                    var parentASCII = true
                    let start = chunk * chunkSize, end = min(total, start + chunkSize)
                    for position in start..<end {
                        let id = useCandidates ? Int(candidatePointer[position]) : position
                        let flag = flagPointer[id]
                        if flag & skipMask != 0 { continue }
                        let name = nameView[id]
                        let stem = UnsafeBufferPointer(rebasing: name[0..<min(name.count, Int(stemPointer[id]))])
                        if ByteMatch.equals(name, phraseBytes) || ByteMatch.equals(stem, phraseBytes) {
                            hits.append(SearchHit(id: Int32(id), score: exactScore))
                            continue
                        }
                        if precision == .exactName { continue }
                        let nameASCII = flag & asciiBit != 0
                        var score = 0
                        var matched = true
                        for w in 0..<wordCount {
                            let gate = gates[w]
                            let wordBytes = buffers.buffer(w)
                            if let s = Scoring.fuzzy(name, textIsASCII: nameASCII, allowsSubsequence: gate.allowsSubsequence, wordBytes: wordBytes) {
                                score += s + 200
                                continue
                            }
                            if precision == .withPath {
                                if gate.allowsPathMatch {
                                    let parent = parentPointer[id]
                                    if parent != memoParent {
                                        memoParent = parent
                                        for k in 0..<wordCount { memoDone[k] = false }
                                        parentBytes = folderPaths[parent] ?? []
                                        parentASCII = parentBytes.allSatisfy { $0 < 0x80 }
                                    }
                                    if !memoDone[w] {
                                        memoDone[w] = true
                                        memoScore[w] = parentBytes.withUnsafeBufferPointer {
                                            Scoring.fuzzy($0, textIsASCII: parentASCII, allowsSubsequence: gate.allowsSubsequence, wordBytes: wordBytes)
                                        }
                                    }
                                    if let s = memoScore[w] {
                                        score += min(350, s / 2)
                                        continue
                                    }
                                }
                                if gate.allowsPathModePinyin,
                                   let s = Scoring.pinyin(full: fullView[id], initials: initialsView[id], allowsPinyin: true, wordBytes: wordBytes) {
                                    score += min(600, s)
                                    continue
                                }
                            } else if let s = Scoring.pinyin(full: fullView[id], initials: initialsView[id], allowsPinyin: gate.allowsPinyin, wordBytes: wordBytes) {
                                score += s
                                continue
                            }
                            matched = false
                            break
                        }
                        if matched { hits.append(SearchHit(id: Int32(id), score: score)) }
                    }
                    output[chunk] = hits
                }
            }}}}}}}}
        }
        return partial.flatMap { $0 }
    }

    /// Highest score first; equal scores keep index order (folder by folder).
    public func ranked(_ hits: [SearchHit], limit: Int? = nil) -> [SearchHit] {
        let sorted = hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        if let limit, sorted.count > limit { return Array(sorted.prefix(limit)) }
        return sorted
    }
}

/// Query words copied into stable buffers for the duration of one search.
final class QueryBuffers {
    private let storage: [UnsafeMutableBufferPointer<UInt8>]
    private let lengths: [Int]

    init(_ arrays: [[UInt8]]) {
        lengths = arrays.map(\.count)
        storage = arrays.map { array in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(1, array.count))
            _ = buffer.initialize(from: array)
            return buffer
        }
    }

    @inline(__always)
    func buffer(_ index: Int) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: storage[index][0..<lengths[index]])
    }

    deinit {
        for buffer in storage { buffer.deallocate() }
    }
}

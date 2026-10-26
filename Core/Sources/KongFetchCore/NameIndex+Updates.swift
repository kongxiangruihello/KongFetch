import Foundation

extension NameIndex {
    /// Applies a batch of changed paths. Each changed path makes its folder be
    /// re-read (one directory listing) and compared with the index; a folder that
    /// appeared is scanned, one that disappeared is removed with its contents.
    /// `rescanSubtree` changes rebuild everything below the path.
    /// Cost depends on the folders touched, not on the size of the index.
    @discardableResult
    public func apply(_ changes: [IndexChange], eventID: UInt64? = nil) -> UpdateSummary {
        var summary = UpdateSummary()
        let compiled = rules.compiled()
        var subtreeTargets = Set<Int32>()
        var shallowTargets = Set<Int32>()

        for change in changes {
            let path = Paths.canonical(change.path)
            guard roots.contains(where: { Paths.isWithin(path, $0) }) else { continue }
            if change.rescanSubtree {
                if let id = nearestIndexedFolder(path) { subtreeTargets.insert(id) }
            } else {
                // A changed root is re-read itself; anything else through its parent folder.
                let anchor = roots.contains(path) ? path : Paths.parent(path)
                if let id = nearestIndexedFolder(anchor) { shallowTargets.insert(id) }
            }
        }

        // Full rescans first; skip those already covered by a rescan above them.
        let minimalSubtrees = subtreeTargets.filter { target in
            !ancestors(of: target).contains(where: subtreeTargets.contains)
        }
        for target in minimalSubtrees.sorted() where !isDeleted(target) {
            summary.removed += removeChildren(of: target)
            if let path = directoryPaths[target], DirectoryReader.children(of: path) != nil || isRoot(target) {
                let before = flags.count
                scanSubtree(of: target, rules: compiled)
                summary.added += flags.count - before
                summary.foldersRescanned += 1
            } else {
                // The folder itself is gone: let its parent drop it.
                shallowTargets.insert(parents[Int(target)])
            }
        }

        var queue = shallowTargets.sorted()
        var visited = Set<Int32>()
        while let folder = queue.popLast() {
            guard visited.insert(folder).inserted, !isDeleted(folder) else { continue }
            if minimalSubtrees.contains(folder) || ancestors(of: folder).contains(where: minimalSubtrees.contains) { continue }
            if !resync(folder, rules: compiled, summary: &summary) {
                let parent = parents[Int(folder)]
                if parent >= 0 { queue.append(parent) }
            }
        }

        if let eventID { lastEventID = max(lastEventID, eventID) }
        if summary.added > 0 || summary.removed > 0 {
            generation += 1
            updated = Date()
        }
        if deletedCount > 50_000 && deletedCount * 4 > flags.count { compact() }
        return summary
    }

    /// Re-reads one folder and reconciles its direct children.
    /// Returns false when the folder itself no longer exists.
    private func resync(_ folder: Int32, rules: CompiledExclusions, summary: inout UpdateSummary) -> Bool {
        guard let path = directoryPaths[folder] else { return true }
        guard let items = DirectoryReader.children(of: path) else {
            if isRoot(folder) {
                summary.removed += removeChildren(of: folder)
                return true
            }
            return false
        }
        summary.foldersResynced += 1
        var existing: [String: Int32] = [:]
        for child in children[folder] ?? [] { existing[names.string(at: Int(child))] = child }

        for item in items {
            let childPath = Paths.join(path, item.name)
            if rules.skips(name: item.name, path: childPath) { continue }
            let kind = Self.classify(item, path: childPath, rules: rules)
            if let old = existing.removeValue(forKey: item.name) {
                if EntryFlags(rawValue: flags[Int(old)]).intersection(.kindMask) == kind { continue }
                summary.removed += removeSubtree(old)
            }
            let before = flags.count
            let id = appendEntry(name: item.name, parent: folder, flags: kind, deriveInline: true)
            if kind.contains(.directory) { scanSubtree(of: id, rules: rules) }
            summary.added += flags.count - before
        }
        for (_, old) in existing { summary.removed += removeSubtree(old) }
        return true
    }

    func nearestIndexedFolder(_ path: String) -> Int32? {
        var current = path
        while true {
            if let id = directoryIDs[current], !isDeleted(id) { return id }
            guard roots.contains(where: { Paths.isWithin(current, $0) }) else { return nil }
            let up = Paths.parent(current)
            if up == current { return nil }
            current = up
        }
    }

    private func ancestors(of id: Int32) -> [Int32] {
        var result: [Int32] = []
        var current = parents[Int(id)]
        while current >= 0 {
            result.append(current)
            current = parents[Int(current)]
        }
        return result
    }

    func isDeleted(_ id: Int32) -> Bool { flags[Int(id)] & EntryFlags.deleted.rawValue != 0 }
    func isRoot(_ id: Int32) -> Bool { flags[Int(id)] & EntryFlags.root.rawValue != 0 }

    private func removeChildren(of folder: Int32) -> Int {
        var removed = 0
        for child in children[folder] ?? [] { removed += removeSubtree(child) }
        return removed
    }

    /// Marks an entry and everything below it deleted. Space is reclaimed by `compact()`.
    @discardableResult
    func removeSubtree(_ id: Int32) -> Int {
        let parent = parents[Int(id)]
        if parent >= 0 { children[parent]?.removeAll { $0 == id } }
        var stack = [id]
        var removed = 0
        while let current = stack.popLast() {
            let i = Int(current)
            if flags[i] & EntryFlags.deleted.rawValue != 0 { continue }
            flags[i] |= EntryFlags.deleted.rawValue
            deletedCount += 1
            removed += 1
            if let kids = children.removeValue(forKey: current) { stack.append(contentsOf: kids) }
            if let path = directoryPaths.removeValue(forKey: current) {
                directoryIDs.removeValue(forKey: path)
                foldedDirectoryPaths.removeValue(forKey: current)
            }
        }
        return removed
    }

    /// Drops deleted entries and renumbers the rest (ids change; sessions reset).
    public func compact() {
        guard deletedCount > 0 else { return }
        let total = flags.count
        var remap = [Int32](repeating: -1, count: total)
        var newNames = ByteColumn(), newFolded = ByteColumn(), newFull = ByteColumn(), newInitials = ByteColumn()
        var newParents: [Int32] = [], newFlags: [UInt8] = [], newStems: [UInt16] = []
        let live = total - deletedCount
        newNames.reserve(entries: live, bytes: names.bytes.count)
        newFolded.reserve(entries: live, bytes: folded.bytes.count)
        newParents.reserveCapacity(live)
        newFlags.reserveCapacity(live)
        newStems.reserveCapacity(live)
        for i in 0..<total where flags[i] & EntryFlags.deleted.rawValue == 0 {
            remap[i] = Int32(newFlags.count)
            let parent = parents[i]
            newParents.append(parent < 0 ? -1 : remap[Int(parent)])
            newFlags.append(flags[i])
            newNames.append(from: names, at: i)
            if derivedReady {
                newFolded.append(from: folded, at: i)
                newFull.append(from: pinyinFull, at: i)
                newInitials.append(from: pinyinInitials, at: i)
                newStems.append(stemLengths[i])
            }
        }
        names = newNames
        parents = newParents
        flags = newFlags
        if derivedReady {
            folded = newFolded
            pinyinFull = newFull
            pinyinInitials = newInitials
            stemLengths = newStems
        }
        deletedCount = 0
        generation += 1
        rebuildDirectoryTables()
    }
}

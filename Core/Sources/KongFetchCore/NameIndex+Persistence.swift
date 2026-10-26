import Foundation

public enum IndexStoreError: Error, Equatable {
    case notAnIndex
    case unsupportedVersion(UInt32)
    case corrupt
}

/// Binary index file: a small header followed by the raw columns, so loading is
/// a few large memory copies instead of decoding one JSON string per path (3.2).
extension NameIndex {
    static let fileMagic: UInt32 = 0x4B46_4E49 // "KFNI"
    public static let fileFormatVersion: UInt32 = 1

    /// Writes the index atomically (compacting it first).
    public func save(to url: URL) throws {
        compact()
        var writer = BinaryWriter()
        writer.u32(Self.fileMagic)
        writer.u32(Self.fileFormatVersion)
        writer.u64(lastEventID)
        writer.u64(updated.timeIntervalSince1970.bitPattern)
        writer.u8(isComplete ? 1 : 0)
        writer.optionalString(eventDatabaseUUID)
        writer.u32(UInt32(roots.count))
        for root in roots { writer.string(root) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        writer.blob(try encoder.encode(rules))
        writer.u64(UInt64(unreadableCount))
        writer.u32(UInt32(unreadableSamples.count))
        for sample in unreadableSamples { writer.string(sample) }
        writer.array(parents)
        writer.array(flags)
        writer.array(stemLengths)
        for column in [names, folded, pinyinFull, pinyinInitials] {
            writer.array(column.offsets)
            writer.array(column.bytes)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer.data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> NameIndex {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try data.withUnsafeBytes { raw -> NameIndex in
            var reader = BinaryReader(base: raw)
            guard try reader.u32() == fileMagic else { throw IndexStoreError.notAnIndex }
            let version = try reader.u32()
            guard version == fileFormatVersion else { throw IndexStoreError.unsupportedVersion(version) }
            let lastEventID = try reader.u64()
            let updated = Date(timeIntervalSince1970: Double(bitPattern: try reader.u64()))
            let isComplete = try reader.u8() == 1
            let uuid = try reader.optionalString()
            var roots: [String] = []
            let rootCount = Int(try reader.u32())
            for _ in 0..<rootCount { roots.append(try reader.string()) }
            let rules = try JSONDecoder().decode(ExclusionRules.self, from: try reader.blob())
            let unreadableCount = Int(try reader.u64())
            var samples: [String] = []
            let sampleCount = Int(try reader.u32())
            for _ in 0..<sampleCount { samples.append(try reader.string()) }

            let index = NameIndex(roots: roots, rules: rules)
            index.lastEventID = lastEventID
            index.updated = updated
            index.isComplete = isComplete
            index.eventDatabaseUUID = uuid
            index.unreadableCount = unreadableCount
            index.unreadableSamples = samples
            index.parents = try reader.array(Int32.self)
            index.flags = try reader.array(UInt8.self)
            index.stemLengths = try reader.array(UInt16.self)
            var columns: [ByteColumn] = []
            for _ in 0..<4 {
                var column = ByteColumn()
                column.offsets = try reader.array(UInt32.self)
                column.bytes = try reader.array(UInt8.self)
                columns.append(column)
            }
            let count = index.flags.count
            guard index.parents.count == count, index.stemLengths.count == count,
                  columns.allSatisfy({ $0.count == count && Int($0.offsets.last ?? 0) == $0.bytes.count }),
                  index.parents.enumerated().allSatisfy({ $0.element < Int32($0.offset) })
            else { throw IndexStoreError.corrupt }
            index.names = columns[0]
            index.folded = columns[1]
            index.pinyinFull = columns[2]
            index.pinyinInitials = columns[3]
            index.derivedReady = true
            index.rebuildDirectoryTables()
            return index
        }
    }
}

struct BinaryWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        u32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func optionalString(_ value: String?) {
        u8(value == nil ? 0 : 1)
        if let value { string(value) }
    }

    mutating func blob(_ value: Data) {
        u64(UInt64(value.count))
        data.append(value)
    }

    /// Raw little-endian dump of a trivial array (all Apple platforms are little-endian).
    mutating func array<T>(_ values: [T]) {
        u64(UInt64(values.count))
        values.withUnsafeBytes { data.append(contentsOf: $0) }
    }
}

struct BinaryReader {
    let base: UnsafeRawBufferPointer
    var offset = 0

    init(base: UnsafeRawBufferPointer) { self.base = base }

    mutating func take(_ count: Int) throws -> UnsafeRawBufferPointer {
        guard count >= 0, count <= base.count - offset else { throw IndexStoreError.corrupt }
        defer { offset += count }
        return UnsafeRawBufferPointer(rebasing: base[offset..<(offset + count)])
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }

    mutating func u32() throws -> UInt32 {
        UInt32(littleEndian: try take(4).loadUnaligned(as: UInt32.self))
    }

    mutating func u64() throws -> UInt64 {
        UInt64(littleEndian: try take(8).loadUnaligned(as: UInt64.self))
    }

    mutating func string() throws -> String {
        let count = Int(try u32())
        return String(decoding: try take(count), as: UTF8.self)
    }

    mutating func optionalString() throws -> String? {
        if try u8() == 0 { return nil }
        return try string()
    }

    mutating func blob() throws -> Data {
        let count = try u64()
        guard count <= UInt64(Int.max) else { throw IndexStoreError.corrupt }
        return Data(try take(Int(count)))
    }

    mutating func array<T>(_ type: T.Type) throws -> [T] {
        let count = try u64()
        let stride = MemoryLayout<T>.stride
        guard count <= UInt64(Int.max / stride) else { throw IndexStoreError.corrupt }
        let n = Int(count)
        let bytes = try take(n * stride)
        return [T](unsafeUninitializedCapacity: n) { buffer, initialized in
            if n > 0 { UnsafeMutableRawBufferPointer(buffer).copyMemory(from: bytes) }
            initialized = n
        }
    }
}

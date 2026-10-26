import Foundation

/// Strings stored back to back in one byte array, addressed by offsets.
/// One allocation for all names instead of one object per file.
struct ByteColumn {
    var bytes: [UInt8] = []
    var offsets: [UInt32] = [0]

    var count: Int { offsets.count - 1 }

    mutating func reserve(entries: Int, bytes byteCount: Int) {
        offsets.reserveCapacity(entries + 1)
        bytes.reserveCapacity(byteCount)
    }

    mutating func append(_ value: String) {
        bytes.append(contentsOf: value.utf8)
        offsets.append(UInt32(bytes.count))
    }

    /// Appends entry `index` of `other`.
    mutating func append(from other: ByteColumn, at index: Int) {
        let start = Int(other.offsets[index]), end = Int(other.offsets[index + 1])
        bytes.append(contentsOf: other.bytes[start..<end])
        offsets.append(UInt32(bytes.count))
    }

    /// Appends all entries of `other`.
    mutating func append(contentsOf other: ByteColumn) {
        let base = UInt32(bytes.count)
        bytes.append(contentsOf: other.bytes)
        offsets.append(contentsOf: other.offsets.dropFirst().map { $0 + base })
    }

    func string(at index: Int) -> String {
        let start = Int(offsets[index]), end = Int(offsets[index + 1])
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    func byteArray(at index: Int) -> [UInt8] {
        let start = Int(offsets[index]), end = Int(offsets[index + 1])
        return Array(bytes[start..<end])
    }

    func withView<R>(_ body: (ColumnView) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { bytePointer in
            try offsets.withUnsafeBufferPointer { offsetPointer in
                try body(ColumnView(bytes: bytePointer, offsets: offsetPointer))
            }
        }
    }
}

/// Read-only pointer view of a `ByteColumn`, valid inside `withView`.
struct ColumnView {
    let bytes: UnsafeBufferPointer<UInt8>
    let offsets: UnsafeBufferPointer<UInt32>

    @inline(__always)
    subscript(index: Int) -> UnsafeBufferPointer<UInt8> {
        let start = Int(offsets[index]), end = Int(offsets[index &+ 1])
        return UnsafeBufferPointer(rebasing: bytes[start..<end])
    }
}

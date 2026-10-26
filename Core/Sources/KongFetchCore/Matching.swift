import Foundation

/// How strictly a name must match, same three modes as 3.1/3.2 `SearchPrecision`.
public enum MatchPrecision: Int, CaseIterable, Codable, Sendable {
    /// The whole name (or name without extension) equals the query.
    case exactName = 0
    /// Substring, abbreviation (subsequence) or pinyin match on the name.
    case fuzzyName = 1
    /// As `fuzzyName`, but a word may also match the parent folder path.
    case withPath = 2
}

/// A query word folded once, with the gates 3.2 applies to it.
struct PreparedWord {
    let folded: String
    let bytes: [UInt8]
    let foldedCount: Int
    let rawCount: Int
    let rawIsASCII: Bool
    let foldedIsASCII: Bool
    let foldedIsAlphanumericASCII: Bool

    init(_ raw: String) {
        folded = SearchText.fold(raw)
        bytes = Array(folded.utf8)
        foldedCount = folded.count
        rawCount = raw.count
        rawIsASCII = raw.unicodeScalars.allSatisfy { $0.isASCII }
        foldedIsASCII = folded.unicodeScalars.allSatisfy { $0.isASCII }
        foldedIsAlphanumericASCII = foldedIsASCII && folded.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// 3.2 `fuzzyScore`: abbreviation matching only for ASCII words of 2+ characters.
    var allowsSubsequence: Bool { foldedCount >= 2 && foldedIsASCII }
    /// 3.2 `computeFilenameScore`: folder-path matching needs 2+ characters.
    var allowsPathMatch: Bool { foldedCount >= 2 }
    /// 3.2 `pinyinScore`: ASCII letters/digits only, 2+ characters.
    var allowsPinyin: Bool { foldedCount >= 2 && foldedIsAlphanumericASCII }
    /// Extra gate 3.2 applies before pinyin in name-and-path mode.
    var allowsPathModePinyin: Bool { rawIsASCII && rawCount >= 2 && allowsPinyin }

    var gate: WordGate {
        WordGate(allowsSubsequence: allowsSubsequence, allowsPathMatch: allowsPathMatch, allowsPinyin: allowsPinyin, allowsPathModePinyin: allowsPathModePinyin)
    }
}

/// Plain flags copied out of `PreparedWord`, cheap to read in the search loop.
struct WordGate {
    let allowsSubsequence: Bool
    let allowsPathMatch: Bool
    let allowsPinyin: Bool
    let allowsPathModePinyin: Bool
}

/// Byte-level primitives over UTF-8 search keys.
enum ByteMatch {
    @inline(__always)
    static func equals(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0
    }

    @inline(__always)
    static func hasPrefix(_ text: UnsafeBufferPointer<UInt8>, _ prefix: UnsafeBufferPointer<UInt8>) -> Bool {
        guard prefix.count <= text.count else { return false }
        if prefix.isEmpty { return true }
        return memcmp(text.baseAddress!, prefix.baseAddress!, prefix.count) == 0
    }

    /// Byte offset of the first occurrence of `word` in `text`.
    static func firstIndex(of word: UnsafeBufferPointer<UInt8>, in text: UnsafeBufferPointer<UInt8>) -> Int? {
        let n = text.count, m = word.count
        if m == 0 { return 0 }
        guard m <= n else { return nil }
        let base = UnsafeRawPointer(text.baseAddress!)
        let needle = UnsafeRawPointer(word.baseAddress!)
        let first = Int32(word[0])
        var start = 0
        while start <= n - m {
            guard let hit = memchr(base + start, first, n - m - start + 1) else { return nil }
            let position = base.distance(to: UnsafeRawPointer(hit))
            if memcmp(base + position, needle, m) == 0 { return position }
            start = position + 1
        }
        return nil
    }

    /// True when every byte of `word` appears in `text` in order.
    /// Any equality, prefix, substring or abbreviation match implies this,
    /// so it is a safe rejection test before the exact scoring.
    @inline(__always)
    static func isSubsequence(_ word: UnsafeBufferPointer<UInt8>, of text: UnsafeBufferPointer<UInt8>) -> Bool {
        let m = word.count
        if m == 0 { return true }
        if m > text.count { return false }
        var j = 0
        var target = word[0]
        for byte in text where byte == target {
            j += 1
            if j == m { return true }
            target = word[j]
        }
        return false
    }

    static func isASCII(_ text: UnsafeBufferPointer<UInt8>) -> Bool {
        for byte in text where byte >= 0x80 { return false }
        return true
    }

    @inline(__always)
    static func isAlphanumericASCII(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
}

/// Scores that reproduce 3.2 exactly, computed on pre-folded bytes.
enum Scoring {
    /// 3.2 `fuzzyScore(text, word)` where `text` is already folded.
    static func fuzzy(_ text: UnsafeBufferPointer<UInt8>, textIsASCII: Bool, allowsSubsequence: Bool, wordBytes: UnsafeBufferPointer<UInt8>) -> Int? {
        if wordBytes.isEmpty { return 0 }
        guard ByteMatch.isSubsequence(wordBytes, of: text) else { return nil }
        if ByteMatch.equals(text, wordBytes) { return 1000 }
        if ByteMatch.hasPrefix(text, wordBytes) { return 850 }
        if let position = ByteMatch.firstIndex(of: wordBytes, in: text) {
            let offset = textIsASCII
                ? position
                : String(decoding: UnsafeBufferPointer(rebasing: text[0..<position]), as: UTF8.self).count
            return 700 - min(120, offset * 3)
        }
        guard allowsSubsequence else { return nil }
        if textIsASCII { return asciiAbbreviation(text, wordBytes) }
        // allowsSubsequence implies an ASCII word, so decoding its bytes is exact.
        return characterAbbreviation(Array(String(decoding: text, as: UTF8.self)), Array(String(decoding: wordBytes, as: UTF8.self)))
    }

    /// The abbreviation branch of 3.2 `fuzzyScore`, for ASCII text.
    static func asciiAbbreviation(_ text: UnsafeBufferPointer<UInt8>, _ pattern: UnsafeBufferPointer<UInt8>) -> Int? {
        var cursor = 0, previous = -1, first = -1, score = 380
        for ch in pattern {
            var hit = -1
            var k = cursor
            while k < text.count {
                if text[k] == ch { hit = k; break }
                k += 1
            }
            if hit < 0 { return nil }
            if first < 0 { first = hit }
            if hit == 0 || !ByteMatch.isAlphanumericASCII(text[hit - 1]) { score += 28 }
            if previous >= 0 { score += hit == previous + 1 ? 18 : -min(140, (hit - previous - 1) * 9) }
            previous = hit
            cursor = hit + 1
        }
        return max(40, score - min(100, first * 3))
    }

    /// The abbreviation branch of 3.2 `fuzzyScore`, on characters (non-ASCII text).
    static func characterAbbreviation(_ chars: [Character], _ pattern: [Character]) -> Int? {
        var cursor = 0, previous = -1, first = -1, score = 380
        for ch in pattern {
            guard let hit = (cursor..<chars.count).first(where: { chars[$0] == ch }) else { return nil }
            if first < 0 { first = hit }
            if hit == 0 || !chars[hit - 1].isLetter && !chars[hit - 1].isNumber { score += 28 }
            if previous >= 0 { score += hit == previous + 1 ? 18 : -min(140, (hit - previous - 1) * 9) }
            previous = hit
            cursor = hit + 1
        }
        return max(40, score - min(100, first * 3))
    }

    /// 3.2 `pinyinScore(forms, word)`.
    static func pinyin(full: UnsafeBufferPointer<UInt8>, initials: UnsafeBufferPointer<UInt8>, allowsPinyin: Bool, wordBytes: UnsafeBufferPointer<UInt8>) -> Int? {
        guard allowsPinyin, !full.isEmpty else { return nil }
        var best: Int?
        for form in [full, initials] where ByteMatch.firstIndex(of: wordBytes, in: form) != nil {
            let score = ByteMatch.equals(form, wordBytes) ? 600 : (ByteMatch.hasPrefix(form, wordBytes) ? 550 : 450)
            best = max(best ?? score, score)
        }
        return best
    }
}

/// String-level entry points with the same results as 3.2's free functions.
/// Used where no index is involved (e.g. scoring a single URL in the app).
public enum NameMatcher {
    public static func fuzzyScore(_ text: String, _ word: String) -> Int? {
        let prepared = PreparedWord(word)
        let foldedText = Array(SearchText.fold(text).utf8)
        return foldedText.withUnsafeBufferPointer { textBuffer in
            prepared.bytes.withUnsafeBufferPointer { wordBuffer in
                Scoring.fuzzy(textBuffer, textIsASCII: ByteMatch.isASCII(textBuffer), allowsSubsequence: prepared.allowsSubsequence, wordBytes: wordBuffer)
            }
        }
    }
}

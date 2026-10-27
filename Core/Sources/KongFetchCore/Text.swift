import Foundation

/// Search-key folding shared by the index and the query side.
public enum SearchText {
    private static let locale = Locale(identifier: "en_US_POSIX")

    /// Same folding as 3.2 `normalized(_:)` (case, diacritics, full/half width),
    /// then precomposed so that byte comparisons agree with `String` comparisons
    /// even for names stored decomposed (old HFS+ files, some Korean names).
    public static func fold(_ value: String) -> String {
        var result = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .precomposedStringWithCanonicalMapping
        result.makeContiguousUTF8()
        return result
    }

    /// Same range test as 3.2 `pinyinForms` (CJK Extension A + Unified Ideographs).
    public static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
    }
}

/// Pinyin spellings used for matching Chinese names with Latin input.
public enum Pinyin {
    /// Phrase readings that avoid blindly expanding polyphonic characters (copied from 3.2).
    private static let phraseReadings: [(phrase: String, latin: String, reading: String)] = {
        let readings = [
            "重庆": "chong qing", "重阳": "chong yang", "重新": "chong xin", "重量": "zhong liang",
            "音乐": "yin yue", "乐器": "yue qi", "乐清": "yue qing", "长乐": "chang le", "快乐": "kuai le",
            "乐乐": "le le", "长沙": "chang sha", "长安": "chang an", "长大": "zhang da", "银行": "yin hang",
            "行长": "hang zhang", "行业": "hang ye", "朝阳": "chao yang", "厦门": "xia men",
        ]
        return readings
            .map { (phrase: $0.key, latin: SearchText.fold($0.key.applyingTransform(.toLatin, reverse: false) ?? $0.key), reading: $0.value) }
            .sorted { $0.phrase < $1.phrase }
    }()

    /// `[full spelling, initials]` for a name containing CJK characters, `[]` otherwise.
    /// Same result as 3.2 `pinyinForms(_:)`.
    public static func forms(_ name: String) -> [String] {
        var cache = RunCache()
        return forms(name, cache: &cache)
    }

    /// As `forms(_:)`, reusing a caller-owned syllable cache (one per worker thread).
    static func forms(_ name: String, cache: inout RunCache) -> [String] {
        guard SearchText.containsCJK(name) else { return [] }
        return finish(name, latin: fastLatin(name, cache: &cache) ?? transformLatin(name))
    }

    public struct FastPathReport: Sendable {
        public var namesWithCJK = 0
        public var slowPathNames = 0
        public var mismatches: [String] = []
    }

    /// Compares the per-character path with whole-name transliteration for every
    /// name (in parallel). Used by tests and the benchmark; not needed at runtime.
    public static func verifyFastPath(_ names: [String]) -> FastPathReport {
        final class Part { var report = FastPathReport() }
        let chunkSize = 2048
        let chunkCount = max(1, (names.count + chunkSize - 1) / chunkSize)
        let parts = (0..<chunkCount).map { _ in Part() }
        DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
            let part = parts[c]
            var cache = RunCache()
            for name in names[(c * chunkSize)..<min(names.count, (c + 1) * chunkSize)] where SearchText.containsCJK(name) {
                part.report.namesWithCJK += 1
                guard let latin = fastLatin(name, cache: &cache) else {
                    part.report.slowPathNames += 1
                    continue
                }
                if finish(name, latin: latin) != slowForms(name), part.report.mismatches.count < 50 {
                    part.report.mismatches.append(name + " → fast " + latin + " / transform " + transformLatin(name))
                }
            }
        }
        var total = FastPathReport()
        for part in parts {
            total.namesWithCJK += part.report.namesWithCJK
            total.slowPathNames += part.report.slowPathNames
            total.mismatches += part.report.mismatches
        }
        return total
    }

    /// 3.2's method: transliterate the whole name with the system's Any-Latin transform.
    static func slowForms(_ name: String) -> [String] {
        guard SearchText.containsCJK(name) else { return [] }
        return finish(name, latin: transformLatin(name))
    }

    static func transformLatin(_ name: String) -> String {
        SearchText.fold(name.applyingTransform(.toLatin, reverse: false) ?? name)
    }

    private static func finish(_ name: String, latin source: String) -> [String] {
        var latin = source
        for item in phraseReadings where name.contains(item.phrase) {
            latin = latin.replacingOccurrences(of: item.latin, with: item.reading)
        }
        let parts = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return [parts.joined(), String(parts.compactMap(\.first))]
    }

    /// Builds the same folded Latin text as `transformLatin` from cached pieces.
    /// The system transform reads runs of consecutive Han characters with phrase
    /// context (重庆 → chong qing, but 重 alone → zhong), so each maximal run is
    /// transliterated as a whole and cached. Between pieces it inserts a space
    /// before a Han run that follows a letter (contract申报 → contract shen bao).
    /// Only names made of Han characters, Latin letters, digits, punctuation,
    /// symbols and spaces take this path; anything else (kana, hangul, other
    /// scripts, CJK punctuation) returns nil and the whole name is transliterated.
    /// `verifyFastPath` and the tests compare both paths.
    static func fastLatin(_ name: String, cache: inout RunCache) -> String? {
        let scalars = Array(name.unicodeScalars)
        var result = String.UnicodeScalarView()
        var previousWasLetter = false
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if isHan(scalar) {
                var run = String.UnicodeScalarView()
                while i < scalars.count, isHan(scalars[i]) {
                    run.append(scalars[i])
                    i += 1
                }
                guard let latin = cache.latin(forRun: String(run)) else { return nil }
                if previousWasLetter { result.append(" ") }
                result.append(contentsOf: latin.unicodeScalars)
                previousWasLetter = false
            } else if isNeutral(scalar) {
                result.append(scalar)
                previousWasLetter = scalar.properties.isAlphabetic
                i += 1
            } else {
                return nil
            }
        }
        return SearchText.fold(String(result))
    }

    @inline(__always)
    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9fff).contains(scalar.value)
    }

    /// Characters the Any-Latin transform leaves as they are (up to folding).
    private static func isNeutral(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x250 {
            // ASCII, Latin-1, Latin Extended-A/B; combining marks and controls excluded.
            return scalar.properties.generalCategory != .nonspacingMark && scalar.properties.generalCategory != .control
        }
        if (0x3000...0x303F).contains(value) || (0xFF00...0xFFEF).contains(value) { return false } // CJK/fullwidth punctuation: transform may rewrite
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// Folded transliteration per run of Han characters, shared across threads
    /// behind a lock and copied into a per-thread dictionary so the lock is rarely taken.
    struct RunCache {
        private var local: [String: String] = [:]
        private static let lock = NSLock()
        private static var shared: [String: String] = [:]

        mutating func latin(forRun run: String) -> String? {
            if let hit = local[run] { return hit.isEmpty ? nil : hit }
            Self.lock.lock()
            var value = Self.shared[run]
            Self.lock.unlock()
            if value == nil {
                let latin = SearchText.fold(run.applyingTransform(.toLatin, reverse: false) ?? run)
                // Expect letters separated by single spaces; otherwise remember ""
                // and let the whole name take the slow path.
                let usable = !latin.isEmpty && !latin.hasPrefix(" ") && !latin.hasSuffix(" ") && !latin.contains("  ")
                    && latin.unicodeScalars.allSatisfy { $0 == " " || ($0.isASCII && $0.properties.isAlphabetic) }
                value = usable ? latin : ""
                Self.lock.lock()
                Self.shared[run] = value
                Self.lock.unlock()
            }
            local[run] = value
            return value!.isEmpty ? nil : value
        }
    }
}

/// Path helpers. Index paths are always canonical: absolute, symlinks in the
/// existing part resolved, `/private` kept (FSEvents reports `/private/var/...`).
public enum Paths {
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if let resolved = realpath(expanded, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // The path no longer exists (e.g. a deleted file): resolve the nearest
        // existing ancestor and re-append the missing components. Avoids
        // `standardizingPath`, which strips `/private` and would not match the index.
        var missing: [String] = []
        var current = expanded
        while current != "/" && !current.isEmpty {
            missing.append((current as NSString).lastPathComponent)
            current = (current as NSString).deletingLastPathComponent
            if let resolved = realpath(current, nil) {
                defer { free(resolved) }
                var result = String(cString: resolved)
                for component in missing.reversed() { result = join(result, component) }
                return result
            }
        }
        return expanded
    }

    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    public static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    public static func isWithin(_ path: String, _ root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }
}

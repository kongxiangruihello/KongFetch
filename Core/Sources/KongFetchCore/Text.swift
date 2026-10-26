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
    /// Matches 3.2 `pinyinForms(_:)`.
    public static func forms(_ name: String) -> [String] {
        guard SearchText.containsCJK(name) else { return [] }
        var latin = SearchText.fold(name.applyingTransform(.toLatin, reverse: false) ?? name)
        for item in phraseReadings where name.contains(item.phrase) {
            latin = latin.replacingOccurrences(of: item.latin, with: item.reading)
        }
        let parts = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return [parts.joined(), String(parts.compactMap(\.first))]
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

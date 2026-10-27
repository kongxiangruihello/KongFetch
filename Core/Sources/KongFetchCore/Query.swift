import Foundation
import UniformTypeIdentifiers

/// File type filter (3.2 `FileFilter`).
public enum KindFilter: Int, CaseIterable, Codable, Sendable {
    case all, documents, pdf, images, audio, video, folders

    public var title: String { ["全部类型", "文档", "PDF", "图片", "音频", "视频", "文件夹"][rawValue] }

    public var contentTypeIdentifiers: [String] {
        switch self {
        case .all: return []
        case .documents: return ["public.text", "com.adobe.pdf", "public.presentation", "public.spreadsheet", "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.pages"]
        case .pdf: return ["com.adobe.pdf"]
        case .images: return ["public.image"]
        case .audio: return ["public.audio"]
        case .video: return ["public.movie"]
        case .folders: return ["public.folder"]
        }
    }

    public func accepts(_ metadata: EntryMetadata) -> Bool {
        if self == .all { return true }
        if self == .folders { return metadata.isDirectory }
        if metadata.isDirectory { return false }
        guard let type = metadata.contentType else { return false }
        return contentTypeIdentifiers.contains { identifier in
            guard let target = UTType(identifier) else { return false }
            return type.conforms(to: target)
        }
    }
}

/// The file attributes that type, date, size and tag filters look at (3.2 `Entry`).
public struct EntryMetadata: Sendable {
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    public var contentType: UTType?
    public var tags: [String]

    public init(isDirectory: Bool, size: Int64, modified: Date?, contentType: UTType?, tags: [String]) {
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.contentType = contentType
        self.tags = tags
    }

    /// Reads the attributes from disk the way 3.2 `Entry.init` did
    /// (packages count as files; Finder color labels count as tags).
    public static func read(path: String) -> EntryMetadata {
        var url = URL(fileURLWithPath: path)
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey, .contentTypeKey, .tagNamesKey, .labelNumberKey])
        let colorNames = [1: "灰色", 2: "绿色", 3: "紫色", 4: "蓝色", 5: "黄色", 6: "红色", 7: "橙色"]
        var tags = values?.tagNames ?? []
        if let color = colorNames[values?.labelNumber ?? 0], !tags.contains(color) { tags.append(color) }
        return EntryMetadata(
            isDirectory: (values?.isDirectory ?? false) && !(values?.isPackage ?? false),
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate,
            contentType: values?.contentType ?? UTType(filenameExtension: url.pathExtension),
            tags: tags
        )
    }
}

/// Natural-language filters (3.2 `NaturalQuery`): "最近一周", "今天", "昨天",
/// "大于100MB", "标签:工作" / "tag:" / "#".
public struct NaturalFilters: Equatable, Sendable {
    public var text: String
    public var days: Int?
    public var yesterday = false
    public var minimum: Int64?
    public var maximum: Int64?
    public var tag: String?
    public var descriptions: [String] = []

    public init(_ input: String) {
        text = input
        func take(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else { return nil }
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            text.replaceSubrange(range, with: " ")
            return groups
        }
        if let m = take("(?:最近|近)\\s*(一周|一星期|一个月|一月|[0-9]{1,3}\\s*天|[0-9]{1,2}\\s*周)(?:的)?") {
            let number = Int(m[1].filter(\.isNumber)) ?? 1
            let value = m[1].contains("月") ? 30 : (m[1].contains("周") || m[1].contains("星期") ? number * 7 : number)
            days = max(1, min(365, value))
            descriptions.append("最近 \(days!) 天")
        } else if take("今天(?:的)?") != nil {
            days = 1
            descriptions.append("今天")
        } else if take("昨天(?:的)?") != nil {
            yesterday = true
            descriptions.append("昨天")
        }
        if let m = take("(大于|超过|小于|不足)\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(KB|MB|GB)(?:的)?"), let value = Double(m[2]), value.isFinite, value <= 1_000_000 {
            let multiplier: Double = m[3].uppercased() == "GB" ? 1e9 : (m[3].uppercased() == "MB" ? 1e6 : 1e3)
            let bytes = Int64(value * multiplier)
            if m[1] == "大于" || m[1] == "超过" { minimum = bytes } else { maximum = bytes }
            descriptions.append(m[1] + m[2] + m[3].uppercased())
        }
        if let m = take("(?:^|\\s)(?:标签[:：]|tag:|#)([^\\s]+)") {
            tag = m[1]
            descriptions.append("标签：" + m[1])
        }
        if !descriptions.isEmpty {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let types = ["PDF": "pdf", "视频": "video", "图片": "image", "音频": "audio", "文档": "doc", "文件夹": "folder"]
            for (type, command) in types.sorted(by: { $0.key.count > $1.key.count }) {
                if text.lowercased() == type.lowercased() { text = command; break }
                if text.lowercased().hasSuffix("的" + type.lowercased()) { text = command + " " + String(text.dropLast(type.count + 1)); break }
                if text.hasSuffix(" " + type) { text = command + " " + String(text.dropLast(type.count + 1)); break }
            }
        }
    }

    public func accepts(_ metadata: EntryMetadata, now: Date = Date()) -> Bool {
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        if let days {
            guard let modified = metadata.modified,
                  modified >= calendar.date(byAdding: .day, value: -(days - 1), to: today)!,
                  modified < calendar.date(byAdding: .day, value: 1, to: today)! else { return false }
        }
        if yesterday {
            guard let modified = metadata.modified,
                  modified >= calendar.date(byAdding: .day, value: -1, to: today)!,
                  modified < today else { return false }
        }
        if minimum != nil || maximum != nil {
            if metadata.isDirectory { return false }
            if let minimum, metadata.size <= minimum { return false }
            if let maximum, metadata.size >= maximum { return false }
        }
        if let tag, !metadata.tags.contains(where: { SearchText.fold($0) == SearchText.fold(tag) }) { return false }
        return true
    }
}

/// A parsed search box entry (3.2 `AdvancedSearchQuery`):
/// words, "quoted phrases", -exclusions, ext:pdf,png / -ext:png, a leading type
/// word (pdf, 文档, 图片 …) and natural-language filters.
public struct SearchQuery: Sendable {
    public let natural: NaturalFilters
    public let filter: KindFilter
    public let words: [String]
    public let phrases: [String]
    public let excluded: [String]
    public let excludedPhrases: Set<String>
    public let extensions: Set<String>
    public let excludedExtensions: Set<String>
    public let notes: [String]
    public let valid: Bool

    public var highlightWords: [String] { words + phrases }
    public var hasConstraints: Bool { !phrases.isEmpty || !excluded.isEmpty || !extensions.isEmpty || !excludedExtensions.isEmpty || !valid }
    /// True when results also need file attributes (type, date, size, tag).
    public var needsMetadata: Bool { filter != .all || !natural.descriptions.isEmpty }

    public var descriptions: [String] {
        var values: [String] = []
        if !phrases.isEmpty { values.append("短语：" + phrases.map { "“" + $0 + "”" }.joined(separator: "、")) }
        if !excluded.isEmpty { values.append("排除：" + excluded.joined(separator: "、")) }
        if !extensions.isEmpty { values.append("扩展名：" + extensions.sorted().joined(separator: "、")) }
        if !excludedExtensions.isEmpty { values.append("排除扩展名：" + excludedExtensions.sorted().joined(separator: "、")) }
        return values + notes
    }

    public init(_ text: String, fallback: KindFilter = .all) {
        let lexed = QueryLexer.lex(text)
        var ordinary: [String] = [], phrases: [String] = [], excluded: [String] = []
        var excludedPhrases = Set<String>(), extensions = Set<String>(), excludedExtensions = Set<String>()
        var notes: [String] = [], valid = true
        var firstPositiveWasPhrase = false, foundPositive = false
        for token in lexed.tokens {
            if token.operatorPrefix {
                let raw = String(token.value.dropFirst(4))
                let parts = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "，" || $0 == "|" }).map { part -> String in
                    let value = SearchText.fold(String(part).trimmingCharacters(in: .whitespacesAndNewlines))
                    return value.hasPrefix(".") ? String(value.dropFirst()) : value
                }
                let accepted = parts.filter {
                    !$0.isEmpty && $0.count <= 64 && !$0.hasPrefix(".") && !$0.hasSuffix(".") && !$0.contains("..")
                        && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-_+".unicodeScalars.contains($0) }
                }
                if accepted.count != parts.count || accepted.isEmpty {
                    valid = false
                    notes.append("扩展名格式无效，请使用 ext:pdf 或 ext:pdf,png")
                }
                if token.excluded { excludedExtensions.formUnion(accepted) } else { extensions.formUnion(accepted) }
            } else if token.excluded {
                excluded.append(token.value)
                if token.phrase { excludedPhrases.insert(token.value) }
            } else {
                if !foundPositive {
                    firstPositiveWasPhrase = token.phrase
                    foundPositive = true
                }
                if token.phrase { phrases.append(token.value) } else { ordinary.append(token.value) }
            }
        }
        let natural = NaturalFilters(ordinary.joined(separator: " "))
        var words = natural.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var filter = fallback
        let aliases: [String: KindFilter] = ["pdf": .pdf, "doc": .documents, "文档": .documents, "image": .images, "图片": .images, "audio": .audio, "音频": .audio, "video": .video, "视频": .video, "folder": .folders, "文件夹": .folders]
        if !firstPositiveWasPhrase || !natural.descriptions.isEmpty, let first = words.first?.lowercased(), let type = aliases[first] {
            filter = type
            words.removeFirst()
        }
        if lexed.unfinishedQuote { notes.append("引号尚未闭合，当前按短语搜索") }
        self.natural = natural
        self.filter = filter
        self.words = words
        self.phrases = phrases
        self.excluded = excluded
        self.excludedPhrases = excludedPhrases
        self.extensions = extensions
        self.excludedExtensions = excludedExtensions
        self.notes = notes
        self.valid = valid
    }

    /// Type and natural-language filters, which need file attributes.
    public func acceptsMetadata(_ metadata: EntryMetadata, now: Date = Date()) -> Bool {
        filter.accepts(metadata) && natural.accepts(metadata, now: now)
    }

    /// Query text with type/date filters removed but quotes and operators kept.
    public var textWithoutFilters: String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let parts = words + phrases.map(quote)
            + excluded.map { "-" + (excludedPhrases.contains($0) ? quote($0) : $0) }
            + (extensions.isEmpty ? [] : ["ext:" + extensions.sorted().joined(separator: ",")])
            + (excludedExtensions.isEmpty ? [] : ["-ext:" + excludedExtensions.sorted().joined(separator: ",")])
        return parts.joined(separator: " ")
    }

    public var positiveText: String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return (words + phrases.map(quote)).joined(separator: " ")
    }
}

/// Tokenizer for the search box (3.2 `lexSearch32`). Quoted text stays literal,
/// so a name such as "今天" is not taken as a date filter.
enum QueryLexer {
    struct Token {
        let value: String
        let phrase: Bool
        let excluded: Bool
        let operatorPrefix: Bool
    }

    struct Result {
        var tokens: [Token] = []
        var unfinishedQuote = false
    }

    static func lex(_ input: String) -> Result {
        let chars = Array(input)
        var result = Result(), index = 0
        while index < chars.count {
            while index < chars.count && chars[index].isWhitespace { index += 1 }
            guard index < chars.count else { break }
            var excluded = false, value = "", prefix = "", quoted = false
            var quote: Character?
            if chars[index] == "-", index + 1 < chars.count, !chars[index + 1].isWhitespace {
                excluded = true
                index += 1
            }
            while index < chars.count {
                let ch = chars[index]
                if ch == "\\", index + 1 < chars.count, [Character("\""), Character("\\"), Character("“"), Character("”")].contains(chars[index + 1]) {
                    value.append(chars[index + 1])
                    if !quoted { prefix.append(chars[index + 1]) }
                    index += 2
                    continue
                }
                if let closing = quote {
                    if ch == closing { quote = nil } else { value.append(ch) }
                    index += 1
                    continue
                }
                if ch == "\"" || ch == "“" {
                    quoted = true
                    quote = ch == "“" ? "”" : "\""
                    index += 1
                    continue
                }
                if ch.isWhitespace { break }
                value.append(ch)
                if !quoted { prefix.append(ch) }
                index += 1
            }
            if quote != nil { result.unfinishedQuote = true }
            if !value.isEmpty {
                result.tokens.append(Token(value: value, phrase: quoted, excluded: excluded, operatorPrefix: prefix.lowercased().hasPrefix("ext:")))
            }
        }
        return result
    }
}

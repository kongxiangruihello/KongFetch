// Verbatim copy of KongFetch 3.2 query handling, for parity tests only:
// Entry/FileFilter/SearchMode (Sources/main.swift), NaturalQuery (Features30.swift),
// lexSearch32/AdvancedSearchQuery (Features32Search.swift) @ 33814f1.
// Unchanged except imports and the SearchPrecision alias below. Do not edit.
import Foundation
import UniformTypeIdentifiers

public typealias SearchPrecision = Legacy32Precision

struct Entry {
    let url: URL
    let directory: Bool
    let size: Int64
    let modified: Date?
    let created: Date?
    let kind: String
    let contentType:UTType?
    let tags:[String]
    init(_ url: URL) {
        self.url = url
        var freshURL=url; freshURL.removeAllCachedResourceValues()
        let r = try? freshURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey, .creationDateKey, .localizedTypeDescriptionKey, .contentTypeKey, .tagNamesKey, .labelNumberKey])
        directory = (r?.isDirectory ?? false) && !(r?.isPackage ?? false)
        size = Int64(r?.fileSize ?? 0)
        modified = r?.contentModificationDate
        created = r?.creationDate
        kind = r?.localizedTypeDescription ?? "文件"
        contentType = r?.contentType ?? UTType(filenameExtension:url.pathExtension)
        let colorNames=[1:"灰色",2:"绿色",3:"紫色",4:"蓝色",5:"黄色",6:"红色",7:"橙色"]; var tagList=r?.tagNames ?? []; if let color=colorNames[r?.labelNumber ?? 0],!tagList.contains(color) { tagList.append(color) }; tags=tagList
    }
}
enum FileFilter:Int, CaseIterable {
    case all, documents, pdf, images, audio, video, folders
    var title:String { ["全部类型","文档","PDF","图片","音频","视频","文件夹"][rawValue] }
    var metadataTypes:[String] {
        switch self {
        case .all: return []
        case .documents: return ["public.text","com.adobe.pdf","public.presentation","public.spreadsheet","org.openxmlformats.wordprocessingml.document","com.microsoft.word.doc","com.apple.iwork.pages.pages"]
        case .pdf: return ["com.adobe.pdf"]
        case .images: return ["public.image"]
        case .audio: return ["public.audio"]
        case .video: return ["public.movie"]
        case .folders: return ["public.folder"]
        }
    }
    func accepts(_ entry:Entry)->Bool {
        if self == .all { return true }; if self == .folders { return entry.directory }; if entry.directory { return false }
        return metadataTypes.contains { name in guard let target=UTType(name), let type=entry.contentType else { return false }; return type.conforms(to:target) }
    }
}
enum SearchMode:Int {
    case filename, content
    var title:String { self == .filename ? "文件名" : "文件内容" }
    var attribute:String { self == .filename ? NSMetadataItemFSNameKey : NSMetadataItemTextContentKey }
    var placeholder:String { self == .filename ? "搜索文件…" : "搜索文件中的文字…" }
}

struct NaturalQuery {
    var text:String
    var days:Int?
    var yesterday=false
    var minimum:Int64?
    var maximum:Int64?
    var tag:String?
    var descriptions:[String]=[]
    init(_ input:String) {
        text=input
        func take(_ pattern:String)->[String]? {
            guard let regex=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive),let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let range=Range(match.range,in:text) else { return nil }
            let groups=(0..<match.numberOfRanges).map { Range(match.range(at:$0),in:text).map { String(text[$0]) } ?? "" }
            text.replaceSubrange(range,with:" "); return groups
        }
        if let m=take("(?:最近|近)\\s*(一周|一星期|一个月|一月|[0-9]{1,3}\\s*天|[0-9]{1,2}\\s*周)(?:的)?") {
            let number=Int(m[1].filter(\.isNumber)) ?? 1
            days=m[1].contains("月") ? 30 : (m[1].contains("周") || m[1].contains("星期") ? number*7 : number)
            days=max(1,min(365,days!)); descriptions.append("最近 \(days!) 天")
        } else if take("今天(?:的)?") != nil { days=1; descriptions.append("今天") }
        else if take("昨天(?:的)?") != nil { yesterday=true; descriptions.append("昨天") }
        if let m=take("(大于|超过|小于|不足)\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(KB|MB|GB)(?:的)?"),let value=Double(m[2]),value.isFinite,value <= 1000000 {
            let multiplier:Double=m[3].uppercased() == "GB" ? 1e9 : (m[3].uppercased() == "MB" ? 1e6 : 1e3)
            let bytes=Int64(value*multiplier)
            if m[1] == "大于" || m[1] == "超过" { minimum=bytes } else { maximum=bytes }
            descriptions.append(m[1]+m[2]+m[3].uppercased())
        }
        if let m=take("(?:^|\\s)(?:标签[:：]|tag:|#)([^\\s]+)") { tag=m[1]; descriptions.append("标签："+m[1]) }
        if !descriptions.isEmpty {
            text=text.trimmingCharacters(in:.whitespacesAndNewlines)
            let types=["PDF":"pdf","视频":"video","图片":"image","音频":"audio","文档":"doc","文件夹":"folder"]
            for (type,command) in types.sorted(by:{ $0.key.count > $1.key.count }) {
                if text.lowercased() == type.lowercased() { text=command; break }
                if text.lowercased().hasSuffix("的"+type.lowercased()) { text=command+" "+String(text.dropLast(type.count+1)); break }
                if text.hasSuffix(" "+type) { text=command+" "+String(text.dropLast(type.count+1)); break }
            }
        }
    }
    func accepts(_ entry:Entry,now:Date=Date())->Bool {
        let cal=Calendar.current,today=cal.startOfDay(for:now)
        if let days { guard let modified=entry.modified,modified >= cal.date(byAdding:.day,value:-(days-1),to:today)!,modified < cal.date(byAdding:.day,value:1,to:today)! else { return false } }
        if yesterday { guard let modified=entry.modified,modified >= cal.date(byAdding:.day,value:-1,to:today)!,modified < today else { return false } }
        if minimum != nil || maximum != nil { if entry.directory { return false }; if let minimum,entry.size <= minimum { return false }; if let maximum,entry.size >= maximum { return false } }
        if let tag,!entry.tags.contains(where:{ normalized($0) == normalized(tag) }) { return false }
        return true
    }
}


// Quoted text is kept out of NaturalQuery so names such as "今天" remain literal.
struct Search32Token {
    let value:String
    let phrase:Bool
    let excluded:Bool
    let operatorPrefix:Bool
}
struct Search32Lexed {
    var tokens:[Search32Token]=[]
    var unfinishedQuote=false
}
func lexSearch32(_ input:String)->Search32Lexed {
    let chars=Array(input);var result=Search32Lexed(),index=0
    while index < chars.count {
        while index < chars.count && chars[index].isWhitespace {index += 1}
        guard index < chars.count else {break}
        var excluded=false,value="",prefix="",quoted=false,quote:Character?
        if chars[index] == "-",index+1 < chars.count,!chars[index+1].isWhitespace {excluded=true;index += 1}
        while index < chars.count {
            let ch=chars[index]
            if ch == "\\",index+1 < chars.count,[Character("\""),Character("\\"),Character("“"),Character("”")].contains(chars[index+1]) {value.append(chars[index+1]);if !quoted {prefix.append(chars[index+1])};index += 2;continue}
            if let closing=quote {
                if ch == closing {quote=nil} else {value.append(ch)}
                index += 1;continue
            }
            if ch == "\"" || ch == "“" {quoted=true;quote=ch == "“" ? "”" : "\"";index += 1;continue}
            if ch.isWhitespace {break}
            value.append(ch);if !quoted {prefix.append(ch)};index += 1
        }
        if quote != nil {result.unfinishedQuote=true}
        if !value.isEmpty {result.tokens.append(Search32Token(value:value,phrase:quoted,excluded:excluded,operatorPrefix:prefix.lowercased().hasPrefix("ext:")))}
    }
    return result
}

struct AdvancedSearchQuery {
    let natural:NaturalQuery
    let filter:FileFilter
    let words:[String]
    let phrases:[String]
    let excluded:[String]
    let excludedPhrases:Set<String>
    let extensions:Set<String>
    let excludedExtensions:Set<String>
    let notes:[String]
    let valid:Bool
    var highlightWords:[String] {words+phrases}
    var hasConstraints:Bool {!phrases.isEmpty || !excluded.isEmpty || !extensions.isEmpty || !excludedExtensions.isEmpty || !valid}
    var descriptions:[String] {
        var values:[String]=[]
        if !phrases.isEmpty {values.append("短语："+phrases.map {"“"+$0+"”"}.joined(separator:"、"))}
        if !excluded.isEmpty {values.append("排除："+excluded.joined(separator:"、"))}
        if !extensions.isEmpty {values.append("扩展名："+extensions.sorted().joined(separator:"、"))}
        if !excludedExtensions.isEmpty {values.append("排除扩展名："+excludedExtensions.sorted().joined(separator:"、"))}
        return values+notes
    }
    init(_ text:String,fallback:FileFilter = .all) {
        let lexed=lexSearch32(text);var ordinary:[String]=[],phrases:[String]=[],excluded:[String]=[],excludedPhrases=Set<String>(),extensions=Set<String>(),excludedExtensions=Set<String>(),notes:[String]=[],valid=true
        var firstPositiveWasPhrase=false,foundPositive=false
        for token in lexed.tokens {
            if token.operatorPrefix {
                let raw=String(token.value.dropFirst(4))
                let parts=raw.split(omittingEmptySubsequences:false,whereSeparator:{$0 == "," || $0 == "，" || $0 == "|"}).map {value -> String in let value=normalized(String(value).trimmingCharacters(in:.whitespacesAndNewlines));return value.hasPrefix(".") ? String(value.dropFirst()) : value}
                let accepted=parts.filter {!$0.isEmpty && $0.count <= 64 && !$0.hasPrefix(".") && !$0.hasSuffix(".") && !$0.contains("..") && $0.unicodeScalars.allSatisfy {CharacterSet.alphanumerics.contains($0) || ".-_+".unicodeScalars.contains($0)}}
                if accepted.count != parts.count || accepted.isEmpty {valid=false;notes.append("扩展名格式无效，请使用 ext:pdf 或 ext:pdf,png")}
                if token.excluded {excludedExtensions.formUnion(accepted)} else {extensions.formUnion(accepted)}
            } else if token.excluded {excluded.append(token.value);if token.phrase {excludedPhrases.insert(token.value)}}
            else {
                if !foundPositive {firstPositiveWasPhrase=token.phrase;foundPositive=true}
                if token.phrase {phrases.append(token.value)} else {ordinary.append(token.value)}
            }
        }
        let natural=NaturalQuery(ordinary.joined(separator:" "));var words=natural.text.split(whereSeparator:{$0.isWhitespace}).map(String.init),filter=fallback
        let aliases:[String:FileFilter]=["pdf":.pdf,"doc":.documents,"文档":.documents,"image":.images,"图片":.images,"audio":.audio,"音频":.audio,"video":.video,"视频":.video,"folder":.folders,"文件夹":.folders]
        if (!firstPositiveWasPhrase || !natural.descriptions.isEmpty),let first=words.first?.lowercased(),let type=aliases[first] {filter=type;words.removeFirst()}
        if lexed.unfinishedQuote {notes.append("引号尚未闭合，当前按短语搜索")}
        self.natural=natural;self.filter=filter;self.words=words;self.phrases=phrases;self.excluded=excluded;self.excludedPhrases=excludedPhrases;self.extensions=extensions;self.excludedExtensions=excludedExtensions;self.notes=notes;self.valid=valid
    }
    private func acceptsExtension(_ url:URL)->Bool {
        let name=normalized(url.lastPathComponent)
        func has(_ values:Set<String>)->Bool {values.contains {name.hasSuffix("."+$0)}}
        if !extensions.isEmpty || !excludedExtensions.isEmpty {
            var directory:ObjCBool=false
            if FileManager.default.fileExists(atPath:url.path,isDirectory:&directory),directory.boolValue,(try? url.resourceValues(forKeys:[.isPackageKey]).isPackage) != true {return extensions.isEmpty}
        }
        guard extensions.isEmpty || has(extensions),!has(excludedExtensions) else {return false}
        return true
    }
    // Apply this to every source, including aliases, before ranking. Positive ordinary
    // filename terms are scored separately so existing pinyin ranking stays intact.
    func acceptsURL(_ url:URL,mode:SearchMode,precision:SearchPrecision)->Bool {
        guard valid,acceptsExtension(url) else {return false}
        guard mode == .filename else {return true}
        let haystack=normalized(precision == .withPath ? url.path : url.lastPathComponent)
        return phrases.allSatisfy {haystack.contains(normalized($0))} && !excluded.contains {haystack.contains(normalized($0))}
    }
    func filenameScore(_ url:URL,precision:SearchPrecision)->Int? {
        guard acceptsURL(url,mode:.filename,precision:precision),let base=precision.score(url,words:words) else {return nil}
        let name=normalized(url.lastPathComponent),stem=normalized(url.deletingPathExtension().lastPathComponent)
        return base+phrases.reduce(0) {score,phrase in let term=normalized(phrase);return score+(name == term || stem == term ? 2000 : name.contains(term) ? 1000 : 400)}
    }
    func acceptsContent(_ text:String)->Bool {
        guard valid else {return false};let source=normalized(text),compact=source.filter {!$0.isWhitespace}
        // Ordinary OCR words may cross recognized line breaks. Quoted phrases keep
        // literal spacing, matching Spotlight's phrase semantics.
        return words.allSatisfy {source.contains(normalized($0)) || compact.contains(normalized($0).filter {!$0.isWhitespace})} && phrases.allSatisfy {source.contains(normalized($0))} && !excluded.contains {source.contains(normalized($0)) || (!excludedPhrases.contains($0) && compact.contains(normalized($0).filter {!$0.isWhitespace}))}
    }
    func metadataPredicates(mode:SearchMode,precision:SearchPrecision)->[NSPredicate] {
        guard valid else {return [NSPredicate(value:false)]}
        let attribute=mode.attribute
        func contains(_ value:String)->NSPredicate {
            let name=NSPredicate(format:"%K CONTAINS[cd] %@",attribute,value)
            if mode == .filename && precision == .withPath {return NSCompoundPredicate(orPredicateWithSubpredicates:[name,NSPredicate(format:"%K CONTAINS[cd] %@",NSMetadataItemPathKey,value)])}
            return name
        }
        var predicates=words.map {word -> NSPredicate in
            guard mode == .filename,word.count >= 2,normalized(word).unicodeScalars.allSatisfy({$0.isASCII}),!word.contains("*"),!word.contains("?"),!word.contains("\\") else {return contains(word)}
            let name=NSPredicate(format:"%K LIKE[cd] %@",NSMetadataItemFSNameKey,"*"+word.map(String.init).joined(separator:"*")+"*")
            if precision == .withPath {return NSCompoundPredicate(orPredicateWithSubpredicates:[name,NSPredicate(format:"%K CONTAINS[cd] %@",NSMetadataItemPathKey,word)])}
            return name
        }
        predicates += phrases.map(contains)
        predicates += excluded.map {NSCompoundPredicate(notPredicateWithSubpredicate:contains($0))}
        func extensionPredicate(_ values:Set<String>)->NSPredicate {NSCompoundPredicate(orPredicateWithSubpredicates:values.sorted().map {NSPredicate(format:"%K ENDSWITH[cd] %@",NSMetadataItemFSNameKey,"."+$0)})}
        if !extensions.isEmpty {predicates.append(extensionPredicate(extensions))}
        if !excludedExtensions.isEmpty {predicates.append(NSCompoundPredicate(notPredicateWithSubpredicate:extensionPredicate(excludedExtensions)))}
        return predicates
    }
    // Keeps quotes/operators when clearing date/type filters; losing the quotes can
    // turn a literal filename into a natural-language date filter.
    var textWithoutFilters:String {
        func quote(_ value:String)->String {"\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""}
        return (words+phrases.map(quote)+excluded.map {"-"+(excludedPhrases.contains($0) ? quote($0) : $0)}+(extensions.isEmpty ? [] : ["ext:"+extensions.sorted().joined(separator:",")])+(excludedExtensions.isEmpty ? [] : ["-ext:"+excludedExtensions.sorted().joined(separator:",")])).joined(separator:" ")
    }
    var positiveText32:String {
        func quote(_ value:String)->String {"\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""}
        return (words+phrases.map(quote)).joined(separator:" ")
    }
}

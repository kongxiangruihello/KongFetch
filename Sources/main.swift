import Compression
import Cocoa
import Quartz
import PDFKit
import Carbon
import UniformTypeIdentifiers
import ServiceManagement
import CoreServices
import CryptoKit

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
struct SearchInput {
    let words:[String]
    let filter:FileFilter
    init(_ text:String, fallback:FileFilter) {
        var parts=NaturalQuery(text).text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let aliases:[String:FileFilter] = ["pdf":.pdf,"doc":.documents,"文档":.documents,"image":.images,"图片":.images,"audio":.audio,"音频":.audio,"video":.video,"视频":.video,"folder":.folders,"文件夹":.folders]
        if let first=parts.first?.lowercased(), let type=aliases[first] { filter=type; parts.removeFirst() } else { filter=fallback }
        words=parts
    }
}
// Independently implemented; inspired by the published Cling/fzf matching principles.
let normalizedCache:NSCache<NSString,NSString> = { let c=NSCache<NSString,NSString>(); c.countLimit=50000; return c }()
func normalized(_ value:String)->String { if let saved=normalizedCache.object(forKey:value as NSString) { return saved as String }; let folded=value.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX")); normalizedCache.setObject(folded as NSString,forKey:value as NSString); return folded }
final class PinyinValue:NSObject { let forms:[String]; init(_ forms:[String]) { self.forms=forms } }
let pinyinCache:NSCache<NSString,PinyinValue> = { let c=NSCache<NSString,PinyinValue>(); c.countLimit=20000; return c }()
final class FilenameScoreValue:NSObject { let score:Int?; init(_ score:Int?) { self.score=score } }
let filenameScoreCache:NSCache<NSString,FilenameScoreValue> = { let c=NSCache<NSString,FilenameScoreValue>(); c.countLimit=50000; return c }()
func fuzzyScore(_ text:String,_ word:String)->Int? {
    let text=normalized(text),word=normalized(word)
    if word.isEmpty { return 0 }
    if text == word { return 1000 }
    if text.hasPrefix(word) { return 850 }
    if let r=text.range(of:word) { let offset=text.distance(from:text.startIndex,to:r.lowerBound); return 700-min(120,offset*3) }
    guard word.count >= 2,word.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
    let chars=Array(text), pattern=Array(word); var cursor=0,previous = -1,first = -1,score=380
    for ch in pattern {
        guard let hit=(cursor..<chars.count).first(where:{ chars[$0] == ch }) else { return nil }
        if first < 0 { first=hit }
        if hit == 0 || !chars[hit-1].isLetter && !chars[hit-1].isNumber { score += 28 }
        if previous >= 0 { score += hit == previous+1 ? 18 : -min(140,(hit-previous-1)*9) }
        previous=hit; cursor=hit+1
    }
    return max(40,score-min(100,first*3))
}
enum PinyinReadings {
    static let mappings:[(String,String,String)] = {
        let readings=["重庆":"chong qing","重阳":"chong yang","重新":"chong xin","重量":"zhong liang","音乐":"yin yue","乐器":"yue qi","乐清":"yue qing","长乐":"chang le","快乐":"kuai le","乐乐":"le le","长沙":"chang sha","长安":"chang an","长大":"zhang da","银行":"yin hang","行长":"hang zhang","行业":"hang ye","朝阳":"chao yang","厦门":"xia men"]
        return readings.map { ($0.key,normalized($0.key.applyingTransform(.toLatin,reverse:false) ?? $0.key),$0.value) }.sorted { $0.0 < $1.0 }
    }()
}
func pinyinForms(_ name:String)->[String] {
    if let cached=pinyinCache.object(forKey:name as NSString) { return cached.forms }
    guard name.unicodeScalars.contains(where:{ (0x3400...0x9fff).contains($0.value) }) else { return [] }
    var latin=normalized(name.applyingTransform(.toLatin,reverse:false) ?? name)
    // Phrase readings avoid blindly expanding every polyphonic character.
    for (phrase,original,reading) in PinyinReadings.mappings where name.contains(phrase) { latin=latin.replacingOccurrences(of:original,with:reading) }
    let parts=latin.split(whereSeparator:{ !$0.isLetter && !$0.isNumber }); let forms=[parts.joined(),String(parts.compactMap(\.first))]; pinyinCache.setObject(PinyinValue(forms),forKey:name as NSString); return forms
}
func pinyinScore(_ forms:[String],_ word:String)->Int? {
    let word=normalized(word); guard word.count >= 2,word.unicodeScalars.allSatisfy({ $0.isASCII }),word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
    // Full spelling and initials must be contiguous; sparse phonetic subsequences are noisy.
    return forms.compactMap { form -> Int? in guard form.contains(word) else { return nil }; return form == word ? 600 : (form.hasPrefix(word) ? 550 : 450) }.max()
}
func filenameScore(_ url:URL,words:[String])->Int? {
    let key=(url.path+"\u{001E}"+words.map(normalized).joined(separator:"\u{001F}")) as NSString
    if let cached=filenameScoreCache.object(forKey:key) { return cached.score }
    let score=computeFilenameScore(url,words:words); filenameScoreCache.setObject(FilenameScoreValue(score),forKey:key); return score
}
func computeFilenameScore(_ url:URL,words:[String])->Int? {
    if words.isEmpty { return 0 }
    let name=url.lastPathComponent,stem=url.deletingPathExtension().lastPathComponent
    let phrase=normalized(words.joined(separator:" "))
    if normalized(name) == phrase || normalized(stem) == phrase { return 2000*words.count }
    var total=0; var forms:[String]?
    for word in words {
        if let score=fuzzyScore(name,word) { total += score+200; continue }
        if let score=fuzzyScore(url.deletingLastPathComponent().path,word),normalized(word).count >= 2 { total += min(350,score/2); continue }
        if word.unicodeScalars.allSatisfy({ $0.isASCII }),word.count >= 2 {
            if forms == nil { forms=pinyinForms(stem) }
            if let score=pinyinScore(forms!,word) { total += min(600,score); continue }
        }
        return nil
    }
    return total
}
func matchingReasons(_ url:URL,words:[String])->[String] {
    var result:[String]=[]
    for word in words {
        let reason:String
        if fuzzyScore(url.lastPathComponent,word) != nil { reason=normalized(url.lastPathComponent).contains(normalized(word)) ? "文件名" : "文件名缩写" }
        else if normalized(word).count >= 2 && fuzzyScore(url.deletingLastPathComponent().path,word) != nil { reason="路径" }
        else if pinyinScore(pinyinForms(url.deletingPathExtension().lastPathComponent),word) != nil { reason="拼音" }
        else { continue }
        if !result.contains(reason) { result.append(reason) }
    }
    return result
}
func highlightedName(_ text:String,words:[String])->NSAttributedString {
    let result=NSMutableAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:14,weight:.medium),.foregroundColor:NSColor.labelColor])
    for word in words {
        var ranges=matchRanges(text,words:[word])
        if ranges.isEmpty && fuzzyScore(text,word) != nil {
            let source=text as NSString; var start=0
            for ch in word { let range=source.range(of:String(ch),options:[.caseInsensitive,.diacriticInsensitive],range:NSRange(location:start,length:source.length-start)); if range.location == NSNotFound { ranges=[]; break }; ranges.append(range); start=range.location+range.length }
        }
        for range in ranges { result.addAttribute(.backgroundColor,value:NSColor.systemYellow.withAlphaComponent(0.35),range:range) }
    }
    return result
}
func rankEntries(_ entries:[Entry], words:[String], counts:[String:Int],preferredPath:String?=nil,manualPath:String?=nil,aliasPath:String?=nil)->[Entry] {
    let scored=entries.compactMap { e -> (Entry,Int)? in guard let score=(e.url.path == aliasPath || e.url.path == manualPath ? 3000*max(1,words.count) : filenameScore(e.url,words:words)) else { return nil }; return (e,score) }
    return scored.sorted { a,b in
        if (a.0.url.path == manualPath) != (b.0.url.path == manualPath) { return a.0.url.path == manualPath }
        if a.1 != b.1 { return a.1 > b.1 }
        if (a.0.url.path == preferredPath) != (b.0.url.path == preferredPath) { return a.0.url.path == preferredPath }
        let ca=min(20,counts[a.0.url.path,default:0]),cb=min(20,counts[b.0.url.path,default:0]); if ca != cb { return ca > cb }
        if a.0.modified != b.0.modified { return (a.0.modified ?? .distantPast) > (b.0.modified ?? .distantPast) }
        return a.0.url.path.localizedStandardCompare(b.0.url.path) == .orderedAscending
    }.map { $0.0 }
}
func sortFiles(_ entries:[Entry],mode:Int)->[Entry] {
    guard mode != 0 else { return entries }
    return entries.sorted { a,b in
        switch mode {
        case 1: if a.modified != b.modified { return (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
        case 3: if a.directory != b.directory { return !a.directory }; if a.size != b.size { return a.size > b.size }
        default: break
        }
        let order=a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
        return order == .orderedSame ? a.url.path < b.url.path : order == .orderedAscending
    }
}
func compactLocation(_ url:URL, peers:[URL])->String {
    let parent=url.deletingLastPathComponent().path
    let cloud=NSHomeDirectory()+"/Library/Mobile Documents/com~apple~CloudDocs"
    if parent == cloud { return "iCloud" }
    if parent.hasPrefix(cloud+"/") { return "iCloud/"+String(parent.dropFirst(cloud.count+1)) }
    let same=peers.filter { normalized($0.lastPathComponent) == normalized(url.lastPathComponent) }
    let parts=url.deletingLastPathComponent().pathComponents
    if same.count > 1 {
        for depth in 1...max(1,parts.count) {
            let suffix=parts.suffix(depth).joined(separator:"/")
            if same.filter({ $0.deletingLastPathComponent().pathComponents.suffix(depth).joined(separator:"/") == suffix }).count == 1 { return suffix }
        }
    }
    return (parent as NSString).abbreviatingWithTildeInPath
}
struct CatalogResult { var urls:[URL]=[]; var limited=false; var unreadable=0; var inaccessible:[String]=[]; var updated:Date? }
func scanNames(_ roots:[URL],maximum:Int=Int.max,excluding:[String]=[],progress:(String,Int)->Void = { _,_ in },throttle:()->Void = {},cancelled:()->Bool)->CatalogResult {
    var result=CatalogResult(); var seen=Set<String>(); let excludedPaths=excluding.map { canonicalIndexPath(URL(fileURLWithPath:$0).resolvingSymlinksInPath()) }
    for root in roots {
        if cancelled() { return result }; if excludedPaths.contains(where:{ let path=canonicalIndexPath(root); return path == $0 || path.hasPrefix($0+"/") }) { continue }; progress(root.path,result.urls.count)
        guard let walker=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isPackageKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles,.skipsPackageDescendants],errorHandler:{ url,_ in result.unreadable += 1; if result.inaccessible.count < 20 { result.inaccessible.append(url.path) }; return true }) else { result.unreadable += 1; result.inaccessible.append(root.path); continue }
        var traversed=0
        for case let url as URL in walker {
            traversed += 1; if traversed % 128 == 0 { throttle() }
            if cancelled() { return result }
            if excludedPaths.contains(where:{ let path=canonicalIndexPath(url); return path == $0 || path.hasPrefix($0+"/") }) { walker.skipDescendants(); continue }
            if ["node_modules","Library",".git","build","DerivedData"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let values=try? url.resourceValues(forKeys:[.isSymbolicLinkKey]); if values?.isSymbolicLink == true { walker.skipDescendants() }
            if seen.insert(url.path).inserted { result.urls.append(url); if result.urls.count % 1000 == 0 { progress(root.path,result.urls.count) } }
            if result.urls.count >= maximum { result.limited=true; return result }
        }
    }
    result.updated=Date(); return result
}

func canonicalIndexPath(_ url:URL)->String {
    let path=url.standardizedFileURL.path
    return path == "/tmp" ? "/private/tmp" : (path.hasPrefix("/tmp/") ? "/private"+path : path)
}
func updateCatalog(_ original:CatalogResult,paths:[String],roots:[URL],excluding:[String],throttle:()->Void = {},cancelled:()->Bool)->CatalogResult {
    let canonicalRoots=roots.map { canonicalIndexPath($0.resolvingSymlinksInPath()) }; let canonicalExclusions=excluding.map { canonicalIndexPath(URL(fileURLWithPath:$0).resolvingSymlinksInPath()) }
    var changed=Set(paths.map { canonicalIndexPath(URL(fileURLWithPath:$0).resolvingSymlinksInPath()) })
    changed=Set(changed.filter { path in canonicalRoots.contains { path == $0 || path.hasPrefix($0+"/") } })
    let minimal=changed.filter { path in !changed.contains { $0 != path && path.hasPrefix($0+"/") } }.sorted()
    var urls=Dictionary(original.urls.filter { url in let path=canonicalIndexPath(url); return !canonicalExclusions.contains { path == $0 || path.hasPrefix($0+"/") } }.map { (canonicalIndexPath($0),$0) },uniquingKeysWith:{ a,_ in a })
    var result=original
    for path in minimal {
        if cancelled() { return original }
        urls=urls.filter { $0.key != path && !$0.key.hasPrefix(path+"/") }
        guard let root=canonicalRoots.first(where:{ path == $0 || path.hasPrefix($0+"/") }) else { continue }
        let relative=String(path.dropFirst(root.count))
        if relative.split(separator:"/").contains(where:{ $0.hasPrefix(".") || ["node_modules","Library","build","DerivedData"].contains(String($0)) }) || canonicalExclusions.contains(where:{ path == $0 || path.hasPrefix($0+"/") }) { continue }
        let url=URL(fileURLWithPath:path)
        var ancestor=url.deletingLastPathComponent(); var packageChild=false
        while ancestor.path != root && ancestor.path.count > root.count {
            if (try? ancestor.resourceValues(forKeys:[.isPackageKey]))?.isPackage == true { packageChild=true; break }
            ancestor=ancestor.deletingLastPathComponent()
        }
        if packageChild { continue }
        guard FileManager.default.fileExists(atPath:path),let values=try? url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isPackageKey]) else { continue }
        urls[path]=url
        if values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true {
            let subtree=scanNames([url],excluding:excluding,throttle:throttle,cancelled:cancelled)
            for item in subtree.urls { urls[canonicalIndexPath(item)]=item }
            result.inaccessible=Array(Set(result.inaccessible.filter { !$0.hasPrefix(path) }+subtree.inaccessible)).sorted(); result.unreadable=result.inaccessible.count
        }
    }
    result.urls=Array(urls.values); result.updated=Date(); return result
}

struct ContentEvidence {
    let excerpt:String
    let document:PDFDocument?
    let matches:[PDFSelection]
    let limited:Bool
}
func matchRanges(_ text:String,words:[String],allowWhitespace:Bool=false)->[NSRange] {
    let source=text as NSString; var result:[NSRange]=[]
    for word in Set(words.filter { !$0.isEmpty }) {
        if allowWhitespace,word.count <= 80,source.range(of:word,options:[.caseInsensitive,.diacriticInsensitive]).location == NSNotFound {
            let pattern=word.map { NSRegularExpression.escapedPattern(for:String($0)) }.joined(separator:"\\s*")
            if let regex=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) { result += regex.matches(in:text,range:NSRange(location:0,length:source.length)).prefix(max(0,2000-result.count)).map(\.range) }; continue
        }
        var start=0
        while start < source.length && result.count < 2000 {
            let range=source.range(of:word,options:[.caseInsensitive,.diacriticInsensitive],range:NSRange(location:start,length:source.length-start))
            if range.location == NSNotFound { break }; result.append(range); start=range.location+max(1,range.length)
        }
    }
    return result.sorted { $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location }
}
func excerptText(_ text:String,words:[String],allowWhitespace:Bool=false)->String {
    let source=text as NSString
    guard let hit=matchRanges(text,words:words,allowWhitespace:allowWhitespace).first else { return "正文可读取，但未找到当前关键词；索引可能尚未更新。" }
    let start=max(0,hit.location-45), end=min(source.length,hit.location+hit.length+100)
    return (start > 0 ? "…" : "")+source.substring(with:NSRange(location:start,length:end-start)).replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")+(end < source.length ? "…" : "")
}
func readEvidence(_ url:URL,words:[String],keepPDF:Bool,cancelled:()->Bool = { false })->ContentEvidence {
    func plain(_ text:String)->ContentEvidence { ContentEvidence(excerpt:text,document:nil,matches:[],limited:false) }
    guard let values=try? url.resourceValues(forKeys:[.fileSizeKey,.contentTypeKey]),let bytes=values.fileSize else { return plain("文件不可读取，可能已移动或尚未下载。") }
    if cancelled() { return plain("已取消摘要读取") }
    let type=values.contentType ?? UTType(filenameExtension:url.pathExtension)
    if type?.conforms(to:.pdf) == true {
        guard bytes <= 50*1024*1024 else { return plain("PDF 超过 50 MB，仍可预览；暂不生成摘要与命中定位。") }
        guard let doc=PDFDocument(url:url),!doc.isLocked else { return plain("PDF 无法读取或已加密，无法提取正文。") }
        var firstText=""; var matches:[PDFSelection]=[]; var characters=0
        let pages=min(doc.pageCount,200)
        for index in 0..<pages {
            if cancelled() { return plain("已取消摘要读取") }
            guard let page=doc.page(at:index),let text=page.string else { continue }
            characters += text.utf16.count
            let ranges=matchRanges(text,words:words)
            if firstText.isEmpty && !ranges.isEmpty { firstText=excerptText(text,words:words) }
            if keepPDF { for range in ranges.prefix(max(0,2000-matches.count)) { if let selection=page.selection(for:range) { matches.append(selection) } } }
            if (!keepPDF && !firstText.isEmpty) || characters > 2_000_000 || matches.count >= 2000 { break }
        }
        let limited=doc.pageCount > pages || characters > 2_000_000 || matches.count >= 2000
        if firstText.isEmpty { firstText="未提取到命中文字；扫描件可能需要 OCR，或索引尚未更新。" }
        return ContentEvidence(excerpt:firstText,document:keepPDF ? doc : nil,matches:matches,limited:limited)
    }
    guard type?.conforms(to:.plainText) == true || ["md","csv","log","json","yaml","yml","swift","py","js","ts"].contains(url.pathExtension.lowercased()) else { return plain("此格式暂不支持命中摘要，可继续使用系统预览。") }
    guard bytes <= 4*1024*1024 else { return plain("文本超过 4 MB，暂不生成摘要。") }
    guard let data=try? Data(contentsOf:url),let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) else { return plain("无法识别文本编码，可继续使用系统预览。") }
    return plain(excerptText(text,words:words))
}
struct StoredCatalog:Codable { let version:Int; let roots:[String]; let paths:[String]; let unreadable:Int; let inaccessible:[String]?; let updated:Date? }
final class CatalogStore {
    final class Cached:NSObject {
        let result:CatalogResult,roots:[String],modified:Date,size:Int
        init(_ result:CatalogResult,roots:[String],modified:Date,size:Int) { self.result=result; self.roots=roots; self.modified=modified; self.size=size }
    }
    let directory:URL
    let cache:NSCache<NSString,Cached> = { let c=NSCache<NSString,Cached>(); c.countLimit=8; c.totalCostLimit=300000; return c }()
    init(_ directory:URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KongFetch/Indexes")) { self.directory=directory }
    func file(_ key:String)->URL { directory.appendingPathComponent(SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()+".kfi") }
    func attributes(_ url:URL)->(Date,Int)? { guard let values=try? FileManager.default.attributesOfItem(atPath:url.path),let date=values[.modificationDate] as? Date,let size=values[.size] as? Int else { return nil }; return (date,size) }
    func remember(_ result:CatalogResult,key:String,roots:[URL],url:URL) { if let (date,size)=attributes(url) { cache.setObject(Cached(result,roots:roots.map(\.path),modified:date,size:size),forKey:key as NSString,cost:result.urls.count) } }
    func load(_ key:String,roots:[URL])->CatalogResult? {
        let modern=file(key),legacy=modern.deletingPathExtension().appendingPathExtension("json")
        let url=FileManager.default.fileExists(atPath:modern.path) ? modern : legacy
        if let (date,size)=attributes(url),let saved=cache.object(forKey:key as NSString),saved.modified == date,saved.size == size,saved.roots == roots.map(\.path) { return saved.result }
        guard var data=try? Data(contentsOf:url,options:.mappedIfSafe) else { return nil }
        if data.starts(with:Data("KFZ1".utf8)) {
            guard data.count >= 12 else { return nil }; var length:UInt64=0; for offset in 0..<8 { length |= UInt64(data[4+offset]) << (offset*8) }
            guard length > 0,length <= 512*1024*1024 else { return nil }; let payload=Data(data.dropFirst(12)); var unpacked=Data(count:Int(length))
            let count=unpacked.withUnsafeMutableBytes { destination in payload.withUnsafeBytes { source in compression_decode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,Int(length),source.bindMemory(to:UInt8.self).baseAddress!,payload.count,nil,COMPRESSION_LZFSE) } }
            guard count == Int(length) else { return nil }; data=unpacked
        }
        guard let saved=(try? JSONDecoder().decode(StoredCatalog.self,from:data)) ?? (try? PropertyListDecoder().decode(StoredCatalog.self,from:data)),saved.version == 1,saved.roots == roots.map(\.path) else { return nil }
        let result=CatalogResult(urls:saved.paths.map { URL(fileURLWithPath:$0) },limited:false,unreadable:saved.unreadable,inaccessible:saved.inaccessible ?? [],updated:saved.updated)
        remember(result,key:key,roots:roots,url:url); return result
    }
    func save(_ result:CatalogResult,key:String,roots:[URL]) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let saved=StoredCatalog(version:1,roots:roots.map(\.path),paths:result.urls.map(\.path),unreadable:result.unreadable,inaccessible:result.inaccessible,updated:result.updated ?? Date())
        let source=try JSONEncoder().encode(saved); var buffer=Data(count:source.count+source.count/16+256)
        let capacity=buffer.count; let count=buffer.withUnsafeMutableBytes { destination in source.withUnsafeBytes { input in compression_encode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,capacity,input.bindMemory(to:UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZFSE) } }
        var data=source
        if count > 0 && count+12 < source.count { data=Data("KFZ1".utf8); var length=UInt64(source.count).littleEndian; withUnsafeBytes(of:&length) { data.append(contentsOf:$0) }; data.append(buffer.prefix(count)) }
        try data.write(to:file(key),options:.atomic); var complete=result; complete.updated=saved.updated; remember(complete,key:key,roots:roots,url:file(key)); try? FileManager.default.removeItem(at:file(key).deletingPathExtension().appendingPathExtension("json"))
    }
    func invalidate(_ key:String) { cache.removeObject(forKey:key as NSString); try? FileManager.default.removeItem(at:file(key)); try? FileManager.default.removeItem(at:file(key).deletingPathExtension().appendingPathExtension("json")) }
}
final class SearchWindow:NSWindow {
    override var canBecomeKey:Bool { true }
    override var canBecomeMain:Bool { true }
}
func editDistance(_ a:String,_ b:String)->Int {
    let x=Array(normalized(a)),y=Array(normalized(b)); if x.count > 64 || y.count > 64 { return 100 }
    var previous=Array(0...y.count)
    for (i,c) in x.enumerated() { var row=[i+1]; for (j,d) in y.enumerated() { row.append(min(row[j]+1,previous[j+1]+1,previous[j]+(c == d ? 0 : 1))) }; previous=row }
    return previous[y.count]
}
final class ThemeSurface:NSView {
    let separator:Bool
    init(separator:Bool=false) { self.separator=separator; super.init(frame:.zero); wantsLayer=true }
    required init?(coder:NSCoder) { fatalError() }
    override var wantsUpdateLayer:Bool { true }
    override func updateLayer() { layer?.backgroundColor=(separator ? NSColor.separatorColor : NSColor.windowBackgroundColor).cgColor }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay=true }
}

final class RoundedRow: NSTableRowView {
    override func drawSelection(in dirtyRect:NSRect) {
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:2,dy:2),xRadius:16,yRadius:16).fill()
    }
    override var isEmphasized:Bool { get { false } set {} }
}
struct ControlDoubleTap {
    var pressedAt: Double?
    var lastRelease: Double?
    mutating func reset() { pressedAt=nil; lastRelease=nil }
    mutating func update(control:Bool, other:Bool, key:Bool, time:Double) -> Bool {
        if other || key { reset(); return false }
        if control { if pressedAt == nil { pressedAt=time }; return false }
        guard let down=pressedAt else { return false }; pressedAt=nil
        guard time-down <= 0.45 else { lastRelease=nil; return false }
        if let previous=lastRelease, down-previous <= 0.5, down >= previous { lastRelease=nil; return true }
        lastRelease=time; return false
    }
}
final class ControlWakeMonitor {
    var detector=ControlDoubleTap()
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var wake: (() -> Void)?
    var lastEvent:Date?
    var lastWake:Date?
    var lastBackgroundEvent:Date?
    var lastWakeWasGlobal=false
    var recoveryTimer:Timer?
    var localMonitor:Any?
    var isListening:Bool { tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap:$0) } ?? false }
    func enable() {
        if recoveryTimer != nil { recover(); return }
        _=start()
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:[.flagsChanged,.keyDown]) { [weak self] event in
            guard let self,!self.isListening else { return event }
            let flags=event.modifierFlags
            self.lastEvent=Date()
            let unrelated=event.type == .flagsChanged && event.keyCode != 59 && event.keyCode != 62
            if self.detector.update(control:flags.contains(.control),other:unrelated || !flags.intersection([.command,.option,.shift,.function]).isEmpty,key:event.type == .keyDown,time:event.timestamp) { self.lastWake=Date(); self.lastWakeWasGlobal=false; DispatchQueue.main.async { self.wake?() } }
            return event
        }
        recoveryTimer=Timer(timeInterval:2,repeats:true) { [weak self] _ in self?.recover() }
        RunLoop.main.add(recoveryTimer!,forMode:.common)
    }
    func recover() {
        if isListening { return }
        if let tap,CFMachPortIsValid(tap) { CGEvent.tapEnable(tap:tap,enable:true) }
        if !isListening && CGPreflightListenEventAccess() { _=start() }
    }
    func disable() {
        recoveryTimer?.invalidate(); recoveryTimer=nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor=nil
        stop()
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap:tap,enable:false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        tap=nil; source=nil; detector.reset()
    }
    func start() -> Bool {
        stop()
        let mask=(CGEventMask(1)<<CGEventType.flagsChanged.rawValue) | (CGEventMask(1)<<CGEventType.keyDown.rawValue)
        tap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.listenOnly,eventsOfInterest:mask,callback:{ _,type,event,context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor=Unmanaged<ControlWakeMonitor>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.detector.reset(); if let tap=monitor.tap { CGEvent.tapEnable(tap:tap,enable:true) }; return Unmanaged.passUnretained(event)
            }
            monitor.lastEvent=Date(); if !NSApp.isActive { monitor.lastBackgroundEvent=Date() }
            let flags=event.flags
            let other = !flags.intersection([.maskCommand,.maskAlternate,.maskShift,.maskSecondaryFn]).isEmpty
            let code=event.getIntegerValueField(.keyboardEventKeycode)
            let unrelatedModifier = type == .flagsChanged && code != 59 && code != 62
            if monitor.detector.update(control:flags.contains(.maskControl),other:other || unrelatedModifier,key:type == .keyDown,time:Double(event.timestamp)/1_000_000_000) {
                monitor.lastWake=Date(); monitor.lastWakeWasGlobal = !NSApp.isActive; DispatchQueue.main.async { monitor.wake?() }
            }
            return Unmanaged.passUnretained(event)
        },userInfo:Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes); CGEvent.tapEnable(tap:tap,enable:true); return CGEvent.tapIsEnabled(tap:tap)
    }
    deinit { disable() }
}

final class ShortcutField: NSTextField {
    var record: ((NSEvent) -> Void)?
    override func keyDown(with event: NSEvent) { record?(event) }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); stringValue = "请按下组合键…" }
}
final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: NSWindow!
    let table = NSTableView()
    let search = NSSearchField()
    let path = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    let titleLabel = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "选择文件查看预览")
    var preview: QLPreviewView!
    let pdfView=PDFView()
    let evidenceLabel=NSTextField(wrappingLabelWithString:"")
    let matchLabel=NSTextField(labelWithString:"")
    var evidenceHeight:NSLayoutConstraint!
    var matchesHeight:NSLayoutConstraint!
    var matchesBar:NSStackView!
    var previewFixture:URL?
    lazy var previousMatch=button("←",#selector(previousPDFMatch))
    lazy var nextMatch=button("→",#selector(nextPDFMatch))
    let evidenceQueue:OperationQueue = { let q=OperationQueue(); q.maxConcurrentOperationCount=2; q.qualityOfService = .utility; return q }()
    let previewQueue:OperationQueue = { let q=OperationQueue(); q.maxConcurrentOperationCount=1; q.qualityOfService = .userInitiated; return q }()
    lazy var cancelButton=button("取消",#selector(cancelSearch))
    var snippetOrder:[String]=[]
    var snippets:[String:String]=[:]
    var snippetRequests=Set<String>()
    var previewToken=UUID()
    var pdfMatches:[PDFSelection]=[]
    var matchIndex=0
    var pdfLimited=false
    let scopePicker=NSPopUpButton()
    let searchModePicker=NSPopUpButton()
    var searchMode:SearchMode = .filename
    let catalogQueue:OperationQueue = { let q=OperationQueue(); q.maxConcurrentOperationCount=1; q.qualityOfService = .utility; return q }()
    var catalogCache:[String:(Date,CatalogResult)]=[:]
    var validatedCatalogs=Set<String>()
    var catalogStore=CatalogStore()
    var catalogToken=UUID()
    var catalogSaveFailed=false
    var extraRoots:[String]=[]
    var savedScopeOverride:[String]?
    var qaSuite:String?
    var savedSearches:[[String:Any]] { preferences.array(forKey:"savedSearches") as? [[String:Any]] ?? [] }
    func captureSearch(_ name:String)->[String:Any] {
        return ["name":name,"query":search.stringValue,"all":scopeAll,"folder":folder.path,"roots":activeSearchRoots,"filter":fileFilter.rawValue,"dateFilter":dateFilter,"sizeFilter":sizeFilter,"dateField":dateField,"customStart":customStart,"customEnd":customEnd,"searchMode":searchMode.rawValue]
    }
    func applySavedSearch(_ item:[String:Any]) {
        let all=item["all"] as? Bool ?? true; let target=URL(fileURLWithPath:item["folder"] as? String ?? NSHomeDirectory())
        if !all && !FileManager.default.fileExists(atPath:target.path) { status.stringValue="保存的搜索目录不可访问，请连接磁盘或重新选择目录"; return }
        stopQuery(); localCollection=nil; showingRecent=false; scopeAll=all; folder=target
        savedScopeOverride=scopeAll ? item["roots"] as? [String] : nil
        if scopeAll { scopePicker.selectItem(at:0) } else { if scopePicker.numberOfItems > 7 { scopePicker.removeItem(at:7) }; scopePicker.addItem(withTitle:"文件夹："+folder.lastPathComponent); scopePicker.selectItem(at:7) }
        fileFilter=FileFilter(rawValue:item["filter"] as? Int ?? 0) ?? .all; filterPicker.selectItem(at:fileFilter.rawValue)
        dateFilter=min(4,max(0,item["dateFilter"] as? Int ?? 0)); sizeFilter=min(3,max(0,item["sizeFilter"] as? Int ?? 0)); dateField=min(1,max(0,item["dateField"] as? Int ?? 0)); customStart=item["customStart"] as? Date ?? Date(); customEnd=item["customEnd"] as? Date ?? Date()
        searchMode=SearchMode(rawValue:item["searchMode"] as? Int ?? 0) ?? .filename; updateSearchModeUI(); updateFilterSummary(); search.stringValue=item["query"] as? String ?? ""; startSearch(); saveState()
    }
    @objc func saveCurrentSearch() {
        let alert=NSAlert(); alert.messageText="保存常用搜索"; alert.informativeText="保存关键词、范围、搜索模式和筛选条件。同名搜索会更新。"; alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"取消")
        let field=NSTextField(string:search.stringValue.isEmpty ? "常用搜索" : search.stringValue); field.frame=NSRect(x:0,y:0,width:320,height:26); alert.accessoryView=field
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .alertFirstButtonReturn else { return }; let name=String(field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).prefix(64)); guard !name.isEmpty else { return }
            var items=self.savedSearches.filter { $0["name"] as? String != name }; items.insert(self.captureSearch(name),at:0); self.preferences.set(Array(items.prefix(50)),forKey:"savedSearches"); self.status.stringValue="已保存搜索："+name
        }
    }
    @objc func chooseSavedSearch(_ sender:NSMenuItem) { if let item=sender.representedObject as? [String:Any] { applySavedSearch(item) } }
    @objc func deleteSavedSearch() {
        let items=savedSearches; guard !items.isEmpty else { return }
        let alert=NSAlert(); alert.messageText="移除常用搜索"; alert.addButton(withTitle:"移除"); alert.addButton(withTitle:"取消"); let picker=NSPopUpButton(); picker.addItems(withTitles:items.map { $0["name"] as? String ?? "搜索" }); picker.frame=NSRect(x:0,y:0,width:320,height:28); alert.accessoryView=picker
        alert.beginSheetModal(for:window) { [weak self] response in guard let self,response == .alertFirstButtonReturn else { return }; var remaining=items; remaining.remove(at:picker.indexOfSelectedItem); self.preferences.set(remaining,forKey:"savedSearches") }
    }
    var watchingRoots:[URL]=[]
    var watchStream:FSEventStreamRef?
    var indexTimer:Timer?
    var pendingChanges=Set<String>()
    var needsFullRefresh=false
    var incrementalUpdates=0
    var fullScans=0
    var indexSummary="尚未建立文件索引"
    weak var indexStatusText:NSTextField?
    func reportIndex(_ text:String) { indexSummary=text; if directoryPicker == nil { indexStatusText?.stringValue=text; indexStatusText?.toolTip=text } }
    func catalogSummary(_ catalog:CatalogResult)->String {
        let time=catalog.updated.map { dateFormat.string(from:$0) } ?? "未知"
        var text="已收录 \(catalog.urls.count) 项 · 上次更新：\(time)"
        if !catalog.inaccessible.isEmpty { text += "\n无法访问：\n"+catalog.inaccessible.prefix(10).joined(separator:"\n") }
        return text
    }
    lazy var widenButton=button("搜索全部目录",#selector(widenSearch))
    lazy var emptyClearButton=button("清除筛选后重试",#selector(clearSearchRestrictions))
    var trackedMenus=Set<ObjectIdentifier>()
    var menuTracking:Bool { !trackedMenus.isEmpty }
    func menuWillOpen(_ menu:NSMenu) { trackedMenus.insert(ObjectIdentifier(menu)) }
    func menuDidClose(_ menu:NSMenu) { trackedMenus.remove(ObjectIdentifier(menu)) }
    func observeMenu(_ menu:NSMenu) { menu.delegate=self; for item in menu.items { if let sub=item.submenu { observeMenu(sub) } } }
    func presentMenu(_ menu:NSMenu,view:NSView) { observeMenu(menu); menu.popUp(positioning:nil,at:NSPoint(x:0,y:view.bounds.height),in:view) }
    var sortMode:Int { min(3,max(0,preferences.integer(forKey:"sortMode"))) }
    let sortTitles=["相关度","最近修改","名称","大小（从大到小）"]
    @objc func changeSort(_ sender:NSMenuItem) {
        let urls=selectedURLs; preferences.set(sender.tag,forKey:"sortMode")
        if !search.stringValue.isEmpty && localCollection == nil { renderSearchResults() }
        else if localCollection != nil { loadLocalCollection(localCollection!) }
        else if showingRecent { entries.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }; refreshList() }
        else { entries=browseEntries.filter(fileFilter.accepts).filter(acceptsDetails); refreshList() }
        selectURLs(urls); status.stringValue="排序："+sortTitles[sortMode]
    }
    @objc func showPathNavigation() {
        let url=scopeAll ? (selected?.url.deletingLastPathComponent() ?? URL(fileURLWithPath:NSHomeDirectory())) : folder
        let menu=NSMenu(); var ancestor=url
        while true { let item=NSMenuItem(title:(ancestor.path as NSString).abbreviatingWithTildeInPath,action:#selector(navigatePath(_:)),keyEquivalent:""); item.target=self; item.representedObject=ancestor; menu.addItem(item); if ancestor.path == "/" { break }; ancestor=ancestor.deletingLastPathComponent() }
        presentMenu(menu,view:navigationButton)
    }
    @objc func navigatePath(_ sender:NSMenuItem) { if let url=sender.representedObject as? URL { browse(url) } }
    lazy var recentSearchButton:NSButton = { let b=button("◷",#selector(showRecentSearches)); b.widthAnchor.constraint(equalToConstant:24).isActive=true; b.toolTip="最近搜索 · ⌘H"; return b }()
    lazy var navigationButton:NSButton = { let b=button("路径",#selector(showPathNavigation)); b.widthAnchor.constraint(equalToConstant:56).isActive=true; b.cell?.lineBreakMode = .byTruncatingTail; return b }()
    func updateNavigation() { navigationButton.title=scopeAll ? "路径" : folder.lastPathComponent; navigationButton.toolTip=scopeAll ? "查看选中文件的路径层级" : folder.path; navigationButton.isHidden=scopeAll && selected == nil }
    var recentSearches:[String] { preferences.stringArray(forKey:"recentSearches") ?? [] }
    var suppressedHistoryTerm:String?
    var recentSearchTimer:Timer?
    var recordsRecentSearches:Bool { preferences.object(forKey:"recordsRecentSearches") as? Bool ?? true }
    func scheduleRecentSearch(_ term:String) { recentSearchTimer?.invalidate(); if let suppressedHistoryTerm,suppressedHistoryTerm != normalized(term) { self.suppressedHistoryTerm=nil }; guard recordsRecentSearches,suppressedHistoryTerm != normalized(term) else { return }; recentSearchTimer=Timer.scheduledTimer(withTimeInterval:1.5,repeats:false) { [weak self] _ in guard let self,self.search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines) == term else { return }; self.rememberRecentSearch(term) } }
    func rememberRecentSearch(_ term:String) { guard recordsRecentSearches,!term.isEmpty,suppressedHistoryTerm != normalized(term) else { return }; var items=recentSearches.filter { normalized($0) != normalized(term) }; items.insert(term,at:0); preferences.set(Array(items.prefix(30)),forKey:"recentSearches") }
    @objc func chooseRecentSearch(_ sender:NSMenuItem) { guard let term=sender.representedObject as? String else { return }; search.stringValue=term; startSearch(); window.makeFirstResponder(search) }
    @objc func removeRecentSearch(_ sender:NSMenuItem) { guard let term=sender.representedObject as? String else { return }; preferences.set(recentSearches.filter { $0 != term },forKey:"recentSearches") }
    @objc func clearRecentSearches() { recentSearchTimer?.invalidate(); suppressedHistoryTerm=normalized(search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)); preferences.removeObject(forKey:"recentSearches"); status.stringValue="已清空最近搜索" }
    @objc func toggleSearchRecording() { preferences.set(!recordsRecentSearches,forKey:"recordsRecentSearches"); recentSearchTimer?.invalidate(); status.stringValue=recordsRecentSearches ? "已开启搜索记录" : "已关闭搜索记录，已有记录可单独清空" }
    @objc func showRecentSearches() {
        let menu=NSMenu(); menu.autoenablesItems=false
        for term in recentSearches { let item=NSMenuItem(title:term,action:#selector(chooseRecentSearch(_:)),keyEquivalent:""); item.target=self; item.representedObject=term; menu.addItem(item) }
        menu.addItem(.separator())
        let toggle=NSMenuItem(title:recordsRecentSearches ? "关闭搜索记录" : "开启搜索记录",action:#selector(toggleSearchRecording),keyEquivalent:""); toggle.target=self; menu.addItem(toggle)
        let remove=NSMenuItem(title:"删除某条记录",action:nil,keyEquivalent:""); let sub=NSMenu(); for term in recentSearches { let item=NSMenuItem(title:term,action:#selector(removeRecentSearch(_:)),keyEquivalent:""); item.target=self; item.representedObject=term; sub.addItem(item) }; remove.submenu=sub; remove.isEnabled = !recentSearches.isEmpty; menu.addItem(remove)
        let clear=NSMenuItem(title:"清空最近搜索",action:#selector(clearRecentSearches),keyEquivalent:""); clear.target=self; clear.isEnabled = !recentSearches.isEmpty; menu.addItem(clear)
        presentMenu(menu,view:actionsButton)
    }
    @objc func manageSearchPreferences() {
        resolveSearchTargets(all:true)
        let choices=preferences.dictionary(forKey:"searchChoices") as? [String:[String:Any]] ?? [:]; let keys=choices.keys.sorted()
        guard !keys.isEmpty else { status.stringValue="尚无搜索偏好"; return }
        let alert=NSAlert(); alert.messageText="搜索偏好"; alert.informativeText="管理手动首选和自动记忆。修改时选择新的文件或文件夹。"; for title in ["完成","修改…","删除所选","清空全部"] { alert.addButton(withTitle:title) }
        let picker=NSPopUpButton(); picker.addItems(withTitles:keys.map { key in let words=key.dropFirst(2).replacingOccurrences(of:"\u{001F}",with:" "); let item=choices[key]!; return String(words)+" · "+(key.hasPrefix("1:") ? "正文" : "文件名")+" · "+(item["manual"] as? Bool == true ? "首选" : "自动")+" · "+URL(fileURLWithPath:item["path"] as? String ?? "/").lastPathComponent }); picker.frame=NSRect(x:0,y:0,width:500,height:32); for (index,key) in keys.enumerated() { picker.item(at:index)?.toolTip=choices[key]?["path"] as? String }; alert.accessoryView=picker
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return }; let key=keys[picker.indexOfSelectedItem]
            if response == .alertSecondButtonReturn {
                let panel=NSOpenPanel(); panel.canChooseFiles=true; panel.canChooseDirectories=true; panel.allowsMultipleSelection=false; panel.prompt="设为首选"
                panel.beginSheetModal(for:self.window) { result in if result == .OK,let url=panel.url { var updated=self.preferences.dictionary(forKey:"searchChoices") ?? [:]; updated[key]=["path":url.path,"time":Date().timeIntervalSince1970,"manual":true]; if var item=updated[key] as? [String:Any] { item["bookmark"]=self.makeBookmark(url); updated[key]=item }; self.preferences.set(updated,forKey:"searchChoices"); if !self.search.stringValue.isEmpty { self.renderSearchResults() } }; self.manageSearchPreferences() }
            } else if response.rawValue == 1002 || response.rawValue == 1003 {
                var updated=self.preferences.dictionary(forKey:"searchChoices") ?? [:]; if response.rawValue == 1003 { updated.removeAll() } else { updated.removeValue(forKey:key) }; self.preferences.set(updated,forKey:"searchChoices"); if !self.search.stringValue.isEmpty { self.renderSearchResults() }; if !updated.isEmpty { self.manageSearchPreferences() } else { self.status.stringValue="搜索偏好已清空" }
            }
        }
    }
    var selectedURLs:[URL] { table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].url : nil } }
    func selectURLs(_ urls:[URL]) { let paths=Set(urls.map(\.path)); table.selectRowIndexes(IndexSet(entries.indices.filter { paths.contains(entries[$0].url.path) }),byExtendingSelection:false) }
    func writePaths(_ urls:[URL],to pasteboard:NSPasteboard) { pasteboard.clearContents(); pasteboard.setString(urls.map(\.path).joined(separator:"\n"),forType:.string) }
    func writeFiles(_ urls:[URL],to pasteboard:NSPasteboard)->Bool { pasteboard.clearContents(); return pasteboard.writeObjects(urls.map { $0 as NSURL }) }
    @objc func copySelectedPaths() { let urls=selectedURLs; guard !urls.isEmpty else { return }; writePaths(urls,to:.general); status.stringValue="已复制 \(urls.count) 个路径" }
    @objc func copySelectedFiles() { let urls=selectedURLs; guard !urls.isEmpty else { return }; guard urls.allSatisfy({ FileManager.default.fileExists(atPath:$0.path) }) else { status.stringValue="部分文件已移动或删除，请重新选择"; return }; status.stringValue=writeFiles(urls,to:.general) ? "已复制 \(urls.count) 个文件，可在访达中粘贴" : "复制失败" }
    @objc func revealSelectedFiles() { let urls=selectedURLs.filter { FileManager.default.fileExists(atPath:$0.path) }; guard !urls.isEmpty else { return }; NSWorkspace.shared.activateFileViewerSelecting(urls) }
    var excludedRoots:[String] { preferences.stringArray(forKey:"excludedSearchRoots") ?? [] }
    func isExcluded(_ url:URL)->Bool { guard !excludedRoots.isEmpty else { return false }; let path=canonicalIndexPath(url.resolvingSymlinksInPath()); return excludedRoots.contains { root in let excluded=canonicalIndexPath(URL(fileURLWithPath:root).resolvingSymlinksInPath()); return path == excluded || path.hasPrefix(excluded+"/") } }
    func aliasKey(_ value:String)->String { normalized(value.split(whereSeparator:{ $0.isWhitespace }).joined(separator:" ")) }
    var searchAliases:[String:[String:Any]] { preferences.dictionary(forKey:"searchAliases") as? [String:[String:Any]] ?? [:] }
    var currentAlias:[String:Any]? { guard searchMode == .filename,!showingRecent,localCollection == nil else { return nil }; let words=SearchInput(search.stringValue,fallback:fileFilter).words; return searchAliases[normalized(words.joined(separator:" "))] }
    var currentAliasPath:String? { currentAlias?["path"] as? String }
    func trackedItem(_ item:[String:Any])->[String:Any] {
        guard let path=item["path"] as? String else { return item }; var updated=item; var url=URL(fileURLWithPath:path)
        if let data=item["bookmark"] as? Data { var stale=false; if let resolved=try? URL(resolvingBookmarkData:data,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale),FileManager.default.fileExists(atPath:resolved.path) { url=resolved } }
        if FileManager.default.fileExists(atPath:url.path) { updated["path"]=url.path; if url.path != path || item["bookmark"] == nil { updated["bookmark"]=makeBookmark(url) } }
        return updated
    }
    func resolveSearchTargets(all:Bool=false) {
        let words=SearchInput(search.stringValue,fallback:fileFilter).words
        for key in ["searchAliases","searchChoices"] {
            guard let items=preferences.dictionary(forKey:key) as? [String:[String:Any]] else { continue }
            let queryKey=key == "searchAliases" ? aliasKey(words.joined(separator:" ")) : "\(searchMode.rawValue):"+words.map(normalized).joined(separator:"\u{001F}")
            var updated=items; var changed=false
            for itemKey in all ? Array(items.keys) : [queryKey] { if let item=items[itemKey] { let tracked=trackedItem(item); if !NSDictionary(dictionary:tracked).isEqual(to:item) { updated[itemKey]=tracked; changed=true } } }
            if changed { preferences.set(updated,forKey:key) }
        }
        resolvePins()
    }
    func storeAlias(_ name:String,url:URL)->Bool {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines); guard !name.isEmpty,name.count <= 64,FileManager.default.fileExists(atPath:url.path) else { return false }
        let key=aliasKey(name); guard !SearchInput(name,fallback:.all).words.isEmpty else { return false }
        // A leading type command is reserved for filters, so aliases use ordinary words.
        guard SearchInput(name,fallback:.all).words.joined(separator:" ") == name.split(whereSeparator:{ $0.isWhitespace }).joined(separator:" ") else { return false }
        var aliases=searchAliases; guard aliases[key] != nil || aliases.count < 300 else { return false }; var item:[String:Any]=["name":name,"path":url.path]; item["bookmark"]=makeBookmark(url); aliases[key]=item; preferences.set(aliases,forKey:"searchAliases"); return true
    }
    @objc func addSelectedAlias() { guard let url=selected?.url else { return }; editAlias(nil,url:url) }
    func editAlias(_ oldKey:String?,url:URL) {
        let alert=NSAlert(); alert.messageText=oldKey == nil ? "添加搜索别名" : "修改搜索别名"; alert.informativeText="为 "+url.lastPathComponent+" 设置容易记住的词，例如“孩子资料”。输入完整别名可找到它；当前目录与筛选仍然生效。"; alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"取消"); let field=NSTextField(string:oldKey.flatMap { searchAliases[$0]?["name"] as? String } ?? ""); field.frame=NSRect(x:0,y:0,width:360,height:28); alert.accessoryView=field
        alert.beginSheetModal(for:window) { [weak self] result in guard let self,result == .alertFirstButtonReturn else { return }; if self.storeAlias(field.stringValue,url:url) { if let oldKey,oldKey != self.aliasKey(field.stringValue) { var aliases=self.searchAliases; aliases.removeValue(forKey:oldKey); self.preferences.set(aliases,forKey:"searchAliases") }; self.status.stringValue="已保存搜索别名"; if !self.search.stringValue.isEmpty { self.renderSearchResults() } } else { self.status.stringValue="别名未保存：请输入 1–64 个字符，避开开头的 pdf 等类型指令，并确认文件存在" } }
    }
    @objc func manageAliases() {
        resolveSearchTargets(all:true); let aliases=searchAliases,keys=aliases.keys.sorted(); guard !keys.isEmpty else { status.stringValue="尚无搜索别名，选中文件后用 ⌘K 添加"; return }
        let alert=NSAlert(); alert.messageText="搜索别名"; alert.informativeText="别名仅在本机保存。文件移动后会尝试跟踪，悬停条目查看完整路径。"; for title in ["完成","修改名称…","删除所选"] { alert.addButton(withTitle:title) }; let picker=NSPopUpButton(); picker.addItems(withTitles:keys.map { (aliases[$0]?["name"] as? String ?? $0)+" → "+URL(fileURLWithPath:aliases[$0]?["path"] as? String ?? "/").lastPathComponent }); for (index,key) in keys.enumerated() { picker.item(at:index)?.toolTip=aliases[key]?["path"] as? String }; picker.frame=NSRect(x:0,y:0,width:460,height:30); alert.accessoryView=picker
        alert.beginSheetModal(for:window) { [weak self] result in guard let self else { return }; let key=keys[picker.indexOfSelectedItem]; if result == .alertSecondButtonReturn { self.editAlias(key,url:URL(fileURLWithPath:aliases[key]?["path"] as? String ?? "/")) } else if result.rawValue == 1002 { var updated=self.searchAliases; updated.removeValue(forKey:key); self.preferences.set(updated,forKey:"searchAliases"); if !self.search.stringValue.isEmpty { self.renderSearchResults() }; if !updated.isEmpty { self.manageAliases() } } }
    }
    func resetCatalogsForExclusions() {
        stopQuery(); catalogCache.removeAll(); validatedCatalogs.removeAll(); directorySnapshots.removeAll(); directoryRepairQueue.cancelAllOperations()
        if let files=try? FileManager.default.contentsOfDirectory(at:catalogStore.directory,includingPropertiesForKeys:nil) { for file in files where ["json","plist","kfi"].contains(file.pathExtension) { try? FileManager.default.removeItem(at:file) } }
        if !search.stringValue.isEmpty { startSearch() } else { refreshList() }
    }
    @objc func manageExcludedDirectories() {
        let roots=excludedRoots; let alert=NSAlert(); alert.messageText="排除搜索目录"; alert.informativeText="这些目录及其子目录不会出现在搜索结果中。设置后重新核对索引。默认跳过隐藏文件、缓存和开发依赖目录。"; for title in ["完成","添加目录…","移除所选"] { alert.addButton(withTitle:title) }; let picker=NSPopUpButton(); picker.addItems(withTitles:roots.isEmpty ? ["尚无自定义排除目录"] : roots); picker.frame=NSRect(x:0,y:0,width:460,height:30); alert.accessoryView=picker
        alert.beginSheetModal(for:window) { [weak self] result in guard let self else { return }; if result == .alertSecondButtonReturn { let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.allowsMultipleSelection=true; panel.prompt="排除此目录"; panel.beginSheetModal(for:self.window) { result in if result == .OK { self.preferences.set(Array(Set(self.excludedRoots+panel.urls.map { $0.resolvingSymlinksInPath().path })).sorted(),forKey:"excludedSearchRoots"); self.resetCatalogsForExclusions() }; self.manageExcludedDirectories() } } else if result.rawValue == 1002,!roots.isEmpty { var updated=roots; updated.remove(at:picker.indexOfSelectedItem); self.preferences.set(updated,forKey:"excludedSearchRoots"); self.resetCatalogsForExclusions(); self.manageExcludedDirectories() } }
    }
    let backupKeys=["keyCode","modifiers","shortcutLabel","sortMode","workspaceState","extraSearchRoots","excludedSearchRoots","savedSearches","searchChoices","searchAliases","pinnedPaths","pinBookmarks","recordsRecentSearches","recentSearches","doubleControlWake","directoryShortcuts","rejectedResults","tagFilter","adaptiveResources"]
    func settingsBackupData() throws -> Data {
        saveState(); var settings:[String:Any]=[:]; for key in backupKeys { settings[key]=preferences.object(forKey:key) }
        let packet:[String:Any]=["version":1,"home":NSHomeDirectory(),"host":ProcessInfo.processInfo.hostName,"settings":settings]
        return try PropertyListSerialization.data(fromPropertyList:packet,format:.xml,options:0)
    }
    func decodedSettingsBackup(_ data:Data) throws -> [String:Any] {
        func fail(_ text:String)->NSError { NSError(domain:"KongFetch.Settings",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
        guard data.count <= 5*1024*1024 else { throw fail("备份文件超过 5 MB") }
        guard let packet=try PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any],packet["version"] as? Int == 1,let values=packet["settings"] as? [String:Any],let oldHome=packet["home"] as? String,!oldHome.isEmpty else { throw fail("不是支持的 KongFetch 设置备份") }
        var settings=values.filter { backupKeys.contains($0.key) }
        if let value=settings["directoryShortcuts"] {
            guard let items=value as? [[String:Any]],items.count <= 20,items.allSatisfy({ item in
                guard let path=item["path"] as? String,let code=item["code"] as? Int,let mods=item["mods"] as? Int else { return false }
                return path.hasPrefix("/") && (0...127).contains(code) && mods > 0 && mods <= Int(cmdKey|optionKey|shiftKey|controlKey) && mods & ~Int(cmdKey|optionKey|shiftKey|controlKey) == 0
            }) else { throw fail("目录快捷键设置无效") }
        }
        if let value=settings["rejectedResults"] { guard let items=value as? [String:[String]],items.count <= 300,items.values.allSatisfy({ $0.count <= 100 && $0.allSatisfy { $0.hasPrefix("/") } }) else { throw fail("搜索反馈设置无效") } }
        if let value=settings["doubleControlWake"],!(value is Bool) { throw fail("Control 唤起设置无效") }
        if let value=settings["adaptiveResources"],!(value is Bool) { throw fail("索引策略设置无效") }
        if let value=settings["tagFilter"] { guard let text=value as? String,text.count <= 64 else { throw fail("标签筛选设置无效") } }
        for key in ["extraSearchRoots","excludedSearchRoots","pinnedPaths","recentSearches"] { if let value=settings[key] { guard let list=value as? [String],list.count <= 5000 else { throw fail("备份中的列表无效："+key) } } }
        for key in ["searchChoices","searchAliases"] { if let value=settings[key] { guard let items=value as? [String:[String:Any]],items.count <= 300,items.values.allSatisfy({ ($0["path"] as? String)?.hasPrefix("/") == true }) else { throw fail("备份中的搜索偏好无效") } } }
        if let value=settings["savedSearches"] { guard let items=value as? [[String:Any]],items.count <= 50 else { throw fail("常用搜索备份无效") } }
        if let code=settings["keyCode"] { guard let value=code as? Int,(0...127).contains(value) else { throw fail("快捷键无效") } }
        if let mods=settings["modifiers"] { let mask=Int(cmdKey)|Int(optionKey)|Int(controlKey)|Int(shiftKey); guard let value=mods as? Int,value & ~mask == 0,value & (Int(cmdKey)|Int(optionKey)|Int(controlKey)) != 0 else { throw fail("快捷键修饰键无效") } }
        func rehome(_ value:Any)->Any {
            if let text=value as? String { if oldHome != NSHomeDirectory(),text == oldHome || text.hasPrefix(oldHome+"/") { return NSHomeDirectory()+String(text.dropFirst(oldHome.count)) }; return text }
            if let array=value as? [Any] { return array.map(rehome) }
            if let dict=value as? [String:Any] { return dict.mapValues(rehome) }
            return value
        }
        settings=settings.mapValues(rehome)
        if packet["host"] as? String != ProcessInfo.processInfo.hostName || oldHome != NSHomeDirectory() {
            settings["pinBookmarks"]=[String:Data]()
            for key in ["searchChoices","searchAliases"] { if let items=settings[key] as? [String:[String:Any]] { settings[key]=items.mapValues { item in var updated=item; updated.removeValue(forKey:"bookmark"); return updated } } }
        }
        return settings
    }
    func applySettingsBackup(_ data:Data) throws -> Bool {
        let settings=try decodedSettingsBackup(data)
        let oldShortcut=["keyCode":preferences.object(forKey:"keyCode") ?? 49,"modifiers":preferences.object(forKey:"modifiers") ?? Int(cmdKey|optionKey),"shortcutLabel":preferences.object(forKey:"shortcutLabel") ?? "⌘⌥空格"]
        let code=settings["keyCode"] as? Int ?? 49,mods=settings["modifiers"] as? Int ?? Int(cmdKey|optionKey)
        let shortcutOK=register(code:UInt32(code),modifiers:UInt32(mods))
        recentSearchTimer?.invalidate(); stopQuery(); stopWatching()
        for key in backupKeys { preferences.removeObject(forKey:key) }; for (key,value) in settings { preferences.set(value,forKey:key) }
        if !shortcutOK { for (key,value) in oldShortcut { preferences.set(value,forKey:key) } }
        registerDirectoryShortcuts(); configureControlWake(); tagFilter=preferences.string(forKey:"tagFilter") ?? ""; extraRoots=preferences.stringArray(forKey:"extraSearchRoots") ?? []; pinnedPaths=preferences.stringArray(forKey:"pinnedPaths") ?? []; pinBookmarks=preferences.dictionary(forKey:"pinBookmarks") as? [String:Data] ?? [:]; resolveSearchTargets(all:true)
        catalogCache.removeAll(); validatedCatalogs.removeAll(); directorySnapshots.removeAll(); directoryRepairQueue.cancelAllOperations()
        var state=preferences.dictionary(forKey:"workspaceState")
        if let path=state?["folder"] as? String,!FileManager.default.fileExists(atPath:path) { state?["all"]=true; state?["roots"]=[NSHomeDirectory(),"/Applications"] }
        let wasRestoring=restoringState; restoreState(state); restoringState=wasRestoring; shortcutField?.stringValue=preferences.string(forKey:"shortcutLabel") ?? "⌘⌥空格"
        return shortcutOK
    }
    @objc func exportSettings() {
        let panel=NSSavePanel(); panel.title="备份 KongFetch 设置"; panel.nameFieldStringValue="KongFetch-settings.plist"; panel.allowedContentTypes=[.propertyList]
        panel.beginSheetModal(for:window) { [weak self] result in guard let self,result == .OK,let url=panel.url else { return }; do { try self.settingsBackupData().write(to:url,options:.atomic); self.status.stringValue="设置已备份；文件包含目录与搜索偏好" } catch { self.status.stringValue="备份失败："+error.localizedDescription } }
    }
    @objc func importSettings() {
        let panel=NSOpenPanel(); panel.title="恢复 KongFetch 设置"; panel.prompt="恢复设置"; panel.allowedContentTypes=[.propertyList]; panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
        panel.beginSheetModal(for:window) { [weak self] result in guard let self,result == .OK,let url=panel.url else { return }; do { let size=(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0; guard size <= 5*1024*1024 else { throw NSError(domain:"KongFetch.Settings",code:1,userInfo:[NSLocalizedDescriptionKey:"备份文件过大"]) }; let shortcutOK=try self.applySettingsBackup(Data(contentsOf:url)); self.status.stringValue=shortcutOK ? "设置已恢复；未连接的目录请在搜索目录中检查" : "设置已恢复，快捷键被占用，保留原组合" } catch { self.status.stringValue="恢复失败，原设置保留："+error.localizedDescription } }
    }
    var activeSearchRoots:[String] { scopeAll ? (savedScopeOverride ?? Array(Set(searchRoots+extraRoots)).sorted()) : [folder.path] }
    func stopWatching() { indexTimer?.invalidate(); pendingChanges=[]; needsFullRefresh=false; if let stream=watchStream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; watchStream=nil }
    func watch(_ roots:[URL]) {
        if watchingRoots == roots && watchStream != nil { return }
        stopWatching(); watchingRoots=roots; validatedCatalogs.remove(roots.map(\.path).joined(separator:"\n"))
        var context=FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        watchStream=FSEventStreamCreate(nil,{ _,info,count,paths,flags,_ in
            guard let info else { return }; let app=Unmanaged<App>.fromOpaque(info).takeUnretainedValue()
            let pointers=paths.assumingMemoryBound(to:UnsafePointer<CChar>.self)
            let indexPath=canonicalIndexPath(app.catalogStore.directory)
            var changed:[String]=[]; var force=false
            for i in 0..<count {
                let path=canonicalIndexPath(URL(fileURLWithPath:String(cString:pointers[i]))); if path == indexPath || path.hasPrefix(indexPath+"/") { continue }
                let flag=flags[i]
                let recovery=FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
                if flag & recovery != 0 { force=true }
                let structural=FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 && flag & structural == 0 && flag & recovery == 0 { continue }
                changed.append(path)
            }
            if !changed.isEmpty || force { app.filesChanged(changed,force:force) }
        },&context,roots.map(\.path) as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),1,FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream=watchStream { FSEventStreamSetDispatchQueue(stream,DispatchQueue.main); if !FSEventStreamStart(stream) { stopWatching() } }
    }
    func filesChanged(_ paths:[String],force:Bool=false) {
        pendingChanges.formUnion(paths); needsFullRefresh = needsFullRefresh || force || pendingChanges.count > 2048
        indexTimer?.invalidate(); indexTimer=Timer.scheduledTimer(withTimeInterval:1,repeats:false) { [weak self] _ in self?.applyChanges() }
    }
    func applyChanges() {
        let roots=watchingRoots,key=roots.map(\.path).joined(separator:"\n"),paths=Array(pendingChanges),force=needsFullRefresh
        pendingChanges=[]; needsFullRefresh=false
        let cached=catalogCache[key]; let validated=validatedCatalogs.contains(key)
        catalogQueue.cancelAllOperations(); validatedCatalogs.remove(key); catalogToken=UUID(); let token=catalogToken
        if force || !validated || cached == nil {
            catalogCache.removeValue(forKey:key); catalogStore.invalidate(key); reportIndex("目录变化较大，需要重新核对索引")
            if searchMode == .filename && !search.stringValue.isEmpty && !showingRecent && localCollection == nil { startNameScan(SearchInput(search.stringValue,fallback:fileFilter)) }
            return
        }
        reportIndex("正在增量更新 · \(paths.count) 个变化路径")
        let policy=ResourcePolicy(adaptive:adaptiveResources)
        let store=catalogStore,original=cached!.1,operation=BlockOperation(),exclusions=excludedRoots
        operation.addExecutionBlock { [weak self,weak operation] in
            guard let operation,!operation.isCancelled else { return }
            let updated=updateCatalog(original,paths:paths,roots:roots,excluding:[store.directory.path]+exclusions,throttle:{ policy.pauseIfNeeded(cancelled:{ operation.isCancelled }) },cancelled:{ operation.isCancelled }); if operation.isCancelled { return }
            var failed=false; do { try store.save(updated,key:key,roots:roots) } catch { failed=true }
            self?.saveDirectorySnapshots(updated,roots:roots,store:store)
            DispatchQueue.main.async {
                guard let self,self.catalogToken == token else { return }
                self.catalogCache[key]=(Date(),updated); self.validatedCatalogs.insert(key); self.incrementalUpdates += 1; self.catalogSaveFailed=failed; self.reportIndex(self.catalogSummary(updated)+(failed ? "\n索引保存失败" : ""))
                if self.searchMode == .filename && !self.search.stringValue.isEmpty && !self.showingRecent && self.localCollection == nil { self.startNameScan(SearchInput(self.search.stringValue,fallback:self.fileFilter)) }
            }
        }
        catalogQueue.addOperation(operation)
    }
    func expandSearchScope() { savedScopeOverride=nil; scopeAll=true; searchRoots=[NSHomeDirectory(),"/Applications"]; scopePicker.selectItem(at:1) }
    @objc func widenSearch() { expandSearchScope(); saveState()
        if search.stringValue.isEmpty { loadRecent() } else { startSearch() }
    }
    var hasSearchRestrictions:Bool { SearchInput(search.stringValue,fallback:fileFilter).filter != .all || dateFilter != 0 || sizeFilter != 0 || !tagFilter.isEmpty || !naturalQuery.descriptions.isEmpty }
    func removeSearchRestrictions() {
        let input=SearchInput(search.stringValue,fallback:fileFilter)
        if input.filter != fileFilter || input.words.count != search.stringValue.split(whereSeparator: { $0.isWhitespace }).count { search.stringValue=input.words.joined(separator:" ") }
        fileFilter = .all; filterPicker.selectItem(at:0); dateFilter=0; sizeFilter=0; tagFilter=""; preferences.set("",forKey:"tagFilter"); if !naturalQuery.descriptions.isEmpty { search.stringValue=SearchInput(search.stringValue,fallback:.all).words.joined(separator:" ") }; updateFilterSummary()
    }
    @objc func clearSearchRestrictions() { removeSearchRestrictions(); saveState(); if search.stringValue.isEmpty { loadRecent() } else { startSearch() } }
    var isFullSearchScope:Bool { scopeAll && savedScopeOverride == nil && Set(searchRoots) == Set([NSHomeDirectory(),"/Applications"]) }
    func emptySearchExplanation()->String {
        var lines=["没有匹配的"+(searchMode == .content ? "正文" : "文件")]
        lines.append(scopeAll ? (isFullSearchScope ? "范围：全部已配置目录" : "范围：当前配置的目录") : "范围："+folder.lastPathComponent)
        let input=SearchInput(search.stringValue,fallback:fileFilter); var filters:[String]=[]
        if input.filter != .all { filters.append(input.filter.title) }
        if dateFilter != 0 { filters.append((dateField == 0 ? "修改：" : "创建：")+dateTitles[dateFilter]) }
        if sizeFilter != 0 { filters.append(sizeTitles[sizeFilter]) }
        if !filters.isEmpty { lines.append("筛选："+filters.joined(separator:" · ")) }
        let excluded=(spotlightMatches+localMatches).filter { !input.filter.accepts($0) || !acceptsDetails($0) }.count
        if excluded > 0 { lines.append("部分匹配项目被筛选排除") }
        if !tagFilter.isEmpty { lines.append("标签："+tagFilter) }; if !naturalQuery.descriptions.isEmpty { lines.append(naturalQuery.descriptions.joined(separator:" · ")) }; if searchMode == .content { lines.append("搜索 Spotlight 正文及已建立的本地 OCR 索引") }
        else if scanningNames { lines.append("文件索引仍在更新，请稍候") }
        else if catalogUnreadable > 0 { lines.append("部分目录无法访问，可在搜索目录中查看") }
        else if excluded > 0 { lines.append("可清除筛选后重试") }
        else { lines.append("当前索引无匹配；可检查目录或关键词") }
        return lines.joined(separator:"\n")
    }
    let directoryRepairQueue:OperationQueue = { let q=OperationQueue(); q.maxConcurrentOperationCount=1; q.qualityOfService = .utility; return q }()
    var directorySnapshots:[String:CatalogResult]=[:]
    var directoryPanelRoots:[URL]=[]
    var selectedDirectoryRoot:String?
    weak var directoryPicker:NSPopUpButton?
    var rebuildingDirectories=Set<String>()
    func expandedRoots(_ paths:[String])->[URL] {
        Array(Set(paths.flatMap { root -> [String] in root == NSHomeDirectory() ? ["Desktop","Documents","Downloads","Pictures","Music","Movies","Library/Mobile Documents/com~apple~CloudDocs"].map { NSHomeDirectory()+"/"+$0 } : [root] })).sorted().map { URL(fileURLWithPath:$0) }
    }
    func directorySnapshot(_ root:URL)->CatalogResult? {
        if let snapshot=directorySnapshots[root.path] { return snapshot }
        if let saved=catalogStore.load(root.path,roots:[root]) { return saved }
        return nil
    }
    @objc func directorySelectionChanged() {
        guard let picker=directoryPicker,directoryPanelRoots.indices.contains(picker.indexOfSelectedItem) else { return }
        let root=directoryPanelRoots[picker.indexOfSelectedItem]; selectedDirectoryRoot=root.path
        var text=(root.path as NSString).abbreviatingWithTildeInPath
        if rebuildingDirectories.contains(root.path) { text += "\n正在重建此目录…" }
        else if let snapshot=directorySnapshot(root) { text += "\n"+catalogSummary(snapshot) }
        else { text += "\n尚未建立此目录的索引" }
        if !FileManager.default.fileExists(atPath:root.path) { text += "\n目录不存在或磁盘未连接" }
        indexStatusText?.stringValue=text; indexStatusText?.toolTip=text
    }
    func saveDirectorySnapshots(_ catalog:CatalogResult,roots:[URL],store:CatalogStore) {
        for root in roots {
            let prefix=canonicalIndexPath(root); var part=CatalogResult(); part.urls=catalog.urls.filter { let path=canonicalIndexPath($0); return path.hasPrefix(prefix+"/") }; part.updated=catalog.updated; part.inaccessible=catalog.inaccessible.filter { let path=canonicalIndexPath(URL(fileURLWithPath:$0)); return path == prefix || path.hasPrefix(prefix+"/") }; part.unreadable=part.inaccessible.count
            try? store.save(part,key:root.path,roots:[root])
            let snapshot=part; DispatchQueue.main.async { [weak self] in guard let self else { return }; if (self.directorySnapshots[root.path]?.updated ?? .distantPast) <= (snapshot.updated ?? .distantPast) { self.directorySnapshots[root.path]=snapshot }; self.directorySelectionChanged() }
        }
    }
    func rebuildDirectory(_ root:URL) {
        guard !rebuildingDirectories.contains(root.path) else { return }; catalogQueue.cancelAllOperations(); catalogToken=UUID(); scanningNames=false; rebuildingDirectories.insert(root.path); directorySelectionChanged()
        let policy=ResourcePolicy(adaptive:adaptiveResources)
        let store=catalogStore,exclusions=excludedRoots
        let operation=BlockOperation(); operation.addExecutionBlock { [weak self,weak operation] in
            guard let operation,!operation.isCancelled else { return }
            let result=scanNames([root],excluding:[store.directory.path]+exclusions,throttle:{ policy.pauseIfNeeded(cancelled:{ operation.isCancelled }) },cancelled:{ operation.isCancelled }); if operation.isCancelled { return }; var failed=false; do { try store.save(result,key:root.path,roots:[root]) } catch { failed=true }
            DispatchQueue.main.async {
                guard let self else { return }; self.directorySnapshots[root.path]=result; self.rebuildingDirectories.remove(root.path)
                let prefix=canonicalIndexPath(root)
                for key in Array(self.catalogCache.keys) {
                    let roots=key.split(separator:"\n").map { URL(fileURLWithPath:String($0)) }
                    guard roots.contains(where:{ let path=canonicalIndexPath($0); return path == prefix || prefix.hasPrefix(path+"/") }) else { continue }
                    var cached=self.catalogCache[key]!.1; cached.urls.removeAll { let path=canonicalIndexPath($0); return path.hasPrefix(prefix+"/") }; var merged=Dictionary(cached.urls.map { ($0.path,$0) },uniquingKeysWith:{ a,_ in a }); for url in result.urls { merged[url.path]=url }; cached.urls=Array(merged.values); cached.updated=result.updated; cached.inaccessible.removeAll { $0 == root.path || $0.hasPrefix(root.path+"/") }; cached.inaccessible += result.inaccessible; cached.unreadable=cached.inaccessible.count; self.catalogCache[key]=(Date(),cached)
                    let snapshot=cached; self.directoryRepairQueue.addOperation { try? store.save(snapshot,key:key,roots:roots) }
                }
                self.directorySelectionChanged(); self.status.stringValue=failed ? "目录已重建，但索引保存失败" : "已重建目录："+root.lastPathComponent
                if !self.search.stringValue.isEmpty && self.searchMode == .filename && self.localCollection == nil {
                    let input=SearchInput(self.search.stringValue,fallback:self.fileFilter),currentRoots=self.expandedRoots(self.activeSearchRoots)
                    self.localMatches.removeAll { canonicalIndexPath($0.url).hasPrefix(prefix+"/") }
                    self.localMatches += result.urls.filter { url in let path=canonicalIndexPath(url); return currentRoots.contains { path.hasPrefix(canonicalIndexPath($0)+"/") } && filenameScore(url,words:input.words) != nil }.map(Entry.init)
                    self.renderSearchResults()
                }
            }
        }; directoryRepairQueue.addOperation(operation)
    }
    @objc func manageDirectories() {
        let alert=NSAlert(); alert.messageText="搜索目录"; alert.informativeText="默认包含桌面、文稿、下载、图片、音乐、影片和 iCloud。可添加其他文件夹或外接硬盘；首次文件名搜索时建立索引。"
        for title in ["完成","添加目录…","移除所选","重建所选目录"] { alert.addButton(withTitle:title) }
        directoryPanelRoots=expandedRoots([NSHomeDirectory(),"/Applications"]+extraRoots+(scopeAll ? [] : [folder.path]))
        let picker=NSPopUpButton(); picker.addItems(withTitles:directoryPanelRoots.map { ($0.path as NSString).abbreviatingWithTildeInPath }); picker.frame=NSRect(x:0,y:0,width:460,height:30); directoryPicker=picker; if let selectedDirectoryRoot,let index=directoryPanelRoots.firstIndex(where:{ $0.path == selectedDirectoryRoot }) { picker.selectItem(at:index) }; picker.widthAnchor.constraint(equalToConstant:460).isActive=true; picker.target=self; picker.action = #selector(directorySelectionChanged)
        let label=NSTextField(wrappingLabelWithString:""); indexStatusText=label; label.maximumNumberOfLines=8; label.widthAnchor.constraint(equalToConstant:460).isActive=true; directorySelectionChanged()
        let stack=NSStackView(views:[picker,label]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=12; stack.frame=NSRect(x:0,y:0,width:460,height:110); alert.accessoryView=stack
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.allowsMultipleSelection=true; panel.prompt="添加搜索目录"
                panel.beginSheetModal(for:self.window) { result in
                    if result == .OK { self.extraRoots=Array(Set(self.extraRoots+panel.urls.map { $0.resolvingSymlinksInPath().path })).sorted(); self.preferences.set(self.extraRoots,forKey:"extraSearchRoots"); if !self.search.stringValue.isEmpty { self.startSearch() } }; self.manageDirectories()
                }
            } else if response.rawValue == 1002 {
                let root=self.directoryPanelRoots[picker.indexOfSelectedItem].path
                if let index=self.extraRoots.firstIndex(of:root) { self.extraRoots.remove(at:index); self.preferences.set(self.extraRoots,forKey:"extraSearchRoots"); self.catalogQueue.cancelAllOperations(); self.stopWatching(); if !self.search.stringValue.isEmpty { self.startSearch() } } else { self.status.stringValue="默认目录无法移除；可切换搜索范围" }; self.manageDirectories()
            } else if response.rawValue == 1003 {
                self.rebuildDirectory(self.directoryPanelRoots[picker.indexOfSelectedItem]); self.manageDirectories()
            }
        }
    }
    var localMatches:[Entry]=[],spotlightMatches:[Entry]=[]
    var scanningNames=false,catalogLimited=false,catalogUnreadable=0
    let filterPicker=NSPopUpButton()
    var fileFilter:FileFilter = .all
    var dateFilter=0, sizeFilter=0, dateField=0
    var customStart=Calendar.current.startOfDay(for:Date()), customEnd=Date()
    lazy var advancedButton=button("日期与大小",#selector(editFilters))
    lazy var clearFiltersButton=button("清除",#selector(clearFilters))
    let filterSummary=NSTextField(labelWithString:"")
    let dateTitles=["不限日期","今天","最近 7 天","最近 30 天","自定义日期"]
    let sizeTitles=["不限大小","小于 1 MB","1–100 MB","大于 100 MB"]
    func dateBounds(now:Date = Date())->(Date,Date)? {
        let cal=Calendar.current; let today=cal.startOfDay(for:now)
        if dateFilter == 0 { return nil }
        if dateFilter == 4 { return (cal.startOfDay(for:customStart),cal.date(byAdding:.day,value:1,to:cal.startOfDay(for:customEnd))!) }
        let days=dateFilter == 1 ? 0 : (dateFilter == 2 ? 6 : 29)
        return (cal.date(byAdding:.day,value:-days,to:today)!,cal.date(byAdding:.day,value:1,to:today)!)
    }
    func acceptsDetails(_ e:Entry)->Bool { acceptsDetails(e,natural:naturalQuery) }
    func acceptsDetails(_ e:Entry,natural:NaturalQuery)->Bool {
        if !tagFilter.isEmpty && !e.tags.contains(where:{ normalized($0) == normalized(tagFilter) }) { return false }
        if !showingRecent && !natural.accepts(e) { return false }
        if let (start,end)=dateBounds() { guard let date=dateField == 0 ? e.modified : e.created,date >= start,date < end else { return false } }
        if sizeFilter != 0 && e.directory { return false }
        switch sizeFilter { case 1: return e.size < 1_000_000; case 2: return e.size >= 1_000_000 && e.size <= 100_000_000; case 3: return e.size > 100_000_000; default: return true }
    }
    func detailPredicates()->[NSPredicate] {
        var result:[NSPredicate]=[]
        if let (start,end)=dateBounds() { let key=dateField == 0 ? NSMetadataItemFSContentChangeDateKey : NSMetadataItemFSCreationDateKey; result += [NSPredicate(format:"%K >= %@",key,start as NSDate),NSPredicate(format:"%K < %@",key,end as NSDate)] }
        switch sizeFilter {
        case 1: result.append(NSPredicate(format:"%K < 1000000",NSMetadataItemFSSizeKey))
        case 2: result += [NSPredicate(format:"%K >= 1000000",NSMetadataItemFSSizeKey),NSPredicate(format:"%K <= 100000000",NSMetadataItemFSSizeKey)]
        case 3: result.append(NSPredicate(format:"%K > 100000000",NSMetadataItemFSSizeKey))
        default: break
        }
        return result
    }
    func updateFilterSummary() {
        var parts:[String]=[]
        if fileFilter != .all { parts.append(fileFilter.title) }
        if dateFilter != 0 { parts.append((dateField == 0 ? "修改 · " : "创建 · ")+dateTitles[dateFilter]) }
        if sizeFilter != 0 { parts.append(sizeTitles[sizeFilter]) }
        if !tagFilter.isEmpty { parts.append("标签："+tagFilter) }; if !showingRecent { parts += naturalQuery.descriptions }; filterSummary.stringValue=parts.isEmpty ? "未设置筛选" : parts.joined(separator:" · "); filterSummary.toolTip=filterSummary.stringValue
        clearFiltersButton.isHidden=parts.isEmpty
    }
    @objc func clearFilters() { fileFilter = .all; filterPicker.selectItem(at:0); dateFilter=0; sizeFilter=0; tagFilter=""; preferences.set("",forKey:"tagFilter"); if !naturalQuery.descriptions.isEmpty { search.stringValue=NaturalQuery(search.stringValue).text }; changeFilter() }
    @objc func editFilters() {
        let alert=NSAlert(); alert.messageText="筛选文件"; alert.informativeText="日期按本地日历计算，大小按文件字节数计算；大小筛选不包含文件夹。"; alert.addButton(withTitle:"应用"); alert.addButton(withTitle:"取消")
        let dates=NSPopUpButton(); dates.addItems(withTitles:dateTitles); dates.selectItem(at:dateFilter)
        let field=NSPopUpButton(); field.addItems(withTitles:["修改时间","创建时间"]); field.selectItem(at:dateField)
        let sizes=NSPopUpButton(); sizes.addItems(withTitles:sizeTitles); sizes.selectItem(at:sizeFilter)
        let start=NSDatePicker(); let end=NSDatePicker()
        for picker in [start,end] { picker.datePickerElements = .yearMonthDay; picker.datePickerStyle = .textFieldAndStepper }
        start.dateValue=customStart; end.dateValue=customEnd
        let stack=NSStackView(views:[NSTextField(labelWithString:"日期范围"),dates,field,NSTextField(labelWithString:"自定义起始日期"),start,NSTextField(labelWithString:"自定义结束日期（包含当天）"),end,NSTextField(labelWithString:"文件大小"),sizes]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=8; stack.frame=NSRect(x:0,y:0,width:340,height:300); alert.accessoryView=stack
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .alertFirstButtonReturn else { return }
            if dates.indexOfSelectedItem == 4 && Calendar.current.startOfDay(for:start.dateValue) > Calendar.current.startOfDay(for:end.dateValue) { let error=NSAlert(); error.messageText="起始日期不能晚于结束日期"; error.beginSheetModal(for:self.window); return }
            self.dateFilter=dates.indexOfSelectedItem; self.dateField=field.indexOfSelectedItem; self.sizeFilter=sizes.indexOfSelectedItem; self.customStart=start.dateValue; self.customEnd=end.dateValue; self.changeFilter()
        }
    }
    var browseEntries:[Entry]=[]
    let loginToggle=NSButton(checkboxWithTitle:"登录后自动启动 KongFetch",target:nil,action:nil)
    let loginStatus=NSTextField(wrappingLabelWithString:"")
    var openCounts:[String:Int] = UserDefaults.standard.dictionary(forKey:"openCounts") as? [String:Int] ?? [:]
    let emptyLabel=NSTextField(wrappingLabelWithString:"")
    var metadataValues:[NSTextField]=[]
    var actionsButton:NSButton!
    var searchRoots=[NSHomeDirectory()]
    var showingRecent=false
    let collectionTabs=NSSegmentedControl(labels:["最近修改","最近打开","固定收藏"],trackingMode:.selectOne,target:nil,action:nil)
    var localCollection:Int?
    var preferences=UserDefaults.standard
    var restoringState=true
    var pinBookmarks:[String:Data] = UserDefaults.standard.dictionary(forKey:"pinBookmarks") as? [String:Data] ?? [:]
    var openedDates:[String:Double] = UserDefaults.standard.dictionary(forKey:"openedDates") as? [String:Double] ?? [:]
    var pinnedPaths:[String] = UserDefaults.standard.stringArray(forKey:"pinnedPaths") ?? []
    var entries: [Entry] = []
    var folder = FileManager.default.homeDirectoryForCurrentUser
    var history: [URL] = []
    var query: NSMetadataQuery?
    var timer: Timer?
    var hotKey: EventHotKeyRef?
    var registeredShortcut: (UInt32, UInt32)?
    var previewPanels: [NSPanel] = []
    var eventHandler: EventHandlerRef?
    var settings: NSPanel?
    var shortcutField: ShortcutField?
    var shortcutStatus: NSTextField?
    var menuItem: NSStatusItem!
    var tagFilter=""
    var fileUndos:[FileUndo]=[]
    let ocrQueue:OperationQueue = { let q=OperationQueue(); q.maxConcurrentOperationCount=1; q.qualityOfService = .background; return q }()
    let ocrSearchQueue:OperationQueue = { let q=OperationQueue(); q.maxConcurrentOperationCount=1; q.qualityOfService = .utility; return q }()
    var ocrToken=UUID()
    var ocrRecords:[String:OCRRecord]=[:]
    var ocrMatches:[Entry]=[]
    var ocrProgress="尚未建立 OCR 索引"
    var ocrStore=OCRStore(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KongFetch/OCR"))
    var lastResourceTime:Double=0,lastResourceCPU:Double=0
    var wakeReceived:Date?
    var wakeWindowVisible=false,wakeInputFocused=false,wakeTesting=false
    var wakeReport="尚未完成唤起检测"
    var wakeCheckToken=UUID()
    let controlWake=ControlWakeMonitor()
    let suggestionButton=NSButton(title:"相近文件名…",target:nil,action:nil)
    var directoryHotKeys:[EventHotKeyRef]=[]
    var directoryTargets:[UInt32:URL]=[:]
    var directoryShortcutErrors:[String]=[]
    let controlWakeToggle=NSButton(checkboxWithTitle:"连按两次 Control 唤起",target:nil,action:nil)
    let controlWakeStatus=NSTextField(wrappingLabelWithString:"")
    var generation = 0
    var scopeAll = false
    let dateFormat: DateFormatter = { let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .short; return d }()
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--smoke-test") { UserDefaults.standard.register(defaults:["NSApplicationCrashOnExceptions":true]) }
        let storedState=preferences.dictionary(forKey:"workspaceState")
        buildMenus(); buildWindow(); buildStatusItem()
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { configureControlWake(); tagFilter=preferences.string(forKey:"tagFilter") ?? ""; loadOCRCache() }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return noErr }
            let app = Unmanaged<App>.fromOpaque(context).takeUnretainedValue()
            var hotID=EventHotKeyID(); GetEventParameter(event,UInt32(kEventParamDirectObject),UInt32(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&hotID)
            DispatchQueue.main.async { if hotID.id >= 100,let url=app.directoryTargets[hotID.id] { if FileManager.default.fileExists(atPath:url.path) { app.browse(url); app.show() } else { app.show(); app.status.stringValue="快捷目录已不存在，请重新设置" } } else { app.show() } }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        _ = register(code: UInt32(UserDefaults.standard.object(forKey: "keyCode") as? Int ?? 49), modifiers: UInt32(UserDefaults.standard.object(forKey: "modifiers") as? Int ?? (cmdKey | optionKey)))
        NotificationCenter.default.addObserver(self, selector: #selector(queryUpdated), name: .NSMetadataQueryDidFinishGathering, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(queryUpdated), name: .NSMetadataQueryDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(queryProgress), name: .NSMetadataQueryGatheringProgress, object: nil)
        if CommandLine.arguments.contains("--dark-ui-check") || CommandLine.arguments.contains("--search-ui-check") || CommandLine.arguments.contains("--empty-ui-check") || CommandLine.arguments.contains("--alias-ui-check") {
            let fixture=URL(fileURLWithPath:"/tmp/kongfetch-savedsearch-"+UUID().uuidString); previewFixture=fixture; let directory=fixture.appendingPathComponent("乐乐")
            try! FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); try! Data("preview".utf8).write(to:directory.appendingPathComponent("证件照片.txt"))
            if CommandLine.arguments.contains("--dark-ui-check") { window.appearance=NSAppearance(named:.darkAqua) }; qaSuite="com.kongfetch.savedsearchcheck."+UUID().uuidString; preferences=UserDefaults(suiteName:qaSuite!)!; restoringState=true; catalogStore=CatalogStore(fixture.appendingPathComponent(".indexes")); ocrStore=OCRStore(fixture.appendingPathComponent(".ocr-cache")); scopeAll=false; folder=fixture; fileFilter = .all; filterPicker.selectItem(at:0); dateFilter=0; sizeFilter=0; searchMode = .filename; if CommandLine.arguments.contains("--alias-ui-check") { _=storeAlias("孩子资料",url:directory); search.stringValue="孩子资料" } else { search.stringValue=CommandLine.arguments.contains("--empty-ui-check") ? "pdf 乐乐" : "乐乐" }; startSearch(); show(); return
        }
        if CommandLine.arguments.contains("--status-check") {
            let fixture=URL(fileURLWithPath:"/tmp/kongfetch-status-"+UUID().uuidString); previewFixture=fixture
            try! FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
            for i in 0..<500 { try! Data([1]).write(to:fixture.appendingPathComponent("sample-\(i).txt")) }
            restoringState=true; catalogStore=CatalogStore(fixture.appendingPathComponent(".indexes")); scopeAll=false; folder=fixture; fileFilter = .all; filterPicker.selectItem(at:0); dateFilter=0; sizeFilter=0; searchMode = .filename; search.stringValue="sample-0"; startSearch(); show(); return
        }
        if CommandLine.arguments.contains("--release30-check") { release30Check(); return }
        if CommandLine.arguments.contains("--next-check") { nextCheck(); return }
        if CommandLine.arguments.contains("--upgrade-check") { upgradeCheck(); return }
        if CommandLine.arguments.contains("--features-check") { featuresCheck(); return }
        if CommandLine.arguments.contains("--index-check") { indexCheck(); return }
        if CommandLine.arguments.contains("--smoke-test") { smokeTest(); return }
        if CommandLine.arguments.contains("--search-check") {
            let suite="com.kongfetch.searchcheck."+UUID().uuidString; preferences=UserDefaults(suiteName:suite)!; restoringState=true
            scopeAll=true; searchRoots=[NSHomeDirectory()]; folder=FileManager.default.homeDirectoryForCurrentUser; fileFilter = .all; filterPicker.selectItem(at:0); dateFilter=0; sizeFilter=0; searchMode = .filename; updateSearchModeUI(); search.stringValue="乐乐"; startSearch(); show()
            Timer.scheduledTimer(withTimeInterval:20,repeats:false) { [weak self] _ in
                guard let self else { return }; print("SEARCH CHECK: \(self.entries.count) results; local scan pending=\(self.scanningNames)")
                for entry in self.entries.prefix(10) { print(entry.url.path) }; self.preferences.removePersistentDomain(forName:suite); fflush(stdout); self.stopQuery(); NSApp.terminate(nil)
            }; return
        }
        if CommandLine.arguments.contains("--preview-check") { previewCheck(); return }
        NotificationCenter.default.addObserver(self,selector:#selector(refreshLoginStatus),name:NSApplication.didBecomeActiveNotification,object:nil)
        extraRoots=preferences.stringArray(forKey:"extraSearchRoots") ?? []; resolveSearchTargets(all:true); registerDirectoryShortcuts(); restoreState(storedState); show()
    }
    func upgradeCheck() {
        let fixture=URL(fileURLWithPath:"/tmp/kongfetch27-"+UUID().uuidString); previewFixture=fixture; try! FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
        qaSuite="com.kongfetch.upgradecheck."+UUID().uuidString; preferences=UserDefaults(suiteName:qaSuite!)!; restoringState=true; pinnedPaths=[]; pinBookmarks=[:]; openCounts=[:]; openedDates=[:]; catalogStore=CatalogStore(fixture.appendingPathComponent(".indexes")); scopeAll=false; folder=fixture; searchMode = .filename; showingRecent=false; localCollection=nil
        let target=fixture.appendingPathComponent("乐乐",isDirectory:true); try! FileManager.default.createDirectory(at:target,withIntermediateDirectories:true); try! Data([1]).write(to:target.appendingPathComponent("资料.txt"))
        precondition(storeAlias("孩子资料",url:target)); precondition(!storeAlias("pdf",url:target)); precondition(storeAlias("孩子  文档",url:target)); precondition(searchAliases[aliasKey("孩子 文档")] != nil)
        search.stringValue="孩子资料"; localMatches=[]; spotlightMatches=[]; renderSearchResults(); precondition(entries.count == 1 && canonicalIndexPath(entries[0].url) == canonicalIndexPath(target))
        rememberSearchChoice(target,manual:true); search.stringValue="乐乐"; rememberSearchChoice(target,manual:true); search.stringValue="孩子资料"; pinnedPaths=[target.path]; pinBookmarks[target.path]=makeBookmark(target)
        let renamed=fixture.appendingPathComponent("孩子文件夹"); try! FileManager.default.moveItem(at:target,to:renamed); resolveSearchTargets(all:true)
        precondition(canonicalIndexPath(URL(fileURLWithPath:currentAliasPath!)) == canonicalIndexPath(renamed)); precondition(canonicalIndexPath(URL(fileURLWithPath:manualSearchPath!)) == canonicalIndexPath(renamed)); precondition(canonicalIndexPath(URL(fileURLWithPath:pinnedPaths[0])) == canonicalIndexPath(renamed))
        search.stringValue="乐乐"; renderSearchResults(); precondition(entries.count == 1 && entries[0].url.lastPathComponent == "孩子文件夹"); search.stringValue="孩子资料"; renderSearchResults(); precondition(entries.count == 1)
        fileFilter = .pdf; renderSearchResults(); precondition(entries.isEmpty); fileFilter = .all
        preferences.set([renamed.path],forKey:"excludedSearchRoots"); renderSearchResults(); precondition(entries.isEmpty); precondition(scanNames([renamed],excluding:[renamed.path],cancelled:{ false }).urls.isEmpty)
        let scanned=scanNames([fixture],excluding:[renamed.path],cancelled:{ false }); precondition(!scanned.urls.contains { canonicalIndexPath($0).hasPrefix(canonicalIndexPath(renamed)) }); preferences.removeObject(forKey:"excludedSearchRoots")
        let elsewhere=fixture.appendingPathComponent("其他"); try! FileManager.default.createDirectory(at:elsewhere,withIntermediateDirectories:true); folder=elsewhere; renderSearchResults(); precondition(entries.isEmpty); folder=fixture
        precondition(filenameScore(URL(fileURLWithPath:"/tmp/重庆音乐资料.pdf"),words:["chongqing"]) != nil && filenameScore(URL(fileURLWithPath:"/tmp/重庆音乐资料.pdf"),words:["yinyue"]) != nil)
        precondition(filenameScore(URL(fileURLWithPath:"/tmp/乐清银行.xlsx"),words:["yueqing"]) != nil && filenameScore(URL(fileURLWithPath:"/tmp/乐清银行.xlsx"),words:["yqyh"]) != nil)
        precondition(pinyinScore(pinyinForms("重庆音乐资料"),"cqyyzl") != nil && pinyinScore(pinyinForms("重庆音乐资料"),"ciqu") == nil)
        let key="compatibility"; let old=StoredCatalog(version:1,roots:[fixture.path],paths:[renamed.path],unreadable:0,inaccessible:[],updated:Date()); try! FileManager.default.createDirectory(at:catalogStore.directory,withIntermediateDirectories:true)
        let legacy=catalogStore.file(key).deletingPathExtension().appendingPathExtension("json"); try! JSONEncoder().encode(old).write(to:legacy); let loaded=catalogStore.load(key,roots:[fixture])!; try! catalogStore.save(loaded,key:key,roots:[fixture]); precondition(CatalogStore(catalogStore.directory).load(key,roots:[fixture])!.urls.count == 1 && !FileManager.default.fileExists(atPath:legacy.path))
        let large=CatalogResult(urls:(0..<2000).map { fixture.appendingPathComponent("文档-\($0).txt") },updated:Date()); try! catalogStore.save(large,key:"compressed",roots:[fixture]); let packed=try! Data(contentsOf:catalogStore.file("compressed")); precondition(packed.starts(with:Data("KFZ1".utf8))); precondition(CatalogStore(catalogStore.directory).load("compressed",roots:[fixture])!.urls.count == 2000)
        try! Data("KFZ1".utf8).write(to:catalogStore.file("compressed")); precondition(catalogStore.load("compressed",roots:[fixture]) == nil)
        preferences.set(2,forKey:"sortMode"); preferences.set([fixture.path],forKey:"extraSearchRoots"); preferences.set([elsewhere.path],forKey:"excludedSearchRoots"); preferences.set(["name":"示例","query":"资料","all":false,"folder":fixture.path,"filter":0],forKey:"exampleUnused")
        preferences.set([["name":"示例","query":"资料","all":false,"folder":fixture.path,"filter":0]],forKey:"savedSearches"); preferences.set(["all":false,"folder":fixture.path,"roots":[fixture.path],"filter":0,"collection":3],forKey:"workspaceState")
        let backup=try! settingsBackupData(); preferences.removeObject(forKey:"searchAliases"); preferences.set(0,forKey:"sortMode"); let restored=try! applySettingsBackup(backup); precondition(restored && sortMode == 2 && !searchAliases.isEmpty && savedSearches.count == 1 && excludedRoots == [elsewhere.path] && extraRoots == [fixture.path])
        let invalid=try! PropertyListSerialization.data(fromPropertyList:["version":99,"home":NSHomeDirectory(),"settings":[:]],format:.xml,options:0); do { _=try applySettingsBackup(invalid); fatalError("invalid backup accepted") } catch { precondition(sortMode == 2 && !searchAliases.isEmpty) }
        let foreign:[String:Any]=["version":1,"home":"/Users/foreign","host":"foreign-computer","settings":["extraSearchRoots":["/Users/foreign/Documents"],"searchChoices":["0:test":["path":"/Users/foreign/Documents/test.txt","bookmark":Data([1])]]]]
        let translated=try! decodedSettingsBackup(PropertyListSerialization.data(fromPropertyList:foreign,format:.xml,options:0)); precondition((translated["extraSearchRoots"] as! [String])[0] == NSHomeDirectory()+"/Documents" && ((translated["searchChoices"] as! [String:[String:Any]])["0:test"]?["bookmark"]) == nil)
        preferences.removeObject(forKey:"excludedSearchRoots"); preferences.set(true,forKey:"recordsRecentSearches"); clearRecentSearches(); search.stringValue="半"; scheduleRecentSearch("半")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak self] in guard let self else { return }; self.search.stringValue="完整关键词"; self.scheduleRecentSearch("完整关键词") }
        DispatchQueue.main.asyncAfter(deadline:.now()+2.1) { [weak self] in
            guard let self else { return }; precondition(self.recentSearches == ["完整关键词"]); self.toggleSearchRecording(); self.rememberRecentSearch("不记录"); precondition(self.recentSearches == ["完整关键词"]); self.toggleSearchRecording(); self.search.stringValue="清除中的记录"; self.scheduleRecentSearch("清除中的记录"); self.clearRecentSearches(); self.scheduleRecentSearch("清除中的记录")
            DispatchQueue.main.asyncAfter(deadline:.now()+1.7) { [weak self] in guard let self else { return }; precondition(self.recentSearches.isEmpty); print("PASS 2.7: aliases and filter/scope/exclusion guards; bookmark tracking for alias/preferred/pinned targets after directory rename; phrase pinyin/initials/noisy-query rejection; compressed/cached index and legacy JSON migration; backup roundtrip, invalid backup atomicity and cross-home remap; settled history, disabled recording and pending-record clear; fixed-size native app"); fflush(stdout); NSApp.terminate(nil) }
        }
        // Hidden fixture keeps user typing separate from timer assertions.
    }
    func featuresCheck() {
        let fixture=URL(fileURLWithPath:"/tmp/kongfetch26-"+UUID().uuidString); previewFixture=fixture
        let root=fixture.appendingPathComponent("目录甲"),other=fixture.appendingPathComponent("目录乙")
        try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); try! FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        let a=root.appendingPathComponent("a.txt"),z=other.appendingPathComponent("z.txt"); try! Data([1]).write(to:a); try! Data([1,2,3]).write(to:z)
        try! FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:10)],ofItemAtPath:a.path); try! FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:20)],ofItemAtPath:z.path)
        qaSuite="com.kongfetch.featurescheck."+UUID().uuidString; preferences=UserDefaults(suiteName:qaSuite!)!; restoringState=true; catalogStore=CatalogStore(fixture.appendingPathComponent(".indexes"))
        let items=[Entry(z),Entry(a)]; precondition(sortFiles(items,mode:2).first!.url == a && sortFiles(items,mode:1).first!.url == z && sortFiles(items,mode:3).first!.url == z)
        preferences.set(2,forKey:"sortMode"); precondition(sortMode == 2)
        entries=items; refreshList(); table.selectRowIndexes(IndexSet([0,1]),byExtendingSelection:false); precondition(selectedURLs.count == 2)
        let clipboard=NSPasteboard.withUniqueName(); writePaths(selectedURLs,to:clipboard); precondition(clipboard.string(forType:.string)!.split(separator:"\n").count == 2); precondition(writeFiles(selectedURLs,to:clipboard)); precondition((clipboard.readObjects(forClasses:[NSURL.self],options:nil) ?? []).count == 2); clipboard.releaseGlobally()
        for index in 0..<35 { rememberRecentSearch("词\(index)") }; rememberRecentSearch("词34"); precondition(recentSearches.count == 30 && recentSearches.first == "词34")
        let remove=NSMenuItem(); remove.representedObject="词34"; removeRecentSearch(remove); precondition(!recentSearches.contains("词34")); clearRecentSearches(); precondition(recentSearches.isEmpty)
        let navigation=NSMenuItem(); navigation.representedObject=root; navigatePath(navigation); precondition(folder == root && !scopeAll && search.stringValue.isEmpty && entries.count == 1)
        scopeAll=false; folder=fixture; search.stringValue="txt"; showingRecent=false; localCollection=nil; searchMode = .filename
        let roots=[root,other],key=roots.map(\.path).joined(separator:"\n"); let initial=scanNames(roots,cancelled:{ false }); try! catalogStore.save(initial,key:key,roots:roots); catalogCache[key]=(Date(),initial); validatedCatalogs.insert(key)
        saveDirectorySnapshots(initial,roots:roots,store:catalogStore); let otherBefore=try! Data(contentsOf:catalogStore.file(other.path))
        let added=root.appendingPathComponent("new.txt"); try! Data([4]).write(to:added); rebuildDirectory(root)
        var attempts=0; Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] timer in
            guard let self else { return }; attempts += 1
            if self.rebuildingDirectories.contains(root.path) { if attempts > 100 { fatalError("single directory rebuild timeout") }; return }
            precondition(self.directorySnapshot(root)!.urls.count == 2 && self.directorySnapshot(other)!.urls.count == 1)
            precondition(try! Data(contentsOf:self.catalogStore.file(other.path)) == otherBefore)
            precondition(self.catalogCache[key]!.1.urls.count == 3 && self.catalogCache[key]!.1.urls.contains { canonicalIndexPath($0) == canonicalIndexPath(z) })
            precondition(self.catalogStore.load(root.path,roots:[root])!.urls.count == 2)
            precondition(self.window.frame.size == NSSize(width:750,height:474))
            print("PASS 2.6: sort order/persistence, multi-selection and isolated file/path clipboard, recent-search bounds/dedup/delete/clear, path navigation, per-directory snapshots and isolated rebuild, unrelated index unchanged, merged catalog preserved, fixed window"); fflush(stdout); timer.invalidate(); NSApp.terminate(nil)
        }
        show()
    }
    func indexCheck() {
        let fixture=URL(fileURLWithPath:"/tmp/kongfetch-indexcheck-"+UUID().uuidString)
        let indexDir=URL(fileURLWithPath:fixture.path+"-store")
        try! FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
        let suite="com.kongfetch.indexcheck."+UUID().uuidString; preferences=UserDefaults(suiteName:suite)!; restoringState=true; catalogStore=CatalogStore(indexDir)
        scopeAll=false; folder=fixture; fileFilter = .all; filterPicker.selectItem(at:0); dateFilter=0; sizeFilter=0; searchMode = .filename; search.stringValue="watch"; startSearch(); show()
        var phase=0; let deadline=Date().addingTimeInterval(65)
        Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if Date() > deadline { print("FAIL: live index phase \(phase)"); fflush(stdout); self.stopQuery(); self.stopWatching(); timer.invalidate(); NSApp.terminate(nil); return }
            let names=self.entries.map { $0.url.lastPathComponent }
            if phase == 0 && !self.scanningNames { precondition(self.watchStream != nil); try! Data("sample".utf8).write(to:fixture.appendingPathComponent("watch-a.txt")); phase=1 }
            else if phase == 1 && names.contains("watch-a.txt") { try! FileManager.default.moveItem(at:fixture.appendingPathComponent("watch-a.txt"),to:fixture.appendingPathComponent("watch-b.txt")); phase=2 }
            else if phase == 2 && names.contains("watch-b.txt") && !names.contains("watch-a.txt") { try! FileManager.default.removeItem(at:fixture.appendingPathComponent("watch-b.txt")); phase=3 }
            else if phase == 3 && !self.scanningNames && names.isEmpty {
                precondition(self.incrementalUpdates >= 3 && self.fullScans == 1); self.filesChanged([],force:true); phase=4
            }
            else if phase == 4 && !self.scanningNames && self.fullScans == 2 {
                let key=fixture.path; let reloaded=CatalogStore(indexDir).load(key,roots:[fixture]); precondition(reloaded != nil && reloaded!.urls.isEmpty)
                precondition(self.window.frame.size == NSSize(width:750,height:474))
                precondition(self.incrementalUpdates >= 3 && self.fullScans == 2)
            print("PASS: incremental FSEvents without full rescans for ordinary changes, recovery fallback; real FSEvents creation, rename, deletion and fresh persisted index reload; frame=\(self.window.frame.size); scale=\(self.window.screen?.backingScaleFactor ?? 0)"); fflush(stdout)
                self.stopQuery(); self.stopWatching(); timer.invalidate(); self.preferences.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:fixture); try? FileManager.default.removeItem(at:indexDir); NSApp.terminate(nil)
            }
        }
    }
    func previewCheck() {
        let fixture=URL(fileURLWithPath:"/tmp/kongfetch-preview-"+UUID().uuidString); previewFixture=fixture
        try! FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
        let pdfURL=fixture.appendingPathComponent("Search-demo.pdf"); var media=CGRect(x:0,y:0,width:595,height:842)
        let context=CGContext(consumer:CGDataConsumer(url:pdfURL as CFURL)!,mediaBox:&media,nil)!
        for text in ["KongFetch alpha on first page","KongFetch alpha on second page"] { context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false); NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:25)]).draw(at:NSPoint(x:50,y:700)); NSGraphicsContext.restoreGraphicsState(); context.endPDFPage() }; context.closePDF()
        let textURL=fixture.appendingPathComponent("Notes-demo.txt"); try! "KongFetch alpha text excerpt for preview validation.".write(to:textURL,atomically:true,encoding:.utf8)
        searchMode = .content; updateSearchModeUI(); search.stringValue="alpha"; folder=fixture; scopeAll=false; showingRecent=false; localCollection=nil; collectionTabs.selectedSegment = -1
        titleLabel.stringValue="正文匹配"; entries=[Entry(pdfURL),Entry(textURL)]; refreshList(selectFirst:true); status.stringValue="界面检查样本 · 2 个项目"; show()
    }
    func smokeTest() {
        let fixture=URL(fileURLWithPath:"/tmp/kongfetch-smoke-\(ProcessInfo.processInfo.processIdentifier)")
        let suite="com.kongfetch.test."+UUID().uuidString
        catalogStore=CatalogStore(fixture.appendingPathComponent("test-index"));
        preferences=UserDefaults(suiteName:suite)!; openedDates=[:]; pinnedPaths=[]; pinBookmarks=[:]; openCounts=[:]; restoringState=false
        defer { preferences.removePersistentDomain(forName:suite) }
        do {
            try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
            try "KongFetch preview verification".write(to:fixture.appendingPathComponent("preview.txt"),atomically:true,encoding:.utf8)
            try FileManager.default.createDirectory(at:fixture.appendingPathComponent("Folder"),withIntermediateDirectories:true)
            browse(fixture,push:false)
            precondition(entries.count == 2 && entries[0].directory)
            table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
            tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification))
            precondition(preview.previewItem?.previewItemURL?.resolvingSymlinksInPath() == fixture.appendingPathComponent("preview.txt").resolvingSymlinksInPath())
            precondition(detail.stringValue.contains("preview.txt"))
            precondition(metadataValues.count == 6 && metadataValues[0].stringValue == "preview.txt")
            precondition(metadataValues[2].stringValue != "—")
            precondition(window.contentView!.subviews.count > 0)
            window.contentView!.layoutSubtreeIfNeeded()
            let exact=Entry(fixture.appendingPathComponent("preview.txt"))
            let prefix=Entry(fixture.appendingPathComponent("preview-notes.txt"))
            let partial=Entry(fixture.appendingPathComponent("my-preview.txt"))
            let ranked=rankEntries([partial,prefix,exact],words:["preview"],counts:[partial.url.path:100])
            precondition(ranked.map { $0.url.lastPathComponent } == ["preview.txt","preview-notes.txt","my-preview.txt"])
            let frequent=rankEntries([partial,prefix],words:["view"],counts:[partial.url.path:4])
            precondition(frequent.first!.url == prefix.url) // Relevance beats usage when match position differs.
            let exactFolder=fixture.appendingPathComponent("乐乐",isDirectory:true); try FileManager.default.createDirectory(at:exactFolder,withIntermediateDirectories:true)
            let photo=exactFolder.appendingPathComponent("乐乐证件照片.jpeg"); try Data([1,2,3]).write(to:photo)
            let chinese=[Entry(photo),Entry(exactFolder),Entry(fixture.appendingPathComponent("焦乐乐论文.docx"))]
            precondition(rankEntries(chinese,words:["乐乐"],counts:[:]).first!.url.path == exactFolder.path)
            precondition(filenameScore(exactFolder,words:["lele"]) != nil && filenameScore(exactFolder,words:["ll"]) != nil)
            precondition(filenameScore(URL(fileURLWithPath:"/tmp/reports/AnnualBudget2026.xlsx"),words:["ab26"]) != nil)
            precondition(filenameScore(URL(fileURLWithPath:"/tmp/reports/AnnualBudget2026.xlsx"),words:["reports","budget"]) != nil)
            precondition(filenameScore(URL(fileURLWithPath:"/tmp/abc.txt"),words:["cba"]) == nil)
            let catalog=scanNames([fixture],maximum:100,cancelled:{ false }); precondition(catalog.urls.contains(where:{ $0.resolvingSymlinksInPath().path == exactFolder.resolvingSymlinksInPath().path }))
            precondition(scanNames([fixture],maximum:1,cancelled:{ false }).limited)
            precondition(scanNames([fixture],cancelled:{ true }).urls.isEmpty)
            let parsed=SearchInput("pdf 合同 年度",fallback:.images)
            precondition(parsed.filter == .pdf && parsed.words == ["合同","年度"])
            precondition(SearchInput("年度 报告",fallback:.documents).words.count == 2)
            try "%PDF-1.4".write(to:fixture.appendingPathComponent("合同.pdf"),atomically:true,encoding:.utf8)
            let pdf=Entry(fixture.appendingPathComponent("合同.pdf"))
            precondition(FileFilter.pdf.accepts(pdf) && FileFilter.documents.accepts(pdf))
            precondition(!FileFilter.images.accepts(pdf) && !FileFilter.folders.accepts(pdf))
            precondition(FileFilter.folders.accepts(entries[0]))
            fileFilter = .pdf; entries=browseEntries.filter(fileFilter.accepts).filter(acceptsDetails); precondition(entries.isEmpty)
            search.stringValue="pdf 合同"; startSearch(); precondition(query!.predicate!.evaluate(with:[NSMetadataItemFSNameKey:"年度合同.pdf",NSMetadataItemContentTypeTreeKey:["public.data","com.adobe.pdf"]]))
            precondition(!query!.predicate!.evaluate(with:[NSMetadataItemFSNameKey:"年度合同.png",NSMetadataItemContentTypeTreeKey:["public.data","public.image"]]))
            stopQuery()
            for filter in FileFilter.allCases {
                fileFilter=filter; search.stringValue="年度 合同"; startSearch(); precondition(query!.isStarted); stopQuery()
                loadRecent(); precondition(query!.isStarted); stopQuery()
            }
            fileFilter = .all
            loginToggle.state = .on; toggleLogin(); precondition(loginStatus.stringValue.contains("请先把"))
            fileFilter = .all; browse(fixture,push:false)
            table.selectRowIndexes(IndexSet(integer:entries.firstIndex { $0.url.lastPathComponent == "preview.txt" }!),byExtendingSelection:false)
            let chosen=selected!.url
            pinSelected(); precondition(preferences.stringArray(forKey:"pinnedPaths") == [chosen.path])
            recordOpen(chosen); precondition(openedDates.count == 1)
            loadLocalCollection(1); precondition(entries.count == 1 && titleLabel.stringValue == "最近打开")
            loadLocalCollection(2); precondition(entries.count == 1 && titleLabel.stringValue == "固定收藏")
            let pb=NSPasteboard.withUniqueName(); defer { pb.releaseGlobally() }
            writePath(entries[0].url,to:pb); precondition(pb.string(forType:.string) == entries[0].url.path)
            precondition(writeFile(entries[0].url,to:pb))
            precondition((pb.readObjects(forClasses:[NSURL.self]) as? [NSURL])?.first.map { ($0 as URL).resolvingSymlinksInPath() } == entries[0].url.resolvingSymlinksInPath())
            pinSelected(); precondition(pinnedPaths.isEmpty && entries.isEmpty)
            pinnedPaths=[chosen.path]; pinBookmarks=[:]; resolvePins()
            precondition(pinBookmarks[chosen.path] != nil)
            let moved=fixture.appendingPathComponent("Folder/renamed-preview.txt")
            try FileManager.default.moveItem(at:chosen,to:moved)
            pinBookmarks=preferences.dictionary(forKey:"pinBookmarks") as? [String:Data] ?? [:]
            resolvePins()
            precondition(pinnedPaths.count == 1 && URL(fileURLWithPath:pinnedPaths[0]).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
            let replacement=fixture.appendingPathComponent("replacement.txt")
            try "Relocated file".write(to:replacement,atomically:true,encoding:.utf8)
            replacePin(pinnedPaths[0],with:replacement)
            precondition(pinnedPaths == [replacement.path] && pinBookmarks[replacement.path] != nil)
            fileFilter = .images; filterPicker.selectItem(at:fileFilter.rawValue)
            loadLocalCollection(2); saveState()
            let saved=preferences.dictionary(forKey:"workspaceState")!
            fileFilter = .all; scopeAll=true; localCollection=nil
            restoreState(saved)
            precondition(fileFilter == .images && !scopeAll && localCollection == 2)
            precondition(folder.resolvingSymlinksInPath().path == fixture.resolvingSymlinksInPath().path)
            fileFilter = .all; filterPicker.selectItem(at:0)
            loadLocalCollection(2); show()
            precondition((window.firstResponder as? NSTextView)?.delegate as? NSSearchField === search || window.firstResponder === search)
            searchMode = .content; updateSearchModeUI()
            search.stringValue="pdf 年度 合同"; startSearch()
            let matching:[String:Any]=[NSMetadataItemFSNameKey:"无关文件名.pdf",NSMetadataItemTextContentKey:"这里是年度合同正文",NSMetadataItemContentTypeTreeKey:["public.data","com.adobe.pdf"]]
            precondition(query!.isStarted && query!.predicate!.evaluate(with:matching))
            let nonmatching:[String:Any]=[NSMetadataItemFSNameKey:"年度合同.pdf",NSMetadataItemTextContentKey:"无关正文",NSMetadataItemContentTypeTreeKey:["public.data","com.adobe.pdf"]]
            precondition(!query!.predicate!.evaluate(with:nonmatching)); stopQuery()
            for filter in FileFilter.allCases { fileFilter=filter; search.stringValue="正文 关键词"; startSearch(); precondition(query!.isStarted); stopQuery() }
            fileFilter = .all; saveState(); let modeState=preferences.dictionary(forKey:"workspaceState")!
            searchMode = .filename; restoreState(modeState); precondition(searchMode == .content && searchModePicker.indexOfSelectedItem == 1)
            searchMode = .filename; updateSearchModeUI()
            precondition(excerptText("Prefix alpha suffix",words:["ALPHA"]).contains("alpha"))
            precondition(matchRanges("café ALPHA alpha",words:["cafe","alpha"]).count == 3)
            let textEvidence=readEvidence(replacement,words:["relocated"],keepPDF:false)
            precondition(textEvidence.excerpt.contains("Relocated"))
            let pdfURL=fixture.appendingPathComponent("two-pages.pdf")
            var media=CGRect(x:0,y:0,width:595,height:842)
            let context=CGContext(consumer:CGDataConsumer(url:pdfURL as CFURL)!,mediaBox:&media,nil)!
            for text in ["First page alpha","Second page alpha beta"] {
                context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
                NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:20)]).draw(at:NSPoint(x:50,y:700))
                NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
            }
            context.closePDF()
            let pdfEvidence=readEvidence(pdfURL,words:["alpha"],keepPDF:true)
            precondition(pdfEvidence.document?.pageCount == 2 && pdfEvidence.matches.count == 2 && pdfEvidence.excerpt.contains("alpha"))
            searchMode = .content; search.stringValue="alpha"; showingRecent=false; localCollection=nil
            pdfView.document=pdfEvidence.document; pdfMatches=pdfEvidence.matches; matchIndex=0; pdfLimited=false; updateMatch()
            precondition(matchLabel.stringValue.contains("第 1 页")); nextPDFMatch(); precondition(matchLabel.stringValue.contains("第 2 页") && evidenceLabel.stringValue.contains("Second page")); previousPDFMatch(); precondition(matchLabel.stringValue.contains("第 1 页"))
            let blankImage=NSImage(size:NSSize(width:100,height:100)); blankImage.lockFocus(); NSColor.white.setFill(); NSBezierPath(rect:NSRect(x:0,y:0,width:100,height:100)).fill(); blankImage.unlockFocus()
            let emptyPDF=PDFDocument(); emptyPDF.insert(PDFPage(image:blankImage)!,at:0)
            let scanURL=fixture.appendingPathComponent("scan.pdf"); precondition(emptyPDF.write(to:scanURL))
            let scanEvidence=readEvidence(scanURL,words:["alpha"],keepPDF:true); precondition(scanEvidence.matches.isEmpty && scanEvidence.excerpt.contains("OCR"))
            searchMode = .content; search.stringValue="alpha"; showingRecent=false; localCollection=nil
            precondition(highlightExcerpt("alpha").attribute(.backgroundColor,at:0,effectiveRange:nil) != nil)
            searchMode = .filename; search.stringValue=""; resetEvidence()
            let registered=hotKey != nil
            if registered, let current=registeredShortcut { precondition(register(code:current.0,modifiers:current.1)) }
            search.stringValue="preview"; startSearch()
            precondition(query != nil && query!.isStarted)
            stopQuery()
            scopeAll=true; loadRecent(); precondition(showingRecent && query!.isStarted)
            stopQuery()
            let cancelledEvidence=readEvidence(replacement,words:["relocated"],keepPDF:false,cancelled:{ true }); precondition(cancelledEvidence.excerpt.contains("取消"))
            search.stringValue="取消测试"; startSearch(); cancelSearch(); precondition(query == nil && cancelButton.isHidden && status.stringValue.contains("取消"))
            let boundary=fixture.appendingPathComponent("size-boundary.txt")
            try Data(count:1_000_000).write(to:boundary)
            sizeFilter=1; precondition(!acceptsDetails(Entry(boundary))); sizeFilter=2; precondition(acceptsDetails(Entry(boundary))); sizeFilter=3; precondition(!acceptsDetails(Entry(boundary)))
            sizeFilter=1; precondition(!acceptsDetails(Entry(fixture))); sizeFilter=0
            dateFilter=4; dateField=0; customStart=Date(); customEnd=Date(); let bounds=dateBounds()!
            try FileManager.default.setAttributes([.modificationDate:bounds.0],ofItemAtPath:boundary.path); precondition(acceptsDetails(Entry(boundary)))
            try FileManager.default.setAttributes([.modificationDate:bounds.1],ofItemAtPath:boundary.path); precondition(!acceptsDetails(Entry(boundary)))
            dateFilter=2; sizeFilter=2; search.stringValue="boundary"; startSearch(); precondition(query!.isStarted && detailPredicates().count == 4); stopQuery()
            saveState(); let filterState=preferences.dictionary(forKey:"workspaceState")!; dateFilter=0; sizeFilter=0; restoreState(filterState); precondition(dateFilter == 2 && sizeFilter == 2)
            clearFilters(); precondition(dateFilter == 0 && sizeFilter == 0 && fileFilter == .all && clearFiltersButton.isHidden); stopQuery()
            let subtree=fixture.appendingPathComponent("watch-dir"); try FileManager.default.createDirectory(at:subtree,withIntermediateDirectories:true); try Data([1]).write(to:subtree.appendingPathComponent("child.txt")); for i in 0..<250 { try Data([1]).write(to:subtree.appendingPathComponent("batch-\(i).txt")) }
            let before=scanNames([fixture],cancelled:{ false }); let renamed=fixture.appendingPathComponent("renamed-dir"); try FileManager.default.moveItem(at:subtree,to:renamed)
            let incremental=updateCatalog(before,paths:[subtree.path,renamed.path],roots:[fixture],excluding:[],cancelled:{ false })
            let full=scanNames([fixture],cancelled:{ false }); precondition(Set(incremental.urls.map(canonicalIndexPath)) == Set(full.urls.map(canonicalIndexPath)))
            let hidden=fixture.appendingPathComponent(".hidden-file"); try Data([1]).write(to:hidden)
            let noHidden=updateCatalog(incremental,paths:[hidden.path],roots:[fixture],excluding:[],cancelled:{ false }); precondition(!noHidden.urls.contains { $0.lastPathComponent == ".hidden-file" })
            let legacy=fixture.appendingPathComponent("legacy-index"); let legacyStore=CatalogStore(legacy); try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true)
            let oldJSON:[String:Any]=["version":1,"roots":[fixture.path],"paths":[boundary.path],"unreadable":0]; try JSONSerialization.data(withJSONObject:oldJSON).write(to:legacyStore.file("old")); precondition(legacyStore.load("old",roots:[fixture])?.urls.count == 1)
            precondition(matchingReasons(exactFolder,words:["乐乐"]) == ["文件名"] && matchingReasons(exactFolder,words:["lele"]) == ["拼音"])
            precondition(matchingReasons(URL(fileURLWithPath:"/tmp/reports/AnnualBudget2026.xlsx"),words:["reports","ab26"]) == ["路径","文件名缩写"])
            precondition(highlightedName("AnnualBudget2026.xlsx",words:["ab26"]).attribute(.backgroundColor,at:0,effectiveRange:nil) != nil)
            scopeAll=false; folder=fixture; search.stringValue="preview"; fileFilter = .documents; dateFilter=2; sizeFilter=1; searchMode = .filename
            let savedQuery=captureSearch("测试搜索"); preferences.set([savedQuery],forKey:"savedSearches"); precondition(savedSearches.count == 1); dateFilter=0; sizeFilter=0; applySavedSearch(savedQuery); precondition(search.stringValue == "preview" && folder.path == fixture.path && fileFilter == .documents && dateFilter == 2 && sizeFilter == 1); stopQuery()
            let store=CatalogStore(fixture.appendingPathComponent("persisted")); let key="test"; try store.save(catalog,key:key,roots:[fixture]); precondition(store.load(key,roots:[fixture])!.urls.count == catalog.urls.count)
            precondition(store.load(key,roots:[fixture.appendingPathComponent("other")]) == nil); store.invalidate(key); precondition(store.load(key,roots:[fixture]) == nil)
            precondition(window.frame.size == NSSize(width:750,height:474))
            try FileManager.default.removeItem(at:fixture)
                let twin=Entry(URL(fileURLWithPath:fixture.path+"/other/preview.txt"))
            precondition(rankEntries([exact,twin],words:["preview"],counts:[:],preferredPath:twin.url.path).first!.url == twin.url)
            precondition(rankEntries([exact,partial],words:["preview"],counts:[:],preferredPath:partial.url.path).first!.url == exact.url)
            precondition(compactLocation(URL(fileURLWithPath:"/tmp/a/same.txt"),peers:[URL(fileURLWithPath:"/tmp/a/same.txt"),URL(fileURLWithPath:"/tmp/b/same.txt")]) == "a")
            showingRecent=false; localCollection=nil; search.stringValue="preview"; recordOpen(exact.url); precondition(rememberedSearchPath == exact.url.path)
            search.stringValue="different"; precondition(rememberedSearchPath == nil)
            scopeAll=false; folder=fixture; search.stringValue="pdf preview"; fileFilter = .all; dateFilter=2; sizeFilter=1; scanningNames=true
            expandSearchScope(); precondition(isFullSearchScope && search.stringValue == "pdf preview" && dateFilter == 2 && sizeFilter == 1); scopeAll=false; folder=fixture
            precondition(hasSearchRestrictions && emptySearchExplanation().contains("PDF") && emptySearchExplanation().contains("索引仍在更新"))
            removeSearchRestrictions(); precondition(search.stringValue == "preview" && !hasSearchRestrictions && folder == fixture)
            searchMode = .content; precondition(emptySearchExplanation().contains("Spotlight")); searchMode = .filename
            search.stringValue="preview"; showingRecent=false; localCollection=nil
            rememberSearchChoice(partial.url,manual:true); precondition(manualSearchPath == partial.url.path)
            rememberSearchChoice(exact.url,manual:false); precondition(manualSearchPath == partial.url.path)
            precondition(rankEntries([exact,partial],words:["preview"],counts:[:],manualPath:manualSearchPath).first!.url == partial.url)
            precondition(rankEntries([exact],words:["preview"],counts:[:],manualPath:manualSearchPath).first!.url == exact.url)
            removeCurrentSearchPreference(); precondition(rememberedSearchPath == nil && manualSearchPath == nil)
            rememberSearchChoice(exact.url,manual:false); precondition(rememberedSearchPath == exact.url.path && manualSearchPath == nil)
            print("PASS: filename/path/pinyin reasons, fuzzy name highlighting, saved search persistence/restore, incremental directory rename matches full scan, hidden-item exclusion, 2.0 index compatibility, persisted index reload/invalidate, compact window dimensions, exact Chinese folder rank, pinyin/initials, filename abbreviation, path tokens, wrong-order rejection, unindexed catalog, scan cap/cancel, date boundaries, decimal MB boundary, folder size exclusion, combined query, filter persistence/clear, cancellation, cooperative extraction cancellation, text excerpt, case/diacritic highlighting, generated two-page PDF matching/navigation, scan fallback, body-only matching, filename-only exclusion, seven content query types, search-mode restore, legacy pin migration, bookmark move/rename tracking, pin relocation, workspace restore, search focus, pinned persistence/removal, opened history, isolated path/file clipboard, exact/prefix ranking, usage ranking, multiword/type parsing, PDF/document/folder filtering, metadata predicates, login installation guard, browsing, preview, search, recents, layout. Global shortcut registered: \(registered)")
            fflush(stdout); NSApp.terminate(nil)
        } catch { print("FAIL: \(error)"); exit(1) }
    }
    func buildMenus() {
        let main = NSMenu(); let item = NSMenuItem(); main.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "关于 KongFetch", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle:"搜索目录…",action:#selector(manageDirectories),keyEquivalent:""); appMenu.addItem(.separator()); appMenu.addItem(withTitle: "退出 KongFetch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); main.addItem(fileItem); fileItem.submenu = NSMenu(title: "文件")
        fileItem.submenu?.addItem(withTitle: "打开文件夹…", action: #selector(chooseFolder), keyEquivalent: "o")
        fileItem.submenu?.addItem(withTitle: "在访达中显示", action: #selector(reveal), keyEquivalent: "r")
        let edit = NSMenuItem(); main.addItem(edit); edit.submenu = NSMenu(title: "编辑")
        for (name, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { edit.submenu?.addItem(withTitle: name, action: Selector(action), keyEquivalent: key) }
        observeMenu(main); NSApp.mainMenu = main
    }
    func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b }
    func buildWindow() {
        window = SearchWindow(contentRect: NSRect(x:0,y:0,width:750,height:474), styleMask:[.borderless],backing:.buffered,defer:false)
        window.title="KongFetch"; window.minSize=NSSize(width:750,height:474); window.maxSize=window.minSize; window.isMovableByWindowBackground=true; window.center(); window.delegate=self; window.isReleasedWhenClosed=false
        window.titlebarAppearsTransparent=true; window.backgroundColor = NSColor(calibratedWhite:0.96,alpha:1)
        window.isOpaque=false; window.backgroundColor = .clear; window.hasShadow=true
        let surface=ThemeSurface(); window.contentView=surface; let root=surface; root.wantsLayer=true; root.layer?.cornerRadius=14; root.layer?.masksToBounds=true; root.needsDisplay=true
        NSLayoutConstraint.activate([root.widthAnchor.constraint(equalToConstant:750),root.heightAnchor.constraint(equalToConstant:474)])
        func mount(_ view:NSView, in parent:NSView) { view.translatesAutoresizingMaskIntoConstraints=false; parent.addSubview(view) }
        func line()->NSView { ThemeSurface(separator:true) }
        let top=NSView(); mount(top,in:root)
        let back=button("←",#selector(goBack)); back.isBordered=false; back.font = .systemFont(ofSize:26); back.toolTip="返回文件夹，或回到最近文件"; mount(back,in:top)
        search.placeholderString="搜索文件…"; search.delegate=self; search.sendsSearchStringImmediately=true; search.font = .systemFont(ofSize:20); search.isBordered=false; search.focusRingType = .none
        if let cell=search.cell as? NSSearchFieldCell { cell.searchButtonCell=nil; cell.backgroundColor = .clear }
        mount(search,in:top)
        let info=button("ⓘ",#selector(about)); info.isBordered=false; info.font = .systemFont(ofSize:22); mount(info,in:top)
        searchModePicker.addItems(withTitles:["文件名","文件内容"]); searchModePicker.target=self; searchModePicker.action = #selector(changeSearchMode); searchModePicker.font = .systemFont(ofSize:14); searchModePicker.toolTip="文件内容搜索 Spotlight 正文及本地 OCR 索引；可从 ⌘K 为扫描 PDF 和图片建立 OCR 索引。"; mount(searchModePicker,in:top)
        scopePicker.removeAllItems(); scopePicker.addItems(withTitles:["全用户文件","全用户与应用程序","桌面","文稿","下载","图片","选择文件夹…"]); scopePicker.target=self; scopePicker.action = #selector(changeScope(_:)); scopePicker.font = .systemFont(ofSize:13); mount(scopePicker,in:top)
        NSLayoutConstraint.activate([top.topAnchor.constraint(equalTo:root.topAnchor),top.leadingAnchor.constraint(equalTo:root.leadingAnchor),top.trailingAnchor.constraint(equalTo:root.trailingAnchor),top.heightAnchor.constraint(equalToConstant:56),back.leadingAnchor.constraint(equalTo:top.leadingAnchor,constant:16),back.centerYAnchor.constraint(equalTo:top.centerYAnchor),back.widthAnchor.constraint(equalToConstant:38),search.leadingAnchor.constraint(equalTo:back.trailingAnchor,constant:8),search.centerYAnchor.constraint(equalTo:top.centerYAnchor),search.trailingAnchor.constraint(equalTo:info.leadingAnchor,constant:-14),search.heightAnchor.constraint(equalToConstant:26),info.widthAnchor.constraint(equalToConstant:32),info.centerYAnchor.constraint(equalTo:top.centerYAnchor),searchModePicker.leadingAnchor.constraint(equalTo:info.trailingAnchor,constant:12),searchModePicker.widthAnchor.constraint(equalToConstant:95),searchModePicker.centerYAnchor.constraint(equalTo:top.centerYAnchor),scopePicker.leadingAnchor.constraint(equalTo:searchModePicker.trailingAnchor,constant:12),scopePicker.trailingAnchor.constraint(equalTo:top.trailingAnchor,constant:-16),scopePicker.centerYAnchor.constraint(equalTo:top.centerYAnchor),scopePicker.widthAnchor.constraint(equalToConstant:165)])
        let topLine=line(); mount(topLine,in:root)
        let footer=NSView(); mount(footer,in:root); let footerLine=line(); mount(footerLine,in:root)
        let body=NSView(); mount(body,in:root)
        NSLayoutConstraint.activate([topLine.topAnchor.constraint(equalTo:top.bottomAnchor),topLine.heightAnchor.constraint(equalToConstant:1),topLine.leadingAnchor.constraint(equalTo:root.leadingAnchor),topLine.trailingAnchor.constraint(equalTo:root.trailingAnchor),footer.bottomAnchor.constraint(equalTo:root.bottomAnchor),footer.heightAnchor.constraint(equalToConstant:40),footer.leadingAnchor.constraint(equalTo:root.leadingAnchor),footer.trailingAnchor.constraint(equalTo:root.trailingAnchor),footerLine.bottomAnchor.constraint(equalTo:footer.topAnchor),footerLine.heightAnchor.constraint(equalToConstant:1),footerLine.leadingAnchor.constraint(equalTo:root.leadingAnchor),footerLine.trailingAnchor.constraint(equalTo:root.trailingAnchor),body.topAnchor.constraint(equalTo:topLine.bottomAnchor),body.bottomAnchor.constraint(equalTo:footerLine.topAnchor),body.leadingAnchor.constraint(equalTo:root.leadingAnchor),body.trailingAnchor.constraint(equalTo:root.trailingAnchor)])
        let left=NSView(); mount(left,in:body); let divider=line(); mount(divider,in:body); let right=NSView(); mount(right,in:body)
        NSLayoutConstraint.activate([left.leadingAnchor.constraint(equalTo:body.leadingAnchor),left.topAnchor.constraint(equalTo:body.topAnchor),left.bottomAnchor.constraint(equalTo:body.bottomAnchor),left.widthAnchor.constraint(equalTo:body.widthAnchor,multiplier:0.39),divider.leadingAnchor.constraint(equalTo:left.trailingAnchor),divider.topAnchor.constraint(equalTo:body.topAnchor),divider.bottomAnchor.constraint(equalTo:body.bottomAnchor),divider.widthAnchor.constraint(equalToConstant:1),right.leadingAnchor.constraint(equalTo:divider.trailingAnchor),right.trailingAnchor.constraint(equalTo:body.trailingAnchor),right.topAnchor.constraint(equalTo:body.topAnchor),right.bottomAnchor.constraint(equalTo:body.bottomAnchor)])
        titleLabel.font = .systemFont(ofSize:13,weight:.semibold); titleLabel.textColor = .secondaryLabelColor; mount(titleLabel,in:left)
        filterPicker.addItems(withTitles:FileFilter.allCases.map(\.title)); filterPicker.target=self; filterPicker.action = #selector(changeFilter); filterPicker.font = .systemFont(ofSize:13); mount(filterPicker,in:left)
        collectionTabs.target=self; collectionTabs.action = #selector(changeCollection); collectionTabs.selectedSegment=0; mount(collectionTabs,in:left)
        NSLayoutConstraint.activate([collectionTabs.leadingAnchor.constraint(equalTo:left.leadingAnchor,constant:16),collectionTabs.trailingAnchor.constraint(equalTo:left.trailingAnchor,constant:-16),collectionTabs.topAnchor.constraint(equalTo:titleLabel.bottomAnchor,constant:8),collectionTabs.heightAnchor.constraint(equalToConstant:30)])
        let filterBar=NSStackView(views:[navigationButton,recentSearchButton,advancedButton,filterSummary,clearFiltersButton]); filterBar.spacing=6; mount(filterBar,in:left); filterSummary.font = .systemFont(ofSize:11); filterSummary.textColor = .secondaryLabelColor; filterSummary.lineBreakMode = .byTruncatingTail; filterSummary.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        NSLayoutConstraint.activate([filterBar.leadingAnchor.constraint(equalTo:left.leadingAnchor,constant:16),filterBar.trailingAnchor.constraint(equalTo:left.trailingAnchor,constant:-16),filterBar.topAnchor.constraint(equalTo:collectionTabs.bottomAnchor,constant:6),filterBar.heightAnchor.constraint(equalToConstant:28)]); updateFilterSummary()
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; scroll.autohidesScrollers=true; scroll.drawsBackground=false; mount(scroll,in:left)
        let c=NSTableColumn(identifier:.init("name")); c.width=420; c.resizingMask = .autoresizingMask; table.addTableColumn(c); table.headerView=nil; table.autoresizingMask=[.width]; c.minWidth=120; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.allowsMultipleSelection=true; table.delegate=self; table.dataSource=self; table.rowHeight=48; table.intercellSpacing=NSSize(width:0,height:4); table.backgroundColor = .clear; table.usesAlternatingRowBackgroundColors=false; table.selectionHighlightStyle = .regular; table.allowsMultipleSelection=true; table.doubleAction = #selector(openSelected); table.target=self; table.setDraggingSourceOperationMask(.copy,forLocal:false); table.setDraggingSourceOperationMask(.copy,forLocal:true); scroll.documentView=table
        suggestionButton.target=self; suggestionButton.action = #selector(showSuggestions); suggestionButton.isHidden=true; emptyLabel.maximumNumberOfLines=5; emptyLabel.lineBreakMode = .byTruncatingTail; emptyLabel.font = .systemFont(ofSize:12); emptyLabel.textColor = .secondaryLabelColor; emptyLabel.alignment = .center; mount(emptyLabel,in:left)
        NSLayoutConstraint.activate([titleLabel.leadingAnchor.constraint(equalTo:left.leadingAnchor,constant:18),titleLabel.trailingAnchor.constraint(equalTo:filterPicker.leadingAnchor,constant:-8),filterPicker.trailingAnchor.constraint(equalTo:left.trailingAnchor,constant:-14),filterPicker.centerYAnchor.constraint(equalTo:titleLabel.centerYAnchor),filterPicker.widthAnchor.constraint(equalToConstant:86),titleLabel.topAnchor.constraint(equalTo:left.topAnchor,constant:10),titleLabel.heightAnchor.constraint(equalToConstant:24),scroll.topAnchor.constraint(equalTo:filterBar.bottomAnchor,constant:8),scroll.leadingAnchor.constraint(equalTo:left.leadingAnchor,constant:4),scroll.trailingAnchor.constraint(equalTo:left.trailingAnchor,constant:-4),scroll.bottomAnchor.constraint(equalTo:left.bottomAnchor,constant:-6),emptyLabel.centerXAnchor.constraint(equalTo:left.centerXAnchor),emptyLabel.topAnchor.constraint(equalTo:scroll.topAnchor,constant:40),emptyLabel.widthAnchor.constraint(equalTo:left.widthAnchor,constant:-32)])
        let emptyActions=NSStackView(views:[widenButton,emptyClearButton,suggestionButton]); emptyActions.orientation = .vertical; emptyActions.spacing=6; mount(emptyActions,in:left); widenButton.isHidden=true; emptyClearButton.isHidden=true; NSLayoutConstraint.activate([emptyActions.centerXAnchor.constraint(equalTo:emptyLabel.centerXAnchor),emptyActions.topAnchor.constraint(equalTo:emptyLabel.bottomAnchor,constant:10)])
        preview=QLPreviewView(frame:.zero,style:.normal); preview.autostarts=false; mount(preview,in:right)
        pdfView.autoScales=true; pdfView.displayMode = .singlePageContinuous; pdfView.isHidden=true; mount(pdfView,in:right)
        evidenceLabel.maximumNumberOfLines=2; evidenceLabel.lineBreakMode = .byTruncatingTail; evidenceLabel.font = .systemFont(ofSize:11); evidenceLabel.textColor = .secondaryLabelColor; mount(evidenceLabel,in:right)
        matchesBar=NSStackView(views:[previousMatch,matchLabel,nextMatch]); matchesBar.spacing=10; matchLabel.font = .systemFont(ofSize:11); previousMatch.isEnabled=false; nextMatch.isEnabled=false; mount(matchesBar,in:right)
        evidenceHeight=evidenceLabel.heightAnchor.constraint(equalToConstant:0); matchesHeight=matchesBar.heightAnchor.constraint(equalToConstant:0)
        let metadata=NSStackView(); metadata.orientation = .vertical; metadata.spacing=0; metadata.alignment = .leading; mount(metadata,in:right)
        let heading=NSTextField(labelWithString:"文件信息"); heading.font = .systemFont(ofSize:16,weight:.semibold); heading.textColor = .secondaryLabelColor; metadata.addArrangedSubview(heading); heading.heightAnchor.constraint(equalToConstant:26).isActive=true
        for label in ["名称","位置","类型","大小","创建时间","修改时间"] {
            let row=NSView(); row.translatesAutoresizingMaskIntoConstraints=false; metadata.addArrangedSubview(row)
            let key=NSTextField(labelWithString:label); key.font = .systemFont(ofSize:12); key.textColor = .secondaryLabelColor; mount(key,in:row)
            let value=NSTextField(labelWithString:"—"); value.font = .systemFont(ofSize:12); value.alignment = .right; value.lineBreakMode = .byTruncatingMiddle; value.isSelectable=true; mount(value,in:row); metadataValues.append(value)
            let rule=line(); mount(rule,in:row)
            NSLayoutConstraint.activate([row.widthAnchor.constraint(equalTo:metadata.widthAnchor),row.heightAnchor.constraint(equalToConstant:27),key.leadingAnchor.constraint(equalTo:row.leadingAnchor),key.centerYAnchor.constraint(equalTo:row.centerYAnchor),key.widthAnchor.constraint(equalToConstant:78),value.leadingAnchor.constraint(equalTo:key.trailingAnchor,constant:8),value.trailingAnchor.constraint(equalTo:row.trailingAnchor),value.centerYAnchor.constraint(equalTo:row.centerYAnchor),rule.leadingAnchor.constraint(equalTo:row.leadingAnchor),rule.trailingAnchor.constraint(equalTo:row.trailingAnchor),rule.bottomAnchor.constraint(equalTo:row.bottomAnchor),rule.heightAnchor.constraint(equalToConstant:1)])
        }
        NSLayoutConstraint.activate([metadata.leadingAnchor.constraint(equalTo:right.leadingAnchor,constant:22),metadata.trailingAnchor.constraint(equalTo:right.trailingAnchor,constant:-20),metadata.bottomAnchor.constraint(equalTo:right.bottomAnchor,constant:-14),preview.leadingAnchor.constraint(equalTo:right.leadingAnchor,constant:22),preview.trailingAnchor.constraint(equalTo:right.trailingAnchor,constant:-22),preview.topAnchor.constraint(equalTo:right.topAnchor,constant:16),preview.bottomAnchor.constraint(equalTo:evidenceLabel.topAnchor,constant:-8),evidenceLabel.leadingAnchor.constraint(equalTo:right.leadingAnchor,constant:22),evidenceLabel.trailingAnchor.constraint(equalTo:right.trailingAnchor,constant:-22),evidenceHeight,evidenceLabel.bottomAnchor.constraint(equalTo:matchesBar.topAnchor,constant:-6),matchesHeight,matchesBar.centerXAnchor.constraint(equalTo:right.centerXAnchor),matchesBar.bottomAnchor.constraint(equalTo:metadata.topAnchor,constant:-8),pdfView.leadingAnchor.constraint(equalTo:preview.leadingAnchor),pdfView.trailingAnchor.constraint(equalTo:preview.trailingAnchor),pdfView.topAnchor.constraint(equalTo:preview.topAnchor),pdfView.bottomAnchor.constraint(equalTo:preview.bottomAnchor)])
        let brand=NSImageView(); brand.image=NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:"搜索文件"); brand.contentTintColor = .systemRed; mount(brand,in:footer)
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail; status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); mount(status,in:footer)
        mount(cancelButton,in:footer); cancelButton.isHidden=true
        let open=button("打开  ↵",#selector(openSelected)); open.isBordered=false; open.font = .systemFont(ofSize:16,weight:.medium); mount(open,in:footer)
        let actions=button("操作  ⌘K",#selector(openActions)); actions.isBordered=false; actions.font = .systemFont(ofSize:16); actionsButton=actions; mount(actions,in:footer)
        NSLayoutConstraint.activate([brand.leadingAnchor.constraint(equalTo:footer.leadingAnchor,constant:18),brand.widthAnchor.constraint(equalToConstant:25),brand.heightAnchor.constraint(equalToConstant:25),brand.centerYAnchor.constraint(equalTo:footer.centerYAnchor),status.leadingAnchor.constraint(equalTo:brand.trailingAnchor,constant:12),status.trailingAnchor.constraint(equalTo:cancelButton.leadingAnchor,constant:-8),cancelButton.trailingAnchor.constraint(equalTo:open.leadingAnchor,constant:-10),cancelButton.widthAnchor.constraint(equalToConstant:52),cancelButton.centerYAnchor.constraint(equalTo:footer.centerYAnchor),status.centerYAnchor.constraint(equalTo:footer.centerYAnchor),open.trailingAnchor.constraint(equalTo:actions.leadingAnchor,constant:-18),open.widthAnchor.constraint(equalToConstant:70),open.centerYAnchor.constraint(equalTo:footer.centerYAnchor),actions.trailingAnchor.constraint(equalTo:footer.trailingAnchor,constant:-18),actions.widthAnchor.constraint(equalToConstant:95),actions.centerYAnchor.constraint(equalTo:footer.centerYAnchor)])
        window.makeFirstResponder(search)
        NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] e in
            guard let self, self.window.isKeyWindow, !self.menuTracking else { return e }
            if self.window.attachedSheet != nil { return e }
            if e.modifierFlags.contains(.command), e.keyCode == 40 { self.openActions(); return nil }
            if self.window.attachedSheet != nil { return e }
            if e.modifierFlags.contains(.command),e.keyCode == 36 { self.revealSelectedFiles(); return nil }
            if e.modifierFlags.contains(.command),e.keyCode == 37 { self.window.makeFirstResponder(self.search); return nil }
            if e.modifierFlags.contains(.command),e.keyCode == 4 { self.showRecentSearches(); return nil }
            if e.keyCode == 125 && !self.entries.isEmpty { let inTable=self.window.firstResponder === self.table; self.window.makeFirstResponder(self.table); let next=inTable ? min(self.entries.count-1,max(0,self.table.selectedRow+1)) : max(0,self.table.selectedRow); self.table.selectRowIndexes(IndexSet(integer:next),byExtendingSelection:e.modifierFlags.contains(.shift)); self.table.scrollRowToVisible(next); return nil }
            if e.keyCode == 126 && !self.entries.isEmpty && !e.modifierFlags.contains(.shift) { self.window.makeFirstResponder(self.table); let next=max(0,self.table.selectedRow-1); self.table.selectRowIndexes(IndexSet(integer:next),byExtendingSelection:false); self.table.scrollRowToVisible(next); return nil }
            if e.keyCode == 53 { self.recentSearchTimer?.invalidate(); self.window.orderOut(nil); return nil }
            if self.window.firstResponder === self.table {
                if e.keyCode == 49 { self.quickLook(); return nil }
                if e.keyCode == 36 { self.openSelected(); return nil }
            }
            return e
        }
    }
    func saveState() {
        guard !restoringState, window != nil else { return }
        preferences.set(["frame":NSStringFromRect(window.frame),"layoutVersion":2,"all":scopeAll,"folder":folder.path,"roots":savedScopeOverride ?? searchRoots,"filter":fileFilter.rawValue,"dateFilter":dateFilter,"sizeFilter":sizeFilter,"dateField":dateField,"customStart":customStart,"customEnd":customEnd,"searchMode":searchMode.rawValue,"collection":localCollection ?? (showingRecent ? 0 : 3)],forKey:"workspaceState")
    }
    func restoreState(_ state:[String:Any]?) {
        restoringState=true
        defer { restoringState=false; saveState() }
        guard let state else { scopeAll=true; loadRecent(); return }
        dateFilter=min(4,max(0,state["dateFilter"] as? Int ?? 0)); sizeFilter=min(3,max(0,state["sizeFilter"] as? Int ?? 0)); dateField=min(1,max(0,state["dateField"] as? Int ?? 0)); customStart=state["customStart"] as? Date ?? customStart; customEnd=state["customEnd"] as? Date ?? customEnd
        fileFilter=FileFilter(rawValue:state["filter"] as? Int ?? 0) ?? .all; filterPicker.selectItem(at:fileFilter.rawValue)
        updateFilterSummary()
        searchMode=SearchMode(rawValue:state["searchMode"] as? Int ?? 0) ?? .filename; updateSearchModeUI()
        let home=FileManager.default.homeDirectoryForCurrentUser
        let stored=URL(fileURLWithPath:state["folder"] as? String ?? home.path)
        let values=try? stored.resourceValues(forKeys:[.isDirectoryKey])
        let validFolder=values?.isDirectory == true ? stored : home
        searchRoots=(state["roots"] as? [String] ?? [home.path]).filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath:$0) }
        if searchRoots.isEmpty { searchRoots=[home.path] }
        let all=state["all"] as? Bool ?? true
        if all { scopeAll=true; folder=home; scopePicker.selectItem(at:searchRoots.count > 1 ? 1 : 0) }
        else { browse(validFolder,push:false) }
        let mode=state["collection"] as? Int ?? 0
        if mode == 1 || mode == 2 { loadLocalCollection(mode) }
        else if mode == 0 || all { loadRecent() }
        if state["layoutVersion"] as? Int == 2,let frameString=state["frame"] as? String {
            var frame=NSRectFromString(frameString)
            if frame.width.isFinite && frame.height.isFinite && frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width > 0 && frame.height > 0,
               let screen=NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
                let bounds=screen.visibleFrame
                frame.size.width=min(750,bounds.width)
                frame.size.height=min(474,bounds.height)
                frame.origin.x=min(max(frame.minX,bounds.minX),bounds.maxX-frame.width)
                frame.origin.y=min(max(frame.minY,bounds.minY),bounds.maxY-frame.height)
                window.setFrame(frame,display:true)
            }
        }
    }
    func windowDidMove(_ notification:Notification) { saveState() }
    func windowDidResize(_ notification:Notification) { saveState() }
    func applicationWillTerminate(_ notification:Notification) { if let qaSuite { preferences.removePersistentDomain(forName:qaSuite) }; catalogQueue.cancelAllOperations(); ocrQueue.cancelAllOperations(); ocrSearchQueue.cancelAllOperations(); controlWake.disable(); directoryRepairQueue.cancelAllOperations(); if previewFixture != nil { directoryRepairQueue.waitUntilAllOperationsAreFinished(); ocrQueue.waitUntilAllOperationsAreFinished(); ocrSearchQueue.waitUntilAllOperationsAreFinished() }; stopWatching(); saveState(); if let fixture=previewFixture { try? FileManager.default.removeItem(at:fixture) } }
    func persistPins() { preferences.set(pinnedPaths,forKey:"pinnedPaths"); preferences.set(pinBookmarks,forKey:"pinBookmarks") }
    func makeBookmark(_ url:URL)->Data? { try? url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil) }
    func resolvePins() {
        var paths:[String]=[]; var bookmarks:[String:Data]=[:]
        for old in pinnedPaths {
            var current=URL(fileURLWithPath:old); var data=pinBookmarks[old]
            if let saved=data {
                var stale=false
                if let resolved=try? URL(resolvingBookmarkData:saved,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale),FileManager.default.fileExists(atPath:resolved.path) {
                    current=resolved
                    if stale || current.path != old { data=makeBookmark(current) ?? saved }
                }
            } else if FileManager.default.fileExists(atPath:old) { data=makeBookmark(current) }
            if !paths.contains(current.path) { paths.append(current.path); bookmarks[current.path]=data }
        }
        pinnedPaths=paths; pinBookmarks=bookmarks; persistPins()
    }
    func replacePin(_ old:String,with url:URL) {
        guard let index=pinnedPaths.firstIndex(of:old) else { return }
        pinnedPaths[index]=url.path; pinBookmarks.removeValue(forKey:old); pinBookmarks[url.path]=makeBookmark(url)
        var seen=Set<String>(); pinnedPaths=pinnedPaths.filter { seen.insert($0).inserted }; persistPins()
    }
    @objc func relocatePin() {
        guard let entry=selected,pinnedPaths.contains(entry.url.path) else { return }
        let panel=NSOpenPanel(); panel.title="重新定位收藏：\(entry.url.lastPathComponent)"; panel.prompt="关联此文件"; panel.canChooseDirectories=true; panel.canChooseFiles=true; panel.allowsMultipleSelection=false
        panel.beginSheetModal(for:window) { [weak self] result in
            guard let self,result == .OK,let url=panel.url else { return }
            self.replacePin(entry.url.path,with:url)
            if self.localCollection == 2 { self.loadLocalCollection(2) } else { self.table.reloadData() }
            self.status.stringValue="收藏已重新定位到 \(url.lastPathComponent)"
        }
    }
    func updateSearchModeUI() {
        searchModePicker.selectItem(at:searchMode.rawValue); search.placeholderString=searchMode.placeholder
        search.toolTip=searchMode == .content ? "搜索 Spotlight 正文及本地 OCR 文字。扫描版 PDF 和图片请先通过 ⌘K 建立本地 OCR 索引。" : "支持文件名缩写、拼音和路径关键词，多个词需同时匹配。"
    }
    @objc func changeSearchMode() {
        searchMode=SearchMode(rawValue:searchModePicker.indexOfSelectedItem) ?? .filename; updateSearchModeUI(); saveState()
        if !search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { timer?.invalidate(); startSearch() }
        else { status.stringValue=searchMode == .content ? "内容搜索 · 输入正文中的关键词 · 使用 Spotlight 索引" : "文件名搜索 · 输入文件名" }
        window.makeFirstResponder(search)
    }
    @objc func changeFilter() {
        defer { saveState() }
        fileFilter=FileFilter(rawValue:filterPicker.indexOfSelectedItem) ?? .all; updateFilterSummary()
        if let mode=localCollection { loadLocalCollection(mode) }
        else if !search.stringValue.isEmpty { startSearch() }
        else if query != nil || showingRecent { loadRecent() }
        else { entries=browseEntries.filter(fileFilter.accepts).filter(acceptsDetails); clearPreview(); refreshList(selectFirst:true); status.stringValue="\(entries.count) 个项目 · \(fileFilter.title)" }
    }
    func typePredicate(_ filter:FileFilter)->NSPredicate? {
        guard filter != .all else { return nil }
        let predicates=filter.metadataTypes.map { NSPredicate(format:"ANY %K == %@",NSMetadataItemContentTypeTreeKey,$0) }
        return predicates.count == 1 ? predicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates:predicates)
    }
    @objc func changeScope(_ sender:NSPopUpButton) { savedScopeOverride=nil;
        defer { saveState() }
        let index=sender.indexOfSelectedItem
        if index >= 7 { return }
        if index < 2 { scopeAll=true; searchRoots=index == 0 ? [NSHomeDirectory()] : [NSHomeDirectory(),"/Applications"]; folder=FileManager.default.homeDirectoryForCurrentUser; if let mode=localCollection { loadLocalCollection(mode) } else if search.stringValue.isEmpty { loadRecent() } else { startSearch() } }
        else if index == 6 { chooseFolder() }
        else { let names=["Desktop","Documents","Downloads","Pictures"]; browse(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(names[index-2])) }
    }
    @objc func changeCollection() {
        switch collectionTabs.selectedSegment { case 1: loadLocalCollection(1); case 2: loadLocalCollection(2); default: loadRecent() }
    }
    func loadLocalCollection(_ mode:Int) {
        defer { saveState() }; resolvePins()
        stopQuery(); showingRecent=false; localCollection=mode; collectionTabs.selectedSegment=mode; search.stringValue=""; titleLabel.stringValue=mode == 1 ? "最近打开" : "固定收藏"; clearPreview()
        let paths=mode == 1 ? openedDates.sorted { $0.value > $1.value }.map(\.key) : pinnedPaths
        let roots=activeSearchRoots.map { URL(fileURLWithPath:$0).resolvingSymlinksInPath().path }
        entries=paths.filter { path in
            let normalized=URL(fileURLWithPath:path).resolvingSymlinksInPath().path
            let inScope=roots.contains { normalized == $0 || normalized.hasPrefix($0.hasSuffix("/") ? $0 : $0+"/") }
            return inScope && (mode == 2 || FileManager.default.fileExists(atPath:path))
        }.map { Entry(URL(fileURLWithPath:$0)) }.filter(fileFilter.accepts).filter(acceptsDetails)
        refreshList(selectFirst:true)
        status.stringValue="\(titleLabel.stringValue) · \(entries.count) 个项目 · 当前范围"
        if entries.isEmpty { emptyLabel.stringValue=mode == 1 ? "还没有打开记录\n从 KongFetch 打开文件后会显示在这里" : "尚无收藏\n选中文件，用 ⌘K 固定到收藏" }
    }
    @objc func pinSelected() {
        guard let entry=selected else { return }
        if let index=pinnedPaths.firstIndex(of:entry.url.path) { pinnedPaths.remove(at:index); pinBookmarks.removeValue(forKey:entry.url.path); status.stringValue="已取消收藏" }
        else { pinnedPaths.insert(entry.url.path,at:0); pinBookmarks[entry.url.path]=makeBookmark(entry.url); status.stringValue=pinBookmarks[entry.url.path] == nil ? "已收藏，但无法建立位置跟踪" : "已固定到收藏，可跟踪同一磁盘内的移动与改名" }
        persistPins()
        if localCollection == 2 { loadLocalCollection(2) } else { let row=table.selectedRow; table.reloadData(); if row >= 0 { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) } }
    }
    @objc func copyPath() {
        guard let url=selected?.url else { return }; writePath(url,to:.general); status.stringValue="已复制完整路径"
    }
    func writePath(_ url:URL,to pasteboard:NSPasteboard) { pasteboard.clearContents(); pasteboard.setString(url.path,forType:.string) }
    @objc func copyFile() {
        guard let url=selected?.url else { return }
        guard FileManager.default.fileExists(atPath:url.path) else { status.stringValue="文件已移动或删除，无法复制"; return }
        status.stringValue=writeFile(url,to:.general) ? "已复制文件，可在访达中粘贴" : "无法复制文件"
    }
    func writeFile(_ url:URL,to pasteboard:NSPasteboard)->Bool { pasteboard.clearContents(); return pasteboard.writeObjects([url as NSURL]) }
    @objc func enterContainer() { guard let url=selected?.url else { return }; browse(url.deletingLastPathComponent()) }
    @objc func openWithApplication() {
        guard let entry=selected else { return }
        guard FileManager.default.fileExists(atPath:entry.url.path) else { status.stringValue="文件已移动或删除"; return }
        let panel=NSOpenPanel(); panel.title="选择打开此文件的应用"; panel.prompt="打开"; panel.allowedContentTypes=[.application]; panel.canChooseDirectories=false; panel.canChooseFiles=true; panel.allowsMultipleSelection=false; panel.directoryURL=URL(fileURLWithPath:"/Applications")
        panel.beginSheetModal(for:window) { [weak self] result in
            guard result == .OK, let appURL=panel.url else { return }
            NSWorkspace.shared.open([entry.url],withApplicationAt:appURL,configuration:NSWorkspace.OpenConfiguration()) { _,error in
                DispatchQueue.main.async { guard let self else { return }; if let error { self.status.stringValue="打开失败：\(error.localizedDescription)" } else { self.recordOpen(entry.url); self.status.stringValue="已用 \(appURL.deletingPathExtension().lastPathComponent) 打开" } }
            }
        }
    }
    @objc func openActions() {
        let menu=NSMenu(); let hasSelection=selected != nil
        for (title,action) in [("重命名…",#selector(renameSelected)),("移动到文件夹…",#selector(moveSelected)),("移到废纸篓…",#selector(trashSelected)),("添加访达标签…",#selector(editFileTags))] { let item=NSMenuItem(title:title,action:action,keyEquivalent:""); item.target=self; item.isEnabled=hasSelection; menu.addItem(item) }
        let undo=NSMenuItem(title:fileUndos.last?.title ?? "撤销文件操作",action:#selector(undoFileOperation),keyEquivalent:""); undo.target=self; undo.isEnabled = !fileUndos.isEmpty; menu.addItem(undo)
        for (title,action) in [("按访达标签筛选…",#selector(chooseTagFilter)),("建立本地 OCR 索引…",#selector(chooseOCRFolder)),("取消 OCR",#selector(cancelOCR)),("清除本地 OCR 缓存",#selector(clearOCRCache)),("后台索引与资源…",#selector(resourceStatus))] { let item=NSMenuItem(title:title,action:action,keyEquivalent:""); item.target=self; menu.addItem(item) }
        menu.addItem(.separator())
        for (title,action) in [("这就是我要的",#selector(acceptResult)),("结果不相关（排到后面）",#selector(rejectResult)),("清除此搜索的结果反馈",#selector(clearResultFeedback)),("相近文件名建议…",#selector(showSuggestions)),("常用目录快捷键…",#selector(manageDirectoryShortcuts)),("唤起诊断…",#selector(wakeDiagnostics))] { let item=NSMenuItem(title:title,action:action,keyEquivalent:""); item.target=self; menu.addItem(item) }
        menu.addItem(.separator())
        let pinTitle=selected.map { pinnedPaths.contains($0.url.path) } == true ? "取消固定收藏" : "固定到收藏"
        for (label,action) in [(pinTitle,#selector(pinSelected)),("复制完整路径",#selector(copyPath)),("复制文件",#selector(copyFile)),("用指定应用打开…",#selector(openWithApplication)),("进入所在文件夹",#selector(enterContainer)),("在访达中显示  ⌘↵",#selector(revealSelectedFiles)),("快速预览  空格",#selector(showQuickLook))] {
            let item=NSMenuItem(title:label,action:action,keyEquivalent:""); item.target=self; item.isEnabled=hasSelection; menu.addItem(item)
        }
        if selectedURLs.count > 1 {
            for (label,action) in [("复制所选文件",#selector(copySelectedFiles)),("复制所选路径",#selector(copySelectedPaths)),("在访达中显示所选文件",#selector(revealSelectedFiles))] { let item=NSMenuItem(title:label,action:action,keyEquivalent:""); item.target=self; menu.addItem(item) }
        }
        let relocate=NSMenuItem(title:"重新定位收藏…",action:#selector(relocatePin),keyEquivalent:""); relocate.target=self; relocate.isEnabled=selected.map { pinnedPaths.contains($0.url.path) } == true; menu.addItem(relocate)
        menu.addItem(.separator()); menu.autoenablesItems=false
        let alias=NSMenuItem(title:"给此文件添加搜索别名…",action:#selector(addSelectedAlias),keyEquivalent:""); alias.target=self; alias.isEnabled=hasSelection; menu.addItem(alias)
        let prefer=NSMenuItem(title:"设为当前搜索的首选",action:#selector(preferSelectedSearchResult),keyEquivalent:""); prefer.target=self; prefer.isEnabled=searchChoiceKey != nil && hasSelection; prefer.state=selected?.url.path == manualSearchPath && manualSearchPath != nil ? .on : .off; menu.addItem(prefer)
        let forget=NSMenuItem(title:"忘记当前搜索偏好",action:#selector(forgetCurrentSearchPreference),keyEquivalent:""); forget.target=self; forget.isEnabled=rememberedSearchPath != nil; menu.addItem(forget)
        menu.addItem(.separator())
        let sorting=NSMenuItem(title:"排序："+sortTitles[sortMode],action:nil,keyEquivalent:""); let sortMenu=NSMenu(); for (index,title) in sortTitles.enumerated() { let item=NSMenuItem(title:title,action:#selector(changeSort(_:)),keyEquivalent:""); item.target=self; item.tag=index; item.state=index == sortMode ? .on : .off; sortMenu.addItem(item) }; sorting.submenu=sortMenu; menu.addItem(sorting)
        for (label,action,key) in [("最近搜索",#selector(showRecentSearches),"h"),("管理搜索偏好…",#selector(manageSearchPreferences),""),("路径导航…",#selector(showPathNavigation),"")] { let item=NSMenuItem(title:label,action:action,keyEquivalent:key); item.target=self; menu.addItem(item) }
        let options=NSMenuItem(title:"搜索设置",action:nil,keyEquivalent:""); let optionsMenu=NSMenu(); for (label,action) in [("管理搜索别名…",#selector(manageAliases)),("排除搜索目录…",#selector(manageExcludedDirectories)),("备份设置…",#selector(exportSettings)),("恢复设置…",#selector(importSettings))] { let item=NSMenuItem(title:label,action:action,keyEquivalent:""); item.target=self; optionsMenu.addItem(item) }; options.submenu=optionsMenu; menu.addItem(options)
        let save=NSMenuItem(title:"保存当前搜索…",action:#selector(saveCurrentSearch),keyEquivalent:""); save.target=self; menu.addItem(save)
        let savedMenu=NSMenu(title:"常用搜索"); savedMenu.autoenablesItems=false
        for saved in savedSearches { let item=NSMenuItem(title:saved["name"] as? String ?? "搜索",action:#selector(chooseSavedSearch(_:)),keyEquivalent:""); item.target=self; item.representedObject=saved; savedMenu.addItem(item) }
        let savedParent=NSMenuItem(title:"常用搜索",action:nil,keyEquivalent:""); savedParent.submenu=savedMenu; savedParent.isEnabled = !savedSearches.isEmpty; menu.addItem(savedParent)
        let remove=NSMenuItem(title:"移除常用搜索…",action:#selector(deleteSavedSearch),keyEquivalent:""); remove.target=self; remove.isEnabled = !savedSearches.isEmpty; menu.addItem(remove)
        for (label,action) in [("上一级文件夹",#selector(goUp)),("选择文件夹…",#selector(chooseFolder)),("最近修改",#selector(loadRecent)),("设置…",#selector(openSettings))] { let item=NSMenuItem(title:label,action:action,keyEquivalent:""); item.target=self; menu.addItem(item) }
        presentMenu(menu,view:actionsButton)
    }
    @objc func showQuickLook() { quickLook() }
    @objc func loadRecent() {
        defer { saveState() }
        stopQuery(); localCollection=nil; collectionTabs.selectedSegment=0; showingRecent=true; search.stringValue=""; titleLabel.stringValue="最近修改"; clearPreview(); entries=[]; refreshList(); status.stringValue="正在读取最近文件…"
        let q=NSMetadataQuery(); q.searchScopes=activeSearchRoots
        var predicates=[NSPredicate(format:"%K >= %@",NSMetadataItemFSContentChangeDateKey,Date(timeIntervalSinceNow:-60*24*3600) as NSDate)]
        if fileFilter != .folders { predicates.append(NSPredicate(format:"ANY %K == 'public.data'",NSMetadataItemContentTypeTreeKey)) }
        if let p=typePredicate(fileFilter) { predicates.append(p) }; predicates += detailPredicates()
        q.predicate=NSCompoundPredicate(andPredicateWithSubpredicates:predicates)
        q.sortDescriptors=[NSSortDescriptor(key:NSMetadataItemFSContentChangeDateKey,ascending:false)]; query=q
        if !q.start() { status.stringValue="无法读取 Spotlight 索引"; emptyLabel.stringValue="无法读取最近文件，可直接输入文件名搜索" }
    }
    func refreshList(selectFirst:Bool=false) {
        if !scopeAll { if scopePicker.numberOfItems > 7 { scopePicker.removeItem(at:7) }; scopePicker.addItem(withTitle:"当前目录："+folder.lastPathComponent); scopePicker.selectItem(at:7) }
        entries=sortFiles(entries,mode:sortMode); recentSearchButton.isHidden = !search.stringValue.isEmpty; updateNavigation(); suggestionButton.isHidden = !entries.isEmpty || showingRecent || searchMode != .filename || scanningNames; scopePicker.toolTip="搜索范围："+activeSearchRoots.joined(separator:"\n"); titleLabel.toolTip=titleLabel.stringValue
        let showEvidence = !evidenceWords.isEmpty; evidenceHeight.constant=showEvidence ? 38 : 0; matchesHeight.constant=showEvidence ? 26 : 0; evidenceLabel.isHidden = !showEvidence; matchesBar.isHidden = !showEvidence
        table.rowHeight=showEvidence ? 60 : 48; table.reloadData(); emptyLabel.isHidden = !entries.isEmpty; widenButton.isHidden = !entries.isEmpty || showingRecent || localCollection != nil || search.stringValue.isEmpty || isFullSearchScope; emptyClearButton.isHidden = !entries.isEmpty || showingRecent || localCollection != nil || search.stringValue.isEmpty || !hasSearchRestrictions
        if entries.isEmpty { emptyLabel.stringValue = showingRecent ? "暂无最近文件\n可输入文件名搜索，或选择文件夹" : emptySearchExplanation() }
        if selectFirst && !entries.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification)) }
    }
    func buildStatusItem() {
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuItem.button?.image = kongFetchMenuIcon()
        menuItem.button?.toolTip = "KongFetch · 查找文件"
        let m = NSMenu(); m.addItem(withTitle: "打开 KongFetch", action: #selector(show), keyEquivalent: ""); m.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ""); m.addItem(.separator()); m.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""); menuItem.menu = m
    }
    @objc func show() {
        if localCollection == 2 { loadLocalCollection(2) }; if window.isMiniaturized { window.deminiaturize(nil) }
        window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]; window.makeKeyAndOrderFront(nil)
        if #available(macOS 14,*) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps:true) }; window.makeFirstResponder(search)
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { show(); return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { recentSearchTimer?.invalidate(); saveState(); sender.orderOut(nil); return false }
    @objc func about() { let a = NSAlert(); a.messageText = "KongFetch 3.0"; a.informativeText = "查找 · 预览 · 快捷唤起\n原生 macOS 文件工具\n\n默认快捷键：⌘⌥空格\n首次打开后请在设置中确认快捷键可用。"; a.runModal() }
    @objc func place(_ sender: NSButton) { scopeAll = sender.tag == 0; if scopeAll { stopQuery(); entries=[]; table.reloadData(); titleLabel.stringValue="全局搜索"; path.stringValue="Spotlight · 当前用户文件及应用程序"; status.stringValue="输入文件名开始搜索"; clearPreview(); window.makeFirstResponder(search); if !search.stringValue.isEmpty { startSearch() } } else { browse(URL(fileURLWithPath: sender.identifier!.rawValue)) } }
    func stopQuery() { catalogToken=UUID(); catalogQueue.cancelAllOperations(); scanningNames=false; localMatches=[]; spotlightMatches=[]; catalogLimited=false; catalogUnreadable=0; cancelButton.isHidden=true; query?.stop(); query = nil; timer?.invalidate(); generation += 1; resetEvidence() }
    func browse(_ url: URL, push: Bool = true) { savedScopeOverride=nil;
        defer { saveState() }
        stopQuery(); localCollection=nil; collectionTabs.selectedSegment = -1; showingRecent=false; scopeAll = false; if push && url != folder { history.append(folder) }; folder = url; if scopePicker.numberOfItems > 7 { scopePicker.removeItem(at:7) }; scopePicker.addItem(withTitle:"文件夹："+url.lastPathComponent); scopePicker.selectItem(at:7); search.stringValue = ""; titleLabel.stringValue = url.lastPathComponent; path.stringValue = url.path; clearPreview()
        do { entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey,.fileSizeKey,.contentModificationDateKey], options: [.skipsHiddenFiles]).map(Entry.init).sorted { $0.directory != $1.directory ? $0.directory : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }; status.stringValue = "\(entries.count) 个项目 · 双击打开 · 空格快速预览" }
        catch { entries=[]; status.stringValue="无法读取此文件夹"; let a=NSAlert(); a.messageText="无法访问文件夹"; a.informativeText="\(error.localizedDescription)\n请在系统设置 → 隐私与安全性中检查文件访问权限，或选择其他文件夹。"; a.beginSheetModal(for: window) }
        browseEntries=entries; entries=browseEntries.filter(fileFilter.accepts).filter(acceptsDetails)
        refreshList(selectFirst:true)
    }
    @objc func chooseFolder() { let p=NSOpenPanel(); p.canChooseFiles=false; p.canChooseDirectories=true; p.allowsMultipleSelection=false; p.beginSheetModal(for:window) { [weak self] r in if r == .OK, let u=p.url { self?.browse(u) } } }
    @objc func goBack() { if let u=history.popLast() { browse(u,push:false) } else { scopeAll=true; scopePicker.selectItem(at:searchRoots.count > 1 ? 1 : 0); loadRecent() } }
    @objc func goUp() { browse(folder.deletingLastPathComponent()) }
    func controlTextDidChange(_ obj: Notification) { guard obj.object as? NSSearchField === search else { return }; recentSearchTimer?.invalidate(); stopQuery(); status.stringValue="等待输入完成…"; timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:false) { [weak self] _ in self?.startSearch() } }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
        guard control === search,!menuTracking,window.attachedSheet == nil else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)), !entries.isEmpty {
            let row=table.selectedRow < 0 ? 0 : min(table.selectedRow+1,entries.count-1)
            table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row); window.makeFirstResponder(table); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), selected != nil { openSelected(); return true }
        return false
    }
    func startSearch() {
        stopQuery(); resolveSearchTargets()
        let term=search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let input=SearchInput(term,fallback:fileFilter)
        scheduleRecentSearch(term); updateFilterSummary()
        if term.isEmpty { loadRecent(); return }
        localCollection=nil; collectionTabs.selectedSegment = -1; showingRecent=false; titleLabel.stringValue=searchMode == .content ? "正文匹配" : "搜索结果"
        let q=NSMetadataQuery(); q.searchScopes=activeSearchRoots
        var predicates=input.words.map { word -> NSPredicate in
            if searchMode == .filename,word.count >= 2,normalized(word).unicodeScalars.allSatisfy({ $0.isASCII }),!word.contains("*"),!word.contains("?") {
                return NSPredicate(format:"%K LIKE[cd] %@",NSMetadataItemFSNameKey,"*"+word.map(String.init).joined(separator:"*")+"*")
            }
            return NSPredicate(format:"%K CONTAINS[cd] %@",searchMode.attribute,word)
        }
        if let p=typePredicate(input.filter) { predicates.append(p) }; predicates += detailPredicates()
        q.predicate=predicates.isEmpty ? NSPredicate(value:true) : (predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates:predicates)); q.sortDescriptors=[NSSortDescriptor(key:NSMetadataItemFSNameKey,ascending:true)]; query=q; entries=[]; refreshList(); clearPreview(); cancelButton.isHidden=false; status.stringValue="正在查找…"; emptyLabel.stringValue="正在搜索…"; if !q.start() { cancelButton.isHidden=true; status.stringValue="无法启动 Spotlight 搜索" }; if searchMode == .filename { startNameScan(input) } else { updateOCRMatches() }
    }
    func startNameScan(_ input:SearchInput) {
        resolveSearchTargets()
        let roots=expandedRoots(activeSearchRoots)
        watch(roots); catalogToken=UUID(); let scanToken=catalogToken
        let policy=ResourcePolicy(adaptive:adaptiveResources)
        let cacheKey=roots.map(\.path).joined(separator:"\n"),token=generation,cached=catalogCache[cacheKey],validated=validatedCatalogs.contains(cacheKey),store=catalogStore,saveWasFailed=catalogSaveFailed,exclusions=excludedRoots
        scanningNames=true; catalogSaveFailed=false; cancelButton.isHidden=false
        let operation=BlockOperation()
        operation.addExecutionBlock { [weak self,weak operation] in
            guard let operation,!operation.isCancelled else { return }
            func deliver(_ catalog:CatalogResult,complete:Bool,saveFailed:Bool=false) {
                var matches:[Entry]=[]
                for url in catalog.urls { if operation.isCancelled { return }; if !exclusions.contains(where:{ let path=canonicalIndexPath(url); let root=canonicalIndexPath(URL(fileURLWithPath:$0)); return path == root || path.hasPrefix(root+"/") }) && filenameScore(url,words:input.words) != nil && FileManager.default.fileExists(atPath:url.path) { matches.append(Entry(url)) } }
                DispatchQueue.main.async { guard let self,self.generation == token,self.catalogToken == scanToken else { return }
                    if self.catalogCache.count >= 3 { self.catalogCache.removeAll() }; self.catalogCache[cacheKey]=(Date(),catalog)
                    if complete { self.validatedCatalogs.insert(cacheKey); self.reportIndex(self.catalogSummary(catalog)+(saveFailed ? "\n索引保存失败" : "")) }
                    self.localMatches=matches; self.scanningNames = !complete; self.catalogLimited=catalog.limited; self.catalogUnreadable=catalog.unreadable; self.catalogSaveFailed=saveFailed; self.renderSearchResults()
                }
            }
            if let cached,validated { deliver(cached.1,complete:true,saveFailed:saveWasFailed); return }
            if let saved=cached?.1 ?? store.load(cacheKey,roots:roots) { deliver(saved,complete:false) }
            DispatchQueue.main.async { [weak self] in guard let self,self.catalogToken == scanToken else { return }; self.fullScans += 1 }
            let catalog=scanNames(roots,excluding:[store.directory.path]+exclusions,progress:{ directory,count in
                DispatchQueue.main.async { [weak self] in guard let self,self.catalogToken == scanToken else { return }; self.reportIndex("正在扫描："+directory+"\n已收录 \(count) 项"); self.status.stringValue="正在建立索引 · \(count) 项"; self.status.toolTip=self.indexSummary }
            },throttle:{ policy.pauseIfNeeded(cancelled:{ operation.isCancelled }) },cancelled:{ operation.isCancelled }); if operation.isCancelled { return }
            var failed=false; do { try store.save(catalog,key:cacheKey,roots:roots) } catch { failed=true }
            self?.saveDirectorySnapshots(catalog,roots:roots,store:store)
            deliver(catalog,complete:true,saveFailed:failed)
        }
        catalogQueue.addOperation(operation)
    }
    @objc func cancelSearch() {
        stopQuery(); status.stringValue="已取消搜索 · 保留当前结果"; emptyLabel.stringValue="搜索已取消"; clearPreview()
    }
    @objc func queryProgress(_ n:Notification) {
        guard let q=n.object as? NSMetadataQuery,q === query else { return }
        status.stringValue="正在搜索 · 已发现 \(q.resultCount) 个索引项目"; cancelButton.isHidden=false
    }
    @objc func queryUpdated(_ n: Notification) {
        guard let q=n.object as? NSMetadataQuery, q === query else { return }; cancelButton.isHidden = !q.isGathering && !scanningNames; q.disableUpdates()
        let found=q.results.compactMap { ($0 as? NSMetadataItem)?.value(forAttribute:NSMetadataItemPathKey) as? String }.filter { path in
            if path.split(separator:"/").contains(where: { $0.hasPrefix(".") }) { return false }
            let library=NSHomeDirectory()+"/Library/"
            if showingRecent && scopeAll && path.hasPrefix(library) {
                return path.hasPrefix(library+"Mobile Documents/") || path.hasPrefix(library+"CloudStorage/")
            }
            return true
        }.map { Entry(URL(fileURLWithPath:$0)) }; q.enableUpdates()
        spotlightMatches=found
        renderSearchResults()
    }
    func renderSearchResults() {
        let previous=selected?.url; let previousURLs=selectedURLs; let limit=showingRecent ? 80 : 2000
        var unique:[String:Entry]=[:]; for e in spotlightMatches+localMatches+(searchMode == .content ? ocrMatches : []) { unique[e.url.path]=e }; entries=Array(unique.values)
        let input=SearchInput(search.stringValue,fallback:fileFilter)
        for path in [currentAliasPath,manualSearchPath].compactMap({ $0 }) { let url=URL(fileURLWithPath:path),canonical=canonicalIndexPath(url); if FileManager.default.fileExists(atPath:path) && expandedRoots(activeSearchRoots).contains(where:{ let root=canonicalIndexPath($0); return canonical == root || canonical.hasPrefix(root+"/") }) { unique[path]=Entry(url); entries=Array(unique.values) } }
        entries=entries.filter { !isExcluded($0.url) }
        let effectiveFilter=showingRecent ? fileFilter : input.filter
        let natural=naturalQuery; entries=entries.filter(effectiveFilter.accepts).filter { acceptsDetails($0,natural:natural) }
        if showingRecent { entries.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) } }
        if !showingRecent { entries=rankEntries(entries,words:searchMode == .content ? [] : input.words,counts:openCounts,preferredPath:rememberedSearchPath,manualPath:manualSearchPath,aliasPath:currentAliasPath) }
        if !showingRecent,let key=searchChoiceKey {
            let rejected=Set((preferences.dictionary(forKey:"rejectedResults")?[key] as? [String]) ?? [])
            entries=entries.filter { !rejected.contains($0.url.path) } + entries.filter { rejected.contains($0.url.path) }
        }
        suggestionButton.isHidden = !entries.isEmpty || showingRecent || searchMode != .filename || scanningNames
        let matchedCount=entries.count
        entries=Array(sortFiles(entries,mode:sortMode).prefix(limit))
        refreshList()
        suggestionButton.isHidden = !entries.isEmpty || showingRecent || searchMode != .filename || scanningNames
        if entries.isEmpty && !showingRecent { emptyLabel.stringValue=emptySearchExplanation(); emptyLabel.toolTip=activeSearchRoots.joined(separator:"\n")+"\n"+indexSummary }
        if let previous, let row=entries.firstIndex(where: { $0.url == previous }) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
        else if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
        if !previousURLs.isEmpty { let kept=previousURLs.filter { url in entries.contains { $0.url == url } }; if !kept.isEmpty { selectURLs(kept) } }
        tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification))
        status.stringValue=showingRecent ? "最近修改 · \(entries.count) 个项目" : "\(entries.count) 个结果 · \(searchMode.title)\(matchedCount > limit ? "（已限制显示数量）" : "")\(searchMode == .content ? " · Spotlight／本地 OCR" : " · 模糊匹配")"
        if scanningNames { status.stringValue += " · 正在更新文件索引" }; if catalogLimited { status.stringValue += " · 索引未完成" }; if catalogUnreadable > 0 { status.stringValue += " · 部分目录不可访问" }; if catalogSaveFailed { status.stringValue += " · 索引保存失败，本次仍可搜索" }; status.stringValue = (scopeAll ? "全用户" : "当前目录")+" · "+status.stringValue; status.toolTip="搜索范围："+activeSearchRoots.joined(separator:"\n")+"\n"+status.stringValue; cancelButton.isHidden = !(scanningNames || query?.isGathering == true)
    }
    func numberOfRows(in tableView:NSTableView)->Int { entries.count }
    func tableView(_ tableView:NSTableView, viewFor tableColumn:NSTableColumn?, row:Int)->NSView? {
        let e=entries[row]; let id=tableColumn!.identifier.rawValue
        if id=="name" {
            let v=NSTableCellView(); let icon=NSImageView(); icon.image=NSWorkspace.shared.icon(forFile:e.url.path); icon.translatesAutoresizingMaskIntoConstraints=false
            let l=NSTextField(labelWithString:(pinnedPaths.contains(e.url.path) ? "★ " : "")+e.url.lastPathComponent); l.font = .systemFont(ofSize:14,weight:.medium); l.lineBreakMode = .byTruncatingMiddle; l.toolTip=e.url.lastPathComponent; l.translatesAutoresizingMaskIntoConstraints=false
            let words=searchMode == .filename && !showingRecent && localCollection == nil ? SearchInput(search.stringValue,fallback:fileFilter).words : []
            l.attributedStringValue=highlightedName(l.stringValue,words:words)
            v.addSubview(icon); v.addSubview(l); let hasExcerpt = !evidenceWords.isEmpty
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:v.leadingAnchor,constant:16),icon.centerYAnchor.constraint(equalTo:v.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:26),icon.heightAnchor.constraint(equalToConstant:30),l.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:14),l.trailingAnchor.constraint(equalTo:v.trailingAnchor,constant:-8),l.centerYAnchor.constraint(equalTo:v.centerYAnchor,constant:-9)])
            if hasExcerpt {
                let excerpt=NSTextField(labelWithString:""); excerpt.lineBreakMode = .byTruncatingTail; excerpt.translatesAutoresizingMaskIntoConstraints=false; excerpt.attributedStringValue=highlightExcerpt(snippets[e.url.path] ?? "正在读取摘要…"); v.addSubview(excerpt)
                NSLayoutConstraint.activate([excerpt.leadingAnchor.constraint(equalTo:l.leadingAnchor),excerpt.trailingAnchor.constraint(equalTo:l.trailingAnchor),excerpt.topAnchor.constraint(equalTo:l.bottomAnchor,constant:5)])
                requestSnippet(e)
            } else {
                let reasons=(e.url.path == currentAliasPath ? ["搜索别名"] : (e.url.path == manualSearchPath ? ["搜索首选"] : matchingReasons(e.url,words:words))).joined(separator:"＋"); let parent=compactLocation(e.url,peers:entries.map { $0.url }); let location=NSTextField(labelWithString:(reasons.isEmpty ? "" : reasons+" · ")+parent); location.font = .systemFont(ofSize:11); location.textColor = .secondaryLabelColor; location.lineBreakMode = .byTruncatingMiddle; location.translatesAutoresizingMaskIntoConstraints=false; location.toolTip=(reasons.isEmpty ? "" : "匹配原因："+reasons+"\n")+e.url.path; v.addSubview(location)
                NSLayoutConstraint.activate([location.leadingAnchor.constraint(equalTo:l.leadingAnchor),location.trailingAnchor.constraint(equalTo:l.trailingAnchor),location.topAnchor.constraint(equalTo:l.bottomAnchor,constant:3)])
            }
            return v
        }
        let l=NSTextField(labelWithString:id=="modified" ? e.modified.map(dateFormat.string) ?? "—" : e.directory ? "—" : ByteCountFormatter.string(fromByteCount:e.size,countStyle:.file)); l.font = .systemFont(ofSize:11); l.textColor = .secondaryLabelColor; return l
    }
    var evidenceWords:[String] { searchMode == .content && !showingRecent && localCollection == nil ? SearchInput(search.stringValue,fallback:fileFilter).words : [] }
    func highlightExcerpt(_ text:String)->NSAttributedString {
        let result=NSMutableAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.secondaryLabelColor])
        for range in matchRanges(text,words:evidenceWords,allowWhitespace:true) { result.addAttributes([.backgroundColor:NSColor.systemYellow.withAlphaComponent(0.35),.foregroundColor:NSColor.labelColor],range:range) }
        return result
    }
    func requestSnippet(_ entry:Entry) {
        let key=entry.url.path; guard !evidenceWords.isEmpty,snippets[key] == nil,!snippetRequests.contains(key) else { return }
        if let record=ocrRecords[key],record.isCurrent() { snippets[key]="本地 OCR · "+excerptText(record.text,words:evidenceWords,allowWhitespace:true); return }
        snippetRequests.insert(key); let token=generation; let words=evidenceWords
        let operation=BlockOperation()
        operation.addExecutionBlock { [weak self,weak operation] in
            guard let operation,!operation.isCancelled else { return }
            let result=readEvidence(entry.url,words:words,keepPDF:false,cancelled:{ operation.isCancelled })
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { guard let self,self.generation == token else { return }; self.snippetRequests.remove(key); self.snippets[key]=result.excerpt; self.snippetOrder.removeAll { $0 == key }; self.snippetOrder.append(key)
                while self.snippetOrder.count > 256 { self.snippets.removeValue(forKey:self.snippetOrder.removeFirst()) }
                if let row=self.entries.firstIndex(where: { $0.url == entry.url }) { self.table.reloadData(forRowIndexes:IndexSet(integer:row),columnIndexes:IndexSet(integer:0)) }
            }
        }
        evidenceQueue.addOperation(operation)
    }
    func resetEvidence() {
        evidenceQueue.cancelAllOperations(); previewQueue.cancelAllOperations(); snippetOrder=[]; snippets=[:]; snippetRequests=[]; previewToken=UUID(); pdfMatches=[]; matchIndex=0; pdfView.document=nil; pdfView.isHidden=true; preview?.isHidden=false; evidenceLabel.stringValue=""; matchLabel.stringValue=""; previousMatch.isEnabled=false; nextMatch.isEnabled=false
    }
    func prepareEvidence(_ entry:Entry) {
        previewQueue.cancelAllOperations(); previewToken=UUID(); let token=previewToken; let words=evidenceWords
        pdfMatches=[]; matchIndex=0; pdfView.document=nil; pdfView.isHidden=true; preview.isHidden=false; previousMatch.isEnabled=false; nextMatch.isEnabled=false; matchLabel.stringValue=""; evidenceLabel.stringValue=""
        guard !words.isEmpty else { return }
        if let record=ocrRecords[entry.url.path],record.isCurrent() { evidenceLabel.attributedStringValue=highlightExcerpt("本地 OCR · "+excerptText(record.text,words:words)); evidenceLabel.toolTip=String(record.text.prefix(4000)); matchLabel.stringValue="OCR 文字命中"+(record.limited ? " · 仅部分页面" : ""); return }
        evidenceLabel.stringValue="正在读取命中摘要…"
        let operation=BlockOperation()
        operation.addExecutionBlock { [weak self,weak operation] in
            guard let operation,!operation.isCancelled else { return }
            let result=readEvidence(entry.url,words:words,keepPDF:true,cancelled:{ operation.isCancelled })
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { guard let self,self.previewToken == token,self.selected?.url == entry.url else { return }
                self.evidenceLabel.attributedStringValue=self.highlightExcerpt(result.excerpt); self.evidenceLabel.toolTip=result.excerpt
                if let document=result.document {
                    self.preview.isHidden=true; self.pdfView.isHidden=false; self.pdfView.document=document; self.pdfMatches=result.matches; self.pdfLimited=result.limited
                    for match in result.matches { match.color=NSColor.systemYellow.withAlphaComponent(0.45) }
                    self.pdfView.highlightedSelections=result.matches; self.updateMatch()
                }
            }
        }
        previewQueue.addOperation(operation)
    }
    func updateMatch() {
        let count=pdfMatches.count; previousMatch.isEnabled=count > 1; nextMatch.isEnabled=count > 1
        guard count > 0,let document=pdfView.document else { matchLabel.stringValue="没有可定位的匹配"+(pdfLimited ? " · 仅检查部分正文" : ""); return }
        matchIndex=(matchIndex+count)%count; let selection=pdfMatches[matchIndex]; pdfView.setCurrentSelection(selection,animate:false); pdfView.go(to:selection)
        if let text=selection.pages.first?.string,!evidenceWords.isEmpty { let excerpt=excerptText(text,words:evidenceWords); evidenceLabel.attributedStringValue=highlightExcerpt(excerpt); evidenceLabel.toolTip=excerpt }
        let page=selection.pages.first.map { document.index(for:$0)+1 } ?? 1
        matchLabel.stringValue="\(matchIndex+1) / \(count) · 第 \(page) 页"+(pdfLimited ? " · 部分正文" : "")
    }
    @objc func previousPDFMatch() { matchIndex -= 1; updateMatch() }
    @objc func nextPDFMatch() { matchIndex += 1; updateMatch() }
    var selected: Entry? { table.selectedRow >= 0 && table.selectedRow < entries.count ? entries[table.selectedRow] : nil }
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? { RoundedRow() }
    func clearPreview() { previewQueue.cancelAllOperations(); previewToken=UUID(); pdfMatches=[]; pdfView.document=nil; pdfView.isHidden=true; preview.isHidden=false; evidenceLabel.stringValue=""; matchLabel.stringValue=""; previousMatch.isEnabled=false; nextMatch.isEnabled=false; preview.previewItem=nil; detail.stringValue="选择文件查看预览"; metadataValues.forEach { $0.stringValue="—"; $0.toolTip=nil } }
    func tableViewSelectionDidChange(_ notification:Notification) {
        updateNavigation(); guard let e=selected else { clearPreview(); return }; preview.previewItem=FileManager.default.fileExists(atPath:e.url.path) ? e.url as NSURL : nil; detail.stringValue=e.url.lastPathComponent; if searchMode == .content,let record=ocrRecords[e.url.path],record.isCurrent() { evidenceLabel.stringValue="本地 OCR · "+excerptText(record.text,words:evidenceWords,allowWhitespace:true) }
        let location=(e.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let values=[e.url.lastPathComponent,location,FileManager.default.fileExists(atPath:e.url.path) ? e.kind : "文件已移动或删除",e.directory ? "—" : ByteCountFormatter.string(fromByteCount:e.size,countStyle:.file),e.created.map(dateFormat.string) ?? "—",e.modified.map(dateFormat.string) ?? "—"]
        for (label,value) in zip(metadataValues,values) { label.stringValue=value; label.toolTip=value }
        prepareEvidence(e)
    }
    @objc func openSelected() {
        guard let e=selected else { return }
        guard FileManager.default.fileExists(atPath:e.url.path) else { status.stringValue="文件已移动或删除，可从收藏中移除"; return }
        if e.directory { recordOpen(e.url); browse(e.url) }
        else if NSWorkspace.shared.open(e.url) { recordOpen(e.url) }
        else { status.stringValue="无法打开此文件，请检查文件是否仍然存在" }
    }
    var searchChoiceKey:String? {
        guard !showingRecent,localCollection == nil else { return nil }
        let words=SearchInput(search.stringValue,fallback:fileFilter).words.map(normalized)
        guard !words.isEmpty else { return nil }
        return "\(searchMode.rawValue):"+words.joined(separator:"\u{001F}")
    }
    var rememberedSearchPath:String? {
        guard let key=searchChoiceKey else { return nil }
        return (preferences.dictionary(forKey:"searchChoices")?[key] as? [String:Any])?["path"] as? String
    }
    var manualSearchPath:String? {
        guard let key=searchChoiceKey,let item=preferences.dictionary(forKey:"searchChoices")?[key] as? [String:Any],item["manual"] as? Bool == true else { return nil }
        return item["path"] as? String
    }
    func rememberSearchChoice(_ url:URL,manual:Bool) {
        guard let key=searchChoiceKey else { return }
        var choices=preferences.dictionary(forKey:"searchChoices") as? [String:[String:Any]] ?? [:]
        if !manual && choices[key]?["manual"] as? Bool == true { return }
        choices[key]=["path":url.path,"time":Date().timeIntervalSince1970,"manual":manual]; choices[key]?["bookmark"]=makeBookmark(url)
        if choices.count > 300 { choices=Dictionary(uniqueKeysWithValues:choices.sorted { ($0.value["time"] as? Double ?? 0) > ($1.value["time"] as? Double ?? 0) }.prefix(300).map { ($0.key,$0.value) }) }
        preferences.set(choices,forKey:"searchChoices")
    }
    @objc func preferSelectedSearchResult() {
        guard searchChoiceKey != nil,let url=selected?.url else { return }
        guard FileManager.default.fileExists(atPath:url.path) else { status.stringValue="文件已移动或删除，无法设为首选"; return }
        rememberSearchChoice(url,manual:true); renderSearchResults(); status.stringValue="已设为此搜索的首选 · "+url.lastPathComponent
    }
    func removeCurrentSearchPreference() {
        guard let key=searchChoiceKey else { return }
        var choices=preferences.dictionary(forKey:"searchChoices") ?? [:]; choices.removeValue(forKey:key); preferences.set(choices,forKey:"searchChoices")
    }
    @objc func forgetCurrentSearchPreference() {
        guard rememberedSearchPath != nil else { return }
        removeCurrentSearchPreference(); renderSearchResults(); status.stringValue="已忘记此搜索偏好 · 下次打开结果会重新学习"
    }
    func recordOpen(_ url:URL) {
        suppressedHistoryTerm=nil; rememberRecentSearch(search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines))
        rememberSearchChoice(url,manual:false)
        openCounts[url.path,default:0] += 1
        if openCounts.count > 1000 { openCounts=Dictionary(uniqueKeysWithValues:openCounts.sorted { $0.value > $1.value }.prefix(1000).map { ($0.key,$0.value) }) }
        preferences.set(openCounts,forKey:"openCounts")
        openedDates[url.path]=Date().timeIntervalSince1970
        if openedDates.count > 300 { openedDates=Dictionary(uniqueKeysWithValues:openedDates.sorted { $0.value > $1.value }.prefix(300).map { ($0.key,$0.value) }) }
        preferences.set(openedDates,forKey:"openedDates")
    }
    @objc func reveal() { guard let e=selected else { return }; NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
    func quickLook() { guard let e=selected else { return }; let p=NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false); p.title=e.url.lastPathComponent; let v=QLPreviewView(frame:p.contentView!.bounds,style:.normal)!; v.autoresizingMask=[.width,.height]; v.previewItem=e.url as NSURL; p.contentView!.addSubview(v); p.isReleasedWhenClosed=false; previewPanels.removeAll { !$0.isVisible }; previewPanels.append(p); p.center(); p.makeKeyAndOrderFront(nil) }
    func register(code:UInt32, modifiers:UInt32)->Bool {
        if let current=registeredShortcut, current.0 == code && current.1 == modifiers, hotKey != nil { return true }
        var candidate:EventHotKeyRef?; let result=RegisterEventHotKey(code,modifiers,EventHotKeyID(signature:0x4B464554,id:1),GetApplicationEventTarget(),0,&candidate)
        if result != noErr { return false }; if let old=hotKey { UnregisterEventHotKey(old) }; hotKey=candidate; registeredShortcut=(code,modifiers); return true
    }
    func nextCheck() {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("kongfetch29-"+UUID().uuidString)
        try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); previewFixture=root
        qaSuite="com.kongfetch.next."+UUID().uuidString; preferences=UserDefaults(suiteName:qaSuite!)!
        let a=root.appendingPathComponent("乐乐"),b=root.appendingPathComponent("乐乐资料")
        try! FileManager.default.createDirectory(at:a,withIntermediateDirectories:true); try! FileManager.default.createDirectory(at:b,withIntermediateDirectories:true)
        scopeAll=false; folder=root; showingRecent=false; searchMode = .filename; fileFilter = .all; dateFilter=0; sizeFilter=0; preferences.set(0,forKey:"sortMode")
        localMatches=[Entry(a),Entry(b)]; spotlightMatches=[]; search.stringValue="乐乐"; renderSearchResults(); precondition(entries.first!.url == a)
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); rejectResult(); precondition(entries.last!.url == a)
        table.selectRowIndexes(IndexSet(integer:entries.count-1),byExtendingSelection:false); acceptResult(); precondition(entries.first!.url.path == a.path)
        clearResultFeedback(); precondition(manualSearchPath == nil)
        catalogCache=[root.path:(Date(),CatalogResult(urls:[a,b]))]; search.stringValue="乐了"; precondition(nearNames() == ["乐乐"])
        let choose=NSMenuItem(); choose.representedObject="乐乐"; useSuggestion(choose); precondition(search.stringValue == "乐乐")
        stopQuery(); catalogCache=[root.path:(Date(),CatalogResult(urls:[a,b]))]; search.stringValue="乐了"; preferences.set([a.path],forKey:"excludedSearchRoots"); precondition(nearNames().isEmpty); preferences.removeObject(forKey:"excludedSearchRoots")
        folder=b; precondition(nearNames().isEmpty); folder=root
        precondition(editDistance("abc","acb") == 2 && editDistance("乐乐","乐了") == 1 && editDistance("", "a") == 1)
        entries=[Entry(a),Entry(b)]; let board=NSPasteboard.withUniqueName(); precondition(board.writeObjects([tableView(table,pasteboardWriterForRow:0)!])); precondition(board.readObjects(forClasses:[NSURL.self])?.count == 1); board.releaseGlobally()
        preferences.set([["path":a.path,"code":80,"mods":Int(cmdKey|optionKey|shiftKey),"label":"测试"]],forKey:"directoryShortcuts"); registerDirectoryShortcuts(); precondition(directoryTargets[100].map { $0.resolvingSymlinksInPath().path } == a.resolvingSymlinksInPath().path && directoryHotKeys.count == 1)
        preferences.set([],forKey:"directoryShortcuts"); registerDirectoryShortcuts(); precondition(directoryHotKeys.isEmpty && directoryTargets.isEmpty)
        let monitor=ControlWakeMonitor(); monitor.enable(); precondition(monitor.recoveryTimer != nil && monitor.localMonitor != nil); monitor.recover(); monitor.disable(); precondition(monitor.recoveryTimer == nil && monitor.localMonitor == nil && monitor.tap == nil)
        precondition(window.contentView is ThemeSurface && window.contentView!.bounds.size == NSSize(width:750,height:474))
        window.appearance=NSAppearance(named:.darkAqua); window.contentView?.needsDisplay=true
        print("PASS 2.9: query-specific positive/negative feedback and reset; Chinese edit-distance suggestions with scope/exclusion guards and explicit selection; file URL drag writer; directory hotkey registration/removal; adaptive theme and fixed window"); fflush(stdout); NSApp.terminate(nil)
    }
    @objc func acceptResult() {
        guard let key=searchChoiceKey,let url=selected?.url else { return }
        var values=preferences.dictionary(forKey:"rejectedResults") as? [String:[String]] ?? [:]
        values[key]?.removeAll { $0 == url.path }; preferences.set(values,forKey:"rejectedResults")
        rememberSearchChoice(url,manual:true); renderSearchResults(); status.stringValue="已记住：此搜索优先显示这个结果"
    }
    @objc func rejectResult() {
        guard let key=searchChoiceKey,let url=selected?.url else { return }
        var values=preferences.dictionary(forKey:"rejectedResults") as? [String:[String]] ?? [:]
        var paths=values[key] ?? []; if !paths.contains(url.path) { paths.append(url.path) }; values[key]=Array(paths.suffix(100))
        if values.count > 300,let old=values.keys.filter({ $0 != key }).sorted().first { values.removeValue(forKey:old) }
        preferences.set(values,forKey:"rejectedResults"); if manualSearchPath == url.path { removeCurrentSearchPreference() }; renderSearchResults(); status.stringValue="已记住：这个结果排到后面，仍可找到"
    }
    @objc func clearResultFeedback() {
        guard let key=searchChoiceKey else { return }; var values=preferences.dictionary(forKey:"rejectedResults") ?? [:]; values.removeValue(forKey:key); preferences.set(values,forKey:"rejectedResults"); removeCurrentSearchPreference(); renderSearchResults()
    }
    func nearNames()->[String] {
        let input=SearchInput(search.stringValue,fallback:fileFilter); let term=input.words.joined(separator:" ")
        guard searchMode == .filename,!term.isEmpty,term.count <= 64 else { return [] }
        let roots=expandedRoots(activeSearchRoots).map(canonicalIndexPath)
        var seen=Set<String>(); var candidates:[(String,Int)]=[]
        let urls=catalogCache.values.flatMap { $0.1.urls }
        for url in urls.prefix(20000) {
            let path=canonicalIndexPath(url)
            guard FileManager.default.fileExists(atPath:url.path),roots.contains(where:{ path == $0 || path.hasPrefix($0+"/") }),!isExcluded(url),input.filter.accepts(Entry(url)),acceptsDetails(Entry(url)) else { continue }
            let name=url.deletingPathExtension().lastPathComponent
            guard seen.insert(name).inserted,name.count <= 64 else { continue }
            let distance=editDistance(term,name)
            if distance > 0 && distance <= (term.count <= 4 ? 1 : 2) { candidates.append((name,distance)) }
        }
        return Array(candidates.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(5).map { $0.0 })
    }
    @objc func showSuggestions() {
        let names=nearNames(); let menu=NSMenu()
        if names.isEmpty { let item=NSMenuItem(title:scanningNames ? "索引更新后再试" : "当前范围没有相近文件名",action:nil,keyEquivalent:""); item.isEnabled=false; menu.addItem(item) }
        for name in names { let item=NSMenuItem(title:"搜索："+name,action:#selector(useSuggestion(_:)),keyEquivalent:""); item.target=self; item.representedObject=name; menu.addItem(item) }
        presentMenu(menu,view:suggestionButton.isHidden ? actionsButton : suggestionButton)
    }
    @objc func useSuggestion(_ sender:NSMenuItem) {
        guard let name=sender.representedObject as? String else { return }; search.stringValue=name; startSearch(); window.makeFirstResponder(search)
    }
    func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int)->NSPasteboardWriting? {
        guard entries.indices.contains(row),FileManager.default.fileExists(atPath:entries[row].url.path) else { return nil }; return entries[row].url as NSURL
    }
    var directoryShortcuts:[[String:Any]] { preferences.array(forKey:"directoryShortcuts") as? [[String:Any]] ?? [] }
    func registerDirectoryShortcuts() {
        for ref in directoryHotKeys { UnregisterEventHotKey(ref) }; directoryHotKeys=[]; directoryTargets=[:]; directoryShortcutErrors=[]
        for (i,item) in directoryShortcuts.prefix(20).enumerated() {
            guard let path=item["path"] as? String,let code=item["code"] as? Int,let mods=item["mods"] as? Int else { continue }
            guard (0...127).contains(code),mods > 0,mods <= Int(cmdKey|optionKey|controlKey|shiftKey) else { continue }; let url=trackedItem(item)["path"] as? String ?? path
            guard FileManager.default.fileExists(atPath:url) else { directoryShortcutErrors.append(path+"：目录不存在"); continue }
            var ref:EventHotKeyRef?; let id=UInt32(100+i)
            if RegisterEventHotKey(UInt32(code),UInt32(mods),EventHotKeyID(signature:0x4B464554,id:id),GetApplicationEventTarget(),0,&ref) == noErr,let ref { directoryHotKeys.append(ref); directoryTargets[id]=URL(fileURLWithPath:url) }
            else { directoryShortcutErrors.append(path+"：快捷键冲突") }
        }
    }
    @objc func manageDirectoryShortcuts() {
        let alert=NSAlert(); alert.messageText="常用目录快捷键"; alert.informativeText="选择添加目录后按组合键。最多 20 个；冲突时不会保存。"
        alert.addButton(withTitle:"添加目录…"); alert.addButton(withTitle:"关闭"); alert.addButton(withTitle:"移除所选")
        let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:390,height:30)); let items=directoryShortcuts
        picker.addItems(withTitles:items.isEmpty ? ["暂无快捷目录"] : items.map { ($0["label"] as? String ?? "")+" · "+URL(fileURLWithPath:$0["path"] as? String ?? "/").lastPathComponent }); alert.accessoryView=picker
        alert.beginSheetModal(for:window) { [weak self] result in guard let self else { return }
            if result == .alertFirstButtonReturn { self.addDirectoryShortcut() }
            else if result.rawValue == 1002,!items.isEmpty { var updated=items; updated.remove(at:picker.indexOfSelectedItem); self.preferences.set(updated,forKey:"directoryShortcuts"); self.registerDirectoryShortcuts() }
        }
    }
    func addDirectoryShortcut() {
        guard directoryShortcuts.count < 20 else { status.stringValue="最多可设置 20 个快捷目录"; return }
        let chooser=NSOpenPanel(); chooser.canChooseFiles=false; chooser.canChooseDirectories=true
        chooser.beginSheetModal(for:window) { [weak self] result in guard let self,result == .OK,let url=chooser.url else { return }
            let alert=NSAlert(); alert.messageText="设置目录快捷键"; alert.informativeText=url.path+"\n点击输入框，按包含 ⌘、⌥ 或 ⌃ 的组合键。"; alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"取消")
            let field=ShortcutField(frame:NSRect(x:0,y:0,width:390,height:32)); field.isEditable=false; var candidate:[String:Any]?
            field.record={ e in
                let flags=e.modifierFlags; var mods:UInt32=0; var label=""
                if flags.contains(.control) { mods |= UInt32(controlKey); label+="⌃" }; if flags.contains(.option) { mods |= UInt32(optionKey); label+="⌥" }; if flags.contains(.command) { mods |= UInt32(cmdKey); label+="⌘" }; if mods == 0 { return }; if flags.contains(.shift) { mods |= UInt32(shiftKey); label+="⇧" }
                label += e.keyCode == 49 ? "空格" : (e.charactersIgnoringModifiers?.uppercased() ?? "键")
                candidate=["path":url.path,"code":Int(e.keyCode),"mods":Int(mods),"label":label]; if let bookmark=self.makeBookmark(url) { candidate?["bookmark"]=bookmark }; field.stringValue=label
            }
            alert.accessoryView=field
            alert.beginSheetModal(for:self.window) { result in
                guard result == .alertFirstButtonReturn,let item=candidate else { return }
                var test:EventHotKeyRef?; let ok=RegisterEventHotKey(UInt32(item["code"] as! Int),UInt32(item["mods"] as! Int),EventHotKeyID(signature:0x4B464554,id:999),GetApplicationEventTarget(),0,&test) == noErr
                if let test { UnregisterEventHotKey(test) }; guard ok else { self.status.stringValue="快捷键已被占用，请重新选择"; return }
                self.preferences.set(self.directoryShortcuts+[item],forKey:"directoryShortcuts"); self.registerDirectoryShortcuts(); self.status.stringValue="目录快捷键已保存"
            }
        }
    }
    @objc func wakeDiagnostics() {
        let alert=NSAlert(); alert.messageText="唤起诊断"
        let date: (Date?) -> String = { $0.map { self.dateFormat.string(from:$0) } ?? "尚未收到" }
        alert.informativeText="输入监控权限："+(CGPreflightListenEventAccess() ? "已允许" : "未允许")+"\n双 Control："+(controlWake.tap.map { CGEvent.tapIsEnabled(tap:$0) ? "正在监听" : "监听已暂停" } ?? "未启动")+"\n最近键盘事件："+date(controlWake.lastEvent)+"\n最近后台键盘事件："+date(controlWake.lastBackgroundEvent)+"\n最近双 Control："+date(controlWake.lastWake)+"（"+(controlWake.lastWakeWasGlobal ? "其他应用前台" : "本应用前台／备用识别")+"）\n"+wakeReport+"\n版本：3.0 · "+Bundle.main.bundleURL.path+"\n组合快捷键："+(hotKey == nil ? "注册失败" : "已注册")+"\n目录快捷键：\(directoryHotKeys.count) 个有效\n"+directoryShortcutErrors.joined(separator:"\n")+"\n\n点击测试后关闭窗口，再连按两次 Control。随后会显示收到事件、窗口可见、输入焦点三项结果。"
        alert.addButton(withTitle:"测试双 Control"); alert.addButton(withTitle:"关闭"); alert.addButton(withTitle:"授权／重新检测")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self else { return }
            if response == .alertFirstButtonReturn {
                guard let tap=self.controlWake.tap,CGEvent.tapIsEnabled(tap:tap) else { self.status.stringValue="监听尚未启用，请先授权并重新检测"; return }
                self.controlWake.detector.reset(); self.wakeTesting=true; self.wakeReceived=nil; self.wakeWindowVisible=false; self.wakeInputFocused=false; self.wakeReport="正在等待其他应用前台的双 Control…"; let token=UUID(); self.wakeCheckToken=token
                self.controlWake.wake={ [weak self] in self?.triggerControlWake() }; self.settings?.orderOut(nil); self.window.orderOut(nil)
                DispatchQueue.main.asyncAfter(deadline:.now()+12) { [weak self] in guard let self,self.wakeTesting,self.wakeCheckToken == token else { return }; self.wakeTesting=false; self.wakeReport="12 秒内未收到双 Control · 请检查输入监控权限及监听状态"; self.show(); self.status.stringValue=self.wakeReport }
            } else if response.rawValue == 1002 { self.authorizeControlWake() }
        }
    }
    func configureControlWake() {
        controlWake.wake={ [weak self] in self?.triggerControlWake() }
        let enabled=preferences.object(forKey:"doubleControlWake") as? Bool ?? true
        controlWakeToggle.state=enabled ? .on : .off
        if enabled { controlWake.enable(); controlWakeStatus.stringValue=controlWake.isListening ? "已启用：快速按下并松开 Control 两次。" : "需要输入监控权限。点击下方按钮授权后重试。" }
        else { controlWake.disable(); controlWakeStatus.stringValue="已关闭，组合快捷键仍可使用。" }
    }
    @objc func toggleControlWake() { preferences.set(controlWakeToggle.state == .on,forKey:"doubleControlWake"); configureControlWake() }
    @objc func authorizeControlWake() {
        if !CGPreflightListenEventAccess() { _=CGRequestListenEventAccess() }
        configureControlWake()
        if !controlWake.isListening { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }
    }
    @objc func openSettings() {
        if let p=settings { configureControlWake(); refreshLoginStatus(); p.makeKeyAndOrderFront(nil); return }
        let p=NSPanel(contentRect:NSRect(x:0,y:0,width:500,height:760),styleMask:[.titled,.closable],backing:.buffered,defer:false); p.title="KongFetch 设置"; p.isReleasedWhenClosed=false; settings=p
        let stack=NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=18; stack.translatesAutoresizingMaskIntoConstraints=false; p.contentView!.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:p.contentView!.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:p.contentView!.trailingAnchor,constant:-28),stack.topAnchor.constraint(equalTo:p.contentView!.topAnchor,constant:25)])
        let h=NSTextField(labelWithString:"随时唤起 KongFetch"); h.font = .systemFont(ofSize:20,weight:.semibold); stack.addArrangedSubview(h)
        let l=NSTextField(wrappingLabelWithString:"点击下方输入框，按下包含 ⌘、⌥ 或 ⌃ 的组合键。\n应用运行时生效，关闭窗口后也可使用。"); l.textColor = .secondaryLabelColor; stack.addArrangedSubview(l)
        let f=ShortcutField(); f.isEditable=false; f.isSelectable=false; f.alignment = .center; f.font = .systemFont(ofSize:20,weight:.medium); f.stringValue=UserDefaults.standard.string(forKey:"shortcutLabel") ?? "⌘⌥空格"; f.widthAnchor.constraint(equalToConstant:280).isActive=true; f.heightAnchor.constraint(equalToConstant:42).isActive=true; shortcutField=f; stack.addArrangedSubview(f)
        let s=NSTextField(wrappingLabelWithString:hotKey == nil ? "当前快捷键被占用，请重新设置。" : "快捷键已启用，修改后自动保存。"); s.font = .systemFont(ofSize:12); shortcutStatus=s; stack.addArrangedSubview(s)
        f.record = { [weak self] e in
            guard let self else { return }; let flags=e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command,.option,.control]).isEmpty else { s.stringValue="请至少包含 ⌘、⌥ 或 ⌃ 中的一个修饰键。"; return }
            var mods:UInt32=0; var label=""; if flags.contains(.control) {mods |= UInt32(controlKey);label+="⌃"}; if flags.contains(.option) {mods |= UInt32(optionKey);label+="⌥"}; if flags.contains(.shift) {mods |= UInt32(shiftKey);label+="⇧"}; if flags.contains(.command) {mods |= UInt32(cmdKey);label+="⌘"}
            label += e.keyCode==49 ? "空格" : (e.charactersIgnoringModifiers?.uppercased() ?? "键 \(e.keyCode)")
            if self.register(code:UInt32(e.keyCode),modifiers:mods) { UserDefaults.standard.set(Int(e.keyCode),forKey:"keyCode"); UserDefaults.standard.set(Int(mods),forKey:"modifiers"); UserDefaults.standard.set(label,forKey:"shortcutLabel"); f.stringValue=label; s.stringValue="已保存。现在可使用 \(label) 唤起 KongFetch。" } else { s.stringValue="这个快捷键已被占用，请选择其他组合。原快捷键保持有效。"; f.stringValue=UserDefaults.standard.string(forKey:"shortcutLabel") ?? "⌘⌥空格" }
        }
        configureControlWake(); controlWakeToggle.target=self; controlWakeToggle.action = #selector(toggleControlWake); stack.addArrangedSubview(controlWakeToggle)
        controlWakeStatus.font = .systemFont(ofSize:12); stack.addArrangedSubview(controlWakeStatus)
        stack.addArrangedSubview(button("授权／重新检测 Control 唤起",#selector(authorizeControlWake)))
        loginToggle.target=self; loginToggle.action = #selector(toggleLogin); stack.addArrangedSubview(loginToggle)
        loginStatus.font = .systemFont(ofSize:12); loginStatus.textColor = .secondaryLabelColor; stack.addArrangedSubview(loginStatus)
        stack.addArrangedSubview(button("管理系统登录项…",#selector(openLoginSettings)))
        stack.addArrangedSubview(button("搜索目录与索引…",#selector(manageDirectories)))
        stack.addArrangedSubview(button("常用目录快捷键…",#selector(manageDirectoryShortcuts)))
        stack.addArrangedSubview(button("唤起诊断…",#selector(wakeDiagnostics)))
        stack.addArrangedSubview(button("OCR、标签与后台资源…",#selector(openActions)))
        refreshLoginStatus(); p.center(); p.makeKeyAndOrderFront(nil)
    }
    @objc func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginToggle.state = .on; loginStatus.stringValue="已启用：登录后自动运行，可直接用快捷键唤起。"
        case .requiresApproval: loginToggle.state = .on; loginStatus.stringValue="等待系统批准，请在系统登录项中允许 KongFetch。"
        case .notFound: loginToggle.state = .off; loginStatus.stringValue="请先将 KongFetch 安装到应用程序，再开启自动启动。"
        case .notRegistered: loginToggle.state = .off; loginStatus.stringValue="尚未启用，登录后需要手动打开 KongFetch。"
        @unknown default: loginToggle.state = .off; loginStatus.stringValue="无法读取登录项状态。"
        }
    }
    @objc func toggleLogin() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") || Bundle.main.bundleURL.path.hasPrefix(NSHomeDirectory()+"/Applications/") else {
            refreshLoginStatus(); loginStatus.stringValue="请先把 KongFetch 拖入应用程序，打开已安装版本后再开启。"; return
        }
        do {
            if loginToggle.state == .on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch { refreshLoginStatus(); loginStatus.stringValue="设置未完成：\(error.localizedDescription)" }
    }
    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
func drawKongFetchMenuSymbol(_ color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let transform=NSAffineTransform()
    transform.translateX(by:-0.2,yBy:-0.56)
    transform.scaleX(by:1.12,yBy:1.25)
    transform.concat()
    color.setStroke()
    let folder = NSBezierPath()
    folder.move(to:NSPoint(x:2,y:5)); folder.line(to:NSPoint(x:2,y:14))
    folder.curve(to:NSPoint(x:3.5,y:15.5),controlPoint1:NSPoint(x:2,y:15),controlPoint2:NSPoint(x:2.5,y:15.5))
    folder.line(to:NSPoint(x:7,y:15.5)); folder.line(to:NSPoint(x:9,y:13.5)); folder.line(to:NSPoint(x:16,y:13.5))
    folder.curve(to:NSPoint(x:17,y:12.5),controlPoint1:NSPoint(x:16.7,y:13.5),controlPoint2:NSPoint(x:17,y:13))
    folder.line(to:NSPoint(x:17,y:11.5))
    folder.move(to:NSPoint(x:2,y:5)); folder.line(to:NSPoint(x:8,y:5))
    folder.lineWidth=1.65; folder.lineCapStyle = .round; folder.lineJoinStyle = .round; folder.stroke()
    let k=NSBezierPath(); k.move(to:NSPoint(x:5,y:7)); k.line(to:NSPoint(x:5,y:12))
    k.move(to:NSPoint(x:8,y:12)); k.line(to:NSPoint(x:5,y:9.5)); k.line(to:NSPoint(x:7.8,y:7))
    k.lineWidth=1.45; k.lineCapStyle = .round; k.lineJoinStyle = .round; k.stroke()
    let lens=NSBezierPath(ovalIn:NSRect(x:10,y:5,width:6,height:6)); lens.lineWidth=1.65; lens.stroke()
    let handle=NSBezierPath(); handle.move(to:NSPoint(x:15.2,y:5.8)); handle.line(to:NSPoint(x:18,y:3))
    handle.lineWidth=1.8; handle.lineCapStyle = .round; handle.stroke()
}
func kongFetchMenuIcon() -> NSImage {
    let icon=NSImage(size:NSSize(width:22,height:22),flipped:false) { _ in drawKongFetchMenuSymbol(.black); return true }
    icon.isTemplate=true; icon.accessibilityDescription="KongFetch"; return icon
}
if CommandLine.arguments.contains("--control-check") {
    var d=ControlDoubleTap()
    precondition(!d.update(control:true,other:false,key:false,time:0))
    precondition(!d.update(control:false,other:false,key:false,time:0.08))
    precondition(!d.update(control:true,other:false,key:false,time:0.2))
    precondition(d.update(control:false,other:false,key:false,time:0.28))
    for other in [false,true] {
        d.reset(); _=d.update(control:true,other:false,key:false,time:1)
        _=d.update(control:true,other:other,key:!other,time:1.03)
        precondition(!d.update(control:false,other:false,key:false,time:1.05))
        _=d.update(control:true,other:false,key:false,time:1.1)
        precondition(!d.update(control:false,other:false,key:false,time:1.2))
    }
    d.reset(); _=d.update(control:true,other:false,key:false,time:2)
    precondition(!d.update(control:false,other:false,key:false,time:2.5))
    _=d.update(control:true,other:false,key:false,time:3)
    precondition(!d.update(control:false,other:false,key:false,time:3.1))
    _=d.update(control:true,other:false,key:false,time:4)
    precondition(!d.update(control:false,other:false,key:false,time:4.1))
    print("PASS double Control, combination cancellation, long hold and slow taps"); exit(0)
}
let application=NSApplication.shared
if CommandLine.arguments.contains("--icon-check") {
    let icon=kongFetchMenuIcon(); precondition(icon.isTemplate && icon.size == NSSize(width:22,height:22))
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:640,pixelsHigh:200,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    NSColor(calibratedWhite:0.96,alpha:1).setFill(); NSRect(x:0,y:0,width:320,height:200).fill()
    NSColor(calibratedWhite:0.12,alpha:1).setFill(); NSRect(x:320,y:0,width:320,height:200).fill()
    for (x,color) in [(CGFloat(60),NSColor.black),(CGFloat(380),NSColor.white)] {
        NSGraphicsContext.saveGraphicsState(); let t=NSAffineTransform(); t.translateX(by:x,yBy:50); t.scale(by:5); t.concat(); drawKongFetchMenuSymbol(color); NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState(); let t2=NSAffineTransform(); t2.translateX(by:x+170,yBy:90); t2.concat(); drawKongFetchMenuSymbol(color); NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments.last!))
    print("PASS menu icon: 22 pt template, light and dark preview"); exit(0)
}
let delegate=App()
application.setActivationPolicy(.regular)
application.delegate=delegate
application.run()

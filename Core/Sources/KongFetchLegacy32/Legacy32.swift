// Verbatim copy of KongFetch 3.2 matching and name-scanning code
// (Sources/main.swift @ 33814f1 and SearchPrecision.score from Features31.swift).
// Only `public` was added. Do not "improve" this file: it is the reference that
// KongFetchCore must match, used by the parity tests and by kfbench.
import Foundation

// Independently implemented; inspired by the published Cling/fzf matching principles.
public let normalizedCache:NSCache<NSString,NSString> = { let c=NSCache<NSString,NSString>(); c.countLimit=50000; return c }()
public func normalized(_ value:String)->String { if let saved=normalizedCache.object(forKey:value as NSString) { return saved as String }; let folded=value.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX")); normalizedCache.setObject(folded as NSString,forKey:value as NSString); return folded }
public final class PinyinValue:NSObject { let forms:[String]; init(_ forms:[String]) { self.forms=forms } }
public let pinyinCache:NSCache<NSString,PinyinValue> = { let c=NSCache<NSString,PinyinValue>(); c.countLimit=20000; return c }()
public final class FilenameScoreValue:NSObject { let score:Int?; init(_ score:Int?) { self.score=score } }
public let filenameScoreCache:NSCache<NSString,FilenameScoreValue> = { let c=NSCache<NSString,FilenameScoreValue>(); c.countLimit=50000; return c }()
public func fuzzyScore(_ text:String,_ word:String)->Int? {
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
public enum PinyinReadings {
    static let mappings:[(String,String,String)] = {
        let readings=["重庆":"chong qing","重阳":"chong yang","重新":"chong xin","重量":"zhong liang","音乐":"yin yue","乐器":"yue qi","乐清":"yue qing","长乐":"chang le","快乐":"kuai le","乐乐":"le le","长沙":"chang sha","长安":"chang an","长大":"zhang da","银行":"yin hang","行长":"hang zhang","行业":"hang ye","朝阳":"chao yang","厦门":"xia men"]
        return readings.map { ($0.key,normalized($0.key.applyingTransform(.toLatin,reverse:false) ?? $0.key),$0.value) }.sorted { $0.0 < $1.0 }
    }()
}
public func pinyinForms(_ name:String)->[String] {
    if let cached=pinyinCache.object(forKey:name as NSString) { return cached.forms }
    guard name.unicodeScalars.contains(where:{ (0x3400...0x9fff).contains($0.value) }) else { return [] }
    var latin=normalized(name.applyingTransform(.toLatin,reverse:false) ?? name)
    // Phrase readings avoid blindly expanding every polyphonic character.
    for (phrase,original,reading) in PinyinReadings.mappings where name.contains(phrase) { latin=latin.replacingOccurrences(of:original,with:reading) }
    let parts=latin.split(whereSeparator:{ !$0.isLetter && !$0.isNumber }); let forms=[parts.joined(),String(parts.compactMap(\.first))]; pinyinCache.setObject(PinyinValue(forms),forKey:name as NSString); return forms
}
public func pinyinScore(_ forms:[String],_ word:String)->Int? {
    let word=normalized(word); guard word.count >= 2,word.unicodeScalars.allSatisfy({ $0.isASCII }),word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
    // Full spelling and initials must be contiguous; sparse phonetic subsequences are noisy.
    return forms.compactMap { form -> Int? in guard form.contains(word) else { return nil }; return form == word ? 600 : (form.hasPrefix(word) ? 550 : 450) }.max()
}
public func filenameScore(_ url:URL,words:[String])->Int? {
    let key=(url.path+"\u{001E}"+words.map(normalized).joined(separator:"\u{001F}")) as NSString
    if let cached=filenameScoreCache.object(forKey:key) { return cached.score }
    let score=computeFilenameScore(url,words:words); filenameScoreCache.setObject(FilenameScoreValue(score),forKey:key); return score
}
public func computeFilenameScore(_ url:URL,words:[String])->Int? {
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

public struct CatalogResult { public var urls:[URL]=[]; public var limited=false; public var unreadable=0; public var inaccessible:[String]=[]; public var updated:Date?; public init() {} }
public func scanNames(_ roots:[URL],maximum:Int=Int.max,excluding:[String]=[],progress:(String,Int)->Void = { _,_ in },throttle:()->Void = {},cancelled:()->Bool)->CatalogResult {
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

public func canonicalIndexPath(_ url:URL)->String {
    let path=url.standardizedFileURL.path
    return ["/tmp","/var"].contains(path) || path.hasPrefix("/tmp/") || path.hasPrefix("/var/") ? "/private"+path : path
}
// 3.1/3.2 `SearchPrecision.score` (Features31.swift), renamed to avoid clashing with the app.
public enum Legacy32Precision: Int, CaseIterable {
    case exactName, fuzzyName, withPath
    public func score(_ url:URL,words:[String])->Int? {
        if words.isEmpty { return 0 }
        if self == .withPath { return filenameScore(url,words:words) }
        let name=url.lastPathComponent,stem=url.deletingPathExtension().lastPathComponent,phrase=normalized(words.joined(separator:" "))
        if normalized(name) == phrase || normalized(stem) == phrase { return 2000*words.count }
        if self == .exactName { return nil }
        var score=0; for word in words { if let s=fuzzyScore(name,word) { score += s+200 } else if let s=pinyinScore(pinyinForms(stem),word) { score += s } else { return nil } }; return score
    }
}

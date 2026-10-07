import Cocoa
import Darwin

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

struct SearchDiagnosisContext {
    var roots:[URL]
    var exclusions:[String]
    var query:AdvancedSearchQuery
    var mode:SearchMode
    var precision:SearchPrecision
    var snapshots:[String:CatalogResult]
    var ocrRecords:[String:OCRRecord]=[:]
    var indexSummary:String=""
    var detailDescription:String=""
    var detailAccepts:(Entry)->Bool={_ in true}
    var localRoots:[URL]?=nil
}
struct SearchDiagnosisReport {
    let text:String
    let repairDirectory:URL?
    let canRepair:Bool
    let indexed:Bool
    let inScope:Bool
    let excluded:Bool
}
func searchDiagnosisPath(_ url:URL)->String {canonicalIndexPath(url.resolvingSymlinksInPath())}
func searchDiagnosisContains(_ root:String,_ path:String)->Bool {path == root || path.hasPrefix(root == "/" ? "/" : root+"/")}
func diagnoseSearch32(_ target:URL?,context:SearchDiagnosisContext)->SearchDiagnosisReport {
    let roots=context.roots.map {($0,searchDiagnosisPath($0))},rootLines=roots.map {"• "+($0.0.path as NSString).abbreviatingWithTildeInPath}
    let localRoots=(context.localRoots ?? context.roots).map {($0,searchDiagnosisPath($0))}
    var lines=["当前搜索",context.mode.title+" · "+context.precision.title,"关键词："+(context.query.highlightWords.isEmpty ? "（仅筛选）" : context.query.highlightWords.joined(separator:"、"))]
    lines += context.query.natural.descriptions+context.query.descriptions
    if !context.detailDescription.isEmpty {lines.append("其他筛选："+context.detailDescription)}
    lines += ["","Spotlight 搜索范围"]+(rootLines.isEmpty ? ["尚未配置可搜索目录"] : rootLines)
    if Set(localRoots.map(\.1)) != Set(roots.map(\.1)) {lines += ["","本地文件名索引目录"]+(localRoots.isEmpty ? ["尚未配置本地索引目录"] : localRoots.map {"• "+($0.0.path as NSString).abbreviatingWithTildeInPath})}
    guard let target else {lines += ["","选择一个未能找到的文件或文件夹，可检查范围、排除规则、权限、索引和当前关键词。","修复只处理所选目标附近的目录。"]+(!context.indexSummary.isEmpty ? ["","索引状态",context.indexSummary] : []);return SearchDiagnosisReport(text:lines.joined(separator:"\n"),repairDirectory:nil,canRepair:false,indexed:false,inScope:false,excluded:false)}
    let path=searchDiagnosisPath(target),containing=localRoots.filter {searchDiagnosisContains($0.1,path)}.sorted {$0.1.count > $1.1.count},inScope=roots.contains {searchDiagnosisContains($0.1,path)},localCoverage = !containing.isEmpty
    let customExcluded=context.exclusions.first {searchDiagnosisContains(searchDiagnosisPath(URL(fileURLWithPath:$0)),path)}
    let relative=containing.first.map {String(path.dropFirst($0.1.count)).split(separator:"/").map(String.init)} ?? []
    let hidden=relative.first {$0.hasPrefix(".")},skipped=relative.first {["node_modules","Library","build","DerivedData"].contains($0)}
    var packageAncestor:String?,symlinkAncestor:String?
    if let nearest=containing.first {
        var ancestor=target.deletingLastPathComponent()
        while searchDiagnosisContains(nearest.1,searchDiagnosisPath(ancestor)),searchDiagnosisPath(ancestor) != nearest.1 {
            let values=try? ancestor.resourceValues(forKeys:[.isPackageKey,.isSymbolicLinkKey])
            if values?.isPackage == true {packageAncestor=ancestor.lastPathComponent}
            if values?.isSymbolicLink == true {symlinkAncestor=ancestor.lastPathComponent}
            let parent=ancestor.deletingLastPathComponent();if parent.path == ancestor.path {break};ancestor=parent
        }
    }
    let excluded=customExcluded != nil || hidden != nil || skipped != nil || packageAncestor != nil || symlinkAncestor != nil
    let indexed=context.snapshots.values.contains {snapshot in snapshot.urls.contains {searchDiagnosisPath($0) == path}}
    var isDirectory:ObjCBool=false;let exists=FileManager.default.fileExists(atPath:target.path,isDirectory:&isDirectory)
    let parent=isDirectory.boolValue ? target : target.deletingLastPathComponent()
    let readable:Bool
    if let handle=opendir(parent.path) {closedir(handle);readable=true} else {readable=false}
    lines += ["","目标",target.path,"","检查结果"]
    lines.append(exists ? "✓ 目标存在" : "• 目标不存在、磁盘未连接，或系统不允许读取其路径")
    lines.append(inScope ? "✓ 位于 Spotlight 搜索范围内" : "• 不在当前搜索范围内；请添加其所在目录，或切换搜索范围")
    if localCoverage {lines.append("✓ 位于本地文件名索引目录中")}
    else if inScope {lines.append("• 不在本地文件名索引目录中；当前结果依赖 Spotlight。可将目标所在文件夹添加为搜索目录以建立本地索引")}
    if let customExcluded {lines.append("• 被排除目录规则覆盖："+(customExcluded as NSString).abbreviatingWithTildeInPath+"；可在“排除搜索目录”中移除此规则")}
    if let hidden {lines.append("• 位于隐藏项目中："+hidden+"；文件名索引默认跳过隐藏项目")}
    if let skipped {lines.append("• 位于默认跳过的目录中："+skipped+"；可将需要搜索的子目录单独添加为搜索目录")}
    if let packageAncestor {lines.append("• 位于程序包内部："+packageAncestor+"；默认不遍历程序包内容")}
    if let symlinkAncestor {lines.append("• 经过符号链接目录："+symlinkAncestor+"；请将实际目录添加为搜索目录")}
    if !excluded {lines.append("✓ 未被目录排除规则覆盖")}
    lines.append(readable ? "✓ 可以列出目标所在目录" : "• 无法列出目标所在目录；请检查磁盘连接及系统的文件访问权限")
    if indexed {lines.append(localCoverage ? "✓ 已收录在本地文件名索引中" : "• 已保存过本地索引记录，当前本地索引范围未覆盖此目标")}
    else if containing.contains(where:{$0.1 == path}) {lines.append("• 目标就是当前搜索范围目录；列表搜索其内部项目，查找目录本身请切换到父目录")}
    else {lines.append("• 尚未在当前本地文件名索引中找到该目标")}
    let entry=Entry(target)
    if !context.query.filter.accepts(entry) {lines.append("• 当前文件类型筛选不包含该目标："+context.query.filter.title)}
    if !context.query.natural.accepts(entry) || !context.detailAccepts(entry) {lines.append("• 目标被当前日期、大小或标签筛选排除")}
    if context.mode == .filename {
        if context.query.filenameScore(target,precision:context.precision) == nil {lines.append("• 当前关键词或高级语法不匹配该名称"+(context.precision == .exactName ? "；可切换为模糊名称搜索" : ""))}
        else {lines.append("✓ 名称符合当前关键词和高级语法")}
    } else if let record=context.ocrRecords.values.first(where:{searchDiagnosisPath(URL(fileURLWithPath:$0.path)) == path}) {
        lines.append(record.isCurrent() ? "✓ 已有当前版本的本地 OCR 文字" : "• 本地 OCR 文字已过期；请在 OCR 管理中重新识别")
        if record.isCurrent(),!context.query.acceptsContent(record.text) {lines.append("• 当前关键词或排除词不匹配本地 OCR 文字")}
    } else {lines.append("• 没有该目标的本地 OCR 文字；正文搜索取决于 Spotlight，扫描图片可先建立 OCR 索引")}
    for (root,rootPath) in containing {
        guard let snapshot=context.snapshots[root.path] ?? context.snapshots[rootPath] else {continue}
        if snapshot.limited {lines.append("• 目录索引尚未完成："+root.lastPathComponent)}
        if snapshot.inaccessible.contains(where:{searchDiagnosisContains(searchDiagnosisPath(URL(fileURLWithPath:$0)),path)}) {lines.append("• 最近一次扫描记录了此路径的访问失败")}
        if let date=snapshot.updated {lines.append("索引核对时间："+DateFormatter.localizedString(from:date,dateStyle:.short,timeStyle:.short))}
        break
    }
    // Scanning the parent includes the missing folder itself. Rebuilding only the
    // missing folder would enumerate its children and keep the folder missing.
    let repairDirectory:URL?
    if let nearest=containing.first {let candidate=target.deletingLastPathComponent();repairDirectory=searchDiagnosisContains(nearest.1,searchDiagnosisPath(candidate)) ? candidate : nearest.0} else {repairDirectory=nil}
    let canRepair=exists && readable && inScope && localCoverage && !excluded && repairDirectory != nil
    if let repairDirectory,canRepair {lines += ["","修复范围",repairDirectory.path,"仅重新核对此目录及其子目录，完成后会刷新当前结果。"]}
    return SearchDiagnosisReport(text:lines.joined(separator:"\n"),repairDirectory:repairDirectory,canRepair:canRepair,indexed:indexed,inScope:inScope,excluded:excluded)
}

final class SearchDiagnosisController:NSObject,NSWindowDelegate {
    let panel=featurePanel("查找不到文件？",size:NSSize(width:680,height:540))
    let targetLabel=NSTextField(labelWithString:"尚未选择目标")
    let text=NSTextView()
    let status=NSTextField(wrappingLabelWithString:"")
    var target:URL?
    let context:()->SearchDiagnosisContext
    let repair:(URL)->Void
    var refreshTimer:Timer?
    lazy var repairButton=featureButton("修复此目录",self,#selector(repairTarget))
    init(target:URL?,context:@escaping()->SearchDiagnosisContext,repair:@escaping(URL)->Void) {
        self.target=target;self.context=context;self.repair=repair;super.init();panel.delegate=self
        targetLabel.lineBreakMode = .byTruncatingMiddle;targetLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let header=featureStack([featureButton("选择文件或文件夹…",self,#selector(choose)),featureButton("重新检查",self,#selector(refresh)),repairButton])
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;scroll.documentView=text
        text.isEditable=false;text.isSelectable=true;text.font = .systemFont(ofSize:13);text.textContainerInset=NSSize(width:10,height:10);text.autoresizingMask=[.width];text.isVerticallyResizable=true;text.isHorizontallyResizable=false;text.textContainer?.widthTracksTextView=true
        let stack=featureStack([header,targetLabel,scroll,status],vertical:true);featureMount(stack,in:panel)
        for view in [header,targetLabel,scroll,status] {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:340).isActive=true;targetLabel.widthAnchor.constraint(lessThanOrEqualToConstant:640).isActive=true
        refresh()
    }
    func show() {panel.makeKeyAndOrderFront(nil);refreshTimer?.invalidate();refreshTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) {[weak self] _ in guard let self,self.panel.isVisible else {return};self.refresh()}}
    func windowWillClose(_ notification:Notification) {refreshTimer?.invalidate();refreshTimer=nil}
    func stop() {refreshTimer?.invalidate();refreshTimer=nil}
    @objc func choose() {let picker=NSOpenPanel();picker.canChooseFiles=true;picker.canChooseDirectories=true;picker.allowsMultipleSelection=false;picker.prompt="检查此目标";picker.beginSheetModal(for:panel) {[weak self] response in guard let self,response == .OK,let url=picker.url else {return};self.target=url;self.status.stringValue="";self.refresh()}}
    @objc func refresh() {let report=diagnoseSearch32(target,context:context());targetLabel.stringValue=target.map {($0.path as NSString).abbreviatingWithTildeInPath} ?? "尚未选择目标";targetLabel.toolTip=target?.path;repairButton.isEnabled=report.canRepair;if text.string != report.text {let scroll=text.enclosingScrollView?.contentView.bounds.origin ?? .zero;text.string=report.text;text.enclosingScrollView?.contentView.scroll(to:scroll);text.enclosingScrollView?.reflectScrolledClipView(text.enclosingScrollView!.contentView)}}
    @objc func repairTarget() {let report=diagnoseSearch32(target,context:context());guard report.canRepair,let directory=report.repairDirectory else {return};repair(directory);status.stringValue="正在核对："+(directory.path as NSString).abbreviatingWithTildeInPath;refresh()}
}

func runSearch32Checks(root:URL)throws {
    let fm=FileManager.default,folder=root.appendingPathComponent("搜索语法");try fm.createDirectory(at:folder,withIntermediateDirectories:true)
    let contract=folder.appendingPathComponent("年度合同 final.pdf"),draft=folder.appendingPathComponent("年度合同 草稿.pdf"),other=folder.appendingPathComponent("年度合同 final.txt"),today=folder.appendingPathComponent("今天记录.txt")
    for url in [contract,draft,other,today] {try Data("fixture".utf8).write(to:url)}
    let advanced=AdvancedSearchQuery("ext:PDF \"年度合同\" -草稿",fallback:.all)
    precondition(advanced.valid && advanced.words.isEmpty && advanced.phrases == ["年度合同"] && advanced.excluded == ["草稿"])
    precondition(advanced.filenameScore(contract,precision:.fuzzyName) != nil && advanced.filenameScore(draft,precision:.fuzzyName) == nil && advanced.filenameScore(other,precision:.fuzzyName) == nil)
    precondition(AdvancedSearchQuery("\"今天\"").natural.days == nil && AdvancedSearchQuery("\"今天\"").filenameScore(today,precision:.fuzzyName) != nil)
    precondition(AdvancedSearchQuery("最近7天的PDF 合同 -草稿").natural.days == 7 && AdvancedSearchQuery("最近7天的PDF 合同 -草稿").filter == .pdf)
    let content=AdvancedSearchQuery("ext:pdf \"annual contract\" -draft")
    precondition(content.acceptsContent("ANNUAL CONTRACT 2026") && !content.acceptsContent("annual contract draft") && !content.acceptsContent("annual other contract"))
    precondition(!AdvancedSearchQuery("合同 -草稿").acceptsContent("合同 草\n稿") && AdvancedSearchQuery("-草稿").filenameScore(contract,precision:.fuzzyName) != nil && AdvancedSearchQuery("-草稿").filenameScore(draft,precision:.fuzzyName) == nil)
    let predicates=advanced.metadataPredicates(mode:.filename,precision:.fuzzyName),predicate=NSCompoundPredicate(andPredicateWithSubpredicates:predicates)
    precondition(predicate.evaluate(with:[NSMetadataItemFSNameKey:contract.lastPathComponent]) && !predicate.evaluate(with:[NSMetadataItemFSNameKey:draft.lastPathComponent]) && !predicate.evaluate(with:[NSMetadataItemFSNameKey:other.lastPathComponent]))
    let contentPredicate=NSCompoundPredicate(andPredicateWithSubpredicates:content.metadataPredicates(mode:.content,precision:.fuzzyName))
    precondition(contentPredicate.evaluate(with:[NSMetadataItemFSNameKey:"a.pdf",NSMetadataItemTextContentKey:"Annual Contract 2026"]) && !contentPredicate.evaluate(with:[NSMetadataItemFSNameKey:"a.pdf",NSMetadataItemTextContentKey:"Annual Contract draft"]))
    precondition(!AdvancedSearchQuery("ext:../pdf").valid && AdvancedSearchQuery("ext:pdf,png -ext:png").filenameScore(contract,precision:.fuzzyName) != nil)
    precondition(AdvancedSearchQuery("\"a*b?\"").metadataPredicates(mode:.filename,precision:.fuzzyName).first!.evaluate(with:[NSMetadataItemFSNameKey:"prefix a*b? suffix"]))
    precondition(AdvancedSearchQuery("\"ext:pdf\"").extensions.isEmpty && AdvancedSearchQuery("ext:\"PDF\"").extensions == ["pdf"])
    precondition(lexSearch32("-\"草稿 版本\" \"annual \\\"contract\\\"\"").tokens.map(\.value) == ["草稿 版本","annual \"contract\""])
    let roundTrip=AdvancedSearchQuery(advanced.textWithoutFilters);precondition(roundTrip.phrases == advanced.phrases && roundTrip.excluded == advanced.excluded && roundTrip.extensions == advanced.extensions)
    precondition(AdvancedSearchQuery("lele").filenameScore(folder.appendingPathComponent("乐乐"),precision:.fuzzyName) != nil)
    var snapshot=scanNames([folder],cancelled:{false}),context=SearchDiagnosisContext(roots:[folder],exclusions:[],query:advanced,mode:.filename,precision:.fuzzyName,snapshots:[folder.path:snapshot])
    let known=diagnoseSearch32(contract,context:context);precondition(known.inScope && known.indexed && known.canRepair && known.repairDirectory.map(searchDiagnosisPath) == searchDiagnosisPath(folder))
    snapshot.urls.removeAll {searchDiagnosisPath($0) == searchDiagnosisPath(contract)};context.snapshots=[folder.path:snapshot];precondition(!diagnoseSearch32(contract,context:context).indexed)
    context.exclusions=[folder.path];let excluded=diagnoseSearch32(contract,context:context);precondition(excluded.excluded && !excluded.canRepair)
    context.exclusions=[];context.roots=[folder.appendingPathComponent("elsewhere")];let outside=diagnoseSearch32(contract,context:context);precondition(!outside.inScope && !outside.canRepair)
    context.roots=[folder];let missingFolder=folder.appendingPathComponent("乐乐");try fm.createDirectory(at:missingFolder,withIntermediateDirectories:true);let folderReport=diagnoseSearch32(missingFolder,context:context);precondition(folderReport.repairDirectory.map(searchDiagnosisPath) == searchDiagnosisPath(folder) && folderReport.canRepair)
    precondition(AdvancedSearchQuery("-ext:pdf").filenameScore(missingFolder,precision:.fuzzyName) != nil && AdvancedSearchQuery("ext:pdf").filenameScore(missingFolder,precision:.fuzzyName) == nil)
    let repaired=scanNames([folderReport.repairDirectory!],cancelled:{false});precondition(repaired.urls.contains {searchDiagnosisPath($0) == searchDiagnosisPath(missingFolder)})
    let spotlightOnly=root.appendingPathComponent("主目录层文件.txt");try Data("fixture".utf8).write(to:spotlightOnly)
    context.roots=[root];context.localRoots=[folder]
    let spotlightReport=diagnoseSearch32(spotlightOnly,context:context)
    precondition(spotlightReport.inScope && !spotlightReport.canRepair && spotlightReport.repairDirectory == nil && spotlightReport.text.contains("不在本地文件名索引目录中") && spotlightReport.text.contains("Spotlight 搜索范围"))
    print("PASS 3.2 advanced search: literal phrases, excluded words, extension unions, natural filters, pinyin, Spotlight/OCR parity and safe predicates")
    print("PASS 3.2 missing-search diagnosis: active scope, exclusions, local index absence and targeted parent-directory repair")
}

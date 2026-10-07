import Cocoa
import CryptoKit

import Vision
import PDFKit
import ImageIO
import IOKit.ps

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

struct ResourcePolicy {
    let adaptive:Bool
    func reasons()->[String] {
        guard adaptive else { return [] }; var reasons:[String]=[]
        if ProcessInfo.processInfo.isLowPowerModeEnabled { reasons.append("低电量模式") }
        if let info=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),let type=IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue(),type as String == kIOPSBatteryPowerValue { reasons.append("电池供电") }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { reasons.append("温度较高") }
        var load:Double=0; if getloadavg(&load,1) == 1,load > Double(ProcessInfo.processInfo.activeProcessorCount)*0.85 { reasons.append("系统繁忙") }
        return reasons
    }
    func pauseIfNeeded(cancelled:()->Bool) {
        if !reasons().isEmpty { for _ in 0..<5 { if cancelled() { return }; Thread.sleep(forTimeInterval:0.04) } }
    }
}

struct OCRRecord:Codable {
    let path:String
    let modified:Date
    let size:Int64
    let text:String
    let pages:Int
    let limited:Bool
    let spans:[OCRSpan]?
    let identity:String?
    init(path:String,modified:Date,size:Int64,text:String,pages:Int,limited:Bool,spans:[OCRSpan]?=nil,identity:String?=nil) { self.path=path;self.modified=modified;self.size=size;self.text=text;self.pages=pages;self.limited=limited;self.spans=spans;self.identity=identity }
    func isCurrent()->Bool {
        let e=Entry(URL(fileURLWithPath:path)); return FileManager.default.fileExists(atPath:path) && e.modified == modified && e.size == size
    }
}
final class OCRStore {
    let directory:URL
    init(_ directory:URL) { self.directory=directory }
    func load()->[String:OCRRecord] {
        var result:[String:OCRRecord]=[:]
        for url in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey])) ?? [] where url.pathExtension == "json" {
            guard ((try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? Int.max) <= 3_000_000,let data=try? Data(contentsOf:url),let record=try? JSONDecoder().decode(OCRRecord.self,from:data) else { continue }; result[record.path]=record
        }
        return result
    }
    func save(_ record:OCRRecord) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let name=SHA256.hash(data:Data(record.path.utf8)).map { String(format:"%02x",$0) }.joined()+".json"
        try JSONEncoder().encode(record).write(to:directory.appendingPathComponent(name),options:.atomic)
    }
    func remove(_ path:String) throws { let name=SHA256.hash(data:Data(path.utf8)).map { String(format:"%02x",$0) }.joined()+".json";let url=directory.appendingPathComponent(name);if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
    func clear() throws {
        for url in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] where url.pathExtension == "json" { try FileManager.default.removeItem(at:url) }
    }
}
func recognizeLocalText(_ url:URL,cancelled:()->Bool,progress:(Int)->Void = { _ in } ) throws -> OCRRecord {
    let entry=Entry(url)
    func failure(_ message:String)->NSError { NSError(domain:"KongFetch.OCR",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    guard !entry.directory,entry.size <= 100_000_000 else { throw failure("文件超过 100 MB 或不是普通文件") }
    let cloud=try? url.resourceValues(forKeys:[.ubiquitousItemDownloadingStatusKey]); if cloud?.ubiquitousItemDownloadingStatus == .notDownloaded { throw failure("文件尚未下载，请先在访达下载") }
    var spans:[OCRSpan]=[],geometryCharacters=0
    func recognize(_ image:CGImage,page:Int)throws->String {
        if cancelled() { throw failure("已取消") }
        let request=VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection=true
        let supported=try request.supportedRecognitionLanguages()
        request.recognitionLanguages=["zh-Hans","zh-Hant","en-US"].filter { supported.contains($0) }
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        if cancelled() { throw failure("已取消") }
        var lines:[String]=[]
        for observation in request.results ?? [] {
            guard let candidate=observation.topCandidates(1).first else { continue };let string=candidate.string;lines.append(string);var glyphs:[OCRGlyph]=[]
            if geometryCharacters < 12000,let regex=try? NSRegularExpression(pattern:"[\\p{Han}]|[^\\p{Han}\\s]+") {
                for hit in regex.matches(in:string,range:NSRange(string.startIndex...,in:string)) {
                    if geometryCharacters >= 12000 { break };guard let range=Range(hit.range,in:string),let observation=try? candidate.boundingBox(for:range) else { continue };let box=observation.boundingBox.intersection(CGRect(x:0,y:0,width:1,height:1));if box.isNull { continue };glyphs.append(OCRGlyph(location:hit.range.location,length:hit.range.length,x:box.minX,y:box.minY,width:box.width,height:box.height));geometryCharacters += hit.range.length
                }
            }
            let box=observation.boundingBox.intersection(CGRect(x:0,y:0,width:1,height:1));if !box.isNull { spans.append(OCRSpan(page:page,text:string,x:box.minX,y:box.minY,width:box.width,height:box.height,glyphs:glyphs)) }
        };return lines.joined(separator:"\n")
    }
    var text="",pages=0,limited=false
    if url.pathExtension.lowercased() == "pdf" {
        guard let document=PDFDocument(url:url),!document.isLocked else { throw failure("PDF 无法打开或需要密码") }
        limited=document.pageCount > 30
        for index in 0..<min(document.pageCount,30) {
            if cancelled() { throw failure("已取消") }
            try autoreleasepool {
                guard let page=document.page(at:index) else { return }
                let existing=page.string?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                let result:String
                if existing.count >= 20 { result=existing
                    let box=page.bounds(for:.mediaBox);if box.width > 0,box.height > 0 { spans.append(OCRSpan(page:index,text:existing,x:0,y:0,width:1,height:1,glyphs:[])) }
                }
                else {
                    let bounds=page.bounds(for:.mediaBox); guard bounds.width > 0,bounds.height > 0 else { return }
                    let scale=min(3,2000/max(bounds.width,bounds.height)); let image=page.thumbnail(of:NSSize(width:bounds.width*scale,height:bounds.height*scale),for:.mediaBox)
                    guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return }; result=try recognize(cg,page:index)
                }
                text += "\n[第 \(index+1) 页]\n"+result; pages += 1; progress(pages)
            }
            if text.count >= 500_000 { limited=true; break }
        }
    } else {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:2000,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { throw failure("不支持的图片格式") }
        text=try recognize(image,page:0); pages=1; progress(1)
    }
    return OCRRecord(path:url.path,modified:entry.modified ?? .distantPast,size:entry.size,text:String(text.prefix(500_000)),pages:pages,limited:limited,spans:spans,identity:fileIdentity(url))
}

struct FileUndo {
    let title:String
    let reverse:() throws -> Void
}
extension App {
    var naturalQuery:NaturalQuery { SearchInput(search.stringValue,fallback:fileFilter).advanced.natural }
    var adaptiveResources:Bool { preferences.object(forKey:"adaptiveResources") as? Bool ?? true }
    func refreshAfterFileOperation() {
        resolveSearchTargets(all:true); registerDirectoryShortcuts(); catalogCache.removeAll(); validatedCatalogs.removeAll(); filenameScoreCache.removeAllObjects()
        if search.stringValue.isEmpty { if !scopeAll { browse(folder,push:false) } else { loadRecent() } } else { startSearch() }
    }
    func moveWithUndo(_ source:URL,_ target:URL) throws {
        guard !FileManager.default.fileExists(atPath:target.path) else { throw NSError(domain:"KongFetch.File",code:1,userInfo:[NSLocalizedDescriptionKey:"目标已存在，不会覆盖"]) }
        try FileManager.default.moveItem(at:source,to:target)
        fileUndos.append(FileUndo(title:"撤销移动／重命名",reverse:{ [weak self] in
            do { guard !FileManager.default.fileExists(atPath:source.path) else { throw NSError(domain:"KongFetch.File",code:2,userInfo:[NSLocalizedDescriptionKey:"原位置已被占用，无法撤销"]) }; try FileManager.default.moveItem(at:target,to:source); self?.refreshAfterFileOperation(); self?.status.stringValue="已撤销文件操作" }
            catch { self?.status.stringValue="撤销失败："+error.localizedDescription; throw error }
        })); if fileUndos.count > 20 { fileUndos.removeFirst() }
    }
    @objc func renameSelected() { guard !fileOperationBusy else { status.stringValue="请等待当前批量操作完成";return };
        guard let url=selected?.url else { return }
        let alert=NSAlert(); alert.messageText="重命名"; alert.informativeText="保留扩展名可避免影响文件打开。操作后可通过 ⌘K 撤销。"; alert.addButton(withTitle:"重命名"); alert.addButton(withTitle:"取消")
        let field=NSTextField(string:url.lastPathComponent); field.frame=NSRect(x:0,y:0,width:360,height:28); alert.accessoryView=field
        alert.beginSheetModal(for:window) { [weak self] response in guard let self,response == .alertFirstButtonReturn else { return }
            let name=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); guard !name.isEmpty,!name.contains("/"),!name.contains(":"),name != ".",name != "..",name != url.lastPathComponent else { self.status.stringValue="名称未更改或无效"; return }
            do { try self.moveWithUndo(url,url.deletingLastPathComponent().appendingPathComponent(name)); self.refreshAfterFileOperation(); self.status.stringValue="已重命名 · 可撤销" } catch { self.status.stringValue="重命名失败："+error.localizedDescription }
        }
    }
    @objc func moveSelected() { guard !fileOperationBusy else { status.stringValue="请等待当前批量操作完成";return };
        let urls=selectedURLs; guard !urls.isEmpty else { return }; let chooser=NSOpenPanel(); chooser.title="移动到文件夹"; chooser.canChooseFiles=false; chooser.canChooseDirectories=true
        chooser.beginSheetModal(for:window) { [weak self] response in guard let self,response == .OK,let directory=chooser.url else { return }
            var count=0
            for url in urls { do { let target=directory.appendingPathComponent(url.lastPathComponent); if target.standardizedFileURL == url.standardizedFileURL { continue }; try self.moveWithUndo(url,target); count += 1 } catch { self.status.stringValue="已移动 \(count) 项；其余失败："+error.localizedDescription; self.refreshAfterFileOperation(); return } }
            self.refreshAfterFileOperation(); self.status.stringValue="已移动 \(count) 项 · 每项可撤销"
        }
    }
    func trashWithUndo(_ url:URL) throws { var result:NSURL?; try FileManager.default.trashItem(at:url,resultingItemURL:&result); if let trashed=result as URL? { fileUndos.append(FileUndo(title:"撤销移到废纸篓",reverse:{ [weak self] in do { guard !FileManager.default.fileExists(atPath:url.path) else { throw NSError(domain:"KongFetch.File",code:2,userInfo:[NSLocalizedDescriptionKey:"原位置已被占用"]) }; try FileManager.default.moveItem(at:trashed,to:url); self?.refreshAfterFileOperation(); self?.status.stringValue="已从废纸篓恢复" } catch { self?.status.stringValue="恢复失败："+error.localizedDescription; throw error } })) }; if fileUndos.count > 20 { fileUndos.removeFirst() } }
    @objc func trashSelected() { guard !fileOperationBusy else { status.stringValue="请等待当前批量操作完成";return };
        let urls=selectedURLs; guard !urls.isEmpty else { return }; let alert=NSAlert(); alert.messageText="将 \(urls.count) 项移到废纸篓？"; alert.informativeText=urls.map(\.lastPathComponent).prefix(5).joined(separator:"\n")+"\n可通过 ⌘K 撤销，或从访达废纸篓恢复。"; alert.addButton(withTitle:"移到废纸篓"); alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self,response == .alertFirstButtonReturn else { return }; var count=0
            for url in urls { do { try self.trashWithUndo(url); count += 1 } catch { self.refreshAfterFileOperation(); self.status.stringValue="已处理 \(count) 项；其余失败："+error.localizedDescription; return } }
            if self.fileUndos.count > 20 { self.fileUndos.removeFirst(self.fileUndos.count-20) }; self.refreshAfterFileOperation(); self.status.stringValue="已移到废纸篓 · 可撤销"
        }
    }
    @objc func undoFileOperation() { guard !fileOperationBusy else { status.stringValue="请等待当前批量操作完成";return }; guard let item=fileUndos.popLast() else { return }; do { try item.reverse() } catch { fileUndos.append(item); status.stringValue="撤销失败，保留撤销记录："+error.localizedDescription } }
    @objc func editFileTags() { guard !fileOperationBusy else { status.stringValue="请等待当前批量操作完成";return };
        let urls=selectedURLs; guard !urls.isEmpty else { return }
        let alert=NSAlert(); alert.messageText="添加访达标签"; alert.informativeText="多个标签用逗号分隔，将添加到原有标签。可输入颜色名称：红色、橙色、黄色、绿色、蓝色、紫色、灰色。"; alert.addButton(withTitle:"添加"); alert.addButton(withTitle:"取消")
        let field=NSTextField(string:""); field.frame=NSRect(x:0,y:0,width:360,height:28); alert.accessoryView=field
        alert.beginSheetModal(for:window) { [weak self] response in guard let self,response == .alertFirstButtonReturn else { return }; let tags=field.stringValue.components(separatedBy:CharacterSet(charactersIn:",，")).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.count <= 64 }; guard !tags.isEmpty else { return }
            var count=0
            for original in urls { let url=original; do { let oldValues=try url.resourceValues(forKeys:[.tagNamesKey,.labelNumberKey]); let old=oldValues.tagNames ?? []; let oldLabel=oldValues.labelNumber ?? 0; try (url as NSURL).setResourceValue(Array(Set(old+tags)).sorted(),forKey:.tagNamesKey); let colors=["灰色":1,"绿色":2,"紫色":3,"蓝色":4,"黄色":5,"红色":6,"橙色":7]; if let number=tags.compactMap({ colors[$0] }).first { try (url as NSURL).setResourceValue(number,forKey:.labelNumberKey) }
                self.fileUndos.append(FileUndo(title:"撤销标签添加",reverse:{ [weak self] in do { try (original as NSURL).setResourceValue(oldLabel,forKey:.labelNumberKey); try (original as NSURL).setResourceValue(old,forKey:.tagNamesKey); self?.refreshAfterFileOperation(); self?.status.stringValue="标签已恢复" } catch { self?.status.stringValue="无法恢复标签："+error.localizedDescription; throw error } })); count += 1
            } catch { self.status.stringValue="已添加 \(count) 项；其余失败："+error.localizedDescription; return } }
            if self.fileUndos.count > 20 { self.fileUndos.removeFirst(self.fileUndos.count-20) }; self.refreshAfterFileOperation(); self.status.stringValue="标签已添加到 \(count) 项 · 可撤销"
        }
    }
    @objc func chooseTagFilter() {
        let alert=NSAlert(); alert.messageText="按访达标签筛选"; alert.informativeText="输入完整标签名称或颜色名称；留空清除筛选。也可搜索“标签:工作 合同”。"; alert.addButton(withTitle:"应用"); alert.addButton(withTitle:"取消")
        let field=NSTextField(string:tagFilter); field.frame=NSRect(x:0,y:0,width:360,height:28); alert.accessoryView=field
        alert.beginSheetModal(for:window) { [weak self] response in guard let self,response == .alertFirstButtonReturn else { return }; self.tagFilter=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); self.preferences.set(self.tagFilter,forKey:"tagFilter"); self.updateFilterSummary(); if self.search.stringValue.isEmpty { self.loadRecent() } else { self.startSearch() } }
    }
    @objc func chooseOCRFolder() {
        let panel=NSOpenPanel(); panel.title="建立本地 OCR 索引"; panel.message="选择包含图片或扫描 PDF 的文件夹。识别文字仅保存在本机，图片和 PDF 原文件不会被修改。"; panel.canChooseFiles=false; panel.canChooseDirectories=true
        panel.beginSheetModal(for:window) { [weak self] response in guard let self,response == .OK,let root=panel.url else { return }; self.startOCRIndex(root) }
    }
    func startOCRIndex(_ root:URL) { ocrManager.add(root) }
    func loadOCRCache() { ocrManager.start() }
    func updateOCRMatches() {
        guard searchMode == .content,!showingRecent else { ocrMatches=[]; return }
        ocrSearchQueue.cancelAllOperations(); let token=generation,records=Array(ocrRecords.values),input=SearchInput(search.stringValue,fallback:fileFilter),exclusions=excludedRoots.map { canonicalIndexPath(URL(fileURLWithPath:$0).resolvingSymlinksInPath()) },roots=expandedRoots(activeSearchRoots).map { canonicalIndexPath($0.resolvingSymlinksInPath()) }
        let operation=BlockOperation(); operation.addExecutionBlock { [weak self,weak operation] in
            guard let operation else { return }; var matches:[Entry]=[]
            for record in records {
                if operation.isCancelled { return }; let url=URL(fileURLWithPath:record.path),path=canonicalIndexPath(url.resolvingSymlinksInPath())
                guard record.isCurrent(),!exclusions.contains(where:{ path == $0 || path.hasPrefix($0+"/") }),roots.contains(where:{ path == $0 || path.hasPrefix($0+"/") }) else { continue }
                if input.advanced.acceptsContent(record.text) && input.advanced.acceptsURL(url,mode:.content,precision:.fuzzyName) { matches.append(Entry(url)) }
            }
            DispatchQueue.main.async { guard let self,!operation.isCancelled,self.generation == token,self.searchMode == .content else { return }; self.ocrMatches=matches; for e in matches { if let record=self.ocrRecords[e.url.path] { self.snippets[e.url.path]="本地 OCR · "+excerptText(record.text,words:input.words,allowWhitespace:true) } }; self.renderSearchResults() }
        }; ocrSearchQueue.addOperation(operation)
    }
    @objc func cancelOCR() { ocrManager.cancel();ocrProgress=ocrManager.summary;status.stringValue=ocrProgress }
    @objc func clearOCRCache() { ocrManager.clear();ocrRecords=[:];ocrMatches=[];status.stringValue="已清除 OCR 文字缓存，原文件保留；目录已暂停自动识别" }
    @objc func resourceStatus() {
        let policy=ResourcePolicy(adaptive:adaptiveResources); var usage=rusage(); getrusage(RUSAGE_SELF,&usage)
        let cpu=Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
        let hasSample=lastResourceTime != 0; let now=ProcessInfo.processInfo.systemUptime; let percent=lastResourceTime == 0 ? 0 : max(0,(cpu-lastResourceCPU)/(now-lastResourceTime)*100); lastResourceTime=now; lastResourceCPU=cpu
        let alert=NSAlert(); alert.messageText="后台索引与资源"; alert.informativeText="运行策略："+(adaptiveResources ? "自动节能" : "标准速度")+"\n减速原因："+(policy.reasons().isEmpty ? "无" : policy.reasons().joined(separator:"、"))+"\n本次 CPU 采样："+(!hasSample ? "首次打开，稍后刷新查看" : String(format:"%.1f%%（单核为100%%）",percent))+"\n峰值内存："+ByteCountFormatter.string(fromByteCount:Int64(usage.ru_maxrss),countStyle:.memory)+"\n名称索引：\n"+indexSummary+"\n名称队列：\(catalogQueue.operationCount) · OCR 队列：\(ocrManager.queue.operationCount)\n"+ocrProgress
        alert.addButton(withTitle:adaptiveResources ? "关闭自动节能" : "启用自动节能"); alert.addButton(withTitle:"关闭"); alert.addButton(withTitle:"刷新")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self else { return }; if response == .alertFirstButtonReturn { self.preferences.set(!self.adaptiveResources,forKey:"adaptiveResources"); self.status.stringValue="索引策略已更新，将在下一次扫描应用" }; if response.rawValue == 1002 { self.resourceStatus() } }
    }
    func triggerControlWake() {
        wakeReceived=Date(); show(); let token=UUID(); wakeCheckToken=token
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak self] in guard let self,self.wakeCheckToken == token else { return }; self.wakeWindowVisible=self.window.isVisible && !self.window.isMiniaturized; self.wakeInputFocused=self.window.isKeyWindow && ((self.window.firstResponder as? NSTextView)?.delegate as? NSSearchField === self.search || self.window.firstResponder === self.search)
            self.wakeReport="收到双 Control：是 · 窗口："+(self.wakeWindowVisible ? "可见" : "未出现")+" · 输入焦点："+(self.wakeInputFocused ? "已获得" : "未获得")
            if self.wakeTesting { if !self.controlWake.lastWakeWasGlobal { self.wakeReport += " · 本应用前台测试，请切换到其他应用验证全局唤起" }; self.status.stringValue=self.wakeReport; self.wakeTesting=false }
        }
    }
}

extension App {
    func release30Check() {
        let fixture=FileManager.default.temporaryDirectory.appendingPathComponent("kongfetch30-"+UUID().uuidString)
        try! FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true); previewFixture=fixture
        qaSuite="com.kongfetch.release30."+UUID().uuidString; preferences=UserDefaults(suiteName:qaSuite!)!; preferences.set(false,forKey:"adaptiveResources")
        catalogStore=CatalogStore(fixture.appendingPathComponent("indexes")); ocrStore=OCRStore(fixture.appendingPathComponent("ocr-cache"))
        scopeAll=false; folder=fixture; fileFilter = .all; dateFilter=0; sizeFilter=0; tagFilter=""; showingRecent=false; localCollection=nil
        let parsed=SearchInput("最近一周的 PDF",fallback:.all); precondition(parsed.words.isEmpty && parsed.filter == .pdf && NaturalQuery("最近一周的 PDF").days == 7)
        let large=SearchInput("大于100MB的视频",fallback:.all); precondition(large.words.isEmpty && large.filter == .video && NaturalQuery("大于100MB的视频").minimum == 100_000_000)
        precondition(SearchInput("昨天的合同的PDF",fallback:.all).words == ["合同"])
        precondition(NaturalQuery("标签:工作 合同").tag == "工作" && SearchInput("标签:工作 合同",fallback:.all).words == ["合同"])
        let original=fixture.appendingPathComponent("合同.txt"),renamed=fixture.appendingPathComponent("年度合同.txt")
        try! "sample".write(to:original,atomically:true,encoding:.utf8); try! moveWithUndo(original,renamed); precondition(FileManager.default.fileExists(atPath:renamed.path)); undoFileOperation(); precondition(FileManager.default.fileExists(atPath:original.path) && !FileManager.default.fileExists(atPath:renamed.path)); stopQuery()
        try! "occupied".write(to:renamed,atomically:true,encoding:.utf8)
        do { try moveWithUndo(original,renamed); fatalError("must reject overwrite") } catch { precondition(FileManager.default.fileExists(atPath:original.path)) }
        try! (original as NSURL).setResourceValue(["工作"],forKey:.tagNamesKey)
        precondition(Entry(original).tags.contains("工作") && NaturalQuery("标签:工作").accepts(Entry(original)))
        precondition(!NaturalQuery("标签:其他").accepts(Entry(original)))
        precondition(!NaturalQuery("大于1MB").accepts(Entry(original)) && NaturalQuery("小于1MB").accepts(Entry(original)))
        let disposable=fixture.appendingPathComponent("undo-trash.txt"); try! "disposable".write(to:disposable,atomically:true,encoding:.utf8)
        try! trashWithUndo(disposable); precondition(!FileManager.default.fileExists(atPath:disposable.path)); undoFileOperation(); precondition(FileManager.default.fileExists(atPath:disposable.path)); stopQuery()
        try! FileManager.default.removeItem(at:renamed); try! moveWithUndo(original,renamed); try! "occupied".write(to:original,atomically:true,encoding:.utf8)
        let undoCount=fileUndos.count; undoFileOperation(); precondition(fileUndos.count == undoCount && FileManager.default.fileExists(atPath:renamed.path)); try! FileManager.default.removeItem(at:original); undoFileOperation(); precondition(FileManager.default.fileExists(atPath:original.path)); stopQuery()
        search.stringValue="最近一周的 PDF"; localMatches=[Entry(original)]; spotlightMatches=[]; searchMode = .filename; showingRecent=false; renderSearchResults(); precondition(entries.isEmpty)
        search.stringValue=""; precondition(ResourcePolicy(adaptive:false).reasons().isEmpty)
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1600,pixelsHigh:500,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor.white.setFill(); NSRect(x:0,y:0,width:1600,height:500).fill()
        ("KongFetch OCR test 2026\n乐乐文件夹 年度合同" as NSString).draw(in:NSRect(x:70,y:80,width:1450,height:330),withAttributes:[.font:NSFont.systemFont(ofSize:72),.foregroundColor:NSColor.black]); NSGraphicsContext.restoreGraphicsState()
        let imageURL=fixture.appendingPathComponent("scan.png"); try! bitmap.representation(using:.png,properties:[:])!.write(to:imageURL)
        let image=NSImage(size:NSSize(width:1600,height:500)); image.addRepresentation(bitmap)
        let pdf=PDFDocument(); pdf.insert(PDFPage(image:image)!,at:0); let pdfURL=fixture.appendingPathComponent("scanned.pdf"); precondition(pdf.write(to:pdfURL))
        let store=ocrStore
        search.stringValue="最近一周的 PDF"; localMatches=[Entry(imageURL),Entry(pdfURL)]; showingRecent=false; renderSearchResults(); precondition(entries.count == 1 && entries[0].url == pdfURL)
        search.stringValue=""; localMatches=[]; precondition(window.frame.size == NSSize(width:750,height:474))
        precondition(excerptText("Kong Fetch OCR",words:["KongFetch"],allowWhitespace:true).contains("Kong Fetch"))
        ocrQueue.addOperation { [weak self] in
            guard let self else { return }
            do {
                let record=try recognizeLocalText(imageURL,cancelled:{ false }); print("Image OCR:",record.text); fflush(stdout); precondition(record.text.replacingOccurrences(of:" ",with:"").contains("KongFetch") && record.text.contains("年度合同")); try store.save(record)
                let scanned=try recognizeLocalText(pdfURL,cancelled:{ false }); print("PDF OCR:",scanned.text); fflush(stdout); precondition(scanned.text.contains("年度合同") && scanned.pages == 1); try store.save(scanned)
                precondition(store.load().count == 2 && record.isCurrent())
                do { _=try recognizeLocalText(imageURL,cancelled:{ true }); fatalError("cancel must stop OCR") } catch {}
                DispatchQueue.main.async {
                    self.ocrRecords=[record.path:record,scanned.path:scanned]; self.searchMode = .content; self.search.stringValue="年度合同"; self.spotlightMatches=[]; self.localMatches=[]; self.updateOCRMatches()
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                        precondition(self.entries.count == 2)
                        self.preferences.set([fixture.path],forKey:"excludedSearchRoots"); self.renderSearchResults(); precondition(self.entries.isEmpty); self.preferences.removeObject(forKey:"excludedSearchRoots")
                        self.show(); self.triggerControlWake()
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
                        precondition(self.wakeReceived != nil && self.wakeWindowVisible && !self.wakeReport.isEmpty)
                        print("PASS 3.0: natural date/size/type/tag parsing; move/rename undo and conflict protection; Finder tags; real Chinese image and scanned PDF OCR, disk cache and cancellation; OCR result/exclusion guards; resource policy; wake event/window/focus stages; fixed window"); fflush(stdout); NSApp.terminate(nil)
                        }
                    }
                }
            } catch { print("OCR check failed",error); fflush(stdout); exit(1) }
        }
    }
}

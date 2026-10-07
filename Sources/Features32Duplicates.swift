import Cocoa
import Quartz
import CryptoKit
import Darwin

// Duplicate discovery reads files only. It never removes or changes the selected files.
struct DuplicateFileSnapshot:Equatable {
    let device:UInt64
    let inode:UInt64
    let size:Int64
    let modifiedSeconds:Int64
    let modifiedNanoseconds:Int64
    let changedSeconds:Int64
    let changedNanoseconds:Int64
    init(_ value:stat) {
        device=UInt64(bitPattern:Int64(value.st_dev));inode=UInt64(value.st_ino);size=Int64(value.st_size)
        modifiedSeconds=Int64(value.st_mtimespec.tv_sec);modifiedNanoseconds=Int64(value.st_mtimespec.tv_nsec)
        changedSeconds=Int64(value.st_ctimespec.tv_sec);changedNanoseconds=Int64(value.st_ctimespec.tv_nsec)
    }
    var identity:String { "\(device):\(inode)" }
    var cacheKey:String { "\(identity):\(size):\(modifiedSeconds):\(modifiedNanoseconds):\(changedSeconds):\(changedNanoseconds)" }
}
struct DuplicateFile {
    let url:URL
    let snapshot:DuplicateFileSnapshot
    var size:Int64 { snapshot.size }
    func isCurrent()->Bool { (try? DuplicateFinder.snapshot(url)) == snapshot }
}
struct DuplicateGroup {
    let digest:String
    let files:[DuplicateFile]
    var size:Int64 { files.first?.size ?? 0 }
    var uniqueFileCount:Int { Set(files.map { $0.snapshot.identity }).count }
    // Hard links share one physical file and contribute no additional savings.
    var additionalBytes:Int64 { Int64(max(0,uniqueFileCount-1))*size }
}
struct DuplicateScanProgress {
    let phase:String
    let visited:Int
    let files:Int
    let hashed:Int
    let bytes:Int64
}
struct DuplicateScanResult {
    var groups:[DuplicateGroup]=[]
    var fileCount=0
    var hashedCount=0
    var hashedBytes:Int64=0
    var skippedCloud=0
    var skippedLinks=0
    var skippedHidden=0
    var excludedCount=0
    var errorCount=0
    var errors:[String]=[]
    var limited=false
    var cancelled=false
    var visitedCount=0
    var additionalBytes:Int64 { groups.reduce(0) { $0+$1.additionalBytes } }
}
struct DuplicateScanLimits {
    var maximumFiles=100_000
    var maximumVisited=200_000
    var maximumHashedBytes:Int64=512*1024*1024*1024
}
enum DuplicateScanFailure:Error { case cancelled,changed }

enum DuplicateFinder {
    static func snapshot(_ url:URL)throws->DuplicateFileSnapshot {
        var value=stat()
        guard lstat(url.path,&value) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        guard value.st_mode & S_IFMT == S_IFREG else { throw featureError("不是普通文件，已跳过") }
        return DuplicateFileSnapshot(value)
    }
    static func digest(_ file:DuplicateFile,cancelled:()->Bool,throttle:()->Void,read:((Int)->Void)?=nil)throws->String {
        if cancelled() { throw DuplicateScanFailure.cancelled }
        let descriptor=open(file.url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer { try? handle.close() }
        var before=stat()
        guard fstat(descriptor,&before) == 0,before.st_mode & S_IFMT == S_IFREG,DuplicateFileSnapshot(before) == file.snapshot else { throw DuplicateScanFailure.changed }
        var hasher=SHA256(),bytes:Int64=0,chunks=0
        while true {
            if cancelled() { throw DuplicateScanFailure.cancelled }
            let data=try handle.read(upToCount:1024*1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data:data);bytes += Int64(data.count);read?(data.count);chunks += 1
            if chunks % 16 == 0 { throttle() }
            if bytes > file.size { throw DuplicateScanFailure.changed }
        }
        var after=stat()
        guard !cancelled() else { throw DuplicateScanFailure.cancelled }
        guard fstat(descriptor,&after) == 0,DuplicateFileSnapshot(after) == file.snapshot,bytes == file.size,file.isCurrent() else { throw DuplicateScanFailure.changed }
        return hasher.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func scan(_ root:URL,excluding:[String]=[],limits:DuplicateScanLimits=DuplicateScanLimits(),adaptive:Bool=true,cancelled:()->Bool,progress:(DuplicateScanProgress)->Void={_ in})->DuplicateScanResult {
        var result=DuplicateScanResult(),buckets:[Int64:[DuplicateFile]]=[:],seenPaths=Set<String>()
        let selectedRoot=root,policy=ResourcePolicy(adaptive:adaptive),root=physicalURL(root)
        let excluded=excluding.map { physicalURL(URL(fileURLWithPath:$0)).path }
        func recordError(_ url:URL,_ message:String) { result.errorCount += 1;if result.errors.count < 25 { result.errors.append(url.path+"："+message) } }
        func isExcluded(_ url:URL)->Bool { excluded.contains { url.path == $0 || url.path.hasPrefix($0+"/") } }
        func emit(_ phase:String) { progress(DuplicateScanProgress(phase:phase,visited:result.visitedCount,files:result.fileCount,hashed:result.hashedCount,bytes:result.hashedBytes)) }
        if cancelled() { result.cancelled=true;return result }
        // A symbolic-link root is not followed, even when selected through a file dialog.
        var requestedStat=stat()
        guard lstat(selectedRoot.path,&requestedStat) == 0,requestedStat.st_mode & S_IFMT == S_IFDIR else { recordError(selectedRoot,"无法读取这个文件夹或它是符号链接");return result }
        if isExcluded(root) { result.excludedCount=1;return result }
        let keys:[URLResourceKey]=[.isDirectoryKey,.isPackageKey,.isSymbolicLinkKey,.isHiddenKey,.isRegularFileKey,.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey]
        guard let walker=FileManager.default.enumerator(at:root,includingPropertiesForKeys:keys,options:[.skipsHiddenFiles,.skipsPackageDescendants],errorHandler:{url,issue in recordError(url,issue.localizedDescription);return true}) else { recordError(root,"无法列出这个文件夹");return result }
        emit("正在检查文件大小")
        for case let url as URL in walker {
            if cancelled() { result.cancelled=true;return result }
            result.visitedCount += 1
            if result.visitedCount > limits.maximumVisited { result.limited=true;break }
            if result.visitedCount % 128 == 0 { policy.pauseIfNeeded(cancelled:cancelled);emit("正在检查文件大小") }
            if isExcluded(url) { result.excludedCount += 1;walker.skipDescendants();continue }
            do {
                let values=try url.resourceValues(forKeys:Set(keys))
                if values.isSymbolicLink == true { result.skippedLinks += 1;walker.skipDescendants();continue }
                if values.isHidden == true { result.skippedHidden += 1;walker.skipDescendants();continue }
                if values.isDirectory == true {
                    if values.isPackage == true || ["node_modules","Library",".git","build","DerivedData","Caches"].contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                if values.isUbiquitousItem == true,values.ubiquitousItemDownloadingStatus != .current,values.ubiquitousItemDownloadingStatus != .downloaded { result.skippedCloud += 1;continue }
                guard values.isRegularFile == true else { continue }
                guard seenPaths.insert(url.standardizedFileURL.path).inserted else { continue }
                let file=DuplicateFile(url:url,snapshot:try snapshot(url))
                if result.fileCount >= limits.maximumFiles { result.limited=true;break }
                buckets[file.size,default:[]].append(file);result.fileCount += 1
            } catch { recordError(url,error.localizedDescription) }
        }
        emit("正在核对相同大小文件的内容")
        var content:[String:[DuplicateFile]]=[:],cache:[String:String]=[:]
        let sizes=buckets.keys.sorted()
        for size in sizes where (buckets[size]?.count ?? 0) > 1 {
            for file in buckets[size]!.sorted(by:{$0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending}) {
                if cancelled() { result.cancelled=true;break }
                do {
                    guard file.isCurrent() else { throw DuplicateScanFailure.changed }
                    let hash:String
                    if let cached=cache[file.snapshot.cacheKey] { hash=cached }
                    else {
                        if size > limits.maximumHashedBytes-result.hashedBytes { result.limited=true;continue }
                        hash=try digest(file,cancelled:cancelled,throttle:{policy.pauseIfNeeded(cancelled:cancelled)},read:{count in result.hashedBytes += Int64(count)})
                        cache[file.snapshot.cacheKey]=hash;result.hashedCount += 1
                    }
                    content["\(size):\(hash)",default:[]].append(file)
                } catch DuplicateScanFailure.cancelled { result.cancelled=true;break }
                catch DuplicateScanFailure.changed { recordError(file.url,"核对时文件发生变化，请重新扫描") }
                catch { recordError(file.url,error.localizedDescription) }
                emit("正在核对相同大小文件的内容")
            }
            if result.cancelled { break }
        }
        result.groups=content.compactMap { key,files in
            let current=files.filter { $0.isCurrent() }
            guard current.count > 1 else { return nil }
            return DuplicateGroup(digest:String(key.split(separator:":",maxSplits:1).last!),files:current.sorted{$0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending})
        }.sorted { left,right in
            if left.additionalBytes != right.additionalBytes { return left.additionalBytes > right.additionalBytes }
            if left.size != right.size { return left.size > right.size }
            return (left.files.first?.url.path ?? "").localizedStandardCompare(right.files.first?.url.path ?? "") == .orderedAscending
        }
        emit(result.cancelled ? "已取消" : "核对完成")
        return result
    }
}

private enum DuplicateResultRow {
    case group(Int)
    case file(Int,DuplicateFile)
}
final class DuplicateFinderController:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate,NSWindowDelegate {
    let panel=featurePanel("重复文件查找",size:NSSize(width:820,height:640))
    let scope=NSTextField(labelWithString:"请选择需要检查的文件夹")
    let status=NSTextField(wrappingLabelWithString:"按实际内容分组；同名而内容不同的文件不会合并。")
    let query=NSSearchField()
    let details=NSTextField(wrappingLabelWithString:"")
    var table:NSTableView!
    var chooseButton:NSButton!
    var scanButton:NSButton!
    var cancelButton:NSButton!
    let queue:OperationQueue={let value=OperationQueue();value.maxConcurrentOperationCount=1;value.qualityOfService = .utility;return value}()
    let exclusions:()->[String]
    let adaptive:()->Bool
    var root:URL?
    var result=DuplicateScanResult()
    private var rows:[DuplicateResultRow]=[]
    var busy=false
    var token=UUID()
    var previewPanel:NSPanel?
    var quickPreview:QLPreviewView?
    init(exclusions:@escaping()->[String],adaptive:@escaping()->Bool) {
        self.exclusions=exclusions;self.adaptive=adaptive;super.init()
        panel.delegate=self;panel.minSize=NSSize(width:720,height:600);scope.lineBreakMode = .byTruncatingMiddle;scope.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        details.maximumNumberOfLines=3;details.lineBreakMode = .byTruncatingTail;details.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        query.placeholderString="筛选名称或路径（保留同组文件）";query.delegate=self
        chooseButton=featureButton("选择文件夹…",self,#selector(choose));scanButton=featureButton("开始扫描",self,#selector(scan));scanButton.isEnabled=false
        cancelButton=featureButton("取消扫描",self,#selector(cancel));cancelButton.isEnabled=false
        let pair=featureTable([("name","文件 / 分组",260),("where","位置",400),("size","大小",110)],target:self);fitFeatureTable32(pair.0,pair.1);table=pair.0;table.allowsMultipleSelection=true;table.target=self;table.doubleAction=#selector(preview)
        let header=featureStack([chooseButton,scanButton,cancelButton]),actions=featureStack([featureButton("预览",self,#selector(preview)),featureButton("打开",self,#selector(open)),featureButton("在访达中显示",self,#selector(reveal)),featureButton("复制所选路径",self,#selector(copyPaths))])
        let note=NSTextField(wrappingLabelWithString:"跳过隐藏文件、符号链接、应用包、排除目录和未下载的 iCloud 文件。相同的空文件也会成组；硬链接不计为额外空间。")
        note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor
        let stack=featureStack([header,scope,status,query,pair.1,details,actions,note],vertical:true);featureMount(stack,in:panel)
        for view in [header,scope,status,query,pair.1,details,actions,note] { view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true }
        pair.1.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive=true;query.heightAnchor.constraint(equalToConstant:26).isActive=true
    }
    func show() { panel.makeKeyAndOrderFront(nil) }
    @objc func choose() {
        guard !busy else { return };let picker=NSOpenPanel();picker.canChooseFiles=false;picker.canChooseDirectories=true;picker.allowsMultipleSelection=false;picker.prompt="检查此文件夹"
        picker.beginSheetModal(for:panel) {[weak self] response in
            guard let self,response == .OK,let url=picker.url else { return }
            self.root=url;self.scope.stringValue=(url.path as NSString).abbreviatingWithTildeInPath;self.scope.toolTip=url.path;self.scanButton.isEnabled=true;self.result=DuplicateScanResult();self.reload();self.status.stringValue="已选择文件夹，点击开始扫描。";self.details.stringValue=""
        }
    }
    @objc func scan() {
        guard !busy,let root else { return };busy=true;token=UUID();let current=token,excluded=exclusions(),adaptive=adaptive()
        result=DuplicateScanResult();reload();details.stringValue="";chooseButton.isEnabled=false;scanButton.isEnabled=false;cancelButton.isEnabled=true;status.stringValue="正在检查文件大小…"
        quickPreview?.previewItem=nil
        let operation=BlockOperation()
        operation.addExecutionBlock {[weak self,weak operation] in
            guard let operation else { return };var lastUpdate=Date.distantPast
            let result=DuplicateFinder.scan(root,excluding:excluded,adaptive:adaptive,cancelled:{operation.isCancelled},progress:{progress in
                let now=Date();guard now.timeIntervalSince(lastUpdate) >= 0.2 else { return };lastUpdate=now
                DispatchQueue.main.async {[weak self] in guard let self,self.token == current,self.busy else { return };self.status.stringValue="\(progress.phase) · 已检查 \(progress.files) 个文件 · 已核对 \(progress.hashed) 个文件（\(Self.bytes(progress.bytes))）"}
            })
            DispatchQueue.main.async {[weak self] in
                guard let self,self.token == current else { return };self.busy=false;self.result=result;self.chooseButton.isEnabled=true;self.scanButton.isEnabled=true;self.cancelButton.isEnabled=false;self.reload()
                let count=result.groups.reduce(0){$0+$1.files.count}
                self.status.stringValue=(result.cancelled ? "已取消；以下为已完成核对的结果。" : "核对完成。")+"\(result.groups.count) 组 · \(count) 个文件 · 额外内容 \(Self.bytes(result.additionalBytes))"
                var notes:[String]=[]
                if result.limited { notes.append("已达到单次检查上限（10 万个文件 / 20 万项 / 512 GB 内容），请选择更小范围继续。") }
                if result.skippedCloud > 0 { notes.append("跳过 \(result.skippedCloud) 个未下载的 iCloud 文件。") }
                if result.excludedCount > 0 { notes.append("跳过 \(result.excludedCount) 项排除目录。") }
                if result.errorCount > 0 { notes.append("\(result.errorCount) 项无法核对；查看下方详情。") }
                self.details.stringValue=notes.joined(separator:" ");self.details.toolTip=(notes+result.errors).joined(separator:"\n")
                if !result.errors.isEmpty { self.details.stringValue += "\n"+result.errors.prefix(2).joined(separator:"\n") }
            }
        }
        queue.addOperation(operation)
    }
    static func bytes(_ amount:Int64)->String { ByteCountFormatter.string(fromByteCount:amount,countStyle:.file) }
    @objc func cancel() { guard busy else { return };queue.cancelAllOperations();cancelButton.isEnabled=false;status.stringValue="正在取消扫描…" }
    func reload() {
        let text=normalized(query.stringValue);rows=[]
        for (index,group) in result.groups.enumerated() where text.isEmpty || group.files.contains(where:{normalized($0.url.path).contains(text)}) {
            rows.append(.group(index));rows.append(contentsOf:group.files.map{.file(index,$0)})
        }
        table.reloadData()
        if let first=rows.firstIndex(where:{if case .file = $0 { return true };return false}) { table.selectRowIndexes(IndexSet(integer:first),byExtendingSelection:false) }
    }
    func controlTextDidChange(_ obj:Notification) { reload() }
    func numberOfRows(in tableView:NSTableView)->Int { rows.count }
    func tableView(_ tableView:NSTableView,isGroupRow row:Int)->Bool { guard rows.indices.contains(row) else { return false };if case .group = rows[row] { return true };return false }
    func tableView(_ tableView:NSTableView,shouldSelectRow row:Int)->Bool { guard rows.indices.contains(row) else { return false };if case .file = rows[row] { return true };return false }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
        guard rows.indices.contains(row) else { return nil };let id=column?.identifier.rawValue ?? "name"
        switch rows[row] {
        case .group(let index):let group=result.groups[index];let label=featureCell(id == "name" ? "第 \(index+1) 组 · \(group.files.count) 份相同内容" : id == "where" ? (group.size == 0 ? "空文件" : "额外内容 "+Self.bytes(group.additionalBytes)) : Self.bytes(group.size));label.font = .systemFont(ofSize:12,weight:.semibold);return label
        case .file(_,let file):return featureCell(id == "name" ? file.url.lastPathComponent : id == "where" ? (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath : Self.bytes(file.size))
        }
    }
    func selectedFiles()->[DuplicateFile] { table.selectedRowIndexes.compactMap { index in guard rows.indices.contains(index),case .file(_,let file)=rows[index] else { return nil };return file } }
    func currentSelection()->[DuplicateFile] { let selected=selectedFiles();guard !selected.isEmpty else { status.stringValue="请先选择文件";return [] };guard selected.allSatisfy({$0.isCurrent()}) else { status.stringValue="所选文件已更改或移动，请重新扫描";quickPreview?.previewItem=nil;return [] };return selected }
    @objc func preview() { guard let file=currentSelection().first else { return };let p=previewPanel ?? featurePanel("重复文件预览",size:NSSize(width:720,height:560));previewPanel=p
        if quickPreview == nil { let view=QLPreviewView(frame:p.contentView!.bounds,style:.normal)!;view.autoresizingMask=[.width,.height];p.contentView!.addSubview(view);quickPreview=view }
        p.title=file.url.lastPathComponent;quickPreview?.previewItem=file.url as NSURL;p.makeKeyAndOrderFront(nil)
    }
    @objc func open() { guard let file=currentSelection().first else { return };NSWorkspace.shared.open(file.url) }
    @objc func reveal() { let files=currentSelection();if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url)) } }
    @objc func copyPaths() { let files=currentSelection();guard !files.isEmpty else { return };let pasteboard=NSPasteboard.general;pasteboard.clearContents();pasteboard.setString(files.map{$0.url.path}.joined(separator:"\n"),forType:.string);status.stringValue="已复制 \(files.count) 个文件路径" }
    func windowShouldClose(_ sender:NSWindow)->Bool { if sender === panel { stop() };return true }
    func stop() { let wasBusy=busy;token=UUID();queue.cancelAllOperations();busy=false;chooseButton.isEnabled=true;scanButton.isEnabled=root != nil;cancelButton.isEnabled=false;quickPreview?.previewItem=nil;previewPanel?.close();if wasBusy { status.stringValue="扫描已停止；点击开始扫描可重新检查。" } }
}

extension App {
    @objc func openDuplicateFinder() {
        if duplicateController == nil { duplicateController=DuplicateFinderController(exclusions:{[weak self] in self?.excludedRoots ?? []},adaptive:{[weak self] in self?.adaptiveResources ?? true}) }
        duplicateController?.show()
    }
}

func runDuplicateFinder32Checks()throws {
    let fm=FileManager.default,root=physicalURL(fm.temporaryDirectory).appendingPathComponent("KongFetch-Duplicates32-"+UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:true);defer { try? fm.removeItem(at:root) }
    func put(_ path:String,_ text:String)throws->URL { let url=root.appendingPathComponent(path);try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:url);return url }
    let a=try put("甲/相同名称.txt","abcde"),b=try put("乙/相同名称.txt","vwxyz"),c=try put("不同名字.txt","abcde")
    _ = try put("空文件一.txt","");_ = try put("空文件二.txt","")
    _ = try put(".hidden.txt","abcde");_ = try put("排除目录/副本.txt","abcde");_ = try put("node_modules/副本.txt","abcde")
    _ = try put(".隐藏目录/副本.txt","abcde");_ = try put("测试.app/Contents/副本.txt","abcde")
    try fm.createSymbolicLink(atPath:root.appendingPathComponent("链接.txt").path,withDestinationPath:a.path)
    try fm.createSymbolicLink(atPath:root.appendingPathComponent("目录链接").path,withDestinationPath:root.appendingPathComponent("甲").path)
    let result=DuplicateFinder.scan(root,excluding:[root.appendingPathComponent("排除目录").path],adaptive:false,cancelled:{false})
    precondition(!result.cancelled && result.groups.count == 2 && result.errorCount == 0)
    let content=result.groups.first{$0.size == 5}!
    precondition(Set(content.files.map{$0.url.path}) == Set([a.path,c.path]));precondition(!result.groups.flatMap(\.files).contains{$0.url.path == b.path})
    precondition(result.groups.first{$0.size == 0}!.files.count == 2 && result.additionalBytes == 5)
    precondition(result.skippedLinks == 2 && result.excludedCount == 1)
    let linkedRoot=root.appendingPathComponent("目录链接")
    let refused=DuplicateFinder.scan(linkedRoot,adaptive:false,cancelled:{false})
    precondition(refused.fileCount == 0 && refused.errorCount == 1)
    let excluded=DuplicateFinder.scan(root,excluding:[root.path],adaptive:false,cancelled:{false})
    precondition(excluded.fileCount == 0 && excluded.excludedCount == 1)
    let linked=root.appendingPathComponent("硬链接.txt");guard link(a.path,linked.path) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
    let withHardlink=DuplicateFinder.scan(root,excluding:[root.appendingPathComponent("排除目录").path],adaptive:false,cancelled:{false})
    let hardGroup=withHardlink.groups.first{$0.size == 5}!
    precondition(hardGroup.files.count == 3 && hardGroup.uniqueFileCount == 2 && hardGroup.additionalBytes == 5)
    var cancellationChecks=0
    let cancelled=DuplicateFinder.scan(root,adaptive:false,cancelled:{cancellationChecks += 1;return cancellationChecks > 4})
    precondition(cancelled.cancelled)
    var readCount=0
    let large=try put("large.txt",String(repeating:"A",count:3*1024*1024)),largeFile=DuplicateFile(url:large,snapshot:try DuplicateFinder.snapshot(large))
    do { _ = try DuplicateFinder.digest(largeFile,cancelled:{readCount > 0},throttle:{},read:{_ in readCount += 1});preconditionFailure("stream cancellation ignored") } catch DuplicateScanFailure.cancelled { }
    precondition(readCount == 1)
    let limited=DuplicateFinder.scan(root,limits:DuplicateScanLimits(maximumFiles:2,maximumVisited:200,maximumHashedBytes:0),adaptive:false,cancelled:{false})
    precondition(limited.limited && limited.fileCount <= 2)
    let old=DuplicateFile(url:c,snapshot:try DuplicateFinder.snapshot(c));try Data("changed".utf8).write(to:c);precondition(!old.isCurrent())
    let changed=DuplicateFile(url:large,snapshot:try DuplicateFinder.snapshot(large));var didMutate=false
    do { _ = try DuplicateFinder.digest(changed,cancelled:{false},throttle:{},read:{_ in if !didMutate { didMutate=true;try? Data("replacement".utf8).write(to:large) }});preconditionFailure("changed file accepted") } catch DuplicateScanFailure.changed { }
    print("PASS: duplicate content, names, empty files, symlinks, hard links, exclusions, streaming cancellation and scan limits")
}

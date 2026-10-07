import Cocoa
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// Clipboard records contain copied values only. They never read referenced files.
struct ClipboardRecord32: Codable, Equatable {
    enum Kind: String, Codable { case text, image, files }
    let id: UUID
    let kind: Kind
    var created: Date
    var pinned: Bool
    let text: String?
    let image: Data?
    let imageType: String?
    let files: [String]?
    let fingerprint: String
    let source: String
    var payloadBytes: Int { (text?.utf8.count ?? 0) + (image?.count ?? 0) + (files ?? []).reduce(0) { $0 + $1.utf8.count } }
    var title: String {
        switch kind {
        case .text: return String((text ?? "").replacingOccurrences(of:"\n",with:"  ").prefix(110))
        case .image: return "图片 · \(ByteCountFormatter.string(fromByteCount:Int64(image?.count ?? 0),countStyle:.file))"
        case .files:
            let paths=files ?? []; let first=paths.first.map { URL(fileURLWithPath:$0).lastPathComponent } ?? "文件"
            return paths.count > 1 ? first+" 等 \(paths.count) 项" : first
        }
    }
    var searchable: String { (text ?? "") + " " + (files ?? []).joined(separator:" ") + " " + source + " " + title }
    var valid: Bool {
        guard payloadBytes > 0, source.utf8.count <= 500, fingerprint.count == 64 else { return false }
        switch kind {
        case .text: return text != nil && text!.utf8.count <= ClipboardHistory32.maximumTextBytes && image == nil && files == nil
        case .image: return text == nil && files == nil && image != nil && image!.count <= ClipboardHistory32.maximumImageBytes && [NSPasteboard.PasteboardType.png.rawValue,NSPasteboard.PasteboardType.tiff.rawValue].contains(imageType ?? "") && ClipboardHistory32.validImage(image!)
        case .files: return text == nil && image == nil && !(files ?? []).isEmpty && (files?.count ?? 0) <= 100 && (files ?? []).allSatisfy { $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 8192 } && payloadBytes <= ClipboardHistory32.maximumTextBytes
        }
    }
}

final class ClipboardStore32 {
    let directory: URL
    var file: URL { directory.appendingPathComponent("history.json") }
    init(_ directory: URL) { self.directory=directory }
    func load() throws -> [ClipboardRecord32] {
        let fm=FileManager.default
        guard fm.fileExists(atPath:file.path) else { return [] }
        let attrs=try fm.attributesOfItem(atPath:file.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 40_000_000, attrs[.type] as? FileAttributeType != .typeSymbolicLink else { throw featureError("剪贴板历史文件无效或过大") }
        let records=try JSONDecoder().decode([ClipboardRecord32].self,from:Data(contentsOf:file))
        guard records.count <= ClipboardHistory32.maximumEntries,records.filter(\.pinned).count <= ClipboardHistory32.maximumPinned,records.reduce(0,{$0+$1.payloadBytes}) <= ClipboardHistory32.maximumTotalBytes,records.allSatisfy(\.valid),Set(records.map(\.id)).count == records.count,Set(records.map(\.fingerprint)).count == records.count,records.filter(\.pinned).count <= ClipboardHistory32.maximumPinned,records.reduce(0,{$0+$1.payloadBytes}) <= ClipboardHistory32.maximumTotalBytes else { throw featureError("剪贴板历史文件内容无效") }
        return records
    }
    func save(_ records:[ClipboardRecord32]) throws {
        let fm=FileManager.default
        if fm.fileExists(atPath:directory.path),try fm.attributesOfItem(atPath:directory.path)[.type] as? FileAttributeType == .typeSymbolicLink { throw featureError("剪贴板历史目录不能是符号链接") }
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        try JSONEncoder().encode(records).write(to:file,options:.atomic)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}

final class ClipboardHistory32 {
    static let maximumEntries=200, maximumPinned=50, maximumTextBytes=200_000, maximumImageBytes=4_000_000, maximumTotalBytes=24_000_000
    static let marker=NSPasteboard.PasteboardType("org.kongfetch.clipboard-history")
    static let defaultExcluded=["com.1password.1password","com.agilebits.onepassword7","com.agilebits.onepassword-osx","com.bitwarden.desktop","com.dashlane.Dashlane","com.apple.Passwords","org.keepassxc.keepassxc"]
    let pasteboard:NSPasteboard,store:ClipboardStore32,preferences:UserDefaults
    let source:()->(String,String)
    private let saveQueue=DispatchQueue(label:"com.kongfetch.clipboard-save",qos:.utility)
    private var timer:Timer?,lastChange:Int,started=false,lastPruned=Date()
    private(set) var records:[ClipboardRecord32]=[]
    private(set) var status=""
    var observer:(()->Void)?
    var enabled:Bool { preferences.bool(forKey:"clipboardHistoryEnabled") }
    var paused:Bool { preferences.bool(forKey:"clipboardHistoryPaused") }
    var excluded:[String] { (preferences.stringArray(forKey:"clipboardExcludedApps") ?? Self.defaultExcluded).map { $0.lowercased() } }
    init(pasteboard:NSPasteboard = .general,store:ClipboardStore32,preferences:UserDefaults,source:@escaping()->(String,String) = { let app=NSWorkspace.shared.frontmostApplication;return(app?.bundleIdentifier ?? "",app?.localizedName ?? "其他应用") }) {
        self.pasteboard=pasteboard;self.store=store;self.preferences=preferences;self.source=source;lastChange=pasteboard.changeCount
        do { records=try store.load();let count=records.count;prune(now:Date());if records.count != count {try store.save(records)};status="" } catch {status="历史未能读取；已有文件保留。"}
    }
    func start() {
        guard !started else { return };started=true;lastChange=pasteboard.changeCount
        timer=Timer.scheduledTimer(withTimeInterval:0.75,repeats:true) { [weak self] _ in self?.poll() }
        if let timer { RunLoop.main.add(timer,forMode:.common) }
    }
    func stop() { timer?.invalidate();timer=nil;started=false;saveQueue.sync {} }
    func setEnabled(_ value:Bool) {preferences.set(value,forKey:"clipboardHistoryEnabled");if value {preferences.set(false,forKey:"clipboardHistoryPaused")};lastChange=pasteboard.changeCount;observer?()}
    func setPaused(_ value:Bool) {preferences.set(value,forKey:"clipboardHistoryPaused");lastChange=pasteboard.changeCount;observer?()}
    func setExcluded(_ apps:[String]) throws {
        let clean=Array(Set(apps.map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}.filter{!$0.isEmpty})).sorted()
        guard clean.count <= 100,clean.allSatisfy({$0.utf8.count <= 200 && $0.contains(".") && $0.unicodeScalars.allSatisfy{CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)}}) else {throw featureError("请输入应用的标识符，每行一个，例如 com.apple.Passwords")}
        preferences.set(clean,forKey:"clipboardExcludedApps");observer?()
    }
    static func sensitive(_ types:[NSPasteboard.PasteboardType])->Bool {
        types.contains { type in let name=type.rawValue.lowercased();return name == marker.rawValue || name.contains("concealed") || name.contains("sensitive") || name.contains("password") || name.contains("transient") || name.contains("autogenerated") || name.contains("onepassword") || name.contains("1password") }
    }
    static func validImage(_ data:Data)->Bool {
        guard !data.isEmpty,data.count <= maximumImageBytes,let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source) > 0,let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=props[kCGImagePropertyPixelWidth] as? NSNumber,let height=props[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        return width.intValue > 0 && height.intValue > 0 && width.intValue <= 8192 && height.intValue <= 8192 && width.intValue*height.intValue <= 24_000_000
    }
    static func fingerprint(_ kind:ClipboardRecord32.Kind,_ data:Data)->String {var bytes=Data(kind.rawValue.utf8);bytes.append(0);bytes.append(data);return SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    static func capture(_ pasteboard:NSPasteboard,source:String,now:Date)->ClipboardRecord32? {
        let types=(pasteboard.types ?? []) + (pasteboard.pasteboardItems ?? []).flatMap{ $0.types }
        guard !sensitive(types) else {return nil}
        let cleanSource=String(source.prefix(200))
        if types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) {
            let urls=(pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
            let paths=urls.map(\.path)
            guard !paths.isEmpty,paths.count <= 100,paths.reduce(0,{$0+$1.utf8.count}) <= maximumTextBytes else {return nil}
            let data=(try? JSONEncoder().encode(paths)) ?? Data()
            let result=ClipboardRecord32(id:UUID(),kind:.files,created:now,pinned:false,text:nil,image:nil,imageType:nil,files:paths,fingerprint:fingerprint(.files,data),source:cleanSource)
            return result.valid ? result : nil
        }
        for type in [NSPasteboard.PasteboardType.png,.tiff] where types.contains(type) {
            guard let data=pasteboard.data(forType:type),validImage(data) else {continue}
            return ClipboardRecord32(id:UUID(),kind:.image,created:now,pinned:false,text:nil,image:data,imageType:type.rawValue,files:nil,fingerprint:fingerprint(.image,data),source:cleanSource)
        }
        guard let text=pasteboard.string(forType:.string),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf8.count <= maximumTextBytes else {return nil}
        return ClipboardRecord32(id:UUID(),kind:.text,created:now,pinned:false,text:text,image:nil,imageType:nil,files:nil,fingerprint:fingerprint(.text,Data(text.utf8)),source:cleanSource)
    }
    func poll(now:Date=Date()) {
        if now.timeIntervalSince(lastPruned) > 3600 {lastPruned=now;let count=records.count;prune(now:now);if records.count != count {persist();observer?()}}
        guard pasteboard.changeCount != lastChange else {return};let change=pasteboard.changeCount;lastChange=change
        guard enabled,!paused else {return};let origin=source();guard !excluded.contains(origin.0.lowercased()) else {return}
        guard let record=Self.capture(pasteboard,source:origin.1,now:now),pasteboard.changeCount == change else {return}
        insert(record,now:now)
    }
    func insert(_ record:ClipboardRecord32,now:Date=Date()) {
        guard record.valid else {return}
        if let i=records.firstIndex(where:{$0.fingerprint == record.fingerprint}) { var existing=records.remove(at:i);existing.created=now;records.insert(existing,at:0) } else {records.insert(record,at:0)}
        prune(now:now);persist();observer?()
    }
    private func prune(now:Date) {
        records.removeAll { !$0.pinned && now.timeIntervalSince($0.created) > 30*86400 }
        records.sort { $0.created > $1.created }
        while records.count > Self.maximumEntries || records.reduce(0,{$0+$1.payloadBytes}) > Self.maximumTotalBytes {
            guard let index=records.lastIndex(where:{!$0.pinned}) else {break};records.remove(at:index)
        }
    }
    private func persist() {
        let snapshot=records,store=store
        saveQueue.async { [weak self] in do {try store.save(snapshot)} catch {DispatchQueue.main.async {self?.status="历史保存失败，请检查本机存储空间与目录权限。";self?.observer?()}} }
    }
    func flush() {saveQueue.sync {}}
    func togglePin(_ id:UUID) throws {
        guard let i=records.firstIndex(where:{$0.id == id}) else {return}
        guard records[i].pinned || records.filter(\.pinned).count < Self.maximumPinned else {throw featureError("最多固定 50 项；请先取消一项固定")}
        // Pins count against the same 24 MB history limit; reject pinning past it.
        let pinnedBytes=records.filter(\.pinned).reduce(0,{$0+$1.payloadBytes})
        guard records[i].pinned || pinnedBytes+records[i].payloadBytes <= Self.maximumTotalBytes else {throw featureError("固定内容超过 24 MB，请先取消其他固定")}
        records[i].pinned.toggle();prune(now:Date());persist();observer?()
    }
    func remove(_ id:UUID) {records.removeAll{$0.id == id};persist();observer?()}
    func clear(includePinned:Bool) {records.removeAll{includePinned || !$0.pinned};persist();observer?()}
    func copy(_ id:UUID) throws {
        guard let record=records.first(where:{$0.id == id}),record.valid else {throw featureError("此历史记录已不可用")}
        try Self.write(record,to:pasteboard);lastChange=pasteboard.changeCount;status="已复制，请切换到目标应用粘贴";observer?()
    }
    static func write(_ record:ClipboardRecord32,to pasteboard:NSPasteboard) throws {
        guard record.valid else {throw featureError("剪贴板内容无效")}
        pasteboard.clearContents()
        let ok:Bool
        switch record.kind {
        case .text: ok=pasteboard.setString(record.text!,forType:.string)
        case .image: ok=pasteboard.setData(record.image!,forType:NSPasteboard.PasteboardType(record.imageType!))
        case .files: ok=pasteboard.writeObjects((record.files ?? []).map{NSURL(fileURLWithPath:$0)})
        }
        guard ok else {throw featureError("未能写入剪贴板，请重试")}
        // Avoid recording a restored item as a new copy, including another running instance.
        pasteboard.setString("restored",forType:marker)
    }
}

final class ClipboardPanel32:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate {
    let manager:ClipboardHistory32,panel=featurePanel("剪贴板历史",size:NSSize(width:750,height:510))
    let query=NSSearchField(),status=NSTextField(wrappingLabelWithString:""),details=NSTextField(wrappingLabelWithString:"")
    let preview=NSTextView(),previewScroll=NSScrollView(),imageView=NSImageView()
    var table:NSTableView!,rows:[ClipboardRecord32]=[],pauseButton:NSButton!,copyButton:NSButton!,pinButton:NSButton!,deleteButton:NSButton!
    var excludedAppsController:ClipboardExcludedApps32?
    init(_ manager:ClipboardHistory32) {
        self.manager=manager;super.init();query.placeholderString="搜索复制过的文字、文件名或来源应用";query.delegate=self
        let pair=featureTable([("item","内容",260),("time","时间",90)],target:self);fitFeatureTable32(pair.0,pair.1);table=pair.0;table.target=self;table.doubleAction = #selector(copySelected)
        pauseButton=featureButton("启用记录",self,#selector(togglePause));copyButton=featureButton("复制",self,#selector(copySelected));pinButton=featureButton("固定",self,#selector(pin));deleteButton=featureButton("删除",self,#selector(remove))
        let header=featureStack([pauseButton,featureButton("不记录的应用…",self,#selector(exclusions)),featureButton("清空…",self,#selector(clear))])
        preview.isEditable=false;preview.isSelectable=true;preview.font = .systemFont(ofSize:13);preview.textContainerInset=NSSize(width:10,height:10);preview.autoresizingMask=[.width];preview.minSize=NSSize(width:0,height:0);preview.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);preview.isVerticallyResizable=true;preview.isHorizontallyResizable=false;preview.textContainer?.widthTracksTextView=true;previewScroll.hasVerticalScroller=true;previewScroll.documentView=preview
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let previewHost=NSView();previewHost.translatesAutoresizingMaskIntoConstraints=false;for view in [previewScroll,imageView] {view.translatesAutoresizingMaskIntoConstraints=false;previewHost.addSubview(view);NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:previewHost.leadingAnchor),view.trailingAnchor.constraint(equalTo:previewHost.trailingAnchor),view.topAnchor.constraint(equalTo:previewHost.topAnchor),view.bottomAnchor.constraint(equalTo:previewHost.bottomAnchor)])}
        let right=featureStack([details,previewHost],vertical:true);details.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true;previewHost.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true
        let body=featureStack([pair.1,right]);body.alignment = .top;pair.1.widthAnchor.constraint(equalTo:body.widthAnchor,multiplier:0.5,constant:-5).isActive=true;right.widthAnchor.constraint(equalTo:body.widthAnchor,multiplier:0.5,constant:-5).isActive=true;pair.1.heightAnchor.constraint(equalTo:body.heightAnchor).isActive=true;right.heightAnchor.constraint(equalTo:body.heightAnchor).isActive=true
        let bottom=featureStack([copyButton,pinButton,deleteButton]);let stack=featureStack([query,header,body,status,bottom],vertical:true);featureMount(stack,in:panel)
        for view in [query,header,body,status,bottom] {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true};body.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive=true;query.heightAnchor.constraint(equalToConstant:26).isActive=true
        manager.observer={ [weak self] in self?.refresh() };refresh()
    }
    var selected:ClipboardRecord32? {rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil}
    func show() {manager.start();refresh();panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(query)}
    func refresh() {
        let selectedID=selected?.id,needle=normalized(query.stringValue)
        rows=manager.records.filter{needle.isEmpty || normalized($0.searchable).contains(needle)}.sorted{if $0.pinned != $1.pinned {return $0.pinned};return $0.created > $1.created}
        table.reloadData();if let selectedID,let index=rows.firstIndex(where:{$0.id == selectedID}) {table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)} else if !rows.isEmpty {table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)}
        pauseButton.title = !manager.enabled ? "启用记录" : manager.paused ? "继续记录" : "暂停记录"
        let state = !manager.enabled ? "尚未启用；只会保存启用之后复制的内容。" : manager.paused ? "已暂停；暂停期间的复制不会被补录。" : "正在记录；200 项 / 24 MB，未固定内容保存 30 天。"
        status.stringValue=state+"\n仅存本机；敏感标记与排除应用自动跳过。"+(manager.status.isEmpty ? "" : "\n"+manager.status)
        updatePreview()
    }
    func controlTextDidChange(_ obj:Notification) {refresh()}
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
        guard control === query,!textView.hasMarkedText(),panel.attachedSheet == nil else{return false}
        if selector == #selector(NSResponder.insertNewline(_:)) {copySelected();return true}
        if selector == #selector(NSResponder.moveDown(_:)),!rows.isEmpty {let index=min(max(table.selectedRow+1,0),rows.count-1);table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);table.scrollRowToVisible(index);return true}
        if selector == #selector(NSResponder.moveUp(_:)),!rows.isEmpty {let index=max(table.selectedRow-1,0);table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);table.scrollRowToVisible(index);return true}
        return false
    }
    func numberOfRows(in tableView:NSTableView)->Int {rows.count}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {guard rows.indices.contains(row) else{return nil};let record=rows[row];let date=DateFormatter();date.dateFormat="MM/dd HH:mm";let text=column?.identifier.rawValue == "time" ? date.string(from:record.created) : (record.pinned ? "📌 " : "")+record.title;return featureCell(text)}
    func tableViewSelectionDidChange(_ notification:Notification) {updatePreview()}
    func updatePreview() {
        let record=selected;copyButton.isEnabled=record != nil;pinButton.isEnabled=record != nil;deleteButton.isEnabled=record != nil;pinButton.title=record?.pinned == true ? "取消固定" : "固定"
        imageView.image=nil;imageView.isHidden=true;previewScroll.isHidden=false;preview.string="";details.stringValue="选择一项查看内容；双击复制后可自行粘贴。"
        guard let record else {return};details.stringValue=record.source+" · "+record.created.formatted(date:.abbreviated,time:.shortened)
        switch record.kind {case .text:preview.string=record.text ?? "";case .files:preview.string=(record.files ?? []).joined(separator:"\n");case .image:previewScroll.isHidden=true;imageView.isHidden=false;imageView.image=record.image.flatMap(NSImage.init(data:))}
        preview.setSelectedRange(NSRange(location:0,length:0));preview.scrollRangeToVisible(NSRange(location:0,length:0))
    }
    @objc func togglePause() {
        if !manager.enabled {let alert=NSAlert();alert.messageText="启用剪贴板历史？";alert.informativeText="启用后保存复制过的文字、图片和文件引用，便于查找并再次复制。内容仅保存在这台 Mac，最多 200 项 / 24 MB。带敏感标记的内容和排除应用不会记录；未标记的私密内容仍可能保存，请按需暂停或清空。不会记录启用前的剪贴板。";alert.addButton(withTitle:"启用");alert.addButton(withTitle:"取消");alert.beginSheetModal(for:panel) {[weak self] response in if response == .alertFirstButtonReturn {self?.manager.setEnabled(true)}}} else {manager.setPaused(!manager.paused)}
    }
    @objc func copySelected() {guard let item=selected else{return};do {try manager.copy(item.id)}catch{status.stringValue=error.localizedDescription}}
    @objc func pin() {guard let item=selected else{return};do {try manager.togglePin(item.id)}catch{status.stringValue=error.localizedDescription}}
    @objc func remove() {guard let item=selected else{return};manager.remove(item.id)}
    @objc func clear() {let alert=NSAlert();alert.messageText="清空剪贴板历史？";alert.informativeText="仅删除 KongFetch 保存的历史，不改变当前剪贴板。";alert.addButton(withTitle:"清空未固定项");alert.addButton(withTitle:"清空全部");alert.addButton(withTitle:"取消");alert.beginSheetModal(for:panel) {[weak self] response in if response == .alertFirstButtonReturn {self?.manager.clear(includePinned:false)} else if response == .alertSecondButtonReturn {self?.manager.clear(includePinned:true)}}}
    @objc func exclusions() {
        guard panel.attachedSheet == nil else{return}
        if excludedAppsController == nil {excludedAppsController=ClipboardExcludedApps32(manager)}
        excludedAppsController?.show(asSheetOf:panel)
    }

}


final class ClipboardExcludedApps32:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate {
    let manager:ClipboardHistory32,panel=featurePanel("不记录的应用",size:NSSize(width:660,height:430))
    let state=NSTextField(wrappingLabelWithString:"")
    var table:NSTableView!,rows:[String]=[],removeButton:NSButton!
    init(_ manager:ClipboardHistory32) {
        self.manager=manager;super.init();panel.delegate=self
        let pair=featureTable([("app","应用",580)],target:self);fitFeatureTable32(pair.0,pair.1);table=pair.0;table.allowsMultipleSelection=true
        removeButton=featureButton("移除所选",self,#selector(remove));let buttons=featureStack([featureButton("添加应用…",self,#selector(add)),removeButton,featureButton("补充默认排除",self,#selector(defaults)),featureButton("完成",self,#selector(done))])
        let explanation=NSTextField(wrappingLabelWithString:"在以下应用中复制的内容会跳过记录。点击“添加应用”直接选择应用；带敏感标记的内容始终不会记录。")
        let stack=featureStack([explanation,pair.1,state,buttons],vertical:true);featureMount(stack,in:panel)
        for view in [explanation,pair.1,state,buttons] {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true};pair.1.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive=true;refresh()
    }
    static func title(_ identifier:String)->String {
        if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:identifier) {
            let info=Bundle(url:url)?.infoDictionary
            return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        }
        let known=["com.1password.1password":"1Password","com.agilebits.onepassword7":"1Password 7","com.agilebits.onepassword-osx":"1Password（旧版）","com.bitwarden.desktop":"Bitwarden","com.dashlane.dashlane":"Dashlane","com.apple.passwords":"密码","org.keepassxc.keepassxc":"KeePassXC"]
        return known[identifier.lowercased()].map{$0+"（尚未安装）"} ?? "未安装的应用"
    }
    func show(asSheetOf parent:NSWindow) {refresh();guard panel.sheetParent == nil else{return};parent.beginSheet(panel)}
    func refresh() {rows=manager.excluded.sorted{Self.title($0).localizedStandardCompare(Self.title($1)) == .orderedAscending};table.reloadData();removeButton.isEnabled=false;state.stringValue="已排除 \(rows.count) 个应用；修改立即生效。"}
    func numberOfRows(in tableView:NSTableView)->Int {rows.count}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {guard rows.indices.contains(row) else{return nil};let field=featureCell(Self.title(rows[row]));field.toolTip=rows[row];return field}
    func tableViewSelectionDidChange(_ notification:Notification) {removeButton.isEnabled = !table.selectedRowIndexes.isEmpty}
    @objc func add() {
        let choose=NSOpenPanel();choose.title="选择不记录的应用";choose.prompt="添加";choose.allowedContentTypes=[.application];choose.canChooseFiles=true;choose.canChooseDirectories=false;choose.allowsMultipleSelection=true;choose.directoryURL=URL(fileURLWithPath:"/Applications")
        choose.beginSheetModal(for:panel) {[weak self] response in guard let self,response == .OK else{return};let identifiers=choose.urls.compactMap{Bundle(url:$0)?.bundleIdentifier};guard identifiers.count == choose.urls.count else{self.state.stringValue="有应用无法识别，请重新选择。";return};do {try self.manager.setExcluded(self.manager.excluded+identifiers);self.refresh()}catch{self.state.stringValue=error.localizedDescription}}
    }
    @objc func remove() {let selected=Set(table.selectedRowIndexes.compactMap{rows.indices.contains($0) ? rows[$0] : nil});do{try manager.setExcluded(manager.excluded.filter{!selected.contains($0)});refresh()}catch{state.stringValue=error.localizedDescription}}
    @objc func defaults() {do{try manager.setExcluded(manager.excluded+ClipboardHistory32.defaultExcluded);refresh()}catch{state.stringValue=error.localizedDescription}}
    @objc func done() {panel.sheetParent?.endSheet(panel);panel.orderOut(nil)}
    func windowShouldClose(_ sender:NSWindow)->Bool {done();return false}
}

// Standard selection copying is checked again against the current OCR cache.
final class OCRTextView32:NSTextView {
    var validateCopy:(()->Bool)?
    override func copy(_ sender:Any?) {guard validateCopy?() ?? false else{return};super.copy(sender)}
}
final class OCRTextPanel32:NSObject,NSTextViewDelegate {
    let panel=featurePanel("OCR 文字",size:NSSize(width:720,height:560)),textView=OCRTextView32(),state=NSTextField(wrappingLabelWithString:"")
    let current:()->OCRRecord?,searchText:(String)->Void
    var displayedPath="",displayedText="",copyAll:NSButton!,exportButton:NSButton!,searchButton:NSButton!
    init(current:@escaping()->OCRRecord?,searchText:@escaping(String)->Void) {
        self.current=current;self.searchText=searchText;super.init();textView.isEditable=false;textView.isSelectable=true;textView.isRichText=false;textView.font = .systemFont(ofSize:15);textView.textContainerInset=NSSize(width:12,height:12);textView.minSize=NSSize(width:0,height:0);textView.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);textView.isVerticallyResizable=true;textView.isHorizontallyResizable=false;textView.autoresizingMask=[.width];textView.textContainer?.widthTracksTextView=true;textView.delegate=self;textView.validateCopy={ [weak self] in self?.validateCurrent() ?? false }
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.documentView=textView
        copyAll=featureButton("复制全部文字",self,#selector(copyText));exportButton=featureButton("导出 TXT…",self,#selector(exportText));searchButton=featureButton("搜索选中文字",self,#selector(searchSelection));let buttons=featureStack([copyAll,exportButton,searchButton]);let stack=featureStack([state,scroll,buttons],vertical:true);featureMount(stack,in:panel);for view in [state,scroll,buttons] {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true};scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:280).isActive=true
    }
    func show() {refresh();panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(textView)}
    func refresh() {
        guard let record=current(),record.isCurrent(),!record.text.isEmpty else {displayedPath="";displayedText="";textView.string="";state.stringValue="没有当前有效的 OCR 文字。请先在 OCR 管理中识别文件，或等待文件更新完成。";copyAll.isEnabled=false;exportButton.isEnabled=false;searchButton.isEnabled=false;return}
        displayedPath=record.path;displayedText=record.text;textView.string=record.text;textView.setSelectedRange(NSRange(location:0,length:0));state.stringValue=URL(fileURLWithPath:record.path).lastPathComponent+" · \(record.pages) 页"+(record.limited ? " · 只识别了部分内容" : "")+"\n可选择文字后复制或搜索；导出为 UTF-8 纯文本，不改变原文件。";copyAll.isEnabled=true;exportButton.isEnabled=true;searchButton.isEnabled=false
    }
    @discardableResult func validateCurrent()->Bool {
        guard let record=current(),record.path == displayedPath,record.text == displayedText,record.isCurrent(),!displayedText.isEmpty else {state.stringValue="原文件或 OCR 缓存已变化，请重新打开 OCR 文字以读取最新结果。";copyAll.isEnabled=false;exportButton.isEnabled=false;searchButton.isEnabled=false;return false};return true
    }
    var selectedText:String? {let range=textView.selectedRange();let string=textView.string as NSString;guard range.length > 0,range.location != NSNotFound,NSMaxRange(range) <= string.length else{return nil};let selected=string.substring(with:range).trimmingCharacters(in:.whitespacesAndNewlines);return selected.isEmpty ? nil : selected}
    func textViewDidChangeSelection(_ notification:Notification) {searchButton.isEnabled=selectedText != nil && !displayedText.isEmpty}
    @objc func copyText() {guard validateCurrent() else{return};NSPasteboard.general.clearContents();if NSPasteboard.general.setString(displayedText,forType:.string) {state.stringValue="已复制全部 OCR 文字"}}
    static func export(_ record:OCRRecord,to url:URL)throws {
        guard record.isCurrent(),!record.text.isEmpty else {throw featureError("OCR 文字已过期，请先完成重新识别")}
        guard url.resolvingSymlinksInPath().standardizedFileURL.path != URL(fileURLWithPath:record.path).resolvingSymlinksInPath().standardizedFileURL.path, fileIdentity(url) == nil || fileIdentity(url) != fileIdentity(URL(fileURLWithPath:record.path)) else {throw featureError("导出文件不能覆盖原文件")}
        try Data(record.text.utf8).write(to:url,options:.atomic)
    }
    @objc func exportText() {
        guard validateCurrent(),let record=current() else{return};let save=NSSavePanel();save.title="导出 OCR 文字";save.allowedContentTypes=[.plainText];save.nameFieldStringValue=URL(fileURLWithPath:record.path).deletingPathExtension().lastPathComponent+"-OCR.txt";save.beginSheetModal(for:panel) {[weak self] response in guard let self,response == .OK,let url=save.url,self.validateCurrent() else{return};do {try Self.export(record,to:url);self.state.stringValue="已导出 TXT："+url.lastPathComponent}catch{self.state.stringValue=error.localizedDescription}}
    }
    @objc func searchSelection() {guard validateCurrent(),let selected=selectedText else{return};guard selected.count <= 300 else {state.stringValue="请选择不超过 300 个字符进行搜索";return};panel.orderOut(nil);searchText(selected)}
}

// Meaningful native regression checks use a named pasteboard and isolated storage.
// The user's general clipboard and installed-app preferences are never modified.
func checkClipboardAndOCR32(_ root:URL)throws {
    func check(_ condition:@autoclosure()throws->Bool,_ message:String)throws {if try !condition(){throw featureError("3.2 剪贴板 / OCR 验证失败："+message)}}
    let pasteboard=NSPasteboard(name:NSPasteboard.Name("com.kongfetch.qa32."+UUID().uuidString)),suite="com.kongfetch.qa32.clipboard."+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!,store=ClipboardStore32(root.appendingPathComponent("clipboard-check"));defer {pasteboard.releaseGlobally();preferences.removePersistentDomain(forName:suite)}
    var origin=("com.kongfetch.qa32","验证应用"),now=Date();let manager=ClipboardHistory32(pasteboard:pasteboard,store:store,preferences:preferences,source:{origin})
    pasteboard.clearContents();pasteboard.setString("启用前的私密文字",forType:.string);manager.poll();try check(manager.records.isEmpty,"默认不记录")
    manager.setEnabled(true);manager.poll();try check(manager.records.isEmpty,"不补录启用前内容")
    pasteboard.clearContents();pasteboard.setString("乐乐的年度合同\n第二行",forType:.string);manager.poll(now:now);try check(manager.records.count == 1 && manager.records[0].text == "乐乐的年度合同\n第二行","中文文本记录")
    let originalID=manager.records[0].id;try manager.togglePin(originalID);now=now.addingTimeInterval(1);pasteboard.clearContents();pasteboard.setString("乐乐的年度合同\n第二行",forType:.string);manager.poll(now:now);try check(manager.records.count == 1 && manager.records[0].pinned && manager.records[0].id == originalID,"重复内容合并且固定保留")
    pasteboard.clearContents();pasteboard.setString("秘密",forType:.string);pasteboard.setString("",forType:NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"));manager.poll();try check(manager.records.count == 1,"敏感标记跳过")
    origin=("com.apple.Passwords","密码");pasteboard.clearContents();pasteboard.setString("不能记录的密码",forType:.string);manager.poll();try check(manager.records.count == 1,"密码应用排除")
    origin=("com.kongfetch.qa32","验证应用");manager.setPaused(true);pasteboard.clearContents();pasteboard.setString("暂停期间",forType:.string);manager.poll();manager.setPaused(false);manager.poll();try check(manager.records.count == 1,"暂停内容不补录")
    pasteboard.clearContents();pasteboard.setString(String(repeating:"a",count:ClipboardHistory32.maximumTextBytes+1),forType:.string);manager.poll();try check(manager.records.count == 1,"超大文字跳过")
    pasteboard.clearContents();pasteboard.writeObjects([root.appendingPathComponent("不存在的乐乐文件.txt") as NSURL]);manager.poll();try check(manager.records.contains{$0.kind == .files && $0.files?.first?.contains("乐乐") == true},"仅保存文件引用")
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:16,bitsPerPixel:32)!;bitmap.bitmapData?.initialize(repeating:0,count:bitmap.bytesPerRow*bitmap.pixelsHigh);let png=bitmap.representation(using:.png,properties:[:])!;pasteboard.clearContents();pasteboard.setData(png,forType:.png);manager.poll();try check(manager.records.contains{$0.kind == .image},"图片记录")
    if let imageRecord=manager.records.first(where:{$0.kind == .image}) {try manager.copy(imageRecord.id);try check(pasteboard.data(forType:.png) == png,"图片复制格式保留")}
    if let fileRecord=manager.records.first(where:{$0.kind == .files}) {try manager.copy(fileRecord.id);let urls=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL];try check(urls?.first?.path == fileRecord.files?.first,"文件引用复制保留")}
    try manager.copy(originalID);try check(pasteboard.string(forType:.string) == "乐乐的年度合同\n第二行","再次复制内容完整");let count=manager.records.count;manager.poll();try check(manager.records.count == count,"恢复内容不会重复记录")
    manager.flush();let loaded=try store.load();try check(loaded.count == manager.records.count && loaded.contains{$0.id == originalID && $0.pinned},"本地保存与固定恢复")
    for index in 0..<205 {let text="bounded record \(index)",record=ClipboardRecord32(id:UUID(),kind:.text,created:now.addingTimeInterval(Double(index+1)),pinned:false,text:text,image:nil,imageType:nil,files:nil,fingerprint:ClipboardHistory32.fingerprint(.text,Data(text.utf8)),source:"验证应用");manager.insert(record,now:record.created)}
    try check(manager.records.count == 200 && manager.records.contains{$0.id == originalID},"200 项上限与固定保留")
    manager.poll(now:now.addingTimeInterval(31*86400));try check(manager.records.count == 1 && manager.records[0].pinned,"剪贴板未变化时也清理过期记录")
    manager.clear(includePinned:false);try check(manager.records.count == 1 && manager.records[0].pinned,"清空未固定项")
    manager.clear(includePinned:true);manager.flush();try check(try store.load().isEmpty,"清空全部持久化")
    let source=root.appendingPathComponent("ocr-current.txt"),destination=root.appendingPathComponent("ocr-export.txt");try Data("source".utf8).write(to:source);let entry=Entry(source),record=OCRRecord(path:source.path,modified:entry.modified ?? .distantPast,size:entry.size,text:"乐乐合同\n保留全部识别文字。",pages:1,limited:false)
    try OCRTextPanel32.export(record,to:destination);try check(try String(contentsOf:destination,encoding:.utf8) == record.text,"OCR 导出 UTF-8 完整内容")
    var searched="";let viewer=OCRTextPanel32(current:{record},searchText:{searched=$0});viewer.refresh();viewer.textView.setSelectedRange(NSRange(location:0,length:4));try check(viewer.selectedText == "乐乐合同" && viewer.validateCurrent(),"OCR 中文选择与当前缓存")
    viewer.searchSelection();try check(searched == "乐乐合同","OCR 选中文字触发搜索")
    var rejectedOriginal=false;do {try OCRTextPanel32.export(record,to:source)}catch{rejectedOriginal=true};try check(rejectedOriginal && (try Data(contentsOf:source)) == Data("source".utf8),"原文件保留")
    try Data("source modified".utf8).write(to:source);var rejectedStale=false;do {try OCRTextPanel32.export(record,to:destination)}catch {rejectedStale=true};try check(rejectedStale && (try String(contentsOf:destination,encoding:.utf8)) == record.text,"过期 OCR 不覆盖导出");try check(!viewer.validateCurrent() && !viewer.exportButton.isEnabled,"OCR 查看器拒绝过期操作")
    manager.stop();print("PASS clipboard: opt-in, pause, sensitive/source filters, Chinese text, files, images, dedup, pins, bounds, persistence, copy and clear; OCR export/current-cache protection")
}

extension App {
    func makeClipboardManager32()->ClipboardHistory32 {
        if let existing=clipboardManager32 {return existing}
        let support=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KongFetch/Clipboard")
        let manager=ClipboardHistory32(store:ClipboardStore32(support),preferences:preferences);clipboardManager32=manager;return manager
    }
    func startClipboardHistory32() {guard preferences.bool(forKey:"clipboardHistoryEnabled") else{return};makeClipboardManager32().start()}
    func stopClipboardHistory32() {clipboardManager32?.stop()}
    @objc func openClipboardHistory32() {
        let manager=makeClipboardManager32();if clipboardPanel32 == nil {clipboardPanel32=ClipboardPanel32(manager)};clipboardPanel32?.show()
    }
    var currentOCRRecord32:OCRRecord? {
        guard let entry=selected,let record=ocrRecords[entry.url.path] ?? ocrRecords[physicalURL(entry.url).path],record.isCurrent(),!record.text.isEmpty else {return nil};return record
    }
    @objc func openOCRText32() {
        guard let record=currentOCRRecord32 else {status.stringValue="选中文件没有当前有效的 OCR 文字，请先在 OCR 管理中识别或等待更新";return}
        let selectedPath=record.path
        ocrTextPanel32?.panel.close()
        ocrTextPanel32=OCRTextPanel32(current:{ [weak self] in self?.ocrRecords[selectedPath] },searchText:{ [weak self] text in
            guard let self else{return};self.show();self.searchMode = .content;self.updateSearchModeUI()
            // A quoted selection is literal even when it contains date words or operators.
            self.search.stringValue="\""+text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\"";self.startSearch();self.saveState()
        });ocrTextPanel32?.show()
    }
}

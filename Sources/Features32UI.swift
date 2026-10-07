import Cocoa
import Carbon

func fitFeatureTable32(_ table:NSTableView,_ scroll:NSScrollView) {
    table.autoresizingMask=[.width]
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    scroll.hasHorizontalScroller=false
    scroll.autohidesScrollers=true
}

struct PaletteCommand32 {
    let item:NSMenuItem
    let title:String
    let shortcut:String
    var enabled:Bool { item.isEnabled }
    static func flatten(_ menu:NSMenu,group:String="",shortcuts:[String:String]=[:])->[PaletteCommand32] {
        menu.items.flatMap { item -> [PaletteCommand32] in
            guard !item.isSeparatorItem else { return [] }
            let name=group.isEmpty ? item.title : group+" › "+item.title
            if let sub=item.submenu { return flatten(sub,group:name,shortcuts:shortcuts) }
            guard let action=item.action else { return [] }
            let key=shortcuts[NSStringFromSelector(action)] ?? (item.keyEquivalent.isEmpty ? "" : "⌘"+item.keyEquivalent.uppercased())
            return [PaletteCommand32(item:item,title:name,shortcut:key)]
        }
    }
    func score(_ query:String)->Int? {
        let words=query.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        var score=0
        for word in words {
            guard let value=fuzzyScore(title,word) ?? pinyinScore(pinyinForms(title),word) else { return nil }
            score += value
        }
        return score
    }
}

final class CommandPalette32:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate,NSWindowDelegate {
    let panel=featurePanel("搜索操作",size:NSSize(width:640,height:440))
    let query=NSSearchField()
    let note=NSTextField(labelWithString:"↑↓ 选择 · 回车执行 · Esc 关闭")
    var table:NSTableView!
    var commands:[PaletteCommand32]=[],rows:[PaletteCommand32]=[]
    var monitor:Any?
    let execute:(NSMenuItem)->Void
    init(execute:@escaping(NSMenuItem)->Void) {
        self.execute=execute;super.init();panel.delegate=self
        query.placeholderString="输入操作名称，例如：剪贴板、重命名、复制路径";query.delegate=self
        let pair=featureTable([("name","操作",440),("key","快捷键",130)],target:self)
        fitFeatureTable32(pair.0,pair.1)
        table=pair.0;table.target=self;table.doubleAction = #selector(run)
        table.headerView=nil;table.usesAlternatingRowBackgroundColors=false;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let stack=featureStack([query,pair.1,note],vertical:true);featureMount(stack,in:panel)
        for view in [query,pair.1,note] { view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true }
        pair.1.heightAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true
        note.textColor = .secondaryLabelColor;note.font = .systemFont(ofSize:11)
        monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,self.panel.isKeyWindow,self.panel.attachedSheet == nil else {return event}
            if let text=self.panel.firstResponder as? NSTextView,text.hasMarkedText() { return event }
            if event.keyCode == 53 {self.panel.close();return nil}
            if event.keyCode == 36 {self.run();return nil}
            if [125,126].contains(event.keyCode),!self.rows.isEmpty {
                let row=max(0,min(self.rows.count-1,self.table.selectedRow+(event.keyCode == 125 ? 1 : -1)))
                self.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);self.table.scrollRowToVisible(row);return nil
            }
            return event
        }
    }
    deinit { if let monitor {NSEvent.removeMonitor(monitor)} }
    func show(_ commands:[PaletteCommand32]) { self.commands=commands;query.stringValue="";filter();panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(query) }
    func filter() {
        let term=query.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        rows=commands.enumerated().compactMap { index,item -> (Int,Int,PaletteCommand32)? in item.score(term).map{($0,index,item)} }.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map{$0.2}
        table.reloadData();if !rows.isEmpty {table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)}
        note.stringValue=rows.isEmpty ? "没有匹配的操作" : "↑↓ 选择 · 回车执行 · 灰色操作需要先选择文件"
    }
    func controlTextDidChange(_ obj:Notification) { if (query.currentEditor() as? NSTextView)?.hasMarkedText() != true {filter()} }
    func numberOfRows(in tableView:NSTableView)->Int {rows.count}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
        let command=rows[row],field=featureCell(column?.identifier.rawValue == "key" ? command.shortcut : command.title)
        field.textColor=command.enabled ? .labelColor : .tertiaryLabelColor;return field
    }
    @objc func run() {guard rows.indices.contains(table.selectedRow) else{return};let command=rows[table.selectedRow];guard command.enabled else {note.stringValue="请先选择适用的文件，再执行此操作";return};panel.close();execute(command.item)}
}

struct ListPosition32 {
    let selected:[URL]
    let top:URL?
    let offset:CGFloat
    init(_ app:App) {
        selected=app.selectedURLs
        let visible=app.table.enclosingScrollView?.contentView.bounds ?? .zero
        let row=max(0,app.table.row(at:NSPoint(x:1,y:visible.minY+1)))
        top=app.entries.indices.contains(row) ? app.entries[row].url : nil
        offset=app.entries.indices.contains(row) ? visible.minY-app.table.rect(ofRow:row).minY : 0
    }
    func restore(_ app:App) {
        app.selectURLs(selected.filter{url in app.entries.contains{$0.url == url}})
        if let top,let row=app.entries.firstIndex(where:{$0.url == top}),let scroll=app.table.enclosingScrollView {
            let maxY=max(0,app.table.bounds.height-scroll.contentView.bounds.height)
            scroll.contentView.scroll(to:NSPoint(x:0,y:min(maxY,max(0,app.table.rect(ofRow:row).minY+offset))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
struct SearchNavigation32 {
    let state:[String:Any]
    let position:ListPosition32
    let entries:[Entry]
    let recent:Bool
    let collection:Int?
    let tag:String
    init(_ app:App) {state=app.captureSearch("");position=ListPosition32(app);entries=app.entries;recent=app.showingRecent;collection=app.localCollection;tag=app.tagFilter}
}

extension App {
    @objc func openSearchDiagnosis32() {
        if searchDiagnosis32 == nil {
            searchDiagnosis32=SearchDiagnosisController(target:selected?.url,context:{[weak self] in
                guard let self else {return SearchDiagnosisContext(roots:[],exclusions:[],query:AdvancedSearchQuery(""),mode:.filename,precision:.fuzzyName,snapshots:[:])}
                let roots=self.expandedRoots(self.activeSearchRoots)
                var snapshots=self.directorySnapshots
                for root in roots {if let snapshot=self.directorySnapshot(root) {snapshots[root.path]=snapshot}}
                for (key,value) in self.catalogCache {snapshots[key]=value.1}
                return SearchDiagnosisContext(roots:self.activeSearchRoots.map{URL(fileURLWithPath:$0)},exclusions:self.excludedRoots,query:SearchInput(self.search.stringValue,fallback:self.fileFilter).advanced,mode:self.searchMode,precision:self.precision,snapshots:snapshots,ocrRecords:self.ocrRecords,indexSummary:self.indexSummary,detailDescription:self.filterSummary.stringValue,detailAccepts:{[weak self] entry in self?.acceptsDetails(entry) ?? true},localRoots:roots)
            },repair:{[weak self] root in self?.rebuildDirectory(root)})
        }
        searchDiagnosis32?.show()
    }
    var isComposing32:Bool { (window.firstResponder as? NSTextView)?.hasMarkedText() == true || (search.currentEditor() as? NSTextView)?.hasMarkedText() == true }
    func routeSearchKey32(_ event:NSEvent)->Bool {
        guard window.isKeyWindow else {return false};return handleSearchKey32(event)
    }
    func handleSearchKey32(_ event:NSEvent)->Bool {
        guard !menuTracking,window.attachedSheet == nil,!isComposing32 else {return false}
        let mods=carbonModifiers(event.modifierFlags)
        if mods == Int(cmdKey),let index=[UInt16(18):0,19:1,20:2,21:3,23:4,22:5,26:6,28:7,25:8][event.keyCode] {
            pendingNavigation32=nil
            guard entries.indices.contains(index) else {return true}
            table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);table.scrollRowToVisible(index);openSelected();return true
        }
        if dispatchOperationShortcut(event) {return true}
        if mods == Int(cmdKey),event.keyCode == 36 {revealSelectedFiles();return true}
        if mods == Int(cmdKey),event.keyCode == 4 {showRecentSearches();return true}
        if mods == Int(cmdKey),event.keyCode == 123 {goBack();return true}
        if mods == Int(cmdKey),event.keyCode == 124,selected?.directory == true {searchSelectedFolder32();return true}
        if [125,126].contains(event.keyCode),mods == 0 || mods == Int(shiftKey),!entries.isEmpty {
            pendingNavigation32=nil
            let inTable=window.firstResponder === table
            let index=event.keyCode == 125 ? (inTable ? min(entries.count-1,max(0,table.selectedRow+1)) : max(0,table.selectedRow)) : max(0,table.selectedRow-1)
            window.makeFirstResponder(table);table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:event.modifierFlags.contains(.shift));table.scrollRowToVisible(index);return true
        }
        if event.keyCode == 53,mods == 0 {recentSearchTimer?.invalidate();window.orderOut(nil);return true}
        if window.firstResponder === table,mods == 0 {
            if event.keyCode == 49 {quickLook();return true}
            if event.keyCode == 36 {openSelected();return true}
        }
        return false
    }
    func pushNavigation32() {
        navigationHistory32.append(SearchNavigation32(self));if navigationHistory32.count > 30 {navigationHistory32.removeFirst()};pendingNavigation32=nil
    }
    @objc func searchSelectedFolder32() {
        guard let selected,selected.directory else {return}
        let term=search.stringValue
        browse(selected.url)
        search.stringValue=term
        if !term.isEmpty {startSearch()}
        window.makeFirstResponder(search);search.selectText(nil)
    }
    func restoreNavigation32(_ snapshot:SearchNavigation32) {
        stopQuery();pendingNavigation32=nil;tagFilter=snapshot.tag;preferences.set(tagFilter,forKey:"tagFilter")
        let state=snapshot.state
        if let filter=state["filter"] as? Int {fileFilter=FileFilter(rawValue:filter) ?? .all;filterPicker.selectItem(at:fileFilter.rawValue)}
        dateFilter=state["dateFilter"] as? Int ?? 0;sizeFilter=state["sizeFilter"] as? Int ?? 0;dateField=state["dateField"] as? Int ?? 0
        customStart=state["customStart"] as? Date ?? customStart;customEnd=state["customEnd"] as? Date ?? customEnd
        precision=SearchPrecision(rawValue:state["searchPrecision"] as? Int ?? 1) ?? .fuzzyName;searchMode=SearchMode(rawValue:state["searchMode"] as? Int ?? 0) ?? .filename
        scopeAll=state["all"] as? Bool ?? true;folder=URL(fileURLWithPath:state["folder"] as? String ?? NSHomeDirectory());savedScopeOverride=scopeAll ? state["roots"] as? [String] : nil
        if scopeAll { if scopePicker.numberOfItems > 7 {scopePicker.removeItem(at:7)};scopePicker.selectItem(at:0) };updateSearchModeUI();search.stringValue=state["query"] as? String ?? "";showingRecent=snapshot.recent;updateFilterSummary()
        if !search.stringValue.isEmpty {startSearch()}
        else if let collection=snapshot.collection {loadLocalCollection(collection)}
        else if snapshot.recent {loadRecent()}
        else {browse(folder,push:false)}
        entries=snapshot.entries.filter{FileManager.default.fileExists(atPath:$0.url.path)};refreshList();snapshot.position.restore(self);tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification))
        if query != nil || scanningNames {pendingNavigation32=snapshot.position}
        saveState();window.makeFirstResponder(search)
    }
    func paletteShortcuts32()->[String:String] {
        let commands:[OperationCommand:Selector]=[.actions:#selector(openActions),.ocr:#selector(openOCRManager),.archive:#selector(openArchiveSearch),.batch:#selector(openBatchRename),.undo:#selector(undoFileOperation),.updates:#selector(checkForUpdates),.clipboard:#selector(openClipboardHistory32),.duplicates:#selector(openDuplicateFinder),.diagnostics:#selector(openSearchDiagnosis32),.ocrText:#selector(openOCRText32)]
        var result:[String:String]=[:]
        for binding in operationBindings where binding.enabled {if let selector=commands[binding.command] {result[NSStringFromSelector(selector)]=binding.label}}
        result[NSStringFromSelector(#selector(searchSelectedFolder32))]="⌘→";result[NSStringFromSelector(#selector(goBack))]="⌘←";result[NSStringFromSelector(#selector(revealSelectedFiles))]="⌘↵";result[NSStringFromSelector(#selector(showQuickLook))]="空格"
        return result
    }
    @objc func showAdvancedSearchHelp32() {
        let alert=NSAlert();alert.messageText="高级搜索语法";alert.informativeText="\"年度合同\"：连续文字，按原文匹配\n合同 -草稿：排除包含“草稿”的结果\next:pdf 合同：只查找 PDF\next:pdf,docx：允许多个扩展名\n\n可和“最近7天”“大于10MB”“tag:工作”等筛选组合。名称模式匹配文件名；路径模式也匹配目录；内容模式匹配正文。引号中的日期词按普通文字搜索。\n⌘1–9 打开前九项，⌘→ 在所选文件夹继续搜索，⌘← 返回原搜索。";alert.beginSheetModal(for:window)
    }
    func add32Actions(_ menu:NSMenu) {
        let items:[(String,Selector,Bool)]=[("剪贴板历史…",#selector(openClipboardHistory32),true),("漏搜诊断与目录修复…",#selector(openSearchDiagnosis32),true),("高级搜索语法…",#selector(showAdvancedSearchHelp32),true),("在所选文件夹继续搜索",#selector(searchSelectedFolder32),selected?.directory == true),("返回上一搜索位置",#selector(goBack),!navigationHistory32.isEmpty),("查看 / 复制 / 导出 OCR 文字…",#selector(openOCRText32),currentOCRRecord32 != nil),("查找内容相同的文件…",#selector(openDuplicateFinder),true)]
        for (title,selector,enabled) in items {let item=NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target=self;item.isEnabled=enabled;menu.addItem(item)}
        menu.addItem(.separator())
    }
    func openPalette32() {
        if paletteController32 == nil {paletteController32=CommandPalette32(execute:{[weak self] item in guard let self,let action=item.action else{return};self.window.makeKeyAndOrderFront(nil);NSApp.sendAction(action,to:item.target,from:item)})}
        paletteController32?.show(PaletteCommand32.flatten(makeActionMenu32(),shortcuts:paletteShortcuts32()))
    }
}

final class ComposingText32:NSTextView { var composing=true;override func hasMarkedText()->Bool {composing} }
extension App {
    func release32UI() {
        let root=make31Fixture();let fm=FileManager.default
        try! fm.createDirectory(at:root.appendingPathComponent("乐乐"),withIntermediateDirectories:true)
        try! Data("年度合同正文".utf8).write(to:root.appendingPathComponent("乐乐/年度合同.txt"))
        clipboardManager32=ClipboardHistory32(pasteboard:NSPasteboard(name:NSPasteboard.Name("com.kongfetch.qa32.ui."+UUID().uuidString)),store:ClipboardStore32(root.appendingPathComponent(".clipboard")),preferences:preferences)
        searchMode = .filename;precision = .fuzzyName;updateSearchModeUI();search.stringValue="乐乐";startSearch();show()
    }
    func release32Check() {
        let root=make31Fixture(),fm=FileManager.default
        do {
            try runSearch32Checks(root:root)
            try runDuplicateFinder32Checks()
            try checkClipboardAndOCR32(root)
            let names=["年度合同 final.pdf","年度合同 草稿.pdf","年度合同 final.txt"]
            for name in names {try Data("fixture".utf8).write(to:root.appendingPathComponent(name))}
            searchMode = .filename;precision = .fuzzyName;search.stringValue="ext:pdf \"年度合同\" -草稿"
            showingRecent=false;localCollection=nil;localMatches=names.map{Entry(root.appendingPathComponent($0))}
            _ = storeAlias(search.stringValue,url:root.appendingPathComponent(names[1]))
            renderSearchResults();precondition(entries.map{$0.url.lastPathComponent} == [names[0]])
            let positive=SearchInput("\"今天\" -草稿 ext:pdf",fallback:.all).advanced.positiveText32
            precondition(positive == "\"今天\"" && AdvancedSearchQuery(positive).natural.days == nil)
            let menu=makeActionMenu32(),palette=PaletteCommand32.flatten(menu,shortcuts:paletteShortcuts32())
            precondition(palette.contains{$0.title.contains("剪贴板历史")} && palette.contains{$0.title.contains("排序")})
            precondition(palette.first{$0.title.contains("剪贴板历史")}?.shortcut == "⌃⌥V")
            precondition(palette.first{$0.title.contains("复制完整路径")}?.enabled == true)
            precondition(palette.first{$0.title.contains("批量重命名") }?.score("piliang") != nil)
            let saved=captureSearch("QA 保存");preferences.set([saved],forKey:"savedSearches")
            precondition(PaletteCommand32.flatten(makeActionMenu32()).contains{$0.title == "常用搜索 › QA 保存" && $0.item.representedObject != nil})
            let panel=CommandPalette32(execute:{_ in});panel.show(palette);panel.query.stringValue="剪贴板";panel.filter();precondition(panel.rows.count == 1);panel.panel.close()
            print("PASS 3.2 integration: aliases respect phrase/exclusion/extension constraints, quoted date survives Clear, searchable actions preserve enabled states, dynamic searches and shortcut labels")
            let items=root.appendingPathComponent("连续搜索");try fm.createDirectory(at:items,withIntermediateDirectories:true)
            for index in 0..<60 {try fm.createDirectory(at:items.appendingPathComponent(String(format:"乐乐-%02d",index)),withIntermediateDirectories:true)}
            navigationHistory32=[];browse(items,push:false);search.stringValue="乐乐";startSearch();show()
            let deadline=Date().addingTimeInterval(20)
            let timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) {[weak self] timer in
                guard let self else{return}
                if Date() > deadline {fatalError("3.2 parent name scan timeout")}
                guard !self.scanningNames,self.entries.count == 60 else{return};timer.invalidate()
                self.table.selectRowIndexes(IndexSet(integer:35),byExtendingSelection:false);self.table.scrollRowToVisible(35)
                let previous=SearchNavigation32(self),selected=self.selected!.url
                self.searchSelectedFolder32();precondition(self.folder == selected && self.search.stringValue == "乐乐" && self.navigationHistory32.count == 1)
                self.goBack();precondition(canonicalIndexPath(self.folder) == canonicalIndexPath(items),"parent directory");precondition(self.search.stringValue == "乐乐","parent query");precondition(self.selected?.url.path == selected.path,"parent selection");precondition(self.navigationHistory32.isEmpty,"parent history")
                let position=ListPosition32(self);precondition(position.top == previous.position.top && abs(position.offset-previous.position.offset) < 2)
                self.stopQuery();self.pendingNavigation32=nil
                let marked=ComposingText32(frame:NSRect(x:0,y:0,width:100,height:30));self.window.contentView!.addSubview(marked);self.window.makeFirstResponder(marked)
                let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:self.window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:125)!
                let row=self.table.selectedRow,generation=self.generation
                precondition(!self.handleSearchKey32(event));precondition(!self.control(self.search,textView:marked,doCommandBy:#selector(NSResponder.moveDown(_:))))
                self.startSearch();precondition(self.generation == generation && self.table.selectedRow == row)
                marked.composing=false;self.window.makeFirstResponder(nil);marked.removeFromSuperview();self.window.makeFirstResponder(self.search)
                let first=self.entries[0].url
                let command=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:self.window.windowNumber,context:nil,characters:"1",charactersIgnoringModifiers:"1",isARepeat:false,keyCode:18)!
                precondition(self.handleSearchKey32(command),"Command1 routed");precondition(self.folder.path == first.path,"Command1 folder")
                self.goBack();self.stopQuery();self.search.stringValue="ext:txt \"annual contract\" -draft";self.searchMode = .content;self.showingRecent=false
                let accepted=items.appendingPathComponent("OCR accepted.txt"),rejected=items.appendingPathComponent("OCR rejected.txt")
                try! Data("fixture".utf8).write(to:accepted);try! Data("fixture".utf8).write(to:rejected)
                for (url,text) in [(accepted,"Annual contract 2026"),(rejected,"Annual contract draft")] {let entry=Entry(url);self.ocrRecords[url.path]=OCRRecord(path:url.path,modified:entry.modified ?? .distantPast,size:entry.size,text:text,pages:1,limited:false)}
                self.localMatches=[];self.spotlightMatches=[];self.updateOCRMatches()
                let bodyDeadline=Date().addingTimeInterval(10)
                Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) {[weak self] timer in
                    guard let self else{return};if Date() > bodyDeadline {fatalError("3.2 content filter timeout")}
                    guard !self.ocrMatches.isEmpty else{return};timer.invalidate();precondition(self.ocrMatches.map(\.url) == [accepted])
                    precondition(self.entries.map(\.url) == [accepted]);self.stopQuery()
                    print("PASS 3.2 navigation/keyboard: folder search + Back restores query, selection and scroll; marked IME input untouched; Command1 opens first folder; local OCR body phrase/exclusion/ext filters")
                    print("PASS release 3.2 checks");fflush(stdout);NSApp.terminate(nil)
                }
            }
            RunLoop.main.add(timer,forMode:.common)
        } catch {print("FAIL 3.2: "+error.localizedDescription);fflush(stdout);exit(1)}
    }
}

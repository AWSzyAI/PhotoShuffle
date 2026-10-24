import AppKit
import Photos
import CoreGraphics
import ServiceManagement
import QuartzCore

struct ShuffleDeck {
    var order: [Int] = []
    var cursor = -1
    var last: Int?
    mutating func reset(_ count: Int) { order = Array(0..<count); cursor = -1; last = nil }
    mutating func next() -> Int? {
        guard !order.isEmpty else { return nil }
        if cursor + 1 >= order.count || cursor < 0 {
            order.shuffle()
            if order.count > 1, order.first == last { order.swapAt(0, 1) }
            cursor = 0
        } else { cursor += 1 }
        last = order[cursor]
        return last
    }
}
struct ReservedIndex { let index: Int; let position: Int }
struct ReservationOrder {
    var deck = ShuffleDeck()
    var returned: [ReservedIndex] = []
    mutating func reset(_ count: Int) { deck.reset(count); returned = [] }
    mutating func take() -> ReservedIndex? {
        if !returned.isEmpty { return returned.removeFirst() }
        guard let index = deck.next() else { return nil }
        return ReservedIndex(index: index, position: deck.cursor + 1)
    }
    mutating func putBack(_ items: [ReservedIndex]) { returned.insert(contentsOf: items, at: 0) }
    mutating func take(avoiding blocked: Set<Int>) -> ReservedIndex? {
        var unique = Set<Int>()
        returned = returned.filter { unique.insert($0.index).inserted }
        if let position = returned.firstIndex(where: { !blocked.contains($0.index) }) { return returned.remove(at: position) }
        guard !deck.order.isEmpty, blocked.count < deck.order.count else { return nil }
        // Do not wait for another display to finish its round (it may be waiting on us).
        // A deferred asset gets priority as soon as free, and is stored only once even
        // if several shuffle rounds pass while another screen holds that photograph.
        for _ in 0..<deck.order.count {
            guard let index = deck.next() else { break }
            let candidate = ReservedIndex(index: index, position: deck.cursor + 1)
            if !blocked.contains(index) { return candidate }
            if !returned.contains(where: { $0.index == index }) { returned.append(candidate) }
        }
        return nil
    }

}
struct DisplayPhotoClaims {
    var visible: [String: Int] = [:]
    var incoming: [String: Int] = [:]
    func blocked(for owner: String, assetCount: Int, displayCount: Int) -> Set<Int> {
        guard assetCount >= displayCount else { return [] }
        return Set(visible.filter { $0.key != owner }.map { $0.value } + incoming.filter { $0.key != owner }.map { $0.value })
    }
    mutating func claim(_ index: Int, for owner: String, assetCount: Int, displayCount: Int) -> Bool {
        guard !blocked(for: owner, assetCount: assetCount, displayCount: displayCount).contains(index) else { return false }
        incoming[owner] = index; return true
    }
    mutating func commit(for owner: String) { if let index = incoming.removeValue(forKey: owner) { visible[owner] = index } }
    mutating func cancel(for owner: String) { incoming.removeValue(forKey: owner) }
    mutating func remove(_ owner: String) { visible.removeValue(forKey: owner); incoming.removeValue(forKey: owner) }
}
func displayIsEnabled(_ id: String, preferences: [String: Bool]) -> Bool { preferences[id] ?? true }
func displayKey(_ screen: NSScreen) -> String {
    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() { return CFUUIDCreateString(nil, uuid) as String }
    // CG display IDs can change; the UUID above is the persistent preference key.
    return "display-\(id)"
}
final class PreparedPhoto {
    let reserved: ReservedIndex
    var image: NSImage?
    var error: String?
    var request = PHInvalidImageRequestID
    var timeout: DispatchWorkItem?
    init(_ reserved: ReservedIndex) { self.reserved = reserved }
}
func photoURL(album: String, asset: String) -> URL? {
    var c = URLComponents(); c.scheme = "photos"; c.path = "albums"
    c.queryItems = [URLQueryItem(name: "albumUuid", value: String(album.split(separator: "/").first ?? "")), URLQueryItem(name: "assetUuid", value: String(asset.split(separator: "/").first ?? "")), URLQueryItem(name: "source", value: "widget")]
    return c.url
}
func shouldStart(authorized: Bool, enabled: Bool, locked: Bool, asleep: Bool, photosActive: Bool, idle: Double, threshold: Double, cooldown: Double) -> Bool {
    authorized && enabled && !locked && !asleep && !photosActive && idle >= threshold && cooldown >= threshold
}
func selfTest() {
    for n in [0, 1, 2, 17, 500] {
        var d = ShuffleDeck(); d.reset(n)
        if n == 0 { precondition(d.next() == nil); continue }
        var previous: Int?
        for _ in 0..<20 {
            var seen = Set<Int>()
            for _ in 0..<n {
                let v = d.next()!
                precondition(v >= 0 && v < n && seen.insert(v).inserted)
                if n > 1 { precondition(previous != v) }
                previous = v
            }
            precondition(seen.count == n)
        }
    }
    for count in [1,2,17,100] {
        var source = ReservationOrder(); source.reset(count)
        var queue: [ReservedIndex] = []
        var values: [Int] = []
        for step in 0..<(count * 8) {
            while queue.count < 3 { queue.append(source.take()!) }
            if step % 7 == 0 {
                // Simulate selecting B, then cancelling before display while C/D are reserved.
                let uncommitted = queue.removeFirst(); source.putBack([uncommitted] + queue); queue = []
                while queue.count < 3 { queue.append(source.take()!) }
            }
            values.append(queue.removeFirst().index)
        }
        for start in stride(from: 0, to: values.count, by: count) { precondition(Set(values[start..<start+count]).count == count) }
        if count > 1 { for i in 1..<values.count { precondition(values[i] != values[i-1]) } }
    }
    // Paused screens and overlapping rounds never grow an unbounded deferred queue.
    for count in [1, 2, 17] {
        var source = ReservationOrder(); source.reset(count)
        for _ in 0..<100 {
            let item = source.take(avoiding: Set([0]))
            if count == 1 { precondition(item == nil) } else { precondition(item != nil && item!.index != 0) }
            precondition(source.returned.count <= 1)
        }
        // Deferred photos regain priority as soon as another screen releases them.
        if count > 1 { precondition(source.take(avoiding: [])!.index == 0) }
        precondition(source.take(avoiding: []) != nil)
    }
    var claims = DisplayPhotoClaims()
    precondition(claims.claim(0, for: "A", assetCount: 10, displayCount: 2)); claims.commit(for: "A")
    precondition(!claims.claim(0, for: "B", assetCount: 10, displayCount: 2))
    precondition(claims.claim(1, for: "B", assetCount: 10, displayCount: 2))
    precondition(!claims.claim(1, for: "A", assetCount: 10, displayCount: 2)) // pending dissolve protected
    claims.commit(for: "B")
    precondition(claims.claim(2, for: "A", assetCount: 10, displayCount: 2))
    precondition(claims.blocked(for: "B", assetCount: 10, displayCount: 2) == Set([0, 2]))
    claims.cancel(for: "A")
    precondition(claims.blocked(for: "B", assetCount: 10, displayCount: 2) == Set([0]))
    claims.remove("A"); precondition(claims.claim(0, for: "B", assetCount: 10, displayCount: 2))
    precondition(claims.claim(0, for: "C", assetCount: 1, displayCount: 2)) // impossible uniqueness degrades gracefully
    for assetCount in [2, 7, 100] {
        var coordinator = DisplayPhotoClaims()
        var orders = [ReservationOrder(), ReservationOrder()]
        orders[0].reset(assetCount); orders[1].reset(assetCount)
        for step in 0..<1000 {
            let owner = String(step % 2)
            let blocked = coordinator.blocked(for: owner, assetCount: assetCount, displayCount: 2)
            if let item = orders[step % 2].take(avoiding: blocked) {
                precondition(coordinator.claim(item.index, for: owner, assetCount: assetCount, displayCount: 2))
                let other = String(1 - step % 2)
                let mine = Set([coordinator.visible[owner], coordinator.incoming[owner]].compactMap { $0 })
                let theirs = Set([coordinator.visible[other], coordinator.incoming[other]].compactMap { $0 })
                precondition(mine.isDisjoint(with: theirs))
                if step % 11 == 0 { coordinator.cancel(for: owner); orders[step % 2].putBack([item]) }
                else { coordinator.commit(for: owner) }
            }
            precondition(orders[step % 2].returned.count <= assetCount + 1)
        }
        // Saving an order at stop and restoring it leaves its pending next asset intact.
        let pending = orders[0].take()!; orders[0].putBack([pending])
        let saved = orders[0]; var restored = saved
        precondition(restored.take()!.index == pending.index)
    }
    let preferences = ["UUID-A": false, "UUID-B": true]
    precondition(!displayIsEnabled("UUID-A", preferences: preferences))
    precondition(displayIsEnabled("UUID-B", preferences: preferences) && displayIsEnabled("new-display", preferences: preferences))
    // Reordering screens does not move an opt-out to a different UUID.
    precondition(["UUID-B", "UUID-A"].filter { displayIsEnabled($0, preferences: preferences) } == ["UUID-B"])
    let u = photoURL(album: "AB CD/L0/040", asset: "EF&GH/L0/001")!
    let q = URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!
    precondition(q[0].value == "AB CD" && q[1].value == "EF&GH" && !u.absoluteString.contains(" "))
    precondition(shouldStart(authorized: true, enabled: true, locked: false, asleep: false, photosActive: false, idle: 61, threshold: 60, cooldown: 61))
    for flag in 0..<5 {
        precondition(!shouldStart(authorized: flag != 0, enabled: flag != 1, locked: flag == 2, asleep: flag == 3, photosActive: flag == 4, idle: 61, threshold: 60, cooldown: 61))
    }
    precondition(!shouldStart(authorized: true, enabled: true, locked: false, asleep: false, photosActive: false, idle: 61, threshold: 60, cooldown: 0))
    // A denied status is deliberately handled by pure status logic; no Photos API is invoked here.
    precondition(![PHAuthorizationStatus.authorized, .limited].contains(.denied))
    print("自检通过：洗牌完整覆盖/轮内不重复/跨轮不相邻重复、预留3张/消费/归还无跳漏、URL编码、自动播放条件、未授权分支。多屏当前及渐变照片互斥/取消释放/图库不足降级/屏幕UUID偏好。未请求或读取图库。")
}

final class PlayerWindow: NSWindow {
    var keyHandler: ((UInt16) -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { keyHandler?(event.keyCode) }
}
final class MovingView: NSView {
    var moved: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { moved?() }
}
final class App: NSObject, NSApplicationDelegate, PHPhotoLibraryChangeObserver {
    let defaults = UserDefaults.standard
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var settings: NSWindow!
    var statusLabel = NSTextField(wrappingLabelWithString: "点击下方按钮，授权后读取图库。")
    var autoItem: NSMenuItem!
    var fetch: PHFetchResult<PHAsset>?
    var albumID = ""
    var players: [DisplayPlayer] = []
    var savedOrders: [String: ReservationOrder] = [:]
    var claims = DisplayPhotoClaims()
    var idleTriggered = false
    var displayStack: NSStackView!
    var settingsStack: NSStackView!
    var displayPreferences: [String: Bool] { defaults.dictionary(forKey: "enabledDisplays") as? [String: Bool] ?? [:] }
    var enabledScreens: [NSScreen] { NSScreen.screens.filter { displayIsEnabled(displayKey($0), preferences: displayPreferences) } }
    var transitionPopup: NSPopUpButton!
    var dockCheckbox: NSButton!
    var dockItem: NSMenuItem!
    var transitionSeconds: Double { get { defaults.object(forKey: "transitionSeconds") == nil ? 1 : defaults.double(forKey: "transitionSeconds") } set { defaults.set(newValue, forKey: "transitionSeconds"); refreshMenu() } }
    var showDock: Bool { get { defaults.object(forKey: "showDock") == nil ? true : defaults.bool(forKey: "showDock") } set { defaults.set(newValue, forKey: "showDock"); NSApp.setActivationPolicy(newValue ? .regular : .accessory); refreshMenu() } }
    var reading = false
    var libraryDirty = false
    var observingLibrary = false
    var locked = false
    var asleep = false
    var screensaverActive = false
    var automatic: Bool { get { defaults.bool(forKey: "automatic") } set { defaults.set(newValue, forKey: "automatic"); refreshMenu() } }
    var idleSeconds: Int { get { let v = defaults.integer(forKey: "idleSeconds"); return v > 0 ? v : 30 } set { defaults.set(newValue, forKey: "idleSeconds"); refreshMenu() } }
    var autoCheckbox: NSButton!
    var idlePopup: NSPopUpButton!
    var loginCheckbox: NSButton!
    var loginItem: NSMenuItem!
    var interval: Int { get { let v = defaults.integer(forKey: "interval"); return v > 0 ? v : 10 } set { defaults.set(newValue, forKey: "interval"); refreshMenu() } }
    var stoppedAt = Date()
    var idleTimer: Timer?
    var authorized: Bool { [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }
    var photosActive: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Photos" }
    func applicationDidFinishLaunching(_ notification: Notification) {
        locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        screensaverActive = NSWorkspace.shared.runningApplications.contains { ["com.apple.ScreenSaver.Engine", "com.apple.ScreenSaver.Engine.legacyScreenSaver"].contains($0.bundleIdentifier ?? "") }
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        buildMenu(); buildSettings(); buildMainMenu()
        if automatic && authorized { readLibrary() } else { showSettings() }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(activated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(self, selector: #selector(saverStarted), name: NSNotification.Name("com.apple.screensaver.didstart"), object: nil)
        dc.addObserver(self, selector: #selector(saverStopped), name: NSNotification.Name("com.apple.screensaver.didstop"), object: nil)
        dc.addObserver(self, selector: #selector(didLock), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dc.addObserver(self, selector: #selector(didUnlock), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkIdle() }
        // Launch never requests authorization or enumerates the library.
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    @objc func toggleDock() { showDock.toggle() }
    @objc func setTransition(_ sender: NSMenuItem) { transitionSeconds = Double(sender.tag) / 1000 }
    @objc func setPopupTransition(_ sender: NSPopUpButton) { transitionSeconds = Double(sender.selectedTag()) / 1000 }
    func item(_ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem { let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.tag = tag; return i }
    func buildMainMenu() {
        let main = NSMenu()
        let application = NSMenuItem(); let submenu = NSMenu(title: "照片随放")
        let quitItem = NSMenuItem(title: "退出照片随放", action: #selector(quit), keyEquivalent: "q"); quitItem.target = self
        submenu.addItem(quitItem); application.submenu = submenu; main.addItem(application); NSApp.mainMenu = main
    }
    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▧"
        statusItem.button?.toolTip = "照片随放"
        menu = NSMenu()
        menu.addItem(item("立即播放", #selector(play)))
        autoItem = item("自动播放", #selector(toggleAuto)); menu.addItem(autoItem)
        let idle = NSMenuItem(title: "空闲时间", action: nil, keyEquivalent: ""); let im = NSMenu()
        for v in [30,60,180,300,600] { im.addItem(item(v == 30 ? "30 秒" : "\(v / 60) 分钟", #selector(setIdle(_:)), tag: v)) }; idle.submenu = im; menu.addItem(idle)
        let change = NSMenuItem(title: "切换间隔", action: nil, keyEquivalent: ""); let cm = NSMenu()
        for v in [5,10,20,30] { cm.addItem(item("\(v) 秒", #selector(setInterval(_:)), tag: v)) }; change.submenu = cm; menu.addItem(change)
        let transition = NSMenuItem(title: "渐变时长", action: nil, keyEquivalent: ""); let tm = NSMenu()
        for value in [0,500,1000,1500,2000] { tm.addItem(item(value == 0 ? "关闭" : "\(Double(value) / 1000) 秒", #selector(setTransition(_:)), tag: value)) }; transition.submenu = tm; menu.addItem(transition)
        dockItem = item("在 Dock 中显示", #selector(toggleDock)); menu.addItem(dockItem)
        loginItem = item("登录时启动", #selector(toggleLogin)); menu.addItem(loginItem)
        menu.addItem(item("设置与图库状态", #selector(showSettings)))
        menu.addItem(item("重新读取图库", #selector(readLibrary)))
        menu.addItem(.separator()); menu.addItem(item("退出", #selector(quit)))
        statusItem.menu = menu; refreshMenu()
    }
    func refreshMenu() {
        guard menu != nil else { return }; autoItem.state = automatic ? .on : .off
        autoCheckbox?.state = automatic ? .on : .off
        idlePopup?.selectItem(withTag: idleSeconds)
        transitionPopup?.selectItem(withTag: Int(transitionSeconds * 1000))
        dockItem?.state = showDock ? .on : .off; dockCheckbox?.state = showDock ? .on : .off
        let loginEnabled = SMAppService.mainApp.status == .enabled
        loginItem?.state = loginEnabled ? .on : .off; loginCheckbox?.state = loginEnabled ? .on : .off
        for i in menu.items { if let sub = i.submenu { for j in sub.items { j.state = j.tag == (i.title == "空闲时间" ? idleSeconds : (i.title == "渐变时长" ? Int(transitionSeconds * 1000) : interval)) ? .on : .off } } }
    }
    func buildSettings() {
        settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 580), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.title = "照片随放"; settings.isReleasedWhenClosed = false; settings.center()
        let title = NSTextField(labelWithString: "让整个图库，一张张随机遇见。")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "首次默认关闭自动播放。授权后可立即播放，或在菜单栏开启空闲自动播放。照片按需加载。系统授予照片读写权限，但本工具代码只读取，不修改图库。系统屏保、锁屏或睡眠可中止展示。\nEsc 结束 · 空格暂停 · ← → 切图 · O / 回车打开照片")
        let auth = NSButton(title: "授权并读取图库", target: self, action: #selector(authorize))
        let start = NSButton(title: "立即播放", target: self, action: #selector(play))
        let quitButton = NSButton(title: "退出照片随放", target: self, action: #selector(quit))
        let actions = NSStackView(views: [start, quitButton]); actions.spacing = 12
        autoCheckbox = NSButton(checkboxWithTitle: "空闲自动播放", target: self, action: #selector(toggleAuto))
        autoCheckbox.state = automatic ? .on : .off
        idlePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for v in [30,60,180,300,600] { idlePopup.addItem(withTitle: v == 30 ? "30 秒" : "\(v / 60) 分钟"); idlePopup.lastItem?.tag = v }
        idlePopup.selectItem(withTag: idleSeconds); idlePopup.target = self; idlePopup.action = #selector(setPopupIdle(_:))
        let row = NSStackView(views: [autoCheckbox, NSTextField(labelWithString: "空闲"), idlePopup]); row.spacing = 12
        loginCheckbox = NSButton(checkboxWithTitle: "登录时启动", target: self, action: #selector(toggleLogin))
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        transitionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for value in [0,500,1000,1500,2000] { transitionPopup.addItem(withTitle: value == 0 ? "关闭" : "\(Double(value) / 1000) 秒"); transitionPopup.lastItem?.tag = value }
        transitionPopup.selectItem(withTag: Int(transitionSeconds * 1000)); transitionPopup.target = self; transitionPopup.action = #selector(setPopupTransition(_:))
        let transitionRow = NSStackView(views: [NSTextField(labelWithString: "照片渐变"), transitionPopup]); transitionRow.spacing = 12
        dockCheckbox = NSButton(checkboxWithTitle: "在 Dock 中显示", target: self, action: #selector(toggleDock)); dockCheckbox.state = showDock ? .on : .off
        displayStack = NSStackView(); displayStack.orientation = .vertical; displayStack.alignment = .leading; displayStack.spacing = 6
        let stack = NSStackView(views: [title, help, statusLabel, auth, row, transitionRow, dockCheckbox, loginCheckbox, NSTextField(labelWithString: "选择播放屏幕（各自随机播放不同照片）"), displayStack, actions]); settingsStack = stack; stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        settings.contentView!.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: settings.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: settings.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: settings.contentView!.topAnchor, constant: 24), stack.bottomAnchor.constraint(lessThanOrEqualTo: settings.contentView!.bottomAnchor, constant: -24), help.widthAnchor.constraint(equalTo: stack.widthAnchor), statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        help.preferredMaxLayoutWidth = 472; statusLabel.preferredMaxLayoutWidth = 472
        rebuildDisplayOptions()
        settings.contentView!.layoutSubtreeIfNeeded()
        settings.setContentSize(NSSize(width: 520, height: max(520, stack.fittingSize.height + 48))); settings.center()
    }
    @objc func showSettings() { if !players.isEmpty { stop() }; NSApp.activate(ignoringOtherApps: true); settings.makeKeyAndOrderFront(nil) }
    @objc func authorize() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in DispatchQueue.main.async { self?.readLibrary() } }
    }
    @objc func readLibrary() {
        guard authorized else { statusLabel.stringValue = "尚未获准读取。请点“授权并读取图库”；若曾拒绝，请在系统设置 → 隐私与安全性 → 照片中允许。"; showSettings(); return }
        guard !reading else { return }
        libraryDirty = false
        if !observingLibrary { PHPhotoLibrary.shared().register(self); observingLibrary = true }
        stop(); reading = true; statusLabel.stringValue = "正在读取图库索引（不下载照片）…"
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions(); options.includeAssetSourceTypes = [.typeUserLibrary]; options.includeHiddenAssets = false; options.includeAllBurstAssets = true
            let result = PHAsset.fetchAssets(with: .image, options: options)
            let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
            let id = albums.firstObject?.localIdentifier ?? ""
            DispatchQueue.main.async {
                self.reading = false
                guard self.authorized else { self.fetch = nil; self.statusLabel.stringValue = "照片访问权限已关闭。"; return }
                self.fetch = result; self.albumID = id; self.claims = DisplayPhotoClaims(); self.savedOrders = [:]
                self.statusLabel.stringValue = "图库可访问照片：\(result.count) 张。自动播放\(self.automatic ? "已开启" : "已关闭")。"
            }
        }
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            guard let current = self.fetch, changeInstance.changeDetails(for: current) != nil else { return }
            self.libraryDirty = true
            // Preserve the currently displayed image; refresh metadata after playback ends.
            if self.players.isEmpty && !self.reading && self.authorized { self.readLibrary() }
        }
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            statusLabel.stringValue = SMAppService.mainApp.status == .requiresApproval ? "登录时启动需要在系统设置 → 通用 → 登录项中允许。" : "登录时启动设置已更新。"
        } catch { statusLabel.stringValue = "无法更新登录时启动：\(error.localizedDescription)。请先把应用放到 Applications 文件夹。" }
        refreshMenu()
    }
    @objc func toggleAuto() { automatic.toggle(); stoppedAt = Date() }
    @objc func setIdle(_ sender: NSMenuItem) { idleSeconds = sender.tag; stoppedAt = Date() }
    @objc func setPopupIdle(_ sender: NSPopUpButton) { idleSeconds = sender.selectedTag(); stoppedAt = Date() }
    @objc func setInterval(_ sender: NSMenuItem) { interval = sender.tag; players.forEach { $0.scheduleSlide() } }
    @objc func quit() { stop(); NSApp.terminate(nil) }
    @objc func willSleep() { asleep = true; stop() }
    @objc func didWake() { asleep = false; stoppedAt = Date() }
    @objc func saverStarted() { screensaverActive = true; stop() }
    @objc func saverStopped() { screensaverActive = false; stoppedAt = Date() }
    @objc func didLock() { locked = true; stop() }
    @objc func didUnlock() { locked = false; stoppedAt = Date() }
    @objc func activated(_ n: Notification) { if photosActive { stop() } }
    @objc func displaysChanged() {
        stop(); rebuildDisplayOptions()
        statusLabel.stringValue = "显示器配置已变化，已安全结束播放。下次播放按新的屏幕选择启动。"
    }
    func rebuildDisplayOptions() {
        displayStack.arrangedSubviews.forEach { displayStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, screen) in NSScreen.screens.enumerated() {
            let button = NSButton(checkboxWithTitle: "屏幕 \(index + 1)：\(screen.localizedName)（\(Int(screen.frame.width)) × \(Int(screen.frame.height))）", target: self, action: #selector(toggleDisplay(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(displayKey(screen))
            button.state = displayIsEnabled(displayKey(screen), preferences: displayPreferences) ? .on : .off
            displayStack.addArrangedSubview(button)
        }
        settings.contentView!.layoutSubtreeIfNeeded()
        settings.setContentSize(NSSize(width: 520, height: max(520, settingsStack.fittingSize.height + 48)))
    }
    @objc func toggleDisplay(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var preferences = displayPreferences; preferences[id] = sender.state == .on
        defaults.set(preferences, forKey: "enabledDisplays"); stop()
        statusLabel.stringValue = enabledScreens.isEmpty ? "尚未选择播放屏幕。勾选至少一块屏幕后再播放。" : "播放屏幕已更新，下次播放生效。"
    }
    var canRevealPlayer: Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        return authorized && !locked && !asleep && !screensaverActive && !photosActive && (!idleTriggered || (automatic && idle >= Double(idleSeconds)))
    }
    func checkIdle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        if !players.isEmpty && (!authorized || photosActive || (players.allSatisfy { $0.player?.isVisible == false } && idleTriggered && idle < Double(idleSeconds))) { stop(); statusLabel.stringValue = "照片准备已取消，等待下一次空闲。" }
        guard players.isEmpty, fetch != nil, !reading, !screensaverActive, !enabledScreens.isEmpty else { return }
        if libraryDirty && authorized { readLibrary(); return }
        if shouldStart(authorized: authorized, enabled: automatic, locked: locked, asleep: asleep, photosActive: photosActive, idle: idle, threshold: Double(idleSeconds), cooldown: Date().timeIntervalSince(stoppedAt)) { beginPlayback(automatically: true) }
    }
    @objc func play() { beginPlayback(automatically: false) }
    func beginPlayback(automatically: Bool) {
        guard authorized else { statusLabel.stringValue = "请先授权并读取图库。"; showSettings(); return }
        guard !locked, !asleep, !photosActive, !screensaverActive, players.isEmpty else { return }
        guard let result = fetch, result.count > 0 else { statusLabel.stringValue = reading ? "正在读取图库，请稍候。" : "请先点击“授权并读取图库”，确认图库中有可访问照片。"; showSettings(); return }
        if libraryDirty { readLibrary(); return }
        let screens = enabledScreens
        guard !screens.isEmpty else { statusLabel.stringValue = "尚未选择播放屏幕。请至少勾选一块屏幕。"; showSettings(); return }
        idleTriggered = automatically; claims = DisplayPhotoClaims()
        players = screens.map { DisplayPlayer(app: self, screen: $0, count: result.count) }
        settings.orderOut(nil)
        players.forEach { $0.start() }
    }
    @objc func stop() {
        let stopped = players; players = []; stopped.forEach { $0.stop() }
        claims = DisplayPhotoClaims(); stoppedAt = Date()
        if libraryDirty && authorized && !reading { DispatchQueue.main.async { [weak self] in guard let self = self, self.players.isEmpty, self.libraryDirty, !self.reading else { return }; self.readLibrary() } }
    }
}

final class DisplayPlayer: NSObject {
    unowned let app: App
    let screen: NSScreen
    let id: String
    var reservationOrder = ReservationOrder()
    var future: [PreparedPhoto] = []
    var activePrepared: PreparedPhoto?
    var pendingHistoryIndex: Int?
    var selectedPosition = 0
    var playbackSession = 0
    var history: [Int] = []
    var historyCursor = -1
    var currentAsset: PHAsset?
    var player: PlayerWindow?
    var imageView: NSImageView!
    var transitionLayer: NSView?
    var transitioning = false
    var openButton: NSButton!
    var controls: NSStackView!
    var caption: NSTextField!
    var pauseButton: NSButton!
    var paused = false
    var loading = false
    var slideTimer: Timer?
    var hideTimer: Timer?
    var timeout: DispatchWorkItem?
    var request: PHImageRequestID = PHInvalidImageRequestID
    var generation = 0
    let manager = PHImageManager.default()
    var fetch: PHFetchResult<PHAsset>? { app.fetch }
    var authorized: Bool { app.authorized }
    var transitionSeconds: Double { app.transitionSeconds }
    var interval: Int { app.interval }
    var statusLabel: NSTextField { app.statusLabel }
    var albumID: String { app.albumID }
    init(app: App, screen: NSScreen, count: Int) {
        self.app = app; self.screen = screen; self.id = displayKey(screen); super.init()
        if let saved = app.savedOrders[id] { reservationOrder = saved } else { reservationOrder.reset(count) }
    }
    func showSettings() { app.showSettings() }
    @objc func endPlayback() { app.stop() }
    func start() {
        let w = PlayerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.level = .normal; w.backgroundColor = .black; w.isReleasedWhenClosed = false; w.acceptsMouseMovedEvents = true
        w.collectionBehavior = [.fullScreenAuxiliary]
        let root = MovingView(frame: NSRect(origin: .zero, size: screen.frame.size)); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.black.cgColor
        imageView = NSImageView(frame: root.bounds); imageView.autoresizingMask = [.width, .height]; imageView.imageScaling = .scaleProportionallyUpOrDown; root.addSubview(imageView)
        caption = NSTextField(labelWithString: "正在加载…"); caption.textColor = .white; caption.font = .systemFont(ofSize: 14, weight: .medium)
        pauseButton = NSButton(title: "暂停", target: self, action: #selector(togglePause))
        openButton = NSButton(title: "在照片中打开", target: self, action: #selector(openPhoto))
        controls = NSStackView(views: [caption, NSButton(title: "上一张", target: self, action: #selector(previous)), pauseButton, NSButton(title: "下一张", target: self, action: #selector(nextPhoto)), openButton, NSButton(title: "结束", target: self, action: #selector(endPlayback))])
        controls.orientation = .horizontal; controls.spacing = 12
        controls.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        for case let button as NSButton in controls.arrangedSubviews { button.font = .systemFont(ofSize: 14, weight: .medium); button.bezelStyle = .rounded; button.contentTintColor = .white }
         controls.wantsLayer = true; controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor; controls.layer?.cornerRadius = 12
        root.addSubview(controls); controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([controls.centerXAnchor.constraint(equalTo: root.centerXAnchor), controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24), controls.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32)])
        root.moved = { [weak self] in
            guard let self = self, self.player?.isVisible == true else { return }
            self.player?.makeKey(); self.showControls()
        }
        w.contentView = root; w.keyHandler = { [weak self] key in
            switch key { case 53: self?.endPlayback(); case 49: self?.togglePause(); case 123: self?.previous(); case 124: self?.nextPhoto(); case 31,36,76: self?.openPhoto(); default: break }
        }
        player = w; paused = false; statusLabel.stringValue = "正在准备照片（已就绪 0 / 3），准备好后开始展示。可随时点结束或退出。"; showControls(); advance(failures: 0)
    }
    func showControls() {
        controls?.isHidden = false; hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in if self?.loading == false { self?.controls?.isHidden = true } }
    }
    func cancelRequest(returnPrepared: Bool = true) {
        app.claims.cancel(for: id)
        generation += 1; timeout?.cancel(); timeout = nil
        if let active = activePrepared {
            if returnPrepared {
                // An uncommitted image belongs before every later reservation, even on history navigation.
                reservationOrder.putBack([active.reserved] + future.map { $0.reserved })
                future.forEach(cancelPrepared); future = []
            }
            cancelPrepared(active)
        }
        activePrepared = nil; pendingHistoryIndex = nil
        transitionLayer?.layer?.removeAllAnimations(); transitionLayer?.removeFromSuperview(); transitionLayer = nil; transitioning = false
        openButton?.isEnabled = currentAsset != nil
        if request != PHInvalidImageRequestID { manager.cancelImageRequest(request); request = PHInvalidImageRequestID }
        slideTimer?.invalidate(); slideTimer = nil; loading = false
    }
    func stop() {
        let unshown = (activePrepared.map { [$0.reserved] } ?? []) + future.map { $0.reserved }
        reservationOrder.putBack(unshown); app.savedOrders[id] = reservationOrder
        playbackSession += 1
        future.forEach(cancelPrepared); future = []
        cancelRequest(returnPrepared: false); hideTimer?.invalidate(); player?.orderOut(nil); player = nil; currentAsset = nil; imageView?.image = nil
        app.claims.remove(id)
    }
    @objc func togglePause() { paused.toggle(); pauseButton?.title = paused ? "继续" : "暂停"; if paused { slideTimer?.invalidate() } else { scheduleSlide() }; showControls() }
    @objc func previous() {
        guard historyCursor > 0 else { return }; historyCursor -= 1; load(history[historyCursor], failures: 0)
    }
    @objc func nextPhoto() { advance(failures: 0) }
    func advance(failures: Int) {
        guard player != nil, authorized else { app.stop(); return }
        if historyCursor + 1 < history.count { historyCursor += 1; load(history[historyCursor], failures: failures); return }
        cancelRequest()
        let blocked = app.claims.blocked(for: id, assetCount: fetch?.count ?? 0, displayCount: app.players.count)
        let unavailable = future.filter { blocked.contains($0.reserved.index) }
        future.removeAll { blocked.contains($0.reserved.index) }
        reservationOrder.putBack(unavailable.map { $0.reserved }); unavailable.forEach(cancelPrepared)
        fillPrefetch()
        guard !future.isEmpty else {
            caption.stringValue = "等待另一块屏幕切换…"; showControls()
            let token = generation
            slideTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                guard let self = self, self.generation == token, self.player != nil else { return }
                self.advance(failures: failures)
            }
            return
        }
        let prepared = future.removeFirst(); activePrepared = prepared; selectedPosition = prepared.reserved.position
        pendingHistoryIndex = prepared.reserved.index; loading = true
        caption.stringValue = "下一张准备中 · 已预备 \(future.filter { $0.image != nil }.count) / 3"; showControls()
        deliverPrepared(prepared, failures: failures)
    }
    func targetSize() -> NSSize {
        let screen: NSScreen? = self.screen
        let width = (screen?.frame.width ?? 1920) * (screen?.backingScaleFactor ?? 1)
        let height = (screen?.frame.height ?? 1080) * (screen?.backingScaleFactor ?? 1)
        let scale = min(1, 2560 / max(width, height))
        return NSSize(width: width * scale, height: height * scale)
    }
    func cancelPrepared(_ prepared: PreparedPhoto) {
        prepared.timeout?.cancel(); prepared.timeout = nil
        if prepared.request != PHInvalidImageRequestID { manager.cancelImageRequest(prepared.request); prepared.request = PHInvalidImageRequestID }
        prepared.image = nil
    }
    func nextReservation() -> ReservedIndex? {
        guard let result = fetch else { return nil }
        let blocked = app.claims.blocked(for: id, assetCount: result.count, displayCount: app.players.count)
        return reservationOrder.take(avoiding: blocked)
    }
    func fillPrefetch() {
        guard player != nil, let result = fetch else { return }
        while future.count + (activePrepared == nil ? 0 : 1) < 3 {
            guard let reserved = nextReservation() else { break }
            let prepared = PreparedPhoto(reserved); future.append(prepared)
            let session = playbackSession
            let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true; options.deliveryMode = .highQualityFormat; options.resizeMode = .exact
            let timeout = DispatchWorkItem { [weak self, weak prepared] in
                guard let self = self, let prepared = prepared, self.playbackSession == session else { return }
                if prepared.request != PHInvalidImageRequestID { self.manager.cancelImageRequest(prepared.request); prepared.request = PHInvalidImageRequestID }
                prepared.error = "照片准备超过 45 秒"; self.preparedChanged(prepared)
            }
            prepared.timeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
            prepared.request = manager.requestImage(for: result.object(at: reserved.index), targetSize: targetSize(), contentMode: .aspectFit, options: options) { [weak self, weak prepared] image, info in
                DispatchQueue.main.async {
                    guard let self = self, let prepared = prepared, self.playbackSession == session,
                          self.activePrepared === prepared || self.future.contains(where: { $0 === prepared }) else { return }
                    if (info?[PHImageCancelledKey] as? Bool) == true || (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    prepared.timeout?.cancel(); prepared.timeout = nil; prepared.request = PHInvalidImageRequestID
                    if let image = image, info?[PHImageErrorKey] == nil {
                        // Materialize the requested screen-size image, rather than just a cache hint.
                        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { prepared.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) } else { prepared.image = image }
                    } else { prepared.error = "无法准备这张照片" }
                    self.preparedChanged(prepared)
                }
            }
        }
    }
    var preparedFailures = 0
    func preparedChanged(_ prepared: PreparedPhoto) {
        if player?.isVisible == false {
            let count = future.filter { $0.image != nil }.count + (activePrepared?.image == nil ? 0 : 1)
            statusLabel.stringValue = "正在准备照片（已就绪 \(count) / 3），首张准备好后开始展示。"
        }
        if activePrepared === prepared { deliverPrepared(prepared, failures: preparedFailures) }
    }
    func deliverPrepared(_ prepared: PreparedPhoto, failures: Int) {
        preparedFailures = failures
        guard activePrepared === prepared, let result = fetch else { return }
        if let image = prepared.image {
            loading = false; present(image, asset: result.object(at: prepared.reserved.index), token: generation, total: result.count)
        } else if let error = prepared.error { failed(token: generation, failures: failures, reason: error) }
    }
    func load(_ index: Int, failures: Int) {
        cancelRequest()
        // History navigation releases future images before loading its incoming image.
        // Keep their reservations so the normal sequence resumes without omissions.
        reservationOrder.putBack(future.map { $0.reserved }); future.forEach(cancelPrepared); future = []
        guard let result = fetch, index < result.count else { return }
        let asset = result.object(at: index); loading = true
        openButton.isEnabled = currentAsset != nil
        let token = generation
        caption.stringValue = "正在加载下一张 · 全库 \(result.count) 张 · 本轮 \(selectedPosition)/\(result.count)"; showControls()
        let opts = PHImageRequestOptions(); opts.isNetworkAccessAllowed = true; opts.deliveryMode = .highQualityFormat; opts.resizeMode = .exact
        let size = targetSize()
        let work = DispatchWorkItem { [weak self] in self?.failed(token: token, failures: failures, reason: "加载超过 45 秒（可能正在从 iCloud 获取）") }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
        request = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: opts) { [weak self] image, info in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token, self.player != nil else { return }
                if (info?[PHImageCancelledKey] as? Bool) == true { return }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard let image = image, info?[PHImageErrorKey] == nil else { self.failed(token: token, failures: failures, reason: "无法加载此照片"); return }
                self.timeout?.cancel(); self.timeout = nil; self.request = PHInvalidImageRequestID; self.loading = false
                self.present(image, asset: asset, token: token, total: result.count)
            }
        }
    }
    func present(_ image: NSImage, asset: PHAsset, token: Int, total: Int) {
        guard let index = fetch?.index(of: asset), index != NSNotFound else { return }
        guard app.claims.claim(index, for: id, assetCount: total, displayCount: app.players.count) else {
            // Another display changed while this photo loaded. Keep the old frame and wait;
            // no conflicting photo is made visible, including during dissolve or history.
            caption.stringValue = "等待另一块屏幕切换…"; showControls()
            slideTimer?.invalidate()
            slideTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                guard let self = self, self.generation == token, self.player != nil else { return }
                if self.activePrepared != nil { self.advance(failures: self.preparedFailures) }
                else { self.present(image, asset: asset, token: token, total: total) }
            }
            return
        }
        let finish: () -> Void = { [weak self] in
            guard let self = self, self.generation == token, self.player != nil else { return }
            if self.player?.isVisible == false {
                guard self.app.canRevealPlayer else { self.app.stop(); self.statusLabel.stringValue = "照片准备已取消。"; return }
            }
            self.app.claims.commit(for: self.id)
            self.imageView.image = image; self.currentAsset = asset
            if let index = self.pendingHistoryIndex {
                self.history.append(index); self.historyCursor = self.history.count - 1
                if self.history.count > 200 { self.history.removeFirst(); self.historyCursor -= 1 }
            }
            self.pendingHistoryIndex = nil; self.activePrepared = nil
            if self.player?.isVisible == false {
                let anotherVisible = self.app.players.contains { $0 !== self && $0.player?.isVisible == true }
                NSApp.activate(ignoringOtherApps: true)
                if anotherVisible { self.player?.orderFront(nil) } else { self.player?.makeKeyAndOrderFront(nil) }
                self.statusLabel.stringValue = "已在 \(self.app.players.count) 块屏幕分别随机播放；每屏提前准备 3 张。"
            }
            self.fillPrefetch()
            self.transitionLayer?.removeFromSuperview(); self.transitionLayer = nil; self.transitioning = false; self.openButton.isEnabled = true
            let date = asset.creationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? "日期未知"
            self.caption.stringValue = "\(date) · 全库 \(total) 张 · 本轮 \(self.selectedPosition)/\(total)"
            self.scheduleSlide(); self.showControls()
        }
        guard currentAsset != nil, transitionSeconds > 0, let root = imageView.superview else { finish(); return }
        let overlay = NSView(frame: root.bounds); overlay.autoresizingMask = [.width, .height]; overlay.wantsLayer = true; overlay.layer?.backgroundColor = NSColor.black.cgColor
        let nextImage = NSImageView(frame: overlay.bounds); nextImage.autoresizingMask = [.width, .height]; nextImage.imageScaling = .scaleProportionallyUpOrDown; nextImage.image = image; overlay.addSubview(nextImage)
        overlay.alphaValue = 0; root.addSubview(overlay, positioned: .above, relativeTo: imageView)
        transitionLayer = overlay; transitioning = true; openButton.isEnabled = false; caption.stringValue = "切换中…"; showControls()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = self.transitionSeconds; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlay.animator().alphaValue = 1
        }, completionHandler: finish)
    }
    func failed(token: Int, failures: Int, reason: String) {
        guard generation == token, player != nil else { return }
        if player?.isVisible == false {
            cancelRequest(returnPrepared: false) // Explicitly skip a failed first reservation.
            app.stop(); statusLabel.stringValue = "首张照片未能准备好：\(reason)。请检查网络或重新播放。"; showSettings(); return
        }
        // Failed reservations are explicitly skipped; ordinary cancellation always returns them.
        cancelRequest(returnPrepared: false)
        let limit = min(fetch?.count ?? 0, 5)
        if failures + 1 >= limit {
            paused = true; pauseButton.title = "继续"; caption.stringValue = "连续加载失败：\(reason)。可点“下一张”跳过或结束。"; showControls(); return
        }
        caption.stringValue = "\(reason)，2 秒后跳过…"; showControls()
        let nextToken = generation
        slideTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in guard let self = self, self.generation == nextToken else { return }; self.advance(failures: failures + 1) }
    }
    func scheduleSlide() {
        slideTimer?.invalidate(); slideTimer = nil
        guard player != nil, !loading, !transitioning, !paused else { return }
        slideTimer = Timer.scheduledTimer(withTimeInterval: Double(interval), repeats: false) { [weak self] _ in self?.advance(failures: 0) }
    }
    @objc func openPhoto() {
        guard !transitioning, let asset = currentAsset else { return }
        guard !albumID.isEmpty, let url = photoURL(album: albumID, asset: asset.localIdentifier) else { caption.stringValue = "未找到系统图库标识，无法定位。"; showControls(); return }
        app.stop()
        if !NSWorkspace.shared.open(url) { statusLabel.stringValue = "系统未能打开照片链接。请手动在“照片”中查找。"; showSettings() }
    }
}
if CommandLine.arguments.contains("--self-test") { selfTest(); exit(0) }
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(delegate.showDock ? .regular : .accessory)
app.run()

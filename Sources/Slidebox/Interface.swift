import AppKit
import ServiceManagement
import WebKit

final class ActionButton: NSButton, NSDraggingSource {
    var usesExactBounds = false
    override var alignmentRectInsets: NSEdgeInsets { usesExactBounds ? NSEdgeInsetsZero : super.alignmentRectInsets }
    static let siteType = NSPasteboard.PasteboardType("local.slidebox.site")
    var siteID: UUID? {
        didSet { if siteID != nil { registerForDraggedTypes([Self.siteType]) } }
    }
    var reorder: ((UUID, UUID) -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard let siteID else { super.mouseDown(with: event); return }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { performClick(nil) }
                return
            }
            if hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) < 4 { continue }
            let pasteboard = NSPasteboardItem(); pasteboard.setString(siteID.uuidString, forType: Self.siteType)
            let item = NSDraggingItem(pasteboardWriter: pasteboard)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: next, source: self)
            return
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let value = sender.draggingPasteboard.string(forType: Self.siteType), let id = UUID(uuidString: value), id != siteID else { return [] }
        highlight(true); return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(false)
        guard let target = siteID, let value = sender.draggingPasteboard.string(forType: Self.siteType), let source = UUID(uuidString: value), source != target else { return false }
        reorder?(source, target); return true
    }
    var actionBlock: (() -> Void)?
    init(_ title: String = "", symbol: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; self.actionBlock = action
        target = self; self.action = #selector(invoke)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageOnly; isBordered = false
        } else {
            isBordered = true
            bezelStyle = .rounded
        }
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { actionBlock?() }
}

final class SlidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Accessory apps have no menu bar; support normal editing shortcuts explicitly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let selector = ["c": "copy:", "v": "paste:", "x": "cut:", "a": "selectAll:", "z": "undo:"][key] {
            return NSApp.sendAction(NSSelectorFromString(selector), to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class EdgeView: NSView {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let store: Store
    private var isolatedDefaultsName: String?
    private let pages = WebPages()
    private var updates: AppUpdates!
    private weak var updateStatus: NSTextField?
    private weak var updateCheckButton: NSButton?
    private weak var updateRevealButton: NSView?
    private var panel: SlidePanel!
    private var rail: SidebarSurface!
    private let railEdge = NSBox()
    private var railContents = FlippedView()
    private var siteScroll: NSScrollView!
    private var siteList: NSView!
    private var railTools: NSStackView!
    private var railDivider: NSBox!
    private var settingsOverlay: GlassSurface?
    private var settingsScroll: NSScrollView?
    private var addOverlay: GlassSurface?
    private var addScroll: NSScrollView?
    private var positionButtons: [ToolbarPosition: ActionButton] = [:]
    private var content: NSView!
    private var edges: [NSPanel] = []
    private var hover: DispatchWorkItem?
    private var monitors: [Any] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var visible = false
    private var transition = 0
    private var screen: NSScreen?
    private var editing: UUID?
    private var addressInput: NSTextField?
    private var nameInput: NSTextField?
    private var formError: NSTextField?
    private var loginStatus: NSTextField?
    private var sleepInput: NSTextField?
    private var clearingCache = false
    private weak var cacheButton: NSButton?
    private var spinner: NSProgressIndicator?
    private var previewBox: NSBox?
    private var previewTitle: NSTextField?
    private var previewDomain: NSTextField?
    private var previewIcon: NSImageView?

    override init() {
        // Checks and previews never alter the installed application's preferences.
        if CommandLine.arguments.contains("--layout-self-test") || (CommandLine.arguments.contains("--ui-preview") || Bundle.main.bundleIdentifier == "local.slidebox.glass-preview") {
            let name = "local.slidebox.check.\(ProcessInfo.processInfo.processIdentifier)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            store = Store(defaults: defaults)
            updates = AppUpdates(defaults: defaults)
            isolatedDefaultsName = name
        } else { store = Store(); updates = AppUpdates() }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--update-network-self-test") || CommandLine.arguments.contains("--web-self-test") || CommandLine.arguments.contains("--memory-self-test") || CommandLine.arguments.contains("--browser-self-test") || CommandLine.arguments.contains("--data-self-test") {
            Task { @MainActor in
                do {
                    if CommandLine.arguments.contains("--update-network-self-test") { try await runUpdateNetworkChecks() }
                    else if CommandLine.arguments.contains("--data-self-test") { try await runDataChecks() }
                    else if CommandLine.arguments.contains("--browser-self-test") { try await runBrowserChecks() }
                    else if CommandLine.arguments.contains("--memory-self-test") { try await runMemoryChecks() }
                    else { try await runWebChecks(); print("PASS: real WebKit lifecycle checks") }
                    exit(0)
                }
                catch { fputs("WebKit check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        SiteIcons.shared.changed = { [weak self] in
            self?.refreshSiteIcons()
            self?.updatePreview()
        }
        updates.changed = { [weak self] in self?.refreshUpdateStatus() }
        makeWindow()
        pages.configureSleep(enabled: store.preferences.sleepEnabled, seconds: store.preferences.sleepSeconds)
        if CommandLine.arguments.contains("--layout-self-test") {
            exit(runLayoutChecks() ? 0 : 1)
        }
        if (CommandLine.arguments.contains("--ui-preview") || Bundle.main.bundleIdentifier == "local.slidebox.glass-preview") {
            NSApp.setActivationPolicy(.regular)
            store.preferences.pinned = true
            store.sites = [Site(name: "DeepSeek", url: URL(string: "https://chat.deepseek.com")!), Site(name: "ChatGPT", url: URL(string: "https://chatgpt.com")!)]
            renderRail()
            if let screen = NSScreen.main { show(on: screen) }
            panel.title = "Slidebox — 本地设计预览"
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil); showAdd()
            return
        }
        updates.check()
        rebuildEdges()
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screensChanged() }
        })
        notificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pages.expire(); self?.screensChanged() }
        })
        notificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide(animated: false) }
        })
        if CommandLine.arguments.contains("--preview"), let screen = NSScreen.main {
            show(on: screen)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updates.stop()
        hover?.cancel(); removeMonitors(); pages.dispose()
        edges.forEach { $0.close() }
        notificationTokens.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        clearCheckDefaults()
    }

    private func clearCheckDefaults() {
        if let name = isolatedDefaultsName { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    }

    private func makeWindow() {
        panel = SlidePanel(contentRect: NSRect(x: 0, y: 0, width: store.preferences.width, height: store.preferences.height), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = "Slidebox"; panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isMovable = false; panel.hasShadow = true
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 360, height: 300)
        let root = SurfaceView(color: .clear)
        root.layer?.cornerRadius = 10; root.layer?.masksToBounds = true
        panel.contentView = root
        root.showsResizeCursor = true
        rail = SidebarSurface()
        rail.addSubview(railContents)
        railEdge.boxType = .separator; rail.addSubview(railEdge)
        rail.setAccessibilityLabel("网站工具栏")
        content = SurfaceView(color: .textBackgroundColor)
        content.wantsLayer = true; content.layer?.masksToBounds = true
        root.addSubview(content); root.addSubview(rail)
        renderRail()
    }

    private func rebuildEdges() {
        hover?.cancel()
        edges.forEach { $0.close() }; edges.removeAll()
        for display in NSScreen.screens {
            // The actual screen edge triggers it; avoid the menu bar and lower hot corner.
            let frame = NSRect(x: display.frame.maxX - 2, y: display.visibleFrame.minY + 8, width: 2, height: max(1, display.visibleFrame.height - 16))
            let edge = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            edge.setAccessibilityElement(false)
            edge.isReleasedWhenClosed = false; edge.isOpaque = false; edge.backgroundColor = .clear
            edge.hasShadow = false; edge.hidesOnDeactivate = false; edge.level = .statusBar
            edge.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
            let view = EdgeView(frame: NSRect(origin: .zero, size: frame.size))
            view.entered = { [weak self] in
                guard let self, NSEvent.pressedMouseButtons == 0 else { return }
                self.hover?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.show(on: display) }
                self.hover = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
            view.exited = { [weak self] in self?.hover?.cancel() }
            edge.contentView = view; edge.orderFrontRegardless(); edges.append(edge)
        }
    }

    private func screensChanged() {
        rebuildEdges()
        if visible, let display = NSScreen.screens.first(where: { $0 == screen }) ?? NSScreen.main {
            screen = display; panel.setFrame(panelFrame(on: display), display: true)
        }
    }

    private func panelFrame(on screen: NSScreen) -> NSRect {
        let bounds = screen.visibleFrame
        panel.maxSize = NSSize(width: bounds.width - 12, height: bounds.height - 16)
        let width = min(store.preferences.width, bounds.width - 12)
        let height = min(store.preferences.height, bounds.height - 16)
        return NSRect(x: bounds.maxX - width - 6, y: bounds.midY - height / 2, width: width, height: height)
    }

    private func show(on screen: NSScreen) {
        hover?.cancel()
        if visible {
            if self.screen != screen { self.screen = screen; panel.setFrame(panelFrame(on: screen), display: true) }
            return
        }
        self.screen = screen; visible = true; transition += 1
        let destination = panelFrame(on: screen)
        panel.setFrame(destination.offsetBy(dx: destination.width, dy: 0), display: false)
        renderWebsite()
        panel.orderFrontRegardless()
        animate(to: destination)
        installMonitors()
    }

    private func animate(to frame: NSRect, completion: (@MainActor @Sendable () -> Void)? = nil) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true); completion?(); return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }

    private func hide(animated: Bool = true) {
        guard visible else { return }
        closeSettings()
        visible = false; transition += 1
        spinner?.stopAnimation(nil)
        let token = transition
        pages.suspendActive(); removeMonitors()
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, !self.visible, self.transition == token else { return }
            self.panel.orderOut(nil)
        }
        if animated { animate(to: panel.frame.offsetBy(dx: panel.frame.width + 12, dy: 0), completion: finish) }
        else { finish() }
    }

    private func installMonitors() {
        removeMonitors()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in self?.outsideClick() }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    if self.settingsOverlay != nil { self.closeSettings(); return nil }
                    if self.addOverlay != nil { self.closeAdd(); return nil }
                }
                return event
            }
            if event.window == self.panel, let overlay = self.settingsOverlay ?? self.addOverlay {
                let point = self.panel.contentView!.convert(event.locationInWindow, from: nil)
                let buttons = self.railContents.convert(self.railContents.bounds, to: self.panel.contentView)
                if !overlay.frame.contains(point) && !buttons.contains(point) {
                    if self.settingsOverlay != nil { self.closeSettings() } else { self.closeAdd() }
                }
            }
            if event.window != self.panel { self.outsideClick() }
            return event
        }) { monitors.append(monitor) }
    }

    private func outsideClick() {
        guard visible, !store.preferences.pinned, panel.attachedSheet == nil,
              !panel.frame.contains(NSEvent.mouseLocation) else { return }
        hide()
    }
    private func removeMonitors() { monitors.forEach(NSEvent.removeMonitor); monitors.removeAll() }

    func windowDidEndLiveResize(_ notification: Notification) {
        var preferences = store.preferences
        preferences.width = panel.frame.width; preferences.height = panel.frame.height
        store.preferences = preferences
    }

    func windowDidResize(_ notification: Notification) {
        if siteScroll != nil { layoutChrome() }
    }

    private func railButton(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, symbol: symbol, action: action)
        button.usesExactBounds = true
        button.toolTip = title; button.translatesAutoresizingMaskIntoConstraints = false
        button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        button.wantsLayer = true; button.layer?.cornerRadius = 14; button.layer?.masksToBounds = true
        (button.cell as? NSButtonCell)?.highlightsBy = [.contentsCellMask]
        button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 28)])
        return button
    }

    private func renderRail() {
        railContents.subviews.forEach { $0.removeFromSuperview() }
        let vertical = store.preferences.toolbarPosition.isVertical
        siteList = FlippedView()
        for (index, site) in store.sites.enumerated() {
            let selected = site.id == store.selected
            let button = railButton(site.name, symbol: "globe", selected: selected) { [weak self] in self?.select(site.id) }
            button.image = siteIcon(site.url); button.imageScaling = .scaleProportionallyDown
            button.translatesAutoresizingMaskIntoConstraints = true
            button.frame = NSRect(x: vertical ? 0 : CGFloat(index) * 34, y: vertical ? CGFloat(index) * 34 : 0, width: 28, height: 28)
            button.siteID = site.id
            button.reorder = { [weak self] source, target in
                guard let self else { return }
                self.store.sites = reorderedSites(self.store.sites, source: source, target: target)
                self.renderRail()
            }
            let menu = NSMenu()
            for (title, action) in [("回到设定页面", #selector(returnToSite(_:))), ("编辑网站", #selector(editSite(_:))), (vertical ? "上移" : "前移", #selector(moveUp(_:))), (vertical ? "下移" : "后移", #selector(moveDown(_:))), ("在默认浏览器打开", #selector(openSite(_:))), ("删除网站", #selector(deleteSite(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.representedObject = site.id.uuidString; menu.addItem(item)
            }
            button.menu = menu; siteList.addSubview(button)
        }
        // Only websites scroll; collapse/add/settings remain reachable at every size.
        siteScroll = NSScrollView(); siteScroll.drawsBackground = false
        siteScroll.hasVerticalScroller = false; siteScroll.hasHorizontalScroller = false
        siteScroll.documentView = siteList
        railTools = NSStackView(); railTools.orientation = vertical ? .vertical : .horizontal
        railTools.spacing = 6
        railTools.addArrangedSubview(railButton("收起", symbol: "play.fill") { [weak self] in self?.hide() })
        railTools.addArrangedSubview(railButton("添加网站", symbol: "plus.circle", selected: addOverlay != nil && settingsOverlay == nil) { [weak self] in self?.showAdd() })
        let settings = railButton("设置", symbol: "slider.horizontal.3", selected: settingsOverlay != nil) { [weak self] in self?.showSettings() }
        railTools.addArrangedSubview(settings)
        railDivider = NSBox(); railDivider.boxType = .separator
        for view in [siteScroll!, railDivider!, railTools!] { railContents.addSubview(view) }
        updateRailSelection()
        layoutChrome()
    }

    private func layoutChrome() {
        guard let root = panel.contentView, siteScroll != nil else { return }
        let bounds = root.bounds, position = store.preferences.toolbarPosition
        let vertical = position.isVertical
        let edge: CGRectEdge
        switch position {
        case .left: edge = .minXEdge
        case .right: edge = .maxXEdge
        case .top: edge = .maxYEdge
        case .bottom: edge = .minYEdge
        }
        let regions = bounds.divided(atDistance: 32, from: edge)
        rail.frame = regions.slice; content.frame = regions.remainder
        let natural = max(0, CGFloat(store.sites.count) * 34 - 6)
        let gap: CGFloat = store.sites.isEmpty ? 0 : 18
        let length = min(natural + gap + 108, (vertical ? bounds.height : bounds.width) - 16)
        let siteLength = max(0, length - 108 - gap)
        railContents.frame = vertical
            ? NSRect(x: 0, y: rail.bounds.midY - length / 2, width: 32, height: length)
            : NSRect(x: rail.bounds.midX - length / 2, y: 0, width: length, height: 32)
        railEdge.frame = vertical
            ? NSRect(x: position == .left ? rail.bounds.width - 1 : 0, y: 0, width: 1, height: rail.bounds.height)
            : NSRect(x: 0, y: position == .bottom ? rail.bounds.height - 1 : 0, width: rail.bounds.width, height: 1)
        rail.layoutSubtreeIfNeeded()
        siteScroll.frame = NSRect(x: vertical ? 2 : 6, y: vertical ? 6 : 2, width: vertical ? 28 : siteLength, height: vertical ? siteLength : 28)
        siteList.frame = NSRect(x: 0, y: 0, width: vertical ? 28 : natural, height: vertical ? natural : 28)
        siteScroll.isHidden = store.sites.isEmpty; railDivider.isHidden = store.sites.isEmpty
        railDivider.frame = vertical ? NSRect(x: 6, y: 6 + siteLength + 8, width: 20, height: 1) : NSRect(x: 6 + siteLength + 8, y: 6, width: 1, height: 20)
        railTools.frame = NSRect(x: vertical ? 2 : 6 + siteLength + gap, y: vertical ? 6 + siteLength + gap : 2, width: vertical ? 28 : 96, height: vertical ? 96 : 28)
        railTools.layoutSubtreeIfNeeded()
        layoutOverlays()
    }

    private func refreshSiteIcons() {
        for case let button as ActionButton in siteList.subviews {
            if let site = store.sites.first(where: { $0.id == button.siteID }) { button.image = siteIcon(site.url) }
        }
    }

    private func updateRailSelection() {
        for case let button as ActionButton in siteList.subviews {
            setRailSelection(button, selected: button.siteID == store.selected)
        }
        for (index, view) in railTools.arrangedSubviews.enumerated() {
            guard let button = view as? ActionButton else { continue }
            setRailSelection(button, selected: index == 1 ? addOverlay != nil && settingsOverlay == nil : index == 2 && settingsOverlay != nil)
            if index == 2 {
                button.toolTip = updates.downloadedURL == nil ? "设置" : "设置：新版本已下载"
                if updates.downloadedURL != nil { button.contentTintColor = .controlAccentColor }
            }
        }
    }

    private func setRailSelection(_ button: ActionButton, selected: Bool) {
        button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
    }

    private func clearContent() {
        spinner?.stopAnimation(nil)
        content.subviews.forEach { $0.removeFromSuperview() }
        spinner = nil
    }

    private func select(_ id: UUID) {
        closeSettings(); closeAdd()
        store.selected = id
        updateRailSelection(); renderWebsite()
    }
    private func renderCurrentPage() {
        closeSettings(); closeAdd()
        renderWebsite(); renderRail()
    }

    private func renderWebsite() {
        guard let site = store.sites.first(where: { $0.id == store.selected }) else {
            pages.suspendActive(); clearContent()
            let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 16
            stack.addArrangedSubview(label("Slidebox", size: 26, weight: .semibold))
            stack.addArrangedSubview(label("把常用网站放在手边", color: .secondaryLabelColor))
            stack.addArrangedSubview(ActionButton("添加网站") { [weak self] in self?.showAdd() })
            center(stack); return
        }
        let page = pages.activate(site)
        if page.view.superview === content { return }
        clearContent()
        page.failed = { [weak self] message in
            guard let self, self.visible, self.store.selected == site.id else { return }
            self.showWebError(message, site: site)
        }
        page.loadingChanged = { [weak self] loading in
            guard let self, self.store.selected == site.id else { return }
            self.spinner?.isHidden = !loading
            if loading { self.spinner?.startAnimation(nil) } else { self.spinner?.stopAnimation(nil) }
        }
        let web = page.view; web.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: content.leadingAnchor), web.trailingAnchor.constraint(equalTo: content.trailingAnchor), web.topAnchor.constraint(equalTo: content.topAnchor), web.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let progress = NSProgressIndicator(); progress.style = .spinning; progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(progress)
        NSLayoutConstraint.activate([progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), progress.topAnchor.constraint(equalTo: content.topAnchor, constant: 12)])
        progress.isHidden = !web.isLoading; if web.isLoading { progress.startAnimation(nil) }; spinner = progress
    }

    private func showWebError(_ message: String, site: Site) {
        clearContent()
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 14
        stack.addArrangedSubview(label("无法显示网页", size: 18, weight: .semibold))
        stack.addArrangedSubview(label(message, color: .secondaryLabelColor))
        stack.addArrangedSubview(ActionButton("重新打开") { [weak self] in self?.pages.remove(site.id); self?.renderWebsite() })
        stack.addArrangedSubview(ActionButton("在默认浏览器打开") { NSWorkspace.shared.open(site.url) })
        center(stack)
    }

    private func showAdd(_ id: UUID? = nil) {
        let wasSettings = settingsOverlay != nil
        closeSettings()
        if addOverlay != nil, editing == id {
            if !wasSettings { closeAdd() }
            return
        }
        closeAdd(); editing = id; renderAdd()
        panel.makeKey(); if let addressInput { panel.makeFirstResponder(addressInput) }
    }

    private func closeAdd() {
        guard let overlay = addOverlay else { return }
        panel.makeFirstResponder(nil)
        overlay.removeFromSuperview(); addOverlay = nil; addScroll = nil; editing = nil
        addressInput = nil; nameInput = nil; formError = nil
        previewBox = nil; previewTitle = nil; previewDomain = nil; previewIcon = nil
        updateRailSelection()
        if let web = content.subviews.first(where: { $0 is WKWebView }) { panel.makeFirstResponder(web) }
    }

    private func renderAdd() {
        let id = editing
        closeSettings(); closeAdd(); editing = id
        let overlay = GlassSurface(radius: 18)
        overlay.setAccessibilityLabel(id == nil ? "添加网站" : "编辑网站")
        addOverlay = overlay; panel.contentView!.addSubview(overlay)
        let (scroll, stack) = overlayStack(in: overlay)
        addScroll = scroll
        let site = store.sites.first { $0.id == editing }
        stack.addArrangedSubview(label(site == nil ? "添加网站" : "编辑网站", size: 18, weight: .semibold))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(label("网站地址"))
        let address = NSTextField(string: site?.url.absoluteString ?? "")
        address.bezelStyle = .roundedBezel
        address.controlSize = .large; address.font = .systemFont(ofSize: 14)
        address.setAccessibilityLabel("网站地址"); stack.addArrangedSubview(glassInput(address)); addressInput = address
        address.delegate = self
        stack.addArrangedSubview(label("网站名称"))
        let name = NSTextField(string: site?.name ?? "")
        name.bezelStyle = .roundedBezel; name.font = .systemFont(ofSize: 14)
        name.controlSize = .large; name.setAccessibilityLabel("网站名称")
        stack.addArrangedSubview(glassInput(name)); nameInput = name
        name.delegate = self
        let preview = NSBox(); preview.boxType = .custom; preview.borderWidth = 1; preview.titlePosition = .noTitle
        preview.borderColor = .separatorColor; preview.cornerRadius = 6; preview.contentViewMargins = NSSize(width: 10, height: 10)
        let icon = NSImageView(); let title = label(""); let domain = label("", size: 12, color: .secondaryLabelColor)
        let words = NSStackView(views: [title, domain]); words.orientation = .vertical; words.alignment = .leading; words.spacing = 4
        let previewRow = NSStackView(views: [icon, words]); previewRow.orientation = .horizontal; previewRow.spacing = 12
        previewRow.alignment = .centerY
        previewRow.translatesAutoresizingMaskIntoConstraints = false; preview.contentView!.addSubview(previewRow)
        // NSBox's autoresized content view does not propagate its content's height.
        preview.heightAnchor.constraint(equalTo: previewRow.heightAnchor, constant: 22).isActive = true
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28), previewRow.leadingAnchor.constraint(equalTo: preview.contentView!.leadingAnchor), previewRow.trailingAnchor.constraint(equalTo: preview.contentView!.trailingAnchor), previewRow.topAnchor.constraint(equalTo: preview.contentView!.topAnchor), previewRow.bottomAnchor.constraint(equalTo: preview.contentView!.bottomAnchor)])
        previewBox = preview; previewIcon = icon; previewTitle = title; previewDomain = domain; stack.addArrangedSubview(preview)
        updatePreview()
        let error = label("", color: .systemRed); error.isHidden = true; stack.addArrangedSubview(error); formError = error
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10; buttons.distribution = .gravityAreas
        let cancel = ActionButton("取消") { [weak self] in
            self?.closeAdd()
        }
        let add = ActionButton(site == nil ? "添加" : "保存") { [weak self] in self?.saveSite() }
        add.keyEquivalent = "\r"; add.bezelColor = .controlAccentColor
        buttons.addView(glassControl(cancel, width: 72), in: .trailing); buttons.addView(glassControl(add, width: 72), in: .trailing); stack.addArrangedSubview(buttons)
        fillPageWidth(stack)
        updateRailSelection(); layoutOverlays()
    }

    private func saveSite() {
        guard let url = websiteURL(addressInput?.stringValue ?? "") else { showFormError("请输入有效的 HTTP 或 HTTPS 网址。"); return }
        let title = nameInput?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard title.count <= 100 else { showFormError("名称请保持在 100 个字符以内。"); return }
        if let editing, let index = store.sites.firstIndex(where: { $0.id == editing }) {
            pages.remove(editing); store.sites[index].url = url; store.sites[index].name = title.isEmpty ? defaultName(url) : title; renderRail(); select(editing)
        } else {
            let site = Site(name: title.isEmpty ? defaultName(url) : title, url: url)
            store.sites.append(site); renderRail(); select(site.id)
        }
    }

    private func showFormError(_ message: String) {
        formError?.stringValue = message; formError?.isHidden = false
        layoutOverlays()
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === addressInput || field === nameInput { updatePreview() }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === sleepInput { saveSleepSeconds(field) }
    }
    private func updatePreview() {
        defer { if addOverlay != nil { layoutOverlays() } }
        guard let url = websiteURL(addressInput?.stringValue ?? "") else { previewBox?.isHidden = true; return }
        previewBox?.isHidden = false
        let name = nameInput?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        previewTitle?.stringValue = name.isEmpty ? defaultName(url) : name
        previewDomain?.stringValue = url.host ?? ""
        previewIcon?.image = siteIcon(url)
    }
    private func defaultName(_ url: URL) -> String {
        switch url.host?.lowercased() {
        case "chat.deepseek.com": return "DeepSeek"
        case "chatgpt.com": return "ChatGPT"
        default: return url.host ?? "网站"
        }
    }
    private func siteIcon(_ url: URL) -> NSImage? {
        let name = url.host == "chat.deepseek.com" ? "deepseek" : (url.host == "chatgpt.com" ? "chatgpt" : "")
        guard let image = (SiteIcons.shared.image(for: url)
            ?? (name.isEmpty ? nil : NSImage(named: NSImage.Name(name)))
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "网站"))?.copy() as? NSImage else { return nil }
        let side = max(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        image.size = NSSize(width: image.size.width * 18 / side, height: image.size.height * 18 / side)
        return image
    }

    private func showSettings() {
        if settingsOverlay != nil { closeSettings(); return }
        renderSettings()
        panel.makeKey()
    }

    private func closeSettings() {
        guard let overlay = settingsOverlay else { return }
        // Commit the seconds field before removing its editor or changing placement.
        panel.makeFirstResponder(nil)
        overlay.removeFromSuperview(); settingsOverlay = nil
        settingsScroll = nil; positionButtons.removeAll()
        sleepInput = nil; loginStatus = nil; cacheButton = nil
        updateStatus = nil; updateCheckButton = nil; updateRevealButton = nil
        addOverlay?.isHidden = false
        updateRailSelection()
        if let web = content.subviews.first(where: { $0 is WKWebView }) { panel.makeFirstResponder(web) }
    }

    private func setToolbarPosition(_ position: ToolbarPosition) {
        panel.makeFirstResponder(nil)
        let changed = store.preferences.toolbarPosition != position
        if changed { store.preferences.toolbarPosition = position }
        for (value, button) in positionButtons {
            button.state = value == position ? .on : .off
            button.setAccessibilityValue(value == position ? 1 : 0)
            button.contentTintColor = value == position ? .controlAccentColor : .labelColor
            let background = button.superview
            background?.wantsLayer = true; background?.layer?.cornerRadius = 10
            background?.layer?.masksToBounds = true
            background?.layer?.backgroundColor = value == position ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
        }
        if changed { renderRail() } else { updateRailSelection() }
    }

    private func layoutOverlays() {
        if let overlay = addOverlay, let scroll = addScroll { layoutOverlay(overlay, scroll: scroll) }
        if let overlay = settingsOverlay, let scroll = settingsScroll { layoutOverlay(overlay, scroll: scroll) }
    }

    private func layoutOverlay(_ overlay: GlassSurface, scroll: NSScrollView) {
        let bounds = content.frame
        let width = min(280, bounds.width - 16)
        let availableHeight = bounds.height - 16
        // Measure at the constrained width so wrapped text determines the compact height.
        overlay.setFrameSize(NSSize(width: width, height: max(32, min(overlay.frame.height, availableHeight))))
        scroll.frame = overlay.bounds.insetBy(dx: 4, dy: 8)
        overlay.layoutSubtreeIfNeeded()
        let height = min(availableHeight, ceil(scroll.documentView?.fittingSize.height ?? availableHeight) + 16)
        var frame = NSRect(x: 0, y: 0, width: width, height: height)
        switch store.preferences.toolbarPosition {
        case .left: frame.origin = NSPoint(x: rail.frame.maxX + 8, y: bounds.midY - height / 2)
        case .right: frame.origin = NSPoint(x: rail.frame.minX - 8 - width, y: bounds.midY - height / 2)
        case .top: frame.origin = NSPoint(x: bounds.midX - width / 2, y: rail.frame.minY - 8 - height)
        case .bottom: frame.origin = NSPoint(x: bounds.midX - width / 2, y: rail.frame.maxY + 8)
        }
        frame.origin.x = max(bounds.minX + 8, min(frame.origin.x, bounds.maxX - width - 8))
        frame.origin.y = max(bounds.minY + 8, min(frame.origin.y, bounds.maxY - height - 8))
        overlay.frame = frame
        scroll.frame = overlay.bounds.insetBy(dx: 4, dy: 8)
        overlay.layoutSubtreeIfNeeded()
    }

    private func renderSettings() {
        closeSettings()
        addOverlay?.isHidden = true
        let overlay = GlassSurface(radius: 18)
        overlay.setAccessibilityLabel("设置")
        settingsOverlay = overlay; panel.contentView!.addSubview(overlay)
        let (scroll, stack) = overlayStack(in: overlay)
        settingsScroll = scroll
        stack.addArrangedSubview(label("设置", size: 18, weight: .semibold))
        stack.addArrangedSubview(label("工具栏位置", weight: .medium))
        let positions = NSStackView(); positions.orientation = .horizontal; positions.spacing = 8; positions.distribution = .fillEqually
        for position in ToolbarPosition.allCases {
            let button = ActionButton(position.title) { [weak self] in self?.setToolbarPosition(position) }
            button.image = NSImage(systemSymbolName: position.symbol, accessibilityDescription: nil)
            button.imagePosition = .imageAbove
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.setButtonType(.pushOnPushOff)
            button.font = .systemFont(ofSize: 12)
            (button.cell as? NSButtonCell)?.showsStateBy = []
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel("工具栏位置：" + position.title)
            positions.addArrangedSubview(glassControl(button, height: 46)); positionButtons[position] = button
        }
        stack.addArrangedSubview(positions)
        let divider = NSBox(); divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(divider)
        let login = NSSwitch(); login.target = self; login.action = #selector(toggleLogin(_:)); login.setAccessibilityLabel("登录时自动启动")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        stack.addArrangedSubview(row("登录时自动启动", trailing: glassControl(login, width: 48)))
        let status = label("", size: 11, color: .secondaryLabelColor); loginStatus = status
        status.isHidden = SMAppService.mainApp.status != .requiresApproval
        if !status.isHidden { status.stringValue = "请在系统设置的登录项中允许 Slidebox。" }
        stack.addArrangedSubview(status)
        let pin = NSSwitch(); pin.state = store.preferences.pinned ? .on : .off
        pin.target = self; pin.action = #selector(togglePin(_:)); pin.setAccessibilityLabel("固定侧栏")
        stack.addArrangedSubview(row("固定侧栏", trailing: glassControl(pin, width: 48)))
        section("网页休眠", in: stack)
        let sleep = NSSwitch(); sleep.state = store.preferences.sleepEnabled ? .on : .off
        sleep.target = self; sleep.action = #selector(toggleSleep(_:)); sleep.setAccessibilityLabel("自动休眠网页")
        stack.addArrangedSubview(row("自动休眠网页", trailing: glassControl(sleep, width: 48)))
        let seconds = NSTextField(string: String(store.preferences.sleepSeconds))
        seconds.alignment = .left; seconds.isBordered = false; seconds.drawsBackground = false
        seconds.font = .systemFont(ofSize: 13)
        seconds.setAccessibilityLabel("隐藏后等待秒数，1 至 86400")
        seconds.delegate = self; seconds.target = self; seconds.action = #selector(saveSleepSeconds(_:))
        seconds.isEnabled = store.preferences.sleepEnabled; sleepInput = seconds
        let input = glassInput(seconds)
        input.widthAnchor.constraint(equalToConstant: 76).isActive = true
        stack.addArrangedSubview(row("等待时间（秒）", trailing: input))
        section("缓存", in: stack)
        let clear = ActionButton(clearingCache ? "正在清理…" : "清理缓存") { [weak self] in self?.clearCache() }
        clear.isEnabled = !clearingCache; cacheButton = clear
        stack.addArrangedSubview(row("网页与图标缓存", trailing: glassControl(clear, width: 104)))
        section("软件更新", in: stack)
        let automatic = NSSwitch(); automatic.state = updates.enabled ? .on : .off
        automatic.target = self; automatic.action = #selector(toggleUpdates(_:)); automatic.setAccessibilityLabel("自动检查并下载更新")
        stack.addArrangedSubview(row("自动检查并下载", trailing: glassControl(automatic, width: 48)))
        let updateText = label(updates.message, size: 11, color: .secondaryLabelColor)
        updateStatus = updateText; stack.addArrangedSubview(updateText)
        let updateButtons = NSStackView(); updateButtons.orientation = .horizontal; updateButtons.spacing = 8
        let check = ActionButton("检查更新") { [weak self] in self?.updates.check(manual: true) }
        updateCheckButton = check; updateButtons.addArrangedSubview(glassControl(check, width: 100))
        let reveal = glassControl(ActionButton("显示安装包") { [weak self] in
            if let url = self?.updates.downloadedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }, width: 110)
        updateRevealButton = reveal; updateButtons.addArrangedSubview(reveal)
        stack.addArrangedSubview(updateButtons)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.distribution = .gravityAreas
        buttons.addView(glassControl(ActionButton("退出 Slidebox") { NSApp.terminate(nil) }, width: 118), in: .trailing)
        stack.addArrangedSubview(buttons)
        fillPageWidth(stack)
        setToolbarPosition(store.preferences.toolbarPosition)
        refreshUpdateStatus()
        layoutOverlays()
    }

    @objc private func toggleUpdates(_ sender: NSSwitch) { updates.setEnabled(sender.state == .on) }

    private func refreshUpdateStatus() {
        updateStatus?.stringValue = updates.message
        updateCheckButton?.isEnabled = !updates.busy
        updateRevealButton?.isHidden = updates.downloadedURL == nil
        updateRailSelection()
        if settingsOverlay != nil { layoutOverlays() }
    }

    private func overlayStack(in overlay: GlassSurface) -> (NSScrollView, NSStackView) {
        let scroll = NSScrollView(); scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        overlay.body.addSubview(scroll)
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12)
        ])
        return (scroll, stack)
    }

    private func glassInput(_ field: NSTextField) -> GlassSurface {
        let surface = GlassSurface(radius: 10)
        field.focusRingType = .none
        field.isBordered = false; field.drawsBackground = false
        field.translatesAutoresizingMaskIntoConstraints = false; surface.body.addSubview(field)
        NSLayoutConstraint.activate([
            surface.heightAnchor.constraint(equalToConstant: 28),
            field.leadingAnchor.constraint(equalTo: surface.body.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: surface.body.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: surface.body.centerYAnchor)
        ])
        return surface
    }

    private func glassControl(_ control: NSControl, width: CGFloat? = nil, height: CGFloat = 28) -> GlassSurface {
        let surface = GlassSurface(radius: 10)
        control.focusRingType = .none
        if let button = control as? ActionButton {
            button.isBordered = false; button.bezelStyle = .regularSquare
            button.usesExactBounds = true
            (button.cell as? NSButtonCell)?.highlightsBy = [.contentsCellMask]
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        surface.body.addSubview(control)
        surface.heightAnchor.constraint(equalToConstant: height).isActive = true
        if let width { surface.widthAnchor.constraint(equalToConstant: width).isActive = true }
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: surface.body.leadingAnchor, constant: 4),
            control.trailingAnchor.constraint(equalTo: surface.body.trailingAnchor, constant: -4),
            control.topAnchor.constraint(equalTo: surface.body.topAnchor, constant: 2),
            control.bottomAnchor.constraint(equalTo: surface.body.bottomAnchor, constant: -2)
        ])
        return surface
    }

    private func clearCache() {
        guard !clearingCache else { return }
        clearingCache = true; updateCacheButton("正在清理…")
        Task { @MainActor [self] in
            await pages.clearCache()
            clearingCache = false
            do {
                try SiteIcons.shared.clearCache()
                updateCacheButton("✓ 清理完成")
            } catch {
                updateCacheButton("清理失败，重试", help: error.localizedDescription)
            }
        }
    }

    private func updateCacheButton(_ title: String, help: String? = nil) {
        cacheButton?.title = title; cacheButton?.setAccessibilityLabel(title)
        cacheButton?.isEnabled = !clearingCache; cacheButton?.toolTip = help
    }

    @objc private func toggleLogin(_ sender: NSSwitch) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            let status = SMAppService.mainApp.status
            loginStatus?.stringValue = status == .requiresApproval ? "请在系统设置的登录项中允许 Slidebox。" : ""
            loginStatus?.isHidden = status != .requiresApproval
            sender.state = status == .enabled || status == .requiresApproval ? .on : .off
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            loginStatus?.stringValue = "操作失败：\(error.localizedDescription)"
            loginStatus?.isHidden = false
        }
    }
    @objc private func togglePin(_ sender: NSSwitch) { store.preferences.pinned = sender.state == .on }
    @objc private func toggleSleep(_ sender: NSSwitch) {
        store.preferences.sleepEnabled = sender.state == .on
        sleepInput?.isEnabled = store.preferences.sleepEnabled
        pages.configureSleep(enabled: store.preferences.sleepEnabled, seconds: store.preferences.sleepSeconds)
    }
    @objc private func saveSleepSeconds(_ sender: NSTextField) {
        guard let seconds = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), (1...86400).contains(seconds) else {
            sender.stringValue = String(store.preferences.sleepSeconds); NSSound.beep(); return
        }
        guard seconds != store.preferences.sleepSeconds else { return }
        store.preferences.sleepSeconds = seconds
        pages.configureSleep(enabled: store.preferences.sleepEnabled, seconds: seconds)
    }

    private func id(_ sender: NSMenuItem) -> UUID? { (sender.representedObject as? String).flatMap(UUID.init(uuidString:)) }
    @objc private func returnToSite(_ sender: NSMenuItem) {
        guard let id = id(sender), store.sites.contains(where: { $0.id == id }) else { return }
        pages.remove(id); select(id)
    }
    @objc private func editSite(_ sender: NSMenuItem) { if let id = id(sender) { showAdd(id) } }
    @objc private func openSite(_ sender: NSMenuItem) { if let site = store.sites.first(where: { $0.id == id(sender) }) { NSWorkspace.shared.open(site.url) } }
    @objc private func deleteSite(_ sender: NSMenuItem) {
        guard let id = id(sender), let index = store.sites.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "删除“\(store.sites[index].name)”？"; alert.informativeText = "仅从侧栏移除，网站的登录数据会保留。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.pages.remove(id); self.store.sites.removeAll { $0.id == id }
            if self.store.selected == id { self.store.selected = self.store.sites.first?.id }
            self.renderCurrentPage()
        }
    }
    @objc private func moveUp(_ sender: NSMenuItem) { move(sender, by: -1) }
    @objc private func moveDown(_ sender: NSMenuItem) { move(sender, by: 1) }
    private func move(_ sender: NSMenuItem, by offset: Int) {
        guard let index = store.sites.firstIndex(where: { $0.id == id(sender) }), store.sites.indices.contains(index + offset) else { return }
        store.sites.swapAt(index, index + offset); renderRail()
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.alignment = .left
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        field.maximumNumberOfLines = 0; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func row(_ title: String, trailing: NSView) -> NSView {
        let view = NSView(); let text = label(title)
        for item in [text, trailing] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([view.heightAnchor.constraint(greaterThanOrEqualToConstant: 28), text.leadingAnchor.constraint(equalTo: view.leadingAnchor), text.centerYAnchor.constraint(equalTo: view.centerYAnchor), trailing.trailingAnchor.constraint(equalTo: view.trailingAnchor), trailing.centerYAnchor.constraint(equalTo: view.centerYAnchor), text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8)])
        return view
    }
    private func section(_ title: String, in stack: NSStackView) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(12, after: last) }
        stack.addArrangedSubview(label(title, weight: .medium))
        let divider = NSBox(); divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(divider)
    }
    private func center(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: content.centerXAnchor), view.centerYAnchor.constraint(equalTo: content.centerYAnchor), view.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48)])
    }
    private func runLayoutChecks() -> Bool {
        defer { clearCheckDefaults() }
        for address in ["https://chat.deepseek.com", "https://chatgpt.com", "https://mail.google.com"] {
            guard let image = siteIcon(URL(string: address)!),
                  abs(max(image.size.width, image.size.height) - 18) < 0.01 else {
                print("FAIL: inconsistent site icon size"); return false
            }
        }
        print("PASS: website icons fit an 18pt box")
        for size in [NSSize(width: 360, height: 300), NSSize(width: 480, height: 680), NSSize(width: 720, height: 500)] {
            panel.setContentSize(size)
            layoutChrome()
            for settings in [false, true] {
                if settings { renderSettings() } else {
                    renderAdd()
                    addressInput?.stringValue = "https://mail.google.com/mail/u/0/#inbox"
                    nameInput?.stringValue = "GMail"
                    updatePreview()
                }
                panel.contentView!.layoutSubtreeIfNeeded()
                guard let scroll = settings ? settingsScroll : addScroll,
                      let document = scroll.documentView,
                      let stack = document.subviews.first as? NSStackView else { return false }
                let valid = document.frame.width > 250 && document.frame.height > 100
                    && stack.frame.width > 200 && stack.frame.height > 100
                print("Layout \(settings ? "settings" : "add") \(size): scroll=\(scroll.frame), document=\(document.frame), stack=\(stack.frame)")
                guard valid else { print("FAIL: form content is collapsed or outside the viewport"); return false }
                if settings {
                    let button = cacheButton!
                    clearingCache = true; updateCacheButton("正在清理…")
                    precondition(!button.isEnabled)
                    clearingCache = false; updateCacheButton("✓ 清理完成")
                    precondition(cacheButton === button && button.isEnabled && button.title == "✓ 清理完成")
                    precondition(button.accessibilityLabel() == button.title)
                    panel.contentView!.layoutSubtreeIfNeeded()
                }
                if !settings {
                    for field in [addressInput!, nameInput!] {
                        guard abs(field.frame.height - field.intrinsicContentSize.height) < 1 else {
                            print("FAIL: input height differs from native text-field height"); return false
                        }
                    }
                    let box = previewBox!
                    let icon = previewIcon!.convert(previewIcon!.bounds, to: box)
                    let title = previewTitle!.convert(previewTitle!.bounds, to: box)
                    let domain = previewDomain!.convert(previewDomain!.bounds, to: box)
                    let words = title.union(domain)
                    print("Preview: box=\(box.bounds), icon=\(icon), words=\(words)")
                    guard box.bounds.insetBy(dx: 8, dy: 8).contains(icon),
                          box.bounds.insetBy(dx: 8, dy: 8).contains(words),
                          abs(icon.midY - words.midY) < 1,
                          words.minX - icon.maxX >= 10 else {
                        print("FAIL: preview content is clipped or misaligned"); return false
                    }
                }
                if let output = ProcessInfo.processInfo.environment["SLIDEBOX_LAYOUT_OUTPUT"],
                   let bitmap = document.bitmapImageRepForCachingDisplay(in: document.bounds) {
                    document.cacheDisplay(in: document.bounds, to: bitmap)
                    do {
                        let directory = URL(fileURLWithPath: output, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let rendered = NSImage(size: document.bounds.size, flipped: false) { rect in
                            NSColor.textBackgroundColor.setFill(); rect.fill()
                            NSImage(cgImage: bitmap.cgImage!, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                            return true
                        }
                        try NSBitmapImageRep(data: rendered.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to:
                            directory.appendingPathComponent("\(settings ? "settings" : "add")-\(Int(size.width)).png"))
                    } catch { print("FAIL: layout render: \(error)"); return false }
                }
            }
        }
        closeSettings()
        for count in [0, 6, 40] {
            store.sites = (0..<count).map { Site(name: "Site \($0)", url: URL(string: "https://example.com/\($0)")!) }
            renderRail()
            for position in ToolbarPosition.allCases {
                for size in [NSSize(width: 360, height: 300), NSSize(width: 480, height: 680)] {
                    panel.setContentSize(size); setToolbarPosition(position)
                    let background = SurfaceView(color: .textBackgroundColor)
                    background.frame = content.bounds; content.addSubview(background)
                    let toolbarViews = railContents.subviews.map(ObjectIdentifier.init)
                    renderAdd()
                    precondition(railContents.subviews.map(ObjectIdentifier.init) == toolbarViews)
                    nameInput?.stringValue = "未保存的名称"
                    let underlyingViews = content.subviews.map(ObjectIdentifier.init)
                    renderSettings(); positionButtons[position]!.performClick(nil); layoutChrome()
                    precondition(railContents.subviews.map(ObjectIdentifier.init) == toolbarViews)
                    precondition(addOverlay!.isHidden)
                    precondition(railTools.arrangedSubviews.allSatisfy { $0.layer?.cornerRadius == 14 })
                    let root = panel.contentView!
                    root.layoutSubtreeIfNeeded()
                    guard root.bounds.contains(rail.frame), root.bounds.contains(settingsOverlay!.frame),
                          !rail.frame.intersects(settingsOverlay!.frame),
                          !content.frame.intersects(rail.frame), content.frame.union(rail.frame) == root.bounds,
                          content.frame.width == root.bounds.width - (position.isVertical ? 32 : 0),
                          content.frame.height == root.bounds.height - (position.isVertical ? 0 : 32),
                          rail.bounds.contains(railContents.frame), rail.bounds.contains(railEdge.frame),
                          content.frame.contains(settingsOverlay!.frame),
                          content.frame.contains(addOverlay!.frame),
                          root.bounds.contains(addOverlay!.frame), !rail.frame.intersects(addOverlay!.frame),
                          railTools.arrangedSubviews.count == 3,
                          railContents.bounds.contains(railTools.frame),
                          (siteScroll.isHidden || railContents.bounds.contains(siteScroll.frame)),
                          railContents.bounds.contains(railDivider.frame),
                          railTools.arrangedSubviews.allSatisfy({ abs($0.frame.width - 28) < 0.1 && abs($0.frame.height - 28) < 0.1 }) else {
                        print("FAIL: overlapping page/sidebar or unreachable controls: \(position) \(size) \(count)"); return false
                    }
                    for button in positionButtons.values {
                        guard let body = button.superview, let cell = button.cell as? NSButtonCell else { return false }
                        precondition(body.bounds.insetBy(dx: 3, dy: 1).contains(button.frame))
                        precondition(button.bounds.contains(cell.imageRect(forBounds: button.bounds)))
                        precondition(button.bounds.contains(cell.titleRect(forBounds: button.bounds)))
                    }
                    precondition(positionButtons[position]?.state == .on)
                    precondition(positionButtons.values.filter { $0.state == .on }.count == 1)
                    precondition(cacheButton!.superview?.superview != nil)
                    precondition(railTools.arrangedSubviews.compactMap { ($0 as? NSButton)?.toolTip } == ["收起", "添加网站", "设置"])
                    let field = sleepInput!
                    for bad in ["0", "86401", "abc"] {
                        field.stringValue = bad; saveSleepSeconds(field)
                        precondition(field.stringValue == String(store.preferences.sleepSeconds))
                    }
                    field.stringValue = "75"; saveSleepSeconds(field)
                    precondition(store.preferences.sleepSeconds == 75)
                    if let last = siteList.subviews.last {
                        siteList.scrollToVisible(last.frame)
                        precondition(siteScroll.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(last.frame))
                    }
                    closeSettings()
                    precondition(content.subviews.map(ObjectIdentifier.init) == underlyingViews)
                    precondition(nameInput?.stringValue == "未保存的名称" && addOverlay?.isHidden == false)
                    refreshSiteIcons()
                    precondition(railContents.subviews.map(ObjectIdentifier.init) == toolbarViews)
                    showAdd()
                    precondition(addOverlay == nil && content.subviews.map(ObjectIdentifier.init) == underlyingViews)
                    background.removeFromSuperview()
                }
            }
        }
        closeAdd()
        let site = Site(name: "Local check", url: URL(string: "about:blank")!)
        store.sites = [site]; renderRail(); select(site.id)
        let web = content.subviews.first(where: { $0 is WKWebView })!
        let mounted = content.subviews.map(ObjectIdentifier.init)
        renderWebsite()
        precondition(content.subviews.map(ObjectIdentifier.init) == mounted)
        for position in ToolbarPosition.allCases {
            for size in [NSSize(width: 360, height: 300), NSSize(width: 480, height: 680), NSSize(width: 960, height: 650)] {
                panel.setContentSize(size); setToolbarPosition(position); layoutChrome()
                panel.contentView!.layoutSubtreeIfNeeded()
                precondition(web.superview === content && web.frame == content.bounds)
                precondition(content.subviews.map(ObjectIdentifier.init) == mounted)
                precondition(!web.convert(web.bounds, to: panel.contentView).intersects(rail.frame))
            }
        }
        panel.setContentSize(NSSize(width: 480, height: 680)); setToolbarPosition(.left)
        showAdd()
        let emptyHeight = addOverlay!.frame.height
        precondition(emptyHeight < 240 && addOverlay!.frame.width == 280)
        addressInput!.stringValue = "https://example.com"; updatePreview()
        precondition(addOverlay!.frame.height > emptyHeight)
        addressInput!.stringValue = ""; updatePreview()
        precondition(abs(addOverlay!.frame.height - emptyHeight) < 1)
        let siteCount = store.sites.count
        saveSite()
        precondition(formError?.isHidden == false && store.sites.count == siteCount)
        precondition(addOverlay!.frame.height > emptyHeight)
        showSettings()
        precondition(settingsOverlay!.frame.height < 600 && settingsOverlay!.frame.width == 280)
        closeSettings(); closeAdd()
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 {
            showAdd(); nameInput?.stringValue = "草稿"
            showSettings(); closeSettings()
            precondition(nameInput?.stringValue == "草稿" && web.superview === content)
            closeAdd()
            precondition(content.subviews.map(ObjectIdentifier.init) == mounted)
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000 / 20
        print("Overlay create/close CPU-side wall time: \(String(format: "%.1f", elapsed)) ms/cycle (20 cycles, excludes display frame timing)")
        print("PASS: separate 32pt sidebar, full web viewport, add/settings draft retention, stable toolbar/web views, four positions and overflow")
        return true
    }

    private func fillPageWidth(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class SurfaceView: NSView {
    var showsResizeCursor = false
    override func resetCursorRects() {
        super.resetCursorRects()
        if showsResizeCursor { addCursorRect(NSRect(x: 0, y: 0, width: 4, height: bounds.height), cursor: .resizeLeftRight) }
    }
    let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero); wantsLayer = true; updateColor() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
    private func updateColor() { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor } }
}

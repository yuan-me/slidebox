import AppKit
import ServiceManagement
import WebKit

final class ActionButton: NSButton, NSDraggingSource {
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
        } else { bezelStyle = .rounded }
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
    private let store = Store()
    private let pages = WebPages()
    private var panel: SlidePanel!
    private var rail: NSView!
    private var content: NSView!
    private var edges: [NSPanel] = []
    private var hover: DispatchWorkItem?
    private var monitors: [Any] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var visible = false
    private var transition = 0
    private var screen: NSScreen?
    private var currentPage: Page = .website
    private var editing: UUID?
    private var addressInput: NSTextField?
    private var nameInput: NSTextField?
    private var formError: NSTextField?
    private var loginStatus: NSTextField?
    private var sleepInput: NSTextField?
    private var spinner: NSProgressIndicator?
    private var previewBox: NSBox?
    private var previewTitle: NSTextField?
    private var previewDomain: NSTextField?
    private var previewIcon: NSImageView?
    private enum Page { case website, add, settings }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--web-self-test") || CommandLine.arguments.contains("--memory-self-test") {
            Task { @MainActor in
                do {
                    if CommandLine.arguments.contains("--memory-self-test") { try await runMemoryChecks() }
                    else { try await runWebChecks(); print("PASS: real WebKit lifecycle checks") }
                    exit(0)
                }
                catch { fputs("WebKit check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        makeWindow()
        pages.configureSleep(enabled: store.preferences.sleepEnabled, seconds: store.preferences.sleepSeconds)
        if CommandLine.arguments.contains("--layout-self-test") {
            exit(runLayoutChecks() ? 0 : 1)
        }
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
        hover?.cancel(); removeMonitors(); pages.dispose()
        edges.forEach { $0.close() }
        notificationTokens.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
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
        let root = SurfaceView(color: .windowBackgroundColor)
        root.layer?.cornerRadius = 10; root.layer?.masksToBounds = true
        panel.contentView = root
        rail = SurfaceView(color: .controlBackgroundColor)
        (rail as? SurfaceView)?.showsResizeCursor = true
        content = SurfaceView(color: .textBackgroundColor)
        for view in [rail!, content!] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor), rail.topAnchor.constraint(equalTo: root.topAnchor), rail.bottomAnchor.constraint(equalTo: root.bottomAnchor), rail.widthAnchor.constraint(equalToConstant: 36),
            content.leadingAnchor.constraint(equalTo: rail.trailingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let divider = NSBox(); divider.boxType = .separator; divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)
        NSLayoutConstraint.activate([divider.leadingAnchor.constraint(equalTo: rail.trailingAnchor), divider.topAnchor.constraint(equalTo: root.topAnchor), divider.bottomAnchor.constraint(equalTo: root.bottomAnchor), divider.widthAnchor.constraint(equalToConstant: 1)])
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
        if currentPage == .website || content.subviews.isEmpty { renderCurrentPage() }
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
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            if event.window != self?.panel { self?.outsideClick() }
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

    private func railButton(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, symbol: symbol, action: action)
        button.toolTip = title; button.translatesAutoresizingMaskIntoConstraints = false
        button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        button.wantsLayer = true; button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 28)])
        return button
    }

    private func renderRail() {
        rail.subviews.forEach { $0.removeFromSuperview() }
        let top = NSStackView(); top.orientation = .vertical; top.spacing = 8
        top.addArrangedSubview(railButton("收起", symbol: "chevron.right") { [weak self] in self?.hide() })
        top.addArrangedSubview(railButton("固定侧栏", symbol: store.preferences.pinned ? "pin.fill" : "pin", selected: store.preferences.pinned) { [weak self] in
            guard let self else { return }; self.store.preferences.pinned.toggle(); self.renderRail()
            if self.currentPage == .settings { self.renderSettings() }
        })
        // Scroll only the site list, so add/settings remain reachable with many sites.
        let list = NSStackView(); list.orientation = .vertical; list.spacing = 8; list.alignment = .centerX
        for site in store.sites {
            let selected = currentPage == .website && site.id == store.selected
            let button = railButton(site.name, symbol: "globe", selected: selected) { [weak self] in self?.select(site.id) }
            button.image = siteIcon(site.url); button.imageScaling = .scaleProportionallyDown
            button.siteID = site.id
            button.reorder = { [weak self] source, target in
                guard let self else { return }
                self.store.sites = reorderedSites(self.store.sites, source: source, target: target)
                self.renderRail()
            }
            let menu = NSMenu()
            for (title, action) in [("编辑网站", #selector(editSite(_:))), ("上移", #selector(moveUp(_:))), ("下移", #selector(moveDown(_:))), ("在默认浏览器打开", #selector(openSite(_:))), ("删除网站", #selector(deleteSite(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.representedObject = site.id.uuidString; menu.addItem(item)
            }
            button.menu = menu; list.addArrangedSubview(button)
        }
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = false
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(list); scroll.documentView = document
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), list.topAnchor.constraint(equalTo: document.topAnchor), list.bottomAnchor.constraint(equalTo: document.bottomAnchor), list.centerXAnchor.constraint(equalTo: document.centerXAnchor)])
        let bottom = NSStackView(); bottom.orientation = .vertical; bottom.spacing = 8
        bottom.addArrangedSubview(railButton("添加网站", symbol: "plus", selected: currentPage == .add) { [weak self] in self?.showAdd() })
        bottom.addArrangedSubview(railButton("设置", symbol: "gearshape", selected: currentPage == .settings) { [weak self] in self?.showSettings() })
        for view in [top, scroll, bottom] { view.translatesAutoresizingMaskIntoConstraints = false; rail.addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: rail.topAnchor, constant: 8), top.centerXAnchor.constraint(equalTo: rail.centerXAnchor),
            bottom.bottomAnchor.constraint(equalTo: rail.bottomAnchor, constant: -12), bottom.centerXAnchor.constraint(equalTo: rail.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12), scroll.leadingAnchor.constraint(equalTo: rail.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: rail.trailingAnchor)
        ])
    }

    private func clearContent() {
        spinner?.stopAnimation(nil)
        content.subviews.forEach { $0.removeFromSuperview() }
        addressInput = nil; nameInput = nil; formError = nil; loginStatus = nil; spinner = nil
        previewBox = nil; previewTitle = nil; previewDomain = nil; previewIcon = nil
        sleepInput = nil
    }

    private func select(_ id: UUID) {
        store.selected = id; currentPage = .website; editing = nil
        renderRail(); renderWebsite()
    }
    private func renderCurrentPage() {
        switch currentPage {
        case .website: renderWebsite()
        case .add: renderAdd()
        case .settings: renderSettings()
        }
        renderRail()
    }

    private func renderWebsite() {
        clearContent()
        guard let site = store.sites.first(where: { $0.id == store.selected }) else {
            pages.suspendActive()
            let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 16
            stack.addArrangedSubview(label("Slidebox", size: 26, weight: .semibold))
            stack.addArrangedSubview(label("把常用网站放在手边", color: .secondaryLabelColor))
            stack.addArrangedSubview(ActionButton("添加网站") { [weak self] in self?.showAdd() })
            center(stack); return
        }
        let page = pages.activate(site)
        page.changed = { [weak self] url in
            guard let self, let index = self.store.sites.firstIndex(where: { $0.id == site.id }) else { return }
            self.store.sites[index].url = url
        }
        page.failed = { [weak self] message in
            guard let self, self.visible, self.currentPage == .website, self.store.selected == site.id else { return }
            self.showWebError(message, site: site)
        }
        page.loadingChanged = { [weak self] loading in
            guard let self, self.store.selected == site.id, self.currentPage == .website else { return }
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
        pages.suspendActive(); editing = id; currentPage = .add; renderRail(); renderAdd()
        panel.makeKey(); if let addressInput { panel.makeFirstResponder(addressInput) }
    }

    private func renderAdd() {
        clearContent()
        let site = store.sites.first { $0.id == editing }
        let stack = pageStack(title: site == nil ? "添加网站" : "编辑网站")
        stack.addArrangedSubview(label(site == nil ? "添加网站" : "编辑网站", size: 22, weight: .semibold))
        stack.addArrangedSubview(label("输入网址，添加到侧栏。", color: .secondaryLabelColor))
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(label("网站地址"))
        let address = NSTextField(string: site?.url.absoluteString ?? "")
        address.bezelStyle = .roundedBezel
        address.controlSize = .large; address.font = .systemFont(ofSize: 14)
        address.setAccessibilityLabel("网站地址"); stack.addArrangedSubview(address); addressInput = address
        address.delegate = self
        stack.setCustomSpacing(22, after: address)
        stack.addArrangedSubview(label("网站名称"))
        let name = NSTextField(string: site?.name ?? "")
        name.bezelStyle = .roundedBezel; name.font = .systemFont(ofSize: 14)
        name.controlSize = .large; name.setAccessibilityLabel("网站名称")
        stack.addArrangedSubview(name); nameInput = name
        name.delegate = self
        let preview = NSBox(); preview.boxType = .custom; preview.borderWidth = 1
        preview.borderColor = .separatorColor; preview.cornerRadius = 6; preview.contentViewMargins = NSSize(width: 10, height: 10)
        let icon = NSImageView(); let title = label(""); let domain = label("", size: 12, color: .secondaryLabelColor)
        let words = NSStackView(views: [title, domain]); words.orientation = .vertical; words.alignment = .leading; words.spacing = 4
        let previewRow = NSStackView(views: [icon, words]); previewRow.orientation = .horizontal; previewRow.spacing = 12
        previewRow.translatesAutoresizingMaskIntoConstraints = false; preview.contentView!.addSubview(previewRow)
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28), previewRow.leadingAnchor.constraint(equalTo: preview.contentView!.leadingAnchor), previewRow.trailingAnchor.constraint(equalTo: preview.contentView!.trailingAnchor), previewRow.topAnchor.constraint(equalTo: preview.contentView!.topAnchor), previewRow.bottomAnchor.constraint(equalTo: preview.contentView!.bottomAnchor)])
        previewBox = preview; previewIcon = icon; previewTitle = title; previewDomain = domain; stack.addArrangedSubview(preview)
        updatePreview()
        let error = label("", color: .systemRed); stack.addArrangedSubview(error); formError = error
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10; buttons.distribution = .gravityAreas
        let cancel = ActionButton("取消") { [weak self] in
            guard let self else { return }; self.currentPage = .website; self.editing = nil; self.renderCurrentPage()
        }
        let add = ActionButton(site == nil ? "添加" : "保存") { [weak self] in self?.saveSite() }
        add.keyEquivalent = "\r"; add.bezelColor = .controlAccentColor
        buttons.addView(cancel, in: .trailing); buttons.addView(add, in: .trailing); stack.addArrangedSubview(buttons)
        fillPageWidth(stack)
    }

    private func saveSite() {
        guard let url = websiteURL(addressInput?.stringValue ?? "") else { formError?.stringValue = "请输入有效的 HTTP 或 HTTPS 网址。"; return }
        let title = nameInput?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard title.count <= 100 else { formError?.stringValue = "名称请保持在 100 个字符以内。"; return }
        if let editing, let index = store.sites.firstIndex(where: { $0.id == editing }) {
            pages.remove(editing); store.sites[index].url = url; store.sites[index].name = title.isEmpty ? defaultName(url) : title; select(editing)
        } else {
            let site = Site(name: title.isEmpty ? defaultName(url) : title, url: url)
            store.sites.append(site); select(site.id)
        }
    }

    func controlTextDidChange(_ notification: Notification) { updatePreview() }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === sleepInput { saveSleepSeconds(field) }
    }
    private func updatePreview() {
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
        // ponytail: bundle the two focus-site icons; other sites use a globe until generic favicon support is needed.
        let name = url.host == "chat.deepseek.com" ? "deepseek" : (url.host == "chatgpt.com" ? "chatgpt" : "")
        if !name.isEmpty, let image = NSImage(named: NSImage.Name(name)) {
            image.size = NSSize(width: 18, height: 18); return image
        }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: "网站")
    }

    private func showSettings() {
        pages.suspendActive(); currentPage = .settings; renderRail(); renderSettings()
    }

    private func renderSettings() {
        clearContent()
        let stack = pageStack(title: "设置")
        stack.addArrangedSubview(label("Slidebox", size: 24, weight: .semibold))
        section("通用", in: stack)
        let login = NSSwitch(); login.target = self; login.action = #selector(toggleLogin(_:)); login.setAccessibilityLabel("登录时自动启动")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        stack.addArrangedSubview(row("登录时自动启动", trailing: login))
        let status = label("", size: 11, color: .secondaryLabelColor); loginStatus = status
        if SMAppService.mainApp.status == .requiresApproval { status.stringValue = "请在系统设置的登录项中允许 Slidebox。" }
        stack.addArrangedSubview(status)
        section("窗口", in: stack)
        let pin = NSSwitch(); pin.state = store.preferences.pinned ? .on : .off; pin.target = self; pin.action = #selector(togglePin(_:)); pin.setAccessibilityLabel("固定侧栏")
        stack.addArrangedSubview(row("固定侧栏", trailing: pin))
        section("网页休眠", in: stack)
        let sleep = NSSwitch(); sleep.state = store.preferences.sleepEnabled ? .on : .off
        sleep.target = self; sleep.action = #selector(toggleSleep(_:)); sleep.setAccessibilityLabel("自动休眠网页")
        stack.addArrangedSubview(row("自动休眠网页", trailing: sleep))
        let seconds = NSTextField(string: String(store.preferences.sleepSeconds))
        seconds.alignment = .left; seconds.widthAnchor.constraint(equalToConstant: 80).isActive = true
        seconds.setAccessibilityLabel("隐藏后等待秒数，1 至 86400")
        seconds.delegate = self; seconds.target = self; seconds.action = #selector(saveSleepSeconds(_:))
        seconds.isEnabled = store.preferences.sleepEnabled; sleepInput = seconds
        stack.addArrangedSubview(row("等待时间（秒）", trailing: seconds))
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.distribution = .gravityAreas
        buttons.addView(ActionButton("退出 Slidebox") { NSApp.terminate(nil) }, in: .trailing)
        stack.addArrangedSubview(buttons)
        fillPageWidth(stack)
    }

    @objc private func toggleLogin(_ sender: NSSwitch) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            let status = SMAppService.mainApp.status
            loginStatus?.stringValue = status == .requiresApproval ? "请在系统设置的登录项中允许 Slidebox。" : ""
            sender.state = status == .enabled || status == .requiresApproval ? .on : .off
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            loginStatus?.stringValue = "操作失败：\(error.localizedDescription)"
        }
    }
    @objc private func togglePin(_ sender: NSSwitch) { store.preferences.pinned = sender.state == .on; renderRail() }
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
            self.currentPage = .website; self.renderCurrentPage()
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
        NSLayoutConstraint.activate([view.heightAnchor.constraint(greaterThanOrEqualToConstant: 32), text.leadingAnchor.constraint(equalTo: view.leadingAnchor), text.centerYAnchor.constraint(equalTo: view.centerYAnchor), trailing.trailingAnchor.constraint(equalTo: view.trailingAnchor), trailing.centerYAnchor.constraint(equalTo: view.centerYAnchor), text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8)])
        return view
    }
    private func section(_ title: String, in stack: NSStackView) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(22, after: last) }
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
        for size in [NSSize(width: 360, height: 300), NSSize(width: 480, height: 680), NSSize(width: 720, height: 500)] {
            panel.setContentSize(size)
            for settings in [false, true] {
                if settings { renderSettings() } else { renderAdd() }
                panel.contentView!.layoutSubtreeIfNeeded()
                guard let scroll = content.subviews.compactMap({ $0 as? NSScrollView }).first,
                      let document = scroll.documentView,
                      let stack = document.subviews.first as? NSStackView else { return false }
                let valid = abs(scroll.frame.height - (content.bounds.height - 47)) < 1
                    && document.frame.width > 250 && document.frame.height > 100
                    && stack.frame.width > 200 && stack.frame.height > 100
                print("Layout \(settings ? "settings" : "add") \(size): scroll=\(scroll.frame), document=\(document.frame), stack=\(stack.frame)")
                guard valid else { print("FAIL: form content is collapsed or outside the viewport"); return false }
                if !settings {
                    for field in [addressInput!, nameInput!] {
                        guard abs(field.frame.height - field.intrinsicContentSize.height) < 1 else {
                            print("FAIL: input height differs from native text-field height"); return false
                        }
                    }
                }
            }
        }
        print("PASS: add/settings layout at three window sizes")
        return true
    }

    private func fillPageWidth(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private func pageStack(title: String) -> NSStackView {
        let header = label(title, weight: .medium)
        header.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(header)
        let divider = NSBox(); divider.boxType = .separator; divider.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(divider)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(scroll)
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28), header.heightAnchor.constraint(equalToConstant: 20),
            divider.topAnchor.constraint(equalTo: content.topAnchor, constant: 46), divider.leadingAnchor.constraint(equalTo: content.leadingAnchor), divider.trailingAnchor.constraint(equalTo: content.trailingAnchor), divider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])
        return stack
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

import AppKit
import WebKit

@MainActor
func runWebChecks() async throws {
    // Prevent test-runner App Nap from turning a requested 29s wait into a >30s wait.
    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Slidebox lifecycle verification")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let pages = WebPages()
    defer { pages.dispose() }
    let site = Site(name: "Local lifecycle check", url: URL(string: "about:blank")!)
    weak var initial: WKWebView?
    autoreleasepool { initial = pages.activate(site).view }
    pages.suspendActive()
    let start = ContinuousClock.now
    try await Task.sleep(for: .seconds(29), tolerance: .zero)
    let elapsed = start.duration(to: .now)
    print("29s check: actual elapsed=\(elapsed), retained=\(pages.pages.count)")
    guard elapsed < .seconds(30) else { throw NSError(domain: "Test runner woke after deadline; pre-deadline result inconclusive", code: 1) }
    precondition(pages.pages.count == 1, "Page released before its deadline")
    autoreleasepool { precondition(pages.activate(site).view === initial, "Quick resume replaced the web view") }
    pages.suspendActive()
    try await Task.sleep(for: .seconds(31), tolerance: .zero)
    precondition(pages.pages.isEmpty, "Hidden page still retained after deadline")
    try await Task.sleep(for: .milliseconds(200))
    precondition(initial == nil, "Web view retained after disposal")
    pages.configureSleep(enabled: false, seconds: 1)
    autoreleasepool { initial = pages.activate(site).view }
    pages.suspendActive()
    try await Task.sleep(for: .seconds(2))
    precondition(pages.pages.count == 1 && initial != nil, "Disabled sleep released a page")
    pages.configureSleep(enabled: true, seconds: 1)
    try await Task.sleep(for: .seconds(2))
    precondition(pages.pages.isEmpty && initial == nil, "Custom sleep failed")
    for _ in 0..<20 {
        weak var view: WKWebView?
        autoreleasepool {
            view = pages.activate(site).view
            pages.suspendActive()
            pages.expire(at: ContinuousClock.now.advanced(by: .seconds(31)))
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(pages.pages.isEmpty && view == nil, "Repeated cycles retain a web view")
    }
}

@MainActor
func runMemoryChecks() async throws {
    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Slidebox memory measurement")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let pages = WebPages()
    defer { pages.dispose() }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Slidebox 内存验证"; window.isReleasedWhenClosed = false
    defer { window.close() }
    func mark(_ text: String) { print("MEMORY \(Date().timeIntervalSince1970) \(text) retained=\(pages.pages.count)"); fflush(stdout) }
    mark("baseline")
    try await Task.sleep(for: .seconds(5))
    for address in ["https://chat.deepseek.com/", "https://chatgpt.com/"] {
        let site = Site(name: address, url: URL(string: address)!)
        weak var original: WKWebView?
        autoreleasepool {
            let page = pages.activate(site)
            original = page.view
            page.failed = { print("SITE FAILURE \(address): \($0)"); fflush(stdout) }
            window.contentView = page.view
            window.orderFrontRegardless()
        }
        try await Task.sleep(for: .seconds(20))
        let title = original?.title ?? ""
        mark("loaded \(address) title=\(title) loading=\(original?.isLoading ?? false)")
        pages.suspendActive(); window.contentView = NSView(); window.orderOut(nil)
        try await Task.sleep(for: .seconds(5))
        autoreleasepool { precondition(pages.activate(site).view === original) }
        mark("quick-reopen \(address)")
        pages.suspendActive()
        try await Task.sleep(for: .seconds(35))
        precondition(pages.pages.isEmpty && original == nil)
        mark("hidden35 \(address) weak=nil")
        try await Task.sleep(for: .seconds(55))
        mark("hidden90 \(address)")
        autoreleasepool { window.contentView = pages.activate(site).view; window.orderFrontRegardless() }
        try await Task.sleep(for: .seconds(15))
        mark("recreated \(address)")
        pages.dispose(); window.contentView = NSView(); window.orderOut(nil)
        try await Task.sleep(for: .seconds(5))
    }
    print("PASS: public-site memory lifecycle checks"); fflush(stdout)
}

@MainActor
func runBrowserChecks() async throws {
    precondition(SiteIcons.key(URL(string: "https://example.com/a?q=1#x")!) == "https://example.com")
    precondition(SiteIcons.key(URL(string: "https://example.com:8443/b")!) == "https://example.com:8443")
    precondition(SiteIcons.key(URL(string: "file:///tmp/icon")!) == nil)
    guard let fixture = ProcessInfo.processInfo.environment["SLIDEBOX_ICON_FIXTURE"], let url = URL(string: fixture) else {
        throw NSError(domain: "Set SLIDEBOX_ICON_FIXTURE to the local icon fixture URL", code: 1)
    }
    let page = WebPage(site: Site(name: "Icon check", url: url))
    defer { page.dispose() }
    for _ in 0..<150 {
        if SiteIcons.shared.image(for: url) != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    precondition(SiteIcons.shared.image(for: url) != nil, "Declared favicon not downloaded")
    let ua = try await page.view.evaluateJavaScript("navigator.userAgent") as? String ?? ""
    precondition(ua.contains("Version/") && ua.contains("Safari/"), "Missing Safari browser identification")
    print("PASS: favicon discovery, download, origin keys; UA=\(ua)")
    for address in ["https://mail.google.com/", "https://chat.deepseek.com/", "https://chatgpt.com/"] {
        let site = WebPage(site: Site(name: "Compatibility check", url: URL(string: address)!))
        for _ in 0..<450 {
            try await Task.sleep(for: .milliseconds(100))
            if !site.view.isLoading { break }
        }
        try await Task.sleep(for: .seconds(3))
        guard !site.view.isLoading else {
            site.dispose()
            throw NSError(domain: "Page load timed out; compatibility inconclusive: " + address, code: 1)
        }
        let hasContent = try await site.view.evaluateJavaScript("document.body.innerText.trim().length > 0") as? Bool ?? false
        guard hasContent else { site.dispose(); throw NSError(domain: "Empty page: " + address, code: 1) }
        let unsupported = try await site.view.evaluateJavaScript("document.body.innerText.includes('This browser version is no longer supported')") as? Bool ?? false
        print("BROWSER \(address) host=\(site.view.url?.host ?? "") loading=\(site.view.isLoading) unsupported=\(unsupported)")
        site.dispose()
        if unsupported { throw NSError(domain: "Unsupported browser: " + address, code: 1) }
    }
}

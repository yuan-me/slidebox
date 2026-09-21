import AppKit
import WebKit

@MainActor
func runDataChecks() async throws {
    guard let fixture = ProcessInfo.processInfo.environment["SLIDEBOX_ICON_FIXTURE"], let url = URL(string: fixture) else {
        throw NSError(domain: "Set SLIDEBOX_ICON_FIXTURE to the local data fixture URL", code: 1)
    }
    let suite = "Slidebox-check-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = Store(defaults: defaults)
    let site = Site(name: "Saved home", url: url)
    store.sites = [site]
    // A unique persistent store exercises the same HTTP cache as the app, without user data.
    let pages = WebPages(dataStore: WKWebsiteDataStore(forIdentifier: UUID()))
    defer { pages.dispose() }
    func loaded(_ page: WebPage, at expected: URL) async throws {
        for _ in 0..<100 {
            if page.view.url == expected && !page.view.isLoading,
               (try? await page.view.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "Local fixture failed to load: " + expected.absoluteString, code: 1)
    }
    let page = pages.activate(site)
    try await loaded(page, at: url)
    let conversation = url.appendingPathComponent("c/example")
    _ = try await page.view.evaluateJavaScript("history.pushState({}, '', '/c/example')")
    try await Task.sleep(for: .milliseconds(100))
    precondition(page.view.url == conversation)
    pages.suspendActive()
    precondition(pages.activate(site) === page, "Quick resume must keep the current page")
    pages.suspendActive()
    pages.expire(at: .now.advanced(by: .seconds(31)))
    let restored = pages.activate(site)
    try await loaded(restored, at: conversation)
    precondition(store.sites == [site] && Store(defaults: defaults).sites == [site], "Navigation overwrote the bookmark")
    print("PASS: SPA navigation and sleep recovery leave saved URLs unchanged")

    // With sleep disabled a hidden SPA may still navigate; capture its URL at disposal.
    pages.configureSleep(enabled: false, seconds: 30)
    pages.suspendActive()
    let backgroundURL = url.appendingPathComponent("c/background")
    _ = try await restored.view.evaluateJavaScript("history.pushState({}, '', '/c/background')")
    pages.configureSleep(enabled: true, seconds: 30)
    pages.expire(at: .now.advanced(by: .seconds(31)))
    let background = pages.activate(site)
    try await loaded(background, at: backgroundURL)
    precondition(Store(defaults: defaults).sites == [site])
    print("PASS: hidden SPA navigation survives sleep without a URL observer")

    _ = try await background.view.callAsyncJavaScript("""
        document.cookie = 'slidebox_login=keep; path=/; SameSite=Lax';
        localStorage.setItem('slidebox_login', 'keep');
        await new Promise((resolve, reject) => {
            const request = indexedDB.open('slidebox-check', 1);
            request.onupgradeneeded = () => request.result.createObjectStore('session');
            request.onerror = () => reject(request.error);
            request.onsuccess = () => {
                const db = request.result, tx = db.transaction('session', 'readwrite');
                tx.objectStore('session').put('keep', 'login');
                tx.oncomplete = () => { db.close(); resolve(); };
                tx.onerror = () => reject(tx.error);
            };
        });
        return true;
        """, arguments: [:], in: nil, contentWorld: .page)
    let fetch = "return await (await fetch('/cached.txt')).text();"
    let first = try await background.view.callAsyncJavaScript(fetch, arguments: [:], in: nil, contentWorld: .page) as? String
    let cached = try await background.view.callAsyncJavaScript(fetch, arguments: [:], in: nil, contentWorld: .page) as? String
    guard first == "1" && cached == first else {
        throw NSError(domain: "Fixture response was not cached: first=\(first ?? "nil"), second=\(cached ?? "nil")", code: 1)
    }
    await pages.clearCache()
    let fresh = try await background.view.callAsyncJavaScript(fetch, arguments: [:], in: nil, contentWorld: .page) as? String
    precondition(fresh == "2", "Resource cache was not cleared")
    pages.remove(site.id)
    let reopened = pages.activate(site)
    try await loaded(reopened, at: url)
    let kept = try await reopened.view.callAsyncJavaScript("""
        const value = await new Promise((resolve, reject) => {
            const request = indexedDB.open('slidebox-check', 1);
            request.onerror = () => reject(request.error);
            request.onsuccess = () => {
                const db = request.result;
                const read = db.transaction('session').objectStore('session').get('login');
                read.onsuccess = () => { db.close(); resolve(read.result); };
                read.onerror = () => reject(read.error);
            };
        });
        return document.cookie.includes('slidebox_login=keep') && localStorage.getItem('slidebox_login') === 'keep' && value === 'keep';
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
    precondition(kept == true, "Cache clearing removed login storage")
    print("PASS: HTTP cache cleared; cookies, localStorage and IndexedDB survive page recreation")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer { try? FileManager.default.removeItem(at: directory) }
    let icons = SiteIcons(directory: directory)
    icons.discover(in: reopened.view)
    for _ in 0..<100 {
        if icons.image(for: url) != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    precondition(icons.image(for: url) != nil, "Fixture icon was not cached")
    try icons.clearCache()
    precondition(icons.image(for: url) == nil && !FileManager.default.fileExists(atPath: directory.path))
    try icons.clearCache() // Clearing an already-empty cache is safe.
    icons.discover(in: reopened.view)
    try icons.clearCache()
    try await Task.sleep(for: .milliseconds(200))
    precondition(icons.image(for: url) == nil, "An old download repopulated the cleared icon cache")
    precondition(Store(defaults: defaults).sites == [site])
    print("PASS: icon memory/disk cache cleared; repeated clearing is safe")

    let other = Site(name: "Other page", url: url.appendingPathComponent("other"))
    let search = URL(string: "/search?q=test", relativeTo: url)!.absoluteURL
    for scenario in ["search", "SPA", "sleep", "already home"] {
        let current = pages.activate(site)
        if scenario == "search" {
            current.view.load(URLRequest(url: search))
            try await loaded(current, at: search)
        } else if scenario != "already home" {
            _ = try await current.view.evaluateJavaScript("history.pushState({}, '', '/search?q=test')")
            precondition(current.view.url == search)
        }
        // Returning through another site's icon must activate the requested site.
        let otherPage = pages.activate(other)
        try await loaded(otherPage, at: other.url)
        if scenario == "sleep" {
            pages.expire(at: .now.advanced(by: .seconds(31)))
            precondition(pages.pages[site.id] == nil)
        }
        pages.remove(site.id)
        let home = pages.activate(site)
        try await loaded(home, at: url)
        precondition(home !== current && pages.active == site.id)
        precondition(pages.pages[other.id] === otherPage)
        precondition(store.sites == [site] && Store(defaults: defaults).sites == [site])
        let login = try await home.view.evaluateJavaScript("document.cookie.includes('slidebox_login=keep') && localStorage.getItem('slidebox_login') === 'keep'") as? Bool
        precondition(login == true, "Returning home removed login storage")
        pages.suspendActive()
        pages.expire(at: .now.advanced(by: .seconds(31)))
        try await loaded(pages.activate(site), at: url)
    }
    print("PASS: return home after search, SPA, sleep and from home; target activation, bookmarks and login data preserved")

    _ = try await pages.activate(site).view.evaluateJavaScript("history.pushState({}, '', '/c/another')")
    try await Task.sleep(for: .milliseconds(100))
    pages.dispose()
    try await loaded(pages.activate(site), at: url)
    pages.remove(site.id)
    store.sites[0].url = url.appendingPathComponent("edited")
    try await loaded(pages.activate(store.sites[0]), at: store.sites[0].url)
    precondition(Store(defaults: defaults).sites == store.sites)
    print("PASS: a new session starts at the bookmark; explicit URL edits still persist")
    pages.dispose()
    // This store contains only fixture data, never real bookmarks or accounts.
    await pages.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
}

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

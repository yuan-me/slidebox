import AppKit
import WebKit

@MainActor
final class WebPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    var changed: ((URL) -> Void)?
    var failed: ((String) -> Void)?
    var loadingChanged: ((Bool) -> Void)?
    private var observation: NSKeyValueObservation?
    private var interrupted = false

    init(site: Site) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Match the installed Safari version without claiming a different browser engine.
        if let version = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            configuration.applicationNameForUserAgent = "Version/\(version) Safari/605.1.15"
        }
        configuration.preferences.inactiveSchedulingPolicy = .suspend
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.underPageBackgroundColor = .textBackgroundColor
        observation = view.observe(\.url) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let url = self.view.url, websiteURL(url.absoluteString) != nil else { return }
                self.changed?(url)
            }
        }
        view.load(URLRequest(url: site.url))
    }

    func suspend(enabled: Bool) {
        view.configuration.preferences.inactiveSchedulingPolicy = enabled ? .suspend : .throttle
        if enabled {
            interrupted = view.isLoading
            view.stopLoading()
            view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        }
        view.removeFromSuperview()
    }

    func resume(url: URL) {
        view.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        if interrupted { interrupted = false; view.load(URLRequest(url: url)) }
    }

    func dispose() {
        view.stopLoading()
        view.removeFromSuperview()
        observation = nil
        view.navigationDelegate = nil
        view.uiDelegate = nil
        changed = nil
        failed = nil
        loadingChanged = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loadingChanged?(true) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingChanged?(false)
        SiteIcons.shared.discover(in: webView)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    private func report(_ error: Error) {
        loadingChanged?(false)
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        failed?(error.localizedDescription)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadingChanged?(false)
        failed?("网页进程已退出，请重新打开。")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload {
            decisionHandler(.cancel); failed?("此版本不支持下载，可在默认浏览器中打开。"); return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "about"].contains(scheme) else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated { failed?("此链接需要在默认浏览器中打开。") }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.canShowMIMEType { decisionHandler(.allow) }
        else { decisionHandler(.cancel); failed?("此文件需要在默认浏览器中打开。") }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, websiteURL(url.absoluteString) != nil {
            webView.load(action.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        completionHandler(nil)
        failed?("此版本不支持上传，可在默认浏览器中打开。")
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window = webView.window else { completionHandler(); return }
        let alert = NSAlert(); alert.messageText = "网页提示"; alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window = webView.window else { completionHandler(false); return }
        let alert = NSAlert(); alert.messageText = "网页确认"; alert.informativeText = message
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let window = webView.window else { completionHandler(nil); return }
        let alert = NSAlert(); alert.messageText = prompt
        let input = NSTextField(string: defaultText ?? ""); input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }
}

@MainActor
final class WebPages {
    private(set) var pages: [UUID: WebPage] = [:]
    private(set) var active: UUID?
    private var retention = Retention()
    private var expiration: Task<Void, Never>?
    private var scheduledDeadline: ContinuousClock.Instant?

    func configureSleep(enabled: Bool, seconds: Int) {
        retention = Retention(delay: enabled ? seconds : nil)
        for (id, page) in pages where id != active {
            if !enabled, let url = page.view.url { page.resume(url: url) }
            suspend(id)
        }
        schedule()
    }

    func activate(_ site: Site) -> WebPage {
        expire()
        if let active, active != site.id { suspend(active) }
        retention.activate(site.id)
        let page: WebPage
        if let existing = pages[site.id] { page = existing; page.resume(url: site.url) }
        else { page = WebPage(site: site); pages[site.id] = page }
        active = site.id
        schedule()
        return page
    }

    func suspendActive() {
        if let active { suspend(active) }
        active = nil
        schedule()
    }

    private func suspend(_ id: UUID) {
        pages[id]?.suspend(enabled: retention.delay != nil)
        retention.suspend(id, at: .now)
    }

    func remove(_ id: UUID) {
        pages.removeValue(forKey: id)?.dispose()
        retention.activate(id)
        if active == id { active = nil }
        schedule()
    }

    func expire(at now: ContinuousClock.Instant = .now) {
        for id in retention.expired(at: now) where id != active {
            pages.removeValue(forKey: id)?.dispose()
            retention.activate(id)
        }
        schedule()
    }

    private func schedule() {
        let deadline = retention.next
        guard deadline != scheduledDeadline else { return }
        scheduledDeadline = deadline
        expiration?.cancel()
        expiration = nil
        guard let deadline else { return }
        expiration = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    func dispose() {
        expiration?.cancel(); expiration = nil
        scheduledDeadline = nil
        pages.values.forEach { $0.dispose() }
        pages.removeAll(); active = nil; retention = Retention()
    }
}

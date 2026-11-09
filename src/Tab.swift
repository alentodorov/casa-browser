// One tab: a WKWebView and what the chrome needs to know about it
import AppKit
import Combine
import WebKit

/// The page a new pane starts on: Casa's keys, laid out like Omarchy's Super+K list (key, then what
/// it does), in Flexoki paper and ink. Physical Cmd is Casa's Super.
let blankHTML: String = {
    let groups: [(String, [(String, String)])] = [
        ("panes", [
            ("CMD + ENTER", "terminal pane"), ("CMD + SHIFT + ENTER", "browser pane"), ("CMD + W", "close pane"),
            ("CMD + ARROWS", "focus pane"), ("CMD + SHIFT + ARROWS", "swap pane"), ("CMD + J", "flip split"),
            ("CMD + SHIFT + F", "zoom pane"), ("CMD + - / =", "divider left / right"), ("CMD + SHIFT + - / =", "divider up / down"),
        ]),
        ("workspaces", [
            ("CMD + T", "new workspace"), ("CMD + 1 … 9", "workspace"), ("CMD + SHIFT + 1 … 9", "move pane to workspace"),
            ("CTRL + TAB", "switcher"), ("CMD + SHIFT + [ / ]", "previous / next"), ("CMD + N", "new window"),
            ("CMD + SHIFT + N", "private window"),
        ]),
        ("browser", [
            ("CMD + L", "address or search"), ("CMD + K", "panes and commands"), ("CMD + [ / ]", "back / forward"),
            ("CMD + R", "reload"), ("CMD + F", "find in page"), ("CMD + 0", "reset zoom"), ("CMD + SHIFT + T", "reopen closed pane"),
            ("CMD + SHIFT + C", "copy url"), ("CMD + SHIFT + D", "downloads"), ("CMD + SHIFT + I", "web inspector"),
            ("CMD + K, > IMPORT", "cookies and history from chrome or safari"),
        ]),
    ]
    func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    let sections = groups.map { title, rows in
        "<section><h2>\(title)</h2>" + rows.map { "<div class=r><kbd>\(esc($0.0))</kbd><span>\(esc($0.1))</span></div>" }.joined() + "</section>"
    }.joined()
    return """
    <!doctype html><html><head><meta charset=utf-8><title></title><style>
    html,body{margin:0;background:#FFFCF0;color:#100F0F;font:bold 12px/1 "JetBrainsMono Nerd Font Propo","JetBrainsMono Nerd Font",ui-monospace,monospace}
    body{display:flex;justify-content:center;padding:14vh 24px 48px;box-sizing:border-box;min-height:100vh}
    main{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:40px 56px;max-width:1120px;width:100%}
    h2{margin:0 0 14px;font-size:11px;font-weight:bold;color:#878580;text-transform:lowercase;letter-spacing:.04em}
    .r{display:grid;grid-template-columns:minmax(12em,auto) 1fr;gap:0 18px;align-items:baseline;padding:6px 0;border-top:1px solid #E6E4D9}
    .r:last-child{border-bottom:1px solid #E6E4D9}
    kbd{font:inherit;color:#100F0F;white-space:nowrap}
    span{color:#878580;font-weight:normal}
    @media (max-width:560px){body{padding-top:8vh}.r{grid-template-columns:1fr;gap:3px}}
    </style></head><body><main>\(sections)</main></body></html>
    """
}()

@MainActor
final class Tab: NSObject, ObservableObject {
    let webView: WKWebView
    weak var owner: BrowserWindow?
    let isPrivate: Bool

    @Published var title = ""
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var secure = false
    var isBlank: Bool { url == nil || url?.absoluteString == "about:blank" }

    private var observers: [NSKeyValueObservation] = []
    private var downloads: [WKDownload: URL] = [:]

    static func configuration(private isPrivate: Bool) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.setValue(true, forKey: "developerExtrasEnabled")
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        // Sites treat a bare WebKit UA as an unknown browser; say we're Safari
        c.applicationNameForUserAgent = "Version/26.2 Safari/605.1.15"
        return c
    }

    init(owner: BrowserWindow, isPrivate: Bool) {
        self.owner = owner
        self.isPrivate = isPrivate
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: Tab.configuration(private: isPrivate))
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = Theme.nsPaper

        observers = [
            webView.observe(\.title, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.title = w.title ?? "" } },
            webView.observe(\.url, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.urlChanged(w.url) } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.isLoading = w.isLoading } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.progress = w.estimatedProgress } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.canGoForward = w.canGoForward } },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] w, _ in Task { @MainActor in self?.secure = w.hasOnlySecureContent } },
        ]
    }

    private func urlChanged(_ u: URL?) {
        url = u
        let host = displayHost(u)
        let z = ZoomStore.zoom(for: host)
        if abs(webView.pageZoom - z) > 0.001 { webView.pageZoom = z }
    }

    func loadBlank() {
        webView.loadHTMLString(blankHTML, baseURL: nil)
    }

    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// A typed address: a URL if it looks like one, otherwise a search
    func open(_ text: String) {
        if let url = Tab.url(from: text) { load(url) }
    }

    static func url(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("/") || t.hasPrefix("~/") {
            return URL(fileURLWithPath: (t as NSString).expandingTildeInPath)
        }
        if let u = URL(string: t), let s = u.scheme, ["http", "https", "file", "about"].contains(s) { return u }
        if looksLikeHost(t), let u = URL(string: "https://" + t) { return u }
        var q = URLComponents(string: "https://www.google.com/search")!
        q.queryItems = [URLQueryItem(name: "q", value: t)]
        return q.url
    }

    static func looksLikeHost(_ t: String) -> Bool {
        if t.contains(" ") { return false }
        if t == "localhost" || t.hasPrefix("localhost:") { return true }
        let hostPart = t.split(separator: "/", maxSplits: 1).first.map(String.init) ?? t
        let noPort = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let parts = noPort.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else {
            return noPort.allSatisfy { $0.isNumber || $0 == "." } && parts.count == 4
        }
        return true
    }

    func zoom(by factor: Double?) {
        let z = factor.map { min(5, max(0.25, webView.pageZoom * $0)) } ?? 1
        webView.pageZoom = z
        ZoomStore.set(z, for: displayHost(url))
    }

    // MARK: Find

    private var findCount = 0
    private var findIndex = 0

    /// Finds the next (or previous) match and reports "index of count"; the count comes from the page text
    func find(_ text: String, forward: Bool, fresh: Bool, done: @escaping (Int, Int) -> Void) {
        guard !text.isEmpty else { findCount = 0; findIndex = 0; done(0, 0); return }
        let cfg = WKFindConfiguration()
        cfg.backwards = !forward
        cfg.caseSensitive = false
        cfg.wraps = true
        let count = { (cb: @escaping (Int) -> Void) in
            if !fresh && self.findCount > 0 { cb(self.findCount); return }
            let js = "(function(n){var t=(document.body?document.body.innerText:'').toLowerCase();n=n.toLowerCase();var c=0,i=0;while((i=t.indexOf(n,i))!==-1){c++;i+=n.length;}return c;})(\(Tab.jsString(text)))"
            self.webView.evaluateJavaScript(js) { v, _ in cb((v as? NSNumber)?.intValue ?? 0) }
        }
        count { total in
            self.findCount = total
            self.webView.find(text, configuration: cfg) { r in
                if !r.matchFound { self.findIndex = 0; done(0, total); return }
                if fresh { self.findIndex = 1 } else {
                    self.findIndex = forward ? (self.findIndex % max(total, 1)) + 1 : (self.findIndex <= 1 ? total : self.findIndex - 1)
                }
                done(self.findIndex, total)
            }
        }
    }

    func clearFind() {
        findCount = 0; findIndex = 0
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
    }

    static func jsString(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s])
        let a = String(data: d, encoding: .utf8)!
        return String(a.dropFirst().dropLast())
    }
}

// MARK: Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, let s = u.scheme, !["http", "https", "file", "about", "blob", "data", "javascript"].contains(s) {
            // mailto:, zoommtg:, and so on: hand them to macOS
            NSWorkspace.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isPrivate, let u = webView.url { History.shared.visit(u, title: webView.title ?? "") }
        owner?.sessionChanged()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: Downloads: straight into ~/Downloads, a pill while they run

extension Tab: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        var name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var url = URL(fileURLWithPath: Paths.downloads).appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            url = URL(fileURLWithPath: Paths.downloads).appendingPathComponent(name)
            n += 1
        }
        downloads[download] = url
        owner?.downloadStarted(download, name: name)
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        owner?.downloadFinished(download, file: downloads[download], failed: false)
        downloads[download] = nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        owner?.downloadFinished(download, file: nil, failed: true)
        downloads[download] = nil
    }
}

// MARK: Pop-ups and dialogs

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open: a new browser pane next to this one
        if let u = navigationAction.request.url { owner?.newBrowserPane(url: u, splitting: self) }
        return nil
    }

    private func sheet(_ message: String, cancel: Bool, field: String? = nil, done: @escaping (Bool, String?) -> Void) {
        let a = NSAlert()
        a.messageText = displayHost(url)
        a.informativeText = message
        a.addButton(withTitle: "OK")
        if cancel { a.addButton(withTitle: "Cancel") }
        var input: NSTextField?
        if let field {
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            f.stringValue = field
            a.accessoryView = f
            input = f
        }
        guard let w = webView.window else { done(true, input?.stringValue); return }
        a.beginSheetModal(for: w) { r in done(r == .alertFirstButtonReturn, input?.stringValue) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        sheet(message, cancel: false) { _, _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        sheet(message, cancel: true) { ok, _ in completionHandler(ok) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        sheet(prompt, cancel: true, field: defaultText ?? "") { ok, s in completionHandler(ok ? s : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        guard let w = webView.window else { completionHandler(nil); return }
        p.beginSheetModal(for: w) { r in completionHandler(r == .OK ? p.urls : nil) }
    }
}

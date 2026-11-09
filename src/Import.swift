// Importing cookies (so you stay signed in) and history (so the palette knows your pages) from another
// browser. ImportSources.swift reads them; this runs that off the main thread (the Keychain prompt for
// Chromium's cookie key blocks while it is up), writes the cookies into WebKit's default store and the
// visits into History, and reports in a pill.
import AppKit
import WebKit

/// The pill top right that says what an import did
struct Notice: Equatable {
    enum Kind { case busy, ok, warn, fail }
    var text: String
    var kind: Kind
    var link: URL?            // where a click goes (System Settings, for Full Disk Access)
}

@MainActor
enum Importer {
    private(set) static var sources: [ImportSource] = []
    private static var running = false
    private static var hide: DispatchWorkItem?

    /// Looked up when the palette opens, so its `> import …` rows are current
    static func refreshSources() { sources = BrowserSources.all() }

    struct Result {
        var cookies: [ImportedCookie] = []
        var visits: [ImportedVisit] = []
        var locked = 0
        var problems: [String] = []
        var needsDiskAccess = false
    }

    static func run(_ id: String, in window: BrowserWindow?, cookies: Bool = true, history: Bool = true) {
        if sources.isEmpty { refreshSources() }
        guard !running, let source = sources.first(where: { $0.id == id }) else { return }
        running = true
        show(Notice(text: "importing from \(source.label)…", kind: .busy), in: window, for: nil)
        Task.detached(priority: .userInitiated) {
            let r = read(source, cookies: cookies, history: history)
            await MainActor.run {
                Task { @MainActor in
                    let stored = await store(r.cookies)
                    let pages = History.shared.merge(r.visits)
                    running = false
                    show(summary(source, r, stored: stored, pages: pages, cookies: cookies, history: history), in: window, for: 10)
                }
            }
        }
    }

    /// Everything that can block or take time: file copies, SQLite, the Keychain prompt
    nonisolated private static func read(_ source: ImportSource, cookies: Bool, history: Bool) -> Result {
        var r = Result()
        func note(_ what: String, _ error: Error) {
            switch error {
            case ImportError.noAccess: r.needsDiskAccess = true
            case ImportError.missing: break
            case ImportError.unreadable(let why): r.problems.append("\(what): \(why)")
            default: r.problems.append("\(what): \(error.localizedDescription)")
            }
        }
        switch source.kind {
        case .chromium(let service, let account):
            if cookies {
                var password: Data?
                switch BrowserSources.keychainPassword(service: service, account: account) {
                case .success(let d): password = d
                case .failure: r.problems.append("keychain said no")
                }
                do {
                    let read = try BrowserSources.chromiumCookies(source, password: password)
                    r.cookies = read.cookies
                    r.locked = read.locked
                    if password != nil, read.locked > 0 { r.problems.append("\(read.locked) cookies would not decrypt") }
                } catch { note("cookies", error) }
            }
            if history { do { r.visits = try BrowserSources.chromiumHistory(source) } catch { note("history", error) } }
        case .safari:
            if cookies { do { r.cookies = try BrowserSources.safariCookies(source) } catch { note("cookies", error) } }
            if history { do { r.visits = try BrowserSources.safariHistory(source) } catch { note("history", error) } }
        }
        return r
    }

    static func httpCookie(_ c: ImportedCookie) -> HTTPCookie? {
        var p: [HTTPCookiePropertyKey: Any] = [.domain: c.domain, .path: c.path.isEmpty ? "/" : c.path, .name: c.name, .value: c.value]
        if c.secure { p[.secure] = "TRUE" }
        if c.httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let e = c.expires { p[.expires] = e }
        if let s = c.sameSite { p[.sameSitePolicy] = s }
        return HTTPCookie(properties: p)
    }

    /// Into the default (non-private) store, the one every normal window uses
    private static func store(_ cookies: [ImportedCookie]) async -> Int {
        let jar = WKWebsiteDataStore.default().httpCookieStore
        var n = 0
        for c in cookies {
            guard let cookie = httpCookie(c) else { continue }
            await jar.setCookie(cookie)
            n += 1
        }
        return n
    }

    private static func summary(_ source: ImportSource, _ r: Result, stored: Int, pages: Int, cookies: Bool, history: Bool) -> Notice {
        if r.needsDiskAccess, stored == 0, pages == 0 {
            return Notice(text: "\(source.browser) needs full disk access for casa", kind: .fail,
                          link: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"))
        }
        var parts: [String] = []
        if cookies { parts.append("\(stored.formatted()) cookies") }
        if history { parts.append("\(pages.formatted()) new pages") }
        var text = "\(source.browser): " + parts.joined(separator: " \u{B7} ")
        if let first = r.problems.first { text += " \u{B7} " + first }
        let failed = (cookies && stored == 0) && (history ? pages == 0 : true)
        return Notice(text: text, kind: failed ? .fail : r.problems.isEmpty ? .ok : .warn)
    }

    private static func show(_ notice: Notice, in window: BrowserWindow?, for seconds: Double?) {
        hide?.cancel()
        let w = window ?? AppDelegate.shared.keyBrowserWindow
        w?.state.notice = notice
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak w] in if w?.state.notice == notice { w?.state.notice = nil } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Debug (CASA_DEBUG): checks without a browser or a Keychain prompt

    /// Sets one cookie through the same path an import takes, reads it back from WebKit, logs which
    /// attributes survived, and removes it again
    static func selfTest() async {
        let jar = WKWebsiteDataStore.default().httpCookieStore
        let cases = [
            ImportedCookie(domain: ".casa-selftest.invalid", name: "casa_a", value: "v1", path: "/", expires: Date().addingTimeInterval(3600), secure: true, httpOnly: true, sameSite: "lax"),
            ImportedCookie(domain: "casa-selftest.invalid", name: "casa_b", value: "v2", path: "/x", expires: nil, secure: false, httpOnly: false, sameSite: "strict"),
            ImportedCookie(domain: ".casa-selftest.invalid", name: "casa_c", value: "v3", path: "/", expires: Date().addingTimeInterval(3600), secure: true, httpOnly: false, sameSite: "none"),
            ImportedCookie(domain: ".casa-selftest.invalid", name: "casa_d", value: "v4", path: "/", expires: Date().addingTimeInterval(3600), secure: false, httpOnly: false, sameSite: nil),
        ]
        for c in cases { if let k = httpCookie(c) { await jar.setCookie(k) } else { NSLog("Casa selftest: could not build %@", c.name) } }
        let back = await jar.allCookies().filter { $0.domain.contains("casa-selftest.invalid") }.sorted { $0.name < $1.name }
        for k in back {
            NSLog("Casa selftest: %@ domain=%@ path=%@ value=%@ secure=%d httpOnly=%d session=%d sameSite=%@", k.name, k.domain, k.path, k.value,
                  k.isSecure ? 1 : 0, k.isHTTPOnly ? 1 : 0, k.isSessionOnly ? 1 : 0, k.sameSitePolicy?.rawValue ?? "-")
            await jar.deleteCookie(k)
        }
        let left = await jar.allCookies().filter { $0.domain.contains("casa-selftest.invalid") }.count
        NSLog("Casa selftest: %d read back of %d, %d left after cleanup", back.count, cases.count, left)
    }

    /// Writes "domain name secure httpOnly session sameSite" per cookie in the store (no values) to a file
    static func dumpCookieFlags(to path: String) async {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let lines = all.map { "\($0.domain)\t\($0.name)\t\($0.isSecure ? 1 : 0)\t\($0.isHTTPOnly ? 1 : 0)\t\($0.isSessionOnly ? 1 : 0)\t\($0.sameSitePolicy?.rawValue ?? "-")" }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        NSLog("Casa cookie-dump: %d cookies", all.count)
    }
}

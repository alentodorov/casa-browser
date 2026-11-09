// A window is a tab group: the widgets' chromeless window pattern, a web view that fills it with the
// pill floating in its top strip, and the console as a split under the web view.
import AppKit
import Combine
import SwiftUI
import WebKit

enum Mode { case rest, palette, find, switcher }
enum PaletteMode { case url, tabs }

struct PaletteRow: Identifiable {
    enum Kind { case tab(Int), history(String), url(String), search(String), command(String) }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let glyph: String
}

struct DownloadPill {
    var name: String
    var finished = false
    var failed = false
    var file: URL?
}

@MainActor
final class WindowState: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var active = 0
    @Published var mode: Mode = .rest
    @Published var hover = false
    @Published var paletteMode: PaletteMode = .url
    @Published var paletteQuery = "" { didSet { recomputePalette() } }
    @Published var paletteRows: [PaletteRow] = []
    @Published var paletteSelection = 0
    @Published var findQuery = "" { didSet { window?.findChanged() } }
    @Published var findIndex = 0
    @Published var findTotal = 0
    @Published var switcherSelection = 0
    @Published var download: DownloadPill?
    @Published var consoleOpen = false
    let isPrivate: Bool
    weak var window: BrowserWindow?

    init(isPrivate: Bool) { self.isPrivate = isPrivate }
    var current: Tab? { tabs.indices.contains(active) ? tabs[active] : nil }

    static let commands: [(String, String)] = [
        ("new window", "new-window"), ("new private window", "private-window"), ("toggle console", "console"),
        ("reload", "reload"), ("copy url", "copy-url"), ("reset zoom", "zoom-reset"), ("close tab", "close-tab"),
        ("reopen closed tab", "reopen"), ("downloads folder", "downloads"), ("web inspector", "inspector"),
    ]

    func recomputePalette() {
        let q = paletteQuery.trimmingCharacters(in: .whitespaces)
        var rows: [PaletteRow] = []
        if q.hasPrefix(">") {
            let needle = q.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
            for (title, id) in WindowState.commands where needle.isEmpty || title.contains(needle) {
                rows.append(PaletteRow(id: "cmd:" + id, kind: .command(id), title: title, subtitle: "", glyph: Theme.command))
            }
        } else if q.isEmpty {
            if paletteMode == .tabs {
                for (i, t) in tabs.enumerated() { rows.append(tabRow(i, t)) }
            }
        } else {
            let needle = q.lowercased()
            for (i, t) in tabs.enumerated() where i != active || paletteMode == .tabs {
                let hay = (t.title + " " + (t.url?.absoluteString ?? "")).lowercased()
                if hay.contains(needle) { rows.append(tabRow(i, t)) }
                if rows.count >= 4 { break }
            }
            for e in History.shared.search(q) where !rows.contains(where: { $0.subtitle == e.url }) {
                rows.append(PaletteRow(id: "hist:" + e.url, kind: .history(e.url),
                                       title: e.title.isEmpty ? e.url : e.title, subtitle: shortURL(e.url), glyph: Theme.history))
            }
            if let u = Tab.url(from: q), u.scheme != nil, !u.absoluteString.contains("google.com/search") {
                rows.append(PaletteRow(id: "url:" + q, kind: .url(q), title: q, subtitle: "open", glyph: Theme.web))
            }
            rows.append(PaletteRow(id: "search:" + q, kind: .search(q), title: "search \u{201C}\(q)\u{201D}", subtitle: "google.com", glyph: Theme.search))
            // The direct address goes first when it is one
            if case .url = rows.last.map({ $0.kind }) ?? .search(""), rows.count > 1 {} // keep order
            if let i = rows.firstIndex(where: { if case .url = $0.kind { return true } else { return false } }), i != 0 {
                let r = rows.remove(at: i); rows.insert(r, at: 0)
            }
        }
        paletteRows = rows
        paletteSelection = 0
    }

    private func tabRow(_ i: Int, _ t: Tab) -> PaletteRow {
        let host = displayHost(t.url)
        return PaletteRow(id: "tab:\(ObjectIdentifier(t).hashValue)", kind: .tab(i),
                          title: t.title.isEmpty ? (host.isEmpty ? "new tab" : host) : t.title, subtitle: host, glyph: Theme.tab)
    }

    private func shortURL(_ s: String) -> String {
        guard let u = URL(string: s) else { return s }
        var r = displayHost(u) + u.path
        if r.hasSuffix("/") { r.removeLast() }
        return r.count > 48 ? String(r.prefix(45)) + "…" : r
    }
}

/// The divider between the page and the console
final class ConsoleSplit: NSSplitView {
    override var dividerColor: NSColor { Theme.nsBase100 }
    override var dividerThickness: CGFloat { 1 }
}

/// The strip's hosting view: empty parts of it drag the window, like a title bar would.
/// The window's hidden title bar is still a 32pt safe area, which would push the pill and the
/// overlays down by it; both hosting views lay out from the very top instead.
final class StripHost<V: View>: NSHostingView<V> {
    required init(rootView: V) { super.init(rootView: rootView); safeAreaRegions = [] }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayHost<V: View>: NSHostingView<V> {
    required init(rootView: V) { super.init(rootView: rootView); safeAreaRegions = [] }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class BrowserWindow: NSWindow, NSWindowDelegate {
    let state: WindowState
    let isPrivate: Bool
    private let split = ConsoleSplit()
    private let webHost = NSView()
    private var strip: StripHost<StripView>!
    private var overlay: OverlayHost<OverlayView>?
    private(set) var terminal: TerminalView?
    private var consoleHeight: CGFloat = 320
    private var closedTabs: [URL] = []
    private var titleSub: AnyCancellable?
    private var flagsMonitor: Any?
    private var downloadHide: DispatchWorkItem?

    init(isPrivate: Bool, frame: NSRect? = nil) {
        self.isPrivate = isPrivate
        state = WindowState(isPrivate: isPrivate)
        let rect = frame ?? BrowserWindow.defaultFrame()
        super.init(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        state.window = self
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: 480, height: 320)
        backgroundColor = Theme.nsPaper
        tabbingMode = .disallowed
        delegate = self
        title = isPrivate ? "Casa (private)" : "Casa"

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.autoresizesSubviews = true
        split.isVertical = false
        split.dividerStyle = .thin
        split.frame = container.bounds
        split.autoresizingMask = [.width, .height]
        webHost.autoresizesSubviews = true
        split.addArrangedSubview(webHost)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        container.addSubview(split)

        strip = StripHost(rootView: StripView(state: state))
        strip.frame = NSRect(x: 0, y: rect.height - Theme.stripHeight, width: rect.width, height: Theme.stripHeight)
        strip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(strip)
        contentView = container

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            guard let self, self.state.mode == .switcher, self.isKeyWindow, !e.modifierFlags.contains(.control) else { return e }
            self.commitSwitcher()
            return e
        }
    }

    static func defaultFrame() -> NSRect {
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(1280, s.width - 40), h = min(820, s.height - 40)
        return NSRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h)
    }

    var current: Tab? { state.current }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL?, select: Bool = true, openPaletteIfBlank: Bool = true) -> Tab {
        let tab = Tab(owner: self, isPrivate: isPrivate)
        state.tabs.append(tab)
        if let url { tab.load(url) } else { tab.loadBlank() }
        if select {
            self.select(state.tabs.count - 1)
            if url == nil, openPaletteIfBlank { openPalette(.url) }
        }
        sessionChanged()
        return tab
    }

    func select(_ i: Int) {
        guard state.tabs.indices.contains(i) else { return }
        state.active = i
        let tab = state.tabs[i]
        webHost.subviews.forEach { $0.removeFromSuperview() }
        tab.webView.frame = webHost.bounds
        webHost.addSubview(tab.webView)
        titleSub = tab.$title.sink { [weak self] t in self?.title = t.isEmpty ? displayHost(tab.url) : t }
        if state.mode == .rest { makeFirstResponder(tab.webView) }
        sessionChanged()
    }

    func closeTab(_ index: Int? = nil) {
        let i = index ?? state.active
        guard state.tabs.indices.contains(i) else { return }
        let tab = state.tabs[i]
        if let u = tab.url, !tab.isBlank { closedTabs.append(u) }
        tab.webView.removeFromSuperview()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        state.tabs.remove(at: i)
        if state.tabs.isEmpty { close(); return }
        select(min(i, state.tabs.count - 1))
    }

    func reopenTab() {
        guard let u = closedTabs.popLast() else { return }
        newTab(url: u)
    }

    func nextTab(_ delta: Int) {
        guard state.tabs.count > 1 else { return }
        select((state.active + delta + state.tabs.count) % state.tabs.count)
    }

    func cwdForConsole() -> String {
        if let u = current?.url, u.isFileURL {
            var dir: ObjCBool = false
            let p = u.path
            if FileManager.default.fileExists(atPath: p, isDirectory: &dir) { return dir.boolValue ? p : (p as NSString).deletingLastPathComponent }
        }
        return FileManager.default.fileExists(atPath: Paths.projects) ? Paths.projects : Paths.home
    }

    // MARK: Navigation

    func goBack() { current?.webView.goBack() }
    func goForward() { current?.webView.goForward() }
    func reload(hard: Bool) {
        guard let t = current else { return }
        if t.isLoading { t.webView.stopLoading(); return }
        if hard { t.webView.reloadFromOrigin() } else { t.webView.reload() }
    }
    func stop() { current?.webView.stopLoading() }

    func zoom(_ factor: Double?) { current?.zoom(by: factor) }

    func copyURL() {
        guard let u = current?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
    }

    // MARK: Overlays

    private func showOverlay() {
        guard overlay == nil, let container = contentView else { return }
        let o = OverlayHost(rootView: OverlayView(state: state))
        o.frame = container.bounds
        o.autoresizingMask = [.width, .height]
        container.addSubview(o, positioned: .above, relativeTo: strip)
        overlay = o
    }

    func closeOverlay() {
        let was = state.mode
        state.mode = .rest
        overlay?.removeFromSuperview()
        overlay = nil
        if was == .find { current?.clearFind() }
        if let t = current { makeFirstResponder(t.webView) }
    }

    func openPalette(_ mode: PaletteMode) {
        if state.mode == .find { closeOverlay() }
        state.paletteMode = mode
        state.paletteQuery = mode == .url ? (current?.isBlank == true ? "" : current?.url?.absoluteString ?? "") : ""
        state.mode = .palette
        showOverlay()
    }

    func moveSelection(_ delta: Int) {
        switch state.mode {
        case .palette:
            guard !state.paletteRows.isEmpty else { return }
            state.paletteSelection = (state.paletteSelection + delta + state.paletteRows.count) % state.paletteRows.count
        case .switcher:
            guard !state.tabs.isEmpty else { return }
            state.switcherSelection = (state.switcherSelection + delta + state.tabs.count) % state.tabs.count
        default: break
        }
    }

    func runPalette() {
        let q = state.paletteQuery.trimmingCharacters(in: .whitespaces)
        let row = state.paletteRows.indices.contains(state.paletteSelection) ? state.paletteRows[state.paletteSelection] : nil
        closeOverlay()
        guard let row else {
            if !q.isEmpty { current?.open(q) }
            return
        }
        switch row.kind {
        case .tab(let i): select(i)
        case .history(let u): if let url = URL(string: u) { current?.load(url) }
        case .url(let s), .search(let s): current?.open(s)
        case .command(let id): runCommand(id)
        }
    }

    func runCommand(_ id: String) {
        switch id {
        case "new-window": AppDelegate.shared.newWindow(private: false)
        case "private-window": AppDelegate.shared.newWindow(private: true)
        case "console": toggleConsole()
        case "reload": reload(hard: false)
        case "copy-url": copyURL()
        case "zoom-reset": zoom(nil)
        case "close-tab": closeTab()
        case "reopen": reopenTab()
        case "downloads": revealDownload()
        case "inspector": showInspector()
        default: break
        }
    }

    func openFind() {
        if state.mode == .palette || state.mode == .switcher { closeOverlay() }
        state.findIndex = 0; state.findTotal = 0
        state.mode = .find
    }

    private var findWork: DispatchWorkItem?
    func findChanged() {
        guard state.mode == .find else { return }
        findWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.current?.find(self.state.findQuery, forward: true, fresh: true) { i, n in
                self.state.findIndex = i; self.state.findTotal = n
            }
        }
        findWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func findNext(forward: Bool) {
        if state.mode != .find { openFind(); return }
        current?.find(state.findQuery, forward: forward, fresh: false) { [weak self] i, n in
            self?.state.findIndex = i; self?.state.findTotal = n
        }
    }

    func showSwitcher(delta: Int) {
        guard !state.tabs.isEmpty else { return }
        if state.mode != .switcher {
            if state.mode != .rest { closeOverlay() }
            state.switcherSelection = state.active
            state.mode = .switcher
            showOverlay()
        }
        moveSelection(delta)
    }

    func commitSwitcher() {
        let i = state.switcherSelection
        closeOverlay()
        select(i)
    }

    func showInspector() {
        current?.webView.evaluateJavaScript("void 0", completionHandler: nil)
        // WebKit opens its inspector from the context menu or this private-ish menu item; the public API only flags inspectability
        if let wv = current?.webView, let inspector = wv.value(forKey: "_inspector") as? NSObject {
            inspector.perform(NSSelectorFromString("show"))
        }
    }

    // MARK: Console

    func toggleConsole() {
        if state.consoleOpen {
            if let t = terminal, split.arrangedSubviews.contains(t) {
                consoleHeight = t.frame.height
                split.removeArrangedSubview(t)
                t.removeFromSuperview()
            }
            state.consoleOpen = false
            if let tab = current { makeFirstResponder(tab.webView) }
            return
        }
        if terminal == nil {
            guard let t = TerminalView(workingDirectory: cwdForConsole(), owner: self) else {
                NSSound.beep(); return
            }
            terminal = t
        }
        guard let t = terminal else { return }
        split.addArrangedSubview(t)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 1)
        split.layoutSubtreeIfNeeded()
        let h = min(max(consoleHeight, 120), split.bounds.height - 160)
        split.setPosition(split.bounds.height - h - split.dividerThickness, ofDividerAt: 0)
        state.consoleOpen = true
        makeFirstResponder(t)
    }

    func setConsoleHeight(_ h: CGFloat) {
        guard state.consoleOpen else { return }
        split.setPosition(split.bounds.height - h - split.dividerThickness, ofDividerAt: 0)
    }

    /// The shell exited (or the surface failed): drop the console
    func consoleEnded() {
        if let t = terminal {
            if split.arrangedSubviews.contains(t) { split.removeArrangedSubview(t) }
            t.removeFromSuperview()
            t.tearDown()
        }
        terminal = nil
        state.consoleOpen = false
        if let tab = current { makeFirstResponder(tab.webView) }
    }

    // MARK: Downloads

    func downloadStarted(_ d: WKDownload, name: String) {
        downloadHide?.cancel()
        state.download = DownloadPill(name: name)
    }

    func downloadFinished(_ d: WKDownload, file: URL?, failed: Bool) {
        state.download = DownloadPill(name: state.download?.name ?? file?.lastPathComponent ?? "download", finished: !failed, failed: failed, file: file)
        let w = DispatchWorkItem { [weak self] in self?.state.download = nil }
        downloadHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 6 : 4), execute: w)
    }

    func revealDownload() {
        if let f = state.download?.file {
            NSWorkspace.shared.activateFileViewerSelecting([f])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: Paths.downloads))
        }
    }

    // MARK: Session

    func sessionChanged() { AppDelegate.shared.sessionChanged() }

    var sessionWindow: Session.Window? {
        guard !isPrivate else { return nil }
        let urls = state.tabs.compactMap { $0.isBlank ? nil : $0.url?.absoluteString }
        guard !urls.isEmpty else { return nil }
        let f = frame
        return Session.Window(urls: urls, active: min(state.active, urls.count - 1), frame: [f.minX, f.minY, f.width, f.height], console: state.consoleOpen)
    }

    func windowDidResize(_ notification: Notification) { sessionChanged() }
    func windowDidMove(_ notification: Notification) { sessionChanged() }

    func windowDidBecomeKey(_ notification: Notification) {
        if state.mode == .rest, let t = current, firstResponder === self { makeFirstResponder(t.webView) }
    }

    func windowWillClose(_ notification: Notification) {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        terminal?.tearDown()
        terminal = nil
        for t in state.tabs { t.webView.navigationDelegate = nil; t.webView.uiDelegate = nil }
        AppDelegate.shared.windowClosed(self)
    }

    // MARK: Menu actions (first responder chain)

    @objc func newTab(_ s: Any?) { newTab(url: nil) }
    @objc func closeTabAction(_ s: Any?) { closeTab() }
    @objc func reopenClosedTab(_ s: Any?) { reopenTab() }
    @objc func openLocation(_ s: Any?) { openPalette(.url) }
    @objc func searchTabs(_ s: Any?) { openPalette(.tabs) }
    @objc func nextTabAction(_ s: Any?) { nextTab(1) }
    @objc func previousTabAction(_ s: Any?) { nextTab(-1) }
    @objc func switchTabNext(_ s: Any?) { showSwitcher(delta: 1) }
    @objc func switchTabPrevious(_ s: Any?) { showSwitcher(delta: -1) }
    @objc func selectTabByNumber(_ s: Any?) {
        guard let item = s as? NSMenuItem else { return }
        if item.tag == 9 { select(state.tabs.count - 1) } else { select(item.tag - 1) }
    }
    @objc func goBack(_ s: Any?) { goBack() }
    @objc func goForward(_ s: Any?) { goForward() }
    @objc func reloadPage(_ s: Any?) { current?.webView.reload() }
    @objc func reloadPageFromOrigin(_ s: Any?) { reload(hard: true) }
    @objc func stopLoading(_ s: Any?) { stop() }
    @objc func zoomIn(_ s: Any?) { zoom(1.1) }
    @objc func zoomOut(_ s: Any?) { zoom(1 / 1.1) }
    @objc func zoomReset(_ s: Any?) { zoom(nil) }
    @objc func copyPageURL(_ s: Any?) { copyURL() }
    @objc func findInPage(_ s: Any?) { openFind() }
    @objc func findNextMatch(_ s: Any?) { findNext(forward: true) }
    @objc func findPreviousMatch(_ s: Any?) { findNext(forward: false) }
    @objc func toggleConsole(_ s: Any?) { toggleConsole() }
    @objc func showDownloads(_ s: Any?) { revealDownload() }
    @objc func showWebInspector(_ s: Any?) { showInspector() }
}

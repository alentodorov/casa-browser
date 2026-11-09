// A window holds numbered workspaces, each a dwindle tree of browser and terminal panes (Layout.swift),
// under a 36pt strip with the workspace numbers and the pill. Omarchy's keys move focus, swap, split,
// resize and zoom panes and move them between workspaces; the chrome follows the focused pane.
import AppKit
import Combine
import SwiftUI
import WebKit

enum Mode { case rest, palette, find, switcher }
enum PaletteMode { case url, tabs }

struct PaletteRow: Identifiable {
    enum Kind { case pane(UUID), history(String), url(String), search(String), command(String) }
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
    @Published var workspaces: [Workspace] = []   // sorted by number
    @Published var current: Workspace?
    @Published var focused: Pane?
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
    let isPrivate: Bool
    weak var window: BrowserWindow?

    init(isPrivate: Bool) { self.isPrivate = isPrivate }

    /// The focused browser pane's tab, or the workspace's first browser if a terminal is focused
    var currentTab: Tab? { focused?.tab ?? current?.panes.first(where: { $0.isBrowser })?.tab }

    static let commands: [(String, String)] = [
        ("new terminal", "terminal"), ("new browser pane", "browser"), ("new workspace", "workspace"),
        ("zoom pane", "zoom"), ("flip split", "flip"), ("new window", "new-window"), ("new private window", "private-window"),
        ("reload", "reload"), ("copy url", "copy-url"), ("zoom in", "zoom-in"), ("zoom out", "zoom-out"), ("reset zoom", "zoom-reset"),
        ("close pane", "close-pane"), ("reopen closed pane", "reopen"), ("downloads folder", "downloads"), ("web inspector", "inspector"),
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
                for w in workspaces { for p in w.panes { rows.append(paneRow(w, p)) } }
            }
        } else {
            let needle = q.lowercased()
            for w in workspaces {
                for p in w.panes where p !== focused || paletteMode == .tabs {
                    let hay = (p.title + " " + (p.tab?.url?.absoluteString ?? p.terminal?.pwd ?? "")).lowercased()
                    if hay.contains(needle) { rows.append(paneRow(w, p)) }
                    if rows.count >= 4 { break }
                }
            }
            for e in History.shared.search(q) where !rows.contains(where: { $0.subtitle == e.url }) {
                rows.append(PaletteRow(id: "hist:" + e.url, kind: .history(e.url),
                                       title: e.title.isEmpty ? e.url : e.title, subtitle: shortURL(e.url), glyph: Theme.history))
            }
            if let u = Tab.url(from: q), u.scheme != nil, !u.absoluteString.contains("google.com/search") {
                rows.insert(PaletteRow(id: "url:" + q, kind: .url(q), title: q, subtitle: "open", glyph: Theme.web), at: 0)
            }
            rows.append(PaletteRow(id: "search:" + q, kind: .search(q), title: "search \u{201C}\(q)\u{201D}", subtitle: "google.com", glyph: Theme.search))
        }
        paletteRows = rows
        paletteSelection = 0
    }

    private func paneRow(_ w: Workspace, _ p: Pane) -> PaletteRow {
        let title = p.title.isEmpty ? (p.host.isEmpty ? (p.isBrowser ? "new tab" : "terminal") : p.host) : p.title
        let sub = p.isBrowser ? p.host : (p.terminal?.pwd ?? p.terminal?.workingDirectory ?? "")
        return PaletteRow(id: "pane:\(p.id)", kind: .pane(p.id), title: title,
                          subtitle: "\(w.number)  " + sub, glyph: p.isBrowser ? Theme.tab : Theme.console)
    }

    private func shortURL(_ s: String) -> String {
        guard let u = URL(string: s) else { return s }
        var r = displayHost(u) + u.path
        if r.hasSuffix("/") { r.removeLast() }
        return r.count > 48 ? String(r.prefix(45)) + "…" : r
    }
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

/// The area under the strip: the current workspace's panes, laid out by its tree
@MainActor
final class TilesView: NSView {
    override var isFlipped: Bool { true }
    private(set) var workspace: Workspace?
    private var focused: Pane?

    func show(_ w: Workspace?, focused f: Pane?) {
        workspace = w
        focused = f
        let boxes = Set((w?.panes ?? []).map { ObjectIdentifier($0.box) })
        for v in subviews where !boxes.contains(ObjectIdentifier(v)) { v.removeFromSuperview() }
        for p in w?.panes ?? [] where p.box.superview !== self { addSubview(p.box) }
        relayout()
    }

    func relayout() {
        guard let w = workspace else { return }
        let frames = w.layout(in: bounds)
        let tiled = w.panes.count > 1 && w.zoomed == nil
        for p in w.panes {
            if let f = frames[p.id] {
                p.box.isHidden = false
                p.box.frame = f
            } else {
                p.box.isHidden = true   // zoomed away
            }
            p.box.style(focused: p === focused, tiled: tiled)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    /// The pane under a point in window coordinates
    func pane(at windowPoint: NSPoint) -> Pane? {
        let p = convert(windowPoint, from: nil)
        return workspace?.panes.first { !$0.box.isHidden && $0.box.frame.contains(p) }
    }
}

@MainActor
final class BrowserWindow: NSWindow, NSWindowDelegate {
    let state: WindowState
    let isPrivate: Bool
    private let tiles = TilesView()
    private var strip: StripHost<StripView>!
    private var overlay: OverlayHost<OverlayView>?
    private var closedURLs: [URL] = []
    private var titleSub: AnyCancellable?
    private var monitors: [Any] = []
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
        tiles.frame = NSRect(x: 0, y: 0, width: rect.width, height: rect.height - Theme.stripHeight)
        tiles.autoresizingMask = [.width, .height]
        container.addSubview(tiles)
        strip = StripHost(rootView: StripView(state: state))
        strip.frame = NSRect(x: 0, y: rect.height - Theme.stripHeight, width: rect.width, height: Theme.stripHeight)
        strip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(strip)
        contentView = container

        // ctrl released while the switcher is up: commit
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            guard let self, self.state.mode == .switcher, self.isKeyWindow, !e.modifierFlags.contains(.control) else { return e }
            self.commitSwitcher()
            return e
        }!)
        // A click in a pane focuses it (the web view and the terminal also take first responder themselves,
        // which makeFirstResponder above turns into the same focus change)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self, e.window === self, self.state.mode == .rest, let p = self.tiles.pane(at: e.locationInWindow) else { return e }
            if p !== self.state.focused { self.focus(p, makeFirst: false) }
            return e
        }!)
        // Omarchy's keys, ahead of the web view and Ghostty: cmd-arrows focus, cmd-shift-arrows swap,
        // cmd-shift-1…9 move the pane to a workspace
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self, self.state.mode == .rest else { return e }
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard f.contains(.command), !f.contains(.control), !f.contains(.option) else { return e }
            let shift = f.contains(.shift)
            let dirs: [UInt16: Direction] = [123: .left, 124: .right, 125: .down, 126: .up]
            if let d = dirs[e.keyCode] {
                if shift { self.swap(d) } else { self.focus(d) }
                return nil
            }
            let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
            if shift, let n = digits[e.keyCode] { self.movePane(toWorkspace: n); return nil }
            return e
        }!)
    }

    /// Whatever moves keyboard focus into a pane (a click, a page focusing a field, a link from a
    /// terminal, the key monitor) also moves the outline: the focused pane follows the first responder
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        if ok, state.mode == .rest, let v = responder as? NSView, let w = current,
           let p = w.panes.first(where: { v === $0.view || v.isDescendant(of: $0.box) }), p !== focused {
            focus(p, makeFirst: false)
        }
        return ok
    }

    static func defaultFrame() -> NSRect {
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(1280, s.width - 40), h = min(820, s.height - 40)
        return NSRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h)
    }

    var current: Workspace? { state.current }
    var focused: Pane? { state.focused }
    var currentTab: Tab? { state.currentTab }

    // MARK: Workspaces

    private func sortWorkspaces() { state.workspaces.sort { $0.number < $1.number } }

    func workspace(_ n: Int) -> Workspace? { state.workspaces.first { $0.number == n } }

    var lowestFreeNumber: Int {
        var n = 1
        while workspace(n) != nil { n += 1 }
        return n
    }

    /// Goes to workspace `n`; an empty one gets a blank browser pane with the palette open
    func goToWorkspace(_ n: Int) {
        if let w = workspace(n) { switchTo(w); return }
        let w = Workspace(number: n)
        state.workspaces.append(w); sortWorkspaces()
        switchTo(w)
        newBrowserPane(url: nil)
    }

    /// cmd-T: a new workspace at the lowest free number
    @discardableResult
    func newWorkspace(url: URL?) -> Workspace {
        let w = Workspace(number: lowestFreeNumber)
        state.workspaces.append(w); sortWorkspaces()
        switchTo(w)
        newBrowserPane(url: url)
        return w
    }

    func switchTo(_ w: Workspace) {
        if state.mode != .rest { closeOverlay() }
        state.current = w
        state.focused = w.focused
        tiles.show(w, focused: w.focused)
        if let p = w.focused { makeFirstResponder(p.view) }
        titleSub = w.focused?.$title.sink { [weak self] t in self?.title = t.isEmpty ? "Casa" : t }
        sessionChanged()
    }

    func nextWorkspace(_ delta: Int) {
        guard let c = current, let i = state.workspaces.firstIndex(where: { $0 === c }), state.workspaces.count > 1 else { return }
        switchTo(state.workspaces[(i + delta + state.workspaces.count) % state.workspaces.count])
    }

    /// Drops an empty workspace from the list and shows a neighbour (or closes the window)
    private func workspaceEmptied(_ w: Workspace) {
        state.workspaces.removeAll { $0 === w }
        guard state.current === w else { return }
        if state.workspaces.isEmpty { close(); return }
        let next = state.workspaces.first { $0.number > w.number } ?? state.workspaces.last!
        switchTo(next)
    }

    // MARK: Panes

    private func cwdForNewTerminal() -> String {
        if let t = focused?.terminal { return t.pwd ?? t.workingDirectory }
        if let u = focused?.tab?.url, u.isFileURL {
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) { return dir.boolValue ? u.path : (u.path as NSString).deletingLastPathComponent }
        }
        return FileManager.default.fileExists(atPath: Paths.projects) ? Paths.projects : Paths.home
    }

    private func add(_ pane: Pane, splitting target: Pane? = nil) {
        if state.mode != .rest { closeOverlay() }
        if current == nil { goToWorkspace(lowestFreeNumber) }
        guard let w = current else { return }
        w.insert(pane, splitting: target)
        refresh()
        makeFirstResponder(pane.view)
        sessionChanged()
    }

    /// A browser pane next to the focused one (or the one `splitting`); blank ones open the palette
    @discardableResult
    func newBrowserPane(url: URL?, splitting from: Tab? = nil) -> Pane {
        let tab = Tab(owner: self, isPrivate: isPrivate)
        let pane = Pane(.browser(tab))
        let target = from.flatMap { t in current?.panes.first { $0.tab === t } }
        if let url { tab.load(url) } else { tab.loadBlank() }
        add(pane, splitting: target)
        if url == nil { openPalette(.url) }
        return pane
    }

    func newTerminalPane() {
        guard let t = TerminalView(workingDirectory: cwdForNewTerminal(), owner: self) else { NSSound.beep(); return }
        add(Pane(.terminal(t)))
    }

    /// cmd-W: the focused pane; the last pane takes its workspace with it, the last workspace the window
    func closePane() {
        guard let w = current, let p = focused else { return }
        if let u = p.tab?.url, p.tab?.isBlank == false { closedURLs.append(u) }
        w.remove(p)
        tearDown(p)
        if w.isEmpty { workspaceEmptied(w) } else { refresh(); if let f = w.focused { makeFirstResponder(f.view) } }
        sessionChanged()
    }

    private func tearDown(_ p: Pane) {
        p.box.removeFromSuperview()
        if let t = p.tab { t.webView.navigationDelegate = nil; t.webView.uiDelegate = nil; t.webView.stopLoading() }
        p.terminal?.tearDown()
    }

    func reopenPane() {
        guard let u = closedURLs.popLast() else { return }
        newBrowserPane(url: u)
    }

    /// The shell exited (or the surface failed): the pane goes
    func terminalEnded(_ t: TerminalView) {
        guard let w = state.workspaces.first(where: { ws in ws.panes.contains { $0.terminal === t } }),
              let p = w.panes.first(where: { $0.terminal === t }) else { return }
        w.remove(p)
        tearDown(p)
        if w.isEmpty { workspaceEmptied(w) } else if w === current { refresh(); if let f = w.focused { makeFirstResponder(f.view) } }
        sessionChanged()
    }

    func focus(_ p: Pane, makeFirst: Bool = true) {
        guard let w = current, w.panes.contains(where: { $0 === p }) else { return }
        w.setFocus(p)
        state.focused = p
        titleSub = p.$title.sink { [weak self] t in self?.title = t.isEmpty ? "Casa" : t }
        tiles.relayout()
        if makeFirst { makeFirstResponder(p.view) }
    }

    func focus(_ dir: Direction) {
        guard let w = current, let p = focused, let n = w.neighbour(of: p, dir) else { return }
        focus(n)
    }

    func swap(_ dir: Direction) {
        guard let w = current, let p = focused, let n = w.neighbour(of: p, dir) else { return }
        w.swap(p, n)
        refresh()
        sessionChanged()
    }

    func toggleSplit() {
        guard let w = current, let p = focused else { return }
        w.toggleSplit(p)
        refresh()
        sessionChanged()
    }

    func toggleZoom() {
        guard let w = current, let p = focused, w.panes.count > 1 else { return }
        w.zoomed = w.zoomed === p ? nil : p
        refresh()
        sessionChanged()
    }

    func resize(_ axis: Axis, by delta: CGFloat) {
        guard let w = current, let p = focused else { return }
        w.resize(p, axis: axis, by: delta)
        refresh()
        sessionChanged()
    }

    /// cmd-shift-N: the focused pane goes to workspace N (made if needed) and focus follows
    func movePane(toWorkspace n: Int) {
        guard let w = current, let p = focused, w.number != n else { return }
        w.remove(p)
        let target = workspace(n) ?? {
            let t = Workspace(number: n)
            state.workspaces.append(t); sortWorkspaces()
            return t
        }()
        target.insert(p)
        if w.isEmpty { state.workspaces.removeAll { $0 === w } }
        switchTo(target)
        sessionChanged()
    }

    /// Relayouts the current workspace and syncs the published focus
    private func refresh() {
        guard let w = current else { return }
        state.focused = w.focused
        if let f = w.focused { titleSub = f.$title.sink { [weak self] t in self?.title = t.isEmpty ? "Casa" : t } }
        tiles.show(w, focused: w.focused)
    }

    // MARK: Navigation (the focused browser pane)

    func goBack() { currentTab?.webView.goBack() }
    func goForward() { currentTab?.webView.goForward() }
    func reload(hard: Bool) {
        guard let t = currentTab else { return }
        if t.isLoading { t.webView.stopLoading(); return }
        if hard { t.webView.reloadFromOrigin() } else { t.webView.reload() }
    }
    func stop() { currentTab?.webView.stopLoading() }
    func zoom(_ factor: Double?) { currentTab?.zoom(by: factor) }

    func copyURL() {
        guard let u = currentTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
    }

    /// Opens a typed address or search: in the focused browser pane, or a new pane beside a terminal
    private func open(_ load: (Tab) -> Void) {
        if let t = focused?.tab { load(t); return }
        let p = newBrowserPane(url: URL(string: "about:blank"))
        if state.mode == .palette { closeOverlay() }
        if let t = p.tab { load(t) }
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
        if was == .find { currentTab?.clearFind() }
        if let p = focused { makeFirstResponder(p.view) }
    }

    func openPalette(_ mode: PaletteMode) {
        if state.mode == .find { closeOverlay() }
        state.paletteMode = mode
        let t = focused?.tab
        state.paletteQuery = mode == .url ? (t == nil || t?.isBlank == true ? "" : t?.url?.absoluteString ?? "") : ""
        state.mode = .palette
        showOverlay()
    }

    func moveSelection(_ delta: Int) {
        switch state.mode {
        case .palette:
            guard !state.paletteRows.isEmpty else { return }
            state.paletteSelection = (state.paletteSelection + delta + state.paletteRows.count) % state.paletteRows.count
        case .switcher:
            guard !state.workspaces.isEmpty else { return }
            state.switcherSelection = (state.switcherSelection + delta + state.workspaces.count) % state.workspaces.count
        default: break
        }
    }

    func runPalette() {
        let q = state.paletteQuery.trimmingCharacters(in: .whitespaces)
        let row = state.paletteRows.indices.contains(state.paletteSelection) ? state.paletteRows[state.paletteSelection] : nil
        closeOverlay()
        guard let row else {
            if !q.isEmpty { open { $0.open(q) } }
            return
        }
        switch row.kind {
        case .pane(let id):
            for w in state.workspaces { if let p = w.panes.first(where: { $0.id == id }) { w.setFocus(p); switchTo(w); break } }
        case .history(let u): if let url = URL(string: u) { open { $0.load(url) } }
        case .url(let s), .search(let s): open { $0.open(s) }
        case .command(let id): runCommand(id)
        }
    }

    func runCommand(_ id: String) {
        switch id {
        case "terminal": newTerminalPane()
        case "browser": newBrowserPane(url: nil)
        case "workspace": newWorkspace(url: nil)
        case "zoom": toggleZoom()
        case "flip": toggleSplit()
        case "new-window": AppDelegate.shared.newWindow(private: false)
        case "private-window": AppDelegate.shared.newWindow(private: true)
        case "reload": reload(hard: false)
        case "copy-url": copyURL()
        case "zoom-in": zoom(1.1)
        case "zoom-out": zoom(1 / 1.1)
        case "zoom-reset": zoom(nil)
        case "close-pane": closePane()
        case "reopen": reopenPane()
        case "downloads": revealDownload()
        case "inspector": showInspector()
        default: break
        }
    }

    func openFind() {
        guard currentTab != nil else { return }
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
            self.currentTab?.find(self.state.findQuery, forward: true, fresh: true) { i, n in
                self.state.findIndex = i; self.state.findTotal = n
            }
        }
        findWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func findNext(forward: Bool) {
        if state.mode != .find { openFind(); return }
        currentTab?.find(state.findQuery, forward: forward, fresh: false) { [weak self] i, n in
            self?.state.findIndex = i; self?.state.findTotal = n
        }
    }

    func showSwitcher(delta: Int) {
        guard !state.workspaces.isEmpty else { return }
        if state.mode != .switcher {
            if state.mode != .rest { closeOverlay() }
            state.switcherSelection = state.workspaces.firstIndex { $0 === current } ?? 0
            state.mode = .switcher
            showOverlay()
        }
        moveSelection(delta)
    }

    func commitSwitcher() {
        let i = state.switcherSelection
        closeOverlay()
        if state.workspaces.indices.contains(i) { switchTo(state.workspaces[i]) }
    }

    func showInspector() {
        // WebKit opens its inspector from the context menu or this private-ish menu item; the public API only flags inspectability
        if let wv = currentTab?.webView, let inspector = wv.value(forKey: "_inspector") as? NSObject {
            inspector.perform(NSSelectorFromString("show"))
        }
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
        let ws: [Session.Workspace] = state.workspaces.compactMap { w in
            guard let tree = w.encode() else { return nil }
            let leaves = w.panes
            let fi = leaves.firstIndex { $0 === w.focused } ?? 0
            return Session.Workspace(number: w.number, tree: tree, focused: fi, zoomed: w.zoomed != nil)
        }
        guard !ws.isEmpty else { return nil }
        let f = frame
        return Session.Window(frame: [f.minX, f.minY, f.width, f.height], workspaces: ws, current: current?.number ?? ws[0].number)
    }

    /// Rebuilds workspaces and panes from a saved window
    func restore(_ s: Session.Window) {
        for sw in s.workspaces {
            let w = Workspace(number: sw.number)
            w.restore(sw.tree) { leaf in
                if let cwd = leaf.cwd {
                    let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : Paths.home
                    return TerminalView(workingDirectory: dir, owner: self).map { Pane(.terminal($0)) }
                }
                let tab = Tab(owner: self, isPrivate: isPrivate)
                if let u = leaf.url, u != "about:blank", let url = URL(string: u) { tab.load(url) } else { tab.loadBlank() }
                return Pane(.browser(tab))
            }
            guard !w.isEmpty else { continue }
            let leaves = w.panes
            w.setFocus(leaves.indices.contains(sw.focused) ? leaves[sw.focused] : leaves[0])
            if sw.zoomed, leaves.count > 1 { w.zoomed = w.focused }
            state.workspaces.append(w)
        }
        sortWorkspaces()
        if let w = workspace(s.current) ?? state.workspaces.first { switchTo(w) }
    }

    func windowDidResize(_ notification: Notification) { sessionChanged() }
    func windowDidMove(_ notification: Notification) { sessionChanged() }

    func windowDidBecomeKey(_ notification: Notification) {
        if state.mode == .rest, let p = focused, firstResponder === self { makeFirstResponder(p.view) }
    }

    func windowWillClose(_ notification: Notification) {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        for w in state.workspaces { for p in w.panes { tearDown(p) } }
        AppDelegate.shared.windowClosed(self)
    }

    // MARK: Menu actions (first responder chain)

    @objc func newWorkspaceAction(_ s: Any?) { newWorkspace(url: nil) }
    @objc func newBrowserPaneAction(_ s: Any?) { newBrowserPane(url: nil) }
    @objc func newTerminalPaneAction(_ s: Any?) { newTerminalPane() }
    @objc func closePaneAction(_ s: Any?) { closePane() }
    @objc func reopenClosedPane(_ s: Any?) { reopenPane() }
    @objc func openLocation(_ s: Any?) { openPalette(.url) }
    @objc func searchTabs(_ s: Any?) { openPalette(.tabs) }
    @objc func nextWorkspaceAction(_ s: Any?) { nextWorkspace(1) }
    @objc func previousWorkspaceAction(_ s: Any?) { nextWorkspace(-1) }
    @objc func switchWorkspaceNext(_ s: Any?) { showSwitcher(delta: 1) }
    @objc func switchWorkspacePrevious(_ s: Any?) { showSwitcher(delta: -1) }
    @objc func goToWorkspaceAction(_ s: Any?) {
        guard let item = s as? NSMenuItem else { return }
        goToWorkspace(item.tag)
    }
    @objc func movePaneToWorkspaceAction(_ s: Any?) {
        guard let item = s as? NSMenuItem else { return }
        movePane(toWorkspace: item.tag)
    }
    @objc func focusLeft(_ s: Any?) { focus(.left) }
    @objc func focusRight(_ s: Any?) { focus(.right) }
    @objc func focusUp(_ s: Any?) { focus(.up) }
    @objc func focusDown(_ s: Any?) { focus(.down) }
    @objc func swapLeft(_ s: Any?) { swap(.left) }
    @objc func swapRight(_ s: Any?) { swap(.right) }
    @objc func swapUp(_ s: Any?) { swap(.up) }
    @objc func swapDown(_ s: Any?) { swap(.down) }
    @objc func toggleSplitAction(_ s: Any?) { toggleSplit() }
    @objc func toggleZoomAction(_ s: Any?) { toggleZoom() }
    @objc func narrower(_ s: Any?) { resize(.horizontal, by: -100) }
    @objc func wider(_ s: Any?) { resize(.horizontal, by: 100) }
    @objc func shorter(_ s: Any?) { resize(.vertical, by: -100) }
    @objc func taller(_ s: Any?) { resize(.vertical, by: 100) }
    @objc func goBack(_ s: Any?) { goBack() }
    @objc func goForward(_ s: Any?) { goForward() }
    @objc func reloadPage(_ s: Any?) { currentTab?.webView.reload() }
    @objc func reloadPageFromOrigin(_ s: Any?) { reload(hard: true) }
    @objc func stopLoading(_ s: Any?) { stop() }
    @objc func zoomIn(_ s: Any?) { zoom(1.1) }
    @objc func zoomOut(_ s: Any?) { zoom(1 / 1.1) }
    @objc func zoomReset(_ s: Any?) { zoom(nil) }
    @objc func copyPageURL(_ s: Any?) { copyURL() }
    @objc func findInPage(_ s: Any?) { openFind() }
    @objc func findNextMatch(_ s: Any?) { findNext(forward: true) }
    @objc func findPreviousMatch(_ s: Any?) { findNext(forward: false) }
    @objc func showDownloads(_ s: Any?) { revealDownload() }
    @objc func showWebInspector(_ s: Any?) { showInspector() }
}

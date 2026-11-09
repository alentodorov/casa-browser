// Casa: a small WebKit browser for the iMac's tiled desktop. One window is one tab group, the chrome
// is a pill in the page's top strip, cmd-L / cmd-K open the palette, cmd-J the console (libghostty).
// Built by build.sh into ~/Applications/Casa.app, like the widgets.
import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    private(set) var windows: [BrowserWindow] = []
    private var pendingURLs: [URL] = []
    private var launched = false
    private var saveWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        Paths.ensureState()
        buildMenu()
        KeySwap.shared.start()   // physical Cmd is cmd again while Casa is in front
        _ = History.shared
        _ = Live.shared
        if !pendingURLs.isEmpty {
            let w = newWindow(private: false, urls: pendingURLs)
            w.makeKeyAndOrderFront(nil)
            pendingURLs = []
        } else if !restore() {
            newWindow(private: false).makeKeyAndOrderFront(nil)
        }
        launched = true
        if ProcessInfo.processInfo.environment["CASA_DEBUG"] != nil { installDebugChannel() }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs += urls; return }
        let w = keyBrowserWindow ?? newWindow(private: false, urls: [])
        for u in urls { w.newTab(url: u) }
        w.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty { newWindow(private: false).makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        saveWork?.cancel()
        saveSession()
    }

    var keyBrowserWindow: BrowserWindow? { NSApp.keyWindow as? BrowserWindow ?? windows.last }

    // MARK: Windows

    @discardableResult
    func newWindow(private isPrivate: Bool, urls: [URL]? = nil, frame: NSRect? = nil) -> BrowserWindow {
        let w = BrowserWindow(isPrivate: isPrivate, frame: frame)
        windows.append(w)
        fullscreen(w)
        if let urls, !urls.isEmpty {
            for u in urls { w.newTab(url: u, select: false) }
            w.select(0)
        } else if urls == nil {
            w.newTab(url: nil)   // a blank tab with the palette open
        }
        return w
    }

    /// Every window is fullscreen (AeroSpace's, so it stays on its workspace and alt-f still toggles
    /// it). AeroSpace needs a moment to pick up a new window, so ask again if the first try was early.
    private func fullscreen(_ w: BrowserWindow, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.4 : 0.8)) { [weak self, weak w] in
            guard let w else { return }
            guard w.isVisible else { if attempt < 4 { self?.fullscreen(w, attempt: attempt + 1) }; return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/aerospace")
            p.arguments = ["fullscreen", "on", "--window-id", String(w.windowNumber)]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                if proc.terminationStatus != 0, attempt < 4 { DispatchQueue.main.async { self?.fullscreen(w, attempt: attempt + 1) } }
            }
            try? p.run()
        }
    }

    func windowClosed(_ w: BrowserWindow) {
        windows.removeAll { $0 === w }
        if !windows.isEmpty { sessionChanged() }   // the last window's tabs stay saved for the next launch
    }

    /// A link from the console (cmd-click, OSC 8): a tab in the window the console is in, or the key window
    func openFromConsole(_ s: String) {
        guard let u = URL(string: s) else { return }
        if let scheme = u.scheme, scheme == "http" || scheme == "https" || scheme == "file" {
            (keyBrowserWindow ?? newWindow(private: false, urls: [])).newTab(url: u)
        } else {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: Session

    func sessionChanged() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveSession() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func saveSession() {
        let s = windows.compactMap { $0.sessionWindow }
        if !s.isEmpty { Session.save(s) }
    }

    private func restore() -> Bool {
        let saved = Session.load()
        guard !saved.isEmpty else { return false }
        for s in saved {
            let urls = s.urls.compactMap { URL(string: $0) }
            guard !urls.isEmpty else { continue }
            var f = s.frame.count == 4 ? NSRect(x: s.frame[0], y: s.frame[1], width: s.frame[2], height: s.frame[3]) : nil
            // AeroSpace parks windows of other workspaces off-screen; a frame saved then is no use
            if let r = f, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r.insetBy(dx: 40, dy: 40)) }) { f = nil }
            let w = newWindow(private: false, urls: urls, frame: f)
            w.select(min(max(0, s.active), urls.count - 1))
            w.makeKeyAndOrderFront(nil)
        }
        return !windows.isEmpty
    }

    // MARK: Menu: every shortcut lives here (physical Option = cmd; AeroSpace owns alt-*)

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.tag = tag
        return i
    }

    private func buildMenu() {
        let main = NSMenu()

        let app = NSMenu(title: "Casa")
        app.addItem(item("About Casa", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item("Hide Casa", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Quit Casa", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(submenu(app))

        let file = NSMenu(title: "File")
        file.addItem(item("New Window", #selector(newWindow(_:)), "n"))
        file.addItem(item("New Private Window", #selector(newPrivateWindow(_:)), "n", [.command, .shift]))
        file.addItem(item("New Tab", #selector(BrowserWindow.newTab(_:)), "t"))
        let newTabEnter = item("New Tab", #selector(BrowserWindow.newTab(_:)), "\r", [.command, .shift])   // as cmd-shift-enter opens a window elsewhere
        newTabEnter.isHidden = true
        newTabEnter.allowsKeyEquivalentWhenHidden = true
        file.addItem(newTabEnter)
        file.addItem(item("Open Location", #selector(BrowserWindow.openLocation(_:)), "l"))
        file.addItem(item("Search Tabs and Commands", #selector(BrowserWindow.searchTabs(_:)), "k"))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(BrowserWindow.closeTabAction(_:)), "w"))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        file.addItem(item("Reopen Closed Tab", #selector(BrowserWindow.reopenClosedTab(_:)), "t", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Downloads", #selector(BrowserWindow.showDownloads(_:)), "d", [.command, .shift]))
        main.addItem(submenu(file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Copy URL", #selector(BrowserWindow.copyPageURL(_:)), "c", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Find", #selector(BrowserWindow.findInPage(_:)), "f"))
        edit.addItem(item("Find Next", #selector(BrowserWindow.findNextMatch(_:)), "g"))
        edit.addItem(item("Find Previous", #selector(BrowserWindow.findPreviousMatch(_:)), "g", [.command, .shift]))
        main.addItem(submenu(edit))

        let view = NSMenu(title: "View")
        view.addItem(item("Reload", #selector(BrowserWindow.reloadPage(_:)), "r"))
        view.addItem(item("Reload Ignoring Cache", #selector(BrowserWindow.reloadPageFromOrigin(_:)), "r", [.command, .shift]))
        view.addItem(item("Stop", #selector(BrowserWindow.stopLoading(_:)), "."))
        view.addItem(.separator())
        view.addItem(item("Zoom In", #selector(BrowserWindow.zoomIn(_:)), "="))
        view.addItem(item("Zoom Out", #selector(BrowserWindow.zoomOut(_:)), "-"))
        view.addItem(item("Actual Size", #selector(BrowserWindow.zoomReset(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item("Toggle Console", #selector(BrowserWindow.toggleConsole(_:)), "j"))
        let alt = item("Toggle Console", #selector(BrowserWindow.toggleConsole(_:)), "`", [.control])
        alt.isAlternate = false
        alt.isHidden = true
        alt.allowsKeyEquivalentWhenHidden = true
        view.addItem(alt)
        let enter = item("Toggle Console", #selector(BrowserWindow.toggleConsole(_:)), "\r")   // as cmd-enter opens a terminal elsewhere
        enter.isHidden = true
        enter.allowsKeyEquivalentWhenHidden = true
        view.addItem(enter)
        view.addItem(item("Web Inspector", #selector(BrowserWindow.showWebInspector(_:)), "i", [.command, .shift]))
        main.addItem(submenu(view))

        let history = NSMenu(title: "History")
        history.addItem(item("Back", #selector(BrowserWindow.goBack(_:)), "["))
        history.addItem(item("Forward", #selector(BrowserWindow.goForward(_:)), "]"))
        main.addItem(submenu(history))

        let window = NSMenu(title: "Window")
        window.addItem(item("Next Tab", #selector(BrowserWindow.switchTabNext(_:)), "\t", [.control]))
        window.addItem(item("Previous Tab", #selector(BrowserWindow.switchTabPrevious(_:)), "\t", [.control, .shift]))
        window.addItem(item("Next Tab", #selector(BrowserWindow.nextTabAction(_:)), "]", [.command, .shift]))
        window.addItem(item("Previous Tab", #selector(BrowserWindow.previousTabAction(_:)), "[", [.command, .shift]))
        window.addItem(.separator())
        for n in 1...9 {
            window.addItem(item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindow.selectTabByNumber(_:)), "\(n)", [.command], tag: n))
        }
        main.addItem(submenu(window))
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private func submenu(_ m: NSMenu) -> NSMenuItem {
        let i = NSMenuItem()
        i.submenu = m
        return i
    }

    @objc func newWindow(_ s: Any?) { newWindow(private: false).makeKeyAndOrderFront(nil) }
    @objc func newPrivateWindow(_ s: Any?) { newWindow(private: true).makeKeyAndOrderFront(nil) }

    // MARK: Debug channel (CASA_DEBUG=1): drives the UI from a script so tests needn't fake mouse or keys

    private func installDebugChannel() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.alentodorov.casa.debug"), object: nil, queue: .main) { n in
            guard let cmd = n.object as? String else { return }
            MainActor.assumeIsolated { AppDelegate.shared.debug(cmd) }
        }
    }

    private func debug(_ cmd: String) {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0], arg = parts.count > 1 ? parts[1] : ""
        guard let w = keyBrowserWindow else { if name == "newwindow" { newWindow(private: false).makeKeyAndOrderFront(nil) }; return }
        switch name {
        case "palette": w.openPalette(.url)
        case "palette-tabs": w.openPalette(.tabs)
        case "type": if w.state.mode == .find { w.state.findQuery = arg } else { w.state.paletteQuery = arg }
        case "down": w.moveSelection(1)
        case "up": w.moveSelection(-1)
        case "enter": if w.state.mode == .find { w.findNext(forward: true) } else { w.runPalette() }
        case "esc": w.closeOverlay()
        case "find": w.openFind()
        case "switcher": w.showSwitcher(delta: 1)
        case "commit": w.commitSwitcher()
        case "hover": w.state.hover = arg != "off"
        case "newtab": w.newTab(url: arg.isEmpty ? nil : URL(string: arg))
        case "closetab": w.closeTab()
        case "reopen": w.reopenTab()
        case "select": w.select(Int(arg) ?? 0)
        case "private": newWindow(private: true).makeKeyAndOrderFront(nil)
        case "newwindow": newWindow(private: false).makeKeyAndOrderFront(nil)
        case "console": w.toggleConsole()
        case "console-type": w.terminal?.type(arg)
        case "console-height": w.setConsoleHeight(CGFloat(Double(arg) ?? 300))
        case "frame":
            let v = arg.split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { w.setFrame(NSRect(x: v[0], y: v[1], width: v[2], height: v[3]), display: true) }
        case "load": if let u = URL(string: arg) { w.current?.load(u) }
        case "close": w.close()
        case "quit": NSApp.terminate(nil)
        default: NSLog("Casa debug: unknown %@", cmd)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // AeroSpace only manages regular apps' windows
    let delegate = AppDelegate()
    AppDelegate.shared = delegate
    app.delegate = delegate
    app.run()
}

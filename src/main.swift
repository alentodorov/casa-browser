// Casa: a small WebKit browser for the iMac's tiled desktop. A window holds numbered workspaces that
// tile browser and terminal panes the way Omarchy's Hyprland does; the chrome is a pill in the top
// strip, cmd-L / cmd-K open the palette, cmd-enter a terminal pane (libghostty).
// Built by build.sh into ~/Applications/Casa.app, like the widgets.
import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    /// The AeroSpace workspace every Casa window lives on
    static let workspace = "8"
    private(set) var windows: [BrowserWindow] = []
    private var pendingURLs: [URL] = []
    private var launched = false
    private var saveWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        Paths.ensureState()
        buildMenu()
        KeySwap.shared.start()   // physical Cmd is cmd again while Casa is in front
        _ = History.shared
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
        for u in urls { w.newWorkspace(url: u) }
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
        place(w)
        if let urls, !urls.isEmpty {
            for u in urls { w.newWorkspace(url: u) }
            if let first = w.workspace(1) { w.switchTo(first) }
        } else if urls == nil {
            w.newWorkspace(url: nil)   // workspace 1, a blank pane with the palette open
        }
        return w
    }

    /// Every window goes to workspace 8 (focus follows it, so SketchyBar and the screen switch too)
    /// and is fullscreen there (AeroSpace's, so alt-f still toggles it). AeroSpace needs a moment to
    /// pick up a new window, so ask again if the first try was early.
    private func place(_ w: BrowserWindow, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.4 : 0.8)) { [weak self, weak w] in
            guard let w else { return }
            guard w.isVisible else { if attempt < 4 { self?.place(w, attempt: attempt + 1) }; return }
            let id = String(w.windowNumber)
            let retry = { if attempt < 4 { self?.place(w, attempt: attempt + 1) } }
            aerospace(["move-node-to-workspace", "--focus-follows-window", "--window-id", id, AppDelegate.workspace]) { ok in
                guard ok else { retry(); return }
                aerospace(["fullscreen", "on", "--window-id", id]) { ok in if !ok { retry() } }
            }
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
            (keyBrowserWindow ?? newWindow(private: false, urls: [])).newBrowserPane(url: u)
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
            var f = s.frame.count == 4 ? NSRect(x: s.frame[0], y: s.frame[1], width: s.frame[2], height: s.frame[3]) : nil
            // AeroSpace parks windows of other workspaces off-screen; a frame saved then is no use
            if let r = f, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r.insetBy(dx: 40, dy: 40)) }) { f = nil }
            let w = newWindow(private: false, urls: [], frame: f)
            w.restore(s)
            if w.state.workspaces.isEmpty { w.newWorkspace(url: nil) }
            w.makeKeyAndOrderFront(nil)
        }
        return !windows.isEmpty
    }

    // MARK: Menu: every shortcut lives here (physical Cmd = cmd inside Casa; AeroSpace owns alt-*)

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
        file.addItem(item("New Workspace", #selector(BrowserWindow.newWorkspaceAction(_:)), "t"))
        file.addItem(item("New Browser Pane", #selector(BrowserWindow.newBrowserPaneAction(_:)), "\r", [.command, .shift]))   // Omarchy: Super+Shift+Enter
        file.addItem(hidden(item("New Browser Pane", #selector(BrowserWindow.newBrowserPaneAction(_:)), "b", [.command, .shift])))
        file.addItem(item("New Terminal Pane", #selector(BrowserWindow.newTerminalPaneAction(_:)), "\r"))   // Omarchy: Super+Enter
        file.addItem(hidden(item("New Terminal Pane", #selector(BrowserWindow.newTerminalPaneAction(_:)), "`", [.control])))
        file.addItem(item("Open Location", #selector(BrowserWindow.openLocation(_:)), "l"))
        file.addItem(item("Search Panes and Commands", #selector(BrowserWindow.searchTabs(_:)), "k"))
        file.addItem(.separator())
        file.addItem(item("Close Pane", #selector(BrowserWindow.closePaneAction(_:)), "w"))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        file.addItem(item("Reopen Closed Pane", #selector(BrowserWindow.reopenClosedPane(_:)), "t", [.command, .shift]))
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
        view.addItem(item("Zoom In", #selector(BrowserWindow.zoomIn(_:))))      // page zoom: pinch, or these from the palette
        view.addItem(item("Zoom Out", #selector(BrowserWindow.zoomOut(_:))))
        view.addItem(item("Actual Size", #selector(BrowserWindow.zoomReset(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item("Web Inspector", #selector(BrowserWindow.showWebInspector(_:)), "i", [.command, .shift]))
        main.addItem(submenu(view))

        // Omarchy's tiling keys, with the physical Cmd key as Super
        let pane = NSMenu(title: "Pane")
        pane.addItem(item("Focus Left", #selector(BrowserWindow.focusLeft(_:)), arrow(NSLeftArrowFunctionKey)))
        pane.addItem(item("Focus Right", #selector(BrowserWindow.focusRight(_:)), arrow(NSRightArrowFunctionKey)))
        pane.addItem(item("Focus Up", #selector(BrowserWindow.focusUp(_:)), arrow(NSUpArrowFunctionKey)))
        pane.addItem(item("Focus Down", #selector(BrowserWindow.focusDown(_:)), arrow(NSDownArrowFunctionKey)))
        pane.addItem(.separator())
        pane.addItem(item("Swap Left", #selector(BrowserWindow.swapLeft(_:)), arrow(NSLeftArrowFunctionKey), [.command, .shift]))
        pane.addItem(item("Swap Right", #selector(BrowserWindow.swapRight(_:)), arrow(NSRightArrowFunctionKey), [.command, .shift]))
        pane.addItem(item("Swap Up", #selector(BrowserWindow.swapUp(_:)), arrow(NSUpArrowFunctionKey), [.command, .shift]))
        pane.addItem(item("Swap Down", #selector(BrowserWindow.swapDown(_:)), arrow(NSDownArrowFunctionKey), [.command, .shift]))
        pane.addItem(.separator())
        pane.addItem(item("Flip Split", #selector(BrowserWindow.toggleSplitAction(_:)), "j"))
        pane.addItem(item("Zoom Pane", #selector(BrowserWindow.toggleZoomAction(_:)), "f", [.command, .shift]))
        pane.addItem(.separator())
        // Omarchy's resizeactive -100 0 / 100 0 / 0 -100 / 0 100: they move the divider, so a pane on
        // the left of it shrinks on cmd-- while a pane on the right grows
        pane.addItem(item("Move Divider Left", #selector(BrowserWindow.dividerLeft(_:)), "-"))
        pane.addItem(item("Move Divider Right", #selector(BrowserWindow.dividerRight(_:)), "="))
        pane.addItem(item("Move Divider Up", #selector(BrowserWindow.dividerUp(_:)), "-", [.command, .shift]))
        pane.addItem(item("Move Divider Down", #selector(BrowserWindow.dividerDown(_:)), "=", [.command, .shift]))
        pane.addItem(.separator())
        for n in 1...9 {   // cmd-shift-N itself is caught by the window's key monitor; these are for the menu
            pane.addItem(item("Move to Workspace \(n)", #selector(BrowserWindow.movePaneToWorkspaceAction(_:)), tag: n))
        }
        main.addItem(submenu(pane))

        let history = NSMenu(title: "History")
        history.addItem(item("Back", #selector(BrowserWindow.goBack(_:)), "["))
        history.addItem(item("Forward", #selector(BrowserWindow.goForward(_:)), "]"))
        main.addItem(submenu(history))

        let window = NSMenu(title: "Workspace")
        window.addItem(item("Next Workspace", #selector(BrowserWindow.switchWorkspaceNext(_:)), "\t", [.control]))
        window.addItem(item("Previous Workspace", #selector(BrowserWindow.switchWorkspacePrevious(_:)), "\t", [.control, .shift]))
        window.addItem(item("Next Workspace", #selector(BrowserWindow.nextWorkspaceAction(_:)), "]", [.command, .shift]))
        window.addItem(item("Previous Workspace", #selector(BrowserWindow.previousWorkspaceAction(_:)), "[", [.command, .shift]))
        window.addItem(.separator())
        for n in 1...9 {
            window.addItem(item("Workspace \(n)", #selector(BrowserWindow.goToWorkspaceAction(_:)), "\(n)", [.command], tag: n))
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

    private func hidden(_ i: NSMenuItem) -> NSMenuItem {
        i.isHidden = true
        i.allowsKeyEquivalentWhenHidden = true
        return i
    }

    private func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(key)!)) }

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
        let dirs: [String: Direction] = ["l": .left, "r": .right, "u": .up, "d": .down]
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
        case "workspace": w.newWorkspace(url: arg.isEmpty ? nil : URL(string: arg))   // cmd-T
        case "ws": w.goToWorkspace(Int(arg) ?? 1)                                      // cmd-N
        case "move-ws": w.movePane(toWorkspace: Int(arg) ?? 1)                          // cmd-shift-N
        case "browser": w.newBrowserPane(url: arg.isEmpty ? nil : URL(string: arg))    // cmd-shift-enter
        case "term": w.newTerminalPane()                                               // cmd-enter
        case "closepane": w.closePane()                                                // cmd-W
        case "reopen": w.reopenPane()
        case "focus": if let d = dirs[arg] { w.focus(d) }                              // cmd-arrows
        case "swap": if let d = dirs[arg] { w.swap(d) }                                // cmd-shift-arrows
        case "flip": w.toggleSplit()                                                   // cmd-J
        case "zoom": w.toggleZoom()                                                    // cmd-shift-F
        case "resize":   // resize:w,100 or resize:h,-100
            let v = arg.split(separator: ",")
            if v.count == 2, let d = Double(v[1]) { w.moveDivider(v[0] == "h" ? .vertical : .horizontal, by: CGFloat(d)) }
        case "private": newWindow(private: true).makeKeyAndOrderFront(nil)
        case "newwindow": newWindow(private: false).makeKeyAndOrderFront(nil)
        case "term-type": w.focused?.terminal?.type(arg)
        case "frame":
            let v = arg.split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { w.setFrame(NSRect(x: v[0], y: v[1], width: v[2], height: v[3]), display: true) }
        case "load": if let u = URL(string: arg) { w.currentTab?.load(u) }
        case "dump":
            for ws in w.state.workspaces {
                let panes = ws.panes.map { ($0.isBrowser ? "web:" : "term:") + ($0.isBrowser ? ($0.tab?.url?.absoluteString ?? "nil") : $0.title) + (ws.focused === $0 ? "*" : "") }
                NSLog("Casa dump: ws %d%@ panes %@", ws.number, ws === w.current ? " (current)" : "", panes.joined(separator: ", "))
            }
            if let c = w.current {
                let frames = c.panes.map { p in c.paneFrames[p.id].map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "hidden" }
                NSLog("Casa dump: frames %@", frames.joined(separator: " | "))
            }
            NSLog("Casa dump: mode %@ focused %@", String(describing: w.state.mode), w.focused?.title ?? "nil")
        case "close": w.close()
        case "quit": NSApp.terminate(nil)
        default: NSLog("Casa debug: unknown %@", cmd)
        }
    }
}

/// Runs an AeroSpace command and reports on the main thread whether it succeeded
@MainActor
func aerospace(_ args: [String], done: @escaping @MainActor (Bool) -> Void) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/aerospace")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.terminationHandler = { proc in
        let ok = proc.terminationStatus == 0
        DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
    }
    do { try p.run() } catch { done(false) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // AeroSpace only manages regular apps' windows
    let delegate = AppDelegate()
    AppDelegate.shared = delegate
    app.delegate = delegate
    app.run()
}

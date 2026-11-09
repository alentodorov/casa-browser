// The console: libghostty (Ghostty's terminal core, vendor/GhosttyKit.xcframework, built from the
// v1.4.0 source) in an NSView. The core draws into a Metal layer it attaches to this view itself; this
// file hands it the size, scale, focus, keys, mouse and clipboard, the way Ghostty.app's SurfaceView
// does, and reads ~/.config/ghostty/config through libghostty's own config loader.
import AppKit
import Carbon.HIToolbox
import GhosttyKit

@MainActor
final class GhosttyRuntime {
    static let shared: GhosttyRuntime? = GhosttyRuntime()
    private(set) var app: ghostty_app_t!
    private(set) var config: ghostty_config_t!

    private init?() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("Casa: ghostty_init failed"); return nil
        }
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)   // ~/.config/ghostty/config: theme, padding, font
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        let diags = ghostty_config_diagnostics_count(cfg)
        for i in 0..<diags {
            let d = ghostty_config_get_diagnostic(cfg, i)
            NSLog("Casa: ghostty config: %@", String(cString: d.message))
        }
        config = cfg

        var rt = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { ud in GhosttyRuntime.wakeup(ud) },
            action_cb: { app, target, action in GhosttyRuntime.action(app, target, action) },
            read_clipboard_cb: { ud, loc, state, mimes, n, list in GhosttyRuntime.readClipboard(ud, loc, state, mimes, n, list) },
            confirm_read_clipboard_cb: { ud, confirm, state, req in GhosttyRuntime.confirmRead(ud, confirm, state, req) },
            write_clipboard_cb: { ud, loc, content, n, confirm in GhosttyRuntime.writeClipboard(ud, loc, content, n, confirm) },
            close_surface_cb: { ud, alive in GhosttyRuntime.closeSurface(ud, alive) })
        guard let app = ghostty_app_new(&rt, cfg) else {
            NSLog("Casa: ghostty_app_new failed"); return nil
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        let c = NotificationCenter.default
        c.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ghostty_app_set_focus(app, true) }
        }
        c.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ghostty_app_set_focus(app, false) }
        }
    }

    // MARK: Callbacks (C function pointers: no captures)

    private static func view(_ ud: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let ud else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func view(of surface: ghostty_surface_t?) -> TerminalView? {
        guard let surface, let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(ud).takeUnretainedValue()
    }

    static func wakeup(_ ud: UnsafeMutableRawPointer?) {
        guard let ud else { return }
        let rt = Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue()
        DispatchQueue.main.async { MainActor.assumeIsolated { ghostty_app_tick(rt.app) } }
    }

    static func action(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        let surfaceView = target.tag == GHOSTTY_TARGET_SURFACE ? view(of: target.target.surface) : nil
        switch action.tag {
        case GHOSTTY_ACTION_PWD:
            guard let v = surfaceView, let p = action.action.pwd.pwd else { return false }
            let s = String(cString: p)
            DispatchQueue.main.async { MainActor.assumeIsolated { v.pwd = s } }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let v = surfaceView else { return false }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { MainActor.assumeIsolated { v.setMouseShape(shape) } }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let p = u.url else { return false }
            let s = String(decoding: UnsafeRawBufferPointer(start: p, count: Int(u.len)), as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { AppDelegate.shared.openFromConsole(s) } }
            return true
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_QUIT_TIMER, GHOSTTY_ACTION_SECURE_INPUT, GHOSTTY_ACTION_SHOW_CHILD_EXITED,
             GHOSTTY_ACTION_PROGRESS_REPORT, GHOSTTY_ACTION_RING_BELL, GHOSTTY_ACTION_SELECTION_CHANGED, GHOSTTY_ACTION_KEY_SEQUENCE,
             GHOSTTY_ACTION_KEY_TABLE, GHOSTTY_ACTION_COMMAND_FINISHED, GHOSTTY_ACTION_READONLY, GHOSTTY_ACTION_SCROLLBAR:
            return true
        default:
            return false   // tabs, splits, quit, fullscreen and so on: not things the console does
        }
    }

    static func closeSurface(_ ud: UnsafeMutableRawPointer?, _ processAlive: Bool) {
        guard let v = view(ud) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { v.owner?.consoleEnded() } }
    }

    static func readClipboard(_ ud: UnsafeMutableRawPointer?, _ loc: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?,
                              _ mimes: UnsafePointer<UnsafePointer<CChar>?>?, _ n: Int, _ list: Bool) -> ghostty_clipboard_read_result_e {
        guard let v = view(ud), let surface = v.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        var wantsText = false
        if let mimes { for i in 0..<n { if let m = mimes[i], String(cString: m) == "text/plain" { wantsText = true } } }
        guard wantsText, let s = NSPasteboard.general.string(forType: .string) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        "text/plain".withCString { mime in
            s.utf8CString.withUnsafeBufferPointer { buf in
                var content = ghostty_clipboard_content_s(mime: mime, data: buf.baseAddress, len: buf.count - 1)
                withUnsafePointer(to: &content) { cp in
                    var complete = ghostty_clipboard_complete_s(contents: cp, contents_len: 1, available: nil, available_len: 0,
                                                                confirmed: false, remember: false)
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ghostty would ask before an unsafe paste or an OSC 52 read; this is Alen's own console, so allow it
    static func confirmRead(_ ud: UnsafeMutableRawPointer?, _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                            _ state: UnsafeMutableRawPointer?, _ req: ghostty_clipboard_request_e) {
        guard let v = view(ud), let surface = v.surface else { return }
        guard let c = confirm?.pointee else { ghostty_surface_deny_clipboard_request(surface, state); return }
        var complete = ghostty_clipboard_complete_s(contents: c.contents, contents_len: c.contents_len, available: c.available,
                                                    available_len: c.available_len, confirmed: true, remember: false)
        ghostty_surface_complete_clipboard_request(surface, &complete, state)
    }

    static func writeClipboard(_ ud: UnsafeMutableRawPointer?, _ loc: ghostty_clipboard_e,
                               _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ n: Int, _ confirm: Bool) {
        guard let content, n > 0 else { return }
        for i in 0..<n {
            let c = content[i]
            guard let m = c.mime, String(cString: m) == "text/plain", let d = c.data else { continue }
            let s = String(decoding: UnsafeRawBufferPointer(start: d, count: c.len), as: UTF8.self)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            return
        }
    }
}

// MARK: The view

@MainActor
final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    weak var owner: BrowserWindow?
    var pwd: String?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var cursor: NSCursor = .iBeam

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init?(workingDirectory: String, owner: BrowserWindow) {
        guard let rt = GhosttyRuntime.shared else { return nil }
        self.owner = owner
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = owner.backingScaleFactor
        cfg.font_size = 0
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        let s: ghostty_surface_t? = workingDirectory.withCString { wd in
            cfg.working_directory = wd
            return ghostty_surface_new(rt.app, &cfg)
        }
        guard let s else { NSLog("Casa: ghostty_surface_new failed"); return nil }
        surface = s
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { nil }

    func tearDown() {
        if let s = surface { ghostty_surface_free(s) }
        surface = nil
    }

    deinit {
        if let s = surface { ghostty_surface_free(s) }
    }

    // MARK: Size, scale, focus

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeChanged()
    }

    private func sizeChanged() {
        guard let surface else { return }
        let b = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(max(1, b.width)), UInt32(max(1, b.height)))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        sizeChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface, let w = window else { return }
        if let n = w.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, n.uint32Value)
        }
        viewDidChangeBackingProperties()
    }

    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r, let surface { ghostty_surface_set_focus(surface, true) }
        return r
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r, let surface { ghostty_surface_set_focus(surface, false) }
        return r
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        default: cursor = .arrow
        }
        window?.invalidateCursorRects(for: self)
    }

    /// Menu shortcuts win over Ghostty's own keybinds: cmd-T is a new browser tab, not a terminal one
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    // MARK: Keys

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    /// The text a key event types, minus control characters and function-key PUA codes (Ghostty encodes those itself)
    static func characters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let s = chars.unicodeScalars.first {
            if s.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if s.value >= 0xF700 && s.value <= 0xF8FF { return nil }
        }
        return chars
    }

    private func keyEvent(_ action: ghostty_input_action_e, _ event: NSEvent) -> ghostty_input_key_s {
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(event.keyCode)
        k.mods = TerminalView.mods(event.modifierFlags)
        k.consumed_mods = TerminalView.mods(event.modifierFlags.subtracting([.control, .command]))
        k.text = nil
        k.composing = false
        k.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let c = event.characters(byApplyingModifiers: []), let cp = c.unicodeScalars.first {
            k.unshifted_codepoint = cp.value
        }
        return k
    }

    @discardableResult
    private func send(_ action: ghostty_input_action_e, _ event: NSEvent, text: String?, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var k = keyEvent(action, event)
        k.composing = composing
        if let text, !text.isEmpty {
            return text.withCString { p in k.text = p; return ghostty_surface_key(surface, k) }
        }
        return ghostty_surface_key(surface, k)
    }

    override func keyDown(with event: NSEvent) {
        guard surface != nil else { return }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])
        let composing = markedText.length > 0
        if let list = keyTextAccumulator, !list.isEmpty {
            for t in list { send(action, event, text: t, composing: composing) }
        } else {
            send(action, event, text: TerminalView.characters(event), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) { send(GHOSTTY_ACTION_RELEASE, event, text: nil) }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if markedText.length > 0 { return }
        let pressed = TerminalView.mods(event.modifierFlags).rawValue & mod != 0
        send(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event, text: nil)
    }

    override func doCommand(by selector: Selector) {}   // the key event itself carries arrows, enter and the rest

    // MARK: NSTextInputClient (typing, dead keys, IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let s as NSAttributedString: chars = s.string
        case let s as String: chars = s
        default: return
        }
        unmarkText()
        if keyTextAccumulator != nil { keyTextAccumulator?.append(chars); return }
        guard let surface else { return }
        chars.withCString { p in ghostty_surface_text(surface, p, UInt(strlen(p))) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let s as NSAttributedString: markedText = NSMutableAttributedString(attributedString: s)
        case let s as String: markedText = NSMutableAttributedString(string: s)
        default: return
        }
        guard let surface else { return }
        markedText.string.withCString { p in ghostty_surface_preedit(surface, p, UInt(strlen(p))) }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let r = NSRect(x: x, y: frame.height - y - h, width: w, height: h)
        return window.convertToScreen(convert(r, to: nil))
    }

    // MARK: Mouse

    private func button(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ b: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, b, TerminalView.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        button(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }
    override func mouseUp(with event: NSEvent) { button(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with event: NSEvent) { button(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { button(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    override func otherMouseDown(with event: NSEvent) { button(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE) }
    override func otherMouseUp(with event: NSEvent) { button(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE) }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, frame.height - p.y, TerminalView.mods(event.modifierFlags))
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | (momentum << 1))
    }

    // MARK: Copy / paste (Edit menu)

    @objc func copy(_ sender: Any?) {
        guard let surface, ghostty_surface_has_selection(surface) else { return }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return }
        defer { ghostty_surface_free_text(surface, &t) }
        guard let p = t.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(cString: p), forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let surface, let s = NSPasteboard.general.string(forType: .string) else { return }
        s.withCString { p in ghostty_surface_paste_text(surface, p, UInt(strlen(p))) }
    }

    /// For the debug channel: type a line into the shell
    func type(_ line: String) {
        guard let surface else { return }
        line.withCString { p in ghostty_surface_text(surface, p, UInt(strlen(p))) }
        var k = ghostty_input_key_s()
        k.action = GHOSTTY_ACTION_PRESS
        k.keycode = 36
        k.mods = GHOSTTY_MODS_NONE
        k.consumed_mods = GHOSTTY_MODS_NONE
        k.unshifted_codepoint = 13
        "\r".withCString { p in k.text = p; _ = ghostty_surface_key(surface, k) }
        k.action = GHOSTTY_ACTION_RELEASE
        k.text = nil
        _ = ghostty_surface_key(surface, k)
    }
}

import AppKit
import ApplicationServices

/// Inside Casa the physical keys mean what they say again.
///
/// Alen's Karabiner swaps cmd and alt everywhere so the physical Cmd key drives AeroSpace (alt-*).
/// While Casa is the frontmost app this event tap swaps them back, before AeroSpace's hotkeys see
/// the keys: physical Cmd is cmd (cmd-1…9 tabs, cmd-enter console, cmd-shift-enter new tab, like
/// Chrome), and physical Option is alt, so AeroSpace still answers to Option from inside Casa.
/// Everywhere else nothing changes. It needs Accessibility access (asked for once at launch).
/// It also takes cmd-shift-1…9 for Casa before the global screenshot hotkeys can (see below).
final class KeySwap {
    static let shared = KeySwap()
    fileprivate var tap: CFMachPort?
    fileprivate var casaFront = true

    func start() {
        // Keep track of whether Casa is in front without asking on every key
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.casaFront = app?.processIdentifier == getpid()
        }
        casaFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            install()
        } else {   // wait for the permission, then start
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.install() }
            }
        }
    }

    private func install() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: keySwapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("Casa: couldn't create the key tap (Accessibility access?)")
            return
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }
}

// Device-specific modifier bits (IOKit's NX_DEVICE*KEYMASK), swapped along with the generic flags
private let leftCmd: UInt64 = 0x08, rightCmd: UInt64 = 0x10, leftAlt: UInt64 = 0x20, rightAlt: UInt64 = 0x40

private func keySwapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let me = Unmanaged<KeySwap>.fromOpaque(info!).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard me.casaFront else { return Unmanaged.passUnretained(event) }

    var raw = event.flags.rawValue
    let cmd = raw & CGEventFlags.maskCommand.rawValue != 0, alt = raw & CGEventFlags.maskAlternate.rawValue != 0
    let lc = raw & leftCmd != 0, rc = raw & rightCmd != 0, la = raw & leftAlt != 0, ra = raw & rightAlt != 0
    raw &= ~(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue | leftCmd | rightCmd | leftAlt | rightAlt)
    if cmd { raw |= CGEventFlags.maskAlternate.rawValue }
    if alt { raw |= CGEventFlags.maskCommand.rawValue }
    if lc { raw |= leftAlt }
    if rc { raw |= rightAlt }
    if la { raw |= leftCmd }
    if ra { raw |= rightCmd }
    event.flags = CGEventFlags(rawValue: raw)

    // The modifier keys themselves: left/right cmd (55/54) <-> left/right option (58/61)
    if type == .flagsChanged {
        let swap: [Int64: Int64] = [55: 58, 58: 55, 54: 61, 61: 54]
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if let to = swap[code] { event.setIntegerValueField(.keyboardEventKeycode, value: to) }
    }

    // cmd-shift-1…9 (Omarchy's "move window to workspace N") would never reach Casa: Shottr holds
    // cmd-shift-1/2 and macOS cmd-shift-3/4/5 as global hotkeys, which fire before any app sees the
    // key. This tap runs before them, so it does the move itself and drops the event.
    if type == .keyDown || type == .keyUp {
        let f = event.flags
        let wanted: CGEventFlags = [.maskCommand, .maskShift]
        let blocked: CGEventFlags = [.maskControl, .maskAlternate]
        if f.isSuperset(of: wanted), f.isDisjoint(with: blocked),
           let n = digitKeycodes[event.getIntegerValueField(.keyboardEventKeycode)] {
            if type == .keyDown {
                DispatchQueue.main.async { MainActor.assumeIsolated { AppDelegate.shared.keyBrowserWindow?.movePane(toWorkspace: n) } }
            }
            return nil
        }
    }
    return Unmanaged.passUnretained(event)
}

/// ANSI keycodes of the 1…9 keys, and 0 for workspace 10
private let digitKeycodes: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 10]

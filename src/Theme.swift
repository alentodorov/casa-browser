// Flexoki, the widgets' font and glyphs, and where Casa keeps its state
import AppKit
import SwiftUI

extension Color {
    init(_ hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension NSColor {
    convenience init(_ hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

enum Theme {
    static let paper = Color(0xFFFCF0), base50 = Color(0xF2F0E5), base100 = Color(0xE6E4D9), base150 = Color(0xDAD8CE)
    static let grey = Color(0x878580), ink = Color(0x100F0F), green = Color(0x879A39), orange = Color(0xDA702C)
    static let red = Color(0xD14D41), blue = Color(0x4385BE), cyan = Color(0x3AA99F), yellow = Color(0xD0A215), purple = Color(0x8B7EC8)
    static let nsPaper = NSColor(0xFFFCF0), nsBase100 = NSColor(0xE6E4D9), nsInk = NSColor(0x100F0F)

    static let fontName = "JetBrainsMono Nerd Font"
    static func mono(_ size: CGFloat) -> Font { .custom(fontName, size: size).bold() }
    static func nsMono(_ size: CGFloat) -> NSFont {
        NSFont(name: "JetBrainsMonoNF-Bold", size: size) ?? NSFont(name: fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .bold)
    }

    /// The strip at the top of the page that the pill floats in (WKWebView.obscuredContentInsets)
    static let stripHeight: CGFloat = 36
    static let narrowWidth: CGFloat = 800

    /// Nerd Font (Material Design) glyphs
    static let lock = "\u{F033E}", search = "\u{F0349}", back = "\u{F004D}", forward = "\u{F0054}", reload = "\u{F0450}"
    static let play = "\u{F040A}", pause = "\u{F03E4}", close = "\u{F0156}", chevronLeft = "\u{F0141}", chevronRight = "\u{F0142}"
    static let history = "\u{F02DA}", web = "\u{F059F}", tab = "\u{F0B4A}", download = "\u{F01DA}", incognito = "\u{F02FA}"
    static let command = "\u{F0633}", music = "\u{F0387}", terminal = "\u{F0489}", stop = "\u{F04DB}"

    /// A stable colour for a host, for the letter tiles that stand in for favicons
    static func tileColor(for host: String) -> Color {
        let palette = [orange, purple, green, blue, cyan, red, yellow]
        var h: UInt32 = 5381
        for b in host.utf8 { h = (h &* 33) &+ UInt32(b) }
        return palette[Int(h % UInt32(palette.count))]
    }
}

enum Paths {
    static let home = NSHomeDirectory()
    static let state = home + "/.local/state/casa"
    static let history = state + "/history.jsonl"
    static let session = state + "/session.json"
    static let zoom = state + "/zoom.json"
    static let downloads = home + "/Downloads"
    static let projects = home + "/projects"
    static let mpvSocket = home + "/.local/state/yt/mpv.sock"
    static let tracks = home + "/.local/state/yt/tracks.json"
    static let timer = home + "/.local/state/timer/current.json"

    static func ensureState() {
        try? FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
    }
}

/// "3:05" or "1:02:14"
func clockString(_ t: Double) -> String {
    let s = Int(t.rounded(.up))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// The host as the pill shows it: no "www."
func displayHost(_ url: URL?) -> String {
    guard let url else { return "" }
    if url.isFileURL { return url.lastPathComponent }
    if url.scheme == "about" || url.absoluteString == "about:blank" { return "" }
    var h = url.host ?? url.absoluteString
    if h.hasPrefix("www.") { h.removeFirst(4) }
    return h
}

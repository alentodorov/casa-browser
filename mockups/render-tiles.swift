// Mockups for direction D, "Tiles": a Casa tab is an Omarchy-style workspace that tiles browser and
// terminal panes (Hyprland's dwindle layout) inside the window. Same style as render.swift.
// ./render-tiles.sh writes d1–d4 next to it.
import AppKit
import SwiftUI

extension Color {
    init(_ hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}
let paper = Color(0xFFFCF0), base50 = Color(0xF2F0E5), base100 = Color(0xE6E4D9), base150 = Color(0xDAD8CE)
let grey = Color(0x878580), ink = Color(0x100F0F), green = Color(0x879A39), orange = Color(0xDA702C), purple = Color(0x8B7EC8)
func mono(_ size: CGFloat) -> Font { .custom("JetBrainsMono Nerd Font Propo", size: size).bold() }
func monoRegular(_ size: CGFloat) -> Font { .custom("JetBrainsMono Nerd Font Propo", size: size) }

let gLock = "\u{F033E}", gFocused = "\u{F14FB}", gConsole = "\u{F018D}", gZoom = "\u{F0293}", gBranch = "\u{F062C}"

// MARK: Pieces

/// The 36pt strip: workspace numbers left (the bar's style), the pill centred
struct Strip: View {
    let width: CGFloat
    let numbers: [String]      // "1", "■", "3"
    let pill: AnyView
    var body: some View {
        ZStack(alignment: .top) {
            paper
            HStack(spacing: 0) {
                ForEach(numbers.indices, id: \.self) { i in
                    Text(numbers[i] == "■" ? gFocused : numbers[i]).font(mono(12))
                        .foregroundStyle(ink.opacity(numbers[i] == "■" ? 1 : 0.85)).frame(width: 20, height: 24)
                }
            }
            .padding(.top, 6).padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
            pill.padding(.top, 5)
        }
        .frame(width: width, height: 36)
    }
}

struct BlackPill<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 12).frame(height: 26)
            .background(Capsule().fill(.black))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

func hostPill(_ host: String, _ count: String, zoomed: Bool = false) -> AnyView {
    AnyView(BlackPill {
        if zoomed { Text(gZoom).font(mono(11)).foregroundStyle(grey) }
        Text(gLock).font(mono(10)).foregroundStyle(grey)
        Text(host).font(mono(12)).foregroundStyle(paper)
        Text(count).font(mono(10)).foregroundStyle(grey)
    })
}

func terminalPill(_ title: String, _ count: String) -> AnyView {
    AnyView(BlackPill {
        Text(gConsole).font(mono(11)).foregroundStyle(grey)
        Text(title).font(mono(12)).foregroundStyle(paper)
        Text(count).font(mono(10)).foregroundStyle(grey)
    })
}

/// A fake article page (white), as render.swift draws it
struct Page: View {
    var title = "Tiling on a Mac"
    var site = "alen.ro"
    static let paragraphs = [
        "For a long time I treated macOS windows the way the Finder treats them: dragged roughly into place, overlapping, never quite the same twice. Omarchy changed that. After a month of i3-style tiling on Linux, going back to overlapping windows felt like losing a sense.",
        "AeroSpace brings most of that to the Mac. Workspaces are numbers, windows are tiles, and the keyboard does the rest. The physical cmd key goes to the window manager, the physical option key goes to apps, and after a day you stop noticing the swap.",
        "The browser was the last thing that didn\u{2019}t fit. Chrome\u{2019}s tab strip, its toolbar and its idea of what a window is were built for a different desktop.",
    ]
    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(site).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(0x1B1B1B))
                    Spacer()
                    HStack(spacing: 22) {
                        ForEach(["Notes", "Projects", "About"], id: \.self) { Text($0).font(.system(size: 13)).foregroundStyle(Color(0x6B6B6B)) }
                    }
                }
                .padding(.horizontal, 28).frame(height: 52)
                Rectangle().fill(Color(0xEBEBEB)).frame(height: 1)
                VStack(alignment: .leading, spacing: 14) {
                    Text(title).font(.custom("Georgia", size: geo.size.width > 500 ? 30 : 24)).foregroundStyle(Color(0x1B1B1B))
                    Text("November 2026 \u{B7} 6 min").font(.system(size: 13)).foregroundStyle(Color(0x8A8A8A))
                    ForEach(Page.paragraphs.indices, id: \.self) { i in
                        Text(Page.paragraphs[i]).font(.custom("Georgia", size: 16)).lineSpacing(5).foregroundStyle(Color(0x2A2A2A))
                    }
                }
                .frame(width: min(560, geo.size.width - 56), alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .background(Color.white)
            .clipped()
        }
    }
}

/// A libghostty pane with Alen's Ghostty config (Adwaita light)
struct Terminal: View {
    var lines: [(String, Color)] = [
        ("~/projects/casa-browser  \(gBranch) main", Color(0x5E5C64)),
        ("\u{276F} ./build.sh", Color(0x1E1E1E)),
        ("Built /Users/alen/Applications/Casa.app", Color(0x1E1E1E)),
        ("", .clear),
        ("~/projects/casa-browser  \(gBranch) main", Color(0x5E5C64)),
        ("\u{276F} git status --short", Color(0x1E1E1E)),
        (" M src/BrowserWindow.swift", Color(0x1E1E1E)),
        ("?? src/Tiles.swift", Color(0x1E1E1E)),
        ("", .clear),
        ("~/projects/casa-browser  \u{F062C} main", Color(0x5E5C64)),
        ("\u{276F} ", Color(0x1E1E1E)),
    ]
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(0xFAFAFA)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines.indices, id: \.self) { i in
                    HStack(spacing: 0) {
                        Text(lines[i].0).font(monoRegular(12.5)).foregroundStyle(lines[i].1)
                        if i == lines.count - 1 { Rectangle().fill(Color(0x1E1E1E)).frame(width: 8, height: 15) }
                    }
                }
            }
            .padding(14)
        }
        .clipped()
    }
}

/// A tile: 2pt ink border when focused, nothing otherwise (Omarchy: border_size 2, active border coloured)
struct Tile<C: View>: View {
    var focused = false
    @ViewBuilder let content: C
    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? ink : base150, lineWidth: focused ? 2 : 1))
    }
}

let gap: CGFloat = 6   // Omarchy gaps_in 5; the window's own edge has no gap, like Alen's outer gaps

/// A window as AeroSpace tiles it: rounded, no title bar
struct WindowBox<C: View>: View {
    let w: CGFloat, h: CGFloat
    @ViewBuilder let content: C
    var body: some View { content.frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 10)) }
}

/// The SketchyBar, as render.swift draws it (trimmed)
struct Bar: View {
    let width: CGFloat
    var body: some View {
        ZStack {
            paper
            HStack(spacing: 2) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8"], id: \.self) { s in
                    Text(s == "8" ? gFocused : s).font(mono(13)).foregroundStyle(ink.opacity(["4", "5", "6", "7"].contains(s) ? 0.5 : 1)).frame(width: 20)
                }
                Text("Casa").font(mono(13)).foregroundStyle(ink).padding(.leading, 12)
            }
            .padding(.leading, 9).frame(maxWidth: .infinity, alignment: .leading)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10, bottomTrailingRadius: 10, topTrailingRadius: 0)
                .fill(.black).frame(width: 185, height: 32).position(x: width / 2, y: 16)
            HStack(spacing: 0) {
                Text("Sunday").foregroundStyle(grey); Text("10:14").foregroundStyle(ink).padding(.leading, 9)
            }.font(mono(13)).frame(width: 300, alignment: .trailing).position(x: width / 2 - 106 - 150, y: 16)
        }
        .frame(width: width, height: 32)
    }
}

struct Wide<C: View>: View {
    @ViewBuilder let content: C
    var body: some View { VStack(spacing: 0) { Bar(width: 1280); content }.background(base50) }
}
struct Narrow<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        content.background(RoundedRectangle(cornerRadius: 10).fill(base50).shadow(color: .black.opacity(0.18), radius: 18, y: 8))
            .padding(24).background(base50)
    }
}

// MARK: D. Tiles

/// d1: browser | terminal, terminal focused. cmd-enter from the page split it to the right (dwindle, force_split 2)
struct D1: View {
    var body: some View {
        WindowBox(w: 1280, h: 800) {
            VStack(spacing: 0) {
                Strip(width: 1280, numbers: ["1", "■", "3"], pill: terminalPill("casa-browser", "2/3"))
                HStack(spacing: gap) {
                    Tile { Page() }
                    Tile(focused: true) { Terminal() }.frame(width: 1280 * 0.42)
                }
                .padding([.horizontal, .bottom], gap).background(paper)
            }
        }
    }
}

/// d2: three panes, browser left focused; the right column was split again (taller than wide → stacked)
struct D2: View {
    var body: some View {
        WindowBox(w: 1280, h: 800) {
            VStack(spacing: 0) {
                Strip(width: 1280, numbers: ["1", "■", "3"], pill: hostPill("alen.ro", "2/3"))
                HStack(spacing: gap) {
                    Tile(focused: true) { Page() }
                    VStack(spacing: gap) {
                        Tile { Page(title: "Casa — handoff", site: "github.com") }
                        Tile { Terminal() }
                    }
                    .frame(width: 1280 * 0.42)
                }
                .padding([.horizontal, .bottom], gap).background(paper)
            }
        }
    }
}

/// d3: the terminal of d2 zoomed (cmd-shift-F): it fills the workspace alone, the pill says so
struct D3: View {
    var body: some View {
        WindowBox(w: 1280, h: 800) {
            VStack(spacing: 0) {
                Strip(width: 1280, numbers: ["1", "■", "3"], pill: AnyView(BlackPill {
                    Text(gZoom).font(mono(11)).foregroundStyle(grey)
                    Text(gConsole).font(mono(11)).foregroundStyle(grey)
                    Text("casa-browser").font(mono(12)).foregroundStyle(paper)
                    Text("2/3").font(mono(10)).foregroundStyle(grey)
                }))
                Terminal()
            }
        }
    }
}

/// d4: a narrow 640 tile: taller than wide, so the terminal went below the page
struct D4: View {
    var body: some View {
        WindowBox(w: 640, h: 800) {
            VStack(spacing: 0) {
                Strip(width: 640, numbers: ["■", "2"], pill: terminalPill("casa-browser", "1/2"))
                VStack(spacing: gap) {
                    Tile { Page() }
                    Tile(focused: true) { Terminal() }.frame(height: 290)
                }
                .padding([.horizontal, .bottom], gap).background(paper)
            }
        }
    }
}

// MARK: Render

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

@MainActor func render<V: View>(_ view: V, _ name: String) {
    let r = ImageRenderer(content: view.environment(\.colorScheme, .light))
    r.scale = 2
    guard let cg = r.cgImage else { print("failed:", name); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: cg.width / 2, height: cg.height / 2)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("wrote \(name).png \(cg.width / 2)x\(cg.height / 2)")
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    render(Wide { D1() }, "d1-tiles-browser-terminal")
    render(Wide { D2() }, "d2-tiles-three")
    render(Wide { D3() }, "d3-tiles-zoomed")
    render(Narrow { D4() }, "d4-tiles-narrow")
}

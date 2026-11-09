// Mockups for Casa, drawn the way the widgets draw: SwiftUI, Flexoki, JetBrainsMono Nerd Font Bold,
// rendered with ImageRenderer at 2x (no window is opened). ./render.sh writes the PNGs next to it.
//
// Three directions:
//   A "Notch"  – no chrome but a black pill over the page (the fake notch's text style), hover/cmd-L grow it
//   B "Rail"   – a 44pt black rail of favicons on the left, hover widens it; the address only on cmd-L
//   C "Strip"  – a 28pt paper strip like SketchyBar: tabs left, host centred, timer/music right
import AppKit
import SwiftUI

// MARK: Flexoki

extension Color {
    init(_ hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}
let paper = Color(0xFFFCF0), base50 = Color(0xF2F0E5), base100 = Color(0xE6E4D9), base150 = Color(0xDAD8CE)
let grey = Color(0x878580), ink = Color(0x100F0F), green = Color(0x879A39), orange = Color(0xDA702C)
let red = Color(0xD14D41), blue = Color(0x4385BE), cyan = Color(0x3AA99F), yellow = Color(0xD0A215), purple = Color(0x8B7EC8)
func mono(_ size: CGFloat) -> Font { .custom("JetBrainsMono Nerd Font", size: size).bold() }

// Nerd Font (Material Design) glyphs
let gLock = "\u{F033E}", gSearch = "\u{F0349}", gBack = "\u{F004D}", gFwd = "\u{F0054}", gReload = "\u{F0450}"
let gPlay = "\u{F040A}", gPause = "\u{F03E4}", gPlus = "\u{F0415}", gClose = "\u{F0156}", gFocused = "\u{F14FB}"
let gChevL = "\u{F0141}", gChevR = "\u{F0142}", gHistory = "\u{F02DA}", gWeb = "\u{F059F}", gTab = "\u{F0B4A}"

// MARK: Data

struct TabInfo { let title: String; let host: String; let letter: String; let color: Color }
let tabs: [TabInfo] = [
    .init(title: "Hacker News", host: "news.ycombinator.com", letter: "Y", color: orange),
    .init(title: "casa-browser: pull requests", host: "github.com", letter: "G", color: purple),
    .init(title: "Tiling on a Mac", host: "alen.ro", letter: "a", color: green),
    .init(title: "Web analytics", host: "eu.posthog.com", letter: "P", color: blue),
    .init(title: "Weather", host: "weather.alen.ro", letter: "W", color: cyan),
    .init(title: "SomaFM: Drone Zone", host: "somafm.com", letter: "S", color: red),
    .init(title: "Omarchy manual", host: "learn.omacom.io", letter: "O", color: yellow),
]
let active = 2
let timerFraction = 0.32   // of the timer gone
let timerLeft = "23:41"

struct Row { let tag: String; let title: String; let sub: String }
let searchRows = [
    Row(tag: gTab, title: "Hacker News", sub: "news.ycombinator.com"),
    Row(tag: gHistory, title: "Show HN: a tiling browser", sub: "news.ycombinator.com/show"),
    Row(tag: gHistory, title: "alentodorov/hn-stremio", sub: "github.com"),
    Row(tag: gWeb, title: "Search \u{201C}hn\u{201D}", sub: "google.com"),
]

// MARK: Pieces

struct Favicon: View {
    let tab: TabInfo
    var size: CGFloat = 16
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25).fill(tab.color).frame(width: size, height: size)
            .overlay(Text(tab.letter).font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(.white))
    }
}

/// The timer, tiny: an arc of the time gone, like the widget's bezel
struct MiniRing: View {
    var size: CGFloat = 14
    var color: Color = paper
    var track: Color = paper.opacity(0.2)
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: size < 20 ? 2 : 2.5)
            Circle().trim(from: 0, to: timerFraction).stroke(color, style: StrokeStyle(lineWidth: size < 20 ? 2 : 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }.frame(width: size, height: size)
    }
}

/// The yt cover art (mocked): Drone Zone's green
struct Cover: View {
    var size: CGFloat = 14
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(LinearGradient(colors: [Color(0x1E4A3A), Color(0x7FB49D)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
    }
}

struct Caret: View {
    var color: Color = paper
    var body: some View { Rectangle().fill(color).frame(width: 1.5, height: 15) }
}

/// A fake article page (white, like most sites), so the chrome is judged over real-looking content
struct Page: View {
    let width: CGFloat
    var topInset: CGFloat = 0
    static let paragraphs = [
        "For a long time I treated macOS windows the way the Finder treats them: dragged roughly into place, overlapping, never quite the same twice. Omarchy changed that. After a month of i3-style tiling on Linux, going back to overlapping windows felt like losing a sense.",
        "AeroSpace brings most of that to the Mac. Workspaces are numbers, windows are tiles, and the keyboard does the rest. The physical cmd key goes to the window manager, the physical option key goes to apps, and after a day you stop noticing the swap.",
        "The browser was the last thing that didn\u{2019}t fit. Chrome\u{2019}s tab strip, its toolbar and its idea of what a window is were built for a different desktop. Every new window needed a script to land on the right workspace, and the chrome took a strip off the top of every tile.",
        "So the plan is a small WebKit browser that treats a window as a tab group, keeps its chrome out of the way, and shows the two things I actually glance at during the day: the timer and whatever mpv is playing.",
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("alen.ro").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(0x1B1B1B))
                Spacer()
                HStack(spacing: 22) {
                    ForEach(["Notes", "Projects", "Weather", "About"], id: \.self) {
                        Text($0).font(.system(size: 13)).foregroundStyle(Color(0x6B6B6B))
                    }
                }
            }
            .padding(.horizontal, 32).frame(height: 56)
            Rectangle().fill(Color(0xEBEBEB)).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                Text("Tiling on a Mac").font(.custom("Georgia", size: 34)).foregroundStyle(Color(0x1B1B1B))
                Text("November 2026 \u{B7} 6 min").font(.system(size: 13)).foregroundStyle(Color(0x8A8A8A))
                ForEach(Page.paragraphs.indices, id: \.self) { i in
                    Text(Page.paragraphs[i]).font(.custom("Georgia", size: 17)).lineSpacing(6).foregroundStyle(Color(0x2A2A2A))
                }
            }
            .frame(width: min(620, width - 64), alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, 44)
            Spacer(minLength: 0)
        }
        .padding(.top, topInset)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white)
    }
}

/// A window as AeroSpace tiles it: rounded, no title bar
struct WindowBox<C: View>: View {
    let w: CGFloat, h: CGFloat
    @ViewBuilder let content: C
    var body: some View {
        content.frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// The SketchyBar, as it is: workspaces and app left, clock left of the fake notch, PostHog right of it
struct Bar: View {
    let width: CGFloat
    var body: some View {
        ZStack {
            paper
            HStack(spacing: 2) {
                ForEach(["1", "2", "3", "4", "5"], id: \.self) { s in
                    Text(s == "3" ? gFocused : s).font(mono(13)).foregroundStyle(ink.opacity(["4", "5"].contains(s) ? 0.5 : 1)).frame(width: 20)
                }
                Text("Casa").font(mono(13)).foregroundStyle(ink).padding(.leading, 12)
            }
            .padding(.leading, 9).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                Text("Saturday").foregroundStyle(grey)
                Text("15:07").foregroundStyle(ink).padding(.leading, 9)
            }
            .font(mono(13)).frame(width: 300, alignment: .trailing).position(x: width / 2 - 106 - 150, y: 16)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10, bottomTrailingRadius: 10, topTrailingRadius: 0)
                .fill(.black).frame(width: 185, height: 32).position(x: width / 2, y: 16)
            HStack(spacing: 14) {
                Text("PostHog").foregroundStyle(ink)
                Text("12% \u{B7} 48%").foregroundStyle(grey)
            }
            .font(mono(13)).frame(width: 300, alignment: .leading).position(x: width / 2 + 106 + 150, y: 16)
            Text("\u{F0082}").font(.custom("JetBrainsMono Nerd Font", size: 16)).foregroundStyle(ink)
                .padding(.trailing, 12).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: width, height: 32)
    }
}

/// The command palette: one surface for URLs, searches, open tabs, history and commands
struct Palette: View {
    let width: CGFloat
    let query: String
    let rows: [Row]
    var selected = 0
    var dark = true
    var input = true   // the strip's own field is the input in C, so its dropdown is just the list
    var fg: Color { dark ? paper : ink }
    var body: some View {
        VStack(spacing: 0) {
            if input {
                HStack(spacing: 10) {
                    Text(gSearch).font(mono(13)).foregroundStyle(grey)
                    Text(query).font(mono(13)).foregroundStyle(fg)
                    Caret(color: fg)
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 40)
                Rectangle().fill(dark ? paper.opacity(0.08) : base100).frame(height: 1)
            }
            VStack(spacing: 2) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        Text(rows[i].tag).font(mono(11)).foregroundStyle(grey).frame(width: 18)
                        Text(rows[i].title).font(mono(12)).foregroundStyle(fg).lineLimit(1)
                        Spacer()
                        Text(rows[i].sub).font(mono(10)).foregroundStyle(grey).lineLimit(1)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(i == selected ? (dark ? paper.opacity(0.1) : base100) : .clear))
                }
            }
            .padding(6)
        }
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: dark ? 13 : 8).fill(dark ? .black : paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(base100, lineWidth: dark ? 0 : 1))
        .shadow(color: .black.opacity(dark ? 0.25 : 0.12), radius: 14, y: 6)
    }
}

/// The tab switcher: every tab in this window, numbered as cmd-1..9 picks them
struct Switcher: View {
    var dark = true
    var fg: Color { dark ? paper : ink }
    var body: some View {
        VStack(spacing: 2) {
            ForEach(tabs.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(mono(10)).foregroundStyle(grey).frame(width: 12)
                    Favicon(tab: tabs[i], size: 16)
                    Text(tabs[i].title).font(mono(12)).foregroundStyle(fg).lineLimit(1)
                    Spacer()
                    Text(tabs[i].host).font(mono(10)).foregroundStyle(grey).lineLimit(1)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(i == active ? (dark ? paper.opacity(0.1) : base100) : .clear))
            }
        }
        .padding(6).frame(width: 460)
        .background(RoundedRectangle(cornerRadius: dark ? 13 : 8).fill(dark ? .black : paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(base100, lineWidth: dark ? 0 : 1))
        .shadow(color: .black.opacity(dark ? 0.25 : 0.12), radius: 14, y: 6)
    }
}

// MARK: A. Notch

enum AState { case browsing, hover, palette, switcher, find, loading }

struct BlackPill<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 12).frame(height: 26)
            .background(Capsule().fill(.black))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

struct NotchWindow: View {
    let w: CGFloat, h: CGFloat
    let state: AState
    var narrow: Bool { w < 800 }

    var body: some View {
        WindowBox(w: w, h: h) {
            ZStack(alignment: .top) {
                // WKWebView.obscuredContentInsets: the page starts 36pt down, its background runs under the pill
                Page(width: w, topInset: 36)
                if state == .loading {
                    Rectangle().fill(ink).frame(width: w * 0.6, height: 2).frame(maxWidth: .infinity, alignment: .leading)
                }
                pill.padding(.top, 6)
                statusPills.padding(.top, 6).padding(.trailing, 8).frame(maxWidth: .infinity, alignment: .trailing)
                if state == .switcher { Switcher().padding(.top, 100) }
            }
        }
    }

    @ViewBuilder var pill: some View {
        switch state {
        case .browsing, .loading:
            BlackPill {
                Text(gLock).font(mono(10)).foregroundStyle(grey)
                Text("alen.ro").font(mono(12)).foregroundStyle(state == .loading ? grey : paper)
                Text("3/7").font(mono(10)).foregroundStyle(grey)
            }
        case .hover:
            BlackPill {
                HStack(spacing: 12) {
                    Text(gBack); Text(gFwd).opacity(0.3); Text(gReload)
                }.font(mono(12)).foregroundStyle(paper.opacity(0.8)).padding(.trailing, 4)
                Text(gLock).font(mono(10)).foregroundStyle(grey)
                (Text("alen.ro").foregroundStyle(paper) + Text("/notes/tiling-on-a-mac").foregroundStyle(grey)).font(mono(12))
                Text("3/7").font(mono(10)).foregroundStyle(grey)
            }
        case .find:
            BlackPill {
                Text(gSearch).font(mono(11)).foregroundStyle(grey)
                Text("aerospace").font(mono(12)).foregroundStyle(paper)
                Caret()
                Text("2/9").font(mono(10)).foregroundStyle(grey).padding(.leading, 6)
                HStack(spacing: 8) { Text(gChevL); Text(gChevR) }.font(mono(11)).foregroundStyle(paper.opacity(0.6))
            }
        case .palette:
            Palette(width: 600, query: "hn", rows: searchRows)
        case .switcher:
            BlackPill {
                Text(gLock).font(mono(10)).foregroundStyle(grey)
                Text("alen.ro").font(mono(12)).foregroundStyle(paper)
                Text("3/7").font(mono(10)).foregroundStyle(grey)
            }
        }
    }

    /// Timer and now-playing, only while they're live; the music pill keeps just its cover when tiled narrow
    var statusPills: some View {
        HStack(spacing: 6) {
            BlackPill {
                MiniRing(size: 13)
                Text(timerLeft).font(mono(11)).foregroundStyle(paper)
            }
            BlackPill {
                Cover(size: 14)
                if !narrow { Text("Drone Zone").font(mono(11)).foregroundStyle(paper) }
            }
        }
    }
}

// MARK: B. Rail

struct RailWindow: View {
    let w: CGFloat, h: CGFloat
    var expanded = false
    var palette = false

    var body: some View {
        WindowBox(w: w, h: h) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    Rectangle().fill(.black).frame(width: 44)
                    Page(width: w - 44)
                }
                if expanded { ExpandedRail(h: h) } else { Rail(h: h) }
                if palette {
                    Palette(width: 600, query: "hn", rows: searchRows)
                        .frame(width: w - 44).padding(.leading, 44).padding(.top, 8)
                }
            }
        }
    }
}

struct Rail: View {
    let h: CGFloat
    var body: some View {
        VStack(spacing: 8) {
            ForEach(tabs.indices, id: \.self) { i in
                ZStack(alignment: .leading) {
                    Favicon(tab: tabs[i], size: 26).opacity(i == active ? 1 : 0.45).frame(width: 44)
                    if i == active {
                        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 2, topTrailingRadius: 2)
                            .fill(paper).frame(width: 3, height: 18)
                    }
                }
            }
            Text(gPlus).font(mono(14)).foregroundStyle(grey).frame(height: 26)
            Spacer()
            MiniRing(size: 24)
            Cover(size: 26).padding(.bottom, 2)
        }
        .padding(.vertical, 10).frame(width: 44, height: h)
    }
}

struct ExpandedRail: View {
    let h: CGFloat
    var body: some View {
        VStack(spacing: 2) {
            ForEach(tabs.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Favicon(tab: tabs[i], size: 22).opacity(i == active ? 1 : 0.6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tabs[i].title).font(mono(12)).foregroundStyle(paper).lineLimit(1)
                        Text(tabs[i].host).font(mono(10)).foregroundStyle(grey).lineLimit(1)
                    }
                    Spacer()
                    if i == active { Text(gClose).font(mono(11)).foregroundStyle(grey) }
                }
                .padding(.horizontal, 10).frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 8).fill(i == active ? paper.opacity(0.1) : .clear))
            }
            HStack(spacing: 10) {
                Text(gPlus).font(mono(14)).frame(width: 22)
                Text("new tab").font(mono(12))
                Spacer()
                Text("\u{2318}T").font(mono(10))
            }
            .foregroundStyle(grey).padding(.horizontal, 10).frame(height: 36)
            Spacer()
            HStack(spacing: 10) {
                MiniRing(size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timerLeft).font(mono(12)).foregroundStyle(paper)
                    Text("ends 15:31").font(mono(10)).foregroundStyle(grey)
                }
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 42)
            HStack(spacing: 10) {
                Cover(size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Drone Zone").font(mono(12)).foregroundStyle(paper)
                    Text("SomaFM \u{B7} 1:02:14").font(mono(10)).foregroundStyle(grey)
                }
                Spacer()
                Text(gPause).font(mono(13)).foregroundStyle(paper.opacity(0.7))
            }
            .padding(.horizontal, 10).frame(height: 42)
        }
        .padding(6).padding(.top, 4).frame(width: 264, height: h)
        .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 12, topTrailingRadius: 12).fill(.black))
        .shadow(color: .black.opacity(0.25), radius: 16, x: 4)
    }
}

// MARK: C. Strip

enum CState { case browsing, palette, tabs, loading }

struct StripWindow: View {
    let w: CGFloat, h: CGFloat
    let state: CState
    var narrow: Bool { w < 800 }

    var body: some View {
        WindowBox(w: w, h: h) {
            VStack(spacing: 0) {
                strip
                ZStack(alignment: .leading) {
                    Rectangle().fill(base100)
                    if state == .loading { Rectangle().fill(ink).frame(width: w * 0.6) }
                }.frame(height: 1)
                Page(width: w)
            }
            .overlay(alignment: .top) {
                if state == .palette { Palette(width: 560, query: "hn", rows: searchRows, dark: false, input: false).padding(.top, 33) }
                if state == .tabs { Switcher(dark: false).padding(.top, 33) }
            }
        }
    }

    var strip: some View {
        ZStack {
            paper
            // tabs, as the bar's workspaces: the active in ink, the rest dim; favicons only when tiled narrow
            HStack(spacing: narrow ? 8 : 14) {
                ForEach(Array((narrow ? tabs : Array(tabs.prefix(4))).enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 6) {
                        Favicon(tab: t, size: 14).opacity(i == active ? 1 : 0.55)
                        if !narrow {
                            Text(t.title).font(mono(12)).foregroundStyle(i == active ? ink : grey).lineLimit(1)
                                .frame(maxWidth: 92, alignment: .leading)
                        }
                    }
                }
                if !narrow { Text("+3").font(mono(11)).foregroundStyle(grey) }
            }
            .fixedSize().padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if state == .palette {
                    Text("hn").font(mono(12)).foregroundStyle(ink)
                    Caret(color: ink)
                } else {
                    Text(gLock).font(mono(10)).foregroundStyle(grey)
                    Text("alen.ro").font(mono(12)).foregroundStyle(state == .loading ? grey : ink)
                }
            }
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    MiniRing(size: 12, color: ink, track: base150)
                    Text(timerLeft).font(mono(12)).foregroundStyle(ink)
                }
                HStack(spacing: 6) {
                    Cover(size: 14)
                    if !narrow { Text("Drone Zone").font(mono(12)).foregroundStyle(grey) }
                }
            }
            .padding(.trailing, 10).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 28)
    }
}

// MARK: Render

/// A full-width tile under the bar (AeroSpace: outer.top 32, no other gap), or a narrow tile on its own
struct Wide<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        VStack(spacing: 0) { Bar(width: 1280); content }.background(base50)
    }
}

struct Narrow<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 10).fill(base50).shadow(color: .black.opacity(0.18), radius: 18, y: 8))
            .padding(24).background(base50)
    }
}

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
    NSApp.setActivationPolicy(.prohibited)   // no dock icon, no window, no focus

    // A. Notch
    render(Wide { NotchWindow(w: 1280, h: 800, state: .browsing) }, "a1-notch-browsing")
    render(Wide { NotchWindow(w: 1280, h: 800, state: .hover) }, "a2-notch-hover")
    render(Wide { NotchWindow(w: 1280, h: 800, state: .palette) }, "a3-notch-palette")
    render(Wide { NotchWindow(w: 1280, h: 800, state: .switcher) }, "a4-notch-switcher")
    render(Narrow { NotchWindow(w: 640, h: 800, state: .loading) }, "a5-notch-narrow-loading")
    render(Narrow { NotchWindow(w: 640, h: 800, state: .find) }, "a6-notch-narrow-find")

    // B. Rail
    render(Wide { RailWindow(w: 1280, h: 800) }, "b1-rail-browsing")
    render(Wide { RailWindow(w: 1280, h: 800, expanded: true) }, "b2-rail-expanded")
    render(Wide { RailWindow(w: 1280, h: 800, palette: true) }, "b3-rail-palette")
    render(Narrow { RailWindow(w: 640, h: 800) }, "b4-rail-narrow")

    // C. Strip
    render(Wide { StripWindow(w: 1280, h: 800, state: .browsing) }, "c1-strip-browsing")
    render(Wide { StripWindow(w: 1280, h: 800, state: .palette) }, "c2-strip-palette")
    render(Wide { StripWindow(w: 1280, h: 800, state: .tabs) }, "c3-strip-tabs")
    render(Narrow { StripWindow(w: 640, h: 800, state: .loading) }, "c4-strip-narrow-loading")
}

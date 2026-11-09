// The chrome, in SwiftUI: the workspace numbers (the bar's style), the pill for the focused pane
// (host, or the terminal's folder; back / forward / reload on hover), the find field in its place,
// the download pill on the right, and the overlays: the palette (one search over panes, history,
// URLs and commands) and the workspace switcher.
import AppKit
import SwiftUI

// MARK: Pieces

struct Tile: View {
    let host: String
    var size: CGFloat = 16
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25).fill(Theme.tileColor(for: host)).frame(width: size, height: size)
            .overlay(Text(String(host.first.map { String($0).uppercased() } ?? "·"))
                .font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(.white))
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

/// An AppKit text field for the palette and find: it owns focus, and arrows / enter / esc go to callbacks
struct KeyField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var selectAll = false
    var onMove: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    final class Field: NSTextField {
        var onMove: (Int) -> Void = { _ in }
        var onSubmit: () -> Void = {}
        var onCancel: () -> Void = {}
        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool {
            let r = super.becomeFirstResponder()
            (currentEditor() as? NSTextView)?.insertionPointColor = Theme.nsPaper
            return r
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyField
        init(_ p: KeyField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            if parent.text != f.stringValue { parent.text = f.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): parent.onMove(1)
            case #selector(NSResponder.insertBacktab(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let f = Field()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = Theme.nsMono(13)
        f.textColor = Theme.nsPaper
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: Theme.nsMono(13), .foregroundColor: NSColor(0x878580)])
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.lineBreakMode = .byClipping
        f.stringValue = text
        f.delegate = context.coordinator
        DispatchQueue.main.async {
            f.window?.makeFirstResponder(f)
            if selectAll { f.currentEditor()?.selectAll(nil) }
            (f.currentEditor() as? NSTextView)?.insertionPointColor = Theme.nsPaper
        }
        return f
    }

    func updateNSView(_ f: Field, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }
}

// MARK: The strip: pill in the middle, the download pill on the right

struct StripView: View {
    @ObservedObject var state: WindowState

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < Theme.narrowWidth
            ZStack(alignment: .top) {
                if let tab = state.focused?.tab { ProgressLine(tab: tab, width: geo.size.width) }
                Group {
                    switch state.mode {
                    case .find: FindPill(state: state)
                    case .palette, .switcher: EmptyView()
                    case .rest:
                        if let pane = state.focused {
                            if let tab = pane.tab { PillView(state: state, pane: pane, tab: tab, narrow: narrow) }
                            else { TerminalPill(state: state, pane: pane) }
                        }
                    }
                }
                .padding(.top, 5)
                .frame(maxWidth: .infinity)
                WorkspaceNumbers(state: state)   // always, like the bar; the palette draws over them when narrow
                    .frame(height: 26)            // the pill's height and line
                    .padding(.top, 5).padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusPills(state: state, narrow: narrow)
                    .padding(.top, 5).padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: Theme.stripHeight)
    }
}

/// The workspaces as Omarchy's bar shows them: 1…5 always, dimmed while empty, higher numbers while
/// in use, the current one a filled square (the same glyph and ink as SketchyBar's workspaces).
/// cmd-1…9 picks them; click one to go to it (an empty one opens blank with the palette). Shown in
/// every mode, palette and switcher included.
struct WorkspaceNumbers: View {
    @ObservedObject var state: WindowState

    var body: some View {
        let used = Set(state.workspaces.map(\.number))
        // 1…5 always; above that only the workspaces that exist, not the gap up to them
        let shown = Array(1...Theme.persistentWorkspaces) + used.filter { $0 > Theme.persistentWorkspaces }.sorted()
        HStack(spacing: 0) {
            ForEach(shown, id: \.self) { n in
                let current = state.current?.number == n
                let inUse = used.contains(n)
                Text(current ? "\u{F14FB}" : (n < 10 ? "\(n)" : "·"))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.ink.opacity(current ? 1 : inUse ? 0.85 : 0.35))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture { state.window?.goToWorkspace(n) }
                    .help(state.workspaces.first { $0.number == n }?.focused?.title ?? "Workspace \(n)")
            }
        }
    }
}

struct ProgressLine: View {
    @ObservedObject var tab: Tab
    let width: CGFloat
    var body: some View {
        if tab.isLoading {
            Rectangle().fill(Theme.ink).frame(width: max(8, width * tab.progress), height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: tab.progress)
        }
    }
}

struct PillView: View {
    @ObservedObject var state: WindowState
    @ObservedObject var pane: Pane
    @ObservedObject var tab: Tab
    let narrow: Bool

    var body: some View {
        let host = displayHost(tab.url)
        BlackPill {
            if state.current?.zoomed === pane { Text(Theme.zoom).font(Theme.mono(11)).foregroundStyle(Theme.grey) }
            if state.hover {
                HStack(spacing: 12) {
                    Button { state.window?.goBack() } label: { Text(Theme.back) }
                        .disabled(!tab.canGoBack).opacity(tab.canGoBack ? 1 : 0.3)
                    Button { state.window?.goForward() } label: { Text(Theme.forward) }
                        .disabled(!tab.canGoForward).opacity(tab.canGoForward ? 1 : 0.3)
                    Button { state.window?.reload(hard: false) } label: { Text(tab.isLoading ? Theme.stop : Theme.reload) }
                }
                .buttonStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.paper.opacity(0.8)).padding(.trailing, 4)
            }
            HStack(spacing: 8) {
                if state.isPrivate {
                    Text(Theme.incognito).font(Theme.mono(11)).foregroundStyle(Theme.grey)
                } else if tab.secure, !host.isEmpty {
                    Text(Theme.lock).font(Theme.mono(10)).foregroundStyle(Theme.grey)
                }
                if host.isEmpty {
                    Text("new tab").font(Theme.mono(12)).foregroundStyle(Theme.grey)
                } else if state.hover, !narrow, let u = tab.url, !u.isFileURL {
                    (Text(host).foregroundStyle(tab.isLoading ? Theme.grey : Theme.paper)
                        + Text(pathPart(u)).foregroundStyle(Theme.grey))
                        .font(Theme.mono(12)).lineLimit(1)
                } else {
                    Text(host).font(Theme.mono(12)).foregroundStyle(tab.isLoading ? Theme.grey : Theme.paper).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { state.window?.openPalette(.url) }
        }
        .frame(maxWidth: narrow ? 300 : 640)
        .onHover { state.hover = $0 }
        .animation(.easeOut(duration: 0.12), value: state.hover)
    }

    func pathPart(_ u: URL) -> String {
        var p = u.path
        if let q = u.query { p += "?" + q }
        if p == "/" { p = "" }
        return p.count > 60 ? String(p.prefix(57)) + "…" : p
    }
}

/// The pill while a terminal pane is focused: the folder it is in
struct TerminalPill: View {
    @ObservedObject var state: WindowState
    @ObservedObject var pane: Pane
    var body: some View {
        BlackPill {
            if state.current?.zoomed === pane { Text(Theme.zoom).font(Theme.mono(11)).foregroundStyle(Theme.grey) }
            Text(Theme.console).font(Theme.mono(11)).foregroundStyle(Theme.grey)
            Text(pane.title).font(Theme.mono(12)).foregroundStyle(Theme.paper).lineLimit(1)
        }
        .frame(maxWidth: 640)
    }
}

struct FindPill: View {
    @ObservedObject var state: WindowState
    var body: some View {
        BlackPill {
            Text(Theme.search).font(Theme.mono(11)).foregroundStyle(Theme.grey)
            KeyField(text: $state.findQuery, placeholder: "find",
                     onMove: { state.window?.findNext(forward: $0 > 0) },
                     onSubmit: { state.window?.findNext(forward: true) },
                     onCancel: { state.window?.closeOverlay() })
                .frame(width: 200, height: 20)
            Text(state.findQuery.isEmpty ? "" : (state.findTotal == 0 ? "none" : "\(state.findIndex)/\(state.findTotal)"))
                .font(Theme.mono(10)).foregroundStyle(Theme.grey).frame(minWidth: 30)
            HStack(spacing: 8) {
                Button { state.window?.findNext(forward: false) } label: { Text(Theme.chevronLeft) }
                Button { state.window?.findNext(forward: true) } label: { Text(Theme.chevronRight) }
            }
            .buttonStyle(.plain).font(Theme.mono(11)).foregroundStyle(Theme.paper.opacity(0.6))
        }
    }
}

struct StatusPills: View {
    @ObservedObject var state: WindowState
    let narrow: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let d = state.download {
                BlackPill {
                    Text(d.failed ? Theme.close : Theme.download).font(Theme.mono(11))
                        .foregroundStyle(d.failed ? Theme.red : d.finished ? Theme.green : Theme.grey)
                    if !narrow { Text(d.name).font(Theme.mono(11)).foregroundStyle(Theme.paper).lineLimit(1).frame(maxWidth: 160) }
                }
                .onTapGesture { state.window?.revealDownload() }
            }
        }
    }
}

// MARK: Overlays

struct OverlayView: View {
    @ObservedObject var state: WindowState
    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.contentShape(Rectangle()).onTapGesture { state.window?.closeOverlay() }
            switch state.mode {
            case .palette: PaletteView(state: state).padding(.top, 5)
            case .switcher: SwitcherView(state: state).padding(.top, 100)
            default: EmptyView()
            }
        }
    }
}

struct PaletteView: View {
    @ObservedObject var state: WindowState
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(Theme.search).font(Theme.mono(13)).foregroundStyle(Theme.grey)
                    KeyField(text: $state.paletteQuery, placeholder: state.paletteMode == .tabs ? "tabs, history, > commands" : "address or search",
                             selectAll: true,
                             onMove: { state.window?.moveSelection($0) },
                             onSubmit: { state.window?.runPalette() },
                             onCancel: { state.window?.closeOverlay() })
                        .frame(height: 20)
                }
                .padding(.horizontal, 14).frame(height: 40)
                if !state.paletteRows.isEmpty {
                    Rectangle().fill(Theme.paper.opacity(0.08)).frame(height: 1)
                    VStack(spacing: 2) {
                        ForEach(Array(state.paletteRows.enumerated()), id: \.element.id) { i, row in
                            HStack(spacing: 10) {
                                Text(row.glyph).font(Theme.mono(11)).foregroundStyle(Theme.grey).frame(width: 18)
                                Text(row.title).font(Theme.mono(12)).foregroundStyle(Theme.paper).lineLimit(1)
                                Spacer()
                                Text(row.subtitle).font(Theme.mono(10)).foregroundStyle(Theme.grey).lineLimit(1).frame(maxWidth: 260, alignment: .trailing)
                            }
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(i == state.paletteSelection ? Theme.paper.opacity(0.1) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { state.paletteSelection = i; state.window?.runPalette() }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: min(600, geo.size.width - 24))
            .background(RoundedRectangle(cornerRadius: 13).fill(.black))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            .frame(maxWidth: .infinity)
        }
    }
}

struct SwitcherView: View {
    @ObservedObject var state: WindowState
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 2) {
                ForEach(Array(state.workspaces.enumerated()), id: \.element.number) { i, w in
                    SwitcherRow(workspace: w, selected: i == state.switcherSelection)
                        .onTapGesture { state.switcherSelection = i; state.window?.commitSwitcher() }
                }
            }
            .padding(6).frame(width: min(460, geo.size.width - 24))
            .background(RoundedRectangle(cornerRadius: 13).fill(.black))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A workspace: its number, the focused pane's tile and title, the host (and how many panes it holds)
struct SwitcherRow: View {
    @ObservedObject var workspace: Workspace
    let selected: Bool
    var body: some View {
        let pane = workspace.focused
        let host = pane?.host ?? ""
        let count = workspace.panes.count
        HStack(spacing: 10) {
            Text(workspace.number < 10 ? "\(workspace.number)" : "·").font(Theme.mono(10)).foregroundStyle(Theme.grey).frame(width: 12)
            if pane?.isBrowser == true {
                Tile(host: host, size: 16)
            } else {
                Text(Theme.console).font(Theme.mono(12)).foregroundStyle(Theme.grey).frame(width: 16)
            }
            Text(pane.map { $0.title.isEmpty ? (host.isEmpty ? ($0.isBrowser ? "new tab" : "terminal") : host) : $0.title } ?? "")
                .font(Theme.mono(12)).foregroundStyle(Theme.paper).lineLimit(1)
            Spacer()
            Text(count > 1 ? "\(host.isEmpty ? "" : host + " \u{B7} ")\(count) panes" : host)
                .font(Theme.mono(10)).foregroundStyle(Theme.grey).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.paper.opacity(0.1) : .clear))
        .contentShape(Rectangle())
    }
}

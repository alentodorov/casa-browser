// A workspace is Hyprland's dwindle layout over panes: a binary tree whose leaves are browser or
// terminal panes and whose inner nodes are splits (side by side or stacked) with a ratio. New panes
// split the focused one along its longer side and land right or below (Omarchy: force_split 2,
// preserve_split). Nothing here knows about windows; BrowserWindow owns the views.
import AppKit
import Combine

enum Axis { case horizontal, vertical }   // horizontal: side by side; vertical: stacked
enum Direction { case left, right, up, down }

/// The container a pane's view sits in: rounded, and when tiled bordered as Omarchy does on Flexoki
/// Light: 2pt in the theme accent on the focused pane. The others get a thin base150 line (Omarchy's
/// 2px grey there was too heavy on paper).
final class PaneBox: NSView {
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }

    func style(focused: Bool, tiled: Bool) {
        guard let l = layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.cornerRadius = tiled ? 6 : 0
        l.borderWidth = tiled ? (focused ? 2 : 1) : 0
        l.borderColor = (focused ? Theme.nsAccent : Theme.nsBase150).cgColor
        CATransaction.commit()
    }
}

@MainActor
final class Pane: ObservableObject, Identifiable {
    enum Kind { case browser(Tab), terminal(TerminalView) }
    let id = UUID()
    let kind: Kind
    let box = PaneBox()
    @Published var title = ""
    @Published var host = ""
    private var subs: [AnyCancellable] = []

    var tab: Tab? { if case .browser(let t) = kind { return t }; return nil }
    var terminal: TerminalView? { if case .terminal(let t) = kind { return t }; return nil }
    var isBrowser: Bool { tab != nil }
    var view: NSView { tab?.webView ?? terminal! }

    init(_ kind: Kind) {
        self.kind = kind
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
        switch kind {
        case .browser(let t):
            subs = [
                t.$title.sink { [weak self] s in self?.title = s },
                t.$url.sink { [weak self] u in self?.host = displayHost(u) },
            ]
        case .terminal(let t):
            let name = { (p: String?) -> String in
                let path = p ?? t.workingDirectory
                let tilde = path.hasPrefix(Paths.home) ? "~" + path.dropFirst(Paths.home.count) : path
                return tilde == "~" ? "~" : (tilde as NSString).lastPathComponent
            }
            title = name(nil)
            t.onPwd = { [weak self] p in self?.title = name(p) }
        }
    }

    func focus(in window: NSWindow) { window.makeFirstResponder(view) }
}

/// A node of the layout tree: a leaf holds a pane, a split holds two children
@MainActor
final class Node {
    weak var parent: Node?
    var pane: Pane?
    var axis: Axis = .horizontal
    var ratio: CGFloat = 0.5
    var first: Node?
    var second: Node?

    init(pane: Pane) { self.pane = pane }
    init(axis: Axis, ratio: CGFloat, first: Node, second: Node) {
        self.axis = axis; self.ratio = ratio; self.first = first; self.second = second
        first.parent = self; second.parent = self
    }

    var isLeaf: Bool { pane != nil }
    var leaves: [Pane] { pane.map { [$0] } ?? ((first?.leaves ?? []) + (second?.leaves ?? [])) }

    func find(_ p: Pane) -> Node? {
        if pane === p { return self }
        return first?.find(p) ?? second?.find(p)
    }

    /// Takes over another node's content (used when a split collapses to its remaining child)
    func become(_ n: Node) {
        pane = n.pane; axis = n.axis; ratio = n.ratio; first = n.first; second = n.second
        first?.parent = self; second?.parent = self
    }
}

@MainActor
final class Workspace: ObservableObject {
    let number: Int
    private(set) var root: Node?
    @Published private(set) var focused: Pane?
    @Published var zoomed: Pane?
    /// The frames of the last layout, by pane and by node, for direction queries and resizing
    private(set) var paneFrames: [UUID: CGRect] = [:]
    private var nodeFrames: [ObjectIdentifier: CGRect] = [:]
    static let gap: CGFloat = 6

    init(number: Int) { self.number = number }

    var panes: [Pane] { root?.leaves ?? [] }
    var isEmpty: Bool { root == nil }

    func setFocus(_ p: Pane?) { if focused !== p { focused = p } }

    /// Adds a pane: the first one becomes the root, later ones split the target (or the focused pane)
    /// along its longer side and land right or below
    func insert(_ pane: Pane, splitting target: Pane? = nil) {
        guard let root else { self.root = Node(pane: pane); focused = pane; return }
        let t = target ?? focused ?? root.leaves.last!
        guard let leaf = root.find(t) else { return }
        let f = paneFrames[t.id] ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let a = Node(pane: t), b = Node(pane: pane)
        leaf.pane = nil
        leaf.axis = f.width >= f.height ? .horizontal : .vertical
        leaf.ratio = 0.5
        leaf.first = a; leaf.second = b
        a.parent = leaf; b.parent = leaf
        if zoomed != nil { zoomed = nil }
        focused = pane
    }

    /// Removes a pane; its sibling takes the parent's place. Focus moves to the nearest remaining pane.
    func remove(_ pane: Pane) {
        guard let root, let leaf = root.find(pane) else { return }
        if zoomed === pane { zoomed = nil }
        let old = paneFrames[pane.id]
        if let p = leaf.parent {
            let sibling = (p.first === leaf ? p.second : p.first)!
            p.become(sibling)
        } else {
            self.root = nil
        }
        if focused === pane {
            let remaining = panes
            if let old, !remaining.isEmpty {
                let c = CGPoint(x: old.midX, y: old.midY)
                focused = remaining.min { a, b in
                    let fa = paneFrames[a.id] ?? .zero, fb = paneFrames[b.id] ?? .zero
                    return hypot(fa.midX - c.x, fa.midY - c.y) < hypot(fb.midX - c.x, fb.midY - c.y)
                }
            } else {
                focused = remaining.last
            }
        }
    }

    func swap(_ a: Pane, _ b: Pane) {
        guard let root, let na = root.find(a), let nb = root.find(b) else { return }
        na.pane = b; nb.pane = a
    }

    /// Flips the split the pane sits in (Omarchy's Super+J)
    func toggleSplit(_ pane: Pane) {
        guard let p = root?.find(pane)?.parent else { return }
        p.axis = p.axis == .horizontal ? .vertical : .horizontal
    }

    /// Hyprland's keyboard `resizeactive` in dwindle (DwindleLayout::resizeActiveWindow with no corner,
    /// smart_resizing on): the nearest split on that axis above the pane gets its ratio moved by the
    /// delta, whichever side of it the pane is on. So the keys move the divider: negative left / up,
    /// positive right / down, and the focused pane grows or shrinks depending on its side. Same clamp
    /// as Hyprland's 0.1…1.9 of a half.
    func moveDivider(of pane: Pane, axis: Axis, by delta: CGFloat) {
        guard let root, var node = root.find(pane) else { return }
        while let p = node.parent {
            if p.axis == axis, let f = nodeFrames[ObjectIdentifier(p)] {
                let size = (axis == .horizontal ? f.width : f.height) - Workspace.gap
                guard size > 0 else { return }
                p.ratio = min(0.95, max(0.05, p.ratio + delta / size))
                return
            }
            node = p
        }
    }

    /// Lays the tree out in `rect` (flipped coordinates, y down) and remembers every frame
    func layout(in rect: CGRect) -> [UUID: CGRect] {
        paneFrames = [:]; nodeFrames = [:]
        guard let root else { return [:] }
        if let z = zoomed, root.find(z) != nil {
            paneFrames[z.id] = rect
            return paneFrames
        }
        let tiled = !root.isLeaf
        let inner = tiled ? rect.insetBy(dx: Workspace.gap, dy: Workspace.gap) : rect
        place(root, in: inner)
        return paneFrames
    }

    private func place(_ n: Node, in r: CGRect) {
        nodeFrames[ObjectIdentifier(n)] = r
        if let p = n.pane { paneFrames[p.id] = r; return }
        guard let a = n.first, let b = n.second else { return }
        let g = Workspace.gap
        if n.axis == .horizontal {
            let w = max(0, r.width - g), wa = (w * n.ratio).rounded()
            place(a, in: CGRect(x: r.minX, y: r.minY, width: wa, height: r.height))
            place(b, in: CGRect(x: r.minX + wa + g, y: r.minY, width: w - wa, height: r.height))
        } else {
            let h = max(0, r.height - g), ha = (h * n.ratio).rounded()
            place(a, in: CGRect(x: r.minX, y: r.minY, width: r.width, height: ha))
            place(b, in: CGRect(x: r.minX, y: r.minY + ha + g, width: r.width, height: h - ha))
        }
    }

    /// The pane next to `pane` in a direction: adjacent across the gap, overlapping it, preferring the
    /// one in line with its centre (Hyprland's movefocus)
    func neighbour(of pane: Pane, _ dir: Direction) -> Pane? {
        guard let f = paneFrames[pane.id] else { return nil }
        let tol = Workspace.gap + 2
        var best: (Pane, CGFloat)?
        for p in panes where p !== pane {
            guard let g = paneFrames[p.id] else { continue }
            let adjacent: Bool, overlap: CGFloat, centred: Bool
            switch dir {
            case .left:
                adjacent = abs(g.maxX - f.minX) <= tol
                overlap = min(f.maxY, g.maxY) - max(f.minY, g.minY); centred = g.minY <= f.midY && f.midY <= g.maxY
            case .right:
                adjacent = abs(g.minX - f.maxX) <= tol
                overlap = min(f.maxY, g.maxY) - max(f.minY, g.minY); centred = g.minY <= f.midY && f.midY <= g.maxY
            case .up:
                adjacent = abs(g.maxY - f.minY) <= tol
                overlap = min(f.maxX, g.maxX) - max(f.minX, g.minX); centred = g.minX <= f.midX && f.midX <= g.maxX
            case .down:
                adjacent = abs(g.minY - f.maxY) <= tol
                overlap = min(f.maxX, g.maxX) - max(f.minX, g.minX); centred = g.minX <= f.midX && f.midX <= g.maxX
            }
            guard adjacent, overlap > 0 else { continue }
            let score = overlap + (centred ? 100_000 : 0)
            if best == nil || score > best!.1 { best = (p, score) }
        }
        return best?.0
    }

    // MARK: Session

    func encode() -> Session.Node? { root.map { encode($0) } }

    private func encode(_ n: Node) -> Session.Node {
        if let p = n.pane {
            if let t = p.tab { return Session.Node(url: t.isBlank ? "about:blank" : t.url?.absoluteString ?? "about:blank") }
            return Session.Node(cwd: p.terminal?.pwd ?? p.terminal?.workingDirectory ?? Paths.home)
        }
        return Session.Node(axis: n.axis == .horizontal ? "h" : "v", ratio: Double(n.ratio),
                            children: [encode(n.first!), encode(n.second!)])
    }

    /// Rebuilds the tree from a session; `make` turns a saved leaf into a pane
    func restore(_ s: Session.Node, make: (Session.Node) -> Pane?) {
        root = build(s, make: make)
        focused = panes.first
    }

    private func build(_ s: Session.Node, make: (Session.Node) -> Pane?) -> Node? {
        if let c = s.children, c.count == 2 {
            let a = build(c[0], make: make), b = build(c[1], make: make)
            switch (a, b) {
            case let (a?, b?): return Node(axis: s.axis == "v" ? .vertical : .horizontal, ratio: CGFloat(s.ratio ?? 0.5), first: a, second: b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            default: return nil
            }
        }
        return make(s).map { Node(pane: $0) }
    }
}

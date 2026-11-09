// What Casa remembers between launches: visited pages (for the palette), the open windows and tabs,
// and zoom per host. All under ~/.local/state/casa.
import Foundation

struct HistoryEntry {
    var url: String
    var title: String
    var count: Int
    var last: Double
}

@MainActor
final class History {
    static let shared = History()
    private(set) var entries: [String: HistoryEntry] = [:]
    private var handle: FileHandle?

    private init() {
        Paths.ensureState()
        if let d = FileManager.default.contents(atPath: Paths.history), let text = String(data: d, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let u = j["u"] as? String else { continue }
                var e = entries[u] ?? HistoryEntry(url: u, title: "", count: 0, last: 0)
                if let t = j["t"] as? String, !t.isEmpty { e.title = t }
                e.count += 1
                e.last = max(e.last, (j["l"] as? NSNumber)?.doubleValue ?? 0)
                entries[u] = e
            }
        }
        if !FileManager.default.fileExists(atPath: Paths.history) {
            FileManager.default.createFile(atPath: Paths.history, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: Paths.history)
        handle?.seekToEndOfFile()
    }

    func visit(_ url: URL, title: String) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let u = url.absoluteString
        var e = entries[u] ?? HistoryEntry(url: u, title: "", count: 0, last: 0)
        if !title.isEmpty { e.title = title }
        e.count += 1
        e.last = Date().timeIntervalSince1970
        entries[u] = e
        if let d = try? JSONSerialization.data(withJSONObject: ["u": u, "t": e.title, "l": e.last]) {
            handle?.write(d + Data("\n".utf8))
        }
    }

    /// Entries whose title or URL contain every word of the query, best first
    func search(_ query: String, limit: Int = 6) -> [HistoryEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let hits = entries.values.filter { e in
            let hay = (e.title + " " + e.url).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        return hits.sorted { a, b in
            let sa = Double(a.count) * 10 + a.last / 86400, sb = Double(b.count) * 10 + b.last / 86400
            return sa > sb
        }.prefix(limit).map { $0 }
    }
}

/// The open windows, their workspaces and each workspace's pane tree, written on every change and
/// restored at launch. Terminals come back as fresh shells in their saved directory.
enum Session {
    struct Window: Codable {
        var frame: [Double]   // x y w h
        var workspaces: [Workspace]
        var current: Int      // workspace number
    }

    struct Workspace: Codable {
        var number: Int
        var tree: Node
        var focused: Int      // index into the tree's leaves, left to right
        var zoomed: Bool
    }

    /// A leaf is a browser (`url`) or a terminal (`cwd`); a split has an axis ("h" side by side, "v"
    /// stacked), a ratio and two children
    struct Node: Codable {
        var url: String?
        var cwd: String?
        var axis: String?
        var ratio: Double?
        var children: [Node]?
        init(url: String) { self.url = url }
        init(cwd: String) { self.cwd = cwd }
        init(axis: String, ratio: Double, children: [Node]) { self.axis = axis; self.ratio = ratio; self.children = children }
        var leaves: [Node] { children.map { $0.flatMap(\.leaves) } ?? [self] }
    }

    /// The v1 format: one tab per URL
    private struct LegacyWindow: Codable {
        var urls: [String]
        var active: Int
        var frame: [Double]
    }

    static func save(_ windows: [Window]) {
        Paths.ensureState()
        if let d = try? JSONEncoder().encode(windows) { try? d.write(to: URL(fileURLWithPath: Paths.session)) }
    }

    static func load() -> [Window] {
        guard let d = FileManager.default.contents(atPath: Paths.session) else { return [] }
        if let w = try? JSONDecoder().decode([Window].self, from: d) { return w.filter { !$0.workspaces.isEmpty } }
        guard let old = try? JSONDecoder().decode([LegacyWindow].self, from: d) else { return [] }
        return old.compactMap { w in
            let ws = w.urls.enumerated().map { i, u in Workspace(number: i + 1, tree: Node(url: u), focused: 0, zoomed: false) }
            guard !ws.isEmpty else { return nil }
            return Window(frame: w.frame, workspaces: ws, current: min(max(0, w.active), ws.count - 1) + 1)
        }
    }
}

enum ZoomStore {
    private static var table: [String: Double] = {
        guard let d = FileManager.default.contents(atPath: Paths.zoom),
              let t = try? JSONSerialization.jsonObject(with: d) as? [String: Double] else { return [:] }
        return t
    }()

    static func zoom(for host: String) -> Double { table[host] ?? 1 }

    static func set(_ z: Double, for host: String) {
        guard !host.isEmpty else { return }
        if abs(z - 1) < 0.001 { table.removeValue(forKey: host) } else { table[host] = z }
        Paths.ensureState()
        if let d = try? JSONSerialization.data(withJSONObject: table) { try? d.write(to: URL(fileURLWithPath: Paths.zoom)) }
    }
}

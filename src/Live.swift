// The two things worth a glance while browsing: the timer (~/.local/state/timer/current.json, shared
// with the `timer` command and the timer widget) and what `yt`'s mpv is playing (its IPC socket and
// tracks.json). Polled once a second; the pills only show while either is live.
import AppKit
import Combine

struct TimerInfo: Equatable {
    var left: Double
    var fraction: Double   // of the time gone
    var paused: Bool
    var done: Bool
}

struct MusicInfo: Equatable {
    var title: String
    var paused: Bool
    var coverURL: String?
}

/// Sends commands to mpv and returns each reply's "data" (nil when mpv isn't running). From the yt widget.
func mpv(_ commands: [[Any]]) -> [Any?]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in Paths.mpvSocket.utf8.prefix(buf.count - 1).enumerated() { buf[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { return nil }
    var tv = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var out = Data()
    for (i, c) in commands.enumerated() {
        guard let d = try? JSONSerialization.data(withJSONObject: ["command": c, "request_id": i + 1]) else { return nil }
        out += d
        out += Data("\n".utf8)
    }
    _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }

    var replies = [Int: Any?](), buffer = Data(), chunk = [UInt8](repeating: 0, count: 65536)
    while replies.count < commands.count {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer += Data(chunk[0..<n])
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[(nl + 1)...])
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = msg["request_id"] as? Int, id > 0 else { continue }
            replies[id] = msg["data"]
        }
    }
    return (1...commands.count).map { replies[$0] ?? nil }
}

@MainActor
final class Live: ObservableObject {
    static let shared = Live()

    @Published var timer: TimerInfo?
    @Published var music: MusicInfo?
    @Published var cover: NSImage?
    private var coverFor: String?
    private var ticks = 0

    private init() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        tick()
    }

    private func tick() {
        ticks += 1
        pollTimer()
        if ticks % 2 == 0 { pollMusic() }
    }

    private func pollTimer() {
        guard let d = FileManager.default.contents(atPath: Paths.timer),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let duration = (j["duration"] as? NSNumber)?.doubleValue else {
            if timer != nil { timer = nil }
            return
        }
        let now = Date().timeIntervalSince1970
        let end = (j["end"] as? NSNumber)?.doubleValue
        let pausedLeft = (j["paused_left"] as? NSNumber)?.doubleValue
        let done = j["done"] as? Bool ?? false
        let left = max(0, end.map { $0 - now } ?? pausedLeft ?? 0)
        let fraction = done ? 1 : (duration > 0 ? 1 - left / duration : 0)
        let info = TimerInfo(left: left, fraction: fraction, paused: end == nil && !done, done: done)
        if info != timer { timer = info }
    }

    private func pollMusic() {
        let r = mpv([["get_property", "path"], ["get_property", "media-title"], ["get_property", "pause"]])
        guard let r, let path = r[0] as? String else {
            if music != nil { music = nil; cover = nil; coverFor = nil }
            return
        }
        var title = r[1] as? String ?? ""
        var coverURL: String?
        if let d = FileManager.default.contents(atPath: Paths.tracks),
           let all = try? JSONSerialization.jsonObject(with: d) as? [String: [String: String]], let t = all[path] {
            if let tt = t["title"], !tt.isEmpty { title = tt }
            coverURL = t["thumbnail"]
        }
        let info = MusicInfo(title: title, paused: r[2] as? Bool ?? false, coverURL: coverURL)
        if info != music { music = info }
        if let coverURL, coverURL != coverFor {
            coverFor = coverURL
            cover = nil
            Task.detached {
                guard let url = URL(string: coverURL), let (data, _) = try? await URLSession.shared.data(from: url),
                      let img = NSImage(data: data) else { return }
                await MainActor.run { if self.coverFor == coverURL { self.cover = img } }
            }
        } else if coverURL == nil, cover != nil {
            cover = nil; coverFor = nil
        }
    }

    func togglePause() { _ = mpv([["cycle", "pause"]]) }
}

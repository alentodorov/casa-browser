// Reading other browsers' data, the way cmux's importer does (its BrowserDataImporter): copy the
// browser's SQLite files to a temp snapshot, query them, and for Chromium decrypt the cookie values
// with the "<Browser> Safe Storage" key from the Keychain. Casa adds what cmux leaves out: Safari's
// Cookies.binarycookies, and the HttpOnly / SameSite flags. Nothing here touches WebKit or AppKit;
// Import.swift applies the result.
import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

struct ImportedCookie {
    var domain: String        // ".example.com" for a domain cookie, "example.com" for a host-only one
    var name: String
    var value: String
    var path: String
    var expires: Date?        // nil: a session cookie
    var secure: Bool
    var httpOnly: Bool
    var sameSite: String?     // "lax", "strict", "none" or nil when unspecified
}

struct ImportedVisit {
    var url: String
    var title: String
    var count: Int
    var last: Date
}

struct ImportSource {
    enum Kind { case chromium(keychainService: String, keychainAccount: String), safari }
    let id: String            // "chrome/Default", "safari"
    let browser: String       // "chrome"
    let profile: String       // "Alen-Jelco", or "" when the browser has one
    let root: URL             // the profile folder (Chromium) or ~/Library (Safari)
    let kind: Kind
    var label: String { profile.isEmpty ? browser : "\(browser): \(profile)" }
}

enum ImportError: Error {
    case noAccess             // macOS privacy (Full Disk Access) keeps the file from us
    case missing
    case unreadable(String)
}

enum BrowserSources {
    static let historyLimit = 5000   // most recent pages, as cmux takes
    static let frequentLimit = 2000  // plus the most visited ones, which may be older than those

    private static let chromiumFamily: [(id: String, dir: String, service: String, account: String)] = [
        ("chrome", "Google/Chrome", "Chrome Safe Storage", "Chrome"),
        ("arc", "Arc/User Data", "Arc Safe Storage", "Arc"),
        ("brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage", "Brave"),
        ("edge", "Microsoft Edge", "Microsoft Edge Safe Storage", "Microsoft Edge"),
        ("chromium", "Chromium", "Chromium Safe Storage", "Chromium"),
    ]

    /// Every browser profile found on this Mac that has something to import
    static func all() -> [ImportSource] {
        let fm = FileManager.default
        let support = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        var out: [ImportSource] = []
        for b in chromiumFamily {
            let dir = support.appendingPathComponent(b.dir)
            guard fm.fileExists(atPath: dir.path) else { continue }
            var names: [String: String] = [:]
            var lastUsed = "Default"
            if let d = try? Data(contentsOf: dir.appendingPathComponent("Local State")),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let profile = j["profile"] as? [String: Any] {
                lastUsed = profile["last_used"] as? String ?? lastUsed
                for (key, v) in profile["info_cache"] as? [String: [String: Any]] ?? [:] { names[key] = v["name"] as? String ?? key }
            }
            if names.isEmpty { names["Default"] = "" }
            let keys = names.keys.sorted { a, b in a == lastUsed ? true : b == lastUsed ? false : a < b }
            for key in keys {
                let root = dir.appendingPathComponent(key)
                guard cookiesFile(in: root) != nil || fm.fileExists(atPath: root.appendingPathComponent("History").path) else { continue }
                out.append(ImportSource(id: "\(b.id)/\(key)", browser: b.id, profile: names.count > 1 ? (names[key] ?? key) : "",
                                        root: root, kind: .chromium(keychainService: b.service, keychainAccount: b.account)))
            }
        }
        if fm.fileExists(atPath: "/Applications/Safari.app") {
            out.append(ImportSource(id: "safari", browser: "safari", profile: "",
                                    root: URL(fileURLWithPath: NSHomeDirectory() + "/Library"), kind: .safari))
        }
        return out
    }

    // MARK: Chromium

    private static func cookiesFile(in root: URL) -> URL? {
        let candidates = [root.appendingPathComponent("Network/Cookies"), root.appendingPathComponent("Cookies")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The browser's cookie key from the login Keychain. macOS asks the user to allow it (once, or
    /// always); the call blocks while it asks, so never make it on the main thread.
    static func keychainPassword(service: String, account: String) -> Result<Data, ImportError> {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        guard status == errSecSuccess, let d = raw as? Data, !d.isEmpty else {
            return .failure(status == errSecItemNotFound ? .missing : .noAccess)
        }
        return .success(d)
    }

    /// Chromium's cookie encryption on macOS ("v10"): AES-128-CBC, key = PBKDF2-HMAC-SHA1 of the
    /// Keychain password with salt "saltysalt" and 1003 rounds, IV = 16 spaces. Since cookie database
    /// version 24 the plaintext starts with SHA-256 of the host key.
    struct ChromiumCrypt {
        let key: Data
        init?(password: Data) {
            let salt = Array("saltysalt".utf8)
            var derived = [UInt8](repeating: 0, count: kCCKeySizeAES128)
            let ok = password.withUnsafeBytes { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &derived, derived.count)
            }
            guard ok == kCCSuccess else { return nil }
            key = Data(derived)
        }

        func crypt(_ op: Int, _ input: Data) -> Data? {
            let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
            var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
            var n = 0
            let status = key.withUnsafeBytes { k in
                input.withUnsafeBytes { i in
                    CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, iv,
                            i.baseAddress, input.count, &out, out.count, &n)
                }
            }
            return status == kCCSuccess ? Data(out.prefix(n)) : nil
        }

        func decrypt(_ encrypted: Data, host: String) -> String? {
            guard encrypted.count > 3, let tag = String(data: encrypted.prefix(3), encoding: .ascii), tag == "v10" || tag == "v11",
                  var plain = crypt(kCCDecrypt, Data(encrypted.dropFirst(3))) else { return nil }
            let digest = Data(SHA256.hash(data: Data(host.utf8)))
            if plain.starts(with: digest) { plain = Data(plain.dropFirst(digest.count)) }
            return String(data: plain, encoding: .utf8)
        }

        /// The inverse, for the self-test
        func encrypt(_ value: String, host: String, withHostDigest: Bool) -> Data? {
            var plain = withHostDigest ? Data(SHA256.hash(data: Data(host.utf8))) : Data()
            plain.append(Data(value.utf8))
            return crypt(kCCEncrypt, plain).map { Data("v10".utf8) + $0 }
        }
    }

    struct CookieRead {
        var cookies: [ImportedCookie] = []
        var locked = 0        // encrypted, and no key or a wrong one
        var skipped = 0       // partitioned (CHIPS) cookies, which WebKit's store can't hold
    }

    /// The profile's cookies. Without `password` only the (rare) unencrypted ones come back; the rest count as locked.
    static func chromiumCookies(_ source: ImportSource, password: Data?) throws -> CookieRead {
        guard let file = cookiesFile(in: source.root) else { throw ImportError.missing }
        let crypt = password.flatMap { ChromiumCrypt(password: $0) }
        var r = CookieRead()
        let now = Date()
        try query(file, "SELECT host_key, name, value, path, expires_utc, is_secure, is_httponly, samesite, has_expires, encrypted_value, top_frame_site_key FROM cookies") { s in
            let host = text(s, 0), name = text(s, 1)
            guard !name.isEmpty, !host.isEmpty else { return }
            if !text(s, 10).isEmpty { r.skipped += 1; return }
            var value = text(s, 2)
            let encrypted = blob(s, 9)
            if value.isEmpty, !encrypted.isEmpty {
                guard let v = crypt?.decrypt(encrypted, host: host) else { r.locked += 1; return }
                value = v
            }
            let expires = sqlite3_column_int64(s, 8) != 0 ? chromiumDate(sqlite3_column_int64(s, 4)) : nil
            if let expires, expires < now { return }
            let sameSite: String? = [0: "none", 1: "lax", 2: "strict"][Int(sqlite3_column_int64(s, 7))]
            r.cookies.append(ImportedCookie(domain: host, name: name, value: value, path: text(s, 3), expires: expires,
                                            secure: sqlite3_column_int64(s, 5) != 0, httpOnly: sqlite3_column_int64(s, 6) != 0, sameSite: sameSite))
        }
        return r
    }

    static func chromiumHistory(_ source: ImportSource) throws -> [ImportedVisit] {
        let file = source.root.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: file.path) else { throw ImportError.missing }
        var out: [ImportedVisit] = []
        var seen = Set<String>()
        for order in ["last_visit_time DESC LIMIT \(historyLimit)", "visit_count DESC LIMIT \(frequentLimit)"] {
            try query(file, "SELECT url, title, visit_count, last_visit_time FROM urls WHERE url LIKE 'http%' AND hidden = 0 ORDER BY \(order)") { s in
                let url = text(s, 0)
                guard seen.insert(url).inserted else { return }
                out.append(ImportedVisit(url: url, title: text(s, 1), count: max(1, Int(sqlite3_column_int64(s, 2))),
                                         last: chromiumDate(sqlite3_column_int64(s, 3)) ?? .distantPast))
            }
        }
        return out
    }

    /// Chromium stores times as microseconds since 1601
    private static func chromiumDate(_ micros: Int64) -> Date? {
        micros > 0 ? Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600) : nil
    }

    // MARK: Safari (both files sit behind macOS's Full Disk Access)

    static func safariHistory(_ source: ImportSource) throws -> [ImportedVisit] {
        let file = source.root.appendingPathComponent("Safari/History.db")
        try checkReadable(file)
        var out: [ImportedVisit] = []
        try query(file, """
            SELECT history_items.url, MAX(history_visits.title), COUNT(history_visits.id), MAX(history_visits.visit_time)
            FROM history_items JOIN history_visits ON history_items.id = history_visits.history_item
            WHERE history_items.url LIKE 'http%' GROUP BY history_items.url ORDER BY 4 DESC LIMIT \(historyLimit)
            """) { s in
            out.append(ImportedVisit(url: text(s, 0), title: text(s, 1), count: max(1, Int(sqlite3_column_int64(s, 2))),
                                     last: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(s, 3))))
        }
        return out
    }

    static func safariCookies(_ source: ImportSource) throws -> [ImportedCookie] {
        let candidates = [source.root.appendingPathComponent("Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                          source.root.appendingPathComponent("Cookies/Cookies.binarycookies")]
        var lastError: Error = ImportError.missing
        for file in candidates {
            do {
                try checkReadable(file)
                let now = Date()
                return try parseBinaryCookies(Data(contentsOf: file)).filter { $0.expires.map { $0 > now } ?? true }
            } catch { if case ImportError.missing = lastError { lastError = error } }
        }
        throw lastError
    }

    /// Apple's Cookies.binarycookies: "cook", a big-endian page count and page sizes, then pages of
    /// little-endian cookie records (size, flags, offsets of domain / name / path / value, expiry and
    /// creation as seconds since 2001, then the NUL-terminated strings).
    static func parseBinaryCookies(_ d: Data) throws -> [ImportedCookie] {
        let b = [UInt8](d)
        func be32(_ o: Int) -> Int? { o + 4 <= b.count ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) : nil }
        func le32(_ o: Int) -> Int? { o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : nil }
        func le64f(_ o: Int) -> Double? {
            guard o + 8 <= b.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: v)
        }
        func cstr(_ o: Int, end: Int) -> String? {
            guard o >= 0, o < end, end <= b.count else { return nil }
            var e = o
            while e < end, b[e] != 0 { e += 1 }
            return String(bytes: b[o..<e], encoding: .utf8)
        }
        guard b.count >= 8, b[0] == 0x63, b[1] == 0x6F, b[2] == 0x6F, b[3] == 0x6B, let pages = be32(4), pages < 100_000 else {
            throw ImportError.unreadable("not a binarycookies file")
        }
        var sizes: [Int] = []
        for i in 0..<pages { guard let s = be32(8 + 4 * i) else { throw ImportError.unreadable("truncated") }; sizes.append(s) }
        var out: [ImportedCookie] = []
        var page = 8 + 4 * pages
        for size in sizes {
            defer { page += size }
            guard page + size <= b.count, let count = le32(page + 4), count < 1_000_000 else { continue }
            for i in 0..<count {
                guard let off = le32(page + 8 + 4 * i) else { break }
                let c = page + off
                guard let len = le32(c), len >= 56, c + len <= b.count, let flags = le32(c + 8),
                      let dO = le32(c + 16), let nO = le32(c + 20), let pO = le32(c + 24), let vO = le32(c + 28),
                      let expiry = le64f(c + 40),
                      let domain = cstr(c + dO, end: c + len), let name = cstr(c + nO, end: c + len),
                      let path = cstr(c + pO, end: c + len), let value = cstr(c + vO, end: c + len), !name.isEmpty, !domain.isEmpty else { continue }
                // Flags: 1 secure, 4 HttpOnly, 8 has a SameSite policy, which is Strict when 0x10 is set too
                // and Lax otherwise (checked against what WKHTTPCookieStore reports for Casa's own file;
                // the other bits are something else). Session cookies normally aren't written at all.
                let session = expiry <= 0
                let sameSite: String? = flags & 8 != 0 ? (flags & 0x10 != 0 ? "strict" : "lax") : nil
                out.append(ImportedCookie(domain: domain, name: name, value: value, path: path.isEmpty ? "/" : path,
                                          expires: session ? nil : Date(timeIntervalSinceReferenceDate: expiry),
                                          secure: flags & 1 != 0, httpOnly: flags & 4 != 0, sameSite: sameSite))
            }
        }
        return out
    }

    private static func checkReadable(_ file: URL) throws {
        let fd = open(file.path, O_RDONLY)
        if fd >= 0 { close(fd); return }
        throw errno == ENOENT ? ImportError.missing : (errno == EPERM || errno == EACCES ? ImportError.noAccess : ImportError.unreadable(String(cString: strerror(errno))))
    }

    // MARK: SQLite, on a snapshot so a running browser's lock doesn't matter

    private static func query(_ file: URL, _ sql: String, row: (OpaquePointer) -> Void) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("casa-import-\(UUID().uuidString)")
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw ImportError.unreadable("\(error.localizedDescription)") }
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(file.lastPathComponent)
        do { try fm.copyItem(at: file, to: copy) } catch {
            let code = (error as NSError).code
            throw code == NSFileReadNoPermissionError ? ImportError.noAccess : code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError ? ImportError.missing : ImportError.unreadable(error.localizedDescription)
        }
        for suffix in ["-wal", "-shm"] { try? fm.copyItem(at: URL(fileURLWithPath: file.path + suffix), to: URL(fileURLWithPath: copy.path + suffix)) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ImportError.unreadable("can't open \(file.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ s: OpaquePointer, _ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(s, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }
}

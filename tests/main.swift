import Foundation
// Harness for src/ImportSources.swift, run by tests/import.sh against this Mac's real Chrome profile and
// Casa's own WebKit cookie file. No Keychain access, no cookie values printed.
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   " : "  FAIL ", what); if !ok { failures += 1 } }

print("1. sources")
let sources = BrowserSources.all()
for s in sources { print("   ", s.id, "|", s.label) }
check(sources.contains { $0.id == "chrome/Default" }, "chrome/Default found")
check(sources.first?.id == "chrome/Default", "last-used profile listed first")
check(sources.contains { $0.id == "safari" }, "safari found")

print("2. chromium crypt round trip (synthetic password)")
let crypt = BrowserSources.ChromiumCrypt(password: Data("c2VjcmV0LXRlc3QtcGFzc3dvcmQ=".utf8))!
for (value, digest) in [("abc123", true), ("abc123", false), ("", true), (String(repeating: "x", count: 4000), true), ("zażółć=~;", true)] {
    let enc = crypt.encrypt(value, host: ".example.com", withHostDigest: digest)!
    check(crypt.decrypt(enc, host: ".example.com") == value, "round trip len \(value.count) digest \(digest)")
}
let wrong = BrowserSources.ChromiumCrypt(password: Data("other".utf8))!
check(wrong.decrypt(crypt.encrypt("abc123", host: "h", withHostDigest: true)!, host: "h") != "abc123", "wrong key does not yield the value")
// Known answer: PBKDF2-HMAC-SHA1("peanuts", "saltysalt", 1003, 16) is Chromium's documented Linux v10 key derivation with 1 round;
// with 1003 rounds we only check the key length and determinism here
check(crypt.key.count == 16 && crypt.key == BrowserSources.ChromiumCrypt(password: Data("c2VjcmV0LXRlc3QtcGFzc3dvcmQ=".utf8))!.key, "key is 16 bytes and deterministic")

print("3. chrome cookies without the key (counts only)")
if let chrome = sources.first(where: { $0.id == "chrome/Default" }) {
    do {
        let r = try BrowserSources.chromiumCookies(chrome, password: nil)
        print("    unencrypted:", r.cookies.count, "locked:", r.locked, "partitioned:", r.skipped)
        check(r.locked > 100, "encrypted cookies counted as locked without a key")
    } catch { check(false, "cookies read: \(error)") }
    print("4. chrome history")
    do {
        let h = try BrowserSources.chromiumHistory(chrome)
        let dates = h.map(\.last)
        print("    rows:", h.count, "newest:", dates.max()!, "oldest:", dates.min()!, "max count:", h.map(\.count).max()!)
        check(h.count > BrowserSources.historyLimit && h.count <= BrowserSources.historyLimit + BrowserSources.frequentLimit, "recent \(BrowserSources.historyLimit) plus the most visited")
        check(Set(h.map(\.url)).count == h.count, "no duplicate urls")
        check(dates.max()! > Date().addingTimeInterval(-86400 * 3) && dates.max()! < Date().addingTimeInterval(3600), "newest visit is recent (date conversion)")
        check(h.allSatisfy { $0.url.hasPrefix("http") }, "only http(s)")
    } catch { check(false, "history read: \(error)") }
}

print("5. binarycookies parser on a real file (Casa's own WebKit store)")
let own = URL(fileURLWithPath: NSHomeDirectory() + "/Library/HTTPStorages/com.alentodorov.casa.binarycookies")
do {
    let cookies = try BrowserSources.parseBinaryCookies(Data(contentsOf: own))
    let domains = Set(cookies.map(\.domain))
    let withExpiry = cookies.compactMap(\.expires)
    print("    cookies:", cookies.count, "domains:", domains.count, "secure:", cookies.filter(\.secure).count, "httpOnly:", cookies.filter(\.httpOnly).count,
          "session:", cookies.filter { $0.expires == nil }.count, "sameSite:", Dictionary(grouping: cookies, by: { $0.sameSite ?? "-" }).mapValues(\.count))
    print("    sample domains:", domains.sorted().prefix(6).joined(separator: " "))
    print("    expiry range:", withExpiry.min() as Any, "…", withExpiry.max() as Any)
    check(cookies.count > 10, "parsed cookies")
    check(domains.allSatisfy { $0.contains(".") && !$0.contains(" ") && !$0.contains("/") }, "domains look like domains")
    check(cookies.allSatisfy { $0.path.hasPrefix("/") }, "paths start with /")
    check(withExpiry.allSatisfy { $0 > Date(timeIntervalSince1970: 1_500_000_000) && $0 < Date(timeIntervalSince1970: 2_500_000_000) }, "expiries are plausible dates")
} catch { check(false, "binarycookies: \(error)") }

print("6. safari without Full Disk Access")
if let safari = sources.first(where: { $0.id == "safari" }) {
    do { _ = try BrowserSources.safariHistory(safari); print("    readable (this process has Full Disk Access)") }
    catch ImportError.noAccess { check(true, "history reports noAccess") }
    catch { check(false, "history: unexpected \(error)") }
    do { _ = try BrowserSources.safariCookies(safari); print("    cookies readable") }
    catch ImportError.noAccess { check(true, "cookies report noAccess") }
    catch { check(false, "cookies: unexpected \(error)") }
}
print(failures == 0 ? "ALL OK" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)

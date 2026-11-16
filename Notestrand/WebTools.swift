import Foundation

/// web_search (Tavily, Brave or Firecrawl with the learner's key) and web_fetch (any public page as text).
enum WebTools {
    static let maxPageChars = 15_000

    static func search(_ query: String) async throws -> String {
        let provider = Prefs.searchProviderValue
        if provider == .free { return try await duckDuckGo(query) }
        guard let key = KeyStore.getSecret(provider.secretName), !key.isEmpty else {
            throw VaultError("No web search key is set. Ask the learner to add one in Settings → Web access, or open a specific URL with web_fetch.")
        }
        var results: [(title: String, url: String, snippet: String)] = []
        switch provider {
        case .tavily:
            let json = try await post("https://api.tavily.com/search", ["query": query, "max_results": 6], bearer: key)
            results = (json["results"] as? [[String: Any]] ?? []).map { ($0["title"] as? String ?? "", $0["url"] as? String ?? "", $0["content"] as? String ?? "") }
        case .brave:
            var comps = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "6")]
            var req = URLRequest(url: comps.url!)
            req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let json = try await send(req)
            results = ((json["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? [])
                .map { ($0["title"] as? String ?? "", $0["url"] as? String ?? "", strip($0["description"] as? String ?? "")) }
        case .free:
            break
        case .firecrawl:
            let json = try await post("https://api.firecrawl.dev/v2/search", ["query": query, "limit": 6], bearer: key)
            // v2 nests web results; older responses return a flat array.
            let data = json["data"]
            let list = (data as? [String: Any])?["web"] as? [[String: Any]] ?? data as? [[String: Any]] ?? []
            results = list.map { ($0["title"] as? String ?? "", $0["url"] as? String ?? "", $0["description"] as? String ?? "") }
        }
        guard !results.isEmpty else { return "No results for \"\(query)\"." }
        return results.enumerated().map { i, r in
            "\(i + 1). \(r.title)\n   \(r.url)\n   \(String(r.snippet.prefix(400)))"
        }.joined(separator: "\n\n") + "\n\n(Search: \(provider.label). Open a result with web_fetch before relying on it.)"
    }

    /// Keyless search via DuckDuckGo's plain-HTML results page.
    /// shortcut: scrapes an unofficial page, can be rate-limited or change layout; upgrade by using a keyed provider.
    static func duckDuckGo(_ query: String) async throws -> String {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let results = parseDuckDuckGo(String(decoding: data, as: UTF8.self))
        guard (resp as? HTTPURLResponse)?.statusCode == 200, !results.isEmpty else {
            if (resp as? HTTPURLResponse)?.statusCode == 200 { return "No results for \"\(query)\"." }
            throw VaultError("Free search is unavailable right now (DuckDuckGo limited it). Don't retry; answer from what you know or ask the learner for a link.")
        }
        return results.prefix(6).enumerated().map { i, r in "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)" }
            .joined(separator: "\n\n") + "\n\n(Search: DuckDuckGo. Open a result with web_fetch before relying on it.)"
    }

    static func parseDuckDuckGo(_ html: String) -> [(title: String, url: String, snippet: String)] {
        let blocks = html.components(separatedBy: "class=\"result__a\"").dropFirst()
        return blocks.compactMap { b in
            guard let hrefR = b.range(of: #"href="([^"]+)""#, options: .regularExpression),
                  let end = b.range(of: "</a>") else { return nil }
            var href = String(b[hrefR]).dropFirst(6).dropLast().replacingOccurrences(of: "&amp;", with: "&")
            // Links go through a redirect: //duckduckgo.com/l/?uddg=<encoded target>
            if let u = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
               let target = u.queryItems?.first(where: { $0.name == "uddg" })?.value { href = target }
            guard href.hasPrefix("http"), !href.contains("duckduckgo.com/y.js") else { return nil }
            // Title runs from the end of the opening <a ...> tag to </a>, and may contain <b> tags.
            guard let open = b.firstIndex(of: ">"), open < end.lowerBound else { return nil }
            let title = strip(String(b[b.index(after: open)..<end.lowerBound]))
            var snippet = ""
            if let s = b.range(of: #"result__snippet[^>]*>([\s\S]*?)</a>"#, options: .regularExpression) {
                snippet = strip(String(b[s]).replacingOccurrences(of: #"^result__snippet[^>]*>"#, with: "", options: .regularExpression))
            }
            return (title.trimmed, href, String(snippet.trimmed.prefix(400)))
        }
    }

    static let maxDownload = 3_000_000

    static func fetch(_ address: String) async throws -> String {
        guard let url = URL(string: address.trimmed) else { throw VaultError("Only public http(s) web pages can be opened.") }
        try await checkPublic(url)
        if Prefs.searchProviderValue == .firecrawl, let key = KeyStore.getSecret(SearchProvider.firecrawl.secretName), !key.isEmpty {
            let json = try await post("https://api.firecrawl.dev/v2/scrape", ["url": url.absoluteString, "formats": ["markdown"], "onlyMainContent": true], bearer: key)
            let data = json["data"] as? [String: Any] ?? [:]
            let title = (data["metadata"] as? [String: Any])?["title"] as? String ?? ""
            return page(title: title, url: url, text: data["markdown"] as? String ?? "")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, resp) = try await URLSession.shared.bytes(for: req, delegate: RedirectGuard())
        let http = resp as? HTTPURLResponse
        guard let status = http?.statusCode, (200..<300).contains(status) else {
            throw VaultError("The page returned HTTP \(http?.statusCode ?? 0).")
        }
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        // Stop reading at the cap instead of downloading a huge file into memory.
        var data = Data()
        data.reserveCapacity(min(max(Int(resp.expectedContentLength), 0), maxDownload))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxDownload { break }
        }
        let body = String(decoding: data, as: UTF8.self)
        if type.contains("html") || type.isEmpty {
            let title = body.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive])
                .map { strip(String(body[$0])) } ?? ""
            return page(title: title, url: url, text: readable(body))
        }
        if type.hasPrefix("text/") || type.contains("json") || type.contains("xml") { return page(title: "", url: url, text: body) }
        throw VaultError("That URL isn't a web page (\(type)).")
    }

    private static func page(title: String, url: URL, text: String) -> String {
        let t = text.count > maxPageChars ? String(text.prefix(maxPageChars)) + "\n\n[truncated]" : text
        return (title.isEmpty ? "" : "# \(title.trimmed)\n") + "\(url.absoluteString)\n\n" + t
    }

    /// Main text of an HTML page: drops scripts, styles and navigation chrome, keeps paragraph breaks.
    static func readable(_ html: String) -> String {
        var s = html
        // Most sites wrap the actual content in <main> or <article>; everything else is chrome.
        for tag in ["main", "article"] {
            if let r = s.range(of: "<\(tag)\\b[\\s\\S]*</\(tag)>", options: [.regularExpression, .caseInsensitive]) {
                s = String(s[r])
                break
            }
        }
        for tag in ["script", "style", "noscript", "svg", "head", "nav", "header", "aside", "footer", "form", "iframe", "template", "button", "select"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<li\\b[^>]*>", with: "\n- ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<h([1-6])\\b[^>]*>", with: "\n\n## ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<(br|/p|/div|/h[1-6]|/li|/tr|/section|/article|/blockquote)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = strip(s)
        s = s.replacingOccurrences(of: "[ \\t\\u00a0]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^ *- *$", with: "", options: .regularExpression) // empty bullets
        s = s.replacingOccurrences(of: " *\\n[ \\n]*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmed
    }

    /// Removes tags and decodes the common entities.
    static func strip(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, c) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&ndash;", "–"), ("&mdash;", "—"), ("&pound;", "£")] {
            t = t.replacingOccurrences(of: e, with: c)
        }
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let r = Range(m.range, in: t), let hex = Range(m.range(at: 1), in: t), let num = Range(m.range(at: 2), in: t),
                      let v = UInt32(t[num], radix: t[hex].isEmpty ? 10 : 16), let u = Unicode.Scalar(v) else { continue }
                t.replaceSubrange(r, with: String(Character(u)))
            }
        }
        return t.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Refuses anything but http(s) to a host that is public by name and by every address it resolves to,
    /// so a page (or the model) can't reach the router, the iPad itself or other devices on the Wi-Fi.
    static func checkPublic(_ url: URL) async throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !isPrivate(host) else {
            throw VaultError("Only public http(s) web pages can be opened.")
        }
        let addresses = await Task.detached { resolve(host) }.value
        guard !addresses.isEmpty else { throw VaultError("Couldn't find \(host).") }
        if addresses.contains(where: isPrivate) { throw VaultError("Only public http(s) web pages can be opened.") }
    }

    /// The numeric addresses a host name resolves to (also normalises odd IP spellings like 0x7f.1 or 2130706433).
    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), nil, &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var out: [String] = []
        var p = list
        while let a = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            p = a.pointee.ai_next
        }
        return out
    }

    /// Hosts and addresses on the device or local network are off limits.
    static func isPrivate(_ host: String) -> Bool {
        var h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) } // fe80::1%en0
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".home.arpa") { return true }
        if h.contains(":") {
            if h == "::" || h == "::1" { return true }
            if let v4 = h.split(separator: ":").last, v4.contains(".") { return isPrivate(String(v4)) } // ::ffff:10.0.0.1
            return h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb") // link-local
                || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("ff") // unique local, multicast
        }
        let p = h.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard p.count == 4, let a = p[0], let b = p[1], p.allSatisfy({ $0 != nil }) else { return false }
        return a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 198 && (18...19).contains(b))
    }

    /// Re-checks every redirect, so a public page can't bounce the request onto the local network.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            Task {
                guard let url = request.url, (try? await WebTools.checkPublic(url)) != nil else { return completionHandler(nil) }
                completionHandler(request)
            }
        }
    }

    private static func post(_ url: String, _ body: [String: Any], bearer: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw VaultError("Search provider returned HTTP \(status): \(LLMClient.errorMessage(data).prefix(200))")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

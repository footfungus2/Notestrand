import Foundation

/// The learner's Obsidian vault, picked once as a folder and kept as a security-scoped bookmark.
final class Vault {
    static let shared = Vault()
    static let appFolder = "Notestrand"
    private let bookmarkKey = "vaultBookmark"
    private(set) var root: URL?

    init(root: URL? = nil) {
        self.root = root
        if root == nil { restore() }
    }

    var name: String? { root?.lastPathComponent }

    func setFolder(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw VaultError("Couldn't open that folder.") }
        root?.stopAccessingSecurityScopedResource()
        UserDefaults.standard.set(try url.bookmarkData(), forKey: bookmarkKey)
        root = url
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
        root = url
    }

    private func requireRoot() throws -> URL {
        guard let root else { throw VaultError("No Obsidian vault folder chosen yet. Ask the learner to pick one in Settings.") }
        return root
    }

    // MARK: reading

    /// All markdown notes as vault-relative paths, plus the count of iCloud placeholders not yet downloaded.
    func notes() throws -> (paths: [String], pending: Int) {
        let root = try requireRoot()
        var paths: [String] = [], pending = 0
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        while let url = e?.nextObject() as? URL {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".md.icloud") {
                pending += 1
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            // Same limits as readNote, so a search can't show lines readNote would refuse: no hidden folders
            // (.obsidian holds plugin settings, which can include keys) and no links pointing out of the vault.
            if name.hasPrefix(".") { e?.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { e?.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "md" {
                paths.append(relative(url, to: root))
            }
            if paths.count > 20000 { break }
        }
        return (paths.sorted(), pending)
    }

    func search(_ query: String) throws -> String {
        let root = try requireRoot()
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return "Empty query." }
        let (paths, pending) = try notes()
        var hits: [(score: Int, path: String, lines: [String])] = []
        for p in paths {
            guard let text = try? read(root.appendingPathComponent(p), limit: 200_000) else { continue }
            let lower = text.lowercased(), title = p.lowercased()
            let score = words.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) + (title.contains($1) ? 2 : 0) }
            guard score > 0 else { continue }
            let lines = text.split(separator: "\n").lazy.filter { l in let low = l.lowercased(); return words.contains { low.contains($0) } }
                .prefix(3).map { String($0.prefix(240)) }
            hits.append((score, p, Array(lines)))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        var out = hits.prefix(10).map { h in "## \(h.path)\n" + h.lines.map { "  " + $0 }.joined(separator: "\n") }.joined(separator: "\n\n")
        if out.isEmpty { out = "No notes match \"\(query)\"." }
        if pending > 0 { out += "\n\n(\(pending) notes are still downloading from iCloud and were not searched.)" }
        return out
    }

    func readNote(_ path: String) throws -> String {
        let root = try requireRoot()
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard isInside(url, root), isInside(url.resolvingSymlinksInPath(), root.resolvingSymlinksInPath()) else {
            throw VaultError("Path is outside the vault.")
        }
        // Notes only: hidden folders like .obsidian hold plugin settings, which can include other services' keys.
        guard url.pathExtension.lowercased() == "md",
              !relative(url, to: root).split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw VaultError("Only .md notes can be read.")
        }
        let stub = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: stub.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw VaultError("\(path) is still downloading from iCloud. Try again in a moment.")
        }
        let text = try read(url, limit: 40_000)
        return text.count >= 40_000 ? text + "\n\n[truncated]" : text
    }

    // MARK: writing (only inside Notestrand/)

    /// Resolves a path relative to the app folder, refusing anything that escapes it.
    func appURL(_ path: String) throws -> URL {
        let base = try requireRoot().appendingPathComponent(Vault.appFolder, isDirectory: true)
        guard path.lowercased().hasSuffix(".md") else { throw VaultError("Only .md notes can be written.") }
        guard !path.hasPrefix("/") else { throw VaultError("Use a path relative to Notestrand/.") }
        let url = base.appendingPathComponent(path).standardizedFileURL
        guard isInside(url, base) else { throw VaultError("Writes are limited to the Notestrand/ folder.") }
        // Reject a symlink anywhere on the way out of the folder.
        let resolvedBase = base.resolvingSymlinksInPath()
        guard isInside(url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent), resolvedBase)
        else { throw VaultError("Writes are limited to the Notestrand/ folder.") }
        return url
    }

    /// Notes written by the app must stay plain text in Obsidian. Some plugins run code found in a note as soon as
    /// it's opened (Dataview's `dataviewjs` blocks and `$=` inline queries, JS Engine), and a web page could talk the
    /// model into saving one. Those are saved as ordinary code instead.
    /// Fences match anywhere, not just at a line start: a fence inside a list item or callout runs too.
    /// `$=` becomes `$ =`: a space after the backtick isn't enough, since Markdown trims one from each end of `code`.
    static func inert(_ content: String) -> String {
        content
            .replacingOccurrences(of: #"(?i)((?:`{3,}|~{3,})[ \t]*)(?:dataviewjs|js-engine|meta-bind-js-view)\b"#, with: "$1js", options: .regularExpression)
            .replacingOccurrences(of: #"(`+\s*)\$="#, with: #"$1\$ ="#, options: .regularExpression)
    }

    func write(_ path: String, content: String, append: Bool) throws {
        // Every vault write comes through here, so this one check covers the AI, knowledge notes, exports and Memory.
        guard Prefs.vaultAccessValue == .readWrite else {
            throw VaultError("The vault is read-only. The learner can allow writing in Settings → Obsidian vault.")
        }
        let url = try appURL(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var err: NSError?, failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &err) { u in
            do {
                var text = Vault.inert(content)
                if append, let old = try? String(contentsOf: u, encoding: .utf8), !old.isEmpty {
                    text = old + (old.hasSuffix("\n") ? "" : "\n") + text
                }
                try text.write(to: u, atomically: true, encoding: .utf8)
            } catch { failure = error }
        }
        if let e = err ?? failure { throw e }
    }

    func appNote(_ path: String) -> String? {
        guard let url = try? appURL(path) else { return nil }
        return try? read(url, limit: 40_000)
    }

    func appFolderNotes(_ folder: String) -> [String] {
        guard let root else { return [] }
        let dir = root.appendingPathComponent(Vault.appFolder).appendingPathComponent(folder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.map { String($0.dropLast(3)) }.sorted()
    }

    // MARK: helpers

    private func read(_ url: URL, limit: Int) throws -> String {
        var err: NSError?, result: Result<String, Error> = .success("")
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            result = Result {
                let h = try FileHandle(forReadingFrom: u)
                defer { try? h.close() }
                let data = h.readData(ofLength: limit)
                return String(decoding: data, as: UTF8.self)
            }
        }
        if let err { throw err }
        return try result.get()
    }

    private func relative(_ url: URL, to root: URL) -> String {
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : url.lastPathComponent
    }

    private func isInside(_ url: URL, _ base: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path + "/")
    }
}

struct VaultError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Taught propositions saved as Obsidian notes: Notestrand/Knowledge and Notestrand/Sessions.
enum Knowledge {
    struct Proposition: Decodable {
        var name: String
        var statement: String
        var premises: [String]?
    }

    static let extractionPrompt = """
    You extract what a tutoring session taught into a knowledge graph. Read the transcript and return ONLY a JSON object, no prose, no code fence:
    {"title": "<short session title>", "goal": "<the learner's goal in one sentence>", "propositions": [{"name": "<short unique name, 2-6 words>", "statement": "<the claim, one or two sentences, markdown + LaTeX allowed>", "premises": ["<names of other propositions in this list it follows from>"]}]}
    Include only claims the learner actually came to understand (they answered checks on them, or explicitly accepted them). Order from foundations to the goal. 3 to 20 propositions.
    """

    static func fileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Untitled" : cleaned).prefix(80))
    }

    /// Parses the model's JSON reply, tolerating a code fence or leading prose.
    static func parse(_ reply: String) -> (title: String, goal: String, props: [Proposition])? {
        guard let s = reply.firstIndex(of: "{"), let e = reply.lastIndex(of: "}") else { return nil }
        struct R: Decodable { var title: String?; var goal: String?; var propositions: [Proposition] }
        guard let r = try? JSONDecoder().decode(R.self, from: Data(reply[s...e].utf8)), !r.propositions.isEmpty else { return nil }
        return (r.title ?? "Session", r.goal ?? "", r.propositions)
    }

    /// Writes one note per proposition and one session note linking them. Returns the session note name.
    static func save(title: String, goal: String, props: [Proposition], date: Date, vault: Vault) throws -> String {
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        let session = fileName("\(day) \(title)")
        var list: [String] = []
        for p in props {
            let name = fileName(p.name)
            let path = "Knowledge/\(name).md"
            let premises = (p.premises ?? []).map { "[[\(fileName($0))]]" }
            if vault.appNote(path) != nil {
                try vault.write(path, content: "\nAlso taught in [[\(session)]].", append: true)
            } else {
                var body = "---\ntype: proposition\nsession: \"[[\(session)]]\"\n---\n\n\(p.statement)\n"
                if !premises.isEmpty { body += "\nFollows from: \(premises.joined(separator: ", "))\n" }
                try vault.write(path, content: body, append: false)
            }
            list.append("- [[\(name)]]: \(p.statement.replacingOccurrences(of: "\n", with: " "))")
        }
        let note = "---\ntype: notestrand-session\ndate: \(day)\n---\n\n# \(title)\n\n**Goal:** \(goal)\n\n## Propositions\n\n" + list.joined(separator: "\n") + "\n"
        try vault.write("Sessions/\(session).md", content: note, append: false)
        return session
    }

    static func listSessions(vault: Vault) -> String {
        let names = vault.appFolderNotes("Sessions")
        guard !names.isEmpty else { return "No sessions in the knowledge map yet." }
        return names.map { n in
            let goal = vault.appNote("Sessions/\(n).md")?.components(separatedBy: "\n").first { $0.hasPrefix("**Goal:**") } ?? ""
            return "- \(n)  \(goal.replacingOccurrences(of: "**Goal:**", with: "goal:"))"
        }.joined(separator: "\n")
    }

    static func listPropositions(session: String, vault: Vault) -> String? {
        guard let note = vault.appNote("Sessions/\(fileName(session)).md") else { return nil }
        let names = note.components(separatedBy: "\n").compactMap { line -> String? in
            guard line.hasPrefix("- [["), let end = line.range(of: "]]") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 4)..<end.lowerBound])
        }
        return names.map { n in
            let body = vault.appNote("Knowledge/\(n).md") ?? ""
            let text = body.components(separatedBy: "---").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? body
            return "[\(n)] \(text)"
        }.joined(separator: "\n\n")
    }
}

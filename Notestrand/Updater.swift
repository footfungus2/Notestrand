import SwiftUI

/// Checks GitHub Releases for a newer build and hands it to the installer Notestrand came from,
/// so updating never needs a trip to GitHub.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "footfungus2/Notestrand"

    struct Release: Equatable {
        var version: String
        var page: URL
        var ipa: URL?
        var tipa: URL?
    }

    enum Installer { case trollStore, sideStore, other }

    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var downloading = false
    @Published var message: String?
    private var lastCheck: Date?

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static var installer: Installer {
        // TrollStore marks the apps it installs with a file next to the .app; AltStore and SideStore add ALTDeviceID to Info.plist.
        let container = Bundle.main.bundleURL.deletingLastPathComponent()
        if ["_TrollStore", "_TrollStoreLite"].contains(where: { FileManager.default.fileExists(atPath: container.appendingPathComponent($0).path) }) {
            return .trollStore
        }
        if Bundle.main.object(forInfoDictionaryKey: "ALTDeviceID") != nil { return .sideStore }
        return .other
    }

    /// Automatic checks run at most hourly and only while the setting is on; a manual check always runs and reports back.
    func check(manual: Bool = false) async {
        if !manual {
            guard Prefs.d.object(forKey: Prefs.checkUpdates) as? Bool ?? true else { return }
            if let last = lastCheck, Date().timeIntervalSince(last) < 3600 { return }
        }
        guard !checking else { return }
        checking = true
        lastCheck = Date()
        defer { checking = false }
        do {
            let latest = try await Self.latest()
            available = Self.isNewer(latest.version, than: Self.current) ? latest : nil
            if manual { message = available == nil ? "You're on the latest version (\(Self.current))." : nil }
        } catch {
            if manual { message = "Couldn't check for updates: \(error.localizedDescription)" }
        }
    }

    func install(_ r: Release) {
        message = nil
        let target: URL?
        switch Self.installer {
        case .trollStore: target = (r.tipa ?? r.ipa).map { appLink("apple-magnifier://install", carrying: $0) }
        case .sideStore: target = r.ipa.map { appLink("sidestore://install", carrying: $0) }
        case .other: target = nil
        }
        guard let target else { Task { await handOver(r) }; return }
        UIApplication.shared.open(target) { [weak self] opened in
            // TrollStore ships with its URL scheme turned off, so the file is handed over instead.
            if !opened { Task { await self?.handOver(r) } }
        }
    }

    /// Downloads the build and offers it in the share sheet, where TrollStore or SideStore installs it.
    func handOver(_ r: Release) async {
        // TrollStore opens .tipa files; SideStore only takes .ipa, which TrollStore can install too.
        guard let file = Self.installer == .trollStore ? (r.tipa ?? r.ipa) : (r.ipa ?? r.tipa) else {
            message = "This release has no app file to install."
            return
        }
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        do {
            let (temp, resp) = try await URLSession.shared.download(from: file)
            if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 { throw VaultError("GitHub answered with error \(code).") }
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("Notestrand-\(r.version).\(file.pathExtension)")
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: temp, to: local)
            message = Self.installer == .trollStore
                ? "Choose TrollStore to install. To skip this step next time, turn on URL Scheme Enabled in TrollStore's settings."
                : "Choose TrollStore or SideStore to install."
            Self.share(local)
        } catch {
            message = "Couldn't download the update: \(error.localizedDescription)"
        }
    }

    /// Presented from UIKit so it works from Home or over Settings alike.
    private static func share(_ file: URL) {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var top = window?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        // On iPad the share sheet is a popover and must be anchored, or presenting it crashes.
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        top.present(sheet, animated: true)
    }

    static func latest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode {
        case 200: return try parse(data)
        case 404: throw VaultError("No release has been published yet.")
        case let code: throw VaultError("GitHub answered with error \(code.map(String.init) ?? "unknown").")
        }
    }

    static func parse(_ data: Data) throws -> Release {
        guard let o = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = o["tag_name"] as? String,
              let page = (o["html_url"] as? String).flatMap(URL.init(string:)),
              page.absoluteString.hasPrefix("https://github.com/\(repo)/") else { throw VaultError("GitHub's reply couldn't be read.") }
        // Only this repository's own release files are ever handed to an installer.
        let prefix = "https://github.com/\(repo)/releases/download/"
        let files = (o["assets"] as? [[String: Any]] ?? [])
            .compactMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            .filter { $0.absoluteString.hasPrefix(prefix) }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page,
                       ipa: files.first { $0.pathExtension == "ipa" }, tipa: files.first { $0.pathExtension == "tipa" })
    }

    /// "0.10.0" is newer than "0.9.1": compares numbers part by part, so missing parts count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

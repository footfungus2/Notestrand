import UIKit

/// Hands photos and links from the share extension to the app. Compiled into both targets.
/// Uses the App Group folder when it exists; otherwise the clipboard, tagged so the app knows the item is a share.
enum ShareInbox {
    static let group = "group.dev.notestrand.ipad"
    static let scheme = "notestrand"
    private static let pasteboardType = "dev.notestrand.shared"

    struct Item: Codable {
        var images: [Data] = []
        /// Shared links and text, one per line.
        var text = ""
        var isEmpty: Bool { images.isEmpty && text.isEmpty }
    }

    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("Inbox", isDirectory: true)
    }

    static func put(_ item: Item) throws {
        let data = try JSONEncoder().encode(item)
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(UUID().uuidString).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            // Never synced to the learner's other devices, and gone after 10 minutes if the app doesn't pick it up.
            UIPasteboard.general.setItems([[pasteboardType: data]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        }
    }

    /// Everything shared since last time, oldest first, removed from the inbox as it's read.
    static func takeAll() -> [Item] {
        var items: [Item] = []
        if let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) {
            let sorted = files.filter { $0.pathExtension == "json" }.sorted {
                ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) <
                    ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }
            for f in sorted {
                if let d = try? Data(contentsOf: f), let item = try? JSONDecoder().decode(Item.self, from: d) { items.append(item) }
                try? FileManager.default.removeItem(at: f)
            }
        }
        // Only our own tagged item is read, so an ordinary copied photo or link is never taken.
        if UIPasteboard.general.contains(pasteboardTypes: [pasteboardType]),
           let d = UIPasteboard.general.data(forPasteboardType: pasteboardType),
           let item = try? JSONDecoder().decode(Item.self, from: d) {
            items.append(item)
            UIPasteboard.general.items = []
        }
        return items
    }

    /// JPEG, longest side at most 1568px: what vision models read at full detail without wasting tokens.
    static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1568 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

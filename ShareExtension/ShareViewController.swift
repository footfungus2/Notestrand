import UIKit
import UniformTypeIdentifiers

/// "Share → Notestrand": collects photos and links, drops them in the share inbox, and opens the app,
/// which adds them to the chat the learner was last in.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        card.layer.cornerRadius = 20
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        label.text = "Adding to Notestrand…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.numberOfLines = 0
        label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 280),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -20),
        ])
        Task { await collectAndHandOff() }
    }

    private func collectAndHandOff() async {
        var item = ShareInbox.Item()
        var lines: [String] = []
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier), item.images.count < 4,
               let data = await loadImage(p) {
                item.images.append(data)
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                lines.append(url.absoluteString)
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                lines.append(text)
            }
        }
        item.text = lines.joined(separator: "\n")
        guard !item.isEmpty else { return finish("Nothing Notestrand can use was shared.") }
        do { try ShareInbox.put(item) } catch { return finish("Couldn't add it: \(error.localizedDescription)") }
        if openApp() {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            finish("Added. Open Notestrand to send it.")
        }
    }

    /// Photos arrive as a file URL, raw data or a UIImage depending on the app sharing them.
    private func loadImage(_ p: NSItemProvider) async -> Data? {
        guard let value = try? await p.loadItem(forTypeIdentifier: UTType.image.identifier) else { return nil }
        let image: UIImage?
        switch value {
        case let url as URL: image = (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
        case let data as Data: image = UIImage(data: data)
        case let img as UIImage: image = img
        default: image = nil
        }
        return image.flatMap(ShareInbox.jpeg)
    }

    /// shortcut: extensions can't call UIApplication.shared, so this walks the responder chain to the app and
    /// sends openURL:. Works on iOS 15–17; iOS 18 removed that selector, where the fallback message shows instead.
    private func openApp() -> Bool {
        guard let url = URL(string: "\(ShareInbox.scheme)://shared") else { return false }
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: selector), r !== self {
                r.perform(selector, with: url)
                return true
            }
            responder = r.next
        }
        return false
    }

    private func finish(_ message: String) {
        label.text = message
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

import PDFKit
import PencilKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Photos and documents the learner attaches to a message, before it's sent.
struct PendingAttachments {
    var images: [Data] = []
    var documents: [Attachment] = []
    var isEmpty: Bool { images.isEmpty && documents.isEmpty }

    static let maxDocumentChars = 60_000
    static let maxTextBytes = 5_000_000

    static func jpeg(_ image: UIImage) -> Data? { ShareInbox.jpeg(image) }

    /// Text of a PDF or plain-text file, truncated to keep the conversation within context.
    static func document(at url: URL) throws -> Attachment {
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw VaultError("Couldn't open that PDF.") }
            text = pdf.string ?? ""
            if text.trimmed.isEmpty { throw VaultError("That PDF has no selectable text (it may be scanned). Attach a photo of the page instead.") }
        } else {
            // A text file is read into memory whole, so a huge one would end the app before it could be truncated.
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxTextBytes {
                throw VaultError("That file is too large to attach (over \(maxTextBytes / 1_000_000) MB).")
            }
            text = try String(contentsOf: url, encoding: .utf8)
        }
        let cut = text.count > maxDocumentChars ? String(text.prefix(maxDocumentChars)) + "\n\n[truncated]" : text
        return Attachment(name: url.lastPathComponent, text: cut)
    }
}

struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: ([Data]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 4
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([Data]) -> Void
        init(_ f: @escaping ([Data]) -> Void) { onPick = f }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let group = DispatchGroup()
            var out = [Data?](repeating: nil, count: results.count)
            for (i, r) in results.enumerated() where r.itemProvider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                    // Callbacks arrive on several threads at once; only touch `out` on main, or the array can be corrupted.
                    let data = (obj as? UIImage).flatMap(PendingAttachments.jpeg)
                    DispatchQueue.main.async { out[i] = data; group.leave() }
                }
            }
            group.notify(queue: .main) { [onPick] in onPick(out.compactMap { $0 }) }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (Data) -> Void
    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (Data) -> Void
        init(_ f: @escaping (Data) -> Void) { onPick = f }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            if let img = info[.originalImage] as? UIImage, let d = PendingAttachments.jpeg(img) { onPick(d) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}

/// A blank page to draw working on (Pencil or finger), attached to the message as a photo.
struct DrawingPad: View {
    let onAttach: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    @State private var isEmpty = true

    var body: some View {
        NavigationView {
            Canvas(canvas: canvas, isEmpty: $isEmpty)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle("Draw your working")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        Button("Clear") { canvas.drawing = PKDrawing() }.disabled(isEmpty)
                        Button("Attach") {
                            if let data = Self.render(canvas).flatMap(PendingAttachments.jpeg) { onAttach(data) }
                            dismiss()
                        }
                        .disabled(isEmpty)
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    /// Dark ink on white whatever the appearance, cropped to the strokes, so the model reads it like paper.
    static func render(_ canvas: PKCanvasView) -> UIImage? {
        let drawing = canvas.drawing
        guard !drawing.strokes.isEmpty else { return nil }
        let area = drawing.bounds.insetBy(dx: -24, dy: -24)
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { ink = drawing.image(from: area, scale: 2) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: area.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: area.size))
            ink.draw(at: .zero)
        }
    }

    private struct Canvas: UIViewRepresentable {
        let canvas: PKCanvasView
        @Binding var isEmpty: Bool

        func makeUIView(context: Context) -> PKCanvasView {
            canvas.drawingPolicy = .anyInput // a finger works too, for iPads without a Pencil
            canvas.overrideUserInterfaceStyle = .light
            canvas.backgroundColor = .white
            canvas.alwaysBounceVertical = true
            canvas.delegate = context.coordinator
            context.coordinator.picker.setVisible(true, forFirstResponder: canvas)
            context.coordinator.picker.addObserver(canvas)
            DispatchQueue.main.async { canvas.becomeFirstResponder() } // the tool picker shows only once it's on screen
            return canvas
        }

        func updateUIView(_ view: PKCanvasView, context: Context) {}
        func makeCoordinator() -> Coordinator { Coordinator(isEmpty: $isEmpty) }

        final class Coordinator: NSObject, PKCanvasViewDelegate {
            let picker = PKToolPicker()
            @Binding var isEmpty: Bool
            init(isEmpty: Binding<Bool>) { _isEmpty = isEmpty }
            func canvasViewDrawingDidChange(_ canvas: PKCanvasView) { isEmpty = canvas.drawing.strokes.isEmpty }
        }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (Result<Attachment, Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .plainText, .text, UTType(filenameExtension: "md") ?? .text], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (Result<Attachment, Error>) -> Void
        init(_ f: @escaping (Result<Attachment, Error>) -> Void) { onPick = f }

        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(Result { try PendingAttachments.document(at: url) })
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

enum Export {
    /// The conversation as a readable note: typed messages and replies, without tool traffic.
    static func markdown(_ s: Session) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var out = "# \(s.title)\n\n*\(s.kind.label) · \(s.model.label) · \(df.string(from: s.created))*\n"
        for m in s.messages {
            if m.role == .user && m.toolName == nil {
                let docs = (m.documents ?? []).map { "📄 \($0.name)" } + ((m.images?.isEmpty ?? true) ? [] : ["🖼 \(m.images!.count) photo(s)"])
                out += "\n## You\n\n" + ([m.text] + docs).filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
            } else if m.role == .assistant && !m.text.isEmpty {
                out += "\n## Notestrand\n\n\(m.text)\n"
            }
        }
        return out
    }

    /// A temporary file to hand to the share sheet.
    static func file(_ name: String, _ ext: String, _ data: Data) throws -> URL {
        let safe = name.replacingOccurrences(of: "[/\\\\:?*\"<>|]", with: "-", options: .regularExpression).prefix(80)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }
}

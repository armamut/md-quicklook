import AppKit
import QuickLookThumbnailing

/// Finder icons and Cover Flow-style previews: the top of the document as a
/// miniature page, drawn by the same native renderer as the preview (always
/// in the light, paper-like theme).
@objc(MDQLThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    /// The page is laid out at this size (points) and scaled to the icon.
    private static let page = NSSize(width: 720, height: 932)
    /// Only the start of the file can be visible.
    private static let maxBytes = 24 * 1024

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: request.fileURL)
            defer { try? handle.close() }
            data = Self.wholeLines(try handle.read(upToCount: Self.maxBytes) ?? Data())
        } catch {
            handler(nil, error)
            return
        }
        let base = request.fileURL.deletingLastPathComponent()
        let document = Renderer.native(markdown: data, baseDirectory: base)

        // AppKit views must be created and drawn on the main thread.
        var bitmap: NSBitmapImageRep?
        DispatchQueue.main.sync {
            bitmap = Self.renderPage(document: document, fallback: data, base: base)
        }

        let height = request.maximumSize.height
        let width = min(request.maximumSize.width, (height * Self.page.width / Self.page.height).rounded())
        let size = CGSize(width: width, height: height)
        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            guard let bitmap else { return false }
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            bitmap.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            return true
        }
        reply.extensionBadge = "MD"
        handler(reply, nil)
    }

    private static func renderPage(document: NativeDocument?, fallback: Data, base: URL) -> NSBitmapImageRep? {
        let view = NativeDocumentView(frame: NSRect(origin: .zero, size: page))
        view.appearance = NSAppearance(named: .aqua)
        if let document {
            let renderer = NativeRenderer(document: document,
                                          options: .init(baseDirectory: base, synchronousDiagramsDark: false))
            view.show(renderer.build(paragraphs: renderer.parts(firstPartCharacters: 3000)[0]), anchors: [:])
        } else {
            view.show(NSAttributedString(string: String(decoding: fallback, as: UTF8.self), attributes: [
                .font: NativeTheme.mono(size: 12), .foregroundColor: NativeTheme.fg,
            ]), anchors: [:])
        }
        let target = view.textView
        target.frame.size = page
        let rect = NSRect(origin: .zero, size: page)
        guard let rep = target.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        target.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// Drops a partial last line so Markdown is not cut mid-construct.
    private static func wholeLines(_ data: Data) -> Data {
        guard data.count == maxBytes, let newline = data.lastIndex(of: UInt8(ascii: "\n")) else { return data }
        return data.prefix(upTo: newline)
    }
}

import AppKit
import QuickLookUI

/// The Quick Look preview: Finder's space-bar panel, the preview pane and the
/// column view all show this view controller.
///
/// Markdown is rendered natively — Rust parses it into a compact layout,
/// TextKit draws it — so there is no web engine to start. The WebKit renderer
/// remains available through the `UseWebRenderer` setting.
@objc(MDQLPreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    /// Files larger than this are shown as plain text.
    private static let maxRenderSize = 64 * 1024 * 1024

    private var web: WebPreviewController?
    private var documentView: NativeDocumentView?

    override func loadView() {
        if Settings.useWebRenderer {
            let web = WebPreviewController()
            addChild(web)
            self.web = web
            view = web.view
        } else {
            let documentView = NativeDocumentView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            self.documentView = documentView
            view = documentView
        }
        preferredContentSize = NSSize(width: 1000, height: 1200)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        if let web {
            web.preparePreviewOfFile(at: url, completionHandler: handler)
            return
        }
        let start = DispatchTime.now()
        // Some hosts do not pass their appearance on; follow the system then.
        if Renderer.systemTheme == MDQL_THEME_DARK, !view.effectiveAppearance.isDark {
            view.appearance = NSAppearance(named: .darkAqua)
        }
        let base = url.deletingLastPathComponent()

        DispatchQueue.global(qos: .userInitiated).async {
            let document: NativeDocument?
            let size: Int
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                size = data.count
                document = data.count <= Self.maxRenderSize
                    ? Renderer.native(markdown: data, baseDirectory: base)
                    : nil
            } catch {
                DispatchQueue.main.async { handler(error) }
                return
            }
            let parsed = start.millisecondsAgo
            DispatchQueue.main.async {
                guard let documentView = self.documentView else { return handler(nil) }
                guard let document else {
                    log.error("Could not render a \(size)-byte file; showing plain text")
                    documentView.showPlainText(url)
                    return handler(nil)
                }
                let queued = start.millisecondsAgo
                let renderer = NativeRenderer(document: document, options: .init(
                    baseDirectory: base, loadRemoteImages: Settings.loadRemoteImages))
                // Long documents: show the first screenful now, the rest when built.
                let parts = renderer.parts()
                let text = renderer.build(paragraphs: parts[0])
                let built = start.millisecondsAgo
                Self.watchRemoteImages(renderer, in: documentView)
                documentView.show(text, anchors: renderer.anchors)
                handler(nil)
                if let rest = parts.dropFirst().first {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let more = renderer.build(paragraphs: rest)
                        DispatchQueue.main.async { [weak documentView] in
                            Self.watchRemoteImages(renderer, in: documentView)
                            documentView?.append(more, anchors: renderer.anchors)
                            log.info("Rest of the document shown at \(start.millisecondsAgo, format: .fixed(precision: 1)) ms")
                        }
                    }
                }
                log.info("""
                    Preview ready in \(start.millisecondsAgo, format: .fixed(precision: 1)) ms \
                    (\(size) bytes; parsed at \(parsed, format: .fixed(precision: 1)), main thread at \
                    \(queued, format: .fixed(precision: 1)), built at \(built, format: .fixed(precision: 1)))
                    """)
            }
        }
    }
}

private extension PreviewViewController {
    static func watchRemoteImages(_ renderer: NativeRenderer, in view: NativeDocumentView?) {
        for cell in renderer.remoteCells where cell.onLoad == nil {
            cell.onLoad = { [weak view] in view?.relayout() }
        }
    }
}

extension DispatchTime {
    var millisecondsAgo: Double {
        Double(DispatchTime.now().uptimeNanoseconds - uptimeNanoseconds) / 1_000_000
    }
}

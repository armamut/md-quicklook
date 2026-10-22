import AppKit
import OSLog
import QuickLookUI
import WebKit

let log = Logger(subsystem: "io.github.armamut.mdquicklook", category: "preview")

/// The WebKit renderer, kept as an alternative to the native one (setting
/// `UseWebRenderer`): renders Markdown to HTML and shows it in a web view.
final class WebPreviewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    /// Files larger than this are shown as plain text.
    private static let maxRenderSize = 64 * 1024 * 1024

    private var webView: WKWebView!
    private var baseDirectory: URL?
    private var completion: ((Error?) -> Void)?
    /// The load showing the previewed file; events of any earlier load (such
    /// as the pool's warm-up page) are ignored.
    private var navigation: WKNavigation?
    private var requested = DispatchTime.now()

    override func loadView() {
        webView = WebViewPool.take()
        webView.navigationDelegate = self
        view = webView
        preferredContentSize = NSSize(width: 1000, height: 1200)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        requested = DispatchTime.now()
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            || Renderer.systemTheme == MDQL_THEME_DARK
        baseDirectory = url.deletingLastPathComponent()
        completion = handler

        DispatchQueue.global(qos: .userInitiated).async {
            let html: Data
            do {
                html = try Self.render(url, dark: dark)
            } catch {
                DispatchQueue.main.async { self.finish(error) }
                return
            }
            DispatchQueue.main.async {
                self.webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                self.navigation = self.webView.load(html, mimeType: "text/html", characterEncodingName: "utf-8",
                                                    baseURL: URL(string: "about:blank")!)
                // Never leave Quick Look waiting, even if WebKit stalls.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.finish(nil) }
            }
        }
    }

    private static func render(_ url: URL, dark: Bool) throws -> Data {
        let start = DispatchTime.now()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxRenderSize,
              let html = Renderer.html(markdown: data, baseDirectory: url.deletingLastPathComponent(),
                                       title: url.lastPathComponent, theme: dark ? MDQL_THEME_DARK : MDQL_THEME_LIGHT)
        else {
            log.error("Could not render a \(data.count)-byte file; showing plain text")
            return Renderer.plainTextHTML(data, dark: dark)
        }
        log.info("Rendered \(data.count) bytes in \(start.millisecondsAgo, format: .fixed(precision: 2)) ms (remote images: \(Settings.loadRemoteImages))")
        return html
    }

    /// Tells Quick Look the preview is ready — only once the page is laid out,
    /// so it never shows an empty view first.
    private func finish(_ error: Error?) {
        guard let completion else { return }
        self.completion = nil
        completion(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        log.info("Preview ready \(self.requested.millisecondsAgo, format: .fixed(precision: 1)) ms after the request")
        finish(nil)
        WebViewPool.prewarmLater()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === self.navigation { finish(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === self.navigation { finish(error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("Web content process terminated")
        finish(nil)
    }

    /// Same-page anchors scroll; other links open in their default app.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "about", url.fragment != nil {
            decisionHandler(.allow) // "#heading" links
            return
        }
        decisionHandler(.cancel)
        NSWorkspace.shared.open(resolve(url))
    }

    /// Relative links (e.g. "other.md") arrive relative to about:blank;
    /// resolve them against the previewed file's folder.
    private func resolve(_ url: URL) -> URL {
        guard url.scheme == "about", let base = baseDirectory else { return url }
        let path = String(url.absoluteString.dropFirst("about:".count))
            .components(separatedBy: "#")[0]
        return URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: base).standardizedFileURL
    }
}

/// Keeps one ready-to-use web view around. Starting WebKit's helper processes
/// and loading fonts for the first time costs far more than rendering
/// Markdown, so that happens ahead of time: when the extension launches
/// (while Quick Look is still setting it up) and after each preview.
enum WebViewPool {
    private static var spare: WKWebView?
    private static var prewarmScheduled = false

    /// Web views sharing a data store can share warm web content processes.
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    /// Exercises the fonts and styles real documents use: headings, bold and
    /// italic, monospace, emoji, tables, task lists, math.
    private static let warmUpDocument = """
        # Warm *up* **bold** ***both***
        ## Heading
        Text with `code`, <kbd>key</kbd>, ==mark==, ~~deleted~~, [link](#a) and 😀.
        > [!TIP]
        > Quote
        - [x] Task
        1. Item

        | a | b |
        |---|--:|
        | 1 | 2 |

        ```rust
        fn main() {}
        ```
        $\\int x^2 \\, dx$
        """

    /// Creates the spare web view now (it must happen on the main thread) and
    /// loads the warm-up page once rendered in the background — unless a
    /// preview has claimed the web view by then.
    static func prewarm() {
        guard spare == nil else { return }
        let webView = make()
        spare = webView
        let theme = Renderer.systemTheme
        DispatchQueue.global(qos: .userInitiated).async {
            let html = Renderer.html(markdown: Data(warmUpDocument.utf8), baseDirectory: nil, title: nil, theme: theme)
            DispatchQueue.main.async {
                guard spare === webView, let html else { return }
                webView.load(html, mimeType: "text/html", characterEncodingName: "utf-8",
                             baseURL: URL(string: "about:blank")!)
            }
        }
    }

    /// Prepares the next spare once the current preview has settled.
    static func prewarmLater() {
        guard spare == nil, !prewarmScheduled else { return }
        prewarmScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            prewarmScheduled = false
            prewarm()
        }
    }

    static func take() -> WKWebView {
        let webView = spare ?? make()
        spare = nil
        return webView
    }

    private static func make() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.suppressesIncrementalRendering = true
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.autoresizingMask = [.width, .height]
        // Transparent until the page paints: no white flash in dark mode.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        return webView
    }
}

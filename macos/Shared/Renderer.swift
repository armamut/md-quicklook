import Foundation

/// Swift face of the Rust rendering core (`core/include/mdql.h`).
enum Renderer {
    /// Renders Markdown file contents into a self-contained HTML document.
    /// Returns `nil` if the core failed, so callers can fall back to plain text.
    static func html(markdown: Data, baseDirectory: URL?, title: String?, theme: mdql_theme = systemTheme) -> Data? {
        var length = 0
        let flags: UInt32 = Settings.loadRemoteImages ? MDQL_FLAG_REMOTE_IMAGES : 0
        let buffer: UnsafeMutablePointer<UInt8>? = markdown.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return withOptionalCString(baseDirectory?.path) { base in
                withOptionalCString(title) { title in
                    mdql_render_html(bytes.baseAddress, bytes.count, base, title, theme.rawValue, flags, &length)
                }
            }
        }
        guard let buffer else { return nil }
        return Data(bytesNoCopy: buffer, count: length, deallocator: .custom { ptr, len in
            mdql_free(ptr.assumingMemoryBound(to: UInt8.self), len)
        })
    }

    /// Last-resort page for files the core could not render.
    static func plainTextHTML(_ data: Data, dark: Bool) -> Data {
        let text = String(decoding: data.prefix(4 * 1024 * 1024), as: UTF8.self)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let colors = dark ? "background:#1e1e1e;color:#f0f6fc" : "background:#fff;color:#1f2328"
        return Data(("<!DOCTYPE html><meta charset=utf-8><body style=\"margin:0;\(colors)\">" +
            "<pre style=\"font:12px ui-monospace,Menlo,monospace;padding:16px;white-space:pre-wrap\">" +
            text + "</pre>").utf8)
    }

    /// The system-wide appearance, from the global preferences. Some Quick
    /// Look hosts do not pass their appearance on to the extension's views.
    static var systemTheme: mdql_theme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? MDQL_THEME_DARK : MDQL_THEME_LIGHT
    }

    /// Compiles the grammars of common languages on all cores, in the
    /// background, so code blocks render without any first-use cost.
    static func warmUpInBackground() {
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: mdql_warm_up_count()) { mdql_warm_up_language($0) }
        }
    }

    private static func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let s else { return body(nil) }
        return s.withCString(body)
    }
}

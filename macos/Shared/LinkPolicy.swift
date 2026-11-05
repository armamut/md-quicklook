import AppKit
import OSLog

private let linkLog = Logger(subsystem: "io.github.armamut.mdquicklook", category: "links")

/// What a click on a link in a previewed document may do. Documents come from
/// anywhere and link text can hide its target, while macOS starts what it is
/// asked to open. The preview extension's sandbox allows opening anything (its
/// `lsopen` exception), so this is the only check: the web and mail open, and
/// nothing else does, local files included.
enum LinkPolicy {
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func allows(_ url: URL) -> Bool {
        allowedSchemes.contains(url.scheme?.lowercased() ?? "")
    }

    static func follow(_ url: URL) {
        guard allows(url) else { return }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { linkLog.error("Could not open a link: \(error, privacy: .public)") }
        }
    }
}

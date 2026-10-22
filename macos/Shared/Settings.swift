import Foundation

/// User settings. The sandboxed preview extension reads them from its own
/// container's preferences; the host app (not sandboxed) writes them there.
enum Settings {
    static let previewExtensionID = "io.github.armamut.mdquicklook.preview"
    private static let remoteImagesKey = "LoadRemoteImages"

    /// Load http(s) images such as README badges. Off by default for privacy.
    static var loadRemoteImages: Bool {
        UserDefaults.standard.bool(forKey: remoteImagesKey)
    }

    /// The preview extension's preferences, as a path-based domain. Nil until
    /// the extension has run once and macOS has created its container.
    static var previewDomain: CFString? {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(previewExtensionID)/Data/Library/Preferences")
        guard FileManager.default.fileExists(atPath: container.path) else { return nil }
        return container.appendingPathComponent(previewExtensionID).path as CFString
    }

    static func previewLoadsRemoteImages() -> Bool {
        guard let domain = previewDomain else { return false }
        return CFPreferencesCopyAppValue(remoteImagesKey as CFString, domain) as? Bool ?? false
    }

    @discardableResult
    static func setPreviewLoadsRemoteImages(_ enabled: Bool) -> Bool {
        guard let domain = previewDomain else { return false }
        CFPreferencesSetAppValue(remoteImagesKey as CFString, enabled as CFBoolean, domain)
        return CFPreferencesAppSynchronize(domain)
    }
}

import AppKit

/// Checks GitHub for a newer release and installs it in place: downloads the
/// release zip, verifies the app inside, swaps it for the running bundle and
/// relaunches. Only the host app talks to the network; the Quick Look
/// extensions never do.
final class Updater {
    struct Release {
        let version: String
        let notes: String
        let page: URL
        let download: URL
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    static let repository = "armamut/md-quicklook"
    /// Downloads must come from this repository's releases.
    private static let downloadPrefix = "https://github.com/\(repository)/releases/download/"

    private let defaults = UserDefaults.standard
    private static let automaticKey = "CheckForUpdatesAutomatically"
    private static let lastCheckKey = "LastUpdateCheck"
    private static let skippedKey = "SkippedVersion"
    /// Overrides the release feed (for testing an update without publishing one).
    private static let feedKey = "UpdateFeedURL"

    var checksAutomatically: Bool {
        get { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticKey) }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Whether a daily automatic check is due.
    var automaticCheckDue: Bool {
        guard checksAutomatically else { return false }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        return Date().timeIntervalSince(last) > 24 * 60 * 60
    }

    func skip(_ release: Release) { defaults.set(release.version, forKey: Self.skippedKey) }

    func isSkipped(_ release: Release) -> Bool { defaults.string(forKey: Self.skippedKey) == release.version }

    // MARK: Checking

    /// Fetches the latest release; calls back on the main thread with nil
    /// when the running version is current.
    func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        let feed = defaults.string(forKey: Self.feedKey).flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MD-QuickLook/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Result { () -> Release? in
                if let error { throw error }
                guard let data, (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true else {
                    throw UpdateError.message("GitHub did not answer the update check.")
                }
                let release = try Self.parse(data)
                return Self.compare(release.version, self.currentVersion) > 0 ? release : nil
            }
            DispatchQueue.main.async {
                if case .success = result { self.defaults.set(Date(), forKey: Self.lastCheckKey) }
                completion(result)
            }
        }.resume()
    }

    private static func parse(_ data: Data) throws -> Release {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let download = assets.compactMap({ $0["browser_download_url"] as? String })
                  .first(where: { $0.hasSuffix(".zip") }).flatMap(URL.init(string:))
        else { throw UpdateError.message("The release information could not be read.") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", page: page, download: download)
    }

    /// Compares dotted versions numerically: 1.10.0 > 1.9.2.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    // MARK: Installing

    /// Downloads, verifies and installs `release` over the running app, then
    /// relaunches it. Calls back on the main thread only on failure.
    /// `progress` reports the download (0...1) on the main thread.
    func install(_ release: Release, progress: @escaping (Double) -> Void, failure: @escaping (Error) -> Void) {
        guard release.download.absoluteString.hasPrefix(Self.downloadPrefix) else {
            failure(UpdateError.message("The download is not from the MD QuickLook releases."))
            return
        }
        let task = URLSession.shared.downloadTask(with: release.download) { location, response, error in
            self.observation = nil
            do {
                if let error { throw error }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError.message("The download failed.")
                }
                let app = try self.unpack(location, expecting: release.version)
                try self.replaceRunningApp(with: app)
                DispatchQueue.main.async { self.relaunch() }
            } catch {
                DispatchQueue.main.async { failure(error) }
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { value, _ in
            DispatchQueue.main.async { progress(value.fractionCompleted) }
        }
        task.resume()
    }

    private var observation: NSKeyValueObservation?

    /// Unzips the download and checks that it holds this app at the expected version.
    private func unpack(_ zip: URL, expecting version: String) throws -> URL {
        // On the app's volume, so the final swap is a rename.
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: Bundle.main.bundleURL, create: true)
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else {
            throw UpdateError.message("The download could not be unpacked.")
        }
        let app = work.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
        else { throw UpdateError.message("The download does not contain MD QuickLook \(version).") }
        guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError.message("The downloaded app is damaged (its signature does not verify).")
        }
        return app
    }

    /// Swaps the new bundle in for the running one (macOS keeps the running
    /// executable mapped, so this is safe).
    private func replaceRunningApp(with app: URL) throws {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw UpdateError.message("MD QuickLook cannot replace itself in \(current.deletingLastPathComponent().path). " +
                                      "Download the new version from the release page instead.")
        }
        _ = try FileManager.default.replaceItemAt(current, withItemAt: app)
        Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", current.path])
    }

    /// Starts the new copy once this process has quit; it registers the
    /// updated extensions and resets Quick Look on launch.
    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", path]
        try? process.run()
        // An open sheet makes AppKit ignore -terminate:; close them first,
        // and quit for sure if termination is still refused.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

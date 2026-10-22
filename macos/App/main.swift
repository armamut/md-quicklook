import AppKit
import Quartz

/// The host app. Its only jobs are to carry the Quick Look extensions,
/// register them with the system and explain what to do next.
final class AppDelegate: NSObject, NSApplicationDelegate, QLPreviewPanelDataSource {
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var remoteImagesCheckbox: NSButton!
    private var previewURL: URL?

    private let previewExtensionID = "io.github.armamut.mdquicklook.preview"
    private let thumbnailExtensionID = "io.github.armamut.mdquicklook.thumbnail"

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        registerExtensions()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        showPreview(URL(fileURLWithPath: filename))
        return true
    }

    // MARK: Registration

    private func registerExtensions() {
        let bundleURL = Bundle.main.bundleURL
        LSRegisterURL(bundleURL as CFURL, true)
        let plugins = bundleURL.appendingPathComponent("Contents/PlugIns")
        for name in ["MDQuickLookPreview.appex", "MDQuickLookThumbnail.appex"] {
            run("/usr/bin/pluginkit", ["-a", plugins.appendingPathComponent(name).path])
        }
        run("/usr/bin/pluginkit", ["-e", "use", "-i", previewExtensionID])
        run("/usr/bin/pluginkit", ["-e", "use", "-i", thumbnailExtensionID])
        resetQuickLookServices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshStatus() }
    }

    private func refreshStatus() {
        let preview = extensionState(previewExtensionID)
        let thumbnail = extensionState(thumbnailExtensionID)
        var lines = ["Preview extension: \(preview)", "Thumbnail extension: \(thumbnail)"]
        if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            lines.append("Tip: move MD QuickLook to /Applications so it keeps working.")
        }
        statusLabel.stringValue = lines.joined(separator: "\n")
        remoteImagesCheckbox.state = Settings.previewLoadsRemoteImages() ? .on : .off
    }

    /// Reads `pluginkit -m` output: "+" enabled, "-" disabled, "!" debug, "=" superseded.
    private func extensionState(_ id: String) -> String {
        let out = run("/usr/bin/pluginkit", ["-m", "-i", id])
        let flag = out.trimmingCharacters(in: .whitespaces).first
        switch flag {
        case "+", "!": return "enabled ✓"
        case "-": return "disabled — turn it on in System Settings"
        case "=": return "superseded by another copy"
        case .some: return "registered"
        case nil: return "not registered yet"
        }
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    // MARK: Actions

    @objc private func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func choosePreviewFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init("net.daringfireball.markdown") ?? .plainText, .plainText]
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { self.showPreview(url) }
        }
    }

    @objc private func toggleRemoteImages(_ sender: NSButton) {
        guard Settings.setPreviewLoadsRemoteImages(sender.state == .on) else {
            sender.state = .off
            let alert = NSAlert()
            alert.messageText = "Preview a Markdown file first"
            alert.informativeText = "macOS sets up the preview extension the first time it runs. " +
                "Press Space on any .md file in Finder, then change this setting."
            alert.beginSheetModal(for: window)
            return
        }
    }

    @objc private func resetQuickLook() {
        resetQuickLookServices()
        refreshStatus()
    }

    /// Quick Look caches which extension handles a type; restarting its
    /// helpers makes newly installed extensions take effect immediately.
    private func resetQuickLookServices() {
        run("/usr/bin/qlmanage", ["-r"])
        run("/usr/bin/qlmanage", ["-r", "cache"])
        // Match the full executable path: process names are truncated, and
        // an unanchored pattern could hit unrelated processes.
        run("/usr/bin/pkill", ["-f", "^/System/Library/Frameworks/QuickLookThumbnailing.framework/Support/com.apple.quicklook.ThumbnailsAgent"])
        run("/usr/bin/pkill", ["-f", "^/System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/"])
    }

    private func showPreview(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }

    // MARK: UI

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "MD QuickLook"
        window.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let title = NSTextField(labelWithString: "MD QuickLook \(version)")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let help = NSTextField(wrappingLabelWithString:
            "Markdown previews are now available in Finder. Select a .md file and press Space, " +
            "or turn on the preview pane (View ▸ Show Preview). You can close this app — " +
            "the extensions keep working without it.")
        help.textColor = .secondaryLabelColor
        help.alignment = .center
        help.preferredMaxLayoutWidth = 440

        statusLabel = NSTextField(wrappingLabelWithString: "Registering…")
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.alignment = .center

        remoteImagesCheckbox = NSButton(checkboxWithTitle: "Load remote images (badges, screenshots)",
                                        target: self, action: #selector(toggleRemoteImages(_:)))
        let remoteNote = NSTextField(wrappingLabelWithString:
            "Off by default: previewing a file never contacts the internet. " +
            "When off, badges are drawn locally and other images show their description.")
        remoteNote.font = .systemFont(ofSize: 11)
        remoteNote.textColor = .secondaryLabelColor
        remoteNote.alignment = .center
        remoteNote.preferredMaxLayoutWidth = 420

        let buttons = NSStackView(views: [
            NSButton(title: "Preview a File…", target: self, action: #selector(choosePreviewFile)),
            NSButton(title: "Extension Settings", target: self, action: #selector(openSettings)),
            NSButton(title: "Reset Quick Look", target: self, action: #selector(resetQuickLook)),
        ])
        buttons.spacing = 8

        let stack = NSStackView(views: [icon, title, help, statusLabel, remoteImagesCheckbox, remoteNote, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MD QuickLook",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MD QuickLook", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit MD QuickLook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Preview a File…", action: #selector(choosePreviewFile), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

import Foundation

// Entry point of the preview extension. Its code lives in the shared
// libMDQuickLookCore.dylib (in the app's Frameworks folder); the extension's
// own executable only calls this (see macos/Launchers).

/// Quick Look spends a while setting up a freshly launched extension before the
/// first request arrives. Use that time to compile syntax grammars and load the
/// math font (and, for the WebKit renderer, to start WebKit's helper processes).
@_cdecl("mdql_preview_main")
public func previewMain() -> Int32 {
    Renderer.warmUpInBackground()
    DispatchQueue.global(qos: .userInitiated).async { MathSupport.warmUp() }
    if Settings.useWebRenderer {
        DispatchQueue.main.async { WebViewPool.prewarm() }
    }
    return NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv)
}

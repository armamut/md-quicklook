import Foundation

// Quick Look spends a while setting up a freshly launched extension before the
// first request arrives. Use that time to compile syntax grammars and to start
// WebKit's helper processes.
Renderer.warmUpInBackground()
DispatchQueue.main.async { WebViewPool.prewarm() }
exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))

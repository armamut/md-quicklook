// Renders an HTML file with WebKit and saves a PNG — used to check styling and
// to produce the README screenshots.
// Usage: swift scripts/snapshot.swift in.html out.png [light|dark] [width] [height]
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: snapshot.swift in.html out.png [light|dark] [width] [height]\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let dark = args.count > 3 && args[3] == "dark"
let width = args.count > 4 ? Double(args[4]) ?? 900 : 900
let height = args.count > 5 ? Double(args[5]) ?? 1400 : 1400

final class Loader: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: width, height: height)
            webView.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    print("snapshot failed: \(String(describing: error))")
                    exit(1)
                }
                try! png.write(to: output)
                exit(0)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
let webView = WKWebView(frame: window.contentView!.bounds)
webView.appearance = window.appearance
window.contentView!.addSubview(webView)
let loader = Loader()
webView.navigationDelegate = loader
webView.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
app.run()

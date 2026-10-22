// Development tool: renders a Markdown file with the native renderer in an
// off-screen view and writes a PNG, so layout can be checked without Finder.
//   build/native-snapshot FILE.md OUT.png [light|dark] [width] [maxHeight]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: native-snapshot FILE.md OUT.png [light|dark] [width] [maxHeight]")
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let dark = args.count > 3 && args[3] == "dark"
let width = args.count > 4 ? CGFloat(Double(args[4]) ?? 900) : 900
let maxHeight = args.count > 5 ? CGFloat(Double(args[5]) ?? 4000) : 4000

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let data = try! Data(contentsOf: input)
var t = Date()
guard let doc = Renderer.native(markdown: data, baseDirectory: input.deletingLastPathComponent()) else {
    print("render failed"); exit(1)
}
let rustMs = Date().timeIntervalSince(t) * 1000
t = Date()
MathSupport.warmUp()
let mathMs = Date().timeIntervalSince(t) * 1000
t = Date()
let renderer = NativeRenderer(document: doc, options: .init(baseDirectory: input.deletingLastPathComponent(),
                                                            synchronousDiagramsDark: dark))
let parts = renderer.parts()
let firstPart = renderer.build(paragraphs: parts[0])
let firstMs = Date().timeIntervalSince(t) * 1000
let text = NSMutableAttributedString(attributedString: firstPart)
for part in parts.dropFirst() { text.append(renderer.build(paragraphs: part)) }
let buildMs = Date().timeIntervalSince(t) * 1000
print(String(format: "%d part(s); first part %.2f ms (%d characters)", parts.count, firstMs, firstPart.length))
if ProcessInfo.processInfo.environment["MDQL_DEBUG_BLOCKS"] != nil {
    text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
        let blocks = (value as? NSParagraphStyle)?.textBlocks ?? []
        let ids = blocks.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue) & 0xfffff, radix: 16) }
        let snippet = (text.string as NSString).substring(with: range).prefix(30).replacingOccurrences(of: "\n", with: "⏎")
        print("\(range.location)+\(range.length) [\(ids.joined(separator: ","))] \(snippet)")
    }
}

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.borderless],
                      backing: .buffered, defer: false)
window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
let view = NativeDocumentView(frame: window.contentView!.bounds)
view.autoresizingMask = [.width, .height]
if ProcessInfo.processInfo.environment["MDQL_NO_WINDOW"] == nil {
    window.contentView!.addSubview(view)
} else {
    view.appearance = window.appearance
}
t = Date()
view.show(text, anchors: renderer.anchors)
let layoutManager = view.textView.layoutManager!
layoutManager.ensureLayout(for: view.textView.textContainer!)
let layoutMs = Date().timeIntervalSince(t) * 1000
print(String(format: "rust %.2f ms, math font %.1f ms, attributed string %.2f ms, full layout %.2f ms",
             rustMs, mathMs, buildMs, layoutMs))

let used = layoutManager.usedRect(for: view.textView.textContainer!)
let height = min(maxHeight, used.height + view.textView.textContainerInset.height * 2)
view.textView.frame.size = NSSize(width: width, height: height)
window.setContentSize(NSSize(width: width, height: height))
view.frame.size = NSSize(width: width, height: height)
view.layoutSubtreeIfNeeded()
let target = view.textView
let rep = target.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: width, height: height))!
target.cacheDisplay(in: NSRect(x: 0, y: 0, width: width, height: height), to: rep)
try! rep.representation(using: .png, properties: [:])!.write(to: output)

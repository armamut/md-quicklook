// Development tool: how much of the math in Markdown files SwiftMath can
// typeset (after MathMacros), and which commands still fail.
//   build/math-coverage FILE.md... [--list] [--min PERCENT]
import AppKit

var files: [String] = []
var list = false
var minimum: Double?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--list": list = true
    case "--min": minimum = args.next().flatMap(Double.init)
    default: files.append(arg)
    }
}
guard !files.isEmpty else {
    print("usage: math-coverage FILE.md... [--list] [--min PERCENT]")
    exit(2)
}

// Every extra symbol must exist in the math font, or it would draw nothing.
MathSupport.warmUp()
let font: CTFont = MTFontManager.fontManager.latinModernFont(withSize: 15)!.ctFont
var missing: [String] = []
for (name, _, value) in MathMacros.symbols {
    let utf16 = Array(value.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
    if !CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) { missing.append("\\\(name) \(value)") }
}
if !missing.isEmpty { print("symbols missing from Latin Modern Math: " + missing.joined(separator: ", ")) }

var total = 0
var failures: [(String, String)] = []
for file in files {
    let url = URL(fileURLWithPath: file)
    guard let data = try? Data(contentsOf: url),
          let doc = Renderer.native(markdown: data, baseDirectory: url.deletingLastPathComponent()) else {
        print("cannot render \(file)")
        exit(1)
    }
    for run in doc.runs where run.flags & NativeDocument.RunFlag.attachment != 0
        && (run.a == NativeDocument.AttachmentKind.mathInline || run.a == NativeDocument.AttachmentKind.mathDisplay) {
        let latex = doc.strings[safe: Int(run.b)] ?? ""
        total += 1
        if MathSupport.parse(latex) == nil {
            var error: NSError?
            _ = MTMathListBuilder.build(fromString: MathMacros.expand(latex), error: &error)
            failures.append((latex, error?.localizedDescription ?? "no result"))
        }
    }
}

let ok = total - failures.count
let percent = total == 0 ? 100 : Double(ok) / Double(total) * 100
print(String(format: "%d formulas, %d typeset (%.1f%%), %d fail", total, ok, percent, failures.count))
var reasons: [String: Int] = [:]
for (_, reason) in failures { reasons[reason, default: 0] += 1 }
for (reason, count) in reasons.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }) {
    print(String(format: "%5d  %@", count, reason))
}
if list {
    print("")
    for (latex, reason) in failures { print("\(latex.replacingOccurrences(of: "\n", with: " "))\n      -> \(reason)") }
}
if let minimum, percent < minimum {
    print(String(format: "coverage %.1f%% is below %.1f%%", percent, minimum))
    exit(1)
}

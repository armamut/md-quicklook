import AppKit
import QuickLookThumbnailing

/// Finder icon thumbnails: a miniature page showing the start of the document
/// with headings, lists and code styled.
@objc(MDQLThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    /// The page is laid out at this width (points) and scaled to fit.
    private static let pageWidth: CGFloat = 600
    private static let pageAspect: CGFloat = 1.294 // A4-ish portrait
    private static let maxBytes = 16 * 1024

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let text: String
        do {
            let handle = try FileHandle(forReadingFrom: request.fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maxBytes) ?? Data()
            text = String(decoding: data, as: UTF8.self)
        } catch {
            handler(nil, error)
            return
        }

        let maxSize = request.maximumSize
        let height = maxSize.height
        let width = min(maxSize.width, (height / Self.pageAspect).rounded())
        let size = CGSize(width: width, height: height)
        let content = ThumbnailText.attributed(from: text)

        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let scale = width / Self.pageWidth
            let pageHeight = height / scale

            NSColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            let inset: CGFloat = 36
            let rect = CGRect(x: inset, y: inset, width: Self.pageWidth - inset * 2, height: pageHeight - inset * 2)
            content.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            cg.restoreGState()
            return true
        }
        reply.extensionBadge = "MD"
        handler(reply, nil)
    }
}

/// A tiny, forgiving Markdown-to-attributed-string pass for thumbnails.
enum ThumbnailText {
    private static let maxLines = 80

    static func attributed(from source: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 15)
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let ink = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.16, alpha: 1)
        let muted = NSColor(srgbRed: 0.35, green: 0.39, blue: 0.43, alpha: 1)

        func paragraph(spacing: CGFloat, before: CGFloat = 0, indent: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = spacing
            p.paragraphSpacingBefore = before
            p.headIndent = indent
            p.firstLineHeadIndent = indent
            p.lineBreakMode = .byWordWrapping
            return p
        }
        func append(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
            out.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }

        var lines = source.components(separatedBy: .newlines)[...]
        // Skip YAML front matter.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = lines[(end + 1)...]
        }

        var inCode = false
        var count = 0
        for raw in lines {
            if count >= maxLines { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            if inCode {
                append(raw.isEmpty ? " " : raw, [.font: mono, .foregroundColor: ink,
                                                .backgroundColor: NSColor(white: 0.95, alpha: 1),
                                                .paragraphStyle: paragraph(spacing: 0, indent: 8)])
                count += 1
                continue
            }
            if line.isEmpty || line.hasPrefix("<!--") { continue }

            if let level = headingLevel(line) {
                let size: CGFloat = [30, 24, 20, 17, 15, 15][level - 1]
                let text = inline(String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces))
                append(text, [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: ink,
                              .paragraphStyle: paragraph(spacing: 8, before: level <= 2 ? 6 : 2)])
            } else if line.hasPrefix(">"), line.contains("[!"), line.hasSuffix("]") {
                continue // GitHub alert marker such as "> [!NOTE]"
            } else if let item = listItem(line) {
                let depth = CGFloat(raw.prefix(while: { $0 == " " || $0 == "\t" }).count / 2)
                let bullet = item.first.map { $0.isNumber || $0 == "☐" || $0 == "☑" } == true ? "" : "•  "
                append(bullet + inline(item), [.font: body, .foregroundColor: ink,
                                               .paragraphStyle: paragraph(spacing: 3, indent: 12 + depth * 16)])
            } else if line.hasPrefix(">") {
                append(inline(String(line.drop(while: { $0 == ">" || $0 == " " }))),
                       [.font: NSFont.systemFont(ofSize: 15).withTraits(.italic), .foregroundColor: muted,
                        .paragraphStyle: paragraph(spacing: 6, indent: 14)])
            } else if line.allSatisfy({ "-*_= ".contains($0) }) {
                continue
            } else if line.hasPrefix("|") {
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                append(cells.map(inline).joined(separator: "   "),
                       [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink,
                        .paragraphStyle: paragraph(spacing: 2)])
            } else {
                append(inline(line), [.font: body, .foregroundColor: ink, .paragraphStyle: paragraph(spacing: 6)])
            }
            count += 1
        }
        return out
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    private static func listItem(_ line: String) -> String? {
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
            let prefix = marker.contains("[") ? (marker.contains(" ] ") ? "☐ " : "☑ ") : ""
            return prefix + line.dropFirst(marker.count)
        }
        if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
           line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            return String(line[..<dot]) + ". " + line[line.index(dot, offsetBy: 2)...]
        }
        return nil
    }

    /// Strips inline markup: images, links, emphasis, code spans and HTML tags.
    private static func inline(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),
            (#"<[^>]+>"#, ""),
            (#"(\*\*|__|~~|==)(.+?)\1"#, "$2"),
            (#"(?<![\w*])[*_](.+?)[*_](?![\w*])"#, "$1"),
            (#"`([^`]*)`"#, "$1"),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return t
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }
}

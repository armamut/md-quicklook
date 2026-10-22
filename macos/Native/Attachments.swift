import AppKit

// TextKit 1 attachment cells for the native renderer. Each draws itself
// (vector, appearance-aware) and sizes itself against the line it is laid
// out in, so images and rules adapt to the width of the preview.

/// Base class: TextKit asks cells for their size and baseline; subclasses
/// implement `size(forLineWidth:)` and `draw(in:)`.
class NativeCell: NSTextAttachmentCell {
    /// Distance from the bottom of the cell to the text baseline.
    var descent: CGFloat = 0
    /// For cells whose content arrives later (downloads, diagrams): called
    /// on the main thread when the cell needs layout again. Content that
    /// arrived before anyone listened is announced when this is set.
    var onLoad: (() -> Void)? {
        didSet {
            if missedLoad, let onLoad {
                missedLoad = false
                onLoad()
            }
        }
    }
    private var missedLoad = false

    /// Main thread only.
    func announceLoad() {
        if let onLoad { onLoad() } else { missedLoad = true }
    }

    func size(forLineWidth width: CGFloat) -> NSSize { .zero }
    func draw(in rect: NSRect) {}

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = max(16, lineFrag.width - textContainer.lineFragmentPadding * 2)
        let size = size(forLineWidth: available)
        return NSRect(x: 0, y: -descent, width: size.width, height: size.height)
    }

    override func cellSize() -> NSSize { size(forLineWidth: 600) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -descent) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSGraphicsContext.saveGraphicsState()
        draw(in: cellFrame)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }

    static func attachment(_ cell: NativeCell) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        return NSAttributedString(attachment: attachment)
    }
}

// MARK: - Math

/// A LaTeX formula typeset with SwiftMath.
final class MathCell: NativeCell {
    private let latex: String
    private let display: Bool
    private let fontSize: CGFloat
    private lazy var typeset: MTMathListDisplay? = MathSupport.typeset(latex, display: display, size: fontSize)
    private lazy var fallback = NSAttributedString(string: latex, attributes: [
        .font: NativeTheme.mono(size: fontSize * 0.8), .foregroundColor: NativeTheme.alerts[4],
    ])

    init(latex: String, display: Bool, fontSize: CGFloat) {
        self.latex = latex
        self.display = display
        self.fontSize = fontSize
        super.init()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func size(forLineWidth width: CGFloat) -> NSSize {
        guard let typeset else {
            // Long source wraps within the line instead of being cut off.
            let size = fallback.boundingRect(with: NSSize(width: width, height: 10_000),
                                             options: [.usesLineFragmentOrigin]).size
            descent = 3
            return NSSize(width: min(ceil(size.width), width), height: ceil(size.height))
        }
        descent = typeset.descent
        return NSSize(width: ceil(typeset.width), height: ceil(typeset.ascent + typeset.descent))
    }

    override func draw(in rect: NSRect) {
        guard let typeset, let context = NSGraphicsContext.current?.cgContext else {
            fallback.draw(with: rect, options: [.usesLineFragmentOrigin])
            return
        }
        typeset.textColor = NativeTheme.fg.resolved()
        context.saveGState()
        // The text view is flipped; SwiftMath draws in Core Text's y-up space
        // and expects an identity text matrix (TextKit leaves its own set).
        context.translateBy(x: rect.minX, y: rect.minY + typeset.ascent)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        typeset.position = .zero
        typeset.draw(context)
        context.restoreGState()
    }
}

// MARK: - Images

/// A local image, scaled down to fit the line (or to an HTML `width`).
final class ImageCell: NativeCell {
    private let url: URL
    private let requestedWidth: CGFloat
    private lazy var picture: NSImage? = NSImage(contentsOf: url)

    init(path: String, width: CGFloat) {
        url = URL(fileURLWithPath: path)
        requestedWidth = width
        super.init()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func size(forLineWidth width: CGFloat) -> NSSize {
        guard let picture, picture.size.width > 0, picture.size.height > 0 else { return NSSize(width: 1, height: 1) }
        var target = requestedWidth > 0 ? requestedWidth : picture.size.width
        target = min(target, width)
        return NSSize(width: target, height: (target * picture.size.height / picture.size.width).rounded())
    }

    override func draw(in rect: NSRect) {
        picture?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// A remote image: loaded when the setting allows it, otherwise a placeholder.
final class RemoteImageCell: NativeCell {
    private let url: URL?
    private let alt: String
    private let badgeLike: Bool
    private let requestedWidth: CGFloat
    private var picture: NSImage?

    init(url: String, alt: String, badgeLike: Bool, width: CGFloat, load: Bool) {
        self.url = URL(string: url.hasPrefix("//") ? "https:" + url : url)
        self.alt = alt
        self.badgeLike = badgeLike
        requestedWidth = width
        super.init()
        if load, let target = self.url {
            URLSession.shared.dataTask(with: target) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    self?.picture = image
                    self?.announceLoad()
                }
            }.resume()
        }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    private var host: String { url?.host ?? "" }

    private var label: NSAttributedString {
        if badgeLike {
            return NSAttributedString(string: alt.isEmpty ? "badge" : alt, attributes: BadgeCell.textAttributes)
        }
        let text = NSMutableAttributedString(string: "🖼 " + (alt.isEmpty ? "Remote image" : alt), attributes: [
            .font: NativeTheme.font(size: 12.5), .foregroundColor: NativeTheme.muted,
        ])
        text.append(NSAttributedString(string: "  " + host, attributes: [
            .font: NativeTheme.font(size: 11), .foregroundColor: NativeTheme.muted.withAlphaComponent(0.7),
        ]))
        return text
    }

    override func size(forLineWidth width: CGFloat) -> NSSize {
        if let picture, picture.size.width > 0 {
            descent = badgeLike ? 5 : 0
            let target = min(requestedWidth > 0 ? requestedWidth : picture.size.width, width)
            return NSSize(width: target, height: (target * picture.size.height / picture.size.width).rounded())
        }
        let size = label.size()
        descent = badgeLike ? 5 : 6
        return NSSize(width: min(ceil(size.width) + (badgeLike ? 12 : 16), width), height: badgeLike ? 20 : 24)
    }

    override func draw(in rect: NSRect) {
        if let picture {
            picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        if badgeLike {
            BadgeCell.drawPill(in: rect, parts: [(label, NSColor(white: 0.36, alpha: 1))])
            return
        }
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 2.5), xRadius: 6, yRadius: 6)
        box.lineWidth = 1
        box.setLineDash([3, 2], count: 2, phase: 0)
        NativeTheme.border.setStroke()
        box.stroke()
        let size = label.size()
        label.draw(at: NSPoint(x: rect.minX + 8, y: rect.midY - size.height / 2))
    }
}

/// A Mermaid diagram, laid out and drawn by the core in the background (the
/// document does not wait for it) in the theme it is shown in. A diagram the
/// core cannot draw shows its source.
final class DiagramCell: NativeCell {
    private let source: String
    private var images: [Bool: CGImage] = [:]
    private var points: CGSize?
    private var pending: Set<Bool> = []
    private var failed = false
    private lazy var fallback = NSAttributedString(string: source.trimmingCharacters(in: .newlines), attributes: [
        .font: NativeTheme.mono(size: 12), .foregroundColor: NativeTheme.muted,
    ])

    /// Diagrams are drawn one at a time, in document order.
    private static let queue = DispatchQueue(label: "mdql.diagrams", qos: .userInitiated)
    private static let scale: CGFloat = 2

    /// `synchronousDark`: draw now, in that theme (thumbnails, snapshots).
    init(source: String, synchronousDark: Bool? = nil) {
        self.source = source
        super.init()
        if let dark = synchronousDark {
            store(Renderer.mermaid(source, dark: dark, scale: Self.scale), dark: dark)
        } else {
            request(dark: Renderer.systemTheme == MDQL_THEME_DARK)
        }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    private func request(dark: Bool) {
        guard !pending.contains(dark), images[dark] == nil, !failed else { return }
        pending.insert(dark)
        let source = source
        Self.queue.async { [weak self] in
            let result = Renderer.mermaid(source, dark: dark, scale: Self.scale)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(dark)
                self.store(result, dark: dark)
                self.announceLoad()
            }
        }
    }

    private func store(_ result: (image: CGImage, size: CGSize)?, dark: Bool) {
        guard let result else {
            failed = true
            return
        }
        images[dark] = result.image
        points = result.size
    }

    override func size(forLineWidth width: CGFloat) -> NSSize {
        guard let points, points.width > 0 else {
            let size = failed ? fallback.boundingRect(with: NSSize(width: width, height: 10_000),
                                                       options: [.usesLineFragmentOrigin]).size
                              : NSSize(width: 1, height: 40)
            return NSSize(width: min(ceil(size.width), width), height: ceil(size.height))
        }
        let target = min(points.width, width)
        return NSSize(width: target, height: (target * points.height / points.width).rounded())
    }

    override func draw(in rect: NSRect) {
        if failed, points == nil {
            fallback.draw(with: rect, options: [.usesLineFragmentOrigin])
            return
        }
        let dark = NSAppearance.currentDrawing().isDark
        // Draw the other theme's picture until this one is ready.
        if images[dark] == nil { request(dark: dark) }
        guard let image = images[dark] ?? images[!dark], let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .high
        // The text view is flipped; CGImage draws bottom-up.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// A shields.io-style badge drawn locally from its label, message and colour.
final class BadgeCell: NativeCell {
    static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Verdana", size: 11) ?? NativeTheme.font(size: 11), .foregroundColor: NSColor.white,
    ]

    private let parts: [(NSAttributedString, NSColor)]

    init(label: String, message: String, color: String) {
        var parts: [(NSAttributedString, NSColor)] = []
        if !label.isEmpty {
            parts.append((NSAttributedString(string: label, attributes: Self.textAttributes), NSColor(white: 0.36, alpha: 1)))
        }
        parts.append((NSAttributedString(string: message, attributes: Self.textAttributes), NativeTheme.hex(color)))
        self.parts = parts
        super.init()
        descent = 5
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func size(forLineWidth width: CGFloat) -> NSSize {
        NSSize(width: parts.reduce(0) { $0 + ceil($1.0.size().width) + 12 }, height: 20)
    }

    override func draw(in rect: NSRect) {
        Self.drawPill(in: rect, parts: parts)
    }

    static func drawPill(in rect: NSRect, parts: [(NSAttributedString, NSColor)]) {
        let pill = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState()
        pill.addClip()
        var x = rect.minX
        for (text, color) in parts {
            let width = ceil(text.size().width) + 12
            color.setFill()
            NSRect(x: x, y: rect.minY, width: width, height: rect.height).fill()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            text.draw(at: NSPoint(x: x + 6, y: rect.midY - text.size().height / 2))
            NSShadow().set()
            x += width
        }
        // Subtle gloss, like shields.io's flat style.
        NSGradient(starting: NSColor.white.withAlphaComponent(0.1), ending: NSColor.black.withAlphaComponent(0.1))?
            .draw(in: rect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Small pieces

/// A task-list checkbox.
final class CheckboxCell: NativeCell {
    private let checked: Bool

    init(checked: Bool) {
        self.checked = checked
        super.init()
        descent = 2
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func size(forLineWidth width: CGFloat) -> NSSize { NSSize(width: 14, height: 14) }

    override func draw(in rect: NSRect) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3.5, yRadius: 3.5)
        if checked {
            NativeTheme.link.setFill()
            box.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 3.8, y: rect.midY + 0.2))
            check.line(to: NSPoint(x: rect.minX + 6.2, y: rect.maxY - 3.8))
            check.line(to: NSPoint(x: rect.maxX - 3.4, y: rect.minY + 4))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            box.lineWidth = 1.2
            NativeTheme.muted.setStroke()
            box.stroke()
        }
    }
}

/// A horizontal rule spanning the line.
final class RuleCell: NativeCell {
    private var width: CGFloat = 100

    override func size(forLineWidth width: CGFloat) -> NSSize {
        self.width = width
        return NSSize(width: width, height: 12)
    }

    override func draw(in rect: NSRect) {
        NativeTheme.border.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4),
                     xRadius: 2, yRadius: 2).fill()
    }
}

extension NSColor {
    /// This colour as it looks in the current drawing appearance.
    func resolved() -> NSColor {
        var color = self
        NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {
            color = self.usingColorSpace(.sRGB) ?? self
        }
        return color
    }
}

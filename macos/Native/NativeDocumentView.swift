import AppKit

/// A scrolling, read-only TextKit 1 view for a rendered document. Text is
/// kept to a readable column (centred in wide windows, edge-to-edge with a
/// small margin in narrow ones), links open, `#anchor` links scroll.
final class NativeDocumentView: NSScrollView, NSTextViewDelegate {
    let textView: DocumentTextView
    private var anchors: [String: Int] = [:]

    override init(frame: NSRect) {
        // TextKit 1: TextKit 2 cannot lay out tables (NSTextTable).
        let textView = DocumentTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(DocumentLayoutManager())
        self.textView = textView
        super.init(frame: frame)

        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = NativeTheme.background
        borderType = .noBorder

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = NativeTheme.background
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.layoutManager?.backgroundLayoutEnabled = true
        textView.linkTextAttributes = [.foregroundColor: NativeTheme.link, .cursor: NSCursor.pointingHand]
        textView.displaysLinkToolTips = true
        textView.delegate = self
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: NSAttributedString, anchors: [String: Int]) {
        self.anchors = anchors
        textView.textStorage?.setAttributedString(text)
        textView.scrollToBeginningOfDocument(nil)
    }

    /// Appends the rest of a progressively rendered document.
    func append(_ text: NSAttributedString, anchors: [String: Int]) {
        self.anchors = anchors
        textView.textStorage?.append(text)
    }

    /// Fallback for files the core could not render.
    func showPlainText(_ url: URL) {
        let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        let text = String(decoding: data.prefix(8 * 1024 * 1024), as: UTF8.self)
        show(NSAttributedString(string: text, attributes: [
            .font: NativeTheme.mono(size: 12), .foregroundColor: NativeTheme.fg,
        ]), anchors: [:])
    }

    /// Redoes layout after something changed size (a downloaded image).
    func relayout() {
        guard let storage = textView.textStorage, let layoutManager = textView.layoutManager else { return }
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                       actualCharacterRange: nil)
        textView.needsDisplay = true
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let anchor = link as? String, anchor.hasPrefix("#") {
            let name = String(anchor.dropFirst()).removingPercentEncoding ?? String(anchor.dropFirst())
            if let index = anchors[name] ?? anchors[name.lowercased()] {
                scrollTo(characterIndex: index)
            }
            return true
        }
        if let url = link as? URL {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }

    private func scrollTo(characterIndex index: Int) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                              actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let y = max(0, rect.minY + textView.textContainerOrigin.y - 12)
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }
}

/// Keeps the text column readable by adjusting the container inset to the
/// view's width.
final class DocumentTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        let side = max(narrowMargin(for: newSize.width), (newSize.width - NativeTheme.maxContentWidth) / 2)
        let inset = NSSize(width: side.rounded(), height: newSize.width < 500 ? 14 : 28)
        if textContainerInset != inset { textContainerInset = inset }
        super.setFrameSize(newSize)
    }

    private func narrowMargin(for width: CGFloat) -> CGFloat {
        width < 500 ? 14 : width < 800 ? 28 : 40
    }
}

/// Draws inline code and highlight backgrounds as rounded boxes hugging the
/// text (TextKit would fill the whole line height, line spacing included).
final class DocumentLayoutManager: NSLayoutManager {
    private var drawingOrigin = NSPoint.zero

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawingOrigin = origin
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, let container = textContainers.first, charRange.location < storage.length,
              storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor === color,
              let font = storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont
        else {
            // Selection and anything else: default drawing.
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        color.setFill()
        for i in 0..<rectCount {
            let rect = rectArray[i]
            let point = NSPoint(x: rect.midX - drawingOrigin.x, y: rect.midY - drawingOrigin.y)
            let glyph = glyphIndex(for: point, in: container)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = drawingOrigin.y + fragment.minY + location(forGlyphAt: glyph).y
            let box = NSRect(x: rect.minX - 1.5, y: baseline - font.ascender - 2,
                             width: rect.width + 3, height: font.ascender - font.descender + 4)
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        }
    }
}

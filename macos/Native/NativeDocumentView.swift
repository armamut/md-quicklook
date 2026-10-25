import AppKit

/// A scrolling, read-only TextKit 1 view for a rendered document. Text is
/// kept to a readable column (centred in wide windows, edge-to-edge with a
/// small margin in narrow ones), links open, `#anchor` links scroll,
/// `<details>` sections fold and unfold.
final class NativeDocumentView: NSScrollView, NSTextViewDelegate {
    let textView: DocumentTextView
    private var folding = DetailsFolding()
    /// Length of the text as built, before folding: anchors index into it.
    private var builtLength = 0

    override init(frame: NSRect) {
        // TextKit 1: TextKit 2 cannot lay out tables (NSTextTable).
        let textView = DocumentTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(DocumentLayoutManager())
        self.textView = textView
        super.init(frame: frame)

        // Follow the host's size: Finder resizes the preview without asking
        // for a new one, e.g. when switching to the column view.
        autoresizingMask = [.width, .height]
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
        textView.summaryClicked = { [weak self] id in self?.toggleDetails(id) }
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: NSAttributedString, anchors: [String: Int], closedDetails: Set<Int> = []) {
        folding = DetailsFolding()
        builtLength = 0
        textView.textStorage?.setAttributedString(prepare(text, anchors: anchors, closedDetails: closedDetails))
        textView.scrollToBeginningOfDocument(nil)
    }

    /// Appends the rest of a progressively rendered document.
    func append(_ text: NSAttributedString, anchors: [String: Int], closedDetails: Set<Int> = []) {
        textView.textStorage?.append(prepare(text, anchors: anchors, closedDetails: closedDetails))
    }

    /// Marks anchors on their characters (folding moves text around) and
    /// folds closed sections.
    private func prepare(_ text: NSAttributedString, anchors: [String: Int],
                         closedDetails: Set<Int>) -> NSAttributedString {
        let part = NSMutableAttributedString(attributedString: text)
        let start = builtLength
        builtLength += part.length
        for (name, index) in anchors where (start..<builtLength).contains(index) {
            part.addAttribute(.anchor, value: name, range: NSRange(location: index - start, length: 1))
        }
        folding.fold(part, closing: closedDetails)
        return part
    }

    private func toggleDetails(_ id: Int) {
        guard let storage = textView.textStorage else { return }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        folding.toggle(id, in: storage)
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
            guard let storage = textView.textStorage else { return true }
            folding.reveal(anchor: name, in: storage)
            if let index = DetailsFolding.location(ofAnchor: name, in: storage) {
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
    var summaryClicked: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let id = summary(at: convert(event.locationInWindow, from: nil)) {
            summaryClicked?(id)
            return
        }
        super.mouseDown(with: event)
    }

    /// The `<details>` whose summary line is under a point.
    private func summary(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        guard layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).contains(inContainer) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < textStorage.length else { return nil }
        return textStorage.attribute(.detailsSummary, at: index, effectiveRange: nil) as? Int
    }

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

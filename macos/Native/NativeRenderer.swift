import AppKit

/// Turns a `NativeDocument` into an attributed string for a TextKit 1 text
/// view: paragraph styles and text blocks (quotes, alerts, code, tables) from
/// the block tree, inline attributes from the runs, attachment cells for
/// images, formulas, badges, checkboxes and rules.
final class NativeRenderer {
    struct Options {
        var baseDirectory: URL?
        var loadRemoteImages = false
        /// Draw diagrams while building, in this theme (thumbnails, snapshots);
        /// nil draws them in the background.
        var synchronousDiagramsDark: Bool?
    }

    typealias Kind = NativeDocument.ParagraphKind
    typealias Block = NativeDocument.BlockKind
    typealias Flag = NativeDocument.RunFlag
    typealias Attach = NativeDocument.AttachmentKind

    private let doc: NativeDocument
    private let options: Options

    /// Heading and footnote anchors → character index.
    private(set) var anchors: [String: Int] = [:]
    /// Cells whose content arrives after display (remote images, diagrams).
    private(set) var lateCells: [NativeCell] = []
    /// `<details>` blocks without `open`, to show folded.
    private(set) var closedDetails: Set<Int> = []

    private lazy var text = doc.text as NSString
    private var runCursor = 0
    private var textBlocks: [Int: NSTextBlock] = [:]
    private var tables: [Int: NSTextTable] = [:]
    /// Cells of each table, to size columns once their text is known.
    private var tableCells: [Int: [(cell: NSTextTableBlock, column: Int, range: NSRange)]] = [:]

    init(document: NativeDocument, options: Options) {
        doc = document
        self.options = options
    }

    /// Builds the whole document.
    func build() -> NSAttributedString {
        build(paragraphs: 0..<doc.paragraphs.count)
    }

    /// Splits the document for progressive display: a first part that fills
    /// the screen, then the rest. Parts end only between top-level blocks, so
    /// a code block or table is never split.
    func parts(firstPartCharacters: Int = 8000) -> [Range<Int>] {
        let paragraphs = doc.paragraphs
        guard let last = paragraphs.indices.last, paragraphs[last].start + paragraphs[last].length > firstPartCharacters * 2
        else { return [0..<paragraphs.count] }
        var split = 0
        while split < paragraphs.count, paragraphs[split].start < firstPartCharacters { split += 1 }
        // Move forward to a top-level boundary.
        while split < paragraphs.count, split > 0, root(of: paragraphs[split].block) != NativeDocument.noBlock,
              root(of: paragraphs[split].block) == root(of: paragraphs[split - 1].block) {
            split += 1
        }
        return split >= paragraphs.count ? [0..<paragraphs.count] : [0..<split, split..<paragraphs.count]
    }

    private func root(of block: UInt16) -> UInt16 {
        doc.ancestry(of: block).last.map { UInt16($0) } ?? NativeDocument.noBlock
    }

    /// Builds the attributed string of a range of paragraphs. Ranges must be
    /// built in order (the renderer keeps shared text blocks and a run cursor).
    func build(paragraphs range: Range<Int>) -> NSAttributedString {
        guard !range.isEmpty, let lastParagraph = doc.paragraphs[safe: range.upperBound - 1] else {
            return NSAttributedString()
        }
        let first = doc.paragraphs[range.lowerBound].start
        let end = range.upperBound == doc.paragraphs.count ? text.length : lastParagraph.start + lastParagraph.length
        let span = NSRange(location: first, length: max(0, min(end, text.length) - first))
        let out = NSMutableAttributedString(string: text.substring(with: span), attributes: [
            .font: NativeTheme.font(size: NativeTheme.bodySize),
            .foregroundColor: NativeTheme.fg,
        ])
        let length = out.length
        let local = { (r: NSRange) in NSRange(location: r.location - first, length: r.length) }
        out.beginEditing()

        var bases: [(range: NSRange, size: CGFloat, mono: Bool, heading: Bool)] = []
        bases.reserveCapacity(range.count)
        for index in range {
            let p = doc.paragraphs[index]
            let r = local(p.range)
            guard r.location >= 0, NSMaxRange(r) <= length else { continue }
            let context = paragraphContext(p)
            var attributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: paragraphStyle(p, context: context, first: index == 0,
                                                afterTable: index > 0 && doc.paragraphs[index - 1].kind == Kind.tableCell),
                .font: context.font,
            ]
            if let color = context.color { attributes[.foregroundColor] = color }
            // Foldable sections: a summary toggles its block, whose other
            // paragraphs are marked with every enclosing <details>.
            var details = doc.ancestry(of: p.block).filter { doc.blocks[$0].kind == Block.details }
            if p.kind == Kind.summary, details.first == Int(p.block) {
                details.removeFirst()
                attributes[.detailsSummary] = Int(p.block)
                attributes[.cursor] = NSCursor.pointingHand
                if doc.blocks[Int(p.block)].flags & Block.open == 0 { closedDetails.insert(Int(p.block)) }
            }
            if !details.isEmpty { attributes[.detailsBody] = details }
            out.addAttributes(attributes, range: r)
            bases.append((p.range, context.font.pointSize, context.mono, p.kind == Kind.heading))

            if p.kind == Kind.heading, let anchor = doc.string(oneBased: p.extra) {
                anchors[anchor] = p.start
            }
            if p.kind == Kind.body, let anchor = doc.string(oneBased: p.extra >> Kind.anchorShift) {
                anchors[anchor] = p.start
            }
        }

        // Runs are sorted like paragraphs; walk both together.
        var pi = 0
        while runCursor < doc.runs.count, doc.runs[runCursor].start < span.location + span.length {
            let run = doc.runs[runCursor]
            runCursor += 1
            let r = local(run.range)
            guard r.location >= 0, NSMaxRange(r) <= length else { continue }
            while pi + 1 < bases.count, NSMaxRange(bases[pi].range) <= run.start { pi += 1 }
            let base = bases[safe: pi] ?? (NSRange(), NativeTheme.bodySize, false, false)
            out.addAttributes(attributes(for: run, size: base.size, mono: base.mono, heading: base.heading), range: r)
        }
        out.endEditing()
        sizeTables(out, offset: first)
        return out
    }

    /// Gives table columns their natural width, like a browser does: the table
    /// is as wide as its content, but never wider than the view.
    private func sizeTables(_ text: NSAttributedString, offset: Int) {
        let sized = tableCells
        tableCells = [:]
        for (tableID, cells) in sized {
            guard let table = tables[tableID] else { continue }
            let frontMatter = doc.blocks[tableID].flags & Block.frontMatterTable != 0
            var widths = Array(repeating: CGFloat(0), count: table.numberOfColumns)
            let padding: CGFloat = frontMatter ? 32 : 30
            for cell in cells where cell.column < widths.count {
                var range = NSRange(location: cell.range.location - offset, length: cell.range.length)
                if range.length > 0 { range.length -= 1 } // trailing newline
                guard range.location >= 0, NSMaxRange(range) <= text.length else { continue }
                // Measure without the cell's paragraph style (its padding).
                let content = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
                content.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: content.length))
                let natural = content.boundingRect(with: NSSize(width: 10_000, height: 10_000),
                                                   options: [.usesLineFragmentOrigin]).width
                widths[cell.column] = max(widths[cell.column], min(ceil(natural) + padding, 420))
            }
            if frontMatter {
                // Keys take what they need; values the rest of the full-width box.
                // The width is the content width: the cell's padding comes on top.
                for cell in cells where cell.column == 0 {
                    cell.cell.setValue(max(1, widths[0] - padding + 2), type: .absoluteValueType, for: .width)
                }
                continue
            }
            let total = widths.reduce(0, +)
            guard total > 0 else { continue }
            table.setValue(total, type: .absoluteValueType, for: .width)
            table.setValue(100, type: .percentageValueType, for: .maximumWidth)
            // A block's width is its content width, padding and border excluded.
            let cellPadding: CGFloat = 27
            for cell in cells where cell.column < widths.count {
                cell.cell.setValue(max(1, widths[cell.column] - cellPadding) / total * 100, type: .percentageValueType,
                                   for: .width)
            }
        }
    }

    // MARK: Paragraphs

    private struct Context {
        var font: NSFont
        var color: NSColor?
        var mono = false
        /// List items enclosing the paragraph inside its innermost text block.
        var listDepth = 0
        var tight = false
        var blocks: [NSTextBlock] = []
        var quote = false
        var alert: Int?
    }

    private func paragraphContext(_ p: NativeDocument.Paragraph) -> Context {
        var context = Context(font: NativeTheme.font(size: NativeTheme.bodySize))
        let chain = doc.ancestry(of: p.block) // innermost first
        var nearestList = true
        var depthInsideBlock = 0
        var reachedBlock = false
        for id in chain {
            let b = doc.blocks[id]
            switch b.kind {
            case Block.listItem:
                if !reachedBlock { depthInsideBlock += 1 }
            case Block.list:
                if nearestList { context.tight = b.flags & Block.tight != 0; nearestList = false }
            case Block.quote, Block.alert, Block.code, Block.frontMatter, Block.table, Block.tableRow:
                reachedBlock = true
                if b.kind == Block.quote { context.quote = true }
                if b.kind == Block.alert, context.alert == nil { context.alert = Int(b.a) }
            default:
                break
            }
        }
        context.listDepth = depthInsideBlock
        context.blocks = textBlockChain(chain, paragraph: p)
        if context.quote { context.color = NativeTheme.muted }

        switch p.kind {
        case Kind.heading:
            let size = NativeTheme.headingSizes[safe: Int(p.level) - 1] ?? NativeTheme.bodySize
            context.font = NativeTheme.font(size: size, bold: true)
            if p.level == 6 { context.color = NativeTheme.muted }
        case Kind.code:
            context.font = NativeTheme.mono(size: 12.75)
            context.mono = true
        case Kind.alertTitle:
            context.font = NativeTheme.font(size: NativeTheme.bodySize, bold: true)
            context.color = NativeTheme.alerts[safe: Int(p.level)] ?? NativeTheme.fg
        default:
            break
        }
        return context
    }

    private func paragraphStyle(_ p: NativeDocument.Paragraph, context: Context, first: Bool,
                                afterTable: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = NativeTheme.lineHeightMultiple
        style.paragraphSpacing = context.tight && context.listDepth > 0 ? 4 : NativeTheme.paragraphSpacing
        style.textBlocks = context.blocks
        // NSTextStorage merges neighbouring paragraphs whose styles are equal,
        // and paragraph-style equality ignores text blocks: two consecutive
        // code blocks would share the first one's box. A per-block value in a
        // property without visible effect keeps their styles distinct.
        if let innermost = context.blocks.last {
            style.tighteningFactorForTruncation = Float(ObjectIdentifier(innermost).hashValue & 0xffff) / 1e6
        }

        // List indentation, with the marker hanging in front of the text.
        let indent = CGFloat(context.listDepth) * NativeTheme.listIndent
        if p.extra & Kind.listMarker != 0 {
            style.firstLineHeadIndent = indent - NativeTheme.listIndent
            style.headIndent = indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        } else {
            style.firstLineHeadIndent = indent
            style.headIndent = indent
        }

        switch p.kind {
        case Kind.heading:
            style.paragraphSpacingBefore = first ? 0 : 24 - NativeTheme.paragraphSpacing
            style.paragraphSpacing = p.level <= 2 ? 16 : 12
            style.lineHeightMultiple = 1.05
        case Kind.code:
            style.paragraphSpacing = 0
            style.lineHeightMultiple = 1.12
            style.tabStops = (1...20).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 30.6) }
            style.defaultTabInterval = 30.6
        case Kind.tableCell:
            style.paragraphSpacing = 0
            let align = p.extra & 0xff
            style.alignment = align == 2 ? .center : align == 3 ? .right : .natural
        case Kind.math, Kind.rule:
            style.alignment = p.kind == Kind.math ? .center : .natural
            style.paragraphSpacingBefore = 2
            // A formula or diagram is the whole line: no extra leading above it.
            if p.kind == Kind.math { style.lineHeightMultiple = 1 }
        case Kind.alertTitle, Kind.caption:
            style.paragraphSpacing = 6
        case Kind.summary:
            style.paragraphSpacing = 8
        default:
            break
        }
        if p.kind != Kind.tableCell {
            switch (p.extra >> Kind.alignShift) & 3 {
            case 1: style.alignment = .left
            case 2: style.alignment = .center
            case 3: style.alignment = .right
            default: break
            }
            // TextKit 1 ignores a table's bottom margin: space the next paragraph.
            if afterTable { style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, NativeTheme.paragraphSpacing) }
        }
        return style
    }

    /// The `NSTextBlock`s a paragraph sits in, outermost first. Paragraphs of
    /// one container share its block object, which is what makes TextKit draw
    /// them as one box.
    private func textBlockChain(_ chain: [Int], paragraph p: NativeDocument.Paragraph) -> [NSTextBlock] {
        // TextKit cannot draw a table nested in another text block, so a
        // table's cells carry no outer blocks; the table itself is styled
        // (and indented) to stand in for them.
        if let rowID = chain.first(where: { doc.blocks[$0].kind == Block.tableRow }) {
            let row = doc.blocks[rowID]
            let tableID = Int(row.parent)
            guard tableID < doc.blocks.count else { return [] }
            let table = self.table(tableID, enclosing: chain)
            let cell = NSTextTableBlock(table: table, startingRow: Int(row.a), rowSpan: 1,
                                        startingColumn: Int(p.level), columnSpan: 1)
            styleCell(cell, row: row, column: Int(p.level),
                      frontMatter: doc.blocks[tableID].flags & Block.frontMatterTable != 0)
            tableCells[tableID, default: []].append((cell, Int(p.level), p.range))
            return [cell]
        }
        var result: [NSTextBlock] = []
        var listItemsOutside = 0 // list items between this block and the next outer one
        for id in chain.reversed() {
            let b = doc.blocks[id]
            if b.kind == Block.listItem { listItemsOutside += 1; continue }
            var block: NSTextBlock?
            switch b.kind {
            case Block.quote, Block.alert, Block.code:
                block = textBlock(id, b)
            default:
                break
            }
            if let block {
                if listItemsOutside > 0, block.width(for: .margin, edge: .minX) == 0 {
                    block.setWidth(CGFloat(listItemsOutside) * NativeTheme.listIndent, type: .absoluteValueType,
                                   for: .margin, edge: .minX)
                }
                listItemsOutside = 0
                result.append(block)
            }
        }
        if p.kind == Kind.heading, p.level <= 2 {
            result.append(headingRule())
        }
        return result
    }

    private func textBlock(_ id: Int, _ b: NativeDocument.Block) -> NSTextBlock {
        if let block = textBlocks[id] { return block }
        let block = DistinctTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        switch b.kind {
        case Block.quote:
            block.setWidth(4, type: .absoluteValueType, for: .border, edge: .minX)
            block.bar = NativeTheme.border
            block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(NativeTheme.paragraphSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
        case Block.alert:
            block.setWidth(4, type: .absoluteValueType, for: .border, edge: .minX)
            block.bar = NativeTheme.alerts[safe: Int(b.a)] ?? NativeTheme.border
            block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(NativeTheme.paragraphSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
        case Block.code:
            block.fill = NativeTheme.subtle
            block.setWidth(14, type: .absoluteValueType, for: .padding)
            block.setWidth(16, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(NativeTheme.paragraphSpacing + 2, type: .absoluteValueType, for: .margin, edge: .maxY)
        case Block.frontMatter:
            block.fill = NativeTheme.subtle
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.stroke = NativeTheme.borderMuted
            block.setWidth(10, type: .absoluteValueType, for: .padding)
            block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(18, type: .absoluteValueType, for: .margin, edge: .maxY)
        default:
            break
        }
        textBlocks[id] = block
        return block
    }

    private func table(_ id: Int, enclosing chain: [Int]) -> NSTextTable {
        if let table = tables[id] { return table }
        let b = doc.blocks[id]
        let table = DistinctTextTable()
        table.numberOfColumns = max(1, Int(b.a))
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setWidth(NativeTheme.paragraphSpacing + 2, type: .absoluteValueType, for: .margin, edge: .maxY)
        if b.flags & Block.frontMatterTable != 0 {
            table.fill = NativeTheme.subtle
            table.setWidth(1, type: .absoluteValueType, for: .border)
            table.stroke = NativeTheme.borderMuted
            table.setValue(100, type: .percentageValueType, for: .width)
            table.setWidth(20, type: .absoluteValueType, for: .margin, edge: .maxY)
        }
        // Stand in for enclosing quotes, alerts and list items.
        var indent: CGFloat = 0
        for ancestor in chain {
            switch doc.blocks[ancestor].kind {
            case Block.listItem: indent += NativeTheme.listIndent
            case Block.quote, Block.alert: indent += 18
            default: break
            }
        }
        if indent > 0 { table.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX) }
        tables[id] = table
        return table
    }

    private func styleCell(_ cell: NSTextTableBlock, row: NativeDocument.Block, column: Int, frontMatter: Bool) {
        if frontMatter {
            // The table's own padding does not reach its cells: inset here.
            let rows = doc.blocks[Int(row.parent)].b
            cell.setWidth(2.5, type: .absoluteValueType, for: .padding)
            cell.setWidth(column == 0 ? 14 : 4, type: .absoluteValueType, for: .padding, edge: .minX)
            cell.setWidth(column == 0 ? 16 : 14, type: .absoluteValueType, for: .padding, edge: .maxX)
            if row.a == 0 { cell.setWidth(9, type: .absoluteValueType, for: .padding, edge: .minY) }
            if row.a + 1 == rows { cell.setWidth(9, type: .absoluteValueType, for: .padding, edge: .maxY) }
            return
        }
        cell.setWidth(1, type: .absoluteValueType, for: .border)
        cell.setBorderColor(NativeTheme.border)
        cell.setWidth(6, type: .absoluteValueType, for: .padding)
        cell.setWidth(13, type: .absoluteValueType, for: .padding, edge: .minX)
        cell.setWidth(13, type: .absoluteValueType, for: .padding, edge: .maxX)
        if row.a > 0, row.a % 2 == 0 { cell.backgroundColor = NativeTheme.subtle }
    }

    /// The thin line under h1 and h2.
    private func headingRule() -> NSTextBlock {
        let block = DistinctTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(NativeTheme.borderMuted, for: .maxY)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
        return block
    }

    // MARK: Runs

    private func attributes(for run: NativeDocument.Run, size: CGFloat, mono: Bool,
                            heading: Bool) -> [NSAttributedString.Key: Any] {
        let f = run.flags
        var attributes: [NSAttributedString.Key: Any] = [:]

        if f & Flag.attachment != 0 {
            if let cell = cell(for: run, size: size) {
                let attachment = NSTextAttachment()
                attachment.attachmentCell = cell
                attributes[.attachment] = attachment
            }
            if f & Flag.link != 0, let url = link(run.c) { attributes[.link] = url }
            return attributes
        }

        var fontSize = size
        if f & Flag.small != 0 { fontSize *= 0.85 }
        if f & (Flag.sup | Flag.sub) != 0 {
            fontSize *= 0.75
            attributes[.baselineOffset] = (f & Flag.sup != 0 ? 0.4 : -0.2) * size
        }
        let bold = heading || f & (Flag.bold | Flag.tokenBold) != 0
        let italic = f & (Flag.italic | Flag.tokenItalic) != 0
        if f & Flag.token != 0 || mono {
            attributes[.font] = NativeTheme.mono(size: fontSize, bold: bold, italic: italic)
        } else if f & Flag.code != 0 {
            attributes[.font] = NativeTheme.mono(size: fontSize * 0.87, bold: bold, italic: italic)
            attributes[.backgroundColor] = NativeTheme.codeBackground
        } else if f & Flag.kbd != 0 {
            attributes[.font] = NativeTheme.mono(size: fontSize * 0.8, bold: bold)
            attributes[.backgroundColor] = NativeTheme.subtle
        } else if bold || italic || fontSize != size {
            attributes[.font] = NativeTheme.font(size: fontSize, bold: bold, italic: italic)
        }

        if f & Flag.token != 0 { attributes[.foregroundColor] = NativeTheme.tokenColor(light: run.a, dark: run.b) }
        if f & Flag.muted != 0 { attributes[.foregroundColor] = NativeTheme.muted }
        if f & Flag.strike != 0 {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = NativeTheme.muted
        }
        if f & Flag.underline != 0 { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if f & Flag.mark != 0 { attributes[.backgroundColor] = NativeTheme.mark }
        if f & Flag.link != 0, let url = link(run.c) {
            attributes[.link] = url
            attributes[.foregroundColor] = NativeTheme.link
        }
        return attributes
    }

    /// Links: "#anchor" stays a string for in-document jumps; relative paths
    /// resolve against the document's folder.
    private func link(_ id: UInt32) -> Any? {
        guard let raw = doc.string(oneBased: id), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") { return raw }
        if let url = URL(string: raw), url.scheme != nil { return url }
        guard let base = options.baseDirectory else { return URL(string: raw) }
        let path = raw.components(separatedBy: "#")[0]
        return URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: base).standardizedFileURL
    }

    private func cell(for run: NativeDocument.Run, size: CGFloat) -> NativeCell? {
        let s = { (offset: Int) in self.doc.strings[safe: Int(run.b) + offset] ?? "" }
        switch run.a {
        case Attach.mathInline:
            return MathCell(latex: s(0), display: false, fontSize: size * 1.05)
        case Attach.mathDisplay:
            return MathCell(latex: s(0), display: true, fontSize: size * 1.15)
        case Attach.image:
            return ImageCell(path: s(0), width: CGFloat(run.d))
        case Attach.remoteImage, Attach.remoteBadge:
            let cell = RemoteImageCell(url: s(0), alt: s(1), badgeLike: run.a == Attach.remoteBadge,
                                       width: CGFloat(run.d), load: options.loadRemoteImages)
            lateCells.append(cell)
            return cell
        case Attach.diagram:
            let cell = DiagramCell(source: s(0), synchronousDark: options.synchronousDiagramsDark)
            if options.synchronousDiagramsDark == nil { lateCells.append(cell) }
            return cell
        case Attach.badge:
            return BadgeCell(label: s(0), message: s(1), color: s(2))
        case Attach.checkboxOn, Attach.checkboxOff:
            return CheckboxCell(checked: run.a == Attach.checkboxOn)
        case Attach.rule:
            return RuleCell()
        default:
            return nil
        }
    }
}

/// TextKit merges neighbouring paragraphs whose text blocks are *equal*, and
/// blocks with the same settings compare equal: two consecutive code blocks
/// would become one box. These compare by identity instead.
///
/// They also draw their own decoration: AppKit paints a block's background
/// over its margins too, which hides the space between neighbouring boxes.
final class DistinctTextBlock: NSTextBlock {
    var decoration = BlockDecoration()

    var fill: NSColor? { get { decoration.fill } set { decoration.fill = newValue } }
    var stroke: NSColor? { get { decoration.stroke } set { decoration.stroke = newValue } }
    var bar: NSColor? { get { decoration.bar } set { decoration.bar = newValue } }

    override func isEqual(_ object: Any?) -> Bool { self === object as AnyObject? }
    override var hash: Int { ObjectIdentifier(self).hashValue }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        if !decoration.draw(for: self, in: frameRect) {
            super.drawBackground(withFrame: frameRect, in: controlView, characterRange: charRange,
                                 layoutManager: layoutManager)
        }
    }
}

final class DistinctTextTable: NSTextTable {
    var decoration = BlockDecoration()

    var fill: NSColor? { get { decoration.fill } set { decoration.fill = newValue } }
    var stroke: NSColor? { get { decoration.stroke } set { decoration.stroke = newValue } }

    override func isEqual(_ object: Any?) -> Bool { self === object as AnyObject? }
    override var hash: Int { ObjectIdentifier(self).hashValue }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        if !decoration.draw(for: self, in: frameRect) {
            super.drawBackground(withFrame: frameRect, in: controlView, characterRange: charRange,
                                 layoutManager: layoutManager)
        }
    }
}

/// Rounded background, outline and leading bar of a text block, drawn inside
/// its margins.
struct BlockDecoration {
    var fill: NSColor?
    var stroke: NSColor?
    /// A bar along the leading edge (quotes, alerts), as wide as that border.
    var bar: NSColor?
    var cornerRadius: CGFloat = 6

    /// Returns false when there is nothing custom to draw.
    func draw(for block: NSTextBlock, in frameRect: NSRect) -> Bool {
        guard fill != nil || stroke != nil || bar != nil else { return false }
        let left = block.width(for: .margin, edge: .minX), right = block.width(for: .margin, edge: .maxX)
        let top = block.width(for: .margin, edge: .minY), bottom = block.width(for: .margin, edge: .maxY)
        let box = NSRect(x: frameRect.minX + left, y: frameRect.minY + top,
                         width: frameRect.width - left - right, height: frameRect.height - top - bottom)
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: box, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        if let stroke {
            stroke.setStroke()
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius,
                                    yRadius: cornerRadius)
            path.lineWidth = 1
            path.stroke()
        }
        if let bar {
            bar.setFill()
            let width = block.width(for: .border, edge: .minX)
            NSBezierPath(roundedRect: NSRect(x: box.minX, y: box.minY, width: width, height: box.height),
                         xRadius: width / 2, yRadius: width / 2).fill()
        }
        return true
    }
}

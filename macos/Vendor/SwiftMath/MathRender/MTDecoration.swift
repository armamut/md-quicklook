//
//  md-quicklook addition (not part of upstream SwiftMath).
//
//  Stretchy decorations above or below a formula: \overbrace, \underbrace,
//  \overbracket, \underbracket, \overgroup, \undergroup, \overlinesegment,
//  \underlinesegment, \Overrightarrow, \overleftharpoon, \overrightharpoon,
//  \underleftarrow, \underrightarrow, \underleftrightarrow and \utilde.
//
//  Like KaTeX, which draws these as SVG paths, they are drawn as vector paths
//  sized to the content, so they stretch to any width. Braces and brackets
//  are operators with limits: \overbrace{a+b}^{n} puts n above the brace.
//
//  This software may be modified and distributed under the terms of the
//  MIT license. See the LICENSE file for details.
//

import Foundation
import CoreGraphics

public enum MTDecoration: String, CaseIterable {
    case overbrace, underbrace, overbracket, underbracket, overgroup, undergroup
    case overlinesegment, underlinesegment
    case Overrightarrow, overleftharpoon, overrightharpoon
    case underleftarrow, underrightarrow, underleftrightarrow, utilde

    var isOver: Bool {
        switch self {
        case .overbrace, .overbracket, .overgroup, .overlinesegment, .Overrightarrow, .overleftharpoon,
             .overrightharpoon:
            return true
        default:
            return false
        }
    }

    /// Braces and brackets take their scripts above or below, like \sum.
    var takesLimits: Bool {
        switch self {
        case .overbrace, .underbrace, .overbracket, .underbracket: return true
        default: return false
        }
    }

    /// Height of the drawn shape, in ems.
    var height: CGFloat {
        switch self {
        case .overbrace, .underbrace: return 0.42
        case .overbracket, .underbracket, .overgroup, .undergroup: return 0.28
        case .overlinesegment, .underlinesegment: return 0.24
        case .utilde: return 0.22
        default: return 0.36 // arrows and harpoons
        }
    }
}

/// An atom decorated above or below. It is a large operator so that braces
/// get \sum-style limits from the existing layout code.
public class MTDecoratedOperator: MTLargeOperator {
    public var decoration: MTDecoration = .overbrace
    public var innerList: MTMathList?

    init(decoration: MTDecoration) {
        super.init(value: "", limits: decoration.takesLimits)
        self.decoration = decoration
    }

    init(_ op: MTDecoratedOperator) {
        super.init(op)
        self.decoration = op.decoration
        self.innerList = MTMathList(op.innerList)
    }

    override public var finalized: MTMathAtom {
        let finalized = super.finalized as! MTDecoratedOperator
        finalized.innerList = finalized.innerList?.finalized
        return finalized
    }
}

/// Draws the inner formula and the decoration's path.
class MTDecorationDisplay: MTDisplay {
    let inner: MTMathListDisplay
    let decoration: MTDecoration
    /// Left of the inner formula within the display (narrow content is centred).
    let innerOffset: CGFloat
    /// The shape's edge nearest the formula, relative to the baseline.
    let shapeBase: CGFloat
    let shapeHeight: CGFloat
    let lineWidth: CGFloat

    init(inner: MTMathListDisplay, decoration: MTDecoration, font: MTFont, range: NSRange) {
        self.inner = inner
        self.decoration = decoration
        let table = font.mathTable!
        let em = font.fontSize
        let rule = table.underbarRuleThickness
        lineWidth = max(rule, em * 0.04) * (decoration == .overbrace || decoration == .underbrace ? 1.25 : 1)
        shapeHeight = em * decoration.height
        let gap = table.overbarVerticalGap * 0.8
        let width = max(inner.width, em * 0.8)
        innerOffset = (width - inner.width) / 2
        if decoration.isOver {
            shapeBase = inner.ascent + gap
        } else {
            shapeBase = -(inner.descent + gap)
        }
        super.init()
        self.range = range
        self.width = width
        self.ascent = decoration.isOver ? shapeBase + shapeHeight + lineWidth : inner.ascent
        self.descent = decoration.isOver ? inner.descent : -shapeBase + shapeHeight + lineWidth
    }

    override var position: CGPoint {
        set {
            super.position = newValue
            inner.position = CGPoint(x: newValue.x + innerOffset, y: newValue.y)
        }
        get { super.position }
    }

    override var textColor: MTColor? {
        set {
            super.textColor = newValue
            inner.textColor = newValue
        }
        get { super.textColor }
    }

    override func draw(_ context: CGContext) {
        super.draw(context)
        inner.draw(context)
        context.saveGState()
        let color = (textColor ?? MTColor.black).cgColor
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // Shape coordinates: x from 0 to w, y from 0 (next to the formula)
        // to h (away from it); flipped below the formula.
        let x0 = position.x, w = width, h = shapeHeight
        let sign: CGFloat = decoration.isOver ? 1 : -1
        let base = position.y + shapeBase
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x0 + x, y: base + sign * y) }

        let path = CGMutablePath()
        switch decoration {
        case .overbrace, .underbrace:
            let r = min(h / 2, w / 4)
            path.move(to: p(0, 0))
            path.addQuadCurve(to: p(r, h / 2), control: p(0, h / 2))
            path.addLine(to: p(w / 2 - r, h / 2))
            path.addQuadCurve(to: p(w / 2, h), control: p(w / 2, h / 2))
            path.addQuadCurve(to: p(w / 2 + r, h / 2), control: p(w / 2, h / 2))
            path.addLine(to: p(w - r, h / 2))
            path.addQuadCurve(to: p(w, 0), control: p(w, h / 2))
        case .overbracket, .underbracket:
            path.move(to: p(0, 0))
            path.addLine(to: p(0, h))
            path.addLine(to: p(w, h))
            path.addLine(to: p(w, 0))
        case .overgroup, .undergroup:
            let r = min(h * 1.5, w / 2)
            path.move(to: p(0, 0))
            path.addQuadCurve(to: p(r, h), control: p(0, h))
            path.addLine(to: p(w - r, h))
            path.addQuadCurve(to: p(w, 0), control: p(w, h))
        case .overlinesegment, .underlinesegment:
            path.move(to: p(0, 0))
            path.addLine(to: p(0, h))
            path.move(to: p(w, 0))
            path.addLine(to: p(w, h))
            path.move(to: p(0, h / 2))
            path.addLine(to: p(w, h / 2))
        case .utilde:
            let y = h / 2, amp = h / 2
            path.move(to: p(0, y - amp * 0.4))
            path.addCurve(to: p(w, y + amp * 0.4), control1: p(w * 0.3, y + amp * 1.6), control2: p(w * 0.7, y - amp * 1.6))
        case .Overrightarrow:
            let y = h / 2, gap = h * 0.22, head = h * 0.55
            path.move(to: p(0, y + gap))
            path.addLine(to: p(w - head * 0.5, y + gap))
            path.move(to: p(0, y - gap))
            path.addLine(to: p(w - head * 0.5, y - gap))
            path.move(to: p(w - head, y + head))
            path.addLine(to: p(w, y))
            path.addLine(to: p(w - head, y - head))
        case .overleftharpoon, .overrightharpoon:
            let y = h / 3, head = h * 0.6
            path.move(to: p(0, y))
            path.addLine(to: p(w, y))
            if decoration == .overrightharpoon {
                path.move(to: p(w, y))
                path.addLine(to: p(w - head, y + head))
            } else {
                path.move(to: p(0, y))
                path.addLine(to: p(head, y + head))
            }
        case .underleftarrow, .underrightarrow, .underleftrightarrow:
            let y = h / 2, head = h * 0.45
            path.move(to: p(0, y))
            path.addLine(to: p(w, y))
            if decoration != .underleftarrow {
                path.move(to: p(w - head, y + head))
                path.addLine(to: p(w, y))
                path.addLine(to: p(w - head, y - head))
            }
            if decoration != .underrightarrow {
                path.move(to: p(head, y + head))
                path.addLine(to: p(0, y))
                path.addLine(to: p(head, y - head))
            }
        }
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

extension MTTypesetter {
    /// The decorated formula, positioned like a large operator's nucleus.
    func makeDecoration(_ op: MTDecoratedOperator) -> MTDisplay? {
        let inner = MTTypesetter.createLineForMathList(op.innerList, font: font, style: style,
                                                      cramped: op.decoration.isOver || cramped)
            ?? MTMathListDisplay(withDisplays: [], range: op.indexRange)
        let display = MTDecorationDisplay(inner: inner, decoration: op.decoration, font: styleFont,
                                          range: op.indexRange)
        display.position = currentPosition
        return display
    }
}

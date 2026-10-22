import Foundation

/// SwiftMath (vendored in `macos/Vendor/SwiftMath`) expects Swift Package
/// Manager's `Bundle.module`; its fonts (`mathFonts.bundle`) are in each
/// extension's resources, and next to the executable for command-line tools.
/// (This code runs from a shared library, so it is the main bundle that
/// holds them, not the code's own location.)
extension Foundation.Bundle {
    static let module: Bundle = .main
}

enum MathSupport {
    private static var fonts: [CGFloat: MTFont] = [:]
    private static let lock = NSLock()

    /// Typesets LaTeX; nil if it does not parse (callers show the source).
    static func typeset(_ latex: String, display: Bool, size: CGFloat) -> MTMathListDisplay? {
        guard let font = font(size: size), let list = parse(latex) else { return nil }
        return MTTypesetter.createLineForMathList(list, font: font, style: display ? .display : .text)
    }

    /// Parses LaTeX after rewriting KaTeX-only syntax; nil if it does not parse.
    static func parse(_ latex: String) -> MTMathList? {
        MathMacros.register()
        var error: NSError?
        guard let list = MTMathListBuilder.build(fromString: MathMacros.expand(latex), error: &error),
              error == nil else { return nil }
        return list
    }

    /// Loads the math font ahead of time (registering it takes ~15 ms).
    static func warmUp() {
        MathMacros.register()
        _ = font(size: NativeTheme.bodySize)
    }

    private static func font(size: CGFloat) -> MTFont? {
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[size] { return font }
        let font = MTFontManager.fontManager.latinModernFont(withSize: size)
        fonts[size] = font
        return font
    }
}

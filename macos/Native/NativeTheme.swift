import AppKit

/// Colours, fonts and metrics of the native renderer — the same GitHub-like
/// palette as `core/assets/style.css`. Colours are dynamic: they follow the
/// view's appearance, so switching light/dark mode needs no re-render.
enum NativeTheme {
    static let fg = dynamic(0x1f2328, 0xf0f6fc)
    static let muted = dynamic(0x59636e, 0x9198a1)
    static let background = dynamic(0xffffff, 0x1e1e1e)
    static let subtle = dynamic(0xf6f8fa, 0x262626)
    static let border = dynamic(0xd1d9e0, 0x3d444d)
    static let borderMuted = dynamic(0xd1d9e0, 0x3d444d, lightAlpha: 0.7, darkAlpha: 0.7)
    static let link = dynamic(0x0969da, 0x4493f8)
    static let codeBackground = dynamic(0x818b98, 0x656c76, lightAlpha: 0.12, darkAlpha: 0.2)
    static let mark = dynamic(0xfff8c5, 0xbb8009, lightAlpha: 1, darkAlpha: 0.15)
    static let alerts = [
        dynamic(0x0969da, 0x4493f8), // note
        dynamic(0x1a7f37, 0x3fb950), // tip
        dynamic(0x8250df, 0xab7df8), // important
        dynamic(0x9a6700, 0xd29922), // warning
        dynamic(0xd1242f, 0xf85149), // caution
    ]

    // Metrics (points), matching the CSS at 15 px.
    static let bodySize: CGFloat = 15
    static let maxContentWidth: CGFloat = 900
    static let paragraphSpacing: CGFloat = 14
    static let lineHeightMultiple: CGFloat = 1.18
    static let listIndent: CGFloat = 24
    static let headingSizes: [CGFloat] = [30, 22.5, 18.75, 15, 13.1, 12.75]

    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let key = FontKey(size: size, bold: bold, italic: italic, mono: false)
        lock.lock()
        defer { lock.unlock() }
        if let font = fontCache[key] { return font }
        var font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if italic {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
        }
        fontCache[key] = font
        return font
    }

    static func mono(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let key = FontKey(size: size, bold: bold, italic: italic, mono: true)
        lock.lock()
        defer { lock.unlock() }
        if let font = fontCache[key] { return font }
        var font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if italic {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
        }
        fontCache[key] = font
        return font
    }

    /// A colour that is `light` in light mode and `dark` in dark mode.
    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? rgb(dark, alpha: darkAlpha) : rgb(light, alpha: lightAlpha)
        }
    }

    /// Token colours arrive as RGBA pairs; reuse one dynamic colour per pair.
    static func tokenColor(light: UInt32, dark: UInt32) -> NSColor {
        let key = UInt64(light) << 32 | UInt64(dark)
        lock.lock()
        defer { lock.unlock() }
        if let color = tokenCache[key] { return color }
        let color = NSColor(name: nil) { appearance in
            rgba(appearance.isDark ? dark : light)
        }
        tokenCache[key] = color
        return color
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    static func rgba(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 24) / 255, green: CGFloat((value >> 16) & 0xff) / 255,
                blue: CGFloat((value >> 8) & 0xff) / 255, alpha: CGFloat(value & 0xff) / 255)
    }

    /// Parses "#rgb" or "#rrggbb".
    static func hex(_ string: String) -> NSColor {
        var s = string.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        return rgb(UInt32(s, radix: 16) ?? 0x007ec6)
    }

    private struct FontKey: Hashable {
        let size: CGFloat
        let bold: Bool
        let italic: Bool
        let mono: Bool
    }

    /// The renderer may build on a background thread while the main thread draws.
    private static let lock = NSLock()
    private static var fontCache: [FontKey: NSFont] = [:]
    private static var tokenCache: [UInt64: NSColor] = [:]
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua,
                         .accessibilityHighContrastAqua]).map {
            [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0)
        } ?? false
    }
}

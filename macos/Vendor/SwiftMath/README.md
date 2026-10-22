# Vendored SwiftMath

[SwiftMath](https://github.com/mgriebling/SwiftMath) (MIT, see `LICENSE`) renders
LaTeX math with CoreText. Sources are unmodified, from commit `1d2c90827e9c3908269d810d055fb03b7da5fd53`.

Only the Latin Modern Math font is kept (`mathFonts.bundle`, GUST Font License).
`macos/Native/MathSupport.swift` provides the `Bundle.module` that the sources
expect from Swift Package Manager.

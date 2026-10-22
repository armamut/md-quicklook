# Vendored SwiftMath

[SwiftMath](https://github.com/mgriebling/SwiftMath) (MIT, see `LICENSE`) renders
LaTeX math with CoreText. Sources are from commit `1d2c90827e9c3908269d810d055fb03b7da5fd53`,
with local fixes, marked `md-quicklook:` in the source:

- `MTMathListBuilder.swift`: `\begin{matrix*}[r]` reads its alignment option
  (upstream only does so in a code path that is never called).
- `Tokenization/MTAtomTokenizer.swift`: explicit spaces (`\quad`, `\;`, `\!`)
  get their own width instead of a fixed 3mu, and neighbouring atoms get TeX's
  spacing (`\sin x`, `a, b`), which upstream applies only to binary operators
  and relations.
- `MTDecoration.swift` (new): stretchy braces, brackets, arrows and tildes over
  or under a formula, drawn as paths; hooked in by `MTMathListBuilder.swift`
  (parsing), `MTMathList.swift` (copying) and `MTTypesetter.swift` (layout).
- `MTMathAtomFactory.swift`: the accents `\mathring`, `\dddot`, `\ddddot` and
  `\widecheck` (the last was declared wide but missing from the table).

Only the Latin Modern Math font is kept (`mathFonts.bundle`, GUST Font License).
`macos/Native/MathSupport.swift` provides the `Bundle.module` that the sources
expect from Swift Package Manager; `macos/Native/MathMacros.swift` adds KaTeX
symbols, aliases and environments on top, without touching these sources.

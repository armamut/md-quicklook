# Math support

MD QuickLook typesets LaTeX math natively, without a web view or JavaScript.
This page describes what works, what does not, and how to check a document.

## Writing math

| Syntax | Result |
|---|---|
| `$x^2$` | inline formula |
| `$$ ... $$` | display formula (centred when on its own lines) |
| ` ```math ` code block | display formula |

## How it works

Formulas are laid out by [SwiftMath](https://github.com/mgriebling/SwiftMath)
(vendored in `macos/Vendor/SwiftMath`) with the Latin Modern Math font, the
OpenType version of TeX's own fonts. On top of it, `macos/Native/MathMacros.swift`
adds what KaTeX users expect:

- **About 300 extra symbols** from AMS and KaTeX (`\therefore`, `\leqq`,
  `\twoheadrightarrow`, `\checkmark`, `\varGamma`, `\Alpha`, …).
- **Aliases**: `\R`, `\N`, `\Z`, `\dots`, `\argmax`, `\gt`, `\lvert`, `\bold`,
  `\Bbb`, `\operatornamewithlimits`, …
- **Macros with arguments**: `\dbinom`, `\tbinom`, `\tag`, `\href`, `\overset`,
  `\underset`, `\stackrel`, the `\xrightarrow` family, text accents (`\'e`, `\"o`),
  `\not=`.
- **Environments**: `align`, `equation`, `alignat`, `gather`, `multline`, `array`,
  `rcases`, besides SwiftMath's own `aligned`, `cases`, `split` and the
  `matrix` family.
- **Braces, brackets and arrows over or under a formula**, drawn as vector
  paths that stretch to any width, as KaTeX does: `\overbrace`, `\underbrace`
  (with `^`/`_` labels above or below), `\overbracket`, `\underbracket`,
  `\overgroup`, `\undergroup`, `\overlinesegment`, `\underlinesegment`,
  `\Overrightarrow`, `\overleftharpoon`, `\overrightharpoon`, `\underleftarrow`,
  `\underrightarrow`, `\underleftrightarrow`, `\utilde`; and the accents
  `\mathring`, `\dddot`, `\ddddot`, `\widecheck`, `\underbar`.

A formula that cannot be typeset is shown as red source, as KaTeX does, so
nothing is lost.

## Coverage

Of the 971 formulas in KaTeX's own list of supported functions
([`tests/math/katex-supported.md`](../tests/math/katex-supported.md)),
**912 (93.9%)** typeset. Every formula in
[`examples/math.md`](../examples/math.md) must typeset; CI checks this.

[`examples/math-unsupported.md`](../examples/math-unsupported.md) lists the rest.
Open it in Quick Look to see each one as the preview draws it.

## Not supported yet

| What | Commands |
|---|---|
| Boxes and strike-outs | `\boxed`, `\fcolorbox`, `\cancel`, `\bcancel`, `\xcancel`, `\sout` |
| Rules and generalized fractions | `\rule`, `\genfrac`, `\above` |
| User macros | `\def`, `\gdef`, `\newcommand` |
| Commutative diagrams | `\begin{CD}` |
| Braket notation (capitalized) | `\Bra`, `\Ket`, `\Braket`, `\Set` (`\bra`, `\ket`, `\braket` work) |
| Symbols missing from Latin Modern Math | `\Finv`, `\Game`, `\circledS`, `\blacklozenge`, `\pitchfork`, `\lBrace`, `\rBrace`, `\minuso`, `\nleqq`, `\ngeqq`, `\lvertneqq`, `\gvertneqq`, `\nsubseteqq`, `\nsupseteqq` |
| Web and TeX internals | `\htmlClass`, `\htmlId`, `\htmlStyle`, `\htmlData`, `\includegraphics`, `\char`, `\verb`, `\reflectbox`, `\phase`, `\angl` |

Known layout differences from KaTeX:

- `\tag` puts the label after the equation instead of at the right margin.
- `array` column lines (`|`) are not drawn, and all columns share one alignment.
- A leading minus inside `cases` gets binary-operator spacing (`- x`).

## Checking a document

```sh
make snapshot-tool                       # builds build/math-coverage
build/math-coverage notes.md --list      # every formula that fails, and why
make math-coverage                       # the CI check on examples/
make math-report                         # regenerate examples/math-unsupported.md
```

If you hit a formula that should work, please open an issue with the LaTeX source.

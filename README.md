<p align="center"><img src="docs/icon.png" width="128" alt="MD QuickLook icon"></p>

<h1 align="center">MD QuickLook</h1>

<p align="center">
  A fast, native Quick Look extension for Markdown on macOS.<br>
  Press <kbd>Space</kbd> on a <code>.md</code> file in Finder and read it — rendered, highlighted, in light or dark.
</p>

<p align="center">
  <a href="https://github.com/armamut/md-quicklook/actions/workflows/ci.yml"><img src="https://github.com/armamut/md-quicklook/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-12%2B-lightgrey.svg" alt="macOS 12+">
</p>

<p align="center">
  <img src="docs/screenshot-light.png" width="49%" alt="Light theme preview">
  <img src="docs/screenshot-dark.png" width="49%" alt="Dark theme preview">
</p>

## Features

- **Works everywhere Quick Look does** — the space-bar panel, Finder's preview pane and the column view, using the full width available.
- **GitHub Flavored Markdown** — tables, task lists, strikethrough, autolinks, footnotes, `> [!NOTE]` alerts, heading anchors, emoji `:shortcodes:`, ==highlights==, front matter (shown as a table).
- **Syntax highlighting** for 220 languages, GitHub-style colours in light mode and One Half Dark in dark mode.
- **Math** — `$inline$`, `$$display$$` and ` ```math ` blocks, typeset natively with TeX-quality layout (fractions, integrals, matrices, aligned equations); [what is supported](docs/math.md).
- **Mermaid diagrams** — ` ```mermaid ` blocks (flowchart, sequence, class, state, ER, pie, mind map, git graph and more) are drawn natively in light and dark, in the background so the document still opens instantly; see [examples/diagrams.md](examples/diagrams.md). Diagrams that cannot be drawn stay visible as source. Rendering comes from [mermaid-rs-renderer](https://github.com/1jehuang/mermaid-rs-renderer), which is young: some layouts differ from mermaid.js (Gantt dates and timelines with several events per period are known gaps).
- **Local images** next to the file are embedded (`![](images/shot.png)`, `<img src="logo.svg">`).
- **Badges without the network** — static shields.io badges are drawn locally in their real colours; other remote images show their description. Loading remote images can be turned on in the app.
- **Light and dark** follow the system appearance.
- **Clickable links** — headings scroll, links to other Markdown files open them.
- **Finder thumbnails** — icons show a miniature of the rendered page.
- **Private by design** — no web engine, no JavaScript, no network requests, sandboxed.

## Fast

There is no web engine. A Rust core ([comrak](https://github.com/kivikakk/comrak) + [syntect](https://github.com/trishume/syntect)) parses the Markdown into a compact layout, and the Swift extension draws it with TextKit, the text system behind every Mac app. Math is typeset with [SwiftMath](https://github.com/mgriebling/SwiftMath), extended with KaTeX symbols, aliases and environments; see [docs/math.md](docs/math.md) for what is supported.

| | Native (default) | WebKit (optional) |
|---|---|---|
| Typical README, request → ready | **~30 ms** | ~200 ms |
| 900 KB changelog, first screen | **~60 ms** | ~300 ms |

- **Long documents** show their first screenful immediately; the rest is laid out in the background.
- **Syntax highlighting** grammars are pre-processed at build time so their regexes compile 3–5× faster, and common languages are compiled on all cores while macOS launches the extension.
- **Light and dark** colours, including code, switch instantly with the system appearance.

## Install

**Homebrew:**

```sh
brew install --cask armamut/tap/md-quicklook
```

**One line** (downloads the latest release into `/Applications`):

```sh
curl -fsSL https://raw.githubusercontent.com/armamut/md-quicklook/main/scripts/install.sh | bash
```

**Manually:** download `MD-QuickLook-x.y.z.zip` from [Releases](https://github.com/armamut/md-quicklook/releases), move *MD QuickLook.app* to `/Applications` and open it once. The app is not notarized, so remove the quarantine flag first:

```sh
xattr -dr com.apple.quarantine "/Applications/MD QuickLook.app"
```

**From source** (needs Rust and the Xcode Command Line Tools — full Xcode is not required):

```sh
git clone https://github.com/armamut/md-quicklook.git
cd md-quicklook
make install
```

Opening the app registers the extensions; after that it can be closed. If previews do not appear, check that *MD QuickLook* is enabled in **System Settings ▸ General ▸ Login Items & Extensions ▸ Quick Look**, then click **Reset Quick Look** in the app.

## Updates

Open the app and click **Check Now** (or *MD QuickLook ▸ Check for Updates…*). When a newer release exists, **Install and Relaunch** downloads it from this repository's releases, verifies it and replaces the app in place. With *Check for updates automatically* on (the default), the app also looks once a day when you open it. Only the app does this: the Quick Look extensions never use the network. Running the one-line installer again also updates.

## Uninstall

```sh
make uninstall    # or drag the app to the Trash
```

## How it works

```
core/      Rust: Markdown → native layout or HTML (static library + `mdql` CLI)
macos/     Swift: host app (with the updater), preview and thumbnail extensions,
           native renderer (macos/Native), vendored SwiftMath (macos/Vendor)
scripts/   build.sh (Xcode-free build), install.sh, icon and screenshot helpers
```

The extensions read the file and call the Rust core through a small C API (`core/include/mdql.h`). `mdql_render_native` returns a binary layout — text plus blocks, paragraphs and styled runs — that `macos/Native` turns into an attributed string with text blocks (quotes, alerts, code), tables and attachment cells (images, formulas, diagrams, badges, checkboxes); `mdql_render_mermaid` draws a diagram. Both extensions share one library with all this code (`Contents/Frameworks/libMDQuickLookCore.dylib`); their own executables only start it (`macos/Launchers`). `mdql_render_html` produces a self-contained HTML page for the optional WebKit renderer, which can be chosen in the app.

Useful while developing:

```sh
make test                                   # Rust tests
make bench                                  # render timing
make snapshot-tool && build/native-snapshot README.md out.png dark   # native render → PNG
build/math-coverage notes.md --list         # formulas that do not typeset
core/target/release/mdql README.md -o out.html --theme dark
log stream --predicate 'subsystem == "io.github.armamut.mdquicklook"'   # extension timings
```

## Credits

Built by [armamut](https://github.com/armamut) together with [Claude Code](https://claude.com/claude-code) (Claude Opus 5.5 by Anthropic).
Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE)

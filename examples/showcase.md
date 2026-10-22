---
title: MD QuickLook showcase
author: armamut
tags: [markdown, quicklook]
---

# MD QuickLook

A **fast** Quick Look previewer for _Markdown_ with ~~no~~ zero JavaScript. Visit https://github.com/armamut/md-quicklook :rocket:

<p align="center"><img src="images/logo.svg" width="64" alt="logo"></p>

## Text

Inline `code`, <kbd>⌘</kbd> + <kbd>Space</kbd>, ==highlighted==, footnote[^1] and an [internal link](#tables).

> Blockquotes look like this.
> They can span lines.

> [!NOTE]
> GitHub-style alerts are supported.

> [!WARNING]
> Even warnings.

## Lists

- Item one
- Item two
  - Nested
    1. Ordered
    2. Still ordered
- [x] Done task
- [ ] Open task

## Tables

| Language | Speed | Notes |
|:---------|------:|:-----:|
| Rust     | 🚀    | core  |
| Swift    | ⚡️    | glue  |

## Code

```rust
fn main() {
    // Say hello
    let name = "world";
    println!("Hello, {name}!");
}
```

```typescript
interface User { id: number; name: string }
const greet = (u: User): string => `Hi ${u.name}`;
```

```swift
import QuickLookUI
final class PreviewProvider: QLPreviewProvider {}
```

```sh
cargo build --release && make install
```

## Math

Inline math $e^{i\pi} + 1 = 0$ and a block:

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
$$

```math
\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}
```

## Images

![Local swatch](images/swatch.png)
![Remote badge](https://img.shields.io/badge/remote-blocked-red)

<details>
<summary>Click to expand</summary>

Hidden content with **markdown**.

</details>

<script>alert("never runs")</script>

---

[^1]: Footnotes are rendered at the bottom.

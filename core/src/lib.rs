//! mdql — the rendering core of MD QuickLook.
//!
//! Turns a Markdown document into a single, self-contained HTML page:
//! GitHub Flavored Markdown, syntax-highlighted code, LaTeX math as native
//! MathML, embedded local images and light/dark styling. No JavaScript and
//! no network access are needed to display the result.

use std::borrow::Cow;
use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use base64::Engine as _;
use comrak::nodes::{AstNode, NodeHtmlBlock, NodeValue};
use comrak::{Arena, Options, format_html, parse_document};
use syntect::html::{ClassStyle, ClassedHTMLGenerator};
use syntect::parsing::{SyntaxReference, SyntaxSet};
use syntect::util::LinesWithEndings;

mod ffi;

const BASE_CSS: &str = include_str!("../assets/style.css");
const DARK_CSS: &str = include_str!("../assets/dark.css");
const HIGHLIGHT_LIGHT_CSS: &str = include_str!("../assets/highlight-light.css");
const HIGHLIGHT_DARK_CSS: &str = include_str!("../assets/highlight-dark.css");
const MATH_CSS: &str = include_str!("../assets/math.css");

/// CSS class prefix used for syntax-highlighting spans.
pub const HIGHLIGHT_PREFIX: &str = "hl-";

/// Code blocks larger than this are shown without highlighting.
const MAX_HIGHLIGHT_BLOCK: usize = 256 * 1024;
/// Documents larger than this are shown without any highlighting.
const MAX_HIGHLIGHT_DOCUMENT: usize = 8 * 1024 * 1024;
/// Local images larger than this are not embedded.
const MAX_IMAGE_BYTES: u64 = 25 * 1024 * 1024;
/// Upper bound for all embedded images of one document.
const MAX_TOTAL_IMAGE_BYTES: u64 = 100 * 1024 * 1024;

/// Colour theme of the rendered page.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Theme {
    /// Follow `prefers-color-scheme`.
    #[default]
    Auto,
    Light,
    Dark,
}

/// Options controlling how a document is rendered.
#[derive(Debug, Clone, Default)]
pub struct RenderOptions {
    /// Directory used to resolve relative image paths (usually the
    /// directory containing the Markdown file). `None` disables embedding.
    pub base_dir: Option<PathBuf>,
    /// Text for the `<title>` element.
    pub title: Option<String>,
    /// Colour theme. Hosts that know the system appearance should pass it
    /// explicitly: some web views do not report it to `prefers-color-scheme`.
    pub theme: Theme,
    /// Let the page fetch `http(s)` images such as README badges. Off by
    /// default: previewing a file should not tell anyone it was opened.
    /// When off, remote images are replaced by their alt text.
    pub remote_images: bool,
}

/// Decodes raw file bytes into text, honouring UTF-8/UTF-16 byte order marks
/// and replacing invalid sequences instead of failing.
pub fn decode_text(bytes: &[u8]) -> Cow<'_, str> {
    match bytes {
        [0xEF, 0xBB, 0xBF, rest @ ..] => String::from_utf8_lossy(rest),
        [0xFF, 0xFE, rest @ ..] => Cow::Owned(decode_utf16(rest, u16::from_le_bytes)),
        [0xFE, 0xFF, rest @ ..] => Cow::Owned(decode_utf16(rest, u16::from_be_bytes)),
        _ => String::from_utf8_lossy(bytes),
    }
}

fn decode_utf16(bytes: &[u8], f: fn([u8; 2]) -> u16) -> String {
    let units = bytes.chunks_exact(2).map(|c| f([c[0], c[1]]));
    char::decode_utf16(units)
        .map(|r| r.unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect()
}

fn comrak_options() -> Options<'static> {
    let mut o = Options::default();
    let e = &mut o.extension;
    e.strikethrough = true;
    e.table = true;
    e.autolink = true;
    e.tasklist = true;
    e.footnotes = true;
    e.inline_footnotes = true;
    e.header_id_prefix = Some(String::new());
    e.front_matter_delimiter = Some("---".into());
    e.alerts = true;
    e.math_dollars = true;
    e.math_code = true;
    e.shortcodes = true;
    e.wikilinks_title_after_pipe = true;
    e.highlight = true;
    o.parse.relaxed_tasklist_matching = true;
    o.parse.relaxed_autolinks = true;
    o.render.r#unsafe = true;
    o.render.github_pre_lang = false;
    o.render.tasklist_classes = true;
    o.render.figure_with_caption = false;
    o
}

/// Renders Markdown to an HTML fragment (the document body only).
pub fn render_fragment(markdown: &str, opts: &RenderOptions) -> String {
    render_body(markdown, opts).0
}

/// Returns the body HTML and whether it contains math.
fn render_body(markdown: &str, opts: &RenderOptions) -> (String, bool) {
    let options = comrak_options();
    let arena = Arena::new();
    let root = parse_document(&arena, markdown, &options);

    let mut ctx = Transform {
        base_dir: opts.base_dir.as_deref(),
        image_budget: MAX_TOTAL_IMAGE_BYTES,
        image_cache: HashMap::new(),
        has_math: false,
        front_matter: None,
        remote_images: opts.remote_images,
    };
    // Remote images replaced by placeholders lose their (alt text) children,
    // after the walk: the tree must not change while it is being traversed.
    let emptied: Vec<_> = root.descendants().filter(|node| ctx.visit(node)).collect();
    for node in emptied {
        let children: Vec<_> = node.children().collect();
        children.into_iter().for_each(|c| c.detach());
    }

    if markdown.len() <= MAX_HIGHLIGHT_DOCUMENT {
        highlight_code_blocks(root);
    }

    let mut out = String::with_capacity(markdown.len() * 2 + 256);
    if let Some(fm) = ctx.front_matter.take() {
        render_front_matter(&mut out, &fm);
    }
    // Writing into a String cannot fail.
    let _ = format_html(root, &options, &mut out);
    (out, ctx.has_math)
}

/// Renders Markdown to a complete, self-contained HTML document.
pub fn render_document(markdown: &str, opts: &RenderOptions) -> String {
    let (body, has_math) = render_body(markdown, opts);
    let title = opts.title.as_deref().unwrap_or("Markdown");

    let color_scheme = match opts.theme {
        Theme::Auto => "light dark",
        Theme::Light => "light",
        Theme::Dark => "dark",
    };
    let mut html = String::with_capacity(body.len() + 24 * 1024);
    html.push_str(
        "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:",
    );
    if opts.remote_images {
        html.push_str(" https: http:");
    }
    html.push_str(
        "; media-src data:; style-src 'unsafe-inline'; font-src data:\">\
         <meta name=\"color-scheme\" content=\"",
    );
    html.push_str(color_scheme);
    html.push_str("\"><title>");
    escape_html(&mut html, title);
    html.push_str("</title><style>:root{color-scheme:");
    html.push_str(color_scheme);
    html.push_str("}\n");
    html.push_str(BASE_CSS);
    match opts.theme {
        Theme::Light => html.push_str(HIGHLIGHT_LIGHT_CSS),
        Theme::Dark => {
            html.push_str(DARK_CSS);
            html.push_str(HIGHLIGHT_DARK_CSS);
        }
        Theme::Auto => {
            for (query, css) in [("", DARK_CSS), ("not ", HIGHLIGHT_LIGHT_CSS), ("", HIGHLIGHT_DARK_CSS)] {
                html.push_str("@media ");
                html.push_str(query);
                html.push_str("(prefers-color-scheme: dark) {\n");
                html.push_str(css);
                html.push_str("}\n");
            }
        }
    }
    html.push_str("</style>");
    if has_math {
        // Separate sheet: it starts with an @namespace rule.
        html.push_str("<style>");
        html.push_str(MATH_CSS);
        html.push_str("</style>");
    }
    html.push_str("</head><body><article class=\"markdown-body\">\n");
    html.push_str(&body);
    html.push_str("</article></body></html>\n");
    html
}

// ---------------------------------------------------------------------------
// AST transformation
// ---------------------------------------------------------------------------

struct Transform<'p> {
    base_dir: Option<&'p Path>,
    image_budget: u64,
    image_cache: HashMap<String, Option<String>>,
    has_math: bool,
    front_matter: Option<String>,
    remote_images: bool,
}

impl Transform<'_> {
    /// Rewrites one node; returns whether its children must be removed.
    fn visit<'a>(&mut self, node: &'a AstNode<'a>) -> bool {
        let mut data = node.data_mut();
        let mut detach_children = false;
        let replacement = match &mut data.value {
            NodeValue::FrontMatter(raw) => {
                self.front_matter = Some(raw.clone());
                None
            }
            NodeValue::Math(m) => {
                self.has_math = true;
                Some(NodeValue::HtmlInline(latex_to_mathml(&m.literal, m.display_math)))
            }
            NodeValue::CodeBlock(cb) if first_word(&cb.info).eq_ignore_ascii_case("math") => {
                self.has_math = true;
                Some(NodeValue::HtmlBlock(NodeHtmlBlock {
                    block_type: 6,
                    literal: format!("<div class=\"math-block\">{}</div>\n", latex_to_mathml(&cb.literal, true)),
                }))
            }
            NodeValue::Image(link) if is_remote(&link.url) => {
                if self.remote_images {
                    None
                } else {
                    // The alt text lives in the image's child nodes.
                    detach_children = true;
                    Some(NodeValue::HtmlInline(remote_image_placeholder(&link.url, &alt_text(node))))
                }
            }
            NodeValue::Image(link) => {
                if let Some(uri) = self.embed_image(&link.url) {
                    link.url = uri;
                }
                None
            }
            NodeValue::HtmlInline(html) => {
                *html = self.sanitize_html(html);
                None
            }
            NodeValue::HtmlBlock(block) => {
                block.literal = self.sanitize_html(&block.literal);
                None
            }
            _ => None,
        };
        if let Some(value) = replacement {
            data.value = value;
        }
        detach_children
    }

    /// Applies the GFM tag filter, embeds local images referenced by raw
    /// `<img src>` tags and, unless allowed, replaces remote ones.
    fn sanitize_html(&mut self, html: &str) -> String {
        let filtered = tag_filter(html);
        let mut out = String::with_capacity(filtered.len());
        let mut rest: &str = &filtered;
        while let Some(start) = find_ascii_ci(rest, "<img") {
            let tag_end = rest[start..].find('>').map_or(rest.len(), |i| start + i + 1);
            out.push_str(&rest[..start]);
            let tag = &rest[start..tag_end];
            match attribute(tag, "src") {
                Some((vs, ve)) if !self.remote_images && is_remote(&decode_entities(&tag[vs..ve])) => {
                    let alt = attribute(tag, "alt").map(|(a, b)| decode_entities(&tag[a..b]).into_owned());
                    out.push_str(&remote_image_placeholder(&decode_entities(&tag[vs..ve]), alt.as_deref().unwrap_or("")));
                }
                Some((vs, ve)) => {
                    let value = decode_entities(&tag[vs..ve]);
                    match self.embed_image(&value) {
                        Some(uri) => {
                            out.push_str(&tag[..vs]);
                            out.push_str(&uri);
                            out.push_str(&tag[ve..]);
                        }
                        None => out.push_str(tag),
                    }
                }
                None => out.push_str(tag),
            }
            rest = &rest[tag_end..];
        }
        out.push_str(rest);
        out
    }

    /// Returns a `data:` URI for a local image, or `None` to keep the URL.
    fn embed_image(&mut self, url: &str) -> Option<String> {
        let base = self.base_dir?;
        if let Some(cached) = self.image_cache.get(url) {
            return cached.clone();
        }
        let result = local_image_path(base, url).and_then(|path| {
            let meta = std::fs::metadata(&path).ok()?;
            if !meta.is_file() || meta.len() > MAX_IMAGE_BYTES || meta.len() > self.image_budget {
                return None;
            }
            let mime = image_mime(&path)?;
            let bytes = std::fs::read(&path).ok()?;
            self.image_budget -= bytes.len() as u64;
            let mut uri = String::with_capacity(bytes.len() * 4 / 3 + 32);
            uri.push_str("data:");
            uri.push_str(mime);
            uri.push_str(";base64,");
            base64::engine::general_purpose::STANDARD.encode_string(&bytes, &mut uri);
            Some(uri)
        });
        self.image_cache.insert(url.to_owned(), result.clone());
        result
    }
}

fn first_word(s: &str) -> &str {
    s.split(|c: char| c.is_whitespace() || c == '{' || c == ',').next().unwrap_or("")
}

/// Resolves an image URL to a local file path, if it refers to one.
fn local_image_path(base: &Path, url: &str) -> Option<PathBuf> {
    let url = url.trim();
    let lower = url.get(..8).unwrap_or(url).to_ascii_lowercase();
    if url.is_empty() || url.starts_with('#') || url.starts_with("//") {
        return None;
    }
    let path_part = if let Some(rest) = lower.strip_prefix("file://").map(|_| &url[7..]) {
        rest.strip_prefix("localhost").unwrap_or(rest)
    } else if url.contains(':') && !url.starts_with('/') && !url.starts_with('.') {
        // http:, https:, data:, mailto: and other schemes.
        let scheme = url.split(':').next().unwrap_or("");
        if scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c)) {
            return None;
        }
        url
    } else {
        url
    };
    let path_part = path_part.split(['?', '#']).next().unwrap_or("");
    let decoded = percent_decode(path_part);
    let decoded = expand_tilde(&decoded);
    let p = Path::new(decoded.as_ref());
    Some(if p.is_absolute() { p.to_path_buf() } else { base.join(p) })
}

fn expand_tilde(p: &str) -> Cow<'_, str> {
    match (p.strip_prefix("~/"), std::env::var("HOME")) {
        (Some(rest), Ok(home)) => Cow::Owned(format!("{home}/{rest}")),
        _ => Cow::Borrowed(p),
    }
}

fn percent_decode(s: &str) -> Cow<'_, str> {
    if !s.contains('%') {
        return Cow::Borrowed(s);
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(h << 4 | l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    Cow::Owned(String::from_utf8_lossy(&out).into_owned())
}

fn hex(b: u8) -> Option<u8> {
    (b as char).to_digit(16).map(|d| d as u8)
}

fn image_mime(path: &Path) -> Option<&'static str> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" | "jpe" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "bmp" => "image/bmp",
        "ico" => "image/x-icon",
        "tif" | "tiff" => "image/tiff",
        "avif" => "image/avif",
        "heic" => "image/heic",
        "heif" => "image/heif",
        "apng" => "image/apng",
        _ => return None,
    })
}

/// Case-insensitive ASCII substring search.
fn find_ascii_ci(haystack: &str, needle: &str) -> Option<usize> {
    let (h, n) = (haystack.as_bytes(), needle.as_bytes());
    if n.len() > h.len() {
        return None;
    }
    (0..=h.len() - n.len()).find(|&i| h[i..i + n.len()].eq_ignore_ascii_case(n))
}

/// Finds the byte range of an attribute's value inside a tag such as `<img ...>`.
fn attribute(tag: &str, name: &str) -> Option<(usize, usize)> {
    let b = tag.as_bytes();
    let mut i = 1; // skip "<"
    while let Some(off) = find_ascii_ci(&tag[i..], name) {
        let at = i + off;
        let preceded_by_space = b.get(at.wrapping_sub(1)).is_some_and(|c| c.is_ascii_whitespace());
        let mut j = at + name.len();
        while b.get(j).is_some_and(|c| c.is_ascii_whitespace()) {
            j += 1;
        }
        if preceded_by_space && b.get(j) == Some(&b'=') {
            j += 1;
            while b.get(j).is_some_and(|c| c.is_ascii_whitespace()) {
                j += 1;
            }
            return match b.get(j) {
                Some(&q @ (b'"' | b'\'')) => {
                    let end = tag[j + 1..].find(q as char)? + j + 1;
                    Some((j + 1, end))
                }
                Some(_) => {
                    let end = tag[j..]
                        .find(|c: char| c.is_ascii_whitespace() || c == '>' || c == '/')
                        .map_or(tag.len(), |e| e + j);
                    Some((j, end))
                }
                None => None,
            };
        }
        i = at + name.len();
    }
    None
}

/// Decodes a static shields.io badge URL, `…/badge/<label>-<message>-<color>`,
/// whose text and colour can be drawn without fetching anything.
fn shields_static_badge(url: &str) -> Option<(Option<String>, String, String)> {
    let rest = url.split_once("img.shields.io/badge/")?.1;
    let spec = rest.split(['?', '#']).next()?;
    let spec = spec.strip_suffix(".svg").or_else(|| spec.strip_suffix(".png")).unwrap_or(spec);
    // "--" is a literal dash, "__" a literal underscore, "_" a space.
    let mut parts = vec![String::new()];
    let mut chars = spec.chars().peekable();
    while let Some(c) = chars.next() {
        match (c, chars.peek()) {
            ('-', Some('-')) | ('_', Some('_')) => {
                parts.last_mut()?.push(c);
                chars.next();
            }
            ('-', _) => parts.push(String::new()),
            ('_', _) => parts.last_mut()?.push(' '),
            _ => parts.last_mut()?.push(c),
        }
    }
    let decode = |s: &str| percent_decode(s).into_owned();
    match parts.as_slice() {
        [label, message, color] => Some((Some(decode(label)).filter(|l| !l.is_empty()), decode(message), color.clone())),
        [message, color] => Some((None, decode(message), color.clone())),
        _ => None,
    }
}

fn badge_color(name: &str) -> String {
    let named = match name.to_ascii_lowercase().as_str() {
        "brightgreen" | "success" => "#44cc11",
        "green" => "#97ca00",
        "yellowgreen" => "#a4a61d",
        "yellow" => "#dfb317",
        "orange" | "important" => "#fe7d37",
        "red" | "critical" => "#e05d44",
        "blue" | "informational" => "#007ec6",
        "lightgrey" | "lightgray" | "inactive" => "#9f9f9f",
        "grey" | "gray" => "#555555",
        "black" => "#000000",
        "white" => "#ffffff",
        "pink" => "#ff69b4",
        "purple" => "#9f00e0",
        _ => "",
    };
    if !named.is_empty() {
        return named.to_owned();
    }
    let hex = name.trim_start_matches('#');
    if matches!(hex.len(), 3 | 6) && hex.chars().all(|c| c.is_ascii_hexdigit()) {
        format!("#{hex}")
    } else {
        "#007ec6".to_owned()
    }
}

fn format_badge(url: &str, label: Option<&str>, message: &str, color: &str) -> String {
    let mut out = String::from("<span class=\"remote-badge badge-static\" title=\"");
    escape_html(&mut out, url);
    out.push_str("\">");
    if let Some(label) = label {
        out.push_str("<span class=\"badge-label\">");
        escape_html(&mut out, label);
        out.push_str("</span>");
    }
    out.push_str("<span class=\"badge-message\" style=\"background:");
    out.push_str(&badge_color(color));
    out.push_str("\">");
    escape_html(&mut out, message);
    out.push_str("</span></span>");
    out
}

fn is_remote(url: &str) -> bool {
    let u = url.trim_start();
    let lower = u.get(..8).unwrap_or(u).to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://") || u.starts_with("//")
}

/// Concatenated text of an image node's children (its alt text).
fn alt_text<'a>(node: &'a AstNode<'a>) -> String {
    let mut alt = String::new();
    for n in node.descendants().skip(1) {
        match &n.data().value {
            NodeValue::Text(t) => alt.push_str(t),
            NodeValue::Code(c) => alt.push_str(&c.literal),
            _ => {}
        }
    }
    alt
}

/// What a remote image shows when it may not be loaded: badges (shields.io
/// and friends) become a badge-like pill, other images a small labelled box.
fn remote_image_placeholder(url: &str, alt: &str) -> String {
    let host = url
        .trim_start_matches(|c| c != '/')
        .trim_start_matches('/')
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("");
    let lower = url.to_ascii_lowercase();
    let badge = ["shields.io", "badgen.net", "badge.fury.io", "codecov.io", "coveralls.io", "travis-ci", "circleci.com"]
        .iter()
        .any(|h| lower.contains(h))
        || lower.contains("badge");
    if let Some((label, message, color)) = shields_static_badge(url) {
        return format_badge(url, label.as_deref(), &message, &color);
    }
    let mut out = String::with_capacity(alt.len() + url.len() + 96);
    out.push_str(if badge { "<span class=\"remote-badge\" title=\"" } else { "<span class=\"remote-image\" title=\"" });
    escape_html(&mut out, url);
    out.push_str("\">");
    let label = alt.trim();
    match (badge, label.is_empty()) {
        (true, false) => escape_html(&mut out, label),
        (true, true) => out.push_str("badge"),
        (false, _) => {
            out.push_str("<span class=\"remote-image-label\">");
            escape_html(&mut out, if label.is_empty() { "Remote image" } else { label });
            out.push_str("</span> <span class=\"remote-image-host\">");
            escape_html(&mut out, host);
            out.push_str("</span>");
        }
    }
    out.push_str("</span>");
    out
}

fn decode_entities(s: &str) -> Cow<'_, str> {
    if !s.contains('&') {
        return Cow::Borrowed(s);
    }
    Cow::Owned(
        s.replace("&amp;", "&")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&lt;", "<")
            .replace("&gt;", ">"),
    )
}

/// GitHub's "disallowed raw HTML" filter: neutralises tags that could run
/// scripts or break the page layout.
fn tag_filter(html: &str) -> Cow<'_, str> {
    const TAGS: [&str; 9] = [
        "title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "script", "plaintext",
    ];
    let b = html.as_bytes();
    let mut out: Option<String> = None;
    let mut last = 0;
    for (i, _) in html.match_indices('<') {
        let mut j = i + 1;
        if b.get(j) == Some(&b'/') {
            j += 1;
        }
        let hit = TAGS.iter().any(|t| {
            b.len() >= j + t.len()
                && b[j..j + t.len()].eq_ignore_ascii_case(t.as_bytes())
                && b.get(j + t.len()).is_none_or(|c| c.is_ascii_whitespace() || *c == b'>' || *c == b'/')
        });
        if hit {
            let o = out.get_or_insert_with(|| String::with_capacity(html.len() + 16));
            o.push_str(&html[last..i]);
            o.push_str("&lt;");
            last = i + 1;
        }
    }
    match out {
        Some(mut o) => {
            o.push_str(&html[last..]);
            Cow::Owned(o)
        }
        None => Cow::Borrowed(html),
    }
}

// ---------------------------------------------------------------------------
// Math
// ---------------------------------------------------------------------------

fn latex_to_mathml(latex: &str, display: bool) -> String {
    use pulldown_latex::config::DisplayMode;
    use pulldown_latex::{Parser, RenderConfig, Storage, push_mathml};

    let storage = Storage::new();
    let parser = Parser::new(latex, &storage);
    let config = RenderConfig {
        display_mode: if display { DisplayMode::Block } else { DisplayMode::Inline },
        annotation: Some(latex),
        ..RenderConfig::default()
    };
    let mut out = String::new();
    if push_mathml(&mut out, parser, config).is_err() {
        out.clear();
        out.push_str("<code class=\"math-error\">");
        escape_html(&mut out, latex);
        out.push_str("</code>");
    }
    out
}

// ---------------------------------------------------------------------------
// Front matter
// ---------------------------------------------------------------------------

fn render_front_matter(out: &mut String, raw: &str) {
    let body = raw
        .trim()
        .trim_start_matches("---")
        .trim_end_matches("---")
        .trim_end_matches("...")
        .trim_matches('\n');
    if body.trim().is_empty() {
        return;
    }
    // Flat `key: value` maps become a table; anything nested stays as YAML.
    let pairs: Option<Vec<(&str, &str)>> = body
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            if l.starts_with([' ', '\t', '-', '#']) {
                return None;
            }
            let (k, v) = l.split_once(':')?;
            Some((k.trim(), v.trim()))
        })
        .collect();
    out.push_str("<details class=\"front-matter\" open><summary>Front matter</summary>");
    match pairs {
        Some(pairs) if !pairs.is_empty() => {
            out.push_str("<table>");
            for (k, v) in pairs {
                out.push_str("<tr><th>");
                escape_html(out, k);
                out.push_str("</th><td>");
                escape_html(out, v.trim_matches(|c| c == '"' || c == '\''));
                out.push_str("</td></tr>");
            }
            out.push_str("</table>");
        }
        _ => {
            out.push_str("<pre><code>");
            escape_html(out, body);
            out.push_str("</code></pre>");
        }
    }
    out.push_str("</details>\n");
}

// ---------------------------------------------------------------------------
// Syntax highlighting
// ---------------------------------------------------------------------------

/// bat's syntax collection with Unicode classes pre-simplified for fast
/// regex compilation; see `examples/gen_syntaxes.rs`.
static SYNTAXES: LazyLock<SyntaxSet> = LazyLock::new(|| {
    syntect::dumps::from_uncompressed_data(include_bytes!("../assets/syntaxes.packdump"))
        .expect("embedded syntax pack is valid")
});

fn find_syntax<'s>(set: &'s SyntaxSet, lang: &str) -> Option<&'s SyntaxReference> {
    let lang = lang.trim().to_ascii_lowercase();
    let token = match lang.as_str() {
        "" | "text" | "txt" | "plain" | "plaintext" | "mermaid" | "output" => return None,
        "shell" | "sh" | "zsh" | "console" | "shell-session" | "shellsession" | "terminal" => "bash",
        "c++" => "cpp",
        "c#" | "csharp" | "cs" => "cs",
        "golang" => "go",
        "jsonc" | "json5" => "json",
        "make" => "makefile",
        "objective-c" | "objc" => "m",
        "objective-c++" | "objcpp" => "mm",
        "js" | "javascript" | "node" | "mjs" | "cjs" => "js",
        "ts" | "typescript" => "ts",
        "jsx" => "jsx",
        "tsx" => "tsx",
        "docker" => "dockerfile",
        "ps1" | "powershell" | "pwsh" => "ps1",
        "py3" | "python3" => "py",
        "rb" => "ruby",
        "kt" => "kotlin",
        "tf" | "hcl" | "terraform" => "tf",
        "vue" | "svelte" => "html",
        "proto" | "protobuf" => "proto",
        "patch" => "diff",
        "ini" | "cfg" | "conf" | "properties" => "ini",
        "zig" => "zig",
        other => other,
    };
    set.find_syntax_by_token(token)
        .or_else(|| set.find_syntax_by_extension(token))
        .or_else(|| set.find_syntax_by_name(token))
}

/// Replaces fenced code blocks with highlighted HTML.
///
/// Compiling a grammar's regexes the first time a language is used is the
/// only noticeable cost in rendering, so each distinct language is handled
/// on its own thread: a cold document costs about as much as its slowest
/// language rather than the sum of all of them.
fn highlight_code_blocks<'a>(root: &'a AstNode<'a>) {
    let set = &*SYNTAXES;
    // Nodes stay on this thread; only (syntax, code, info word) is shared.
    let mut nodes: Vec<&'a AstNode<'a>> = Vec::new();
    let mut jobs: Vec<(&SyntaxReference, String, String)> = Vec::new();
    for node in root.descendants() {
        if let NodeValue::CodeBlock(cb) = &node.data().value {
            let lang = first_word(&cb.info);
            if cb.literal.len() > MAX_HIGHLIGHT_BLOCK || lang.is_empty() {
                continue;
            }
            if let Some(syntax) = find_syntax(set, lang) {
                nodes.push(node);
                jobs.push((syntax, cb.literal.clone(), lang.to_owned()));
            }
        }
    }
    if jobs.is_empty() {
        return;
    }

    // Group job indices by language.
    let mut groups: Vec<(&str, Vec<usize>)> = Vec::new();
    for (i, (syntax, _, _)) in jobs.iter().enumerate() {
        match groups.iter_mut().find(|(name, _)| *name == syntax.name) {
            Some((_, v)) => v.push(i),
            None => groups.push((&syntax.name, vec![i])),
        }
    }

    let work = |indices: &[usize]| -> Vec<(usize, Option<String>)> {
        indices.iter().map(|&i| (i, highlight(set, jobs[i].0, &jobs[i].1))).collect()
    };
    let results: Vec<(usize, Option<String>)> = if groups.len() == 1 {
        work(&groups[0].1)
    } else {
        let threads = std::thread::available_parallelism().map_or(4, |n| n.get()).min(groups.len());
        let mut buckets: Vec<Vec<usize>> = vec![Vec::new(); threads];
        for (n, (_, indices)) in groups.iter().enumerate() {
            buckets[n % threads].extend_from_slice(indices);
        }
        std::thread::scope(|scope| {
            let handles: Vec<_> = buckets[1..].iter().map(|b| scope.spawn(|| work(b))).collect();
            let mut all = work(&buckets[0]);
            for h in handles {
                all.extend(h.join().unwrap_or_default());
            }
            all
        })
    };

    for (i, html) in results {
        let Some(html) = html else { continue };
        let lang = &jobs[i].2;
        let mut literal = String::with_capacity(html.len() + lang.len() + 48);
        literal.push_str("<pre><code class=\"language-");
        escape_html(&mut literal, lang);
        literal.push_str("\">");
        literal.push_str(&html);
        literal.push_str("</code></pre>\n");
        nodes[i].data_mut().value = NodeValue::HtmlBlock(NodeHtmlBlock { block_type: 6, literal });
    }
}

fn highlight(set: &SyntaxSet, syntax: &SyntaxReference, code: &str) -> Option<String> {
    let mut generator =
        ClassedHTMLGenerator::new_with_class_style(syntax, set, ClassStyle::SpacedPrefixed { prefix: HIGHLIGHT_PREFIX });
    for line in LinesWithEndings::from(code) {
        generator.parse_html_for_line_which_includes_newline(line).ok()?;
    }
    Some(generator.finalize())
}

fn write_escaped(output: &mut dyn fmt::Write, s: &str) -> fmt::Result {
    let mut last = 0;
    for (i, c) in s.char_indices() {
        let rep = match c {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '"' => "&quot;",
            _ => continue,
        };
        output.write_str(&s[last..i])?;
        output.write_str(rep)?;
        last = i + 1;
    }
    output.write_str(&s[last..])
}

fn escape_html(out: &mut String, s: &str) {
    let _ = write_escaped(out, s);
}

/// Languages compiled ahead of time by [`warm_up`]. The most expensive
/// grammars come first so parallel warm-up finishes as early as possible.
const WARM_UP_LANGUAGES: &[(&str, &str)] = &[
    ("ts", "import type { A } from './a';\ninterface B<T> extends C { x?: T[]; readonly y: string }\nexport async function f(a: B<number>): Promise<void> { const z = a as unknown; }\nenum E { A = 1 }\ntype U = keyof B<string> | null;\n"),
    ("cpp", "#include <vector>\ntemplate <typename T> class A : public B { public: virtual ~A() = default; std::vector<T> v; };\nint main() { auto x = [&](int y) { return y; }; }\n"),
    ("js", "import x from 'y';\nexport const f = async (a, ...b) => { return `${a}` ?? null; };\nclass A extends B {}\n"),
    ("rs", "use std::io;\n#[derive(Debug)]\npub struct A<'a> { x: &'a str }\nimpl A<'_> { fn f(&self) -> Option<u8> { match self.x { _ => None } } }\nfn main() { println!(\"{}\", 1); }\n"),
    ("py", "import os\n@dataclass\nclass A(B):\n    def f(self, x: int = 1) -> str:\n        return f\"{x}\" if x else None\n"),
    ("bash", "if [ -f \"$HOME/x\" ]; then echo $(ls -la) | grep -v foo && exit 0; fi\n"),
    ("json", "{\"a\": [1, 2.5, true, null, \"s\"]}\n"),
    ("yaml", "a: 1\nb:\n  - x\n  - {y: z}\n"),
    ("go", "package main\nimport \"fmt\"\ntype A struct { X int `json:\"x\"` }\nfunc (a *A) F() error { go func() {}(); return nil }\n"),
    ("swift", "import Foundation\n@MainActor final class A: B { private var x: [String: Int] = [:]\n func f() async throws -> Int? { guard let y else { return nil }; return y } }\n"),
    ("html", "<!DOCTYPE html><html><head><style>a{color:red}</style><script>let x=1;</script></head><body class=\"a\"></body></html>\n"),
    ("css", ".a > b:hover { color: #fff; margin: 0 auto !important; }\n@media (max-width: 1px) { a { x: y } }\n"),
    ("diff", "--- a\n+++ b\n@@ -1 +1 @@\n-x\n+y\n"),
    ("toml", "[package]\nname = \"x\"\n[dependencies]\ny = { version = \"1\" }\n"),
    ("sql", "SELECT a, COUNT(*) FROM t WHERE b = 'x' GROUP BY a ORDER BY 2 DESC;\n"),
    ("c", "#include <stdio.h>\nstatic int f(const char *s) { struct a b; return printf(\"%s\", s); }\n"),
    ("java", "package a;\nimport java.util.*;\npublic class A<T> extends B implements C { @Override public void f() throws E { var x = new ArrayList<T>(); } }\n"),
    ("rb", "require 'x'\nclass A < B\n  def f(x = 1, *y, &z) = x.map { |v| \"#{v}\" }\nend\n"),
    ("dockerfile", "FROM rust:1 AS build\nRUN cargo build --release\nCOPY --from=build /a /b\n"),
    ("kotlin", "data class A(val x: Int) { fun f(): String? = when (x) { 1 -> \"a\" else -> null } }\n"),
    ("php", "<?php\nnamespace A;\nclass B { public function f(array $x): ?string { return $x['a'] ?? null; } }\n"),
    ("cs", "using System;\nnamespace A { public class B<T> : C { public async Task<int> F() => await G(); } }\n"),
    ("makefile", "all: build\nbuild:\n\t$(CC) -o $@ $<\n"),
    ("xml", "<?xml version=\"1.0\"?><a b=\"c\"><!-- d --><e/></a>\n"),
];

/// Loads the syntax definitions and compiles the most common grammars so
/// later documents render without any first-use cost. Safe to call from any
/// thread, any number of times; meant for a low-priority background thread.
pub fn warm_up() {
    (0..warm_up_count()).for_each(warm_up_language);
}

/// Number of languages [`warm_up_language`] accepts.
pub fn warm_up_count() -> usize {
    WARM_UP_LANGUAGES.len()
}

/// Compiles one warm-up language; lets callers spread the work over cores.
pub fn warm_up_language(index: usize) {
    let set = &*SYNTAXES;
    if let Some((lang, sample)) = WARM_UP_LANGUAGES.get(index) {
        if let Some(syntax) = find_syntax(set, lang) {
            let _ = highlight(set, syntax, sample);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(md: &str) -> String {
        render_fragment(md, &RenderOptions::default())
    }

    #[test]
    fn simplified_grammars_highlight_identically() {
        let original = two_face::syntax::extra_newlines();
        let mut samples: Vec<(&str, &str)> = WARM_UP_LANGUAGES.to_vec();
        samples.push(("ts", "const café = (naïve: string) => naïve.length; // ünïcode\n"));
        for (lang, code) in samples {
            let a = highlight(&original, find_syntax(&original, lang).unwrap(), code);
            let b = highlight(&SYNTAXES, find_syntax(&SYNTAXES, lang).unwrap(), code);
            assert_eq!(a, b, "highlighting differs for {lang}");
        }
    }

    #[test]
    fn every_warm_up_language_resolves() {
        for (lang, _) in WARM_UP_LANGUAGES {
            assert!(find_syntax(&SYNTAXES, lang).is_some(), "no syntax for {lang}");
        }
        for alias in ["shell", "zsh", "console", "typescript", "golang", "c++", "jsonc", "objc", "python3"] {
            assert!(find_syntax(&SYNTAXES, alias).is_some(), "no syntax for alias {alias}");
        }
        assert!(find_syntax(&SYNTAXES, "mermaid").is_none());
    }

    #[test]
    fn gfm_features() {
        let html = body("| a | b |\n|---|--:|\n| 1 | 2 |\n\n- [x] done\n- [ ] todo\n\n~~gone~~ www.example.com\n\nx[^1]\n\n[^1]: note\n");
        assert!(html.contains("<table>") && html.contains("align=\"right\""));
        assert!(html.contains("task-list-item") && html.contains("checked"));
        assert!(html.contains("<del>gone</del>"));
        assert!(html.contains("href=\"http://www.example.com\""));
        assert!(html.contains("footnote"));
    }

    #[test]
    fn alerts_and_headings() {
        let html = body("# Hello World\n\n> [!WARNING]\n> careful\n");
        assert!(html.contains("id=\"hello-world\""));
        assert!(html.contains("markdown-alert-warning"));
    }

    #[test]
    fn code_blocks_are_highlighted_in_parallel_and_escaped() {
        let md = "```rust\nfn a() {}\n```\n\n```ts\nlet x: number = 1;\n```\n\n```python\nprint('<b>')\n```\n\n```\n<plain> & text\n```\n\n```unknownlang\n<x>\n```\n";
        let html = body(md);
        assert!(html.contains("class=\"language-rust\"") && html.contains("hl-source hl-rust"));
        assert!(html.contains("class=\"language-ts\"") && html.contains("hl-source hl-ts"));
        assert!(html.contains("hl-source hl-python") && html.contains("&lt;b&gt;"));
        assert!(html.contains("&lt;plain&gt; &amp; text"));
        assert!(html.contains("&lt;x&gt;"));
        // Order is preserved.
        let (r, t, p) = (html.find("hl-rust").unwrap(), html.find("hl-ts").unwrap(), html.find("hl-python").unwrap());
        assert!(r < t && t < p);
    }

    #[test]
    fn code_blocks_nested_in_lists_and_quotes() {
        let html = body("- item\n\n  ```sh\n  echo hi\n  ```\n\n> ```json\n> {\"a\": 1}\n> ```\n");
        assert!(html.contains("hl-shell") && html.contains("hl-json"));
        assert!(html.find("<li>").unwrap() < html.find("hl-shell").unwrap());
    }

    #[test]
    fn math_becomes_mathml() {
        let (html, has_math) = render_body("Inline $a^2$ and\n\n$$\n\\frac{1}{2}\n$$\n\n```math\nx\n```\n", &RenderOptions::default());
        assert!(has_math);
        assert_eq!(html.matches("<math").count(), 3);
        assert!(html.contains("<mfrac>"));
        assert!(!body("costs $5 and $10 today").contains("<math"), "currency is not math");
    }

    #[test]
    fn front_matter_table_and_yaml() {
        let html = body("---\ntitle: Hi <there>\ndate: 2026\n---\n# Doc\n");
        assert!(html.contains("<th>title</th><td>Hi &lt;there&gt;</td>"));
        let html = body("---\ntags:\n  - a\n  - b\n---\ntext\n");
        assert!(html.contains("<pre><code>tags:"));
    }

    #[test]
    fn dangerous_tags_are_filtered() {
        let html = body("<script>alert(1)</script>\n\nhi <iframe src=x></iframe> <style>*{}</style>\n");
        assert!(!html.contains("<script") && html.contains("&lt;script>"));
        assert!(!html.contains("<iframe") && !html.contains("<style"));
        assert!(body("<details><summary>s</summary>x</details>").contains("<details>"));
    }

    #[test]
    fn local_images_are_embedded() {
        let dir = std::env::temp_dir().join(format!("mdql-test-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("img dir")).unwrap();
        std::fs::write(dir.join("img dir/a.png"), b"\x89PNG fake").unwrap();
        std::fs::write(dir.join("b.svg"), b"<svg/>").unwrap();
        let opts = RenderOptions { base_dir: Some(dir.clone()), ..Default::default() };
        let html = render_fragment(
            "![a](img%20dir/a.png) ![b](<img dir/a.png>) <img width=10 src=\"./b.svg\"> ![r](https://x.org/r.png) ![m](missing.png)",
            &opts,
        );
        assert_eq!(html.matches("data:image/png;base64,").count(), 2);
        assert!(html.contains("src=\"data:image/svg+xml;base64,"));
        assert!(html.contains("class=\"remote-image\" title=\"https://x.org/r.png\""));
        assert!(html.contains("missing.png"));
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn document_is_self_contained() {
        let html = render_document("# x", &RenderOptions { title: Some("a<b".into()), ..Default::default() });
        assert!(html.starts_with("<!DOCTYPE html>"));
        assert!(html.contains("<title>a&lt;b</title>"));
        assert!(html.contains("Content-Security-Policy"));
        assert!(!html.contains("@namespace"), "math CSS only when needed");
        assert!(render_document("$x$", &RenderOptions::default()).contains("@namespace"));
    }

    #[test]
    fn themes() {
        let page = |theme| render_document("```rs\nfn a() {}\n```", &RenderOptions { theme, ..Default::default() });
        let (auto, light, dark) = (page(Theme::Auto), page(Theme::Light), page(Theme::Dark));
        assert!(auto.contains("content=\"light dark\"") && auto.contains("@media (prefers-color-scheme: dark)"));
        assert!(light.contains("content=\"light\"") && !light.contains("prefers-color-scheme"));
        assert!(light.contains("#ffffff") && !light.contains("#1e1e1e"));
        assert!(dark.contains("content=\"dark\"") && !dark.contains("prefers-color-scheme"));
        assert!(dark.contains("#1e1e1e"));
    }

    #[test]
    fn remote_images_are_blocked_unless_allowed() {
        let md = "[![CI](https://github.com/a/b/actions/workflows/ci.yml/badge.svg)](https://x) \
                  ![shot](https://example.com/s.png) <img src=\"https://img.shields.io/x\" alt=\"MIT\">";
        let html = body(md);
        assert!(!html.contains("<img"), "no remote <img> may remain: {html}");
        assert!(html.contains("<span class=\"remote-badge\" title=\"https://github.com/a/b/actions/workflows/ci.yml/badge.svg\">CI</span>"));
        assert!(html.contains("<span class=\"remote-badge\" title=\"https://img.shields.io/x\">MIT</span>"));
        let statics = body("![l](https://img.shields.io/badge/License-MIT-yellow.svg) ![v](https://img.shields.io/badge/v1.0--beta-blue?logo=x) ![c](https://img.shields.io/badge/a_b-ok-ff00aa)");
        assert!(statics.contains("<span class=\"badge-label\">License</span><span class=\"badge-message\" style=\"background:#dfb317\">MIT</span>"));
        assert!(statics.contains("<span class=\"badge-message\" style=\"background:#007ec6\">v1.0-beta</span>"));
        assert!(statics.contains("<span class=\"badge-label\">a b</span><span class=\"badge-message\" style=\"background:#ff00aa\">ok</span>"));
        assert!(html.contains("remote-image-label\">shot</span> <span class=\"remote-image-host\">example.com</span>"));
        assert!(html.contains("<a href=\"https://x\"><span class=\"remote-badge\""), "badge stays a link");
        let page = render_document(md, &RenderOptions::default());
        assert!(page.contains("img-src data:;"));

        let opts = RenderOptions { remote_images: true, ..Default::default() };
        let html = render_fragment(md, &opts);
        assert_eq!(html.matches("<img").count(), 3);
        assert!(render_document(md, &opts).contains("img-src data: https: http:;"));
    }

    #[test]
    fn text_decoding() {
        assert_eq!(decode_text(b"\xEF\xBB\xBFhi"), "hi");
        assert_eq!(decode_text(&[0xFF, 0xFE, b'h', 0, b'i', 0]), "hi");
        assert_eq!(decode_text(&[0xFE, 0xFF, 0, b'h', 0, b'i']), "hi");
        assert_eq!(decode_text(b"a\xFFb"), "a\u{FFFD}b");
    }

    #[test]
    fn helpers() {
        assert_eq!(percent_decode("a%20b%zz%"), "a b%zz%");
        let tag = "<img alt='x' data-src=\"no\" src = 'y.png'>";
        let (s, e) = attribute(tag, "src").unwrap();
        assert_eq!(&tag[s..e], "y.png");
        let (s, e) = attribute(tag, "alt").unwrap();
        assert_eq!(&tag[s..e], "x");
        assert_eq!(attribute("<img src=z.png/>", "src").map(|(s, e)| &"<img src=z.png/>"[s..e]), Some("z.png"));
        assert!(local_image_path(Path::new("/b"), "https://x").is_none());
        assert!(local_image_path(Path::new("/b"), "data:image/png;base64,").is_none());
        assert_eq!(local_image_path(Path::new("/b"), "c/d.png?x#y").unwrap(), Path::new("/b/c/d.png"));
        assert_eq!(local_image_path(Path::new("/b"), "file:///e.png").unwrap(), Path::new("/e.png"));
    }

    #[test]
    fn empty_and_huge_inputs() {
        assert!(render_document("", &RenderOptions::default()).contains("markdown-body"));
        let big = "word ".repeat(2_000_000) + "\n```rust\nfn x() {}\n```\n";
        let html = body(&big);
        assert!(html.contains("language-rust") && !html.contains("hl-rust"), "huge documents skip highlighting");
    }
}

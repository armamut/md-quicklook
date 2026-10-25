//! Native document model: Markdown → a compact binary layout that the Swift
//! side turns directly into an `NSAttributedString` for TextKit. No HTML, no
//! web engine.
//!
//! The document is plain text plus three tables that point into it by UTF-16
//! offsets (what `NSRange` uses):
//!
//! * **blocks** – containers such as quotes, lists, code blocks and tables,
//!   each with a parent, forming a tree;
//! * **paragraphs** – ranges with a paragraph-level style and their innermost
//!   block;
//! * **runs** – ranges with inline styles (bold, code, link, token colours…)
//!   or an attachment (image, formula, badge, checkbox, rule), which occupies
//!   a single U+FFFC character.
//!
//! Strings that are not text (URLs, paths, LaTeX, languages) live in a string
//! table. The byte layout is documented in `core/include/mdql.h` and decoded
//! by `macos/Native/NativeDocument.swift`.

use std::collections::HashMap;
use std::path::Path;
use std::sync::LazyLock;

use comrak::nodes::{AlertType, AstNode, ListType, NodeValue, TableAlignment};
use comrak::{Anchorizer, Arena, parse_document};
use syntect::highlighting::{HighlightState, Highlighter, RangedHighlightIterator, Theme};
use syntect::parsing::{ParseState, ScopeStack, SyntaxReference};
use syntect::util::LinesWithEndings;

use crate::{
    MAX_HIGHLIGHT_BLOCK, MAX_HIGHLIGHT_DOCUMENT, SYNTAXES, attribute, comrak_options, decode_entities, find_ascii_ci,
    find_syntax, first_word, image_mime, is_remote, local_image_path, shields_static_badge,
};

pub const MAGIC: &[u8; 4] = b"MDQ1";
pub const NO_BLOCK: u16 = u16::MAX;

/// Block (container) kinds.
pub mod block {
    pub const QUOTE: u8 = 1;
    /// `a` = alert type (0 note, 1 tip, 2 important, 3 warning, 4 caution).
    pub const ALERT: u8 = 2;
    /// `a` = 1 if ordered; flags: `TIGHT`.
    pub const LIST: u8 = 3;
    /// `a` = depth (1 = top level).
    pub const LIST_ITEM: u8 = 4;
    /// `a` = language string id + 1 (0 = none).
    pub const CODE: u8 = 5;
    /// `a` = columns, `b` = rows; flags: `FRONT_MATTER`.
    pub const TABLE: u8 = 6;
    /// `a` = row index; flags: `HEADER`.
    pub const TABLE_ROW: u8 = 7;
    pub const FRONT_MATTER: u8 = 9;
    pub const FOOTNOTES: u8 = 10;
    /// Flags: `OPEN`. Its first paragraph is usually the `SUMMARY`.
    pub const DETAILS: u8 = 11;

    pub const TIGHT: u8 = 1;
    pub const HEADER: u8 = 2;
    pub const FRONT_MATTER_TABLE: u8 = 4;
    /// `<details open>`: starts expanded.
    pub const OPEN: u8 = 8;
}

/// Paragraph kinds.
pub mod para {
    pub const BODY: u8 = 0;
    /// `level` = 1–6, `extra` = anchor string id + 1.
    pub const HEADING: u8 = 1;
    pub const CODE: u8 = 2;
    /// Block = its row; `level` = column; `extra` low byte = alignment.
    pub const TABLE_CELL: u8 = 3;
    pub const RULE: u8 = 4;
    pub const MATH: u8 = 5;
    /// `level` = alert type.
    pub const ALERT_TITLE: u8 = 6;
    pub const CAPTION: u8 = 7;
    pub const SUMMARY: u8 = 8;

    /// `extra` bits 8–9: alignment (0 natural, 1 left, 2 center, 3 right).
    pub const ALIGN_SHIFT: u32 = 8;
    /// `extra` bit 10: the paragraph starts with a list marker and a tab.
    pub const LIST_MARKER: u32 = 1 << 10;
    /// `extra` bits 16–31 on BODY paragraphs: anchor string id + 1 (footnotes).
    pub const ANCHOR_SHIFT: u32 = 16;
}

/// Run flags.
pub mod run {
    pub const BOLD: u32 = 1 << 0;
    pub const ITALIC: u32 = 1 << 1;
    pub const CODE: u32 = 1 << 2;
    pub const STRIKE: u32 = 1 << 3;
    /// `c` = URL string id + 1.
    pub const LINK: u32 = 1 << 4;
    pub const MARK: u32 = 1 << 5;
    pub const SUP: u32 = 1 << 6;
    pub const SUB: u32 = 1 << 7;
    pub const KBD: u32 = 1 << 8;
    pub const UNDERLINE: u32 = 1 << 9;
    /// `a` = light RGBA, `b` = dark RGBA.
    pub const TOKEN: u32 = 1 << 10;
    /// `a` = attachment kind, `b` = first string id, `d` = width in points (0 = natural).
    pub const ATTACHMENT: u32 = 1 << 11;
    pub const SMALL: u32 = 1 << 12;
    pub const MUTED: u32 = 1 << 13;
    pub const TOKEN_BOLD: u32 = 1 << 14;
    pub const TOKEN_ITALIC: u32 = 1 << 15;
}

/// Attachment kinds (`a` of an attachment run).
pub mod attach {
    /// Strings: path, alt.
    pub const IMAGE: u32 = 1;
    /// Strings: URL, alt.
    pub const REMOTE_IMAGE: u32 = 2;
    /// Strings: URL, alt. A remote image that looks like a badge.
    pub const REMOTE_BADGE: u32 = 3;
    /// Strings: label (may be empty), message, colour (#rrggbb).
    pub const BADGE: u32 = 4;
    /// Strings: LaTeX.
    pub const MATH_INLINE: u32 = 5;
    pub const MATH_DISPLAY: u32 = 6;
    pub const CHECKBOX_ON: u32 = 7;
    pub const CHECKBOX_OFF: u32 = 8;
    pub const RULE: u32 = 9;
    /// Strings: Mermaid source (drawn by `mdql_render_mermaid`).
    pub const DIAGRAM: u32 = 10;
}

const OBJECT: char = '\u{FFFC}';
const LINE_SEPARATOR: char = '\u{2028}';

/// Light and dark highlighting themes (GitHub, One Half Dark).
static THEMES: LazyLock<(Theme, Theme)> =
    LazyLock::new(|| syntect::dumps::from_binary(include_bytes!("../assets/themes.themedump")));

struct Block {
    kind: u8,
    flags: u8,
    parent: u16,
    a: u32,
    b: u32,
    c: u32,
}

struct Para {
    start: u32,
    len: u32,
    block: u16,
    kind: u8,
    level: u8,
    extra: u32,
}

#[derive(Clone, Copy, PartialEq, Eq, Default)]
struct Style {
    flags: u32,
    a: u32,
    b: u32,
    c: u32,
    d: u32,
}

struct Run {
    start: u32,
    len: u32,
    style: Style,
}

/// Code highlighted ahead of time: (text, light RGBA, dark RGBA, font bits).
type Segments = Vec<(String, u32, u32, u32)>;

struct Builder<'p> {
    text: String,
    utf16: u32,
    strings: Vec<String>,
    string_ids: HashMap<String, u32>,
    blocks: Vec<Block>,
    paras: Vec<Para>,
    runs: Vec<Run>,

    stack: Vec<u16>,
    style: Style,
    /// Open paragraph: (start, kind, level, extra).
    open: Option<(u32, u8, u8, u32)>,
    /// List marker waiting for the item's first paragraph.
    pending_marker: Option<Marker>,
    /// Alignment set by raw HTML (`<div align="center">`), innermost last.
    align_stack: Vec<u32>,
    /// Inline style saved by open raw-HTML inline tags.
    html_inline: Vec<(String, Style)>,
    list_depth: u32,
    in_footnotes: bool,
    footnote_count: u32,
    anchorizer: Anchorizer,

    base_dir: Option<&'p Path>,
    remote_images: bool,
    highlighted: HashMap<usize, Segments>,
}

enum Marker {
    Text(String),
    Checkbox(bool),
}

/// Renders Markdown into the binary native layout.
pub fn render_native(markdown: &str, base_dir: Option<&Path>, remote_images: bool) -> Vec<u8> {
    let options = comrak_options();
    let arena = Arena::new();
    let root = parse_document(&arena, markdown, &options);

    let highlighted = if markdown.len() <= MAX_HIGHLIGHT_DOCUMENT { highlight_all(root) } else { HashMap::new() };
    let mut b = Builder {
        text: String::with_capacity(markdown.len() + 64),
        utf16: 0,
        strings: Vec::new(),
        string_ids: HashMap::new(),
        blocks: Vec::new(),
        paras: Vec::new(),
        runs: Vec::new(),
        stack: Vec::new(),
        style: Style::default(),
        open: None,
        pending_marker: None,
        align_stack: Vec::new(),
        html_inline: Vec::new(),
        list_depth: 0,
        in_footnotes: false,
        footnote_count: 0,
        anchorizer: Anchorizer::new(),
        base_dir,
        remote_images,
        highlighted,
    };
    for child in root.children() {
        b.block_node(child);
    }
    b.close_para();
    b.encode()
}

impl Builder<'_> {
    // -- Low-level output --------------------------------------------------

    fn string(&mut self, s: &str) -> u32 {
        if let Some(&id) = self.string_ids.get(s) {
            return id;
        }
        let id = self.strings.len() as u32;
        self.strings.push(s.to_owned());
        self.string_ids.insert(s.to_owned(), id);
        id
    }

    fn push_raw(&mut self, s: &str, style: Style) {
        if s.is_empty() {
            return;
        }
        let start = self.utf16;
        let len = s.encode_utf16().count() as u32;
        self.text.push_str(s);
        self.utf16 += len;
        if style == Style::default() {
            return;
        }
        if let Some(last) = self.runs.last_mut() {
            if last.style == style && last.start + last.len == start && style.flags & run::ATTACHMENT == 0 {
                last.len += len;
                return;
            }
        }
        self.runs.push(Run { start, len, style });
    }

    /// Appends inline text with the current style, opening a paragraph if needed.
    fn text(&mut self, s: &str) {
        self.ensure_para();
        let style = self.style;
        self.push_raw(s, style);
    }

    fn attachment(&mut self, kind: u32, strings: &[&str], width: u32) {
        self.ensure_para();
        // An attachment's strings are consecutive, so they are never shared.
        let first = self.strings.len() as u32;
        self.strings.extend(strings.iter().map(|s| (*s).to_owned()));
        let mut style = self.style;
        style.flags |= run::ATTACHMENT;
        style.a = kind;
        style.b = first;
        style.d = width;
        let mut buf = [0u8; 4];
        self.push_raw(OBJECT.encode_utf8(&mut buf), style);
    }

    fn push_block(&mut self, kind: u8, flags: u8, a: u32, b: u32) -> u16 {
        let parent = self.stack.last().copied().unwrap_or(NO_BLOCK);
        self.blocks.push(Block { kind, flags, parent, a, b, c: 0 });
        let id = (self.blocks.len() - 1) as u16;
        self.stack.push(id);
        id
    }

    fn pop_block(&mut self) {
        self.close_para();
        self.stack.pop();
    }

    fn current_align(&self) -> u32 {
        self.align_stack.last().copied().unwrap_or(0)
    }

    fn begin_para(&mut self, kind: u8, level: u8, extra: u32) {
        self.close_para();
        let mut extra = extra | (self.current_align() << para::ALIGN_SHIFT);
        let marker = self.pending_marker.take();
        self.open = Some((self.utf16, kind, level, extra));
        if let Some(marker) = marker {
            extra |= para::LIST_MARKER;
            if let Some(open) = self.open.as_mut() {
                open.3 = extra;
            }
            let saved = std::mem::take(&mut self.style);
            match marker {
                Marker::Text(t) => {
                    let style = Style { flags: if self.in_footnotes { run::SMALL | run::MUTED } else { 0 }, ..Style::default() };
                    self.push_raw(&t, style);
                }
                Marker::Checkbox(on) => {
                    let s = Style {
                        flags: run::ATTACHMENT,
                        a: if on { attach::CHECKBOX_ON } else { attach::CHECKBOX_OFF },
                        ..Style::default()
                    };
                    let mut buf = [0u8; 4];
                    self.push_raw(OBJECT.encode_utf8(&mut buf), s);
                }
            }
            self.push_raw("\t", Style::default());
            self.style = saved;
        }
    }

    fn ensure_para(&mut self) {
        if self.open.is_none() {
            self.begin_para(para::BODY, 0, 0);
        }
    }

    fn close_para(&mut self) {
        if let Some((start, kind, level, extra)) = self.open.take() {
            self.push_raw("\n", Style::default());
            let block = self.stack.last().copied().unwrap_or(NO_BLOCK);
            self.paras.push(Para { start, len: self.utf16 - start, block, kind, level, extra });
        }
    }

    /// A non-paragraph block is starting inside a list item that has not shown
    /// its marker yet: give the marker a paragraph of its own.
    fn flush_marker(&mut self) {
        if self.pending_marker.is_some() {
            self.begin_para(para::BODY, 0, 0);
            self.close_para();
        }
    }

    // -- Blocks ------------------------------------------------------------

    fn block_node<'a>(&mut self, node: &'a AstNode<'a>) {
        let value = node.data().value.clone();
        match value {
            NodeValue::Paragraph => {
                let children: Vec<_> = node.children().collect();
                if let [only] = children.as_slice() {
                    if let NodeValue::Math(m) = &only.data().value {
                        if m.display_math {
                            self.begin_para(para::MATH, 0, 0);
                            self.attachment(attach::MATH_DISPLAY, &[&m.literal], 0);
                            self.close_para();
                            return;
                        }
                    }
                }
                self.begin_para(para::BODY, 0, 0);
                self.inlines(node);
                self.close_para();
            }
            NodeValue::Heading(h) => {
                let title = plain_text(node);
                let anchor = self.anchorizer.anchorize(&title);
                let id = self.string(&anchor) + 1;
                self.flush_marker();
                self.begin_para(para::HEADING, h.level, id);
                self.inlines(node);
                self.close_para();
            }
            NodeValue::BlockQuote | NodeValue::MultilineBlockQuote(_) => {
                self.flush_marker();
                self.close_para();
                self.push_block(block::QUOTE, 0, 0, 0);
                self.children(node);
                self.pop_block();
            }
            NodeValue::Alert(alert) => {
                self.flush_marker();
                self.close_para();
                let (kind, title, icon) = match alert.alert_type {
                    AlertType::Note => (0, "Note", "ⓘ"),
                    AlertType::Tip => (1, "Tip", "✦"),
                    AlertType::Important => (2, "Important", "!"),
                    AlertType::Warning => (3, "Warning", "⚠"),
                    AlertType::Caution => (4, "Caution", "⊘"),
                };
                self.push_block(block::ALERT, 0, kind, 0);
                self.begin_para(para::ALERT_TITLE, kind as u8, 0);
                let title = alert.title.as_deref().unwrap_or(title);
                self.push_raw(&format!("{icon}  {title}"), Style { flags: run::BOLD, ..Style::default() });
                self.close_para();
                self.children(node);
                self.pop_block();
            }
            NodeValue::List(list) => {
                self.flush_marker();
                self.close_para();
                let ordered = list.list_type == ListType::Ordered;
                let flags = if list.tight { block::TIGHT } else { 0 };
                self.push_block(block::LIST, flags, ordered as u32, list.start as u32);
                self.list_depth += 1;
                let delimiter = if list.delimiter == comrak::nodes::ListDelimType::Paren { ")" } else { "." };
                for (i, item) in node.children().enumerate() {
                    let marker = match &item.data().value {
                        NodeValue::TaskItem(t) => Marker::Checkbox(t.symbol.is_some_and(|c| c != ' ')),
                        _ if ordered => Marker::Text(format!("{}{delimiter}", list.start + i)),
                        _ => Marker::Text(["•", "◦", "▪"][(self.list_depth as usize - 1) % 3].to_owned()),
                    };
                    self.push_block(block::LIST_ITEM, 0, self.list_depth, 0);
                    self.pending_marker = Some(marker);
                    self.children(item);
                    self.flush_marker();
                    self.pop_block();
                }
                self.list_depth -= 1;
                self.pop_block();
            }
            NodeValue::Item(_) | NodeValue::TaskItem(_) => self.children(node),
            NodeValue::CodeBlock(cb) => {
                self.flush_marker();
                let lang = first_word(&cb.info).to_owned();
                if lang.eq_ignore_ascii_case("math") {
                    self.begin_para(para::MATH, 0, 0);
                    self.attachment(attach::MATH_DISPLAY, &[cb.literal.trim_end()], 0);
                    self.close_para();
                    return;
                }
                // Diagrams that cannot be parsed stay code.
                if lang.eq_ignore_ascii_case("mermaid") && crate::mermaid::is_diagram(&cb.literal) {
                    self.close_para();
                    self.begin_para(para::MATH, 0, 0);
                    self.attachment(attach::DIAGRAM, &[&cb.literal], 0);
                    self.close_para();
                    return;
                }
                self.close_para();
                let lang_id = if lang.is_empty() { 0 } else { self.string(&lang) + 1 };
                self.push_block(block::CODE, 0, lang_id, 0);
                self.begin_para(para::CODE, 0, 0);
                let code = cb.literal.strip_suffix('\n').unwrap_or(&cb.literal);
                match self.highlighted.remove(&(node as *const _ as usize)) {
                    Some(segments) => {
                        let last = segments.len().saturating_sub(1);
                        for (i, (text, light, dark, font)) in segments.iter().enumerate() {
                            // The block's final newline is the paragraph terminator.
                            let text = if i == last { text.strip_suffix('\n').unwrap_or(text) } else { text };
                            let style = Style { flags: run::TOKEN | font, a: *light, b: *dark, ..Style::default() };
                            self.push_raw(text, style);
                        }
                    }
                    None => self.push_raw(code, Style::default()),
                }
                self.pop_block();
            }
            NodeValue::HtmlBlock(html) => {
                self.flush_marker();
                self.html(&html.literal, true);
                self.close_para();
            }
            NodeValue::ThematicBreak => {
                self.flush_marker();
                self.begin_para(para::RULE, 0, 0);
                self.attachment(attach::RULE, &[], 0);
                self.close_para();
            }
            NodeValue::Table(table) => {
                self.flush_marker();
                self.close_para();
                self.push_block(block::TABLE, 0, table.num_columns as u32, table.num_rows as u32);
                for (r, row) in node.children().enumerate() {
                    let header = matches!(row.data().value, NodeValue::TableRow(true));
                    self.push_block(block::TABLE_ROW, if header { block::HEADER } else { 0 }, r as u32, 0);
                    for (c, cell) in row.children().enumerate() {
                        let align = match table.alignments.get(c) {
                            Some(TableAlignment::Left) => 1,
                            Some(TableAlignment::Center) => 2,
                            Some(TableAlignment::Right) => 3,
                            _ => 0,
                        };
                        if header {
                            self.style.flags |= run::BOLD;
                        }
                        self.begin_para(para::TABLE_CELL, c as u8, align);
                        self.inlines(cell);
                        self.close_para();
                        self.style = Style::default();
                    }
                    self.pop_block();
                }
                self.pop_block();
            }
            NodeValue::FootnoteDefinition(def) => {
                if !self.in_footnotes {
                    self.close_para();
                    self.begin_para(para::RULE, 0, 0);
                    self.attachment(attach::RULE, &[], 0);
                    self.close_para();
                    self.push_block(block::FOOTNOTES, 0, 0, 0);
                    self.push_block(block::LIST, block::TIGHT, 1, 1);
                    self.in_footnotes = true;
                    self.list_depth += 1;
                }
                self.footnote_count += 1;
                self.push_block(block::LIST_ITEM, 0, self.list_depth, 0);
                self.pending_marker = Some(Marker::Text(format!("{}.", self.footnote_count)));
                let anchor = self.string(&format!("fn-{}", def.name)) + 1;
                let first = self.paras.len();
                let saved = self.style;
                self.style.flags |= run::SMALL | run::MUTED;
                self.children(node);
                self.close_para();
                if let Some(p) = self.paras.get_mut(first) {
                    p.extra |= anchor << para::ANCHOR_SHIFT;
                }
                self.style = saved;
                self.pop_block();
            }
            NodeValue::FrontMatter(raw) => self.front_matter(&raw),
            NodeValue::DescriptionList | NodeValue::DescriptionItem(_) | NodeValue::DescriptionDetails => {
                self.children(node)
            }
            NodeValue::DescriptionTerm => {
                self.begin_para(para::BODY, 0, 0);
                let saved = self.style;
                self.style.flags |= run::BOLD;
                self.inlines(node);
                self.style = saved;
                self.close_para();
            }
            NodeValue::MultilineComment(_) => {}
            _ if node.first_child().is_some() => self.children(node),
            _ => {
                // Unknown leaf block: show whatever text it has.
                let t = plain_text(node);
                if !t.is_empty() {
                    self.begin_para(para::BODY, 0, 0);
                    self.text(&t);
                    self.close_para();
                }
            }
        }
    }

    fn children<'a>(&mut self, node: &'a AstNode<'a>) {
        for child in node.children() {
            if child.data().value.block() {
                self.block_node(child);
            } else {
                self.inline_node(child);
            }
        }
    }

    fn front_matter(&mut self, raw: &str) {
        let body = raw.trim().trim_start_matches("---").trim_end_matches("---").trim_end_matches("...").trim_matches('\n');
        if body.trim().is_empty() {
            return;
        }
        let pairs: Option<Vec<(&str, &str)>> = body
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| {
                if l.starts_with([' ', '\t', '-', '#']) {
                    return None;
                }
                let (k, v) = l.split_once(':')?;
                Some((k.trim(), v.trim().trim_matches(|c| c == '"' || c == '\'')))
            })
            .collect();
        self.push_block(block::FRONT_MATTER, 0, 0, 0);
        self.begin_para(para::CAPTION, 0, 0);
        self.push_raw("FRONT MATTER", Style { flags: run::SMALL | run::MUTED | run::BOLD, ..Style::default() });
        self.close_para();
        match pairs {
            Some(pairs) if !pairs.is_empty() => {
                self.push_block(block::TABLE, block::FRONT_MATTER_TABLE, 2, pairs.len() as u32);
                for (r, (k, v)) in pairs.iter().enumerate() {
                    self.push_block(block::TABLE_ROW, 0, r as u32, 0);
                    self.begin_para(para::TABLE_CELL, 0, 0);
                    self.push_raw(k, Style { flags: run::BOLD | run::SMALL, ..Style::default() });
                    self.close_para();
                    self.begin_para(para::TABLE_CELL, 1, 0);
                    self.push_raw(v, Style { flags: run::SMALL | run::MUTED, ..Style::default() });
                    self.close_para();
                    self.pop_block();
                }
                self.pop_block();
            }
            _ => {
                let lang = self.string("yaml") + 1;
                self.push_block(block::CODE, 0, lang, 0);
                self.begin_para(para::CODE, 0, 0);
                self.push_raw(body, Style::default());
                self.pop_block();
            }
        }
        self.pop_block();
    }

    // -- Inlines -----------------------------------------------------------

    fn inlines<'a>(&mut self, node: &'a AstNode<'a>) {
        for child in node.children() {
            self.inline_node(child);
        }
    }

    fn with_flags<'a>(&mut self, node: &'a AstNode<'a>, flags: u32) {
        let saved = self.style;
        self.style.flags |= flags;
        self.inlines(node);
        self.style = saved;
    }

    fn inline_node<'a>(&mut self, node: &'a AstNode<'a>) {
        let value = node.data().value.clone();
        match value {
            NodeValue::Text(t) => self.text(&t),
            NodeValue::SoftBreak => self.text(" "),
            NodeValue::LineBreak => self.text(&LINE_SEPARATOR.to_string()),
            NodeValue::Code(c) => {
                let saved = self.style;
                self.style.flags |= run::CODE;
                self.text(&c.literal);
                self.style = saved;
            }
            NodeValue::Emph => self.with_flags(node, run::ITALIC),
            NodeValue::Strong => self.with_flags(node, run::BOLD),
            NodeValue::Strikethrough => self.with_flags(node, run::STRIKE),
            NodeValue::Highlight => self.with_flags(node, run::MARK),
            NodeValue::Superscript => self.with_flags(node, run::SUP),
            NodeValue::Subscript => self.with_flags(node, run::SUB),
            NodeValue::Underline | NodeValue::Insert => self.with_flags(node, run::UNDERLINE),
            NodeValue::Subtext => self.with_flags(node, run::SMALL | run::MUTED),
            NodeValue::Link(link) => self.link(node, &link.url),
            NodeValue::WikiLink(link) => self.link(node, &link.url),
            NodeValue::Image(link) => {
                let alt = plain_text(node);
                self.image(&link.url, &alt, 0);
            }
            NodeValue::FootnoteReference(r) => {
                let saved = self.style;
                self.style.flags |= run::SUP | run::LINK;
                self.style.c = self.string(&format!("#fn-{}", r.name)) + 1;
                self.text(&format!("[{}]", r.ref_num.max(1)));
                self.style = saved;
            }
            NodeValue::ShortCode(sc) => self.text(&sc.emoji),
            NodeValue::Math(m) => {
                let kind = if m.display_math { attach::MATH_DISPLAY } else { attach::MATH_INLINE };
                self.attachment(kind, &[&m.literal], 0);
            }
            NodeValue::HtmlInline(html) => self.html(&html, false),
            NodeValue::Raw(s) => self.text(&s),
            NodeValue::EscapedTag(s) => self.text(s),
            NodeValue::CommentInline(_) => {}
            _ => self.inlines(node),
        }
    }

    fn link<'a>(&mut self, node: &'a AstNode<'a>, url: &str) {
        let saved = self.style;
        self.style.flags |= run::LINK;
        self.style.c = self.string(url) + 1;
        self.inlines(node);
        self.style = saved;
    }

    fn image(&mut self, url: &str, alt: &str, width: u32) {
        if is_remote(url) {
            if !self.remote_images {
                if let Some((label, message, color)) = shields_static_badge(url) {
                    let color = crate::badge_color(&color);
                    self.attachment(attach::BADGE, &[label.as_deref().unwrap_or(""), &message, &color], 0);
                    return;
                }
            }
            let lower = url.to_ascii_lowercase();
            let badge = lower.contains("badge") || lower.contains("shields.io") || lower.contains("badgen.net");
            let kind = if badge { attach::REMOTE_BADGE } else { attach::REMOTE_IMAGE };
            self.attachment(kind, &[url, alt], width);
            return;
        }
        if let Some(base) = self.base_dir {
            if let Some(path) = local_image_path(base, url) {
                if image_mime(&path).is_some() && path.is_file() {
                    self.attachment(attach::IMAGE, &[&path.to_string_lossy(), alt], width);
                    return;
                }
            }
        }
        // Missing image: show its alt text.
        if !alt.is_empty() {
            let saved = self.style;
            self.style.flags |= run::MUTED | run::ITALIC;
            self.text(alt);
            self.style = saved;
        }
    }

    // -- Raw HTML ----------------------------------------------------------

    /// Interprets the common subset of raw HTML found in Markdown documents:
    /// inline formatting, links, images, line breaks, alignment, headings,
    /// paragraphs and `<details>`. Anything else contributes only its text.
    fn html(&mut self, html: &str, block: bool) {
        let mut rest = html;
        while !rest.is_empty() {
            let Some(lt) = rest.find('<') else {
                self.html_text(rest, block);
                break;
            };
            self.html_text(&rest[..lt], block);
            rest = &rest[lt..];
            if rest.starts_with("<!--") {
                rest = rest.find("-->").map_or("", |e| &rest[e + 3..]);
                continue;
            }
            // Never show the contents of scripts and styles.
            if let Some(tag) = ["script", "style", "title", "noscript", "template"]
                .into_iter()
                .find(|t| rest.as_bytes().get(1..=t.len()).is_some_and(|b| b.eq_ignore_ascii_case(t.as_bytes())))
            {
                let close = format!("</{tag}");
                rest = find_ascii_ci(rest, &close)
                    .map_or("", |e| rest[e..].find('>').map_or("", |g| &rest[e + g + 1..]));
                continue;
            }
            let Some(gt) = rest.find('>') else {
                self.html_text(rest, block);
                break;
            };
            let tag = &rest[..=gt];
            rest = &rest[gt + 1..];
            self.html_tag(tag);
        }
    }

    fn html_text(&mut self, text: &str, block: bool) {
        if text.is_empty() {
            return;
        }
        let decoded = decode_html_entities(text);
        if block {
            // HTML whitespace collapses.
            let collapsed: String = decoded.split_whitespace().collect::<Vec<_>>().join(" ");
            if collapsed.is_empty() {
                return;
            }
            let lead = decoded.starts_with(char::is_whitespace) && self.open.is_some();
            let trail = decoded.ends_with(char::is_whitespace);
            if lead {
                self.text(" ");
            }
            self.text(&collapsed);
            if trail {
                self.text(" ");
            }
        } else {
            self.text(&decoded);
        }
    }

    fn html_tag(&mut self, tag: &str) {
        let inner = tag.trim_start_matches('<').trim_end_matches('>').trim_end_matches('/').trim();
        let closing = inner.starts_with('/');
        let name: String = inner
            .trim_start_matches('/')
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect::<String>()
            .to_ascii_lowercase();
        let align = attribute(tag, "align")
            .map(|(a, b)| tag[a..b].to_ascii_lowercase())
            .map(|v| match v.as_str() {
                "center" => 2,
                "right" => 3,
                "left" => 1,
                _ => 0,
            })
            .unwrap_or(0);

        let inline_flag = match name.as_str() {
            "b" | "strong" => run::BOLD,
            "i" | "em" | "cite" | "var" => run::ITALIC,
            "code" | "tt" | "samp" => run::CODE,
            "kbd" => run::KBD,
            "s" | "del" | "strike" => run::STRIKE,
            "mark" => run::MARK,
            "sup" => run::SUP,
            "sub" => run::SUB,
            "u" | "ins" => run::UNDERLINE,
            "small" => run::SMALL,
            _ => 0,
        };
        if inline_flag != 0 || name == "a" || name == "span" || name == "font" {
            if closing {
                if let Some(pos) = self.html_inline.iter().rposition(|(n, _)| *n == name) {
                    self.style = self.html_inline[pos].1;
                    self.html_inline.truncate(pos);
                }
            } else {
                self.html_inline.push((name.clone(), self.style));
                self.style.flags |= inline_flag;
                if name == "a" {
                    if let Some((a, b)) = attribute(tag, "href") {
                        let href = decode_entities(&tag[a..b]).into_owned();
                        self.style.flags |= run::LINK;
                        self.style.c = self.string(&href) + 1;
                    }
                }
            }
            return;
        }

        match (name.as_str(), closing) {
            ("br", _) => self.text(&LINE_SEPARATOR.to_string()),
            ("img", false) => {
                let src = attribute(tag, "src").map(|(a, b)| decode_entities(&tag[a..b]).into_owned()).unwrap_or_default();
                let alt = attribute(tag, "alt").map(|(a, b)| decode_entities(&tag[a..b]).into_owned()).unwrap_or_default();
                let width = attribute(tag, "width")
                    .and_then(|(a, b)| tag[a..b].trim_end_matches("px").parse::<u32>().ok())
                    .unwrap_or(0);
                if !src.is_empty() {
                    self.image(&src, &alt, width);
                }
            }
            ("p" | "div" | "center" | "section" | "header" | "footer" | "article" | "blockquote" | "figure", false) => {
                self.close_para();
                let align = if name == "center" { 2 } else { align };
                // Alignment is inherited until the matching close tag.
                self.align_stack.push(if align != 0 { align } else { self.current_align() });
            }
            ("p" | "div" | "center" | "section" | "header" | "footer" | "article" | "blockquote" | "figure", true) => {
                self.close_para();
                self.align_stack.pop();
            }
            (h, false) if h.len() == 2 && h.starts_with('h') && h.as_bytes()[1].is_ascii_digit() => {
                let level = (h.as_bytes()[1] - b'0').clamp(1, 6);
                self.close_para();
                self.align_stack.push(if align != 0 { align } else { self.current_align() });
                self.begin_para(para::HEADING, level, 0);
            }
            (h, true) if h.len() == 2 && h.starts_with('h') && h.as_bytes()[1].is_ascii_digit() => {
                self.close_para();
                self.align_stack.pop();
            }
            ("details", false) => {
                self.close_para();
                let open = inner.split_ascii_whitespace().skip(1).any(|word| {
                    let attr = word.split('=').next().unwrap_or_default();
                    attr.eq_ignore_ascii_case("open")
                });
                self.push_block(block::DETAILS, if open { block::OPEN } else { 0 }, 0, 0);
            }
            ("details", true) => {
                if self.stack.last().is_some_and(|&b| self.blocks[b as usize].kind == block::DETAILS) {
                    self.pop_block();
                }
            }
            ("summary", false) => {
                self.begin_para(para::SUMMARY, 0, 0);
                self.push_raw("▾ ", Style { flags: run::MUTED, ..Style::default() });
                self.html_inline.push(("summary".into(), self.style));
                self.style.flags |= run::BOLD;
            }
            ("summary", true) => {
                if let Some(pos) = self.html_inline.iter().rposition(|(n, _)| n == "summary") {
                    self.style = self.html_inline[pos].1;
                    self.html_inline.truncate(pos);
                }
                self.close_para();
            }
            ("hr", _) => {
                self.begin_para(para::RULE, 0, 0);
                self.attachment(attach::RULE, &[], 0);
                self.close_para();
            }
            ("li", false) => {
                self.begin_para(para::BODY, 0, 0);
                self.push_raw("•  ", Style::default());
            }
            ("li" | "tr" | "ul" | "ol" | "table" | "pre", _) => self.close_para(),
            ("td" | "th", false) => {
                if self.open.is_some() {
                    self.text("  ");
                }
            }
            _ => {}
        }
    }

    // -- Encoding ----------------------------------------------------------

    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.text.len() + self.runs.len() * 28 + self.paras.len() * 16 + 256);
        out.extend_from_slice(MAGIC);
        put(&mut out, self.text.len() as u32);
        out.extend_from_slice(self.text.as_bytes());
        put(&mut out, self.strings.len() as u32);
        for s in &self.strings {
            put(&mut out, s.len() as u32);
            out.extend_from_slice(s.as_bytes());
        }
        put(&mut out, self.blocks.len() as u32);
        for b in &self.blocks {
            out.push(b.kind);
            out.push(b.flags);
            out.extend_from_slice(&b.parent.to_le_bytes());
            put(&mut out, b.a);
            put(&mut out, b.b);
            put(&mut out, b.c);
        }
        put(&mut out, self.paras.len() as u32);
        for p in &self.paras {
            put(&mut out, p.start);
            put(&mut out, p.len);
            out.extend_from_slice(&p.block.to_le_bytes());
            out.push(p.kind);
            out.push(p.level);
            put(&mut out, p.extra);
        }
        put(&mut out, self.runs.len() as u32);
        for r in &self.runs {
            put(&mut out, r.start);
            put(&mut out, r.len);
            put(&mut out, r.style.flags);
            put(&mut out, r.style.a);
            put(&mut out, r.style.b);
            put(&mut out, r.style.c);
            put(&mut out, r.style.d);
        }
        out
    }
}

fn put(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}

/// Concatenated text of a node's descendants.
fn plain_text<'a>(node: &'a AstNode<'a>) -> String {
    let mut s = String::new();
    for n in node.descendants().skip(1) {
        match &n.data().value {
            NodeValue::Text(t) => s.push_str(t),
            NodeValue::Code(c) => s.push_str(&c.literal),
            NodeValue::SoftBreak | NodeValue::LineBreak => s.push(' '),
            NodeValue::ShortCode(sc) => s.push_str(&sc.emoji),
            NodeValue::Math(m) => s.push_str(&m.literal),
            _ => {}
        }
    }
    s
}

/// Decodes the HTML entities that appear in practice.
fn decode_html_entities(s: &str) -> std::borrow::Cow<'_, str> {
    if !s.contains('&') {
        return std::borrow::Cow::Borrowed(s);
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        rest = &rest[amp..];
        let Some(semi) = rest.bytes().take(12).position(|b| b == b';') else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let entity = &rest[1..semi];
        let decoded = if let Some(num) = entity.strip_prefix('#') {
            let code = match num.strip_prefix(['x', 'X']) {
                Some(hex) => u32::from_str_radix(hex, 16).ok(),
                None => num.parse().ok(),
            };
            code.and_then(char::from_u32)
        } else {
            Some(match entity {
                "amp" => '&',
                "lt" => '<',
                "gt" => '>',
                "quot" => '"',
                "apos" => '\'',
                "nbsp" => '\u{a0}',
                "copy" => '©',
                "reg" => '®',
                "trade" => '™',
                "hellip" => '…',
                "mdash" => '—',
                "ndash" => '–',
                "rarr" => '→',
                "larr" => '←',
                "uarr" => '↑',
                "darr" => '↓',
                "times" => '×',
                "middot" => '·',
                "bull" => '•',
                "laquo" => '«',
                "raquo" => '»',
                "deg" => '°',
                "check" => '✓',
                "emsp" => '\u{2003}',
                "ensp" => '\u{2002}',
                "thinsp" => '\u{2009}',
                "zwj" => '\u{200d}',
                _ => {
                    out.push('&');
                    rest = &rest[1..];
                    continue;
                }
            })
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &rest[semi + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    std::borrow::Cow::Owned(out)
}

// -- Syntax highlighting with both themes at once ----------------------------

fn rgba(c: syntect::highlighting::Color) -> u32 {
    u32::from_be_bytes([c.r, c.g, c.b, c.a])
}

/// Highlights every code block, one thread per language (see
/// `highlight_code_blocks` for why), keyed by node address.
fn highlight_all<'a>(root: &'a AstNode<'a>) -> HashMap<usize, Segments> {
    let set = &*SYNTAXES;
    let mut jobs: Vec<(usize, &SyntaxReference, String)> = Vec::new();
    for node in root.descendants() {
        if let NodeValue::CodeBlock(cb) = &node.data().value {
            let lang = first_word(&cb.info);
            if cb.literal.len() > MAX_HIGHLIGHT_BLOCK || lang.is_empty() {
                continue;
            }
            if let Some(syntax) = find_syntax(set, lang) {
                jobs.push((node as *const _ as usize, syntax, cb.literal.clone()));
            }
        }
    }
    if jobs.is_empty() {
        return HashMap::new();
    }
    let mut groups: Vec<(&str, Vec<usize>)> = Vec::new();
    for (i, (_, syntax, _)) in jobs.iter().enumerate() {
        match groups.iter_mut().find(|(n, _)| *n == syntax.name) {
            Some((_, v)) => v.push(i),
            None => groups.push((&syntax.name, vec![i])),
        }
    }
    let work = |indices: &[usize]| -> Vec<(usize, Option<Segments>)> {
        indices.iter().map(|&i| (i, highlight_dual(jobs[i].1, &jobs[i].2))).collect()
    };
    let results = if groups.len() == 1 {
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
    results.into_iter().filter_map(|(i, segs)| Some((jobs[i].0, segs?))).collect()
}

/// Parses the code once and colours it with the light and the dark theme.
fn highlight_dual(syntax: &SyntaxReference, code: &str) -> Option<Segments> {
    let set = &*SYNTAXES;
    let (light_theme, dark_theme) = &*THEMES;
    let (hl_light, hl_dark) = (Highlighter::new(light_theme), Highlighter::new(dark_theme));
    let mut parse = ParseState::new(syntax);
    let mut st_light = HighlightState::new(&hl_light, ScopeStack::new());
    let mut st_dark = HighlightState::new(&hl_dark, ScopeStack::new());
    let mut out: Segments = Vec::new();
    for line in LinesWithEndings::from(code) {
        let ops = parse.parse_line(line, set).ok()?;
        let light: Vec<_> = RangedHighlightIterator::new(&mut st_light, &ops, line, &hl_light)
            .map(|(style, _, range)| (range.end, style))
            .collect();
        let dark: Vec<_> = RangedHighlightIterator::new(&mut st_dark, &ops, line, &hl_dark)
            .map(|(style, _, range)| (range.end, style.foreground))
            .collect();
        // Split the line at the union of both themes' boundaries.
        let (mut i, mut j, mut pos) = (0, 0, 0);
        while pos < line.len() && i < light.len() && j < dark.len() {
            let end = light[i].0.min(dark[j].0);
            let style = light[i].1;
            let mut font = 0;
            if style.font_style.contains(syntect::highlighting::FontStyle::BOLD) {
                font |= run::TOKEN_BOLD;
            }
            if style.font_style.contains(syntect::highlighting::FontStyle::ITALIC) {
                font |= run::TOKEN_ITALIC;
            }
            let (l, d) = (rgba(style.foreground), rgba(dark[j].1));
            let piece = &line[pos..end];
            match out.last_mut() {
                Some(last) if last.1 == l && last.2 == d && last.3 == font => last.0.push_str(piece),
                _ => out.push((piece.to_owned(), l, d, font)),
            }
            pos = end;
            if light[i].0 == end {
                i += 1;
            }
            if dark[j].0 == end {
                j += 1;
            }
        }
    }
    Some(out)
}

// ---------------------------------------------------------------------------
// Decoding (used by tests and the CLI's --native dump)
// ---------------------------------------------------------------------------

/// A decoded document, for tests and debugging.
#[derive(Debug, Default)]
pub struct Decoded {
    pub text: String,
    pub strings: Vec<String>,
    pub blocks: Vec<(u8, u8, u16, u32, u32, u32)>,
    pub paras: Vec<(u32, u32, u16, u8, u8, u32)>,
    pub runs: Vec<(u32, u32, u32, u32, u32, u32, u32)>,
}

impl Decoded {
    pub fn parse(bytes: &[u8]) -> Option<Decoded> {
        let mut r = Reader { b: bytes, i: 0 };
        if r.take(4)? != MAGIC {
            return None;
        }
        let mut d = Decoded::default();
        let n = r.u32()? as usize;
        d.text = String::from_utf8(r.take(n)?.to_vec()).ok()?;
        for _ in 0..r.u32()? {
            let n = r.u32()? as usize;
            d.strings.push(String::from_utf8(r.take(n)?.to_vec()).ok()?);
        }
        for _ in 0..r.u32()? {
            let h = r.take(4)?;
            d.blocks.push((h[0], h[1], u16::from_le_bytes([h[2], h[3]]), r.u32()?, r.u32()?, r.u32()?));
        }
        for _ in 0..r.u32()? {
            let (s, l) = (r.u32()?, r.u32()?);
            let h = r.take(4)?;
            d.paras.push((s, l, u16::from_le_bytes([h[0], h[1]]), h[2], h[3], r.u32()?));
        }
        for _ in 0..r.u32()? {
            d.runs.push((r.u32()?, r.u32()?, r.u32()?, r.u32()?, r.u32()?, r.u32()?, r.u32()?));
        }
        (r.i == bytes.len()).then_some(d)
    }

    /// Text of a UTF-16 range.
    pub fn slice(&self, start: u32, len: u32) -> String {
        let units: Vec<u16> = self.text.encode_utf16().skip(start as usize).take(len as usize).collect();
        String::from_utf16_lossy(&units)
    }
}

struct Reader<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let s = self.b.get(self.i..self.i + n)?;
        self.i += n;
        Some(s)
    }
    fn u32(&mut self) -> Option<u32> {
        self.take(4).map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(md: &str) -> Decoded {
        Decoded::parse(&render_native(md, None, false)).expect("valid encoding")
    }

    fn para_text(d: &Decoded, i: usize) -> String {
        let p = d.paras[i];
        d.slice(p.0, p.1)
    }

    #[test]
    fn paragraphs_and_inline_styles() {
        let d = doc("# Title\n\nSome **bold** and *it* and `code` [link](https://x.y).\n");
        assert_eq!(d.text, "Title\nSome bold and it and code link.\n");
        assert_eq!(d.paras.len(), 2);
        assert_eq!((d.paras[0].3, d.paras[0].4), (para::HEADING, 1));
        assert_eq!(d.strings[(d.paras[0].5 - 1) as usize], "title");
        let bold = d.runs.iter().find(|r| r.2 & run::BOLD != 0).unwrap();
        assert_eq!(d.slice(bold.0, bold.1), "bold");
        let link = d.runs.iter().find(|r| r.2 & run::LINK != 0).unwrap();
        assert_eq!(d.strings[(link.5 - 1) as usize], "https://x.y");
        assert_eq!(d.slice(link.0, link.1), "link");
    }

    #[test]
    fn utf16_offsets() {
        let d = doc("😀 **b**\n");
        let bold = d.runs.iter().find(|r| r.2 & run::BOLD != 0).unwrap();
        assert_eq!(bold.0, 3, "emoji is two UTF-16 units plus a space");
        assert_eq!(d.slice(bold.0, bold.1), "b");
    }

    #[test]
    fn lists_and_tasks() {
        let d = doc("- a\n- b\n  1. c\n- [x] done\n- [ ] todo\n");
        assert!(para_text(&d, 0).starts_with("•\ta"));
        assert!(d.paras[0].5 & para::LIST_MARKER != 0);
        assert!(para_text(&d, 2).starts_with("1.\tc"));
        let checks: Vec<_> = d.runs.iter().filter(|r| r.2 & run::ATTACHMENT != 0).map(|r| r.3).collect();
        assert_eq!(checks, vec![attach::CHECKBOX_ON, attach::CHECKBOX_OFF]);
        let depths: Vec<u32> = d.blocks.iter().filter(|b| b.0 == block::LIST_ITEM).map(|b| b.3).collect();
        assert_eq!(depths, vec![1, 1, 2, 1, 1]);
    }

    #[test]
    fn mermaid_blocks_become_diagrams() {
        let d = doc("```mermaid\nflowchart LR\n  A --> B\n```\n\n```mermaid\nnot a diagram\n```\n");
        let diagrams: Vec<_> = d.runs.iter().filter(|r| r.2 & run::ATTACHMENT != 0 && r.3 == attach::DIAGRAM).collect();
        assert_eq!(diagrams.len(), 1);
        assert_eq!(d.strings[diagrams[0].4 as usize], "flowchart LR\n  A --> B\n");
        assert_eq!(d.paras[0].3, para::MATH);
        // What does not parse stays a code block.
        assert_eq!(d.paras[1].3, para::CODE);
        assert_eq!(para_text(&d, 1), "not a diagram\n");
    }

    #[test]
    fn code_blocks_carry_both_theme_colours() {
        let d = doc("```rust\nfn main() {}\n```\n");
        assert_eq!(d.paras[0].3, para::CODE);
        assert_eq!(para_text(&d, 0), "fn main() {}\n");
        let d = doc("```rust\nfn a() {}\n// b\nlet c = 1;\n```\n");
        assert_eq!(para_text(&d, 0), "fn a() {}\n// b\nlet c = 1;\n", "line breaks survive highlighting");
        let tokens: Vec<_> = d.runs.iter().filter(|r| r.2 & run::TOKEN != 0).collect();
        assert!(tokens.len() >= 3);
        assert!(tokens.iter().any(|r| r.3 != r.4), "light and dark colours differ");
        let code = d.blocks.iter().find(|b| b.0 == block::CODE).unwrap();
        assert_eq!(d.strings[(code.3 - 1) as usize], "rust");
    }

    #[test]
    fn tables() {
        let d = doc("| a | b |\n|:--|--:|\n| 1 | 2 |\n");
        let table = d.blocks.iter().find(|b| b.0 == block::TABLE).unwrap();
        assert_eq!((table.3, table.4), (2, 2));
        let cells: Vec<_> = d.paras.iter().filter(|p| p.3 == para::TABLE_CELL).collect();
        assert_eq!(cells.len(), 4);
        assert_eq!(cells[1].4, 1, "column index");
        assert_eq!(cells[1].5 & 0xff, 3, "right aligned");
        assert!(d.runs.iter().any(|r| r.2 & run::BOLD != 0 && d.slice(r.0, r.1) == "a"), "header is bold");
    }

    #[test]
    fn math_and_images() {
        let d = doc("Inline $x^2$.\n\n$$\n\\frac{1}{2}\n$$\n\n![b](https://img.shields.io/badge/License-MIT-yellow) ![r](https://x.org/a.png)\n");
        let kinds: Vec<_> = d.runs.iter().filter(|r| r.2 & run::ATTACHMENT != 0).map(|r| (r.3, d.strings[r.4 as usize].clone())).collect();
        assert_eq!(kinds[0], (attach::MATH_INLINE, "x^2".into()));
        assert_eq!(kinds[1].0, attach::MATH_DISPLAY);
        assert_eq!(d.paras[1].3, para::MATH);
        assert_eq!(kinds[2], (attach::BADGE, "License".into()));
        assert_eq!(kinds[3], (attach::REMOTE_IMAGE, "https://x.org/a.png".into()));
        let badge = d.runs.iter().find(|r| r.3 == attach::BADGE).unwrap();
        assert_eq!(&d.strings[badge.4 as usize..badge.4 as usize + 3], ["License", "MIT", "#dfb317"]);
    }

    #[test]
    fn quotes_alerts_rules() {
        let d = doc("> quote\n\n> [!WARNING]\n> careful\n\n---\n");
        assert!(d.blocks.iter().any(|b| b.0 == block::QUOTE));
        let alert = d.blocks.iter().find(|b| b.0 == block::ALERT).unwrap();
        assert_eq!(alert.3, 3);
        assert!(d.text.contains("⚠  Warning\ncareful\n"));
        assert!(d.paras.iter().any(|p| p.3 == para::RULE));
    }

    #[test]
    fn raw_html_subset() {
        let d = doc("<p align=\"center\"><img src=\"https://x/a.png\" alt=\"logo\" width=\"64\"></p>\n\nPress <kbd>⌘</kbd> and <b>go</b><br>next\n\n<details>\n<summary>More</summary>\n\nHidden **text**\n\n</details>\n");
        assert_eq!((d.paras[0].5 >> para::ALIGN_SHIFT) & 3, 2, "centered");
        let img = d.runs.iter().find(|r| r.3 == attach::REMOTE_IMAGE).unwrap();
        assert_eq!(img.6, 64);
        assert!(d.runs.iter().any(|r| r.2 & run::KBD != 0 && d.slice(r.0, r.1) == "⌘"));
        assert!(d.text.contains("go\u{2028}next"));
        assert!(d.paras.iter().any(|p| p.3 == para::SUMMARY));
        assert!(d.text.contains("Hidden text"));
        assert!(d.blocks.iter().any(|b| b.0 == block::DETAILS && b.1 & block::OPEN == 0));
        let open = doc("<details open>\n<summary>More</summary>\n\nShown\n\n</details>\n");
        assert!(open.blocks.iter().any(|b| b.0 == block::DETAILS && b.1 & block::OPEN != 0));
        let d = doc("<script>alert(1)</script>\n\n<style>p{}</style>\n\nok\n");
        assert_eq!(d.text, "ok\n", "script and style contents are dropped");
    }

    #[test]
    fn footnotes_and_front_matter() {
        let d = doc("---\ntitle: Hi\n---\nText[^n].\n\n[^n]: The note.\n");
        assert!(d.text.starts_with("FRONT MATTER\ntitle\nHi\n"));
        assert!(d.text.contains("Text[1]."));
        assert!(d.text.contains("1.\tThe note."));
        let d2 = doc("- a\n- b\n\nx[^1] y[^2]\n\n[^1]: one\n[^2]: two\n");
        assert!(d2.text.contains("1.\tone\n") && d2.text.contains("2.\ttwo\n"), "footnotes numbered on their own");
        assert!(d.strings.iter().any(|s| s == "#fn-n"));
    }

    /// Random documents assembled from tricky fragments must never panic and
    /// must always produce a well-formed layout.
    #[test]
    fn survives_random_documents() {
        const PIECES: &[&str] = &[
            "# ", "## ", "- ", "1. ", "> ", "> [!NOTE]\n", "```rust\n", "```\n", "```math\n", "|a|b|\n|-|-|\n", "| x |",
            "**", "*", "_", "`", "~~", "==", "[link](", ")", "![img](", "https://x.y/z.png", "<", ">", "</", "<br>",
            "<img src=\"a.png\" alt=\"•\">", "<div align=\"center\">", "</div>", "<details>", "<summary>",
            "</summary>", "</details>", "<script>", "</script>", "<!--", "-->", "&amp;", "&#x1F600;", "&nbsp;", "&",
            "$", "$$", "\\frac{1}{2}", "[^1]", "[^1]: note\n", "---\n", "\n", "\n\n", "  ", "\t", "•", "😀", "ğüşİ",
            "日本語", "\u{200d}", "é", "<kbd>", "</kbd>", "<a href=\"#x\">", "</a>", "- [x] ", "- [ ] ", "[[wiki]]",
            ":rocket:", "\\", "text ", "word",
        ];
        let mut seed: u64 = 0x2545_f491_4f6c_dd1d;
        for _ in 0..3000 {
            let mut md = String::new();
            for _ in 0..(seed % 40) {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                md.push_str(PIECES[(seed % PIECES.len() as u64) as usize]);
            }
            // The HTML renderer sees the same inputs.
            let _ = crate::render_document(&md, &crate::RenderOptions::default());
            let bytes = render_native(&md, None, false);
            let d = Decoded::parse(&bytes).unwrap_or_else(|| panic!("malformed layout for {md:?}"));
            let total = d.text.encode_utf16().count() as u32;
            for p in &d.paras {
                assert!(p.0 + p.1 <= total, "paragraph out of range for {md:?}");
            }
            for r in &d.runs {
                assert!(r.0 + r.1 <= total, "run out of range for {md:?}");
            }
        }
    }

    #[test]
    fn every_paragraph_ends_with_newline_and_ranges_are_ordered() {
        let md = include_str!("../../examples/showcase.md");
        let d = doc(md);
        let total = d.text.encode_utf16().count() as u32;
        let mut pos = 0;
        for p in &d.paras {
            assert!(p.0 >= pos, "paragraphs are ordered");
            assert!(d.slice(p.0, p.1).ends_with('\n'));
            pos = p.0 + p.1;
        }
        assert!(pos <= total);
        for r in &d.runs {
            assert!(r.0 + r.1 <= total);
        }
    }
}

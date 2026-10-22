//! Mermaid diagrams, without a browser: laid out by mermaid-rs-renderer and
//! drawn into a bitmap with resvg.

use std::sync::{Arc, LazyLock};

use mermaid_rs_renderer::{RenderOptions, Theme, render_with_options};
use resvg::{tiny_skia, usvg};

/// Fonts for the labels. Only these files are loaded (scanning every system
/// font would cost far more than a diagram takes to draw).
const FONT_FILES: &[&str] = &[
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Helvetica.ttc",
];
const FONT_FAMILY: &str = "Helvetica Neue, Helvetica, Arial, sans-serif";

/// Diagrams are never drawn wider or taller than this many pixels.
const MAX_PIXELS: f32 = 8192.0;

static FONTS: LazyLock<Arc<usvg::fontdb::Database>> = LazyLock::new(|| {
    let mut db = usvg::fontdb::Database::new();
    for file in FONT_FILES {
        let _ = db.load_font_file(file);
    }
    db.set_sans_serif_family("Helvetica Neue");
    Arc::new(db)
});

const PIE_LIGHT: [&str; 12] = [
    "#B6D4FE", "#B7E4C7", "#FDE2A7", "#D9C7FB", "#FBC4C4", "#B3E5E9", "#F7C6E0", "#FCD2B5", "#D0D7DE",
    "#9EC5FE", "#A7E3B5", "#FDD0A2",
];
const PIE_DARK: [&str; 12] = [
    "#1F4E8C", "#1F5E33", "#6B4F12", "#4E3A8A", "#7A2B2B", "#1D5C63", "#6E2A50", "#7A4317", "#3D444D",
    "#24508F", "#2B6B3F", "#7A5A1D",
];

/// A drawn diagram: premultiplied RGBA pixels, and its size in points.
pub struct Bitmap {
    pub width: u32,
    pub height: u32,
    pub points: (f32, f32),
    pub rgba: Vec<u8>,
}

/// Whether `source` is a diagram mermaid-rs-renderer understands (cheap: parses only).
pub fn is_diagram(source: &str) -> bool {
    mermaid_rs_renderer::parse_mermaid(source).is_ok()
}

/// The diagram as SVG, in the light or dark theme.
pub fn svg(source: &str, dark: bool) -> Option<String> {
    render_with_options(source, RenderOptions { theme: theme(dark), ..RenderOptions::default() }).ok()
}

/// mermaid-rs-renderer's "modern" theme, and a dark version of it in the
/// preview's dark palette (its own dark theme uses other sizes and black
/// boxes). Both have the same metrics, so a diagram keeps its size when the
/// appearance changes.
fn theme(dark: bool) -> Theme {
    let mut theme = Theme::modern();
    theme.font_family = FONT_FAMILY.to_owned();
    theme.background = "transparent".to_owned();
    // The stock pie slices are near-white; these stay apart, with the
    // page's text colour readable on them.
    theme.pie_colors = if dark { PIE_DARK } else { PIE_LIGHT }.map(str::to_owned);
    if dark {
        let set = |field: &mut String, value: &str| *field = value.to_owned();
        let text = "#E6EDF3";
        set(&mut theme.primary_color, "#262A30");
        set(&mut theme.primary_text_color, text);
        set(&mut theme.primary_border_color, "#59636E");
        set(&mut theme.line_color, "#9198A1");
        set(&mut theme.secondary_color, "#30363D");
        set(&mut theme.tertiary_color, "#1E1E1E");
        set(&mut theme.edge_label_background, "#1E1E1E");
        set(&mut theme.cluster_background, "#23272C");
        set(&mut theme.cluster_border, "#3D444D");
        set(&mut theme.sequence_actor_fill, "#262A30");
        set(&mut theme.sequence_actor_border, "#59636E");
        set(&mut theme.sequence_actor_line, "#9198A1");
        set(&mut theme.sequence_note_fill, "#3A3020");
        set(&mut theme.sequence_note_border, "#9A6700");
        set(&mut theme.sequence_activation_fill, "#30363D");
        set(&mut theme.sequence_activation_border, "#59636E");
        set(&mut theme.text_color, text);
        set(&mut theme.git_commit_label_color, text);
        set(&mut theme.git_commit_label_background, "#30363D");
        set(&mut theme.pie_title_text_color, text);
        set(&mut theme.pie_section_text_color, text);
        set(&mut theme.pie_legend_text_color, text);
        set(&mut theme.pie_stroke_color, "#1E1E1E");
        set(&mut theme.pie_outer_stroke_color, "#3D444D");
    }
    theme
}

/// Draws the diagram at `scale` pixels per point.
pub fn render(source: &str, dark: bool, scale: f32) -> Option<Bitmap> {
    let svg = svg(source, dark)?;
    let options = usvg::Options { fontdb: FONTS.clone(), ..usvg::Options::default() };
    let tree = usvg::Tree::from_str(&svg, &options).ok()?;
    let size = tree.size();
    // Input the lenient parser accepted but could not make sense of comes
    // out as an empty 16 x 16 picture: report it so the source is shown.
    if size.width() <= 16.0 && size.height() <= 16.0 {
        return None;
    }
    let scale = scale.min(MAX_PIXELS / size.width().max(size.height())).max(0.1);
    let width = (size.width() * scale).ceil() as u32;
    let height = (size.height() * scale).ceil() as u32;
    let mut pixmap = tiny_skia::Pixmap::new(width.max(1), height.max(1))?;
    resvg::render(&tree, tiny_skia::Transform::from_scale(scale, scale), &mut pixmap.as_mut());
    Some(Bitmap { width, height, points: (size.width(), size.height()), rgba: pixmap.take() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draws_a_flowchart() {
        let bitmap = render("flowchart LR\n  A[Start] --> B{Choice}\n  B --> C[End]\n", false, 2.0).unwrap();
        assert!(bitmap.points.0 > 50.0 && bitmap.points.1 > 10.0);
        assert_eq!(bitmap.rgba.len(), (bitmap.width * bitmap.height * 4) as usize);
        // Something was drawn, and the background stayed transparent.
        assert!(bitmap.rgba.chunks(4).any(|p| p[3] == 255));
        assert_eq!(bitmap.rgba[3], 0);
    }

    #[test]
    fn rejects_what_it_cannot_parse() {
        assert!(is_diagram("sequenceDiagram\n  A->>B: hi\n"));
        assert!(!is_diagram("this is not a diagram"));
        // Parses, but holds nothing to draw.
        assert!(render("flowchart TD\n  A[unclosed --> B\n", false, 2.0).is_none());
    }
}

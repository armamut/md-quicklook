//! Regenerates the syntax-highlighting stylesheets:
//! `cargo run --example gen_css`
use syntect::html::{ClassStyle, css_for_theme_with_class_style};
use two_face::theme::EmbeddedThemeName;

fn main() {
    let themes = two_face::theme::extra();
    let style = ClassStyle::SpacedPrefixed { prefix: mdql::HIGHLIGHT_PREFIX };
    for (file, theme) in [("highlight-light.css", EmbeddedThemeName::Github), ("highlight-dark.css", EmbeddedThemeName::OneHalfDark)] {
        let css = css_for_theme_with_class_style(themes.get(theme), style).expect("theme converts to CSS");
        let path = format!("{}/assets/{file}", env!("CARGO_MANIFEST_DIR"));
        std::fs::write(&path, css).expect("write stylesheet");
        eprintln!("wrote {path}");
    }
}

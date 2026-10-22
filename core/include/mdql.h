#ifndef MDQL_H
#define MDQL_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    MDQL_THEME_AUTO = 0,  ///< follow prefers-color-scheme
    MDQL_THEME_LIGHT = 1,
    MDQL_THEME_DARK = 2,
} mdql_theme;

/// Let the page load http(s) images such as README badges. Without it they
/// are replaced by their alt text, so previewing never touches the network.
#define MDQL_FLAG_REMOTE_IMAGES 1u

/// Renders Markdown bytes into a self-contained HTML document.
/// base_dir (for relative images) and title may be NULL; flags combines
/// MDQL_FLAG_* values.
/// Returns NULL on failure; otherwise free the result with mdql_free().
uint8_t *mdql_render_html(const uint8_t *data, size_t len,
                          const char *base_dir, const char *title,
                          uint32_t theme, uint32_t flags, size_t *out_len);

/// Renders Markdown bytes into the native layout below (for TextKit).
/// Returns NULL on failure; otherwise free the result with mdql_free().
///
/// Layout, all integers little-endian, offsets/lengths in UTF-16 units:
///   "MDQ1"
///   u32 n, n bytes                      text (UTF-8; U+FFFC marks attachments)
///   u32 n, n x { u32 len, bytes }       string table (URLs, paths, LaTeX…)
///   u32 n, n x 16-byte blocks           { u8 kind, u8 flags, u16 parent, u32 a, b, c }
///   u32 n, n x 16-byte paragraphs       { u32 start, len, u16 block, u8 kind, u8 level, u32 extra }
///   u32 n, n x 28-byte runs             { u32 start, len, flags, a, b, c, d }
/// Kinds and flags are defined in core/src/native.rs (modules block, para,
/// run, attach) and mirrored in macos/Native/NativeDocument.swift.
uint8_t *mdql_render_native(const uint8_t *data, size_t len,
                            const char *base_dir, uint32_t flags,
                            size_t *out_len);

/// Lays out and draws a Mermaid diagram (the string of a DIAGRAM attachment)
/// at `scale` pixels per point, dark themed when `dark` is non-zero. Returns
/// premultiplied RGBA, *width x *height x 4 bytes (free with mdql_free()),
/// and the diagram's size in points; NULL if it cannot be drawn.
uint8_t *mdql_render_mermaid(const uint8_t *source, size_t len, uint32_t dark,
                             float scale, uint32_t *width, uint32_t *height,
                             float *points_width, float *points_height);

/// Releases a buffer returned by mdql_render_html(), mdql_render_native() or
/// mdql_render_mermaid().
void mdql_free(uint8_t *ptr, size_t len);

/// Number of languages accepted by mdql_warm_up_language().
size_t mdql_warm_up_count(void);

/// Compiles one common language's grammar ahead of time (optional).
/// Safe to call concurrently; lower indices are the most expensive.
void mdql_warm_up_language(size_t index);

/// Entry point of app extensions (Foundation).
int NSExtensionMain(int argc, char *_Nullable argv[_Nonnull]);

#endif

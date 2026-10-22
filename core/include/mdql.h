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

/// Releases a buffer returned by mdql_render_html().
void mdql_free(uint8_t *ptr, size_t len);

/// Number of languages accepted by mdql_warm_up_language().
size_t mdql_warm_up_count(void);

/// Compiles one common language's grammar ahead of time (optional).
/// Safe to call concurrently; lower indices are the most expensive.
void mdql_warm_up_language(size_t index);

/// Entry point of app extensions (Foundation).
int NSExtensionMain(int argc, char *_Nullable argv[_Nonnull]);

#endif

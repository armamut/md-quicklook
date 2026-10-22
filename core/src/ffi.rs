//! C ABI used by the Swift Quick Look extensions. See `include/mdql.h`.

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;

use crate::{RenderOptions, Theme, decode_text, render_document};

/// Allow `http(s)` images (see [`RenderOptions::remote_images`]).
const FLAG_REMOTE_IMAGES: u32 = 1;

/// Renders `len` bytes of Markdown at `data` into a complete HTML document.
///
/// `base_dir` and `title` are optional NUL-terminated UTF-8 strings;
/// `theme` is 0 (follow `prefers-color-scheme`), 1 (light) or 2 (dark);
/// `flags` is a combination of the `MDQL_FLAG_*` values in `mdql.h`. On
/// success the returned buffer holds `*out_len` bytes of UTF-8 HTML and must
/// be released with [`mdql_free`]. Returns NULL on failure.
///
/// # Safety
/// `data` must point to `len` readable bytes; string arguments must be NULL
/// or valid NUL-terminated strings; `out_len` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdql_render_html(
    data: *const u8,
    len: usize,
    base_dir: *const c_char,
    title: *const c_char,
    theme: u32,
    flags: u32,
    out_len: *mut usize,
) -> *mut u8 {
    if out_len.is_null() || (data.is_null() && len != 0) {
        return std::ptr::null_mut();
    }
    let bytes = if len == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(data, len) } };
    let base_dir = unsafe { opt_str(base_dir) }.map(PathBuf::from);
    let title = unsafe { opt_str(title) }.map(str::to_owned);

    let result = catch_unwind(AssertUnwindSafe(|| {
        let text = decode_text(bytes);
        let theme = match theme {
            1 => Theme::Light,
            2 => Theme::Dark,
            _ => Theme::Auto,
        };
        let remote_images = flags & FLAG_REMOTE_IMAGES != 0;
        render_document(&text, &RenderOptions { base_dir, title, theme, remote_images })
    }));
    match result {
        Ok(html) => {
            let boxed = html.into_bytes().into_boxed_slice();
            unsafe { *out_len = boxed.len() };
            Box::into_raw(boxed) as *mut u8
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// Renders Markdown into the native layout described in `mdql.h`, for
/// drawing with TextKit instead of a web view. Same ownership rules as
/// [`mdql_render_html`].
///
/// # Safety
/// As for [`mdql_render_html`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdql_render_native(
    data: *const u8,
    len: usize,
    base_dir: *const c_char,
    flags: u32,
    out_len: *mut usize,
) -> *mut u8 {
    if out_len.is_null() || (data.is_null() && len != 0) {
        return std::ptr::null_mut();
    }
    let bytes = if len == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(data, len) } };
    let base_dir = unsafe { opt_str(base_dir) }.map(PathBuf::from);
    let result = catch_unwind(AssertUnwindSafe(|| {
        let text = decode_text(bytes);
        crate::native::render_native(&text, base_dir.as_deref(), flags & FLAG_REMOTE_IMAGES != 0)
    }));
    match result {
        Ok(buf) => {
            let boxed = buf.into_boxed_slice();
            unsafe { *out_len = boxed.len() };
            Box::into_raw(boxed) as *mut u8
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// Releases a buffer returned by [`mdql_render_html`] or [`mdql_render_native`].
///
/// # Safety
/// `ptr`/`len` must come from a single successful `mdql_render_html` call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdql_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}

/// Number of languages accepted by [`mdql_warm_up_language`].
#[unsafe(no_mangle)]
pub extern "C" fn mdql_warm_up_count() -> usize {
    crate::warm_up_count()
}

/// Compiles the grammar of one common language ahead of time. Indices may be
/// processed concurrently from several threads; the most expensive come first.
#[unsafe(no_mangle)]
pub extern "C" fn mdql_warm_up_language(index: usize) {
    let _ = catch_unwind(|| crate::warm_up_language(index));
}

unsafe fn opt_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok().filter(|s| !s.is_empty())
}

/// Lays out and draws a Mermaid diagram at `scale` pixels per point, in the
/// dark theme when `dark` is non-zero. Returns premultiplied RGBA pixels
/// (`*width` x `*height` x 4 bytes, release with [`mdql_free`]) and the
/// diagram's size in points, or NULL if it cannot be drawn.
///
/// # Safety
/// `source` must point to `len` readable bytes; the out-pointers must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdql_render_mermaid(
    source: *const u8,
    len: usize,
    dark: u32,
    scale: f32,
    width: *mut u32,
    height: *mut u32,
    points_width: *mut f32,
    points_height: *mut f32,
) -> *mut u8 {
    if source.is_null() || width.is_null() || height.is_null() || points_width.is_null() || points_height.is_null() {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(source, len) };
    let result = catch_unwind(AssertUnwindSafe(|| {
        crate::mermaid::render(&String::from_utf8_lossy(bytes), dark != 0, scale)
    }));
    match result {
        Ok(Some(bitmap)) => {
            unsafe {
                *width = bitmap.width;
                *height = bitmap.height;
                *points_width = bitmap.points.0;
                *points_height = bitmap.points.1;
            }
            Box::into_raw(bitmap.rgba.into_boxed_slice()) as *mut u8
        }
        _ => std::ptr::null_mut(),
    }
}

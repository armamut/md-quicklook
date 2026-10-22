//! Command-line front end: `mdql [FILE] [-o OUT.html] [--theme auto|light|dark] [--remote-images] [--native] [--fragment] [--bench N]`.
//! Reads standard input when no file is given.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::Instant;

fn main() {
    let mut input: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut fragment = false;
    let mut bench = 0usize;
    let mut theme = mdql::Theme::Auto;
    let mut remote_images = false;
    let mut native = false;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-o" | "--output" => output = args.next().map(PathBuf::from),
            "--fragment" => fragment = true,
            "--remote-images" => remote_images = true,
            "--native" => native = true,
            "--theme" => {
                theme = match args.next().as_deref() {
                    Some("light") => mdql::Theme::Light,
                    Some("dark") => mdql::Theme::Dark,
                    Some("auto") => mdql::Theme::Auto,
                    _ => fail("--theme expects auto, light or dark"),
                }
            }
            "--bench" => bench = args.next().and_then(|n| n.parse().ok()).unwrap_or(100),
            "-h" | "--help" => {
                println!("usage: mdql [FILE] [-o OUT.html] [--theme auto|light|dark] [--remote-images] [--native] [--fragment] [--bench N]");
                return;
            }
            _ => input = Some(PathBuf::from(arg)),
        }
    }

    let bytes = match &input {
        Some(p) => std::fs::read(p).unwrap_or_else(|e| fail(&format!("{}: {e}", p.display()))),
        None => {
            let mut b = Vec::new();
            std::io::stdin().read_to_end(&mut b).unwrap_or_else(|e| fail(&e.to_string()));
            b
        }
    };
    let opts = mdql::RenderOptions {
        base_dir: input
            .as_ref()
            .and_then(|p| std::fs::canonicalize(p).ok())
            .and_then(|p| p.parent().map(PathBuf::from)),
        title: input.as_ref().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().into_owned()),
        theme,
        remote_images,
    };
    let text = mdql::decode_text(&bytes);
    let render = || {
        if native {
            // Bench the binary layout; print a readable dump of it otherwise.
            let bytes = mdql::native::render_native(&text, opts.base_dir.as_deref(), opts.remote_images);
            if bench > 0 { format!("{}", bytes.len()) } else { native_dump(&bytes) }
        } else if fragment {
            mdql::render_fragment(&text, &opts)
        } else {
            mdql::render_document(&text, &opts)
        }
    };

    if bench > 0 {
        let t = Instant::now();
        let first = render();
        let cold = t.elapsed();
        let t = Instant::now();
        for _ in 0..bench {
            std::hint::black_box(render());
        }
        let warm = t.elapsed() / bench as u32;
        eprintln!(
            "input {} KiB, output {} KiB, first render {:.2?}, average of {bench} {:.2?}",
            bytes.len() / 1024,
            first.len() / 1024,
            cold,
            warm
        );
        return;
    }

    let html = render();
    match output {
        Some(p) => std::fs::write(&p, html).unwrap_or_else(|e| fail(&format!("{}: {e}", p.display()))),
        None => std::io::stdout().write_all(html.as_bytes()).unwrap_or_else(|e| fail(&e.to_string())),
    }
}

fn native_dump(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let d = mdql::native::Decoded::parse(bytes).unwrap_or_else(|| fail("invalid native layout"));
    let mut out = String::new();
    let _ = writeln!(out, "{} bytes, {} paragraphs, {} runs, {} blocks, {} strings", bytes.len(), d.paras.len(), d.runs.len(), d.blocks.len(), d.strings.len());
    for (i, b) in d.blocks.iter().enumerate() {
        let _ = writeln!(out, "block {i}: kind={} flags={} parent={} a={} b={}", b.0, b.1, b.2 as i32 - if b.2 == u16::MAX { 65536 } else { 0 }, b.3, b.4);
    }
    for p in &d.paras {
        let _ = writeln!(out, "para kind={} level={} block={} extra={:#x} {:?}", p.3, p.4, p.2, p.5, d.slice(p.0, p.1));
    }
    for r in &d.runs {
        let _ = writeln!(out, "  run flags={:#x} a={:#x} b={:#x} c={} d={} {:?}", r.2, r.3, r.4, r.5, r.6, d.slice(r.0, r.1));
    }
    out
}

fn fail(msg: &str) -> ! {
    eprintln!("mdql: {msg}");
    std::process::exit(1)
}

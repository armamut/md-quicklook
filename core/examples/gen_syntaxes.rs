//! Regenerates `assets/syntaxes.packdump`:
//! `cargo run --release --example gen_syntaxes`
//!
//! Takes bat's syntax collection (via two-face) and rewrites Unicode
//! character classes inside bracket expressions — `[:alpha:]`, `\w` and
//! friends — into plain code-point ranges. Oniguruma expands each Unicode
//! class into thousands of ranges every time a regex is compiled, which made
//! the first use of a language cost up to ~45 ms (TypeScript). The rewritten
//! classes match exactly the same ASCII text and treat every non-ASCII
//! character as a letter, which is what source-code grammars want anyway.

use syntect::parsing::syntax_definition::{Context, Pattern};
use syntect::parsing::{Regex, SyntaxSet, SyntaxSetBuilder};

const NON_ASCII: &str = r"\x{80}-\x{10FFFF}";

fn main() {
    let source = two_face::syntax::extra_newlines().into_builder();
    let mut builder = SyntaxSetBuilder::new();
    let (mut total, mut changed) = (0usize, 0usize);
    for syntax in source.syntaxes() {
        let mut syntax = syntax.clone();
        for context in syntax.contexts.values_mut() {
            rewrite_context(context, &mut total, &mut changed);
        }
        builder.add(syntax);
    }
    let set: SyntaxSet = builder.build();
    let out = concat!(env!("CARGO_MANIFEST_DIR"), "/assets/syntaxes.packdump");
    syntect::dumps::dump_to_uncompressed_file(&set, out).expect("write dump");
    eprintln!("{} syntaxes, rewrote {changed} of {total} patterns -> {out}", set.syntaxes().len());
}

fn rewrite_context(context: &mut Context, total: &mut usize, changed: &mut usize) {
    for pattern in &mut context.patterns {
        if let Pattern::Match(m) = pattern {
            *total += 1;
            let new = rewrite(m.regex.regex_str());
            if new != m.regex.regex_str() {
                *changed += 1;
                m.regex = Regex::new(new);
            }
        }
    }
}

/// Rewrites Unicode classes that appear inside `[...]` bracket expressions.
fn rewrite(re: &str) -> String {
    let posix: [(&str, String); 6] = [
        ("[:alpha:]", format!("a-zA-Z{NON_ASCII}")),
        ("[:alnum:]", format!("a-zA-Z0-9{NON_ASCII}")),
        ("[:word:]", format!("a-zA-Z0-9_{NON_ASCII}")),
        ("[:upper:]", "A-Z".to_owned()),
        ("[:lower:]", format!("a-z{NON_ASCII}")),
        ("[:digit:]", "0-9".to_owned()),
    ];
    let mut out = String::with_capacity(re.len() + 32);
    let mut depth = 0usize;
    let mut i = 0;
    let b = re.as_bytes();
    while i < re.len() {
        let rest = &re[i..];
        if b[i] == b'\\' {
            let next = rest[1..].chars().next();
            if next == Some('p') {
                if let Some((len, ranges)) = unicode_property(&rest[2..]) {
                    if depth > 0 {
                        out.push_str(&ranges);
                    } else {
                        out.push('[');
                        out.push_str(&ranges);
                        out.push(']');
                    }
                    i += 2 + len;
                    continue;
                }
            }
            match next {
                Some('w') if depth > 0 => out.push_str(&format!("a-zA-Z0-9_{NON_ASCII}")),
                Some('d') if depth > 0 => out.push_str("0-9"),
                Some(c) => {
                    out.push('\\');
                    out.push(c);
                }
                None => out.push('\\'),
            }
            i += 1 + next.map_or(0, char::len_utf8);
            continue;
        }
        if depth > 0 {
            if let Some((name, rep)) = posix.iter().find(|(n, _)| rest.starts_with(n)) {
                out.push_str(rep);
                i += name.len();
                continue;
            }
            if rest.starts_with("[:") {
                // Some other POSIX class: copy verbatim.
                if let Some(end) = rest.find(":]") {
                    out.push_str(&rest[..end + 2]);
                    i += end + 2;
                    continue;
                }
            }
        }
        match b[i] {
            b'[' => {
                depth += 1;
                out.push('[');
                i += 1;
                // A leading '^' and a leading ']' are part of the class.
                if re[i..].starts_with('^') {
                    out.push('^');
                    i += 1;
                }
                if re[i..].starts_with(']') {
                    out.push(']');
                    i += 1;
                }
                continue;
            }
            b']' if depth > 0 => depth -= 1,
            _ => {}
        }
        let c = rest.chars().next().unwrap();
        out.push(c);
        i += c.len_utf8();
    }
    out
}

/// Maps `{L}`-style property names (the text after `\p`) to ranges.
/// Returns the consumed length and the replacement.
fn unicode_property(s: &str) -> Option<(usize, String)> {
    let end = s.strip_prefix('{')?.find('}')? + 2;
    let ranges = match &s[1..end - 1] {
        "L" | "Alpha" | "Letter" => format!("a-zA-Z{NON_ASCII}"),
        "Lu" => "A-Z".to_owned(),
        "Ll" => "a-z".to_owned(),
        "N" | "Nd" | "Digit" => "0-9".to_owned(),
        "Alnum" => format!("a-zA-Z0-9{NON_ASCII}"),
        "Word" => format!("a-zA-Z0-9_{NON_ASCII}"),
        _ => return None,
    };
    Some((end, ranges))
}

// Prints a Mermaid diagram as SVG, as the previews draw it: cargo run --example mermaid_svg -- FILE [dark]
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let source = std::fs::read_to_string(&args[1]).unwrap();
    print!("{}", mdql::mermaid::svg(&source, args.get(2).is_some_and(|a| a == "dark")).unwrap());
}

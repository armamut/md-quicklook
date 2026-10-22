import Foundation

/// Fills the gap between what KaTeX understands and what SwiftMath parses:
/// extra symbols (registered with SwiftMath once) and a rewriting pass that
/// turns KaTeX aliases, macros and environments into constructs SwiftMath
/// knows. Formulas that still fail are shown as source by the caller.
enum MathMacros {
    /// Registers the extra symbols; safe to call from any thread, runs once.
    static func register() { _ = registered }

    private static let registered: Void = {
        for (name, type, value) in symbols {
            let atom = type == .largeOperator
                ? MTLargeOperator(value: value, limits: false)
                : MTMathAtom(type: type, value: value)
            MTMathAtomFactory.add(latexSymbol: name, value: atom)
        }
    }()

    // MARK: Symbols

    /// AMS and KaTeX symbols missing from SwiftMath. All are in Latin Modern Math
    /// (`build/math-coverage` checks); a few use the nearest glyph it has.
    static let symbols: [(String, MTMathAtomType, String)] = {
        var list: [(String, MTMathAtomType, String)] = []
        func add(_ type: MTMathAtomType, _ pairs: [(String, String)]) {
            list += pairs.map { ($0.0, type, $0.1) }
        }
        add(.relation, [
            ("leqq", "\u{2266}"), ("geqq", "\u{2267}"), ("eqslantless", "\u{2A95}"), ("eqslantgtr", "\u{2A96}"),
            ("lesssim", "\u{2272}"), ("gtrsim", "\u{2273}"), ("lessapprox", "\u{2A85}"), ("gtrapprox", "\u{2A86}"),
            ("approxeq", "\u{224A}"), ("lessdot", "\u{22D6}"), ("gtrdot", "\u{22D7}"), ("lll", "\u{22D8}"),
            ("llless", "\u{22D8}"), ("ggg", "\u{22D9}"), ("gggtr", "\u{22D9}"), ("lessgtr", "\u{2276}"),
            ("gtrless", "\u{2277}"), ("lesseqgtr", "\u{22DA}"), ("gtreqless", "\u{22DB}"), ("lesseqqgtr", "\u{2A8B}"),
            ("gtreqqless", "\u{2A8C}"), ("doteqdot", "\u{2251}"), ("Doteq", "\u{2251}"), ("risingdotseq", "\u{2253}"),
            ("fallingdotseq", "\u{2252}"), ("backsim", "\u{223D}"), ("backsimeq", "\u{22CD}"),
            ("subseteqq", "\u{2286}"), ("supseteqq", "\u{2287}"), ("Subset", "\u{22D0}"), ("Supset", "\u{22D1}"),
            ("preccurlyeq", "\u{227C}"), ("succcurlyeq", "\u{227D}"), ("curlyeqprec", "\u{22DE}"),
            ("curlyeqsucc", "\u{22DF}"), ("precsim", "\u{227E}"), ("succsim", "\u{227F}"), ("precapprox", "\u{227E}"),
            ("succapprox", "\u{227F}"), ("vartriangleleft", "\u{22B2}"), ("vartriangleright", "\u{22B3}"),
            ("trianglelefteq", "\u{22B4}"), ("trianglerighteq", "\u{22B5}"), ("vDash", "\u{22A8}"),
            ("Vdash", "\u{22A9}"), ("Vvdash", "\u{22AA}"), ("smallsmile", "\u{2323}"), ("smallfrown", "\u{2322}"),
            ("smile", "\u{2323}"), ("frown", "\u{2322}"), ("bumpeq", "\u{224F}"), ("Bumpeq", "\u{224E}"),
            ("eqcirc", "\u{2256}"), ("circeq", "\u{2257}"), ("triangleq", "\u{225C}"), ("thicksim", "\u{223C}"),
            ("thickapprox", "\u{2248}"), ("shortmid", "\u{2223}"), ("shortparallel", "\u{2225}"),
            ("between", "\u{226C}"), ("varpropto", "\u{221D}"), ("backepsilon", "\u{220D}"),
            ("because", "\u{2235}"), ("therefore", "\u{2234}"), ("eqsim", "\u{2242}"), ("owns", "\u{220B}"),
            ("Join", "\u{22C8}"), ("multimap", "\u{22B8}"), ("origof", "\u{22B6}"), ("imageof", "\u{22B7}"),
            ("coloneqq", "\u{2254}"), ("coloneq", "\u{2254}"), ("eqqcolon", "\u{2255}"),
            ("eqcolon", "\u{2239}"), ("dblcolon", "\u{2237}"),
            // Arrows
            ("nleftarrow", "\u{219A}"), ("nrightarrow", "\u{219B}"), ("nLeftarrow", "\u{21CD}"),
            ("nRightarrow", "\u{21CF}"), ("nleftrightarrow", "\u{21AE}"), ("nLeftrightarrow", "\u{21CE}"),
            ("leftleftarrows", "\u{21C7}"),
            ("rightrightarrows", "\u{21C9}"), ("leftrightarrows", "\u{21C6}"), ("rightleftarrows", "\u{21C4}"),
            ("Lleftarrow", "\u{21DA}"), ("Rrightarrow", "\u{21DB}"), ("twoheadleftarrow", "\u{219E}"),
            ("twoheadrightarrow", "\u{21A0}"), ("leftarrowtail", "\u{21A2}"), ("rightarrowtail", "\u{21A3}"),
            ("looparrowleft", "\u{21AB}"), ("looparrowright", "\u{21AC}"), ("leftrightharpoons", "\u{21CB}"),
            ("rightleftharpoons", "\u{21CC}"), ("curvearrowleft", "\u{21B6}"), ("curvearrowright", "\u{21B7}"),
            ("circlearrowleft", "\u{21BA}"), ("circlearrowright", "\u{21BB}"), ("Lsh", "\u{21B0}"),
            ("Rsh", "\u{21B1}"), ("upuparrows", "\u{21C8}"), ("downdownarrows", "\u{21CA}"),
            ("upharpoonleft", "\u{21BF}"), ("upharpoonright", "\u{21BE}"), ("downharpoonleft", "\u{21C3}"),
            ("downharpoonright", "\u{21C2}"), ("leftharpoonup", "\u{21BC}"), ("leftharpoondown", "\u{21BD}"),
            ("rightharpoonup", "\u{21C0}"), ("rightharpoondown", "\u{21C1}"), ("rightsquigarrow", "\u{21DD}"),
            ("leadsto", "\u{21DD}"), ("leftrightsquigarrow", "\u{21AD}"), ("mapsfrom", "\u{21A4}"),
            ("restriction", "\u{21BE}"), ("impliedby", "\u{27F8}"),
            ("larr", "\u{2190}"), ("rarr", "\u{2192}"), ("uarr", "\u{2191}"), ("darr", "\u{2193}"),
            ("harr", "\u{2194}"), ("lrarr", "\u{2194}"), ("Larr", "\u{21D0}"), ("Rarr", "\u{21D2}"),
            ("Uarr", "\u{21D1}"), ("Darr", "\u{21D3}"), ("Harr", "\u{21D4}"), ("Lrarr", "\u{21D4}"),
            ("lArr", "\u{21D0}"), ("rArr", "\u{21D2}"), ("uArr", "\u{21D1}"), ("dArr", "\u{21D3}"),
            ("hArr", "\u{21D4}"), ("lrArr", "\u{21D4}"), ("isin", "\u{2208}"),
        ])
        add(.binaryOperator, [
            ("leftthreetimes", "\u{22CB}"), ("rightthreetimes", "\u{22CC}"), ("Cap", "\u{22D2}"),
            ("doublecap", "\u{22D2}"), ("Cup", "\u{22D3}"), ("doublecup", "\u{22D3}"), ("smallsetminus", "\u{2216}"),
            ("dotplus", "\u{2214}"), ("curlywedge", "\u{22CF}"), ("curlyvee", "\u{22CE}"), ("barwedge", "\u{2305}"),
            ("veebar", "\u{22BB}"), ("boxplus", "\u{229E}"), ("boxminus", "\u{229F}"), ("boxtimes", "\u{22A0}"),
            ("boxdot", "\u{22A1}"), ("circledast", "\u{229B}"), ("circledcirc", "\u{229A}"),
            ("circleddash", "\u{229D}"), ("centerdot", "\u{22C5}"), ("sdot", "\u{22C5}"), ("intercal", "\u{22BA}"),
            ("divideontimes", "\u{22C7}"), ("triangleleft", "\u{25C1}"), ("triangleright", "\u{25B7}"),
            ("bigcirc", "\u{25EF}"), ("bigtriangleup", "\u{25B3}"), ("bigtriangledown", "\u{25BD}"),
            ("ltimes", "\u{22C9}"), ("rtimes", "\u{22CA}"), ("And", "&"),
        ])
        add(.ordinary, [
            ("backprime", "\u{2035}"), ("bigstar", "\u{22C6}"), 
            ("blacksquare", "\u{25A0}"), ("blacktriangle", "\u{25B2}"), ("blacktriangledown", "\u{25BC}"),
            ("blacktriangleleft", "\u{25C0}"), ("blacktriangleright", "\u{25B6}"), ("lozenge", "\u{25CA}"),
            ("Diamond", "\u{25CA}"), ("vartriangle", "\u{25B3}"), ("triangledown", "\u{25BD}"),
            ("diagup", "\u{2215}"), ("diagdown", "\u{2216}"), ("complement", "\u{2201}"), ("eth", "\u{00F0}"),
            ("hslash", "\u{210F}"), ("mho", "\u{2127}"),
            ("sphericalangle", "\u{2222}"), ("measuredangle", "\u{2221}"),
            ("checkmark", "\u{2713}"), ("maltese", "\u{2720}"), ("flat", "\u{266D}"), ("natural", "\u{266E}"),
            ("sharp", "\u{266F}"), ("clubsuit", "\u{2663}"), ("clubs", "\u{2663}"), ("diamondsuit", "\u{2662}"),
            ("diamonds", "\u{2662}"), ("heartsuit", "\u{2661}"), ("hearts", "\u{2661}"), ("spadesuit", "\u{2660}"),
            ("spades", "\u{2660}"), ("surd", "\u{221A}"), ("Bbbk", "\u{1D55C}"), ("copyright", "\u{00A9}"),
            ("circledR", "\u{00AE}"), ("pounds", "\u{00A3}"), ("mathsterling", "\u{00A3}"), ("yen", "\u{00A5}"),
            ("S", "\u{00A7}"), ("sect", "\u{00A7}"), ("P", "\u{00B6}"), ("dag", "\u{2020}"), ("ddag", "\u{2021}"),
            ("Dagger", "\u{2021}"), ("i", "\u{0131}"), ("j", "\u{0237}"), ("smallint", "\u{222B}"),
            ("infin", "\u{221E}"), ("exist", "\u{2203}"), ("empty", "\u{2205}"), ("alef", "\u{2135}"),
            ("alefsym", "\u{2135}"), ("weierp", "\u{2118}"), ("real", "\u{211C}"), ("image", "\u{2111}"),
            ("thetasym", "\u{03D1}"), ("ldotp", "."), ("vcentcolon", ":"),
            // Upright capitals that look like Latin letters
            ("Alpha", "A"), ("Beta", "B"), ("Epsilon", "E"), ("Zeta", "Z"), ("Eta", "H"), ("Iota", "I"),
            ("Kappa", "K"), ("Mu", "M"), ("Nu", "N"), ("Omicron", "O"), ("Rho", "P"), ("Tau", "T"), ("Chi", "X"),
            // Italic capital Greek
            ("varGamma", "\u{1D6E4}"), ("varDelta", "\u{1D6E5}"), ("varTheta", "\u{1D6E9}"),
            ("varLambda", "\u{1D6EC}"), ("varXi", "\u{1D6EF}"), ("varPi", "\u{1D6F1}"), ("varSigma", "\u{1D6F4}"),
            ("varUpsilon", "\u{1D6F6}"), ("varPhi", "\u{1D6F7}"), ("varPsi", "\u{1D6F9}"), ("varOmega", "\u{1D6FA}"),
            // Text-mode symbols KaTeX accepts in math too
            ("textbackslash", "\\"), ("textbar", "|"), ("textbardbl", "\u{2016}"), ("textbraceleft", "{"),
            ("textbraceright", "}"), ("textdagger", "\u{2020}"), ("textdaggerdbl", "\u{2021}"),
            ("textdegree", "\u{00B0}"), ("textdollar", "$"), ("textellipsis", "\u{2026}"),
            ("textemdash", "\u{2014}"), ("textendash", "\u{2013}"), ("textgreater", ">"), ("textless", "<"),
            ("textquotedblleft", "\u{201C}"), ("textquotedblright", "\u{201D}"), ("textquoteleft", "\u{2018}"),
            ("textquoteright", "\u{2019}"), ("lq", "\u{2018}"), ("rq", "\u{2019}"), ("textregistered", "\u{00AE}"),
            ("textsterling", "\u{00A3}"), ("textunderscore", "_"), ("textasciitilde", "~"),
            ("textasciicircum", "^"), ("textampersand", "&"),
        ])
        add(.open, [("ulcorner", "\u{231C}"), ("llcorner", "\u{231E}"), ("llbracket", "\u{27E6}"), ("lparen", "("), ("lbrack", "["), ("lang", "\u{27E8}")])
        add(.close, [("urcorner", "\u{231D}"), ("lrcorner", "\u{231F}"), ("rrbracket", "\u{27E7}"), ("rparen", ")"), ("rbrack", "]"), ("rang", "\u{27E9}")])
        add(.largeOperator, [("oiint", "\u{222F}"), ("oiiint", "\u{2230}"), ("intop", "\u{222B}")])
        return list
    }()

    // MARK: Rewriting

    /// Commands replaced by other LaTeX (no arguments).
    private static let aliases: [String: String] = [
        "R": "\\mathbb{R}", "Reals": "\\mathbb{R}", "reals": "\\mathbb{R}", "N": "\\mathbb{N}",
        "natnums": "\\mathbb{N}", "Z": "\\mathbb{Z}", "Complex": "\\mathbb{C}", "cnums": "\\mathbb{C}",
        "dots": "\\ldots", "dotsc": "\\ldots", "dotso": "\\ldots", "mathellipsis": "\\ldots",
        "dotsb": "\\cdots", "dotsi": "\\cdots", "dotsm": "\\cdots",
        "gt": ">", "lt": "<", "lvert": "|", "rvert": "|", "lVert": "\\Vert", "rVert": "\\Vert", "VERT": "\\Vert",
        "bold": "\\mathbf", "Bbb": "\\mathbb", "pmb": "\\boldsymbol", "it": "\\mathit", "sf": "\\mathsf",
        "tt": "\\mathtt", "mathscr": "\\mathcal", "mathsfit": "\\mathsf",
        "operatornamewithlimits": "\\operatorname*",
        "tg": "\\operatorname{tg}", "ctg": "\\operatorname{ctg}", "cotg": "\\operatorname{cotg}",
        "arctg": "\\operatorname{arctg}", "arcctg": "\\operatorname{arcctg}", "cosec": "\\operatorname{cosec}",
        "sh": "\\operatorname{sh}", "ch": "\\operatorname{ch}", "th": "\\operatorname{th}",
        "cth": "\\operatorname{cth}", "argmax": "\\operatorname*{arg\\,max}", "argmin": "\\operatorname*{arg\\,min}",
        "plim": "\\operatorname*{plim}", "injlim": "\\operatorname*{inj\\,lim}",
        "projlim": "\\operatorname*{proj\\,lim}", "varinjlim": "\\operatorname*{inj\\,lim}",
        "varprojlim": "\\operatorname*{proj\\,lim}", "varliminf": "\\liminf", "varlimsup": "\\limsup",
        "bmod": "\\;\\operatorname{mod}\\;",
        "KaTeX": "\\text{KaTeX}", "LaTeX": "\\text{LaTeX}", "TeX": "\\text{TeX}",
        "colonapprox": ":\\approx", "Colonapprox": "::\\approx", "colonsim": ":\\sim", "Colonsim": "::\\sim",
        "Coloneq": "::-", "Eqcolon": "-::", "Eqqcolon": "=::", "approxcolon": "\\approx:",
        "approxcoloncolon": "\\approx::", "Coloneqq": "::=",
        "dashrightarrow": "\\rightarrow", "dashleftarrow": "\\leftarrow", "simcolon": "\\sim:", "simcoloncolon": "\\sim::",
        // Sizes and line-breaking hints: no effect here
        "tiny": "", "scriptsize": "", "footnotesize": "", "small": "", "normalsize": "", "large": "",
        "Large": "", "LARGE": "", "huge": "", "Huge": "", "allowbreak": "", "nobreak": "", "notag": "",
        "nonumber": "",
    ]

    /// Commands with arguments: count and a template using #1, #2.
    private static let templates: [String: (Int, String)] = [
        "href": (2, "#2"), "url": (1, "\\texttt{#1}"), "smash": (1, "#1"), "mathclap": (1, "#1"),
        "mathllap": (1, "#1"), "mathrlap": (1, "#1"), "clap": (1, "#1"), "llap": (1, "#1"), "rlap": (1, "#1"),
        "raisebox": (2, "#2"), "vcenter": (1, "#1"),
        "dbinom": (2, "{\\displaystyle\\binom{#1}{#2}}"), "tbinom": (2, "{\\textstyle\\binom{#1}{#2}}"),
        "emph": (1, "\\textit{#1}"), "textup": (1, "\\textrm{#1}"), "textmd": (1, "\\textrm{#1}"),
        "textnormal": (1, "\\textrm{#1}"), "pod": (1, "\\;(#1)"),
        "tag": (1, "\\qquad\\text{(#1)}"), "tag*": (1, "\\qquad\\text{#1}"),
    ]

    /// Environments SwiftMath lacks, mapped onto ones it has.
    private static let environments: [String: String] = [
        "equation": "", "equation*": "", "align": "aligned", "align*": "aligned", "flalign": "aligned",
        "flalign*": "aligned", "alignat": "aligned", "alignat*": "aligned", "alignedat": "aligned",
        "gather*": "gather", "gathered": "gather", "multline": "gather", "multline*": "gather",
        "dcases": "cases", "darray": "array",
    ]

    /// Rewrites KaTeX-only syntax into what SwiftMath parses.
    static func expand(_ latex: String) -> String {
        guard latex.contains("\\") else { return latex }
        var scanner = Scanner(Array(latex))
        return scanner.run()
    }

    private struct Scanner {
        let chars: [Character]
        var i = 0
        var out = ""

        init(_ chars: [Character]) { self.chars = chars }

        mutating func run() -> String {
            while i < chars.count {
                let c = chars[i]
                guard c == "\\", i + 1 < chars.count else {
                    out.append(c)
                    i += 1
                    continue
                }
                i += 1
                guard chars[i].isLetter else {
                    let c = chars[i]
                    i += 1
                    if c == " " || c == "\n" || c == "\t" {
                        out += "\\;" // control space
                    } else if c == "&" {
                        out += "\\textampersand"
                    } else if let mark = textAccents[c] {
                        accent(mark)
                    } else {
                        out.append("\\")
                        out.append(c)
                    }
                    continue
                }
                var name = ""
                while i < chars.count, chars[i].isLetter {
                    name.append(chars[i])
                    i += 1
                }
                if i < chars.count, chars[i] == "*", templates[name + "*"] != nil {
                    name += "*"
                    i += 1
                }
                command(name)
            }
            return out
        }

        mutating func command(_ name: String) {
            if name == "begin" || name == "end" {
                environment(begin: name == "begin")
            } else if name.count == 1, let mark = textAccents[Character(name)] {
                accent(mark)
            } else if name == "not", let negated = negation() {
                out += negated
            } else if let replacement = aliases[name] {
                out += replacement
                // Keep "\R x" from becoming "\mathbb{R}x" glued to a following letter.
                if replacement.last?.isLetter == true, i < chars.count, chars[i].isLetter { out += " " }
            } else if let (count, template) = templates[name] {
                var args: [String] = []
                for _ in 0..<count {
                    skipOptional()
                    args.append(MathMacros.expand(argument()))
                }
                var result = template
                for (index, arg) in args.enumerated() { result = result.replacingOccurrences(of: "#\(index + 1)", with: arg) }
                out += result
            } else if name.hasPrefix("x"), let arrow = extensibleArrows[String(name.dropFirst())] {
                let below = optional().map { MathMacros.expand($0) }
                let above = MathMacros.expand(argument())
                // SwiftMath spaces the stack like an operator; add a relation's space.
                out += "\\;\\operatorname*{\(arrow)}\\limits"
                if let below, !below.isEmpty { out += "_{\(below)}" }
                out += "^{\(above.isEmpty ? "\\," : above)}\\;"
            } else if name == "overset" || name == "stackrel" || name == "underset" {
                let mark = MathMacros.expand(argument())
                let base = MathMacros.expand(argument())
                let space = isRelation(base) ? "\\;" : ""
                out += "\(space)\\operatorname*{\(base)}\\limits\(name == "underset" ? "_" : "^"){\(mark)}\(space)"
            } else {
                out += "\\" + name
            }
        }

        /// `\'{e}` and friends: the letter with a combining mark, composed
        /// where Unicode has the character.
        mutating func accent(_ mark: Character) {
            let base = argument()
            if base.count == 1, !base.hasPrefix("\\") {
                out += (base + String(mark)).precomposedStringWithCanonicalMapping
            } else {
                out += MathMacros.expand(base)
            }
        }

        /// `\not` before a character SwiftMath cannot negate.
        mutating func negation() -> String? {
            let saved = i
            skipSpaces()
            guard i < chars.count, let negated = ["=": "\\neq", "<": "\\nless", ">": "\\ngtr"][chars[i]] else {
                i = saved
                return nil
            }
            i += 1
            return negated
        }

        func isRelation(_ latex: String) -> Bool {
            if latex.count == 1 { return "=<>:".contains(latex) }
            guard latex.hasPrefix("\\") else { return false }
            return MTMathAtomFactory.atom(forLatexSymbol: String(latex.dropFirst()))?.type == .relation
        }

        mutating func environment(begin: Bool) {
            let saved = i
            guard let env = group() else {
                i = saved
                out += begin ? "\\begin" : "\\end"
                return
            }
            let mapped = environments[env] ?? env
            if begin, env.hasPrefix("alignat") || env == "alignedat" { _ = group() } // column count
            switch mapped {
            case "":
                out += begin ? "{" : "}"
                return
            case "array", "subarray":
                if begin {
                    let spec = group() ?? ""
                    let aligns = Set(spec.filter { "lcr".contains($0) })
                    let align = aligns.count == 1 ? aligns.first! : "c"
                    out += mapped == "subarray" ? "\\begin{smallmatrix}" : "\\begin{matrix*}[\(align)]"
                } else {
                    out += mapped == "subarray" ? "\\end{smallmatrix}" : "\\end{matrix*}"
                }
                return
            case "rcases", "drcases":
                out += begin ? "\\left.\\begin{matrix*}[l]" : "\\end{matrix*}\\right\\}"
                return
            default:
                break
            }
            out += (begin ? "\\begin{" : "\\end{") + mapped + "}"
        }

        mutating func skipSpaces() {
            while i < chars.count, chars[i] == " " { i += 1 }
        }

        /// A `{...}` group's contents, or nil (position unchanged) if none follows.
        mutating func group() -> String? {
            skipSpaces()
            guard i < chars.count, chars[i] == "{" else { return nil }
            return balanced(open: "{", close: "}")
        }

        /// A `[...]` optional argument's contents, if present.
        mutating func optional() -> String? {
            skipSpaces()
            guard i < chars.count, chars[i] == "[" else { return nil }
            return balanced(open: "[", close: "]")
        }

        mutating func skipOptional() { _ = optional() }

        mutating func balanced(open: Character, close: Character) -> String {
            var depth = 0
            var content = ""
            while i < chars.count {
                let c = chars[i]
                i += 1
                if c == "\\", i < chars.count {
                    if depth > 0 { content.append(c); content.append(chars[i]) }
                    i += 1
                    continue
                }
                if c == open {
                    depth += 1
                    if depth == 1 { continue }
                } else if c == close {
                    depth -= 1
                    if depth == 0 { break }
                }
                content.append(c)
            }
            return content
        }

        /// One argument: a group, a command or a single character.
        mutating func argument() -> String {
            if let g = group() { return g }
            guard i < chars.count else { return "" }
            if chars[i] == "\\" {
                var token = "\\"
                i += 1
                if i < chars.count, chars[i].isLetter {
                    while i < chars.count, chars[i].isLetter { token.append(chars[i]); i += 1 }
                } else if i < chars.count {
                    token.append(chars[i]); i += 1
                }
                return token
            }
            defer { i += 1 }
            return String(chars[i])
        }
    }

    /// Text accents (`\'e`, `\v{s}`, ...) as combining marks.
    private static let textAccents: [Character: Character] = [
        "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}", "\"": "\u{0308}", "~": "\u{0303}", "=": "\u{0304}",
        ".": "\u{0307}", "v": "\u{030C}", "u": "\u{0306}", "H": "\u{030B}", "r": "\u{030A}", "c": "\u{0327}",
    ]

    /// `\x...` arrows: the arrow drawn under the label.
    private static let extensibleArrows: [String: String] = [
        "rightarrow": "\\longrightarrow", "leftarrow": "\\longleftarrow", "leftrightarrow": "\\longleftrightarrow",
        "Rightarrow": "\\Longrightarrow", "Leftarrow": "\\Longleftarrow", "Leftrightarrow": "\\Longleftrightarrow",
        "mapsto": "\\longmapsto", "hookrightarrow": "\\hookrightarrow", "hookleftarrow": "\\hookleftarrow",
        "twoheadrightarrow": "\\twoheadrightarrow", "twoheadleftarrow": "\\twoheadleftarrow",
        "rightharpoonup": "\\rightharpoonup", "rightharpoondown": "\\rightharpoondown",
        "leftharpoonup": "\\leftharpoonup", "leftharpoondown": "\\leftharpoondown",
        "rightleftharpoons": "\\rightleftharpoons", "leftrightharpoons": "\\leftrightharpoons",
        "longequal": "=", "tofrom": "\\rightleftarrows",
    ]
}

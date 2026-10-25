import AppKit

extension NSAttributedString.Key {
    /// On a `<summary>` paragraph: the id of the `<details>` it toggles.
    static let detailsSummary = NSAttributedString.Key("MDQLDetailsSummary")
    /// On the rest of a `<details>`: the ids of every enclosing one ([Int]).
    static let detailsBody = NSAttributedString.Key("MDQLDetailsBody")
    /// On the first character of a heading or footnote: its anchor name.
    static let anchor = NSAttributedString.Key("MDQLAnchor")
}

/// Folded `<details>` contents are taken out of the text and kept here until
/// their summary is clicked: TextKit 1 has no way to hide paragraphs, and
/// removing them keeps tables and attachments laid out correctly.
struct DetailsFolding {
    private(set) var closed: Set<Int> = []
    private var hidden: [Int: NSMutableAttributedString] = [:]

    /// Folds the closed sections found in newly added text.
    mutating func fold(_ text: NSMutableAttributedString, closing ids: Set<Int>) {
        closed.formUnion(ids)
        // Innermost first (ids grow with nesting), so an inner section is
        // still folded when its outer one opens.
        for id in closed.sorted(by: >) {
            setMarker(of: id, open: false, in: text)
            guard let range = Self.body(of: id, in: text) else { continue }
            let piece = text.attributedSubstring(from: range)
            text.deleteCharacters(in: range)
            if let stored = hidden[id] { stored.append(piece) } else { hidden[id] = NSMutableAttributedString(attributedString: piece) }
        }
    }

    /// Opens or closes a section in place.
    mutating func toggle(_ id: Int, in storage: NSTextStorage) {
        storage.beginEditing()
        defer { storage.endEditing() }
        if closed.contains(id) {
            guard let summary = Self.summary(of: id, in: storage) else { return }
            closed.remove(id)
            setMarker(of: id, open: true, in: storage)
            if let content = hidden.removeValue(forKey: id) { storage.insert(content, at: NSMaxRange(summary)) }
        } else {
            guard let range = Self.body(of: id, in: storage) else { return }
            closed.insert(id)
            setMarker(of: id, open: false, in: storage)
            hidden[id] = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            storage.deleteCharacters(in: range)
        }
    }

    /// Opens the sections an anchor is folded into, from the outside in.
    mutating func reveal(anchor name: String, in storage: NSTextStorage) {
        for _ in 0..<64 where Self.location(ofAnchor: name, in: storage) == nil {
            guard var id = hiddenSection(where: { Self.location(ofAnchor: name, in: $0) != nil }) else { return }
            while Self.summary(of: id, in: storage) == nil,
                  let outer = hiddenSection(where: { Self.summary(of: id, in: $0) != nil }) {
                id = outer
            }
            guard Self.summary(of: id, in: storage) != nil else { return }
            toggle(id, in: storage)
        }
    }

    private func hiddenSection(where matches: (NSAttributedString) -> Bool) -> Int? {
        hidden.first { matches($0.value) }?.key
    }

    static func location(ofAnchor name: String, in text: NSAttributedString) -> Int? {
        var found: Int?
        text.enumerateAttribute(.anchor, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            if let value = value as? String, value == name || value == name.lowercased() {
                found = range.location
                stop.pointee = true
            }
        }
        return found
    }

    private static func summary(of id: Int, in text: NSAttributedString) -> NSRange? {
        var found: NSRange?
        text.enumerateAttribute(.detailsSummary, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            if value as? Int == id { found = range; stop.pointee = true }
        }
        return found
    }

    /// Everything inside a section but its summary (one contiguous range).
    private static func body(of id: Int, in text: NSAttributedString) -> NSRange? {
        var union: NSRange?
        text.enumerateAttribute(.detailsBody, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let ids = value as? [Int], ids.contains(id) else { return }
            union = union.map { NSUnionRange($0, range) } ?? range
        }
        return union
    }

    /// The core starts every summary with "▾ "; a folded one points right.
    private func setMarker(of id: Int, open: Bool, in text: NSMutableAttributedString) {
        guard let summary = Self.summary(of: id, in: text), summary.length > 0 else { return }
        let first = NSRange(location: summary.location, length: 1)
        let marker = open ? "▾" : "▸"
        let current = (text.string as NSString).substring(with: first)
        guard current == "▾" || current == "▸", current != marker else { return }
        text.replaceCharacters(in: first, with: marker)
    }
}

import Foundation

/// The native layout produced by `mdql_render_native` (see `core/src/native.rs`
/// for the meaning of every field). Offsets and lengths are UTF-16 units.
struct NativeDocument {
    struct Block {
        var kind: UInt8
        var flags: UInt8
        var parent: UInt16
        var a: UInt32
        var b: UInt32
        var c: UInt32
    }

    struct Paragraph {
        var start: Int
        var length: Int
        var block: UInt16
        var kind: UInt8
        var level: UInt8
        var extra: UInt32
        var range: NSRange { NSRange(location: start, length: length) }
    }

    struct Run {
        var start: Int
        var length: Int
        var flags: UInt32
        var a: UInt32
        var b: UInt32
        var c: UInt32
        var d: UInt32
        var range: NSRange { NSRange(location: start, length: length) }
    }

    var text: String
    var strings: [String]
    var blocks: [Block]
    var paragraphs: [Paragraph]
    var runs: [Run]

    static let noBlock = UInt16.max

    enum BlockKind {
        static let quote: UInt8 = 1, alert: UInt8 = 2, list: UInt8 = 3, listItem: UInt8 = 4, code: UInt8 = 5
        static let table: UInt8 = 6, tableRow: UInt8 = 7, frontMatter: UInt8 = 9, footnotes: UInt8 = 10
        static let details: UInt8 = 11
        // Flags
        static let tight: UInt8 = 1, header: UInt8 = 2, frontMatterTable: UInt8 = 4
    }

    enum ParagraphKind {
        static let body: UInt8 = 0, heading: UInt8 = 1, code: UInt8 = 2, tableCell: UInt8 = 3, rule: UInt8 = 4
        static let math: UInt8 = 5, alertTitle: UInt8 = 6, caption: UInt8 = 7, summary: UInt8 = 8
        static let alignShift: UInt32 = 8, listMarker: UInt32 = 1 << 10, anchorShift: UInt32 = 16
    }

    enum RunFlag {
        static let bold: UInt32 = 1 << 0, italic: UInt32 = 1 << 1, code: UInt32 = 1 << 2, strike: UInt32 = 1 << 3
        static let link: UInt32 = 1 << 4, mark: UInt32 = 1 << 5, sup: UInt32 = 1 << 6, sub: UInt32 = 1 << 7
        static let kbd: UInt32 = 1 << 8, underline: UInt32 = 1 << 9, token: UInt32 = 1 << 10
        static let attachment: UInt32 = 1 << 11, small: UInt32 = 1 << 12, muted: UInt32 = 1 << 13
        static let tokenBold: UInt32 = 1 << 14, tokenItalic: UInt32 = 1 << 15
    }

    enum AttachmentKind {
        static let image: UInt32 = 1, remoteImage: UInt32 = 2, remoteBadge: UInt32 = 3, badge: UInt32 = 4
        static let mathInline: UInt32 = 5, mathDisplay: UInt32 = 6, checkboxOn: UInt32 = 7, checkboxOff: UInt32 = 8
        static let rule: UInt32 = 9, diagram: UInt32 = 10
    }

    /// The string a 1-based id refers to (0 means none).
    func string(oneBased id: UInt32) -> String? {
        id == 0 ? nil : strings[safe: Int(id) - 1]
    }

    /// Decodes a buffer; returns nil if it is malformed.
    init?(_ data: Data) {
        var reader = Reader(data: data)
        guard reader.bytes(4) == Data("MDQ1".utf8),
              let textBytes = reader.lengthPrefixed(),
              let stringCount = reader.u32() else { return nil }
        text = String(decoding: textBytes, as: UTF8.self)

        strings = []
        strings.reserveCapacity(Int(stringCount))
        for _ in 0..<stringCount {
            guard let bytes = reader.lengthPrefixed() else { return nil }
            strings.append(String(decoding: bytes, as: UTF8.self))
        }

        guard let blockCount = reader.u32() else { return nil }
        blocks = []
        blocks.reserveCapacity(Int(blockCount))
        for _ in 0..<blockCount {
            guard let kind = reader.u8(), let flags = reader.u8(), let parent = reader.u16(),
                  let a = reader.u32(), let b = reader.u32(), let c = reader.u32() else { return nil }
            blocks.append(Block(kind: kind, flags: flags, parent: parent, a: a, b: b, c: c))
        }

        guard let paragraphCount = reader.u32() else { return nil }
        paragraphs = []
        paragraphs.reserveCapacity(Int(paragraphCount))
        for _ in 0..<paragraphCount {
            guard let start = reader.u32(), let length = reader.u32(), let block = reader.u16(),
                  let kind = reader.u8(), let level = reader.u8(), let extra = reader.u32() else { return nil }
            paragraphs.append(Paragraph(start: Int(start), length: Int(length), block: block,
                                        kind: kind, level: level, extra: extra))
        }

        guard let runCount = reader.u32() else { return nil }
        runs = []
        runs.reserveCapacity(Int(runCount))
        for _ in 0..<runCount {
            guard let start = reader.u32(), let length = reader.u32(), let flags = reader.u32(),
                  let a = reader.u32(), let b = reader.u32(), let c = reader.u32(), let d = reader.u32() else { return nil }
            runs.append(Run(start: Int(start), length: Int(length), flags: flags, a: a, b: b, c: c, d: d))
        }
        guard reader.atEnd else { return nil }
    }

    /// Walks from a block to the document root, innermost first.
    func ancestry(of block: UInt16) -> [Int] {
        var chain: [Int] = []
        var id = block
        while id != Self.noBlock, Int(id) < blocks.count, chain.count < 64 {
            chain.append(Int(id))
            id = blocks[Int(id)].parent
        }
        return chain
    }
}

private struct Reader {
    let data: Data
    var offset = 0

    var atEnd: Bool { offset == data.count }

    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, offset + n <= data.count else { return nil }
        defer { offset += n }
        return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + n)
    }

    mutating func lengthPrefixed() -> Data? {
        guard let n = u32() else { return nil }
        return bytes(Int(n))
    }

    mutating func u8() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func u16() -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        defer { offset += 2 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }.littleEndian
    }

    mutating func u32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        defer { offset += 4 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import CoreGraphics
import Foundation

/// Groups OCR'd lines into paragraphs. Coordinates are top-left origin.
public enum OCRLayout {
    public struct Line: Equatable, Sendable {
        public var text: String
        public var rect: CGRect
        public init(text: String, rect: CGRect) { self.text = text; self.rect = rect }
    }

    public struct Block: Equatable, Sendable {
        public var lines: [Line]
        public var rect: CGRect { lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) } }
        public var text: String {
            // Re-join hyphenated line breaks; otherwise lines flow with a space.
            lines.map(\.text).reduce("") { acc, line in
                if acc.isEmpty { return line }
                if acc.hasSuffix("-") { return String(acc.dropLast()) + line }
                return acc + " " + line
            }
        }
    }

    /// Lines are in the same block when they overlap horizontally and the gap
    /// to the previous line is small relative to line height.
    public static func blocks(_ lines: [Line]) -> [Block] {
        let sorted = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.rect.minY < $1.rect.minY }
        var blocks: [Block] = []
        for line in sorted {
            if let i = blocks.lastIndex(where: { belongs(line, to: $0) }) {
                blocks[i].lines.append(line)
            } else {
                blocks.append(Block(lines: [line]))
            }
        }
        return blocks.sorted { a, b in
            abs(a.rect.minY - b.rect.minY) < 4 ? a.rect.minX < b.rect.minX : a.rect.minY < b.rect.minY
        }
    }

    static func belongs(_ line: Line, to block: Block) -> Bool {
        guard let last = block.lines.last else { return false }
        let h = max(min(line.rect.height, last.rect.height), 1)
        let gap = line.rect.minY - last.rect.maxY
        let sameSize = abs(line.rect.height - last.rect.height) < h * 0.45
        let overlap = min(line.rect.maxX, last.rect.maxX) - max(line.rect.minX, last.rect.minX)
        let aligned = abs(line.rect.minX - last.rect.minX) < h * 1.5 || overlap > min(line.rect.width, last.rect.width) * 0.5
        return gap > -h * 0.5 && gap < h * 0.9 && sameSize && aligned
    }

    /// The block under `point`, or the nearest one.
    public static func blockIndex(at point: CGPoint, in blocks: [Block]) -> Int? {
        if let i = blocks.firstIndex(where: { $0.rect.insetBy(dx: -6, dy: -6).contains(point) }) { return i }
        return blocks.indices.min { distance(point, blocks[$0].rect) < distance(point, blocks[$1].rect) }
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}

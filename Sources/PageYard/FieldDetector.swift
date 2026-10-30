import AppKit
import PDFKit

/// A spot on a page that looks like it's meant to be filled in.
struct DetectedField {
    enum Kind { case line, box, checkbox }
    let kind: Kind
    /// Page space (unrotated PDF user space).
    let rect: CGRect
}

/// Finds fill-in lines (____ / ......), table cells / input boxes and
/// checkboxes by rasterising the original page content. Works on documents
/// that have no form fields at all.
final class FieldDetector {
    private var cache: [ObjectIdentifier: [DetectedField]] = [:]

    func fields(on page: PDFPage) -> [DetectedField] {
        let key = ObjectIdentifier(page)
        if let f = cache[key] { return f }
        let f = Self.detect(page)
        cache[key] = f
        return f
    }

    // MARK: - Snapping queries

    /// The smallest detected box of the given kinds that contains `p`.
    static func box(containing p: CGPoint, in fields: [DetectedField], kinds: Set<DetectedField.Kind>, tolerance: CGFloat = 0) -> CGRect? {
        fields
            .filter { kinds.contains($0.kind) && $0.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
            .map(\.rect)
            .min { $0.width * $0.height < $1.width * $1.height }
    }

    /// A fill-in line the click most likely refers to: just above / on it.
    static func line(near p: CGPoint, in fields: [DetectedField]) -> CGRect? {
        fields
            .filter { f in
                f.kind == .line
                    && p.x >= f.rect.minX - 6 && p.x <= f.rect.maxX + 6
                    && p.y >= f.rect.minY - 5 && p.y <= f.rect.maxY + 18
            }
            .map(\.rect)
            .min { abs($0.maxY - p.y) < abs($1.maxY - p.y) }
    }

    // MARK: - Detection

    static let scale: CGFloat = 2

    private struct Grid {
        let w: Int, h: Int
        let dark: [UInt8]
        let rowPrefix: [Int32]
        let vDown: [UInt16]

        init(w: Int, h: Int, dark: [UInt8]) {
            self.w = w
            self.h = h
            self.dark = dark
            var prefix = [Int32](repeating: 0, count: h * (w + 1))
            var down = [UInt16](repeating: 0, count: w * h)
            for r in 0..<h {
                var acc: Int32 = 0
                let base = r * (w + 1)
                for x in 0..<w {
                    acc += Int32(dark[r * w + x])
                    prefix[base + x + 1] = acc
                }
            }
            for r in stride(from: h - 1, through: 0, by: -1) {
                for x in 0..<w where dark[r * w + x] == 1 {
                    down[r * w + x] = r == h - 1 ? 1 : min(60_000, down[(r + 1) * w + x] + 1)
                }
            }
            rowPrefix = prefix
            vDown = down
        }

        @inline(__always) func isDark(_ r: Int, _ x: Int) -> Bool { dark[r * w + x] == 1 }
        @inline(__always) func down(_ r: Int, _ x: Int) -> Int { Int(vDown[r * w + x]) }

        /// Dark pixels in row r, columns [x0, x1).
        func count(_ r: Int, _ x0: Int, _ x1: Int) -> Int {
            guard r >= 0, r < h else { return 0 }
            let a = max(0, x0), b = min(w, x1)
            guard b > a else { return 0 }
            let base = r * (w + 1)
            return Int(rowPrefix[base + b] - rowPrefix[base + a])
        }

        func density(rows: Range<Int>, _ x0: Int, _ x1: Int) -> Double {
            let rr = max(0, rows.lowerBound)..<min(h, rows.upperBound)
            guard !rr.isEmpty, x1 > x0 else { return 0 }
            var n = 0
            for r in rr { n += count(r, x0, x1) }
            return Double(n) / Double(rr.count * (x1 - x0))
        }
    }

    /// Integer rectangle in bitmap space; rows grow downward.
    private struct IRect { var x0, y0, x1, y1: Int }

    static func detect(_ page: PDFPage) -> [DetectedField] {
        guard let ref = page.pageRef else { return [] }
        let box = page.bounds(for: .cropBox)
        let s = scale
        let w = Int(box.width * s), h = Int(box.height * s)
        guard w > 8, h > 8, w * h < 60_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return [] }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setShouldAntialias(false)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(ref)
        guard let raw = ctx.data else { return [] }
        let px = raw.bindMemory(to: UInt8.self, capacity: w * h)
        var dark = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) where px[i] < 170 { dark[i] = 1 }

        let g = Grid(w: w, h: h, dark: dark)
        let rects = findRects(g)
        let lines = findLines(g, excluding: rects)

        func toPage(_ r: IRect) -> CGRect {
            CGRect(x: box.minX + CGFloat(r.x0) / s,
                   y: box.maxY - CGFloat(r.y1 + 1) / s,
                   width: CGFloat(r.x1 - r.x0 + 1) / s,
                   height: CGFloat(r.y1 - r.y0 + 1) / s)
        }

        var out: [DetectedField] = []
        for r in rects {
            let pr = toPage(r)
            let aspect = pr.width / max(pr.height, 0.1)
            if pr.width <= 30, pr.height <= 30, aspect > 0.7, aspect < 1.4 {
                // An already ticked or solid square isn't an empty checkbox.
                let inner = g.density(rows: (r.y0 + 3)..<(r.y1 - 2), r.x0 + 3, r.x1 - 2)
                if inner < 0.25 { out.append(DetectedField(kind: .checkbox, rect: pr)) }
            } else if pr.height >= 8 {
                out.append(DetectedField(kind: .box, rect: pr))
            }
        }
        out += lines.map { DetectedField(kind: .line, rect: toPage($0)) }
        return out
    }

    /// Rectangles: a horizontal top edge with vertical edges going down from
    /// it, closed by a horizontal bottom edge. Table rows yield one rect per cell.
    private static func findRects(_ g: Grid) -> [IRect] {
        let s = scale
        let minSide = Int(5 * s)
        let maxH = Int(80 * s)
        var found: [IRect] = []

        for r in 0..<(g.h - minSide) {
            var x = 0
            while x < g.w {
                guard g.isDark(r, x) else { x += 1; continue }
                let a = x
                while x < g.w && g.isDark(r, x) { x += 1 }
                let b = x - 1
                guard b - a + 1 >= minSide else { continue }

                // Columns of vertical lines leaving this run downward, clustered.
                var cols: [(lo: Int, hi: Int, len: Int)] = []
                var cx = a
                while cx <= b {
                    if g.down(r, cx) >= minSide {
                        let lo = cx
                        var len = 0
                        while cx <= b && g.down(r, cx) >= minSide { len = max(len, g.down(r, cx)); cx += 1 }
                        cols.append((lo, cx - 1, len))
                    } else {
                        cx += 1
                    }
                }
                guard cols.count >= 2 else { continue }

                for i in 0..<(cols.count - 1) {
                    let left = cols[i].lo, right = cols[i + 1].hi
                    let width = right - left + 1
                    guard width >= minSide else { continue }
                    let reach = min(cols[i].len, cols[i + 1].len, maxH)
                    var y = r + minSide
                    let end = min(g.h - 1, r + reach)
                    while y <= end {
                        if g.count(y, left, right + 1) * 10 >= width * 9 {
                            found.append(IRect(x0: left, y0: r, x1: right, y1: y))
                            break
                        }
                        y += 1
                    }
                }
            }
        }
        return dedupe(found)
    }

    /// Horizontal solid / dashed / dotted lines with empty space above them.
    private static func findLines(_ g: Grid, excluding rects: [IRect]) -> [IRect] {
        let s = scale
        let minLen = Int(24 * s)
        let gap = Int(3 * s)
        struct Seg { var x0, x1, r0, r1: Int }
        var active: [Seg] = []
        var done: [Seg] = []

        for r in 0..<g.h {
            var segs: [(Int, Int)] = []
            var start = -1, end = -1, filled = 0
            func flush() {
                if start >= 0, end - start + 1 >= minLen, filled * 5 >= (end - start + 1) {
                    segs.append((start, end))
                }
            }
            var x = 0
            while x < g.w {
                guard g.isDark(r, x) else { x += 1; continue }
                let a = x
                while x < g.w && g.isDark(r, x) { x += 1 }
                let b = x - 1
                if start >= 0 && a - end - 1 <= gap {
                    end = b
                    filled += b - a + 1
                } else {
                    flush()
                    start = a
                    end = b
                    filled = b - a + 1
                }
            }
            flush()

            var next: [Seg] = []
            for (a, b) in segs {
                if let i = active.firstIndex(where: { min($0.x1, b) - max($0.x0, a) > (b - a) / 2 }) {
                    var sg = active.remove(at: i)
                    sg.r1 = r
                    sg.x0 = min(sg.x0, a)
                    sg.x1 = max(sg.x1, b)
                    next.append(sg)
                } else {
                    next.append(Seg(x0: a, x1: b, r0: r, r1: r))
                }
            }
            done += active
            active = next
        }
        done += active

        let maxThick = Int(3 * s), clearAbove = Int(4 * s), clearBelow = Int(1.5 * s)
        let lines = done.filter { sg in
            sg.r1 - sg.r0 + 1 <= maxThick
                && g.density(rows: (sg.r0 - clearAbove)..<(sg.r0 - 1), sg.x0, sg.x1 + 1) < 0.03
                && g.density(rows: (sg.r1 + 2)..<(sg.r1 + 2 + clearBelow), sg.x0, sg.x1 + 1) < 0.08
        }
        .filter { sg in
            // Drop edges of detected boxes: those are handled as boxes.
            var covered = 0
            for rc in rects where abs(rc.y0 - sg.r0) <= 3 || abs(rc.y1 - sg.r1) <= 3 {
                covered += max(0, min(rc.x1, sg.x1) - max(rc.x0, sg.x0))
            }
            return covered * 10 < (sg.x1 - sg.x0) * 7
        }
        .map { IRect(x0: $0.x0, y0: $0.r0, x1: $0.x1, y1: $0.r1) }
        return dedupe(lines)
    }

    private static func dedupe(_ rects: [IRect]) -> [IRect] {
        var kept: [IRect] = []
        for r in rects {
            let area = Double((r.x1 - r.x0 + 1) * (r.y1 - r.y0 + 1))
            let dup = kept.contains { k in
                let ix = min(k.x1, r.x1) - max(k.x0, r.x0) + 1
                let iy = min(k.y1, r.y1) - max(k.y0, r.y0) + 1
                guard ix > 0, iy > 0 else { return false }
                let kArea = Double((k.x1 - k.x0 + 1) * (k.y1 - k.y0 + 1))
                let inter = Double(ix * iy)
                return inter / (area + kArea - inter) > 0.6
            }
            if !dup { kept.append(r) }
        }
        return kept
    }
}

/// Picks the dominant colour around a region of the original page, so that
/// replaced text sits on a matching background.
enum BackgroundSampler {
    static func color(on page: PDFPage, around rect: CGRect) -> NSColor {
        guard let ref = page.pageRef else { return .white }
        let s: CGFloat = 2
        let w = max(4, Int(rect.width * s)), h = max(4, Int(rect.height * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .white }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.drawPDFPage(ref)
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return .white }

        var histogram: [Int: Int] = [:]
        func sample(_ x: Int, _ y: Int) {
            let i = (y * w + x) * 4
            let key = (Int(data[i]) >> 4) << 8 | (Int(data[i + 1]) >> 4) << 4 | (Int(data[i + 2]) >> 4)
            histogram[key, default: 0] += 1
        }
        for x in 0..<w { sample(x, 0); sample(x, h - 1) }
        for y in 0..<h { sample(0, y); sample(w - 1, y) }
        guard let best = histogram.max(by: { $0.value < $1.value })?.key else { return .white }
        func channel(_ v: Int) -> CGFloat { CGFloat(v * 16 + 8) / 255 }
        let r = channel(best >> 8 & 0xF), gr = channel(best >> 4 & 0xF), b = channel(best & 0xF)
        // Near-white snaps to pure white to avoid a visible tinted box.
        if r > 0.93, gr > 0.93, b > 0.93 { return .white }
        return NSColor(srgbRed: r, green: gr, blue: b, alpha: 1)
    }
}

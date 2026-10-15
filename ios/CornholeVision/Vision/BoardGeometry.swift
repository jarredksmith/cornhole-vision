import Foundation
import CoreGraphics

/// Regulation board (ACL/ACO): 24 x 48 in, 6 in hole centred 9 in from the back edge.
///
/// Board coordinate frame (inches):
///   x: 0 (left edge) ... 24 (right edge)
///   y: 0 (back edge, the hole end) ... 48 (front edge, nearest the thrower)
enum BoardSpec {
    static let widthIn: Double = 24
    static let lengthIn: Double = 48
    static let holeCenter = CGPoint(x: 12, y: 9)
    static let holeRadiusIn: Double = 3
    static let bagSizeIn: Double = 6

    /// Resolution of the top-down "board map" image the detector works on.
    static let pixelsPerInch = 8
    static var warpWidth: Int { Int(widthIn) * pixelsPerInch }    // 192
    static var warpHeight: Int { Int(lengthIn) * pixelsPerInch }  // 384

    /// Board corners in inches, in the canonical order used everywhere:
    /// c0 = back-left (0,0), c1 = back-right (24,0), c2 = front-right (24,48), c3 = front-left (0,48)
    static let cornersIn: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: widthIn, y: 0),
        CGPoint(x: widthIn, y: lengthIn), CGPoint(x: 0, y: lengthIn),
    ]

    static func isInsideBoard(_ p: CGPoint, margin: Double = 0) -> Bool {
        p.x >= -margin && p.x <= widthIn + margin && p.y >= -margin && p.y <= lengthIn + margin
    }

    static func distanceToHole(_ p: CGPoint) -> Double {
        hypot(p.x - holeCenter.x, p.y - holeCenter.y)
    }

    static func distanceToEdge(_ p: CGPoint) -> Double {
        min(min(p.x, widthIn - p.x), min(p.y, lengthIn - p.y))
    }
}

/// 3x3 planar homography, row-major. Maps (x, y) -> (x', y').
struct Homography {
    var m: [Double]

    static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// Solve H such that dst[i] ~ H * src[i] for four point correspondences (DLT, 8 unknowns).
    init?(from src: [CGPoint], to dst: [CGPoint]) {
        guard src.count == 4, dst.count == 4 else { return nil }
        // Build the 8x9 augmented system
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        // Gaussian elimination with partial pivoting
        for col in 0..<8 {
            var pivot = col
            for r in (col + 1)..<8 where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            if abs(a[pivot][col]) < 1e-12 { return nil }
            if pivot != col { a.swapAt(pivot, col) }
            let p = a[col][col]
            for c in col..<9 { a[col][c] /= p }
            for r in 0..<8 where r != col {
                let f = a[r][col]
                if f == 0 { continue }
                for c in col..<9 { a[r][c] -= f * a[col][c] }
            }
        }
        m = [a[0][8], a[1][8], a[2][8], a[3][8], a[4][8], a[5][8], a[6][8], a[7][8], 1]
    }

    init(m: [Double]) { self.m = m }

    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        let iw = abs(w) < 1e-12 ? 0 : 1.0 / w
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) * iw,
                       y: (m[3] * x + m[4] * y + m[5]) * iw)
    }

    func inverted() -> Homography? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        if abs(det) < 1e-14 { return nil }
        let inv = 1.0 / det
        return Homography(m: [
            (e * i - f * h) * inv, (c * h - b * i) * inv, (b * f - c * e) * inv,
            (f * g - d * i) * inv, (a * i - c * g) * inv, (c * d - a * f) * inv,
            (d * h - e * g) * inv, (b * g - a * h) * inv, (a * e - b * d) * inv,
        ])
    }
}

enum Geometry {
    /// Shoelace area of a polygon.
    static func polygonArea(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<pts.count {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            s += Double(p.x * q.y - q.x * p.y)
        }
        return abs(s) * 0.5
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }

    /// Mean corner displacement between two quads with corners in the same order.
    static func quadDrift(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        guard a.count == 4, b.count == 4 else { return .infinity }
        var s = 0.0
        for i in 0..<4 { s += distance(a[i], b[i]) }
        return s / 4
    }

    /// Point-in-polygon (ray casting).
    static func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func average(_ quads: [[CGPoint]]) -> [CGPoint] {
        guard let first = quads.first else { return [] }
        var out = first
        if quads.count == 1 { return out }
        for i in 0..<4 {
            var x = 0.0, y = 0.0
            for q in quads { x += Double(q[i].x); y += Double(q[i].y) }
            out[i] = CGPoint(x: x / Double(quads.count), y: y / Double(quads.count))
        }
        return out
    }
}

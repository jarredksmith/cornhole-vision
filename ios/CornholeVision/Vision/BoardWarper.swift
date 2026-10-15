import Foundation
import CoreImage
import CoreVideo
import CoreGraphics

/// Produces a fixed-size top-down image of the board (192 x 384 px, 8 px/in)
/// from the camera frame using the locked corner quad. Pixel (px, py) in the
/// result corresponds to board inches (px / 8, py / 8), y = 0 at the hole end.
final class BoardWarper {
    let width = BoardSpec.warpWidth
    let height = BoardSpec.warpHeight

    /// BGRA, top row first.
    private(set) var pixels: [UInt8]

    /// Core Image renders bitmaps top-row-first. If the calibrator finds the hole
    /// consistently at the mirrored end, it flips this so the hole end is row 0.
    var flipY = false

    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false,
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
    ])
    private let filter = CIFilter(name: "CIPerspectiveCorrection")

    init() {
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// `quad`: the 4 board corners c0..c3 (see BoardSpec.cornersIn) in Vision
    /// normalized coordinates (origin bottom-left, same as Core Image).
    @discardableResult
    func warp(pixelBuffer: CVPixelBuffer, quad: [CGPoint]) -> Bool {
        guard quad.count == 4, let filter else { return false }
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        func vec(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(vec(quad[0]), forKey: "inputTopLeft")
        filter.setValue(vec(quad[1]), forKey: "inputTopRight")
        filter.setValue(vec(quad[2]), forKey: "inputBottomRight")
        filter.setValue(vec(quad[3]), forKey: "inputBottomLeft")
        guard let corrected = filter.outputImage else { return false }

        let e = corrected.extent
        guard e.width > 1, e.height > 1 else { return false }
        let sx = CGFloat(width) / e.width
        let sy = CGFloat(height) / e.height
        var scaled = corrected
            .transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        if flipY {
            scaled = scaled
                .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(height)))
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(scaled, toBitmap: base, rowBytes: width * 4, bounds: bounds, format: .BGRA8, colorSpace: nil)
        }
        return true
    }

    /// Average colour (r, g, b in 0...255) of a small patch around a board-inch position.
    func sampleColor(atInches p: CGPoint, radiusPx: Int = 3) -> (r: Double, g: Double, b: Double) {
        let cx = min(width - 1, max(0, Int(p.x * Double(BoardSpec.pixelsPerInch))))
        let cy = min(height - 1, max(0, Int(p.y * Double(BoardSpec.pixelsPerInch))))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in max(0, cy - radiusPx)...min(height - 1, cy + radiusPx) {
            for x in max(0, cx - radiusPx)...min(width - 1, cx + radiusPx) {
                let i = (y * width + x) * 4
                b += Double(pixels[i]); g += Double(pixels[i + 1]); r += Double(pixels[i + 2]); n += 1
            }
        }
        if n == 0 { return (0, 0, 0) }
        return (r / n, g / n, b / n)
    }

    // MARK: - Debug picture

    /// The warped board with changed pixels tinted red.
    func debugImage(mask: [UInt8]) -> CGImage? {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let p = i * 4
            var b = pixels[p], g = pixels[p + 1], r = pixels[p + 2]
            if i < mask.count, mask[i] == 1 {
                r = UInt8(min(255, Int(r) / 2 + 128)); g = g / 2; b = b / 2
            }
            out[p] = b; out[p + 1] = g; out[p + 2] = r; out[p + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: cs, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Hole search

    struct HoleFit {
        var center: CGPoint     // inches on the 24x48 map
        var radius: Double      // inches
        var contrast: Double    // luma levels darker than the ring around it (0 = no hole)
    }

    private var integral = [Int32](repeating: 0, count: (BoardSpec.warpWidth + 1) * (BoardSpec.warpHeight + 1))

    /// Summed-area table of luma over the current warped map.
    private func buildIntegral() {
        let w = width, h = height, stride = w + 1
        pixels.withUnsafeBufferPointer { px in
            integral.withUnsafeMutableBufferPointer { ig in
                for x in 0...w { ig[x] = 0 }
                for y in 1...h {
                    var row: Int32 = 0
                    ig[y * stride] = 0
                    for x in 1...w {
                        let i = ((y - 1) * w + (x - 1)) * 4
                        let luma = (Int32(px[i]) * 29 + Int32(px[i + 1]) * 150 + Int32(px[i + 2]) * 77) >> 8
                        row += luma
                        ig[y * stride + x] = ig[(y - 1) * stride + x] + row
                    }
                }
            }
        }
    }

    /// Mean luma of the pixel box [x0,x1) x [y0,y1) (clamped) using the integral image.
    private func boxMean(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> (sum: Double, area: Double) {
        let stride = width + 1
        let ax = max(0, min(width, x0)), ay = max(0, min(height, y0))
        let bx = max(0, min(width, x1)), by = max(0, min(height, y1))
        if bx <= ax || by <= ay { return (0, 0) }
        let s = Int(integral[by * stride + bx]) - Int(integral[ay * stride + bx]) - Int(integral[by * stride + ax]) + Int(integral[ay * stride + ax])
        return (Double(s), Double((bx - ax) * (by - ay)))
    }

    /// Look for a dark, roughly round hole near the centre line of the warped board.
    /// Regulation puts it at (12, 9) with radius 3, but makeshift boards put it anywhere,
    /// so this searches the whole length and returns what it actually finds. The caller
    /// decides which end is the hole end (y < 24 means the c0-c1 edge).
    func findHole() -> HoleFit? {
        buildIntegral()
        let ppi = Double(BoardSpec.pixelsPerInch)
        var best: HoleFit?
        func evaluate(cx: Double, cy: Double, r: Double) -> Double {
            let ri = Int((r * 0.7 * ppi).rounded()), ro = Int((r * 1.8 * ppi).rounded())
            let px = Int((cx * ppi).rounded()), py = Int((cy * ppi).rounded())
            let inner = boxMean(px - ri, py - ri, px + ri, py + ri)
            guard inner.area > 0 else { return 0 }
            let innerMean = inner.sum / inner.area
            // A real hole is surrounded by board on every side. A shadow line, a gap or an
            // edge is dark on one side only, so each of the four side boxes must be brighter.
            let sides = [
                boxMean(px - ro, py - ri, px - ri, py + ri),   // left
                boxMean(px + ri, py - ri, px + ro, py + ri),   // right
                boxMean(px - ri, py - ro, px + ri, py - ri),   // above
                boxMean(px - ri, py + ri, px + ri, py + ro),   // below
            ]
            var minSide = Double.infinity
            for sd in sides {
                guard sd.area > 0 else { return 0 }
                minSide = min(minSide, sd.sum / sd.area)
            }
            guard innerMean < minSide * 0.62 else { return 0 }
            return minSide - innerMean
        }
        for r in [2.5, 3.0, 3.6, 4.3] {
            var cy = 3.5
            while cy <= 44.5 {
                var cx = 6.0
                while cx <= 18 {
                    let c = evaluate(cx: cx, cy: cy, r: r)
                    if c > (best?.contrast ?? 0) { best = HoleFit(center: CGPoint(x: cx, y: cy), radius: r, contrast: c) }
                    cx += 1
                }
                cy += 1
            }
        }
        guard var fit = best, fit.contrast > 0 else { return nil }
        // The playing surface should be fairly even in tone (plywood, paint, cardboard).
        // Pillows, clothes and clutter are not. Scale the contrast by surface evenness.
        fit.contrast *= surfaceEvenness(excluding: fit)
        // Refine to half an inch.
        for dy in [-0.5, 0, 0.5] {
            for dx in [-0.5, 0, 0.5] {
                let c = evaluate(cx: fit.center.x + dx, cy: fit.center.y + dy, r: fit.radius)
                if c > fit.contrast { fit = HoleFit(center: CGPoint(x: fit.center.x + dx, y: fit.center.y + dy), radius: fit.radius, contrast: c) }
            }
        }
        return fit
    }

    /// 0...1: how even the board surface is, from the spread of 4x4-inch block means.
    private func surfaceEvenness(excluding hole: HoleFit) -> Double {
        let ppi = Double(BoardSpec.pixelsPerInch)
        var means: [Double] = []
        var by = 1.0
        while by + 4 <= BoardSpec.lengthIn - 1 {
            var bx = 1.0
            while bx + 4 <= BoardSpec.widthIn - 1 {
                let cx = bx + 2, cy = by + 2
                if hypot(cx - hole.center.x, cy - hole.center.y) > hole.radius + 3.5 {
                    let m = boxMean(Int(bx * ppi), Int(by * ppi), Int((bx + 4) * ppi), Int((by + 4) * ppi))
                    if m.area > 0 { means.append(m.sum / m.area) }
                }
                bx += 4
            }
            by += 4
        }
        guard means.count > 6 else { return 1 }
        let avg = means.reduce(0, +) / Double(means.count)
        let mad = means.reduce(0) { $0 + abs($1 - avg) } / Double(means.count)
        // mad ~5-15 on a board, 30-60 on a pile of laundry.
        return max(0.15, min(1, 1.3 - mad / 40))
    }

    /// Mean luminance inside a circle (inches) — used to find which end has the hole.
    func meanLuma(centerIn c: CGPoint, innerIn: Double, outerIn: Double) -> Double {
        let ppi = Double(BoardSpec.pixelsPerInch)
        let cx = c.x * ppi, cy = c.y * ppi
        let r0 = innerIn * ppi, r1 = outerIn * ppi
        var sum = 0.0, n = 0.0
        let y0 = max(0, Int(cy - r1)), y1 = min(height - 1, Int(cy + r1))
        let x0 = max(0, Int(cx - r1)), x1 = min(width - 1, Int(cx + r1))
        if y0 > y1 || x0 > x1 { return 0 }
        for y in y0...y1 {
            for x in x0...x1 {
                let d = hypot(Double(x) - cx, Double(y) - cy)
                if d < r0 || d > r1 { continue }
                let i = (y * width + x) * 4
                sum += 0.114 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.299 * Double(pixels[i + 2])
                n += 1
            }
        }
        return n == 0 ? 0 : sum / n
    }
}

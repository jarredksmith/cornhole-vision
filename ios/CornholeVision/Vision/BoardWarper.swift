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

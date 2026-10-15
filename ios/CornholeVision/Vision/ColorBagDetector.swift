import Foundation
import CoreGraphics

/// One detected bag (or bag-sized blob) in board coordinates.
struct BagDetection {
    var position: CGPoint        // inches
    var areaIn2: Double          // visible area in square inches
    var r: Double, g: Double, b: Double   // mean colour 0...255
    var inHoleHint: Bool = false // set by the ML detector's "bag_in_hole" class
    var source: Source = .color
    enum Source { case color, ml }
}

/// Model-free bag detector: background subtraction against a reference image
/// of the empty board taken at lock time, then connected components.
/// Works on the 192x384 top-down board map. Runs in ~1-2 ms on-device.
final class ColorBagDetector {
    let width = BoardSpec.warpWidth
    let height = BoardSpec.warpHeight
    private let count: Int

    private var reference: [Float]      // RGB per pixel, 3 floats
    private(set) var hasReference = false
    private var mask: [UInt8]
    private var eroded: [UInt8]
    private var labels: [Int32]
    private var stack: [Int32]

    // Tunables
    var chromaThreshold: Float = 0.085   // sum of |Δr/s| + |Δg/s|
    var darkRatio: Float = 0.52          // intensity ratio below this = foreground (black bags)
    var brightRatio: Float = 1.55        // above this = foreground (white bags)
    var minBlobPx = 180                  // ~2.8 in² — only accepted next to the hole (a bag hanging in it)
    var minBagPx = 850                   // ~13 in² — anywhere else a bag shows at least this much
    var nominalBagPx = 2100              // 6x6 in bag ≈ 2304 px; deformed bags are a bit smaller
    var backgroundLearnRate: Float = 0.015
    var maxForegroundFraction = 0.35     // more than this changed => camera/lighting/board moved, not bags
    var holeCenter = BoardSpec.holeCenter
    var holeRadius = BoardSpec.holeRadiusIn

    /// Fraction of the board that differed from the reference on the last frame.
    private(set) var lastForegroundFraction = 0.0
    private var unstableFrames = 0
    /// The last foreground mask (1 = changed), for the debug view.
    var lastMask: [UInt8] { mask }

    init() {
        count = width * height
        reference = [Float](repeating: 0, count: count * 3)
        mask = [UInt8](repeating: 0, count: count)
        eroded = [UInt8](repeating: 0, count: count)
        labels = [Int32](repeating: 0, count: count)
        stack = [Int32](repeating: 0, count: count)
    }

    func resetReference() { hasReference = false }

    /// Capture the empty board as the background reference.
    func captureReference(_ bgra: [UInt8]) {
        for i in 0..<count {
            let p = i * 4
            reference[i * 3] = Float(bgra[p + 2])
            reference[i * 3 + 1] = Float(bgra[p + 1])
            reference[i * 3 + 2] = Float(bgra[p])
        }
        hasReference = true
    }

    /// Returns bag detections in board inches. `learnBackground` slowly adapts the
    /// reference on pixels classified as background (lighting drift, clouds).
    func detect(_ bgra: [UInt8], learnBackground: Bool) -> [BagDetection] {
        guard hasReference else { return [] }
        let w = width, h = height
        let chromaT = chromaThreshold, dark = darkRatio, bright = brightRatio, lr = backgroundLearnRate

        // 1. Foreground mask
        var fgCount = 0
        bgra.withUnsafeBufferPointer { src in
            reference.withUnsafeMutableBufferPointer { ref in
                mask.withUnsafeMutableBufferPointer { m in
                    for i in 0..<count {
                        let p = i * 4
                        let r = Float(src[p + 2]), g = Float(src[p + 1]), b = Float(src[p])
                        let R = ref[i * 3], G = ref[i * 3 + 1], B = ref[i * 3 + 2]
                        let s = r + g + b + 1
                        let S = R + G + B + 1
                        let dChroma = abs(r / s - R / S) + abs(g / s - G / S)
                        let ratio = s / S
                        let fg = dChroma > chromaT || ratio < dark || ratio > bright
                        m[i] = fg ? 1 : 0
                        if fg { fgCount += 1 }
                        if learnBackground && !fg {
                            ref[i * 3] += (r - R) * lr
                            ref[i * 3 + 1] += (g - G) * lr
                            ref[i * 3 + 2] += (b - B) * lr
                        }
                    }
                }
            }
        }

        lastForegroundFraction = Double(fgCount) / Double(count)
        if lastForegroundFraction > maxForegroundFraction {
            // Something big changed (exposure, the board got bumped, a person leaned over it).
            // That's not bags. Wait it out; if it stays that way, adopt it as the new background.
            unstableFrames += 1
            if unstableFrames >= 45 { captureReference(bgra); unstableFrames = 0 }
            return []
        }
        unstableFrames = 0

        // 2. 3x3 erosion to kill speckle and thin shadow edges
        eroded.withUnsafeMutableBufferPointer { e in
            mask.withUnsafeBufferPointer { m in
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y * w + x
                        if m[i] == 0 || x == 0 || y == 0 || x == w - 1 || y == h - 1 { e[i] = 0; continue }
                        let ok = m[i - 1] & m[i + 1] & m[i - w] & m[i + w] & m[i - w - 1] & m[i - w + 1] & m[i + w - 1] & m[i + w + 1]
                        e[i] = ok
                    }
                }
            }
        }

        // 3. Connected components (4-connectivity, iterative flood fill)
        for i in 0..<count { labels[i] = 0 }
        var blobs: [Blob] = []
        var nextLabel: Int32 = 1
        for start in 0..<count where eroded[start] == 1 && labels[start] == 0 {
            var blob = Blob()
            blob.label = nextLabel
            var sp = 0
            stack[sp] = Int32(start); sp += 1
            labels[start] = nextLabel
            while sp > 0 {
                sp -= 1
                let i = Int(stack[sp])
                let x = i % w, y = i / w
                blob.add(x: x, y: y, bgra: bgra, index: i)
                if x > 0, eroded[i - 1] == 1, labels[i - 1] == 0 { labels[i - 1] = nextLabel; stack[sp] = Int32(i - 1); sp += 1 }
                if x < w - 1, eroded[i + 1] == 1, labels[i + 1] == 0 { labels[i + 1] = nextLabel; stack[sp] = Int32(i + 1); sp += 1 }
                if y > 0, eroded[i - w] == 1, labels[i - w] == 0 { labels[i - w] = nextLabel; stack[sp] = Int32(i - w); sp += 1 }
                if y < h - 1, eroded[i + w] == 1, labels[i + w] == 0 { labels[i + w] = nextLabel; stack[sp] = Int32(i + w); sp += 1 }
            }
            nextLabel += 1
            if blob.area >= minBlobPx { blobs.append(blob) }
        }

        // 4. Blobs -> detections (split touching bags), then keep only bag-shaped, bag-coloured ones
        var out: [BagDetection] = []
        let ppi = Double(BoardSpec.pixelsPerInch)
        let maxReasonable = nominalBagPx * 9   // a person's shadow / a leg: ignore
        for blob in blobs {
            if blob.area > maxReasonable { continue }
            let k = min(4, max(1, Int((Double(blob.area) / Double(nominalBagPx)).rounded())))
            let parts: [Blob]
            if k == 1 || blob.area < Int(Double(nominalBagPx) * 1.55) {
                parts = [blob]
            } else {
                parts = blob.split(into: k, bgra: bgra, labels: labels, width: w, height: h)
            }
            for part in parts {
                guard part.area >= minBlobPx else { continue }
                let det = part.detection(ppi: ppi)
                let nearHole = hypot(det.position.x - holeCenter.x, det.position.y - holeCenter.y) < holeRadius + 2.5
                // Size: a bag is big. Small blobs only count right at the hole (hanging in it).
                if part.area < minBagPx && !nearHole { continue }
                // Shape: a bag is compact; a shifted edge or shadow line is long and thin.
                let bw = Double(part.maxX - part.minX + 1), bh = Double(part.maxY - part.minY + 1)
                let fill = Double(part.area) / (bw * bh)
                let aspect = max(bw, bh) / max(1, min(bw, bh))
                if fill < 0.38 || aspect > 2.6 { continue }
                // Colour: a bag looks different from the board around it. A blob the same colour as
                // its surroundings is the board itself (reference went stale), so adopt it instead.
                if looksLikeSurroundings(part, bgra: bgra) {
                    absorb(part, bgra: bgra)
                    continue
                }
                out.append(det)
            }
        }
        return out
    }

    /// Compare the blob's colour with a band of current-frame pixels around its box.
    private func looksLikeSurroundings(_ b: Blob, bgra: [UInt8]) -> Bool {
        let pad = 6
        let x0 = max(0, b.minX - pad), y0 = max(0, b.minY - pad)
        let x1 = min(width - 1, b.maxX + pad), y1 = min(height - 1, b.maxY + pad)
        var r = 0.0, g = 0.0, bl = 0.0, n = 0.0
        for y in y0...y1 {
            for x in x0...x1 {
                let inside = x >= b.minX && x <= b.maxX && y >= b.minY && y <= b.maxY
                if inside { continue }
                let i = (y * width + x) * 4
                if mask[y * width + x] == 1 { continue }   // only compare against settled background
                bl += Double(bgra[i]); g += Double(bgra[i + 1]); r += Double(bgra[i + 2]); n += 1
            }
        }
        guard n > 40 else { return false }
        r /= n; g /= n; bl /= n
        let a = Double(max(b.area, 1))
        let br = b.sr / a, bg = b.sg / a, bb = b.sb / a
        let s1 = br + bg + bb + 1, s2 = r + g + bl + 1
        let dChroma = abs(br / s1 - r / s2) + abs(bg / s1 - g / s2)
        let ratio = s1 / s2
        return dChroma < 0.06 && ratio > 0.78 && ratio < 1.28
    }

    /// Fold a blob's pixels into the reference (it was the board, not a bag).
    private func absorb(_ b: Blob, bgra: [UInt8]) {
        for y in b.minY...b.maxY {
            for x in b.minX...b.maxX {
                let i = y * width + x
                guard labels[i] == b.label else { continue }
                let p = i * 4
                reference[i * 3] = Float(bgra[p + 2])
                reference[i * 3 + 1] = Float(bgra[p + 1])
                reference[i * 3 + 2] = Float(bgra[p])
            }
        }
    }

    // MARK: - Blob

    struct Blob {
        var area = 0
        var sx = 0, sy = 0
        var sr = 0.0, sg = 0.0, sb = 0.0
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        var label: Int32 = 0

        mutating func add(x: Int, y: Int, bgra: [UInt8], index i: Int) {
            area += 1; sx += x; sy += y
            let p = i * 4
            sb += Double(bgra[p]); sg += Double(bgra[p + 1]); sr += Double(bgra[p + 2])
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }

        func detection(ppi: Double) -> BagDetection {
            let n = Double(max(area, 1))
            return BagDetection(position: CGPoint(x: Double(sx) / n / ppi, y: Double(sy) / n / ppi),
                                areaIn2: n / (ppi * ppi), r: sr / n, g: sg / n, b: sb / n)
        }

        /// K-means on pixel positions to split a merged blob into k bags.
        func split(into k: Int, bgra: [UInt8], labels: [Int32], width w: Int, height h: Int) -> [Blob] {
            // Collect pixels of this blob inside its bbox
            var pts: [(Int, Int, Int)] = []  // x, y, index
            let myLabel = label
            for y in minY...maxY {
                for x in minX...maxX {
                    let i = y * w + x
                    if labels[i] == myLabel { pts.append((x, y, i)) }
                }
            }
            guard pts.count > k * 10 else { return [self] }
            // Init centroids along the bbox's major axis
            var cx = [Double](), cy = [Double]()
            let wide = (maxX - minX) >= (maxY - minY)
            for j in 0..<k {
                let t = (Double(j) + 0.5) / Double(k)
                cx.append(wide ? Double(minX) + t * Double(maxX - minX) : Double(sx) / Double(area))
                cy.append(wide ? Double(sy) / Double(area) : Double(minY) + t * Double(maxY - minY))
            }
            var assign = [Int](repeating: 0, count: pts.count)
            for _ in 0..<8 {
                var nx = [Double](repeating: 0, count: k), ny = [Double](repeating: 0, count: k), nn = [Double](repeating: 0, count: k)
                for (pi, p) in pts.enumerated() {
                    var best = 0; var bd = Double.infinity
                    for j in 0..<k {
                        let d = (Double(p.0) - cx[j]) * (Double(p.0) - cx[j]) + (Double(p.1) - cy[j]) * (Double(p.1) - cy[j])
                        if d < bd { bd = d; best = j }
                    }
                    assign[pi] = best
                    nx[best] += Double(p.0); ny[best] += Double(p.1); nn[best] += 1
                }
                for j in 0..<k where nn[j] > 0 { cx[j] = nx[j] / nn[j]; cy[j] = ny[j] / nn[j] }
            }
            var parts = [Blob](repeating: Blob(), count: k)
            for (pi, p) in pts.enumerated() {
                parts[assign[pi]].add(x: p.0, y: p.1, bgra: bgra, index: p.2)
            }
            return parts.filter { $0.area > 0 }
        }
    }
}

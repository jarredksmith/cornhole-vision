import SwiftUI
import AVFoundation

/// Draws the board outline, the hole and a marker per tracked bag on top of
/// the camera preview. Tap a marker to correct its state.
struct OverlayView: View {
    @EnvironmentObject var game: GameViewModel

    var body: some View {
        // Snapshot the view-model state on the main actor; the Canvas renderer and the
        // local helpers below are nonisolated.
        let previewLayer = game.previewLayer
        let boardToImage = game.boardToImage
        let candidatePolygon = game.candidatePolygon
        let boardQuad = game.boardQuad
        let liveTracks = game.liveTracks
        let overrides = game.overrides
        let teams = game.teams
        let holeCenter = game.holeCenter
        let holeRadius = game.holeRadius
        let candidateHole = game.candidateHole
        let manualCorners = game.manualCorners
        let manualMode = game.manualMode
        return GeometryReader { _ in
            Canvas { ctx, _ in
                guard let layer = previewLayer else { return }
                func pt(_ vnorm: CGPoint) -> CGPoint {
                    layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: vnorm.x, y: 1 - vnorm.y))
                }
                func boardPt(_ inches: CGPoint) -> CGPoint? {
                    guard let h = boardToImage else { return nil }
                    return pt(h.apply(inches))
                }

                // Candidate rectangle while locking (hole end drawn heavier)
                if let poly = candidatePolygon, boardQuad == nil, !manualMode {
                    var path = Path()
                    path.move(to: pt(poly[0]))
                    for p in poly.dropFirst() { path.addLine(to: pt(p)) }
                    path.closeSubpath()
                    ctx.stroke(path, with: .color(.yellow.opacity(0.9)), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    var back = Path(); back.move(to: pt(poly[0])); back.addLine(to: pt(poly[1]))
                    ctx.stroke(back, with: .color(.yellow), lineWidth: 6)
                }
                // Where the model thinks the hole is
                if let h = candidateHole, boardQuad == nil {
                    let c = pt(h)
                    let rect = CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.cyan.opacity(0.9)), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
                // Manual corner taps
                if manualMode {
                    for (i, c) in manualCorners.enumerated() {
                        let p = pt(c)
                        let rect = CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26)
                        ctx.fill(Path(ellipseIn: rect), with: .color(i < 2 ? .orange : .yellow))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2)
                        ctx.draw(Text("\(i + 1)").font(.system(size: 14, weight: .black)).foregroundStyle(.black), at: p)
                    }
                    if manualCorners.count >= 2 {
                        var path = Path()
                        path.move(to: pt(manualCorners[0]))
                        for c in manualCorners.dropFirst() { path.addLine(to: pt(c)) }
                        if manualCorners.count == 4 { path.closeSubpath() }
                        ctx.stroke(path, with: .color(.yellow.opacity(0.8)), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }

                // Locked board + hole
                if let quad = boardQuad {
                    var path = Path()
                    path.move(to: pt(quad[0]))
                    for p in quad.dropFirst() { path.addLine(to: pt(p)) }
                    path.closeSubpath()
                    ctx.stroke(path, with: .color(.green.opacity(0.9)), lineWidth: 3)

                    var hole = Path()
                    let steps = 24
                    for i in 0...steps {
                        let t = Double(i) / Double(steps) * 2 * .pi
                        let p = CGPoint(x: holeCenter.x + holeRadius * cos(t),
                                        y: holeCenter.y + holeRadius * sin(t))
                        if let q = boardPt(p) {
                            if i == 0 { hole.move(to: q) } else { hole.addLine(to: q) }
                        }
                    }
                    ctx.stroke(hole, with: .color(.green.opacity(0.7)), lineWidth: 2)
                }

                // Bags
                for t in liveTracks {
                    guard let c = boardPt(t.position) else { continue }
                    let state = overrides[t.id] ?? t.state
                    let color = Color(hex: teams[min(t.team, 1)].color)
                    let r: CGFloat = 16
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                    switch state {
                    case .inHole:
                        ctx.fill(Path(ellipseIn: rect), with: .color(color))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 3)
                        ctx.draw(Text("3").font(.system(size: 15, weight: .black)).foregroundStyle(.white), at: c)
                    case .resting:
                        ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.85)))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)), lineWidth: 2)
                        ctx.draw(Text("1").font(.system(size: 15, weight: .black)).foregroundStyle(.white), at: c)
                    case .off:
                        ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        ctx.draw(Text("0").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.8)), at: c)
                    case .moving, .lost:
                        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 4, dy: 4)), with: .color(color.opacity(0.7)), lineWidth: 2)
                    }
                    if overrides[t.id] != nil {
                        ctx.draw(Text("✎").font(.system(size: 12)).foregroundStyle(.yellow), at: CGPoint(x: c.x + r, y: c.y - r))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                tap(at: location)
            }
        }
    }

    @MainActor private func tap(at location: CGPoint) {
        guard let layer = game.previewLayer else { return }
        if game.manualMode {
            // Layer point -> capture-device point (top-left origin) -> Vision (bottom-left origin)
            let dp = layer.captureDevicePointConverted(fromLayerPoint: location)
            game.addManualCorner(CGPoint(x: dp.x, y: 1 - dp.y))
            return
        }
        guard let h = game.boardToImage else { return }
        var best: Int?
        var bestD = 40.0
        for t in game.liveTracks {
            let v = h.apply(t.position)
            let p = layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: v.x, y: 1 - v.y))
            let d = Geometry.distance(p, location)
            if d < bestD { bestD = d; best = t.id }
        }
        if let id = best { game.cycleOverride(trackId: id) }
    }
}

extension Color {
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

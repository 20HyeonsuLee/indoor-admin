import SwiftUI

struct CoverageMiniMapView: View {
    let points: [CGPoint]
    let current: CGPoint?
    var size: CGSize = CGSize(width: 128, height: 128)

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(.black.opacity(0.42)))

            let transform = CoverageTransform(points: points, current: current, size: size)
            var route = Path()
            for (index, point) in points.enumerated() {
                let p = transform.screen(point)
                if index == 0 {
                    route.move(to: p)
                } else {
                    route.addLine(to: p)
                }
            }
            context.stroke(route, with: .color(.red.opacity(0.52)), lineWidth: 18)
            context.stroke(route, with: .color(.white.opacity(0.42)), lineWidth: 3)

            for point in points {
                let p = transform.screen(point)
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                    with: .color(.red.opacity(0.34))
                )
            }

            if let current {
                let p = transform.screen(current)
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                    with: .color(.white)
                )
                context.stroke(
                    Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                    with: .color(.red),
                    lineWidth: 2
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            Label("스캔 범위", systemImage: "square.grid.3x3.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(6)
        }
    }
}

private struct CoverageTransform {
    let points: [CGPoint]
    let current: CGPoint?
    let size: CGSize

    func screen(_ point: CGPoint) -> CGPoint {
        let all = points + [current].compactMap { $0 }
        let minX = all.map(\.x).min() ?? -1
        let maxX = all.map(\.x).max() ?? 1
        let minY = all.map(\.y).min() ?? -1
        let maxY = all.map(\.y).max() ?? 1
        let w = max(maxX - minX, 1)
        let h = max(maxY - minY, 1)
        let margin: CGFloat = 16
        let scale = min((size.width - margin * 2) / w, (size.height - margin * 2) / h)
        let drawW = w * scale
        let drawH = h * scale
        let ox = (size.width - drawW) / 2
        let oy = (size.height - drawH) / 2
        return CGPoint(
            x: ox + (point.x - minX) * scale,
            y: oy + drawH - (point.y - minY) * scale
        )
    }
}

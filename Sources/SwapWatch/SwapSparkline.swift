import SwiftUI
import SwapCore

/// Two paths replace hundreds of individual chart marks. No intermediate
/// history arrays or per-point view objects are needed.
struct SwapSparkline: View {
    let points: [ActivityPoint]
    let threshold: Double

    var body: some View {
        Canvas { context, size in
            guard let first = points.first, let last = points.last else { return }
            let maximum = points.reduce(max(1, threshold)) {
                max($0, max($1.writeBytesPerSecond, $1.readBytesPerSecond) / 1_048_576 * 1.1)
            }
            let left: CGFloat = 46
            let height = max(1, size.height - 22)
            let width = max(1, size.width - left)
            let duration = max(1, last.timestamp.timeIntervalSince(first.timestamp))
            func y(_ rate: Double) -> CGFloat { 6 + height * (1 - min(1, max(0, rate / maximum))) }

            for rate in [0, maximum / 2, maximum] {
                var grid = Path()
                grid.move(to: CGPoint(x: left, y: y(rate)))
                grid.addLine(to: CGPoint(x: size.width, y: y(rate)))
                context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
                context.draw(Text(String(format: "%.1f", rate)).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: left - 5, y: y(rate)), anchor: .trailing)
            }
            var limit = Path()
            limit.move(to: CGPoint(x: left, y: y(threshold)))
            limit.addLine(to: CGPoint(x: size.width, y: y(threshold)))
            context.stroke(limit, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            var writes = Path()
            var reads = Path()
            var previous: Date?
            for point in points {
                let x = left + width * point.timestamp.timeIntervalSince(first.timestamp) / duration
                let write = CGPoint(x: x, y: y(point.writeBytesPerSecond / 1_048_576))
                let read = CGPoint(x: x, y: y(point.readBytesPerSecond / 1_048_576))
                let continues = previous.map {
                    let gap = point.timestamp.timeIntervalSince($0)
                    return gap >= 0 && gap <= 10
                } ?? false
                if !continues {
                    writes.move(to: write)
                    reads.move(to: read)
                } else {
                    writes.addLine(to: write)
                    reads.addLine(to: read)
                }
                previous = point.timestamp
            }
            context.stroke(writes, with: .color(.orange), lineWidth: 1.5)
            context.stroke(reads, with: .color(.blue), lineWidth: 1.5)
            context.draw(Text("MiB/s").font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: left, y: size.height), anchor: .bottomLeading)
        }
    }
}

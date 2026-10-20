import CompanionCore
import SwiftUI

/// The visor: protoke's face on an LED panel, drawn every frame from the
/// performance. Unlit cells stay faintly visible, the way a real panel does.
public struct FaceView: View {
    public let performance: FacePerformance
    public var colour: Color

    /// One grid for every expression, so the cells never move.
    static let grid = FaceMatrix.grid(for: Expression.allCases.map(\.face))

    public init(performance: FacePerformance, colour: Color = Color(red: 0x4F / 255, green: 0xE3 / 255, blue: 0xF5 / 255)) {
        self.performance = performance
        self.colour = colour
    }

    public var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                Self.draw(performance.pose(at: ProcessInfo.processInfo.systemUptime), in: &context, size: size,
                          colour: colour)
            }
        }
        .accessibilityLabel("Companion's face, \(performance.mood.rawValue)")
    }

    /// One pose, still, on black: for looking at the face without a window.
    @MainActor
    public static func image(_ pose: Pose, size: CGSize, colour: Color = Color(red: 0x4F / 255, green: 0xE3 / 255, blue: 0xF5 / 255)) -> CGImage? {
        let view = Canvas { context, size in draw(pose, in: &context, size: size, colour: colour) }
            .frame(width: size.width, height: size.height)
            .background(.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage
    }

    static func draw(_ pose: Pose, in context: inout GraphicsContext, size: CGSize, colour: Color) {
        let grid = Self.grid
        let width = grid.cell * Double(grid.columns)
        let height = grid.rowHeight * Double(grid.rows)
        let scale = min(size.width / width, size.height / height) * 0.92
        guard scale > 0 else { return }
        // The panel is bolted to the head: the whole grid moves and tilts with it.
        let faceWidth = FaceGeometry.unit * scale
        context.translateBy(x: size.width / 2 + pose.offset.x * faceWidth, y: size.height / 2 + pose.offset.y * faceWidth)
        context.rotate(by: .degrees(pose.tilt))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -(grid.left + width / 2), y: -(grid.top + height / 2))

        let lit = FaceMatrix.lit(FaceGeometry.shapes(pose.face, muzzle: pose.muzzle), on: grid)
        let side = min(grid.cell, grid.rowHeight) * FaceMatrix.dotFill
        func dot(_ column: Int, _ row: Int) -> CGRect {
            let centre = grid.centre(column, row)
            return CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        }
        var unlit = Path()
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                unlit.addRoundedRect(in: dot(column, row), cornerSize: CGSize(width: side * 0.2, height: side * 0.2))
            }
        }
        var bright = Path()
        for cell in lit {
            bright.addRoundedRect(in: dot(cell.column, cell.row), cornerSize: CGSize(width: side * 0.2, height: side * 0.2))
        }
        context.fill(unlit, with: .color(colour.opacity(0.07)))
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: side * scale * 0.9))
            glow.fill(bright, with: .color(colour.opacity(0.85)))
        }
        context.fill(bright, with: .color(colour))
    }
}

import CompanionCore
import SwiftUI

/// The visor: protoke's face drawn every frame from the performance, as an
/// LED panel or as smooth outlines. Only the face is drawn: the panel's unlit
/// cells stay dark, so nothing shows but the face, and while it listens the
/// face glows a little brighter with your voice.
public struct FaceView: View {
    public let performance: FacePerformance
    public var colour: Color
    public var style: VisorStyle
    /// How loud the microphone is, read every frame; 0 when not listening.
    public var hearing: () -> Float
    /// How the device is moving, read every frame.
    public var felt: () -> Felt
    /// Where whoever is talking is, read every frame.
    public var look: () -> Point?
    /// Where the head is in a dance to music, read every frame.
    public var dance: () -> (point: Point, amount: Double)?

    /// One grid for every expression, so the cells never move.
    static let grid = FaceMatrix.grid(for: Expression.allCases.map(\.face))

    public init(performance: FacePerformance, colour: Color = VisorColour.cyan.color, style: VisorStyle = .panel,
                hearing: @escaping () -> Float = { 0 }, felt: @escaping () -> Felt = { .still },
                look: @escaping () -> Point? = { nil },
                dance: @escaping () -> (point: Point, amount: Double)? = { nil }) {
        self.performance = performance
        self.colour = colour
        self.style = style
        self.hearing = hearing
        self.felt = felt
        self.look = look
        self.dance = dance
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            // The frame's own time, read inside the drawing: a canvas that
            // doesn't depend on the timeline is taken as unchanged and never
            // redrawn between changes of state, which froze the mouth, the
            // blinks and the eyes (found in the first real run).
            let now = ProcessInfo.processInfo.systemUptime + timeline.date.timeIntervalSinceNow
            Canvas { context, size in
                let posed = performance.pose(at: now)
                let danced = Dance.apply(dance(), to: posed)
                let pose = felt().apply(to: Attention.apply(look(), mood: performance.mood, to: danced))
                // Drowsy late at night: the visor dims to under half.
                let lit = colour.opacity(1 - 0.55 * performance.dimming(at: now))
                Self.draw(pose, in: &context, size: size, colour: lit, style: style, hearing: Double(hearing()))
            }
        }
        .accessibilityLabel("Companion's face, \(performance.mood.rawValue)")
    }

    /// One pose, still, on black: for looking at the face without a window.
    @MainActor
    public static func image(_ pose: Pose, size: CGSize, colour: Color = VisorColour.cyan.color,
                             style: VisorStyle = .panel, hearing: Double = 0) -> CGImage? {
        let view = Canvas { context, size in
            draw(pose, in: &context, size: size, colour: colour, style: style, hearing: hearing)
        }
            .frame(width: size.width, height: size.height)
            .background(.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage
    }

    static func draw(_ pose: Pose, in context: inout GraphicsContext, size: CGSize, colour: Color,
                     style: VisorStyle = .panel, hearing: Double = 0) {
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

        let shapes = FaceGeometry.shapes(pose.face, muzzle: pose.muzzle, gaze: pose.gaze)
        // Speech is about 0.02 to 0.1 RMS at the microphone.
        let glow = min(1, hearing * 10)
        guard style == .panel else {
            var outline = Path()
            for shape in shapes where shape.count > 2 {
                outline.addLines(shape.map { CGPoint(x: $0.x, y: $0.y) })
                outline.closeSubpath()
            }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 9 + 10 * glow))
                layer.fill(outline, with: .color(colour.opacity(0.75 + 0.2 * glow)))
            }
            context.fill(outline, with: .color(colour))
            return
        }
        let lit = FaceMatrix.lit(shapes, on: grid)
        let side = min(grid.cell, grid.rowHeight) * FaceMatrix.dotFill
        func dot(_ column: Int, _ row: Int) -> CGRect {
            let centre = grid.centre(column, row)
            return CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        }
        var bright = Path()
        for cell in lit {
            bright.addRoundedRect(in: dot(cell.column, cell.row), cornerSize: CGSize(width: side * 0.2, height: side * 0.2))
        }
        context.drawLayer { halo in
            halo.addFilter(.blur(radius: side * scale * (0.9 + 0.5 * glow)))
            halo.fill(bright, with: .color(colour.opacity(0.75 + 0.25 * glow)))
        }
        context.fill(bright, with: .color(colour))
    }
}

import Foundation

/// Dials to outlines: protoke's face_render.py geometry, in its 1000-unit
/// face space centred on the origin, y down. Two eyes and a mouth, nothing
/// else; a protogen visor has no nose and no iris.
public enum FaceGeometry {
    public static let unit = 1000.0

    static let eyeCentre = Point(268, -132)
    static let eyeHalfWidth = 152.0
    static let eyeThickness = 62.0
    static let eyeClosedThickness = 17.0
    static let eyeCaretRise = 112.0
    /// Every shape narrows to this fraction of its width as it shuts, so a
    /// blink from any expression lands on the same line.
    static let eyeShutWidth = 0.86

    static let mouthCentreY = 126.0
    static let mouthHalfWidth = 262.0
    /// How much more the mouth moves than the eyes when the head shifts: it is
    /// further out on the muzzle.
    public static let mouthParallax = 1.7
    static let mouthAperture = 210.0
    static let mouthThickness = 34.0
    static let mouthCornerLift = 78.0

    /// How far the eyes travel at the edge of their gaze, in face units.
    public static let gazeReach = Point(55, 35)

    /// Every filled outline of one pose. `muzzle` shifts the mouth alone;
    /// `gaze` (-1...1 each way) moves the eyes, and the mouth a little with
    /// them, as a head turns a touch towards what it looks at.
    public static func shapes(_ face: Face, muzzle: Point = .zero, gaze: Point = .zero) -> [[Point]] {
        let sharpness = min(1, max(0, face.sharpness))
        let look = gaze * gazeReach
        let mouthShift = muzzle + look * 0.18
        var mouth = self.mouth(face.mouth, sharpness: sharpness)
        if mouthShift != .zero { mouth = mouth.map { $0.map { $0 + mouthShift } } }
        var eyes = [eye(face.eye, sharpness: sharpness), eye(face.eye, mirrored: true, sharpness: sharpness)]
        if look != .zero { eyes = eyes.map { $0.map { $0 + look } } }
        return eyes + mouth
    }

    // MARK: eyes

    public static func eye(_ eye: Eye, mirrored: Bool = false, sharpness: Double = 0) -> [Point] {
        let openness = min(1, max(0, eye.openness))
        let shut = eyeHalfWidth * eyeShutWidth
        let halfWidth = shut + (eyeHalfWidth - shut) * openness
        let height = eyeCaretRise * 1.15 * openness
        let thickness = eyeClosedThickness + (eyeThickness - eyeClosedThickness) * openness * eye.weight
        let ovalHeight = max(eyeClosedThickness / 2, height * 0.92)

        var outline: [Point]
        if eye.roundness >= 0.985 {
            outline = oval(halfWidth * 0.68, ovalHeight, sharpness: sharpness)
        } else {
            // Inner point, over the bow, to the outer end; the hook drags that
            // outer end back down and inward.
            let slant = eye.slant * height * 0.55
            let bow = eye.bow * height
            let hook = eye.hook * height * 0.75
            let outer = Point(halfWidth * 0.72, -bow * 0.55 - slant)
            var spine = quadratic(Point(-halfWidth, slant * 0.35), Point(-halfWidth * 0.18, -bow * 0.95), outer,
                                  steps: 12, sharpness: sharpness)
            if hook > 1 {
                spine += quadratic(outer, Point(halfWidth * 1.02, -bow * 0.30 - slant),
                                   Point(halfWidth * 0.86, hook - bow * 0.20 - slant),
                                   steps: 8, sharpness: sharpness).dropFirst()
            }
            outline = stroke(spine, taper(spine.count, thickness, tip: 0.10, tail: 0.90))
            if eye.roundness > 0 {
                outline = morph(outline, oval(halfWidth * 0.68, ovalHeight, sharpness: sharpness),
                                eye.roundness, count: 40)
            }
        }
        let sign = mirrored ? -1.0 : 1.0
        return outline.map { Point(eyeCentre.x * sign + $0.x * sign, eyeCentre.y + $0.y) }
    }

    // MARK: mouth

    /// Solid, never a ring: a ring thins to nothing as the mouth closes.
    public static func mouth(_ mouth: Mouth, sharpness: Double = 0) -> [[Point]] {
        let halfWidth = mouthHalfWidth * max(0.05, mouth.width)
        let aperture = mouthAperture * max(0, mouth.aperture)
        let lift = mouthCornerLift * mouth.curve
        let skew = mouthCornerLift * mouth.skew

        guard aperture >= mouthThickness else {
            let left = Point(-halfWidth, mouthCentreY - lift + skew)
            let right = Point(halfWidth, mouthCentreY - lift - skew)
            let spine = mouth.jag > 0.001
                ? jagged(left, right, lift: lift, amount: mouth.jag, sharpness: sharpness)
                : quadratic(left, Point(0, mouthCentreY + lift * 0.75), right, steps: 16, sharpness: sharpness)
            return [stroke(spine, Array(repeating: mouthThickness * mouth.weight, count: spine.count))]
        }
        return [lens(halfWidth, aperture, lift: lift, sharpness: sharpness)]
    }

    /// An open mouth: an ellipse bent along a smiling centre line, built
    /// directly because an offset outline folds through itself at the tips.
    static func lens(_ halfWidth: Double, _ aperture: Double, lift: Double, steps: Int = 30,
                     sharpness: Double = 0) -> [Point] {
        (0..<steps).map { step in
            let angle = 2 * Double.pi * Double(step) / Double(steps)
            var x = halfWidth * cos(angle)
            let ratio = halfWidth != 0 ? x / halfWidth : 0
            let centre = mouthCentreY + lift * 0.75 - lift * 1.75 * ratio * ratio
            var y = centre + aperture / 2 * sin(angle)
            if sharpness > 0 {
                let edge = abs(cos(angle)) + abs(sin(angle))
                let e = edge == 0 ? 1 : edge
                x += (x / e - x) * sharpness
                y = centre + (y - centre) / e * sharpness + (y - centre) * (1 - sharpness)
            }
            return Point(x, y)
        }
    }

    /// The resting zigzag grin: two broad points, the ends riding up towards the eyes.
    static func jagged(_ left: Point, _ right: Point, lift: Double, amount: Double, peaks: Int = 2,
                       sharpness: Double = 0) -> [Point] {
        let span = right.x - left.x
        let points = (0...(peaks * 2)).map { step -> Point in
            let fraction = Double(step) / Double(peaks * 2)
            let base = left.y + (right.y - left.y) * fraction
            let swing = lift * 0.46 * amount * (step % 2 == 1 ? 1 : -1)
            let ends = lift * 0.55 * amount * (1 - abs(fraction - 0.5) * 2)
            return Point(left.x + span * fraction, base + lift * 0.45 + swing + ends)
        }
        var smoothed: [Point] = []
        for index in 0..<(points.count - 1) {
            let (a, b) = (points[index], points[index + 1])
            smoothed += quadratic(a, Point((a.x + b.x) / 2, a.y), b, steps: 4, sharpness: sharpness).dropLast()
        }
        smoothed.append(points[points.count - 1])
        return smoothed
    }

    // MARK: curves

    /// A quadratic bezier as a polyline; `sharpness` pulls it towards the
    /// straight run start, control, end, so at 1 it is two edges and a corner.
    static func quadratic(_ start: Point, _ control: Point, _ end: Point, steps: Int = 14,
                          sharpness: Double = 0) -> [Point] {
        (0...steps).map { step in
            let t = Double(step) / Double(steps)
            let u = 1 - t
            let curved = u * u * start + 2 * u * t * control + t * t * end
            guard sharpness > 0 else { return curved }
            let straight = t < 0.5 ? start + (control - start) * (t * 2) : control + (end - control) * ((t - 0.5) * 2)
            return curved + (straight - curved) * sharpness
        }
    }

    static func normals(_ points: [Point], closed: Bool = false) -> [Point] {
        let count = points.count
        return (0..<count).map { index in
            let previous = closed ? points[(index - 1 + count) % count] : points[max(0, index - 1)]
            let following = closed ? points[(index + 1) % count] : points[min(count - 1, index + 1)]
            let d = following - previous
            var length = (d.x * d.x + d.y * d.y).squareRoot()
            if length == 0 { length = 1 }
            return Point(-d.y / length, d.x / length)
        }
    }

    /// A path to a fillable outline of the given thickness at each point.
    static func stroke(_ points: [Point], _ thickness: [Double], closed: Bool = false) -> [Point] {
        guard points.count >= 2 else { return [] }
        let normals = normals(points, closed: closed)
        var outer: [Point] = []
        var inner: [Point] = []
        for (index, point) in points.enumerated() {
            let half = max(0.35, thickness[index] / 2)
            outer.append(point + normals[index] * half)
            inner.append(point - normals[index] * half)
        }
        return outer + inner.reversed()
    }

    /// Thickness along an eye: a fine inner point swelling to a blunt tail.
    static func taper(_ count: Int, _ peak: Double, tip: Double, tail: Double) -> [Double] {
        (0..<count).map { index in
            let fraction = Double(index) / Double(max(1, count - 1))
            let swell = sin(Double.pi * min(1, fraction * 0.78 + 0.06))
            let blend = tip + (1 - tip) * swell
            return max(0.6, peak * max(blend, tail * fraction))
        }
    }

    /// A filled oval; `sharpness` pulls it towards the diamond in the same box.
    static func oval(_ halfWidth: Double, _ halfHeight: Double, steps: Int = 30, sharpness: Double = 0) -> [Point] {
        (0..<steps).map { step in
            let angle = 2 * Double.pi * Double(step) / Double(steps)
            var p = Point(halfWidth * cos(angle), halfHeight * sin(angle))
            if sharpness > 0 {
                let edge = abs(cos(angle)) + abs(sin(angle))
                p += (p / (edge == 0 ? 1 : edge) - p) * sharpness
            }
            return p
        }
    }

    static func signedArea(_ points: [Point]) -> Double {
        var total = 0.0
        for (index, a) in points.enumerated() {
            let b = points[(index + 1) % points.count]
            total += a.x * b.y - b.x * a.y
        }
        return total / 2
    }

    /// Evenly spaced points around a closed outline from a fixed start, so two
    /// outlines can be morphed without one turning inside out.
    static func resample(_ points: [Point], _ count: Int) -> [Point] {
        guard points.count >= 3 else { return points }
        let points = signedArea(points) < 0 ? points.reversed() : points
        let start = points.indices.min { (points[$0].x, points[$0].y) < (points[$1].x, points[$1].y) }!
        let ordered = Array(points[start...] + points[..<start])
        var lengths: [Double] = []
        var total = 0.0
        for (index, current) in ordered.enumerated() {
            let d = ordered[(index + 1) % ordered.count] - current
            total += (d.x * d.x + d.y * d.y).squareRoot()
            lengths.append(total)
        }
        guard total > 0 else { return Array(repeating: ordered[0], count: count) }
        var sampled: [Point] = []
        var index = 0
        for step in 0..<count {
            let target = total * Double(step) / Double(count)
            while index < lengths.count - 1 && lengths[index] < target { index += 1 }
            let previous = index > 0 ? lengths[index - 1] : 0
            var span = lengths[index] - previous
            if span == 0 { span = 1 }
            let current = ordered[index]
            let following = ordered[(index + 1) % ordered.count]
            sampled.append(current + (following - current) * ((target - previous) / span))
        }
        return sampled
    }

    /// One outline part way to another.
    public static func morph(_ first: [Point], _ second: [Point], _ blend: Double, count: Int = 48) -> [Point] {
        zip(resample(first, count), resample(second, count)).map { $0 + ($1 - $0) * blend }
    }
}

/// The face as an LED panel shows it: the same outlines sampled onto a grid of
/// lit cells (protoke's face_matrix.py). Coarse is what reads as a panel.
public enum FaceMatrix {
    public static let columns = 36
    /// How much of each cell the lit dot fills; below 1 the grid stays visible.
    public static let dotFill = 0.72

    public struct Grid: Sendable {
        public let left, top, cell, rowHeight: Double
        public let columns, rows: Int
        public func centre(_ column: Int, _ row: Int) -> Point {
            Point(left + (Double(column) + 0.5) * cell, top + (Double(row) + 0.5) * rowHeight)
        }
    }

    /// A grid anchored to the face rather than to each pose, sized from the
    /// widest the face gets in any of these expressions, so cells stay put
    /// while shapes change inside them.
    public static func grid(for resting: [Face], columns: Int = columns) -> Grid {
        let corners = [Point(-1, -1), Point(1, 1)]
        let widest = resting.flatMap { face in
            corners.flatMap { FaceGeometry.shapes(Face(face.eye.with(openness: 1), Viseme.ah.mouth), gaze: $0) }
        }
        let xs = widest.flatMap { $0.map(\.x) }
        let ys = widest.flatMap { $0.map(\.y) }
        let pad = (xs.max()! - xs.min()!) * 0.04
        let (left, top) = (xs.min()! - pad, ys.min()! - pad)
        let (width, height) = (xs.max()! + pad - left, ys.max()! + pad - top)
        let cell = width / Double(columns)
        let rows = max(1, Int((height / cell).rounded()))
        return Grid(left: left, top: top, cell: cell, rowHeight: height / Double(rows), columns: columns, rows: rows)
    }

    /// The lit cells, by scanline with even-odd filling, so a hole stays dark.
    public static func lit(_ shapes: [[Point]], on grid: Grid) -> [(column: Int, row: Int)] {
        var lit: [(Int, Int)] = []
        var seen = Set<Int>()
        for row in 0..<grid.rows {
            let y = grid.top + (Double(row) + 0.5) * grid.rowHeight
            for shape in shapes {
                let crossings = crossings(shape, y)
                var index = 0
                while index + 1 < crossings.count {
                    let (start, end) = (crossings[index], crossings[index + 1])
                    let first = Int(((start - grid.left) / grid.cell).rounded(.down))
                    let last = Int(((end - grid.left) / grid.cell).rounded(.down))
                    let (low, high) = (max(0, first), min(grid.columns - 1, last))
                    if low <= high {
                        for column in low...high {
                            let centre = grid.left + (Double(column) + 0.5) * grid.cell
                            if start <= centre && centre <= end && seen.insert(row * grid.columns + column).inserted {
                                lit.append((column, row))
                            }
                        }
                    }
                    index += 2
                }
            }
        }
        return lit
    }

    static func crossings(_ shape: [Point], _ y: Double) -> [Double] {
        var found: [Double] = []
        for (index, a) in shape.enumerated() {
            let b = shape[(index + 1) % shape.count]
            if (a.y <= y && y < b.y) || (b.y <= y && y < a.y) {
                found.append(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
            }
        }
        return found.sorted()
    }
}

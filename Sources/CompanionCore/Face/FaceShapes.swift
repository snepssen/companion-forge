import Foundation

// protoke's face, ported from face_shapes.py and face_expression.py: every
// eye and every mouth is one shape with its dials in a different position, so
// any expression can be half way to any other and a viseme is just a mouth.
// The numbers are protoke's; a change to one belongs there first.

public typealias Point = SIMD2<Double>

/// One eye's dials. `hook` curls the outer end down into the point that makes
/// a visor eye read as one; `roundness` takes the same shape to a filled oval.
public struct Eye: Equatable, Sendable {
    public var openness, bow, slant, hook, roundness, weight: Double

    public init(_ openness: Double = 1, _ bow: Double = 0.55, _ slant: Double = 0.30,
                _ hook: Double = 0.70, _ roundness: Double = 0.10, _ weight: Double = 1) {
        (self.openness, self.bow, self.slant, self.hook, self.roundness, self.weight) =
            (openness, bow, slant, hook, roundness, weight)
    }

    public func blended(_ other: Eye, _ amount: Double) -> Eye {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return Eye(mix(openness, other.openness), mix(bow, other.bow), mix(slant, other.slant),
                   mix(hook, other.hook), mix(roundness, other.roundness), mix(weight, other.weight))
    }

    public func with(openness: Double) -> Eye {
        var eye = self
        eye.openness = openness
        return eye
    }
}

/// One mouth's dials. `width` and `aperture` are the visemes, `curve` the
/// smile, `skew` the smirk, `jag` the zigzag grin a visor wears at rest.
public struct Mouth: Equatable, Sendable {
    public var width, aperture, curve, skew, jag, weight: Double

    public init(_ width: Double = 0.86, _ aperture: Double = 0, _ curve: Double = 0.70,
                _ skew: Double = 0, _ jag: Double = 0, _ weight: Double = 1) {
        (self.width, self.aperture, self.curve, self.skew, self.jag, self.weight) =
            (width, aperture, curve, skew, jag, weight)
    }

    public func blended(_ other: Mouth, _ amount: Double) -> Mouth {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return Mouth(mix(width, other.width), mix(aperture, other.aperture), mix(curve, other.curve),
                     mix(skew, other.skew), mix(jag, other.jag), mix(weight, other.weight))
    }
}

/// An eye setting, a mouth setting and how hard the drawing is: `sharpness`
/// straightens every curve towards its control polygon.
public struct Face: Equatable, Sendable {
    public var eye: Eye
    public var mouth: Mouth
    public var sharpness: Double

    public init(_ eye: Eye, _ mouth: Mouth, sharpness: Double = 0) {
        self.eye = eye
        self.mouth = mouth
        self.sharpness = sharpness
    }

    public func blended(_ other: Face, _ amount: Double) -> Face {
        Face(eye.blended(other.eye, amount), mouth.blended(other.mouth, amount),
             sharpness: sharpness + (other.sharpness - sharpness) * amount)
    }
}

/// Mouth settings for each visible articulation.
public enum Viseme: String, CaseIterable, Sendable {
    case rest, mm, ff, ee, eh, ah, oh, oo, th, ll

    public var mouth: Mouth {
        switch self {
        case .rest: Mouth(0.86, 0.00, 0.70)
        case .mm: Mouth(0.80, 0.00, 0.40)
        case .ff: Mouth(0.84, 0.14, 0.32)
        case .ee: Mouth(1.00, 0.30, 0.58)
        case .eh: Mouth(0.92, 0.52, 0.44)
        case .ah: Mouth(0.86, 1.00, 0.25)
        case .oh: Mouth(0.60, 0.86, 0.22)
        case .oo: Mouth(0.40, 0.52, 0.18)
        case .th: Mouth(0.88, 0.26, 0.40)
        case .ll: Mouth(0.78, 0.58, 0.36)
        }
    }
}

/// Resting faces, as dial settings. `motion` is how freely the head moves:
/// anger is direct, and directness is still.
public enum Expression: String, CaseIterable, Sendable {
    case visor, grin, hooked, sharp, smug, content, happy, wide, sleepy, delighted, curious

    public var face: Face {
        //                                 open  bow  slant hook round weight
        //                               width  aper curve skew  jag  weight
        switch self {
        case .visor: Face(Eye(1.0, 0.55, 0.34, 0.80, 0.06, 1.0), Mouth(0.84, 0.0, 0.62, 0.34, 0.0, 1.0))
        case .grin: Face(Eye(1.0, 0.62, 0.30, 0.85, 0.05, 1.0), Mouth(1.00, 0.0, 0.66, 0.0, 0.90, 0.95))
        case .hooked: Face(Eye(1.0, 0.95, 0.05, 1.00, 0.0, 0.78), Mouth(1.00, 0.0, 0.72, 0.0, 0.75, 0.86))
        case .sharp: Face(Eye(1.0, 0.10, -0.85, 0.55, 0.0, 1.10), Mouth(0.92, 0.0, 0.22, 0.0, 0.85, 1.05),
                          sharpness: 1.0)
        case .smug: Face(Eye(0.62, 0.18, 0.10, 0.30, 0.10, 0.95), Mouth(0.82, 0.0, 0.58, 0.42, 0.0, 1.0))
        case .content: Face(Eye(1.0, 1.00, 0.0, 0.10, 0.0, 0.95), Mouth(0.88, 0.0, 0.14, 0.0, 0.0, 1.0))
        case .happy: Face(Eye(1.0, 1.00, 0.0, 0.10, 0.0, 0.95), Mouth(1.00, 0.0, 0.62, 0.0, 0.95, 0.95))
        case .wide: Face(Eye(1.0, 0.40, 0.0, 0.0, 1.0, 1.0), Mouth(0.88, 0.0, 0.10, 0.0, 0.0, 1.0))
        case .sleepy: Face(Eye(0.24, 0.05, 0.0, 0.0, 0.0, 1.0), Mouth(0.86, 0.0, 0.08, 0.0, 0.0, 1.0))
        case .delighted: Face(Eye(1.0, 1.00, 0.0, 0.10, 0.0, 0.95), Mouth(0.56, 0.78, 0.10, 0.0, 0.0, 1.0))
        case .curious: Face(Eye(1.0, 0.40, 0.0, 0.0, 1.0, 1.0), Mouth(1.00, 0.0, 0.62, 0.0, 0.90, 0.95))
        }
    }

    public var motion: Double { self == .sharp ? 0.22 : 1.0 }
}

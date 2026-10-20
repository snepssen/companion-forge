import SwiftUI

/// What the visor is lit with. Protogen visors come in every colour; these
/// are the ones that read well on black.
public enum VisorColour: String, CaseIterable, Identifiable, Sendable {
    case cyan, magenta, lime, amber, violet, white

    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }

    public var color: Color {
        switch self {
        case .cyan: Color(red: 0x4F / 255, green: 0xE3 / 255, blue: 0xF5 / 255)
        case .magenta: Color(red: 0xFF / 255, green: 0x5C / 255, blue: 0xD2 / 255)
        case .lime: Color(red: 0x9B / 255, green: 0xF5 / 255, blue: 0x5A / 255)
        case .amber: Color(red: 0xFF / 255, green: 0xB0 / 255, blue: 0x3B / 255)
        case .violet: Color(red: 0xA8 / 255, green: 0x8B / 255, blue: 0xFF / 255)
        case .white: Color(red: 0xEE / 255, green: 0xF4 / 255, blue: 0xFF / 255)
        }
    }

    static let key = "visorColour"
}

/// How the face is drawn: lit cells on an LED panel, or protoke's smooth
/// outlines, the same face either way.
public enum VisorStyle: String, CaseIterable, Identifiable, Sendable {
    case panel, smooth

    public var id: String { rawValue }
    public var name: String { self == .panel ? "LED panel" : "Smooth" }

    static let key = "visorStyle"
}

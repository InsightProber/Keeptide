import SwiftUI

extension Color {
    /// The colour a collection's stored colour name stands for; an unknown name is blue.
    static func collection(_ name: String) -> Color {
        switch name {
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        case "gray": .gray
        default: .blue
        }
    }
}

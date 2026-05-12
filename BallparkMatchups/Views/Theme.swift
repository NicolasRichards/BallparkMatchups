import SwiftUI

enum Theme {
    static let background = Color(hex: "#0A1A0A")
    static let primaryText = Color(hex: "#F5F5F5")
    static let secondaryText = Color(hex: "#888888")
    static let situationBackground = Color(hex: "#112211")
    static let cardBackground = Color(hex: "#0D1A0D")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Text Modifiers

extension View {
    func statFont(size: CGFloat, bold: Bool = false) -> some View {
        self.font(.system(size: size, weight: bold ? .bold : .regular, design: .monospaced))
    }

    func labelFont(size: CGFloat = 13, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight, design: .default))
            .foregroundColor(Theme.secondaryText)
    }

    func primaryFont(size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        self.font(.system(size: size, weight: weight, design: .default))
            .foregroundColor(Theme.primaryText)
    }
}

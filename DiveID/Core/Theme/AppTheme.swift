import SwiftUI

extension Color {
    static let appBackground = Color.black
    static let appSurface = Color(red: 0.12, green: 0.04, blue: 0.20)
    static let appSurfaceElevated = Color(red: 0.18, green: 0.08, blue: 0.27)
    static let appAccent = Color(red: 0.72, green: 0.29, blue: 0.95)
    static let appHighlight = Color(red: 0.98, green: 0.32, blue: 0.67)
    static let appPrimary = appAccent
    static let appTextPrimary = Color.white
    static let appTextSecondary = Color.white.opacity(0.72)
    static let appSuccess = Color(red: 0.30, green: 0.82, blue: 0.62)
    static let appWarning = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let appError = Color(red: 1.0, green: 0.38, blue: 0.48)
}

enum AppTheme {
    static let spacing: CGFloat = 16
    static let radius: CGFloat = 18
}

extension View {
    func appScreenBackground() -> some View {
        scrollContentBackground(.hidden)
            .foregroundStyle(Color.appTextPrimary)
            .background(Color.appBackground.ignoresSafeArea())
    }
}

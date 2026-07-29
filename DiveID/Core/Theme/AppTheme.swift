import SwiftUI

extension Color {
    static let appBackground = Color(uiColor: .systemGroupedBackground)
    static let appSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let appPrimary = Color(red: 0.02, green: 0.43, blue: 0.58)
    static let appSecondary = Color(red: 0.08, green: 0.65, blue: 0.68)
    static let appTextPrimary = Color.primary
    static let appTextSecondary = Color.secondary
    static let appSuccess = Color.green
    static let appWarning = Color.orange
}

enum AppTheme { static let spacing: CGFloat = 16; static let radius: CGFloat = 18 }

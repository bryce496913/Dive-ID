import SwiftUI

extension Color {
    static let appBackground = Color.black
    static let appSurface = Color(red: 0.12, green: 0.04, blue: 0.20)
    static let appSurfaceElevated = Color(red: 0.18, green: 0.08, blue: 0.27)
    static let appAccent = Color(red: 0.72, green: 0.29, blue: 0.95)
    static let appHighlight = Color(red: 0.98, green: 0.32, blue: 0.67)
    /// Deeper shades of the accent and highlight, for fills behind white text: both stay
    /// above 4.5:1 with white, where the bright accent and highlight do not.
    static let appAccentDeep = Color(red: 0.50, green: 0.17, blue: 0.76)
    static let appHighlightDeep = Color(red: 0.76, green: 0.18, blue: 0.48)
    static let appPrimary = appAccent
    static let appTextPrimary = Color.white
    static let appTextSecondary = Color.white.opacity(0.72)
    static let appStroke = Color.white.opacity(0.09)
    static let appSuccess = Color(red: 0.30, green: 0.82, blue: 0.62)
    static let appWarning = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let appError = Color(red: 1.0, green: 0.38, blue: 0.48)
}

extension LinearGradient {
    /// The brand fill for primary actions and hero surfaces: deep accent into deep highlight.
    static var appBrand: LinearGradient { LinearGradient(colors: [.appAccentDeep, .appHighlightDeep], startPoint: .topLeading, endPoint: .bottomTrailing) }
    /// Card fill: the surface color lifting slightly toward its top edge.
    static var appCard: LinearGradient { LinearGradient(colors: [.appSurfaceElevated, .appSurface], startPoint: .top, endPoint: .bottom) }
}

enum AppTheme {
    /// Spacing scale for stack spacing and explicit padding, taken from the values the screens already use.
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }
    static let radius: CGFloat = 18
    /// Corner radius for hero surfaces such as Home's banner and the species header.
    static let heroRadius: CGFloat = 28
    /// Corner radius for buttons and other controls inside cards.
    static let controlRadius: CGFloat = 14
}

extension View {
    /// Black with a soft accent glow from the top and a faint highlight from the bottom,
    /// so screens read as depth rather than a flat black page.
    func appScreenBackground() -> some View {
        scrollContentBackground(.hidden)
            .foregroundStyle(Color.appTextPrimary)
            .background {
                ZStack {
                    Color.appBackground
                    RadialGradient(colors: [Color.appAccent.opacity(0.30), .clear], center: .top, startRadius: 0, endRadius: 520)
                    RadialGradient(colors: [Color.appHighlight.opacity(0.12), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 420)
                }
                .ignoresSafeArea()
            }
    }

    /// The standard card: a lifted surface with a hairline edge.
    func appCard(cornerRadius: CGFloat = AppTheme.radius) -> some View {
        background(LinearGradient.appCard, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.appStroke, lineWidth: 1))
    }
}

/// Primary actions: the brand gradient, a light press, and an obvious disabled state.
struct AppPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.appTextPrimary)
            .background(LinearGradient.appBrand, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
            .shadow(color: Color.appAccent.opacity(isEnabled ? 0.45 : 0), radius: 14, y: 6)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Cards that act as buttons: a slight press-down, without the default highlight.
struct AppCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

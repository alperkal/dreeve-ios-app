import SwiftUI

typealias AppAppearance = ThemePreference

extension ThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

// Dynamic colors follow the selected color scheme throughout SwiftUI and MapKit.
enum DreeveTheme {
    private static func adaptive(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0 / 255, green: value.1 / 255, blue: value.2 / 255, alpha: 1)
        })
    }
    static let background = adaptive(dark: (9, 16, 28), light: (243, 247, 241))
    static let surface = adaptive(dark: (19, 31, 47), light: (255, 255, 255))
    static let elevated = adaptive(dark: (27, 42, 59), light: (227, 236, 224))
    static let accent = adaptive(dark: (177, 244, 82), light: (39, 102, 39))
    static let muted = adaptive(dark: (153, 170, 185), light: (79, 96, 108))
}

struct SurfaceCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct MetricView: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        SurfaceCard {
            Label(title, systemImage: symbol)
                .foregroundStyle(DreeveTheme.muted)
                .font(.caption)
            Text(value)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.top, 6)
        }
    }
}

struct EmptyMessage: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, minHeight: 180)
    }
}

extension View {
    func dreeveBackground() -> some View {
        self.background(DreeveTheme.background.ignoresSafeArea())
    }
}

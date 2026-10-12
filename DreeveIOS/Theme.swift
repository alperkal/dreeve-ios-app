import SwiftUI

// Initial visual direction, independent of any official Dreeve brand assets.
enum DreeveTheme {
    static let background = Color(red: 9/255, green: 16/255, blue: 28/255)
    static let surface = Color(red: 19/255, green: 31/255, blue: 47/255)
    static let elevated = Color(red: 27/255, green: 42/255, blue: 59/255)
    static let accent = Color(red: 177/255, green: 244/255, blue: 82/255)
    static let muted = Color(red: 153/255, green: 170/255, blue: 185/255)
}

struct SurfaceCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
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

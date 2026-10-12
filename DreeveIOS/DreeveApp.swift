import SwiftUI

@main
struct DreeveApp: App {
    @StateObject private var session = DreeveSession()
    @StateObject private var healthSync = HealthSyncStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(healthSync)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: DreeveSession

    var body: some View {
        Group {
            if session.isConfigured {
                TabView {
                    DashboardView()
                        .tabItem { Label("Overview", systemImage: "chart.bar.xaxis") }
                    ActivitiesView()
                        .tabItem { Label("Activities", systemImage: "figure.run") }
                    HealthSyncView()
                        .tabItem { Label("Health sync", systemImage: "heart") }
                    UploadView()
                        .tabItem { Label("Upload", systemImage: "square.and.arrow.up") }
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
                .tint(DreeveTheme.accent)
            } else {
                NavigationStack { SettingsView() }
            }
        }
        .background(DreeveTheme.background)
    }
}

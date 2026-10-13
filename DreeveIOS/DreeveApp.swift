import SwiftUI
import SwiftData
import CoreData

@main
struct DreeveApp: App {
    @StateObject private var goals = GoalPersistence()
    @StateObject private var session = DreeveSession()
    @StateObject private var healthSync = HealthSyncStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = goals.container {
                    RootView().modelContainer(container)
                } else { RootView() }
            }
                .environmentObject(goals)
                .environmentObject(session.goalProgress)
                .environmentObject(session)
                .environmentObject(healthSync)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var persistence: GoalPersistence
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.isConfigured {
                TabView {
                    DashboardView()
                        .tabItem { Label("Overview", systemImage: "chart.bar.xaxis") }
                    ActivitiesView()
                        .tabItem { Label("Activities", systemImage: "figure.run") }
                    GoalsView()
                        .tabItem { Label("Goals", systemImage: "target") }
                    GearView()
                        .tabItem { Label("Gear", systemImage: "shoeprints.fill") }
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
        .task(id: "\(session.serverAddress)|\(scenePhase == .active)") {
            guard scenePhase == .active, session.isConfigured else { return }
            await session.refreshGoals()
            await persistence.checkAccount()
            _ = try? await session.testConnection()
            // Refresh on open / foreground and while active: covers external edits,
            // deletions, asynchronous import completion and calendar rollover.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                await session.refreshGoals()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)) { note in
            if let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event {
                persistence.received(event)
            }
        }
    }
}

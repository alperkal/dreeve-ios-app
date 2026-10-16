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
                    RootView().background { GoalWidgetPublisher() }.modelContainer(container)
                } else {
                    RootView().task { try? GoalWidgetStorage().write(.empty) }
                }
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
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if session.isConfigured {
                TabView(selection: $selectedTab) {
                    DashboardView()
                        .tabItem { Label("Overview", systemImage: "chart.bar.xaxis") }
                        .tag(0)
                    ActivitiesView()
                        .tabItem { Label("Activities", systemImage: "figure.run") }
                        .tag(1)
                    GoalsView()
                        .tabItem { Label("Goals", systemImage: "target") }
                        .tag(2)
                    GearView()
                        .tabItem { Label("Gear", systemImage: "shoeprints.fill") }
                        .tag(3)
                    HealthSyncView()
                        .tabItem { Label("Health sync", systemImage: "heart") }
                        .tag(4)
                    UploadView()
                        .tabItem { Label("Upload", systemImage: "square.and.arrow.up") }
                        .tag(5)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(6)
                }
                .tint(DreeveTheme.accent)
            } else {
                NavigationStack { SettingsView() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Return ordinary app opens to Overview.
            if phase == .background { selectedTab = 0 }
        }
        .onOpenURL { url in
            // Accept the old widget URL too, so cached widget timelines open Overview.
            if url.scheme == "dreeve", ["overview", "goals"].contains(url.host ?? "") {
                selectedTab = 0
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

import SwiftUI
import SwiftData
import CoreData
import WidgetKit

@main
struct DreeveApp: App {
    @StateObject private var watchBridge = PhoneGoalWatchBridge()
    @StateObject private var goals = GoalPersistence()
    @StateObject private var session = DreeveSession()
    @StateObject private var healthSync = HealthSyncStore()
    @StateObject private var healthDiscovery = HealthImportDiscovery()

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = goals.container {
                    RootView().background { GoalWidgetPublisher() }.modelContainer(container)
                } else {
                    // Preserve the saved widget if Goals storage is temporarily unavailable.
                    RootView()
                }
            }
                .environmentObject(watchBridge)
                .environmentObject(goals)
                .task { watchBridge.start() }
                .environmentObject(session.goalProgress)
                .environmentObject(session)
                .environmentObject(healthSync)
                .environmentObject(healthDiscovery)
                .onChange(of: session.serverAddress) { old, new in
                    // Only an explicit connection change/logout clears the old scope.
                    // Initial unavailable storage or credentials must not clear it.
                    guard old != new else { return }
                    watchBridge.selectInstance((try? DreeveAPIClient.validatedURL(new)).map(GoalEngine.instanceID))
                    do {
                        let storage = GoalWidgetStorage()
                        if let url = try? DreeveAPIClient.validatedURL(new),
                           storage.readResult().snapshot?.instanceID == GoalEngine.instanceID(url) { return }
                        try storage.write(.empty)
                        for kind in GoalWidgetStorage.kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
                    } catch {}
                }
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var persistence: GoalPersistence
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @EnvironmentObject private var watchBridge: PhoneGoalWatchBridge
    @EnvironmentObject private var healthSync: HealthSyncStore
    @EnvironmentObject private var healthDiscovery: HealthImportDiscovery
    @AppStorage("health.discovery.enabled") private var discoverWorkouts = true
    @AppStorage("health.includeRoutes") private var includeRoutes = true
    @AppStorage("health.includeHeartRate") private var includeHeartRate = true

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
                    NavigationStack { RoutesView() }
                        .tabItem { Label("Routes", systemImage: "map") }
                        .tag(6)
                    HealthSyncView()
                        .tabItem { Label("Health sync", systemImage: "heart") }
                        .tag(4)
                        .badge(healthDiscovery.visibleEntries.count)
                    GearView()
                        .tabItem { Label("Gear", systemImage: "shoeprints.fill") }
                        .tag(3)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(5)
                }
                .tint(DreeveTheme.accent)
            } else {
                NavigationStack { SettingsView() }
            }
        }
        .sheet(isPresented: $healthDiscovery.showingPrompt, onDismiss: { healthDiscovery.dismissedPrompt() }) {
            HealthImportPrompt {
                healthDiscovery.showingPrompt = false
                selectedTab = 4
            }
        }
        .onChange(of: session.serverAddress) { _, address in healthDiscovery.reset(server: address) }
        .onReceive(healthSync.$records) { records in
            healthDiscovery.noteRecords(records, server: session.serverAddress)
        }
        .task(id: "gearInventory|\(session.serverAddress)|\(scenePhase == .active)") {
            guard scenePhase == .active, session.isConfigured else { return }
            _ = try? await session.gear()
        }
        .task(id: "importQueue|\(session.serverAddress)|\(scenePhase == .active)") {
            guard scenePhase == .active, session.isConfigured else { return }
            while !Task.isCancelled {
                await healthSync.refreshQueuedImports(session: session)
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
        .task(id: "health|\(session.serverAddress)|\(scenePhase == .active)|\(discoverWorkouts)") {
            guard scenePhase == .active, session.isConfigured, discoverWorkouts else {
                healthDiscovery.stop()
                return
            }
            await healthDiscovery.start(session: session, sync: healthSync, routes: includeRoutes, heartRate: includeHeartRate)
            if !healthSync.isBusy { healthDiscovery.considerPrompt() }
            while !Task.isCancelled {
                // Retry a presentation after another sheet closes, without interrupting it.
                for _ in 0..<10 {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    if !healthSync.isBusy { healthDiscovery.considerPrompt() }
                }
                await healthDiscovery.check(session: session, sync: healthSync)
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
            watchBridge.start()
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

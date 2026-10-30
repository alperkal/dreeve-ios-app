import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var watchBridge: PhoneGoalWatchBridge
    @State private var url = ""
    @State private var key = ""
    @State private var isWorking = false
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var confirmDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 11) {
                        Image(systemName: "figure.run.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(DreeveTheme.accent)
                        Text("DREEVE")
                            .font(.system(size: 33, weight: .black, design: .rounded))
                            .tracking(2)
                    }
                    Text(session.isConfigured ? "Connected to your training world." : "Connect to your self-hosted Dreeve instance.")
                        .foregroundStyle(DreeveTheme.muted)
                }
                .padding(.vertical, 12)

                if session.isConfigured {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 15) {
                            Label("Connected", systemImage: "checkmark.shield.fill")
                                .font(.headline)
                                .foregroundStyle(DreeveTheme.accent)
                            Text(session.serverAddress)
                                .font(.subheadline)
                                .textSelection(.enabled)
                            if !session.serverVersion.isEmpty {
                                Text("Dreeve \(session.serverVersion)")
                                    .foregroundStyle(DreeveTheme.muted)
                                    .font(.caption)
                            }
                            Label(session.canUpload ? "Activity uploads enabled" : "Activity uploads disabled by server", systemImage: "square.and.arrow.up")
                                .font(.caption)
                                .foregroundStyle(DreeveTheme.muted)
                            Button("Test connection") {
                                Task {
                                    isWorking = true
                                    defer { isWorking = false }
                                    do {
                                        let result = try await session.testConnection()
                                        notice = "Connected to Dreeve \(result.version)."
                                    } catch { errorMessage = error.localizedDescription }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DreeveTheme.accent)
                            .foregroundStyle(DreeveTheme.background)
                            .disabled(isWorking)
                        }
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Apple Watch", systemImage: "applewatch").font(.headline)
                            Text(watchBridge.syncStatus).font(.caption).foregroundStyle(DreeveTheme.muted)
                            Button("Retry Watch sync") { watchBridge.retry() }
                                .buttonStyle(.bordered)
                        }
                    }
                    Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                        .padding(8)
                } else {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("SERVER CONNECTION")
                                .font(.caption.weight(.bold))
                                .tracking(1.4)
                                .foregroundStyle(DreeveTheme.muted)
                            TextField("https://dreeve.example.com", text: $url)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textContentType(.URL)
                                .padding(13)
                                .background(DreeveTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
                            SecureField("Dreeve API key (drv_…)", text: $key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(13)
                                .background(DreeveTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
                            Button {
                                Task {
                                    isWorking = true
                                    defer { isWorking = false }
                                    do {
                                        try await session.connect(address: url, key: key)
                                        key = ""
                                    } catch { errorMessage = error.localizedDescription }
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isWorking { ProgressView() }
                                    else { Label("Connect to Dreeve", systemImage: "network") }
                                    Spacer()
                                }
                                .padding(9)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DreeveTheme.accent)
                            .foregroundStyle(DreeveTheme.background)
                            .disabled(isWorking || url.isEmpty || key.isEmpty)
                        }
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API ACCESS")
                                .font(.caption.bold())
                                .foregroundStyle(DreeveTheme.accent)
                            Text("Generate an API key in the Dreeve admin panel: Settings → Security → API access. Set DREEVE_API_KEY in the server environment and recreate its containers.")
                                .font(.subheadline)
                            Text("The app requires HTTPS. For private home servers, a private VPN/tailnet with HTTPS works without making Dreeve publicly reachable. Your API key is saved in the iOS Keychain, never embedded into the app.")
                                .font(.caption)
                                .foregroundStyle(DreeveTheme.muted)
                        }
                    }
                }
                RouteProviderSettingsView()
                GearImageSearchSettingsView()
                if let notice {
                    Label(notice, systemImage: "checkmark.circle")
                        .foregroundStyle(DreeveTheme.accent)
                }
                Link("API documentation", destination: URL(string: "https://docs.dreeve.app/api/")!)
                    .font(.subheadline)
                    .tint(DreeveTheme.accent)
                    .padding(8)
            }
            .padding(18)
        }
        .dreeveBackground()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect from Dreeve?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { session.disconnect() }
        } message: { Text("This removes the server address and locally stored API key. No server activities are deleted.") }
        .alert("Connection error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }
}

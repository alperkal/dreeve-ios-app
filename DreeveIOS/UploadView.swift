import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @EnvironmentObject private var session: DreeveSession
    @State private var showImporter = false
    @State private var uploading = false
    @State private var uploadMessage: String?
    @State private var errorMessage: String?
    @State private var imports: [DreeveImport] = []
    @State private var loadingImports = false

    private var activityTypes: [UTType] {
        ["fit", "tcx", "gpx"].compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 15) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 49))
                                .foregroundStyle(DreeveTheme.accent)
                            Text("Post an activity")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("Choose a workout file from Files. Dreeve will queue the file and import it on its next processing run.")
                                .foregroundStyle(DreeveTheme.muted)
                            Button {
                                showImporter = true
                            } label: {
                                Label(uploading ? "Uploading…" : "Choose FIT / GPX / TCX", systemImage: "folder")
                                    .frame(maxWidth: .infinity)
                                    .padding(10)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DreeveTheme.accent)
                            .foregroundStyle(DreeveTheme.background)
                            .disabled(!session.canUpload || uploading)
                            if !session.canUpload {
                                Label("Uploads are disabled on this Dreeve instance. The server needs IMPORT_MODE=files.", systemImage: "lock")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if uploading { ProgressView() }
                            if let uploadMessage {
                                Label(uploadMessage, systemImage: "checkmark.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(DreeveTheme.accent)
                            }
                        }
                    }
                    HStack {
                        Text("Import history")
                            .font(.title3.bold())
                        Spacer()
                        Button {
                            Task { await refreshImports() }
                        } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loadingImports)
                    }
                    if loadingImports { ProgressView().frame(maxWidth: .infinity) }
                    if imports.isEmpty && !loadingImports {
                        EmptyMessage(title: "No recent imports", message: "Import a file to see its processing status.", symbol: "tray")
                    }
                    ForEach(imports.indices, id: \.self) { index in
                        let item = imports[index]
                        SurfaceCard {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: icon(for: item.status))
                                    .foregroundStyle(color(for: item.status))
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.filename)
                                        .font(.headline)
                                        .lineLimit(2)
                                    Text(item.status.capitalized)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(color(for: item.status))
                                    if let error = item.errorMessage, !error.isEmpty {
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(DreeveTheme.muted)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                    Text("A queued upload is not yet a published activity. Refresh the history to see whether it succeeded, was skipped or failed.")
                        .font(.caption)
                        .foregroundStyle(DreeveTheme.muted)
                }
                .padding(18)
            }
            .dreeveBackground()
            .navigationTitle("Upload")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: activityTypes) { result in
                switch result {
                case .success(let url):
                    Task {
                        uploading = true
                        uploadMessage = nil
                        defer { uploading = false }
                        do {
                            let receipt = try await session.uploadActivity(url)
                            uploadMessage = receipt.message
                            await refreshImports()
                            await session.reloadActivities()
                        } catch { errorMessage = error.localizedDescription }
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .task {
                _ = try? await session.testConnection()
                await refreshImports()
            }
            .refreshable { await refreshImports() }
            .alert("Import error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "Unknown error") }
        }
    }

    private func refreshImports() async {
        guard !loadingImports else { return }
        loadingImports = true
        defer { loadingImports = false }
        do { imports = try await session.imports() }
        catch { errorMessage = error.localizedDescription }
    }

    private func icon(for state: String) -> String {
        switch state {
        case "success": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "skipped": return "forward.circle.fill"
        default: return "clock.fill"
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "success": return DreeveTheme.accent
        case "failed": return .red
        case "skipped": return .orange
        default: return DreeveTheme.muted
        }
    }
}

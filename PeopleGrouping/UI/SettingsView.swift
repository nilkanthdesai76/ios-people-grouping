import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var stats = StoreStats(
        assetsScanned: 0, assetsFailed: 0, assetsInCloud: 0, assetsCloudFailed: 0,
        facesTotal: 0, facesAssigned: 0, peopleCount: 0, unassignedFaces: 0
    )
    @State private var stages = StageAverages(photos: 0, loadMs: 0, detectMs: 0, embedMs: 0, totalMs: 0)
    @State private var logs: [String] = []
    @State private var library: LibraryBreakdown?
    @State private var confirmRescan = false
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = appModel
        NavigationStack {
            Form {
                if appModel.embedderInfo.isFallback {
                    Section {
                        Label {
                            Text("Face model missing — using the Vision feature-print fallback. Matching quality is reduced.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.callout)
                    }
                }
                Section {
                    Toggle("Include iCloud photos", isOn: $model.includeICloud)
                    Toggle("Wi-Fi only", isOn: $model.wifiOnly)
                    Toggle("Quick iCloud scan", isOn: $model.quickICloud)
                } header: {
                    Text("iCloud Photos")
                } footer: {
                    Text("Quick iCloud scan checks the copy already on your iPhone first and only downloads photos whose faces are too small in it. Downloads are done by iOS at scan size (not full originals) with your own iCloud account. Nothing is uploaded.")
                }
                Section {
                    HStack {
                        Text("Match threshold")
                        @Bindable var model = appModel
                        Slider(
                            value: $model.matchThreshold,
                            in: Double(appModel.embedderInfo.thresholdRange.lowerBound)...Double(appModel.embedderInfo.thresholdRange.upperBound),
                            step: 0.01
                        )
                        .accessibilityLabel("Match threshold")
                        Text(String(format: "%.2f", appModel.matchThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Group merging")
                        @Bindable var model = appModel
                        Slider(value: $model.mergeThreshold, in: AppModel.mergeThresholdRange, step: 0.01)
                            .accessibilityLabel("Group merging")
                        Text(String(format: "%.2f", appModel.mergeThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Button("Re-cluster") {
                        appModel.recluster()
                    }
                    .disabled(appModel.progress.state == .running)
                } header: {
                    Text("Matching")
                } footer: {
                    Text("Match threshold forms small, strict groups. Group merging then joins groups that are the same person: raise it if one person is split into several groups, lower it if different people get mixed. Tap Re-cluster to apply; no rescan needed.")
                }
                Section("Data") {
                    Button("Retry iCloud failures") {
                        appModel.retryCloudFailures()
                    }
                    .disabled(appModel.progress.state == .running)
                    Button("Rescan all") { confirmRescan = true }
                        .disabled(appModel.progress.state == .running)
                    Button("Reset all data", role: .destructive) { confirmReset = true }
                        .disabled(appModel.progress.state == .running)
                }
                if let library {
                    Section {
                        LabeledContent("All items", value: "\(library.allItems)")
                        LabeledContent("Videos (not scanned)", value: "\(library.videos)")
                        LabeledContent("Photos", value: "\(library.photos)")
                        LabeledContent("Screenshots (not scanned)", value: "\(library.screenshots)")
                        LabeledContent("Hidden photos (not scanned)", value: "\(library.hiddenPhotos)")
                        LabeledContent("Extra burst frames (not scanned)", value: "\(library.extraBurstFrames)")
                        LabeledContent("Shared album photos (not scanned)", value: "\(library.sharedAlbumPhotos)")
                        LabeledContent("Scanned by this app", value: "\(library.scanned)")
                    } header: {
                        Text("Photo library")
                    } footer: {
                        Text(appModel.auth.isLimited
                             ? "Limited access: the app only sees the photos you selected. Allow full access in iOS Settings to scan everything."
                             : "Scanned = Photos minus screenshots. Videos, hidden photos, extra burst frames and shared albums are left out.")
                    }
                }
                Section("Diagnostics") {
                    LabeledContent("Embedder", value: appModel.embedderInfo.name)
                    LabeledContent("Photos scanned", value: "\(stats.assetsScanned)")
                    LabeledContent("Photos failed", value: "\(stats.assetsFailed)")
                    LabeledContent("In iCloud (pending)", value: "\(stats.assetsInCloud)")
                    LabeledContent("iCloud failed", value: "\(stats.assetsCloudFailed)")
                    LabeledContent("Faces stored", value: "\(stats.facesTotal)")
                    LabeledContent("Faces assigned", value: "\(stats.facesAssigned)")
                    LabeledContent("Unassigned faces", value: "\(stats.unassignedFaces)")
                    LabeledContent("People", value: "\(stats.peopleCount)")
                    if stages.photos > 0 {
                        LabeledContent("Avg load", value: String(format: "%.0f ms", stages.loadMs))
                        LabeledContent("Avg detect", value: String(format: "%.0f ms", stages.detectMs))
                        LabeledContent("Avg embed", value: String(format: "%.0f ms", stages.embedMs))
                        LabeledContent("Avg per photo", value: String(format: "%.0f ms", stages.totalMs))
                    }
                    LabeledContent("Thermal state", value: thermalDescription)
                    if !logs.isEmpty {
                        Text(logs.joined(separator: "\n"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Recent log lines")
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Rescan all photos from scratch?", isPresented: $confirmRescan, titleVisibility: .visible) {
                Button("Rescan all", role: .destructive) { appModel.rescanAll() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete all people, faces and scan data?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset all data", role: .destructive) { appModel.resetAll() }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                await refreshDiagnostics()
            }
            .refreshable {
                await refreshDiagnostics()
            }
        }
    }

    private var thermalDescription: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func refreshDiagnostics() async {
        async let storeStats = appModel.store.stats()
        async let stageStats = appModel.stageAverages()
        stats = await storeStats
        stages = await stageStats
        logs = AppLog.shared.recent()
        library = await Task.detached(priority: .utility) { PhotoLibraryService().libraryBreakdown() }.value
    }
}

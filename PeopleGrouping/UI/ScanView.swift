import SwiftUI

struct ScanView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                progressRing
                counts
                if progress.state == .waitingForNetwork {
                    Label(
                        appModel.wifiOnly ? "Waiting for Wi-Fi" : "Waiting for network",
                        systemImage: "icloud.and.arrow.down"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                controlButton
                if isThermallyThrottled {
                    Label("Device is hot: scanning is pausing to cool down.", systemImage: "thermometer.sun")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .navigationTitle("Scan")
        }
    }

    private var progress: ScanProgress { appModel.progress }

    private var fraction: Double {
        guard progress.total > 0 else { return 0 }
        return Double(progress.scanned) / Double(progress.total)
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.2), lineWidth: 12)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(fraction * 100))%")
                .font(.title2.bold())
        }
        .frame(width: 140, height: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scan progress: \(progress.scanned) of \(progress.total) photos")
    }

    private var counts: some View {
        VStack(spacing: 8) {
            Text("\(progress.scanned) / \(progress.total) photos scanned")
            Text("\(progress.facesFound) faces found")
            Text("\(progress.peopleCount) people")
            if progress.inCloudPending > 0 {
                Text("Waiting in iCloud: \(progress.inCloudPending)")
                    .foregroundStyle(.secondary)
            }
            if progress.downloading > 0 {
                Text("Downloading: \(progress.downloading)")
                    .foregroundStyle(.secondary)
            }
            if progress.downloadsSaved > 0 {
                Text("Downloads skipped: \(progress.downloadsSaved)")
                    .foregroundStyle(.secondary)
            }
            if progress.cloudFailed > 0 {
                Text("iCloud failed: \(progress.cloudFailed)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
    }

    private var controlButton: some View {
        Group {
            switch progress.state {
            case .running:
                Button("Pause", role: .destructive) { appModel.pauseScan() }
                    .buttonStyle(.borderedProminent)
            case .paused:
                Button("Resume") { appModel.resumeScan() }
                    .buttonStyle(.borderedProminent)
            case .waitingForNetwork:
                Button("Pause", role: .destructive) { appModel.pauseScan() }
                    .buttonStyle(.borderedProminent)
            default:
                Button(progress.state == .finished ? "Scan again" : "Start Scan") {
                    appModel.startScan()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var isThermallyThrottled: Bool {
        ProcessInfo.processInfo.thermalState == .serious
            || ProcessInfo.processInfo.thermalState == .critical
    }
}

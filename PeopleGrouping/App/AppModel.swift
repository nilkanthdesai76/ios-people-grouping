import Foundation
import SwiftUI

/// Root app state shared via SwiftUI environment.
@Observable
final class AppModel {
    let auth = PhotoAuthorization()
    let container = StoreConfiguration.makeContainer()
    let store: FaceStore
    let thumbs = ThumbnailCache()
    /// Cheap description of the embedder; the model itself loads in the background (see `loadEmbedder`).
    let embedderInfo = FaceEmbedderFactory.info()
    @ObservationIgnored private var embedderTask: Task<any FaceEmbedder, Never>?
    let networkMonitor = NetworkMonitor()

    var progress = ScanProgress.initial
    var people: [PersonSummary] = []

    private var coordinator: ScanCoordinator?
    private var scanTask: Task<Void, Never>?

    /// Match threshold, remembered separately for each embedder because their distance scales differ.
    var matchThreshold: Double {
        didSet { UserDefaults.standard.set(matchThreshold, forKey: thresholdKey) }
    }

    @ObservationIgnored private let thresholdKey: String

    /// Second-pass merge distance (average linkage). Higher = fewer, bigger groups.
    var mergeThreshold: Double {
        didSet { UserDefaults.standard.set(mergeThreshold, forKey: Self.mergeThresholdKey) }
    }

    static let mergeThresholdRange: ClosedRange<Double> = 0.45...0.85
    @ObservationIgnored private static let mergeThresholdKey = "mergeThreshold"

    /// Whether the scan should also download iCloud-only photos.
    var includeICloud: Bool {
        didSet { persistCloudPolicy() }
    }

    /// Download iCloud photos on Wi-Fi only.
    var wifiOnly: Bool {
        didSet { persistCloudPolicy() }
    }

    /// Use the on-device preview of iCloud photos and download only when it is not enough.
    var quickICloud: Bool {
        didSet { persistCloudPolicy() }
    }

    var cloudPolicy: CloudPolicy {
        CloudPolicy(includeICloud: includeICloud, wifiOnly: wifiOnly, previewFirst: quickICloud)
    }

    @ObservationIgnored private let quickICloudKey = "quickICloud"

    @ObservationIgnored private let includeICloudKey = "includeICloud"
    @ObservationIgnored private let wifiOnlyKey = "wifiOnly"

    private func persistCloudPolicy() {
        UserDefaults.standard.set(includeICloud, forKey: includeICloudKey)
        UserDefaults.standard.set(wifiOnly, forKey: wifiOnlyKey)
        UserDefaults.standard.set(quickICloud, forKey: quickICloudKey)
        Task { await coordinator?.setCloudPolicy(cloudPolicy) }
    }

    init() {
        store = FaceStore(modelContainer: container)
        let info = embedderInfo
        let key = "matchThreshold.\(info.name)"
        thresholdKey = key
        let saved = UserDefaults.standard.object(forKey: key) as? Double
        let range = Double(info.thresholdRange.lowerBound)...Double(info.thresholdRange.upperBound)
        matchThreshold = min(max(saved ?? Double(info.defaultThreshold), range.lowerBound), range.upperBound)
        let savedMerge = UserDefaults.standard.object(forKey: Self.mergeThresholdKey) as? Double ?? 0.65
        mergeThreshold = min(max(savedMerge, Self.mergeThresholdRange.lowerBound), Self.mergeThresholdRange.upperBound)
        includeICloud = UserDefaults.standard.object(forKey: includeICloudKey) as? Bool ?? true
        wifiOnly = UserDefaults.standard.object(forKey: wifiOnlyKey) as? Bool ?? true
        quickICloud = UserDefaults.standard.object(forKey: quickICloudKey) as? Bool ?? true
    }

    var scanState: ScanState { progress.state }
    var isScanning: Bool { scanTask != nil }

    func refreshPeople() async {
        people = await store.peopleSummaries()
    }

    /// Loads and warms the Core ML model once, off the main thread. Safe to call repeatedly.
    func loadEmbedder() async -> any FaceEmbedder {
        if let embedderTask { return await embedderTask.value }
        let task = Task.detached(priority: .userInitiated) { FaceEmbedderFactory.makeWarmed() }
        embedderTask = task
        return await task.value
    }

    /// Start preparing the model right after launch so Start Scan is instant.
    func prewarmModel() {
        Task { _ = await loadEmbedder() }
    }

    func startScan() {
        guard scanTask == nil else { return }
        scanTask = Task { [store] in
            let embedder = await loadEmbedder()
            let coordinator = ScanCoordinator(
                store: store,
                thumbs: thumbs,
                embedder: embedder,
                params: ClusterParams(threshold: Float(matchThreshold), mergeThreshold: Float(mergeThreshold)),
                policy: cloudPolicy,
                monitor: networkMonitor
            )
            self.coordinator = coordinator
            let stream = coordinator.start()
            for await tick in stream {
                progress = tick
                people = await store.peopleSummaries()
            }
            progress.state = .finished
            people = await store.peopleSummaries()
            scanTask = nil
        }
    }

    func pauseScan() {
        Task { await coordinator?.pause() }
    }

    func resumeScan() {
        Task { await coordinator?.resume() }
    }

    /// Re-group from stored embeddings (no photo reading). Works even when no scan ran this launch.
    func recluster() {
        Task {
            let coordinator: ScanCoordinator
            if let existing = self.coordinator {
                coordinator = existing
            } else {
                coordinator = ScanCoordinator(
                    store: store,
                    thumbs: thumbs,
                    embedder: await loadEmbedder(),
                    params: ClusterParams(threshold: Float(matchThreshold), mergeThreshold: Float(mergeThreshold)),
                    policy: cloudPolicy,
                    monitor: networkMonitor
                )
                self.coordinator = coordinator
            }
            await coordinator.recluster(threshold: Float(matchThreshold), mergeThreshold: Float(mergeThreshold))
            people = await store.peopleSummaries()
        }
    }

    /// Clear scan data (keeping named people) and start a fresh full scan.
    func rescanAll() {
        Task {
            await store.rescanReset()
            await thumbs.removeAll()
            UserDefaults.standard.set(false, forKey: ScanCoordinator.completedFlag)
            progress = .initial
            people = await store.peopleSummaries()
            startScan()
        }
    }

    /// Delete everything: people, faces, scan records, thumbnails.
    func resetAll() {
        Task {
            await store.resetAll()
            await thumbs.removeAll()
            UserDefaults.standard.removeObject(forKey: ScanCoordinator.completedFlag)
            progress = .initial
            people = []
        }
    }

    /// Make failed cloud downloads pending again and pick them up with a new scan pass.
    func retryCloudFailures() {
        Task {
            await store.resetCloudFailures()
            startScan()
        }
    }

    /// Cached face thumbnail, or rebuild it from the photo and the stored face box
    /// (used for faces whose thumbnail is missing or was made before the crop fix).
    func faceThumbnail(faceID: UUID) async -> UIImage? {
        if let url = await thumbs.url(forFaceID: faceID), let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        guard let info = await store.faceInfo(id: faceID) else { return nil }
        let jpeg: Data? = await Task.detached(priority: .utility) {
            guard case .image(let photo) = await PhotoLibraryService().loadScanImage(id: info.assetID, allowNetwork: true)
            else { return nil }
            let face = DetectedFace(
                box: info.box, quality: info.quality,
                leftEye: nil, rightEye: nil, landmarks: nil, passesGate: true
            )
            guard let crop = FaceCropper.crop(face: face, from: photo, size: 256, aligned: false) else { return nil }
            return ScanCoordinator.jpeg(from: crop, quality: 0.8)
        }.value
        guard let jpeg else { return nil }
        await thumbs.save(faceID: faceID, jpeg: jpeg)
        return UIImage(data: jpeg)
    }

    func stageAverages() async -> StageAverages {
        await coordinator?.stageAverages() ?? StageAverages(photos: 0, loadMs: 0, detectMs: 0, embedMs: 0, totalMs: 0)
    }

    /// After the first completed scan, later launches pick up where they left off.
    func autoResumeIfNeeded() {
        guard UserDefaults.standard.bool(forKey: ScanCoordinator.completedFlag) else { return }
        startScan()
    }
}

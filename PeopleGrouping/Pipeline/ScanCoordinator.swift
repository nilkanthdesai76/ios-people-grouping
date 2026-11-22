import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Drives the resumable scan: load -> detect -> embed -> persist -> cluster.
actor ScanCoordinator {
    private let photoService = PhotoLibraryService()
    private let store: FaceStore
    private let thumbs: ThumbnailCache
    private let embedder: any FaceEmbedder
    private let monitor: NetworkMonitor
    private var params: ClusterParams

    private var isPaused = false
    private var started = false
    private var policy = CloudPolicy(includeICloud: true, wifiOnly: true)
    private var continuation: AsyncStream<ScanProgress>.Continuation?
    private var progress = ScanProgress.initial
    private var facesSinceClustering = 0
    private var lastEmit = ContinuousClock.now

    private var photosTimed = 0
    private var loadMs = 0.0
    private var detectMs = 0.0
    private var embedMs = 0.0
    private var totalMs = 0.0

    init(
        store: FaceStore,
        thumbs: ThumbnailCache,
        embedder: any FaceEmbedder,
        params: ClusterParams,
        policy: CloudPolicy,
        monitor: NetworkMonitor
    ) {
        self.store = store
        self.thumbs = thumbs
        self.embedder = embedder
        self.params = params
        self.policy = policy
        self.monitor = monitor
    }

    nonisolated func start() -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            Task { await self.begin(continuation: continuation) }
        }
    }

    private func begin(continuation: AsyncStream<ScanProgress>.Continuation) async {
        if started {
            continuation.finish()
            return
        }
        started = true
        progress.state = .running
        self.continuation = continuation
        Task { await run() }
    }

    func pause() {
        isPaused = true
        progress.state = .paused
        emit(force: true)
    }

    func resume() {
        isPaused = false
        progress.state = .running
        emit(force: true)
    }

    func setCloudPolicy(_ policy: CloudPolicy) {
        self.policy = policy
    }

    /// Re-run clustering from stored embeddings after dropping unnamed persons.
    func recluster(threshold: Float, mergeThreshold: Float) async {
        params.threshold = threshold
        params.mergeThreshold = mergeThreshold
        await store.clearUnnamedAssignments()
        await clusterNow()
        progress.peopleCount = await store.peopleSummaries().count
        emit(force: true)
    }

    func stageAverages() -> StageAverages {
        StageAverages(
            photos: photosTimed,
            loadMs: photosTimed > 0 ? loadMs / Double(photosTimed) : 0,
            detectMs: photosTimed > 0 ? detectMs / Double(photosTimed) : 0,
            embedMs: photosTimed > 0 ? embedMs / Double(photosTimed) : 0,
            totalMs: photosTimed > 0 ? totalMs / Double(photosTimed) : 0
        )
    }

    // MARK: - Pipeline

    private func run() async {
        AppLog.shared.log("Scan started")
        let allIDs = photoService.fetchImageAssetIDs()
        let done = await store.scannedIDs()
        let cloudPending = await store.cloudPendingIDs()
        let pendingSet = Set(cloudPending)
        let remaining = allIDs.filter { !done.contains($0) && !pendingSet.contains($0) }
        progress.total = allIDs.count
        progress.scanned = allIDs.count - remaining.count - cloudPending.count
        progress.inCloudPending = cloudPending.count
        progress.peopleCount = await store.peopleSummaries().count
        emit(force: true)

        // Phase 1: local photos only, no network.
        await runPipeline(ids: remaining, allowNetwork: false, concurrency: Self.localConcurrency)
        // People appear before the (slower) download pass finishes.
        await clusterNow()

        // Phase 2: download iCloud-only photos at scan size.
        if policy.includeICloud {
            await runCloudPhase(ids: cloudPending)
        }

        await clusterNow()
        progress.state = .finished
        progress.peopleCount = await store.peopleSummaries().count
        AppLog.shared.log("Scan finished: \(progress.facesFound) faces, \(progress.peopleCount) people, \(progress.inCloudPending) still in iCloud")
        emit(force: true)
        UserDefaults.standard.set(true, forKey: ScanCoordinator.completedFlag)
        continuation?.finish()
    }

    /// Downloads pending cloud photos with a wide sliding window, honouring the network policy.
    private func runCloudPhase(ids: [String]) async {
        guard !ids.isEmpty else { return }
        AppLog.shared.log("Cloud pass: \(ids.count) iCloud photos, up to \(Self.cloudConcurrency) at once")
        await runPipeline(ids: ids, allowNetwork: true, concurrency: Self.cloudConcurrency)
        if progress.state == .waitingForNetwork {
            progress.state = .running
            emit(force: true)
        }
    }

    // MARK: - Concurrent pipeline

    /// Photos fetched at the same time. Loading is mostly waiting (disk or iCloud), so this is wide.
    private static let localConcurrency = 6
    private static let cloudConcurrency = 16
    /// Face detection + embedding run at most this many at a time (CPU / Neural Engine bound).
    private let computeGate = ConcurrencyGate(limit: max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 1)))

    /// Sliding window: a new photo starts the moment any in-flight one finishes (no batch barrier).
    /// Loading and analysis run off this actor, so a slow download never stalls the others.
    private func runPipeline(ids: [String], allowNetwork: Bool, concurrency: Int) async {
        guard !ids.isEmpty else { return }
        var queue = ArraySlice(ids)
        var inFlight = 0
        let service = photoService
        let embedder = self.embedder
        let gate = computeGate
        await withTaskGroup(of: PhotoResult.self) { group in
            while !queue.isEmpty || inFlight > 0 {
                while inFlight < concurrency, !queue.isEmpty {
                    if allowNetwork {
                        guard await waitForNetwork() else {
                            queue.removeAll()
                            break
                        }
                    }
                    await waitIfPaused()
                    await waitForCoolDown()
                    guard let id = queue.popFirst() else { break }
                    inFlight += 1
                    if allowNetwork {
                        progress.downloading += 1
                        emit()
                    }
                    let previewFirst = policy.previewFirst
                    group.addTask {
                        await Self.analyse(
                            id: id, allowNetwork: allowNetwork, previewFirst: previewFirst,
                            service: service, embedder: embedder, gate: gate
                        )
                    }
                }
                guard inFlight > 0, let result = await group.next() else { break }
                inFlight -= 1
                if allowNetwork { progress.downloading = max(0, progress.downloading - 1) }
                await handle(result)
                await clusterIfNeeded()
            }
        }
    }

    /// Blocks until downloads are allowed. False means the cloud phase should stop.
    private func waitForNetwork() async -> Bool {
        while !Task.isCancelled && policy.includeICloud {
            let allowed = await monitor.isCloudDownloadAllowed(wifiOnly: policy.wifiOnly)
            if allowed { break }
            if progress.state != .waitingForNetwork {
                progress.state = .waitingForNetwork
                emit(force: true)
            }
            await waitIfPaused()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if progress.state == .waitingForNetwork {
            progress.state = .running
            emit(force: true)
        }
        return policy.includeICloud && !Task.isCancelled
    }

    /// Load one photo, then detect, align, embed and thumbnail its faces. Touches no actor state.
    private nonisolated static func analyse(
        id: String,
        allowNetwork: Bool,
        previewFirst: Bool,
        service: PhotoLibraryService,
        embedder: any FaceEmbedder,
        gate: ConcurrencyGate
    ) async -> PhotoResult {
        let startedAt = ContinuousClock.now
        func failure(_ status: ScanStatus) -> PhotoResult {
            PhotoResult(
                assetID: id, status: status, detectedCount: 0,
                faces: [], thumbnails: [], fromCloud: allowNetwork
            )
        }
        // iCloud photo: look at the copy already on the device before downloading anything.
        if allowNetwork, previewFirst, let preview = await service.loadLocalPreview(id: id) {
            let loadTime = startedAt.duration(to: ContinuousClock.now).milliseconds
            await gate.acquire()
            let finished = finishFromPreview(
                preview, assetID: id, embedder: embedder, startedAt: startedAt, loadTime: loadTime
            )
            await gate.release()
            if let finished { return finished }
        }
        switch await service.loadScanImage(id: id, allowNetwork: allowNetwork) {
        case .inCloud:
            return failure(.inCloud)
        case .failed:
            return failure(allowNetwork ? .cloudFailed : .failed)
        case .image(let image):
            let loadTime = startedAt.duration(to: ContinuousClock.now).milliseconds
            await gate.acquire()
            let result = process(
                image: image, assetID: id, embedder: embedder,
                startedAt: startedAt, loadTime: loadTime, fromCloud: allowNetwork
            ) ?? failure(allowNetwork ? .cloudFailed : .failed)
            await gate.release()
            return result
        }
    }

    /// Decide from the on-device preview. Returns a result when no download is needed:
    /// - no face big enough to pass the size gate: the full image would not pass it either
    ///   (the gate is relative to the image), so the photo is done with no faces;
    /// - every usable face is already >= 100 px: embed straight from the preview.
    /// Returns nil when the photo has faces that are too small in the preview: download it.
    private nonisolated static func finishFromPreview(
        _ preview: CGImage,
        assetID: String,
        embedder: any FaceEmbedder,
        startedAt: ContinuousClock.Instant,
        loadTime: Double
    ) -> PhotoResult? {
        guard let detected = try? FaceDetector.detect(in: preview) else { return nil }
        let usable = detected.filter { FaceGate.passesSize($0, width: preview.width, height: preview.height) }
        if usable.isEmpty {
            var result = PhotoResult(
                assetID: assetID, status: .ok, detectedCount: detected.count,
                faces: [], thumbnails: [], fromCloud: true
            )
            result.savedDownload = true
            return result
        }
        let bigEnough = usable.allSatisfy {
            FaceGate.pixelSide($0, width: preview.width, height: preview.height) >= FaceGate.previewEmbedSide
        }
        guard bigEnough, var result = process(
            image: preview, assetID: assetID, embedder: embedder,
            startedAt: startedAt, loadTime: loadTime, fromCloud: true, detected: detected
        ) else { return nil }
        result.savedDownload = true
        return result
    }

    private nonisolated static func process(
        image: CGImage,
        assetID: String,
        embedder: any FaceEmbedder,
        startedAt: ContinuousClock.Instant,
        loadTime: Double,
        fromCloud: Bool,
        detected precomputed: [DetectedFace]? = nil
    ) -> PhotoResult? {
        do {
            let detectStart = ContinuousClock.now
            let detected = try precomputed ?? FaceDetector.detect(in: image)
            let detectTime = detectStart.duration(to: ContinuousClock.now).milliseconds

            var faces: [NewFace] = []
            var thumbnails: [FaceThumb] = []
            let embedStart = ContinuousClock.now
            for face in detected where face.passesGate {
                guard let crop = FaceCropper.crop(face: face, from: image) else { continue }
                let embedding = try embedder.embed(crop)
                let faceID = UUID()
                faces.append(NewFace(
                    id: faceID, box: face.box, quality: face.quality,
                    embedding: embedding, passesGate: true
                ))
                if let thumbCG = FaceCropper.crop(face: face, from: image, size: 256, aligned: false),
                   let jpeg = jpeg(from: thumbCG, quality: 0.8) {
                    thumbnails.append(FaceThumb(faceID: faceID, jpeg: jpeg))
                }
            }
            var result = PhotoResult(
                assetID: assetID, status: .ok, detectedCount: detected.count,
                faces: faces, thumbnails: thumbnails, fromCloud: fromCloud
            )
            result.timing = StageTiming(
                load: loadTime, detect: detectTime,
                embed: embedStart.duration(to: ContinuousClock.now).milliseconds,
                total: startedAt.duration(to: ContinuousClock.now).milliseconds
            )
            return result
        } catch {
            return nil
        }
    }

    private func handle(_ result: PhotoResult) async {
        if let timing = result.timing {
            recordTiming(load: timing.load, detect: timing.detect, embed: timing.embed, total: timing.total)
        }
        for thumb in result.thumbnails {
            await thumbs.save(faceID: thumb.faceID, jpeg: thumb.jpeg)
        }
        await store.save(assetID: result.assetID, status: result.status, faces: result.faces)
        switch result.status {
        case .ok:
            progress.scanned += 1
            if result.fromCloud {
                progress.inCloudPending = max(0, progress.inCloudPending - 1)
            }
        case .inCloud:
            progress.inCloudPending += 1
        case .cloudFailed:
            progress.scanned += 1
            progress.cloudFailed += 1
            progress.inCloudPending = max(0, progress.inCloudPending - 1)
        case .failed, .unavailable:
            progress.scanned += 1
        }
        if result.savedDownload { progress.downloadsSaved += 1 }
        progress.facesFound += result.detectedCount
        facesSinceClustering += result.faces.count
        emit()
    }

    // MARK: - Clustering

    private func clusterIfNeeded() async {
        guard facesSinceClustering >= 200 else { return }
        facesSinceClustering = 0
        await clusterNow()
    }

    private func clusterNow() async {
        let faces = await store.unassignedFaceVectors()
        let centroids = await store.allPersonCentroids()
        let result = FaceClusterer.cluster(faces: faces, centroids: centroids, params: params)
        guard !result.assignments.isEmpty || !result.newPersons.isEmpty || !result.merges.isEmpty else {
            await consolidate()
            return
        }
        AppLog.shared.log("Clustering: \(result.assignments.count) assigned, \(result.newPersons.count) new people, \(result.merges.count) merges")
        await store.applyAssignments(toExisting: result.assignments, newPersons: result.newPersons)
        for (source, target) in result.merges {
            await store.merge(from: source, into: target)
        }
        await consolidate()
        progress.peopleCount = await store.peopleSummaries().count
    }

    /// Second pass: merge groups that are the same person and attach leftover faces.
    private func consolidate() async {
        let sums = await store.personSums()
        let loose = await store.unassignedFaceVectors()
        let result = FaceClusterer.consolidate(persons: sums, loose: loose, mergeThreshold: params.mergeThreshold)
        guard !result.merges.isEmpty || !result.assignments.isEmpty else { return }
        AppLog.shared.log("Merging pass: \(result.merges.count) groups merged, \(result.assignments.count) loose faces attached")
        for (source, target) in result.merges {
            await store.merge(from: source, into: target)
        }
        await store.applyAssignments(toExisting: result.assignments, newPersons: [])
    }

    // MARK: - Helpers

    private func recordTiming(load: Double, detect: Double, embed: Double, total: Double) {
        photosTimed += 1
        loadMs += load
        detectMs += detect
        embedMs += embed
        totalMs += total
    }

    private func waitIfPaused() async {
        while isPaused {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func waitForCoolDown() async {
        while ProcessInfo.processInfo.thermalState == .serious
                || ProcessInfo.processInfo.thermalState == .critical {
            AppLog.shared.log("Thermal throttling: waiting to cool down")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func emit(force: Bool = false) {
        guard let continuation else { return }
        let now = ContinuousClock.now
        if force || progress.state != .running || now - lastEmit >= .milliseconds(100) {
            lastEmit = now
            continuation.yield(progress)
        }
    }

    static let completedFlag = "hasCompletedScan"

    static func jpeg(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

nonisolated extension Duration {
    var milliseconds: Double {
        Double(components.attoseconds) / 1e15 + Double(components.seconds) * 1000
    }
}

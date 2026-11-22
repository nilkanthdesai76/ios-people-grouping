# ARCHITECTURE.md

## 1. Directory structure (target state)
All new code goes under `PeopleGrouping/` (the synchronized folder). Existing: `MyApp.swift`, `ContentView.swift` (replace its body with the root view), `Assets.xcassets`.
```text
PeopleGrouping/
├── MyApp.swift                  # @main, builds AppModel, injects ModelContainer
├── App/
│   ├── AppModel.swift           # @Observable root state (permission, scan state, settings)
│   └── RootView.swift           # Permission gate -> TabView(People, Scan, Settings)
├── Photos/
│   ├── PhotoAuthorization.swift # PHPhotoLibrary status wrapper (read-only)
│   └── PhotoLibraryService.swift# nonisolated: fetch assets, load CGImage for scanning, thumbnails
├── Faces/
│   ├── DetectedFace.swift       # Sendable struct: normalized box, landmarks, quality, crop
│   ├── FaceDetector.swift       # Vision VNDetectFaceLandmarksRequest + capture quality
│   ├── FaceCropper.swift        # aligned 112x112 crop (CoreImage)
│   ├── FaceEmbedder.swift       # protocol: embed(CGImage) -> [Float] (L2-normalised)
│   ├── CoreMLFaceEmbedder.swift # loads FaceEmbedding.mlmodelc from the bundle at runtime
│   └── FeaturePrintEmbedder.swift # fallback (VNGenerateImageFeaturePrintRequest), low accuracy
├── Clustering/
│   ├── VectorMath.swift         # dot, cosineDistance, normalize (Accelerate vDSP)
│   └── FaceClusterer.swift      # pure functions: cluster([FaceVector]) -> assignments
├── Store/
│   ├── Models.swift             # SwiftData: ScannedAsset, FaceRecord, Person
│   ├── FaceStore.swift          # @ModelActor: all reads/writes off the main actor
│   └── ThumbnailCache.swift     # actor: face-crop JPEGs in Caches/FaceThumbs
├── Pipeline/
│   └── ScanCoordinator.swift    # actor: fetch -> detect -> crop -> embed -> store -> cluster, progress stream
├── UI/
│   ├── PeopleGridView.swift
│   ├── PersonDetailView.swift
│   ├── PhotoViewerView.swift
│   ├── ScanView.swift
│   ├── SettingsView.swift
│   ├── PermissionView.swift
│   └── Components/              # FaceAvatar, ProgressRing, EmptyState
└── ML/
    └── FaceEmbedding.mlpackage  # placed by the user, git-ignored
```

## 2. Data flow
```mermaid
flowchart TD
    PL[PhotoLibraryService<br/>PHAsset fetch] --> SC[ScanCoordinator actor]
    SC -->|CGImage 1024px| FD[FaceDetector<br/>Vision landmarks + quality]
    FD -->|boxes + landmarks| FC[FaceCropper 112x112]
    FC --> FE[FaceEmbedder<br/>Core ML 512-d]
    FE -->|Float vector| FS[(FaceStore SwiftData)]
    FC -->|JPEG| TC[ThumbnailCache]
    FS --> CL[FaceClusterer]
    CL -->|person assignments| FS
    FS -->|@Query| UI[SwiftUI People / Detail]
    SC -->|AsyncStream progress| AM[AppModel] --> UI
```

## 3. Data model (SwiftData)
- `ScannedAsset`: `localIdentifier: String` (unique), `scannedAt: Date`, `faceCount: Int`, `status` (ok / unavailable / failed).
- `FaceRecord`: `id: UUID`, `assetID: String`, `boxX, boxY, boxW, boxH: Double` (normalised, origin top-left), `quality: Float`, `embedding: Data` (512 x Float32), `personID: UUID?`, `isPinnedAway: Bool` (user removed it from a person), `rejectedPersonIDs: [UUID]`.
- `Person`: `id: UUID`, `name: String?`, `coverFaceID: UUID?`, `createdAt: Date`, `isHidden: Bool`.
Relationships are by ID (no SwiftData relationships) to keep `@ModelActor` batch writes simple and fast.

## 4. Clustering algorithm
Incremental and deterministic. It runs after each scan batch of ~200 faces and on "Re-cluster". People are described by their **members**, not by one average vector, so one person with many poses, lights and ages stays one person (an average vector splits them; this was the original bug).
1. Quality gate: faces with a shorter side under 60 px (at the 1024 px scan size) or capture quality under 0.25 are not embedded.
2. **Join existing people.** A loose face joins the person whose 3 nearest members are closest (mean cosine distance), if that is <= `threshold`. People are represented by up to 40 spread members; people the user removed the face from (`rejectedPersonIDs`) are skipped.
3. **New people with DBSCAN** (min 3 faces, `eps = threshold`) over the faces that joined nobody. Density chaining links a person's pose variations through their close neighbours.
4. **Merge people** when at least 3 members of each (fewer for tiny people) have a neighbour in the other within `threshold * 0.9`. Two named people never merge; a named person is kept over an unnamed one.
5. **Second pass (Apple Photos style, `FaceClusterer.consolidate`).** Pass 1 is strict on purpose and leaves one person split over several groups (glasses, lighting, angle, age). Average-linkage hierarchical clustering over whole groups (exact, from summed vectors: mean pairwise similarity = dot(sumA, sumB) / (nA nB)) merges groups whose faces are on average within `mergeThreshold` (default 0.65, Settings "Group merging"); two named people never merge. Leftover single faces then join the person they are on average closest to. Mirrors Apple's published design: conservative first pass, then HAC across groups for recall (https://machinelearning.apple.com/research/recognizing-people-photos). On synthetic data with 3 distinct looks per person, pass 1 alone gives 36 groups for 12 people; with the second pass, 12.
6. Embeddings average the face and its mirror image (ArcFace "flip test").
7. Cover face = the clearest face (capture quality, then size).
`Re-cluster` clears unnamed assignments and re-runs from stored embeddings (no photo re-reading). Heavy work uses `vDSP_mmul` matrix multiplies in chunks. On synthetic data (12 to 300 people, 20k faces) it finds every person with no splits, the old centroid method split people into 2-3 groups each; default threshold 0.40 (Core ML mode). Real accuracy still has to be checked on a device and the slider tuned.

## 4b. Face alignment
The embedding model expects the InsightFace 112 x 112 template. `FaceCropper` warps each face with a least-squares similarity transform from four Vision landmarks (both pupils, both mouth corners) onto the template points; with only two eyes it uses those. Without landmarks it falls back to a looser upright crop. Thumbnails use the loose crop. **Changing alignment changes embeddings, so existing scans must be reset ("Reset all data", then scan).**

## 5. Module boundaries
- `Clustering/` and `Faces/` import no SwiftUI and no SwiftData. Pure Swift + Vision/CoreML/CoreImage/Accelerate.
- `Store/` is the only place that touches `ModelContext`.
- `UI/` reads through `@Query` or `AppModel`; never calls Vision, Core ML or PhotoKit directly. Image loading for display goes through `PhotoLibraryService`.
- `Pipeline/ScanCoordinator` is the only orchestrator; UI starts/pauses it via `AppModel`.

## 6. Model choice
- **Detection**: Apple Vision, no model file.
- **Embedding**: an ArcFace-class 512-d Core ML model named `FaceEmbedding`, input 112x112 RGB face crop. Recommended ready-made: the **AuraFace-v1 Core ML** conversions on Hugging Face (ResNet100, 512-d, about 124 MB fp16), see https://huggingface.co/RuiSumida/AuraFace-v1-CoreML. Check the model licence before any distribution; this demo is local only. A smaller alternative is MobileFaceNet (128-d, about 4 MB) converted with coremltools.
- The embedder reads input/output names, image size and output dimension from `MLModel.modelDescription` at runtime, so any compatible model works without code changes. Thresholds scale with the model; Immich uses 0.5 for ArcFace with a different clusterer, this app defaults to 0.40.
- Fallback embedder (`VNGenerateImageFeaturePrintRequest` on the crop) exists only so the app runs before the model is placed. It is not identity-aware and the UI must show a warning banner when it is active.

## 7. iCloud photos (US-09)
With iCloud Photos + "Optimize iPhone Storage" the device holds only small derivatives; originals live in iCloud. PhotoKit can deliver a derivative at the requested size, so we never download originals.
- **Two-phase scan** in `ScanCoordinator`: (1) local pass over every not-yet-scanned asset with `isNetworkAccessAllowed = false`; assets that come back in-cloud are saved as `ScanStatus.inCloud` and counted as pending. (2) cloud pass over `inCloud` (and `cloudFailed`) assets with `isNetworkAccessAllowed = true`, 1024 px, 90 s timeout per photo, only while `CloudPolicy` allows it. Both phases use one **sliding-window pipeline** (`runPipeline`): up to 16 cloud downloads (6 local loads) in flight, a new one starts the moment any finishes (no batch barrier), loading and analysis run off the coordinator actor, and detection + embedding are limited by a `ConcurrencyGate` to min(4, cores - 1) at a time.
- **Statuses** (`ScanStatus`): `ok`, `failed` (permanent, e.g. no decodable image), `inCloud` (pending download), `cloudFailed` (download error or timeout, retried next scan). Legacy `unavailable` rows are treated as `inCloud`. `scannedIDs()` returns only `ok` and `failed`.
- **Policy**: `CloudPolicy { includeICloud: Bool, wifiOnly: Bool }` (Settings, both default true). `NetworkMonitor` (`NWPathMonitor` wrapper, no traffic) reports whether a path is satisfied, is Wi-Fi, and is constrained (Low Data Mode). When not allowed the cloud pass waits (poll every 2 s) and progress state shows "Waiting for Wi-Fi".
- **Robust PhotoKit requests**: one resume per request guarded by a lock; resume on a final image, `PHImageErrorKey`, `PHImageCancelledKey`, or timeout (timeout cancels the request via `PHImageManager.cancelImageRequest`). Never leave a continuation unresumed.
- **Fetch scope**: `PHFetchOptions.includeAssetSourceTypes = [.typeUserLibrary]` (the iCloud Photos library is the user library; shared albums are out of scope).

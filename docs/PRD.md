# PRD.md — PeopleGrouping

## 1. Problem statement
Apple Photos, Google Photos and Immich automatically group a library by the people in it. The owner wants a **working demo** of that whole pipeline on iPhone: fetch photos, find faces, compute face identity vectors, match them, cluster them into people, and browse them. Everything runs on-device.

## 2. Persona
- **Primary**: the developer/owner evaluating how people grouping works, running the demo on their own iPhone with their own library.
- **Core need**: see real grouping results on a real library, understand each pipeline stage, and tune matching.

## 3. How the competitors do it (design reference)
| Stage | Apple Photos / Google | Immich | This demo |
| --- | --- | --- | --- |
| Detect faces | on-device model | RetinaFace | Apple Vision (`VNDetectFaceLandmarksRequest`) |
| Align + crop | yes | 112x112 aligned | 112x112 crop with margin |
| Embed | private model | ArcFace 512-d | Core ML ArcFace-class model, 512-d (L2-normalised) |
| Cluster | private | DBSCAN, cosine dist 0.5, min 3 | Incremental member-based clustering + DBSCAN, cosine dist threshold (default 0.40), min 3 faces to form a Person |
| Naming | user names | user names | user names, merge, remove face |

Apple's public iOS 27 SDK exposes no face-identity vectors (Vision only detects faces and landmarks; a "Media Intelligence" framework reportedly groups faces but returns IDs without vectors, unverified). So a bundled Core ML embedding model is required for real matching.

## 4. Scope
**In**: Photos permission, library scan, face detection, embedding, clustering, persistence, People grid, person detail, rename, merge, remove face, scan progress, resumable and incremental scan, settings (threshold, rescan, reset).
**Out**: cloud sync, sharing, face search by uploading a selfie, pets, video faces, editing or deleting photos, other platforms (the app is iOS only: no macOS, Catalyst, visionOS, watchOS), custom iPad layouts, unit tests.

## 5. User stories and acceptance criteria
- **US-01 Permission.** As a user I grant Photos access once so the app can read my library.
  - AC: Clear explanation screen before the system prompt; denied and limited states handled with a Settings button; the app never writes to the library.
- **US-02 Scan.** As a user I tap Start and the app scans all photos for faces.
  - AC: Live progress (scanned / total, faces found, people found); works in the background of the UI without freezing; can be paused and resumed; killing the app and relaunching resumes where it stopped; already-scanned photos are skipped; new photos added later are picked up on next launch or pull-to-refresh.
- **US-03 People grid.** As a user I see a grid of people, biggest group first.
  - AC: Circular face cover, name (or "Unnamed"), photo count; groups with fewer than 3 faces are hidden under "Other faces" count; empty state before first scan.
- **US-04 Person detail.** As a user I open a person to see every photo they appear in.
  - AC: Photo grid sorted newest first, tap opens a full-screen photo with a face-box overlay; loads smoothly with thumbnails.
- **US-05 Name a person.** AC: Rename inline; name persists across launches.
- **US-06 Fix mistakes.** AC: Merge two people (select in grid); remove a wrong face from a person (it becomes unassigned and is never auto-reassigned to that person).
- **US-07 Tune.** AC: Settings has match-threshold slider (0.30–0.70) with a "Re-cluster" button that re-groups from stored embeddings without re-scanning photos.
- **US-08 Privacy.** AC: the app's own code never opens a network connection (no URLSession, no sockets, no third-party SDKs). Photos already on the device are scanned fully offline; airplane-mode runs work identically for them.
- **US-09 iCloud photos.** As a user with iCloud Photos and "Optimize iPhone Storage", photos that live only in iCloud are scanned too.
  - AC: Local photos are scanned first, then cloud-only photos are fetched through PhotoKit at scan size only (about 1024 px, never the full original) and scanned; Settings has "Include iCloud photos" (default on) and "Wi-Fi only" (default on, also honours Low Data Mode); with no allowed network the cloud pass waits and the UI says so, the scan never hangs; each cloud download has a 90 s timeout and a failed one is retried on the next scan; the Scan tab shows counts for scanned, waiting in iCloud, downloading and failed; grids and the viewer can open cloud photos and show a placeholder while downloading.

## 6. Non-functional requirements
- **Performance target** (iPhone 15 Pro class): scan >= 4 photos/sec; library of 20,000 photos completes in < 90 min in foreground; memory < 400 MB peak while scanning; UI stays at 60 fps.
- **Storage**: embeddings 2 KB per face (512 float32); face thumbnails 112 px JPEG cached on disk.
- **Battery/thermal**: scanning concurrency capped at 2; stops when thermal state is `.serious` or worse.
- **Privacy**: zero analytics, no app-level networking. iCloud downloads are performed by PhotoKit/iOS itself with the user's own iCloud account; the app never sees credentials and never uploads anything.
- **Reliability**: one bad photo (iCloud-only, corrupt) is logged and skipped, never aborts the scan.

## 7. Risks
| Risk | Mitigation |
| --- | --- |
| Face model not yet in the project | `FaceEmbedder` protocol; fallback embedder lets the app build and run, and the UI shows a "Demo fallback: low accuracy" banner |
| iCloud-optimised library (photos not on device) | Two-phase scan: local first, then cloud-only photos via PhotoKit at 1024 px with timeout, Wi-Fi-only policy and retry (US-09) |
| Clustering quality | Quality filter (face size, Vision capture quality), threshold tuning in Settings |
| Simulator has no realistic photo library | Build checks plus on-device testing and built-in diagnostics |

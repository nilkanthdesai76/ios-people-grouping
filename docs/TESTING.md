# Testing

## 1. Approach
This is a demo app without a unit test target. Correctness is checked in three ways:

1. **Build check** with zero errors and zero warnings:
   ```bash
   xcodebuild build -project PeopleGrouping.xcodeproj -scheme PeopleGrouping -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
   ```
2. **On-device runs** against a real photo library (the simulator has no realistic library).
3. **Built-in diagnostics** in Settings (see below).

The face alignment, the clustering passes and the concurrency gate were also exercised offline with synthetic data during development (aligned landmarks land within 1 px of the template; 12 synthetic people with 3 distinct "looks" each regroup into exactly 12 people).

## 2. Built-in diagnostics
Settings shows the embedder in use (Core ML model or fallback), photos scanned and failed, faces stored / assigned / unassigned, people count, average milliseconds per stage (load, detect, embed), thermal state, a breakdown of the photo library (videos, screenshots, hidden photos, burst frames and shared albums are not scanned) and the last log lines. Logs use `os.Logger` with subsystem `PeopleGrouping`.

## 3. Device checklist
1. Run on an iPhone, grant Photos access, tap Start Scan.
2. Progress moves; people appear while scanning.
3. Open the biggest person; spot-check that the photos are the same person.
4. Rename, merge two people, remove a wrong face, kill the app, relaunch: state persists and the scan resumes.
5. Settings: move the sliders, tap Re-cluster, grouping changes.
6. With iCloud Photos and "Optimize iPhone Storage": "Downloads skipped" and "Downloading" counts move.
7. Airplane mode: on-device photos still scan.

## 4. Test data
Never commit real photos, face crops or embeddings. The repository contains no fixtures.

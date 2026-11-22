# SECURITY.md

Face data is biometric and the most sensitive data a photo app can hold.

## 1. Privacy invariants
- 100% on-device processing. No `URLSession`, no sockets, no third-party SDKs, no analytics, no crash reporters. The only network activity is PhotoKit downloading the user's own iCloud photos (at scan size) on the app's behalf, controlled by the "Include iCloud photos" and "Wi-Fi only" settings. Observing connectivity with `NWPathMonitor` (Network framework) is allowed because it sends no traffic.
- Read-only Photos access. Never call `PHAssetChangeRequest`, `PHPhotoLibrary.performChanges`, or any delete/edit API.
- Embeddings and face thumbnails live only in the app sandbox (SwiftData store in Application Support, thumbnails in Caches). Set `isExcludedFromBackup = true` on the Application Support store directory.
- "Reset all data" in Settings deletes the SwiftData store, thumbnails and scan state.
- Do not log face embeddings, names, or photo identifiers above `.debug` level; never log to files.

## 2. Info.plist
Photos usage string is set through the build setting in `project.xcproj` target `build-settings`:
`"INFOPLIST_KEY_NSPhotoLibraryUsageDescription": "PeopleGrouping reads your photos on this device to group them by person. Nothing leaves your phone."`
No other privacy keys. No camera, location or network entitlement is added.

## 3. Secrets
No keys, tokens or server URLs exist in this project. Do not add any. `.env*`, certificates and provisioning profiles are git-ignored.

## 4. Repo hygiene
- Never commit photos, face crops, embeddings, or the face model file (`PeopleGrouping/ML/FaceEmbedding.*`, git-ignored).
- Pre-commit secret scan:
```bash
git grep -nE "(ghp_[a-zA-Z0-9]{36}|sk-[a-zA-Z0-9]{32,}|AKIA[0-9A-Z]{16})" || echo "No secrets found"
```

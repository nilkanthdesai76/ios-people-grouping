# CODE_STYLE.md

## 1. Naming
Types PascalCase, members camelCase, one primary type per file named after the file. Protocols are nouns (`FaceEmbedder`), implementations are prefixed (`CoreMLFaceEmbedder`).

## 2. Formatting
4 spaces, max 120 columns, trailing commas in multi-line collections, no linter. `// MARK:` only in files over 150 lines. Comments explain why, not what; no comment banners.

## 3. Concurrency (the most important section for this project)
The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so **every type is implicitly `@MainActor`**. Therefore:
- Pure/background types (`FaceDetector`, `FaceCropper`, `FaceClusterer`, `VectorMath`, `PhotoLibraryService`, models in `Faces/`) must be declared `nonisolated` (for structs/enums/classes) or be an `actor`. Without it, calling them from `ScanCoordinator` fails with isolation errors.
- Value types crossing actors conform to `Sendable`. `CGImage` is not Sendable in all SDKs; wrap with `nonisolated(unsafe)` only if the compiler demands it and never share a mutable image.
- SwiftData `@Model` classes are never passed between actors. Pass `PersistentIdentifier` or plain `Sendable` structs. All writes go through `FaceStore` (`@ModelActor`).
- UI state lives in an `@Observable` `AppModel` (MainActor). Progress comes in via `AsyncStream`, consumed in a `Task` on the MainActor.
- No `DispatchQueue`, no completion handlers in new code; wrap PhotoKit callbacks with `withCheckedContinuation`.
- Explicitly `import Combine` only if you use `@Published`/`@AppStorage`-style APIs (member import visibility is enabled). Prefer `@Observable` and `@AppStorage` via SwiftUI import.

## 4. Idioms
- Value types by default. Typed error enums (`enum ScanError: Error`). No force unwrap/`try!`/`fatalError` in production paths.
- `guard` early exits. Small functions (< 40 lines). No premature abstraction: one protocol only (`FaceEmbedder`).
- Use SwiftUI modern APIs for the iOS 27 SDK; no `NavigationView`, no `ObservableObject` for new code.
- Memory: wrap per-photo work in `autoreleasepool`-style scopes (`withExtendedLifetime` is not needed); release images before the next photo; never hold more than 2 full-size images at once.

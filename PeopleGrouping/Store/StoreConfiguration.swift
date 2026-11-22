import Foundation
import SwiftData

nonisolated enum StoreConfiguration {
    /// Store in Application Support, excluded from iCloud/iTunes backup.
    static func makeContainer() -> ModelContainer {
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PeopleGrouping.store", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        let schema = Schema([ScannedAsset.self, FaceRecord.self, Person.self])
        let configuration = ModelConfiguration(schema: schema, url: directory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Fall back to the default location so the app still launches.
            if let container = try? ModelContainer(for: schema) {
                return container
            }
            preconditionFailure("Unable to create the SwiftData store")
        }
    }
}

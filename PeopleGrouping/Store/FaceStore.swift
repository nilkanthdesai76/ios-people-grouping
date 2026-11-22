import Foundation
import SwiftData

/// All persistence goes through this actor; @Model objects never leave it.
@ModelActor
actor FaceStore {
    private var context: ModelContext { modelExecutor.modelContext }

    // MARK: - Scan bookkeeping

    /// Only truly finished ids: cloud-pending ones are retried by later scans.
    func scannedIDs() -> Set<String> {
        let descriptor = FetchDescriptor<ScannedAsset>()
        guard let assets = try? context.fetch(descriptor) else { return [] }
        return Set(assets
            .filter { $0.status == .ok || $0.status == .failed }
            .map(\.localIdentifier))
    }

    /// Ids that still need a network download pass.
    func cloudPendingIDs() -> [String] {
        let descriptor = FetchDescriptor<ScannedAsset>()
        guard let assets = try? context.fetch(descriptor) else { return [] }
        return assets
            .filter {
                $0.status == .inCloud
                    || $0.status == .cloudFailed
                    || $0.status == .unavailable
            }
            .map(\.localIdentifier)
    }

    func save(assetID: String, status: ScanStatus, faces: [NewFace]) {
        let descriptor = FetchDescriptor<ScannedAsset>(
            predicate: #Predicate { $0.localIdentifier == assetID }
        )
        let asset = (try? context.fetch(descriptor))?.first
        if let asset {
            asset.scannedAt = Date()
            asset.faceCount = faces.count
            asset.status = status
        } else {
            context.insert(ScannedAsset(localIdentifier: assetID, faceCount: faces.count, status: status))
        }
        for face in faces where face.passesGate {
            context.insert(FaceRecord(
                id: face.id,
                assetID: assetID,
                box: face.box,
                quality: face.quality,
                embedding: face.embedding.floatData
            ))
        }
        try? context.save()
    }

    // MARK: - Clustering inputs / outputs

    func unassignedFaceVectors() -> [FaceVector] {
        let descriptor = FetchDescriptor<FaceRecord>(
            predicate: #Predicate { $0.personID == nil && $0.isPinnedAway == false }
        )
        guard let records = try? context.fetch(descriptor) else { return [] }
        return records.map {
            FaceVector(faceID: $0.id, vector: $0.vector(), rejectedPersonIDs: $0.rejectedPersonIDs)
        }
    }

    /// Summed face vectors per visible person, for the average-linkage second pass.
    func personSums() -> [PersonSum] {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let visible = Dictionary(uniqueKeysWithValues: people.filter { !$0.isHidden }.map { ($0.id, $0.name != nil) })
        let faces = (try? context.fetch(FetchDescriptor<FaceRecord>())) ?? []
        var sums: [UUID: PersonSum] = [:]
        for face in faces {
            guard let personID = face.personID, let isNamed = visible[personID] else { continue }
            let vector = face.vector()
            if var entry = sums[personID], entry.sum.count == vector.count {
                for index in vector.indices { entry.sum[index] += vector[index] }
                entry.count += 1
                sums[personID] = entry
            } else if sums[personID] == nil {
                sums[personID] = PersonSum(id: personID, sum: vector, count: 1, isNamed: isNamed)
            }
        }
        return Array(sums.values)
    }

    func allPersonCentroids() -> [Centroid] {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let faces = (try? context.fetch(FetchDescriptor<FaceRecord>())) ?? []
        var grouped: [UUID: [[Float]]] = [:]
        for face in faces {
            guard let personID = face.personID else { continue }
            grouped[personID, default: []].append(face.vector())
        }
        return people.filter { !$0.isHidden }.compactMap { person in
            guard let vectors = grouped[person.id], !vectors.isEmpty else { return nil }
            let cap = 40
            let stride = max(1, vectors.count / cap)
            let sample = Swift.stride(from: 0, to: vectors.count, by: stride).prefix(cap).map { vectors[$0] }
            return Centroid(
                id: person.id,
                vector: VectorMath.normalize(VectorMath.mean(vectors)),
                count: vectors.count,
                members: sample,
                isNamed: person.name != nil
            )
        }
    }

    /// Assign faces to existing persons and create new persons for grouped faces.
    func applyAssignments(
        toExisting assignments: [UUID: UUID],
        newPersons: [NewPersonFaces]
    ) {
        let faceIDs = assignments.keys
        guard !faceIDs.isEmpty || !newPersons.isEmpty else { return }
        let descriptor = FetchDescriptor<FaceRecord>()
        guard let records = try? context.fetch(descriptor) else { return }
        var byID: [UUID: FaceRecord] = [:]
        for record in records { byID[record.id] = record }

        for (faceID, personID) in assignments {
            guard let record = byID[faceID],
                  personExists(personID) else { continue }
            record.personID = personID
        }
        for group in newPersons where !group.faceIDs.isEmpty {
            let person = Person(coverFaceID: group.faceIDs[0])
            context.insert(person)
            for faceID in group.faceIDs {
                byID[faceID]?.personID = person.id
            }
        }
        try? context.save()
    }

    // MARK: - Queries for the UI

    func peopleSummaries() -> [PersonSummary] {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let faces = (try? context.fetch(FetchDescriptor<FaceRecord>())) ?? []
        // Cover = the clearest face: highest capture quality, then the biggest box.
        var counts: [UUID: (count: Int, best: UUID?, score: Double)] = [:]
        for face in faces {
            guard let personID = face.personID else { continue }
            var current = counts[personID] ?? (0, nil, -1)
            current.count += 1
            let score = Double(face.quality) + min(face.boxW * face.boxH, 0.25)
            if score > current.score {
                current.best = face.id
                current.score = score
            }
            counts[personID] = current
        }
        return people
            .filter { !$0.isHidden }
            .map { person in
                PersonSummary(
                    id: person.id,
                    name: person.name,
                    faceCount: counts[person.id]?.count ?? 0,
                    coverFaceID: counts[person.id]?.best ?? person.coverFaceID
                )
            }
            .filter { $0.faceCount > 0 }
            // Named people first, then the biggest groups.
            .sorted {
                if ($0.name != nil) != ($1.name != nil) { return $0.name != nil }
                return $0.faceCount > $1.faceCount
            }
    }

    func assetIDs(forPerson personID: UUID) -> [String] {
        let descriptor = FetchDescriptor<FaceRecord>(
            predicate: #Predicate { $0.personID == personID }
        )
        guard let records = try? context.fetch(descriptor) else { return [] }
        var seen = Set<String>()
        var ids: [String] = []
        for record in records where seen.insert(record.assetID).inserted {
            ids.append(record.assetID)
        }
        return ids
    }

    /// One face, for regenerating its thumbnail.
    func faceInfo(id: UUID) -> FaceInfo? {
        let descriptor = FetchDescriptor<FaceRecord>(predicate: #Predicate { $0.id == id })
        guard let record = (try? context.fetch(descriptor))?.first else { return nil }
        return FaceInfo(
            id: record.id, assetID: record.assetID, box: record.box,
            quality: record.quality, personID: record.personID, personName: nil
        )
    }

    func faces(inAsset assetID: String) -> [FaceInfo] {
        let descriptor = FetchDescriptor<FaceRecord>(
            predicate: #Predicate { $0.assetID == assetID }
        )
        guard let records = try? context.fetch(descriptor) else { return [] }
        let names = personNames()
        return records.map {
            FaceInfo(
                id: $0.id,
                assetID: $0.assetID,
                box: $0.box,
                quality: $0.quality,
                personID: $0.personID,
                personName: $0.personID.flatMap { names[$0] }
            )
        }
    }

    // MARK: - User actions

    func rename(person id: UUID, name: String) {
        guard let person = person(id) else { return }
        person.name = name
        try? context.save()
    }

    func merge(from sourceID: UUID, into targetID: UUID) {
        let descriptor = FetchDescriptor<FaceRecord>(
            predicate: #Predicate { $0.personID == sourceID }
        )
        let faces = (try? context.fetch(descriptor)) ?? []
        for face in faces { face.personID = targetID }
        if let source = person(sourceID) {
            context.delete(source)
        }
        try? context.save()
    }

    func removeFace(_ faceID: UUID, fromPerson personID: UUID) {
        let descriptor = FetchDescriptor<FaceRecord>(
            predicate: #Predicate { $0.id == faceID }
        )
        guard let face = (try? context.fetch(descriptor))?.first else { return }
        face.personID = nil
        face.isPinnedAway = true
        if !face.rejectedPersonIDs.contains(personID) {
            face.rejectedPersonIDs.append(personID)
        }
        try? context.save()
    }

    func hide(person id: UUID) {
        guard let person = person(id) else { return }
        person.isHidden = true
        try? context.save()
    }

    func resetAll() {
        try? context.delete(model: ScannedAsset.self)
        try? context.delete(model: FaceRecord.self)
        try? context.delete(model: Person.self)
        try? context.save()
    }

    /// Re-clustering support: detach faces from unnamed persons, drop empty unnamed persons.
    func clearUnnamedAssignments() {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let unnamedIDs = Set(people.filter { $0.name == nil }.map(\.id))
        guard !unnamedIDs.isEmpty else { return }
        let faces = (try? context.fetch(FetchDescriptor<FaceRecord>())) ?? []
        for face in faces {
            if let personID = face.personID, unnamedIDs.contains(personID) {
                face.personID = nil
            }
        }
        for person in people where unnamedIDs.contains(person.id) {
            context.delete(person)
        }
        try? context.save()
    }

    /// Rescan-all support: drop scan records and faces, keep named persons as anchors.
    func rescanReset() {
        try? context.delete(model: ScannedAsset.self)
        try? context.delete(model: FaceRecord.self)
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        for person in people where person.name == nil {
            context.delete(person)
        }
        try? context.save()
    }

    /// Cloud-phase failures can be retried on demand; they become pending again.
    func resetCloudFailures() {
        let assets = (try? context.fetch(FetchDescriptor<ScannedAsset>())) ?? []
        let failed = assets.filter { $0.status == .cloudFailed }
        guard !failed.isEmpty else { return }
        for asset in failed {
            asset.status = .inCloud
        }
        try? context.save()
    }

    func stats() -> StoreStats {
        let assets = (try? context.fetch(FetchDescriptor<ScannedAsset>())) ?? []
        let faces = (try? context.fetch(FetchDescriptor<FaceRecord>())) ?? []
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        return StoreStats(
            assetsScanned: assets.filter { $0.status == .ok }.count,
            assetsFailed: assets.filter { $0.status == .failed }.count,
            assetsInCloud: assets.filter { $0.status == .inCloud || $0.status == .unavailable }.count,
            assetsCloudFailed: assets.filter { $0.status == .cloudFailed }.count,
            facesTotal: faces.count,
            facesAssigned: faces.filter { $0.personID != nil }.count,
            peopleCount: people.filter { !$0.isHidden }.count,
            unassignedFaces: faces.filter { $0.personID == nil && !$0.isPinnedAway }.count
        )
    }

    // MARK: - Private helpers

    private func person(_ id: UUID) -> Person? {
        let descriptor = FetchDescriptor<Person>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    private func personExists(_ id: UUID) -> Bool {
        person(id) != nil
    }

    private func personNames() -> [UUID: String] {
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        var names: [UUID: String] = [:]
        for person in people {
            names[person.id] = person.name ?? "Unnamed"
        }
        return names
    }
}

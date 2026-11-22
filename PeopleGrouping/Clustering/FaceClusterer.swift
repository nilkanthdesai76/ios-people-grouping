import Accelerate
import Foundation

nonisolated struct ClusterParams: Sendable {
    /// Cosine distance under which two faces count as the same person.
    var threshold: Float = 0.4
    /// Minimum faces for a new person (DBSCAN min points, like Immich).
    var minFaces: Int = 3
    /// Two persons merge when enough members of both are neighbours within `threshold * mergeFactor`.
    var mergeFactor: Float = 0.9
    /// Nearest members averaged when matching a face to a person.
    var neighbours: Int = 3
    /// Second pass (average linkage across whole groups): two people whose faces are, on
    /// average, within this cosine distance are the same person. Looser than `threshold`
    /// because it averages over many faces, so single odd photos cannot chain people together.
    var mergeThreshold: Float = 0.65
    /// Members of each side that must have a close neighbour in the other person before they merge.
    var mergeSupport: Int = 3
}

/// A person's face vectors summed (not normalised) plus the count: enough for exact
/// average-linkage similarity, since mean pairwise dot(A, B) = dot(sumA, sumB) / (nA * nB).
nonisolated struct PersonSum: Sendable {
    var id: UUID
    var sum: [Float]
    var count: Int
    var isNamed: Bool
}

nonisolated struct ConsolidationResult: Sendable {
    /// source personID -> target personID.
    var merges: [UUID: UUID]
    /// loose faceID -> personID.
    var assignments: [UUID: UUID]
}

nonisolated struct ClusterResult: Sendable {
    /// faceID -> existing personID.
    var assignments: [UUID: UUID]
    /// Groups of unassigned faces that form brand-new persons.
    var newPersons: [NewPersonFaces]
    /// source personID -> target personID (merges to apply).
    var merges: [UUID: UUID]
}

/// Incremental, deterministic clustering over stored face vectors.
///
/// People are described by their members, not by one average vector, so one person with
/// different poses and lighting stays one person:
/// 1. A loose face joins the person whose nearest members are closest (mean of the k nearest).
/// 2. Leftover faces form new persons with DBSCAN (density based, chains through similar faces).
/// 3. Persons that have several mutual near neighbours are merged.
nonisolated enum FaceClusterer {
    static func cluster(
        faces: [FaceVector],
        centroids: [Centroid],
        params: ClusterParams
    ) -> ClusterResult {
        guard let dim = (faces.first?.vector.count ?? centroids.first?.members.first?.count), dim > 0 else {
            return ClusterResult(assignments: [:], newPersons: [], merges: [:])
        }
        let ordered = faces
            .filter { $0.vector.count == dim }
            .sorted { $0.faceID.uuidString < $1.faceID.uuidString }
        let persons = centroids
            .map { centroid -> Centroid in
                var copy = centroid
                copy.members = centroid.members.filter { $0.count == dim }
                return copy
            }
            .filter { !$0.members.isEmpty }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let book = MemberBook(persons: persons, dim: dim)

        let joined = assign(ordered, to: book, params: params)
        var assignments = joined.0
        let newPersons = densityGroups(of: joined.1, params: params)
        let merges = mergePersons(book: book, params: params)
        for (faceID, personID) in assignments {
            assignments[faceID] = representative(of: personID, in: merges)
        }
        return ClusterResult(assignments: assignments, newPersons: newPersons, merges: merges)
    }

    // MARK: - Step 1: join existing persons

    private static func assign(
        _ faces: [FaceVector],
        to book: MemberBook,
        params: ClusterParams
    ) -> ([UUID: UUID], [FaceVector]) {
        var assignments: [UUID: UUID] = [:]
        guard !faces.isEmpty, !book.persons.isEmpty else { return (assignments, faces) }
        var pending: [FaceVector] = []
        let flat = flatten(faces.map(\.vector))
        var scratch: [Float] = []
        forEachChunk(rows: faces.count, columns: book.count) { range in
            let sims = similarities(flat, range, book.flatT, book.count, book.dim)
            for (offset, row) in range.enumerated() {
                let face = faces[row]
                var best: (id: UUID, distance: Float)?
                for (index, person) in book.persons.enumerated() where !face.rejectedPersonIDs.contains(person.id) {
                    let start = book.starts[index]
                    let end = book.starts[index + 1]
                    scratch.removeAll(keepingCapacity: true)
                    for column in start..<end { scratch.append(sims[offset * book.count + column]) }
                    scratch.sort(by: >)
                    let k = min(params.neighbours, scratch.count)
                    let distance = 1 - scratch.prefix(k).reduce(0, +) / Float(k)
                    if distance <= params.threshold, distance < (best?.distance ?? .infinity) {
                        best = (person.id, distance)
                    }
                }
                if let best { assignments[face.faceID] = best.id } else { pending.append(face) }
            }
        }
        return (assignments, pending)
    }

    // MARK: - Step 2: new persons (DBSCAN)

    private static func densityGroups(of faces: [FaceVector], params: ClusterParams) -> [NewPersonFaces] {
        let count = faces.count
        guard count >= params.minFaces, let dim = faces.first?.vector.count else { return [] }
        let flat = flatten(faces.map(\.vector))
        let flatT = transpose(flat, rows: count, dim: dim)
        let minSimilarity = 1 - params.threshold

        var neighbourCount = [Int](repeating: 0, count: count)
        forEachChunk(rows: count, columns: count) { range in
            let sims = similarities(flat, range, flatT, count, dim)
            for (offset, row) in range.enumerated() {
                var total = 0
                for column in 0..<count where sims[offset * count + column] >= minSimilarity { total += 1 }
                neighbourCount[row] = total
            }
        }
        let isCore = neighbourCount.map { $0 >= params.minFaces }
        guard isCore.contains(true) else { return [] }

        var parent = Array(0..<count)
        func find(_ node: Int) -> Int {
            var root = node
            while parent[root] != root { root = parent[root] }
            var current = node
            while parent[current] != root { (parent[current], current) = (root, parent[current]) }
            return root
        }
        var borderOwner = [Int](repeating: -1, count: count)
        var borderSimilarity = [Float](repeating: -.infinity, count: count)
        forEachChunk(rows: count, columns: count) { range in
            let sims = similarities(flat, range, flatT, count, dim)
            for (offset, row) in range.enumerated() where isCore[row] {
                for column in 0..<count {
                    let similarity = sims[offset * count + column]
                    guard column != row, similarity >= minSimilarity else { continue }
                    if isCore[column] {
                        let a = find(row), b = find(column)
                        if a != b { parent[max(a, b)] = min(a, b) }
                    } else if similarity > borderSimilarity[column] {
                        borderSimilarity[column] = similarity
                        borderOwner[column] = row
                    }
                }
            }
        }
        var groups: [Int: [UUID]] = [:]
        for index in 0..<count {
            if isCore[index] {
                groups[find(index), default: []].append(faces[index].faceID)
            } else if borderOwner[index] >= 0 {
                groups[find(borderOwner[index]), default: []].append(faces[index].faceID)
            }
        }
        return groups.keys.sorted().compactMap { key in
            groups[key].map { NewPersonFaces(faceIDs: $0) }
        }
    }

    // MARK: - Step 3: merge persons

    private static func mergePersons(book: MemberBook, params: ClusterParams) -> [UUID: UUID] {
        let personCount = book.persons.count
        guard personCount > 1 else { return [:] }
        let minSimilarity = 1 - params.threshold * params.mergeFactor
        // support[a * personCount + b]: members of a that have a neighbour in b.
        var support = [Int32](repeating: 0, count: personCount * personCount)
        var touched: [Int] = []
        var seen = [Bool](repeating: false, count: personCount)
        forEachChunk(rows: book.count, columns: book.count) { range in
            let sims = similarities(book.flat, range, book.flatT, book.count, book.dim)
            for (offset, row) in range.enumerated() {
                let owner = book.owner[row]
                touched.removeAll(keepingCapacity: true)
                for column in 0..<book.count where sims[offset * book.count + column] >= minSimilarity {
                    let other = book.owner[column]
                    if other != owner, !seen[other] {
                        seen[other] = true
                        touched.append(other)
                    }
                }
                for other in touched {
                    support[owner * personCount + other] += 1
                    seen[other] = false
                }
            }
        }
        var parent: [UUID: UUID] = [:]
        var size: [UUID: Int] = Dictionary(uniqueKeysWithValues: book.persons.map { ($0.id, $0.count) })
        var named: [UUID: Bool] = Dictionary(uniqueKeysWithValues: book.persons.map { ($0.id, $0.isNamed) })
        func root(_ id: UUID) -> UUID {
            var current = id
            while let next = parent[current] { current = next }
            return current
        }
        for a in 0..<personCount {
            for b in (a + 1)..<personCount {
                let membersA = book.starts[a + 1] - book.starts[a]
                let membersB = book.starts[b + 1] - book.starts[b]
                let needed = Int32(min(params.mergeSupport, min(membersA, membersB)))
                guard support[a * personCount + b] >= needed, support[b * personCount + a] >= needed else { continue }
                let rootA = root(book.persons[a].id)
                let rootB = root(book.persons[b].id)
                guard rootA != rootB, !(named[rootA] == true && named[rootB] == true) else { continue }
                let keepA = named[rootA] == true
                    || (named[rootB] != true && (size[rootA] ?? 0) >= (size[rootB] ?? 0))
                let keep = keepA ? rootA : rootB
                let drop = keepA ? rootB : rootA
                parent[drop] = keep
                size[keep, default: 0] += size[drop] ?? 0
                named[keep] = (named[keep] ?? false) || (named[drop] ?? false)
            }
        }
        var merges: [UUID: UUID] = [:]
        for person in book.persons {
            let target = root(person.id)
            if target != person.id { merges[person.id] = target }
        }
        return merges
    }

    private static func representative(of id: UUID, in merges: [UUID: UUID]) -> UUID {
        merges[id] ?? id
    }

    // MARK: - Second pass (Apple Photos style)

    /// Pass 1 is deliberately strict and leaves one person split over several groups
    /// (glasses, lighting, angle, age). This pass merges those groups with average-linkage
    /// hierarchical clustering, then attaches leftover single faces to the closest person.
    static func consolidate(
        persons input: [PersonSum],
        loose: [FaceVector],
        mergeThreshold: Float
    ) -> ConsolidationResult {
        guard let dim = input.first?.sum.count, dim > 0 else {
            return ConsolidationResult(merges: [:], assignments: [:])
        }
        let persons = input
            .filter { $0.sum.count == dim && $0.count > 0 }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let n = persons.count
        let minSimilarity = 1 - mergeThreshold
        var sums = persons.map(\.sum)
        var counts = persons.map { Float($0.count) }
        var named = persons.map(\.isNamed)
        var members: [[UUID]] = persons.map { [$0.id] }
        var alive = [Bool](repeating: true, count: n)

        // Average-linkage similarity matrix from the sums.
        var sim = [Float](repeating: -2, count: n * n)
        if n > 1 {
            let flat = flatten(sums)
            let flatT = transpose(flat, rows: n, dim: dim)
            forEachChunk(rows: n, columns: n) { range in
                let raw = similarities(flat, range, flatT, n, dim)
                for (offset, row) in range.enumerated() {
                    for column in 0..<n where column != row {
                        sim[row * n + column] = raw[offset * n + column] / (counts[row] * counts[column])
                    }
                }
            }
        }
        func allowed(_ a: Int, _ b: Int) -> Bool { a != b && alive[a] && alive[b] && !(named[a] && named[b]) }
        func bestInRow(_ row: Int) -> (Int, Float) {
            var best = (-1, Float(-2))
            for column in 0..<n where allowed(row, column) && sim[row * n + column] > best.1 {
                best = (column, sim[row * n + column])
            }
            return best
        }
        var rowBest = (0..<n).map { bestInRow($0) }
        var merges: [UUID: UUID] = [:]

        while true {
            var pick = (-1, -1, Float(-2))
            for row in 0..<n where alive[row] && rowBest[row].0 >= 0 && rowBest[row].1 > pick.2 {
                pick = (row, rowBest[row].0, rowBest[row].1)
            }
            guard pick.0 >= 0, pick.2 >= minSimilarity else { break }
            // Keep the named one, else the bigger one.
            let (a, b) = (pick.0, pick.1)
            let keep = named[a] || (!named[b] && counts[a] >= counts[b]) ? a : b
            let drop = keep == a ? b : a
            for index in 0..<dim { sums[keep][index] += sums[drop][index] }
            counts[keep] += counts[drop]
            named[keep] = named[keep] || named[drop]
            members[keep] += members[drop]
            alive[drop] = false
            for id in members[drop] { merges[id] = persons[keep].id }
            for other in 0..<n where alive[other] && other != keep {
                let value = VectorMath.dot(sums[keep], sums[other]) / (counts[keep] * counts[other])
                sim[keep * n + other] = value
                sim[other * n + keep] = value
            }
            rowBest[keep] = bestInRow(keep)
            for row in 0..<n where alive[row] && row != keep {
                if rowBest[row].0 == keep || rowBest[row].0 == drop {
                    rowBest[row] = bestInRow(row)
                } else if allowed(row, keep), sim[row * n + keep] > rowBest[row].1 {
                    rowBest[row] = (keep, sim[row * n + keep])
                }
            }
        }
        // Chains (a -> b, then b -> c) resolve to the final survivor.
        for (source, target) in merges {
            var final = target
            while let next = merges[final], next != final { final = next }
            merges[source] = final
        }
        merges = merges.filter { $0.key != $0.value }

        // Leftover single faces join the person they are, on average, closest to.
        var assignments: [UUID: UUID] = [:]
        let survivors = (0..<n).filter { alive[$0] }
        let faces = loose.filter { $0.vector.count == dim }
        if !survivors.isEmpty, !faces.isEmpty {
            let flatFaces = flatten(faces.map(\.vector))
            let survivorT = transpose(flatten(survivors.map { sums[$0] }), rows: survivors.count, dim: dim)
            forEachChunk(rows: faces.count, columns: survivors.count) { range in
                let raw = similarities(flatFaces, range, survivorT, survivors.count, dim)
                for (offset, row) in range.enumerated() {
                    let face = faces[row]
                    var best = (-1, Float(-2))
                    for (column, person) in survivors.enumerated() {
                        if members[person].contains(where: face.rejectedPersonIDs.contains) { continue }
                        let value = raw[offset * survivors.count + column] / counts[person]
                        if value > best.1 { best = (person, value) }
                    }
                    if best.0 >= 0, best.1 >= minSimilarity {
                        assignments[face.faceID] = persons[best.0].id
                    }
                }
            }
        }
        return ConsolidationResult(merges: merges, assignments: assignments)
    }

    // MARK: - Matrix helpers

    /// All members of all persons as one row-major matrix; person p owns rows starts[p]..<starts[p + 1].
    private struct MemberBook {
        var persons: [Centroid]
        var dim: Int
        var flat: [Float] = []
        /// `flat` transposed (dim x count), the layout the matrix multiply needs.
        var flatT: [Float] = []
        var starts: [Int] = [0]
        var owner: [Int] = []
        var count: Int { owner.count }

        init(persons: [Centroid], dim: Int) {
            self.persons = persons
            self.dim = dim
            for (index, person) in persons.enumerated() {
                for member in person.members {
                    flat.append(contentsOf: member)
                    owner.append(index)
                }
                starts.append(owner.count)
            }
            flatT = FaceClusterer.transpose(flat, rows: owner.count, dim: dim)
        }
    }

    private static func flatten(_ vectors: [[Float]]) -> [Float] {
        var flat: [Float] = []
        flat.reserveCapacity(vectors.count * (vectors.first?.count ?? 0))
        for vector in vectors { flat.append(contentsOf: vector) }
        return flat
    }

    /// Visits row ranges sized so a chunk of similarities stays around 4M floats.
    private static func forEachChunk(rows: Int, columns: Int, _ body: (Range<Int>) -> Void) {
        guard rows > 0, columns > 0 else { return }
        let step = max(1, 4_000_000 / columns)
        var start = 0
        while start < rows {
            let end = min(rows, start + step)
            body(start..<end)
            start = end
        }
    }

    /// `rows` x `dim` row-major -> `dim` x `rows` row-major.
    fileprivate static func transpose(_ flat: [Float], rows: Int, dim: Int) -> [Float] {
        var result = [Float](repeating: 0, count: flat.count)
        guard rows > 0, dim > 0 else { return result }
        vDSP_mtrans(flat, 1, &result, 1, vDSP_Length(dim), vDSP_Length(rows))
        return result
    }

    /// Dot products (cosine similarity for unit vectors) of `rows` of `a` against every column of `bT` (dim x bRows).
    private static func similarities(
        _ a: [Float], _ rows: Range<Int>, _ bT: [Float], _ bRows: Int, _ dim: Int
    ) -> [Float] {
        var result = [Float](repeating: 0, count: rows.count * bRows)
        a.withUnsafeBufferPointer { aBuffer in
            guard let base = aBuffer.baseAddress else { return }
            vDSP_mmul(
                base + rows.lowerBound * dim, 1, bT, 1, &result, 1,
                vDSP_Length(rows.count), vDSP_Length(bRows), vDSP_Length(dim)
            )
        }
        return result
    }
}

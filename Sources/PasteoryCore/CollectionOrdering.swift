import Foundation

public enum CollectionOrdering {
    public static func moving(
        id: UUID,
        before targetID: UUID,
        in collections: [ClipCollection]
    ) -> [ClipCollection] {
        guard id != targetID,
              let sourceIndex = collections.firstIndex(where: { $0.id == id }) else { return collections }
        var result = collections
        let moved = result.remove(at: sourceIndex)
        guard let targetIndex = result.firstIndex(where: { $0.id == targetID }) else { return collections }
        result.insert(moved, at: targetIndex)
        return normalized(result)
    }

    public static func movingToEnd(
        id: UUID,
        in collections: [ClipCollection]
    ) -> [ClipCollection] {
        guard let sourceIndex = collections.firstIndex(where: { $0.id == id }) else { return collections }
        var result = collections
        result.append(result.remove(at: sourceIndex))
        return normalized(result)
    }

    public static func moving(
        kind: CollectionKind,
        fromOffsets: IndexSet,
        toOffset: Int,
        in collections: [ClipCollection]
    ) -> [ClipCollection] {
        var sameKind = collections.filter { $0.kind == kind }
        let moving = fromOffsets.sorted().compactMap { sameKind.indices.contains($0) ? sameKind[$0] : nil }
        for index in fromOffsets.sorted(by: >) where sameKind.indices.contains(index) {
            sameKind.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let destination = min(max(toOffset - removedBeforeDestination, 0), sameKind.count)
        sameKind.insert(contentsOf: moving, at: destination)

        var iterator = sameKind.makeIterator()
        let result = collections.map { collection in
            collection.kind == kind ? (iterator.next() ?? collection) : collection
        }
        return normalized(result)
    }

    private static func normalized(_ collections: [ClipCollection]) -> [ClipCollection] {
        collections.enumerated().map { index, collection in
            var value = collection
            value.sortOrder = index
            return value
        }
    }
}

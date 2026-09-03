import Foundation
import Testing
@testable import PasteoryCore

@Test func quickTabOrderingCanMoveAcrossCollectionKinds() {
    let normalOne = ClipCollection(name: "普通一", kind: .normal, sortOrder: 0)
    let smartOne = ClipCollection(name: "智能一", kind: .smart, sortOrder: 1)
    let normalTwo = ClipCollection(name: "普通二", kind: .normal, sortOrder: 2)
    let smartTwo = ClipCollection(name: "智能二", kind: .smart, sortOrder: 3)
    let original = [normalOne, smartOne, normalTwo, smartTwo]

    let moved = CollectionOrdering.moving(id: smartTwo.id, before: normalOne.id, in: original)
    #expect(moved.map(\.id) == [smartTwo.id, normalOne.id, smartOne.id, normalTwo.id])
    #expect(moved.map(\.sortOrder) == [0, 1, 2, 3])

    let movedToEnd = CollectionOrdering.movingToEnd(id: normalOne.id, in: moved)
    #expect(movedToEnd.map(\.id) == [smartTwo.id, smartOne.id, normalTwo.id, normalOne.id])
}

@Test func libraryKindReorderingPreservesOtherKindSlots() {
    let normalOne = ClipCollection(name: "普通一", kind: .normal, sortOrder: 0)
    let smartOne = ClipCollection(name: "智能一", kind: .smart, sortOrder: 1)
    let normalTwo = ClipCollection(name: "普通二", kind: .normal, sortOrder: 2)
    let smartTwo = ClipCollection(name: "智能二", kind: .smart, sortOrder: 3)

    let moved = CollectionOrdering.moving(
        kind: .normal,
        fromOffsets: IndexSet(integer: 1),
        toOffset: 0,
        in: [normalOne, smartOne, normalTwo, smartTwo]
    )

    #expect(moved.map(\.id) == [normalTwo.id, smartOne.id, normalOne.id, smartTwo.id])
    #expect(moved.map(\.sortOrder) == [0, 1, 2, 3])
}

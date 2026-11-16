import Foundation
import PasteoryCore

struct ClipListRequest: Equatable, Sendable {
    let filter: ClipFilter
    let query: String
    var rules: SmartRuleSet?
}

struct ClipListPage: Sendable {
    let clips: [Clip]
    let hasMore: Bool
}

/// Database reads, smart rules and full-result search ranking stay off the UI actor.
actor ClipListLoader {
    static let pageSize = 100
    private let repository: any ClipRepository
    private var ranked: (generation: UUID, request: ClipListRequest, clips: [Clip])?

    init(repository: any ClipRepository) { self.repository = repository }

    func page(_ request: ClipListRequest, generation: UUID, offset: Int = 0, limit: Int = pageSize) async throws -> ClipListPage {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty && request.rules == nil {
            ranked = nil
            let clips = try await repository.list(filter: request.filter, query: "", limit: limit + 1, offset: offset)
            try Task.checkCancellation()
            return ClipListPage(clips: Array(clips.prefix(limit)), hasMore: clips.count > limit)
        }

        let all: [Clip]
        if let cached = ranked, cached.generation == generation, cached.request == request {
            all = cached.clips
        } else {
            // Match against the entire library before paginating the presentation.
            // The offset belongs to database candidates, not to matched smart-rule items.
            var candidates = [Clip](), cursor = 0
            while true {
                try Task.checkCancellation()
                let batch = try await repository.listMetadata(filter: request.filter, query: query, limit: 500, offset: cursor)
                if let rules = request.rules { candidates += try SmartRuleEngine().matchingItems(in: batch, ruleSet: rules) }
                else { candidates += batch }
                cursor += batch.count
                if batch.count < 500 { break }
            }
            try Task.checkCancellation()
            all = SearchRanker.rank(candidates, query: query)
            try Task.checkCancellation()
            ranked = (generation, request, all)
        }
        let page = Array(all.dropFirst(offset).prefix(limit))
        let hydrated = try await repository.clips(ids: page.map(\.id))
        try Task.checkCancellation()
        return ClipListPage(clips: hydrated, hasMore: offset + limit < all.count)
    }
}

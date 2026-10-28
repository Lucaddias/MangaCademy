import Foundation
import SwiftData
import Testing
@testable import MihonReader

@MainActor
struct SearchAndSourceTests {
    private func work(_ title: String, altTitles: [String] = []) -> UnifiedWork {
        let ref = WorkSourceRef(sourceId: title, sourceName: "Fonte", remoteUrl: "/\(title)", title: title, coverUrl: nil, languages: [])
        return UnifiedWork(ref: ref, altTitles: altTitles)
    }

    @Test func searchRanksDisplayedTitleBeforeAliasesAndUnrelatedResults() {
        let values = [
            work("Honeymoon"),
            work("Soldado a Monarca"),
            work("Outra obra", altTitles: ["Monarca"]),
            work("Monarca Mágico"),
            work("Monarca"),
            work("MONÁRCA Distante")
        ]
        let ranked = CatalogFeed.sortedSearchResults(values, query: "monarca")
        #expect(ranked.map(\.title) == ["Monarca", "Monarca Mágico", "MONÁRCA Distante", "Soldado a Monarca", "Outra obra", "Honeymoon"])
    }

    @Test func malformedMangaDexChapterResponseIsAnErrorRatherThanEmpty() throws {
        let (data, total) = try MangaDexSource.chapterFeedPage(["data": [[String: Any]](), "total": 0])
        #expect(data.isEmpty)
        #expect(total == 0)
        #expect(throws: HTTPError.self) { try MangaDexSource.chapterFeedPage(["errors": []]) }
        #expect(throws: HTTPError.self) { try MangaDexSource.chapterFeedPage(["data": "invalid", "total": 3]) }
    }
}

private actor SearchProbe {
    private(set) var searches: [String: Set<String>] = [:]
    private(set) var metadataStarted = 0
    private(set) var metadataCancelled = 0

    func searched(_ source: String, query: String) { searches[query, default: []].insert(source) }
    func started() { metadataStarted += 1 }
    func cancelled() { metadataCancelled += 1 }
    func count(_ query: String) -> Int { searches[query]?.count ?? 0 }
}

private final class SlowSearchSource: MangaSource, @unchecked Sendable {
    let id: String
    let name: String
    let language = "all"
    let baseUrl = ""
    let probe: SearchProbe
    let itemsPerPage: Int

    init(id: String, probe: SearchProbe, itemsPerPage: Int = 12) {
        self.id = id
        self.name = id
        self.probe = probe
        self.itemsPerPage = itemsPerPage
    }

    func fetchPopular(page: Int) async throws -> SourceMangaPage { .empty }
    func fetchLatest(page: Int) async throws -> SourceMangaPage { .empty }
    func search(query: String, page: Int) async throws -> SourceMangaPage {
        await probe.searched(id, query: query)
        guard page == 1 else { return .empty }
        return SourceMangaPage(items: (0..<itemsPerPage).map { index in
            SourceMangaItem(sourceId: id, remoteUrl: "\(query)-\(index)", title: "\(query) \(UUID().uuidString)", coverUrl: nil)
        }, hasNextPage: false)
    }
    func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        (try await fetchMetadata(remoteUrl: remoteUrl), [])
    }
    func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail {
        await probe.started()
        do { try await Task.sleep(nanoseconds: 200_000_000) }
        catch { await probe.cancelled(); throw error }
        return SourceMangaDetail(remoteUrl: remoteUrl, title: remoteUrl)
    }
    func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] { [] }
}

@MainActor
struct SearchSchedulingTests {
    @Test func discoversAllSourcesWithBoundedEnrichmentBacklog() async throws {
        let probe = SearchProbe()
        let prefix = UUID().uuidString
        let sources = (0..<20).map { SlowSearchSource(id: "\(prefix)-\($0)", probe: probe) }
        let feed = CatalogFeed(testSources: sources)
        feed.reset(filter: .all, mode: .search("Monarca"), includeNsfw: false)
        var peak = 0
        for _ in 0..<600 {
            peak = max(peak, feed.verifyingCount)
            if await probe.count("Monarca") == sources.count && !feed.isLoading && feed.works.count == sources.count * 12 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await probe.count("Monarca") == sources.count)
        #expect(feed.works.count == sources.count * 12)
        // The high water mark plus at most eight in-flight pages, each with twelve items.
        #expect(peak <= 96 + 8 * 12)
    }

    @Test func rapidResetCancelsEnrichmentAndDoesNotPublishOldResults() async throws {
        let probe = SearchProbe()
        let prefix = UUID().uuidString
        let sources = (0..<4).map { SlowSearchSource(id: "\(prefix)-\($0)", probe: probe, itemsPerPage: 5) }
        let feed = CatalogFeed(testSources: sources)
        feed.reset(filter: .all, mode: .search("antigo"), includeNsfw: false)
        for _ in 0..<100 {
            if await probe.metadataStarted > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await probe.metadataStarted > 0)
        feed.reset(filter: .all, mode: .search("novo"), includeNsfw: false)
        for _ in 0..<400 {
            if await probe.count("novo") == sources.count && !feed.isLoading && !feed.works.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await probe.metadataCancelled > 0)
        #expect(await probe.count("novo") == sources.count)
        #expect(!feed.works.isEmpty)
        #expect(feed.works.allSatisfy { $0.title.hasPrefix("novo") })
    }
}

private final class CachedResultSource: MangaSource, @unchecked Sendable {
    let item: SourceMangaItem
    let delay: UInt64
    var id: String { item.sourceId }
    var name: String { item.sourceId }
    let language = "all"
    let baseUrl = ""
    init(item: SourceMangaItem, delay: UInt64 = 0) { self.item = item; self.delay = delay }
    func fetchPopular(page: Int) async throws -> SourceMangaPage { try await search(query: "", page: page) }
    func fetchLatest(page: Int) async throws -> SourceMangaPage { .empty }
    func search(query: String, page: Int) async throws -> SourceMangaPage {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return SourceMangaPage(items: page == 1 ? [item] : [], hasNextPage: false)
    }
    func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        (SourceMangaDetail(remoteUrl: remoteUrl, title: item.title), [])
    }
    func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] { [] }
}

@MainActor
struct SearchMergeIntegrationTests {
    @Test func detailSearchProtectsTwoSavedIdentities() async throws {
        let container = try ModelContainer(for: ModelStore.schema, configurations: ModelConfiguration(schema: ModelStore.schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let prefix = UUID().uuidString
        let sources = (0..<2).map { index in
            CachedResultSource(item: SourceMangaItem(sourceId: "\(prefix)-\(index)", remoteUrl: "/\(index)", title: "Obra", coverUrl: nil, hasFullMetadata: true))
        }
        for index in 0..<2 {
            context.insert(Manga(sourceId: "\(prefix)-\(index)", remoteUrl: "/\(index)", title: "Obra", isFavorite: true))
        }
        try context.save()
        let feed = CatalogFeed(testSources: sources)
        SearchResultsView.configureSafety(feed, context: context)
        feed.reset(filter: .all, mode: .search("Obra"), includeNsfw: false)
        for _ in 0..<200 {
            if feed.works.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(feed.works.count == 2)
    }

    @Test(arguments: [true, false])
    func laterResultReconcilesAliasesUsingCachedMetadata(listingIsComplete: Bool) async throws {
        let prefix = UUID().uuidString
        let cover = "https://example.invalid/cover.png"
        let titles = ["Reader", "O leitor", "Reader"]
        let items = titles.enumerated().map { index, title in
            SourceMangaItem(sourceId: "\(prefix)-\(index)", remoteUrl: "/\(index)", title: title,
                            coverUrl: cover, altTitles: index == 2 && listingIsComplete ? ["O leitor"] : [],
                            hasFullMetadata: listingIsComplete)
        }
        for (index, item) in items.enumerated() {
            MetadataCache.shared.store(refId: item.id, altTitles: index == 2 ? ["O leitor"] : [], genres: [], coverUrl: cover, coverHash: 0x123456789abcdef0)
        }
        let sources = items.enumerated().map { index, item in
            CachedResultSource(item: item, delay: UInt64(index) * 300_000_000)
        }
        let feed = CatalogFeed(testSources: sources)
        feed.canMergeIdentities = { _ in .allow(preferredID: nil) }
        feed.reset(filter: .all, mode: .search("Reader"), includeNsfw: false)
        for _ in 0..<150 {
            if feed.works.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(feed.works.count == 2)
        let originalId = feed.works.first?.id
        for _ in 0..<250 {
            if feed.works.count == 1 && feed.works.first?.refs.count == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(feed.works.count == 1)
        #expect(feed.works.first?.refs.count == 3)
        #expect(feed.works.first?.id == originalId)
    }
}

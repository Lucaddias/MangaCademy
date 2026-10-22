import Foundation
import SwiftData
import Testing
@testable import MihonReader

@MainActor
struct UpdatesTests {
    private func makeContext() throws -> ModelContext {
        let schema = ModelStore.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @Test func restrictionsAndCategories() throws {
        let context = try makeContext()
        let completed = Manga(sourceId: "s", remoteUrl: "/a", title: "A", status: 2, isFavorite: true)
        let ongoing = Manga(sourceId: "s", remoteUrl: "/b", title: "B", status: 1, isFavorite: true)
        ongoing.categoryIds = ["cat"]
        let unread = Manga(sourceId: "s", remoteUrl: "/c", title: "C", status: 1, isFavorite: true)
        unread.unreadCount = 4
        [completed, ongoing, unread].forEach(context.insert)

        let settings = UpdateSettings(defaults: UserDefaults(suiteName: "upd-\(UUID().uuidString)")!)
        settings.skipCompleted = true
        let all = LibraryUpdater.candidates([completed, ongoing, unread], categoryId: nil, knownCategories: ["cat"], settings: settings, startedIds: [])
        #expect(Set(all.map(\.title)) == ["B", "C"])

        settings.skipWithUnread = true
        settings.excludedCategories = ["cat"]
        #expect(LibraryUpdater.candidates([completed, ongoing, unread], categoryId: nil, knownCategories: ["cat"], settings: settings, startedIds: []).isEmpty)

        let tab = LibraryUpdater.candidates([completed, ongoing, unread], categoryId: "cat", knownCategories: ["cat"], settings: settings, startedIds: [])
        #expect(tab.map(\.title) == ["B"])
    }

    /// O predicado com data opcional usado na aba Novidades roda no SwiftData e só traz
    /// capítulos que entraram depois de a obra ir para a biblioteca.
    @Test func feedShowsOnlyNewChapters() throws {
        let context = try makeContext()
        let manga = Manga(sourceId: "s", remoteUrl: "/a", title: "A", isFavorite: true)
        manga.favoriteAt = Date(timeIntervalSinceNow: -10 * 86_400)
        context.insert(manga)
        let old = Chapter(mangaId: manga.id, remoteUrl: "/1", name: "1", chapterNumber: 1, orderIndex: 0, sourceId: "s")
        old.dateFetch = manga.favoriteAt
        let new = Chapter(mangaId: manga.id, remoteUrl: "/2", name: "2", chapterNumber: 2, orderIndex: 1, sourceId: "s")
        new.dateFetch = Date()
        let ancient = Chapter(mangaId: manga.id, remoteUrl: "/0", name: "0", chapterNumber: 0.5, orderIndex: 2, sourceId: "s")
        ancient.dateFetch = Date(timeIntervalSinceNow: -400 * 86_400)
        [old, new, ancient].forEach(context.insert)
        try context.save()

        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let recent = try context.fetch(FetchDescriptor<Chapter>(predicate: #Predicate { $0.dateFetch.flatMap { $0 > cutoff } == true }))
        #expect(Set(recent.map(\.name)) == ["1", "2"])
        let items = UpdatesFeed.items(records: recent, favorites: [manga])
        #expect(items.map(\.chapter.name) == ["2"])
    }
}

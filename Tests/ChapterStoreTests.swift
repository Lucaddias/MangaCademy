import Foundation
import SwiftData
import Testing
@testable import MihonReader

@MainActor
struct ChapterStoreTests {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init() throws {
        let config = ModelConfiguration(schema: ModelStore.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: ModelStore.schema, configurations: config)
    }

    private func chapter(_ number: Double, source: String = "a", language: String? = "pt-BR") -> SourceChapterItem {
        SourceChapterItem(
            remoteUrl: "/\(source)/\(number)",
            name: "Cap. \(number)",
            chapterNumber: number,
            orderIndex: 0,
            language: language,
            sourceId: source,
            mangaRemoteUrl: "/\(source)"
        )
    }

    private func libraryManga(favoriteAt: Date) -> Manga {
        let manga = Manga(sourceId: "a", remoteUrl: "/obra", title: "Obra", isFavorite: true)
        manga.favoriteAt = favoriteAt
        manga.preferredLanguage = "pt-BR"
        context.insert(manga)
        return manga
    }

    private func records(_ manga: Manga) -> [Chapter] {
        ChapterStore.records(mangaId: manga.id, context: context)
    }

    @Test func firstSyncIsNotNews() {
        let added = Date(timeIntervalSince1970: 1_000)
        let manga = libraryManga(favoriteAt: added)
        ChapterStore.sync(["pt-BR": [chapter(2), chapter(1)]], manga: manga, context: context, now: Date(timeIntervalSince1970: 2_000))

        let saved = records(manga)
        #expect(saved.count == 2)
        #expect(saved.allSatisfy { $0.dateFetch == added })
        #expect(saved.allSatisfy { $0.manga?.id == manga.id })
        #expect(saved.allSatisfy { $0.mangaRemoteUrl == "/a" })
    }

    @Test func laterChaptersAreNews() {
        let added = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 5_000)
        let manga = libraryManga(favoriteAt: added)
        ChapterStore.sync(["pt-BR": [chapter(1)]], manga: manga, context: context, now: Date(timeIntervalSince1970: 2_000))
        ChapterStore.sync(["pt-BR": [chapter(2), chapter(1)]], manga: manga, context: context, now: later)

        let byNumber = Dictionary(uniqueKeysWithValues: records(manga).map { ($0.chapterNumber, $0) })
        #expect(byNumber[1]?.dateFetch == added)
        #expect(byNumber[2]?.dateFetch == later)
    }

    @Test func sameNumberFromAnotherSourceIsNotNews() {
        let added = Date(timeIntervalSince1970: 1_000)
        let manga = libraryManga(favoriteAt: added)
        ChapterStore.sync(["pt-BR": [chapter(1, source: "a")]], manga: manga, context: context, now: Date(timeIntervalSince1970: 2_000))
        ChapterStore.sync(["pt-BR": [chapter(1, source: "b")]], manga: manga, context: context, now: Date(timeIntervalSince1970: 5_000))

        #expect(records(manga).allSatisfy { $0.dateFetch == added })
    }

    @Test func unreadCountUsesPreferredLanguageAndNumbers() {
        let manga = libraryManga(favoriteAt: .distantPast)
        ChapterStore.sync([
            "pt-BR": [chapter(3), chapter(2), chapter(1)],
            "en": [chapter(4, language: "en")],
        ], manga: manga, context: context)
        #expect(manga.unreadCount == 3)

        ChapterStore.setRead(true, chapter: chapter(1), mangaId: manga.id, context: context)
        #expect(manga.unreadCount == 2)

        // O mesmo número lido em outra fonte conta como lido.
        ChapterStore.setRead(true, chapter: chapter(2, source: "b"), mangaId: manga.id, context: context)
        #expect(manga.unreadCount == 1)
    }

    @Test func unmarkingReadClearsOtherSources() {
        let manga = libraryManga(favoriteAt: .distantPast)
        ChapterStore.setRead(true, chapter: chapter(1, source: "a"), mangaId: manga.id, context: context)
        ChapterStore.setRead(true, chapter: chapter(1, source: "b"), mangaId: manga.id, context: context)

        let progress = ChapterProgress(records: records(manga), mangaId: manga.id)
        #expect(progress.isRead(chapter(1, source: "c")))

        ChapterStore.setRead(false, chapter: chapter(1, source: "c"), mangaId: manga.id, context: context)
        let after = ChapterProgress(records: records(manga), mangaId: manga.id)
        #expect(!after.isRead(chapter(1, source: "a")))
        #expect(!after.isRead(chapter(1, source: "b")))
    }

    @Test func bookmarkAndPageProgress() {
        let manga = libraryManga(favoriteAt: .distantPast)
        ChapterStore.setBookmarked(true, chapter: chapter(1), mangaId: manga.id, context: context)
        ChapterStore.saveProgress(page: 7, totalPages: 20, chapter: chapter(1), mangaId: manga.id, context: context)

        let progress = ChapterProgress(records: records(manga), mangaId: manga.id)
        #expect(progress.isBookmarked(chapter(1)))
        #expect(!progress.isBookmarked(chapter(1, source: "b")))
        #expect(progress.pageInProgress(chapter(1)) == 7)

        ChapterStore.setRead(true, chapter: chapter(1), mangaId: manga.id, context: context)
        let read = ChapterProgress(records: records(manga), mangaId: manga.id)
        #expect(read.pageInProgress(chapter(1)) == nil)
    }
}

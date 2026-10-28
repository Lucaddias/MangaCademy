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

    @Test func localProgressAndBookmarksPreventIdentityMerge() {
        let a = "a:/1", b = "b:/2"
        let item = chapter(1)
        let record = ChapterStore.ensureRecord(for: item, mangaId: b, context: context)
        record.isRead = true
        record.isBookmarked = true
        record.lastPageRead = 7
        try? context.save()
        #expect(!LocalIdentitySafety.canMerge([a, b], context: context))
        #expect(record.isRead && record.isBookmarked && record.lastPageRead == 7)
    }

    @Test func savedWorkAndSourceRefsPreventIdentityMerge() {
        let manga = libraryManga(favoriteAt: .distantPast)
        let ref = WorkSourceRef(sourceId: "b", sourceName: "B", remoteUrl: "/2", title: "Obra", coverUrl: nil, languages: [])
        manga.sourcesJSON = String(data: try! JSONEncoder().encode([ref]), encoding: .utf8)
        try? context.save()
        #expect(!LocalIdentitySafety.canMerge([ref.id, "c:/3"], context: context))
    }

    @Test func oneSavedWorkWithoutChapterStateKeepsItsIdentity() {
        let saved = libraryManga(favoriteAt: .distantPast)
        ChapterStore.sync(["pt-BR": [chapter(1)]], manga: saved, context: context)
        #expect(records(saved).count == 1)
        #expect(records(saved).allSatisfy { !$0.isRead && !$0.isBookmarked && $0.lastPageRead == 0 })
        var merger = WorkMerger(canMergeIdentities: { LocalIdentitySafety.decision($0, context: context) })
        let other = SourceMangaItem(sourceId: "b", remoteUrl: "/other", title: "Obra", coverUrl: nil)
        let original = SourceMangaItem(sourceId: saved.sourceId, remoteUrl: saved.remoteUrl, title: "Obra", coverUrl: nil)
        merger.add(other, sourceName: "B")
        merger.add(original, sourceName: "A")
        #expect(merger.works.count == 1)
        #expect(merger.works.first?.id == saved.id)
        #expect(merger.works.first?.refs.count == 2)
    }

    @Test func identitySafetyDoesNotStopAfterSixteenCandidateMerges() {
        let gate = LocalIdentitySafety.Gate(context: context)
        var allowed = 0
        for index in 0..<20 {
            if case .allow = gate.decide(["source-a:/\(index)", "source-b:/\(index)"]) { allowed += 1 }
        }
        #expect(allowed == 20)
    }

    @Test func identitySafetyFindsWorksSavedAfterFeedStarted() {
        let gate = LocalIdentitySafety.Gate(context: context)
        let first = libraryManga(favoriteAt: .distantPast)
        let second = Manga(sourceId: "b", remoteUrl: "/other", title: "Obra", isFavorite: true)
        context.insert(second)
        try? context.save()
        let decision = gate.decide([first.id, second.id])
        let denied: Bool
        if case .deny = decision { denied = true } else { denied = false }
        #expect(denied)
    }

    @Test func twoSavedWorksCannotMerge() {
        let first = libraryManga(favoriteAt: .distantPast)
        let second = Manga(sourceId: "b", remoteUrl: "/other", title: "Obra", isFavorite: true)
        context.insert(second)
        try? context.save()
        #expect(!LocalIdentitySafety.canMerge([first.id, second.id], context: context))
    }

    @Test func historyAndTrackingPreventIdentityMerge() {
        let history = HistoryEntry(mangaId: "b:/2", chapterId: "history", mangaTitle: "Obra", chapterName: "Cap. 1", coverUrl: nil)
        let tracking = TrackRecord(mangaId: "c:/3", trackerId: "tracker", remoteId: "remote", title: "Obra")
        context.insert(history)
        context.insert(tracking)
        try? context.save()
        #expect(!LocalIdentitySafety.canMerge(["a:/1", "b:/2"], context: context))
        #expect(!LocalIdentitySafety.canMerge(["a:/1", "c:/3"], context: context))
    }

    @Test func downloadedFilesPreventIdentityMerge() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = DownloadStore(root: dir)
        let item = chapter(1)
        try FileManager.default.createDirectory(at: downloads.chapterDirectory(for: item, mangaId: "b:/2"), withIntermediateDirectories: true)
        try downloads.finish(chapter: item, mangaId: "b:/2", files: ["001.jpg"])
        #expect(!LocalIdentitySafety.canMerge(["a:/1", "b:/2"], context: context, downloads: downloads))
        #expect(downloads.isDownloaded(item, mangaId: "b:/2"))
        #expect(LocalIdentitySafety.canMerge(["a:/1", "c:/3"], context: context, downloads: downloads))
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

    @Test func markAllReadCreatesMissingRecords() {
        let manga = libraryManga(favoriteAt: .distantPast)
        manga.unreadCount = 3
        let list = [chapter(3), chapter(2), chapter(1)]
        ChapterStore.setRead(true, chapters: list, mangaId: manga.id, context: context)

        let progress = ChapterProgress(records: records(manga), mangaId: manga.id)
        #expect(list.allSatisfy(progress.isRead))
        #expect(manga.unreadCount == 0)
    }

    @Test func unmarkAllClearsOtherSourcesToo() {
        let manga = libraryManga(favoriteAt: .distantPast)
        ChapterStore.setRead(true, chapters: [chapter(2, source: "b"), chapter(1, source: "b")], mangaId: manga.id, context: context)
        ChapterStore.setRead(false, chapters: [chapter(2, source: "a"), chapter(1, source: "a")], mangaId: manga.id, context: context)

        let progress = ChapterProgress(records: records(manga), mangaId: manga.id)
        #expect(!progress.isRead(chapter(2, source: "b")))
        #expect(!progress.isRead(chapter(1, source: "b")))
        // Desmarcar não cria registros para capítulos que nunca foram lidos
        #expect(records(manga).allSatisfy { $0.sourceId == "b" })
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

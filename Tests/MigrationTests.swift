import Foundation
import SwiftData
import Testing
@testable import MihonReader

@MainActor
struct MigrationTests {
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).store")
    }

    /// Bancos criados antes do versionamento (schema sem versão, com os modelos da V1)
    /// abrem na versão atual sem perder dados.
    @Test func unversionedV1StoreMigratesToCurrent() throws {
        let url = temporaryStoreURL()
        do {
            let schema = Schema([SchemaV1.Manga.self, SchemaV1.Chapter.self, SchemaV1.HistoryEntry.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            let manga = SchemaV1.Manga(sourceId: "ky-1", remoteUrl: "/obra", title: "Obra")
            manga.isFavorite = true
            context.insert(manga)
            let chapter = SchemaV1.Chapter(id: "ky-1:/obra:ky-1:/cap-1", mangaId: manga.id, remoteUrl: "/cap-1", name: "Cap. 1", chapterNumber: 1)
            chapter.isRead = true
            chapter.manga = manga
            context.insert(chapter)
            context.insert(SchemaV1.HistoryEntry(mangaId: manga.id, chapterId: chapter.id, mangaTitle: "Obra", chapterName: "Cap. 1"))
            try context.save()
        }

        let container = try ModelStore.open(url: url)
        let context = ModelContext(container)
        let mangas = try context.fetch(FetchDescriptor<Manga>())
        #expect(mangas.map(\.title) == ["Obra"])
        #expect(mangas.first?.isFavorite == true)

        let chapters = try context.fetch(FetchDescriptor<Chapter>())
        #expect(chapters.count == 1)
        #expect(chapters.first?.isRead == true)
        #expect(chapters.first?.dateFetch == nil)
        #expect(chapters.first?.manga?.id == "ky-1:/obra")

        let history = try context.fetch(FetchDescriptor<HistoryEntry>())
        #expect(history.count == 1)
        #expect(history.first?.sourceId == nil)
    }

    /// Bancos V2 ganham os campos novos da V3 com valores padrão, sem perder o progresso.
    @Test func v2StoreMigratesToV3WithDefaults() throws {
        let url = temporaryStoreURL()
        do {
            let schema = Schema(versionedSchema: SchemaV2.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            let manga = SchemaV2.Manga(sourceId: "ky-1", remoteUrl: "/obra", title: "Obra", isFavorite: true)
            context.insert(manga)
            let chapter = SchemaV2.Chapter(mangaId: manga.id, remoteUrl: "/cap-1", name: "Cap. 1", chapterNumber: 1, orderIndex: 0, sourceId: "ky-1")
            chapter.lastPageRead = 7
            chapter.manga = manga
            context.insert(chapter)
            try context.save()
        }

        let context = ModelContext(try ModelStore.open(url: url))
        let manga = try #require(try context.fetch(FetchDescriptor<Manga>()).first)
        #expect(manga.categoryIds.isEmpty)
        #expect(manga.readingMode == nil)
        #expect(manga.notes.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Chapter>()).first?.lastPageRead == 7)
        context.insert(MangaCategory(name: "Lendo", order: 0))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<MangaCategory>()) == 1)
    }

    @Test func unreadableStoreIsMovedAsideAndRecreated() throws {
        let url = temporaryStoreURL()
        try Data("não é um banco sqlite".utf8).write(to: url)

        let result = ModelStore.openRecovering(url: url)
        #expect(result.didReset)
        let context = ModelContext(result.container)
        context.insert(Manga(sourceId: "ky-1", remoteUrl: "/obra", title: "Obra"))
        try context.save()

        let backups = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(url.lastPathComponent + ".broken-") }
        #expect(!backups.isEmpty)
    }
}

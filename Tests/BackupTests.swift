import Foundation
import SwiftData
import Testing
@testable import MihonReader

@MainActor
struct BackupTests {
    private func makeContext() throws -> ModelContext {
        let schema = ModelStore.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "backup-\(UUID().uuidString)")!
    }

    @Test func gzipRoundTrip() throws {
        let text = Data(String(repeating: "MangaCademy ", count: 500).utf8)
        let zipped = try Gzip.compress(text)
        #expect(Gzip.isGzip(zipped))
        #expect(zipped.count < text.count)
        #expect(try Gzip.decompress(zipped) == text)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF43926)
    }

    @Test func backupRoundTripMergesProgress() throws {
        let source = try makeContext()
        let manga = Manga(sourceId: "s", remoteUrl: "/a", title: "A", isFavorite: true)
        manga.notes = "nota"
        source.insert(manga)
        let read = Chapter(mangaId: manga.id, remoteUrl: "/c1", name: "Cap. 1", chapterNumber: 1, orderIndex: 1, sourceId: "s")
        read.isRead = true
        let partial = Chapter(mangaId: manga.id, remoteUrl: "/c2", name: "Cap. 2", chapterNumber: 2, orderIndex: 0, sourceId: "s")
        partial.lastPageRead = 7
        [read, partial].forEach { $0.manga = manga; source.insert($0) }
        source.insert(MangaCategory(id: "c", name: "Lendo", order: 0))
        manga.categoryIds = ["c"]
        let defaults = isolatedDefaults()
        defaults.set(3, forKey: "reader_mode")
        defaults.set("x", forKey: "unrelated_key")
        try source.save()

        let data = try BackupManager.encode(BackupManager.makeBackup(context: source, defaults: defaults))
        let backup = try BackupManager.decode(data)
        #expect(backup.preferences["reader_mode"] == .int(3))
        #expect(backup.preferences["unrelated_key"] == nil)

        // Destino já tem a obra, com menos progresso num capítulo e mais em outro.
        let target = try makeContext()
        let existing = Manga(sourceId: "s", remoteUrl: "/a", title: "A")
        target.insert(existing)
        let ahead = Chapter(mangaId: existing.id, remoteUrl: "/c2", name: "Cap. 2", chapterNumber: 2, orderIndex: 0, sourceId: "s")
        ahead.lastPageRead = 12
        ahead.manga = existing
        target.insert(ahead)
        target.insert(MangaCategory(id: "other", name: "lendo", order: 0))
        try target.save()

        let summary = BackupManager.restore(backup, context: target, defaults: isolatedDefaults())
        #expect(summary.merged == 1 && summary.added == 0)
        let chapters = ChapterStore.records(mangaId: existing.id, context: target)
        #expect(chapters.count == 2)
        #expect(chapters.first { $0.remoteUrl == "/c1" }?.isRead == true)
        #expect(chapters.first { $0.remoteUrl == "/c2" }?.lastPageRead == 12)
        #expect(existing.isFavorite)
        #expect(existing.notes == "nota")
        // Categoria casada pelo nome, sem duplicar.
        #expect(existing.categoryIds == ["other"])
        #expect(try target.fetch(FetchDescriptor<MangaCategory>()).count == 1)
    }

    // MARK: - .tachibk

    private func varint(_ value: UInt64) -> Data {
        var v = value, out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func field(_ number: Int, _ value: UInt64) -> Data { varint(UInt64(number << 3)) + varint(value) }
    private func field(_ number: Int, _ bytes: Data) -> Data { varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    private func field(_ number: Int, _ text: String) -> Data { field(number, Data(text.utf8)) }
    private func field(_ number: Int, float: Float) -> Data {
        var bits = float.bitPattern.littleEndian
        return varint(UInt64(number << 3 | 5)) + withUnsafeBytes(of: &bits) { Data($0) }
    }

    @Test func importsMihonBackup() throws {
        let chapter1 = field(1, "/chapter/aaa") + field(2, "Ch. 1") + field(4, 1) + field(9, float: 1) + field(10, 1)
        let chapter2 = field(1, "/chapter/bbb") + field(2, "Ch. 2") + field(6, 4) + field(9, float: 2) + field(10, 0) + field(7, 1_700_000_000_000)
        let history = field(1, "/chapter/bbb") + field(2, 1_700_000_100_000) + field(3, 60_000)
        let tracking = field(1, 2) + field(5, "AniList title") + field(6, float: 1) + field(100, 12345)
        let parts: [Data] = [
            field(1, 999), field(2, "/manga/uuid-1"), field(3, "Obra"), field(7, "Ação"), field(7, "Drama"),
            field(13, 1_600_000_000_000), field(16, chapter1), field(16, chapter2),
            field(17, varint(1)), field(18, tracking), field(104, history), field(110, "nota"),
        ]
        let manga = parts.reduce(Data(), +)
        let category = field(1, "Lendo") + field(2, 1)
        let sourceInfo = field(1, "MangaDex") + field(2, 999)
        let raw = field(1, manga) + field(2, category) + field(101, sourceInfo)

        let parsed = try MihonBackupImporter.parse(try Gzip.compress(raw))
        #expect(parsed.mangas.count == 1)
        #expect(parsed.mangas[0].genres == ["Ação", "Drama"])
        #expect(parsed.mangas[0].chapters[1].lastPageRead == 4)
        #expect(parsed.sourceNames[999] == "MangaDex")

        let backup = MihonBackupImporter.convert(parsed)
        let item = try #require(backup.mangas.first)
        #expect(item.sourceId == "mangadex")
        #expect(item.remoteUrl == "uuid-1")
        #expect(item.notes == "nota")
        #expect(item.categoryIds == [backup.categories[0].id])
        #expect(item.favoriteAt == Date(timeIntervalSince1970: 1_600_000_000))
        let ch2 = try #require(item.chapters.first { $0.remoteUrl == "bbb" })
        #expect(ch2.lastPageRead == 5) // Mihon conta páginas de 0
        #expect(item.chapters.first { $0.remoteUrl == "aaa" }?.isRead == true)
        #expect(backup.history.first?.timeRead == 60)
        #expect(backup.tracks.first?.trackerId == "anilist")
        #expect(backup.tracks.first?.remoteId == "12345")

        let context = try makeContext()
        let summary = BackupManager.restore(backup, context: context, defaults: isolatedDefaults())
        #expect(summary.added == 1)
        #expect(ChapterStore.records(mangaId: item.id, context: context).count == 2)
    }
}

import Foundation
import SwiftData

// MARK: - Formato

/// Backup do MangaCademy: JSON versionado, comprimido com gzip.
struct AppBackup: Codable {
    static let currentVersion = 1

    var version = AppBackup.currentVersion
    var createdAt = Date()
    var mangas: [BackupManga] = []
    var categories: [BackupCategory] = []
    var history: [BackupHistory] = []
    var tracks: [BackupTrack] = []
    var preferences: [String: BackupPreference] = [:]

    struct BackupManga: Codable {
        var id: String
        var sourceId: String
        var remoteUrl: String
        var title: String
        var author: String?
        var artist: String?
        var desc: String?
        var genres: [String]
        var status: Int
        var coverUrl: String?
        var isFavorite: Bool
        var favoriteAt: Date?
        var sourcesJSON: String?
        var preferredLanguage: String?
        var categoryIds: [String]
        var readingMode: Int?
        var orientation: Int?
        var chapterFlags: Int
        var excludedScanlators: [String]
        var preferredSourceId: String?
        var notes: String
        /// Capa personalizada (JPEG).
        var customCover: Data?
        var chapters: [BackupChapter]
    }

    struct BackupChapter: Codable {
        var remoteUrl: String
        var name: String
        var scanlator: String?
        var chapterNumber: Double
        var uploadDate: Date?
        var orderIndex: Int
        var sourceId: String?
        var language: String?
        var mangaRemoteUrl: String?
        var isRead: Bool
        var isBookmarked: Bool
        var lastPageRead: Int
        var totalPages: Int
        var lastReadDate: Date?
        var dateFetch: Date?
    }

    struct BackupCategory: Codable {
        var id: String
        var name: String
        var order: Int
    }

    struct BackupHistory: Codable {
        var mangaId: String
        var chapterId: String
        var mangaTitle: String
        var chapterName: String
        var coverUrl: String?
        var readAt: Date
        var pageNumber: Int
        var totalPages: Int
        var sourceId: String?
        var chapterRemoteUrl: String?
        var mangaRemoteUrl: String?
        var timeRead: Double
    }

    struct BackupTrack: Codable {
        var mangaId: String
        var trackerId: String
        var remoteId: String
        var title: String
        var status: Int
        var score: Double
        var lastChapterRead: Double
        var totalChapters: Int
        var startDate: Date?
        var finishDate: Date?
        var remoteUrl: String?
    }
}

/// Valor de uma preferência (só os tipos que o app usa).
enum BackupPreference: Codable, Equatable {
    case bool(Bool), int(Int), double(Double), string(String), strings([String])

    init?(_ value: Any) {
        switch value {
        case let v as Bool where CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(): self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Double: self = .double(v)
        case let v as String: self = .string(v)
        case let v as [String]: self = .strings(v)
        default: return nil
        }
    }

    var value: Any {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .strings(let v): return v
        }
    }
}

/// O que uma restauração fez.
struct RestoreSummary {
    var added = 0
    var merged = 0
    var chapters = 0
    var unavailableSources: Set<String> = []

    var text: String {
        var parts = ["\(added) obras adicionadas", "\(merged) mescladas", "\(chapters) capítulos"]
        if !unavailableSources.isEmpty {
            parts.append("\(unavailableSources.count) fontes sem motor no iOS (abra a obra e use “Fontes desta obra” para achar em outra)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Backup automático

@MainActor
@Observable
final class BackupSettings {
    static let shared = BackupSettings()

    /// Backup automático a cada N horas (0 = desligado).
    var intervalHours: Int {
        didSet {
            UserDefaults.standard.set(intervalHours, forKey: "backup_interval_hours")
            BackgroundTasks.scheduleBackup()
        }
    }
    /// Quantos backups automáticos manter.
    var keepCount: Int { didSet { UserDefaults.standard.set(keepCount, forKey: "backup_keep_count") } }
    var lastAutomatic: Date? { didSet { UserDefaults.standard.set(lastAutomatic, forKey: "backup_last_automatic") } }

    private init() {
        intervalHours = UserDefaults.standard.object(forKey: "backup_interval_hours") as? Int ?? 24 * 7
        keepCount = UserDefaults.standard.object(forKey: "backup_keep_count") as? Int ?? 3
        lastAutomatic = UserDefaults.standard.object(forKey: "backup_last_automatic") as? Date
    }
}

// MARK: - Criar e restaurar

@MainActor
enum BackupManager {
    /// Preferências que vão no backup (as do app; nada do sistema).
    static let preferencePrefixes = ["reader_", "library_", "update_", "chapter_", "download_", "catalog_", "show_nsfw", "block_adult", "incognito", "security_", "appearance_", "disabled_", "pinned_sources", "default_reader", "track_"]

    static var backupsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeBackup(context: ModelContext, defaults: UserDefaults = .standard) -> AppBackup {
        var backup = AppBackup()
        let mangas = (try? context.fetch(FetchDescriptor<Manga>())) ?? []
        let chapters = (try? context.fetch(FetchDescriptor<Chapter>())) ?? []
        let byManga = Dictionary(grouping: chapters, by: \.mangaId)
        let history = (try? context.fetch(FetchDescriptor<HistoryEntry>())) ?? []
        // Obras fora da biblioteca só entram se tiverem progresso ou histórico.
        let historyIds = Set(history.map(\.mangaId))
        for manga in mangas where manga.isFavorite || historyIds.contains(manga.id) || byManga[manga.id]?.contains(where: { $0.isRead || $0.isBookmarked }) == true {
            backup.mangas.append(AppBackup.BackupManga(
                id: manga.id, sourceId: manga.sourceId, remoteUrl: manga.remoteUrl, title: manga.title,
                author: manga.author, artist: manga.artist, desc: manga.desc, genres: manga.genres, status: manga.status,
                coverUrl: manga.coverUrl, isFavorite: manga.isFavorite, favoriteAt: manga.favoriteAt,
                sourcesJSON: manga.sourcesJSON, preferredLanguage: manga.preferredLanguage, categoryIds: manga.categoryIds,
                readingMode: manga.readingMode, orientation: manga.orientation, chapterFlags: manga.chapterFlags,
                excludedScanlators: manga.excludedScanlators, preferredSourceId: manga.preferredSourceId, notes: manga.notes,
                customCover: CustomCoverStore.url(for: manga.customCoverPath).flatMap { try? Data(contentsOf: $0) },
                chapters: (byManga[manga.id] ?? []).map(Self.backupChapter)
            ))
        }
        // Progresso de obras que nunca foram salvas como Manga (lidas fora da biblioteca).
        let saved = Set(mangas.map(\.id))
        for (mangaId, list) in byManga where !saved.contains(mangaId) && list.contains(where: { $0.isRead || $0.isBookmarked || $0.lastPageRead > 0 }) {
            let title = history.first { $0.mangaId == mangaId }?.mangaTitle ?? mangaId
            let parts = mangaId.split(separator: ":", maxSplits: 1).map(String.init)
            backup.mangas.append(AppBackup.BackupManga(
                id: mangaId, sourceId: parts.first ?? "", remoteUrl: parts.count > 1 ? parts[1] : "", title: title,
                author: nil, artist: nil, desc: nil, genres: [], status: 0, coverUrl: history.first { $0.mangaId == mangaId }?.coverUrl,
                isFavorite: false, favoriteAt: nil, sourcesJSON: nil, preferredLanguage: nil, categoryIds: [], readingMode: nil,
                orientation: nil, chapterFlags: 0, excludedScanlators: [], preferredSourceId: nil, notes: "", customCover: nil,
                chapters: list.map(Self.backupChapter)
            ))
        }
        backup.categories = ((try? context.fetch(FetchDescriptor<MangaCategory>())) ?? []).map {
            AppBackup.BackupCategory(id: $0.id, name: $0.name, order: $0.order)
        }
        backup.history = history.map {
            AppBackup.BackupHistory(
                mangaId: $0.mangaId, chapterId: $0.chapterId, mangaTitle: $0.mangaTitle, chapterName: $0.chapterName,
                coverUrl: $0.coverUrl, readAt: $0.readAt, pageNumber: $0.pageNumber, totalPages: $0.totalPages,
                sourceId: $0.sourceId, chapterRemoteUrl: $0.chapterRemoteUrl, mangaRemoteUrl: $0.mangaRemoteUrl, timeRead: $0.timeRead
            )
        }
        backup.tracks = ((try? context.fetch(FetchDescriptor<TrackRecord>())) ?? []).map {
            AppBackup.BackupTrack(
                mangaId: $0.mangaId, trackerId: $0.trackerId, remoteId: $0.remoteId, title: $0.title, status: $0.status,
                score: $0.score, lastChapterRead: $0.lastChapterRead, totalChapters: $0.totalChapters,
                startDate: $0.startDate, finishDate: $0.finishDate, remoteUrl: $0.remoteUrl
            )
        }
        for (key, value) in defaults.dictionaryRepresentation() where preferencePrefixes.contains(where: key.hasPrefix) {
            if let pref = BackupPreference(value) { backup.preferences[key] = pref }
        }
        return backup
    }

    private static func backupChapter(_ c: Chapter) -> AppBackup.BackupChapter {
        AppBackup.BackupChapter(
            remoteUrl: c.remoteUrl, name: c.name, scanlator: c.scanlator, chapterNumber: c.chapterNumber,
            uploadDate: c.uploadDate, orderIndex: c.orderIndex, sourceId: c.sourceId, language: c.language,
            mangaRemoteUrl: c.mangaRemoteUrl, isRead: c.isRead, isBookmarked: c.isBookmarked, lastPageRead: c.lastPageRead,
            totalPages: c.totalPages, lastReadDate: c.lastReadDate, dateFetch: c.dateFetch
        )
    }

    static func encode(_ backup: AppBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try Gzip.compress(encoder.encode(backup))
    }

    static func decode(_ data: Data) throws -> AppBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let raw = Gzip.isGzip(data) ? try Gzip.decompress(data) : data
        return try decoder.decode(AppBackup.self, from: raw)
    }

    static func fileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "MangaCademy_\(formatter.string(from: date)).mcbackup"
    }

    /// Cria o arquivo de backup numa pasta temporária (para compartilhar/exportar).
    static func writeBackupFile(context: ModelContext) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName())
        try encode(makeBackup(context: context)).write(to: url, options: .atomic)
        return url
    }

    /// Backup automático em Documentos/Backups (visível no app Arquivos), mantendo os mais recentes.
    @discardableResult
    static func writeAutomaticBackup(context: ModelContext) throws -> URL {
        let dir = backupsDirectory
        let url = dir.appendingPathComponent(fileName())
        try encode(makeBackup(context: context)).write(to: url, options: .atomic)
        BackupSettings.shared.lastAutomatic = Date()
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "mcbackup" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(max(BackupSettings.shared.keepCount, 1)) {
            try? FileManager.default.removeItem(at: old)
        }
        return url
    }

    /// Restaura mesclando com o que já existe (como o Mihon 0.21): fica o maior progresso,
    /// a data de adição mais antiga e a união das categorias.
    static func restore(_ backup: AppBackup, context: ModelContext, defaults: UserDefaults = .standard) -> RestoreSummary {
        var summary = RestoreSummary()
        // Categorias: casam pelo nome.
        var categoryMap: [String: String] = [:]
        var existingCategories = (try? context.fetch(FetchDescriptor<MangaCategory>())) ?? []
        for category in backup.categories.sorted(by: { $0.order < $1.order }) {
            if let match = existingCategories.first(where: { $0.id == category.id || $0.name.caseInsensitiveCompare(category.name) == .orderedSame }) {
                categoryMap[category.id] = match.id
            } else {
                let created = MangaCategory(id: category.id, name: category.name, order: (existingCategories.map(\.order).max() ?? -1) + 1)
                context.insert(created)
                existingCategories.append(created)
                categoryMap[category.id] = created.id
            }
        }

        for item in backup.mangas {
            let id = item.id
            var descriptor = FetchDescriptor<Manga>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            let manga: Manga
            if let existing = try? context.fetch(descriptor).first {
                manga = existing
                summary.merged += 1
                if item.isFavorite && !existing.isFavorite {
                    existing.isFavorite = true
                    existing.favoriteAt = item.favoriteAt ?? Date()
                } else if let date = item.favoriteAt, let current = existing.favoriteAt, date < current {
                    existing.favoriteAt = date
                }
                if existing.notes.isEmpty { existing.notes = item.notes }
                existing.categoryIds = Array(Set(existing.categoryIds).union(item.categoryIds.compactMap { categoryMap[$0] }))
                if existing.sourcesJSON == nil { existing.sourcesJSON = item.sourcesJSON }
            } else {
                manga = Manga(
                    sourceId: item.sourceId, remoteUrl: item.remoteUrl, title: item.title, author: item.author,
                    artist: item.artist, desc: item.desc, genres: item.genres, status: item.status,
                    coverUrl: item.coverUrl, isFavorite: item.isFavorite
                )
                manga.favoriteAt = item.favoriteAt
                manga.sourcesJSON = item.sourcesJSON
                manga.preferredLanguage = item.preferredLanguage
                manga.categoryIds = item.categoryIds.compactMap { categoryMap[$0] }
                manga.readingMode = item.readingMode
                manga.orientation = item.orientation
                manga.chapterFlags = item.chapterFlags
                manga.excludedScanlators = item.excludedScanlators
                manga.preferredSourceId = item.preferredSourceId
                manga.notes = item.notes
                if let cover = item.customCover { manga.customCoverPath = CustomCoverStore.save(cover) }
                context.insert(manga)
                summary.added += 1
            }
            if SourceManager.shared.getSource(id: item.sourceId) == nil { summary.unavailableSources.insert(item.sourceId) }
            summary.chapters += mergeChapters(item.chapters, into: manga, context: context)
            ChapterStore.refreshUnreadCount(manga: manga, context: context)
            ChapterStore.refreshStats(manga: manga, records: ChapterStore.records(mangaId: manga.id, context: context))
        }

        for entry in backup.history {
            let chapterId = entry.chapterId
            var descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.id == chapterId })
            descriptor.fetchLimit = 1
            if let existing = try? context.fetch(descriptor).first {
                if entry.readAt > existing.readAt {
                    existing.readAt = entry.readAt
                    existing.pageNumber = entry.pageNumber
                    existing.totalPages = entry.totalPages
                }
                existing.timeRead = max(existing.timeRead, entry.timeRead)
            } else {
                context.insert(HistoryEntry(
                    mangaId: entry.mangaId, chapterId: entry.chapterId, mangaTitle: entry.mangaTitle,
                    chapterName: entry.chapterName, coverUrl: entry.coverUrl, readAt: entry.readAt,
                    pageNumber: entry.pageNumber, totalPages: entry.totalPages, sourceId: entry.sourceId,
                    chapterRemoteUrl: entry.chapterRemoteUrl, mangaRemoteUrl: entry.mangaRemoteUrl
                ))
                if let inserted = try? context.fetch(descriptor).first { inserted.timeRead = entry.timeRead }
            }
        }

        for track in backup.tracks {
            let id = "\(track.mangaId)|\(track.trackerId)"
            var descriptor = FetchDescriptor<TrackRecord>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            let record = (try? context.fetch(descriptor).first) ?? {
                let created = TrackRecord(mangaId: track.mangaId, trackerId: track.trackerId, remoteId: track.remoteId, title: track.title)
                context.insert(created)
                return created
            }()
            record.status = track.status
            record.score = track.score
            record.lastChapterRead = max(record.lastChapterRead, track.lastChapterRead)
            record.totalChapters = track.totalChapters
            record.startDate = record.startDate ?? track.startDate
            record.finishDate = record.finishDate ?? track.finishDate
            record.remoteUrl = track.remoteUrl
        }

        for (key, pref) in backup.preferences where preferencePrefixes.contains(where: key.hasPrefix) {
            defaults.set(pref.value, forKey: key)
        }
        try? context.save()
        return summary
    }

    /// Junta capítulos do backup com os salvos. Devolve quantos foram tocados.
    private static func mergeChapters(_ chapters: [AppBackup.BackupChapter], into manga: Manga, context: ModelContext) -> Int {
        let existing = ChapterStore.records(mangaId: manga.id, context: context)
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for item in chapters {
            let id = Chapter.storageId(mangaId: manga.id, sourceId: item.sourceId, remoteUrl: item.remoteUrl)
            let record: Chapter
            if let found = byId[id] {
                record = found
            } else {
                record = Chapter(
                    mangaId: manga.id, remoteUrl: item.remoteUrl, name: item.name, chapterNumber: item.chapterNumber,
                    orderIndex: item.orderIndex, scanlator: item.scanlator, uploadDate: item.uploadDate,
                    sourceId: item.sourceId, language: item.language, mangaRemoteUrl: item.mangaRemoteUrl
                )
                record.dateFetch = item.dateFetch
                record.manga = manga
                context.insert(record)
                byId[id] = record
            }
            record.isRead = record.isRead || item.isRead
            record.isBookmarked = record.isBookmarked || item.isBookmarked
            if item.lastPageRead > record.lastPageRead {
                record.lastPageRead = item.lastPageRead
                record.totalPages = max(record.totalPages, item.totalPages)
            }
            if let date = item.lastReadDate, date > (record.lastReadDate ?? .distantPast) { record.lastReadDate = date }
            if let fetched = item.dateFetch, record.dateFetch == nil || fetched < record.dateFetch! { record.dateFetch = fetched }
        }
        return chapters.count
    }

    // MARK: - CSV

    /// Título, autor, fontes e status das obras da biblioteca.
    static func csv(context: ModelContext) -> String {
        let mangas = ((try? context.fetch(FetchDescriptor<Manga>(predicate: #Predicate { $0.isFavorite == true }))) ?? [])
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        func field(_ value: String?) -> String {
            let text = value ?? ""
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let statuses = ["Desconhecido", "Em lançamento", "Completo", "Cancelado", "Em hiato"]
        var lines = ["Título,Autor,Artista,Fontes,Status,Não lidos"]
        for manga in mangas {
            let sources = UnifiedWork.refs(fromJSON: manga.sourcesJSON).map(\.sourceName)
            let names = sources.isEmpty ? [SourceManager.shared.sourceName(id: manga.sourceId)] : sources
            lines.append([
                field(manga.title), field(manga.author), field(manga.artist), field(names.joined(separator: "; ")),
                field(statuses.indices.contains(manga.status) ? statuses[manga.status] : statuses[0]), "\(manga.unreadCount)",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Backup do Mihon (.tachibk)

/// Lê o `.tachibk` do Mihon/Tachiyomi: protobuf (kotlinx.serialization) comprimido com gzip.
/// Os IDs de fonte do Mihon são os mesmos do índice Keiyoushi (`ky-<id>`).
enum MihonBackupImporter {
    struct Manga {
        var source: Int64 = 0
        var url = ""
        var title = ""
        var artist: String?
        var author: String?
        var description: String?
        var genres: [String] = []
        var status = 0
        var thumbnailUrl: String?
        var dateAdded: Int64 = 0
        var chapters: [Chapter] = []
        var categories: [Int64] = []
        var tracking: [Tracking] = []
        var favorite = true
        var history: [History] = []
        var excludedScanlators: [String] = []
        var notes = ""
    }

    struct Chapter {
        var url = ""
        var name = ""
        var scanlator: String?
        var read = false
        var bookmark = false
        var lastPageRead: Int64 = 0
        var dateFetch: Int64 = 0
        var dateUpload: Int64 = 0
        var chapterNumber: Float = -1
        var sourceOrder: Int64 = 0
    }

    struct Category {
        var name = ""
        var order: Int64 = 0
        var id: Int64 = 0
    }

    struct History {
        var url = ""
        var lastRead: Int64 = 0
        var readDuration: Int64 = 0
    }

    struct Tracking {
        var syncId = 0
        var trackingUrl = ""
        var title = ""
        var lastChapterRead: Float = 0
        var totalChapters = 0
        var score: Float = 0
        var status = 0
        var startedReadingDate: Int64 = 0
        var finishedReadingDate: Int64 = 0
        var mediaId: Int64 = 0
    }

    struct Backup {
        var mangas: [Manga] = []
        var categories: [Category] = []
        var sourceNames: [Int64: String] = [:]
    }

    static func parse(_ data: Data) throws -> Backup {
        let raw = Gzip.isGzip(data) ? try Gzip.decompress(data) : data
        var backup = Backup()
        var reader = ProtoReader(raw)
        while let (field, value) = try reader.next() {
            switch (field, value) {
            case (1, .bytes(let bytes)): backup.mangas.append(try parseManga(bytes))
            case (2, .bytes(let bytes)): backup.categories.append(try parseCategory(bytes))
            case (101, .bytes(let bytes)):
                var r = ProtoReader(bytes)
                var name = "", id: Int64 = 0
                while let (f, v) = try r.next() {
                    if f == 1, case .bytes(let b) = v { name = String(decoding: b, as: UTF8.self) }
                    if f == 2 { id = v.int64 }
                }
                backup.sourceNames[id] = name
            default: break
            }
        }
        return backup
    }

    private static func string(_ value: ProtoValue) -> String {
        if case .bytes(let b) = value { return String(decoding: b, as: UTF8.self) }
        return ""
    }

    private static func parseManga(_ data: Data) throws -> Manga {
        var m = Manga()
        var r = ProtoReader(data)
        while let (f, v) = try r.next() {
            switch f {
            case 1: m.source = v.int64
            case 2: m.url = string(v)
            case 3: m.title = string(v)
            case 4: m.artist = string(v)
            case 5: m.author = string(v)
            case 6: m.description = string(v)
            case 7: m.genres.append(string(v))
            case 8: m.status = Int(v.int64)
            case 9: m.thumbnailUrl = string(v)
            case 13: m.dateAdded = v.int64
            case 16: if case .bytes(let b) = v { m.chapters.append(try parseChapter(b)) }
            case 17: m.categories += v.packedVarints
            case 18: if case .bytes(let b) = v { m.tracking.append(try parseTracking(b)) }
            case 100: m.favorite = v.int64 != 0
            case 104: if case .bytes(let b) = v { m.history.append(try parseHistory(b)) }
            case 108: m.excludedScanlators.append(string(v))
            case 110: m.notes = string(v)
            default: break
            }
        }
        return m
    }

    private static func parseChapter(_ data: Data) throws -> Chapter {
        var c = Chapter()
        var r = ProtoReader(data)
        while let (f, v) = try r.next() {
            switch f {
            case 1: c.url = string(v)
            case 2: c.name = string(v)
            case 3: c.scanlator = string(v)
            case 4: c.read = v.int64 != 0
            case 5: c.bookmark = v.int64 != 0
            case 6: c.lastPageRead = v.int64
            case 7: c.dateFetch = v.int64
            case 8: c.dateUpload = v.int64
            case 9: c.chapterNumber = v.float
            case 10: c.sourceOrder = v.int64
            default: break
            }
        }
        return c
    }

    private static func parseCategory(_ data: Data) throws -> Category {
        var c = Category()
        var r = ProtoReader(data)
        while let (f, v) = try r.next() {
            switch f {
            case 1: c.name = string(v)
            case 2: c.order = v.int64
            case 3: c.id = v.int64
            default: break
            }
        }
        return c
    }

    private static func parseHistory(_ data: Data) throws -> History {
        var h = History()
        var r = ProtoReader(data)
        while let (f, v) = try r.next() {
            switch f {
            case 1: h.url = string(v)
            case 2: h.lastRead = v.int64
            case 3: h.readDuration = v.int64
            default: break
            }
        }
        return h
    }

    private static func parseTracking(_ data: Data) throws -> Tracking {
        var t = Tracking()
        var r = ProtoReader(data)
        while let (f, v) = try r.next() {
            switch f {
            case 1: t.syncId = Int(v.int64)
            case 3: if t.mediaId == 0 { t.mediaId = v.int64 }
            case 4: t.trackingUrl = string(v)
            case 5: t.title = string(v)
            case 6: t.lastChapterRead = v.float
            case 7: t.totalChapters = Int(v.int64)
            case 8: t.score = v.float
            case 9: t.status = Int(v.int64)
            case 10: t.startedReadingDate = v.int64
            case 11: t.finishedReadingDate = v.int64
            case 100: t.mediaId = v.int64
            default: break
            }
        }
        return t
    }

    /// Rastreadores do Mihon (syncId) → ids do app.
    static let trackerIds: [Int: String] = [1: "myanimelist", 2: "anilist", 3: "kitsu", 4: "shikimori", 5: "bangumi", 7: "mangaupdates"]

    /// Converte para o formato do app.
    @MainActor
    static func convert(_ backup: Backup) -> AppBackup {
        var result = AppBackup()
        let categories = backup.categories.sorted { $0.order < $1.order }
        result.categories = categories.enumerated().map { index, category in
            AppBackup.BackupCategory(id: "mihon-\(category.order)-\(category.name)", name: category.name, order: index)
        }
        func categoryId(_ value: Int64) -> String? {
            // Versões antigas guardam a ordem da categoria; as novas, o id.
            let match = categories.first { $0.order == value } ?? categories.first { $0.id == value }
            return match.map { "mihon-\($0.order)-\($0.name)" }
        }
        func date(_ millis: Int64) -> Date? { millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1000) : nil }

        for manga in backup.mangas {
            let (sourceId, mangaUrl) = mapSource(manga.source, url: manga.url, name: backup.sourceNames[manga.source])
            let language = SourceManager.shared.getSource(id: sourceId).map { $0.language == "all" ? nil : $0.language } ?? nil
            let mangaId = "\(sourceId):\(mangaUrl)"
            let chapters = manga.chapters.map { chapter -> AppBackup.BackupChapter in
                let url = sourceId == "mangadex" ? mangaDexId(chapter.url) : chapter.url
                return AppBackup.BackupChapter(
                    remoteUrl: url, name: chapter.name, scanlator: chapter.scanlator?.isEmpty == true ? nil : chapter.scanlator,
                    chapterNumber: Double(chapter.chapterNumber), uploadDate: date(chapter.dateUpload),
                    orderIndex: Int(chapter.sourceOrder), sourceId: sourceId, language: language, mangaRemoteUrl: mangaUrl,
                    isRead: chapter.read, isBookmarked: chapter.bookmark,
                    // No Mihon a página é contada de 0.
                    lastPageRead: chapter.read ? 0 : (chapter.lastPageRead > 0 ? Int(chapter.lastPageRead) + 1 : 0),
                    totalPages: 0, lastReadDate: nil, dateFetch: date(chapter.dateFetch) ?? date(manga.dateAdded)
                )
            }
            let ref = WorkSourceRef(
                sourceId: sourceId, sourceName: backup.sourceNames[manga.source] ?? SourceManager.shared.sourceName(id: sourceId),
                remoteUrl: mangaUrl, title: manga.title, coverUrl: manga.thumbnailUrl, languages: language.map { [$0] } ?? []
            )
            result.mangas.append(AppBackup.BackupManga(
                id: mangaId, sourceId: sourceId, remoteUrl: mangaUrl, title: manga.title, author: manga.author,
                artist: manga.artist, desc: manga.description, genres: manga.genres, status: manga.status,
                coverUrl: manga.thumbnailUrl, isFavorite: manga.favorite, favoriteAt: date(manga.dateAdded),
                sourcesJSON: (try? JSONEncoder().encode([ref])).flatMap { String(data: $0, encoding: .utf8) },
                preferredLanguage: language, categoryIds: manga.categories.compactMap(categoryId), readingMode: nil,
                orientation: nil, chapterFlags: 0, excludedScanlators: manga.excludedScanlators, preferredSourceId: nil,
                notes: manga.notes, customCover: nil, chapters: chapters
            ))
            for entry in manga.history {
                guard let chapter = chapters.first(where: { $0.remoteUrl == (sourceId == "mangadex" ? mangaDexId(entry.url) : entry.url) }),
                      let readAt = date(entry.lastRead) else { continue }
                result.history.append(AppBackup.BackupHistory(
                    mangaId: mangaId, chapterId: storageId(mangaId, sourceId, chapter.remoteUrl), mangaTitle: manga.title,
                    chapterName: chapter.name, coverUrl: manga.thumbnailUrl, readAt: readAt,
                    pageNumber: max(chapter.lastPageRead, 1), totalPages: 0, sourceId: sourceId,
                    chapterRemoteUrl: chapter.remoteUrl, mangaRemoteUrl: mangaUrl, timeRead: Double(entry.readDuration) / 1000
                ))
            }
            for track in manga.tracking {
                guard let trackerId = trackerIds[track.syncId] else { continue }
                result.tracks.append(AppBackup.BackupTrack(
                    mangaId: mangaId, trackerId: trackerId, remoteId: String(track.mediaId), title: track.title,
                    status: track.status, score: Double(track.score), lastChapterRead: Double(track.lastChapterRead),
                    totalChapters: track.totalChapters, startDate: date(track.startedReadingDate),
                    finishDate: date(track.finishedReadingDate), remoteUrl: track.trackingUrl.isEmpty ? nil : track.trackingUrl
                ))
            }
        }
        return result
    }

    /// `Chapter` aqui é o tipo do Mihon; o id salvo vem do modelo do app.
    private static func storageId(_ mangaId: String, _ sourceId: String, _ url: String) -> String {
        SchemaV3.Chapter.storageId(mangaId: mangaId, sourceId: sourceId, remoteUrl: url)
    }

    /// Fonte do app para um id do Mihon. MangaDex tem um id por idioma no Mihon e um só aqui.
    @MainActor
    static func mapSource(_ id: Int64, url: String, name: String?) -> (String, String) {
        let keiyoushi = "ky-\(id)"
        if SourceManager.shared.getSource(id: keiyoushi) != nil { return (keiyoushi, url) }
        if name?.localizedCaseInsensitiveContains("mangadex") == true { return ("mangadex", mangaDexId(url)) }
        return (keiyoushi, url)
    }

    /// "/manga/<uuid>" ou "/chapter/<uuid>" → "<uuid>".
    static func mangaDexId(_ url: String) -> String {
        url.split(separator: "/").last.map(String.init) ?? url
    }
}

// MARK: - Protobuf mínimo

enum ProtoValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(Data)

    var int64: Int64 {
        switch self {
        case .varint(let v): return Int64(bitPattern: v)
        case .fixed64(let v): return Int64(bitPattern: v)
        case .fixed32(let v): return Int64(Int32(bitPattern: v))
        case .bytes: return 0
        }
    }

    var float: Float {
        if case .fixed32(let v) = self { return Float(bitPattern: v) }
        return Float(int64)
    }

    /// Lista de números: um por campo ou empacotada num campo só.
    var packedVarints: [Int64] {
        guard case .bytes(let data) = self else { return [int64] }
        var reader = ProtoReader(data)
        var values: [Int64] = []
        while let value = try? reader.readVarint() { values.append(Int64(bitPattern: value)) }
        return values
    }
}

struct ProtoReader {
    enum Failure: Error { case truncated, badWireType(Int) }

    private let data: [UInt8]
    private var index = 0

    init(_ data: Data) { self.data = [UInt8](data) }

    var isAtEnd: Bool { index >= data.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < data.count, shift < 64 else { throw Failure.truncated }
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    /// Próximo campo, ou nil no fim.
    mutating func next() throws -> (Int, ProtoValue)? {
        guard !isAtEnd else { return nil }
        let key = try readVarint()
        let field = Int(key >> 3)
        switch Int(key & 7) {
        case 0: return (field, .varint(try readVarint()))
        case 1:
            guard index + 8 <= data.count else { throw Failure.truncated }
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(data[index + i]) << (8 * UInt64(i)) }
            index += 8
            return (field, .fixed64(value))
        case 2:
            let length = Int(try readVarint())
            guard length >= 0, index + length <= data.count else { throw Failure.truncated }
            let bytes = Data(data[index..<(index + length)])
            index += length
            return (field, .bytes(bytes))
        case 5:
            guard index + 4 <= data.count else { throw Failure.truncated }
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(data[index + i]) << (8 * UInt32(i)) }
            index += 4
            return (field, .fixed32(value))
        case let type:
            throw Failure.badWireType(type)
        }
    }
}

// MARK: - Gzip

/// Gzip com o deflate do sistema (`NSData.compressed(using: .zlib)` é deflate puro).
enum Gzip {
    enum Failure: Error { case invalid }

    static func isGzip(_ data: Data) -> Bool {
        data.count > 18 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(deflated)
        var crc = CRC32.checksum(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard isGzip(data), bytes[2] == 8 else { throw Failure.invalid }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard index + 2 <= bytes.count else { throw Failure.invalid }
            index += 2 + Int(bytes[index]) | Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 { while index < bytes.count && bytes[index] != 0 { index += 1 }; index += 1 } // FNAME
        if flags & 0x10 != 0 { while index < bytes.count && bytes[index] != 0 { index += 1 }; index += 1 } // FCOMMENT
        if flags & 0x02 != 0 { index += 2 } // FHCRC
        guard index < bytes.count - 8 else { throw Failure.invalid }
        let body = Data(bytes[index..<(bytes.count - 8)])
        return try (body as NSData).decompressed(using: .zlib) as Data
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

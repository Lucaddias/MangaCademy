import Foundation
import SwiftData

/// Estado salvo dos capítulos (`Chapter` do SwiftData): lido, marcador, página, lista das obras
/// da biblioteca e contador de não lidos.
@MainActor
enum ChapterStore {
    // MARK: - Registro de um capítulo

    /// Registro salvo do capítulo, ou nil se ele nunca foi lido/marcado/sincronizado.
    static func record(for chapter: SourceChapterItem, mangaId: String, context: ModelContext) -> Chapter? {
        let id = Chapter.storageId(mangaId: mangaId, sourceId: chapter.sourceId, remoteUrl: chapter.remoteUrl)
        var descriptor = FetchDescriptor<Chapter>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Registro do capítulo, criado se ainda não existir.
    static func ensureRecord(for chapter: SourceChapterItem, mangaId: String, context: ModelContext) -> Chapter {
        if let existing = record(for: chapter, mangaId: mangaId, context: context) {
            return existing
        }
        let record = Chapter(
            mangaId: mangaId,
            remoteUrl: chapter.remoteUrl,
            name: chapter.name,
            chapterNumber: chapter.chapterNumber,
            orderIndex: chapter.orderIndex,
            scanlator: chapter.scanlator,
            uploadDate: chapter.uploadDate,
            sourceId: chapter.sourceId,
            language: chapter.language,
            mangaRemoteUrl: chapter.mangaRemoteUrl
        )
        context.insert(record)
        return record
    }

    // MARK: - Ações

    /// Marca como lido/não lido. Ao desmarcar, desmarca também o mesmo capítulo vindo de outras
    /// fontes (mesmo idioma e número), senão ele continuaria aparecendo como lido.
    static func setRead(_ read: Bool, chapter: SourceChapterItem, mangaId: String, context: ModelContext) {
        let record = ensureRecord(for: chapter, mangaId: mangaId, context: context)
        record.isRead = read
        if read {
            record.lastReadDate = Date()
        } else {
            let key = progressKey(language: chapter.language, chapterNumber: chapter.chapterNumber, name: chapter.name)
            for other in records(mangaId: mangaId, context: context) where other.isRead && progressKey(other) == key {
                other.isRead = false
            }
        }
        refreshUnreadCount(mangaId: mangaId, context: context)
        try? context.save()
    }

    static func setBookmarked(_ bookmarked: Bool, chapter: SourceChapterItem, mangaId: String, context: ModelContext) {
        ensureRecord(for: chapter, mangaId: mangaId, context: context).isBookmarked = bookmarked
        try? context.save()
    }

    /// Guarda a página onde a leitura está (contando de 1).
    static func saveProgress(page: Int, totalPages: Int, chapter: SourceChapterItem, mangaId: String, context: ModelContext) {
        let record = ensureRecord(for: chapter, mangaId: mangaId, context: context)
        record.lastPageRead = page
        record.totalPages = totalPages
        record.lastReadDate = Date()
        try? context.save()
    }

    // MARK: - Lista das obras da biblioteca

    /// Salva a lista atual de capítulos (já agrupada e sem repetição) de uma obra da biblioteca.
    ///
    /// Capítulos que entram pela primeira vez ganham `dateFetch = now`, o que os torna novidades
    /// (`dateFetch > favoriteAt`). Não são novidade: a primeira lista salva da obra e um capítulo
    /// cujo número já existia no mesmo idioma vindo de outra fonte.
    static func sync(_ chaptersByLanguage: [String: [SourceChapterItem]], manga: Manga, context: ModelContext, now: Date = Date()) {
        let existing = records(mangaId: manga.id, context: context)
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var knownKeys = Set(existing.map(progressKey))
        let isFirstSync = !existing.contains { $0.dateFetch != nil }
        let baseline = min(manga.favoriteAt ?? now, now)

        for list in chaptersByLanguage.values {
            for item in list {
                let id = Chapter.storageId(mangaId: manga.id, sourceId: item.sourceId, remoteUrl: item.remoteUrl)
                let key = progressKey(item)
                let record: Chapter
                if let found = byId[id] {
                    record = found
                    record.name = item.name
                    record.scanlator = item.scanlator
                    record.chapterNumber = item.chapterNumber
                    record.uploadDate = item.uploadDate
                    record.orderIndex = item.orderIndex
                    record.language = item.language
                    record.mangaRemoteUrl = item.mangaRemoteUrl
                    if record.dateFetch == nil { record.dateFetch = baseline }
                } else {
                    record = Chapter(
                        mangaId: manga.id,
                        remoteUrl: item.remoteUrl,
                        name: item.name,
                        chapterNumber: item.chapterNumber,
                        orderIndex: item.orderIndex,
                        scanlator: item.scanlator,
                        uploadDate: item.uploadDate,
                        sourceId: item.sourceId,
                        language: item.language,
                        mangaRemoteUrl: item.mangaRemoteUrl
                    )
                    record.dateFetch = isFirstSync || knownKeys.contains(key) ? baseline : now
                    context.insert(record)
                    byId[id] = record
                }
                if record.manga == nil { record.manga = manga }
                knownKeys.insert(key)
            }
        }
        refreshUnreadCount(manga: manga, context: context)
        try? context.save()
    }

    // MARK: - Não lidos

    /// Recalcula `Manga.unreadCount`, se a obra estiver salva.
    static func refreshUnreadCount(mangaId: String, context: ModelContext) {
        var descriptor = FetchDescriptor<Manga>(predicate: #Predicate { $0.id == mangaId })
        descriptor.fetchLimit = 1
        guard let manga = try? context.fetch(descriptor).first else { return }
        refreshUnreadCount(manga: manga, context: context)
    }

    static func refreshUnreadCount(manga: Manga, context: ModelContext) {
        let count = unreadCount(records(mangaId: manga.id, context: context), language: manga.preferredLanguage)
        if manga.unreadCount != count { manga.unreadCount = count }
    }

    /// Capítulos não lidos no idioma escolhido para a obra (sem a escolha, no idioma com mais
    /// capítulos). O mesmo número vindo de várias fontes conta uma vez, e conta como lido se
    /// qualquer uma delas foi lida.
    static func unreadCount(_ records: [Chapter], language: String?) -> Int {
        let language = language ?? mostCommonLanguage(records)
        var readByKey: [String: Bool] = [:]
        for record in records where (record.language ?? "all") == (language ?? "all") {
            let key = progressKey(record)
            readByKey[key] = (readByKey[key] ?? false) || record.isRead
        }
        return readByKey.values.filter { !$0 }.count
    }

    private static func mostCommonLanguage(_ records: [Chapter]) -> String? {
        var counts: [String: Int] = [:]
        for record in records { counts[record.language ?? "all", default: 0] += 1 }
        let best = counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
        return best == "all" ? nil : best
    }

    // MARK: - Chaves

    /// "Mesmo capítulo" para progresso: idioma + número (ou nome, sem número).
    nonisolated static func progressKey(language: String?, chapterNumber: Double, name: String) -> String {
        "\(language ?? "all")|\(SourceAggregator.dedupeKey(chapterNumber: chapterNumber, name: name))"
    }

    nonisolated static func progressKey(_ record: Chapter) -> String {
        progressKey(language: record.language, chapterNumber: record.chapterNumber, name: record.name)
    }

    nonisolated static func progressKey(_ item: SourceChapterItem) -> String {
        progressKey(language: item.language, chapterNumber: item.chapterNumber, name: item.name)
    }

    static func records(mangaId: String, context: ModelContext) -> [Chapter] {
        (try? context.fetch(FetchDescriptor<Chapter>(predicate: #Predicate { $0.mangaId == mangaId }))) ?? []
    }
}

/// Leitura rápida do estado salvo dos capítulos de uma obra, para a lista do detalhe.
struct ChapterProgress {
    private var byId: [String: Chapter] = [:]
    private var readKeys = Set<String>()
    let mangaId: String

    init(records: [Chapter], mangaId: String) {
        self.mangaId = mangaId
        for record in records {
            byId[record.id] = record
            if record.isRead { readKeys.insert(ChapterStore.progressKey(record)) }
        }
    }

    func record(_ chapter: SourceChapterItem) -> Chapter? {
        byId[Chapter.storageId(mangaId: mangaId, sourceId: chapter.sourceId, remoteUrl: chapter.remoteUrl)]
    }

    /// Lido nesta fonte ou o mesmo capítulo lido em outra fonte.
    func isRead(_ chapter: SourceChapterItem) -> Bool {
        record(chapter)?.isRead == true || readKeys.contains(ChapterStore.progressKey(chapter))
    }

    func isBookmarked(_ chapter: SourceChapterItem) -> Bool {
        record(chapter)?.isBookmarked == true
    }

    /// Página onde parou (contando de 1), se o capítulo foi aberto e não terminado.
    func pageInProgress(_ chapter: SourceChapterItem) -> Int? {
        guard let record = record(chapter), !isRead(chapter), record.lastPageRead > 0 else { return nil }
        return record.lastPageRead
    }

    var hasAnyRead: Bool { !readKeys.isEmpty }
}

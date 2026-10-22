import Foundation
import SwiftData

/// Monta o que o leitor precisa para reabrir um capítulo do histórico: a lista de capítulos do
/// mesmo idioma (para anterior/próximo) e a posição do capítulo nela.
@MainActor
enum HistoryResume {
    struct Resumed {
        let chapters: [SourceChapterItem]
        let index: Int
    }

    enum Failure: LocalizedError {
        case missingChapter
        case sourceUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .missingChapter: return "Este item do histórico é de uma versão antiga do app. Abra a obra para continuar."
            case .sourceUnavailable(let id): return "A fonte \(SourceManager.shared.sourceName(id: id)) não está disponível."
            }
        }
    }

    /// Capítulo do histórico, com o idioma salvo no registro do capítulo.
    static func chapter(for entry: HistoryEntry, context: ModelContext) -> SourceChapterItem? {
        let chapterId = entry.chapterId
        var descriptor = FetchDescriptor<Chapter>(predicate: #Predicate { $0.id == chapterId })
        descriptor.fetchLimit = 1
        let record = try? context.fetch(descriptor).first
        guard let sourceId = entry.sourceId ?? record?.sourceId,
              let remoteUrl = entry.chapterRemoteUrl ?? record?.remoteUrl,
              let mangaRemoteUrl = entry.mangaRemoteUrl ?? record?.mangaRemoteUrl else { return nil }
        return SourceChapterItem(
            remoteUrl: remoteUrl,
            name: record?.name ?? entry.chapterName,
            chapterNumber: record?.chapterNumber ?? -1,
            orderIndex: record?.orderIndex ?? 0,
            scanlator: record?.scanlator,
            uploadDate: record?.uploadDate,
            language: record?.language,
            sourceId: sourceId,
            mangaRemoteUrl: mangaRemoteUrl
        )
    }

    /// Obras da biblioteca usam a lista salva (sem rede); as outras consultam a fonte do capítulo.
    static func resume(_ entry: HistoryEntry, context: ModelContext) async throws -> Resumed {
        guard let target = chapter(for: entry, context: context) else { throw Failure.missingChapter }

        let saved = ChapterStore.records(mangaId: entry.mangaId, context: context)
            .filter { $0.dateFetch != nil }
            .map(ChapterStore.item(from:))
        var list: [SourceChapterItem]
        if !saved.isEmpty {
            list = saved
        } else {
            guard let source = SourceManager.shared.getSource(id: target.sourceId) else {
                throw Failure.sourceUnavailable(target.sourceId)
            }
            let (_, chapters) = try await source.fetchDetails(remoteUrl: target.mangaRemoteUrl)
            let ref = WorkSourceRef(
                sourceId: source.id,
                sourceName: source.name,
                remoteUrl: target.mangaRemoteUrl,
                title: entry.mangaTitle,
                coverUrl: entry.coverUrl,
                languages: []
            )
            list = WorkLoadState.normalize(chapters, ref: ref, sourceLanguage: source.language)
        }
        return arrange(list, around: target)
    }

    /// Lista do idioma do capítulo, sem repetição, garantindo que o próprio capítulo esteja nela
    /// (no lugar da versão de outra fonte com o mesmo número, se for o caso).
    static func arrange(_ chapters: [SourceChapterItem], around target: SourceChapterItem) -> Resumed {
        let byLanguage = SourceAggregator.shared.chaptersByLanguage(chapters)
        let language = target.language ?? byLanguage.keys.first(where: { key in
            byLanguage[key]?.contains(where: { $0.id == target.id }) == true
        }) ?? "all"
        var list = byLanguage[language] ?? []
        if let index = list.firstIndex(where: { $0.id == target.id }) {
            return Resumed(chapters: list, index: index)
        }
        let key = ChapterStore.progressKey(target)
        if let index = list.firstIndex(where: { ChapterStore.progressKey($0) == key }) {
            list[index] = target
            return Resumed(chapters: list, index: index)
        }
        // Capítulo sumiu da fonte: lê só ele.
        return Resumed(chapters: [target], index: 0)
    }
}

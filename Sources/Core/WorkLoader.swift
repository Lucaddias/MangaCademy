import Foundation

/// O que já se sabe de uma obra unificada depois de carregar parte (ou todas) as suas fontes.
/// Só dados, sem rede: o `WorkLoader` alimenta, e o detalhe, a atualização da biblioteca e os
/// downloads leem.
public struct WorkLoadState {
    public private(set) var work: UnifiedWork
    /// Capítulos de todas as fontes, já com fonte, obra e idioma preenchidos.
    public private(set) var chapters: [SourceChapterItem] = []
    public private(set) var failures: [String] = []
    private var details: [(language: String, detail: SourceMangaDetail)] = []

    public init(work: UnifiedWork) {
        self.work = work
    }

    /// Fontes que já responderam.
    public var loadedSourceCount: Int { details.count }

    public mutating func merge(ref: WorkSourceRef, altTitles: [String]) {
        work.merge(ref: ref, altTitles: altTitles)
    }

    /// Resultado de uma fonte. `sourceLanguage` é o idioma da fonte ("all" se for multi-idioma).
    public mutating func add(ref: WorkSourceRef, sourceLanguage: String, detail: SourceMangaDetail, chapters list: [SourceChapterItem]) {
        let normalized = Self.normalize(list, ref: ref, sourceLanguage: sourceLanguage)
        chapters += normalized
        work.addLanguages(Array(Set(normalized.compactMap(\.language))).sorted())
        details.append((sourceLanguage, detail))
        if work.coverUrl == nil, let cover = detail.coverUrl {
            work.coverUrl = cover
            work.coverSourceId = ref.sourceId
        }
    }

    public mutating func addFailure(_ message: String) {
        failures.append(message)
    }

    /// Completa nos capítulos a fonte, a obra e o idioma (quando a fonte não informa).
    public static func normalize(_ chapters: [SourceChapterItem], ref: WorkSourceRef, sourceLanguage: String) -> [SourceChapterItem] {
        let fallbackLanguage = sourceLanguage == "all" ? nil : sourceLanguage
        return chapters.map { item in
            var c = item
            if c.sourceId.isEmpty { c.sourceId = ref.sourceId }
            if c.mangaRemoteUrl.isEmpty { c.mangaRemoteUrl = ref.remoteUrl }
            if c.language == nil { c.language = fallbackLanguage }
            return c
        }
    }

    /// Capítulos agrupados por idioma, sem repetição.
    public var chaptersByLanguage: [String: [SourceChapterItem]] {
        SourceAggregator.shared.chaptersByLanguage(chapters)
    }

    /// Tags de todas as fontes, sem repetição (sem limite, para o filtro adulto ver todas).
    public var allGenres: [String] {
        var genres: [String] = []
        for entry in rankedDetails(filter: .all) {
            for genre in entry.genres where !genres.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) {
                genres.append(genre)
            }
        }
        return genres
    }

    /// Alguma fonte marcou a obra como conteúdo adulto.
    public var isAdult: Bool {
        work.isAdult || ContentFilter.isAdult(genres: allGenres)
    }

    /// Junta os dados das fontes: prefere a fonte no idioma do filtro e com sinopse,
    /// e completa autor, artista, status e tags com as outras.
    public func mergedDetail(filter: LanguageFilter) -> SourceMangaDetail? {
        let ranked = rankedDetails(filter: filter)
        guard let best = ranked.first else { return nil }
        var genres: [String] = []
        for entry in ranked {
            for genre in entry.genres where !genres.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) {
                genres.append(genre)
            }
        }
        return SourceMangaDetail(
            remoteUrl: best.remoteUrl,
            title: best.title,
            author: ranked.lazy.compactMap(\.author).first(where: { !$0.isEmpty }),
            artist: ranked.lazy.compactMap(\.artist).first(where: { !$0.isEmpty }),
            description: ranked.lazy.compactMap(\.description).first(where: { !$0.isEmpty }),
            genres: Array(genres.prefix(15)),
            status: ranked.first(where: { $0.status != 0 })?.status ?? 0,
            coverUrl: best.coverUrl
        )
    }

    private func rankedDetails(filter: LanguageFilter) -> [SourceMangaDetail] {
        details.enumerated().sorted { a, b in
            let la = filter.matches(a.element.language) || a.element.language == "all" ? 0 : 1
            let lb = filter.matches(b.element.language) || b.element.language == "all" ? 0 : 1
            if la != lb { return la < lb }
            let da = (a.element.detail.description?.isEmpty ?? true) ? 1 : 0
            let db = (b.element.detail.description?.isEmpty ?? true) ? 1 : 0
            if da != db { return da < db }
            return a.offset < b.offset
        }.map(\.element.detail)
    }
}

/// Carrega uma obra unificada em todas as fontes onde ela existe (sem UI).
/// Usado pelo detalhe da obra e, nas próximas fases, pela atualização da biblioteca e pelos downloads.
@MainActor
public final class WorkLoader {
    public private(set) var state: WorkLoadState
    /// Fontes sendo consultadas agora.
    public private(set) var pendingSources = 0
    /// Chamado a cada fonte que começa, responde ou falha.
    public var onUpdate: ((WorkLoader) -> Void)?

    private let filter: LanguageFilter
    /// Procura a obra também no MangaDex e no ComicK (desligado na atualização da biblioteca).
    private let lookupOtherLanguages: Bool
    private var loadedRefIds = Set<String>()
    private static let maxConcurrentSources = 6

    public init(work: UnifiedWork, filter: LanguageFilter, lookupOtherLanguages: Bool = true) {
        self.state = WorkLoadState(work: work)
        self.filter = filter
        self.lookupOtherLanguages = lookupOtherLanguages
    }

    /// Consulta todas as fontes da obra (as do idioma do filtro primeiro, no máximo 6 ao mesmo
    /// tempo) e procura a mesma obra no MangaDex e no ComicK para listar mais idiomas.
    public func load() async {
        let refs = state.work.refs.sorted { a, b in
            let la = SourceManager.shared.getSource(id: a.sourceId)?.language ?? "all"
            let lb = SourceManager.shared.getSource(id: b.sourceId)?.language ?? "all"
            return (filter.matches(la) ? 0 : 1) < (filter.matches(lb) ? 0 : 1)
        }
        await withTaskGroup(of: Void.self) { group in
            var pending = refs.makeIterator()
            if lookupOtherLanguages {
                group.addTask { await self.lookupMultiLanguage(sourceId: "mangadex") }
                group.addTask { await self.lookupMultiLanguage(sourceId: "comick") }
            }
            for _ in 0..<Self.maxConcurrentSources {
                guard let ref = pending.next() else { break }
                group.addTask { await self.loadRef(ref) }
            }
            while await group.next() != nil {
                if let ref = pending.next() {
                    group.addTask { await self.loadRef(ref) }
                }
            }
        }
    }

    private func loadRef(_ ref: WorkSourceRef) async {
        guard loadedRefIds.insert(ref.id).inserted else { return }
        guard let source = SourceManager.shared.getSource(id: ref.sourceId) else {
            state.addFailure("\(ref.sourceName): fonte indisponível")
            onUpdate?(self)
            return
        }
        pendingSources += 1
        onUpdate?(self)
        do {
            let (detail, chapters) = try await source.fetchDetails(remoteUrl: ref.remoteUrl)
            state.add(ref: ref, sourceLanguage: source.language, detail: detail, chapters: chapters)
        } catch {
            state.addFailure("\(ref.sourceName): \(error.localizedDescription)")
        }
        pendingSources -= 1
        onUpdate?(self)
    }

    /// Busca a obra pelo título numa fonte multi-idioma e só aceita se algum título coincidir.
    private func lookupMultiLanguage(sourceId: String) async {
        guard !state.work.refs.contains(where: { $0.sourceId == sourceId }),
              let source = SourceManager.shared.getSource(id: sourceId) else { return }
        let candidates = [state.work.title] + state.work.refs.map(\.title)
        var seenQueries = Set<String>()
        for query in candidates where seenQueries.insert(TitleKey.normalize(query)).inserted {
            guard query.count >= 3, let page = try? await source.search(query: query, page: 1) else { continue }
            if let match = page.items.first(where: { !TitleKey.keys(for: [$0.title] + $0.altTitles).isDisjoint(with: state.work.titleKeys) }) {
                let ref = WorkSourceRef(
                    sourceId: match.sourceId,
                    sourceName: source.name,
                    remoteUrl: match.remoteUrl,
                    title: match.title,
                    coverUrl: match.coverUrl,
                    languages: match.languages
                )
                state.merge(ref: ref, altTitles: match.altTitles)
                await loadRef(ref)
                return
            }
            if seenQueries.count >= 2 { return }
        }
    }
}

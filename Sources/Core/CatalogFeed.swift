import Foundation
import Observation

/// Catálogo infinito: consulta todas as fontes Keiyoushi do filtro de idioma em rodízio,
/// página por página, unificando as obras repetidas à medida que os resultados chegam.
/// Só termina quando todas as fontes não têm mais páginas.
///
/// Antes de aparecer, cada obra nova é verificada: títulos alternativos e tags (página da obra,
/// quando a listagem não traz) e a impressão digital da capa. Assim a mesma obra com título
/// traduzido entra unificada desde o início, e obras com tag adulta são escondidas.
///
/// Em "Recentes" a ordem é a do capítulo mais novo entre todas as fontes: a primeira página de
/// cada fonte é pedida logo de início e as listas são juntadas por data (`LatestMerge`).
@MainActor
@Observable
public final class CatalogFeed {
    public enum Mode: Equatable {
        case popular
        case latest
        case search(String)
    }

    // MARK: Estado observado pela interface

    public private(set) var works: [UnifiedWork] = []
    public private(set) var isExhausted = false
    public private(set) var inFlight = 0
    public private(set) var totalSources = 0
    public private(set) var finishedSources = 0
    public private(set) var failedSources = 0
    public private(set) var respondingSources = 0
    /// Obras aguardando verificação (duplicatas/tags) antes de aparecer.
    public private(set) var verifyingCount = 0
    /// Obras escondidas pelo filtro de tag adulta.
    public private(set) var blockedCount = 0
    public private(set) var mode: Mode = .popular
    public private(set) var filter: LanguageFilter = .all
    /// Fonte única escolhida no Explorar; `nil` = todas as fontes do filtro.
    public private(set) var sourceId: String?
    /// Tags escolhidas (chaves de `GenreTags`): só aparecem obras com todas elas.
    public private(set) var tagFilter: Set<String> = []
    /// Todos os gêneros fixos e depois as tags das obras já carregadas, das mais comuns para as menos comuns.
    public private(set) var availableTags = GenreTags.counts([], includeAllGenres: true)
    /// Obras carregadas antes do filtro de tags.
    public private(set) var loadedCount = 0

    public var isLoading: Bool { inFlight > 0 || verifyingCount > 0 }
    /// Diagnóstico: motivo de cada fusão sem título idêntico, por referência.
    public var fuzzyReasons: [String: String] { merger.fuzzyReasons }
    public var isInitialLoading: Bool { works.isEmpty && !isExhausted }

    // MARK: Paginação por fonte

    private final class Cursor {
        let source: MangaSource
        var nextPage = 1
        var seen = Set<String>()
        var failures = 0
        var produced = 0

        init(source: MangaSource) { self.source = source }
    }

    private struct Pending {
        let item: SourceMangaItem
        let source: MangaSource
        let key: String
    }

    private var merger = WorkMerger()
    private var queue: [Cursor] = []
    private var queueHead = 0
    private var generation = 0
    private var targetCount = 0
    private var includeNsfw = false
    private var blockAdult = true

    // MARK: Recentes

    private var latestMerge = LatestMerge()
    /// Fontes com mais páginas esperando a vez (só pedem a próxima quando ela pode ter algo mais novo).
    private var idleLatest: [String: Cursor] = [:]
    private var sourcesById: [String: MangaSource] = [:]
    /// Data usada na ordem de cada referência mostrada (obra unificada = a mais nova delas).
    private var latestSortDate: [String: Date] = [:]
    /// Item mais antigo já mostrado: o que chegar mais novo que ele entra na lista na hora.
    private var oldestShown: Date?

    // MARK: Verificação

    private var pending: [Pending] = []
    /// Itens com o mesmo título de um que já está em verificação esperam por ele
    /// (depois entram direto, sem abrir a página da obra de novo).
    private var waitingByKey: [String: [Pending]] = [:]
    private var waitingCount = 0
    private var verifyingKeys = Set<String>()
    private var enrichInFlight = 0
    private var enrichBySource: [String: Int] = [:]
    private var publishScheduled = false

    private let initialTarget = 60
    private let pageStep = 45
    private let prefetchDistance = 15
    private let maxConcurrent = 8
    private let maxConcurrentLatest = 12
    private let maxSearchPagesPerSource = 3
    private let maxEnrich = 16
    private let maxEnrichPerSource = 4
    private let metadataTimeout: Double = 12

    public init() {}

    /// Reinicia o feed (troca de filtro, modo, busca, fonte ou do filtro de conteúdo adulto).
    public func reset(filter: LanguageFilter, mode: Mode, includeNsfw: Bool, sourceId: String? = nil) {
        generation += 1
        self.filter = filter
        self.sourceId = sourceId
        self.mode = mode
        self.includeNsfw = includeNsfw
        blockAdult = Preferences.blockAdultTags
        merger = WorkMerger()
        works = []
        isExhausted = false
        inFlight = 0
        finishedSources = 0
        failedSources = 0
        respondingSources = 0
        verifyingCount = 0
        blockedCount = 0
        pending = []
        waitingByKey = [:]
        waitingCount = 0
        verifyingKeys = []
        enrichInFlight = 0
        enrichBySource = [:]
        publishScheduled = false
        targetCount = initialTarget
        latestMerge = LatestMerge()
        idleLatest = [:]
        latestSortDate = [:]
        oldestShown = nil
        availableTags = GenreTags.counts([], includeAllGenres: true)
        loadedCount = 0
        matchingCount = 0

        var sources = SourceHealth.prioritized(SourceManager.shared.catalogSources(for: filter, includeNsfw: includeNsfw))
        if let sourceId { sources = sources.filter { $0.id == sourceId } }
        sourcesById = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue = sources.map(Cursor.init)
        queueHead = 0
        totalSources = queue.count
        pump()
    }

    /// Chamado quando uma obra aparece na tela; pede mais páginas perto do fim da lista.
    public func onAppear(of work: UnifiedWork) {
        guard !isExhausted else { return }
        guard let index = works.lastIndex(where: { $0.id == work.id }) else { return }
        if index >= works.count - prefetchDistance {
            requestMore()
        }
    }

    /// Pede mais obras (rolagem chegou perto do fim ou o usuário tocou em "carregar mais").
    public func requestMore() {
        targetCount = max(targetCount, visibleCount + pageStep)
        pump()
    }

    /// Troca as tags sem recarregar: filtra o que já veio e busca mais até ter obras suficientes.
    public func setTagFilter(_ tags: Set<String>) {
        guard tags != tagFilter else { return }
        tagFilter = tags
        targetCount = initialTarget
        publish()
        pump()
    }

    public func retry() {
        reset(filter: filter, mode: mode, includeNsfw: includeNsfw)
    }

    // MARK: - Motor

    private var pendingCount: Int { queue.count - queueHead }
    private var unverifiedCount: Int { pending.count + enrichInFlight + waitingCount }
    /// Obras que já aparecem (ou vão aparecer na próxima publicação).
    /// Com tags escolhidas, só as que têm as tags (contadas na última publicação).
    private var visibleCount: Int {
        tagFilter.isEmpty ? merger.works.count - (blockAdult ? merger.adultCount : 0) : matchingCount
    }
    private var matchingCount = 0

    private var needsMore: Bool { visibleCount + unverifiedCount < targetCount }

    private func pump() {
        if mode == .latest {
            pumpLatest()
            return
        }
        // Itens ainda em verificação contam para a meta: evita baixar páginas demais de uma vez
        while inFlight < maxConcurrent, needsMore, let cursor = dequeue() {
            launch(cursor)
        }
        verifyingCount = unverifiedCount
        if inFlight == 0 && pendingCount == 0 && unverifiedCount == 0 {
            isExhausted = true
        }
    }

    private func dequeue() -> Cursor? {
        guard queueHead < queue.count else { return nil }
        let cursor = queue[queueHead]
        queueHead += 1
        // Compacta a fila de tempos em tempos
        if queueHead > 256 {
            queue.removeFirst(queueHead)
            queueHead = 0
        }
        return cursor
    }

    /// "Recentes": primeira página de todas as fontes, depois só o que pode ser mais novo.
    private func pumpLatest() {
        while inFlight < maxConcurrentLatest, let cursor = dequeue() {
            launch(cursor)
        }
        drainLatest()
        pumpEnrichment()
        while inFlight < maxConcurrentLatest, let id = nextLatestSource(), let cursor = idleLatest.removeValue(forKey: id) {
            launch(cursor)
        }
        verifyingCount = unverifiedCount
        if inFlight == 0 && pendingCount == 0 && idleLatest.isEmpty && latestMerge.buffer.isEmpty && unverifiedCount == 0 {
            isExhausted = true
        }
    }

    /// Mostra os itens seguros: até a meta e, depois dela, os mais novos que algo já mostrado.
    private func drainLatest() {
        while true {
            let next: LatestMerge.Entry?
            if needsMore {
                next = latestMerge.popSafe()
            } else if let oldestShown {
                next = latestMerge.popSafe(newerThan: oldestShown)
            } else {
                next = nil
            }
            guard let entry = next else { break }
            guard let source = sourcesById[entry.sourceId] else { continue }
            latestSortDate[entry.item.id] = entry.sortDate
            oldestShown = min(oldestShown ?? entry.sortDate, entry.sortDate)
            ingest(entry.item, source: source)
        }
    }

    /// Fonte cuja próxima página deve vir agora: a que pode ter algo mais novo do que o próximo
    /// item da fila (quando falta obra) ou do que algo já mostrado.
    private func nextLatestSource() -> String? {
        if needsMore {
            return latestMerge.sourceToFetch(among: idleLatest.keys, newerThan: latestMerge.buffer.first?.sortDate)
        }
        guard let oldestShown else { return nil }
        return latestMerge.sourceToFetch(among: idleLatest.keys, newerThan: oldestShown)
    }

    private func launch(_ cursor: Cursor) {
        inFlight += 1
        let gen = generation
        let page = cursor.nextPage
        let mode = self.mode
        let source = cursor.source
        Task {
            let result: Result<SourceMangaPage, Error>
            do {
                let pageResult: SourceMangaPage
                switch mode {
                case .popular: pageResult = try await source.fetchPopular(page: page)
                case .latest: pageResult = try await source.fetchLatest(page: page)
                case .search(let query): pageResult = try await source.search(query: query, page: page)
                }
                result = .success(pageResult)
            } catch {
                result = .failure(error)
            }
            self.finish(cursor, page: page, result: result, generation: gen)
        }
    }

    private func finish(_ cursor: Cursor, page: Int, result: Result<SourceMangaPage, Error>, generation gen: Int) {
        guard gen == generation else { return }
        inFlight -= 1

        var keepGoing = false
        switch result {
        case .success(let pageResult):
            let fresh = pageResult.items.filter { cursor.seen.insert($0.id).inserted }
            if page == 1 && !fresh.isEmpty { respondingSources += 1 }
            if !fresh.isEmpty {
                cursor.produced += fresh.count
                // Em "Recentes" os itens esperam a vez no merge por data
                if mode != .latest {
                    for item in fresh where isRelevant(item) {
                        ingest(item, source: cursor.source)
                    }
                }
                SourceHealth.recordSuccess(cursor.source.id)
            }
            // Página sem itens novos = a fonte repetiu a última página: acabou
            keepGoing = pageResult.hasNextPage && !fresh.isEmpty
            if case .search = mode, page >= maxSearchPagesPerSource { keepGoing = false }
            cursor.nextPage = page + 1
            if mode == .latest {
                latestMerge.add(fresh, from: cursor.source.id, hasMore: keepGoing, keep: isRelevant)
            }
        case .failure:
            cursor.failures += 1
            SourceHealth.recordFailure(cursor.source.id)
            // Uma nova tentativa para falhas no meio da paginação; na primeira página desiste logo
            keepGoing = page > 1 && cursor.failures < 2
            if !keepGoing { failedSources += 1 }
        }

        if keepGoing {
            if mode == .latest {
                idleLatest[cursor.source.id] = cursor
            } else {
                queue.append(cursor)
            }
        } else {
            finishedSources += 1
            if mode == .latest { latestMerge.end(cursor.source.id) }
        }
        schedulePublish()
        pumpEnrichment()
        pump()
    }

    /// Filtro final por idioma (fontes multi-idioma podem trazer obras sem o idioma pedido).
    private func isRelevant(_ item: SourceMangaItem) -> Bool {
        guard filter != .all else { return true }
        if item.languages.isEmpty { return true }
        return item.languages.contains(where: filter.matches)
    }

    // MARK: - Verificação antes de mostrar

    private func ingest(_ item: SourceMangaItem, source: MangaSource) {
        guard !merger.contains(refId: item.id) else { return }
        let adultSource = SourceManager.shared.isNsfw(source.id)
        // Mesmo título de uma obra já conhecida: funde direto
        if merger.exactMatch(for: item) != nil {
            merger.add(item, sourceName: source.name, adultSource: adultSource)
            return
        }
        // Já verificada antes (cache de 14 dias)
        if let cached = MetadataCache.shared.entry(for: item.id) {
            var enriched = item
            enriched.altTitles = Self.unique(item.altTitles + cached.altTitles)
            enriched.genres = Self.unique(item.genres + cached.genres)
            if enriched.coverUrl == nil { enriched.coverUrl = cached.coverUrl }
            let hash = cached.coverUrl == enriched.coverUrl ? cached.hash : nil
            merger.add(enriched, sourceName: source.name, coverHash: hash, adultSource: adultSource)
            return
        }
        let key = TitleKey.normalize(item.title)
        let entry = Pending(item: item, source: source, key: key)
        if !key.isEmpty && verifyingKeys.contains(key) {
            waitingByKey[key, default: []].append(entry)
            waitingCount += 1
            return
        }
        if !key.isEmpty { verifyingKeys.insert(key) }
        pending.append(entry)
    }

    private func pumpEnrichment() {
        var index = 0
        while enrichInFlight < maxEnrich, index < pending.count {
            let entry = pending[index]
            let needsMetadata = !entry.item.hasFullMetadata
            // Limite por site para não sobrecarregar (nem levar bloqueio de) uma fonte só
            if needsMetadata && enrichBySource[entry.source.id, default: 0] >= maxEnrichPerSource {
                index += 1
                continue
            }
            pending.remove(at: index)
            launchEnrichment(entry, needsMetadata: needsMetadata)
        }
        verifyingCount = unverifiedCount
    }

    private func launchEnrichment(_ entry: Pending, needsMetadata: Bool) {
        enrichInFlight += 1
        if needsMetadata { enrichBySource[entry.source.id, default: 0] += 1 }
        let gen = generation
        let timeout = metadataTimeout
        Task {
            let result = await Self.enrich(entry.item, source: entry.source, fetchMetadata: needsMetadata, timeout: timeout)
            self.finishEnrichment(entry, needsMetadata: needsMetadata, result: result, generation: gen)
        }
    }

    private struct Enrichment {
        var item: SourceMangaItem
        var coverHash: UInt64?
        var complete: Bool
    }

    /// Busca o que falta da obra (fora da thread principal).
    nonisolated private static func enrich(_ item: SourceMangaItem, source: MangaSource, fetchMetadata: Bool, timeout: Double) async -> Enrichment {
        let referer = source.imageReferer
        async let listingHash = CoverFingerprint.hash(urlString: item.coverUrl, referer: referer)
        var detail: SourceMangaDetail?
        if fetchMetadata {
            detail = await withTimeout(timeout) { try await source.fetchMetadata(remoteUrl: item.remoteUrl) }
        }
        var enriched = item
        if let detail {
            enriched.altTitles = unique(item.altTitles + detail.altTitles)
            enriched.genres = unique(item.genres + detail.genres)
            enriched.hasFullMetadata = true
        }
        var hash = await listingHash
        if hash == nil, item.coverUrl == nil, let cover = detail?.coverUrl {
            enriched.coverUrl = cover
            hash = await CoverFingerprint.hash(urlString: cover, referer: referer)
        }
        return Enrichment(item: enriched, coverHash: hash, complete: !fetchMetadata || detail != nil)
    }

    private func finishEnrichment(_ entry: Pending, needsMetadata: Bool, result: Enrichment, generation gen: Int) {
        guard gen == generation else { return }
        enrichInFlight -= 1
        if needsMetadata { enrichBySource[entry.source.id, default: 0] -= 1 }

        let item = result.item
        if result.complete {
            MetadataCache.shared.store(
                refId: item.id,
                altTitles: item.altTitles,
                genres: item.genres,
                coverUrl: item.coverUrl,
                coverHash: result.coverHash
            )
        }
        merger.add(item, sourceName: entry.source.name, coverHash: result.coverHash, adultSource: SourceManager.shared.isNsfw(entry.source.id))

        // Libera quem esperava pelo mesmo título: agora entra direto na obra verificada
        if !entry.key.isEmpty {
            verifyingKeys.remove(entry.key)
            if let waiting = waitingByKey.removeValue(forKey: entry.key) {
                waitingCount -= waiting.count
                for other in waiting { ingest(other.item, source: other.source) }
            }
        }
        schedulePublish()
        pumpEnrichment()
        pump()
    }

    // MARK: - Publicação

    /// Agrupa atualizações próximas para a grade não redesenhar a cada obra verificada.
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        let gen = generation
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard gen == self.generation else { return }
            self.publishScheduled = false
            self.publish()
            self.pump()
        }
    }

    private func publish() {
        var list = merger.works
        // O ajuste pode mudar com o feed aberto: sem "Mostrar fontes +18", nada que só exista nelas aparece
        if !Preferences.showNsfwSources {
            list = list.filter { !$0.onlyAdultSources }
        }
        if blockAdult {
            if merger.adultCount > 0 { list = list.filter { !$0.isAdult } }
            blockedCount = merger.adultCount
        } else {
            blockedCount = 0
        }
        loadedCount = list.count
        availableTags = GenreTags.counts(list.map(\.genres), includeAllGenres: true)
        if !tagFilter.isEmpty {
            list = list.filter { GenreTags.matches($0.genres, all: tagFilter) }
        }
        matchingCount = list.count
        works = mode == .latest ? sortedByLatest(list) : list
        verifyingCount = unverifiedCount
    }

    /// Do capítulo mais novo para o mais antigo (empates na ordem de chegada).
    private func sortedByLatest(_ list: [UnifiedWork]) -> [UnifiedWork] {
        let keys = list.map { work in work.refs.compactMap { latestSortDate[$0.id] }.max() ?? .distantPast }
        return list.indices
            .sorted { keys[$0] != keys[$1] ? keys[$0] > keys[$1] : $0 < $1 }
            .map { list[$0] }
    }

    nonisolated private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Executa `operation`, desistindo depois de `seconds` (retorna nil em erro ou tempo esgotado).
func withTimeout<T>(_ seconds: Double, _ operation: @escaping () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Memória simples de quais fontes estão falhando (fora do ar, Cloudflare...), para consultá-las por último.
public enum SourceHealth {
    private static let key = "source_health_failures"
    private static let window: TimeInterval = 12 * 3600

    private static var failures: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    public static func recordFailure(_ sourceId: String) {
        var f = failures
        f[sourceId] = Date().timeIntervalSince1970
        failures = f
    }

    public static func recordSuccess(_ sourceId: String) {
        var f = failures
        guard f[sourceId] != nil else { return }
        f[sourceId] = nil
        failures = f
    }

    /// Mantém a ordem original, mas move para o fim as fontes que falharam nas últimas horas.
    public static func prioritized(_ sources: [MangaSource]) -> [MangaSource] {
        let now = Date().timeIntervalSince1970
        let f = failures
        let isFailing: (MangaSource) -> Bool = { source in
            guard let at = f[source.id] else { return false }
            return now - at < window
        }
        return sources.filter { !isFailing($0) } + sources.filter(isFailing)
    }
}

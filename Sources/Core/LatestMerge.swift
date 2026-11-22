import Foundation

/// Ordem de "Recentes" no catálogo: junta as listas de várias fontes (cada uma já do mais novo
/// para o mais antigo) numa só, pela data do capítulo mais novo — um merge de k listas ordenadas.
///
/// Um item só sai do buffer quando nenhuma página ainda não lida pode ter algo mais novo que ele
/// (a "fronteira" de cada fonte é a data mais antiga que ela já mandou).
///
/// Itens sem data verificável ficam depois dos itens datados, sem atribuir-lhes uma data fictícia.
struct LatestMerge {
    struct Entry {
        let item: SourceMangaItem
        let sourceId: String
        let sortDate: Date
    }

    /// Itens ainda não mostrados, do mais novo para o mais antigo.
    private(set) var buffer: [Entry] = []
    /// Data mais antiga já recebida de cada fonte que ainda tem páginas.
    private(set) var frontier: [String: Date] = [:]
    private var oldest: [String: Date] = [:]
    /// Um número limitado de páginas desconhecidas é examinado antes de publicar resultados.
    private var undatedPages: [String: Int] = [:]
    private static let undatedLookaheadPages = 2
    private let now: Date

    init(now: Date = Date()) {
        self.now = now
    }

    /// Página recebida de uma fonte. `keep` decide quais itens entram no buffer (os demais só
    /// contam para a fronteira, ex.: obras de outro idioma numa fonte multi-idioma).
    mutating func add(_ items: [SourceMangaItem], from sourceId: String, hasMore: Bool, keep: (SourceMangaItem) -> Bool = { _ in true }) {
        var foundDate = false
        for item in items {
            let date = sortDate(for: item)
            // A ausência de data não prova que a página seguinte seja antiga.
            if date != .distantPast {
                foundDate = true
                oldest[sourceId] = min(oldest[sourceId] ?? date, date)
            }
            if keep(item) { insert(Entry(item: item, sourceId: sourceId, sortDate: date)) }
        }
        if !foundDate && oldest[sourceId] == nil { undatedPages[sourceId, default: 0] += 1 }
        // Dados ausentes não garantem a ordem. Limitar a antecipação evita bloquear o feed
        // e uma data posterior ainda pode ser inserida antes dos itens sem data já exibidos.
        let unknown = (undatedPages[sourceId] ?? 0) < Self.undatedLookaheadPages ? Date.distantFuture : .distantPast
        frontier[sourceId] = hasMore ? (oldest[sourceId] ?? unknown) : nil
    }

    /// A fonte não tem mais páginas (acabou ou falhou).
    mutating func end(_ sourceId: String) {
        frontier[sourceId] = nil
    }

    /// Tira o item mais novo, se for seguro (e, com `cutoff`, só se for mais novo que ele).
    mutating func popSafe(newerThan cutoff: Date? = nil) -> Entry? {
        guard let head = buffer.first, isSafe(head) else { return nil }
        if let cutoff, head.sortDate <= cutoff { return nil }
        return buffer.removeFirst()
    }

    /// Entre as fontes `available`, a que deve ser consultada agora: a de fronteira mais nova,
    /// desde que possa trazer algo mais novo que `date` (sem `date`, qualquer uma serve).
    func sourceToFetch(among available: some Collection<String>, newerThan date: Date?) -> String? {
        let best = available
            .compactMap { id in frontier[id].map { (id, $0) } }
            .max { $0.1 < $1.1 }
        guard let best else { return nil }
        if let date, best.1 <= date { return nil }
        return best.0
    }

    // MARK: - Internos

    private func isSafe(_ entry: Entry) -> Bool {
        !frontier.contains { $0.value > entry.sortDate }
    }

    private func sortDate(for item: SourceMangaItem) -> Date {
        guard let date = item.latestChapterDate, date <= now else { return .distantPast }
        return date
    }

    /// Insere mantendo a ordem (empates ficam na ordem de chegada).
    private mutating func insert(_ entry: Entry) {
        var low = 0
        var high = buffer.count
        while low < high {
            let mid = (low + high) / 2
            if buffer[mid].sortDate >= entry.sortDate { low = mid + 1 } else { high = mid }
        }
        buffer.insert(entry, at: low)
    }
}

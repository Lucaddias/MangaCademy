import Foundation

/// Uma ocorrência da obra em uma fonte específica.
public struct WorkSourceRef: Codable, Hashable, Identifiable {
    public var id: String { "\(sourceId):\(remoteUrl)" }
    public let sourceId: String
    public let sourceName: String
    public let remoteUrl: String
    public let title: String
    public let coverUrl: String?
    public let languages: [String]

    public init(sourceId: String, sourceName: String, remoteUrl: String, title: String, coverUrl: String?, languages: [String]) {
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.remoteUrl = remoteUrl
        self.title = title
        self.coverUrl = coverUrl
        self.languages = languages
    }
}

/// Obra unificada: o mesmo título vindo de várias fontes e idiomas aparece uma única vez.
public struct UnifiedWork: Identifiable, Hashable {
    public private(set) var id: String
    public var title: String
    public var coverUrl: String?
    public var coverSourceId: String?
    public var refs: [WorkSourceRef]
    public var languages: [String]
    public var titleKeys: Set<String>
    /// Tags de todas as fontes (sem repetição).
    public private(set) var genres: [String] = []
    /// Alguma fonte marcou a obra como conteúdo adulto ("Adult", "Adulto", "+18"...)
    /// ou ela só existe em fontes +18, que não marcam as obras (lá tudo é adulto).
    public var isAdult: Bool { hasAdultTag || onlyAdultSources }
    private var hasAdultTag = false
    /// Todas as fontes da obra são marcadas +18 no índice Keiyoushi.
    public private(set) var onlyAdultSources = false
    /// Capítulo mais novo entre as fontes (quando a listagem informa), para "Recentes".
    public private(set) var latestChapterName: String?
    public private(set) var latestChapterDate: Date?

    public init(ref: WorkSourceRef, altTitles: [String] = [], genres: [String] = [], fromAdultSource: Bool = false) {
        self.id = ref.id
        self.title = ref.title
        self.coverUrl = ref.coverUrl
        self.coverSourceId = ref.coverUrl == nil ? nil : ref.sourceId
        self.refs = [ref]
        self.languages = ref.languages
        self.titleKeys = TitleKey.keys(for: [ref.title] + altTitles)
        self.onlyAdultSources = fromAdultSource
        addGenres(genres)
    }

    /// Reconstrói a obra a partir das referências salvas (biblioteca).
    public init?(id: String, title: String, coverUrl: String?, refs: [WorkSourceRef]) {
        guard let first = refs.first else { return nil }
        self.id = id
        self.title = title
        self.coverUrl = coverUrl ?? first.coverUrl
        self.coverSourceId = first.sourceId
        self.refs = refs
        self.languages = []
        self.titleKeys = []
        for ref in refs {
            addLanguages(ref.languages)
            titleKeys.formUnion(TitleKey.keys(for: [ref.title]))
        }
        titleKeys.formUnion(TitleKey.keys(for: [title]))
    }

    public func matches(_ filter: LanguageFilter) -> Bool {
        filter == .all || languages.contains(where: filter.matches)
    }

    /// Capas das outras fontes, para quando a principal não carregar.
    public var fallbackCovers: [WorkSourceRef] {
        refs.filter { $0.coverUrl != nil && $0.coverUrl != coverUrl }
    }

    public mutating func merge(ref: WorkSourceRef, altTitles: [String], genres: [String] = [], fromAdultSource: Bool = false) {
        guard !refs.contains(where: { $0.id == ref.id }) else { return }
        refs.append(ref)
        onlyAdultSources = onlyAdultSources && fromAdultSource
        addLanguages(ref.languages)
        addGenres(genres)
        titleKeys.formUnion(TitleKey.keys(for: [ref.title] + altTitles))
        if coverUrl == nil, let cover = ref.coverUrl {
            coverUrl = cover
            coverSourceId = ref.sourceId
        }
    }

    /// Une grupos do catálogo sem trocar a identidade do primeiro grupo ou descartar referências.
    mutating func merge(work other: UnifiedWork) {
        for ref in other.refs where !refs.contains(where: { $0.id == ref.id }) { refs.append(ref) }
        addLanguages(other.languages)
        addGenres(other.genres)
        titleKeys.formUnion(other.titleKeys)
        hasAdultTag = hasAdultTag || other.hasAdultTag
        onlyAdultSources = onlyAdultSources && other.onlyAdultSources
        if coverUrl == nil { coverUrl = other.coverUrl; coverSourceId = other.coverSourceId }
        noteLatestChapter(name: other.latestChapterName, date: other.latestChapterDate)
    }

    mutating func preserveIdentity(_ id: String?) {
        if let id { self.id = id }
    }

    /// Guarda o capítulo se for mais novo que o conhecido (com data vale mais que sem data).
    public mutating func noteLatestChapter(name: String?, date: Date?) {
        if let date {
            guard latestChapterDate.map({ date > $0 }) ?? true else { return }
            latestChapterDate = date
            latestChapterName = name
        } else if latestChapterDate == nil, latestChapterName == nil, let name {
            latestChapterName = name
        }
    }

    public mutating func addLanguages(_ langs: [String]) {
        for lang in langs where !languages.contains(lang) {
            languages.append(lang)
        }
    }

    public mutating func addGenres(_ tags: [String]) {
        for tag in tags {
            let name = tag.trimmed
            guard !name.isEmpty else { continue }
            let key = ContentFilter.normalizeTag(name)
            if !genres.contains(where: { ContentFilter.normalizeTag($0) == key }) {
                genres.append(name)
                if ContentFilter.isAdultTag(name) { hasAdultTag = true }
            }
        }
    }

    /// Badges compactos de idioma priorizando o filtro ativo.
    public func languageBadges(preferred filter: LanguageFilter, limit: Int = 2) -> String? {
        let known = languages.filter { $0 != "all" }
        guard !known.isEmpty else { return nil }
        let order = filter.preferredLanguages
        let sorted = known.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max
            let ib = order.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }
        var text = sorted.prefix(limit).map(LanguageCode.shortLabel).joined(separator: " · ")
        if sorted.count > limit { text += " +\(sorted.count - limit)" }
        return text
    }

    public var refsJSON: String? {
        guard let data = try? JSONEncoder().encode(refs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func refs(fromJSON json: String?) -> [WorkSourceRef] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WorkSourceRef].self, from: data)) ?? []
    }
}

extension UnifiedWork {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// "Cap. 123 · há 2 h" (só o que a fonte informou).
    public func latestChapterCaption(now: Date = Date()) -> String? {
        let when = latestChapterDate.map { date in
            now.timeIntervalSince(date) < 60 ? "agora" : Self.relativeFormatter.localizedString(for: date, relativeTo: now)
        }
        let parts = [latestChapterName?.collapsedWhitespace.nilIfEmpty, when].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Reconstrói a obra unificada (todas as fontes/idiomas) salva na biblioteca.
    public init(libraryManga manga: Manga) {
        var refs = UnifiedWork.refs(fromJSON: manga.sourcesJSON)
        if refs.isEmpty {
            refs = [WorkSourceRef(
                sourceId: manga.sourceId,
                sourceName: SourceManager.shared.sourceName(id: manga.sourceId),
                remoteUrl: manga.remoteUrl,
                title: manga.title,
                coverUrl: manga.coverUrl,
                languages: []
            )]
        }
        // Capa escolhida pelo usuário vale mais que a da fonte.
        let cover = CustomCoverStore.url(for: manga.customCoverPath)?.absoluteString ?? manga.coverUrl
        self = UnifiedWork(id: manga.id, title: manga.title, coverUrl: cover, refs: refs)
            ?? UnifiedWork(ref: refs[0])
        if manga.customCoverPath != nil { coverSourceId = nil }
    }

    /// Obra de uma fonte só a partir do id salvo ("fonte:endereço"), quando ela não está na biblioteca.
    /// O id fica igual ao salvo, então o progresso de leitura continua valendo.
    public init?(storedId: String, title: String, coverUrl: String?) {
        guard let separator = storedId.firstIndex(of: ":") else { return nil }
        let sourceId = String(storedId[..<separator])
        let remoteUrl = String(storedId[storedId.index(after: separator)...])
        guard !sourceId.isEmpty, !remoteUrl.isEmpty else { return nil }
        self.init(ref: WorkSourceRef(
            sourceId: sourceId,
            sourceName: SourceManager.shared.sourceName(id: sourceId),
            remoteUrl: remoteUrl,
            title: title,
            coverUrl: coverUrl,
            languages: []
        ))
    }
}

/// Chave normalizada de título para detectar a mesma obra em fontes diferentes.
public enum TitleKey {
    public static func normalize(_ title: String) -> String {
        var s = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: "’", with: "")
        s = s.replacingOccurrences(of: "'", with: "")
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            out.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        var words = String(out).split(separator: " ").map(String.init)
        if words.first == "the" && words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }

    public static func keys(for titles: [String]) -> Set<String> {
        var result = Set<String>()
        for title in titles {
            let key = normalize(title)
            // Evita fundir obras por títulos genéricos demais (curtos ou só números)
            guard !key.isEmpty, !key.allSatisfy({ $0.isNumber || $0 == " " }) else { continue }
            if key.count >= 3 || key.unicodeScalars.contains(where: { $0.value > 0x2E80 }) {
                result.insert(key)
            }
        }
        return result
    }
}

/// Índice incremental usado pelo catálogo para unificar resultados à medida que chegam.
///
/// Uma obra nova é fundida a uma existente quando:
/// 1. algum título (principal ou alternativo) normalizado é igual;
/// 2. os títulos têm o mesmo significado em idiomas diferentes ("Ilusão de Amor: Superstar" =
///    "Love is an Illusion! - Superstar"), com confirmação pela capa quando só há palavras comuns;
/// 3. as capas são praticamente a mesma imagem e os títulos compartilham uma palavra distintiva.
/// Duas entradas diferentes da mesma fonte nunca são fundidas pelos critérios 2 e 3.
public enum IdentityMergeDecision {
    case deny
    case allow(preferredID: String?)
}

public struct WorkMerger {
    public private(set) var works: [UnifiedWork] = []
    /// Quantas obras têm tag adulta (para o catálogo saber quantas ficarão visíveis).
    public private(set) var adultCount = 0
    private var indexByKey: [String: Int] = [:]
    private var indexByRef: [String: Int] = [:]
    private var aliasesByRef: [String: Set<String>] = [:]
    /// Paralelos a `works`: conceitos de cada título e fontes presentes.
    private var conceptSets: [[Set<String>]] = []
    private var sourceIds: [Set<String>] = []
    private var indexByConcept: [String: [Int]] = [:]
    private var covers: [(hash: UInt64, work: Int, sourceId: String)] = []
    private var genericCovers: [UInt64] = []
    /// Por que cada entrada foi fundida sem título idêntico (diagnóstico).
    public private(set) var fuzzyReasons: [String: String] = [:]
    /// Deve confirmar que as identidades envolvidas não têm dados locais independentes.
    private let canMergeIdentities: ((Set<String>) -> IdentityMergeDecision)?

    public init(canMergeIdentities: ((Set<String>) -> IdentityMergeDecision)? = nil) {
        self.canMergeIdentities = canMergeIdentities
    }

    public func contains(refId: String) -> Bool {
        indexByRef[refId] != nil
    }

    /// Obra já existente com algum título idêntico (não precisa de dados extras para fundir).
    public func exactMatch(for item: SourceMangaItem) -> Int? {
        let mainKeys = TitleKey.keys(for: [item.title])
        let alternateKeys = TitleKey.keys(for: item.altTitles)
        let keys = mainKeys.union(alternateKeys)
        for existing in Set(keys.compactMap({ indexByKey[$0] })).sorted() {
            // Na mesma fonte, um alias unilateral pode ser genérico demais.
            let sameSource = works[existing].refs.filter { $0.sourceId == item.sourceId }
            if !sameSource.isEmpty && mainKeys.isDisjoint(with: TitleKey.keys(for: sameSource.map(\.title))) {
                // Na mesma fonte, um alias unilateral pode ser genérico. Aceitar nomes
                // diferentes apenas quando ambos os registros declaram o outro como alias.
                let reciprocal = sameSource.contains { ref in
                    !mainKeys.isDisjoint(with: aliasesByRef[ref.id] ?? [])
                        && !alternateKeys.isDisjoint(with: TitleKey.keys(for: [ref.title]))
                }
                if !reciprocal { continue }
            }
            return existing
        }
        return nil
    }

    /// Insere ou funde um item. Retorna true se criou uma obra nova.
    /// `adultSource`: a fonte é marcada +18 no índice (a obra conta como adulta se só existir nessas fontes).
    @discardableResult
    public mutating func add(_ item: SourceMangaItem, sourceName: String, coverHash: UInt64? = nil, adultSource: Bool = false) -> Bool {
        if indexByRef[item.id] != nil { return false }
        let ref = WorkSourceRef(
            sourceId: item.sourceId,
            sourceName: sourceName,
            remoteUrl: item.remoteUrl,
            title: item.title,
            coverUrl: item.coverUrl,
            languages: item.languages
        )
        let sets = Self.concepts(for: item)
        var hash = coverHash
        if let coverHash, isGeneric(coverHash, sourceId: item.sourceId) { hash = nil }

        reconcileGroups(for: item, coverHash: hash)

        var target = exactMatch(for: item)
        if target == nil, let match = conceptMatch(sets, sourceId: item.sourceId, coverHash: hash) {
            target = match.index
            fuzzyReasons[item.id] = match.reason
        }
        if target == nil, let hash, let match = coverMatch(hash, tokens: Set(sets.joined()), sourceId: item.sourceId) {
            target = match.index
            fuzzyReasons[item.id] = match.reason
        }
        var preferredID: String?
        if let index = target, let canMergeIdentities {
            let identities = Set(works[index].refs.map(\.id)).union([works[index].id, item.id])
            switch canMergeIdentities(identities) {
            case .deny: target = nil; fuzzyReasons[item.id] = nil
            case .allow(let id):
                if let id, !identities.contains(id) { target = nil; fuzzyReasons[item.id] = nil }
                else { preferredID = id }
            }
        }
        if let target {
            works[target].preserveIdentity(preferredID)
            let wasAdult = works[target].isAdult
            works[target].merge(ref: ref, altTitles: item.altTitles, genres: item.genres, fromAdultSource: adultSource)
            works[target].noteLatestChapter(name: item.latestChapterName, date: item.latestChapterDate)
            // Pode deixar de ser adulta: obra de fonte +18 que também está numa fonte comum
            if wasAdult != works[target].isAdult { adultCount += wasAdult ? -1 : 1 }
            register(item, sets: sets, coverHash: hash, at: target)
            return false
        }

        var work = UnifiedWork(ref: ref, altTitles: item.altTitles, genres: item.genres, fromAdultSource: adultSource)
        work.noteLatestChapter(name: item.latestChapterName, date: item.latestChapterDate)
        if work.isAdult { adultCount += 1 }
        works.append(work)
        conceptSets.append([])
        sourceIds.append([])
        register(item, sets: sets, coverHash: hash, at: works.count - 1)
        return true
    }

    // MARK: - Índices

    /// Um registro enriquecido pode conectar grupos anteriormente separados. Só os une com
    /// metadados completos, nomes distintos confirmados e impressão de capa idêntica e exclusiva.
    private mutating func reconcileGroups(for item: SourceMangaItem, coverHash: UInt64?) {
        guard item.hasFullMetadata, let hash = coverHash else { return }
        let keys = TitleKey.keys(for: [item.title] + item.altTitles)
        guard keys.count >= 2 else { return }
        let imageGroups = Set(covers.filter { $0.hash == hash }.map(\.work))
        let candidates = imageGroups.filter { !works[$0].titleKeys.isDisjoint(with: keys) }.sorted()
        guard candidates.count > 1, Set(candidates) == imageGroups else { return }
        let matchedKeys = candidates.reduce(into: Set<String>()) {
            $0.formUnion(TitleKey.keys(for: works[$1].refs.map(\.title)).intersection(keys))
        }
        guard matchedKeys.count >= 2 else { return }
        // Sem contexto de persistência, não se pode garantir que a segunda identidade
        // não tenha progresso, marcadores ou downloads que a tela deixaria de mostrar.
        guard let canMergeIdentities else { return }
        let identities = Set(candidates.flatMap { [works[$0].id] + works[$0].refs.map(\.id) }).union([item.id])
        let preferredID: String?
        switch canMergeIdentities(identities) {
        case .deny: return
        case .allow(let id): preferredID = id
        }
        // A identidade escolhida deve já pertencer ao grupo: o item novo ainda pode
        // ser recusado no passo seguinte (por exemplo, ao esgotar o orçamento da guarda).
        if let preferredID, !candidates.contains(where: { works[$0].refs.contains(where: { $0.id == preferredID }) }) { return }
        // Não unir duas entradas de uma mesma fonte sem confirmação recíproca de aliases.
        for (offset, left) in candidates.enumerated() {
            for right in candidates.dropFirst(offset + 1) {
                for a in works[left].refs {
                    for b in works[right].refs where a.sourceId == b.sourceId {
                        guard !(aliasesByRef[a.id] ?? []).isDisjoint(with: TitleKey.keys(for: [b.title])),
                              !(aliasesByRef[b.id] ?? []).isDisjoint(with: TitleKey.keys(for: [a.title])) else { return }
                    }
                }
            }
        }
        let target = candidates[0]
        let removed = Set(candidates.dropFirst())
        for index in removed.sorted(by: >) {
            let other = works[index]
            let otherSets = conceptSets[index]
            let otherSources = sourceIds[index]
            works[target].merge(work: other)
            for set in otherSets where !conceptSets[target].contains(set) { conceptSets[target].append(set) }
            sourceIds[target].formUnion(otherSources)
            works.remove(at: index)
            conceptSets.remove(at: index)
            sourceIds.remove(at: index)
        }
        works[target].preserveIdentity(preferredID)
        func remap(_ index: Int) -> Int {
            if removed.contains(index) { return target }
            return index - removed.filter { $0 < index }.count
        }
        indexByRef = indexByRef.mapValues(remap)
        covers = covers.map { (hash: $0.hash, work: remap($0.work), sourceId: $0.sourceId) }
        indexByKey.removeAll()
        indexByConcept.removeAll()
        for index in works.indices {
            for key in works[index].titleKeys where indexByKey[key] == nil { indexByKey[key] = index }
            for token in Set(conceptSets[index].joined()) { indexByConcept[token, default: []].append(index) }
        }
        adultCount = works.filter(\.isAdult).count
    }

    private static func concepts(for item: SourceMangaItem) -> [Set<String>] {
        var result: [Set<String>] = []
        for title in [item.title] + item.altTitles.prefix(40) {
            let set = TitleConcepts.tokens(title)
            if !set.isEmpty && !result.contains(set) { result.append(set) }
        }
        return result
    }

    private mutating func register(_ item: SourceMangaItem, sets: [Set<String>], coverHash: UInt64?, at index: Int) {
        indexByRef[item.id] = index
        aliasesByRef[item.id] = TitleKey.keys(for: item.altTitles)
        for key in works[index].titleKeys where indexByKey[key] == nil {
            indexByKey[key] = index
        }
        sourceIds[index].insert(item.sourceId)
        for set in sets where !conceptSets[index].contains(set) {
            conceptSets[index].append(set)
        }
        for token in Set(sets.joined()) where indexByConcept[token]?.last != index {
            indexByConcept[token, default: []].append(index)
        }
        if let coverHash {
            covers.append((coverHash, index, item.sourceId))
        }
    }

    // MARK: - Títulos traduzidos

    private func conceptMatch(_ sets: [Set<String>], sourceId: String, coverHash: UInt64?) -> (index: Int, reason: String)? {
        let candidates = sets.filter { $0.count >= 2 }
        guard !candidates.isEmpty else { return nil }
        var hits: [Int: Int] = [:]
        for token in Set(candidates.joined()) {
            for index in indexByConcept[token] ?? [] { hits[index, default: 0] += 1 }
        }
        var best: (index: Int, score: Double, reason: String)?
        for (index, count) in hits where count >= 2 && !sourceIds[index].contains(sourceId) {
            for a in candidates {
                for b in conceptSets[index] {
                    let shared = a.intersection(b)
                    guard shared.count >= 2 else { continue }
                    let score = Double(shared.count) / Double(a.count + b.count - shared.count)
                    guard score > (best?.score ?? 0) else { continue }
                    var reason: String?
                    if score >= 0.75 {
                        // Um nome próprio/termo raro em comum ("solo leveling"), ou o título inteiro
                        // equivalente com 3+ conceitos ("Ilusão de Amor: Superstar"); só palavras comuns
                        // em outra ordem ("Primeiro os Filhos, Depois o Amor" × "O Filho do Meu Primeiro
                        // Amor") ou poucas ("Torre de Deus") precisam da confirmação da capa
                        if shared.contains(where: { !TitleConcepts.isCommon($0) && TitleConcepts.isDistinctive($0) }) {
                            reason = "conceitos raros"
                        } else if score == 1 && shared.count >= 3 {
                            reason = "conceitos"
                        } else if coverClose(index, coverHash, maxDistance: 14) {
                            reason = "conceitos + capa"
                        }
                    } else if score >= 0.5 && coverClose(index, coverHash, maxDistance: 10) {
                        // Tradução parcial ("Herói de Classe Desastre" × "Disaster-Class Hero"): exige a capa
                        reason = "conceitos parciais + capa"
                    }
                    if let reason {
                        best = (index, score, "\(reason) \(String(format: "%.2f", score)) \(shared.sorted())")
                    }
                }
            }
        }
        return best.map { ($0.index, $0.reason) }
    }

    // MARK: - Capas

    private func coverClose(_ index: Int, _ hash: UInt64?, maxDistance: Int) -> Bool {
        guard let hash else { return false }
        return covers.contains { $0.work == index && CoverFingerprint.distance($0.hash, hash) <= maxDistance }
    }

    /// Mesma imagem em obras diferentes da mesma fonte = capa genérica do site.
    private mutating func isGeneric(_ hash: UInt64, sourceId: String) -> Bool {
        if genericCovers.contains(where: { CoverFingerprint.distance($0, hash) <= 3 }) { return true }
        if covers.contains(where: { $0.sourceId == sourceId && CoverFingerprint.distance($0.hash, hash) <= 3 }) {
            genericCovers.append(hash)
            return true
        }
        return false
    }

    private func coverMatch(_ hash: UInt64, tokens: Set<String>, sourceId: String) -> (index: Int, reason: String)? {
        var best: (index: Int, distance: Int)?
        var nearby = Set<Int>()
        for entry in covers {
            let distance = CoverFingerprint.distance(hash, entry.hash)
            guard distance <= 4 else { continue }
            nearby.insert(entry.work)
            guard !sourceIds[entry.work].contains(sourceId) else { continue }
            let workTokens = Set(conceptSets[entry.work].joined())
            guard tokens.intersection(workTokens).contains(where: TitleConcepts.isDistinctive) else { continue }
            if distance < (best?.distance ?? Int.max) { best = (entry.work, distance) }
        }
        // A mesma imagem em várias obras distintas não identifica nenhuma delas
        guard nearby.count == 1, let best else { return nil }
        let shared = tokens.intersection(Set(conceptSets[best.index].joined())).sorted()
        return (best.index, "capa d=\(best.distance) \(shared)")
    }
}

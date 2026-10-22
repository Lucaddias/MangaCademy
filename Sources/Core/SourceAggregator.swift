import Foundation

public final class SourceAggregator {
    public static let shared = SourceAggregator()

    /// Agrupa capítulos de várias fontes por idioma e remove duplicatas dentro de cada idioma.
    /// Quando o mesmo capítulo existe em mais de uma fonte no mesmo idioma, fica a versão da
    /// fonte com mais capítulos naquele idioma (a mais completa), salvo se o usuário escolheu
    /// uma fonte preferida para a obra.
    public func chaptersByLanguage(_ chapters: [SourceChapterItem], preferredSourceId: String? = nil) -> [String: [SourceChapterItem]] {
        var byLanguage: [String: [SourceChapterItem]] = [:]
        for ch in chapters {
            byLanguage[ch.language ?? "all", default: []].append(ch)
        }

        var result: [String: [SourceChapterItem]] = [:]
        for (language, list) in byLanguage {
            // Pontuação = nº de capítulos que a fonte oferece neste idioma
            var availability: [String: Int] = [:]
            for ch in list { availability[ch.sourceId, default: 0] += 1 }

            var best: [String: SourceChapterItem] = [:]
            var order: [String] = []
            for ch in list {
                let key = Self.dedupeKey(chapterNumber: ch.chapterNumber, name: ch.name)
                if let existing = best[key] {
                    if let preferredSourceId, existing.sourceId != ch.sourceId {
                        if ch.sourceId == preferredSourceId { best[key] = ch; continue }
                        if existing.sourceId == preferredSourceId { continue }
                    }
                    let a = availability[ch.sourceId] ?? 0
                    let b = availability[existing.sourceId] ?? 0
                    if a > b || (a == b && (ch.scanlator?.count ?? 0) > (existing.scanlator?.count ?? 0)) {
                        best[key] = ch
                    }
                } else {
                    best[key] = ch
                    order.append(key)
                }
            }

            let merged = order.compactMap { best[$0] }
            result[language] = merged.enumerated().sorted { lhs, rhs in
                let a = lhs.element, b = rhs.element
                if a.chapterNumber >= 0 && b.chapterNumber >= 0 && a.chapterNumber != b.chapterNumber {
                    return a.chapterNumber > b.chapterNumber
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
        return result
    }

    /// Chave que identifica "o mesmo capítulo" vindo de fontes diferentes, dentro de um idioma:
    /// o número, ou o nome normalizado quando a fonte não traz número.
    public static func dedupeKey(chapterNumber: Double, name: String) -> String {
        chapterNumber >= 0 ? String(format: "%.3f", chapterNumber) : "name:\(TitleKey.normalize(name))"
    }

    /// Ordena os idiomas: primeiro os do filtro ativo, depois por quantidade de capítulos.
    public func sortedLanguages(_ byLanguage: [String: [SourceChapterItem]], filter: LanguageFilter) -> [String] {
        let preferred = filter.preferredLanguages
        return byLanguage.keys.sorted { a, b in
            let ia = preferred.firstIndex(of: a) ?? Int.max
            let ib = preferred.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            let ca = byLanguage[a]?.count ?? 0
            let cb = byLanguage[b]?.count ?? 0
            return ca == cb ? a < b : ca > cb
        }
    }
}

import Foundation

/// Port da extensão NamiComi — src/all/namicomi (API JSON em api.namicomi.com).
/// Cada idioma do catálogo é uma fonte; obras e capítulos são guardados pelo id da API.
public final class NamiComiSource: ThemeSource, MangaSource {
    private static let api = "https://api.namicomi.com"
    private static let cdn = "https://uploads.namicomi.com"
    private static let pageSize = 20

    /// Códigos de idioma da API ("pt-br", "pt-pt", "es-es"...).
    private var apiLanguage: String {
        switch language {
        case "pt-BR": return "pt-br"
        case "pt": return "pt-pt"
        case "es": return "es-es"
        default: return language.lowercased()
        }
    }

    public var imageReferer: String? { "\(baseUrl)/" }

    private func url(_ path: String, _ params: [(String, String)]) -> String {
        let query = params.map { "\(HTTPClient.queryEncode($0.0))=\(HTTPClient.queryEncode($0.1))" }.joined(separator: "&")
        return "\(Self.api)\(path)?\(query)"
    }

    private static let includes: [(String, String)] = ["cover_art", "organization", "tag", "primary_tag", "secondary_tag"].map { ("includes[]", $0) }
    private static let types: [(String, String)] = ["manhua", "manwha", "manga", "comic"].map { ("types[]", $0) }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await titles(page: page, extra: [("order[views]", "desc"), ("availableTranslatedLanguages[]", apiLanguage)])
    }

    /// Os capítulos mais novos no idioma da fonte, uma obra por vez (como o MangaDex).
    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        let limit = 100
        let offset = (page - 1) * limit
        guard let root = try await http.json(url("/chapter", [
            ("order[publishAt]", "desc"), ("translatedLanguages[]", apiLanguage),
            ("limit", "\(limit)"), ("offset", "\(offset)"), ("includes[]", "title"),
        ])) as? [String: Any] else { return .empty }

        var order: [String] = []
        var newest: [String: (name: String, date: Date?)] = [:]
        for chapter in root.array("data") {
            guard let titleId = chapter.array("relationships").first(where: { $0.string("type") == "title" })?.string("id"),
                  newest[titleId] == nil else { continue }
            let attrs = chapter.dict("attributes") ?? [:]
            order.append(titleId)
            newest[titleId] = (Self.chapterName(attrs), attrs.string("publishAt").flatMap(DateParsing.iso))
        }
        let meta = root.dict("meta") ?? [:]
        let hasNext = offset + limit < (meta.int("total") ?? 0)
        guard !order.isEmpty else { return SourceMangaPage(items: [], hasNextPage: hasNext) }

        let byId = Dictionary(
            try await titleList(url("/title/search", [("limit", "\(order.count)")] + order.map { ("ids[]", $0) } + Self.includes))
                .map { ($0.remoteUrl, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let items: [SourceMangaItem] = order.compactMap { id in
            guard var item = byId[id] else { return nil }
            item.latestChapterName = newest[id]?.name
            item.latestChapterDate = newest[id]?.date
            return item
        }
        return SourceMangaPage(items: items, hasNextPage: hasNext)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await titles(page: page, extra: [("title", query), ("availableTranslatedLanguages[]", apiLanguage)])
    }

    private func titles(page: Int, extra: [(String, String)]) async throws -> SourceMangaPage {
        let offset = (page - 1) * Self.pageSize
        let params = [("limit", "\(Self.pageSize)"), ("offset", "\(offset)")] + extra + Self.includes + Self.types
        guard let root = try await http.json(url("/title/search", params)) as? [String: Any] else { return .empty }
        let meta = root.dict("meta") ?? [:]
        let total = meta.int("total") ?? 0
        return SourceMangaPage(items: root.array("data").compactMap(makeItem), hasNextPage: offset + Self.pageSize < total)
    }

    private func titleList(_ urlString: String) async throws -> [SourceMangaItem] {
        guard let root = try await http.json(urlString) as? [String: Any] else { return [] }
        return root.array("data").compactMap(makeItem)
    }

    private func localized(_ map: [String: Any]?) -> String? {
        guard let map else { return nil }
        return (map[apiLanguage] as? String ?? map["en"] as? String ?? map.values.compactMap { $0 as? String }.first)?.nilIfEmpty
    }

    private func makeItem(_ entity: [String: Any]) -> SourceMangaItem? {
        guard let detail = makeDetail(entity) else { return nil }
        var result = item(remoteUrl: detail.remoteUrl, title: detail.title, cover: detail.coverUrl)
        result.genres = detail.genres
        result.altTitles = detail.altTitles
        result.hasFullMetadata = true
        return result
    }

    private func makeDetail(_ entity: [String: Any]) -> SourceMangaDetail? {
        guard let id = entity.string("id"), let attrs = entity.dict("attributes"),
              let title = localized(attrs.dict("title")) else { return nil }
        let relationships = entity.array("relationships")
        func related(_ type: String) -> [[String: Any]] { relationships.filter { $0.string("type") == type } }

        let organizations = related("organization").compactMap { $0.dict("attributes")?.string("name") }
        // Tags na ordem da extensão: avisos de conteúdo, formato, gênero e tema
        let groups = ["content-warnings", "format", "genre", "theme"]
        let tags = (related("tag") + related("primary_tag") + related("secondary_tag"))
            .compactMap { $0.dict("attributes") }
            .sorted { (groups.firstIndex(of: $0.string("group") ?? "") ?? groups.count) < (groups.firstIndex(of: $1.string("group") ?? "") ?? groups.count) }
            .compactMap { localized($0.dict("name")) }
        var genres = Self.unique(tags)
        if let rating = attrs.string("contentRating"), rating != "safe" { genres.append("Content Rating: \(rating)") }

        let cover = related("cover_art").first?.dict("attributes")?.string("fileName").map { "\(Self.cdn)/covers/\(id)/\($0)" }
        let status: Int
        switch attrs.string("publicationStatus") {
        case "ongoing": status = 1
        case "completed": status = 2
        case "cancelled": status = 3
        case "hiatus": status = 4
        default: status = 0
        }
        let titles = (attrs.dict("title") ?? [:]).values.compactMap { $0 as? String }.filter { $0 != title }
        return SourceMangaDetail(
            remoteUrl: id,
            title: title,
            author: Self.unique(organizations).joined(separator: ", ").nilIfEmpty,
            description: localized(attrs.dict("description")),
            genres: genres,
            status: status,
            coverUrl: cover,
            altTitles: titles
        )
    }

    public func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail {
        guard let root = try await http.json(url("/title/\(remoteUrl)", Self.includes)) as? [String: Any],
              let entity = root.dict("data"), let detail = makeDetail(entity) else {
            throw HTTPError.parse("os detalhes da obra")
        }
        return detail
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        async let detail = fetchMetadata(remoteUrl: remoteUrl)
        async let chapters = fetchChapters(titleId: remoteUrl)
        return (try await detail, try await chapters)
    }

    private func chapterPage(_ titleId: String, offset: Int) async throws -> [String: Any] {
        let params = [
            ("titleId", titleId), ("includes[]", "organization"), ("limit", "200"), ("offset", "\(offset)"),
            ("translatedLanguages[]", apiLanguage), ("order[volume]", "desc"), ("order[chapter]", "desc"),
        ]
        return try await http.json(url("/chapter", params)) as? [String: Any] ?? [:]
    }

    private func fetchChapters(titleId: String) async throws -> [SourceChapterItem] {
        let first = try await chapterPage(titleId, offset: 0)
        let meta = first.dict("meta") ?? [:]
        let limit = max(meta.int("limit") ?? 200, 1)
        let total = meta.int("total") ?? 0
        var pages = [first]
        if total > limit {
            pages += try await withThrowingTaskGroup(of: (Int, [String: Any]).self) { group in
                for offset in stride(from: limit, to: total, by: limit) {
                    group.addTask { (offset, try await self.chapterPage(titleId, offset: offset)) }
                }
                var results: [(Int, [String: Any])] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        let entries = pages.flatMap { $0.array("data") }
        let ids = entries.compactMap { $0.string("id") }
        guard !ids.isEmpty else { return [] }

        // Capítulos pagos ou só para assinantes ficam de fora (precisam de conta)
        let accessible = try await accessMap(ids)
        return entries.filter { accessible[$0.string("id") ?? ""] != false }
            .enumerated()
            .compactMap { index, entry in
                guard let id = entry.string("id"), let attrs = entry.dict("attributes") else { return nil }
                var item = chapter(
                    remoteUrl: id,
                    name: Self.chapterName(attrs),
                    index: index,
                    number: attrs.string("chapter").flatMap(Double.init),
                    date: attrs.string("publishAt").flatMap(DateParsing.iso)
                )
                item.mangaRemoteUrl = titleId
                return item
            }
    }

    private func accessMap(_ ids: [String]) async throws -> [String: Bool] {
        var map: [String: Bool] = [:]
        for start in stride(from: 0, to: ids.count, by: 200) {
            let chunk = ids[start..<min(start + 200, ids.count)]
            let body = try JSONSerialization.data(withJSONObject: ["entities": chunk.map { ["entityId": $0, "entityType": "chapter"] }])
            let (data, _) = try await http.data("\(Self.api)/gating/check", method: "POST", headers: ["Content-Type": "application/json"], body: body)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let entries = root?.dict("data")?.dict("attributes")?["map"] as? [String: Bool] {
                map.merge(entries) { $1 }
            }
        }
        return map
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// "Vol.2 Ch.10 - Nome", como na extensão.
    static func chapterName(_ attrs: [String: Any]) -> String {
        var parts = ""
        if let volume = attrs.string("volume")?.nilIfEmpty { parts += "Vol.\(volume)" }
        if let number = attrs.string("chapter")?.nilIfEmpty { parts += (parts.isEmpty ? "" : " ") + "Ch.\(number)" }
        if let name = attrs.string("name")?.nilIfEmpty { parts += (parts.isEmpty ? "" : " - ") + name }
        return parts.isEmpty ? "Oneshot" : parts
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let data: Data
        do {
            data = try await http.data("\(Self.api)/images/chapter/\(chapterRemoteUrl)?newQualities=true").0
        } catch HTTPError.badStatus(402) {
            throw HTTPError.parse("as páginas: capítulo pago, compre no site da NamiComi")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let info = root.dict("data"),
              let base = info.string("baseUrl"), let hash = info.string("hash") else {
            throw HTTPError.parse("as páginas")
        }
        let prefix = "\(base)/chapter/\(chapterRemoteUrl)/\(hash)/source/"
        return info.array("source").compactMap { $0.string("filename") }.enumerated().map {
            SourcePageItem(pageNumber: $0.offset + 1, imageUrl: prefix + $0.element, referer: "\(baseUrl)/")
        }
    }
}

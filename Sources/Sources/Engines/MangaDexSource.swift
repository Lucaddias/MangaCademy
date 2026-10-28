import Foundation

/// MangaDex via API oficial (extensão all.mangadex do Keiyoushi).
/// Uma única fonte cobre os 60+ idiomas: cada obra informa em quais idiomas tem capítulos.
public final class MangaDexSource: LanguageScopedSource {
    public let id = "mangadex"
    public let name = "MangaDex"
    public let language = "all"
    public let baseUrl = "https://mangadex.org"
    public var imageReferer: String? { nil }

    private let api = "https://api.mangadex.org"
    private let userAgent = "MangaCademy-iOS/1.0"
    private let pageSize = 24
    private let languageFilter: LanguageFilter
    private let includeNsfw: Bool
    private let http = HTTPClient.shared

    public init(languageFilter: LanguageFilter = .all, includeNsfw: Bool = false) {
        self.languageFilter = languageFilter
        self.includeNsfw = includeNsfw
    }

    public func scoped(to filter: LanguageFilter, includeNsfw: Bool) -> MangaSource? {
        MangaDexSource(languageFilter: filter, includeNsfw: includeNsfw)
    }

    private var contentRatings: [String] {
        includeNsfw ? ["safe", "suggestive", "erotica", "pornographic"] : ["safe", "suggestive"]
    }

    // MARK: - Catálogo

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await list(page: page, extra: [("order[followedCount]", "desc")])
    }

    /// Como no Mihon: os capítulos mais novos no idioma do filtro (e não o último capítulo em
    /// qualquer idioma), uma obra por vez, na ordem em que saíram.
    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        let limit = 100
        let offset = (page - 1) * limit
        guard offset + limit <= 10_000 else { return .empty }
        var params: [(String, String)] = [
            ("limit", "\(limit)"),
            ("offset", "\(offset)"),
            ("order[readableAt]", "desc"),
            ("includeFutureUpdates", "0"),
            ("includeExternalUrl", "0"),
            ("includeEmptyPages", "0"),
        ]
        params += contentRatings.map { ("contentRating[]", $0) }
        params += languageFilter.mangaDexLanguages.map { ("translatedLanguage[]", $0) }
        guard let root = try await http.json(url("/chapter", params), userAgent: userAgent) as? [String: Any] else { return .empty }

        var order: [String] = []
        var newest: [String: (name: String, date: Date?)] = [:]
        for chapter in root.array("data") {
            guard let mangaId = chapter.array("relationships").first(where: { $0.string("type") == "manga" })?.string("id"),
                  newest[mangaId] == nil else { continue }
            let attrs = chapter.dict("attributes") ?? [:]
            order.append(mangaId)
            newest[mangaId] = (
                attrs.string("chapter").map { "Cap. \($0)" } ?? attrs.string("title")?.nilIfEmpty ?? "Oneshot",
                attrs.string("readableAt").flatMap(DateParsing.iso)
            )
        }
        let total = root.int("total") ?? 0
        let hasNext = offset + limit < min(total, 10_000)
        guard !order.isEmpty else { return SourceMangaPage(items: [], hasNextPage: hasNext) }

        var mangaParams: [(String, String)] = [("limit", "\(order.count)"), ("includes[]", "cover_art")]
        mangaParams += order.map { ("ids[]", $0) }
        mangaParams += contentRatings.map { ("contentRating[]", $0) }
        guard let mangaRoot = try await http.json(url("/manga", mangaParams), userAgent: userAgent) as? [String: Any] else { return .empty }
        let byId = Dictionary(
            mangaRoot.array("data").compactMap { manga in manga.string("id").map { ($0, manga) } },
            uniquingKeysWith: { first, _ in first }
        )
        let items: [SourceMangaItem] = order.compactMap { mangaId in
            guard let manga = byId[mangaId], var item = makeItem(manga) else { return nil }
            item.latestChapterName = newest[mangaId]?.name
            item.latestChapterDate = newest[mangaId]?.date
            return item
        }
        return SourceMangaPage(items: items, hasNextPage: hasNext)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await list(page: page, extra: [("title", query), ("order[relevance]", "desc")])
    }

    private func list(page: Int, extra: [(String, String)]) async throws -> SourceMangaPage {
        let offset = (page - 1) * pageSize
        guard offset + pageSize <= 10_000 else { return .empty }
        var params: [(String, String)] = [
            ("limit", "\(pageSize)"),
            ("offset", "\(offset)"),
            ("includes[]", "cover_art"),
            ("hasAvailableChapters", "true"),
        ]
        params += contentRatings.map { ("contentRating[]", $0) }
        params += languageFilter.mangaDexLanguages.map { ("availableTranslatedLanguage[]", $0) }
        params += extra

        guard let root = try await http.json(url("/manga", params), userAgent: userAgent) as? [String: Any] else { return .empty }
        let items = root.array("data").compactMap(makeItem)
        let total = root.int("total") ?? 0
        return SourceMangaPage(items: items, hasNextPage: offset + pageSize < min(total, 10_000))
    }

    private func url(_ path: String, _ params: [(String, String)]) -> String {
        let query = params.map { "\(HTTPClient.queryEncode($0.0))=\(HTTPClient.queryEncode($0.1))" }.joined(separator: "&")
        return "\(api)\(path)?\(query)"
    }

    private func makeItem(_ manga: [String: Any]) -> SourceMangaItem? {
        guard let mangaId = manga.string("id"), let attrs = manga.dict("attributes") else { return nil }
        let titles = allTitles(attrs)
        let languages = (attrs["availableTranslatedLanguages"] as? [Any] ?? [])
            .compactMap { $0 as? String }
            .map(LanguageCode.normalize)
        return SourceMangaItem(
            sourceId: id,
            remoteUrl: mangaId,
            title: preferredTitle(attrs),
            coverUrl: coverURL(mangaId: mangaId, relationships: manga.array("relationships")),
            status: attrs.string("status"),
            languages: languages,
            altTitles: titles,
            genres: genres(attrs),
            hasFullMetadata: true
        )
    }

    /// Tags em inglês; classificação erótica/pornográfica conta como "Adult".
    private func genres(_ attrs: [String: Any]) -> [String] {
        var tags = attrs.array("tags").compactMap { ($0.dict("attributes")?["name"] as? [String: String])?["en"] }
        if ["erotica", "pornographic"].contains(attrs.string("contentRating") ?? "") { tags.append("Adult") }
        return tags
    }

    /// Todos os títulos (principal + alternativos) — essencial para unificar com fontes PT/EN.
    private func allTitles(_ attrs: [String: Any]) -> [String] {
        var titles = Array((attrs["title"] as? [String: String] ?? [:]).values)
        for alt in attrs["altTitles"] as? [[String: String]] ?? [] {
            titles += alt.values
        }
        return titles
    }

    /// Título no idioma do filtro, depois inglês, depois o principal.
    private func preferredTitle(_ attrs: [String: Any]) -> String {
        let main = attrs["title"] as? [String: String] ?? [:]
        let alts = attrs["altTitles"] as? [[String: String]] ?? []
        let wanted: [String]
        switch languageFilter {
        case .portuguese: wanted = ["pt-br", "pt", "en"]
        case .english, .all: wanted = ["en"]
        }
        for lang in wanted {
            if let t = main[lang] { return t }
            if let t = alts.first(where: { $0[lang] != nil })?[lang] { return t }
        }
        return main.values.first ?? alts.first?.values.first ?? "Sem título"
    }

    private func coverURL(mangaId: String, relationships: [[String: Any]]) -> String? {
        guard let file = relationships.first(where: { $0.string("type") == "cover_art" })?.dict("attributes")?.string("fileName") else { return nil }
        return "https://uploads.mangadex.org/covers/\(mangaId)/\(file).256.jpg"
    }

    // MARK: - Detalhes e capítulos (todos os idiomas)

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let detailURL = url("/manga/\(remoteUrl)", [("includes[]", "author"), ("includes[]", "artist"), ("includes[]", "cover_art")])
        guard let root = try await http.json(detailURL, userAgent: userAgent) as? [String: Any],
              let manga = root.dict("data"), let attrs = manga.dict("attributes") else {
            throw HTTPError.parse("os detalhes da obra")
        }
        let relationships = manga.array("relationships")
        func names(_ type: String) -> String? {
            let list = relationships.filter { $0.string("type") == type }.compactMap { $0.dict("attributes")?.string("name") }
            return list.isEmpty ? nil : list.joined(separator: ", ")
        }
        let descriptions = attrs["description"] as? [String: String] ?? [:]
        let description = descriptions["pt-br"] ?? descriptions["en"] ?? descriptions.values.first
        let genres = genres(attrs)
        let statusMap = ["ongoing": 1, "completed": 2, "cancelled": 3, "hiatus": 4]
        let largeCover = coverURL(mangaId: remoteUrl, relationships: relationships)?.replacingOccurrences(of: ".256.jpg", with: ".512.jpg")

        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: preferredTitle(attrs),
            author: names("author"),
            artist: names("artist"),
            description: description,
            genres: genres,
            status: statusMap[attrs.string("status") ?? ""] ?? 0,
            coverUrl: largeCover,
            altTitles: allTitles(attrs)
        )
        return (detail, try await fetchChapters(mangaId: remoteUrl))
    }

    private func fetchChapters(mangaId: String) async throws -> [SourceChapterItem] {
        var chapters: [SourceChapterItem] = []
        var offset = 0
        let limit = 500
        while offset < 10_000 {
            var params: [(String, String)] = [
                ("limit", "\(limit)"),
                ("offset", "\(offset)"),
                ("includes[]", "scanlation_group"),
                ("order[volume]", "desc"),
                ("order[chapter]", "desc"),
                ("includeExternalUrl", "0"),
                ("includeEmptyPages", "0"),
            ]
            params += ["safe", "suggestive", "erotica", "pornographic"].map { ("contentRating[]", $0) }
            let response = try await http.json(url("/manga/\(mangaId)/feed", params), userAgent: userAgent)
            let (data, total) = try Self.chapterFeedPage(response)
            for ch in data {
                guard let chapterId = ch.string("id"), let attrs = ch.dict("attributes") else { continue }
                if attrs.string("externalUrl") != nil { continue }
                let number = attrs.string("chapter")
                let volume = attrs.string("volume")
                var name = ""
                if let volume, !volume.isEmpty { name += "Vol. \(volume) " }
                name += number.map { "Cap. \($0)" } ?? "Oneshot"
                if let title = attrs.string("title")?.nilIfEmpty { name += ": \(title)" }
                let groups = ch.array("relationships")
                    .filter { $0.string("type") == "scanlation_group" }
                    .compactMap { $0.dict("attributes")?.string("name") }
                chapters.append(SourceChapterItem(
                    remoteUrl: chapterId,
                    name: name,
                    chapterNumber: number.flatMap(Double.init) ?? -1,
                    orderIndex: chapters.count,
                    scanlator: groups.isEmpty ? nil : groups.joined(separator: ", "),
                    uploadDate: attrs.string("publishAt").flatMap(DateParsing.iso),
                    language: LanguageCode.normalize(attrs.string("translatedLanguage") ?? "en"),
                    sourceId: id,
                    mangaRemoteUrl: mangaId
                ))
            }
            offset += limit
            if data.isEmpty || offset >= total { break }
        }
        return chapters
    }

    static func chapterFeedPage(_ response: Any) throws -> ([[String: Any]], Int) {
        guard let root = response as? [String: Any],
              let data = root["data"] as? [[String: Any]],
              let total = root.int("total"), total >= 0 else {
            throw HTTPError.parse("a lista de capítulos do MangaDex")
        }
        return (data, total)
    }

    // MARK: - Páginas

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        guard let root = try await http.json("\(api)/at-home/server/\(chapterRemoteUrl)", userAgent: userAgent) as? [String: Any],
              let server = root.string("baseUrl"),
              let chapter = root.dict("chapter"),
              let hash = chapter.string("hash") else {
            throw HTTPError.parse("as páginas do MangaDex")
        }
        let files = chapter["data"] as? [String] ?? []
        return files.enumerated().map { index, file in
            SourcePageItem(pageNumber: index + 1, imageUrl: "\(server)/data/\(hash)/\(file)")
        }
    }
}

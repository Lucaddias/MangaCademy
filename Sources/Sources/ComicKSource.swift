import Foundation

/// ComicK (extensão all.comicklive do Keiyoushi). Uma fonte com capítulos em vários idiomas.
public final class ComicKSource: LanguageScopedSource {
    public let id: String = "comick"
    public let name: String = "ComicK"
    public let language: String = "all"
    public let baseUrl: String

    private let http = HTTPClient.shared
    private let languageFilter: LanguageFilter
    private let includeNsfw: Bool
    /// Cursores de paginação (a API usa `next_cursor` em vez de número de página).
    private var cursors: [String: String] = [:]
    private let lock = NSLock()

    public init(baseUrl: String = "https://comick.live", languageFilter: LanguageFilter = .all, includeNsfw: Bool = false) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.languageFilter = languageFilter
        self.includeNsfw = includeNsfw
    }

    /// O catálogo do ComicK não filtra por idioma; a maioria das obras tem capítulos em inglês,
    /// então ele participa de "Inglês" e "Todos", mas não de "Português".
    public func scoped(to filter: LanguageFilter, includeNsfw: Bool) -> MangaSource? {
        filter == .portuguese ? nil : ComicKSource(baseUrl: baseUrl, languageFilter: filter, includeNsfw: includeNsfw)
    }

    private var headers: [String: String] { ["Referer": "\(baseUrl)/"] }

    // MARK: - Catálogo

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        // Mesma estratégia da extensão: 6 "páginas" = 3 períodos × 2 rankings
        guard (1...6).contains(page) else { return .empty }
        let days = [7, 30, 90][(page - 1) % 3]
        let type = page <= 3 ? "follow" : "most_follow_new"
        guard let json = try await http.json("\(baseUrl)/api/comics/top?day=\(days)&type=\(type)", headers: headers) as? [String: Any] else { return .empty }
        return SourceMangaPage(items: json.array("data").compactMap(makeItem), hasNextPage: page < 6)
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await cursorList(key: "latest", page: page, base: "\(baseUrl)/api/chapters/latest?order=new&page=\(page)")
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        let q = query.trimmed
        guard q.count >= 3 else { return .empty }
        let base = "\(baseUrl)/api/search?showAll=false&exclude_mylist=false&type=comic&q=\(HTTPClient.queryEncode(q))"
        return try await cursorList(key: "search:\(q)", page: page, base: base)
    }

    private func cursorList(key: String, page: Int, base: String) async throws -> SourceMangaPage {
        var url = base
        if page > 1 {
            guard let cursor = cursor(for: "\(key)#\(page)") else { return .empty }
            url += "&cursor=\(HTTPClient.queryEncode(cursor))"
        }
        guard let json = try await http.json(url, headers: headers) as? [String: Any] else { return .empty }
        let next = json.string("next_cursor")?.nilIfEmpty
        if let next { setCursor(next, for: "\(key)#\(page + 1)") }
        return SourceMangaPage(items: json.array("data").compactMap(makeItem), hasNextPage: next != nil)
    }

    private func cursor(for key: String) -> String? {
        lock.withLock { cursors[key] }
    }
    
    private func setCursor(_ value: String, for key: String) {
        lock.withLock { cursors[key] = value }
    }
    
    private func makeItem(_ comic: [String: Any]) -> SourceMangaItem? {
        guard let slug = comic.string("slug"), let title = comic.string("title") else { return nil }
        let rating = comic.string("content_rating") ?? "safe"
        if !includeNsfw && rating == "erotica" { return nil }
        // `chapter_latest_by_langs` (só em "Recentes") revela os idiomas disponíveis
        let languages = (comic["chapter_latest_by_langs"] as? [String: Any])?.keys.map(LanguageCode.normalize) ?? []
        if languageFilter == .english, !languages.isEmpty, !languages.contains(where: { LanguageCode.base($0) == "en" }) {
            return nil
        }
        return SourceMangaItem(
            sourceId: id,
            remoteUrl: slug,
            title: title,
            coverUrl: comic.string("default_thumbnail"),
            languages: languages.sorted(),
            genres: rating == "erotica" ? ["Adult"] : []
        )
    }

    // MARK: - Detalhes

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        async let chaptersTask = fetchChapters(slug: remoteUrl)
        let detail = try await fetchMetadata(remoteUrl: remoteUrl)
        return (detail, try await chaptersTask)
    }
    
    public func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail {
        let doc = try await http.html("\(baseUrl)/comic/\(remoteUrl)", headers: headers)
        guard let raw = doc.first("//script[@id='comic-data']")?.rawText,
              let data = raw.data(using: .utf8),
              let comic = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.parse("os detalhes da obra")
        }
        let names: (String) -> String? = { key in
            let list = comic.array(key).compactMap { $0.string("name") }
            return list.isEmpty ? nil : list.joined(separator: ", ")
        }
        var altTitles: [String] = []
        if let list = comic["md_titles"] as? [[String: Any]] {
            altTitles = list.compactMap { $0.string("title") }
        } else if let dict = comic["md_titles"] as? [String: Any] {
            altTitles = dict.values.compactMap { ($0 as? [String: Any])?.string("title") }
        }
        let description = comic.string("desc").flatMap { html in
            HTMLDocument(html: "<div>\(html)</div>", url: nil)?.first("//div")?.text
        }
        var genres: [String] = []
        switch comic.string("country") {
        case "jp": genres.append("Manga")
        case "kr": genres.append("Manhwa")
        case "cn": genres.append("Manhua")
        default: break
        }
        genres += comic.array("md_comic_md_genres").compactMap { $0.dict("md_genres")?.string("name") }
        if comic.string("content_rating") == "erotica" { genres.append("Adult") }

        return SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: comic.string("title") ?? remoteUrl,
            author: names("authors"),
            artist: names("artists"),
            description: description,
            genres: genres,
            status: comic.int("status") ?? 0,
            coverUrl: comic.string("default_thumbnail"),
            altTitles: altTitles
        )
    }

    /// Lista paginada com capítulos de todos os idiomas (cada capítulo informa `lang`).
    private func fetchChapters(slug: String) async throws -> [SourceChapterItem] {
        let base = "\(baseUrl)/api/comics/\(slug)/chapter-list"
        let headers = self.headers
        let http = self.http
        guard let first = try await http.json(base, headers: headers) as? [String: Any] else { return [] }
        var raw = first.array("data")
        let lastPage = min(first.dict("pagination")?.int("last_page") ?? 1, 80)
        if lastPage > 1 {
            let pages = await withTaskGroup(of: (Int, [[String: Any]]).self) { group in
                for page in 2...lastPage {
                    group.addTask {
                        let json = try? await http.json("\(base)?page=\(page)", headers: headers) as? [String: Any]
                        return (page, json?.array("data") ?? [])
                    }
                }
                var result: [(Int, [[String: Any]])] = []
                for await item in group { result.append(item) }
                return result.sorted { $0.0 < $1.0 }
            }
            for (_, list) in pages { raw += list }
        }

        return raw.enumerated().compactMap { index, ch in
            guard let hid = ch.string("hid") else { return nil }
            let chap = ch.string("chap")
            let lang = ch.string("lang") ?? "en"
            var name = ""
            if let vol = ch.string("vol")?.nilIfEmpty { name += "Vol. \(vol) " }
            name += chap.map { "Cap. \($0)" } ?? "Oneshot"
            if let title = ch.string("title")?.nilIfEmpty { name += ": \(title)" }
            let groups = ch["group_name"] as? [String] ?? []
            return SourceChapterItem(
                remoteUrl: "/comic/\(slug)/\(hid)-chapter-\(chap ?? "0")-\(lang)",
                name: name,
                chapterNumber: chap.flatMap(Double.init) ?? -1,
                orderIndex: index,
                scanlator: groups.isEmpty ? nil : groups.joined(separator: ", "),
                uploadDate: ch.string("created_at").flatMap(DateParsing.iso),
                language: LanguageCode.normalize(lang),
                sourceId: id,
                mangaRemoteUrl: slug
            )
        }
    }

    // MARK: - Páginas

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let url = chapterRemoteUrl.hasPrefix("http") ? chapterRemoteUrl : baseUrl + chapterRemoteUrl
        let doc = try await http.html(url, headers: headers)
        guard let raw = doc.first("//script[@id='sv-data']")?.rawText,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chapter = json.dict("chapter") else {
            throw HTTPError.parse("as páginas do ComicK")
        }
        return chapter.array("images").enumerated().compactMap { index, img in
            guard let imgUrl = img.string("url") else { return nil }
            return SourcePageItem(pageNumber: index + 1, imageUrl: imgUrl, width: img.int("w"), height: img.int("h"), referer: "\(baseUrl)/")
        }
    }
}

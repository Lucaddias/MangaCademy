import Foundation

/// Port do tema ZeistManga (Blogger) — lib-multisrc/zeistmanga. Usa o feed JSON do Blogger.
public final class ZeistMangaSource: ThemeSource, MangaSource {
    private var mangaCategory: String { config.mangaCategory ?? "Series" }
    private var chapterCategory: String { config.chapterCategory ?? "Chapter" }
    private let pageSize = 20
    private let excludedCategories: Set<String> = ["Anime", "Novel", "Novela"]

    private func feedURL(category: String) -> String {
        "\(baseUrl)/feeds/posts/default/-/\(category.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? category)?alt=json"
    }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await fetchLatest(page: page)
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        let start = pageSize * (page - 1) + 1
        return try await parseList(feedURL(category: mangaCategory) + "&orderby=published&max-results=\(pageSize + 1)&start-index=\(start)")
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        let start = pageSize * (page - 1) + 1
        let q = HTTPClient.queryEncode("label:\(mangaCategory) \(query)").replacingOccurrences(of: "%20", with: "+")
        return try await parseList(feedURL(category: mangaCategory) + "&q=\(q)&max-results=\(pageSize + 1)&start-index=\(start)")
    }

    private func parseList(_ url: String) async throws -> SourceMangaPage {
        guard let root = try await http.json(url) as? [String: Any] else { return .empty }
        let entries = root.dict("feed")?.array("entry") ?? []
        let items: [SourceMangaItem] = entries.compactMap { entry in
            let terms = Set(entry.array("category").compactMap { $0.string("term") })
            guard terms.contains(mangaCategory), terms.isDisjoint(with: excludedCategories) else { return nil }
            guard let title = entry.dict("title")?.string("$t"), let link = alternateLink(entry) else { return nil }
            return item(remoteUrl: storedPath(link), title: title, cover: thumbnail(entry))
        }
        let hasNext = entries.count > pageSize
        return SourceMangaPage(items: Array(items.prefix(pageSize)), hasNextPage: hasNext)
    }

    private func alternateLink(_ entry: [String: Any]) -> String? {
        entry.array("link").first { $0.string("rel") == "alternate" }?.string("href")
    }

    private func thumbnail(_ entry: [String: Any]) -> String? {
        if let url = entry.dict("media$thumbnail")?.string("url") {
            return url
                .replacingOccurrences(of: #"/s\d+-c/"#, with: "/w600/", options: .regularExpression)
                .replacingOccurrences(of: #"=s\d+-c$"#, with: "=w600", options: .regularExpression)
        }
        if let html = entry.dict("content")?.string("$t"),
           let doc = HTMLDocument(html: html, url: URL(string: baseUrl)) {
            return doc.first("//img")?.imageURL
        }
        return nil
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let doc = try await http.html(absoluteURL(remoteUrl))
        let detail = parseDetail(doc, remoteUrl: remoteUrl)
        let label = chapterLabel(doc) ?? detail.title
        var chapters = try await fetchChapterFeed(label: label)
        chapters = chapters.map { var c = $0; c.mangaRemoteUrl = remoteUrl; return c }
        return (detail, chapters)
    }

    public func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail {
        parseDetail(try await http.html(absoluteURL(remoteUrl)), remoteUrl: remoteUrl)
    }

    private func parseDetail(_ doc: HTMLDocument, remoteUrl: String) -> SourceMangaDetail {
        let ogTitle = doc.first("//meta[@property='og:title']")?.attr("content")
        let title = doc.first("//header//h1 | //h1[\(cls("entry-title"))] | //h1")?.text.nilIfEmpty ?? ogTitle ?? remoteUrl
        let description = doc.first("//*[@id='synopsis'] | //*[\(cls("synopsis"))]")?.text.nilIfEmpty
            ?? doc.first("//meta[@property='og:description']")?.attr("content")
        let genres = doc.select("//div[\(cls("mt-15"))]/a[@rel='tag'] | //*[\(cls("genres"))]//a").map(\.text).filter { !$0.isEmpty }
        return SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: title,
            author: doc.first("//span[@id='author']")?.text.nilIfEmpty,
            artist: doc.first("//span[@id='artist']")?.text.nilIfEmpty,
            description: description,
            genres: genres,
            status: StatusParser.parse(doc.first("//span[@data-status]")?.text),
            coverUrl: doc.first("//meta[@property='og:image']")?.attr("content") ?? doc.first("//*[\(cls("thumb"))]//img")?.imageURL
        )
    }

    /// O rótulo do feed de capítulos fica em scripts como `clwd.run('XYZ')` ou `label = 'XYZ'`.
    private func chapterLabel(_ doc: HTMLDocument) -> String? {
        let scripts = doc.scriptsText
        let patterns = [#"clwd\.run\(["'](.*?)["']\)"#, #"var\s+label\s*=\s*'([^']+)'"#, #"/feeds/posts/default/-/[^/'"]+/([^?'"]+)\?"#]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: scripts, range: NSRange(scripts.startIndex..., in: scripts)),
               let range = Range(match.range(at: 1), in: scripts) {
                let value = String(scripts[range]).removingPercentEncoding ?? String(scripts[range])
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private func fetchChapterFeed(label: String) async throws -> [SourceChapterItem] {
        let encodedLabel = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?.replacingOccurrences(of: "/", with: "%2F") ?? label
        let base = "\(baseUrl)/feeds/posts/default/-/\(chapterCategory)/\(encodedLabel)?alt=json"
        var entries: [[String: Any]] = []
        var start = 1
        let chunk = 150
        while start < 5000 {
            guard let root = try await http.json("\(base)&start-index=\(start)&max-results=\(chunk)") as? [String: Any] else { break }
            let feed = root.dict("feed")
            let page = feed?.array("entry") ?? []
            entries += page
            let total = Int(feed?.dict("openSearch$totalResults")?.string("$t") ?? "") ?? entries.count
            if page.isEmpty || entries.count >= total { break }
            start += page.count
        }
        return entries.enumerated().compactMap { index, entry in
            let terms = Set(entry.array("category").compactMap { $0.string("term") })
            guard terms.contains(chapterCategory),
                  let name = entry.dict("title")?.string("$t"),
                  let link = alternateLink(entry) else { return nil }
            let date = entry.dict("published")?.string("$t").flatMap(DateParsing.iso)
            return chapter(remoteUrl: storedPath(link), name: name, index: index, date: date)
        }
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let doc = try await http.html(absoluteURL(chapterRemoteUrl))
        var images = doc.select("//div[\(cls("check-box"))]//div[\(cls("separator"))]//img")
        if images.isEmpty { images = doc.select("//div[\(cls("check-box"))]//img | //*[@id='reader']//img | //div[\(cls("post-body"))]//img") }
        var seen = Set<String>()
        let urls = images.compactMap(\.imageURL).filter { seen.insert($0).inserted }
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: "\(baseUrl)/") }
    }
}

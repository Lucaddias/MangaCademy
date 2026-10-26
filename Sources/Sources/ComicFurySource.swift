import Foundation

/// Port da extensão Comic Fury — src/all/comicfury (HTML). Cada idioma do catálogo é uma fonte;
/// cada "comic" (tira ou página) do webcomic vira um capítulo.
public final class ComicFurySource: ThemeSource, MangaSource {
    /// Idioma usado na busca do site ("other" sem texto vira "notext").
    private var siteLanguage: String {
        if language == "other" && name.hasSuffix("(No Text)") { return "notext" }
        return language == "pt-BR" ? "pt" : language
    }

    /// Obras com aviso de conteúdo mostram um formulário antes: confirma e segue.
    private func page(_ url: String) async throws -> HTMLDocument {
        let doc = try await http.html(url)
        guard doc.first("//title")?.text.contains("Content Warning") == true,
              doc.first("//input[@name='proceed' and @value='View Webcomic']") != nil,
              let token = doc.first("//input[@name='token']")?.attr("value") else { return doc }
        return try await http.postFormHTML(url, fields: [("token", token), ("proceed", "View Webcomic")])
    }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await searchPage(page: page, query: "", sort: 1)
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await searchPage(page: page, query: "", sort: 2)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await searchPage(page: page, query: query, sort: 0)
    }

    private func searchPage(page number: Int, query: String, sort: Int) async throws -> SourceMangaPage {
        let doc = try await page("\(baseUrl)/search.php?query=\(HTTPClient.queryEncode(query))&page=\(number)&language=\(siteLanguage)&sort=\(sort)")
        let items: [SourceMangaItem] = doc.select("//div[\(cls("webcomic-result"))]").compactMap { result in
            guard let link = result.first(".//div[\(cls("webcomic-result-avatar"))]//a"), let href = link.absAttr("href"),
                  let title = result.first(".//div[\(cls("webcomic-result-title"))]")?.attr("title")?.nilIfEmpty else { return nil }
            return item(remoteUrl: storedPath(href), title: title, cover: link.first(".//img")?.absAttr("src"))
        }
        return SourceMangaPage(items: items, hasNextPage: doc.first("//div[\(cls("search-next-page"))]") != nil)
    }

    /// "/comicprofile.php?url=slug" → "slug".
    private func slug(_ remoteUrl: String) -> String {
        URLComponents(string: absoluteURL(remoteUrl))?.queryItems?.first { $0.name == "url" }?.value
            ?? remoteUrl.split(separator: "/").dropFirst().first.map(String.init) ?? remoteUrl
    }

    public func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail {
        let doc = try await page(absoluteURL(remoteUrl))
        let tags = doc.first("//div[\(cls("description-tags"))]")
        let genres = tags.map { $0.select("./*").map(\.text) }
            ?? doc.select("//div[\(cls("authorinfo")) and contains(., 'Genre')]//a").map(\.text)
        return SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: doc.first("//div[\(cls("username-and-title"))]/div[\(cls("authorname"))]")?.ownText.nilIfEmpty
                ?? doc.first("//title")?.text.components(separatedBy: " - ").first?.nilIfEmpty ?? slug(remoteUrl),
            author: doc.select("//a[\(cls("authorname"))]").map(\.text).filter { !$0.isEmpty }.joined(separator: ", ").nilIfEmpty,
            description: (tags?.first("..")?.ownText ?? doc.first("//div[\(cls("username-and-title"))]/em")?.text)?.nilIfEmpty,
            genres: genres.filter { !$0.isEmpty },
            status: StatusParser.parse(doc.first("//div[\(cls("authorinfo")) and contains(., 'Activity status')]//span[\(cls("info"))]")?.text),
            coverUrl: doc.first("//div[\(cls("profile-avatar"))]//img")?.absAttr("src")
        )
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        async let detail = fetchMetadata(remoteUrl: remoteUrl)
        let archive = try await page("\(baseUrl)/read/\(slug(remoteUrl))/archive")

        // Com capítulos, cada um tem o próprio arquivo paginado; sem, é uma lista só
        var entries: [(url: String, title: String, date: Date?)] = []
        let groups = archive.select("//a[.//div[\(cls("archive-chapter"))]]")
        if groups.isEmpty {
            entries = try await collect(archive, header: nil)
        } else {
            for group in groups {
                guard let href = group.absAttr("href") else { continue }
                let header = group.first(".//*[\(cls("archive-chapter-title"))]")?.text.nilIfEmpty ?? group.text
                entries += try await collect(try await page(href), header: header)
            }
        }
        let total = entries.count
        let chapters: [SourceChapterItem] = entries.enumerated().reversed().map { position, entry in
            var item = chapter(remoteUrl: storedPath(entry.url), name: entry.title, index: total - 1 - position, number: Double(position + 1), date: entry.date)
            item.mangaRemoteUrl = remoteUrl
            return item
        }
        return (try await detail, chapters)
    }

    /// Todas as páginas de um arquivo, seguindo a paginação.
    private func collect(_ start: HTMLDocument, header: String?) async throws -> [(url: String, title: String, date: Date?)] {
        var result: [(url: String, title: String, date: Date?)] = []
        var current = start
        var visited = Set<String>()
        while true {
            for link in current.select("//a[div[\(cls("archive-comic"))]]") {
                guard let href = link.absAttr("href") else { continue }
                let title = link.first(".//*[\(cls("archive-comic-title"))]")?.text ?? ""
                result.append((href, header.map { "\($0) - \(title)" } ?? title, Self.date(link.first(".//*[\(cls("archive-comic-date"))]")?.text)))
            }
            guard let next = current.first("//span[\(cls("vfpagecurrent"))]/following-sibling::a[1][\(cls("vfpage"))]")?.absAttr("href"),
                  visited.insert(next).inserted else { break }
            current = try await page(next)
        }
        return result
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let url = absoluteURL(chapterRemoteUrl)
        let doc = try await page(url)
        // A rolagem infinita já traz as próximas tiras: só a primeira é deste capítulo
        var urls = doc.select("(//div[\(cls("is--comic-page"))])[1]//div[\(cls("is--image-segment"))]//img").compactMap { $0.absAttr("src") }
        if urls.isEmpty { urls = doc.select("//img[@id='comicimage']").compactMap { $0.absAttr("src") } }
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: url) }
    }

    private static let formatters: [DateFormatter] = ["d MMM yyyy h:mm a", "d MMMM yyyy h:mm a", "d MMM yyyy", "d MMMM yyyy", "MMM d yyyy", "MMMM d yyyy", "d.M.yyyy"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = $0
        return formatter
    }
    private static let lock = NSLock()

    /// "29th Jul 2024, 5:15 PM", "Jul 29 2024", "29.7.2024".
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: #"(?<=\d)(st|nd|rd|th)|,"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        lock.lock()
        defer { lock.unlock() }
        return formatters.lazy.compactMap { $0.date(from: cleaned) }.first
    }
}

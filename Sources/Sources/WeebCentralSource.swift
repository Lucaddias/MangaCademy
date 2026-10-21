import Foundation

/// Weeb Central (extensão en.weebcentral do Keiyoushi) — HTML gerado com HTMX.
public final class WeebCentralSource: MangaSource {
    public let id: String = "weebcentral"
    public let name: String = "Weeb Central"
    public let language: String = "en"
    public let baseUrl: String = "https://weebcentral.com"

    private let pageSize = 32
    private let http = HTTPClient.shared

    public init() {}

    private var headers: [String: String] { ["Referer": "\(baseUrl)/"] }

    // MARK: - Catálogo

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await list(page: page, sort: "Popularity", text: nil)
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await list(page: page, sort: "Latest Updates", text: nil)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await list(page: page, sort: "Best Match", text: query.trimmed)
    }

    private func list(page: Int, sort: String, text: String?) async throws -> SourceMangaPage {
        var url = "\(baseUrl)/search/data?limit=\(pageSize)&offset=\((page - 1) * pageSize)"
            + "&sort=\(HTTPClient.queryEncode(sort))&order=Descending&official=Any&anime=Any&adult=Any"
            + "&display_mode=\(HTTPClient.queryEncode("Full Display"))"
        if let text, !text.isEmpty { url += "&text=\(HTTPClient.queryEncode(text))" }
        let doc = try await http.html(url, headers: headers)

        var seen = Set<String>()
        let items: [SourceMangaItem] = doc.select("//article[.//a[contains(@href, '/series/')]]").compactMap { article in
            guard let link = article.first(".//a[contains(@href, '/series/')]"),
                  let href = link.absAttr("href"), seen.insert(href.urlPath).inserted else { return nil }
            let title = [
                article.first(".//a[contains(@href, '/series/')][normalize-space()]")?.text,
                article.first(".//*[\(cls("truncate"))]")?.text,
                article.first(".//img")?.attr("alt")?.replacingOccurrences(of: " cover", with: ""),
            ].compactMap { $0?.trimmed.nilIfEmpty }.first
            guard let title else { return nil }
            let tags = article.select(".//strong[contains(., 'Tag')]/following-sibling::*//text()|.//strong[contains(., 'Tag')]/..//a")
                .map(\.text).filter { !$0.isEmpty }
            return SourceMangaItem(
                sourceId: id,
                remoteUrl: href.urlPath,
                title: title,
                coverUrl: article.first(".//img")?.imageURL,
                languages: [language],
                genres: tags
            )
        }
        // O botão "View More" só aparece quando há mais resultados
        let hasMore = items.count >= pageSize || doc.first("//button[contains(., 'View More')]") != nil
        return SourceMangaPage(items: items, hasNextPage: hasMore && !items.isEmpty)
    }

    // MARK: - Detalhes

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        async let chaptersTask = fetchChapters(remoteUrl: remoteUrl)
        let detail = try await fetchMetadata(remoteUrl: remoteUrl)
        return (detail, (try? await chaptersTask) ?? [])
    }

    public func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail {
        let doc = try await http.html(baseUrl + remoteUrl, headers: headers)
        guard let title = doc.first("//h1")?.text.nilIfEmpty else { throw HTTPError.parse("os detalhes da obra") }

        /// Itens da lista lateral: `<li><strong>Tags(s):</strong> <span><a>…</a></span></li>`.
        func field(_ label: String) -> HTMLElement? {
            doc.first("//li[strong[contains(., '\(label)')]]")
        }
        func links(_ label: String) -> [String] {
            field(label)?.select(".//a").map(\.text).filter { !$0.isEmpty } ?? []
        }

        var genres = links("Type") + links("Tag")
        if field("Adult Content")?.text.localizedCaseInsensitiveContains("yes") == true {
            genres.append("Adult")
        }
        let altTitles = field("Associated Name")?.select(".//li").map(\.text).filter { !$0.isEmpty } ?? []

        return SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: title,
            author: links("Author").joined(separator: ", ").nilIfEmpty,
            artist: nil,
            description: field("Description")?.first(".//p")?.text,
            genres: genres,
            status: StatusParser.parse(links("Status").first),
            coverUrl: doc.first("//section//picture//img|//section//img")?.imageURL,
            altTitles: altTitles
        )
    }

    /// `/series/<id>/<slug>` → `/series/<id>/full-chapter-list`
    private func fetchChapters(remoteUrl: String) async throws -> [SourceChapterItem] {
        let parts = remoteUrl.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "series"), index + 1 < parts.count else { return [] }
        let doc = try await http.html("\(baseUrl)/series/\(parts[index + 1])/full-chapter-list", headers: headers)
        return doc.select("//a[contains(@href, '/chapters/')]").enumerated().compactMap { order, link in
            guard let href = link.absAttr("href") else { return nil }
            let name = link.first(".//span[\(cls("flex"))]/span")?.text.nilIfEmpty
                ?? link.select(".//span").map(\.ownText).first(where: { !$0.isEmpty })
                ?? link.text
            return SourceChapterItem(
                remoteUrl: href.urlPath,
                name: name,
                chapterNumber: ChapterNumberParser.parse(name),
                orderIndex: order,
                scanlator: nil,
                uploadDate: link.first(".//time")?.attr("datetime").flatMap(DateParsing.iso),
                language: language,
                sourceId: id,
                mangaRemoteUrl: remoteUrl
            )
        }
    }

    // MARK: - Páginas

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let url = "\(baseUrl)\(chapterRemoteUrl)/images?is_prev=False&current_page=1&reading_style=long_strip"
        let doc = try await http.html(url, headers: ["Referer": baseUrl + chapterRemoteUrl])
        return doc.select("//section//img|//img").compactMap(\.imageURL)
            .reduce(into: [String]()) { list, src in if !list.contains(src) { list.append(src) } }
            .enumerated()
            .map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: "\(baseUrl)/") }
    }
}

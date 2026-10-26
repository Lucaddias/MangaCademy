import Foundation

/// Port do Keyoapp V2 — lib-multisrc/keyoapp/KeyoappV2.kt. Mesma família do Keyoapp, mas com
/// listas e capítulos vindos de endpoints `?_ajax=` que devolvem HTML dentro de JSON.
public final class KeyoappV2Source: ThemeSource, MangaSource {
    private static let pageSize = 20

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await searchPage(page: page, sort: "popular")
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        let doc = try await http.html("\(baseUrl)/?_ajax=recent-chapters&page=\(page)")
        return SourceMangaPage(items: parseRecent(doc), hasNextPage: doc.first("//button[@aria-label='Next recently updated page' and not(@disabled)]") != nil)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await searchPage(page: page, query: query)
    }

    /// Cartões de "atualizados recentemente": o capítulo mais novo que dá para ler (sem moedas).
    func parseRecent(_ doc: HTMLDocument) -> [SourceMangaItem] {
        doc.select("//article[\(cls("ru-card"))]").compactMap { card in
            guard let link = card.first(".//h2[\(cls("ru-title"))]/a"), let href = link.absAttr("href") else { return nil }
            var result = item(remoteUrl: storedPath(href), title: link.text, cover: card.first(".//img[\(cls("ru-cover-img"))]")?.imageURL)
            let rows = card.select(".//a[\(cls("ru-row"))]")
            if let newest = rows.first(where: { !($0.attr("class") ?? "").contains("ru-row--paid") }) ?? rows.first {
                result.latestChapterName = newest.first(".//*[\(cls("ru-ch"))]")?.text.nilIfEmpty
                result.latestChapterDate = newest.first(".//time")?.attr("datetime").flatMap(DateParsing.iso)
            }
            return result
        }
    }

    private func searchPage(page: Int, query: String? = nil, sort: String? = nil) async throws -> SourceMangaPage {
        var url = "\(baseUrl)/?_ajax=search&offset=\((page - 1) * Self.pageSize)"
        if let query, !query.isEmpty { url += "&q=\(HTTPClient.queryEncode(query))" }
        if let sort { url += "&sort=\(sort)" }
        guard let root = try await http.json(url) as? [String: Any], let html = root.string("html"),
              let doc = HTMLDocument(html: html, url: URL(string: baseUrl)) else { return .empty }
        let items: [SourceMangaItem] = doc.select("//a[\(cls("group")) and @href]").compactMap { card in
            if card.first(".//*[translate(@data-type, 'NOVEL', 'novel')='novel']") != nil { return nil }
            if card.select(".//span").contains(where: { $0.ownText.lowercased() == "novel" }) { return nil }
            guard let href = card.absAttr("href"), let title = card.first(".//h2")?.text.nilIfEmpty else { return nil }
            return item(remoteUrl: storedPath(href), title: title, cover: card.first(".//img")?.imageURL)
        }
        return SourceMangaPage(items: items, hasNextPage: (root["has_more"] as? Bool) == true)
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let slug = remoteUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        async let page = http.html(absoluteURL(remoteUrl))
        async let rows = http.json("\(baseUrl)/?_chapters_html=1&series_slug=\(HTTPClient.queryEncode(slug))")
        let doc = try await page

        func meta(_ label: String) -> String? {
            doc.first("//span[\(cls("text-xs")) and normalize-space(text())='\(label)']/parent::*/following-sibling::*[1]")?.text.nilIfEmpty
        }
        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: doc.first("//h1")?.text ?? slug,
            author: meta("Author"),
            artist: meta("Artist"),
            description: doc.first("//*[@id='series-desc']")?.rawText.trimmed.nilIfEmpty,
            genres: doc.select("//a[contains(@href, '?browse&tag')]").map(\.text).filter { !$0.isEmpty },
            status: StatusParser.parse(doc.first("//div[\(cls("text-xs")) and contains(text(), 'Status')]/following-sibling::div[1]//span[\(cls("text-sm"))]")?.text),
            coverUrl: doc.first("//meta[@property='og:image']")?.attr("content")
        )

        guard let root = try await rows as? [String: Any], let html = root.string("rows_html"),
              let list = HTMLDocument(html: html, url: URL(string: baseUrl)) else { return (detail, []) }
        // Capítulos pagos (moedas) ficam de fora: não dá para ler sem conta
        let chapters: [SourceChapterItem] = list.select("//a[\(cls("chapter-row")) and @href]")
            .filter { $0.attr("data-ch-locked") != "1" }
            .enumerated()
            .compactMap { index, row in
                guard let href = row.absAttr("href") else { return nil }
                let name = row.attr("data-ch-label")?.nilIfEmpty ?? row.text
                let date = ChapterDateParser.parse(row.first(".//*[\(cls("ch-date-row"))]/span[last()]")?.text, language: "en")
                var item = chapter(remoteUrl: storedPath(href), name: name, index: index, date: date)
                item.mangaRemoteUrl = remoteUrl
                return item
            }
        return (detail, chapters)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let chapterURL = absoluteURL(chapterRemoteUrl)
        let doc = try await http.html(chapterURL)
        let urls = doc.select("//*[@id='strip-reader']//img[\(cls("reader-page"))]").compactMap(\.imageURL)
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: chapterURL) }
    }
}

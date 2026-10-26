import Foundation

/// Port do tema Yiimanga — lib-multisrc/yiimanga. Listas em /page/N/, com o último capítulo de
/// cada obra; a página da obra segue três layouts parecidos com o Madara.
public final class YiiMangaSource: ThemeSource, MangaSource {
    private var searchParam: String { config.searchParam ?? "s" }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        guard let path = config.popularPath else { return try await fetchLatest(page: page) }
        return try await list("\(baseUrl)/\(path)/page/\(page)/?order=views")
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await list("\(baseUrl)/page/\(page)/")
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await list("\(baseUrl)/search/?\(searchParam)=\(HTTPClient.queryEncode(query))&page=\(page)")
    }

    private func list(_ url: String) async throws -> SourceMangaPage {
        let doc = try await http.html(url)
        return SourceMangaPage(items: parseList(doc), hasNextPage: doc.first("//*[@id='pagination']//li[\(cls("next"))]/a") != nil)
    }

    func parseList(_ doc: HTMLDocument) -> [SourceMangaItem] {
        let cards = doc.select("//*[\(cls("latest-list"))]//*[\(cls("latest-item"))] | //*[\(cls("list"))]//*[\(cls("list-item"))]")
        return cards.compactMap { card in
            guard let link = card.first(".//*[\(cls("latest-right"))]//a[.//h3 or .//h4] | .//*[\(cls("item-title"))]//a"),
                  let href = link.absAttr("href"), !link.text.isEmpty else { return nil }
            let cover = card.first(".//*[\(cls("latest-left"))]//img | .//*[\(cls("item-img"))]//img")?.imageURL
            var result = item(remoteUrl: storedPath(href), title: link.text, cover: cover)
            if let newest = card.first(".//ul/li[1]") {
                result.latestChapterName = newest.first(".//a")?.text.nilIfEmpty
                result.latestChapterDate = Self.date(newest.first("./span[not(\(cls("c-new-tag")))]")?.text)
                    ?? (newest.first(".//*[\(cls("c-new-tag"))]") != nil ? ChapterDateParser.parse("today") : nil)
            }
            return result
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let dateLock = NSLock()

    /// "06 Oct 2026", "12 Oct 26" ou só mês e ano com dois dígitos: "Oct 26".
    static func date(_ text: String?) -> Date? {
        guard let parts = text?.trimmed.split(separator: " "), parts.count >= 2 else { return nil }
        let year = parts.last?.count == 4 ? "yyyy" : "yy"
        let pattern = parts.count == 3 ? "dd MMM \(year)" : "MMM \(year)"
        dateLock.lock()
        defer { dateLock.unlock() }
        dateFormatter.dateFormat = pattern
        return dateFormatter.date(from: parts.joined(separator: " "))
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let doc = try await http.html(absoluteURL(remoteUrl))
        return (parseDetail(doc, remoteUrl: remoteUrl), parseChapters(doc, remoteUrl: remoteUrl))
    }

    func parseDetail(_ doc: HTMLDocument, remoteUrl: String) -> SourceMangaDetail {
        let title = doc.first("//h1[\(cls("main-info-title"))] | //*[\(cls("post-title"))]//h1 | //*[\(cls("manga-detail"))]//*[\(cls("info"))]//h1")?.text
        let cover = doc.first("//img[\(cls("img-cover"))] | //*[\(cls("summary_image"))]//img | //*[\(cls("manga-detail"))]//*[\(cls("poster"))]//img")?.imageURL

        let headings = doc.select("//*[\(cls("main-info-list"))]//li/h5 | //*[\(cls("post-content_item"))]//*[\(cls("summary-heading"))]/h5 | //*[\(cls("info-item"))]/span[\(cls("sh"))]")
        func info(_ labels: String...) -> HTMLElement? {
            for heading in headings {
                var label = heading.text
                for suffix in [":", " -"] where label.hasSuffix(suffix) { label = String(label.dropLast(suffix.count)) }
                guard labels.contains(label.trimmed),
                      let row = heading.first("./ancestor::*[self::li or \(cls("post-content_item")) or \(cls("info-item"))][1]") else { continue }
                return row.first("./*[not(self::h5) and not(\(cls("summary-heading"))) and not(\(cls("sh")))]")
            }
            return nil
        }
        func names(_ element: HTMLElement?) -> [String] {
            guard let element else { return [] }
            let links = element.select(".//a")
            return links.isEmpty ? [element.text].filter { !$0.isEmpty } : links.map(\.ownText).filter { !$0.isEmpty }
        }

        let synopsisBlock = doc.first("//*[\(cls("short-desc-content")) or \(cls("dsct")) or \(cls("description-summary"))]")
        let paragraphs = synopsisBlock.map { block in
            let parts = block.select(".//p | .//li").map(\.text).filter { !$0.isEmpty }
            return parts.isEmpty ? block.text : parts.joined(separator: "\n\n")
        }
        let alternative = info("Alternative")?.text.nilIfEmpty
            ?? doc.first("//*[\(cls("main-info-list"))]//li/h4 | //*[\(cls("manga-detail"))]//*[\(cls("info"))]//h6")?.text.nilIfEmpty
        let status = info("Status", "Estado")?.text ?? doc.first("//*[\(cls("manga-detail"))]//*[\(cls("info"))]//p[\(cls("type"))]")?.text

        return SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: title ?? remoteUrl,
            author: names(info("Author(s)", "Author", "Autores")).joined(separator: ", ").nilIfEmpty,
            artist: names(info("Artist(s)", "Artist", "Artistas")).joined(separator: ", ").nilIfEmpty,
            description: paragraphs?.nilIfEmpty,
            genres: names(info("Genres", "Genre(s)", "Géneros")),
            status: StatusParser.parse(status),
            coverUrl: cover,
            altTitles: alternative.map { $0.split(whereSeparator: { ",;/".contains($0) }).map { String($0).trimmed }.filter { !$0.isEmpty } } ?? []
        )
    }

    func parseChapters(_ doc: HTMLDocument, remoteUrl: String) -> [SourceChapterItem] {
        let rows = doc.select("//ul[\(cls("chapter-list"))]/li | //ul[\(cls("row-content-chapter"))]/li | //*[\(cls("list-items"))]//li[\(cls("item"))]")
        return rows.enumerated().compactMap { index, row in
            guard let href = row.first(".//a[@href]")?.absAttr("href"),
                  let name = row.first(".//*[\(cls("chapter-name"))] | .//*[\(cls("item"))]//a/span[1]")?.text.nilIfEmpty else { return nil }
            let date = Self.date(row.first(".//*[\(cls("ct-update")) or \(cls("chapter-time"))] | .//*[\(cls("item"))]//a/span[2]")?.text)
            var item = chapter(remoteUrl: storedPath(href), name: name, index: index, date: date)
            item.mangaRemoteUrl = remoteUrl
            return item
        }
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let chapterURL = absoluteURL(chapterRemoteUrl)
        let doc = try await http.html(chapterURL)
        let urls = doc.select("//*[\(cls("reading-content")) or \(cls("read-content"))]//img").compactMap(\.imageURL)
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: chapterURL) }
    }
}

import Foundation

/// Port do tema FoolSlide — lib-multisrc/foolslide. Leitor antigo (CodeIgniter) de scanlators;
/// alguns sites ficam num subcaminho (`config.urlModifier`, ex.: "/slide").
public final class FoolSlideSource: ThemeSource, MangaSource {
    private static let pagesRegex = try! NSRegularExpression(pattern: #"var\s+pages\s*=\s*(\[.*?\]);"#, options: .dotMatchesLineSeparators)
    private static let dotDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    private var root: String { baseUrl + (config.urlModifier ?? "") }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        let doc = try await http.html("\(root)/directory/\(page)/")
        let items = parseGroups(doc, withCover: true)
        // Alguns leitores não têm diretório: a lista de lançamentos serve de catálogo
        if items.isEmpty && page == 1 { return try await fetchLatest(page: page) }
        return SourceMangaPage(items: items, hasNextPage: doc.first("//div[\(cls("next"))]") != nil)
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        let doc = try await http.html("\(root)/latest/\(page)/")
        return SourceMangaPage(items: parseGroups(doc, withCover: false), hasNextPage: doc.first("//div[\(cls("next"))]//a") != nil)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        let doc = try await http.postFormHTML("\(root)/search/", fields: [("search", query)])
        return SourceMangaPage(items: parseGroups(doc, withCover: true), hasNextPage: false)
    }

    /// Cada `div.group` é uma série; na lista de lançamentos o 1º `div.element` é o capítulo mais novo.
    func parseGroups(_ doc: HTMLDocument, withCover: Bool) -> [SourceMangaItem] {
        var seen = Set<String>()
        return doc.select("//div[\(cls("group"))]").compactMap { group in
            guard let link = group.first(".//a[@title]"), let href = link.absAttr("href") else { return nil }
            let path = storedPath(href)
            guard seen.insert(path).inserted else { return nil }
            let cover = withCover ? group.first(".//img")?.absAttr("src")?.replacingOccurrences(of: "/thumb_", with: "/") : nil
            var result = item(remoteUrl: path, title: link.attr("title")?.nilIfEmpty ?? link.text, cover: cover)
            if let newest = group.first(".//div[\(cls("element"))]") {
                result.latestChapterName = newest.first(".//div[\(cls("title"))]/a")?.text.nilIfEmpty
                result.latestChapterDate = date(newest.first(".//div[\(cls("meta_r"))]")?.text)
            }
            return result
        }
    }

    /// "by Equipe, 2026.07.18", "by Equipe, Yesterday", "3 days ago", "15th October, 2026".
    func date(_ meta: String?) -> Date? {
        guard let meta else { return nil }
        let text = meta.components(separatedBy: ", ").dropFirst().joined(separator: ", ").nilIfEmpty ?? meta
        if let date = Self.dotDate.date(from: text.trimmed) { return date }
        return ChapterDateParser.parse(text, language: "en")
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        // O formulário "adult=true" passa pelo aviso de conteúdo adulto
        let doc = try await http.postFormHTML(absoluteURL(remoteUrl), fields: [("adult", "true")])
        let info = doc.first("//div[\(cls("info"))]")
        var author: String?, artist: String?, description: String?
        for label in info?.select(".//b") ?? [] {
            let key = label.text.lowercased()
            let value = label.first("./following-sibling::text()[1]")?.rawText
                .trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":")).trimmed ?? ""
            guard !value.isEmpty else { continue }
            if key.contains("author") || key.contains("autore") { author = value }
            else if key.contains("artist") { artist = value }
            else if key.contains("synopsis") || key.contains("description") || key.contains("trama") { description = value }
        }
        let title = doc.first("//h1[\(cls("title"))]")?.text.nilIfEmpty
            ?? doc.first("//div[\(cls("info"))]//li[1]")?.text.nilIfEmpty ?? remoteUrl
        let cover = doc.first("//div[\(cls("thumbnail"))]//img | //table[\(cls("thumb"))]//img")?.absAttr("src")
        let detail = SourceMangaDetail(remoteUrl: remoteUrl, title: title, author: author, artist: artist, description: description, coverUrl: cover)

        let rows = doc.select("//div[\(cls("group")) or \(cls("list")) or \(cls("group_comic"))]//div[\(cls("element"))]")
        var seen = Set<String>()
        let chapters: [SourceChapterItem] = rows.compactMap { row in
            guard let link = row.first(".//div[\(cls("title"))]/a[@title] | .//a[@title]"), let href = link.absAttr("href"),
                  href.contains("/read/"), seen.insert(href).inserted else { return nil }
            var item = chapter(remoteUrl: storedPath(href), name: link.text, index: seen.count - 1,
                               date: date(row.first(".//div[\(cls("meta_r"))]")?.text))
            item.mangaRemoteUrl = remoteUrl
            return item
        }
        return (detail, chapters)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let chapterURL = absoluteURL(chapterRemoteUrl)
        let (data, finalURL) = try await http.postForm(chapterURL, fields: [("adult", "true")])
        let html = String(decoding: data, as: UTF8.self)
        guard let match = Self.pagesRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let pages = try? JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [[String: Any]] else {
            throw HTTPError.parse("as páginas")
        }
        let urls = pages.compactMap { $0.string("url") }.compactMap { URL(string: $0, relativeTo: finalURL)?.absoluteString }
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: chapterURL) }
    }
}

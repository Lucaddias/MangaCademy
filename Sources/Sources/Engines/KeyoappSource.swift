import Foundation

/// Port do tema Keyoapp — lib-multisrc/keyoapp. O site lista todas as séries numa única página.
public final class KeyoappSource: ThemeSource, MangaSource {
    private static let backgroundRegex = try! NSRegularExpression(pattern: #"url\(['"]?([^'")]+)"#)
    private static let cdnRegex = try! NSRegularExpression(pattern: #"realUrl\s*=\s*`[^`]+//([^/]+)"#)

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        let items = parseCards(try await http.html("\(baseUrl)/series/"))
        return SourceMangaPage(items: items, hasNextPage: false)
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        var items = parseCards(try await http.html("\(baseUrl)/latest/"))
        if items.isEmpty { items = parseCards(try await http.html("\(baseUrl)/series/")) }
        return SourceMangaPage(items: items, hasNextPage: false)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        let doc = try await http.html("\(baseUrl)/series/?q=\(HTTPClient.queryEncode(query))")
        let q = query.lowercased()
        let items = parseCards(doc).filter { $0.title.lowercased().contains(q) }
        return SourceMangaPage(items: items, hasNextPage: false)
    }

    /// Cartões de série: links para /series/<slug> com título e capa em background-image.
    private func parseCards(_ doc: HTMLDocument) -> [SourceMangaItem] {
        var seen = Set<String>()
        var items: [SourceMangaItem] = []
        for link in doc.select("//a[contains(@href, '/series/')]") {
            guard let href = link.absAttr("href"), let path = URL(string: href)?.path else { continue }
            let segments = path.split(separator: "/")
            guard segments.count == 2, segments[0] == "series" else { continue }
            let stored = storedPath(href)
            let title = link.attr("title")?.nilIfEmpty ?? link.text
            guard !title.isEmpty, seen.insert(stored).inserted else { continue }
            let container = link.first("./ancestor::*[contains(@class, 'group')][1]") ?? link
            let cover = backgroundImage(container) ?? backgroundImage(link) ?? container.first(".//img")?.imageURL
            items.append(item(remoteUrl: stored, title: title, cover: cover))
        }
        return items
    }

    private func backgroundImage(_ element: HTMLElement) -> String? {
        let styled = element.first("descendant-or-self::*[contains(@style, 'background-image') or contains(@style, 'url(')]")
        guard let style = styled?.attr("style"),
              let match = Self.backgroundRegex.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)),
              let range = Range(match.range(at: 1), in: style) else { return nil }
        return element.document.absolute(String(style[range]))
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let doc = try await http.html(absoluteURL(remoteUrl))
        let title = doc.first("//div[\(cls("grid"))]/h1 | //h1")?.text.nilIfEmpty
            ?? doc.first("//meta[@property='og:title']")?.attr("content") ?? remoteUrl
        let paragraphs = doc.select("//*[@id='expand_content']//p").map(\.text).filter { !$0.isEmpty }
        let coverNode = doc.first("//div[contains(@class, 'photoURL') or contains(@style, 'photoURL')]")
        let cover = coverNode.flatMap(backgroundImage) ?? doc.first("//meta[@property='og:image']")?.attr("content")
        let genres = doc.select("//a[contains(@href, 'genre=')]").map { $0.text.trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }.filter { !$0.isEmpty }

        func value(after label: String) -> String? {
            doc.first("//div[.//span[normalize-space(text())='\(label)']]/following-sibling::div[1]")?.text.nilIfEmpty
        }

        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: title,
            author: value(after: "Author"),
            artist: value(after: "Artist"),
            description: paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n"),
            genres: genres,
            status: StatusParser.parse(value(after: "Status")),
            coverUrl: cover
        )

        let rows = doc.select("//*[@id='chapters']/a | //*[@id='chapters']/div")
        let chapters: [SourceChapterItem] = rows.enumerated().compactMap { index, row in
            // Capítulos pagos (moedas) e "Upcoming" não podem ser lidos
            if row.first(".//img[contains(@alt, 'Coin')]") != nil { return nil }
            if row.text.contains("Upcoming") { return nil }
            let link = row.tagName == "a" ? row : row.first(".//a[@href]")
            guard let href = link?.absAttr("href") else { return nil }
            let name = row.first(".//*[\(cls("text-sm"))]")?.text.nilIfEmpty ?? link?.attr("title") ?? row.text
            var ch = chapter(remoteUrl: storedPath(href), name: name, index: index)
            ch.mangaRemoteUrl = remoteUrl
            return ch
        }
        return (detail, chapters)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let chapterURL = absoluteURL(chapterRemoteUrl)
        let doc = try await http.html(chapterURL)
        let scripts = doc.scriptsText
        var cdn: String?
        if let match = Self.cdnRegex.firstMatch(in: scripts, range: NSRange(scripts.startIndex..., in: scripts)),
           let range = Range(match.range(at: 1), in: scripts) {
            let host = String(scripts[range]).replacingOccurrences(of: #"\$\{[^}]*\}"#, with: "", options: .regularExpression)
            cdn = "https://\(host)/uploads"
        }
        let images = doc.select("//*[@id='pages']/img")
        var urls: [String] = []
        if let cdn {
            urls = images.compactMap { $0.attr("uid")?.nilIfEmpty }.map { "\(cdn)/\($0)" }
        }
        if urls.isEmpty {
            urls = images.compactMap(\.imageURL)
        }
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: chapterURL) }
    }
}

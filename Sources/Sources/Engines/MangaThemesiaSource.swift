import Foundation

/// Port do tema MangaThemesia (antigos WPMangaStream/WPMangaReader) — lib-multisrc/mangathemesia.
public final class MangaThemesiaSource: ThemeSource, MangaSource {
    private var directory: String {
        let dir = config.mangaUrlDirectory ?? "/manga"
        return dir.hasPrefix("/") ? dir : "/\(dir)"
    }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await list(page: page, query: "", order: "popular")
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await list(page: page, query: "", order: "update")
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await list(page: page, query: query, order: "")
    }

    private func list(page: Int, query: String, order: String) async throws -> SourceMangaPage {
        var url = "\(baseUrl)\(directory)/?page=\(page)"
        if !query.isEmpty { url += "&title=\(HTTPClient.queryEncode(query))" }
        if !order.isEmpty { url += "&order=\(order)" }
        let doc = try await http.html(url)

        let cards = doc.select("//div[\(cls("listupd"))]//div[\(cls("bs"))]//div[\(cls("bsx"))] | //div[\(cls("utao"))]//div[\(cls("uta"))]//div[\(cls("imgu"))] | //div[\(cls("listo"))]//div[\(cls("bs"))]//div[\(cls("bsx"))]")
        var seen = Set<String>()
        let items: [SourceMangaItem] = cards.compactMap { card in
            // Novels não têm páginas de imagem
            if card.first(".//*[\(cls("novelabel"))]") != nil { return nil }
            guard let link = card.first(".//a[@href]"), let href = link.absAttr("href") else { return nil }
            let path = storedPath(href)
            guard seen.insert(path).inserted else { return nil }
            let title = link.attr("title")?.nilIfEmpty ?? card.first(".//div[\(cls("tt"))]")?.text ?? link.text
            guard !title.isEmpty else { return nil }
            var result = item(remoteUrl: path, title: title, cover: card.first(".//img")?.imageURL)
            // O tema mostra o último capítulo, mas sem data
            result.latestChapterName = card.first(".//*[\(cls("epxs"))]")?.text.nilIfEmpty
            return result
        }
        let hasNextLink = doc.first("//div[\(cls("pagination"))]//a[\(cls("next"))] | //div[\(cls("hpage"))]//a[\(cls("r"))]") != nil
        return SourceMangaPage(items: items, hasNextPage: hasNextLink || !items.isEmpty)
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let doc = try await http.html(absoluteURL(remoteUrl))
        let title = doc.first("//h1[\(cls("entry-title"))]")?.text.nilIfEmpty
            ?? doc.first("//meta[@property='og:title']")?.attr("content")?.nilIfEmpty
            ?? remoteUrl
        let altText = doc.first("//*[\(cls("alternative"))] | //*[\(cls("seriestualt"))]")?.text
        let altTitles = altText.map { $0.split(whereSeparator: { "|/•,;".contains($0) }).map { String($0).trimmed }.filter { !$0.isEmpty } } ?? []
        let descriptionNode = doc.first("//div[@itemprop='description'] | //div[\(cls("entry-content"))][@itemprop='description'] | //div[\(cls("desc"))]")
        let description: String? = descriptionNode.map { node in
            let paragraphs = node.select(".//p").map(\.text).filter { !$0.isEmpty }
            return paragraphs.isEmpty ? node.text : paragraphs.joined(separator: "\n\n")
        }
        let genres = doc.select("//span[\(cls("mgen"))]/a | //div[\(cls("gnr"))]/a | //div[\(cls("seriestugenre"))]/a").map(\.text).filter { !$0.isEmpty }
        let cover = doc.first("//div[\(cls("thumb"))]//img | //div[\(cls("infomanga"))]//div[@itemprop='image']//img")?.imageURL
            ?? doc.first("//meta[@property='og:image']")?.attr("content")

        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: title,
            author: info(doc, labels: ["author", "autor", "auteur", "mangaka"]),
            artist: info(doc, labels: ["artist", "artista", "artiste"]),
            description: description,
            genres: genres,
            status: StatusParser.parse(info(doc, labels: ["status", "estado", "statut"])),
            coverUrl: cover,
            altTitles: altTitles
        )

        let rows = doc.select("//div[@id='chapterlist']//li | //div[\(cls("bxcl"))]//li | //div[\(cls("cl"))]//li")
        var seen = Set<String>()
        let chapters: [SourceChapterItem] = rows.enumerated().compactMap { index, row in
            guard let link = row.first(".//a[@href]"), let href = link.absAttr("href") else { return nil }
            let path = storedPath(href)
            guard seen.insert(path).inserted else { return nil }
            let name = row.first(".//*[\(cls("chapternum"))] | .//*[\(cls("lch"))]/a")?.text.nilIfEmpty ?? link.text
            let number = row.attr("data-num").map(ChapterNumberParser.parse).flatMap { $0 >= 0 ? $0 : nil }
            var ch = chapter(remoteUrl: path, name: name, index: index, number: number)
            ch.mangaRemoteUrl = remoteUrl
            return ch
        }
        return (detail, chapters)
    }

    private func info(_ doc: HTMLDocument, labels: [String]) -> String? {
        for row in doc.select("//div[\(cls("imptdt"))] | //table[\(cls("infotable"))]//tr | //div[\(cls("fmed"))]") {
            let label = row.text.lowercased()
            guard labels.contains(where: label.contains) else { continue }
            let value = row.first(".//i | .//td[last()] | .//span | .//a")?.text.trimmed ?? ""
            if !value.isEmpty, value != "-", value.lowercased() != "n/a", value.lowercased() != "unknown" {
                return value
            }
        }
        return nil
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let chapterURL = absoluteURL(chapterRemoteUrl)
        let doc = try await http.html(chapterURL)

        var seen = Set<String>()
        var urls = doc.select("//div[@id='readerarea']//img")
            .compactMap(\.imageURL)
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        if urls.isEmpty {
            // Muitos sites carregam as páginas via JS: ts_reader.run({... "images": [...] })
            var scripts = doc.scriptsText
            for script in doc.select("//script[starts-with(@src, 'data:text/javascript;base64,')]") {
                if let src = script.attr("src"),
                   let data = Data(base64Encoded: String(src.dropFirst("data:text/javascript;base64,".count))),
                   let decoded = String(data: data, encoding: .utf8) {
                    scripts += "\n" + decoded
                }
            }
            if let regex = try? NSRegularExpression(pattern: #"["']?(?:images|imageUrls)["']?\s*[:=]\s*(\[[^\]]*\])"#),
               let match = regex.firstMatch(in: scripts, range: NSRange(scripts.startIndex..., in: scripts)),
               let range = Range(match.range(at: 1), in: scripts),
               let list = try? JSONSerialization.jsonObject(with: Data(String(scripts[range]).utf8)) as? [String] {
                urls = list.compactMap { doc.absolute($0) }
            }
        }
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: "\(baseUrl)/") }
    }
}

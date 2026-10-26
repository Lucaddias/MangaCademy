import Foundation
import CommonCrypto
import CryptoKit

/// Port do tema Madara (WordPress) do Keiyoushi — lib-multisrc/madara.
public final class MadaraSource: ThemeSource, MangaSource {
    private var mangaSubString: String { config.mangaSubString ?? "manga" }
    private var pageSize: Int { config.pageSize ?? 25 }
    private var usesAjaxListing: Bool { config.noAjax != true }
    private let xhr = ["X-Requested-With": "XMLHttpRequest"]

    private enum Order { case popular, latest }

    // MARK: - Catálogo

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await list(page: page, order: .popular)
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await list(page: page, order: .latest)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        if usesAjaxListing {
            var fields = ajaxBaseFields(page: page)
            fields.append(("vars[s]", query))
            if config.filterNonMangaItems != false {
                fields.append(("vars[meta_query][1][key]", "_wp_manga_chapter_type"))
                fields.append(("vars[meta_query][1][value]", "manga"))
            }
            // Se o admin-ajax falhar (desativado ou atrás do Cloudflare), usa a busca normal.
            if let doc = try? await http.postFormHTML("\(baseUrl)/wp-admin/admin-ajax.php", fields: fields, headers: xhr) {
                let items = parseArchive(doc)
                if !items.isEmpty || page > 1 {
                    return SourceMangaPage(items: items, hasNextPage: items.count >= pageSize)
                }
            }
        }
        var url = baseUrl + "/"
        if page > 1 { url += "page/\(page)/" }
        url += "?s=\(HTTPClient.queryEncode(query))&post_type=wp-manga"
        let doc = try await http.html(url)
        let items = parseArchive(doc)
        return SourceMangaPage(items: items, hasNextPage: hasNextPageLink(doc) && !items.isEmpty)
    }

    private func list(page: Int, order: Order) async throws -> SourceMangaPage {
        if usesAjaxListing {
            do {
                var fields = ajaxBaseFields(page: page)
                if config.filterNonMangaItems != false {
                    fields.append(("vars[meta_query][0][key]", "_wp_manga_chapter_type"))
                    fields.append(("vars[meta_query][0][value]", "manga"))
                }
                fields.append(("vars[orderby]", "meta_value_num"))
                fields.append(("vars[meta_key]", order == .popular ? "_wp_manga_views" : "_latest_update"))
                fields.append(("vars[order]", "DESC"))
                let doc = try await http.postFormHTML("\(baseUrl)/wp-admin/admin-ajax.php", fields: fields, headers: xhr)
                let items = parseArchive(doc)
                if !items.isEmpty || page > 1 {
                    return SourceMangaPage(items: items, hasNextPage: items.count >= pageSize)
                }
            } catch {
                // Alguns sites desativam o admin-ajax ou só protegem ele com Cloudflare:
                // tenta a página de arquivo (se ela também for bloqueada, o erro sobe dali).
            }
        }
        var url = "\(baseUrl)/\(mangaSubString)/"
        if page > 1 { url += "page/\(page)/" }
        url += "?m_orderby=\(order == .popular ? "views" : "latest")"
        let doc = try await http.html(url)
        let items = parseArchive(doc)
        return SourceMangaPage(items: items, hasNextPage: !items.isEmpty)
    }

    private func ajaxBaseFields(page: Int) -> [(String, String)] {
        [
            ("action", "madara_load_more"),
            ("page", String(page - 1)),
            ("template", config.ajaxTemplate ?? "madara-core/content/content-archive"),
            ("vars[paged]", "1"),
            ("vars[template]", "archive"),
            ("vars[posts_per_page]", String(pageSize)),
            ("vars[post_type]", "wp-manga"),
            ("vars[post_status]", "publish"),
            ("vars[manga_archives_item_layout]", "big_thumbnail"),
        ]
    }

    private func parseArchive(_ doc: HTMLDocument) -> [SourceMangaItem] {
        let cards = doc.select("//div[\(cls("page-item-detail"))] | //div[\(cls("manga__item"))] | //div[\(cls("c-tabs-item__content"))]")
        var seen = Set<String>()
        return cards.compactMap { card in
            guard let link = card.first(".//*[\(cls("post-title"))]//a[@href]") ?? card.first(".//h3/a[@href] | .//h5/a[@href]"),
                  let href = link.absAttr("href") else { return nil }
            let path = storedPath(href)
            guard seen.insert(path).inserted else { return nil }
            let title = link.text
            guard !title.isEmpty else { return nil }
            var result = item(remoteUrl: path, title: title, cover: card.first(".//img")?.imageURL)
            // O card traz os dois últimos capítulos; o primeiro é o mais novo
            if let latest = card.first(".//div[\(cls("chapter-item"))]") {
                result.latestChapterName = latest.first(".//span[\(cls("chapter"))]//a | .//a")?.text.nilIfEmpty
                result.latestChapterDate = date(in: latest)
            }
            return result
        }
    }

    /// Data de um capítulo como o tema mostra: capítulos novos trazem a data relativa no `alt` do
    /// selo "novo" ou no `title` do link, os demais como texto em `.post-on`/`.chapter-release-date`.
    private func date(in element: HTMLElement) -> Date? {
        let dateSpan = ".//span[\(cls("post-on")) or \(cls("chapter-release-date"))]"
        let candidates = [
            element.first(".//img[not(\(cls("thumb")))]")?.attr("alt"),
            element.first("\(dateSpan)//a")?.attr("title"),
            element.first(dateSpan)?.text,
        ]
        return candidates.lazy.compactMap { ChapterDateParser.parse($0, language: self.language) }.first
    }

    private func hasNextPageLink(_ doc: HTMLDocument) -> Bool {
        doc.first("//div[\(cls("nav-previous"))] | //a[\(cls("nextpostslink"))] | //*[@id='navigation-ajax'] | //a[\(cls("next"))]") != nil
    }

    // MARK: - Detalhes

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let doc = try await http.html(absoluteURL(remoteUrl))
        let detail = parseDetail(doc, remoteUrl: remoteUrl)
        let mangaPath = (doc.url?.absoluteString ?? absoluteURL(remoteUrl)).urlPath
        let chapters = try await fetchChapters(doc: doc, mangaPath: mangaPath)
        return (detail, chapters.map { var c = $0; c.mangaRemoteUrl = remoteUrl; return c })
    }

    public func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail {
        parseDetail(try await http.html(absoluteURL(remoteUrl)), remoteUrl: remoteUrl)
    }

    private func parseDetail(_ doc: HTMLDocument, remoteUrl: String) -> SourceMangaDetail {
        let title = (doc.first("//div[\(cls("post-title"))]/h1 | //div[\(cls("post-title"))]/h3 | //*[@id='manga-title']/h1")?.ownText.nilIfEmpty)
            ?? doc.first("//meta[@property='og:title']")?.attr("content")?.nilIfEmpty
            ?? remoteUrl
        let authors = doc.select("//div[\(cls("author-content"))]/a | //div[\(cls("manga-authors"))]/a").map(\.text).filter { !$0.isEmpty }
        let artists = doc.select("//div[\(cls("artist-content"))]/a").map(\.text).filter { !$0.isEmpty }
        let descriptionNode = doc.first("//div[\(cls("description-summary"))]//div[\(cls("summary__content"))] | //div[\(cls("summary_content"))]//div[\(cls("manga-excerpt"))] | //div[\(cls("summary__content"))] | //div[\(cls("manga-summary"))]")
        let description: String? = descriptionNode.map { node in
            let paragraphs = node.select(".//p").map(\.text).filter { !$0.isEmpty }
            return paragraphs.isEmpty ? node.text : paragraphs.joined(separator: "\n\n")
        }
        let genres = doc.select("//div[\(cls("genres-content"))]/a").map(\.text).filter { !$0.isEmpty }
        let statusText = infoValue(doc, headings: ["status", "estado"])
            ?? doc.select("//div[\(cls("post-status"))]//div[\(cls("summary-content"))]").last?.text
        let altText = infoValue(doc, headings: ["alt", "alternativ", "nome"])
        let altTitles = altText.map { $0.split(whereSeparator: { ",;/|".contains($0) }).map { String($0).trimmed }.filter { !$0.isEmpty } } ?? []
        let cover = doc.first("//div[\(cls("summary_image"))]//img")?.imageURL
            ?? doc.first("//meta[@property='og:image']")?.attr("content")

        // Selo "18+" do próprio tema conta como tag adulta
        var allGenres = genres
        if doc.first("//div[\(cls("post-title"))]//span[\(cls("manga-title-badges"))][\(cls("adult"))]") != nil {
            allGenres.append("18+")
        }
        return SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: title,
            author: authors.isEmpty ? nil : authors.joined(separator: ", "),
            artist: artists.isEmpty ? nil : artists.joined(separator: ", "),
            description: description,
            genres: allGenres,
            status: StatusParser.parse(statusText),
            coverUrl: cover,
            altTitles: altTitles
        )
    }

    private func infoValue(_ doc: HTMLDocument, headings: [String]) -> String? {
        for item in doc.select("//div[\(cls("post-content_item"))]") {
            let heading = (item.first(".//div[\(cls("summary-heading"))]")?.text ?? "").lowercased()
            if headings.contains(where: heading.contains),
               let value = item.first(".//div[\(cls("summary-content"))]")?.text, !value.isEmpty,
               !value.lowercased().contains("updating"), !value.lowercased().contains("atualizando") {
                return value
            }
        }
        return nil
    }

    private func fetchChapters(doc: HTMLDocument, mangaPath: String) async throws -> [SourceChapterItem] {
        let ajaxURL = "\(baseUrl)\(mangaPath.hasSuffix("/") ? String(mangaPath.dropLast()) : mangaPath)/ajax/chapters/"
        let postId = doc.first("//*[starts-with(@id, 'manga-chapters-holder')]")?.attr("data-id")?.nilIfEmpty
            ?? doc.first("//input[\(cls("rating-post-id"))]")?.attr("value")?.nilIfEmpty

        var strategies: [String] = []
        let preferred = config.chapterMode ?? "MangaPage"
        strategies.append(preferred)
        for fallback in ["MangaPage", "MangaAjax", "AdminAjax"] where !strategies.contains(fallback) {
            strategies.append(fallback)
        }

        var lastError: Error?
        for strategy in strategies {
            do {
                let chapters: [SourceChapterItem]
                switch strategy {
                case "MangaAjax":
                    chapters = parseChapters(try await http.postFormHTML(ajaxURL, fields: [], headers: xhr))
                case "MangaAjaxPaginated":
                    var all: [SourceChapterItem] = []
                    var lastUrl: String?
                    for page in 1...60 {
                        guard let pageDoc = try? await http.postFormHTML("\(ajaxURL)?t=\(page)", fields: [], headers: xhr) else { break }
                        let pageChapters = parseChapters(pageDoc, offset: all.count)
                        if pageChapters.isEmpty || pageChapters.last?.remoteUrl == lastUrl { break }
                        lastUrl = pageChapters.last?.remoteUrl
                        all += pageChapters
                    }
                    chapters = all
                case "AdminAjax":
                    guard let postId else { continue }
                    chapters = parseChapters(try await http.postFormHTML(
                        "\(baseUrl)/wp-admin/admin-ajax.php",
                        fields: [("action", "manga_get_chapters"), ("manga", postId)],
                        headers: xhr
                    ))
                case "MangaAjaxQuery":
                    let slug = mangaPath.split(separator: "/").last.map(String.init) ?? ""
                    chapters = parseChapters(try await http.postFormHTML(
                        "\(baseUrl)/index.php",
                        fields: [("manga-core", slug), ("manga_ajax", "1"), ("maction", "get_chapters")],
                        headers: xhr
                    ))
                default:
                    chapters = parseChapters(doc)
                }
                if !chapters.isEmpty { return chapters }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return []
    }

    private func parseChapters(_ doc: HTMLDocument, offset: Int = 0) -> [SourceChapterItem] {
        doc.select("//li[\(cls("wp-manga-chapter"))]").enumerated().compactMap { index, li in
            guard let link = li.first(".//a[@href]"), let href = link.absAttr("href") else { return nil }
            let name = link.text.isEmpty ? (li.first(".//*[\(cls("chapter-manhwa-title"))]")?.text ?? "") : link.text
            return chapter(remoteUrl: storedPath(href), name: name, index: offset + index, date: date(in: li))
        }
    }

    // MARK: - Páginas

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let chapterURL = absoluteURL(chapterRemoteUrl)
        let separator = chapterURL.contains("?") ? "&" : "?"
        var doc = try await http.html(chapterURL + "\(separator)style=list")
        if doc.first("//*[@id='single-pager']") != nil, doc.select("//div[\(cls("page-break"))]//img").count <= 1 {
            doc = try await http.html(chapterURL)
        }

        if let protector = doc.first("//*[@id='chapter-protector-data']") {
            let images = try decryptProtectedChapter(protector)
            return images.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: chapterURL) }
        }

        var seen = Set<String>()
        let urls = doc.select("//div[\(cls("page-break"))]//img | //li[\(cls("blocks-gallery-item"))]//img | //div[\(cls("reading-content"))]//img")
            .compactMap(\.imageURL)
            .filter { seen.insert($0).inserted }
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: chapterURL) }
    }

    /// "wp-manga-chapter-protector": JSON CryptoJS (AES-256-CBC, chave derivada por EVP_BytesToKey/MD5).
    private func decryptProtectedChapter(_ element: HTMLElement) throws -> [String] {
        var script = element.rawText
        if let src = element.attr("src"), src.hasPrefix("data:text/javascript;base64,"),
           let data = Data(base64Encoded: String(src.dropFirst("data:text/javascript;base64,".count))),
           let decoded = String(data: data, encoding: .utf8) {
            script = decoded
        }
        func between(_ start: String, _ end: String) -> String? {
            guard let r1 = script.range(of: start), let r2 = script.range(of: end, range: r1.upperBound..<script.endIndex) else { return nil }
            return String(script[r1.upperBound..<r2.lowerBound])
        }
        guard let password = between("wpmangaprotectornonce='", "';"),
              let encrypted = between("chapter_data='", "';")?.replacingOccurrences(of: "\\/", with: "/"),
              let object = try? JSONSerialization.jsonObject(with: Data(encrypted.utf8)) as? [String: Any],
              let ciphertext = (object["ct"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let saltHex = object["s"] as? String else {
            throw HTTPError.parse("as páginas protegidas")
        }
        let salt = Data(stride(from: 0, to: saltHex.count - 1, by: 2).compactMap { i -> UInt8? in
            let start = saltHex.index(saltHex.startIndex, offsetBy: i)
            return UInt8(saltHex[start..<saltHex.index(start, offsetBy: 2)], radix: 16)
        })

        // EVP_BytesToKey (MD5) -> 32 bytes de chave + 16 de IV
        var derived = Data()
        var previous = Data()
        let passwordData = Data(password.utf8)
        while derived.count < 48 {
            var input = previous
            input.append(passwordData)
            input.append(salt)
            previous = Data(Insecure.MD5.hash(data: input))
            derived.append(previous)
        }
        let key = derived.prefix(32)
        let iv = derived.subdata(in: 32..<48)

        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var outLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outBytes in
            ciphertext.withUnsafeBytes { ctBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            ctBytes.baseAddress, ciphertext.count,
                            outBytes.baseAddress, outputCapacity, &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw HTTPError.parse("as páginas protegidas") }
        output.count = outLength

        // Resultado é uma string JSON que contém outra lista JSON
        guard let first = try? JSONSerialization.jsonObject(with: output, options: [.fragmentsAllowed]) else {
            throw HTTPError.parse("as páginas protegidas")
        }
        if let list = first as? [String] { return list }
        if let inner = first as? String,
           let list = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String] {
            return list
        }
        throw HTTPError.parse("as páginas protegidas")
    }
}

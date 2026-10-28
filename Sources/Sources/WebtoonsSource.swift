import Foundation

/// Port da extensão Webtoons — src/all/webtoons. Cada idioma é uma fonte própria do catálogo;
/// o idioma da fonte vira o prefixo das URLs ("en", "es", "zh-hant"...).
public final class WebtoonsSource: ThemeSource, MangaSource {
    private static let mobileUrl = "https://m.webtoons.com"
    /// O layout de celular do site é outro: as páginas são pedidas como desktop, igual à extensão.
    private static let desktopAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let episodeRegex = try! NSRegularExpression(
        pattern: #"(?:(s(eason)?|saison|part|vol(ume)?)\s*\.?\s*(\d+).*?)?(.*?(mini|bonus|special).*?)?(e(p(isode)?)?|ch(apter)?)\s*\.?\s*(\d+(\.\d+)?)"#,
        options: .caseInsensitive
    )

    private var langCode: String { language.lowercased() }

    public override init(id: String, name: String, language: String, baseUrl: String, config: KeiyoushiEngineConfig) {
        super.init(id: id, name: name, language: language, baseUrl: baseUrl, config: config)
        // Passa direto pelo aviso de idade e pelo GDPR, no idioma da fonte
        let locale = langCode == "zh-hant" ? "zh_TW" : langCode
        for (cookieName, value) in [("ageGatePass", "true"), ("locale", locale), ("needGDPR", "false")] {
            if let cookie = HTTPCookie(properties: [.domain: ".webtoons.com", .path: "/", .name: cookieName, .value: value]) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    public var imageReferer: String? { "https://www.webtoons.com/" }

    private func page(_ url: String) async throws -> HTMLDocument {
        let (data, finalURL) = try await http.data(url, userAgent: Self.desktopAgent)
        guard let doc = HTMLDocument(data: data, url: finalURL) else { throw HTTPError.parse("a página") }
        return doc
    }

    /// Página 1: em alta; 2: populares; 3: originais; 4: canvas.
    public func fetchPopular(page number: Int) async throws -> SourceMangaPage {
        let rankings = ["trending", "popular", "originals", "canvas"]
        guard rankings.indices.contains(number - 1) else { return .empty }
        let doc = try await page("\(baseUrl)/\(langCode)/ranking/\(rankings[number - 1])")
        return SourceMangaPage(items: parseList(doc), hasNextPage: number < rankings.count)
    }

    /// Originais do dia da semana, ordenados pela atualização (o selo "UP" marca as de hoje).
    public func fetchLatest(page number: Int) async throws -> SourceMangaPage {
        guard number == 1 else { return .empty }
        let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let day = days[Calendar.current.component(.weekday, from: Date()) - 1]
        let doc = try await page("\(baseUrl)/\(langCode)/originals/\(day)?sortOrder=UPDATE")
        return SourceMangaPage(items: parseList(doc), hasNextPage: false)
    }

    public func search(query: String, page number: Int) async throws -> SourceMangaPage {
        let doc = try await page("\(baseUrl)/\(langCode)/search?keyword=\(HTTPClient.queryEncode(query))")
        return SourceMangaPage(items: number == 1 ? parseList(doc) : [], hasNextPage: false)
    }

    func parseList(_ doc: HTMLDocument) -> [SourceMangaItem] {
        doc.select("//*[\(cls("webtoon_list"))]//li//a[@href]").compactMap { link in
            guard let href = link.absAttr("href"), let title = link.first(".//*[\(cls("title"))]")?.text.nilIfEmpty else { return nil }
            // O selo UP não informa a data de publicação de um capítulo.
            return item(remoteUrl: storedPath(href), title: title, cover: link.first(".//img")?.absAttr("src"))
        }
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let url = absoluteURL(remoteUrl)
        async let detailsPage = page(url)
        async let episodes = fetchEpisodes(url: url, remoteUrl: remoteUrl)
        let doc = try await detailsPage

        let info = doc.first("//*[\(cls("detail_header"))]//*[\(cls("info"))]")
        let authors = info?.first(".//*[\(cls("author_area"))]")?.text
            .split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty } ?? []
        let dayInfo = doc.first("//*[@id='_asideDetail']//p[\(cls("day_info"))]")?.text.uppercased() ?? ""
        let status = dayInfo.contains("UP") || dayInfo.contains("EVERY") || dayInfo.contains("NOUVEAU") ? 1
            : (dayInfo.contains("END") || dayInfo.contains("COMPLETED") || dayInfo.contains("TERMINÉ") ? 2 : 0)
        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: doc.first("//h1[\(cls("subj"))] | //h3[\(cls("subj"))]")?.text
                ?? doc.first("//meta[@property='og:title']")?.attr("content")?.nilIfEmpty ?? remoteUrl,
            author: authors.first,
            artist: authors.dropFirst().first ?? authors.first,
            description: doc.first("//*[@id='_asideDetail']//p[\(cls("summary"))]")?.text.nilIfEmpty,
            genres: info?.select(".//*[\(cls("genre"))]").map(\.text).filter { !$0.isEmpty } ?? [],
            status: status,
            coverUrl: doc.first("//meta[@property='og:image']")?.attr("content")
        )
        return (detail, try await episodes)
    }

    /// Lista de episódios pela API do site móvel (o desktop pagina de 10 em 10).
    private func fetchEpisodes(url: String, remoteUrl: String) async throws -> [SourceChapterItem] {
        guard let components = URLComponents(string: url),
              let titleNo = components.queryItems?.first(where: { $0.name == "title_no" || $0.name == "titleNo" })?.value else {
            throw HTTPError.parse("a lista de episódios")
        }
        let segments = components.path.split(separator: "/")
        let type = segments.count > 1 && segments[1] == "canvas" || components.path.hasPrefix("/challenge") ? "canvas" : "webtoon"
        var api = "\(Self.mobileUrl)/api/v1/\(type)/\(titleNo)/episodes?pageSize=99999"
        if type == "canvas" { api += "&readingLanguageCode=\(langCode)" }
        guard let root = try await http.json(api, headers: ["Referer": "\(Self.mobileUrl)/"]) as? [String: Any] else { return [] }
        let episodes = root.dict("result")?.array("episodeList") ?? []
        let numbers = Self.chapterNumbers(episodes.map { $0.string("episodeTitle") ?? "" })

        // A API manda do 1º para o último; o app espera o mais novo primeiro
        let chapters: [SourceChapterItem] = episodes.enumerated().compactMap { index, episode in
            guard let link = episode.string("viewerLink") else { return nil }
            let title = Self.unescape(episode.string("episodeTitle") ?? "Episode \(index + 1)")
            let number = numbers[index]
            let formatted = number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(number)) : String(format: "%.2f", number)
            var name = "\(title) (ch. \(formatted))"
            if (episode["hasBgm"] as? Bool) == true { name += " ♫" }
            let date = (episode["exposureDateMillis"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            var item = chapter(remoteUrl: storedPath(absoluteURL(link)), name: name, index: episodes.count - 1 - index, number: number, date: date)
            item.mangaRemoteUrl = remoteUrl
            return item
        }
        return chapters.reversed()
    }

    /// Mesma numeração da extensão: lê "Season 2 Ep. 5", soma as temporadas e numera os extras.
    static func chapterNumbers(_ titles: [String]) -> [Double] {
        var parsed: [(number: Double?, season: Int)] = titles.map { title in
            let range = NSRange(title.startIndex..., in: title)
            guard let match = episodeRegex.firstMatch(in: title, range: range),
                  match.range(at: 6).location == NSNotFound,
                  let numberRange = Range(match.range(at: 11), in: title) else { return (nil, 1) }
            let season = Range(match.range(at: 4), in: title).flatMap { Int(title[$0]) } ?? 1
            return (Double(title[numberRange]), season)
        }
        let recognized = parsed.filter { $0.number != nil }.count
        if parsed.count - recognized > recognized { return titles.indices.map { Double($0 + 1) } }

        var maxNumber = 0.0, currentSeason = 1, offset = 0.0
        var result: [Double] = []
        for index in parsed.indices {
            if let original = parsed[index].number {
                if parsed[index].season > currentSeason {
                    currentSeason = parsed[index].season
                    if original <= maxNumber { offset = maxNumber }
                }
                let number = offset + original
                maxNumber = max(maxNumber, number)
                result.append(number)
            } else {
                result.append(index == 0 ? 0 : result[index - 1] + 0.01)
            }
            parsed[index].number = result[index]
        }
        return result
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return HTMLDocument(html: "<p>\(text)</p>", url: nil)?.first("//p")?.text ?? text
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let doc = try await page(absoluteURL(chapterRemoteUrl))
        var urls = doc.select("//div[@id='_imageList']/img").compactMap { $0.attr("data-url")?.nilIfEmpty }
        if urls.isEmpty { urls = try await motionToonPages(doc) }
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: "https://www.webtoons.com/") }
    }

    /// Episódios animados ("motion toon"): as camadas vêm de um JSON à parte.
    private func motionToonPages(_ doc: HTMLDocument) async throws -> [String] {
        let html = doc.scriptsText
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        guard let documentURL = capture(#"documentURL:.*?'(.*?)'"#), let path = capture(#"jpg:.*?'(.*?)\{"#),
              let root = try await http.json(documentURL) as? [String: Any],
              let images = root.dict("assets")?["images"] as? [String: String] else { return [] }
        return images.keys.filter { $0.contains("layer") }.sorted().compactMap { images[$0].map { path + $0 } }
    }
}

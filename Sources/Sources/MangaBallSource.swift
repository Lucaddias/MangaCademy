import Foundation

/// Port da extensão MangaBall — src/all/mangaball (API JSON em /api/v1). O site tem um catálogo
/// só; cada idioma do Keiyoushi vira uma fonte que lista as obras traduzidas nele e mostra só os
/// capítulos desse idioma.
public final class MangaBallSource: ThemeSource, MangaSource {
    private static let coverBase = "https://bulbasaur.poke-black-and-white.net/covers/"

    /// Códigos de idioma do site para cada idioma do Keiyoushi (alguns têm variantes regionais).
    private static let siteLanguages: [String: [String]] = [
        "ca": ["ca", "ca-ad", "ca-es", "ca-fr", "ca-it", "ca-pt"],
        "es": ["es", "es-ar", "es-mx", "es-es", "es-la", "es-419"],
        "it": ["it", "it-it"],
        "is": ["ib", "ib-is", "is"],
        "ja": ["ja", "jp"],
        "ko": ["ko", "kr"],
        "kn": ["kn", "kn-in", "kn-my", "kn-sg", "kn-tw"],
        "ml": ["ml", "ml-in", "ml-my", "ml-sg", "ml-tw"],
        "nl": ["nl", "nl-be"],
        "pt-BR": ["pt-br", "pt-pt"],
        "sr": ["sr", "sr-cyrl"],
        "th": ["th", "th-hk", "th-kh", "th-la", "th-my", "th-sg"],
        "zh": ["zh", "zh-cn", "zh-hk", "zh-mo", "zh-sg", "zh-tw", "cn"],
    ]

    private var siteLanguages: [String] { Self.siteLanguages[language] ?? [language.lowercased()] }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await searchPage(page: page, params: "&sort_by=views&sort_order=desc")
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await searchPage(page: page, params: "&sort_by=lastupdate&sort_order=desc")
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await searchPage(page: page, params: "&keyword=\(HTTPClient.queryEncode(query.trimmed))")
    }

    private func searchPage(page: Int, params: String) async throws -> SourceMangaPage {
        let adult = Preferences.blockAdultTags ? "no_18" : "all"
        let languages = HTTPClient.queryEncode(siteLanguages.joined(separator: ","))
        let urlString = "\(baseUrl)/api/v1/title/search-advanced?page=\(page)&limit=24&tag_mode=AND&adult_mode=\(adult)&lang=\(languages)\(params)"
        guard let root = try await http.json(urlString) as? [String: Any] else { return .empty }
        let pagination = root.dict("pagination") ?? [:]
        let items: [SourceMangaItem] = root.array("data").compactMap { title in
            guard let detail = makeDetail(title) else { return nil }
            var result = item(remoteUrl: detail.remoteUrl, title: detail.title, cover: detail.coverUrl)
            result.genres = detail.genres
            result.altTitles = detail.altTitles
            result.hasFullMetadata = true
            // Capítulo mais novo no idioma da fonte
            if let newest = title.array("recent_chapters").first(where: { siteLanguages.contains($0.string("lang") ?? "") }) {
                result.latestChapterName = newest.int("number").map { "Cap. \($0)" } ?? newest.string("name")?.nilIfEmpty
                result.latestChapterDate = Self.date(newest.string("created_at"))
            }
            return result
        }
        return SourceMangaPage(items: items, hasNextPage: (pagination.int("page") ?? page) < (pagination.int("total_pages") ?? 0))
    }

    private func makeDetail(_ title: [String: Any]) -> SourceMangaDetail? {
        guard let id = title.string("id"), let name = title.string("name") else { return nil }
        let strings: (String) -> [String] = { key in (title[key] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.trimmed.isEmpty } }
        let status: Int
        switch title.string("status") {
        case "ongoing": status = 1
        case "completed": status = 2
        case "cancelled": status = 3
        case "hiatus": status = 4
        default: status = 0
        }
        // O site repete o autor quando ele também é o artista
        var seen = Set<String>()
        let authors = title.array("author").compactMap { $0.string("name") }.filter { seen.insert($0).inserted }
        return SourceMangaDetail(
            remoteUrl: id,
            title: name,
            author: authors.joined(separator: ", ").nilIfEmpty,
            description: strings("description").joined(separator: "\n\n").nilIfEmpty,
            genres: title.array("tags").compactMap { $0.string("name") },
            status: status,
            coverUrl: Self.coverURL(title.dict("image")),
            altTitles: strings("alternateName")
        )
    }

    /// Mesma prioridade do site: a capa hospedada por ele, depois os espelhos externos.
    static func coverURL(_ image: [String: Any]?) -> String? {
        guard let image else { return nil }
        if let path = image.dict("cover")?.string("path")?.trimmed.replacingOccurrences(of: "\\", with: "/"), !path.isEmpty {
            return path.hasPrefix("http") ? path : coverBase + path
        }
        return ["file", "cdn_mangadex", "cdn_mangaupdate", "cdn_mangaupdates"].lazy.compactMap { image.string($0)?.nilIfEmpty }.first
    }

    public func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail {
        guard let root = try await http.json("\(baseUrl)/api/v1/title/detail/\(remoteUrl)") as? [String: Any],
              let title = root.dict("data"), let detail = makeDetail(title) else {
            throw HTTPError.parse("os detalhes da obra")
        }
        return detail
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        async let detail = fetchMetadata(remoteUrl: remoteUrl)
        let body = try JSONSerialization.data(withJSONObject: ["title_id": remoteUrl])
        // A API recusa "application/json; charset=utf-8": só o tipo puro
        let (data, _) = try await http.data(
            "\(baseUrl)/api/v1/chapter/chapter-listing-by-title-id",
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let chapters: [SourceChapterItem] = root.array("data")
            .filter { siteLanguages.contains($0.string("lang") ?? "") }
            .enumerated()
            .compactMap { index, entry in
                guard let id = entry.string("id") else { return nil }
                let number = entry["number"] as? NSNumber
                var item = chapter(
                    remoteUrl: id,
                    name: Self.chapterName(entry),
                    index: index,
                    number: number?.doubleValue,
                    scanlator: entry.dict("group")?.string("name"),
                    date: Self.date(entry.string("created_at"))
                )
                item.mangaRemoteUrl = remoteUrl
                return item
            }
        return (try await detail, chapters)
    }

    /// "Vol. 2 Ch. 10 Nome", sem repetir o número quando o nome já tem ("Chapter 70").
    static func chapterName(_ entry: [String: Any]) -> String {
        let name = entry.string("name")?.trimmed ?? ""
        var result = ""
        if let volume = (entry["volume"] as? NSNumber)?.doubleValue, volume > 0 {
            result = "Vol. \(format(volume)) "
        }
        guard let number = (entry["number"] as? NSNumber)?.doubleValue else { return (result + name).trimmed.nilIfEmpty ?? "Oneshot" }
        let numberText = format(number)
        if name.contains(numberText) { return result + name }
        return result + "Ch. \(numberText)" + (name.isEmpty ? "" : " \(name)")
    }

    private static func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        guard let root = try await http.json("\(baseUrl)/api/v1/chapter-detail?chapter_id=\(chapterRemoteUrl)") as? [String: Any],
              let pages = root.dict("data")?.dict("chapter")?["pages"] as? [String] else {
            throw HTTPError.parse("as páginas")
        }
        return pages.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: "\(baseUrl)/") }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
    private static let lock = NSLock()

    /// "2026-10-26T17:16:02.700000" (UTC, sem fuso): os segundos fracionados ficam de fora.
    static func date(_ text: String?) -> Date? {
        guard let text, text.count >= 19 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: String(text.prefix(19)))
    }
}

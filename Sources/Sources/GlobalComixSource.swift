import Foundation

/// Port da extensão GlobalComix — src/all/globalcomix (API JSON em api.globalcomix.com).
/// Cada idioma do catálogo é uma fonte. A obra fica guardada como "id/slug": os capítulos
/// vêm pelo id e os detalhes pelo slug.
public final class GlobalComixSource: ThemeSource, MangaSource {
    private static let api = "https://api.globalcomix.com/v1"
    private static let headers = ["x-gc-client": "gck_d0f170d5729446dcb3b55e6b3ebc7bf6", "x-gc-identmode": "cookie"]

    /// Os códigos de idioma do site não são os do Keiyoushi ("br", "jp", "kr"...).
    private var apiLanguage: String {
        let codes = [
            "sq": "al", "pt-BR": "br", "zh-hans": "cn", "cs": "cz", "da": "dk", "fil": "fo",
            "he": "iw", "ja": "jp", "ko": "kr", "ms": "my", "sv": "se", "uk": "ua",
        ]
        return codes[language] ?? language
    }

    private func json(_ path: String) async throws -> [String: Any] {
        try await http.json("\(Self.api)\(path)", headers: Self.headers) as? [String: Any] ?? [:]
    }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await comics(page: page, extra: "")
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await comics(page: page, extra: "&sort=recent")
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await comics(page: page, extra: "&sort=relevance&q=\(HTTPClient.queryEncode(query))")
    }

    private func comics(page: Int, extra: String) async throws -> SourceMangaPage {
        let payload = try await json("/comics?lang_id%5B%5D=\(apiLanguage)&p=\(page)\(extra)").dict("payload") ?? [:]
        let pagination = payload.dict("pagination") ?? [:]
        let items: [SourceMangaItem] = payload.array("results").compactMap { comic in
            guard let detail = makeDetail(comic) else { return nil }
            var result = item(remoteUrl: detail.remoteUrl, title: detail.title, cover: detail.coverUrl)
            result.genres = detail.genres
            result.hasFullMetadata = true
            result.latestChapterName = comic.string("last_published_release_title")?.nilIfEmpty
            result.latestChapterDate = Self.date(comic.string("last_published_release_published_time"))
            return result
        }
        return SourceMangaPage(items: items, hasNextPage: (pagination.int("page") ?? page) < (pagination.int("total_pages") ?? 0))
    }

    private func makeDetail(_ comic: [String: Any]) -> SourceMangaDetail? {
        guard let id = comic.string("id"), let name = comic.string("name"), let slug = comic.string("slug") else { return nil }
        let artist = comic.dict("artist")
        let status: Int
        switch comic.string("status_name") {
        case "Ongoing", "Preview": status = 1
        case "Finished": status = 2
        case "Cancelled": status = 3
        case "On hold": status = 4
        default: status = 0
        }
        return SourceMangaDetail(
            remoteUrl: "\(id)/\(slug)",
            title: name,
            author: (artist?.string("roman_name") ?? artist?.string("name"))?.nilIfEmpty,
            description: comic.string("description")?.nilIfEmpty,
            genres: [comic.string("category_name")].compactMap { $0?.nilIfEmpty },
            status: status,
            coverUrl: comic.string("image_url")?.nilIfEmpty
        )
    }

    private func parts(_ remoteUrl: String) throws -> (id: String, slug: String) {
        let pieces = remoteUrl.split(separator: "/", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { throw HTTPError.parse("a obra") }
        return (pieces[0], pieces[1])
    }

    public func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail {
        let slug = try parts(remoteUrl).slug
        guard let comic = try await json("/read/\(slug)").dict("payload")?.dict("results"), let detail = makeDetail(comic) else {
            throw HTTPError.parse("os detalhes da obra")
        }
        return detail
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let id = try parts(remoteUrl).id
        async let detail = fetchMetadata(remoteUrl: remoteUrl)
        async let releases = json("/comics/\(id)/releases?lang_id=\(apiLanguage)&all=true")
        // Capítulos só para assinantes ficam de fora: não dá para ler sem conta
        let list = (try await releases.dict("payload")?.array("results") ?? [])
            .filter { $0.int("premium_only") != 1 }
            .sorted { ($0.int("order") ?? 0) > ($1.int("order") ?? 0) }
        let chapters: [SourceChapterItem] = list.enumerated().compactMap { index, release in
            guard let key = release.string("key") else { return nil }
            let number = release.string("chapter")?.nilIfEmpty
            let title = release.string("title")?.nilIfEmpty
            let name = [number.map { "Ch.\($0)" }, title].compactMap { $0 }.joined(separator: " - ")
            var item = chapter(
                remoteUrl: key,
                name: name.isEmpty ? "Ch.\(index + 1)" : name,
                index: index,
                number: number.flatMap(Double.init),
                date: Self.date(release.string("published_time"))
            )
            item.mangaRemoteUrl = remoteUrl
            return item
        }
        return (try await detail, chapters)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let pages = try await json("/readV2/\(chapterRemoteUrl)").dict("payload")?.dict("results")?.array("page_objects") ?? []
        let urls = pages.filter { ($0["is_page_paid"] as? Bool) != true }.compactMap { $0.string("desktop_image_url") }
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: "\(baseUrl)/") }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private static let lock = NSLock()

    /// "2026-10-26 13:00:00" (UTC).
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: text)
    }
}

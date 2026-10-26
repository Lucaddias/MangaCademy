import Foundation

/// Port do tema Guya (API JSON em /api) — lib-multisrc/guya. O site devolve todas as séries numa
/// resposta; cada capítulo pode ter várias equipes, e o app usa a preferida pelo site.
public final class GuyaSource: ThemeSource, MangaSource {
    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        return SourceMangaPage(items: try await allSeries(), hasNextPage: false)
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        let items = try await allSeries().sorted { ($0.latestChapterDate ?? .distantPast) > ($1.latestChapterDate ?? .distantPast) }
        return SourceMangaPage(items: items, hasNextPage: false)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        let q = query.lowercased()
        return SourceMangaPage(items: try await allSeries().filter { $0.title.lowercased().contains(q) }, hasNextPage: false)
    }

    private func allSeries() async throws -> [SourceMangaItem] {
        guard let root = try await http.json("\(baseUrl)/api/get_all_series/") as? [String: Any] else { return [] }
        return root.compactMap { title, value -> SourceMangaItem? in
            guard let series = value as? [String: Any], let slug = series.string("slug") else { return nil }
            var result = item(remoteUrl: slug, title: title, cover: coverURL(series.string("cover")))
            result.latestChapterDate = (series["last_updated"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return result
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func coverURL(_ cover: String?) -> String? {
        guard let cover = cover?.nilIfEmpty else { return nil }
        return cover.hasPrefix("http") ? cover : absoluteURL(cover)
    }

    private func series(_ slug: String) async throws -> [String: Any] {
        guard let root = try await http.json("\(baseUrl)/api/series/\(slug)/") as? [String: Any] else {
            throw HTTPError.parse("os detalhes da obra")
        }
        return root
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let root = try await series(remoteUrl)
        let groups = root["groups"] as? [String: String] ?? [:]
        let seriesSort = root["preferred_sort"] as? [String] ?? []
        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: root.string("title") ?? remoteUrl,
            author: root.string("author")?.nilIfEmpty,
            artist: root.string("artist")?.nilIfEmpty,
            description: Self.cleanDescription(root.string("description")),
            coverUrl: coverURL(root.string("cover"))
        )

        let entries = (root["chapters"] as? [String: [String: Any]] ?? [:])
            .sorted { (Double($0.key) ?? 0) > (Double($1.key) ?? 0) }
        let chapters: [SourceChapterItem] = entries.enumerated().compactMap { index, entry in
            let (number, ch) = entry
            let available = Set((ch["groups"] as? [String: Any] ?? [:]).keys)
            let sort = (ch["preferred_sort"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? seriesSort
            guard let group = sort.first(where: available.contains) ?? available.sorted().first else { return nil }
            let released = (ch["release_date"] as? [String: Any])?[group] as? NSNumber
            let title = ch.string("title") ?? ""
            var item = chapter(
                remoteUrl: "\(remoteUrl)/\(number)/\(group)",
                name: title.isEmpty ? number : "\(number) - \(title)",
                index: index,
                number: Double(number),
                scanlator: groups[group],
                date: released.map { Date(timeIntervalSince1970: $0.doubleValue) }
            )
            item.mangaRemoteUrl = remoteUrl
            return item
        }
        return (detail, chapters)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let parts = chapterRemoteUrl.split(separator: "/").map(String.init)
        guard parts.count == 3 else { throw HTTPError.parse("as páginas") }
        let (slug, number, group) = (parts[0], parts[1], parts[2])
        let root = try await series(slug)
        guard let ch = (root["chapters"] as? [String: [String: Any]])?[number],
              let folder = ch.string("folder"),
              let files = (ch["groups"] as? [String: Any])?[group] as? [String] else {
            throw HTTPError.parse("as páginas")
        }
        let reader = "\(baseUrl)/read/manga/\(slug)/\(number.replacingOccurrences(of: ".", with: "-"))/1/"
        return files.enumerated().map { index, file in
            SourcePageItem(pageNumber: index + 1, imageUrl: "\(baseUrl)/media/manga/\(slug)/chapters/\(folder)/\(group)/\(file)", referer: reader)
        }
    }

    /// As descrições trazem links de redes sociais em HTML: fica só o texto.
    private static func cleanDescription(_ html: String?) -> String? {
        guard let html = html?.nilIfEmpty else { return nil }
        guard html.contains("<") else { return html }
        let withoutLinks = html.replacingOccurrences(of: #"<a\b[^>]*>.*?</a>"#, with: "", options: [.regularExpression, .caseInsensitive])
        let doc = HTMLDocument(html: "<div>\(withoutLinks.replacingOccurrences(of: "\n", with: "<br>"))</div>", url: nil)
        return doc?.first("//div")?.text.nilIfEmpty
    }
}

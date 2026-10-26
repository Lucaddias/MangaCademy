import Foundation

/// Port do tema PizzaReader (API JSON em /api) — lib-multisrc/pizzareader.
/// O site devolve o catálogo inteiro numa resposta só.
public final class PizzaReaderSource: ThemeSource, MangaSource {
    private var apiUrl: String { config.apiUrl ?? "\(baseUrl)/api" }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        return SourceMangaPage(items: try await comics("\(apiUrl)/comics"), hasNextPage: false)
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        let items = try await comics("\(apiUrl)/comics")
            .filter { $0.latestChapterDate != nil }
            .sorted { ($0.latestChapterDate ?? .distantPast) > ($1.latestChapterDate ?? .distantPast) }
        return SourceMangaPage(items: items, hasNextPage: false)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        let term = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? query
        return SourceMangaPage(items: try await comics("\(apiUrl)/search/\(term)"), hasNextPage: false)
    }

    private func comics(_ url: String) async throws -> [SourceMangaItem] {
        guard let root = try await http.json(url) as? [String: Any] else { return [] }
        return root.array("comics").compactMap { comic in
            guard let path = comic.string("url"), let title = comic.string("title")?.nilIfEmpty else { return nil }
            var result = item(remoteUrl: path, title: title, cover: comic.string("thumbnail"))
            if let last = comic.dict("last_chapter") {
                result.latestChapterName = last.int("chapter").map { "Cap. \($0)" } ?? last.string("full_title")
                result.latestChapterDate = last.string("published_on").flatMap(DateParsing.iso)
            }
            return result
        }
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        guard let root = try await http.json(apiUrl + remoteUrl) as? [String: Any], let comic = root.dict("comic") else {
            throw HTTPError.parse("os detalhes da obra")
        }
        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: comic.string("title") ?? remoteUrl,
            author: comic.string("author")?.nilIfEmpty,
            artist: comic.string("artist")?.nilIfEmpty,
            description: comic.string("description")?.nilIfEmpty,
            genres: comic.array("genres").compactMap { $0.string("name") },
            status: StatusParser.parse(comic.string("status")),
            coverUrl: comic.string("thumbnail"),
            altTitles: comic["alt_titles"] as? [String] ?? []
        )
        let chapters: [SourceChapterItem] = comic.array("chapters").enumerated().compactMap { index, ch in
            guard let path = ch.string("url") else { return nil }
            var number: Double?
            if let main = ch.int("chapter") {
                number = Double(main) + (Double("0.\(ch.int("subchapter") ?? 0)") ?? 0)
            }
            let teams = (ch["teams"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?.string("name") }
            var item = chapter(
                remoteUrl: path,
                name: ch.string("full_title") ?? "Cap. \(index + 1)",
                index: index,
                number: number,
                scanlator: teams.isEmpty ? nil : teams.joined(separator: " & "),
                date: ch.string("published_on").flatMap(DateParsing.iso)
            )
            item.mangaRemoteUrl = remoteUrl
            return item
        }
        return (detail, chapters)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        guard let root = try await http.json(apiUrl + chapterRemoteUrl) as? [String: Any],
              let pages = root.dict("chapter")?["pages"] as? [String] else {
            throw HTTPError.parse("as páginas")
        }
        return pages.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: "\(baseUrl)/") }
    }
}

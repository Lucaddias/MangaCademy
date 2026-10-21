import Foundation

/// Port do tema Iken (API JSON em api.<domínio>) — lib-multisrc/iken.
public final class IkenSource: ThemeSource, MangaSource {
    private var apiUrl: String {
        config.apiUrl ?? baseUrl.replacingOccurrences(of: "https://", with: "https://api.")
    }
    private var perPage: Int { config.perPage ?? 18 }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await query(page: page, term: "", orderBy: "totalViews")
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await query(page: page, term: "", orderBy: "lastChapterAddedAt")
    }

    public func search(query term: String, page: Int) async throws -> SourceMangaPage {
        try await query(page: page, term: term, orderBy: "")
    }

    private func query(page: Int, term: String, orderBy: String) async throws -> SourceMangaPage {
        var url = "\(apiUrl)/api/query?page=\(page)&perPage=\(perPage)&searchTerm=\(HTTPClient.queryEncode(term))"
        if !orderBy.isEmpty { url += "&orderBy=\(orderBy)" }
        guard let root = try await http.json(url, headers: ["Referer": "\(baseUrl)/"]) as? [String: Any] else { return .empty }
        let posts = root.array("posts")
        let items: [SourceMangaItem] = posts.compactMap { post in
            guard !isNovel(post), let id = post.int("id"), let slug = post.string("slug"),
                  let title = post.string("postTitle") else { return nil }
            return item(remoteUrl: "\(slug)#\(id)", title: title, cover: post.string("featuredImage"))
        }
        let total = root.int("totalCount") ?? 0
        return SourceMangaPage(items: items, hasNextPage: total > page * perPage)
    }

    private func isNovel(_ post: [String: Any]) -> Bool {
        (post["isNovel"] as? Bool) == true || post.string("seriesType")?.lowercased() == "novel"
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let slug = remoteUrl.components(separatedBy: "#").first ?? remoteUrl
        let headers = ["Referer": "\(baseUrl)/"]
        guard let root = try await http.json("\(apiUrl)/api/post?postSlug=\(HTTPClient.queryEncode(slug))", headers: headers) as? [String: Any],
              let post = root.dict("post") else {
            throw HTTPError.parse("os detalhes da obra")
        }
        var rawChapters = post.array("chapters")
        if let total = root.int("totalChapterCount"), total > rawChapters.count, let postId = post.int("id"),
           let chaptersRoot = try? await http.json("\(apiUrl)/api/chapters?postId=\(postId)", headers: headers) as? [String: Any] {
            let fromApi = chaptersRoot.dict("post")?.array("chapters") ?? []
            if fromApi.count > rawChapters.count { rawChapters = fromApi }
        }

        var description = post.string("postContent").flatMap { html in
            HTMLDocument(html: "<div>\(html.replacingOccurrences(of: "\n", with: "<br>"))</div>", url: nil)?.first("//div")?.text
        }
        let alt = post.string("alternativeTitles")?.nilIfEmpty
        if let alt { description = [description, "Títulos alternativos: \(alt)"].compactMap { $0 }.joined(separator: "\n\n") }
        let statusMap = ["ONGOING": 1, "COMING_SOON": 1, "MASS_RELEASED": 1, "COMPLETED": 2, "CANCELLED": 3, "DROPPED": 3]

        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: post.string("postTitle") ?? slug,
            author: post.string("author")?.nilIfEmpty,
            artist: post.string("artist")?.nilIfEmpty,
            description: description,
            genres: post.array("genres").compactMap { $0.string("name") },
            status: statusMap[post.string("seriesStatus") ?? ""] ?? 0,
            coverUrl: post.string("featuredImage"),
            altTitles: alt.map { $0.split(whereSeparator: { ",;/|".contains($0) }).map { String($0).trimmed } } ?? []
        )

        let chapters: [SourceChapterItem] = rawChapters.enumerated().compactMap { index, ch in
            guard let id = ch.int("id") else { return nil }
            let locked = (ch["isLocked"] as? Bool) == true || (ch["isTimeLocked"] as? Bool) == true
                || ((ch["chapterPurchased"] as? Bool) == false && (ch.int("price") ?? 0) != 0)
            if locked { return nil }
            let number = ch.string("number") ?? "\(index + 1)"
            var name = "Cap. \(number)"
            if let title = ch.string("title")?.nilIfEmpty { name += " - \(title)" }
            let date = ch.string("createdAt").flatMap(DateParsing.iso)
            var item = chapter(remoteUrl: "\(id)", name: name, index: index, number: Double(number), date: date)
            item.mangaRemoteUrl = remoteUrl
            return item
        }
        return (detail, chapters)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        guard let root = try await http.json("\(apiUrl)/api/chapter?chapterId=\(chapterRemoteUrl)", headers: ["Referer": "\(baseUrl)/"]) as? [String: Any],
              let chapter = root.dict("chapter") else {
            throw HTTPError.parse("as páginas")
        }
        if (chapter["isLockedByCoins"] as? Bool) == true || (chapter["isPermanentlyLocked"] as? Bool) == true {
            throw HTTPError.parse("este capítulo (bloqueado no site)")
        }
        let urls = chapter.array("images").compactMap { $0.string("url") }
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: "\(baseUrl)/") }
    }
}

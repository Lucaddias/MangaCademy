import Foundation

/// NexusToons (extensão pt.spectralscan do Keiyoushi) — API própria com respostas cifradas (OrionCrypto).
public final class NexusToonsSource: MangaSource {
    public let id: String = "nexustoons"
    public let name: String = "NexusToons"
    public let language: String = "pt-BR"
    public let baseUrl: String = "https://nexustoons.com"

    private let pageSize = 30
    private let http = HTTPClient.shared
    private let crypto = OrionCrypto.shared

    public init() {}

    private var headers: [String: String] { ["Referer": "\(baseUrl)/"] }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await list("\(baseUrl)/api/mangas?page=\(page)&limit=\(pageSize)")
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await fetchPopular(page: page)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await list("\(baseUrl)/api/mangas?search=\(HTTPClient.queryEncode(query))&page=\(page)&limit=\(pageSize)")
    }

    private func list(_ url: String) async throws -> SourceMangaPage {
        guard let json = try await http.json(url, headers: headers) as? [String: Any] else { return .empty }
        let items: [SourceMangaItem] = json.array("data").compactMap { item in
            guard let slug = item.string("slug"), let title = item.string("title") else { return nil }
            return SourceMangaItem(
                sourceId: id,
                remoteUrl: slug,
                title: title,
                coverUrl: item.string("coverImage"),
                status: item.string("status"),
                languages: [language],
                altTitles: Self.alternativeTitles(item["alternativeTitles"]),
                genres: Self.genres(item),
                hasFullMetadata: true
            )
        }
        let page = json.int("page") ?? 1
        let pages = json.int("pages") ?? page
        return SourceMangaPage(items: items, hasNextPage: page < pages && !items.isEmpty)
    }

    /// Categorias: na listagem vêm como `{category: {name}}`, nos detalhes como `{name}`.
    /// Obras/categorias marcadas `isNsfw` contam como conteúdo adulto.
    private static func genres(_ manga: [String: Any]) -> [String] {
        var names: [String] = []
        var adult = (manga["isNsfw"] as? Bool) == true
        for entry in manga.array("categories") {
            let category = entry.dict("category") ?? entry
            if let name = category.string("name") { names.append(name) }
            if (category["isNsfw"] as? Bool) == true { adult = true }
        }
        if adult { names.append("Adulto") }
        return names
    }
    
    /// `alternativeTitles` vem como string: JSON `[{"lang":"en","title":"..."}]`, JSON de strings
    /// ou texto simples separado por vírgulas.
    private static func alternativeTitles(_ raw: Any?) -> [String] {
        func titles(from value: Any) -> [String]? {
            if let list = value as? [String] { return list }
            if let list = value as? [[String: Any]] { return list.compactMap { $0.string("title") } }
            return nil
        }
        if let raw, let list = titles(from: raw) { return list.filter { !$0.trimmed.isEmpty } }
        guard let text = (raw as? String)?.nilIfEmpty else { return [] }
        if text.hasPrefix("["), let data = text.data(using: .utf8) {
            // JSON malformado não deve virar fragmentos de título
            guard let json = try? JSONSerialization.jsonObject(with: data), let list = titles(from: json) else { return [] }
            return list.filter { !$0.trimmed.isEmpty }
        }
        return text.split(whereSeparator: { ",;|\n".contains($0) }).map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        guard let envelope = try await http.json("\(baseUrl)/api/manga/\(remoteUrl)", headers: headers) as? [String: Any] else {
            throw HTTPError.parse("os detalhes da obra")
        }
        let manga: [String: Any]
        if envelope["d"] != nil {
            let decrypted = try crypto.decryptEnvelope(json: envelope)
            guard let obj = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else {
                throw HTTPError.parse("os detalhes da obra")
            }
            manga = obj
        } else {
            manga = envelope
        }

        let genres = Self.genres(manga)
        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: manga.string("title") ?? remoteUrl,
            author: manga.string("author")?.nilIfEmpty,
            artist: manga.string("artist")?.nilIfEmpty,
            description: manga.string("description"),
            genres: genres,
            status: StatusParser.parse(manga.string("status")),
            coverUrl: manga.string("coverImage"),
            altTitles: Self.alternativeTitles(manga["alternativeTitles"])
        )

        let chapters: [SourceChapterItem] = manga.array("chapters").enumerated().compactMap { idx, ch in
            guard let chId = ch.string("id") else { return nil }
            let number = ch.string("number") ?? "\(idx + 1)"
            var name = "Capítulo \(number)"
            if let title = ch.string("title")?.nilIfEmpty { name += ": \(title)" }
            return SourceChapterItem(
                remoteUrl: chId,
                name: name,
                chapterNumber: Double(number) ?? ChapterNumberParser.parse(name),
                orderIndex: idx,
                scanlator: "NexusToons",
                uploadDate: ch.string("createdAt").flatMap(DateParsing.iso),
                language: language,
                sourceId: id,
                mangaRemoteUrl: remoteUrl
            )
        }
        return (detail, chapters)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let referer = "\(baseUrl)/ler/\(mangaRemoteUrl)/\(chapterRemoteUrl)"
        guard let envelope = try await http.json("\(baseUrl)/api/chapter/\(chapterRemoteUrl)", headers: ["Referer": referer]) as? [String: Any] else {
            throw HTTPError.parse("as páginas")
        }
        let json: [String: Any]
        if envelope["d"] != nil {
            let decrypted = try crypto.decryptEnvelope(json: envelope)
            json = (try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any]) ?? [:]
        } else {
            json = envelope
        }
        return json.array("pages").enumerated().compactMap { index, p in
            guard let imgUrl = p.string("imageUrl") else { return nil }
            return SourcePageItem(pageNumber: p.int("pageNumber") ?? (index + 1), imageUrl: imgUrl, referer: "\(baseUrl)/")
        }
    }
}

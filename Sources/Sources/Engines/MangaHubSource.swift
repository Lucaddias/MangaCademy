import CryptoKit
import Foundation

/// Port do tema MangaHub (GraphQL em api.mghcdn.com) — lib-multisrc/mangahub. Todos os sites da
/// rede usam a mesma API; `config.mangaSource` ("m01", "mf01"...) escolhe o acervo do site.
public final class MangaHubSource: ThemeSource, MangaSource {
    private static let apiUrl = "https://api.mghcdn.com/graphql"
    private static let cdnUrl = "https://imgx.mghcdn.com"
    private static let thumbUrl = "https://thumb.mghcdn.com"
    private static let apiErrorRegex = try! NSRegularExpression(pattern: #"rate\s*limit|api\s*key|encryption"#, options: .caseInsensitive)
    private static let pageSize = 30

    private let keyLock = NSLock()
    private var apiKey = MangaHubSource.randomKey()

    private var mangaSource: String { config.mangaSource ?? "m01" }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        try await list(page: page, order: "POPULAR")
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        try await list(page: page, order: "LATEST")
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        try await list(page: page, order: "POPULAR", query: query)
    }

    private func list(page: Int, order: String, query: String = "") async throws -> SourceMangaPage {
        let gql = """
        { search(x: \(mangaSource), q: \(Self.quoted(query)), genre: "all", mod: \(order), offset: \((page - 1) * Self.pageSize)) {
            rows { title, slug, image, latestChapter, updatedDate } } }
        """
        let rows = try await graphQL(gql).dict("search")?.array("rows") ?? []
        let items: [SourceMangaItem] = rows.compactMap { row in
            guard let slug = row.string("slug"), let title = row.string("title") else { return nil }
            var result = item(remoteUrl: "/manga/\(slug)", title: title, cover: Self.thumbnail(row.string("image")))
            result.latestChapterName = row.string("latestChapter").map { "Cap. \(Self.number($0))" }
            // updatedDate pertence à obra e pode mudar sem capítulo novo.
            return result
        }
        return SourceMangaPage(items: items, hasNextPage: rows.count == Self.pageSize)
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let slug = remoteUrl.replacingOccurrences(of: "/manga/", with: "")
        let gql = """
        { manga(x: \(mangaSource), slug: \(Self.quoted(slug))) {
            title, slug, status, image, author, artist, genres, description, alternativeTitle,
            chapters { number, title, date } } }
        """
        guard let manga = try await graphQL(gql, refreshUrl: "\(baseUrl)\(remoteUrl)").dict("manga") else {
            throw HTTPError.parse("os detalhes da obra")
        }
        let altTitles = (manga.string("alternativeTitle") ?? "").split(separator: ";").map { String($0).trimmed }.filter { !$0.isEmpty }
        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl,
            title: manga.string("title") ?? slug,
            author: manga.string("author")?.nilIfEmpty,
            artist: manga.string("artist")?.nilIfEmpty,
            description: manga.string("description")?.nilIfEmpty,
            genres: (manga.string("genres") ?? "").split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty },
            status: StatusParser.parse(manga.string("status")),
            coverUrl: Self.thumbnail(manga.string("image")),
            altTitles: altTitles
        )
        // A API manda do mais antigo para o mais novo
        let raw = manga.array("chapters").reversed()
        let chapters: [SourceChapterItem] = raw.enumerated().compactMap { index, ch in
            guard let numberText = ch.string("number"), let number = Double(numberText) else { return nil }
            let display = Self.number(numberText)
            let title = (ch.string("title") ?? "").collapsedWhitespace
            let name = title.contains(display) ? title : (title.isEmpty ? "Chapter \(display)" : "Chapter \(display) - \(title)")
            var item = chapter(remoteUrl: "/\(slug)/chapter-\(display)", name: name, index: index, number: number,
                               date: ch.string("date").flatMap(DateParsing.iso))
            item.mangaRemoteUrl = remoteUrl
            return item
        }
        return (detail, chapters)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let parts = chapterRemoteUrl.split(separator: "/")
        guard parts.count == 2, let number = Double(parts[1].replacingOccurrences(of: "chapter-", with: "")) else {
            throw HTTPError.parse("as páginas")
        }
        let gql = "{ chapter(x: \(mangaSource), slug: \(Self.quoted(String(parts[0]))), number: \(number)) { pages, mangaID, number } }"
        guard var pages = try await graphQL(gql, refreshUrl: "\(baseUrl)/chapter\(chapterRemoteUrl)").dict("chapter")?.string("pages") else {
            throw HTTPError.parse("as páginas")
        }
        if pages.hasPrefix("enc:v1") { pages = try await decrypt(pages) }

        let json = try? JSONSerialization.jsonObject(with: Data(pages.utf8))
        var paths: [String] = []
        if let object = json as? [String: Any], let images = object["i"] as? [String] {
            let prefix = object.string("p") ?? ""
            paths = images.map { prefix + $0 }
        } else if let array = json as? [String] {
            paths = array
        } else if let object = json as? [String: Any] {
            paths = object.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { object[$0] as? String }
        }
        return paths.enumerated().map { index, path in
            let url = path.hasPrefix("http") ? path : "\(Self.cdnUrl)/\(path.hasPrefix("/") ? String(path.dropFirst()) : path)"
            return SourcePageItem(pageNumber: index + 1, imageUrl: url, referer: "\(baseUrl)/")
        }
    }

    // MARK: - API

    private func currentKey() -> String {
        keyLock.lock()
        defer { keyLock.unlock() }
        return apiKey
    }

    private func setKey(_ key: String) {
        keyLock.lock()
        apiKey = key
        keyLock.unlock()
    }

    /// Faz a consulta; se a API recusar a chave, pede uma nova ao site (ou gera outra) e tenta de novo.
    private func graphQL(_ query: String, refreshUrl: String? = nil) async throws -> [String: Any] {
        do {
            return try await request(query)
        } catch let error as HTTPError {
            switch error {
            case .parse(let message) where Self.isKeyError(message): break
            case .badStatus(let code) where [401, 403, 429].contains(code): break
            default: throw error
            }
            let old = currentKey()
            await refreshKey(from: refreshUrl ?? "\(baseUrl)/chapter/martial-peak/chapter-\(Int.random(in: 1000...3000))")
            if currentKey() == old { setKey(Self.randomKey()) }
            return try await request(query)
        }
    }

    private func request(_ query: String) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["query": query])
        let headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Origin": baseUrl,
            "Referer": "\(baseUrl)/",
            "x-mhub-access": currentKey(),
        ]
        let (data, _) = try await http.data(Self.apiUrl, method: "POST", headers: headers, body: body)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.parse("a resposta JSON")
        }
        if let message = root.array("errors").first?.string("message") { throw HTTPError.parse(message) }
        guard let payload = root.dict("data") else { throw HTTPError.parse("a resposta JSON") }
        return payload
    }

    /// A página do capítulo devolve a chave no cookie `mhub_access`.
    private func refreshKey(from url: String) async {
        for suffix in ["?reloadKey=1", ""] {
            _ = try? await http.data(url + suffix, headers: ["Referer": "\(baseUrl)/"])
            if let host = URL(string: baseUrl)?.host,
               let cookie = HTTPCookieStorage.shared.cookies?.first(where: { $0.name == "mhub_access" && host.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }),
               !cookie.value.isEmpty, cookie.value != currentKey() {
                setKey(cookie.value)
                return
            }
        }
    }

    /// Páginas cifradas: "enc:v1:<keyId>:<iv>:<tag>:<dados>" em AES-GCM, chave em /api/chapter-crypto.
    private func decrypt(_ value: String) async throws -> String {
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count >= 6,
              let crypto = try await http.json("\(baseUrl)/api/chapter-crypto", headers: ["x-mhub-access": currentKey()]) as? [String: Any] else {
            throw HTTPError.parse("as páginas")
        }
        let keyId = parts[2]
        let keyText = (crypto["keys"] as? [String: String])?[keyId]
            ?? crypto.string("key").flatMap { key in crypto.string("keyId").map { $0 == keyId ? key : nil } ?? key }
        guard let keyText,
              let key = Data(base64URL: keyText), let iv = Data(base64URL: parts[3]),
              let tag = Data(base64URL: parts[4]), let cipher = Data(base64URL: parts[5]),
              let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)),
              let text = String(data: plain, encoding: .utf8) else {
            throw HTTPError.parse("as páginas (cifradas)")
        }
        return text
    }

    // MARK: - Auxiliares

    private static func isKeyError(_ message: String) -> Bool {
        apiErrorRegex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) != nil
    }

    private static func randomKey() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func thumbnail(_ image: String?) -> String? {
        guard let image = image?.nilIfEmpty else { return nil }
        return image.hasPrefix("http") ? image : "\(thumbUrl)/\(image)"
    }

    /// "92.0" → "92"
    private static func number(_ text: String) -> String {
        text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// Literal de string GraphQL (aspas e barras escapadas como no JSON).
    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: .fragmentsAllowed),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}

extension Data {
    /// Base64 "URL safe" (com - e _), com ou sem preenchimento.
    init?(base64URL value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }
}

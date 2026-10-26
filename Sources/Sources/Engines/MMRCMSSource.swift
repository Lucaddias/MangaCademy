import Foundation

/// Port do tema "My Manga Reader CMS" — lib-multisrc/mmrcms (Laravel, layout Bootstrap).
public final class MMRCMSSource: ThemeSource, MangaSource {
    private var itemPath: String { config.itemPath ?? "manga" }

    private var chapterString: String {
        switch language {
        case "es", "es-419": return "Capítulo"
        case "fr": return "Chapitre"
        default: return "Chapter"
        }
    }

    private lazy var chapterDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = config.dateFormat ?? "d MMM. yyyy"
        return formatter
    }()
    private let dateLock = NSLock()

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        if let path = config.popularPath {
            guard page == 1 else { return .empty }
            return try await cards("\(baseUrl)/\(path)")
        }
        return try await cards("\(baseUrl)/filterList?page=\(page)&sortBy=views&asc=false")
    }

    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        let doc = try await http.html("\(baseUrl)/latest-release?page=\(page)")
        var seen = Set<String>()
        let items: [SourceMangaItem] = doc.select("//div[\(cls("mangalist"))]//div[\(cls("manga-item"))]").compactMap { row in
            guard let link = row.first(".//*[\(cls("manga-heading"))]//a"), let href = link.absAttr("href") else { return nil }
            let path = storedPath(href)
            guard seen.insert(path).inserted else { return nil }
            var result = item(remoteUrl: path, title: link.text, cover: guessCover(path, nil))
            result.latestChapterName = row.first(".//*[\(cls("manga-chapter"))]//a")?.text.nilIfEmpty
            result.latestChapterDate = ChapterDateParser.parse(row.first(".//small")?.text, language: language)
            return result
        }
        return SourceMangaPage(items: items, hasNextPage: doc.first("//*[\(cls("pagination"))]//a[@rel='next']") != nil)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        guard let root = try await http.json("\(baseUrl)/search?query=\(HTTPClient.queryEncode(query))") as? [String: Any] else { return .empty }
        let suggestions = root.array("suggestions")
        let slice = suggestions.dropFirst((page - 1) * 24).prefix(24)
        let items: [SourceMangaItem] = slice.compactMap { entry in
            guard let slug = entry.string("data"), let title = entry.string("value") else { return nil }
            let path = itemPath.isEmpty ? "/\(slug)" : "/\(itemPath)/\(slug)"
            return item(remoteUrl: path, title: title, cover: guessCover(path, nil))
        }
        return SourceMangaPage(items: items, hasNextPage: suggestions.count > page * 24)
    }

    private func cards(_ url: String) async throws -> SourceMangaPage {
        let doc = try await http.html(url)
        let items: [SourceMangaItem] = doc.select("//div[\(cls("media"))]").compactMap { card in
            guard let link = card.first(".//*[\(cls("media-heading")) or \(cls("manga-heading"))]//a"), let href = link.absAttr("href") else { return nil }
            let path = storedPath(href)
            return item(remoteUrl: path, title: link.text, cover: guessCover(path, card.first(".//img").flatMap(imageAttr)))
        }
        return SourceMangaPage(items: items, hasNextPage: doc.first("//*[\(cls("pagination"))]//a[@rel='next']") != nil)
    }

    /// Sem capa (ou com a imagem padrão), o tema guarda a capa num caminho fixo.
    private func guessCover(_ path: String, _ url: String?) -> String {
        if let url, !url.hasSuffix("no-image.png") { return url }
        let slug = path.split(separator: "/").last.map(String.init) ?? ""
        return "\(baseUrl)/uploads/manga/\(slug)/cover/cover_250x350.jpg"
    }

    private func imageAttr(_ img: HTMLElement) -> String? {
        img.absAttr("data-background-image") ?? img.imageURL
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let doc = try await http.html(absoluteURL(remoteUrl))
        let title = doc.first("//*[\(cls("listmanga-header")) or \(cls("widget-title")) or \(cls("panel-heading"))]")?.text ?? remoteUrl

        var author: String?, artist: String?, genres: [String] = [], status = 0, altTitles: [String] = []
        // Rótulos em várias línguas (<dt>), ou <h3> no layout do Onma
        let labels = doc.select("//*[\(cls("row"))]//dl[\(cls("dl-horizontal"))]/dt | //*[\(cls("panel-body"))]//h3")
        for label in labels {
            let key = (label.tagName == "dt" ? label.text : label.ownText).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            guard let value = label.tagName == "dt" ? label.first("./following-sibling::dd[1]") : label.first(".//div[\(cls("text"))]") else { continue }
            if Self.authorLabels.contains(key) { author = value.text.nilIfEmpty }
            else if Self.artistLabels.contains(key) { artist = value.text.nilIfEmpty }
            else if Self.genreLabels.contains(key) { genres = value.select(".//a").map(\.text).filter { !$0.isEmpty } }
            else if Self.statusLabels.contains(key) { status = StatusParser.parse(value.text) }
            else if Self.altLabels.contains(key) {
                altTitles = value.text.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
            }
        }
        if status == 0 { status = StatusParser.parse(doc.first("//div[\(cls("manga-name"))]//span[\(cls("label"))]")?.text) }
        let description = doc.select("//*[\(cls("row"))]//*[\(cls("well"))]//p").map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let cover = doc.first("//*[\(cls("row"))]//img[\(cls("img-responsive"))]").flatMap(imageAttr)
        let detail = SourceMangaDetail(
            remoteUrl: remoteUrl, title: title, author: author, artist: artist,
            description: description.nilIfEmpty, genres: genres, status: status,
            coverUrl: guessCover(remoteUrl, cover), altTitles: altTitles
        )

        let rows = doc.select("//ul[\(cls("chapters"))]/li[not(\(cls("btn")))]")
        let chapters: [SourceChapterItem] = rows.enumerated().compactMap { index, row in
            guard let wrapper = row.first(".//*[\(cls("chapter-title-rtl"))]"), let href = wrapper.first(".//a")?.absAttr("href") else { return nil }
            let dateText = row.first(".//*[\(cls("date-chapter-title-rtl"))]")?.text
            var item = chapter(remoteUrl: storedPath(href), name: cleanChapterName(title, wrapper.text), index: index, date: parseDate(dateText))
            item.mangaRemoteUrl = remoteUrl
            return item
        }
        return (detail, chapters)
    }

    /// "One Piece 1196 : Título" → "Chapitre 1196: Título".
    func cleanChapterName(_ mangaTitle: String, _ name: String) -> String {
        var text = name
        let prefix = (config.chapterNamePrefix ?? "") + mangaTitle
        if !prefix.isEmpty, let range = text.range(of: prefix) { text.replaceSubrange(range, with: chapterString) }
        let parts = text.split(separator: ":", maxSplits: 1).map { String($0).trimmed }
        return parts.count < 2 || parts[0] == parts[1] ? parts.first ?? text : "\(parts[0]): \(parts[1])"
    }

    private func parseDate(_ text: String?) -> Date? {
        guard let text = text?.trimmed.nilIfEmpty else { return nil }
        dateLock.lock()
        let date = chapterDate.date(from: text)
        dateLock.unlock()
        return date ?? ChapterDateParser.parse(text, language: language)
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let chapterURL = absoluteURL(chapterRemoteUrl)
        let doc = try await http.html(chapterURL)
        let urls = doc.select("//*[@id='all']/img[\(cls("img-responsive"))]").compactMap(imageAttr)
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element.trimmed, referer: chapterURL) }
    }

    private static let authorLabels: Set<String> = ["author(s)", "autor(es)", "auteur(s)", "著作", "yazar(lar)", "mangaka(lar)", "pengarang/penulis", "pengarang", "penulis", "autor", "المؤلف", "перевод", "autor/autorzy"]
    private static let artistLabels: Set<String> = ["artist(s)", "artiste(s)", "sanatçi(lar)", "artista(s)", "artist(s)/ilustrator", "الرسام", "seniman", "rysownik/rysownicy", "artista"]
    private static let genreLabels: Set<String> = ["categories", "categorías", "catégories", "ジャンル", "kategoriler", "categorias", "kategorie", "التصنيفات", "жанр", "kategori", "tagi", "género"]
    private static let statusLabels: Set<String> = ["status", "statut", "estado", "状態", "durum", "الحالة", "статус"]
    private static let altLabels: Set<String> = ["other names", "autres noms", "otros nombres", "outros nomes", "أسماء أخرى"]
}

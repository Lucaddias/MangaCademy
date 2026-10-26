import Foundation

/// Port do tema MangaCatalog — lib-multisrc/mangacatalog. Cada site é dedicado a uma franquia e
/// tem poucas séries, listadas na extensão (`config.series`, extraído pelo gerador do catálogo).
/// Há dois layouts: Tailwind (padrão do tema) e Bootstrap (tabela com data, ex.: readberserk.com).
public final class MangaCatalogSource: ThemeSource, MangaSource {
    private static let chapterNumberRegex = try! NSRegularExpression(pattern: #"chapter-(\d+(?:[.-]\d+)?)"#)
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private var series: [SourceMangaItem] {
        (config.series ?? []).compactMap { pair in
            guard pair.count == 2 else { return nil }
            let path = storedPath(absoluteURL(pair[1]))
            return item(remoteUrl: path, title: Self.title(fromPath: path) ?? pair[0], cover: nil)
        }
    }

    public func fetchPopular(page: Int) async throws -> SourceMangaPage {
        SourceMangaPage(items: page == 1 ? series : [], hasNextPage: false)
    }

    /// O tema não tem "Recentes": abre a página de cada série para saber o capítulo mais novo.
    public func fetchLatest(page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        let items = await withTaskGroup(of: (Int, SourceMangaItem).self) { group in
            for (index, base) in series.enumerated() {
                group.addTask {
                    var result = base
                    if let (detail, chapters) = try? await self.fetchDetails(remoteUrl: base.remoteUrl) {
                        result.coverUrl = detail.coverUrl
                        result.latestChapterName = chapters.first?.name
                        result.latestChapterDate = chapters.first?.uploadDate
                    }
                    return (index, result)
                }
            }
            var collected: [(Int, SourceMangaItem)] = []
            for await entry in group { collected.append(entry) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let sorted = items
            .filter { $0.latestChapterName != nil }
            .sorted { ($0.latestChapterDate ?? .distantPast) > ($1.latestChapterDate ?? .distantPast) }
        return SourceMangaPage(items: sorted, hasNextPage: false)
    }

    public func search(query: String, page: Int) async throws -> SourceMangaPage {
        guard page == 1 else { return .empty }
        let q = query.lowercased()
        let matches = (config.series ?? []).enumerated().filter { $0.element.first?.lowercased().contains(q) == true }.map(\.offset)
        let all = series
        return SourceMangaPage(items: matches.compactMap { all.indices.contains($0) ? all[$0] : nil }, hasNextPage: false)
    }

    /// "/manga/berserk-colored/" → "Berserk Colored" (o nome curto da extensão, ex.: "Colored",
    /// misturaria séries de sites diferentes no catálogo unificado).
    static func title(fromPath path: String) -> String? {
        guard let slug = path.split(separator: "/").last(where: { !$0.isEmpty }), slug != "manga" else { return nil }
        return slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    public func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let doc = try await http.html(absoluteURL(remoteUrl))
        return (parseDetail(doc, remoteUrl: remoteUrl), parseChapters(doc, remoteUrl: remoteUrl))
    }

    func parseDetail(_ doc: HTMLDocument, remoteUrl: String) -> SourceMangaDetail {
        let bootstrap = doc.first("//h2/span")
        let rawTitle = bootstrap?.text.nilIfEmpty
            ?? doc.first("//div[\(cls("container"))]/h1")?.text.nilIfEmpty
            ?? doc.first("//meta[@property='og:title']")?.attr("content")?.components(separatedBy: "|").first?.trimmed
        let title = rawTitle.map { $0.hasPrefix("Manga: ") ? String($0.dropFirst(7)) : $0 }
            ?? Self.title(fromPath: remoteUrl) ?? name
        var description: String?
        if bootstrap != nil {
            description = doc.first("//div[\(cls("card-body"))]/p")?.text.nilIfEmpty
        } else {
            let info = doc.first("//div[\(cls("bg-bg-secondary"))]/div[\(cls("px-6"))]/div[\(cls("flex-col"))]")?.text ?? ""
            description = (info.range(of: "Description").map { String(info[$0.upperBound...]) } ?? info).trimmed.nilIfEmpty
        }
        description = description ?? doc.first("//meta[@property='og:description']")?.attr("content")?.nilIfEmpty
        let cover = doc.first("//img[\(cls("card-img-right"))]")?.imageURL
            ?? doc.first("//div[\(cls("flex"))]/img")?.imageURL
            ?? doc.first("//meta[@property='og:image']")?.attr("content")
        return SourceMangaDetail(remoteUrl: remoteUrl, title: title, description: description, coverUrl: cover)
    }

    func parseChapters(_ doc: HTMLDocument, remoteUrl: String) -> [SourceChapterItem] {
        var entries: [(url: String, name: String, date: Date?)] = []
        // Bootstrap: tabela com nome, data e botão "Read"
        for row in doc.select("//tbody/tr") {
            guard let href = (row.first(".//a[\(cls("btn-primary"))]") ?? row.first(".//a[@href]"))?.absAttr("href") else { continue }
            let name = row.first("./td[1]")?.text ?? ""
            let date = row.first("./td[2]").flatMap { Self.dateFormatter.date(from: $0.text) }
            entries.append((href, name, date))
        }
        // Tailwind: cartões com o link do capítulo e um subtítulo opcional
        if entries.isEmpty {
            for card in doc.select("//div[\(cls("w-full"))]//div[\(cls("bg-bg-secondary"))]/div[\(cls("grid"))]") {
                guard let link = card.first(".//div[contains(@class, 'col-span-4')]/a"), let href = link.absAttr("href") else { continue }
                let subtitle = card.first(".//div[\(cls("text-xs"))]")?.text ?? ""
                entries.append((href, subtitle.isEmpty ? link.text : "\(link.text) - \(subtitle)", nil))
            }
        }
        // Tower of God: só links soltos para os capítulos
        if entries.isEmpty {
            var seen = Set<String>()
            for link in doc.select("//a[contains(@href, '-chapter-')]") {
                guard let href = link.absAttr("href"), seen.insert(href).inserted else { continue }
                let range = NSRange(href.startIndex..., in: href)
                guard let match = Self.chapterNumberRegex.firstMatch(in: href, range: range),
                      let numberRange = Range(match.range(at: 1), in: href) else { continue }
                entries.append((href, "Chapter \(href[numberRange])", nil))
            }
        }
        return entries.enumerated().map { index, entry in
            var item = chapter(remoteUrl: storedPath(entry.url), name: entry.name, index: index, date: entry.date)
            item.mangaRemoteUrl = remoteUrl
            return item
        }
    }

    public func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let chapterURL = absoluteURL(chapterRemoteUrl)
        let doc = try await http.html(chapterURL)
        // A 1ª página vem com src e as demais com data-src: o seletor do Kotlin (img[data-src]) perde a 1ª
        var urls = doc.select("//img[\(cls("js-page"))]").compactMap(\.imageURL)
        if urls.isEmpty { urls = doc.select("//div[\(cls("pages"))]//img[\(cls("pages__img"))]").compactMap(\.imageURL) }
        if urls.isEmpty { urls = doc.select("//img[@data-src]").compactMap(\.imageURL) }
        if urls.isEmpty {
            urls = doc.select("//img[contains(@src, 'blogger.googleusercontent.com') or contains(@src, 'bp.blogspot.com')]").compactMap(\.imageURL)
        }
        var seen = Set<String>()
        urls = urls.filter { seen.insert($0).inserted }
        return urls.enumerated().map { SourcePageItem(pageNumber: $0.offset + 1, imageUrl: $0.element, referer: chapterURL) }
    }
}

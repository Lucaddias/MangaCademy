import Foundation

/// Base comum dos motores que reimplementam os temas multisrc do Keiyoushi.
public class ThemeSource {
    public let id: String
    public let name: String
    public let language: String
    public let baseUrl: String
    public let config: KeiyoushiEngineConfig
    let http = HTTPClient.shared

    public init(id: String, name: String, language: String, baseUrl: String, config: KeiyoushiEngineConfig) {
        self.id = id
        self.name = name
        self.language = language
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.config = config
    }

    /// URL absoluta para um caminho guardado como referência.
    func absoluteURL(_ pathOrURL: String) -> String {
        if pathOrURL.hasPrefix("http://") || pathOrURL.hasPrefix("https://") { return pathOrURL }
        return baseUrl + (pathOrURL.hasPrefix("/") ? pathOrURL : "/\(pathOrURL)")
    }

    /// Guarda somente o caminho quando a URL é do próprio site (sobrevive a troca de domínio).
    func storedPath(_ url: String) -> String {
        guard let host = URL(string: url)?.host, let baseHost = URL(string: baseUrl)?.host else { return url }
        return host == baseHost ? url.urlPath : url
    }

    func item(remoteUrl: String, title: String, cover: String?) -> SourceMangaItem {
        SourceMangaItem(sourceId: id, remoteUrl: remoteUrl, title: title, coverUrl: cover, languages: [language])
    }

    func chapter(remoteUrl: String, name: String, index: Int, number: Double? = nil, scanlator: String? = nil, date: Date? = nil) -> SourceChapterItem {
        SourceChapterItem(
            remoteUrl: remoteUrl,
            name: name,
            chapterNumber: number ?? ChapterNumberParser.parse(name),
            orderIndex: index,
            scanlator: scanlator,
            uploadDate: date,
            language: language,
            sourceId: id
        )
    }
}

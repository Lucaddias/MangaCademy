import Foundation

public protocol MangaSource: AnyObject {
    var id: String { get }
    var name: String { get }
    /// Idioma normalizado da fonte ("pt-BR", "en"...) ou "all" para fontes multi-idioma.
    var language: String { get }
    var baseUrl: String { get }
    /// Referer enviado ao baixar capas e páginas desta fonte.
    var imageReferer: String? { get }

    func fetchPopular(page: Int) async throws -> SourceMangaPage
    func fetchLatest(page: Int) async throws -> SourceMangaPage
    func search(query: String, page: Int) async throws -> SourceMangaPage
    func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem])
    /// Só os dados da obra (títulos alternativos, tags, capa), sem a lista de capítulos.
    func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail
    func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem]
}

public extension MangaSource {
    var imageReferer: String? { baseUrl.isEmpty ? nil : "\(baseUrl)/" }

    func fetchMetadata(remoteUrl: String) async throws -> SourceMangaDetail {
        try await fetchDetails(remoteUrl: remoteUrl).0
    }
}

/// Fontes multi-idioma que se ajustam ao filtro de idioma/+18 (ex.: MangaDex, ComicK).
/// Retorna `nil` quando a fonte não deve participar do catálogo para aquele filtro.
public protocol LanguageScopedSource: MangaSource {
    func scoped(to filter: LanguageFilter, includeNsfw: Bool) -> MangaSource?
}

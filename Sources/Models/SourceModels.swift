import Foundation

public struct SourceMangaItem: Identifiable, Hashable {
    public let id: String
    public let sourceId: String
    public let remoteUrl: String
    public let title: String
    public var coverUrl: String?
    public let status: String?
    /// Idiomas (normalizados) em que a obra está disponível nesta fonte.
    public let languages: [String]
    /// Títulos alternativos conhecidos — usados para unificar a obra entre fontes/idiomas.
    public var altTitles: [String]
    /// Gêneros/tags (usados no filtro de conteúdo adulto).
    public var genres: [String]
    /// A listagem já trouxe títulos alternativos e tags (não precisa abrir a página da obra).
    public var hasFullMetadata: Bool

    public init(
        sourceId: String,
        remoteUrl: String,
        title: String,
        coverUrl: String?,
        status: String? = nil,
        languages: [String] = [],
        altTitles: [String] = [],
        genres: [String] = [],
        hasFullMetadata: Bool = false
    ) {
        self.id = "\(sourceId):\(remoteUrl)"
        self.sourceId = sourceId
        self.remoteUrl = remoteUrl
        self.title = title
        self.coverUrl = coverUrl
        self.status = status
        self.languages = languages
        self.altTitles = altTitles
        self.genres = genres
        self.hasFullMetadata = hasFullMetadata
    }
}

/// Uma página de resultados de catálogo/busca de uma fonte.
public struct SourceMangaPage {
    public let items: [SourceMangaItem]
    public let hasNextPage: Bool

    public init(items: [SourceMangaItem], hasNextPage: Bool) {
        self.items = items
        self.hasNextPage = hasNextPage
    }

    public static let empty = SourceMangaPage(items: [], hasNextPage: false)
}

public struct SourceMangaDetail {
    public let remoteUrl: String
    public let title: String
    public let author: String?
    public let artist: String?
    public let description: String?
    public let genres: [String]
    public let status: Int
    public let coverUrl: String?
    public let altTitles: [String]

    public init(
        remoteUrl: String,
        title: String,
        author: String? = nil,
        artist: String? = nil,
        description: String? = nil,
        genres: [String] = [],
        status: Int = 0,
        coverUrl: String? = nil,
        altTitles: [String] = []
    ) {
        self.remoteUrl = remoteUrl
        self.title = title
        self.author = author
        self.artist = artist
        self.description = description
        self.genres = genres
        self.status = status
        self.coverUrl = coverUrl
        self.altTitles = altTitles
    }
}

public struct SourceChapterItem: Identifiable, Hashable {
    public var id: String { "\(sourceId):\(remoteUrl)" }
    public let remoteUrl: String
    public let name: String
    public let chapterNumber: Double
    public let scanlator: String?
    public let uploadDate: Date?
    public let orderIndex: Int
    /// Idioma do capítulo. `nil` = idioma da fonte.
    public var language: String?
    /// Fonte e obra de origem — necessários quando a lista mistura capítulos de várias fontes.
    public var sourceId: String
    public var mangaRemoteUrl: String

    public init(
        remoteUrl: String,
        name: String,
        chapterNumber: Double,
        orderIndex: Int,
        scanlator: String? = nil,
        uploadDate: Date? = nil,
        language: String? = nil,
        sourceId: String = "",
        mangaRemoteUrl: String = ""
    ) {
        self.remoteUrl = remoteUrl
        self.name = name
        self.chapterNumber = chapterNumber
        self.orderIndex = orderIndex
        self.scanlator = scanlator
        self.uploadDate = uploadDate
        self.language = language
        self.sourceId = sourceId
        self.mangaRemoteUrl = mangaRemoteUrl
    }
}

public struct SourcePageItem: Identifiable, Hashable {
    public let id: Int
    public let pageNumber: Int
    public let imageUrl: String
    public let width: Int?
    public let height: Int?
    /// Referer exigido por alguns sites para servir as imagens (proteção contra hotlink).
    public let referer: String?

    public init(pageNumber: Int, imageUrl: String, width: Int? = nil, height: Int? = nil, referer: String? = nil) {
        self.id = pageNumber
        self.pageNumber = pageNumber
        self.imageUrl = imageUrl
        self.width = width
        self.height = height
        self.referer = referer
    }
}

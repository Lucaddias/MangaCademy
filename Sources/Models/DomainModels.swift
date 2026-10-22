import Foundation
import SwiftData

// O resto do app usa os nomes curtos, sempre apontando para a versão atual do banco.
public typealias Manga = SchemaV3.Manga
public typealias Chapter = SchemaV3.Chapter
public typealias HistoryEntry = SchemaV3.HistoryEntry
public typealias MangaCategory = SchemaV3.MangaCategory
public typealias TrackRecord = SchemaV3.TrackRecord

/// Versão atual do banco. Para mudar um modelo: copie este arquivo para `Schema/SchemaV3.swift`
/// (congelado), crie `SchemaV4` aqui com a mudança, aponte os typealiases para ele e
/// acrescente a etapa em `AppMigrationPlan`. Propriedades novas sempre com valor padrão.
public enum SchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [Manga.self, Chapter.self, HistoryEntry.self, MangaCategory.self, TrackRecord.self]
    }

    @Model
    public final class Manga {
        @Attribute(.unique) public var id: String // "\(sourceId):\(remoteUrl)"
        public var sourceId: String
        public var remoteUrl: String
        public var title: String
        public var author: String?
        public var artist: String?
        public var desc: String?
        public var genres: [String]
        public var status: Int // 0: Unknown, 1: Ongoing, 2: Completed, 3: Cancelled, 4: Hiatus
        public var coverUrl: String?
        public var isFavorite: Bool
        public var favoriteAt: Date?
        public var lastUpdated: Date?
        public var unreadCount: Int
        /// Todas as fontes/idiomas em que a obra unificada foi encontrada (JSON de `[WorkSourceRef]`).
        public var sourcesJSON: String?
        /// Último idioma de capítulos escolhido pelo usuário para esta obra.
        public var preferredLanguage: String?

        /// Categorias da biblioteca (`MangaCategory.id`). Vazio = categoria padrão.
        public var categoryIds: [String] = []
        /// Modo de leitura desta obra (`ReadingMode.rawValue`); nil = padrão global.
        public var readingMode: Int? = nil
        /// Orientação travada no leitor (`ReaderOrientation.rawValue`); nil = padrão global.
        public var orientation: Int? = nil
        /// Filtros, ordem e exibição da lista de capítulos (`ChapterListFlags`).
        public var chapterFlags: Int = 0
        /// Scanlators e fontes escondidos nesta obra.
        public var excludedScanlators: [String] = []
        /// Fonte preferida quando o mesmo capítulo existe em várias fontes.
        public var preferredSourceId: String? = nil
        /// Anotações do usuário (Markdown).
        public var notes: String = ""
        /// Capa escolhida pelo usuário (nome do arquivo em Application Support/Covers).
        public var customCoverPath: String? = nil
        public var lastReadAt: Date? = nil
        /// Data de upload do capítulo mais novo.
        public var latestUploadAt: Date? = nil
        /// Capítulos (sem repetição) no idioma da obra.
        public var chapterCount: Int = 0
        /// Previsão do próximo capítulo (intervalo mediano entre lançamentos).
        public var nextUpdateAt: Date? = nil

        @Relationship(deleteRule: .cascade, inverse: \Chapter.manga)
        public var chapters: [Chapter] = []

        public init(
            sourceId: String,
            remoteUrl: String,
            title: String,
            author: String? = nil,
            artist: String? = nil,
            desc: String? = nil,
            genres: [String] = [],
            status: Int = 0,
            coverUrl: String? = nil,
            isFavorite: Bool = false
        ) {
            self.id = "\(sourceId):\(remoteUrl)"
            self.sourceId = sourceId
            self.remoteUrl = remoteUrl
            self.title = title
            self.author = author
            self.artist = artist
            self.desc = desc
            self.genres = genres
            self.status = status
            self.coverUrl = coverUrl
            self.isFavorite = isFavorite
            self.favoriteAt = isFavorite ? Date() : nil
            self.lastUpdated = Date()
            self.unreadCount = 0
        }
    }

    @Model
    public final class Chapter {
        @Attribute(.unique) public var id: String // "\(mangaId):\(sourceId):\(remoteUrl)"
        public var mangaId: String
        public var remoteUrl: String
        public var name: String
        public var scanlator: String?
        public var chapterNumber: Double
        public var uploadDate: Date?
        public var orderIndex: Int
        /// Fonte e idioma do capítulo (obras unificadas misturam várias fontes).
        public var sourceId: String?
        public var language: String?
        /// Endereço da obra na fonte do capítulo (algumas fontes precisam dele para as páginas).
        public var mangaRemoteUrl: String? = nil

        public var isRead: Bool
        public var isBookmarked: Bool
        /// Última página aberta, contando de 1. 0 = capítulo nunca aberto.
        public var lastPageRead: Int
        public var totalPages: Int
        public var lastReadDate: Date?
        /// Quando o capítulo apareceu pela primeira vez na lista salva da obra.
        /// Capítulos com `dateFetch` depois de `Manga.favoriteAt` são novidades.
        public var dateFetch: Date? = nil

        public var manga: Manga?

        public init(
            mangaId: String,
            remoteUrl: String,
            name: String,
            chapterNumber: Double,
            orderIndex: Int,
            scanlator: String? = nil,
            uploadDate: Date? = nil,
            sourceId: String? = nil,
            language: String? = nil,
            mangaRemoteUrl: String? = nil
        ) {
            self.id = Chapter.storageId(mangaId: mangaId, sourceId: sourceId, remoteUrl: remoteUrl)
            self.mangaId = mangaId
            self.remoteUrl = remoteUrl
            self.name = name
            self.chapterNumber = chapterNumber
            self.orderIndex = orderIndex
            self.scanlator = scanlator
            self.uploadDate = uploadDate
            self.sourceId = sourceId
            self.language = language
            self.mangaRemoteUrl = mangaRemoteUrl
            self.isRead = false
            self.isBookmarked = false
            self.lastPageRead = 0
            self.totalPages = 0
        }

        /// Identificador estável do capítulo dentro de uma obra unificada.
        public static func storageId(mangaId: String, sourceId: String?, remoteUrl: String) -> String {
            guard let sourceId, !sourceId.isEmpty else { return "\(mangaId):\(remoteUrl)" }
            return "\(mangaId):\(sourceId):\(remoteUrl)"
        }
    }

    @Model
    public final class HistoryEntry {
        @Attribute(.unique) public var id: String // "\(chapterId)"
        public var mangaId: String
        public var chapterId: String
        public var mangaTitle: String
        public var chapterName: String
        public var coverUrl: String?
        public var readAt: Date
        /// Página onde a leitura parou, contando de 1.
        public var pageNumber: Int
        public var totalPages: Int
        /// Dados para reabrir o capítulo direto do histórico.
        public var sourceId: String? = nil
        public var chapterRemoteUrl: String? = nil
        public var mangaRemoteUrl: String? = nil
        /// Tempo de leitura acumulado neste capítulo, em segundos.
        public var timeRead: Double = 0

        public init(
            mangaId: String,
            chapterId: String,
            mangaTitle: String,
            chapterName: String,
            coverUrl: String?,
            readAt: Date = Date(),
            pageNumber: Int = 0,
            totalPages: Int = 0,
            sourceId: String? = nil,
            chapterRemoteUrl: String? = nil,
            mangaRemoteUrl: String? = nil
        ) {
            self.id = chapterId
            self.mangaId = mangaId
            self.chapterId = chapterId
            self.mangaTitle = mangaTitle
            self.chapterName = chapterName
            self.coverUrl = coverUrl
            self.readAt = readAt
            self.pageNumber = pageNumber
            self.totalPages = totalPages
            self.sourceId = sourceId
            self.chapterRemoteUrl = chapterRemoteUrl
            self.mangaRemoteUrl = mangaRemoteUrl
        }
    }

    /// Categoria da biblioteca (aba).
    @Model
    public final class MangaCategory {
        @Attribute(.unique) public var id: String
        public var name: String
        public var order: Int
        /// Reservado para filtros/ordem por categoria.
        public var flags: Int = 0

        public init(id: String = UUID().uuidString, name: String, order: Int) {
            self.id = id
            self.name = name
            self.order = order
        }
    }

    /// Vínculo de uma obra com um serviço de rastreamento (AniList, MyAnimeList...).
    @Model
    public final class TrackRecord {
        @Attribute(.unique) public var id: String // "\(mangaId)|\(trackerId)"
        public var mangaId: String
        public var trackerId: String
        public var remoteId: String
        public var title: String
        /// `TrackStatus.rawValue`.
        public var status: Int
        public var score: Double
        public var lastChapterRead: Double
        public var totalChapters: Int
        public var startDate: Date?
        public var finishDate: Date?
        public var remoteUrl: String?
        public var isPrivate: Bool = false

        public init(mangaId: String, trackerId: String, remoteId: String, title: String) {
            self.id = "\(mangaId)|\(trackerId)"
            self.mangaId = mangaId
            self.trackerId = trackerId
            self.remoteId = remoteId
            self.title = title
            self.status = 1
            self.score = 0
            self.lastChapterRead = 0
            self.totalChapters = 0
        }
    }
}

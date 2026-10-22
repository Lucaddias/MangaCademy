import Foundation
import SwiftData

/// Banco como era antes do versionamento (até out/2026). **Congelado**: não edite.
/// Serve só para o SwiftData reconhecer bancos antigos e migrá-los para a versão atual.
public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [Manga.self, Chapter.self, HistoryEntry.self]
    }

    @Model
    public final class Manga {
        @Attribute(.unique) public var id: String
        public var sourceId: String
        public var remoteUrl: String
        public var title: String
        public var author: String?
        public var artist: String?
        public var desc: String?
        public var genres: [String]
        public var status: Int
        public var coverUrl: String?
        public var isFavorite: Bool
        public var favoriteAt: Date?
        public var lastUpdated: Date?
        public var unreadCount: Int
        public var sourcesJSON: String?
        public var preferredLanguage: String?

        @Relationship(deleteRule: .cascade, inverse: \Chapter.manga)
        public var chapters: [Chapter] = []

        public init(sourceId: String, remoteUrl: String, title: String) {
            self.id = "\(sourceId):\(remoteUrl)"
            self.sourceId = sourceId
            self.remoteUrl = remoteUrl
            self.title = title
            self.genres = []
            self.status = 0
            self.isFavorite = false
            self.unreadCount = 0
        }
    }

    @Model
    public final class Chapter {
        @Attribute(.unique) public var id: String
        public var mangaId: String
        public var remoteUrl: String
        public var name: String
        public var scanlator: String?
        public var chapterNumber: Double
        public var uploadDate: Date?
        public var orderIndex: Int
        public var sourceId: String?
        public var language: String?

        public var isRead: Bool
        public var isBookmarked: Bool
        public var lastPageRead: Int
        public var totalPages: Int
        public var lastReadDate: Date?

        public var manga: Manga?

        public init(id: String, mangaId: String, remoteUrl: String, name: String, chapterNumber: Double) {
            self.id = id
            self.mangaId = mangaId
            self.remoteUrl = remoteUrl
            self.name = name
            self.chapterNumber = chapterNumber
            self.orderIndex = 0
            self.isRead = false
            self.isBookmarked = false
            self.lastPageRead = 0
            self.totalPages = 0
        }
    }

    @Model
    public final class HistoryEntry {
        @Attribute(.unique) public var id: String
        public var mangaId: String
        public var chapterId: String
        public var mangaTitle: String
        public var chapterName: String
        public var coverUrl: String?
        public var readAt: Date
        public var pageNumber: Int
        public var totalPages: Int

        public init(mangaId: String, chapterId: String, mangaTitle: String, chapterName: String) {
            self.id = chapterId
            self.mangaId = mangaId
            self.chapterId = chapterId
            self.mangaTitle = mangaTitle
            self.chapterName = chapterName
            self.readAt = Date()
            self.pageNumber = 0
            self.totalPages = 0
        }
    }
}

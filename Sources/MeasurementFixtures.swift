import Foundation
import SwiftData
import UIKit

/// Local fixtures activated only by the isolated UI-test bundle's launch argument.
enum MeasurementFixtureSupport {
    static let launchArgument = "--measurement-ui-fixtures"
    static let emptyLaunchArgument = "--measurement-ui-empty"
    static let sourceId = "measurement-fixture"

    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(launchArgument) || arguments.contains(emptyLaunchArgument)
    }

    private static var shouldSeedData: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    private static var assetDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeasurementFixtures", isDirectory: true)
    }

    static var coverURL: String {
        assetDirectory.appendingPathComponent("cover.png").absoluteString
    }

    static func title(for remoteUrl: String) -> String {
        switch remoteUrl {
        case "library-600": return "Fixture Library 600"
        case "reader-paged": return "Fixture Paged Reader"
        case "reader-webtoon": return "Fixture Webtoon Reader"
        case "download-one": return "Fixture Download"
        default:
            let suffix = remoteUrl.replacingOccurrences(of: "catalog-", with: "")
            if let index = Int(suffix) { return String(format: "Fixture Catalog %03d", index) }
            return "Fixture Work"
        }
    }

    static func pageURL(for mangaRemoteUrl: String, page: Int) -> String {
        let prefix = mangaRemoteUrl == "reader-webtoon" ? "webtoon" : "page"
        return assetDirectory.appendingPathComponent("\(prefix)-\(page).png").absoluteString
    }

    @MainActor
    static func seedIfRequested(container: ModelContainer) {
        guard isEnabled else { return }
        do {
            SourceManager.shared.rebuild()

            UserDefaults.standard.set(true, forKey: "onboarding_done")
            UserDefaults.standard.set(LanguageFilter.portuguese.rawValue, forKey: Preferences.Key.languageFilter)
            UserDefaults.standard.set(false, forKey: Preferences.Key.showNsfwSources)
            UserDefaults.standard.set(false, forKey: Preferences.Key.blockAdultTags)
            UserDefaults.standard.set(sourceId, forKey: Preferences.Key.catalogSource)
            SourceSettings.shared.disabledSources = []
            SourceSettings.shared.disabledLanguages = []
            SourceSettings.shared.pinnedSources = [sourceId]
            SourceSettings.shared.lastUsedSource = sourceId
            ReaderSettings.shared.defaultMode = .pagedLTR
            UpdateSettings.shared.intervalHours = 0
            UpdateSettings.shared.notify = false
            DownloadSettings.shared.onlyOnWifi = false
            DownloadSettings.shared.parallelSources = 1
            DownloadSettings.shared.parallelPages = 1
            DownloadSettings.shared.downloadNewChapters = false
            DownloadManager.shared.cancelAll()

            let context = container.mainContext
            let existing = (try? context.fetch(FetchDescriptor<Manga>())) ?? []
            for manga in existing where manga.id.hasPrefix("\(sourceId):") {
                DownloadStore.shared.deleteManga(mangaId: manga.id)
                context.delete(manga)
            }
            try context.save()
            guard shouldSeedData else { return }
            try prepareAssets()

            let favoriteDate = Date().addingTimeInterval(-86_400)
            let library = Manga(
                sourceId: sourceId,
                remoteUrl: "library-600",
                title: title(for: "library-600"),
                isFavorite: true
            )
            library.favoriteAt = favoriteDate
            library.preferredLanguage = "pt-BR"
            library.unreadCount = 300
            context.insert(library)

            for number in 1...600 {
                let chapter = Chapter(
                    mangaId: library.id,
                    remoteUrl: "library-600/chapter/\(number)",
                    name: "Capítulo \(number)",
                    chapterNumber: Double(number),
                    orderIndex: 600 - number,
                    uploadDate: favoriteDate.addingTimeInterval(Double(number)),
                    sourceId: sourceId,
                    language: "pt-BR",
                    mangaRemoteUrl: library.remoteUrl
                )
                chapter.isRead = number.isMultiple(of: 2)
                chapter.dateFetch = favoriteDate
                chapter.manga = library
                context.insert(chapter)
            }

            let paged = makeReaderManga(remoteUrl: "reader-paged", mode: .pagedLTR, context: context, favoriteDate: favoriteDate)
            _ = makeReaderManga(remoteUrl: "reader-webtoon", mode: .webtoon, context: context, favoriteDate: favoriteDate)
            _ = makeReaderManga(remoteUrl: "download-one", mode: .pagedLTR, context: context, favoriteDate: favoriteDate, chapterCount: 1)
            try context.save()
            try seedDownloadedChapter(manga: library, chapterNumber: 600)
            try seedDownloadedChapter(manga: paged, chapterNumber: 3)
        } catch {
            print("[MeasurementFixtures] Seed failed: \(error)")
        }
    }

    @MainActor
    private static func makeReaderManga(
        remoteUrl: String,
        mode: ReadingMode,
        context: ModelContext,
        favoriteDate: Date,
        chapterCount: Int = 3
    ) -> Manga {
        let manga = Manga(sourceId: sourceId, remoteUrl: remoteUrl, title: title(for: remoteUrl), isFavorite: true)
        manga.favoriteAt = favoriteDate
        manga.preferredLanguage = "pt-BR"
        manga.readingMode = mode.rawValue
        manga.unreadCount = chapterCount
        context.insert(manga)

        for number in 1...chapterCount {
            let chapter = Chapter(
                mangaId: manga.id,
                remoteUrl: "\(remoteUrl)/chapter/\(number)",
                name: "Capítulo \(number)",
                chapterNumber: Double(number),
                orderIndex: chapterCount - number,
                uploadDate: favoriteDate.addingTimeInterval(Double(number)),
                sourceId: sourceId,
                language: "pt-BR",
                mangaRemoteUrl: manga.remoteUrl
            )
            chapter.dateFetch = favoriteDate
            chapter.manga = manga
            context.insert(chapter)
        }
        return manga
    }

    @MainActor
    private static func seedDownloadedChapter(manga: Manga, chapterNumber: Int) throws {
        let chapter = SourceChapterItem(
            remoteUrl: "\(manga.remoteUrl)/chapter/\(chapterNumber)",
            name: "Capítulo \(chapterNumber)",
            chapterNumber: Double(chapterNumber),
            orderIndex: 0,
            language: "pt-BR",
            sourceId: sourceId,
            mangaRemoteUrl: manga.remoteUrl
        )
        let store = DownloadStore.shared
        let directory = store.chapterDirectory(for: chapter, mangaId: manga.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for page in 1...4 {
            let data = try Data(contentsOf: URL(string: pageURL(for: manga.remoteUrl, page: page))!)
            let fileName = String(format: "%03d.png", page)
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        }
        try store.finish(chapter: chapter, mangaId: manga.id, files: (1...4).map { String(format: "%03d.png", $0) })
    }

    @MainActor
    private static func prepareAssets() throws {
        try? FileManager.default.removeItem(at: assetDirectory)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        try render(size: CGSize(width: 600, height: 900), label: "Fixture cover", color: 0)
            .write(to: assetDirectory.appendingPathComponent("cover.png"), options: .atomic)
        for page in 1...4 {
            try render(size: CGSize(width: 900, height: 1_400), label: "Paged \(page)", color: page)
                .write(to: assetDirectory.appendingPathComponent("page-\(page).png"), options: .atomic)
        }
        for page in 1...8 {
            try render(size: CGSize(width: 900, height: 2_000), label: "Webtoon \(page)", color: page + 4)
                .write(to: assetDirectory.appendingPathComponent("webtoon-\(page).png"), options: .atomic)
        }
    }

    @MainActor
    private static func render(size: CGSize, label: String, color: Int) -> Data {
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: CGFloat(color % 10) / 10, saturation: 0.65, brightness: 0.72, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 42, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            (label as NSString).draw(
                in: CGRect(x: 36, y: 36, width: size.width - 72, height: 64),
                withAttributes: attributes
            )
        }
        return image.pngData() ?? Data()
    }
}

final class MeasurementFixtureSource: MangaSource, @unchecked Sendable {
    let id = MeasurementFixtureSupport.sourceId
    let name = "Fixture Local"
    let language = "pt-BR"
    let baseUrl = ""
    private let pageSize = 24

    func fetchPopular(page: Int) async throws -> SourceMangaPage {
        catalogPage(page: page, items: catalogItems)
    }

    func fetchLatest(page: Int) async throws -> SourceMangaPage {
        catalogPage(page: page, items: Array(catalogItems.reversed()))
    }

    func search(query: String, page: Int) async throws -> SourceMangaPage {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = term.isEmpty ? catalogItems : catalogItems.filter { $0.title.lowercased().contains(term) }
        return catalogPage(page: page, items: matches)
    }

    func fetchDetails(remoteUrl: String) async throws -> (SourceMangaDetail, [SourceChapterItem]) {
        let title = MeasurementFixtureSupport.title(for: remoteUrl)
        let count = remoteUrl == "library-600" ? 601 : (remoteUrl == "download-one" ? 1 : 3)
        let chapters = (1...count).reversed().map { number in
            SourceChapterItem(
                remoteUrl: "\(remoteUrl)/chapter/\(number)",
                name: "Capítulo \(number)",
                chapterNumber: Double(number),
                orderIndex: count - number,
                uploadDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(number)),
                language: "pt-BR",
                sourceId: id,
                mangaRemoteUrl: remoteUrl
            )
        }
        return (
            SourceMangaDetail(
                remoteUrl: remoteUrl,
                title: title,
                author: "Fixture Author",
                description: "Fixture local para testes de UI; nenhuma fonte externa é chamada.",
                genres: ["Action", "Adventure"],
                status: 1,
                coverUrl: MeasurementFixtureSupport.coverURL,
                altTitles: [title + " Alt"]
            ),
            chapters
        )
    }

    func fetchPages(chapterRemoteUrl: String, mangaRemoteUrl: String) async throws -> [SourcePageItem] {
        let count = mangaRemoteUrl == "reader-webtoon" ? 8 : 4
        return (1...count).map { page in
            SourcePageItem(
                pageNumber: page,
                imageUrl: MeasurementFixtureSupport.pageURL(for: mangaRemoteUrl, page: page),
                width: 900,
                height: mangaRemoteUrl == "reader-webtoon" ? 2_000 : 1_400
            )
        }
    }

    private var catalogItems: [SourceMangaItem] {
        (0..<120).map { index in
            let remoteUrl = "catalog-\(String(format: "%03d", index))"
            let title = MeasurementFixtureSupport.title(for: remoteUrl)
            return SourceMangaItem(
                sourceId: id,
                remoteUrl: remoteUrl,
                title: title,
                coverUrl: MeasurementFixtureSupport.coverURL,
                status: "ongoing",
                languages: ["pt-BR", "en"],
                altTitles: [title + " Alt"],
                genres: ["Action"],
                hasFullMetadata: true,
                latestChapterName: "Capítulo \(index + 1)",
                latestChapterDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
    }

    private func catalogPage(page: Int, items: [SourceMangaItem]) -> SourceMangaPage {
        let start = max(page - 1, 0) * pageSize
        let slice = Array(items.dropFirst(start).prefix(pageSize))
        return SourceMangaPage(items: slice, hasNextPage: start + slice.count < items.count)
    }
}

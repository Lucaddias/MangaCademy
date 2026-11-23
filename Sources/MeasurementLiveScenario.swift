import Foundation
import SwiftData

/// Real-provider data for the isolated device performance harness.
/// The normal MihonReader bundle ignores every measurement launch argument.
enum MeasurementLiveScenarioSupport {
    private static let slugPrefix = "--measurement-live-manga-slug="
    private static let automaticArgument = "--measurement-live-nexustoons"
    private static let cacheColdArgument = "--measurement-cache-cold"
    private static let isolatedBundleSuffix = ".PerformanceHarness"
    private static let providerID = "nexustoons"
    private static let selectedSlugKey = "measurement_live_nexustoons_slug"

    static var requestedMangaRemoteURL: String? {
        guard isIsolatedHarness else { return nil }
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(slugPrefix) }) else {
            return nil
        }
        let slug = String(argument.dropFirst(slugPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return slug.isEmpty ? nil : slug
    }

    static var isEnabled: Bool {
        guard isIsolatedHarness else { return false }
        return requestedMangaRemoteURL != nil || ProcessInfo.processInfo.arguments.contains(automaticArgument)
    }

    private static var isIsolatedHarness: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(isolatedBundleSuffix) == true
    }

    static func prepareIfRequested() {
        guard isEnabled else { return }

        UserDefaults.standard.set(true, forKey: "onboarding_done")
        UserDefaults.standard.set(LanguageFilter.portuguese.rawValue, forKey: Preferences.Key.languageFilter)
        UserDefaults.standard.set(false, forKey: Preferences.Key.showNsfwSources)
        UserDefaults.standard.set(true, forKey: Preferences.Key.blockAdultTags)
        UserDefaults.standard.set(providerID, forKey: Preferences.Key.catalogSource)
        UserDefaults.standard.set(true, forKey: Preferences.Key.incognito)
        UserDefaults.standard.set(true, forKey: "library_continue_button")
        UserDefaults.standard.set(0, forKey: "download_ahead")
        UserDefaults.standard.set(false, forKey: "download_new_chapters")
        UserDefaults.standard.set(true, forKey: "download_paused")

        SourceSettings.shared.disabledSources = []
        SourceSettings.shared.disabledLanguages = []
        SourceSettings.shared.pinnedSources = [providerID]
        SourceSettings.shared.lastUsedSource = providerID

        if ProcessInfo.processInfo.arguments.contains(cacheColdArgument) {
            ImageCache.shared.clearCache()
            MetadataCache.shared.clear()
            URLCache.shared.removeAllCachedResponses()
            print("[Measurement] cache_mode=cold; image, chapter-page, metadata and URL caches cleared")
        } else {
            print("[Measurement] cache_mode=retained; persistent caches preserved")
        }
    }

    @MainActor
    static func seedIfNeeded(container: ModelContainer, remoteURL: String?) async {
        let context = container.mainContext

        do {
            guard let source = SourceManager.shared.getSource(id: providerID) else {
                print("[Measurement] seed_failed=provider-unavailable; provider=\(providerID)")
                return
            }

            var resolvedRemoteURL = remoteURL ?? UserDefaults.standard.string(forKey: selectedSlugKey)
            if resolvedRemoteURL == nil {
                let catalog = try await source.fetchPopular(page: 1)
                guard let candidate = catalog.items
                    .filter({
                        ($0.chapterCount ?? 0) >= 1_000 &&
                        !$0.isSuggestive &&
                        !ContentFilter.isAdult(genres: $0.genres)
                    })
                    .max(by: { ($0.chapterCount ?? 0) < ($1.chapterCount ?? 0) }) else {
                    print("[Measurement] seed_failed=no-safe-high-chapter-work")
                    return
                }
                resolvedRemoteURL = candidate.remoteUrl
                UserDefaults.standard.set(candidate.remoteUrl, forKey: selectedSlugKey)
                print("[Measurement] provider=\(providerID); selected_real_chapters=\(candidate.chapterCount ?? 0)")
            }

            guard let resolvedRemoteURL else { return }
            let mangaID = "\(providerID):\(resolvedRemoteURL)"
            let mangaDescriptor = FetchDescriptor<Manga>(predicate: #Predicate { $0.id == mangaID })

            let isolatedWorks = try context.fetch(FetchDescriptor<Manga>())
            for work in isolatedWorks where
                work.sourceId == MeasurementFixtureSupport.sourceId ||
                (work.sourceId == providerID && work.remoteUrl != resolvedRemoteURL) {
                DownloadStore.shared.deleteManga(mangaId: work.id)
                context.delete(work)
            }
            try context.save()

            if let existing = try context.fetch(mangaDescriptor).first {
                DownloadStore.shared.deleteManga(mangaId: existing.id)
                if existing.chapterCount > 0 {
                    print("[Measurement] provider=\(providerID); stored_chapters=\(existing.chapterCount); source=local-database")
                    return
                }
                context.delete(existing)
                try context.save()
            }

            let (detail, sourceChapters) = try await source.fetchDetails(remoteUrl: resolvedRemoteURL)
            guard sourceChapters.count >= 1_000 else {
                print("[Measurement] seed_failed=insufficient-real-chapters; count=\(sourceChapters.count)")
                return
            }
            guard !ContentFilter.isAdult(genres: detail.genres) else {
                print("[Measurement] seed_failed=adult-work-rejected")
                return
            }

            let manga = Manga(
                sourceId: providerID,
                remoteUrl: resolvedRemoteURL,
                title: detail.title,
                author: detail.author,
                artist: detail.artist,
                desc: detail.description,
                genres: detail.genres,
                status: detail.status,
                coverUrl: detail.coverUrl,
                isFavorite: true
            )
            manga.favoriteAt = Date()
            manga.preferredLanguage = "pt-BR"
            manga.chapterCount = sourceChapters.count
            manga.unreadCount = sourceChapters.count
            manga.readingMode = ReadingMode.pagedLTR.rawValue
            context.insert(manga)

            let fetchedAt = Date()
            for item in sourceChapters {
                let chapter = Chapter(
                    mangaId: manga.id,
                    remoteUrl: item.remoteUrl,
                    name: item.name,
                    chapterNumber: item.chapterNumber,
                    orderIndex: item.orderIndex,
                    scanlator: item.scanlator,
                    uploadDate: item.uploadDate,
                    sourceId: item.sourceId,
                    language: item.language,
                    mangaRemoteUrl: item.mangaRemoteUrl
                )
                chapter.dateFetch = fetchedAt
                chapter.manga = manga
                context.insert(chapter)
            }

            try context.save()
            print("[Measurement] provider=\(providerID); real_chapters_saved=\(sourceChapters.count)")
        } catch {
            print("[Measurement] seed_failed=\(error.localizedDescription)")
        }
    }
}

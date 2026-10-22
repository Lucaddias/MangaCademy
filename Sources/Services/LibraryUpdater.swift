import Foundation
import SwiftData
import BackgroundTasks
import UserNotifications

/// Restrições e agenda da atualização da biblioteca.
@MainActor
@Observable
final class UpdateSettings {
    static let shared = UpdateSettings()

    private let defaults: UserDefaults

    /// Atualização automática a cada N horas (0 = desligada).
    var intervalHours: Int { didSet { defaults.set(intervalHours, forKey: "update_interval_hours"); BackgroundTasks.scheduleLibraryUpdate() } }
    var onlyOnWifi: Bool { didSet { defaults.set(onlyOnWifi, forKey: "update_only_wifi") } }
    var skipCompleted: Bool { didSet { defaults.set(skipCompleted, forKey: "update_skip_completed") } }
    var skipNotStarted: Bool { didSet { defaults.set(skipNotStarted, forKey: "update_skip_not_started") } }
    var skipWithUnread: Bool { didSet { defaults.set(skipWithUnread, forKey: "update_skip_unread") } }
    /// Pula obras cujo próximo capítulo só é esperado mais tarde (previsão de lançamento).
    var skipOutsidePrediction: Bool { didSet { defaults.set(skipOutsidePrediction, forKey: "update_skip_prediction") } }
    var refreshMetadata: Bool { didSet { defaults.set(refreshMetadata, forKey: "update_refresh_metadata") } }
    var notify: Bool { didSet { defaults.set(notify, forKey: "update_notify") } }
    /// Categorias atualizadas (vazio = todas) e categorias nunca atualizadas. "" = Padrão.
    var includedCategories: [String] { didSet { defaults.set(includedCategories, forKey: "update_included_categories") } }
    var excludedCategories: [String] { didSet { defaults.set(excludedCategories, forKey: "update_excluded_categories") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        intervalHours = defaults.object(forKey: "update_interval_hours") as? Int ?? 24
        onlyOnWifi = bool("update_only_wifi", true)
        skipCompleted = bool("update_skip_completed", true)
        skipNotStarted = bool("update_skip_not_started", false)
        skipWithUnread = bool("update_skip_unread", false)
        skipOutsidePrediction = bool("update_skip_prediction", false)
        refreshMetadata = bool("update_refresh_metadata", false)
        notify = bool("update_notify", true)
        includedCategories = defaults.stringArray(forKey: "update_included_categories") ?? []
        excludedCategories = defaults.stringArray(forKey: "update_excluded_categories") ?? []
    }
}

/// Obra que falhou na última atualização.
struct UpdateError: Codable, Identifiable, Hashable {
    let mangaId: String
    let title: String
    let message: String
    var id: String { mangaId }
}

/// Atualiza a biblioteca: consulta as fontes de cada obra e salva os capítulos novos
/// (equivalente ao `LibraryUpdateJob` do Mihon).
@MainActor
@Observable
final class LibraryUpdater {
    static let shared = LibraryUpdater()

    private(set) var isRunning = false
    private(set) var progress = 0
    private(set) var total = 0
    private(set) var errors: [UpdateError]
    private(set) var lastRun: Date?
    /// Capítulos novos encontrados na última atualização.
    private(set) var lastNewCount = 0

    private static let maxConcurrentWorks = 3
    private let defaults = UserDefaults.standard

    private init() {
        errors = (defaults.data(forKey: "library_update_errors")).flatMap { try? JSONDecoder().decode([UpdateError].self, from: $0) } ?? []
        lastRun = defaults.object(forKey: "library_update_last_run") as? Date
    }

    /// Obras que entram numa atualização, já com as restrições aplicadas.
    static func candidates(
        _ mangas: [Manga],
        categoryId: String?,
        knownCategories: Set<String>,
        settings: UpdateSettings,
        startedIds: Set<String>,
        now: Date = Date()
    ) -> [Manga] {
        mangas.filter { manga in
            let categories = Set(manga.categoryIds).intersection(knownCategories)
            let effective: Set<String> = categories.isEmpty ? [""] : categories
            if let categoryId {
                guard effective.contains(categoryId) else { return false }
            } else {
                if !settings.includedCategories.isEmpty && effective.isDisjoint(with: settings.includedCategories) { return false }
                if !effective.isDisjoint(with: settings.excludedCategories) { return false }
            }
            if settings.skipCompleted && manga.status == 2 { return false }
            if settings.skipNotStarted && !startedIds.contains(manga.id) { return false }
            if settings.skipWithUnread && manga.unreadCount > 0 { return false }
            // Previsão: só pula se o próximo capítulo é esperado daqui a mais de um dia.
            if settings.skipOutsidePrediction, let next = manga.nextUpdateAt, next > now.addingTimeInterval(86_400) { return false }
            return true
        }
    }

    /// Atualiza a biblioteca (ou uma categoria, ou obras específicas). Devolve quantos capítulos novos achou.
    @discardableResult
    func update(categoryId: String?, context: ModelContext, mangaIds: Set<String>? = nil, automatic: Bool = false) async -> Int {
        guard !isRunning else { return 0 }
        let settings = UpdateSettings.shared
        if automatic && settings.onlyOnWifi && !NetworkMonitor.shared.isOnWifi { return 0 }

        let favorites = (try? context.fetch(FetchDescriptor<Manga>(predicate: #Predicate { $0.isFavorite == true }))) ?? []
        let categories = Set(((try? context.fetch(FetchDescriptor<MangaCategory>())) ?? []).map(\.id))
        let started = Set(((try? context.fetch(FetchDescriptor<Chapter>(predicate: #Predicate { $0.isRead || $0.lastPageRead > 0 }))) ?? []).map(\.mangaId))
        var list: [Manga]
        if let mangaIds {
            list = favorites.filter { mangaIds.contains($0.id) }
        } else {
            list = Self.candidates(favorites, categoryId: categoryId, knownCategories: categories, settings: settings, startedIds: started)
        }
        // Como no Mihon: fontes com mais obras primeiro, para espalhar as consultas.
        var perSource: [String: Int] = [:]
        for manga in list { perSource[manga.sourceId, default: 0] += 1 }
        list.sort { (perSource[$0.sourceId] ?? 0, $1.title) > (perSource[$1.sourceId] ?? 0, $0.title) }

        isRunning = true
        progress = 0
        total = list.count
        if mangaIds == nil { errors = [] } else { errors.removeAll { mangaIds?.contains($0.mangaId) == true } }
        let now = Date()
        var newByTitle: [(String, Int)] = []
        var newChapters: [String: [SourceChapterItem]] = [:]

        await withTaskGroup(of: Void.self) { group in
            var pending = list.makeIterator()
            func next() -> Manga? { pending.next() }
            for _ in 0..<Self.maxConcurrentWorks {
                guard let manga = next() else { break }
                group.addTask { @MainActor in
                    if let result = await self.updateOne(manga, context: context, now: now, refreshMetadata: settings.refreshMetadata) {
                        newByTitle.append((manga.title, result.count))
                        newChapters[manga.id] = result
                    }
                }
            }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                if let manga = next() {
                    group.addTask { @MainActor in
                        if let result = await self.updateOne(manga, context: context, now: now, refreshMetadata: settings.refreshMetadata) {
                            newByTitle.append((manga.title, result.count))
                            newChapters[manga.id] = result
                        }
                    }
                }
            }
        }

        try? context.save()
        for manga in list {
            if let new = newChapters[manga.id] { AutoDownloader.downloadNewChapters(new, manga: manga) }
        }
        lastRun = now
        defaults.set(now, forKey: "library_update_last_run")
        defaults.set(try? JSONEncoder().encode(errors), forKey: "library_update_errors")
        let newCount = newByTitle.reduce(0) { $0 + $1.1 }
        lastNewCount = newCount
        isRunning = false

        if newCount > 0 {
            if settings.notify { UpdateNotifier.notify(newChapters: newCount, titles: newByTitle.map(\.0)) }
        }
        return newCount
    }

    /// Atualiza uma obra. Devolve os capítulos novos (vazio se nada mudou) ou nil se falhou.
    private func updateOne(_ manga: Manga, context: ModelContext, now: Date, refreshMetadata: Bool) async -> [SourceChapterItem]? {
        defer { progress += 1 }
        let loader = WorkLoader(work: UnifiedWork(libraryManga: manga), filter: Preferences.languageFilter, lookupOtherLanguages: false)
        await loader.load()
        let state = loader.state
        guard !state.chapters.isEmpty else {
            errors.append(UpdateError(mangaId: manga.id, title: manga.title, message: state.failures.first ?? "Nenhum capítulo encontrado"))
            return nil
        }
        let excluded = Set(manga.excludedScanlators)
        let visible = state.chapters.filter { !ScanlatorFilter.isExcluded($0, excluded: excluded) }
        let byLanguage = SourceAggregator.shared.chaptersByLanguage(visible, preferredSourceId: manga.preferredSourceId)
        ChapterStore.sync(byLanguage, manga: manga, context: context, now: now)

        if refreshMetadata, let detail = state.mergedDetail(filter: Preferences.languageFilter) {
            if let desc = detail.description, !desc.isEmpty { manga.desc = desc }
            if detail.status != 0 { manga.status = detail.status }
            if !detail.genres.isEmpty { manga.genres = detail.genres }
            if let cover = state.work.coverUrl ?? detail.coverUrl, manga.customCoverPath == nil { manga.coverUrl = cover }
        }
        let language = manga.preferredLanguage ?? byLanguage.keys.first
        let records = ChapterStore.records(mangaId: manga.id, context: context)
        let newIds = Set(records.filter { $0.dateFetch == now && ($0.language ?? "all") == (language ?? "all") }.map(\.id))
        return (byLanguage[language ?? "all"] ?? []).filter {
            newIds.contains(Chapter.storageId(mangaId: manga.id, sourceId: $0.sourceId, remoteUrl: $0.remoteUrl))
        }
    }
}

/// Avisos de capítulos novos.
enum UpdateNotifier {
    static let categoryId = "library-update"

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    static func notify(newChapters: Int, titles: [String]) {
        let content = UNMutableNotificationContent()
        let works = titles.count
        content.title = newChapters == 1 ? "1 capítulo novo" : "\(newChapters) capítulos novos"
        content.body = works == 1 ? titles[0] : "Em \(works) obras: " + titles.prefix(4).joined(separator: ", ") + (works > 4 ? "…" : "")
        content.sound = .default
        content.categoryIdentifier = categoryId
        let request = UNNotificationRequest(identifier: "library-update-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Tarefas em segundo plano. O iOS decide quando rodar: é "melhor esforço".
enum BackgroundTasks {
    static let libraryUpdateId = "com.lucadias.MihonReader.library-update"
    static let backupId = "com.lucadias.MihonReader.backup"

    @MainActor
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: libraryUpdateId, using: nil) { task in
            Task { @MainActor in handleLibraryUpdate(task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backupId, using: nil) { task in
            Task { @MainActor in handleBackup(task) }
        }
    }

    @MainActor
    static func scheduleBackup() {
        let hours = BackupSettings.shared.intervalHours
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backupId)
        guard hours > 0 else { return }
        let request = BGProcessingTaskRequest(identifier: backupId)
        request.earliestBeginDate = (BackupSettings.shared.lastAutomatic ?? Date()).addingTimeInterval(Double(hours) * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func handleBackup(_ task: BGTask) {
        guard let container = AppStore.container else { task.setTaskCompleted(success: false); return }
        let ok = (try? BackupManager.writeAutomaticBackup(context: ModelContext(container))) != nil
        scheduleBackup()
        task.setTaskCompleted(success: ok)
    }

    @MainActor
    static func scheduleLibraryUpdate() {
        let hours = UpdateSettings.shared.intervalHours
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: libraryUpdateId)
        guard hours > 0 else { return }
        let request = BGAppRefreshTaskRequest(identifier: libraryUpdateId)
        request.earliestBeginDate = Date().addingTimeInterval(Double(hours) * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func handleLibraryUpdate(_ task: BGTask) {
        scheduleLibraryUpdate()
        guard let container = AppStore.container else { task.setTaskCompleted(success: false); return }
        let work = Task { @MainActor in
            await LibraryUpdater.shared.update(categoryId: nil, context: ModelContext(container), automatic: true)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Se o iOS não rodou a atualização no prazo, roda ao abrir o app.
    @MainActor
    static func catchUpIfNeeded(context: ModelContext) {
        let hours = UpdateSettings.shared.intervalHours
        guard hours > 0 else { return }
        let last = LibraryUpdater.shared.lastRun ?? .distantPast
        if Date().timeIntervalSince(last) > Double(hours) * 3600 {
            Task { await LibraryUpdater.shared.update(categoryId: nil, context: context, automatic: true) }
        }
        let backupHours = BackupSettings.shared.intervalHours
        if backupHours > 0, Date().timeIntervalSince(BackupSettings.shared.lastAutomatic ?? .distantPast) > Double(backupHours) * 3600 {
            try? BackupManager.writeAutomaticBackup(context: context)
            scheduleBackup()
        }
    }
}

/// Banco do app, para as tarefas em segundo plano.
enum AppStore {
    @MainActor static var container: ModelContainer?
}

import Foundation
import SwiftData
import UIKit

// MARK: - Ajustes

@MainActor
@Observable
final class DownloadSettings {
    static let shared = DownloadSettings()

    private let defaults: UserDefaults

    var onlyOnWifi: Bool { didSet { defaults.set(onlyOnWifi, forKey: "download_only_wifi") } }
    /// Fontes baixando ao mesmo tempo (uma obra por fonte de cada vez, como no Mihon).
    var parallelSources: Int { didSet { defaults.set(parallelSources, forKey: "download_parallel_sources") } }
    /// Páginas baixando ao mesmo tempo em cada capítulo.
    var parallelPages: Int { didSet { defaults.set(parallelPages, forKey: "download_parallel_pages") } }
    var deleteAfterRead: Bool { didSet { defaults.set(deleteAfterRead, forKey: "download_delete_after_read") } }
    var keepBookmarked: Bool { didSet { defaults.set(keepBookmarked, forKey: "download_keep_bookmarked") } }
    var deleteOnRemoveFromLibrary: Bool { didSet { defaults.set(deleteOnRemoveFromLibrary, forKey: "download_delete_on_remove") } }
    /// Baixa os capítulos novos encontrados pela atualização da biblioteca.
    var downloadNewChapters: Bool { didSet { defaults.set(downloadNewChapters, forKey: "download_new_chapters") } }
    /// Categorias em que baixar capítulos novos (vazio = todas).
    var newChapterCategories: Set<String> { didSet { defaults.set(newChapterCategories.sorted(), forKey: "download_new_categories") } }
    /// Ao ler um capítulo baixado, baixa os N seguintes (0 = desligado).
    var downloadAhead: Int { didSet { defaults.set(downloadAhead, forKey: "download_ahead") } }
    /// Modo "somente baixados": biblioteca e novidades mostram só o que está offline.
    var downloadedOnly: Bool { didSet { defaults.set(downloadedOnly, forKey: "download_only_mode") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        onlyOnWifi = bool("download_only_wifi", false)
        parallelSources = int("download_parallel_sources", 3)
        parallelPages = int("download_parallel_pages", 5)
        deleteAfterRead = bool("download_delete_after_read", false)
        keepBookmarked = bool("download_keep_bookmarked", true)
        deleteOnRemoveFromLibrary = bool("download_delete_on_remove", false)
        downloadNewChapters = bool("download_new_chapters", false)
        newChapterCategories = Set(defaults.stringArray(forKey: "download_new_categories") ?? [])
        downloadAhead = int("download_ahead", 0)
        downloadedOnly = bool("download_only_mode", false)
    }
}

// MARK: - Fila

/// Um capítulo na fila. Guarda o necessário para baixar sem abrir a obra.
struct DownloadTask: Codable, Identifiable, Hashable {
    enum State: String, Codable { case queued, downloading, failed }

    var id: String
    var mangaId: String
    var mangaTitle: String
    var remoteUrl: String
    var name: String
    var chapterNumber: Double
    var orderIndex: Int
    var scanlator: String?
    var language: String?
    var sourceId: String
    var mangaRemoteUrl: String
    var state: State = .queued
    var downloadedPages = 0
    var totalPages = 0
    var error: String?

    init(chapter: SourceChapterItem, mangaId: String, mangaTitle: String) {
        id = Chapter.storageId(mangaId: mangaId, sourceId: chapter.sourceId, remoteUrl: chapter.remoteUrl)
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        remoteUrl = chapter.remoteUrl
        name = chapter.name
        chapterNumber = chapter.chapterNumber
        orderIndex = chapter.orderIndex
        scanlator = chapter.scanlator
        language = chapter.language
        sourceId = chapter.sourceId
        mangaRemoteUrl = chapter.mangaRemoteUrl
    }

    var chapter: SourceChapterItem {
        SourceChapterItem(
            remoteUrl: remoteUrl, name: name, chapterNumber: chapterNumber, orderIndex: orderIndex,
            scanlator: scanlator, language: language, sourceId: sourceId, mangaRemoteUrl: mangaRemoteUrl
        )
    }

    var fraction: Double { totalPages > 0 ? Double(downloadedPages) / Double(totalPages) : 0 }
}

/// Estado de download de um capítulo, para a linha do capítulo.
enum ChapterDownloadState: Equatable {
    case none, queued, downloading(Double), failed, downloaded
}

/// Baixa capítulos para leitura offline: fila persistida, pausar/retomar/cancelar/reordenar,
/// limite de fontes e de páginas em paralelo.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var queue: [DownloadTask] = []
    private(set) var isPaused: Bool
    /// Fila parada esperando Wi‑Fi.
    private(set) var waitingForWifi = false

    private let store: DownloadStore
    private let queueURL: URL
    private let settings: DownloadSettings
    private var workers: [String: Task<Void, Never>] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(store: DownloadStore = .shared, settings: DownloadSettings = .shared, queueURL: URL? = nil) {
        self.store = store
        self.settings = settings
        self.queueURL = queueURL ?? store.root.deletingLastPathComponent().appendingPathComponent("download_queue.json")
        isPaused = UserDefaults.standard.bool(forKey: "download_paused")
        if let data = try? Data(contentsOf: self.queueURL), let saved = try? JSONDecoder().decode([DownloadTask].self, from: data) {
            // Um download interrompido volta para a fila.
            queue = saved.map { var task = $0; if task.state == .downloading { task.state = .queued }; return task }
        }
    }

    var isRunning: Bool { !workers.isEmpty }
    var activeCount: Int { queue.filter { $0.state != .failed }.count }

    func state(of chapter: SourceChapterItem, mangaId: String) -> ChapterDownloadState {
        let id = Chapter.storageId(mangaId: mangaId, sourceId: chapter.sourceId, remoteUrl: chapter.remoteUrl)
        if let task = queue.first(where: { $0.id == id }) {
            switch task.state {
            case .queued: return .queued
            case .downloading: return .downloading(task.fraction)
            case .failed: return .failed
            }
        }
        return store.isDownloaded(chapter, mangaId: mangaId) ? .downloaded : .none
    }

    // MARK: Ações

    /// Põe capítulos na fila (pula os já baixados ou na fila). Devolve quantos entraram.
    @discardableResult
    func enqueue(_ chapters: [SourceChapterItem], mangaId: String, mangaTitle: String) -> Int {
        let known = Set(queue.map(\.id))
        // Ordem de leitura: do mais antigo para o mais novo.
        let new = chapters
            .sorted { $0.orderIndex > $1.orderIndex }
            .map { DownloadTask(chapter: $0, mangaId: mangaId, mangaTitle: mangaTitle) }
            .filter { !known.contains($0.id) && !store.isDownloaded($0.chapter, mangaId: mangaId) }
        guard !new.isEmpty else { return 0 }
        queue += new
        save()
        pump()
        return new.count
    }

    func cancel(_ id: String) {
        workers[id]?.cancel()
        workers[id] = nil
        if let task = queue.first(where: { $0.id == id }), task.state == .downloading {
            store.delete(task.chapter, mangaId: task.mangaId)
        }
        queue.removeAll { $0.id == id }
        save()
        pump()
    }

    func cancel(mangaId: String) {
        for task in queue where task.mangaId == mangaId { cancel(task.id) }
    }

    func cancelAll() {
        for id in Array(workers.keys) { cancel(id) }
        queue.removeAll()
        save()
        endBackgroundTaskIfIdle()
    }

    func pause() {
        isPaused = true
        UserDefaults.standard.set(true, forKey: "download_paused")
        for (id, worker) in workers {
            worker.cancel()
            if let index = queue.firstIndex(where: { $0.id == id }) { queue[index].state = .queued }
        }
        workers.removeAll()
        save()
        endBackgroundTaskIfIdle()
    }

    func resume() {
        isPaused = false
        UserDefaults.standard.set(false, forKey: "download_paused")
        pump()
    }

    func retryFailed() {
        for index in queue.indices where queue[index].state == .failed {
            queue[index].state = .queued
            queue[index].error = nil
        }
        save()
        pump()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Apaga capítulos baixados (e tira da fila).
    func delete(_ chapters: [SourceChapterItem], mangaId: String) {
        for chapter in chapters {
            let id = Chapter.storageId(mangaId: mangaId, sourceId: chapter.sourceId, remoteUrl: chapter.remoteUrl)
            if queue.contains(where: { $0.id == id }) { cancel(id) }
            store.delete(chapter, mangaId: mangaId)
        }
        NotificationCenter.default.post(name: .downloadsChanged, object: nil)
    }

    /// Retoma a fila (ao abrir o app ou ao voltar o Wi‑Fi).
    func pump() {
        guard !isPaused else { return }
        if settings.onlyOnWifi && !NetworkMonitor.shared.isOnWifi {
            waitingForWifi = queue.contains { $0.state == .queued }
            return
        }
        waitingForWifi = false
        let busySources = Set(queue.filter { workers[$0.id] != nil }.map(\.sourceId))
        var busy = busySources
        for task in queue where task.state == .queued {
            guard workers.count < max(settings.parallelSources, 1) else { break }
            guard !busy.contains(task.sourceId) else { continue }
            busy.insert(task.sourceId)
            start(task)
        }
        if workers.isEmpty { endBackgroundTaskIfIdle() } else { beginBackgroundTask() }
    }

    // MARK: Trabalho

    private func start(_ task: DownloadTask) {
        update(task.id) { $0.state = .downloading; $0.downloadedPages = 0; $0.error = nil }
        let id = task.id
        workers[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.download(task)
                guard !Task.isCancelled else { return }
                self.queue.removeAll { $0.id == id }
                NotificationCenter.default.post(name: .downloadsChanged, object: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.update(id) { $0.state = .failed; $0.error = error.localizedDescription }
            }
            self.workers[id] = nil
            self.save()
            self.pump()
        }
    }

    private func download(_ task: DownloadTask) async throws {
        guard let source = SourceManager.shared.getSource(id: task.sourceId) else { throw ChapterPageProvider.Failure.sourceUnavailable }
        let chapter = task.chapter
        let pages = try await source.fetchPages(chapterRemoteUrl: chapter.remoteUrl, mangaRemoteUrl: chapter.mangaRemoteUrl)
        guard !pages.isEmpty else { throw ChapterPageProvider.Failure.empty(source.name) }
        update(task.id) { $0.totalPages = pages.count }

        let directory = store.chapterDirectory(for: chapter, mangaId: task.mangaId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fallbackReferer = source.imageReferer
        let limit = max(settings.parallelPages, 1)
        var files = [String](repeating: "", count: pages.count)

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func addNext() {
                guard next < pages.count else { return }
                let index = next
                let page = pages[index]
                next += 1
                group.addTask {
                    let data = try await Self.fetchPage(page.imageUrl, referer: page.referer ?? fallbackReferer)
                    let name = String(format: "%03d.%@", index + 1, Self.fileExtension(for: data))
                    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                    return (index, name)
                }
            }
            for _ in 0..<min(limit, pages.count) { addNext() }
            while let (index, name) = try await group.next() {
                try Task.checkCancellation()
                files[index] = name
                update(task.id) { $0.downloadedPages += 1 }
                addNext()
            }
        }
        try Task.checkCancellation()
        try store.finish(chapter: chapter, mangaId: task.mangaId, files: files)
    }

    enum PageError: LocalizedError {
        case failed(Int)
        var errorDescription: String? {
            if case .failed(let page) = self { return "Não foi possível baixar a página \(page)" }
            return nil
        }
    }

    /// Bytes de uma página, com as mesmas regras de cabeçalho do leitor (sem guardar no cache).
    nonisolated static func fetchPage(_ urlString: String, referer: String?, attempts: Int = 3) async throws -> Data {
        guard let url = URL(string: urlString) else { throw HTTPError.badURL(urlString) }
        if url.isFileURL { return try Data(contentsOf: url) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        let isMangaDexHome = url.host?.hasSuffix("mangadex.network") == true
        request.setValue(isMangaDexHome ? "MangaCademy-iOS/1.0" : HTTPClient.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        var lastError: Error = HTTPError.badStatus(0)
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw HTTPError.badStatus(http.statusCode)
                }
                guard !data.isEmpty else { throw HTTPError.parse("a imagem") }
                return data
            } catch {
                lastError = error
                if error is CancellationError { throw error }
                try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
            }
        }
        throw lastError
    }

    nonisolated static func fileExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return "avif" }
        return "jpg"
    }

    private func update(_ id: String, _ change: (inout DownloadTask) -> Void) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        change(&queue[index])
    }

    private func save() {
        try? JSONEncoder().encode(queue).write(to: queueURL, options: .atomic)
    }

    // MARK: Segundo plano

    /// Pede ao iOS alguns minutos para terminar ao sair do app.
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "downloads") { [weak self] in
            Task { @MainActor in
                self?.pause()
                // Volta a baixar quando o app abrir de novo.
                self?.isPaused = false
                UserDefaults.standard.set(false, forKey: "download_paused")
            }
        }
    }

    private func endBackgroundTaskIfIdle() {
        guard workers.isEmpty, backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - Regras automáticas

@MainActor
enum AutoDownloader {
    /// Capítulos novos da atualização, se o ajuste e a categoria permitirem.
    static func downloadNewChapters(_ chapters: [SourceChapterItem], manga: Manga, settings: DownloadSettings = .shared) {
        guard settings.downloadNewChapters, !chapters.isEmpty else { return }
        let categories = settings.newChapterCategories
        guard categories.isEmpty || !categories.isDisjoint(with: manga.categoryIds) else { return }
        DownloadManager.shared.enqueue(chapters, mangaId: manga.id, mangaTitle: manga.title)
    }

    /// Ao abrir um capítulo baixado de uma obra da biblioteca, baixa os próximos não lidos.
    static func downloadAhead(from index: Int, in chapters: [SourceChapterItem], mangaId: String, mangaTitle: String, context: ModelContext) {
        let count = DownloadSettings.shared.downloadAhead
        guard count > 0, chapters.indices.contains(index),
              DownloadStore.shared.isDownloaded(chapters[index], mangaId: mangaId) else { return }
        let id = mangaId
        var descriptor = FetchDescriptor<Manga>(predicate: #Predicate { $0.id == id && $0.isFavorite == true })
        descriptor.fetchLimit = 1
        guard (try? context.fetch(descriptor).first) != nil else { return }
        let progress = ChapterProgress(records: ChapterStore.records(mangaId: mangaId, context: context), mangaId: mangaId)
        // A lista vai do mais novo (índice 0) para o mais antigo.
        let next = chapters[..<index].reversed().filter { !progress.isRead($0) }.prefix(count)
        DownloadManager.shared.enqueue(Array(next), mangaId: mangaId, mangaTitle: mangaTitle)
    }

    /// Ao sair do leitor: apaga os capítulos lidos nesta sessão (menos os marcados, se pedido).
    static func deleteRead(_ chapters: [SourceChapterItem], mangaId: String, context: ModelContext) {
        let settings = DownloadSettings.shared
        guard settings.deleteAfterRead, !chapters.isEmpty else { return }
        let progress = ChapterProgress(records: ChapterStore.records(mangaId: mangaId, context: context), mangaId: mangaId)
        let toDelete = chapters.filter { progress.isRead($0) && !(settings.keepBookmarked && progress.isBookmarked($0)) }
        guard !toDelete.isEmpty else { return }
        DownloadManager.shared.delete(toDelete, mangaId: mangaId)
    }
}

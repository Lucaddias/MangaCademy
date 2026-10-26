import SwiftUI
import SwiftData

/// Fila de downloads: progresso, pausar/retomar, reordenar e cancelar.
struct DownloadQueueView: View {
    @State private var manager = DownloadManager.shared

    var body: some View {
        List {
            if manager.waitingForWifi {
                Label("Aguardando Wi‑Fi (ajuste “Só no Wi‑Fi”).", systemImage: "wifi")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
            if manager.queue.isEmpty {
                ContentUnavailableView("Nenhum download", systemImage: "arrow.down.circle", description: Text("Baixe capítulos pelo detalhe da obra."))
            }
            ForEach(manager.queue) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.mangaTitle).font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    Text(task.name).font(.subheadline).lineLimit(1)
                    switch task.state {
                    case .queued:
                        Text(manager.isPaused ? "Pausado" : "Na fila").font(.caption2).foregroundStyle(Theme.inkTertiary)
                    case .downloading:
                        ProgressView(value: task.fraction) {
                            Text(task.totalPages > 0 ? "\(task.downloadedPages) de \(task.totalPages) páginas" : "Buscando páginas…")
                                .font(.caption2)
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    case .failed:
                        Text(task.error ?? "Falhou").font(.caption2).foregroundStyle(Theme.critical).lineLimit(2)
                    }
                }
                .swipeActions {
                    Button("Cancelar", role: .destructive) { manager.cancel(task.id) }
                }
            }
            .onMove { manager.move(fromOffsets: $0, toOffset: $1) }
        }
        .themedList()
        .navigationTitle("Fila de downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !manager.queue.isEmpty {
                    Button(manager.isPaused ? "Retomar" : "Pausar", systemImage: manager.isPaused ? "play.fill" : "pause.fill") {
                        if manager.isPaused { manager.resume() } else { manager.pause() }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if manager.queue.contains(where: { $0.state == .failed }) {
                        Button("Tentar falhas de novo", systemImage: "arrow.clockwise") { manager.retryFailed() }
                    }
                    Button("Cancelar todos", systemImage: "xmark.circle", role: .destructive) { manager.cancelAll() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(manager.queue.isEmpty)
            }
            ToolbarItem(placement: .topBarLeading) {
                if manager.queue.count > 1 { EditButton() }
            }
        }
    }
}

/// Ajustes de download (como em Mais › Ajustes › Downloads no Mihon).
struct DownloadSettingsView: View {
    @State private var settings = DownloadSettings.shared
    @Query(sort: \MangaCategory.order) private var categories: [MangaCategory]

    var body: some View {
        Form {
            Section {
                Toggle("Só no Wi‑Fi", isOn: $settings.onlyOnWifi)
                Stepper("Fontes ao mesmo tempo: \(settings.parallelSources)", value: $settings.parallelSources, in: 1...5)
                Stepper("Páginas ao mesmo tempo: \(settings.parallelPages)", value: $settings.parallelPages, in: 1...10)
            }

            Section {
                Toggle("Somente baixados", isOn: $settings.downloadedOnly)
            } footer: {
                Text("Biblioteca e Novidades mostram só obras e capítulos disponíveis offline.")
            }

            Section("Apagar") {
                Toggle("Depois de ler", isOn: $settings.deleteAfterRead)
                if settings.deleteAfterRead {
                    Toggle("Manter capítulos marcados", isOn: $settings.keepBookmarked)
                }
                Toggle("Ao remover da biblioteca", isOn: $settings.deleteOnRemoveFromLibrary)
            }

            Section {
                Toggle("Baixar capítulos novos", isOn: $settings.downloadNewChapters)
                if settings.downloadNewChapters && !categories.isEmpty {
                    ForEach(categories) { category in
                        Toggle(category.name, isOn: Binding(
                            get: { settings.newChapterCategories.contains(category.id) },
                            set: { on in
                                if on { settings.newChapterCategories.insert(category.id) } else { settings.newChapterCategories.remove(category.id) }
                            }
                        ))
                        .padding(.leading, 12)
                    }
                }
            } header: {
                Text("Automático")
            } footer: {
                Text(settings.downloadNewChapters && !categories.isEmpty
                     ? "Sem nenhuma categoria marcada, vale para a biblioteca toda."
                     : "Depois de cada atualização da biblioteca.")
            }

            Section {
                Picker("Baixar à frente", selection: $settings.downloadAhead) {
                    Text("Desligado").tag(0)
                    ForEach([2, 3, 5, 10], id: \.self) { Text("\($0) capítulos").tag($0) }
                }
            } footer: {
                Text("Ao ler um capítulo baixado de uma obra da biblioteca, baixa os próximos não lidos.")
            }

            Section {
                NavigationLink("Armazenamento") { StorageView() }
            }
        }
        .themedList()
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Espaço ocupado por obra, com opção de apagar; e o cache de imagens.
struct StorageView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var rows: [Row] = []
    @State private var total: Int64 = 0
    @State private var cacheSize: Int64 = 0
    @State private var confirmDeleteAll = false

    struct Row: Identifiable {
        let id: String
        let title: String
        let chapters: Int
        let size: Int64
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Downloads", value: format(total))
                LabeledContent("Cache de imagens", value: format(cacheSize))
                Button("Limpar cache de imagens") {
                    ImageCache.shared.clearCache()
                    refresh()
                }
            }
            if !rows.isEmpty {
                Section("Por obra") {
                    ForEach(rows) { row in
                        LabeledContent {
                            Text(format(row.size))
                        } label: {
                            Text(row.title).lineLimit(1)
                            Text("\(row.chapters) capítulos").font(.caption).foregroundStyle(Theme.inkSecondary)
                        }
                        .swipeActions {
                            Button("Apagar", role: .destructive) {
                                DownloadManager.shared.cancel(mangaId: row.id)
                                DownloadStore.shared.deleteManga(mangaId: row.id)
                                NotificationCenter.default.post(name: .downloadsChanged, object: nil)
                                refresh()
                            }
                        }
                    }
                }
                Section {
                    Button("Apagar todos os downloads", role: .destructive) { confirmDeleteAll = true }
                }
            }
        }
        .themedList()
        .navigationTitle("Armazenamento")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .confirmationDialog("Apagar todos os capítulos baixados?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Apagar tudo", role: .destructive) {
                DownloadManager.shared.cancelAll()
                DownloadStore.shared.deleteAll()
                NotificationCenter.default.post(name: .downloadsChanged, object: nil)
                refresh()
            }
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refresh() {
        let store = DownloadStore.shared
        // Obras salvas e obras lidas fora da biblioteca (histórico) podem ter downloads.
        var titles: [String: String] = [:]
        for entry in (try? modelContext.fetch(FetchDescriptor<HistoryEntry>())) ?? [] { titles[entry.mangaId] = entry.mangaTitle }
        for manga in (try? modelContext.fetch(FetchDescriptor<Manga>())) ?? [] { titles[manga.id] = manga.title }
        rows = titles.compactMap { id, title in
            let count = store.downloadedCount(mangaId: id)
            guard count > 0 else { return nil }
            return Row(id: id, title: title, chapters: count, size: store.size(mangaId: id))
        }
        .sorted { $0.size > $1.size }
        total = store.totalSize
        cacheSize = store.size(of: ImageDiskStore.shared.directory)
    }
}

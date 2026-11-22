import SwiftUI
import SwiftData

/// Capítulo a abrir direto da biblioteca ("continuar lendo").
struct LibraryReadingTarget: Identifiable {
    let mangaId: String
    let title: String
    let coverUrl: String?
    let chapters: [SourceChapterItem]
    let index: Int
    var id: String { "\(mangaId)#\(index)" }
}

public struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Manga> { $0.isFavorite == true }, sort: \.title)
    private var favoriteMangas: [Manga]
    @Query(sort: \MangaCategory.order) private var categories: [MangaCategory]
    /// Capítulos com algum estado (lido, marcado, começado): base dos filtros.
    @Query(filter: #Predicate<Chapter> { $0.isRead || $0.isBookmarked || $0.lastPageRead > 0 })
    private var activeChapters: [Chapter]
    @Query private var trackRecords: [TrackRecord]

    @AppStorage(Preferences.Key.languageFilter) private var filterRaw: String = Preferences.Default.languageFilter.rawValue
    @State private var settings = LibrarySettings.shared
    @State private var updater = LibraryUpdater.shared
    @State private var searchText = ""
    @State private var path: [UnifiedWork] = []
    @State private var downloadCounts: [String: Int] = [:]

    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var showSettings = false
    @State private var categoryTargets: [Manga] = []
    @State private var confirmRemove = false
    @State private var readingTarget: LibraryReadingTarget?

    private var filter: LanguageFilter { LanguageFilter(rawValue: filterRaw) ?? .portuguese }

    public init() {}

    // MARK: - Dados

    /// Abas: "Padrão" (se tiver obras ou não houver categorias) e as categorias criadas.
    private var tabs: [(id: String, name: String)] {
        let known = Set(categories.map(\.id))
        let hasDefault = categories.isEmpty || favoriteMangas.contains { Set($0.categoryIds).isDisjoint(with: known) }
        return (hasDefault ? [("", "Padrão")] : []) + categories.map { ($0.id, $0.name) }
    }

    private var activeTab: String {
        let ids = tabs.map(\.id)
        return ids.contains(settings.selectedCategory) ? settings.selectedCategory : (ids.first ?? "")
    }

    private func mangas(in tab: String) -> [Manga] {
        guard settings.showCategoryTabs, !categories.isEmpty else { return favoriteMangas }
        let known = Set(categories.map(\.id))
        if tab.isEmpty { return favoriteMangas.filter { Set($0.categoryIds).isDisjoint(with: known) } }
        return favoriteMangas.filter { $0.categoryIds.contains(tab) }
    }

    private var visibleMangas: [Manga] {
        let started = Set(activeChapters.filter { $0.isRead || $0.lastPageRead > 0 }.map(\.mangaId))
        let bookmarked = Set(activeChapters.filter(\.isBookmarked).map(\.mangaId))
        let tracked = Set(trackRecords.map(\.mangaId))
        let candidates = mangas(in: activeTab)
        let byId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let entries = candidates.map { manga -> LibraryEntry in
            let refs = UnifiedWork.refs(fromJSON: manga.sourcesJSON)
            return LibraryEntry(
                id: manga.id,
                title: manga.title,
                altTitles: refs.map(\.title),
                author: manga.author,
                artist: manga.artist,
                genres: manga.genres,
                sourceNames: refs.map(\.sourceName),
                sourceIds: refs.map(\.sourceId) + [manga.sourceId],
                status: manga.status,
                unreadCount: manga.unreadCount,
                chapterCount: manga.chapterCount,
                lastReadAt: manga.lastReadAt,
                lastUpdated: manga.lastUpdated,
                latestUploadAt: manga.latestUploadAt,
                favoriteAt: manga.favoriteAt,
                isStarted: started.contains(manga.id),
                hasBookmarks: bookmarked.contains(manga.id),
                isDownloaded: (downloadCounts[manga.id] ?? 0) > 0,
                isTracked: tracked.contains(manga.id)
            )
        }
        var filters = LibraryQuery.Filters()
        filters.unread = settings.filterUnread
        filters.started = settings.filterStarted
        filters.completed = settings.filterCompleted
        filters.bookmarked = settings.filterBookmarked
        filters.downloaded = DownloadSettings.shared.downloadedOnly ? .include : settings.filterDownloaded
        filters.tracked = settings.filterTracked
        filters.tags = settings.filterTags
        return LibraryQuery.apply(entries, filters: filters, search: searchText, sort: settings.sort, ascending: settings.ascending, seed: settings.randomSeed)
            .compactMap { byId[$0.id] }
    }

    private var selectedMangas: [Manga] {
        favoriteMangas.filter { selection.contains($0.id) }
    }

    // MARK: - Corpo

    public var body: some View {
        NavigationStack(path: $path) {
            content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            .floatingHeader { header }
            .navigationTitle(isSelecting ? "\(selection.count) selecionadas" : "Biblioteca")
            .navigationDestination(for: UnifiedWork.self) { work in
                MangaDetailView(work: work)
            }
            .searchable(text: $searchText, prompt: "Título, autor:, genero:, src:")
            .toolbar { toolbar }
            .sheet(isPresented: $showSettings) {
                LibrarySettingsSheet(settings: settings, tags: GenreTags.counts(favoriteMangas.map(\.genres)))
            }
            .sheet(isPresented: Binding(get: { !categoryTargets.isEmpty }, set: { if !$0 { categoryTargets = [] } })) {
                CategoryPickerSheet(mangas: categoryTargets)
            }
            .confirmationDialog("Remover \(selection.count) obras da biblioteca?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remover", role: .destructive) { removeSelected() }
            }
            .fullScreenCover(item: $readingTarget) { target in
                ReaderView(mangaId: target.mangaId, mangaTitle: target.title, chapters: target.chapters, initialChapterIndex: target.index, coverUrl: target.coverUrl)
            }
            .task(id: favoriteMangas.count) { refreshDownloadCounts() }
            .onChange(of: AppNavigation.shared.pendingMangaId, initial: true) { _, id in
                guard let id, let manga = favoriteMangas.first(where: { $0.id == id }) else { return }
                AppNavigation.shared.pendingMangaId = nil
                path = [UnifiedWork(libraryManga: manga)]
            }
            .onReceive(NotificationCenter.default.publisher(for: .downloadsChanged)) { _ in refreshDownloadCounts() }
        }
    }

    /// Categorias e progresso da atualização, por cima da grade (translúcido, não empurra o conteúdo).
    @ViewBuilder
    private var header: some View {
        let showsTabs = settings.showCategoryTabs && tabs.count > 1 && !favoriteMangas.isEmpty
        if showsTabs || updater.isRunning {
            VStack(spacing: Theme.Space.s) {
                if showsTabs { categoryBar }
                if updater.isRunning { UpdateProgressBar(updater: updater) }
            }
            .padding(.vertical, Theme.Space.s)
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(tabs, id: \.id) { tab in
                    let selected = tab.id == activeTab
                    Button {
                        withAnimation(.snappy) { settings.selectedCategory = tab.id }
                    } label: {
                        Chip(title: tab.name, count: mangas(in: tab.id).count, isSelected: selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Space.margin)
        }
    }

    @ViewBuilder
    private var content: some View {
        if favoriteMangas.isEmpty {
            ContentUnavailableView {
                Label("Biblioteca vazia", systemImage: "books.vertical")
            } description: {
                Text("Adicione obras pelo Explorar.")
            } actions: {
                Button("Explorar") { AppNavigation.shared.tab = .browse }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            let list = visibleMangas
            GeometryReader { proxy in
                ScrollView {
                    if list.isEmpty {
                        ContentUnavailableView(
                            settings.hasActiveFilter || !searchText.isEmpty ? "Nada com esses filtros" : "Categoria vazia",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                        .padding(.top, 60)
                    } else if settings.displayMode == .list {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { manga in
                                cell(manga)
                                    .padding(.horizontal, Theme.Space.margin)
                                Rectangle()
                                    .fill(Theme.hairline)
                                    .frame(height: 0.5)
                                    .padding(.leading, Theme.Space.margin + 46 + Theme.Space.m)
                            }
                        }
                    } else {
                        LazyVGrid(columns: columns(width: proxy.size.width, landscape: proxy.size.width > proxy.size.height), spacing: Theme.Space.gridRow) {
                            ForEach(list) { manga in
                                cell(manga)
                            }
                        }
                        .padding(.horizontal, Theme.Space.margin)
                        .padding(.vertical, Theme.Space.s)
                    }
                }
                .refreshable {
                    // Puxar para atualizar atualiza a aba aberta.
                    await updater.update(categoryId: settings.showCategoryTabs && !categories.isEmpty ? activeTab : nil, context: modelContext)
                }
            }
        }
    }

    private func columns(width: CGFloat, landscape: Bool) -> [GridItem] {
        let count = landscape ? settings.landscapeColumns : settings.portraitColumns
        if count > 0 {
            return Array(repeating: GridItem(.flexible(), spacing: Theme.Space.gutter), count: count)
        }
        let minimum: CGFloat = settings.displayMode == .coverOnly ? 90 : 105
        return [GridItem(.adaptive(minimum: minimum, maximum: 130), spacing: Theme.Space.gutter)]
    }

    private func cell(_ manga: Manga) -> some View {
        let work = UnifiedWork(libraryManga: manga)
        let item = MangaGridItem(
            work: work,
            filter: filter,
            unreadCount: settings.showUnreadBadge && manga.unreadCount > 0 ? manga.unreadCount : nil
        )
        .library(
            mode: settings.displayMode,
            downloadCount: settings.showDownloadBadge ? downloadCounts[manga.id] : nil,
            isSelected: selection.contains(manga.id),
            onContinue: settings.showContinueButton && manga.unreadCount > 0 && !isSelecting ? { continueReading(manga) } : nil
        )
        return Button {
            if isSelecting {
                toggleSelection(manga.id)
            } else {
                path.append(work)
            }
        } label: {
            if settings.showLanguageBadge { item } else { item.withoutLanguages() }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture().onEnded { _ in
            if !isSelecting {
                isSelecting = true
                selection = [manga.id]
            }
        })
    }

    // MARK: - Barra

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancelar") { endSelection() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Selecionar tudo") { selection = Set(visibleMangas.map(\.id)) }
                    Button("Inverter seleção") {
                        selection = Set(visibleMangas.map(\.id)).subtracting(selection)
                    }
                } label: {
                    Image(systemName: "checklist")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { markSelected(read: true) } label: { Image(systemName: "checkmark.circle") }
                    .accessibilityLabel("Marcar como lidas")
                Spacer()
                Button { markSelected(read: false) } label: { Image(systemName: "circle") }
                    .accessibilityLabel("Marcar como não lidas")
                Spacer()
                Button { categoryTargets = selectedMangas } label: { Image(systemName: "folder") }
                    .accessibilityLabel("Mudar categoria")
                Spacer()
                Button { downloadSelected() } label: { Image(systemName: "arrow.down.circle") }
                    .accessibilityLabel("Baixar não lidos")
                Spacer()
                Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Remover da biblioteca")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let manga = visibleMangas.randomElement() { path.append(UnifiedWork(libraryManga: manga)) }
                } label: {
                    Image(systemName: "shuffle")
                }
                .accessibilityLabel("Abrir obra aleatória")
                .disabled(favoriteMangas.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: settings.hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filtrar, ordenar e exibição")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await updater.update(categoryId: nil, context: modelContext) }
                    } label: {
                        Label("Atualizar biblioteca", systemImage: "arrow.clockwise")
                    }
                    NavigationLink {
                        CategoryManagerView()
                    } label: {
                        Label("Categorias", systemImage: "folder")
                    }
                    Button {
                        isSelecting = true
                    } label: {
                        Label("Selecionar", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Ações

    private func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func endSelection() {
        isSelecting = false
        selection = []
    }

    private func markSelected(read: Bool) {
        for manga in selectedMangas {
            ChapterStore.setAllRead(read, mangaId: manga.id, context: modelContext)
        }
        endSelection()
    }

    private func removeSelected() {
        for manga in selectedMangas {
            LibraryActions.removeFromLibrary(manga, context: modelContext)
        }
        try? modelContext.save()
        endSelection()
    }

    private func continueReading(_ manga: Manga) {
        let list = ChapterStore.savedChapterList(for: manga, context: modelContext)
        let progress = ChapterProgress(records: ChapterStore.records(mangaId: manga.id, context: modelContext), mangaId: manga.id)
        guard let index = list.lastIndex(where: { !progress.isRead($0) }) else { return }
        let work = UnifiedWork(libraryManga: manga)
        readingTarget = LibraryReadingTarget(mangaId: manga.id, title: manga.title, coverUrl: work.coverUrl, chapters: list, index: index)
    }

    /// Põe na fila os capítulos não lidos das obras selecionadas.
    private func downloadSelected() {
        for manga in selectedMangas {
            let list = ChapterStore.savedChapterList(for: manga, context: modelContext)
            let progress = ChapterProgress(records: ChapterStore.records(mangaId: manga.id, context: modelContext), mangaId: manga.id)
            DownloadManager.shared.enqueue(list.filter { !progress.isRead($0) }, mangaId: manga.id, mangaTitle: manga.title)
        }
        endSelection()
    }

    private func refreshDownloadCounts() {
        var counts: [String: Int] = [:]
        for manga in favoriteMangas {
            let count = DownloadStore.shared.downloadedCount(mangaId: manga.id)
            if count > 0 { counts[manga.id] = count }
        }
        downloadCounts = counts
    }
}

/// Ações sobre obras da biblioteca usadas em mais de uma tela.
@MainActor
enum LibraryActions {
    static func removeFromLibrary(_ manga: Manga, context: ModelContext) {
        manga.isFavorite = false
        manga.favoriteAt = nil
        if DownloadSettings.shared.deleteOnRemoveFromLibrary {
            DownloadManager.shared.cancel(mangaId: manga.id)
            DownloadStore.shared.deleteManga(mangaId: manga.id)
            NotificationCenter.default.post(name: .downloadsChanged, object: nil)
        }
    }

    /// Categorias de uma obra recém-adicionada, segundo o ajuste "categoria padrão".
    /// Devolve true quando é preciso perguntar ao usuário.
    static func applyDefaultCategory(to manga: Manga, categories: [MangaCategory]) -> Bool {
        let setting = LibrarySettings.shared.defaultCategory
        if setting == "ask" { return !categories.isEmpty }
        if !setting.isEmpty, categories.contains(where: { $0.id == setting }) { manga.categoryIds = [setting] }
        return false
    }
}

extension MangaGridItem {
    func withoutLanguages() -> MangaGridItem {
        MangaGridItem(
            title: title,
            coverUrl: coverUrl,
            coverReferer: coverReferer,
            coverFallbacks: coverFallbacks,
            badgeText: badgeText,
            languageText: nil,
            sourceCount: sourceCount,
            unreadCount: unreadCount
        )
        .library(mode: displayMode, downloadCount: downloadCount, isSelected: isSelected, onContinue: onContinue)
    }
}

/// Barra fina do progresso da atualização da biblioteca, com o contador ao lado.
struct UpdateProgressBar: View {
    let updater: LibraryUpdater

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView(value: Double(updater.progress), total: Double(max(updater.total, 1)))
                .tint(Theme.accent)
            Text("\(updater.progress)/\(updater.total)")
                .textRole(.caption)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Space.margin)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Atualizando \(updater.progress) de \(updater.total)")
    }
}

extension Notification.Name {
    /// Algum capítulo foi baixado ou apagado.
    static let downloadsChanged = Notification.Name("downloadsChanged")
}

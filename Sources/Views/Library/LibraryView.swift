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
        filters.downloaded = settings.filterDownloaded
        filters.tracked = settings.filterTracked
        return LibraryQuery.apply(entries, filters: filters, search: searchText, sort: settings.sort, ascending: settings.ascending, seed: settings.randomSeed)
            .compactMap { byId[$0.id] }
    }

    private var selectedMangas: [Manga] {
        favoriteMangas.filter { selection.contains($0.id) }
    }

    // MARK: - Corpo

    public var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if settings.showCategoryTabs && tabs.count > 1 && !favoriteMangas.isEmpty {
                    categoryBar
                }
                content
            }
            .navigationTitle(isSelecting ? "\(selection.count) selecionadas" : "Biblioteca")
            .navigationDestination(for: UnifiedWork.self) { work in
                MangaDetailView(work: work)
            }
            .searchable(text: $searchText, prompt: "Título, autor:, genero:, src:")
            .toolbar { toolbar }
            .sheet(isPresented: $showSettings) {
                LibrarySettingsSheet(settings: settings)
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
            .onReceive(NotificationCenter.default.publisher(for: .downloadsChanged)) { _ in refreshDownloadCounts() }
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs, id: \.id) { tab in
                    let selected = tab.id == activeTab
                    Button {
                        withAnimation(.snappy) { settings.selectedCategory = tab.id }
                    } label: {
                        HStack(spacing: 4) {
                            Text(tab.name)
                            Text("\(mangas(in: tab.id).count)")
                                .monospacedDigit()
                                .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selected ? Color.accentColor : Color.secondary.opacity(0.12))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        if favoriteMangas.isEmpty {
            ContentUnavailableView {
                Label("Sua biblioteca está vazia", systemImage: "books.vertical")
            } description: {
                Text("Explore obras de todas as fontes Keiyoushi e adicione às suas favoritas.")
            }
        } else {
            let list = visibleMangas
            GeometryReader { proxy in
                ScrollView {
                    if list.isEmpty {
                        ContentUnavailableView(
                            "Nada por aqui",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text(settings.hasActiveFilter || !searchText.isEmpty ? "Nenhuma obra combina com a busca ou os filtros." : "Esta categoria está vazia.")
                        )
                        .padding(.top, 60)
                    } else if settings.displayMode == .list {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { manga in
                                cell(manga)
                                    .padding(.horizontal)
                                Divider().padding(.leading, 74)
                            }
                        }
                    } else {
                        LazyVGrid(columns: columns(width: proxy.size.width, landscape: proxy.size.width > proxy.size.height), spacing: 16) {
                            ForEach(list) { manga in
                                cell(manga)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
    }

    private func columns(width: CGFloat, landscape: Bool) -> [GridItem] {
        let count = landscape ? settings.landscapeColumns : settings.portraitColumns
        if count > 0 {
            return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
        }
        let minimum: CGFloat = settings.displayMode == .coverOnly ? 90 : 105
        return [GridItem(.adaptive(minimum: minimum, maximum: 130), spacing: 14)]
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

extension Notification.Name {
    /// Algum capítulo foi baixado ou apagado.
    static let downloadsChanged = Notification.Name("downloadsChanged")
}

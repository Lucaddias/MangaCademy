import SwiftUI
import SwiftData
import UserNotifications

/// Aba aberta e o que precisa de navegação entre telas (notificações, atalhos, links).
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    enum Tab: Hashable { case library, updates, history, browse, settings }

    var tab: Tab = .library
    /// Última vez que a aba Novidades foi aberta (o selo conta o que veio depois).
    var updatesLastViewed: Date {
        didSet { UserDefaults.standard.set(updatesLastViewed, forKey: "updates_last_viewed") }
    }

    private init() {
        updatesLastViewed = UserDefaults.standard.object(forKey: "updates_last_viewed") as? Date ?? .distantPast
    }
}

/// Capítulo novo de uma obra da biblioteca.
struct UpdateItem: Identifiable {
    let chapter: SourceChapterItem
    let manga: Manga
    let date: Date
    let isRead: Bool
    var id: String { "\(manga.id)|\(chapter.id)" }
}

enum UpdatesFeed {
    /// Capítulos que entraram depois de a obra ir para a biblioteca, no idioma dela, sem repetição.
    @MainActor
    static func items(records: [Chapter], favorites: [Manga]) -> [UpdateItem] {
        let byId = Dictionary(favorites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var readKeys = Set<String>()
        for record in records where record.isRead { readKeys.insert("\(record.mangaId)|\(ChapterStore.progressKey(record))") }
        var result: [UpdateItem] = []
        for record in records {
            guard let date = record.dateFetch, let manga = byId[record.mangaId],
                  date > (manga.favoriteAt ?? .distantPast).addingTimeInterval(1) else { continue }
            if let language = manga.preferredLanguage, (record.language ?? "all") != language { continue }
            let key = "\(manga.id)|\(ChapterStore.progressKey(record))"
            guard seen.insert(key).inserted else { continue }
            let item = ChapterStore.item(from: record)
            if ScanlatorFilter.isExcluded(item, excluded: Set(manga.excludedScanlators)) { continue }
            result.append(UpdateItem(chapter: item, manga: manga, date: date, isRead: record.isRead || readKeys.contains(key)))
        }
        return result
    }
}

struct UpdatesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var records: [Chapter]
    @Query(filter: #Predicate<Manga> { $0.isFavorite == true }) private var favorites: [Manga]
    @Query(sort: \MangaCategory.order) private var categories: [MangaCategory]

    @State private var updater = LibraryUpdater.shared
    @AppStorage("updates_filter_unread") private var onlyUnread = false
    @AppStorage("updates_filter_downloaded") private var onlyDownloaded = false
    @State private var categoryFilter: String?
    @State private var readingTarget: LibraryReadingTarget?
    @State private var downloadVersion = 0

    init() {
        // Últimos 90 dias de capítulos novos.
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        _records = Query(
            filter: #Predicate<Chapter> { $0.dateFetch.flatMap { $0 > cutoff } == true },
            sort: \Chapter.dateFetch,
            order: .reverse
        )
    }

    private var items: [UpdateItem] {
        _ = downloadVersion
        return UpdatesFeed.items(records: records, favorites: favorites).filter { item in
            if onlyUnread && item.isRead { return false }
            if (onlyDownloaded || DownloadSettings.shared.downloadedOnly) && !DownloadStore.shared.isDownloaded(item.chapter, mangaId: item.manga.id) { return false }
            if let categoryFilter {
                let known = Set(categories.map(\.id))
                let mine = Set(item.manga.categoryIds).intersection(known)
                return categoryFilter.isEmpty ? mine.isEmpty : mine.contains(categoryFilter)
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            let items = items
            let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }
            List {
                if updater.isRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(updater.progress), total: Double(max(updater.total, 1)))
                        Text("Atualizando \(updater.progress) de \(updater.total)…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !updater.errors.isEmpty {
                    NavigationLink {
                        UpdateErrorsView()
                    } label: {
                        Label("\(updater.errors.count) obras falharam na última atualização", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if items.isEmpty && !updater.isRunning {
                    ContentUnavailableView {
                        Label("Sem novidades", systemImage: "bell")
                    } description: {
                        Text(lastRunText)
                    } actions: {
                        Button("Atualizar biblioteca") { runUpdate() }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowSeparator(.hidden)
                }
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Section(day.formatted(.relative(presentation: .named, unitsStyle: .wide)).capitalized(with: .current)) {
                        ForEach(days[day] ?? []) { item in
                            row(item)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Novidades")
            .refreshable { await updater.update(categoryId: nil, context: modelContext) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        UpcomingView()
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Próximos lançamentos")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Só não lidos", isOn: $onlyUnread)
                        Toggle("Só baixados", isOn: $onlyDownloaded)
                        if !categories.isEmpty {
                            Picker("Categoria", selection: $categoryFilter) {
                                Text("Todas").tag(String?.none)
                                Text("Padrão").tag(String?.some(""))
                                ForEach(categories) { Text($0.name).tag(String?.some($0.id)) }
                            }
                        }
                        Divider()
                        Button { markAll(items, read: true) } label: { Label("Marcar todos como lidos", systemImage: "checkmark.circle") }
                    } label: {
                        Image(systemName: onlyUnread || onlyDownloaded || categoryFilter != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { runUpdate() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(updater.isRunning)
                        .accessibilityLabel("Atualizar biblioteca")
                }
            }
            .fullScreenCover(item: $readingTarget) { target in
                ReaderView(mangaId: target.mangaId, mangaTitle: target.title, chapters: target.chapters, initialChapterIndex: target.index, coverUrl: target.coverUrl)
            }
            .onAppear { AppNavigation.shared.updatesLastViewed = Date() }
            .onReceive(NotificationCenter.default.publisher(for: .downloadsChanged)) { _ in downloadVersion += 1 }
        }
    }

    private var lastRunText: String {
        guard let last = updater.lastRun else { return "Puxe para baixo para procurar capítulos novos nas obras da biblioteca." }
        return "Última atualização \(last.formatted(.relative(presentation: .named)))."
    }

    private func row(_ item: UpdateItem) -> some View {
        let work = UnifiedWork(libraryManga: item.manga)
        return Button {
            open(item)
        } label: {
            HStack(spacing: 12) {
                AsyncMangaCover(urlString: work.coverUrl, cornerRadius: 6, referer: work.coverSourceId.flatMap { SourceManager.shared.getSource(id: $0)?.imageReferer })
                    .frame(width: 44, height: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.manga.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(item.chapter.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if DownloadStore.shared.isDownloaded(item.chapter, mangaId: item.manga.id) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.teal)
                }
            }
            .opacity(item.isRead ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button {
                ChapterStore.setRead(!item.isRead, chapter: item.chapter, mangaId: item.manga.id, context: modelContext)
            } label: {
                Label(item.isRead ? "Não lido" : "Lido", systemImage: item.isRead ? "circle" : "checkmark.circle")
            }
            .tint(.blue)
        }
    }

    private func open(_ item: UpdateItem) {
        var list = ChapterStore.savedChapterList(for: item.manga, context: modelContext)
        let key = ChapterStore.progressKey(item.chapter)
        let index: Int
        if let found = list.firstIndex(where: { $0.id == item.chapter.id }) {
            index = found
        } else if let found = list.firstIndex(where: { ChapterStore.progressKey($0) == key }) {
            list[found] = item.chapter
            index = found
        } else {
            list = [item.chapter]
            index = 0
        }
        let work = UnifiedWork(libraryManga: item.manga)
        readingTarget = LibraryReadingTarget(mangaId: item.manga.id, title: item.manga.title, coverUrl: work.coverUrl, chapters: list, index: index)
    }

    private func markAll(_ items: [UpdateItem], read: Bool) {
        for item in items where item.isRead != read {
            ChapterStore.setRead(read, chapter: item.chapter, mangaId: item.manga.id, context: modelContext)
        }
    }

    private func runUpdate() {
        Task {
            if UpdateSettings.shared.notify { _ = await UpdateNotifier.requestPermission() }
            await updater.update(categoryId: nil, context: modelContext)
        }
    }
}

/// Próximos lançamentos previstos (intervalo mediano entre capítulos de cada obra).
struct UpcomingView: View {
    @Query(filter: #Predicate<Manga> { $0.isFavorite == true && $0.nextUpdateAt != nil }, sort: \Manga.nextUpdateAt)
    private var mangas: [Manga]

    var body: some View {
        let days = Dictionary(grouping: mangas) { Calendar.current.startOfDay(for: $0.nextUpdateAt ?? Date()) }
        List {
            if mangas.isEmpty {
                ContentUnavailableView(
                    "Sem previsões",
                    systemImage: "calendar",
                    description: Text("A previsão aparece depois que a obra tem alguns capítulos com data de lançamento.")
                )
            }
            ForEach(days.keys.sorted(), id: \.self) { day in
                Section(day.formatted(date: .complete, time: .omitted).capitalized(with: .current)) {
                    ForEach(days[day] ?? []) { manga in
                        NavigationLink {
                            MangaDetailView(work: UnifiedWork(libraryManga: manga))
                        } label: {
                            HStack(spacing: 12) {
                                AsyncMangaCover(urlString: UnifiedWork(libraryManga: manga).coverUrl, cornerRadius: 4)
                                    .frame(width: 36, height: 54)
                                VStack(alignment: .leading) {
                                    Text(manga.title).font(.subheadline).lineLimit(2)
                                    if let latest = manga.latestUploadAt {
                                        Text("Último: \(latest.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Próximos")
    }
}

/// Obras que falharam na última atualização, com "tentar de novo".
struct UpdateErrorsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var updater = LibraryUpdater.shared

    var body: some View {
        List {
            ForEach(updater.errors) { error in
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.title).font(.subheadline.bold())
                    Text(error.message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if updater.errors.isEmpty {
                ContentUnavailableView("Nenhum erro", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Erros da atualização")
        .toolbar {
            Button("Tentar de novo") {
                let ids = Set(updater.errors.map(\.mangaId))
                Task { await updater.update(categoryId: nil, context: modelContext, mangaIds: ids) }
            }
            .disabled(updater.errors.isEmpty || updater.isRunning)
        }
    }
}

/// Ajustes de atualização da biblioteca.
struct UpdateSettingsView: View {
    @State private var settings = UpdateSettings.shared
    @Query(sort: \MangaCategory.order) private var categories: [MangaCategory]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Atualizar automaticamente", selection: $settings.intervalHours) {
                    Text("Nunca").tag(0)
                    Text("A cada 12 horas").tag(12)
                    Text("Diariamente").tag(24)
                    Text("A cada 2 dias").tag(48)
                    Text("Semanalmente").tag(168)
                }
                Toggle("Só no Wi‑Fi", isOn: $settings.onlyOnWifi)
                Toggle("Notificar capítulos novos", isOn: $settings.notify)
                    .onChange(of: settings.notify) { _, on in
                        if on { Task { _ = await UpdateNotifier.requestPermission() } }
                    }
            } footer: {
                Text("O iOS decide o melhor momento para rodar em segundo plano. Se passar do prazo, a atualização roda ao abrir o app.")
            }
            Section("Pular obras") {
                Toggle("Completas", isOn: $settings.skipCompleted)
                Toggle("Não iniciadas", isOn: $settings.skipNotStarted)
                Toggle("Com capítulos não lidos", isOn: $settings.skipWithUnread)
                Toggle("Fora da previsão de lançamento", isOn: $settings.skipOutsidePrediction)
            }
            Section {
                Toggle("Atualizar capa, sinopse e status", isOn: $settings.refreshMetadata)
            }
            if !categories.isEmpty {
                Section {
                    categoryRow("Padrão", id: "")
                    ForEach(categories) { categoryRow($0.name, id: $0.id) }
                } header: {
                    Text("Categorias")
                } footer: {
                    Text("Toque para alternar: incluir ✓, excluir ✕ ou ignorar. Sem nenhuma incluída, todas entram.")
                }
            }
        }
        .navigationTitle("Atualizações")
    }

    private func categoryRow(_ name: String, id: String) -> some View {
        let state: TriState = settings.includedCategories.contains(id) ? .include : (settings.excludedCategories.contains(id) ? .exclude : .ignore)
        return Button {
            settings.includedCategories.removeAll { $0 == id }
            settings.excludedCategories.removeAll { $0 == id }
            switch state.next {
            case .include: settings.includedCategories.append(id)
            case .exclude: settings.excludedCategories.append(id)
            case .ignore: break
            }
        } label: {
            HStack {
                Image(systemName: state.symbol)
                    .foregroundStyle(state == .exclude ? Color.red : Color.accentColor)
                Text(name).foregroundStyle(.primary)
            }
        }
    }
}

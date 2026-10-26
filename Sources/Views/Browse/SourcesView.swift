import SwiftUI
import SwiftData

/// Lista de fontes do Explorar: última usada, fixadas e o resto por idioma.
struct SourcesListView: View {
    @AppStorage(Preferences.Key.showNsfwSources) private var showNsfw = Preferences.Default.showNsfwSources
    @State private var settings = SourceSettings.shared
    @State private var searchText = ""
    @State private var webSource: WebTarget?

    private var sources: [MangaSource] {
        _ = settings.disabledSources
        _ = settings.disabledLanguages
        let all = SourceManager.shared.browsableSources(includeNsfw: showNsfw)
        let query = searchText.trimmed
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let list = sources
        let grouped = Dictionary(grouping: list, by: \.language)
        let languages = grouped.keys.sorted { LanguageOrder.rank($0) < LanguageOrder.rank($1) }
        List {
            if searchText.isEmpty, let last = settings.lastUsedSource.flatMap({ id in list.first { $0.id == id } }) {
                Section("Última usada") { row(last) }
            }
            let pinned = list.filter { settings.pinnedSources.contains($0.id) }
            if !pinned.isEmpty {
                Section("Fixadas") { ForEach(pinned, id: \.id) { row($0) } }
            }
            ForEach(languages, id: \.self) { language in
                Section(LanguageCode.displayName(language)) {
                    ForEach(grouped[language]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, id: \.id) { row($0) }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Buscar fonte")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SourcesFilterView() } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Ativar e desativar fontes")
            }
        }
        .sheet(item: $webSource) { target in
            SourceWebView(title: target.title, url: target.url)
        }
    }

    private func row(_ source: MangaSource) -> some View {
        NavigationLink(value: SourceRoute(id: source.id)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                    Text(LanguageCode.shortLabel(source.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if settings.pinnedSources.contains(source.id) {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button(settings.pinnedSources.contains(source.id) ? "Desafixar" : "Fixar", systemImage: "pin") {
                settings.toggle(source.id, in: \.pinnedSources)
            }
            .tint(.orange)
        }
        .contextMenu {
            Button(settings.pinnedSources.contains(source.id) ? "Desafixar" : "Fixar", systemImage: "pin") {
                settings.toggle(source.id, in: \.pinnedSources)
            }
            if let url = URL(string: source.baseUrl), !source.baseUrl.isEmpty {
                Button("Abrir no navegador", systemImage: "safari") {
                    webSource = WebTarget(title: source.name, url: url)
                }
            }
            Button("Desativar", systemImage: "eye.slash", role: .destructive) {
                settings.disabledSources.insert(source.id)
            }
        }
    }
}

struct SourceRoute: Hashable {
    let id: String
}

struct WebTarget: Identifiable {
    let title: String
    let url: URL
    var id: URL { url }
}

/// Português primeiro, depois inglês e "todos", depois o resto em ordem alfabética.
enum LanguageOrder {
    static func rank(_ code: String) -> (Int, String) {
        if LanguageCode.isPortuguese(code) { return (0, code) }
        if code == "en" { return (1, code) }
        if code == "all" { return (2, code) }
        return (3, LanguageCode.displayName(code))
    }
}

/// Ativar/desativar idiomas e fontes (como o `SourcesFilterScreen` do Mihon).
struct SourcesFilterView: View {
    @AppStorage(Preferences.Key.showNsfwSources) private var showNsfw = Preferences.Default.showNsfwSources
    @State private var settings = SourceSettings.shared

    var body: some View {
        let all = SourceManager.shared.browsableSources(includeNsfw: showNsfw, includeDisabled: true)
        let grouped = Dictionary(grouping: all, by: \.language)
        List {
            Section {
                Text("Fontes desativadas saem do catálogo, da busca e da lista de fontes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(grouped.keys.sorted { LanguageOrder.rank($0) < LanguageOrder.rank($1) }, id: \.self) { language in
                Section {
                    Toggle(isOn: binding(language, in: \.disabledLanguages)) {
                        Text(LanguageCode.displayName(language)).bold()
                    }
                    if !settings.disabledLanguages.contains(language) {
                        ForEach(grouped[language]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, id: \.id) { source in
                            Toggle(source.name, isOn: binding(source.id, in: \.disabledSources))
                                .padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .navigationTitle("Fontes")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Liga = ativada (não está no conjunto de desativadas).
    private func binding(_ id: String, in keyPath: ReferenceWritableKeyPath<SourceSettings, Set<String>>) -> Binding<Bool> {
        Binding(
            get: { !settings[keyPath: keyPath].contains(id) },
            set: { enabled in
                if enabled { settings[keyPath: keyPath].remove(id) } else { settings[keyPath: keyPath].insert(id) }
            }
        )
    }
}

/// Populares, Recentes e Busca de uma só fonte, usando a `MangaSource` direto.
struct SourceBrowseView: View {
    let source: MangaSource

    @AppStorage(Preferences.Key.languageFilter) private var filterRaw: String = Preferences.Default.languageFilter.rawValue
    @AppStorage(Preferences.Key.blockAdultTags) private var blockAdult = Preferences.Default.blockAdultTags
    @Query(filter: #Predicate<Manga> { $0.isFavorite == true }) private var favorites: [Manga]
    @State private var mode: Mode = .popular
    @State private var searchText = ""
    @State private var activeQuery: String?
    @State private var works: [UnifiedWork] = []
    @State private var page = 0
    @State private var hasNext = true
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showWeb = false
    @State private var generation = 0

    enum Mode: String, CaseIterable, Identifiable {
        case popular = "Populares"
        case latest = "Recentes"
        var id: String { rawValue }
    }

    private let columns = [GridItem(.adaptive(minimum: 105, maximum: 130), spacing: 14)]
    private var filter: LanguageFilter { LanguageFilter(rawValue: filterRaw) ?? .portuguese }
    private var isBlocked: Bool {
        if case .blocked? = error as? HTTPError { return true }
        return false
    }

    var body: some View {
        let index = LibraryIndex(favorites)
        ScrollView {
            if activeQuery == nil {
                Picker("Ordem", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(works) { work in
                    CatalogCell(work: work, filter: filter, index: index, showsLatestChapter: mode == .latest && activeQuery == nil)
                        .onAppear { if work.id == works.last?.id { loadMore() } }
                }
            }
            .padding()
            footer
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Buscar em \(source.name)")
        .onSubmit(of: .search) {
            let query = searchText.trimmed
            activeQuery = query.isEmpty ? nil : query
            reset()
        }
        .onChange(of: searchText) { _, value in
            if value.trimmed.isEmpty && activeQuery != nil {
                activeQuery = nil
                reset()
            }
        }
        .onChange(of: mode) { _, _ in reset() }
        .refreshable { reset() }
        .toolbar {
            if let url = URL(string: source.baseUrl), !source.baseUrl.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Abrir no navegador", systemImage: "safari") { showWeb = true }
                }
            }
        }
        .sheet(isPresented: $showWeb) {
            if let url = URL(string: source.baseUrl) {
                SourceWebView(title: source.name, url: url) { if error != nil { reset() } }
            }
        }
        .task {
            SourceSettings.shared.lastUsedSource = source.id
            if works.isEmpty { reset() }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error, works.isEmpty || !hasNext {
            VStack(spacing: 10) {
                Image(systemName: isBlocked ? "shield.lefthalf.filled" : "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(error.localizedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if isBlocked {
                    Button("Resolver no navegador") { showWeb = true }
                        .buttonStyle(.borderedProminent)
                }
                Button("Tentar novamente") { reset() }
            }
            .padding()
        } else if isLoading {
            ProgressView().padding()
        } else if works.isEmpty {
            Text(activeQuery == nil ? "Nenhuma obra" : "Nada encontrado para “\(activeQuery ?? "")”")
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    private func reset() {
        generation += 1
        works = []
        page = 0
        hasNext = true
        error = nil
        isLoading = false
        loadMore()
    }

    private func loadMore() {
        guard hasNext, !isLoading else { return }
        isLoading = true
        let next = page + 1
        let current = generation
        let query = activeQuery
        let mode = mode
        Task { @MainActor in
            do {
                let result: SourceMangaPage
                if let query {
                    result = try await source.search(query: query, page: next)
                } else if mode == .latest {
                    result = try await source.fetchLatest(page: next)
                } else {
                    result = try await source.fetchPopular(page: next)
                }
                guard current == generation else { return }
                let known = Set(works.map(\.id))
                let fallback = source.language == "all" ? [] : [source.language]
                let new = result.items.compactMap { item -> UnifiedWork? in
                    let ref = WorkSourceRef(
                        sourceId: source.id, sourceName: source.name, remoteUrl: item.remoteUrl, title: item.title,
                        coverUrl: item.coverUrl, languages: item.languages.isEmpty ? fallback : item.languages
                    )
                    var work = UnifiedWork(ref: ref, altTitles: item.altTitles, genres: item.genres)
                    work.noteLatestChapter(name: item.latestChapterName, date: item.latestChapterDate)
                    if known.contains(work.id) || (blockAdult && work.isAdult) { return nil }
                    return work
                }
                works += new
                page = next
                hasNext = result.hasNextPage && !result.items.isEmpty
            } catch {
                guard current == generation else { return }
                self.error = error
                hasNext = false
            }
            isLoading = false
        }
    }
}

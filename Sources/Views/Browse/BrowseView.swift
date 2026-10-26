import SwiftUI
import SwiftData

/// Catálogo unificado de todas as fontes Keiyoushi com motor iOS, em todos os idiomas, ou de uma fonte só
/// (menu do título). O idioma preferido (Ajustes) só decide a ordem dos selos de idioma.
public struct BrowseView: View {
    @AppStorage(Preferences.Key.languageFilter) private var filterRaw: String = Preferences.Default.languageFilter.rawValue
    @AppStorage(Preferences.Key.showNsfwSources) private var showNsfw = Preferences.Default.showNsfwSources
    @AppStorage(Preferences.Key.blockAdultTags) private var blockAdult = Preferences.Default.blockAdultTags

    @AppStorage(Preferences.Key.catalogSource) private var sourceId = ""

    @Query(filter: #Predicate<Manga> { $0.isFavorite == true }) private var favorites: [Manga]
    @State private var sourceSettings = SourceSettings.shared
    @State private var feed = CatalogFeed()
    @State private var sort: BrowseSort = .popular
    @State private var searchText = ""
    @State private var activeQuery: String?
    @State private var showSourcePicker = false
    @State private var showTagPicker = false
    @FocusState private var searchFocused: Bool

    enum BrowseSort: String, CaseIterable, Identifiable {
        case popular = "Populares"
        case latest = "Recentes"
        var id: String { rawValue }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 105, maximum: 130), spacing: Theme.Space.gutter)
    ]

    /// Idioma preferido: vem primeiro nos selos de cada obra.
    private var preferred: LanguageFilter {
        LanguageFilter(rawValue: filterRaw) ?? .portuguese
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            catalog
                // O cabeçalho próprio faz o papel da barra; o título fica para o botão de voltar
                .toolbar(.hidden, for: .navigationBar)
                .navigationTitle(title)
                .navigationDestination(for: UnifiedWork.self) { work in
                    MangaDetailView(work: work)
                }
        }
    }

    private var catalog: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            // Título, busca e filtros numa faixa translúcida: as capas passam por baixo
            .floatingHeader { header }
            .sheet(isPresented: $showSourcePicker) {
                NavigationStack {
                    CatalogSourcePicker(selection: $sourceId)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showTagPicker) {
                NavigationStack {
                    TagPickerList(tags: feed.availableTags, selection: tagSelection)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("OK") { showTagPicker = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .onChange(of: searchText) { _, newValue in
                if newValue.trimmed.isEmpty && activeQuery != nil {
                    activeQuery = nil
                    reload()
                }
            }
            .onChange(of: sort) { _, _ in reload() }
            .onChange(of: sourceId) { _, _ in reload() }
            .onChange(of: showNsfw) { _, _ in reload() }
            .onChange(of: blockAdult) { _, _ in reload() }
            .task {
                if feed.totalSources == 0 { reload() }
            }
            .onChange(of: sourceSettings.disabledSources) { _, _ in reload() }
            .onChange(of: sourceSettings.disabledLanguages) { _, _ in reload() }
    }

    // MARK: - Cabeçalho

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            sourceMenu
                .padding(.horizontal, Theme.Space.margin)
            searchField
                .padding(.horizontal, Theme.Space.margin)
            filterChips
        }
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.m)
    }

    /// "Explorar" = todas as fontes; o menu troca para uma fonte só.
    private var title: String {
        selectedSource?.name ?? "Explorar"
    }

    /// Fonte escolhida, se ainda estiver disponível (ativa e, se for +18, com +18 ligado).
    private var selectedSource: MangaSource? {
        sourceId.isEmpty ? nil : available(sourceId)
    }

    private func available(_ id: String) -> MangaSource? {
        guard let source = SourceManager.shared.getSource(id: id),
              sourceSettings.isEnabled(source),
              showNsfw || !SourceManager.shared.isNsfw(id) else { return nil }
        return source
    }

    /// Atalhos do menu: NexusToons primeiro, depois as fixadas e a fonte escolhida.
    private var quickSources: [MangaSource] {
        let pinned = sourceSettings.pinnedSources
            .filter { $0 != CatalogSourcePicker.featuredId }
            .compactMap(available)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var list = [available(CatalogSourcePicker.featuredId)].compactMap { $0 } + pinned
        if let selectedSource, !list.contains(where: { $0.id == selectedSource.id }) {
            list.append(selectedSource)
        }
        return list
    }

    private var sourceMenu: some View {
        Menu {
            Picker("Fonte", selection: $sourceId) {
                Text("Todas as fontes").tag("")
                ForEach(quickSources, id: \.id) { source in
                    Text(source.name).tag(source.id)
                }
            }
            Button("Outras fontes…", systemImage: "list.bullet") { showSourcePicker = true }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Fonte: \(selectedSource?.name ?? "todas")")
        .accessibilityHint("Troca a fonte do catálogo")
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.inkTertiary)
            TextField("", text: $searchText, prompt: Text(searchPrompt).foregroundStyle(Theme.inkTertiary))
                .foregroundStyle(Theme.ink)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit {
                    let query = searchText.trimmed
                    activeQuery = query.isEmpty ? nil : query
                    reload()
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpar busca")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 40)
        .floatingSurface(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { searchFocused = true }
    }

    private var searchPrompt: String {
        selectedSource.map { "Buscar em \($0.name)" } ?? "Buscar em todas as fontes"
    }

    /// Ordem e tags. Na busca a ordem não vale e some; as tags ficam só na folha do botão.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                if activeQuery == nil {
                    ForEach(BrowseSort.allCases) { option in
                        Button {
                            withAnimation(.snappy) { sort = option }
                        } label: {
                            Chip(title: option.rawValue, isSelected: sort == option, large: true)
                        }
                        .accessibilityAddTraits(sort == option ? .isSelected : [])
                    }
                }
                Button { showTagPicker = true } label: {
                    Chip(title: "Tags",
                         count: feed.tagFilter.isEmpty ? nil : feed.tagFilter.count,
                         systemImage: "tag",
                         isSelected: !feed.tagFilter.isEmpty,
                         large: true)
                }
                .accessibilityLabel(feed.tagFilter.isEmpty ? "Tags" : "Tags: \(tagNames)")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Space.margin)
        }
        .scrollClipDisabled()
    }

    private var tagSelection: Binding<Set<String>> {
        Binding(get: { feed.tagFilter }, set: { feed.setTagFilter($0) })
    }

    private var tagNames: String {
        feed.tagFilter.map(GenreTags.label(for:)).sorted().joined(separator: " + ")
    }

    // MARK: - Conteúdo

    @ViewBuilder
    private var content: some View {
        if feed.works.isEmpty {
            if feed.isExhausted {
                emptyState
            } else {
                VStack(spacing: Theme.Space.s) {
                    ProgressView()
                    Text(loadingTitle)
                        .textRole(.meta)
                        .multilineTextAlignment(.center)
                    if feed.totalSources > 1 {
                        Text("\(feed.finishedSources)/\(feed.totalSources) fontes")
                            .textRole(.caption)
                            .monospacedDigit()
                    }
                }
                .padding(Theme.Space.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Theme.Space.gridRow) {
                    let index = LibraryIndex(favorites)
                    ForEach(feed.works) { work in
                        CatalogCell(work: work, filter: preferred, index: index, showsLatestChapter: feed.mode == .latest)
                            .onAppear { feed.onAppear(of: work) }
                    }
                }
                .padding(.horizontal, Theme.Space.margin)
                .padding(.vertical, Theme.Space.s)

                footer
                    .padding(.vertical, Theme.Space.xl)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { reload() }
        }
    }

    /// Uma linha de status no fim da grade: total ao terminar, progresso enquanto carrega.
    @ViewBuilder
    private var footer: some View {
        VStack(spacing: Theme.Space.s) {
            if feed.isExhausted {
                Text(summaryText)
                    .textRole(.caption)
                    .multilineTextAlignment(.center)
            } else {
                VStack(spacing: Theme.Space.s) {
                    ProgressView()
                    if feed.inFlight > 0 && feed.totalSources > 1 {
                        Text("\(feed.finishedSources)/\(feed.totalSources) fontes")
                            .textRole(.caption)
                            .monospacedDigit()
                    }
                }
                // Sentinela: se o fim da lista ficou visível, pede mais obras
                .onAppear { feed.requestMore() }
            }
            blockedNote
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.margin)
    }

    private var loadingTitle: String {
        if !feed.tagFilter.isEmpty { return "Procurando \(tagNames)" }
        if let activeQuery { return "Buscando “\(activeQuery)”" }
        return "Carregando catálogo"
    }

    private var summaryText: String {
        guard selectedSource == nil else { return "\(feed.works.count) obras" }
        var parts = ["\(feed.works.count) obras", "\(feed.respondingSources) fontes"]
        if feed.failedSources > 0 { parts.append("\(feed.failedSources) fora do ar") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var blockedNote: some View {
        if feed.blockedCount > 0 {
            Label("\(feed.blockedCount) ocultas", systemImage: "eye.slash")
                .textRole(.caption)
                .accessibilityLabel("\(feed.blockedCount) obras com tag adulta ocultas")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !feed.tagFilter.isEmpty {
            ContentUnavailableView {
                Label("Nenhuma obra com essas tags", systemImage: "tag.slash")
            } description: {
                Text(tagNames)
            } actions: {
                Button("Limpar tags") { feed.setTagFilter([]) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            sourcesEmptyState
        }
    }

    private var sourcesEmptyState: some View {
        ContentUnavailableView {
            Label(activeQuery == nil ? selectedSource.map { "\($0.name) não respondeu" } ?? "Nenhuma fonte respondeu" : "Nada encontrado",
                  systemImage: activeQuery == nil ? "wifi.exclamationmark" : "magnifyingglass")
        } description: {
            if activeQuery == nil { Text("Verifique sua conexão.") }
        } actions: {
            Button("Tentar de novo") { reload() }
                .buttonStyle(.borderedProminent)
            blockedNote
        }
    }

    private func reload() {
        let mode: CatalogFeed.Mode
        if let activeQuery {
            mode = .search(activeQuery)
        } else {
            mode = sort == .popular ? .popular : .latest
        }
        feed.reset(filter: .all, mode: mode, includeNsfw: showNsfw, sourceId: selectedSource?.id)
    }
}

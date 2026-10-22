import SwiftUI

/// Catálogo unificado de todas as fontes Keiyoushi com motor iOS.
/// O filtro de idioma substitui o antigo seletor "Fontes / Extensões".
public struct BrowseView: View {
    @AppStorage(Preferences.Key.languageFilter) private var filterRaw: String = Preferences.Default.languageFilter.rawValue
    @AppStorage(Preferences.Key.showNsfwSources) private var showNsfw = Preferences.Default.showNsfwSources
    @AppStorage(Preferences.Key.blockAdultTags) private var blockAdult = Preferences.Default.blockAdultTags

    @State private var feed = CatalogFeed()
    @State private var sort: BrowseSort = .popular
    @State private var searchText = ""
    @State private var activeQuery: String?

    enum BrowseSort: String, CaseIterable, Identifiable {
        case popular = "Populares"
        case latest = "Recentes"
        var id: String { rawValue }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 105, maximum: 130), spacing: 14)
    ]

    private var filter: LanguageFilter {
        LanguageFilter(rawValue: filterRaw) ?? .portuguese
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                content
            }
            .navigationTitle("Explorar")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UnifiedWork.self) { work in
                MangaDetailView(work: work)
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar em todas as fontes")
            .onSubmit(of: .search) {
                let query = searchText.trimmed
                activeQuery = query.isEmpty ? nil : query
                reload()
            }
            .onChange(of: searchText) { _, newValue in
                if newValue.trimmed.isEmpty && activeQuery != nil {
                    activeQuery = nil
                    reload()
                }
            }
            .onChange(of: filterRaw) { _, _ in reload() }
            .onChange(of: sort) { _, _ in reload() }
            .onChange(of: showNsfw) { _, _ in reload() }
            .onChange(of: blockAdult) { _, _ in reload() }
            .task {
                if feed.totalSources == 0 { reload() }
            }
        }
    }

    // MARK: - Filtros

    private var filterBar: some View {
        VStack(spacing: 8) {
            Picker("Idioma", selection: $filterRaw) {
                ForEach(LanguageFilter.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                if let activeQuery {
                    Label("“\(activeQuery)”", systemImage: "magnifyingglass")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Picker("Ordem", selection: $sort) {
                        ForEach(BrowseSort.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                Spacer(minLength: 4)
                Text("\(feed.works.count) obras · \(feed.totalSources) fontes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Conteúdo

    @ViewBuilder
    private var content: some View {
        if feed.works.isEmpty {
            if feed.isExhausted {
                emptyState
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text(activeQuery == nil
                         ? "Carregando obras de \(feed.totalSources) fontes Keiyoushi…"
                         : "Buscando em \(feed.totalSources) fontes…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if feed.finishedSources > 0 {
                        Text("\(feed.finishedSources) de \(feed.totalSources) fontes consultadas")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if feed.verifyingCount > 0 {
                        Text("Unificando \(feed.verifyingCount) obras entre fontes e idiomas…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(feed.works) { work in
                        NavigationLink(value: work) {
                            MangaGridItem(work: work, filter: filter)
                        }
                        .buttonStyle(.plain)
                        .onAppear { feed.onAppear(of: work) }
                    }
                }
                .padding()

                footer
                    .padding(.bottom, 24)
            }
            .refreshable { reload() }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if feed.isExhausted {
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text("Fim do catálogo — \(feed.works.count) obras de \(feed.respondingSources) fontes Keiyoushi")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if feed.failedSources > 0 {
                    Text("\(feed.failedSources) fontes não responderam (fora do ar ou com proteção anti-bot)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                blockedNote
            }
            .padding(.horizontal)
        } else {
            VStack(spacing: 6) {
                ProgressView()
                Text(feed.inFlight > 0
                     ? "Buscando em \(feed.inFlight) fontes… (\(feed.finishedSources)/\(feed.totalSources) concluídas)"
                     : "Carregando mais…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if feed.verifyingCount > 0 {
                    Text("Unificando \(feed.verifyingCount) obras entre fontes e idiomas…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                blockedNote
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            // Sentinela: se o fim da lista ficou visível, pede mais obras
            .onAppear { feed.requestMore() }
        }
    }

    @ViewBuilder
    private var blockedNote: some View {
        if feed.blockedCount > 0 {
            Label("\(feed.blockedCount) obras com tag adulta ocultas", systemImage: "eye.slash")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: activeQuery == nil ? "wifi.exclamationmark" : "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(activeQuery == nil ? "Nenhuma fonte respondeu" : "Nenhuma obra encontrada")
                .font(.headline)
            Text(activeQuery == nil
                 ? "Verifique sua conexão. \(feed.failedSources) de \(feed.totalSources) fontes falharam."
                 : "Nenhuma das \(feed.totalSources) fontes (\(filter.title)) tem resultados para “\(activeQuery ?? "")”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            blockedNote
            Button("Tentar novamente") { reload() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func reload() {
        let mode: CatalogFeed.Mode
        if let activeQuery {
            mode = .search(activeQuery)
        } else {
            mode = sort == .popular ? .popular : .latest
        }
        feed.reset(filter: filter, mode: mode, includeNsfw: showNsfw)
    }
}

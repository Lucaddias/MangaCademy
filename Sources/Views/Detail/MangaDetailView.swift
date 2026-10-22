import SwiftUI
import SwiftData

/// Estado da tela de detalhe: carrega a obra pelo `WorkLoader` e cuida da escolha do idioma,
/// das scans escondidas e da fonte preferida.
@MainActor
@Observable
final class WorkDetailModel {
    private(set) var work: UnifiedWork
    private(set) var detail: SourceMangaDetail?
    /// Capítulos de todas as fontes, antes de esconder scans e tirar repetidos.
    private(set) var rawChapters: [SourceChapterItem] = []
    private(set) var chaptersByLanguage: [String: [SourceChapterItem]] = [:]
    private(set) var languages: [String] = []
    private(set) var pendingSources = 0
    private(set) var failures: [String] = []
    private(set) var hasLoaded = false
    /// Alguma fonte marcou a obra como conteúdo adulto.
    private(set) var isAdult = false
    var selectedLanguage: String?

    /// Scans e fontes escondidas (`ScanlatorFilter`) e fonte preferida nos capítulos repetidos.
    var excluded: Set<String> = [] { didSet { regroup() } }
    var preferredSourceId: String? { didSet { regroup() } }
    var blockedRefs: [WorkSourceRef] = []

    private var userPickedLanguage = false
    private var filter: LanguageFilter = .all
    private var savedLanguage: String?

    init(work: UnifiedWork) {
        self.work = work
        self.isAdult = work.isAdult
    }

    var isLoading: Bool { pendingSources > 0 }

    var chapters: [SourceChapterItem] {
        guard let selectedLanguage else { return [] }
        return chaptersByLanguage[selectedLanguage] ?? []
    }

    var displayTitle: String { work.title }
    var coverUrl: String? { work.coverUrl ?? detail?.coverUrl }
    var coverReferer: String? {
        work.coverSourceId.flatMap { SourceManager.shared.getSource(id: $0)?.imageReferer }
    }

    /// Scans de todos os capítulos (de todos os idiomas), em ordem alfabética.
    var allScanlators: [String] {
        Array(Set(rawChapters.flatMap(ScanlatorFilter.scanlators(of:)))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var chapterSourceIds: [String] {
        var seen: [String] = []
        for chapter in rawChapters where !seen.contains(chapter.sourceId) { seen.append(chapter.sourceId) }
        return seen
    }

    func pickLanguage(_ language: String) {
        userPickedLanguage = true
        selectedLanguage = language
    }

    func load(filter: LanguageFilter, savedLanguage: String?) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        self.filter = filter
        self.savedLanguage = savedLanguage
        if let savedLanguage { selectedLanguage = savedLanguage; userPickedLanguage = true }

        let loader = WorkLoader(work: work, filter: filter)
        loader.onUpdate = { [weak self] loader in self?.apply(loader) }
        await loader.load()
    }

    func reload() async {
        hasLoaded = false
        failures = []
        rawChapters = []
        chaptersByLanguage = [:]
        languages = []
        await load(filter: filter, savedLanguage: userPickedLanguage ? selectedLanguage : savedLanguage)
    }

    /// Anexa uma fonte achada à mão e recarrega.
    func attach(_ ref: WorkSourceRef) async {
        work.merge(ref: ref, altTitles: [])
        await reload()
    }

    /// Separa uma fonte unificada por engano.
    func detach(refId: String) async {
        guard work.refs.count > 1 else { return }
        work.refs.removeAll { $0.id == refId }
        await reload()
    }

    /// Usa a capa desta fonte.
    func useCover(of ref: WorkSourceRef) {
        guard let cover = ref.coverUrl else { return }
        work.coverUrl = cover
        work.coverSourceId = ref.sourceId
    }

    private func apply(_ loader: WorkLoader) {
        let state = loader.state
        pendingSources = loader.pendingSources
        work = state.work
        failures = state.failures
        blockedRefs = state.blockedRefs
        rawChapters = state.chapters
        regroup()

        if let merged = state.mergedDetail(filter: filter) {
            detail = merged
            isAdult = state.isAdult
        }
    }

    private func regroup() {
        let visible = rawChapters.filter { !ScanlatorFilter.isExcluded($0, excluded: excluded) }
        chaptersByLanguage = SourceAggregator.shared.chaptersByLanguage(visible, preferredSourceId: preferredSourceId)
        languages = SourceAggregator.shared.sortedLanguages(chaptersByLanguage, filter: filter)
        if let selectedLanguage, userPickedLanguage, chaptersByLanguage[selectedLanguage] != nil {
            // mantém a escolha do usuário
        } else {
            selectedLanguage = languages.first
        }
    }
}

public struct MangaDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @AppStorage(Preferences.Key.languageFilter) private var filterRaw: String = Preferences.Default.languageFilter.rawValue
    @AppStorage(Preferences.Key.blockAdultTags) private var blockAdult = Preferences.Default.blockAdultTags
    @Query private var libraryMatches: [Manga]
    @Query private var chapterStates: [Chapter]
    @Query(filter: #Predicate<Manga> { $0.isFavorite == true }) private var favorites: [Manga]
    @Query(sort: \MangaCategory.order) private var categories: [MangaCategory]

    @State private var model: WorkDetailModel
    @State private var readingChapter: SourceChapterItem?
    @State private var showAllSynopsis = false
    /// Lista de capítulos de obras fora da biblioteca (das da biblioteca, vem do banco).
    @State private var localFlags = ChapterListFlags.globalDefault
    @State private var selecting = false
    @State private var selected: Set<String> = []

    @State private var showChapterOptions = false
    @State private var showScanlators = false
    @State private var showSources = false
    @State private var showNotes = false
    @State private var showCover = false
    @State private var categoryTargets: [Manga] = []
    @State private var confirmRemoval = false
    @State private var duplicate: Manga?
    @State private var searchQuery: SearchRequest?
    @State private var downloadVersion = 0
    @State private var webTarget: WebTarget?
    @State private var showTracking = false

    private let mangaId: String

    public init(work: UnifiedWork) {
        _model = State(initialValue: WorkDetailModel(work: work))
        mangaId = work.id
        let refIds = work.refs.map(\.id)
        _libraryMatches = Query(filter: #Predicate<Manga> { refIds.contains($0.id) })
        _chapterStates = Query(filter: #Predicate<Chapter> { refIds.contains($0.mangaId) })
    }

    /// Abre uma obra a partir de uma única fonte (ex.: histórico).
    public init(sourceId: String, remoteUrl: String, title: String, coverUrl: String?) {
        let ref = WorkSourceRef(
            sourceId: sourceId,
            sourceName: SourceManager.shared.sourceName(id: sourceId),
            remoteUrl: remoteUrl,
            title: title,
            coverUrl: coverUrl,
            languages: []
        )
        self.init(work: UnifiedWork(ref: ref))
    }

    private var filter: LanguageFilter { LanguageFilter(rawValue: filterRaw) ?? .portuguese }
    private var localManga: Manga? { libraryMatches.first }
    private var isFavorited: Bool { localManga?.isFavorite ?? false }
    /// Id usado para progresso de leitura: o da biblioteca (se já salva) ou o da obra.
    private var progressId: String { localManga?.id ?? mangaId }

    private var progress: ChapterProgress {
        ChapterProgress(records: chapterStates, mangaId: progressId)
    }

    private var flags: ChapterListFlags {
        get { localManga.map { ChapterListFlags(rawValue: $0.chapterFlags) } ?? localFlags }
        nonmutating set {
            if let localManga {
                localManga.chapterFlags = newValue.rawValue
                try? modelContext.save()
            } else {
                localFlags = newValue
            }
        }
    }

    private var flagsBinding: Binding<ChapterListFlags> {
        Binding(get: { flags }, set: { flags = $0 })
    }

    /// Capa escolhida pelo usuário, se houver.
    private var coverUrl: String? {
        CustomCoverStore.url(for: localManga?.customCoverPath)?.absoluteString ?? model.coverUrl
    }

    /// Capítulos como aparecem na tela (filtros e ordem do usuário).
    private var visibleChapters: [SourceChapterItem] {
        _ = downloadVersion
        let progress = progress
        return flags.apply(
            model.chapters,
            isRead: progress.isRead,
            isBookmarked: progress.isBookmarked,
            isDownloaded: { DownloadStore.shared.isDownloaded($0, mangaId: progressId) }
        )
    }

    public var body: some View {
        List {
            if blockAdult && model.isAdult {
                blockedNotice
                    .listRowSeparator(.hidden)
            } else {
                Group {
                    header
                    genresRow
                    synopsis
                    notesRow
                    blockedBanner
                    languageSection
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                chapterSection
            }
        }
        .listStyle(.plain)
        .navigationTitle(model.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable {
            await model.reload()
            syncLibrary()
        }
        .fullScreenCover(item: $readingChapter) { chapter in
            let list = model.chapters
            ReaderView(
                mangaId: progressId,
                mangaTitle: model.displayTitle,
                chapters: list,
                initialChapterIndex: list.firstIndex(where: { $0.id == chapter.id }) ?? 0,
                coverUrl: coverUrl
            )
        }
        .sheet(isPresented: $showTracking) {
            TrackingSheet(mangaId: progressId, title: model.displayTitle)
        }
        .sheet(item: $webTarget) { target in
            SourceWebView(title: target.title, url: target.url) {
                Task { await model.reload() }
            }
        }
        .sheet(isPresented: $showChapterOptions) {
            ChapterOptionsSheet(flags: flagsBinding)
        }
        .sheet(isPresented: $showScanlators) {
            ScanlatorFilterSheet(
                scanlators: model.allScanlators,
                sourceIds: model.chapterSourceIds,
                excluded: Binding(get: { model.excluded }, set: { setExcluded($0) }),
                preferredSourceId: Binding(get: { model.preferredSourceId }, set: { setPreferredSource($0) }),
                canSave: localManga != nil
            )
        }
        .sheet(isPresented: $showSources) {
            ManageSourcesSheet(model: model, onChange: { syncLibrary(force: true) }, onCoverChange: { ref in useCover(of: ref) })
        }
        .sheet(isPresented: $showNotes) {
            if let localManga { NotesEditorSheet(manga: localManga) }
        }
        .sheet(isPresented: $showCover) {
            CoverSheet(
                coverUrl: coverUrl,
                referer: model.coverReferer,
                manga: localManga
            )
        }
        .sheet(isPresented: Binding(get: { !categoryTargets.isEmpty }, set: { if !$0 { categoryTargets = [] } })) {
            CategoryPickerSheet(mangas: categoryTargets)
        }
        .navigationDestination(item: $searchQuery) { request in
            SearchResultsView(query: request.query)
        }
        .confirmationDialog("Remover da biblioteca?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remover", role: .destructive) {
                if let localManga { LibraryActions.removeFromLibrary(localManga, context: modelContext) }
                try? modelContext.save()
            }
        } message: {
            Text("O progresso de leitura continua salvo.")
        }
        .confirmationDialog(
            "Parece que esta obra já está na biblioteca",
            isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }),
            titleVisibility: .visible
        ) {
            if let duplicate {
                Button("Unificar com “\(duplicate.title)”") { unify(into: duplicate) }
            }
            Button("Adicionar mesmo assim") { addToLibrary() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Unificar junta as fontes desta obra à que já está salva.")
        }
        .task {
            if let localManga {
                model.excluded = Set(localManga.excludedScanlators)
                model.preferredSourceId = localManga.preferredSourceId
            }
            await model.load(filter: filter, savedLanguage: localManga?.preferredLanguage)
            syncLibrary()
        }
        .onChange(of: model.selectedLanguage) { _, newValue in
            if let local = localManga, let newValue, local.preferredLanguage != newValue {
                local.preferredLanguage = newValue
                ChapterStore.refreshUnreadCount(manga: local, context: modelContext)
                try? modelContext.save()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadsChanged)) { _ in downloadVersion += 1 }
    }

    // MARK: - Barra

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button("OK") {
                    selecting = false
                    selected = []
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { applyToSelection { ChapterStore.setRead(true, chapter: $0, mangaId: progressId, context: modelContext) } } label: {
                    Image(systemName: "checkmark.circle")
                }
                .accessibilityLabel("Marcar como lidos")
                Spacer()
                Button {
                    let chosen = model.chapters.filter { selected.contains($0.id) }
                    DownloadManager.shared.enqueue(chosen, mangaId: progressId, mangaTitle: model.displayTitle)
                    selected = []
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .accessibilityLabel("Baixar")
                Spacer()
                Button {
                    DownloadManager.shared.delete(model.chapters.filter { selected.contains($0.id) }, mangaId: progressId)
                    selected = []
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Apagar downloads")
                Spacer()
                Button { applyToSelection { ChapterStore.setRead(false, chapter: $0, mangaId: progressId, context: modelContext) } } label: {
                    Image(systemName: "circle")
                }
                .accessibilityLabel("Marcar como não lidos")
                Spacer()
                Button { applyToSelection { ChapterStore.setBookmarked(true, chapter: $0, mangaId: progressId, context: modelContext) } } label: {
                    Image(systemName: "bookmark")
                }
                .accessibilityLabel("Marcar")
                Spacer()
                Button {
                    if let last = model.chapters.last(where: { selected.contains($0.id) }) {
                        ChapterStore.markPreviousRead(before: last, in: model.chapters, mangaId: progressId, context: modelContext)
                    }
                    selected = []
                } label: {
                    Image(systemName: "text.badge.checkmark")
                }
                .accessibilityLabel("Marcar anteriores como lidos")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Próximo capítulo") { download(.next(1)) }
                    Button("Próximos 5") { download(.next(5)) }
                    Button("Próximos 10") { download(.next(10)) }
                    Button("Não lidos") { download(.unread) }
                    Button("Marcados") { download(.bookmarked) }
                    Button("Todos") { download(.all) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .accessibilityLabel("Baixar capítulos")
                .disabled(model.chapters.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let url = webURL {
                        ShareLink(item: url) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                        Button { openURL(url) } label: { Label("Abrir no navegador", systemImage: "safari") }
                    }
                    if isFavorited, let localManga {
                        Button { categoryTargets = [localManga] } label: { Label("Editar categorias", systemImage: "folder") }
                        Button { showNotes = true } label: { Label("Notas", systemImage: "note.text") }
                    }
                    Button { showTracking = true } label: { Label("Rastreamento", systemImage: "chart.line.uptrend.xyaxis") }
                    Button { showSources = true } label: { Label("Fontes desta obra", systemImage: "square.stack") }
                    Button { showScanlators = true } label: { Label("Scans e fonte preferida", systemImage: "person.2") }
                    Button { if !model.chapters.isEmpty { selecting = true } } label: { Label("Selecionar capítulos", systemImage: "checkmark.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var webURL: URL? {
        guard let ref = model.work.refs.first, let source = SourceManager.shared.getSource(id: ref.sourceId) else { return nil }
        if ref.remoteUrl.hasPrefix("http") { return URL(string: ref.remoteUrl) }
        return URL(string: source.baseUrl + (ref.remoteUrl.hasPrefix("/") ? "" : "/") + ref.remoteUrl)
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Button { showCover = true } label: {
                AsyncMangaCover(urlString: coverUrl, cornerRadius: 10, referer: localManga?.customCoverPath == nil ? model.coverReferer : nil)
                    .frame(width: 110, height: 165)
                    .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ver capa")

            VStack(alignment: .leading, spacing: 6) {
                Text(model.displayTitle)
                    .font(.headline)
                    .fontWeight(.bold)
                    .lineLimit(3)
                    .contextMenu {
                        Button { UIPasteboard.general.string = model.displayTitle } label: { Label("Copiar título", systemImage: "doc.on.doc") }
                        Button { searchQuery = SearchRequest(query: model.displayTitle) } label: { Label("Buscar em todas as fontes", systemImage: "magnifyingglass") }
                    }

                if let author = model.detail?.author, !author.isEmpty {
                    Button { searchQuery = SearchRequest(query: author) } label: {
                        Text("Autor: \(author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }

                if let artist = model.detail?.artist, !artist.isEmpty, artist != model.detail?.author {
                    Button { searchQuery = SearchRequest(query: artist) } label: {
                        Text("Artista: \(artist)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    BadgeView(statusText, color: statusColor)
                    BadgeView(model.work.refs.count == 1 ? model.work.refs[0].sourceName : "\(model.work.refs.count) fontes", color: .purple)
                }
                .padding(.top, 4)

                Spacer(minLength: 4)

                Button {
                    toggleFavorite()
                } label: {
                    Label(isFavorited ? "Na Biblioteca" : "Adicionar", systemImage: isFavorited ? "heart.fill" : "heart")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isFavorited ? .pink : .blue)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
    }

    private var statusText: String {
        switch model.detail?.status ?? 0 {
        case 1: return "Em lançamento"
        case 2: return "Completo"
        case 3: return "Cancelado"
        case 4: return "Em hiato"
        default: return "Status desconhecido"
        }
    }

    private var statusColor: Color {
        switch model.detail?.status ?? 0 {
        case 1: return .blue
        case 2: return .green
        case 3: return .red
        case 4: return .orange
        default: return .secondary
        }
    }

    /// Obra com tag adulta enquanto o filtro está ligado em Ajustes.
    private var blockedNotice: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Obra bloqueada")
                .font(.headline)
            Text("Uma das fontes marca esta obra com a tag Adulto/Adult. Para vê-la, desligue “Bloquear obras com tag adulta” em Ajustes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 80)
    }

    @ViewBuilder
    private var genresRow: some View {
        if let genres = model.detail?.genres, !genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(genres, id: \.self) { genre in
                        Button { searchQuery = SearchRequest(query: genre) } label: {
                            BadgeView(genre, color: .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var synopsis: some View {
        if let desc = model.detail?.description, !desc.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sinopse")
                    .font(.subheadline.bold())
                Text(Self.markdown(desc))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(showAllSynopsis ? nil : 6)
                    .onTapGesture { withAnimation { showAllSynopsis.toggle() } }
            }
            .padding(.horizontal)
        }
    }

    /// Sinopse em Markdown quando der; senão, texto puro.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    @ViewBuilder
    private var notesRow: some View {
        if let notes = localManga?.notes, !notes.isEmpty {
            Button { showNotes = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Notas", systemImage: "note.text")
                        .font(.subheadline.bold())
                    Text(Self.markdown(notes))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
    }

    // MARK: - Idiomas

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.horizontal)
            HStack {
                Text("Idioma dos capítulos")
                    .font(.headline)
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal)

            if model.languages.isEmpty {
                if !model.isLoading && model.hasLoaded {
                    Text("Nenhum capítulo disponível nas fontes desta obra.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.languages, id: \.self) { language in
                            languageChip(language)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            if !model.work.refs.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.work.refs) { ref in
                            HStack {
                                Text(ref.sourceName)
                                    .font(.caption)
                                Spacer()
                                Text(sourceLanguageLabel(ref))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(model.failures, id: \.self) { failure in
                            Text(failure)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Encontrada em \(model.work.refs.count) \(model.work.refs.count == 1 ? "fonte" : "fontes")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
        }
    }

    private func languageChip(_ language: String) -> some View {
        let selected = model.selectedLanguage == language
        let count = model.chaptersByLanguage[language]?.count ?? 0
        return Button {
            withAnimation(.snappy) { model.pickLanguage(language) }
        } label: {
            HStack(spacing: 4) {
                Text(LanguageCode.displayName(language))
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(LanguageCode.displayName(language)), \(count) capítulos")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sourceLanguageLabel(_ ref: WorkSourceRef) -> String {
        guard let source = SourceManager.shared.getSource(id: ref.sourceId) else { return "" }
        return source.language == "all" ? "Vários idiomas" : LanguageCode.displayName(source.language)
    }

    // MARK: - Capítulos

    @ViewBuilder
    private var chapterSection: some View {
        let chapters = visibleChapters
        let progress = progress
        let flags = flags
        let totalMissing = flags.hideMissing ? 0 : missingTotal(model.chapters)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Capítulos (\(chapters.count))")
                    .font(.headline)
                Spacer()
                Button {
                    showChapterOptions = true
                } label: {
                    Image(systemName: flags.hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Filtrar e ordenar capítulos")
            }
            if let next = nextChapterToRead(model.chapters, progress: progress) {
                Button {
                    readingChapter = next
                } label: {
                    Label(continueTitle(next, progress: progress), systemImage: "play.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            if totalMissing > 0 {
                Label("\(totalMissing) \(totalMissing == 1 ? "capítulo faltando" : "capítulos faltando") na numeração", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

        if chapters.isEmpty {
            Group {
                if model.isLoading && model.chapters.isEmpty {
                    ProgressView("Carregando capítulos de \(model.work.refs.count) fontes…")
                        .frame(maxWidth: .infinity)
                        .padding()
                } else if model.hasLoaded {
                    VStack(spacing: 8) {
                        Text(emptyChaptersText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if model.chapters.isEmpty {
                            Button("Tentar novamente") {
                                Task { await model.reload() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }
            .listRowSeparator(.hidden)
        } else {
            ForEach(Array(chapters.enumerated()), id: \.element.id) { offset, ch in
                chapterRow(ch, progress: progress, flags: flags)
                if !flags.hideMissing, flags.sort == .number, offset + 1 < chapters.count {
                    let gap = ChapterGaps.missing(between: ch.chapterNumber, and: chapters[offset + 1].chapterNumber)
                    if gap > 0 {
                        Text("— \(gap) \(gap == 1 ? "capítulo faltando" : "capítulos faltando") —")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
    }

    private var emptyChaptersText: String {
        if !model.chapters.isEmpty { return "Nenhum capítulo com os filtros atuais." }
        return model.failures.isEmpty ? "Sem capítulos neste idioma." : "Não foi possível carregar os capítulos."
    }

    private func chapterRow(_ ch: SourceChapterItem, progress: ChapterProgress, flags: ChapterListFlags) -> some View {
        let isRead = progress.isRead(ch)
        let isBookmarked = progress.isBookmarked(ch)
        return Button {
            if selecting {
                if selected.contains(ch.id) { selected.remove(ch.id) } else { selected.insert(ch.id) }
            } else {
                readingChapter = ch
            }
        } label: {
            HStack(spacing: 10) {
                if selecting {
                    Image(systemName: selected.contains(ch.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(ch.id) ? Color.accentColor : .secondary)
                }
                ChapterRowView(
                    title: flags.displayName(ch),
                    scanlator: chapterSubtitle(ch, pageInProgress: progress.pageInProgress(ch)),
                    isRead: isRead,
                    isBookmarked: isBookmarked,
                    onToggleRead: {
                        ChapterStore.setRead(!isRead, chapter: ch, mangaId: progressId, context: modelContext)
                    },
                    onToggleBookmark: {
                        ChapterStore.setBookmarked(!isBookmarked, chapter: ch, mangaId: progressId, context: modelContext)
                    }
                )
                .download(DownloadManager.shared.state(of: ch, mangaId: progressId)) { toggleDownload(ch) }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) { swipeButton(ChapterSwipeAction.leading, ch, isRead: isRead, isBookmarked: isBookmarked) }
        .swipeActions(edge: .trailing) { swipeButton(ChapterSwipeAction.trailing, ch, isRead: isRead, isBookmarked: isBookmarked) }
        .contextMenu {
            Button { ChapterStore.setRead(!isRead, chapter: ch, mangaId: progressId, context: modelContext) } label: {
                Label(isRead ? "Marcar como não lido" : "Marcar como lido", systemImage: isRead ? "circle" : "checkmark.circle")
            }
            Button { ChapterStore.markPreviousRead(before: ch, in: model.chapters, mangaId: progressId, context: modelContext) } label: {
                Label("Marcar anteriores como lidos", systemImage: "text.badge.checkmark")
            }
            Button { ChapterStore.setBookmarked(!isBookmarked, chapter: ch, mangaId: progressId, context: modelContext) } label: {
                Label(isBookmarked ? "Tirar marcador" : "Marcar", systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
            }
            downloadMenuButton(ch)
        }
    }

    @ViewBuilder
    private func downloadMenuButton(_ ch: SourceChapterItem) -> some View {
        switch DownloadManager.shared.state(of: ch, mangaId: progressId) {
        case .downloaded:
            Button(role: .destructive) { toggleDownload(ch) } label: { Label("Apagar download", systemImage: "trash") }
        case .queued, .downloading:
            Button { toggleDownload(ch) } label: { Label("Cancelar download", systemImage: "xmark.circle") }
        case .none, .failed:
            Button { toggleDownload(ch) } label: { Label("Baixar", systemImage: "arrow.down.circle") }
        }
    }

    /// Baixa, cancela, tenta de novo ou apaga, conforme o estado.
    private func toggleDownload(_ ch: SourceChapterItem) {
        let manager = DownloadManager.shared
        switch manager.state(of: ch, mangaId: progressId) {
        case .none:
            manager.enqueue([ch], mangaId: progressId, mangaTitle: model.displayTitle)
        case .failed:
            manager.delete([ch], mangaId: progressId)
            manager.enqueue([ch], mangaId: progressId, mangaTitle: model.displayTitle)
        case .queued, .downloading, .downloaded:
            manager.delete([ch], mangaId: progressId)
        }
    }

    private enum DownloadChoice { case next(Int), unread, all, bookmarked }

    private func download(_ choice: DownloadChoice) {
        let progress = progress
        // A lista vai do mais novo para o mais antigo; "próximos" segue a ordem de leitura.
        let oldestFirst = Array(model.chapters.reversed())
        let chapters: [SourceChapterItem]
        switch choice {
        case .next(let count): chapters = Array(oldestFirst.filter { !progress.isRead($0) }.prefix(count))
        case .unread: chapters = oldestFirst.filter { !progress.isRead($0) }
        case .all: chapters = oldestFirst
        case .bookmarked: chapters = oldestFirst.filter { progress.isBookmarked($0) }
        }
        DownloadManager.shared.enqueue(chapters, mangaId: progressId, mangaTitle: model.displayTitle)
    }

    @ViewBuilder
    private func swipeButton(_ action: ChapterSwipeAction, _ ch: SourceChapterItem, isRead: Bool, isBookmarked: Bool) -> some View {
        switch action {
        case .toggleRead:
            Button { ChapterStore.setRead(!isRead, chapter: ch, mangaId: progressId, context: modelContext) } label: {
                Label(isRead ? "Não lido" : "Lido", systemImage: isRead ? "circle" : "checkmark.circle")
            }
            .tint(.blue)
        case .toggleBookmark:
            Button { ChapterStore.setBookmarked(!isBookmarked, chapter: ch, mangaId: progressId, context: modelContext) } label: {
                Label("Marcador", systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
            }
            .tint(.yellow)
        case .markPreviousRead:
            Button { ChapterStore.markPreviousRead(before: ch, in: model.chapters, mangaId: progressId, context: modelContext) } label: {
                Label("Anteriores", systemImage: "text.badge.checkmark")
            }
            .tint(.indigo)
        case .download:
            let downloaded = DownloadManager.shared.state(of: ch, mangaId: progressId) != .none
            Button { toggleDownload(ch) } label: {
                Label(downloaded ? "Apagar" : "Baixar", systemImage: downloaded ? "trash" : "arrow.down.circle")
            }
            .tint(downloaded ? .red : .green)
        case .disabled:
            EmptyView()
        }
    }

    private func applyToSelection(_ action: (SourceChapterItem) -> Void) {
        for chapter in model.chapters where selected.contains(chapter.id) { action(chapter) }
        selected = []
    }

    private func chapterSubtitle(_ ch: SourceChapterItem, pageInProgress: Int?) -> String {
        var parts: [String] = []
        if let pageInProgress { parts.append("Página \(pageInProgress)") }
        if let scan = ch.scanlator, !scan.isEmpty { parts.append(scan) }
        if model.work.refs.count > 1 { parts.append(SourceManager.shared.sourceName(id: ch.sourceId)) }
        if let date = ch.uploadDate { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " • ")
    }

    /// Primeiro capítulo não lido em ordem de leitura (lista está do mais novo para o mais antigo).
    private func nextChapterToRead(_ chapters: [SourceChapterItem], progress: ChapterProgress) -> SourceChapterItem? {
        // Um capítulo começado e não terminado vem antes.
        if let started = chapters.last(where: { progress.pageInProgress($0) != nil }) { return started }
        return chapters.last(where: { !progress.isRead($0) })
    }

    private func continueTitle(_ chapter: SourceChapterItem, progress: ChapterProgress) -> String {
        let name = flags.displayName(chapter)
        guard progress.hasAnyRead || progress.pageInProgress(chapter) != nil else { return "Começar: \(name)" }
        if let page = progress.pageInProgress(chapter) { return "Continuar \(name) · pág. \(page)" }
        return "Continuar \(name)"
    }

    private func missingTotal(_ chapters: [SourceChapterItem]) -> Int {
        let numbers = Array(Set(chapters.map(\.chapterNumber).filter { $0 > 0 }.map(floor))).sorted()
        return zip(numbers, numbers.dropFirst()).reduce(0) { $0 + ChapterGaps.missing(between: $1.0, and: $1.1) }
    }

    /// Fontes que pediram a verificação do Cloudflare: o usuário resolve na WebView.
    @ViewBuilder
    private var blockedBanner: some View {
        ForEach(model.blockedRefs, id: \.id) { ref in
            if let source = SourceManager.shared.getSource(id: ref.sourceId), let url = URL(string: source.baseUrl) {
                Button {
                    webTarget = WebTarget(title: source.name, url: url)
                } label: {
                    Label("\(source.name) pediu uma verificação anti-bot. Toque para resolver.", systemImage: "shield.lefthalf.filled")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Biblioteca

    private func toggleFavorite() {
        if isFavorited {
            confirmRemoval = true
            return
        }
        // Já existe na biblioteca com outro id (outra fonte)? Oferece unificar.
        let keys = model.work.titleKeys.union(TitleKey.keys(for: [model.displayTitle]))
        if localManga == nil, let match = favorites.first(where: { manga in
            !TitleKey.keys(for: [manga.title] + UnifiedWork.refs(fromJSON: manga.sourcesJSON).map(\.title)).isDisjoint(with: keys)
        }) {
            duplicate = match
            return
        }
        addToLibrary()
    }

    private func addToLibrary() {
        let manga: Manga
        if let existing = localManga {
            manga = existing
            existing.isFavorite = true
            existing.favoriteAt = Date()
            existing.sourcesJSON = model.work.refsJSON
        } else {
            let ref = model.work.refs[0]
            let newManga = Manga(
                sourceId: ref.sourceId,
                remoteUrl: ref.remoteUrl,
                title: model.displayTitle,
                author: model.detail?.author,
                artist: model.detail?.artist,
                desc: model.detail?.description,
                genres: model.detail?.genres ?? [],
                status: model.detail?.status ?? 0,
                coverUrl: model.coverUrl,
                isFavorite: true
            )
            newManga.sourcesJSON = model.work.refsJSON
            newManga.preferredLanguage = model.selectedLanguage
            newManga.excludedScanlators = Array(model.excluded)
            newManga.preferredSourceId = model.preferredSourceId
            newManga.chapterFlags = localFlags.rawValue
            modelContext.insert(newManga)
            manga = newManga
        }
        let ask = LibraryActions.applyDefaultCategory(to: manga, categories: categories)
        try? modelContext.save()
        saveChapterList(of: manga)
        if ask { categoryTargets = [manga] }
    }

    /// Junta as fontes desta obra à que já está na biblioteca.
    private func unify(into existing: Manga) {
        var refs = UnifiedWork.refs(fromJSON: existing.sourcesJSON)
        for ref in model.work.refs where !refs.contains(where: { $0.id == ref.id }) { refs.append(ref) }
        existing.sourcesJSON = (try? JSONEncoder().encode(refs)).flatMap { String(data: $0, encoding: .utf8) }
        try? modelContext.save()
    }

    /// Atualiza a obra salva com as fontes/idiomas descobertos.
    private func syncLibrary(force: Bool = false) {
        guard let local = localManga else { return }
        if let detail = model.detail {
            local.desc = detail.description ?? local.desc
            local.status = detail.status
            if !detail.genres.isEmpty { local.genres = detail.genres }
            if local.author == nil { local.author = detail.author }
            if local.artist == nil { local.artist = detail.artist }
        } else if !force {
            return
        }
        if local.coverUrl == nil { local.coverUrl = model.coverUrl }
        local.sourcesJSON = model.work.refsJSON
        try? modelContext.save()
        saveChapterList(of: local)
    }

    /// Obras da biblioteca guardam a lista de capítulos (base para não lidos e novidades).
    private func saveChapterList(of manga: Manga) {
        guard manga.isFavorite, !model.isLoading, !model.chaptersByLanguage.isEmpty else { return }
        ChapterStore.sync(model.chaptersByLanguage, manga: manga, context: modelContext)
    }

    private func setExcluded(_ value: Set<String>) {
        model.excluded = value
        localManga?.excludedScanlators = value.sorted()
        try? modelContext.save()
    }

    private func setPreferredSource(_ value: String?) {
        model.preferredSourceId = value
        localManga?.preferredSourceId = value
        try? modelContext.save()
    }

    private func useCover(of ref: WorkSourceRef) {
        model.useCover(of: ref)
        if let localManga {
            localManga.coverUrl = ref.coverUrl
            CustomCoverStore.remove(localManga.customCoverPath)
            localManga.customCoverPath = nil
            try? modelContext.save()
        }
    }
}

/// Busca aberta a partir de gênero, autor ou título.
struct SearchRequest: Hashable, Identifiable {
    let query: String
    var id: String { query }
}

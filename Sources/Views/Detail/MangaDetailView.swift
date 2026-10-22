import SwiftUI
import SwiftData

/// Estado da tela de detalhe: carrega a obra pelo `WorkLoader` e cuida da escolha do idioma.
@MainActor
@Observable
final class WorkDetailModel {
    private(set) var work: UnifiedWork
    private(set) var detail: SourceMangaDetail?
    private(set) var chaptersByLanguage: [String: [SourceChapterItem]] = [:]
    private(set) var languages: [String] = []
    private(set) var pendingSources = 0
    private(set) var failures: [String] = []
    private(set) var hasLoaded = false
    /// Alguma fonte marcou a obra como conteúdo adulto.
    private(set) var isAdult = false
    var selectedLanguage: String?

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
        chaptersByLanguage = [:]
        languages = []
        await load(filter: filter, savedLanguage: userPickedLanguage ? selectedLanguage : savedLanguage)
    }

    private func apply(_ loader: WorkLoader) {
        let state = loader.state
        pendingSources = loader.pendingSources
        work = state.work
        failures = state.failures
        chaptersByLanguage = state.chaptersByLanguage
        languages = SourceAggregator.shared.sortedLanguages(chaptersByLanguage, filter: filter)

        if let selectedLanguage, userPickedLanguage, chaptersByLanguage[selectedLanguage] != nil {
            // mantém a escolha do usuário
        } else {
            selectedLanguage = languages.first
        }

        if let merged = state.mergedDetail(filter: filter) {
            detail = merged
            isAdult = state.isAdult
        }
    }
}

public struct MangaDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Preferences.Key.languageFilter) private var filterRaw: String = Preferences.Default.languageFilter.rawValue
    @AppStorage(Preferences.Key.blockAdultTags) private var blockAdult = Preferences.Default.blockAdultTags
    @Query private var libraryMatches: [Manga]
    @Query private var chapterStates: [Chapter]

    @State private var model: WorkDetailModel
    @State private var readingChapter: SourceChapterItem?
    @State private var showAllSynopsis = false

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

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if blockAdult && model.isAdult {
                    blockedNotice
                } else {
                    header
                    genresRow
                    synopsis
                    Divider().padding(.horizontal)
                    languageSection
                    chapterList
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(model.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
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
                coverUrl: model.coverUrl
            )
        }
        .task {
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
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncMangaCover(urlString: model.coverUrl, cornerRadius: 10, referer: model.coverReferer)
                .frame(width: 110, height: 165)
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.displayTitle)
                    .font(.headline)
                    .fontWeight(.bold)
                    .lineLimit(3)

                if let author = model.detail?.author, !author.isEmpty {
                    Text("Autor: \(author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let artist = model.detail?.artist, !artist.isEmpty, artist != model.detail?.author {
                    Text("Artista: \(artist)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                        BadgeView(genre, color: .secondary)
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
                Text(desc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(showAllSynopsis ? nil : 6)
                    .onTapGesture { withAnimation { showAllSynopsis.toggle() } }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Idiomas

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
    private var chapterList: some View {
        let chapters = model.chapters
        HStack {
            Text("Capítulos (\(chapters.count))")
                .font(.headline)
            Spacer()
            if let first = nextChapterToRead(chapters) {
                Button(progress.hasAnyRead ? "Continuar" : "Começar") {
                    readingChapter = first
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)

        if chapters.isEmpty {
            if model.isLoading {
                HStack {
                    Spacer()
                    ProgressView("Carregando capítulos de \(model.work.refs.count) fontes…")
                        .padding()
                    Spacer()
                }
            } else if model.hasLoaded {
                VStack(spacing: 8) {
                    Text(model.failures.isEmpty ? "Sem capítulos neste idioma." : "Não foi possível carregar os capítulos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Tentar novamente") {
                        Task { await model.reload() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
        } else {
            let progress = progress
            LazyVStack(spacing: 0) {
                ForEach(chapters) { ch in
                    let isRead = progress.isRead(ch)
                    let isBookmarked = progress.isBookmarked(ch)
                    Button {
                        readingChapter = ch
                    } label: {
                        ChapterRowView(
                            title: ch.name,
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
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)

                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
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
    private func nextChapterToRead(_ chapters: [SourceChapterItem]) -> SourceChapterItem? {
        let progress = progress
        return chapters.last(where: { !progress.isRead($0) })
    }

    // MARK: - Biblioteca

    private func toggleFavorite() {
        let manga: Manga
        if let existing = localManga {
            manga = existing
            existing.isFavorite.toggle()
            existing.favoriteAt = existing.isFavorite ? Date() : nil
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
            modelContext.insert(newManga)
            manga = newManga
        }
        try? modelContext.save()
        saveChapterList(of: manga)
    }

    /// Atualiza a obra salva com as fontes/idiomas descobertos.
    private func syncLibrary() {
        guard let local = localManga, let detail = model.detail else { return }
        local.desc = detail.description ?? local.desc
        local.status = detail.status
        if !detail.genres.isEmpty { local.genres = detail.genres }
        if local.coverUrl == nil { local.coverUrl = model.coverUrl }
        local.sourcesJSON = model.work.refsJSON
        local.lastUpdated = Date()
        try? modelContext.save()
        saveChapterList(of: local)
    }

    /// Obras da biblioteca guardam a lista de capítulos (base para não lidos e novidades).
    private func saveChapterList(of manga: Manga) {
        guard manga.isFavorite, !model.isLoading, !model.chaptersByLanguage.isEmpty else { return }
        ChapterStore.sync(model.chaptersByLanguage, manga: manga, context: modelContext)
    }
}

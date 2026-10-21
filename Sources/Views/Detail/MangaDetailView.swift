import SwiftUI
import SwiftData

/// Carrega uma obra unificada em todas as fontes onde ela existe e agrupa os capítulos por idioma.
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

    private var allChapters: [SourceChapterItem] = []
    private struct LoadedDetail {
        let language: String
        let detail: SourceMangaDetail
    }
    private var details: [LoadedDetail] = []
    private var loadedRefIds = Set<String>()
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

        // Todas as fontes da obra entram, para unificar todos os capítulos de cada idioma.
        // As do idioma do filtro vêm primeiro; no máximo 6 requisições simultâneas
        let refs = work.refs.sorted { a, b in
            let la = SourceManager.shared.getSource(id: a.sourceId)?.language ?? "all"
            let lb = SourceManager.shared.getSource(id: b.sourceId)?.language ?? "all"
            return (filter.matches(la) ? 0 : 1) < (filter.matches(lb) ? 0 : 1)
        }
        await withTaskGroup(of: Void.self) { group in
            var pending = refs.makeIterator()
            // Procura a mesma obra nas fontes multi-idioma para listar todos os idiomas disponíveis
            group.addTask { await self.lookupMultiLanguage(sourceId: "mangadex") }
            group.addTask { await self.lookupMultiLanguage(sourceId: "comick") }
            for _ in 0..<6 {
                guard let ref = pending.next() else { break }
                group.addTask { await self.loadRef(ref) }
            }
            while await group.next() != nil {
                if let ref = pending.next() {
                    group.addTask { await self.loadRef(ref) }
                }
            }
        }
    }

    func reload() async {
        hasLoaded = false
        allChapters = []
        details = []
        loadedRefIds = []
        failures = []
        chaptersByLanguage = [:]
        languages = []
        await load(filter: filter, savedLanguage: userPickedLanguage ? selectedLanguage : savedLanguage)
    }

    private func loadRef(_ ref: WorkSourceRef) async {
        guard loadedRefIds.insert(ref.id).inserted else { return }
        guard let source = SourceManager.shared.getSource(id: ref.sourceId) else {
            failures.append("\(ref.sourceName): fonte indisponível")
            return
        }
        pendingSources += 1
        defer { pendingSources -= 1 }
        do {
            let (sourceDetail, chapters) = try await source.fetchDetails(remoteUrl: ref.remoteUrl)
            let fallbackLanguage = source.language == "all" ? nil : source.language
            let normalized = chapters.map { item -> SourceChapterItem in
                var c = item
                if c.sourceId.isEmpty { c.sourceId = ref.sourceId }
                if c.mangaRemoteUrl.isEmpty { c.mangaRemoteUrl = ref.remoteUrl }
                if c.language == nil { c.language = fallbackLanguage }
                return c
            }
            allChapters += normalized
            work.addLanguages(Array(Set(normalized.compactMap(\.language))).sorted())
            details.append(LoadedDetail(language: source.language, detail: sourceDetail))
            if work.coverUrl == nil, let cover = sourceDetail.coverUrl {
                work.coverUrl = cover
                work.coverSourceId = ref.sourceId
            }
            recompute()
        } catch {
            failures.append("\(ref.sourceName): \(error.localizedDescription)")
        }
    }

    /// Busca a obra pelo título numa fonte multi-idioma e só aceita se algum título coincidir.
    private func lookupMultiLanguage(sourceId: String) async {
        guard !work.refs.contains(where: { $0.sourceId == sourceId }),
              let source = SourceManager.shared.getSource(id: sourceId) else { return }
        let candidates = [work.title] + work.refs.map(\.title)
        var seenQueries = Set<String>()
        for query in candidates where seenQueries.insert(TitleKey.normalize(query)).inserted {
            guard query.count >= 3, let page = try? await source.search(query: query, page: 1) else { continue }
            if let match = page.items.first(where: { !TitleKey.keys(for: [$0.title] + $0.altTitles).isDisjoint(with: work.titleKeys) }) {
                let ref = WorkSourceRef(
                    sourceId: match.sourceId,
                    sourceName: source.name,
                    remoteUrl: match.remoteUrl,
                    title: match.title,
                    coverUrl: match.coverUrl,
                    languages: match.languages
                )
                work.merge(ref: ref, altTitles: match.altTitles)
                await loadRef(ref)
                return
            }
            if seenQueries.count >= 2 { return }
        }
    }

    private func recompute() {
        chaptersByLanguage = SourceAggregator.shared.chaptersByLanguage(allChapters)
        languages = SourceAggregator.shared.sortedLanguages(chaptersByLanguage, filter: filter)

        if let selectedLanguage, userPickedLanguage, chaptersByLanguage[selectedLanguage] != nil {
            // mantém a escolha do usuário
        } else {
            selectedLanguage = languages.first
        }

        // Detalhes: prefere a fonte no idioma do filtro e com sinopse
        let ranked = details.sorted { a, b in
            let la = filter.matches(a.language) || a.language == "all" ? 0 : 1
            let lb = filter.matches(b.language) || b.language == "all" ? 0 : 1
            if la != lb { return la < lb }
            let da = (a.detail.description?.isEmpty ?? true) ? 1 : 0
            let db = (b.detail.description?.isEmpty ?? true) ? 1 : 0
            return da < db
        }
        guard let best = ranked.first?.detail else { return }
        var genres: [String] = []
        for entry in ranked {
            for genre in entry.detail.genres where !genres.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) {
                genres.append(genre)
            }
        }
        isAdult = work.isAdult || ContentFilter.isAdult(genres: genres)
        detail = SourceMangaDetail(
            remoteUrl: best.remoteUrl,
            title: best.title,
            author: ranked.lazy.compactMap(\.detail.author).first(where: { !$0.isEmpty }),
            artist: ranked.lazy.compactMap(\.detail.artist).first(where: { !$0.isEmpty }),
            description: ranked.lazy.compactMap(\.detail.description).first(where: { !$0.isEmpty }),
            genres: Array(genres.prefix(15)),
            status: ranked.first(where: { $0.detail.status != 0 })?.detail.status ?? 0,
            coverUrl: best.coverUrl
        )
    }
}

/// Marca capítulos como lidos (registro `Chapter` do SwiftData).
enum ReadTracker {
    @MainActor
    static func setRead(_ read: Bool, chapter: SourceChapterItem, mangaId: String, context: ModelContext) {
        let id = Chapter.storageId(mangaId: mangaId, sourceId: chapter.sourceId, remoteUrl: chapter.remoteUrl)
        var descriptor = FetchDescriptor<Chapter>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let record: Chapter
        if let existing = try? context.fetch(descriptor).first {
            record = existing
        } else {
            record = Chapter(
                mangaId: mangaId,
                remoteUrl: chapter.remoteUrl,
                name: chapter.name,
                chapterNumber: chapter.chapterNumber,
                orderIndex: chapter.orderIndex,
                scanlator: chapter.scanlator,
                uploadDate: chapter.uploadDate,
                sourceId: chapter.sourceId,
                language: chapter.language
            )
            context.insert(record)
        }
        record.isRead = read
        record.lastReadDate = read ? Date() : record.lastReadDate
        try? context.save()
    }
}

public struct MangaDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(LanguageFilter.storageKey) private var filterRaw: String = LanguageFilter.portuguese.rawValue
    @AppStorage(ContentFilter.blockAdultKey) private var blockAdult = true
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

    private var readIds: Set<String> {
        Set(chapterStates.filter(\.isRead).map(\.id))
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
        .refreshable { await model.reload() }
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
                Button(readIds.isEmpty ? "Começar" : "Continuar") {
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
            let read = readIds
            LazyVStack(spacing: 0) {
                ForEach(chapters) { ch in
                    let isRead = read.contains(Chapter.storageId(mangaId: progressId, sourceId: ch.sourceId, remoteUrl: ch.remoteUrl))
                    Button {
                        readingChapter = ch
                    } label: {
                        ChapterRowView(
                            title: ch.name,
                            scanlator: chapterSubtitle(ch),
                            isRead: isRead,
                            isBookmarked: false,
                            onToggleRead: {
                                ReadTracker.setRead(!isRead, chapter: ch, mangaId: progressId, context: modelContext)
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

    private func chapterSubtitle(_ ch: SourceChapterItem) -> String {
        var parts: [String] = []
        if let scan = ch.scanlator, !scan.isEmpty { parts.append(scan) }
        if model.work.refs.count > 1 { parts.append(SourceManager.shared.sourceName(id: ch.sourceId)) }
        if let date = ch.uploadDate { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " • ")
    }

    /// Primeiro capítulo não lido em ordem de leitura (lista está do mais novo para o mais antigo).
    private func nextChapterToRead(_ chapters: [SourceChapterItem]) -> SourceChapterItem? {
        let read = readIds
        return chapters.last(where: { !read.contains(Chapter.storageId(mangaId: progressId, sourceId: $0.sourceId, remoteUrl: $0.remoteUrl)) })
    }

    // MARK: - Biblioteca

    private func toggleFavorite() {
        if let existing = localManga {
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
        }
        try? modelContext.save()
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
    }
}

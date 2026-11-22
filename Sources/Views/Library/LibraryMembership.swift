import SwiftUI
import SwiftData

/// A tela de detalhes usa um único ID para progresso e downloads.
enum LocalIdentitySafety {
    /// Reutiliza o índice de obras salvas durante a vida do feed.
    final class Gate {
        private let context: ModelContext
        private let mangaIDsByIdentity: [String: Set<String>]?

        init(context: ModelContext) {
            self.context = context
            mangaIDsByIdentity = try? LocalIdentitySafety.mangaIdentityIndex(context: context)
        }

        func decide(_ identities: Set<String>) -> IdentityMergeDecision {
            guard let mangaIDsByIdentity else { return .deny }
            return LocalIdentitySafety.decision(identities, context: context, mangaIDsByIdentity: mangaIDsByIdentity)
        }
    }

    static func decision(_ identities: Set<String>, context: ModelContext, downloads: DownloadStore = .shared) -> IdentityMergeDecision {
        guard let mangaIDsByIdentity = try? mangaIdentityIndex(context: context) else { return .deny }
        return decision(identities, context: context, downloads: downloads, mangaIDsByIdentity: mangaIDsByIdentity)
    }

    private static func decision(
        _ identities: Set<String>,
        context: ModelContext,
        downloads: DownloadStore = .shared,
        mangaIDsByIdentity: [String: Set<String>]
    ) -> IdentityMergeDecision {
        let ids = Array(identities)
        guard !ids.isEmpty else { return .deny }
        do {
            var matchingMangaIDs = Set(identities.flatMap { mangaIDsByIdentity[$0] ?? [] })
            // Captura obras salvas durante a vida do feed sem reler a biblioteca inteira.
            let directlyMatching = try context.fetch(FetchDescriptor<Manga>(predicate: #Predicate { ids.contains($0.id) }))
            matchingMangaIDs.formUnion(directlyMatching.map(\.id))
            guard matchingMangaIDs.count <= 1,
                  matchingMangaIDs.first.map(identities.contains) ?? true else { return .deny }

            // Uma única obra salva pode receber outra fonte; estados independentes não podem ser
            // combinados porque progresso e downloads são indexados pelo ID da obra.
            let chapters = try context.fetch(FetchDescriptor<Chapter>(predicate: #Predicate { ids.contains($0.mangaId) }))
            if chapters.contains(where: { $0.isRead || $0.isBookmarked || $0.lastPageRead > 0 || $0.lastReadDate != nil }) { return .deny }
            if try context.fetchCount(FetchDescriptor<HistoryEntry>(predicate: #Predicate { ids.contains($0.mangaId) })) > 0 { return .deny }
            if try context.fetchCount(FetchDescriptor<TrackRecord>(predicate: #Predicate { ids.contains($0.mangaId) })) > 0 { return .deny }
            if ids.contains(where: { FileManager.default.fileExists(atPath: downloads.mangaDirectory(mangaId: $0).path) }) { return .deny }
            return .allow(preferredID: matchingMangaIDs.first)
        } catch {
            // Falha ao consultar dados não deve permitir uma fusão que os oculte.
            return .deny
        }
    }

    private static func mangaIdentityIndex(context: ModelContext) throws -> [String: Set<String>] {
        let mangas = try context.fetch(FetchDescriptor<Manga>())
        var index: [String: Set<String>] = [:]
        for manga in mangas {
            let identities = Set([manga.id] + UnifiedWork.refs(fromJSON: manga.sourcesJSON).map(\.id))
            for identity in identities { index[identity, default: []].insert(manga.id) }
        }
        return index
    }

    static func canMerge(_ identities: Set<String>, context: ModelContext, downloads: DownloadStore = .shared) -> Bool {
        if case .allow = decision(identities, context: context, downloads: downloads) { return true }
        return false
    }
}

/// Quais obras do catálogo já estão na biblioteca (por qualquer uma das fontes salvas).
struct LibraryIndex {
    private var byRef: [String: Manga] = [:]

    init(_ favorites: [Manga]) {
        for manga in favorites where manga.isFavorite {
            byRef[manga.id] = manga
            for ref in UnifiedWork.refs(fromJSON: manga.sourcesJSON) where byRef[ref.id] == nil {
                byRef[ref.id] = manga
            }
        }
    }

    func manga(for work: UnifiedWork) -> Manga? {
        if let manga = byRef[work.id] { return manga }
        return work.refs.lazy.compactMap { byRef[$0.id] }.first
    }
}

extension LibraryActions {
    /// Adiciona direto do catálogo (toque longo). Os capítulos vêm na atualização seguinte.
    static func add(_ work: UnifiedWork, context: ModelContext, categories: [MangaCategory]) {
        guard let ref = work.refs.first else { return }
        let manga: Manga
        let id = ref.id
        var descriptor = FetchDescriptor<Manga>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            manga = existing
            existing.isFavorite = true
            existing.favoriteAt = Date()
        } else {
            manga = Manga(sourceId: ref.sourceId, remoteUrl: ref.remoteUrl, title: work.title, genres: work.genres, coverUrl: work.coverUrl, isFavorite: true)
            context.insert(manga)
        }
        manga.sourcesJSON = work.refsJSON
        // "Perguntar" não cabe num toque longo: fica sem categoria.
        _ = applyDefaultCategory(to: manga, categories: categories)
        try? context.save()
        let mangaId = manga.id
        Task { @MainActor in
            await LibraryUpdater.shared.update(categoryId: nil, context: context, mangaIds: [mangaId])
        }
    }
}

/// Célula do catálogo: escurece obras da biblioteca e adiciona/remove com toque longo.
struct CatalogCell: View {
    let work: UnifiedWork
    let filter: LanguageFilter
    let index: LibraryIndex
    /// Mostra o último capítulo e quando saiu (em "Recentes").
    var showsLatestChapter = false

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MangaCategory.order) private var categories: [MangaCategory]

    var body: some View {
        let manga = index.manga(for: work)
        NavigationLink(value: work) {
            MangaGridItem(work: work, filter: filter)
                .markedInLibrary(manga != nil)
                .caption(showsLatestChapter ? work.latestChapterCaption() : nil)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let manga {
                Button("Remover da biblioteca", systemImage: "heart.slash", role: .destructive) {
                    LibraryActions.removeFromLibrary(manga, context: modelContext)
                    try? modelContext.save()
                }
            } else {
                Button("Adicionar à biblioteca", systemImage: "heart") {
                    LibraryActions.add(work, context: modelContext, categories: categories)
                }
            }
        }
    }
}

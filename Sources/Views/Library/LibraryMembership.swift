import SwiftUI
import SwiftData

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

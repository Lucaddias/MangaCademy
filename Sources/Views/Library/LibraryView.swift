import SwiftUI
import SwiftData

public struct LibraryView: View {
    @Query(filter: #Predicate<Manga> { $0.isFavorite == true }, sort: \.title)
    private var favoriteMangas: [Manga]

    @AppStorage(LanguageFilter.storageKey) private var filterRaw: String = LanguageFilter.portuguese.rawValue
    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 105, maximum: 130), spacing: 14)
    ]

    private var filter: LanguageFilter { LanguageFilter(rawValue: filterRaw) ?? .portuguese }

    private var filteredMangas: [Manga] {
        if searchText.isEmpty {
            return favoriteMangas
        }
        return favoriteMangas.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    public init() {}

    /// Reconstrói a obra unificada (todas as fontes/idiomas) salva na biblioteca.
    private func work(for manga: Manga) -> UnifiedWork {
        var refs = UnifiedWork.refs(fromJSON: manga.sourcesJSON)
        if refs.isEmpty {
            refs = [WorkSourceRef(
                sourceId: manga.sourceId,
                sourceName: SourceManager.shared.sourceName(id: manga.sourceId),
                remoteUrl: manga.remoteUrl,
                title: manga.title,
                coverUrl: manga.coverUrl,
                languages: []
            )]
        }
        return UnifiedWork(id: manga.id, title: manga.title, coverUrl: manga.coverUrl, refs: refs)
            ?? UnifiedWork(ref: refs[0])
    }

    public var body: some View {
        NavigationStack {
            Group {
                if favoriteMangas.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        Text("Sua biblioteca está vazia")
                            .font(.headline)
                        Text("Explore obras de todas as fontes Keiyoushi e adicione às suas favoritas.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(filteredMangas) { manga in
                                let work = work(for: manga)
                                NavigationLink {
                                    MangaDetailView(work: work)
                                } label: {
                                    MangaGridItem(
                                        work: work,
                                        filter: filter,
                                        unreadCount: manga.unreadCount > 0 ? manga.unreadCount : nil
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Biblioteca")
            .searchable(text: $searchText, prompt: "Filtrar biblioteca...")
        }
    }
}

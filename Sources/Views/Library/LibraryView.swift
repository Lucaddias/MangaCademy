import SwiftUI
import SwiftData

public struct LibraryView: View {
    @Query(filter: #Predicate<Manga> { $0.isFavorite == true }, sort: \.title)
    private var favoriteMangas: [Manga]

    @AppStorage(Preferences.Key.languageFilter) private var filterRaw: String = Preferences.Default.languageFilter.rawValue
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
                                let work = UnifiedWork(libraryManga: manga)
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

import SwiftUI
import SwiftData

public struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var showStoreResetAlert: Bool
    @State private var navigation = AppNavigation.shared
    @Query private var recentChapters: [Chapter]
    @Query(filter: #Predicate<Manga> { $0.isFavorite == true }) private var favorites: [Manga]

    public init(storeWasReset: Bool = false) {
        _showStoreResetAlert = State(initialValue: storeWasReset)
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        _recentChapters = Query(filter: #Predicate<Chapter> { $0.dateFetch.flatMap { $0 > cutoff } == true && !$0.isRead })
    }

    /// Capítulos novos e não lidos desde a última vez que a aba Novidades foi aberta.
    private var updatesBadge: Int {
        let lastViewed = navigation.updatesLastViewed
        return UpdatesFeed.items(records: recentChapters, favorites: favorites)
            .filter { !$0.isRead && $0.date > lastViewed }
            .count
    }

    public var body: some View {
        TabView(selection: $navigation.tab) {
            LibraryView()
                .tabItem {
                    Label("Biblioteca", systemImage: "books.vertical")
                }
                .tag(AppNavigation.Tab.library)

            UpdatesView()
                .tabItem {
                    Label("Novidades", systemImage: "bell")
                }
                .badge(updatesBadge)
                .tag(AppNavigation.Tab.updates)

            HistoryView()
                .tabItem {
                    Label("Histórico", systemImage: "clock")
                }
                .tag(AppNavigation.Tab.history)

            BrowseView()
                .tabItem {
                    Label("Explorar", systemImage: "safari")
                }
                .tag(AppNavigation.Tab.browse)

            SettingsView()
                .tabItem {
                    Label("Ajustes", systemImage: "gearshape")
                }
                .tag(AppNavigation.Tab.settings)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { BackgroundTasks.catchUpIfNeeded(context: modelContext) }
        }
        .alert("Dados recriados", isPresented: $showStoreResetAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Não foi possível abrir a biblioteca salva neste aparelho, então ela foi recriada vazia. Uma cópia do arquivo antigo ficou guardada no app.")
        }
    }
}

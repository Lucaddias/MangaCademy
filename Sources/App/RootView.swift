import SwiftUI

public struct RootView: View {
    @State private var showStoreResetAlert: Bool

    public init(storeWasReset: Bool = false) {
        _showStoreResetAlert = State(initialValue: storeWasReset)
    }

    public var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("Biblioteca", systemImage: "books.vertical")
                }

            BrowseView()
                .tabItem {
                    Label("Explorar", systemImage: "safari")
                }

            HistoryView()
                .tabItem {
                    Label("Histórico", systemImage: "clock")
                }

            SettingsView()
                .tabItem {
                    Label("Ajustes", systemImage: "gearshape")
                }
        }
        .alert("Dados recriados", isPresented: $showStoreResetAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Não foi possível abrir a biblioteca salva neste aparelho, então ela foi recriada vazia. Uma cópia do arquivo antigo ficou guardada no app.")
        }
    }
}

import SwiftUI

public struct RootView: View {
    public init() {}
    
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
    }
}

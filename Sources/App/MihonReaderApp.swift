import SwiftUI
import SwiftData

@main
struct MihonReaderApp: App {
    private let store = ModelStore.openRecovering()

    var body: some Scene {
        WindowGroup {
            RootView(storeWasReset: store.didReset)
        }
        .modelContainer(store.container)
    }
}

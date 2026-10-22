import SwiftUI
import SwiftData
import UIKit

@main
struct MihonReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let store = ModelStore.openRecovering()

    var body: some Scene {
        WindowGroup {
            RootView(storeWasReset: store.didReset)
        }
        .modelContainer(store.container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Orientações permitidas agora (o leitor trava a orientação por obra).
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }

    /// Trava (ou libera) a rotação da tela.
    @MainActor
    static func lockOrientation(_ mask: UIInterfaceOrientationMask) {
        orientationLock = mask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            windowScene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

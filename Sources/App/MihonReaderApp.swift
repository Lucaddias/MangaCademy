import SwiftUI
import SwiftData
import UIKit
import UserNotifications

@main
struct MihonReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let store: (container: ModelContainer, didReset: Bool)

    init() {
        store = ModelStore.openRecovering()
        AppStore.container = store.container
    }

    var body: some Scene {
        WindowGroup {
            RootView(storeWasReset: store.didReset)
        }
        .modelContainer(store.container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Orientações permitidas agora (o leitor trava a orientação por obra).
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BackgroundTasks.register()
        BackgroundTasks.scheduleLibraryUpdate()
        BackgroundTasks.scheduleBackup()
        return true
    }

    /// Mostra o aviso mesmo com o app aberto.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Tocar no aviso de capítulos novos abre a aba Novidades.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { AppNavigation.shared.tab = .updates }
    }

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

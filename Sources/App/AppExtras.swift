import SwiftUI
import SwiftData
import LocalAuthentication
import CoreSpotlight
import UIKit

// MARK: - Segurança e aparência

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Pede Face ID/Touch ID (ou o código) ao abrir.
    var lockEnabled: Bool { didSet { defaults.set(lockEnabled, forKey: "security_lock") } }
    /// Minutos fora do app até pedir de novo (0 = sempre).
    var lockAfterMinutes: Int { didSet { defaults.set(lockAfterMinutes, forKey: "security_lock_after") } }
    /// Esconde o conteúdo no seletor de apps.
    var hideInSwitcher: Bool { didSet { defaults.set(hideInSwitcher, forKey: "security_hide_switcher") } }
    /// 0 = sistema, 1 = claro, 2 = escuro.
    var theme: Int { didSet { defaults.set(theme, forKey: "appearance_theme") } }
    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboarding_done") } }

    private init() {
        lockEnabled = defaults.bool(forKey: "security_lock")
        lockAfterMinutes = defaults.object(forKey: "security_lock_after") as? Int ?? 0
        hideInSwitcher = defaults.bool(forKey: "security_hide_switcher")
        theme = defaults.integer(forKey: "appearance_theme")
        onboardingDone = defaults.bool(forKey: "onboarding_done")
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "código do aparelho"
        }
    }
}

/// Tranca o app com biometria e esconde o conteúdo no seletor de apps.
struct AppLockModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = AppSettings.shared
    @State private var locked = AppSettings.shared.lockEnabled
    @State private var leftAt: Date?
    @State private var authenticating = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if locked {
                    lockScreen
                } else if settings.hideInSwitcher && scenePhase != .active {
                    Rectangle().fill(.regularMaterial).ignoresSafeArea()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    leftAt = Date()
                case .active:
                    if settings.lockEnabled, let leftAt, Date().timeIntervalSince(leftAt) >= Double(settings.lockAfterMinutes * 60) {
                        locked = true
                    }
                    leftAt = nil
                    if locked { authenticate() }
                default:
                    break
                }
            }
            .task { if locked { authenticate() } }
    }

    private var lockScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text("MangaCademy está bloqueado").font(.headline)
            Button("Desbloquear") { authenticate() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func authenticate() {
        guard !authenticating else { return }
        authenticating = true
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Desbloquear o MangaCademy") { success, _ in
            Task { @MainActor in
                if success { locked = false }
                authenticating = false
            }
        }
    }
}

// MARK: - Spotlight, atalhos e links

@MainActor
enum AppLinks {
    static let spotlightDomain = "com.lucadias.MihonReader.library"

    /// Põe as obras da biblioteca na busca do sistema.
    static func indexLibrary(_ mangas: [Manga]) {
        let items = mangas.map { manga -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = manga.title
            attributes.contentDescription = [manga.author, manga.desc].compactMap { $0 }.first
            attributes.keywords = manga.genres
            return CSSearchableItem(uniqueIdentifier: manga.id, domainIdentifier: spotlightDomain, attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [spotlightDomain]) { _ in
            index.indexSearchableItems(items)
        }
    }

    /// `mangacademy://biblioteca`, `novidades`, `historico`, `explorar`, `ajustes` ou `obra/<id>`.
    static func open(_ url: URL) {
        guard url.scheme == "mangacademy" else { return }
        let navigation = AppNavigation.shared
        switch url.host {
        case "biblioteca", "library": navigation.tab = .library
        case "novidades", "updates": navigation.tab = .updates
        case "historico", "history": navigation.tab = .history
        case "explorar", "browse": navigation.tab = .browse
        case "ajustes", "settings": navigation.tab = .settings
        case "obra", "manga":
            let id = url.pathComponents.dropFirst().joined(separator: "/")
            guard !id.isEmpty else { return }
            navigation.tab = .library
            navigation.pendingMangaId = id.removingPercentEncoding ?? id
        default: break
        }
    }

    static func handle(_ item: UIApplicationShortcutItem) {
        switch item.type {
        case "updates": AppNavigation.shared.tab = .updates
        case "browse": AppNavigation.shared.tab = .browse
        default: AppNavigation.shared.tab = .history
        }
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        await MainActor.run { AppLinks.handle(shortcutItem) }
        return true
    }
}

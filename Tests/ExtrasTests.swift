import Foundation
import Testing
@testable import MihonReader

@MainActor
@Suite(.serialized)
struct ExtrasTests {
    @Test func deepLinksPickTabAndWork() {
        let navigation = AppNavigation.shared
        AppLinks.open(URL(string: "mangacademy://novidades")!)
        #expect(navigation.tab == .updates)
        AppLinks.open(URL(string: "mangacademy://obra/ky-1%3A%2Fmanga%2Fx")!)
        #expect(navigation.tab == .library)
        #expect(navigation.pendingMangaId == "ky-1:/manga/x")
        navigation.pendingMangaId = nil
        AppLinks.open(URL(string: "https://example.com/historico")!)
        #expect(navigation.tab == .library)
    }

    @Test func aniListTokenGoesToKeychain() async throws {
        let tracker = AniListTracker()
        tracker.logout()
        #expect(!tracker.isLoggedIn)
        try await tracker.completeOAuth(callback: URL(string: "mangacademy://anilist#access_token=abc123&token_type=Bearer&expires_in=1")!)
        #expect(tracker.isLoggedIn)
        #expect(Keychain.get("anilist_token") == "abc123")
        tracker.logout()
        #expect(!tracker.isLoggedIn)
    }

    @Test func readingTimeFormat() {
        #expect(StatsView.duration(3_660).contains("1"))
        #expect(!StatsView.duration(90_000).isEmpty)
    }
}

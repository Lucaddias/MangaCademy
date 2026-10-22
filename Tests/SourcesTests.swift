import Foundation
import Testing
@testable import MihonReader

@MainActor
struct SourcesTests {
    @Test func disabledSourcesAndLanguagesPersist() {
        let defaults = UserDefaults(suiteName: "src-\(UUID().uuidString)")!
        let settings = SourceSettings(defaults: defaults)
        let source = MangaDexSource()
        #expect(settings.isEnabled(source))
        settings.toggle(source.id, in: \.disabledSources)
        #expect(!settings.isEnabled(source))
        settings.toggle(source.id, in: \.disabledSources)
        settings.disabledLanguages = [source.language]
        #expect(!settings.isEnabled(source))
        settings.pinnedSources = ["x"]
        let reloaded = SourceSettings(defaults: defaults)
        #expect(reloaded.disabledLanguages == [source.language])
        #expect(reloaded.pinnedSources == ["x"])
    }

    @Test func libraryIndexMatchesAnySavedSource() {
        let first = WorkSourceRef(sourceId: "a", sourceName: "A", remoteUrl: "/1", title: "Obra", coverUrl: nil, languages: [])
        let second = WorkSourceRef(sourceId: "b", sourceName: "B", remoteUrl: "/2", title: "Obra", coverUrl: nil, languages: [])
        let manga = Manga(sourceId: "a", remoteUrl: "/1", title: "Obra", isFavorite: true)
        manga.sourcesJSON = String(data: try! JSONEncoder().encode([first, second]), encoding: .utf8)
        let index = LibraryIndex([manga])
        #expect(index.manga(for: UnifiedWork(ref: second)) === manga)
        let other = WorkSourceRef(sourceId: "c", sourceName: "C", remoteUrl: "/3", title: "Outra", coverUrl: nil, languages: [])
        #expect(index.manga(for: UnifiedWork(ref: other)) == nil)
        manga.isFavorite = false
        #expect(LibraryIndex([manga]).manga(for: UnifiedWork(ref: first)) == nil)
    }
}

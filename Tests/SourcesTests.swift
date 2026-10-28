import Foundation
import Testing
@testable import MihonReader

@MainActor
struct SourcesTests {
    @Test func lateAliasWithConfirmedCoverReconcilesExistingGroupsAndPreservesRefs() {
        var merger = WorkMerger(canMergeIdentities: { _ in .allow(preferredID: nil) })
        let first = SourceMangaItem(sourceId: "a", remoteUrl: "/1", title: "Reader", coverUrl: "https://example.com/1")
        let second = SourceMangaItem(sourceId: "b", remoteUrl: "/2", title: "O leitor", coverUrl: "https://example.com/2")
        merger.add(first, sourceName: "A", coverHash: 0x1234)
        merger.add(second, sourceName: "B", coverHash: 0x1234)
        #expect(merger.works.count == 2)
        let bridge = SourceMangaItem(sourceId: "c", remoteUrl: "/3", title: "Reader", coverUrl: nil, altTitles: ["O leitor"], hasFullMetadata: true)
        merger.add(bridge, sourceName: "C", coverHash: 0x1234)
        #expect(merger.works.count == 1)
        #expect(merger.works[0].id == first.id)
        #expect(Set(merger.works[0].refs.map(\.id)) == Set([first.id, second.id, bridge.id]))
        #expect(merger.contains(refId: second.id))
    }

    @Test func lateAliasWithoutMatchingCoverDoesNotReconcileGroups() {
        var merger = WorkMerger(canMergeIdentities: { _ in .allow(preferredID: nil) })
        merger.add(SourceMangaItem(sourceId: "a", remoteUrl: "/1", title: "Reader", coverUrl: nil), sourceName: "A", coverHash: 0x1234)
        merger.add(SourceMangaItem(sourceId: "b", remoteUrl: "/2", title: "O leitor", coverUrl: nil), sourceName: "B", coverHash: 0xffff)
        let bridge = SourceMangaItem(sourceId: "c", remoteUrl: "/3", title: "Reader", coverUrl: nil, altTitles: ["O leitor"], hasFullMetadata: true)
        merger.add(bridge, sourceName: "C", coverHash: 0x1234)
        #expect(merger.works.count == 2)
    }

    @Test func persistedIdentitiesNeverReconcileOrJoinAnotherWork() {
        let protected: Set<String> = ["a:/1", "b:/2"]
        var merger = WorkMerger(canMergeIdentities: { $0.isDisjoint(with: protected) ? .allow(preferredID: nil) : .deny })
        let a = SourceMangaItem(sourceId: "a", remoteUrl: "/1", title: "Reader", coverUrl: nil)
        let b = SourceMangaItem(sourceId: "b", remoteUrl: "/2", title: "O leitor", coverUrl: nil)
        merger.add(a, sourceName: "A", coverHash: 0x1234)
        merger.add(b, sourceName: "B", coverHash: 0x1234)
        let bridge = SourceMangaItem(sourceId: "c", remoteUrl: "/3", title: "Reader", coverUrl: nil, altTitles: ["O leitor"], hasFullMetadata: true)
        merger.add(bridge, sourceName: "C", coverHash: 0x1234)
        #expect(merger.works.count == 3)
        #expect(merger.works.contains { $0.id == a.id && $0.refs.count == 1 })
        #expect(merger.works.contains { $0.id == b.id && $0.refs.count == 1 })
    }

    @Test func sameSourceRequiresReciprocalAliasesForDifferentTitles() {
        var merger = WorkMerger()
        merger.add(SourceMangaItem(sourceId: "a", remoteUrl: "/1", title: "Reader", coverUrl: nil, altTitles: ["O leitor"]), sourceName: "A")
        merger.add(SourceMangaItem(sourceId: "a", remoteUrl: "/2", title: "O leitor", coverUrl: nil, altTitles: ["Reader"]), sourceName: "A")
        #expect(merger.works.count == 1)
        #expect(merger.works[0].refs.count == 2)
    }

    @Test func unilateralSameSourceAliasDoesNotMergeDifferentWorks() {
        var merger = WorkMerger()
        merger.add(SourceMangaItem(sourceId: "a", remoteUrl: "/1", title: "Reader", coverUrl: nil), sourceName: "A")
        merger.add(SourceMangaItem(sourceId: "a", remoteUrl: "/2", title: "O leitor", coverUrl: nil, altTitles: ["Reader"]), sourceName: "A")
        #expect(merger.works.count == 2)
    }
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

import Testing
@testable import MihonReader

struct SourceAggregatorTests {
    private func chapter(_ number: Double, source: String, language: String? = "pt-BR", scanlator: String? = nil) -> SourceChapterItem {
        SourceChapterItem(
            remoteUrl: "/\(source)/\(number)",
            name: "Cap. \(number)",
            chapterNumber: number,
            orderIndex: 0,
            scanlator: scanlator,
            language: language,
            sourceId: source,
            mangaRemoteUrl: "/\(source)"
        )
    }

    @Test func groupsByLanguageAndSortsDescending() {
        let result = SourceAggregator.shared.chaptersByLanguage([
            chapter(1, source: "a"),
            chapter(3, source: "a"),
            chapter(2, source: "a", language: "en"),
        ])
        #expect(result["pt-BR"]?.map(\.chapterNumber) == [3, 1])
        #expect(result["en"]?.map(\.chapterNumber) == [2])
    }

    @Test func dedupesPreferringMostCompleteSource() {
        let result = SourceAggregator.shared.chaptersByLanguage([
            chapter(1, source: "small"),
            chapter(1, source: "big"),
            chapter(2, source: "big"),
        ])
        let list = result["pt-BR"] ?? []
        #expect(list.map(\.chapterNumber) == [2, 1])
        #expect(list.allSatisfy { $0.sourceId == "big" })
    }

    @Test func chaptersWithoutLanguageGoToAll() {
        let result = SourceAggregator.shared.chaptersByLanguage([chapter(1, source: "a", language: nil)])
        #expect(result["all"]?.count == 1)
    }
}

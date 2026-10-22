import Testing
@testable import MihonReader

@MainActor
struct HistoryResumeTests {
    private func chapter(_ number: Double, source: String = "a", language: String? = "pt-BR") -> SourceChapterItem {
        SourceChapterItem(
            remoteUrl: "/\(source)/\(number)",
            name: "Cap. \(number)",
            chapterNumber: number,
            orderIndex: 0,
            language: language,
            sourceId: source,
            mangaRemoteUrl: "/\(source)"
        )
    }

    @Test func findsChapterInItsLanguage() {
        let list = [chapter(1), chapter(2), chapter(3), chapter(2, language: "en")]
        let resumed = HistoryResume.arrange(list, around: chapter(2))
        #expect(resumed.chapters.map(\.chapterNumber) == [3, 2, 1])
        #expect(resumed.chapters[resumed.index].id == chapter(2).id)
    }

    @Test func replacesOtherSourceVersionOfSameNumber() {
        // A deduplicação escolheu a fonte "b" (mais completa), mas o histórico é da "a".
        let list = [chapter(1, source: "b"), chapter(2, source: "b"), chapter(1, source: "a")]
        let resumed = HistoryResume.arrange(list, around: chapter(1, source: "a"))
        #expect(resumed.chapters.count == 2)
        #expect(resumed.chapters[resumed.index].sourceId == "a")
    }

    @Test func chapterMissingFromSourceIsReadAlone() {
        let resumed = HistoryResume.arrange([chapter(1)], around: chapter(9))
        #expect(resumed.chapters.map(\.chapterNumber) == [9])
        #expect(resumed.index == 0)
    }

    @Test func storedIdRebuildsSingleSourceWork() {
        let work = UnifiedWork(storedId: "ky-123:https://site.com/obra/1", title: "Obra", coverUrl: nil)
        #expect(work?.id == "ky-123:https://site.com/obra/1")
        #expect(work?.refs.first?.sourceId == "ky-123")
        #expect(work?.refs.first?.remoteUrl == "https://site.com/obra/1")
        #expect(UnifiedWork(storedId: "sem-separador", title: "", coverUrl: nil) == nil)
    }
}

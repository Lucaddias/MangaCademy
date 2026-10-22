import Testing
@testable import MihonReader

struct WorkLoadStateTests {
    private func ref(_ source: String, title: String = "Obra") -> WorkSourceRef {
        WorkSourceRef(sourceId: source, sourceName: source.uppercased(), remoteUrl: "/\(source)", title: title, coverUrl: nil, languages: [])
    }

    private func chapter(_ number: Double, language: String? = nil) -> SourceChapterItem {
        SourceChapterItem(remoteUrl: "/cap-\(number)", name: "Cap. \(number)", chapterNumber: number, orderIndex: 0, language: language)
    }

    @Test func normalizeFillsSourceMangaAndLanguage() {
        let list = WorkLoadState.normalize([chapter(1), chapter(2, language: "en")], ref: ref("a"), sourceLanguage: "pt-BR")
        #expect(list.map(\.sourceId) == ["a", "a"])
        #expect(list.map(\.mangaRemoteUrl) == ["/a", "/a"])
        #expect(list.map(\.language) == ["pt-BR", "en"])

        // Fonte multi-idioma não inventa idioma.
        let multi = WorkLoadState.normalize([chapter(1)], ref: ref("m"), sourceLanguage: "all")
        #expect(multi.first?.language == nil)
    }

    @Test func groupsChaptersFromAllSources() {
        var state = WorkLoadState(work: UnifiedWork(ref: ref("a")))
        state.add(ref: ref("a"), sourceLanguage: "pt-BR", detail: SourceMangaDetail(remoteUrl: "/a", title: "Obra"), chapters: [chapter(1), chapter(2)])
        state.add(ref: ref("b"), sourceLanguage: "en", detail: SourceMangaDetail(remoteUrl: "/b", title: "Obra"), chapters: [chapter(1)])

        #expect(state.loadedSourceCount == 2)
        #expect(state.chaptersByLanguage["pt-BR"]?.count == 2)
        #expect(state.chaptersByLanguage["en"]?.count == 1)
        #expect(Set(state.work.languages) == ["pt-BR", "en"])
    }

    @Test func mergedDetailPrefersFilterLanguageAndSynopsis() {
        var state = WorkLoadState(work: UnifiedWork(ref: ref("en")))
        state.add(ref: ref("en"), sourceLanguage: "en",
                  detail: SourceMangaDetail(remoteUrl: "/en", title: "Work", author: "Autor", description: "English synopsis", genres: ["Action"], status: 1),
                  chapters: [])
        state.add(ref: ref("pt"), sourceLanguage: "pt-BR",
                  detail: SourceMangaDetail(remoteUrl: "/pt", title: "Obra", description: "Sinopse", genres: ["Ação", "Adulto"]),
                  chapters: [])

        let pt = state.mergedDetail(filter: .portuguese)
        #expect(pt?.title == "Obra")
        #expect(pt?.description == "Sinopse")
        #expect(pt?.author == "Autor")      // completa com a outra fonte
        #expect(pt?.status == 1)
        #expect(pt?.genres == ["Ação", "Adulto", "Action"])
        #expect(state.isAdult)

        #expect(state.mergedDetail(filter: .english)?.title == "Work")
    }

    @Test func failuresAreKept() {
        var state = WorkLoadState(work: UnifiedWork(ref: ref("a")))
        state.addFailure("A: fora do ar")
        #expect(state.failures == ["A: fora do ar"])
        #expect(state.mergedDetail(filter: .all) == nil)
    }
}

import Foundation
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

    @MainActor
    @Test func detailModelSeedsLocalSnapshotAndReplacesWithRemoteSafely() {
        let refA = WorkSourceRef(sourceId: "a", sourceName: "A", remoteUrl: "/a", title: "Obra", coverUrl: nil, languages: ["pt-BR"])
        let refB = WorkSourceRef(sourceId: "b", sourceName: "B", remoteUrl: "/b", title: "Obra", coverUrl: nil, languages: ["en"])
        var work = UnifiedWork(ref: refA)
        work.merge(ref: refB, altTitles: [])

        let model = WorkDetailModel(work: work)
        let mangaId = work.id

        let validPt = Chapter(mangaId: mangaId, remoteUrl: "/a/1", name: "Cap. 1", chapterNumber: 1, orderIndex: 0, sourceId: "a", language: "pt-BR", mangaRemoteUrl: "/a")
        validPt.dateFetch = Date()
        let validEn = Chapter(mangaId: mangaId, remoteUrl: "/b/1", name: "Ch. 1", chapterNumber: 1, orderIndex: 0, sourceId: "b", language: "en", mangaRemoteUrl: "/b")
        validEn.dateFetch = Date()
        let missingDateFetch = Chapter(mangaId: mangaId, remoteUrl: "/a/2", name: "Cap. 2", chapterNumber: 2, orderIndex: 1, sourceId: "a", language: "pt-BR", mangaRemoteUrl: "/a")
        let otherManga = Chapter(mangaId: "other:/x", remoteUrl: "/a/9", name: "Cap. 9", chapterNumber: 9, orderIndex: 0, sourceId: "a", language: "pt-BR", mangaRemoteUrl: "/a")
        otherManga.dateFetch = Date()
        let detachedSource = Chapter(mangaId: mangaId, remoteUrl: "/c/3", name: "Cap. 3", chapterNumber: 3, orderIndex: 0, sourceId: "c", language: "pt-BR", mangaRemoteUrl: "/c")
        detachedSource.dateFetch = Date()

        model.seedLocalSnapshot(
            records: [validPt, validEn, missingDateFetch, otherManga, detachedSource],
            mangaId: mangaId,
            filter: .portuguese,
            savedLanguage: "pt-BR"
        )

        #expect(!model.hasRemoteChapters)
        #expect(!model.canPersistSelectedLanguage)
        #expect(model.selectedLanguage == "pt-BR")
        #expect(model.chapters.map(\.remoteUrl) == ["/a/1"])
        #expect(model.chaptersByLanguage["en"]?.map(\.remoteUrl) == ["/b/1"])

        // Resposta parcial de outra fonte ("en") enquanto a preferida ("pt-BR") ainda está pendente.
        var loadState = WorkLoadState(work: work)
        loadState.add(
            ref: refB,
            sourceLanguage: "en",
            detail: SourceMangaDetail(remoteUrl: "/b", title: "Obra"),
            chapters: [chapter(2, language: "en")]
        )
        model.apply(state: loadState, pendingSources: 1)

        #expect(model.selectedLanguage == "pt-BR")
        #expect(!model.canPersistSelectedLanguage)
        #expect(model.chapters.map(\.remoteUrl) == ["/a/1"])
        #expect(model.chaptersByLanguage["en"]?.map(\.remoteUrl) == ["/cap-2.0"])

        // Resposta completa da fonte preferida substitui os capítulos locais pelos remotos.
        loadState.add(
            ref: refA,
            sourceLanguage: "pt-BR",
            detail: SourceMangaDetail(remoteUrl: "/a", title: "Obra"),
            chapters: [chapter(10, language: "pt-BR")]
        )
        model.apply(state: loadState, pendingSources: 0)

        #expect(model.hasRemoteChapters)
        #expect(model.selectedLanguage == "pt-BR")
        #expect(model.chapters.map(\.remoteUrl) == ["/cap-10.0"])
    }

    @MainActor
    @Test func detailModelPreservesLocalSnapshotWhenRemoteFails() {
        let refA = WorkSourceRef(sourceId: "a", sourceName: "A", remoteUrl: "/a", title: "Obra", coverUrl: nil, languages: ["pt-BR"])
        let refB = WorkSourceRef(sourceId: "b", sourceName: "B", remoteUrl: "/b", title: "Obra", coverUrl: nil, languages: ["en"])
        var work = UnifiedWork(ref: refA)
        work.merge(ref: refB, altTitles: [])

        let model = WorkDetailModel(work: work)
        let saved = Chapter(mangaId: work.id, remoteUrl: "/a/1", name: "Cap. 1", chapterNumber: 1, orderIndex: 0, sourceId: "a", language: "pt-BR", mangaRemoteUrl: "/a")
        saved.dateFetch = Date()

        model.seedLocalSnapshot(records: [saved], mangaId: work.id, filter: .portuguese, savedLanguage: "pt-BR")

        // Fonte "en" responde parcialmente enquanto "pt-BR" pendente, mesmo sem capítulos locais em "pt-BR" ou com falha final.
        var failedState = WorkLoadState(work: work)
        failedState.addFailure("A: fora do ar")
        model.apply(state: failedState, pendingSources: 0)

        #expect(!model.hasRemoteChapters)
        #expect(model.selectedLanguage == "pt-BR")
        #expect(model.chapters.map(\.remoteUrl) == ["/a/1"])

        // Também preserva o idioma salvo se apenas outra fonte responder enquanto a preferida está pendente, sem snapshot local em "pt-BR".
        let pendingOnlyModel = WorkDetailModel(work: work)
        pendingOnlyModel.seedLocalSnapshot(records: [], mangaId: work.id, filter: .portuguese, savedLanguage: "pt-BR")
        var partialOther = WorkLoadState(work: work)
        partialOther.add(ref: refB, sourceLanguage: "en", detail: SourceMangaDetail(remoteUrl: "/b", title: "Obra"), chapters: [chapter(1, language: "en")])
        pendingOnlyModel.apply(state: partialOther, pendingSources: 1)

        #expect(pendingOnlyModel.selectedLanguage == "pt-BR")
        #expect(!pendingOnlyModel.canPersistSelectedLanguage)
    }
}

import Foundation
import Testing
@testable import MihonReader

struct ContentFilterTests {
    @Test func blocksAdultTagsUsedBySites() {
        for tag in ["Adult", "Adulto", "+18", "Mature", "Smut", "Hentai", "Erótico", "Sexual Violence",
                    "Manhwa 18+", "Adulto (+18)", "R-18", "Content Rating: mature",
                    "Lolicon", "Shotacon", "Futanari", "BDSM", "Netorare", "Sexo a três"] {
            #expect(ContentFilter.isAdultTag(tag), "\(tag) deveria ser adulta")
        }
    }

    @Test func keepsCommonGenres() {
        for tag in ["Vida Adulta", "Ecchi", "Romance", "Drama", "Content Rating: restricted", "Shounen", "2018",
                    "Harem", "Yuri", "Incest", "Big Breast", "Female Only"] {
            #expect(!ContentFilter.isAdultTag(tag), "\(tag) não deveria ser adulta")
        }
    }

    @Test func adultSourceNames() {
        #expect(ContentFilter.isAdultSourceName("Manhwa18TX"))
        #expect(ContentFilter.isAdultSourceName("Hentai20 (Unoriginal)"))
        #expect(!ContentFilter.isAdultSourceName("ManhwaBuddy"))
        #expect(!ContentFilter.isAdultSourceName("Read Solo Leveling Manga Manhwa Online"))
    }

    @Test func mixedSourceWithAdultNameCountsAsNsfw() {
        let mixed = KeiyoushiExtensionItem(name: "Manhwa18TX", pkg: "x", version: "1", iconUrl: "", contentWarning: "MIXED", engine: nil, sources: [])
        let safe = KeiyoushiExtensionItem(name: "Manga18 Scan", pkg: "y", version: "1", iconUrl: "", contentWarning: "SAFE", engine: nil, sources: [])
        #expect(mixed.isNsfw)
        #expect(!safe.isNsfw)
    }

    /// Sites +18 (ex.: Inkapk) não põem tag adulta nas obras: a obra conta como adulta pela fonte.
    @Test func worksOnlyFromAdultSourcesAreAdult() {
        var merger = WorkMerger()
        merger.add(SourceMangaItem(sourceId: "ky-nsfw", remoteUrl: "/obras/frequency/", title: "Frequency", coverUrl: nil),
                   sourceName: "Inkapk", adultSource: true)
        #expect(merger.works[0].isAdult)
        #expect(merger.works[0].onlyAdultSources)
        #expect(merger.adultCount == 1)

        // A mesma obra numa fonte comum deixa de contar como adulta
        merger.add(SourceMangaItem(sourceId: "ky-safe", remoteUrl: "/manga/frequency/", title: "Frequency", coverUrl: nil),
                   sourceName: "Comum")
        #expect(merger.works.count == 1)
        #expect(!merger.works[0].isAdult)
        #expect(merger.adultCount == 0)

        // Tag adulta continua valendo mesmo com fonte comum
        merger.add(SourceMangaItem(sourceId: "ky-safe", remoteUrl: "/manga/outra/", title: "Outra", coverUrl: nil, genres: ["Smut"]),
                   sourceName: "Comum")
        #expect(merger.works[1].isAdult)
        #expect(!merger.works[1].onlyAdultSources)
        #expect(merger.adultCount == 1)
    }

    @Test func mangaBallMarksEighteenPlusTitles() {
        let source = MangaBallSource(id: "b", name: "Manga Ball", language: "en", baseUrl: "https://mangaball.com", config: KeiyoushiEngineConfig(type: "mangaball"))
        let adult = source.makeDetail(["id": "1", "name": "Obra", "tags": [["name": "Drama"]], "is18plus": true])
        let regular = source.makeDetail(["id": "2", "name": "Outra", "tags": [["name": "Drama"]], "is18plus": false])
        #expect(ContentFilter.isAdult(genres: adult?.genres ?? []))
        #expect(!ContentFilter.isAdult(genres: regular?.genres ?? []))
    }
}

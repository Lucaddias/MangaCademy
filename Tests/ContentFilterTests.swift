import Foundation
import Testing
@testable import MihonReader

struct ContentFilterTests {
    @Test func blocksAdultTagsUsedBySites() {
        for tag in ["Adult", "Adulto", "+18", "Mature", "Smut", "Hentai", "Erótico", "Sexual Violence",
                    "Manhwa 18+", "Adulto (+18)", "R-18", "Content Rating: mature"] {
            #expect(ContentFilter.isAdultTag(tag), "\(tag) deveria ser adulta")
        }
    }

    @Test func keepsCommonGenres() {
        for tag in ["Vida Adulta", "Ecchi", "Romance", "Drama", "Content Rating: restricted", "Shounen", "2018"] {
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

    @Test func mangaBallMarksEighteenPlusTitles() {
        let source = MangaBallSource(id: "b", name: "Manga Ball", language: "en", baseUrl: "https://mangaball.com", config: KeiyoushiEngineConfig(type: "mangaball"))
        let adult = source.makeDetail(["id": "1", "name": "Obra", "tags": [["name": "Drama"]], "is18plus": true])
        let regular = source.makeDetail(["id": "2", "name": "Outra", "tags": [["name": "Drama"]], "is18plus": false])
        #expect(ContentFilter.isAdult(genres: adult?.genres ?? []))
        #expect(!ContentFilter.isAdult(genres: regular?.genres ?? []))
    }
}

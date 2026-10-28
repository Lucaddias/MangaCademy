import Foundation
import Testing
@testable import MihonReader

/// Parsers dos motores novos (temas multi-site e extensões multi-idioma), com HTML/JSON de exemplo.
struct EngineParserTests {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func html(_ text: String, base: String = "https://example.com") -> HTMLDocument {
        HTMLDocument(html: text, url: URL(string: base))!
    }

    private func config(_ type: String) -> KeiyoushiEngineConfig {
        KeiyoushiEngineConfig(type: type)
    }

    // MARK: - Temas

    @Test func yiiMangaListAndDates() {
        let source = YiiMangaSource(id: "y", name: "Y", language: "en", baseUrl: "https://example.com", config: config("yiimanga"))
        let doc = html("""
        <div class="latest-list"><div class="latest-item">
          <div class="latest-left"><img data-src="/covers/foo.jpg"></div>
          <div class="latest-right"><a href="https://example.com/manga/foo"><h3>Foo</h3></a>
            <ul><li><a href="/manga/foo/chapter-12">Chapter 12</a><span>06 Oct 2026</span></li>
                <li><a href="/manga/foo/chapter-11">Chapter 11</a><span>01 Oct 2026</span></li></ul>
          </div>
        </div></div>
        """)
        let items = source.parseList(doc)
        #expect(items.count == 1)
        #expect(items.first?.remoteUrl == "/manga/foo")
        #expect(items.first?.title == "Foo")
        #expect(items.first?.coverUrl == "https://example.com/covers/foo.jpg")
        #expect(items.first?.latestChapterName == "Chapter 12")
        #expect(items.first?.latestChapterDate == utc(2026, 10, 6))

        #expect(YiiMangaSource.date("12 Oct 26") == utc(2026, 10, 12))
        #expect(YiiMangaSource.date("Oct 26") == utc(2026, 10, 1))
        #expect(YiiMangaSource.date("ontem") == nil)
    }

    @Test func mangaCatalogTitleComesFromThePath() {
        #expect(MangaCatalogSource.title(fromPath: "/manga/berserk-colored/") == "Berserk Colored")
        #expect(MangaCatalogSource.title(fromPath: "/manga/") == nil)
    }

    @Test func mmrcmsChapterNameUsesTheSourceLanguage() {
        let french = MMRCMSSource(id: "m", name: "M", language: "fr", baseUrl: "https://example.com", config: config("mmrcms"))
        #expect(french.cleanChapterName("One Piece", "One Piece 1196 : Le titre") == "Chapitre 1196: Le titre")
        let english = MMRCMSSource(id: "m", name: "M", language: "en", baseUrl: "https://example.com", config: config("mmrcms"))
        #expect(english.cleanChapterName("Naruto", "Naruto 700") == "Chapter 700")
        #expect(english.cleanChapterName("Naruto", "Naruto 700 : Chapter 700") == "Chapter 700")
    }

    @Test func foolSlideReleasesBringTheNewestChapter() {
        let source = FoolSlideSource(id: "f", name: "F", language: "en", baseUrl: "https://example.com", config: config("foolslide"))
        let doc = html("""
        <div class="group">
          <div class="title"><a href="https://example.com/series/foo/" title="Foo">Foo</a></div>
          <div class="element"><div class="title"><a href="https://example.com/read/foo/en/0/12/">Chapter 12</a></div>
            <div class="meta_r">by Equipe, 2026.07.18</div></div>
          <div class="element"><div class="title"><a href="https://example.com/read/foo/en/0/11/">Chapter 11</a></div>
            <div class="meta_r">by Equipe, 2026.07.01</div></div>
        </div>
        """)
        let items = source.parseGroups(doc, withCover: false)
        #expect(items.map(\.remoteUrl) == ["/series/foo/"])
        #expect(items.first?.latestChapterName == "Chapter 12")
        #expect(items.first?.latestChapterDate == utc(2026, 7, 18))
        #expect(source.date("2026.07.18") == utc(2026, 7, 18))
    }

    @Test func keyoappV2SkipsPaidChaptersInRecents() {
        let source = KeyoappV2Source(id: "k", name: "K", language: "en", baseUrl: "https://example.com", config: config("keyoappv2"))
        let doc = html("""
        <article class="ru-card">
          <img class="ru-cover-img" src="https://example.com/c.jpg">
          <h2 class="ru-title"><a href="https://example.com/series/foo/">Foo</a></h2>
          <a class="ru-row ru-row--paid" href="/chapter/13"><span class="ru-ch">Chapter 13</span><time datetime="2026-10-26T10:00:00Z"></time></a>
          <a class="ru-row" href="/chapter/12"><span class="ru-ch">Chapter 12</span><time datetime="2026-10-25T10:00:00Z"></time></a>
        </article>
        """)
        let items = source.parseRecent(doc)
        #expect(items.first?.title == "Foo")
        #expect(items.first?.latestChapterName == "Chapter 12")
        #expect(items.first?.latestChapterDate == utc(2026, 10, 25, 10))
    }

    // MARK: - Multi-idioma

    @Test func webtoonsNumbersSeasonsAndExtras() {
        let titles = ["Ep. 1", "Ep. 2", "Season 2 Ep. 1", "Season 2 Ep. 2", "Bonus Special"]
        #expect(WebtoonsSource.chapterNumbers(titles) == [1, 2, 3, 4, 4.01])
        // Quando a maioria não tem número, numera pela ordem
        #expect(WebtoonsSource.chapterNumbers(["Prologue", "The start", "Ep. 1"]) == [1, 2, 3])
    }

    @Test func webtoonsListKeepsTheTitleNumberWithoutInventingUpdateDates() {
        let source = WebtoonsSource(id: "w", name: "W", language: "en", baseUrl: "https://www.webtoons.com", config: config("webtoons"))
        let doc = html("""
        <ul class="webtoon_list">
          <li><a href="https://www.webtoons.com/en/romance/foo/list?title_no=95"><img src="https://c.example/foo.jpg">
            <strong class="title">Foo</strong><span class="badge_up">UP</span></a></li>
          <li><a href="https://www.webtoons.com/en/drama/bar/list?title_no=7"><strong class="title">Bar</strong></a></li>
        </ul>
        """, base: "https://www.webtoons.com")
        let items = source.parseList(doc)
        #expect(items.map(\.remoteUrl) == ["/en/romance/foo/list?title_no=95", "/en/drama/bar/list?title_no=7"])
        #expect(items[0].latestChapterDate == nil)
        #expect(items[1].latestChapterDate == nil)
    }

    @Test func namiComiChapterNames() {
        #expect(NamiComiSource.chapterName(["volume": "2", "chapter": "10", "name": "Nome"]) == "Vol.2 Ch.10 - Nome")
        #expect(NamiComiSource.chapterName(["chapter": "5"]) == "Ch.5")
        #expect(NamiComiSource.chapterName([:]) == "Oneshot")
    }

    @Test func mangaBallChapterNamesCoversAndDates() {
        #expect(MangaBallSource.chapterName(["number": 70, "name": "Chapter 70"]) == "Chapter 70")
        #expect(MangaBallSource.chapterName(["volume": 2, "number": 10.5, "name": "Fim"]) == "Vol. 2 Ch. 10.5 Fim")
        #expect(MangaBallSource.chapterName(["name": ""]) == "Oneshot")

        #expect(MangaBallSource.coverURL(["cover": ["path": "ab\\cd.webp"]]) == "https://bulbasaur.poke-black-and-white.net/covers/ab/cd.webp")
        #expect(MangaBallSource.coverURL(["cover": ["path": ""], "file": "https://x.example/y.jpg"]) == "https://x.example/y.jpg")
        #expect(MangaBallSource.coverURL(nil) == nil)

        #expect(MangaBallSource.date("2026-10-26T17:16:02.700000") == utc(2026, 10, 26, 17, 16).addingTimeInterval(2))
        #expect(MangaBallSource.date("2026") == nil)
    }

    @Test func globalComixAndComicFuryDates() {
        #expect(GlobalComixSource.date("2026-10-26 13:00:00") == utc(2026, 10, 26, 13))
        #expect(ComicFurySource.date("29th Jul 2024, 5:15 PM") == utc(2024, 7, 29, 17, 15))
        #expect(ComicFurySource.date("Jul 29 2024") == utc(2024, 7, 29))
        #expect(ComicFurySource.date("29.7.2024") == utc(2024, 7, 29))
        #expect(ComicFurySource.date("amanhã") == nil)
    }
}

import Foundation
import Testing
@testable import MihonReader

struct ChapterDateParserTests {
    /// 26/10/2026 12:00 UTC
    private let now = Date(timeIntervalSince1970: 1_793_016_000)

    private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func relativeDatesInSeveralLanguages() {
        #expect(ChapterDateParser.parse("há 2 horas", language: "pt-BR", now: now) == now.addingTimeInterval(-7200))
        #expect(ChapterDateParser.parse("2 hours ago", now: now) == now.addingTimeInterval(-7200))
        #expect(ChapterDateParser.parse("hace 3 días", language: "es", now: now) == now.addingTimeInterval(-3 * 86_400))
        #expect(ChapterDateParser.parse("1 semana atrás", language: "pt-BR", now: now) == now.addingTimeInterval(-7 * 86_400))
        #expect(ChapterDateParser.parse("an hour ago", now: now) == now.addingTimeInterval(-3600))
        #expect(ChapterDateParser.parse("15 mins ago", now: now) == now.addingTimeInterval(-900))
        #expect(ChapterDateParser.parse("Ontem", language: "pt-BR", now: now) == utc(2026, 10, 25))
    }

    @Test func absoluteDatesInSeveralFormats() {
        #expect(ChapterDateParser.parse("outubro 6, 2026", language: "pt-BR", now: now) == utc(2026, 10, 6))
        #expect(ChapterDateParser.parse("6 de outubro de 2026", language: "pt-BR", now: now) == utc(2026, 10, 6))
        #expect(ChapterDateParser.parse("October 6th, 2026", now: now) == utc(2026, 10, 6))
        #expect(ChapterDateParser.parse("May 6, 2026", now: now) == utc(2026, 5, 6))
        #expect(ChapterDateParser.parse("06/10/2026", language: "pt-BR", now: now) == utc(2026, 10, 6))
        #expect(ChapterDateParser.parse("2026-10-06", now: now) == utc(2026, 10, 6))
        #expect(ChapterDateParser.parse("6 de mayo de 2026", language: "es", now: now) == utc(2026, 5, 6))
    }

    @Test func rejectsGarbageAndFutureDates() {
        #expect(ChapterDateParser.parse("Capítulo 12", language: "pt-BR", now: now) == nil)
        #expect(ChapterDateParser.parse("", now: now) == nil)
        #expect(ChapterDateParser.parse("December 6, 2027", now: now) == nil)
    }

    @Test func isoWithMicroseconds() {
        let date = DateParsing.iso("2026-10-26T17:37:23.466336+01:00")
        #expect(abs((date?.timeIntervalSince1970 ?? 0) - 1_793_032_643.466) < 0.01)
    }
}

struct LatestMergeTests {
    private let now = Date(timeIntervalSince1970: 1_793_016_000)

    private func item(_ name: String, source: String, hoursAgo: Double?) -> SourceMangaItem {
        SourceMangaItem(
            sourceId: source,
            remoteUrl: "/\(name)",
            title: name,
            coverUrl: nil,
            latestChapterDate: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) }
        )
    }

    private func drain(_ merge: inout LatestMerge) -> [String] {
        var titles: [String] = []
        while let entry = merge.popSafe() { titles.append(entry.item.title) }
        return titles
    }

    @Test func ordersAcrossSourcesByDate() {
        var merge = LatestMerge(now: now)
        merge.add([item("a1", source: "a", hoursAgo: 1), item("a2", source: "a", hoursAgo: 5)], from: "a", hasMore: false)
        merge.add([item("b1", source: "b", hoursAgo: 2), item("b2", source: "b", hoursAgo: 3)], from: "b", hasMore: false)
        #expect(drain(&merge) == ["a1", "b1", "b2", "a2"])
    }

    @Test func waitsForSourcesThatMayHaveNewerItems() {
        var merge = LatestMerge(now: now)
        merge.add([item("a1", source: "a", hoursAgo: 1), item("a2", source: "a", hoursAgo: 2)], from: "a", hasMore: true)
        merge.add([item("b1", source: "b", hoursAgo: 3)], from: "b", hasMore: false)
        // A próxima página de "a" pode ter itens entre 2 h e 3 h: "b1" espera
        #expect(drain(&merge) == ["a1", "a2"])
        #expect(merge.sourceToFetch(among: ["a"], newerThan: merge.buffer.first?.sortDate) == "a")
        merge.add([item("a3", source: "a", hoursAgo: 2.5), item("a4", source: "a", hoursAgo: 4)], from: "a", hasMore: true)
        // A fronteira de "a" agora é 4 h: nada que ainda falta pode passar à frente de "a4"
        #expect(drain(&merge) == ["a3", "b1", "a4"])
        #expect(merge.buffer.isEmpty)
    }

    @Test func undatedItemsFollowDatedItemsWithoutInventedDates() {
        var merge = LatestMerge(now: now)
        merge.add([item("a1", source: "a", hoursAgo: 1), item("a2", source: "a", hoursAgo: nil)], from: "a", hasMore: false)
        merge.add([item("t1", source: "t", hoursAgo: nil), item("t2", source: "t", hoursAgo: nil)], from: "t", hasMore: false)
        merge.add([item("b1", source: "b", hoursAgo: 30)], from: "b", hasMore: false)
        #expect(drain(&merge) == ["a1", "b1", "a2", "t1", "t2"])
    }

    @Test func undatedPagesRemainPaginated() {
        var merge = LatestMerge(now: now)
        merge.add([item("sem-data", source: "a", hoursAgo: nil)], from: "a", hasMore: true)
        #expect(drain(&merge).isEmpty)
        #expect(merge.sourceToFetch(among: ["a"], newerThan: nil) == "a")
        merge.add([item("pagina-2", source: "a", hoursAgo: nil)], from: "a", hasMore: false)
        #expect(drain(&merge) == ["sem-data", "pagina-2"])
    }

    @Test func datedSecondPageAppearsBeforeUndatedFirstPage() {
        var merge = LatestMerge(now: now)
        merge.add([item("sem-data", source: "a", hoursAgo: nil)], from: "a", hasMore: true)
        #expect(merge.popSafe()?.item.title == nil)
        #expect(merge.sourceToFetch(among: ["a"], newerThan: merge.buffer.first?.sortDate) == "a")
        merge.add([item("datado", source: "a", hoursAgo: 2)], from: "a", hasMore: false)
        #expect(drain(&merge) == ["datado", "sem-data"])
    }

    @Test func undatedSourceMakesProgressAndLateDatesCanBeInserted() {
        var merge = LatestMerge(now: now)
        merge.add([item("sem-data-1", source: "a", hoursAgo: nil)], from: "a", hasMore: true)
        #expect(merge.popSafe()?.item.title == nil)
        #expect(merge.sourceToFetch(among: ["a"], newerThan: merge.buffer.first?.sortDate) == "a")
        merge.add([item("sem-data-2", source: "a", hoursAgo: nil)], from: "a", hasMore: true)
        #expect(drain(&merge) == ["sem-data-1", "sem-data-2"])
        #expect(merge.sourceToFetch(among: ["a"], newerThan: nil) == "a")
        merge.add([item("datado-tardio", source: "a", hoursAgo: 3)], from: "a", hasMore: false)
        #expect(merge.popSafe(newerThan: .distantPast)?.item.title == "datado-tardio")
    }

    @Test func mixedPageWaitsForDatedFrontierBeforeUndated() {
        var merge = LatestMerge(now: now)
        merge.add([item("a1", source: "a", hoursAgo: 1), item("unknown", source: "a", hoursAgo: nil)], from: "a", hasMore: true)
        #expect(drain(&merge) == ["a1"])
        #expect(merge.sourceToFetch(among: ["a"], newerThan: merge.buffer.first?.sortDate) == "a")
        merge.add([item("a2", source: "a", hoursAgo: 4)], from: "a", hasMore: false)
        #expect(drain(&merge) == ["a2", "unknown"])
    }

    @Test func cutoffOnlyReleasesNewerItems() {
        var merge = LatestMerge(now: now)
        merge.add([item("a1", source: "a", hoursAgo: 1), item("a2", source: "a", hoursAgo: 10)], from: "a", hasMore: false)
        let cutoff = now.addingTimeInterval(-5 * 3600)
        #expect(merge.popSafe(newerThan: cutoff)?.item.title == "a1")
        #expect(merge.popSafe(newerThan: cutoff) == nil)
    }
}

struct UnifiedLatestChapterTests {
    @Test func keepsNewestChapterAcrossSources() {
        let now = Date()
        var merger = WorkMerger()
        merger.add(SourceMangaItem(sourceId: "a", remoteUrl: "/x", title: "Solo Leveling", coverUrl: nil,
                                   latestChapterName: "Cap. 10", latestChapterDate: now.addingTimeInterval(-7200)), sourceName: "A")
        merger.add(SourceMangaItem(sourceId: "b", remoteUrl: "/y", title: "Solo Leveling", coverUrl: nil,
                                   latestChapterName: "Cap. 11", latestChapterDate: now.addingTimeInterval(-600)), sourceName: "B")
        merger.add(SourceMangaItem(sourceId: "c", remoteUrl: "/z", title: "Solo Leveling", coverUrl: nil,
                                   latestChapterName: "Cap. 9"), sourceName: "C")
        #expect(merger.works.count == 1)
        #expect(merger.works[0].latestChapterName == "Cap. 11")
        #expect(merger.works[0].latestChapterCaption(now: now) == "Cap. 11 · há 10 min.")
    }
}

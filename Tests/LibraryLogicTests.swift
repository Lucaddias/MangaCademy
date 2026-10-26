import Foundation
import Testing
@testable import MihonReader

struct LibraryLogicTests {
    private func entry(_ id: String, title: String, unread: Int = 0, status: Int = 1, started: Bool = false,
                       author: String? = nil, genres: [String] = [], source: String = "Fonte", lastRead: Date? = nil) -> LibraryEntry {
        LibraryEntry(id: id, title: title, altTitles: ["Alt \(title)"], author: author, artist: nil, genres: genres,
                     sourceNames: [source], sourceIds: ["ky-\(id)"], status: status, unreadCount: unread, chapterCount: unread,
                     lastReadAt: lastRead, lastUpdated: nil, latestUploadAt: nil, favoriteAt: nil, isStarted: started,
                     hasBookmarks: false, isDownloaded: false, isTracked: false)
    }

    @Test func triStateFilters() {
        let list = [entry("a", title: "A", unread: 3), entry("b", title: "B"), entry("c", title: "C", status: 2)]
        var filters = LibraryQuery.Filters()
        filters.unread = .include
        #expect(LibraryQuery.apply(list, filters: filters, search: "", sort: .alphabetical, ascending: true).map(\.id) == ["a"])
        filters.unread = .exclude
        filters.completed = .include
        #expect(LibraryQuery.apply(list, filters: filters, search: "", sort: .alphabetical, ascending: true).map(\.id) == ["c"])
    }

    @Test func advancedSearch() {
        let a = entry("a", title: "Solo Leveling", author: "Chugong", genres: ["Ação"], source: "MangaDex")
        #expect(LibraryQuery.matches(a, search: "solo"))
        #expect(LibraryQuery.matches(a, search: "alt solo"))
        #expect(LibraryQuery.matches(a, search: "autor:chug"))
        #expect(LibraryQuery.matches(a, search: "genero:ação, src:dex"))
        #expect(!LibraryQuery.matches(a, search: "genero:romance"))
        #expect(LibraryQuery.matches(a, search: "id:a"))
    }

    @Test func tagFilterNeedsEveryTagAcrossLanguages() {
        let list = [
            entry("a", title: "A", genres: ["Romance", "School Life"]),
            entry("b", title: "B", genres: ["Romântico", "Vida Escolar", "Comédia"]),
            entry("c", title: "C", genres: ["Romance", "Sci-Fi"]),
        ]
        var filters = LibraryQuery.Filters()
        filters.tags = [GenreTags.key(for: "romance"), GenreTags.key(for: "Escolar")]
        #expect(LibraryQuery.apply(list, filters: filters, search: "", sort: .alphabetical, ascending: true).map(\.id) == ["a", "b"])
        filters.tags = [GenreTags.key(for: "Ficção Científica")]
        #expect(LibraryQuery.apply(list, filters: filters, search: "", sort: .alphabetical, ascending: true).map(\.id) == ["c"])
    }

    @Test func sortingByLastReadDescending() {
        let old = entry("a", title: "A", lastRead: Date(timeIntervalSince1970: 1))
        let new = entry("b", title: "B", lastRead: Date(timeIntervalSince1970: 100))
        let never = entry("c", title: "C")
        #expect(LibraryQuery.sorted([old, new, never], by: .lastRead, ascending: false).map(\.id) == ["b", "a", "c"])
        let shuffled = LibraryQuery.sorted([old, new, never], by: .random, ascending: true, seed: 7).map(\.id)
        #expect(LibraryQuery.sorted([never, new, old], by: .random, ascending: true, seed: 7).map(\.id) == shuffled)
    }

    @Test func chapterFlagsRoundTrip() {
        var flags = ChapterListFlags()
        #expect(ChapterListFlags(rawValue: 0) == flags)
        flags.unread = .include
        flags.downloaded = .exclude
        flags.sort = .uploadDate
        flags.descending = false
        flags.showNumber = true
        flags.hideMissing = true
        #expect(ChapterListFlags(rawValue: flags.rawValue) == flags)
    }

    @Test func chapterFlagsFilterAndOrder() {
        let chapters = (1...4).reversed().map { SourceChapterItem(remoteUrl: "/\($0)", name: "Cap \($0)", chapterNumber: Double($0), orderIndex: 4 - $0, sourceId: "s") }
        var flags = ChapterListFlags()
        flags.unread = .include
        flags.descending = false
        let result = flags.apply(chapters, isRead: { $0.chapterNumber == 2 }, isBookmarked: { _ in false }, isDownloaded: { _ in false })
        #expect(result.map(\.chapterNumber) == [1, 3, 4])
        flags.showNumber = true
        #expect(flags.displayName(chapters[0]) == "Capítulo 4")
    }

    @Test func scanlatorExclusion() {
        let chapter = SourceChapterItem(remoteUrl: "/1", name: "1", chapterNumber: 1, orderIndex: 0, scanlator: "Scan A & Scan B", sourceId: "ky-9")
        #expect(ScanlatorFilter.isExcluded(chapter, excluded: ["Scan B"]))
        #expect(ScanlatorFilter.isExcluded(chapter, excluded: [ScanlatorFilter.sourceKey("ky-9")]))
        #expect(!ScanlatorFilter.isExcluded(chapter, excluded: ["Scan C"]))
    }

    @Test func preferredSourceWinsDedupe() {
        let a = SourceChapterItem(remoteUrl: "/a1", name: "1", chapterNumber: 1, orderIndex: 0, language: "en", sourceId: "big")
        let a2 = SourceChapterItem(remoteUrl: "/a2", name: "2", chapterNumber: 2, orderIndex: 1, language: "en", sourceId: "big")
        let b = SourceChapterItem(remoteUrl: "/b1", name: "1", chapterNumber: 1, orderIndex: 0, language: "en", sourceId: "small")
        let auto = SourceAggregator.shared.chaptersByLanguage([a, a2, b])["en"]!
        #expect(auto.first { $0.chapterNumber == 1 }?.sourceId == "big")
        let preferred = SourceAggregator.shared.chaptersByLanguage([a, a2, b], preferredSourceId: "small")["en"]!
        #expect(preferred.first { $0.chapterNumber == 1 }?.sourceId == "small")
    }

    @Test func updateScheduleUsesMedianInterval() {
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = (0..<5).map { base.addingTimeInterval(Double($0) * 7 * day) }
        let interval = UpdateSchedule.medianInterval(dates)
        #expect(interval.map { abs($0 - 7 * day) < day } == true)
        let next = UpdateSchedule.nextUpdate(uploadDates: dates, now: dates.last!.addingTimeInterval(day))
        #expect(next.map { $0 > dates.last! } == true)
        #expect(UpdateSchedule.nextUpdate(uploadDates: Array(dates.prefix(2))) == nil)
    }
}

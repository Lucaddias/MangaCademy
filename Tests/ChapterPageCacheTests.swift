import Foundation
import Testing
@testable import MihonReader

struct ChapterPageCacheTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func makeCache(at dir: URL) -> ChapterPageCache { ChapterPageCache(directory: dir) }
    private func pageURL(_ n: Int) -> String { "https://img.example/c\(n)/001.jpg" }

    @discardableResult
    private func read(_ n: Int, in cache: ChapterPageCache) -> String {
        let key = ChapterPageCache.key(sourceId: "fonte", remoteUrl: "/c\(n)")
        cache.assign(urls: [pageURL(n)], to: key)
        cache.store(Data([UInt8(n)]), for: pageURL(n))
        return key
    }
    private func isCached(_ key: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(key).path)
    }

    @Test func noFixedChapterLimit() {
        let cache = makeCache(at: temporaryDirectory())
        for n in 1...20 { read(n, in: cache) }
        #expect(cache.chapterCount == 20)
    }

    @Test func progressPolicyCountsThreeDistinctLaterReadChapters() {
        let read = [true, true, true, false, false, true]
        let partial = [false, false, false, true, true, false]
        let ids = ["4", "3", "2", "1", "0", "old"]
        #expect(ChapterCachePolicy.eligible(read: read, partial: partial, identity: ids) == [0, 1, 2, 3, 4, 5])
        #expect(ChapterCachePolicy.eligible(read: [true, true, false], partial: [false, false, true], identity: ["2", "2", "1"]) == [0, 1])
        #expect(ChapterCachePolicy.eligible(read: [true, true, false], partial: [false, false, true], identity: ["3", "2", "1"]) == [0, 1])
    }

    @Test func protectedAndOldRequestsCannotRecreateRemovedPages() {
        let dir = temporaryDirectory()
        let cache = makeCache(at: dir)
        let key = read(1, in: cache)
        let old = cache.registration(for: pageURL(1))!
        let owner = UUID()
        cache.setProtected([key], owner: owner)
        cache.removeEligible([key])
        #expect(isCached(key, in: dir))
        cache.releaseProtection(owner: owner)
        cache.removeEligible([key])
        #expect(!isCached(key, in: dir))
        #expect(cache.store(Data([3]), for: pageURL(1), expected: old))
        #expect(!isCached(key, in: dir))
        cache.assign(urls: [pageURL(1)], to: key)
        #expect(cache.store(Data([4]), for: pageURL(1), expected: old))
        #expect(!isCached(key, in: dir))
        #expect(cache.store(Data([5]), for: pageURL(1)))
        #expect(cache.data(for: pageURL(1)) == Data([5]))
    }

    @Test func interruptedDeletionIsRecoveredWithoutDeletingChapter() throws {
        let dir = temporaryDirectory()
        let orphan = dir.appendingPathComponent(".trash-interrupted", isDirectory: true)
        let chapter = dir.appendingPathComponent("chapter", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
        try Data([1]).write(to: orphan.appendingPathComponent("page"))
        let cache = makeCache(at: dir)
        cache.waitForRecovery()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: chapter.path))
        #expect(cache.chapterCount == 1)
    }

    @Test func recoveryDoesNotDeleteTrashOwnedByActiveCleanup() throws {
        let dir = temporaryDirectory()
        let cache = makeCache(at: dir)
        cache.waitForRecovery()
        let key = read(1, in: cache)
        let moved = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        cache.onTrashMoved = { moved.signal(); resume.wait() }
        DispatchQueue.global().async {
            cache.removeEligible([key])
            finished.signal()
        }
        moved.wait()
        let paths = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".trash-") }
        #expect(paths.count == 1)
        let otherInstance = makeCache(at: dir)
        otherInstance.waitForRecovery()
        if let path = paths.first { #expect(FileManager.default.fileExists(atPath: path.path)) }
        resume.signal()
        finished.wait()
        if let path = paths.first { #expect(!FileManager.default.fileExists(atPath: path.path)) }
    }

    @Test func concurrentReaderProtectionPreventsIncognitoCleanup() {
        let dir = temporaryDirectory()
        let cache = makeCache(at: dir)
        let key = read(1, in: cache)
        let incognito = UUID()
        let otherReader = UUID()
        cache.setProtected([key], owner: incognito)
        cache.setProtected([key], owner: otherReader)
        cache.releaseProtection(owner: incognito)
        cache.removeEligible([key])
        #expect(isCached(key, in: dir))
        cache.releaseProtection(owner: otherReader)
        cache.removeEligible([key])
        #expect(!isCached(key, in: dir))
    }

    @Test func simultaneousProtectionAndCleanupAreLinearizable() {
        let dir = temporaryDirectory()
        let cache = makeCache(at: dir)
        let key = read(1, in: cache)
        let owner = UUID()
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            cache.setProtected([key], owner: owner)
            ready.signal()
            done.wait()
        }
        ready.wait()
        cache.removeEligible([key])
        #expect(isCached(key, in: dir))
        done.signal()
        cache.releaseProtection(owner: owner)
        cache.removeEligible([key])
        #expect(!isCached(key, in: dir))
    }

    @Test func concurrentOldWritesCannotSurviveEviction() {
        let dir = temporaryDirectory()
        let cache = makeCache(at: dir)
        let key = read(1, in: cache)
        let old = cache.registration(for: pageURL(1))!
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index == 0 { cache.removeEligible([key]) }
            else { cache.store(Data([UInt8(index)]), for: pageURL(1), expected: old) }
        }
        #expect(!isCached(key, in: dir))
    }

    @Test func clearInvalidatesPendingWrites() {
        let cache = makeCache(at: temporaryDirectory())
        read(1, in: cache)
        let old = cache.registration(for: pageURL(1))!
        cache.clear()
        #expect(cache.store(Data([1]), for: pageURL(1), expected: old))
        #expect(cache.chapterCount == 0)
    }

    @Test func registeredPagesSkipCoverCache() {
        let dir = temporaryDirectory()
        let chapters = makeCache(at: dir.appendingPathComponent("ChapterPages"))
        let store = ImageDiskStore(directory: dir.appendingPathComponent("Covers"), chapters: chapters)
        read(1, in: chapters)
        store.store(Data([9]), for: pageURL(1))
        store.store(Data([7]), for: "https://img.example/capa.jpg")

        #expect(store.data(for: pageURL(1)) == Data([9]))
        #expect(!FileManager.default.fileExists(atPath: store.path(for: pageURL(1)).path))
        #expect(store.data(for: "https://img.example/capa.jpg") == Data([7]))
        #expect(store.coverSize == 1)
    }

    @Test func coverLimitTrimsOldestFirst() throws {
        let dir = temporaryDirectory()
        let chapters = makeCache(at: dir.appendingPathComponent("ChapterPages"))
        let store = ImageDiskStore(directory: dir.appendingPathComponent("Covers"), coverLimit: 250, chapters: chapters)
        let blob = Data(repeating: 1, count: 100)
        let covers = ["a", "b", "c", "d"].map { "https://img.example/\($0).jpg" }
        for (i, url) in covers.enumerated() {
            store.store(blob, for: url)
            let date = Date(timeIntervalSinceNow: Double(i - 10) * 3600)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: store.path(for: url).path)
        }
        // Ler a capa mais antiga conta como uso recente.
        #expect(store.data(for: covers[0]) == blob)

        store.trim()
        #expect(store.coverSize == 200)
        let remaining = covers.filter { FileManager.default.fileExists(atPath: store.path(for: $0).path) }
        #expect(remaining == [covers[0], covers[3]])
    }

    @Test func legacyCacheIsClearedOnce() {
        let dir = temporaryDirectory()
        let defaults = UserDefaults(suiteName: "img-\(UUID().uuidString)")!
        let chapters = makeCache(at: dir.appendingPathComponent("ChapterPages"))
        let store = ImageDiskStore(directory: dir.appendingPathComponent("MangaImageCache"), chapters: chapters)
        store.store(Data([1]), for: "antiga")

        store.migrateLegacyCache(defaults: defaults)
        #expect(store.data(for: "antiga") == nil)

        store.store(Data([2]), for: "nova")
        store.migrateLegacyCache(defaults: defaults)
        #expect(store.data(for: "nova") == Data([2]))
    }
}

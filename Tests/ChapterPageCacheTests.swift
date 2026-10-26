import Foundation
import Testing
@testable import MihonReader

struct ChapterPageCacheTests {
    /// Relógio que anda 1 s a cada leitura, para a ordem de uso não depender do tempo real.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0

        func now() -> Date {
            lock.withLock {
                seconds += 1
                return Date(timeIntervalSince1970: seconds)
            }
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func makeCache(at dir: URL) -> ChapterPageCache {
        let clock = Clock()
        return ChapterPageCache(directory: dir, now: { clock.now() })
    }

    private func pageURL(_ n: Int) -> String { "https://img.example/c\(n)/001.jpg" }

    /// Lê (grava) uma página do capítulo `n` e devolve a chave dele.
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

    @Test func eleventhChapterEvictsTheOldest() {
        let dir = temporaryDirectory()
        let cache = makeCache(at: dir)
        let keys = (1...10).map { read($0, in: cache) }
        #expect(cache.chapterCount == 10)

        let newest = read(11, in: cache)
        #expect(cache.chapterCount == 10)
        #expect(!isCached(keys[0], in: dir))
        #expect(isCached(keys[1], in: dir))
        #expect(isCached(newest, in: dir))
        #expect(cache.data(for: pageURL(1)) == nil)
        #expect(cache.data(for: pageURL(11)) == Data([11]))
    }

    @Test func pinnedChapterIsNeverEvicted() {
        let dir = temporaryDirectory()
        let cache = makeCache(at: dir)
        let open = read(1, in: cache)
        let next = read(2, in: cache)
        cache.enforceLimit(pinned: [open, next])

        for n in 3...30 { read(n, in: cache) }
        #expect(cache.chapterCount == 10)
        #expect(isCached(open, in: dir))
        #expect(isCached(next, in: dir))
        #expect(cache.data(for: pageURL(1)) == Data([1]))
        #expect(!isCached(ChapterPageCache.key(sourceId: "fonte", remoteUrl: "/c3"), in: dir))

        // Sem proteção, o capítulo 2 (o 1 acabou de ser lido) volta a ser o mais antigo.
        cache.enforceLimit(pinned: [])
        read(31, in: cache)
        #expect(!isCached(next, in: dir))
    }

    @Test func touchChangesOrder() {
        let dir = temporaryDirectory()
        let cache = makeCache(at: dir)
        let keys = (1...10).map { read($0, in: cache) }
        cache.touch(keys[0])

        read(11, in: cache)
        #expect(isCached(keys[0], in: dir))
        #expect(!isCached(keys[1], in: dir))

        // A ordem de uso sobrevive a reabrir o app.
        let reopened = ChapterPageCache(directory: dir, limit: 9)
        reopened.enforceLimit(pinned: [])
        #expect(reopened.chapterCount == 9)
        #expect(!isCached(keys[2], in: dir))
        #expect(isCached(keys[0], in: dir))
    }

    @Test func removeAndClear() {
        let dir = temporaryDirectory()
        let cache = makeCache(at: dir)
        let first = read(1, in: cache)
        read(2, in: cache)
        cache.remove(chapter: first)
        #expect(cache.chapterCount == 1)
        #expect(cache.data(for: pageURL(1)) == nil)

        cache.clear()
        #expect(cache.chapterCount == 0)
        #expect(cache.size == 0)
        // A página continua registrada: a próxima leitura volta para a pasta do capítulo.
        cache.store(Data([2]), for: pageURL(2))
        #expect(cache.chapterCount == 1)
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

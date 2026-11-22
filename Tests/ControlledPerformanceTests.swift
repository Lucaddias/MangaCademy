import Foundation
import SwiftData
import Testing
import UIKit
@testable import MihonReader

private final class PageResponse: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests = 0
    static var payload = Data()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "page-benchmark.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png", "Cache-Control": "no-store"])!
        let data = Self.lock.withLock { Self.payload }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
struct ControlledPerformanceTests {
    @Test func readerColdOverlap() async {
        let drawing = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 240)).pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 240))
        }
        PageResponse.lock.withLock {
            PageResponse.payload = drawing
            PageResponse.requests = 0
        }
        URLProtocol.registerClass(PageResponse.self)
        defer { URLProtocol.unregisterClass(PageResponse.self) }
        for _ in 0..<3 {
            let url = "https://page-benchmark.invalid/" + UUID().uuidString
            async let preload: Void = ImageCache.shared.prefetch(urlString: url, referer: nil)
            async let display = ImageCache.shared.loadForDisplay(urlString: url, referer: nil, maxPixelWidth: 120, cropBorders: false)
            let (_, image) = await (preload, display)
            #expect(image != nil)
        }
        print("PERF_NETWORK_REQUESTS \(PageResponse.lock.withLock { PageResponse.requests })")
    }

    @Test func repeatedChapterSync() throws {
        let config = ModelConfiguration(schema: ModelStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStore.schema, configurations: config)
        let context = container.mainContext
        let manga = Manga(sourceId: "fixture", remoteUrl: "/work", title: "Obra", isFavorite: true)
        let start = Date(timeIntervalSince1970: 1_000_000)
        manga.favoriteAt = start
        manga.preferredLanguage = "pt-BR"
        context.insert(manga)
        let list = (1...600).map { i in SourceChapterItem(
            remoteUrl: "/ch/\(i)", name: "Capítulo \(i)", chapterNumber: Double(i), orderIndex: 600 - i,
            scanlator: "Fixture", uploadDate: start.addingTimeInterval(Double(i)), language: "pt-BR", sourceId: "fixture", mangaRemoteUrl: "/work"
        ) }
        let groups = ["pt-BR": list]
        ChapterStore.sync(groups, manga: manga, context: context, now: start)
        for i in 1...6 {
            let begin = ProcessInfo.processInfo.systemUptime
            ChapterStore.sync(groups, manga: manga, context: context, now: start.addingTimeInterval(Double(i)))
            let ms = (ProcessInfo.processInfo.systemUptime - begin) * 1_000
            print("PERF_SYNC_MS \(String(format: "%.1f", ms))")
        }
        #expect(manga.unreadCount == 600)
        #expect(ChapterStore.records(mangaId: manga.id, context: context).count == 600)
    }
}

extension ControlledPerformanceTests {
    @Test func chapterListWithDefaultFilters() {
        let list = (1...600).map { n in SourceChapterItem(remoteUrl: "/\(n)", name: "Capítulo \(n)", chapterNumber: Double(n), orderIndex: 600 - n, language: "pt-BR", sourceId: "fixture") }
        let flags = ChapterListFlags(rawValue: 0)
        var probes = 0
        let begin = ProcessInfo.processInfo.systemUptime
        let visible = flags.apply(list, isRead: { _ in false }, isBookmarked: { _ in false }, isDownloaded: {
            probes += 1
            return DownloadStore.shared.isDownloaded($0, mangaId: "missing-fixture")
        })
        let ms = 1000 * (ProcessInfo.processInfo.systemUptime - begin)
        #expect(visible.count == 600)
        print("PERF_DEFAULT_FILTER_DISK_PROBES \(probes) \(String(format: "%.1f", ms)) ms")
    }
}

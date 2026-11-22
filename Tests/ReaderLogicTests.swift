import Foundation
import Testing
@testable import MihonReader

struct ReaderLogicTests {
    @Test func lShapedZones() {
        let layout = TapZoneLayout.lShaped
        #expect(layout.action(at: CGPoint(x: 0.5, y: 0.1), inversion: .none) == .previous)
        #expect(layout.action(at: CGPoint(x: 0.5, y: 0.5), inversion: .none) == .menu)
        #expect(layout.action(at: CGPoint(x: 0.9, y: 0.5), inversion: .none) == .next)
        #expect(layout.action(at: CGPoint(x: 0.1, y: 0.9), inversion: .none) == .next)
    }

    /// Na leitura da direita para a esquerda, tocar à esquerda avança.
    @Test func rightToLeftMirrorsZones() {
        let layout = TapZoneLayout.rightAndLeft
        #expect(layout.action(at: CGPoint(x: 0.1, y: 0.5), inversion: .none) == .previous)
        #expect(layout.action(at: CGPoint(x: 0.1, y: 0.5), inversion: .none, mirrored: true) == .next)
        // Inverter de novo desfaz o espelhamento.
        #expect(layout.action(at: CGPoint(x: 0.1, y: 0.5), inversion: .horizontal, mirrored: true) == .previous)
    }

    @Test func kindleVerticalInversion() {
        #expect(TapZoneLayout.kindle.action(at: CGPoint(x: 0.5, y: 0.05), inversion: .none) == .menu)
        #expect(TapZoneLayout.kindle.action(at: CGPoint(x: 0.5, y: 0.95), inversion: .vertical) == .menu)
    }

    @Test func missingChapters() {
        #expect(ChapterGaps.missing(between: 10, and: 14) == 3)
        #expect(ChapterGaps.missing(between: 14, and: 10) == 3)
        #expect(ChapterGaps.missing(between: 10, and: 10.5) == 0)
        #expect(ChapterGaps.missing(between: 10, and: 11) == 0)
        #expect(ChapterGaps.missing(between: -1, and: 30) == 0)
    }

    @Test func readerSettingsRoundTrip() async {
        let defaults = UserDefaults(suiteName: "reader-\(UUID().uuidString)")!
        await MainActor.run {
            let settings = ReaderSettings(defaults: defaults)
            #expect(settings.defaultMode == .webtoon)
            settings.defaultMode = .pagedRTL
            settings.tapZones = .kindle
            let reloaded = ReaderSettings(defaults: defaults)
            #expect(reloaded.defaultMode == .pagedRTL)
            #expect(reloaded.tapZones == .kindle)
        }
    }

    @Test func imageDiskStoreCoalescesSameURLAndReferer() async {
        let url = "https://reader-fetch-test.invalid/coalesce-\(UUID().uuidString)"
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ReaderFetchStubProtocol.configure(url: url, responses: [(200, payload)])
        URLProtocol.registerClass(ReaderFetchStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(ReaderFetchStubProtocol.self)
            ImageDiskStore.shared.remove(url)
            ReaderFetchStubProtocol.reset()
        }

        async let prefetched: Void = ImageCache.shared.prefetch(urlString: url, referer: "https://example.invalid")
        async let fetched = ImageDiskStore.shared.fetch(urlString: url, referer: "https://example.invalid")
        let (_, data) = await (prefetched, fetched)

        #expect(data == payload)
        #expect(ReaderFetchStubProtocol.requestCount(for: url) == 1)
    }

    @Test func imageDiskStoreRetriesAfterFailureWithoutStaleInFlight() async {
        let url = "https://reader-fetch-test.invalid/retry-\(UUID().uuidString)"
        let payload = Data([1, 2, 3, 4])
        ReaderFetchStubProtocol.configure(url: url, responses: [(500, Data()), (200, payload)])
        URLProtocol.registerClass(ReaderFetchStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(ReaderFetchStubProtocol.self)
            ImageDiskStore.shared.remove(url)
            ReaderFetchStubProtocol.reset()
        }

        let first = await ImageDiskStore.shared.fetch(urlString: url, referer: "https://example.invalid")
        let second = await ImageDiskStore.shared.fetch(urlString: url, referer: "https://example.invalid")

        #expect(first == nil)
        #expect(second == payload)
        #expect(ReaderFetchStubProtocol.requestCount(for: url) == 2)
    }

    @Test func imageDiskStoreReadsLocalFileWithoutNetworkRequest() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-local-\(UUID().uuidString).bin")
        let payload = Data([9, 8, 7, 6])
        try payload.write(to: tempURL)
        URLProtocol.registerClass(ReaderFetchStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(ReaderFetchStubProtocol.self)
            try? FileManager.default.removeItem(at: tempURL)
            ReaderFetchStubProtocol.reset()
        }

        let data = await ImageDiskStore.shared.fetch(urlString: tempURL.absoluteString, referer: "https://example.invalid")

        #expect(data == payload)
        #expect(ReaderFetchStubProtocol.totalRequests() == 0)
    }
}

private final class ReaderFetchStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var queues: [String: [(Int, Data)]] = [:]
    private static var counts: [String: Int] = [:]
    private static var allCount = 0

    static func configure(url: String, responses: [(Int, Data)]) {
        lock.withLock {
            queues[url] = responses
            counts[url] = 0
        }
    }

    static func reset() {
        lock.withLock {
            queues.removeAll()
            counts.removeAll()
            allCount = 0
        }
    }

    static func requestCount(for url: String) -> Int {
        lock.withLock { counts[url] ?? 0 }
    }

    static func totalRequests() -> Int {
        lock.withLock { allCount }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "reader-fetch-test.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = url.absoluteString
        let next: (Int, Data) = Self.lock.withLock {
            Self.allCount += 1
            Self.counts[key, default: 0] += 1
            var list = Self.queues[key] ?? [(404, Data())]
            let item = list.isEmpty ? (404, Data()) : list.removeFirst()
            Self.queues[key] = list
            return item
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: next.0,
            httpVersion: "HTTP/1.1",
            headerFields: ["Cache-Control": "no-store"]
        )!
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: next.1)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

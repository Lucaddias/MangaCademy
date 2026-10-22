import Foundation
import Testing
@testable import MihonReader

@MainActor
@Suite(.serialized)
struct DownloadTests {
    private func chapter(_ n: Int) -> SourceChapterItem {
        SourceChapterItem(remoteUrl: "/c\(n)", name: "Cap. \(n)", chapterNumber: Double(n), orderIndex: 10 - n, sourceId: "fonte-inexistente", mangaRemoteUrl: "/m")
    }

    @Test func detectsImageTypes() {
        #expect(DownloadManager.fileExtension(for: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0])) == "png")
        #expect(DownloadManager.fileExtension(for: Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])) == "webp")
        #expect(DownloadManager.fileExtension(for: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
    }

    @Test func queuePersistsAndSkipsDownloaded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DownloadStore(root: dir.appendingPathComponent("Downloads"))
        let settings = DownloadSettings(defaults: UserDefaults(suiteName: "dl-\(UUID().uuidString)")!)
        let queueURL = dir.appendingPathComponent("queue.json")
        let manager = DownloadManager(store: store, settings: settings, queueURL: queueURL)
        manager.pause()
        defer { manager.resume() }

        // Capítulo 1 já baixado.
        let done = chapter(1)
        try FileManager.default.createDirectory(at: store.chapterDirectory(for: done, mangaId: "m"), withIntermediateDirectories: true)
        try store.finish(chapter: done, mangaId: "m", files: ["001.jpg"])
        #expect(manager.state(of: done, mangaId: "m") == .downloaded)

        #expect(manager.enqueue([done, chapter(2), chapter(3)], mangaId: "m", mangaTitle: "Obra") == 2)
        #expect(manager.enqueue([chapter(2)], mangaId: "m", mangaTitle: "Obra") == 0)
        // Ordem de leitura: o mais antigo (maior orderIndex) primeiro.
        #expect(manager.queue.map(\.name) == ["Cap. 2", "Cap. 3"])
        #expect(manager.state(of: chapter(2), mangaId: "m") == .queued)

        let reopened = DownloadManager(store: store, settings: settings, queueURL: queueURL)
        #expect(reopened.queue.count == 2)
        #expect(reopened.queue.first?.chapter.remoteUrl == "/c2")

        manager.delete([chapter(2), done], mangaId: "m")
        #expect(manager.queue.map(\.name) == ["Cap. 3"])
        #expect(manager.state(of: done, mangaId: "m") == .none)
    }
}

import Foundation
import CryptoKit

/// Capítulos baixados no aparelho: `Application Support/Downloads/<obra>/<capítulo>/001.jpg…`
/// com um `pages.json` listando as páginas. Só disco, sem rede (a fila fica no `DownloadManager`).
public final class DownloadStore: @unchecked Sendable {
    public static let shared = DownloadStore()

    public let root: URL
    private let fm = FileManager.default

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        self.root = base
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        // Downloads não vão para o backup do iCloud (podem ser baixados de novo).
        var url = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    struct Manifest: Codable {
        var chapterName: String
        var files: [String]
        var downloadedAt: Date
    }

    static func folderName(_ id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return digest
    }

    public func mangaDirectory(mangaId: String) -> URL {
        root.appendingPathComponent(Self.folderName(mangaId), isDirectory: true)
    }

    public func chapterDirectory(for chapter: SourceChapterItem, mangaId: String) -> URL {
        let chapterId = Chapter.storageId(mangaId: mangaId, sourceId: chapter.sourceId, remoteUrl: chapter.remoteUrl)
        return mangaDirectory(mangaId: mangaId).appendingPathComponent(Self.folderName(chapterId), isDirectory: true)
    }

    public func isDownloaded(_ chapter: SourceChapterItem, mangaId: String) -> Bool {
        fm.fileExists(atPath: chapterDirectory(for: chapter, mangaId: mangaId).appendingPathComponent("pages.json").path)
    }

    /// Páginas do capítulo baixado (endereços `file://`), ou nil se não estiver baixado.
    public func downloadedPages(for chapter: SourceChapterItem, mangaId: String) -> [SourcePageItem]? {
        let dir = chapterDirectory(for: chapter, mangaId: mangaId)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("pages.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return manifest.files.enumerated().map { index, file in
            SourcePageItem(pageNumber: index + 1, imageUrl: dir.appendingPathComponent(file).absoluteString)
        }
    }

    /// Grava o manifesto: o capítulo passa a contar como baixado.
    func finish(chapter: SourceChapterItem, mangaId: String, files: [String]) throws {
        let dir = chapterDirectory(for: chapter, mangaId: mangaId)
        let manifest = Manifest(chapterName: chapter.name, files: files, downloadedAt: Date())
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("pages.json"), options: .atomic)
    }

    public func delete(_ chapter: SourceChapterItem, mangaId: String) {
        try? fm.removeItem(at: chapterDirectory(for: chapter, mangaId: mangaId))
    }

    public func deleteManga(mangaId: String) {
        try? fm.removeItem(at: mangaDirectory(mangaId: mangaId))
    }

    public func deleteAll() {
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Bytes ocupados por uma pasta.
    public func size(of directory: URL) -> Int64 {
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    public func size(mangaId: String) -> Int64 { size(of: mangaDirectory(mangaId: mangaId)) }
    public var totalSize: Int64 { size(of: root) }
}

import Foundation

/// De onde vêm as páginas de um capítulo: primeiro o que já está baixado no aparelho,
/// depois a fonte na internet.
@MainActor
enum ChapterPageProvider {
    enum Failure: LocalizedError {
        case sourceUnavailable
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .sourceUnavailable: return "Capítulo ou fonte indisponível"
            case .empty(let source): return "Nenhuma página encontrada neste capítulo (\(source))."
            }
        }
    }

    static func pages(for chapter: SourceChapterItem, mangaId: String) async throws -> [SourcePageItem] {
        if let local = DownloadStore.shared.downloadedPages(for: chapter, mangaId: mangaId), !local.isEmpty {
            return local
        }
        guard let source = SourceManager.shared.getSource(id: chapter.sourceId) else { throw Failure.sourceUnavailable }
        let pages = try await source.fetchPages(chapterRemoteUrl: chapter.remoteUrl, mangaRemoteUrl: chapter.mangaRemoteUrl)
        guard !pages.isEmpty else { throw Failure.empty(source.name) }
        cache(pages, of: chapter)
        return pages
    }

    /// Páginas da internet ficam na pasta temporária do capítulo.
    private static func cache(_ pages: [SourcePageItem], of chapter: SourceChapterItem) {
        // Páginas da Fonte Local já estão no aparelho.
        let urls = pages.map(\.imageUrl).filter { !$0.hasPrefix("file:") }
        guard !urls.isEmpty else { return }
        let key = ChapterPageCache.key(for: chapter)
        ChapterPageCache.shared.assign(urls: urls, to: key)
    }
}

/// Capas escolhidas pelo usuário, em Application Support/Covers.
enum CustomCoverStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Grava a capa e devolve o nome do arquivo (para `Manga.customCoverPath`).
    static func save(_ data: Data) -> String? {
        let name = "\(UUID().uuidString).jpg"
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func url(for name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        return directory.appendingPathComponent(name)
    }

    static func remove(_ name: String?) {
        guard let url = url(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

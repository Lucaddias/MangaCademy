import Foundation
import CryptoKit

/// Páginas lidas da internet, separadas por capítulo: `Caches/ChapterPages/<capítulo>/<página>`.
/// Guarda no máximo `limit` capítulos; ao passar disso, apaga o usado há mais tempo, menos os
/// protegidos (o capítulo aberto no leitor e o próximo já carregado).
/// Downloads (`file://`) não passam por aqui e não contam no limite.
public final class ChapterPageCache: @unchecked Sendable {
    public static let shared = ChapterPageCache()

    public let directory: URL
    /// Máximo de capítulos no cache.
    public let limit: Int

    private let fm = FileManager.default
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let indexURL: URL
    /// Último acesso de cada capítulo, gravado em `index.json`.
    private var lastAccess: [String: Date] = [:]
    /// Capítulo de cada página. Só em memória: o leitor registra as páginas ao abrir o capítulo.
    private var chapterOfURL: [String: String] = [:]
    /// Capítulos que não podem ser apagados agora (vale também para os gravados depois).
    private var pinned: Set<String> = []

    public init(directory: URL? = nil, limit: Int = 10, now: @escaping @Sendable () -> Date = { Date() }) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChapterPages", isDirectory: true)
        self.directory = base
        self.limit = limit
        self.now = now
        indexURL = base.appendingPathComponent("index.json")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            lastAccess = decoded
        }
    }

    /// Chave estável do capítulo (nome da pasta).
    public static func key(sourceId: String, remoteUrl: String) -> String {
        hex(sourceId + remoteUrl)
    }

    public static func key(for chapter: SourceChapterItem) -> String {
        key(sourceId: chapter.sourceId, remoteUrl: chapter.remoteUrl)
    }

    private static func hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func folder(for key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: true)
    }

    private func file(for urlString: String, key: String) -> URL {
        folder(for: key).appendingPathComponent(Self.hex(urlString))
    }

    // MARK: - Páginas

    /// Registra as páginas do capítulo: daqui em diante elas são lidas e gravadas na pasta dele.
    public func assign(urls: [String], to key: String) {
        lock.withLock {
            for url in urls { chapterOfURL[url] = key }
        }
        touch(key)
    }

    /// Se a página pertence a algum capítulo registrado.
    public func isRegistered(_ urlString: String) -> Bool {
        lock.withLock { chapterOfURL[urlString] != nil }
    }

    /// Bytes da página, se ela é de um capítulo registrado e já está no disco.
    public func data(for urlString: String) -> Data? {
        guard let key = lock.withLock({ chapterOfURL[urlString] }),
              let data = try? Data(contentsOf: file(for: urlString, key: key)) else { return nil }
        touch(key)
        return data
    }

    /// Grava a página na pasta do capítulo dela. Devolve false se ela não é de nenhum capítulo.
    @discardableResult
    public func store(_ data: Data, for urlString: String) -> Bool {
        let key: String? = lock.withLock {
            guard let key = chapterOfURL[urlString] else { return nil }
            let folder = folder(for: key)
            if !fm.fileExists(atPath: folder.path) {
                // Capítulo novo: abre espaço antes de criar a pasta, para nunca passar do limite.
                evict(keeping: pinned.union([key]), maxCount: limit - 1)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            return key
        }
        guard let key else { return false }
        try? data.write(to: file(for: urlString, key: key), options: .atomic)
        touch(key)
        return true
    }

    /// Marca o capítulo como usado agora.
    public func touch(_ key: String) {
        lock.withLock {
            let date = now()
            let previous = lastAccess[key]
            lastAccess[key] = date
            // A ordem em memória é exata; no disco basta valer ao minuto (evita regravar a cada página).
            if previous.map({ date.timeIntervalSince($0) > 60 }) ?? true { saveIndex() }
        }
    }

    // MARK: - Limite

    /// Apaga os capítulos usados há mais tempo até sobrarem `limit`, sem tocar nos protegidos.
    /// A proteção continua valendo para os capítulos gravados depois, até a próxima chamada.
    public func enforceLimit(pinned: Set<String>) {
        lock.withLock {
            self.pinned = pinned
            evict(keeping: pinned, maxCount: limit)
        }
    }

    /// Chamar com o lock.
    private func evict(keeping protected: Set<String>, maxCount: Int) {
        var folders = chapterFolders()
        // O índice só guarda capítulos que existem no disco (ou que estão protegidos).
        lastAccess = lastAccess.filter { folders.contains($0.key) || protected.contains($0.key) }
        var candidates = folders.subtracting(protected)
            .sorted { (lastAccess[$0] ?? .distantPast) < (lastAccess[$1] ?? .distantPast) }
        while folders.count > maxCount, !candidates.isEmpty {
            let oldest = candidates.removeFirst()
            try? fm.removeItem(at: folder(for: oldest))
            folders.remove(oldest)
            lastAccess[oldest] = nil
        }
        saveIndex()
    }

    /// Chamar com o lock.
    private func chapterFolders() -> Set<String> {
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return Set(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent))
    }

    /// Chamar com o lock.
    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(lastAccess) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Limpeza

    /// Apaga a pasta do capítulo (as páginas serão baixadas de novo).
    public func remove(chapter key: String) {
        lock.withLock {
            try? fm.removeItem(at: folder(for: key))
            lastAccess[key] = nil
            saveIndex()
        }
    }

    /// Apaga todos os capítulos. As páginas registradas voltam a ser gravadas na próxima leitura.
    public func clear() {
        lock.withLock {
            try? fm.removeItem(at: directory)
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            lastAccess = [:]
        }
    }

    /// Capítulos no cache agora.
    public var chapterCount: Int {
        lock.withLock { chapterFolders().count }
    }

    /// Espaço ocupado, em bytes.
    public var size: Int64 {
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

import Foundation
import CryptoKit

/// Impede que a recuperação de outra instância apague uma pasta em remoção ativa.
private final class ChapterTrashRegistry: @unchecked Sendable {
    static let shared = ChapterTrashRegistry()
    private let lock = NSLock()
    private var claimed = Set<String>()
    func claim(_ path: String) -> Bool { lock.withLock { claimed.insert(path).inserted } }
    func release(_ path: String) { _ = lock.withLock { claimed.remove(path) } }
}

/// Páginas temporárias da internet, separadas por capítulo. Downloads não usam este cache.
public final class ChapterPageCache: @unchecked Sendable {
    public static let shared = ChapterPageCache()
    public let directory: URL
    private let fm = FileManager.default
    private let lock = NSLock()
    private let ioLock = NSLock()
    private let recoveryQueue = DispatchQueue(label: "ChapterPageCache.recovery", qos: .utility)
    var onTrashMoved: (@Sendable () -> Void)?
    private var chapterOfURL: [String: String] = [:]
    private var generations: [String: UInt64] = [:]
    private var disabled = Set<String>()
    private var protectedByOwner: [UUID: Set<String>] = [:]

    public struct Registration: Equatable, Sendable {
        fileprivate let key: String
        fileprivate let generation: UInt64
    }

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChapterPages", isDirectory: true)
        try? fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
        recoveryQueue.async { [self] in recoverAbandonedTrash() }
    }

    public static func key(sourceId: String, remoteUrl: String) -> String { hex(sourceId + remoteUrl) }
    public static func key(for chapter: SourceChapterItem) -> String { key(sourceId: chapter.sourceId, remoteUrl: chapter.remoteUrl) }
    private static func hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func folder(for key: String) -> URL { directory.appendingPathComponent(key, isDirectory: true) }
    private func file(for url: String, key: String) -> URL { folder(for: key).appendingPathComponent(Self.hex(url)) }

    /// Registro é apenas em memória, sem operações de disco na thread do leitor.
    public func assign(urls: [String], to key: String) {
        lock.withLock {
            generations[key, default: 0] &+= 1
            disabled.remove(key)
            for url in urls { chapterOfURL[url] = key }
        }
    }
    public func isRegistered(_ url: String) -> Bool { lock.withLock { chapterOfURL[url] != nil } }
    public func registration(for url: String) -> Registration? {
        lock.withLock {
            guard let key = chapterOfURL[url] else { return nil }
            return Registration(key: key, generation: generations[key, default: 0])
        }
    }
    public func data(for url: String) -> Data? {
        ioLock.withLock {
            guard let key = lock.withLock({ chapterOfURL[url].flatMap { disabled.contains($0) ? nil : $0 } }) else { return nil }
            return try? Data(contentsOf: file(for: url, key: key))
        }
    }
    /// A gravação e exclusão são serializadas. Uma resposta antiga nunca recria uma pasta removida.
    @discardableResult
    public func store(_ data: Data, for url: String, expected: Registration? = nil) -> Bool {
        ioLock.withLock {
            let state: (String?, Bool) = lock.withLock {
                guard let key = chapterOfURL[url] else { return (nil, expected != nil) }
                let allowed = !disabled.contains(key) && (expected == nil || expected == Registration(key: key, generation: generations[key, default: 0]))
                return (allowed ? key : nil, true)
            }
            guard let key = state.0 else { return state.1 }
            do {
                try fm.createDirectory(at: folder(for: key), withIntermediateDirectories: true)
                try data.write(to: file(for: url, key: key), options: .atomic)
            } catch { return true }
            return true
        }
    }
    /// Cada leitor protege seu capítulo atual e o pré-carregado, sem afetar outros leitores.
    public func setProtected(_ keys: Set<String>, owner: UUID) {
        lock.withLock { protectedByOwner[owner] = keys }
    }
    public func releaseProtection(owner: UUID) {
        _ = lock.withLock { protectedByOwner.removeValue(forKey: owner) }
    }
    public func removeEligible(_ keys: Set<String>) {
        // A decisão e a retirada da pasta são atômicas com setProtected. A remoção
        // potencialmente lenta dos arquivos acontece depois, sem segurar o lock de estado.
        let trash: [URL] = ioLock.withLock {
            lock.withLock {
                let protected = protectedByOwner.values.reduce(into: Set<String>()) { $0.formUnion($1) }
                var moved: [URL] = []
                for key in keys.subtracting(protected) {
                    let source = folder(for: key)
                    if fm.fileExists(atPath: source.path) {
                        let destination = directory.appendingPathComponent(".trash-\(UUID().uuidString)", isDirectory: true)
                        guard ChapterTrashRegistry.shared.claim(destination.path) else { continue }
                        guard (try? fm.moveItem(at: source, to: destination)) != nil else {
                            ChapterTrashRegistry.shared.release(destination.path)
                            continue
                        }
                        moved.append(destination)
                    }
                    invalidateLocked(key)
                }
                return moved
            }
        }
        if !trash.isEmpty { onTrashMoved?() }
        for url in trash {
            try? fm.removeItem(at: url)
            ChapterTrashRegistry.shared.release(url.path)
        }
    }
    func waitForRecovery() { recoveryQueue.sync {} }

    /// Remove resíduos deixados por encerramento ou falha em uma limpeza anterior.
    /// Pastas pertencentes a uma limpeza em andamento ficam reservadas no registro.
    func recoverAbandonedTrash() {
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let legacy = (try? fm.contentsOfDirectory(at: directory.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let legacyPrefix = "\(directory.lastPathComponent)-trash-"
        for url in urls.filter({ $0.lastPathComponent.hasPrefix(".trash-") }) + legacy.filter({ $0.lastPathComponent.hasPrefix(legacyPrefix) }) {
            guard ChapterTrashRegistry.shared.claim(url.path) else { continue }
            try? fm.removeItem(at: url)
            ChapterTrashRegistry.shared.release(url.path)
        }
    }
    private func invalidateLocked(_ key: String) {
        disabled.insert(key)
        generations[key, default: 0] &+= 1
    }
    public func remove(chapter key: String) {
        ioLock.withLock {
            lock.withLock { invalidateLocked(key) }
            try? fm.removeItem(at: folder(for: key))
        }
    }
    public func clear() {
        ioLock.withLock {
            lock.withLock { for key in Set(chapterOfURL.values) { invalidateLocked(key) } }
            try? fm.removeItem(at: directory)
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
    public var chapterCount: Int {
        ioLock.withLock {
            let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            return urls.filter { !$0.lastPathComponent.hasPrefix(".trash-") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
        }
    }
    public var size: Int64 {
        ioLock.withLock {
            guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            var total: Int64 = 0
            for case let url as URL in enumerator { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return total
        }
    }
}

/// Ordem da lista: mais recente primeiro. A contagem considera capítulos distintos já lidos.
enum ChapterCachePolicy {
    static func eligible(read: [Bool], partial: [Bool], identity: [String]) -> Set<Int> {
        guard read.count == partial.count, read.count == identity.count else { return [] }
        var laterRead = Set<String>()
        var result = Set<Int>()
        for index in read.indices {
            if read[index] || (partial[index] && laterRead.subtracting([identity[index]]).count >= 3) { result.insert(index) }
            if read[index] { laterRead.insert(identity[index]) }
        }
        return result
    }
}

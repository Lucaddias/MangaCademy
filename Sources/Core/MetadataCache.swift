import Foundation

/// Guarda o que já foi descoberto sobre cada obra de cada fonte (títulos alternativos, tags,
/// impressão digital da capa), para o catálogo não precisar abrir a página da obra de novo.
public final class MetadataCache: @unchecked Sendable {
    public static let shared = MetadataCache()

    public struct Entry: Codable {
        public var altTitles: [String]
        public var genres: [String]
        public var coverUrl: String?
        /// dHash da capa em hexadecimal (UInt64 não sobrevive bem a todo leitor de JSON).
        public var coverHash: String?
        public var savedAt: Date

        public var hash: UInt64? { coverHash.flatMap { UInt64($0, radix: 16) } }
    }

    private let ttl: TimeInterval = 14 * 24 * 3600
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var saveScheduled = false
    private let fileURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = caches.appendingPathComponent("work_metadata_v1.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            let now = Date()
            entries = decoded.filter { now.timeIntervalSince($0.value.savedAt) < ttl }
        }
    }

    public func entry(for refId: String) -> Entry? {
        lock.withLock { entries[refId] }
    }

    public func store(refId: String, altTitles: [String], genres: [String], coverUrl: String?, coverHash: UInt64?) {
        let entry = Entry(
            altTitles: altTitles,
            genres: genres,
            coverUrl: coverUrl,
            coverHash: coverHash.map { String($0, radix: 16) },
            savedAt: Date()
        )
        let shouldSchedule: Bool = lock.withLock {
            entries[refId] = entry
            if saveScheduled { return false }
            saveScheduled = true
            return true
        }
        if shouldSchedule {
            // Agrupa várias gravações em uma só
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.save()
            }
        }
    }

    public func clear() {
        lock.withLock { entries = [:] }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        let snapshot: [String: Entry] = lock.withLock {
            saveScheduled = false
            return entries
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

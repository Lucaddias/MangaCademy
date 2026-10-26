import Foundation
import CryptoKit
import ImageIO
import CoreGraphics

/// Bytes das imagens baixadas, em disco. Compartilhado entre a grade (ImageCache) e a
/// impressão digital das capas, para cada capa ser baixada uma vez só.
/// Capas e imagens soltas ficam em `Caches/MangaImageCache` (até `coverLimit`); páginas de
/// capítulos registrados no `ChapterPageCache` vão para a pasta do capítulo.
public final class ImageDiskStore: @unchecked Sendable {
    public static let shared = ImageDiskStore()

    public let directory: URL
    /// Teto do cache de capas: `trim()` apaga as usadas há mais tempo até ficar abaixo dele.
    public let coverLimit: Int64
    public let chapters: ChapterPageCache
    private let fm = FileManager.default

    public init(directory: URL? = nil, coverLimit: Int64 = 150 * 1024 * 1024, chapters: ChapterPageCache = .shared) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MangaImageCache", isDirectory: true)
        self.directory = base
        self.coverLimit = coverLimit
        self.chapters = chapters
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// Chave estável entre execuções (`hashValue` muda a cada abertura do app).
    public func path(for urlString: String) -> URL {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    public func data(for urlString: String) -> Data? {
        if chapters.isRegistered(urlString) { return chapters.data(for: urlString) }
        let file = path(for: urlString)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // A data de modificação marca o último uso, para o `trim()` apagar as mais antigas.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    public func store(_ data: Data, for urlString: String) {
        if chapters.store(data, for: urlString) { return }
        try? data.write(to: path(for: urlString), options: .atomic)
    }

    /// Apaga capas e páginas lidas (os downloads ficam).
    public func clear() {
        try? fm.removeItem(at: directory)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        chapters.clear()
    }

    /// Espaço ocupado pelas capas, em bytes.
    public var coverSize: Int64 {
        coverFiles().reduce(0) { $0 + $1.size }
    }

    /// Apaga as capas usadas há mais tempo até o cache ficar abaixo de `coverLimit`.
    public func trim() {
        let files = coverFiles().sorted { $0.date < $1.date }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total > coverLimit {
            try? fm.removeItem(at: file.url)
            total -= file.size
        }
    }

    private func coverFiles() -> [(url: URL, date: Date, size: Int64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0))
        }
    }

    /// Até esta versão, `MangaImageCache` misturava capas e todas as páginas lidas, sem limite.
    /// Na primeira abertura depois da atualização ele recomeça vazio (uma vez só).
    public func migrateLegacyCache(defaults: UserDefaults = .standard) {
        let flag = "imageCache.chapterPagesSplit"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        // Renomear é instantâneo; apagar milhares de páginas fica para segundo plano.
        let old = directory.deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent)-old-\(UUID().uuidString)", isDirectory: true)
        if (try? fm.moveItem(at: directory, to: old)) != nil {
            DispatchQueue.global(qos: .background).async { try? FileManager.default.removeItem(at: old) }
        } else {
            try? fm.removeItem(at: directory)
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Baixa (ou lê do disco) os bytes de uma imagem.
    public func fetch(urlString: String, referer: String?) async -> Data? {
        if let cached = data(for: urlString) { return cached }
        guard let url = URL(string: urlString) else { return nil }
        // Páginas baixadas e da Fonte Local já estão no aparelho.
        if url.isFileURL { return try? Data(contentsOf: url) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        // Servidores MangaDex@Home recusam User-Agent de navegador falsificado (respondem 404)
        let isMangaDexHome = url.host?.hasSuffix("mangadex.network") == true
        req.setValue(isMangaDexHome ? "MangaCademy-iOS/1.0" : HTTPClient.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        // Muitos sites bloqueiam imagens sem o Referer do próprio domínio (anti-hotlink)
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard !data.isEmpty else { return nil }
        store(data, for: urlString)
        return data
    }
}

/// "Impressão digital" da capa (dHash de 64 bits): a mesma arte redimensionada ou recomprimida
/// por sites diferentes dá hashes quase iguais, o que ajuda a reconhecer a mesma obra
/// mesmo quando os títulos foram traduzidos de formas diferentes.
public enum CoverFingerprint {
    public static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    public static func hash(urlString: String?, referer: String?) async -> UInt64? {
        guard let urlString, !looksLikePlaceholder(urlString) else { return nil }
        guard let data = await ImageDiskStore.shared.fetch(urlString: urlString, referer: referer) else { return nil }
        return hash(data: data)
    }

    /// Capas genéricas ("sem imagem") não identificam a obra.
    public static func looksLikePlaceholder(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return ["placeholder", "no-image", "noimage", "no_image", "nocover", "no-cover", "default-cover", "dflazy", "lazy.gif"]
            .contains { lower.contains($0) }
    }

    public static func hash(data: Data) -> UInt64? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Imagem quase lisa (capa em branco, erro do servidor) não tem informação suficiente
        guard let low = pixels.min(), let high = pixels.max(), Int(high) - Int(low) >= 24 else { return nil }

        var value: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    value |= 1 << bit
                }
                bit += 1
            }
        }
        return value
    }
}

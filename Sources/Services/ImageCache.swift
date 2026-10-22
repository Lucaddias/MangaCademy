import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
import ImageIO
#endif

public final class ImageCache {
    public static let shared = ImageCache()
    
    private let memoryCache = NSCache<NSString, UIImage>()
    /// Disco compartilhado com a impressão digital das capas (CoverFingerprint).
    private let disk = ImageDiskStore.shared
    
    public init() {
        memoryCache.countLimit = 150
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100MB
    }
    
    public func image(for urlString: String) -> UIImage? {
        let key = NSString(string: urlString)
        if let memoryImage = memoryCache.object(forKey: key) {
            return memoryImage
        }
        
        if let data = disk.data(for: urlString),
           let diskImage = UIImage(data: data) {
            memoryCache.setObject(diskImage, forKey: key, cost: data.count)
            return diskImage
        }
        
        return nil
    }
    
    public func insertImage(_ image: UIImage, data: Data, for urlString: String) {
        memoryCache.setObject(image, forKey: NSString(string: urlString), cost: data.count)
        disk.store(data, for: urlString)
    }
    
    /// Apaga só estas imagens (memória e disco), para baixá-las de novo.
    public func remove(urlStrings: [String]) {
        for urlString in urlStrings {
            memoryCache.removeObject(forKey: NSString(string: urlString))
            disk.remove(urlString)
        }
    }
    
    public func clearCache() {
        memoryCache.removeAllObjects()
        disk.clear()
    }
    
    public func load(urlString: String, referer: String? = nil) async -> UIImage? {
        if let cached = image(for: urlString) {
            return cached
        }
        guard let data = await disk.fetch(urlString: urlString, referer: referer),
              let img = UIImage(data: data) else { return nil }
        memoryCache.setObject(img, forKey: NSString(string: urlString), cost: data.count)
        return img
    }
}

// MARK: - Leitor

/// Página pronta para a tela: decodificada no tamanho da tela e, se for muito alta,
/// dividida em pedaços (o iOS não desenha imagens muito altas numa camada só).
public struct ReaderImage {
    public let image: UIImage
    public let tiles: [UIImage]
    /// Tamanho em pixels.
    public let pixelSize: CGSize

    public var aspectRatio: CGFloat { pixelSize.width / max(pixelSize.height, 1) }
    public var isWide: Bool { pixelSize.width > pixelSize.height }
}

extension ImageCache {
    private static let displayCache: NSCache<NSString, ReaderImageBox> = {
        let cache = NSCache<NSString, ReaderImageBox>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()
    /// Altura máxima de cada pedaço, em pixels.
    static let maxTileHeight = 4096

    /// Carrega a página reduzida para `maxPixelWidth` (sem decodificar a imagem inteira) e,
    /// se pedido, sem as bordas lisas.
    public func loadForDisplay(urlString: String, referer: String?, maxPixelWidth: Int, cropBorders: Bool) async -> ReaderImage? {
        let key = NSString(string: "\(urlString)#\(maxPixelWidth)#\(cropBorders)")
        if let box = Self.displayCache.object(forKey: key) { return box.value }
        guard let data = await ImageDiskStore.shared.fetch(urlString: urlString, referer: referer) else { return nil }
        let result = await Task.detached(priority: .userInitiated) {
            Self.decode(data, maxPixelWidth: maxPixelWidth, cropBorders: cropBorders)
        }.value
        if let result {
            let cost = Int(result.pixelSize.width * result.pixelSize.height * 4)
            Self.displayCache.setObject(ReaderImageBox(result), forKey: key, cost: cost)
        }
        return result
    }

    /// Só baixa para o disco (pré-carregamento), sem decodificar.
    public func prefetch(urlString: String, referer: String?) async {
        _ = await ImageDiskStore.shared.fetch(urlString: urlString, referer: referer)
    }

    nonisolated static func decode(_ data: Data, maxPixelWidth: Int, cropBorders: Bool) -> ReaderImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            return UIImage(data: data).flatMap { image in
                image.cgImage.map { split($0, scale: image.scale) }
            }
        }
        // O tamanho máximo vale para o lado maior: numa tira de webtoon, é a altura.
        let targetWidth = min(width, maxPixelWidth)
        let longest = width >= height ? targetWidth : Int(Double(height) * Double(targetWidth) / Double(width))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(longest, 1),
        ]
        guard var cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if cropBorders, let cropped = BorderCropper.crop(cgImage) { cgImage = cropped }
        return split(cgImage, scale: 1)
    }

    private nonisolated static func split(_ cgImage: CGImage, scale: CGFloat) -> ReaderImage {
        let full = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        var tiles: [UIImage] = []
        if cgImage.height > maxTileHeight {
            var y = 0
            while y < cgImage.height {
                let h = min(maxTileHeight, cgImage.height - y)
                if let tile = cgImage.cropping(to: CGRect(x: 0, y: y, width: cgImage.width, height: h)) {
                    tiles.append(UIImage(cgImage: tile, scale: scale, orientation: .up))
                }
                y += h
            }
        }
        return ReaderImage(image: full, tiles: tiles, pixelSize: CGSize(width: cgImage.width, height: cgImage.height))
    }
}

private final class ReaderImageBox {
    let value: ReaderImage
    init(_ value: ReaderImage) { self.value = value }
}

/// Corta margens lisas (brancas, pretas ou de qualquer cor uniforme) em volta da página.
public enum BorderCropper {
    /// Diferença máxima de cor (0–255) para considerar a borda lisa.
    static let tolerance = 24

    public static func crop(_ image: CGImage) -> CGImage? {
        // Analisa uma cópia pequena e aplica o corte na imagem real.
        let sampleWidth = min(image.width, 240)
        let sampleHeight = max(1, Int(Double(image.height) * Double(sampleWidth) / Double(image.width)))
        guard sampleHeight < 20_000,
              let ctx = CGContext(data: nil, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8, bytesPerRow: sampleWidth * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let raw = ctx.data else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        let pixels = raw.bindMemory(to: UInt8.self, capacity: sampleWidth * sampleHeight * 4)
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * sampleWidth + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        let ref = pixel(0, 0)
        func matches(_ p: (Int, Int, Int)) -> Bool {
            abs(p.0 - ref.0) <= tolerance && abs(p.1 - ref.1) <= tolerance && abs(p.2 - ref.2) <= tolerance
        }
        func rowIsBorder(_ y: Int) -> Bool { stride(from: 0, to: sampleWidth, by: 2).allSatisfy { matches(pixel($0, y)) } }
        func colIsBorder(_ x: Int) -> Bool { stride(from: 0, to: sampleHeight, by: 2).allSatisfy { matches(pixel(x, $0)) } }

        var top = 0, bottom = sampleHeight - 1, left = 0, right = sampleWidth - 1
        while top < bottom && rowIsBorder(top) { top += 1 }
        while bottom > top && rowIsBorder(bottom) { bottom -= 1 }
        while left < right && colIsBorder(left) { left += 1 }
        while right > left && colIsBorder(right) { right -= 1 }
        // Página quase toda lisa (ou nada para cortar): mantém.
        guard bottom - top > sampleHeight / 4, right - left > sampleWidth / 4,
              top > 0 || left > 0 || bottom < sampleHeight - 1 || right < sampleWidth - 1 else { return nil }
        let scale = Double(image.width) / Double(sampleWidth)
        // Na memória do contexto a primeira linha é a de cima, como em `cropping(to:)`.
        let rect = CGRect(
            x: Double(left) * scale,
            y: Double(top) * scale,
            width: Double(right - left + 1) * scale,
            height: Double(bottom - top + 1) * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return image.cropping(to: rect)
    }
}

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
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

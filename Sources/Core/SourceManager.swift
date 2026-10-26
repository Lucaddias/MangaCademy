import Foundation
import SwiftUI

/// Registro de todas as fontes Keiyoushi que têm motor iOS.
@Observable
public final class SourceManager {
    public static let shared = SourceManager()

    public private(set) var sources: [MangaSource] = []
    private var byId: [String: MangaSource] = [:]
    private var nsfwIds: Set<String> = []
    private var safeIds: Set<String> = []
    private let lock = NSLock()

    public init() {
        rebuild()
    }

    /// Recria as fontes a partir do catálogo Keiyoushi (empacotado ou atualizado ao vivo).
    public func rebuild() {
        var list: [MangaSource] = []
        var nsfw: Set<String> = []
        var safe: Set<String> = []
        var builtIns: Set<String> = []

        for ext in KeiyoushiRepository.shared.extensions {
            guard let engine = ext.engine else { continue }
            switch engine.type {
            case "mangadex":
                if builtIns.insert("mangadex").inserted { list.append(MangaDexSource()) }
            case "comick":
                if builtIns.insert("comick").inserted {
                    list.append(ComicKSource(baseUrl: ext.sources.first?.baseUrl ?? "https://comick.live"))
                }
            case "nexustoons":
                if builtIns.insert("nexustoons").inserted { list.append(NexusToonsSource()) }
            default:
                for info in ext.sources {
                    guard let source = Self.makeThemeSource(engine: engine, info: info) else { continue }
                    list.append(source)
                    if ext.isNsfw { nsfw.insert(source.id) }
                    if ext.contentWarning == "SAFE" { safe.insert(source.id) }
                }
            }
        }
        // Fontes nativas continuam disponíveis mesmo se o catálogo falhar
        if !builtIns.contains("mangadex") { list.insert(MangaDexSource(), at: 0) }
        if !builtIns.contains("nexustoons") { list.append(NexusToonsSource()) }
        if !builtIns.contains("comick") { list.append(ComicKSource()) }
        list.append(WeebCentralSource())

        lock.lock()
        sources = list
        byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        nsfwIds = nsfw
        safeIds = safe
        lock.unlock()
    }

    private static func makeThemeSource(engine: KeiyoushiEngineConfig, info: KeiyoushiSourceInfo) -> MangaSource? {
        let id = "ky-\(info.id)"
        let lang = LanguageCode.normalize(info.lang)
        switch engine.type {
        case "madara":
            return MadaraSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "mangathemesia":
            return MangaThemesiaSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "zeistmanga":
            return ZeistMangaSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "keyoapp":
            return KeyoappSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "iken":
            return IkenSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "pizzareader":
            return PizzaReaderSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "mangacatalog":
            return MangaCatalogSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "yiimanga":
            return YiiMangaSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "mangahub":
            return MangaHubSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "foolslide":
            return FoolSlideSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "guya":
            return GuyaSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "mmrcms":
            return MMRCMSSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "keyoappv2":
            return KeyoappV2Source(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "webtoons":
            return WebtoonsSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "namicomi":
            return NamiComiSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "globalcomix":
            return GlobalComixSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "mangaball":
            return MangaBallSource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        case "comicfury":
            return ComicFurySource(id: id, name: info.name, language: lang, baseUrl: info.baseUrl, config: engine)
        default:
            return nil
        }
    }

    public func getSource(id: String) -> MangaSource? {
        lock.lock()
        defer { lock.unlock() }
        return byId[id]
    }

    public func sourceName(id: String) -> String {
        getSource(id: id)?.name ?? id
    }

    /// Fontes para a lista "Fontes" do Explorar (respeita +18 e as desativadas).
    public func browsableSources(includeNsfw: Bool, includeDisabled: Bool = false) -> [MangaSource] {
        lock.lock()
        let all = sources
        let nsfw = nsfwIds
        lock.unlock()
        let settings = SourceSettings.shared
        return all.filter { (includeNsfw || !nsfw.contains($0.id)) && (includeDisabled || settings.isEnabled($0)) }
    }

    public func isNsfw(_ sourceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nsfwIds.contains(sourceId)
    }

    /// Fontes que alimentam o catálogo para um filtro de idioma, na ordem em que serão consultadas.
    public func catalogSources(for filter: LanguageFilter, includeNsfw: Bool) -> [MangaSource] {
        lock.lock()
        let all = sources
        let nsfw = nsfwIds
        let safe = safeIds
        lock.unlock()

        let preferred = filter.preferredLanguages
        func rank(_ s: MangaSource) -> (Int, Int, Int, String) {
            let priority: Int
            switch s.id {
            case "mangadex": priority = 0
            case "nexustoons", "comick": priority = 1
            default: priority = 2
            }
            let langRank = preferred.firstIndex(of: s.language) ?? preferred.count
            return (priority, langRank, safe.contains(s.id) ? 0 : 1, s.name.lowercased())
        }

        let settings = SourceSettings.shared
        return all
            .filter { (includeNsfw || !nsfw.contains($0.id)) && settings.isEnabled($0) }
            .compactMap { source -> MangaSource? in
                if let scoped = source as? LanguageScopedSource {
                    return scoped.scoped(to: filter, includeNsfw: includeNsfw)
                }
                // Fontes multi-idioma sem filtro no servidor só entram em "Todos"
                if source.language == "all" { return filter == .all ? source : nil }
                return filter.matches(source.language) ? source : nil
            }
            .sorted { rank($0) < rank($1) }
    }
}

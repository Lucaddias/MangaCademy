import Foundation
import SwiftUI

public struct KeiyoushiSourceInfo: Identifiable, Hashable, Codable {
    public let id: String
    public let name: String
    public let lang: String
    public let baseUrl: String

    public init(id: String, name: String, lang: String, baseUrl: String) {
        self.id = id
        self.name = name
        self.lang = lang
        self.baseUrl = baseUrl
    }
}

/// Motor iOS que reimplementa o tema/extensão Kotlin e os ajustes que cada site sobrescreve.
public struct KeiyoushiEngineConfig: Hashable, Codable {
    public let type: String
    // Madara
    public var noAjax: Bool?
    public var chapterMode: String?
    public var mangaSubString: String?
    public var ajaxTemplate: String?
    public var supportsPostId: Bool?
    public var filterNonMangaItems: Bool?
    public var pageSize: Int?
    // MangaThemesia
    public var mangaUrlDirectory: String?
    // ZeistManga
    public var mangaCategory: String?
    public var chapterCategory: String?
    // Iken, PizzaReader
    public var apiUrl: String?
    public var perPage: Int?
    // MangaCatalog: séries do site, pares [nome, caminho]
    public var series: [[String]]?
    // Yiimanga, MMRCMS
    public var searchParam: String?
    public var popularPath: String?
    // MangaHub: acervo do site na API ("m01", "mf01"...)
    public var mangaSource: String?
    // FoolSlide
    public var urlModifier: String?
    // MMRCMS
    public var itemPath: String?
    public var dateFormat: String?
    public var chapterNamePrefix: String?
}

public struct KeiyoushiExtensionItem: Identifiable, Hashable, Codable {
    public var id: String { pkg }
    public let name: String
    public let pkg: String
    public let version: String
    public let iconUrl: String
    public let contentWarning: String
    public let engine: KeiyoushiEngineConfig?
    public let sources: [KeiyoushiSourceInfo]

    public var isNsfw: Bool { contentWarning == "NSFW" }
    public var isSupported: Bool { engine != nil }

    func with(engine: KeiyoushiEngineConfig?) -> KeiyoushiExtensionItem {
        KeiyoushiExtensionItem(name: name, pkg: pkg, version: version, iconUrl: iconUrl, contentWarning: contentWarning, engine: engine, sources: sources)
    }
}

struct KeiyoushiCatalog: Codable {
    let generatedAt: String
    let extensions: [KeiyoushiExtensionItem]
}

@Observable
public final class KeiyoushiRepository {
    public static let shared = KeiyoushiRepository()

    public static let indexURL = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.json"

    public private(set) var extensions: [KeiyoushiExtensionItem] = []
    public private(set) var isLoading = false
    public private(set) var lastUpdated: Date?
    public private(set) var lastError: String?

    /// Motores conhecidos por pacote (vindos do catálogo empacotado no app).
    private var bundledEngines: [String: KeiyoushiEngineConfig] = [:]

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keiyoushi_catalog_live.json")
    }

    public init() {
        loadBundledExtensions()
    }

    public var supportedSourceCount: Int {
        extensions.filter(\.isSupported).reduce(0) { $0 + $1.sources.count }
    }

    public var totalSourceCount: Int {
        extensions.reduce(0) { $0 + $1.sources.count }
    }

    public func loadBundledExtensions() {
        guard let url = Bundle.main.url(forResource: "keiyoushi_catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(KeiyoushiCatalog.self, from: data) else {
            return
        }
        bundledEngines = Dictionary(
            catalog.extensions.compactMap { ext in ext.engine.map { (ext.pkg, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        extensions = catalog.extensions
        lastUpdated = ISO8601DateFormatter().date(from: catalog.generatedAt)

        // Índice baixado anteriormente tem prioridade (domínios dos sites mudam com frequência)
        if let cached = try? Data(contentsOf: Self.cacheURL),
           let live = try? JSONDecoder().decode(KeiyoushiCatalog.self, from: cached) {
            // Motores sempre vêm do catálogo desta versão do app (o cache só atualiza domínios/fontes)
            extensions = live.extensions.map { $0.with(engine: bundledEngines[$0.pkg]) }
            lastUpdated = ISO8601DateFormatter().date(from: live.generatedAt) ?? lastUpdated
        }
    }

    /// Baixa o index.json oficial do repositório Keiyoushi e atualiza fontes/domínios.
    @MainActor
    public func refreshLive() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let json = try await HTTPClient.shared.json(Self.indexURL, userAgent: "MangaCademy-iOS")
            guard let root = json as? [String: Any],
                  let list = root.dict("extensionList")?.array("extensions") else {
                throw HTTPError.parse("o índice do Keiyoushi")
            }
            let updated: [KeiyoushiExtensionItem] = list.compactMap { ext in
                guard let pkg = ext.string("packageName"), let name = ext.string("name") else { return nil }
                let sources = ext.array("sources").compactMap { s -> KeiyoushiSourceInfo? in
                    guard let id = s.string("id"), let home = s.string("homeUrl") else { return nil }
                    return KeiyoushiSourceInfo(
                        id: id,
                        name: s.string("name") ?? name,
                        lang: s.string("language") ?? "all",
                        baseUrl: home.hasSuffix("/") ? String(home.dropLast()) : home
                    )
                }
                return KeiyoushiExtensionItem(
                    name: name,
                    pkg: pkg,
                    version: ext.string("versionName") ?? "",
                    iconUrl: ext.dict("resources")?.string("iconUrl") ?? "",
                    contentWarning: (ext.string("contentWarning") ?? "").replacingOccurrences(of: "CONTENT_WARNING_", with: ""),
                    engine: bundledEngines[pkg],
                    sources: sources
                )
            }
            guard !updated.isEmpty else { throw HTTPError.parse("o índice do Keiyoushi") }

            let now = Date()
            let catalog = KeiyoushiCatalog(generatedAt: ISO8601DateFormatter().string(from: now), extensions: updated)
            if let data = try? JSONEncoder().encode(catalog) {
                try? data.write(to: Self.cacheURL)
            }
            extensions = updated
            lastUpdated = now
            SourceManager.shared.rebuild()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func filterExtensions(
        query: String,
        language: LanguageFilter,
        includeNsfw: Bool,
        onlySupported: Bool = false
    ) -> [KeiyoushiExtensionItem] {
        let q = query.trimmingCharacters(in: .whitespaces).localizedLowercase
        return extensions.filter { ext in
            if !includeNsfw && ext.isNsfw { return false }
            if onlySupported && !ext.isSupported { return false }
            if language != .all {
                let matches = ext.sources.contains { language.matches(LanguageCode.normalize($0.lang)) }
                if !matches { return false }
            }
            if !q.isEmpty {
                return ext.name.localizedLowercase.contains(q)
                    || ext.sources.contains { $0.name.localizedLowercase.contains(q) || $0.baseUrl.contains(q) }
            }
            return true
        }
    }
}

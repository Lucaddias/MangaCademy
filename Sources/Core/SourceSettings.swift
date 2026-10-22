import Foundation

/// Fontes e idiomas desativados, fontes fixadas e a última fonte aberta (como no Mihon).
@Observable
public final class SourceSettings {
    public static let shared = SourceSettings()

    private let defaults: UserDefaults

    public var disabledSources: Set<String> { didSet { save(disabledSources, "disabled_sources") } }
    public var disabledLanguages: Set<String> { didSet { save(disabledLanguages, "disabled_source_languages") } }
    public var pinnedSources: Set<String> { didSet { save(pinnedSources, "pinned_sources") } }
    public var lastUsedSource: String? { didSet { defaults.set(lastUsedSource, forKey: "catalog_last_source") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabledSources = Set(defaults.stringArray(forKey: "disabled_sources") ?? [])
        disabledLanguages = Set(defaults.stringArray(forKey: "disabled_source_languages") ?? [])
        pinnedSources = Set(defaults.stringArray(forKey: "pinned_sources") ?? [])
        lastUsedSource = defaults.string(forKey: "catalog_last_source")
    }

    private func save(_ set: Set<String>, _ key: String) {
        defaults.set(set.sorted(), forKey: key)
    }

    public func isEnabled(_ source: MangaSource) -> Bool {
        !disabledSources.contains(source.id) && !disabledLanguages.contains(source.language)
    }

    public func toggle(_ id: String, in keyPath: ReferenceWritableKeyPath<SourceSettings, Set<String>>) {
        if self[keyPath: keyPath].contains(id) {
            self[keyPath: keyPath].remove(id)
        } else {
            self[keyPath: keyPath].insert(id)
        }
    }
}

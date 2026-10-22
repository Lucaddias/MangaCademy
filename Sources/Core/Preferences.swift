import Foundation

/// Chaves e valores padrão das preferências do app (UserDefaults / `@AppStorage`).
/// As strings das chaves não mudam: são as mesmas já gravadas nos aparelhos.
public enum Preferences {
    public enum Key {
        /// Filtro rápido de idioma do catálogo (`LanguageFilter.rawValue`).
        public static let languageFilter = "catalog_language_filter"
        /// Inclui no catálogo as fontes marcadas como +18 no índice Keiyoushi.
        public static let showNsfwSources = "show_nsfw_sources"
        /// Esconde obras com tag adulta ("Adult", "Adulto", "+18"...).
        public static let blockAdultTags = "block_adult_tags"
        /// Leitor abre em modo Webtoon (rolagem contínua) em vez de paginado.
        public static let defaultReaderWebtoon = "default_reader_webtoon"
        /// Botões de volume viram a página no leitor.
        public static let readerVolumeButtons = "reader_volume_buttons"
        /// Inverte os botões de volume (Volume + avança).
        public static let readerInvertVolumeButtons = "reader_volume_buttons_inverted"
    }

    public enum Default {
        public static let languageFilter = LanguageFilter.portuguese
        public static let showNsfwSources = false
        public static let blockAdultTags = true
        public static let defaultReaderWebtoon = true
        public static let readerVolumeButtons = true
        public static let readerInvertVolumeButtons = false
    }

    public static var languageFilter: LanguageFilter {
        UserDefaults.standard.string(forKey: Key.languageFilter).flatMap(LanguageFilter.init(rawValue:)) ?? Default.languageFilter
    }

    public static var showNsfwSources: Bool {
        bool(Key.showNsfwSources, default: Default.showNsfwSources)
    }

    public static var blockAdultTags: Bool {
        bool(Key.blockAdultTags, default: Default.blockAdultTags)
    }

    public static var defaultReaderWebtoon: Bool {
        bool(Key.defaultReaderWebtoon, default: Default.defaultReaderWebtoon)
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}
